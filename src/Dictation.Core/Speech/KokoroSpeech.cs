using System.Diagnostics;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;
using Dictation.Core.Setup;

namespace Dictation.Core.Speech;

/// <summary>A voice that Read aloud can use.</summary>
public sealed record VoiceOption(string Id, string Name);

/// <summary>
/// Text-to-speech through inference/tts_server.py (Kokoro on ONNX Runtime). The Python process starts on first use
/// and then stays up so later readings start instantly. One sentence per request.
/// </summary>
public sealed class KokoroSpeech : IAsyncDisposable
{
    public const int SampleRate = 24000;

    /// <summary>A short list of Kokoro v1.0's best English voices.</summary>
    public static readonly IReadOnlyList<VoiceOption> Voices = new[]
    {
        new VoiceOption("af_heart", "Heart (American, female)"),
        new VoiceOption("af_bella", "Bella (American, female)"),
        new VoiceOption("af_nicole", "Nicole (American, female, soft)"),
        new VoiceOption("am_michael", "Michael (American, male)"),
        new VoiceOption("am_fenrir", "Fenrir (American, male)"),
        new VoiceOption("bf_emma", "Emma (British, female)"),
        new VoiceOption("bm_george", "George (British, male)"),
        new VoiceOption("bm_fable", "Fable (British, male)"),
    };

    readonly SettingsService _settings;
    readonly SemaphoreSlim _lock = new(1, 1);
    Process? _proc;
    ClientWebSocket? _ws;
    int _nextId;

    public KokoroSpeech(SettingsService settings) => _settings = settings;

    bool Connected => _ws?.State == WebSocketState.Open && _proc is { HasExited: false };

    /// <summary>Start the voice server if it isn't running. Takes a few seconds the first time.</summary>
    public async Task EnsureStartedAsync(CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct);
        try { await EnsureStartedLockedAsync(ct); }
        finally { _lock.Release(); }
    }

    async Task EnsureStartedLockedAsync(CancellationToken ct)
    {
        if (Connected) return;
        if (!RuntimeInstaller.ReadAloudInstalled)
            throw new UserFacingException("Read aloud isn't installed yet.");
        Stop();
        var port = _settings.Current.TtsPort;
        var psi = new ProcessStartInfo(AppPaths.PythonExe)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = AppPaths.Root,
        };
        foreach (var a in new[]
        {
            "-u", Path.Combine(AppPaths.InferenceDir, "tts_server.py"),
            "--model", RuntimeInstaller.KokoroModel, "--voices", RuntimeInstaller.KokoroVoices, "--port", port.ToString(),
        }) psi.ArgumentList.Add(a);
        psi.Environment["PYTHONUTF8"] = "1";

        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        p.OutputDataReceived += (_, e) =>
        {
            if (e.Data == null) return;
            Log.Info("tts: " + e.Data);
            if (e.Data.StartsWith("READY")) started.TrySetResult();
            else if (e.Data.StartsWith("ERROR")) started.TrySetException(new UserFacingException(
                "The voice model could not be loaded. Try reinstalling Read aloud under Settings › Read aloud."));
        };
        p.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) Log.Info("tts: " + e.Data); };
        p.Exited += (_, _) => started.TrySetException(new UserFacingException("The voice engine stopped unexpectedly."));
        p.Start();
        ChildProcessJob.Add(p);
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        _proc = p;

        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            timeout.CancelAfter(TimeSpan.FromMinutes(2));
            using (timeout.Token.Register(() => started.TrySetCanceled()))
                await started.Task;
        }
        _ws = new ClientWebSocket();
        await _ws.ConnectAsync(new Uri($"ws://127.0.0.1:{port}/"), ct);
        await ReceiveTextAsync(ct); // the "ready" greeting
    }

    /// <summary>Speak one short piece of text. Returns mono float samples at <see cref="SampleRate"/>.</summary>
    /// <param name="speed">0.5 to 2.0; Kokoro changes the pace without changing the pitch.</param>
    public async Task<float[]> SynthesizeAsync(string text, string voice, double speed, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct);
        try
        {
            await EnsureStartedLockedAsync(ct);
            var id = ++_nextId;
            var request = JsonSerializer.Serialize(new { type = "speak", id, text, voice, speed });
            await _ws!.SendAsync(Encoding.UTF8.GetBytes(request), WebSocketMessageType.Text, true, ct);
            using var reply = JsonDocument.Parse(await ReceiveTextAsync(ct));
            var root = reply.RootElement;
            if (root.GetProperty("type").GetString() == "error")
                throw new UserFacingException("The voice engine couldn't read that: " + root.GetProperty("message").GetString());
            var pcm = await ReceiveBinaryAsync(ct);
            var samples = new float[pcm.Length / 4];
            Buffer.BlockCopy(pcm, 0, samples, 0, samples.Length * 4);
            return samples;
        }
        catch (WebSocketException e)
        {
            Stop(); // restart on the next request
            throw new UserFacingException("Lost the connection to the voice engine.", e);
        }
        finally { _lock.Release(); }
    }

    async Task<string> ReceiveTextAsync(CancellationToken ct) => Encoding.UTF8.GetString(await ReceiveAsync(WebSocketMessageType.Text, ct));
    Task<byte[]> ReceiveBinaryAsync(CancellationToken ct) => ReceiveAsync(WebSocketMessageType.Binary, ct);

    async Task<byte[]> ReceiveAsync(WebSocketMessageType expected, CancellationToken ct)
    {
        var buf = new byte[64 * 1024];
        using var ms = new MemoryStream();
        WebSocketReceiveResult r;
        do
        {
            r = await _ws!.ReceiveAsync(buf, ct);
            if (r.MessageType == WebSocketMessageType.Close) throw new WebSocketException("The voice engine closed the connection.");
            ms.Write(buf, 0, r.Count);
        } while (!r.EndOfMessage);
        if (r.MessageType != expected) throw new WebSocketException("Unexpected message from the voice engine.");
        return ms.ToArray();
    }

    void Stop()
    {
        try { _ws?.Dispose(); } catch { }
        _ws = null;
        try { if (_proc is { HasExited: false }) _proc.Kill(true); } catch { }
        _proc = null;
    }

    public ValueTask DisposeAsync()
    {
        Stop();
        return ValueTask.CompletedTask;
    }
}
