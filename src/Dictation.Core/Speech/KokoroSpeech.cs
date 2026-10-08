using System.Diagnostics;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;
using Dictation.Core.Setup;

namespace Dictation.Core.Speech;

/// <summary>
/// Text-to-speech through inference/tts_server.py: the local voice server, running Kokoro and Piper voices on ONNX
/// Runtime (see <see cref="VoiceCatalog"/>). The Python process starts on first use
/// and then stays up so later readings start instantly. One sentence per request.
/// </summary>
public sealed class KokoroSpeech : ISpeechSynthesizer, IAsyncDisposable
{
    public const int SampleRate = 24000;

    /// <summary>Kokoro's voices; see <see cref="VoiceCatalog"/>.</summary>
    public static IReadOnlyList<VoiceOption> Voices => VoiceCatalog.KokoroVoices;

    /// <summary>How long one request may take before the engine counts as hung.</summary>
    static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(60);

    readonly SettingsService _settings;
    readonly SemaphoreSlim _lock = new(1, 1);
    Process? _proc;
    Task? _started; // completes when the running process prints READY
    ClientWebSocket? _ws;
    int _nextId;
    bool _withKokoro; // the running server loaded Kokoro

    public KokoroSpeech(SettingsService settings) => _settings = settings;

    bool ProcessAlive => _proc is { HasExited: false };
    /// <summary>The voice engine is running (its model is in memory).</summary>
    public bool IsRunning => ProcessAlive;
    /// <summary>When the voice was last asked to speak; for unloading it when idle.</summary>
    public DateTime LastUsed { get; private set; } = DateTime.Now;

    /// <summary>Stop the voice engine to free its memory; it starts again on the next reading.</summary>
    public async Task UnloadAsync()
    {
        await _lock.WaitAsync();
        try
        {
            if (!ProcessAlive) return;
            Stop();
            Log.Info("Read aloud voice unloaded after being idle");
        }
        finally { _lock.Release(); }
    }
    bool Connected => _ws?.State == WebSocketState.Open && ProcessAlive;

    /// <summary>Start the voice server if it isn't running. Takes a few seconds the first time.</summary>
    public async Task EnsureStartedAsync(CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct);
        try { await EnsureStartedLockedAsync(ct); }
        finally { _lock.Release(); }
    }

    async Task EnsureStartedLockedAsync(CancellationToken ct)
    {
        // A server started before Kokoro was downloaded doesn't have it: start afresh so it loads.
        if (ProcessAlive && !_withKokoro && RuntimeInstaller.ReadAloudInstalled) Stop();
        if (Connected) return;
        if (!RuntimeInstaller.VoiceEngineInstalled)
            throw new UserFacingException("Read aloud isn't installed yet.");

        // A dead socket doesn't mean a dead engine (a cancelled read aborts the socket, for one): reconnect to the
        // running process instead of paying for a restart.
        if (ProcessAlive && _started != null)
        {
            try
            {
                await WaitStartedAsync(_started, ct);
                await ConnectLockedAsync(ct);
                return;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception e) when (e is WebSocketException or OperationCanceledException or UserFacingException)
            {
                Log.Warn("Couldn't reconnect to the voice engine, restarting it: " + e.Message);
            }
        }

        Stop();
        var port = _settings.Current.TtsPort;
        var psi = new ProcessStartInfo(AppPaths.PythonExe)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = AppPaths.Root,
        };
        var args = new List<string>
        {
            "-u", Path.Combine(AppPaths.InferenceDir, "tts_server.py"), "--piper-dir", RuntimeInstaller.PiperDir, "--port", port.ToString(),
        };
        _withKokoro = RuntimeInstaller.ReadAloudInstalled;
        if (_withKokoro) args.AddRange(new[] { "--model", RuntimeInstaller.KokoroModel, "--voices", RuntimeInstaller.KokoroVoices });
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["PYTHONUTF8"] = "1";

        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        p.OutputDataReceived += (_, e) =>
        {
            if (e.Data == null) return;
            Log.Info("tts: " + e.Data);
            if (e.Data.StartsWith("READY")) started.TrySetResult();
            else if (e.Data.StartsWith("ERROR")) started.TrySetException(new UserFacingException(
                "The voice model could not be loaded. Try downloading the voice again under Read aloud."));
        };
        p.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) Log.Info("tts: " + e.Data); };
        p.Exited += (_, _) => started.TrySetException(new UserFacingException("The voice engine stopped unexpectedly."));
        p.Start();
        ChildProcessJob.Add(p);
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        _proc = p;
        _started = started.Task;

        await WaitStartedAsync(_started, ct);
        await ConnectLockedAsync(ct);
    }

    static async Task WaitStartedAsync(Task started, CancellationToken ct)
    {
        try { await started.WaitAsync(TimeSpan.FromMinutes(2), ct); }
        catch (TimeoutException) { throw new UserFacingException("The voice engine took too long to start."); }
    }

    /// <summary>Open a fresh connection to the running server and read its greeting.</summary>
    async Task ConnectLockedAsync(CancellationToken ct)
    {
        DropSocket();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        var ws = new ClientWebSocket();
        _ws = ws;
        await ws.ConnectAsync(new Uri($"ws://127.0.0.1:{_settings.Current.TtsPort}/"), timeout.Token);
        await ReceiveTextAsync(timeout.Token); // the "ready" greeting
    }

    /// <summary>Speak one short piece of text. Returns mono float samples at <see cref="SampleRate"/>.</summary>
    /// <param name="speed">0.25 to 4.0; the pace changes, never the pitch (past 0.5–2 the server time-stretches).</param>
    /// <remarks>
    /// <paramref name="ct"/> is only checked between socket calls, never passed to them: cancelling a pending
    /// WebSocket call aborts the connection. A cancelled request finishes (about a second) and its audio is dropped.
    /// </remarks>
    public async Task<float[]> SynthesizeAsync(string text, string voice, double speed, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct);
        LastUsed = DateTime.Now;
        try
        {
            for (var attempt = 1; ; attempt++)
            {
                try { await EnsureStartedLockedAsync(ct); }
                catch (Exception e) when (e is WebSocketException || e is OperationCanceledException && !ct.IsCancellationRequested)
                {
                    Stop();
                    throw new UserFacingException("Couldn't connect to the voice engine.", e);
                }
                try
                {
                    return await SpeakLockedAsync(text, voice, speed, ct);
                }
                catch (Exception e) when (e is WebSocketException || e is OperationCanceledException && !ct.IsCancellationRequested)
                {
                    DropSocket();
                    if (!ProcessAlive) Stop(); // restart on the next request
                    else if (attempt == 1 && e is WebSocketException)
                    {
                        Log.Warn("Lost the connection to the voice engine, reconnecting: " + e.Message);
                        continue;
                    }
                    if (e is OperationCanceledException)
                    {
                        Stop(); // hung: start afresh next time
                        throw new UserFacingException("The voice engine stopped responding.", e);
                    }
                    throw new UserFacingException("Lost the connection to the voice engine.", e);
                }
            }
        }
        finally { _lock.Release(); }
    }

    async Task<float[]> SpeakLockedAsync(string text, string voice, double speed, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        using var timeout = new CancellationTokenSource(RequestTimeout);
        var id = ++_nextId;
        var request = JsonSerializer.Serialize(new { type = "speak", id, text, voice, speed });
        await _ws!.SendAsync(Encoding.UTF8.GetBytes(request), WebSocketMessageType.Text, true, timeout.Token);
        using var reply = JsonDocument.Parse(await ReceiveTextAsync(timeout.Token));
        var root = reply.RootElement;
        if (root.GetProperty("type").GetString() == "error")
            throw new UserFacingException("The voice engine couldn't read that: " + root.GetProperty("message").GetString());
        var pcm = await ReceiveBinaryAsync(timeout.Token);
        ct.ThrowIfCancellationRequested(); // the reading was stopped meanwhile; the connection stays usable
        var samples = new float[pcm.Length / 4];
        Buffer.BlockCopy(pcm, 0, samples, 0, samples.Length * 4);
        return samples;
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

    void DropSocket()
    {
        try { _ws?.Dispose(); } catch { }
        _ws = null;
    }

    void Stop()
    {
        DropSocket();
        try { if (_proc is { HasExited: false }) _proc.Kill(true); } catch { }
        _proc = null;
        _started = null;
    }

    public ValueTask DisposeAsync()
    {
        Stop();
        return ValueTask.CompletedTask;
    }
}
