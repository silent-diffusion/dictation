using System.Diagnostics;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;

namespace Dictation.Core.Speech;

/// <summary>
/// A replaceable speech-to-text engine. Audio is pushed in as 16 kHz mono 16-bit PCM;
/// partial results stream out while recording and one final result is returned by <see cref="StopAsync"/>.
/// </summary>
public interface ISpeechRecognizer : IAsyncDisposable
{
    event Action<string>? PartialTranscript;
    /// <summary>Live mode: a finished piece (whole sentences) that will not change any more. Raised on a background thread.</summary>
    event Action<string>? Committed;
    event Action<string>? FinalTranscript;
    /// <summary>Human-readable status for the UI ("Loading speech model…", "Ready (GPU)").</summary>
    event Action<string, bool>? StatusChanged;
    bool IsReady { get; }
    string Status { get; }
    /// <summary>Load the model / start the engine. Safe to call repeatedly.</summary>
    Task InitializeAsync(CancellationToken ct = default);
    /// <summary>Make sure the engine runs <paramref name="model"/> (null = the model in Settings), restarting it with that
    /// model if another one is loaded. Safe to call repeatedly.</summary>
    Task InitializeAsync(string? model, CancellationToken ct);
    /// <summary>The model the running engine was started with; null when it isn't running.</summary>
    string? LoadedModel { get; }
    /// <summary>Begin a new utterance. Returns immediately; audio may be pushed right away.</summary>
    /// <param name="live">Commit finished sentences every few seconds (<see cref="Committed"/>) instead of
    /// streaming partial transcripts.</param>
    void Start(bool live = false);
    void AcceptAudio(byte[] pcm16kMono);
    /// <summary>Live mode: the transcript of the speech after the last <see cref="Committed"/> piece, from the last StopAsync.</summary>
    string FinalTail { get; }
    /// <summary>Stop, finish decoding and return the final raw transcript.</summary>
    Task<string> StopAsync(CancellationToken ct = default);
    void Cancel();
    /// <summary>Restart the engine with current settings (after the user changed the model, etc.).</summary>
    /// <param name="model">null = the model in Settings.</param>
    Task RestartAsync(string? model = null);
    /// <summary>Free the model's memory (GPU memory especially). The next <see cref="InitializeAsync"/> loads it again.</summary>
    Task UnloadAsync();
}

/// <summary>
/// Talks to inference/asr_server.py (faster-whisper on CUDA) over a loopback WebSocket.
/// The Python process is a child of the app and is killed when the app exits.
/// </summary>
public sealed class SidecarSpeechRecognizer : ISpeechRecognizer
{
    readonly SettingsService _settings;
    readonly SemaphoreSlim _initLock = new(1, 1);
    Process? _proc;
    ClientWebSocket? _ws;
    Channel<(bool Binary, byte[] Data)> _outbox = NewOutbox();
    TaskCompletionSource<string>? _final;
    CancellationTokenSource _lifetime = new();
    volatile bool _ready;
    string _status = "Speech engine not started";

    public event Action<string>? PartialTranscript;
    public event Action<string>? Committed;
    public string FinalTail { get; private set; } = "";
    public event Action<string>? FinalTranscript;
    public event Action<string, bool>? StatusChanged;
    public bool IsReady => _ready && _ws?.State == WebSocketState.Open;
    public string Status => _status;

    public SidecarSpeechRecognizer(SettingsService settings) => _settings = settings;

    static Channel<(bool, byte[])> NewOutbox() => Channel.CreateUnbounded<(bool, byte[])>(
        new UnboundedChannelOptions { SingleReader = true });

    void SetStatus(string s, bool ok)
    {
        _status = s;
        StatusChanged?.Invoke(s, ok);
    }

    public Task InitializeAsync(CancellationToken ct = default) => InitializeAsync(null, ct);

    public string? LoadedModel => IsReady ? _loadedModel : null;
    string? _loadedModel;

    public async Task InitializeAsync(string? model, CancellationToken ct)
    {
        await _initLock.WaitAsync(ct);
        try
        {
            var asr = _settings.Current.Asr;
            var wanted = string.IsNullOrWhiteSpace(model) ? asr.Model : model.Trim();
            if (IsReady && string.Equals(_loadedModel, wanted, StringComparison.OrdinalIgnoreCase)) return;
            if (IsReady)
            {
                // A profile with its own speech model: swap the model (the engine loads one at a time).
                Log.Info($"Switching the speech model from {_loadedModel} to {wanted}");
                _ready = false;
                _lifetime.Cancel();
                KillProcess();
            }
            if (!File.Exists(AppPaths.PythonExe) || !File.Exists(Path.Combine(AppPaths.InferenceDir, "asr_server.py")))
            {
                SetStatus("Speech engine is not installed", false);
                throw new UserFacingException(
                    "The speech engine isn't installed yet. Run scripts\\setup.ps1 once (it needs internet), then restart the app.");
            }

            SetStatus($"Loading speech model ({wanted})…", false);
            await StartProcessAsync(asr, wanted, ct);
            await ConnectAsync(asr.Port, ct);
            _loadedModel = wanted;
        }
        catch (Exception e) when (e is not UserFacingException && e is not OperationCanceledException)
        {
            SetStatus("Speech engine failed to start", false);
            throw new UserFacingException("The speech engine failed to start. See data\\logs\\dictation.log for details.", e);
        }
        finally { _initLock.Release(); }
    }

    async Task StartProcessAsync(AsrSettings asr, string model, CancellationToken ct)
    {
        KillProcess();
        var psi = new ProcessStartInfo(AppPaths.PythonExe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = AppPaths.Root,
        };
        foreach (var a in new[]
        {
            "-u", Path.Combine(AppPaths.InferenceDir, "asr_server.py"),
            "--engine", asr.Engine, "--model", model,
            "--model-dir", Path.Combine(AppPaths.ModelsDir, "whisper"),
            "--device", asr.Device, "--compute-type", asr.ComputeType,
            "--port", asr.Port.ToString(),
        }) psi.ArgumentList.Add(a);
        psi.Environment["PYTHONUTF8"] = "1";
        psi.Environment["HF_HUB_OFFLINE"] = "1";
        psi.Environment["DICTATION_ROOT"] = AppPaths.Root;

        var started = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        p.OutputDataReceived += (_, e) =>
        {
            if (e.Data == null) return;
            Log.Info("asr: " + e.Data);
            if (e.Data.StartsWith("READY")) started.TrySetResult(e.Data);
            else if (e.Data.StartsWith("ERROR")) started.TrySetException(new UserFacingException(
                "The speech model could not be loaded. Is it installed? Run scripts\\setup.ps1. (" + e.Data[5..].Trim() + ")"));
        };
        p.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) Log.Info("asr: " + e.Data); };
        p.Exited += (_, _) =>
        {
            started.TrySetException(new UserFacingException("The speech engine stopped unexpectedly."));
            if (_proc == p) { _ready = false; SetStatus("Speech engine stopped", false); }
        };
        p.Start();
        ChildProcessJob.Add(p);
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        _proc = p;

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromMinutes(3));
        using (timeout.Token.Register(() => started.TrySetCanceled()))
            await started.Task;
    }

    async Task ConnectAsync(int port, CancellationToken ct)
    {
        _lifetime.Cancel();
        _lifetime = new CancellationTokenSource();
        _outbox = NewOutbox();
        _ws?.Dispose();
        _ws = new ClientWebSocket();
        await _ws.ConnectAsync(new Uri($"ws://127.0.0.1:{port}/"), ct);
        var ws = _ws;
        var life = _lifetime.Token;
        var outbox = _outbox;
        _ = Task.Run(() => ReceiveLoop(ws, life));
        _ = Task.Run(() => SendLoop(ws, outbox, life));

        // Wait for the server's "ready" greeting (it is sent immediately on connect).
        for (var i = 0; i < 50 && !_ready; i++) await Task.Delay(20, ct);
        _ready = true;
    }

    async Task SendLoop(ClientWebSocket ws, Channel<(bool Binary, byte[] Data)> outbox, CancellationToken ct)
    {
        try
        {
            await foreach (var (binary, data) in outbox.Reader.ReadAllAsync(ct))
                await ws.SendAsync(data, binary ? WebSocketMessageType.Binary : WebSocketMessageType.Text, true, ct);
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { Log.Warn("asr send loop ended: " + e.Message); }
    }

    async Task ReceiveLoop(ClientWebSocket ws, CancellationToken ct)
    {
        var buf = new byte[64 * 1024];
        try
        {
            while (!ct.IsCancellationRequested && ws.State == WebSocketState.Open)
            {
                using var ms = new MemoryStream();
                WebSocketReceiveResult r;
                do
                {
                    r = await ws.ReceiveAsync(buf, ct);
                    if (r.MessageType == WebSocketMessageType.Close) throw new WebSocketException("closed");
                    ms.Write(buf, 0, r.Count);
                } while (!r.EndOfMessage);
                Handle(Encoding.UTF8.GetString(ms.ToArray()));
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            Log.Warn("asr receive loop ended: " + e.Message);
            if (!ct.IsCancellationRequested)
            {
                _ready = false;
                SetStatus("Speech engine disconnected", false);
                _final?.TrySetException(new UserFacingException("The speech engine disconnected."));
            }
        }
    }

    void Handle(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var type = root.GetProperty("type").GetString();
        switch (type)
        {
            case "ready":
                var dev = root.GetProperty("device").GetString();
                var model = root.GetProperty("model").GetString();
                SetStatus($"Ready · {model} on {(dev == "cuda" ? "GPU" : "CPU")}", true);
                _ready = true;
                if (dev == "cpu" && _settings.Current.Asr.Device != "cpu")
                    Log.Warn("Speech engine fell back to CPU (CUDA unavailable).");
                break;
            case "partial":
                PartialTranscript?.Invoke(root.GetProperty("text").GetString() ?? "");
                break;
            case "commit":
                Committed?.Invoke(root.GetProperty("text").GetString() ?? "");
                break;
            case "final":
                var text = root.GetProperty("text").GetString() ?? "";
                FinalTail = root.TryGetProperty("tail", out var tail) ? tail.GetString() ?? "" : "";
                Log.Info($"asr final: {text.Length} chars, {root.GetProperty("seconds").GetDouble():0.0}s audio, {root.GetProperty("decode_ms").GetInt32()} ms decode");
                FinalTranscript?.Invoke(text);
                _final?.TrySetResult(text);
                break;
            case "error":
                var msg = root.GetProperty("message").GetString();
                Log.Error("asr error: " + msg);
                // A failed live piece only costs that piece; the final transcript still covers all the audio.
                if (root.TryGetProperty("code", out var code) && code.GetString() == "live_failed") break;
                _final?.TrySetException(new UserFacingException("Speech recognition failed: " + msg));
                break;
        }
    }

    public void Start(bool live = false)
    {
        if (!IsReady) throw new UserFacingException(
            _ready ? "The speech engine is not connected." : "The speech model is still loading. Try again in a moment.");
        var asr = _settings.Current.Asr;
        var msg = JsonSerializer.Serialize(new { type = "start", language = asr.Language, prompt = asr.VocabularyHint, live });
        _final = null;
        _outbox.Writer.TryWrite((false, Encoding.UTF8.GetBytes(msg)));
    }

    public void AcceptAudio(byte[] pcm) => _outbox.Writer.TryWrite((true, pcm));

    public async Task<string> StopAsync(CancellationToken ct = default)
    {
        var tcs = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        _final = tcs;
        _outbox.Writer.TryWrite((false, Encoding.UTF8.GetBytes("{\"type\":\"stop\"}")));
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromMinutes(5));
        using (timeout.Token.Register(() => tcs.TrySetException(new UserFacingException("Speech recognition timed out."))))
            return await tcs.Task;
    }

    public void Cancel()
    {
        _final = null;
        _outbox.Writer.TryWrite((false, Encoding.UTF8.GetBytes("{\"type\":\"cancel\"}")));
    }

    public async Task UnloadAsync()
    {
        await _initLock.WaitAsync();
        try
        {
            if (!IsReady) return;
            _ready = false;
            _lifetime.Cancel();
            KillProcess();
            Log.Info("Speech model unloaded after being idle");
            SetStatus("Unloaded · loads again when you dictate", false);
        }
        finally { _initLock.Release(); }
    }

    public async Task RestartAsync(string? model = null)
    {
        _ready = false;
        _lifetime.Cancel();
        KillProcess();
        await InitializeAsync(model, CancellationToken.None);
    }

    void KillProcess()
    {
        var p = _proc;
        _proc = null;
        try { if (p is { HasExited: false }) p.Kill(true); } catch { }
    }

    public ValueTask DisposeAsync()
    {
        _lifetime.Cancel();
        _ws?.Dispose();
        KillProcess();
        return ValueTask.CompletedTask;
    }
}

/// <summary>A speech-to-text (Whisper) model Oberton offers.</summary>
public sealed record SpeechModelOption(string Id, string Name, string Description, string Size);

public static class SpeechModels
{
    public static readonly IReadOnlyList<SpeechModelOption> All = new SpeechModelOption[]
    {
        new("large-v3-turbo", "Whisper large-v3 turbo", "The best balance: nearly the accuracy of large-v3, several times faster. Needs an NVIDIA GPU to keep up.", "1.6 GB"),
        new("large-v3", "Whisper large-v3", "The most accurate, and the slowest. GPU only.", "3 GB"),
        new("distil-large-v3", "Distil-Whisper large-v3", "English only. Fast and accurate on a GPU.", "1.5 GB"),
        new("medium.en", "Whisper medium (English)", "Good accuracy; slow on a CPU.", "1.5 GB"),
        new("small.en", "Whisper small (English)", "The pick for PCs without an NVIDIA GPU.", "470 MB"),
        new("base.en", "Whisper base (English)", "Tiny and quick; makes more mistakes.", "145 MB"),
    };

    /// <summary>The speech model a profile dictates with: its own, or the one in Settings.</summary>
    public static string For(Profile? profile, AsrSettings asr) =>
        string.IsNullOrWhiteSpace(profile?.SpeechModel) ? asr.Model : profile!.SpeechModel!.Trim();

    public static string NameOf(string id) => All.FirstOrDefault(m => string.Equals(m.Id, id, StringComparison.OrdinalIgnoreCase))?.Name ?? id;
}
