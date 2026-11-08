using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;
using Dictation.Core.Speech;
using Dictation.Core.Text;

namespace Dictation.Core.Setup;

public sealed record SetupProgress(int Step, int TotalSteps, string Title, double? Fraction, string Detail);

/// <summary>
/// First-run installer for everything that is too big to ship in the setup .exe: a private Python with the
/// speech engine, the Ollama runtime, and the models. Every step is skipped if already done, so a failed or
/// cancelled setup simply resumes when it is run again. This is the only code that downloads anything.
/// </summary>
public sealed class RuntimeInstaller
{
    // Pinned, tested versions. Bump deliberately, and the SHA-256 with each: a download is unpacked only if it matches.
    // Each hash is the one its project publishes (uv's .sha256, python-build-standalone's SHA256SUMS, Ollama's
    // sha256sum.txt), which is also GitHub's digest of the asset.
    const string UvUrl = "https://github.com/astral-sh/uv/releases/download/0.12.22/uv-x86_64-pc-windows-msvc.zip";
    internal const string UvSha256 = "ea1397797a0ca15f63516dd0f49c2dde9776db9be5861cab152ebe8ad199894d";
    // Standalone CPython (the build uv itself uses): a plain folder, no virtualenv and no links, so it is relocatable.
    const string PythonUrl = "https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.12.15%2B20261003-x86_64-pc-windows-msvc-install_only.tar.gz";
    internal const string PythonSha256 = "4b6f0beebbb695a0f3ea237b8c3eaa5bd424f47a7bc25b2fbe3a43390c770f08";
    const string OllamaUrl = "https://github.com/ollama/ollama/releases/download/v0.35.1/ollama-windows-amd64.zip";
    internal const string OllamaSha256 = "dc50b9ca7f9023c86525012632cd1615b093d0407987444a7f62ecab617e8e93";
    const int Steps = 6;
    // Read aloud: Kokoro v1.0 (Apache 2.0), full-precision model for the best voice quality.
    const string KokoroModelUrl = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx";
    const string KokoroVoicesUrl = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin";

    readonly SettingsService _settings;
    readonly OllamaHost _ollama;
    readonly HttpClient _http = new() { Timeout = Timeout.InfiniteTimeSpan };

    public RuntimeInstaller(SettingsService settings, OllamaHost ollama)
    {
        _settings = settings;
        _ollama = ollama;
        _http.DefaultRequestHeaders.UserAgent.ParseAdd($"LocalDictation/{AppInfo.VersionText}");
    }

    static string Marker => Path.Combine(AppPaths.DataDir, "runtime.json");
    static string UvExe => Path.Combine(AppPaths.RuntimeDir, "uv", "uv.exe");
    static string WhisperDir => Path.Combine(AppPaths.ModelsDir, "whisper");

    public static bool IsInstalled =>
        File.Exists(Marker) && File.Exists(AppPaths.PythonExe) && File.Exists(AppPaths.OllamaExe);

    static readonly Lazy<long?> GpuMemory = new(ReadGpuMemory);

    /// <summary>The NVIDIA GPU's memory in bytes (the largest, if there are several); null without one. Asked once.</summary>
    public static long? GpuMemoryBytes() => GpuMemory.Value;

    static long? ReadGpuMemory()
    {
        if (Environment.GetEnvironmentVariable("DICTATION_FORCE_CPU") == "1") return null;
        try
        {
            var exe = new[]
            {
                Path.Combine(Environment.SystemDirectory, "nvidia-smi.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "NVIDIA Corporation", "NVSMI", "nvidia-smi.exe"),
            }.FirstOrDefault(File.Exists);
            if (exe == null) return null;
            var psi = new ProcessStartInfo(exe, "--query-gpu=memory.total --format=csv,noheader,nounits")
                { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            using var p = Process.Start(psi)!;
            var output = p.StandardOutput.ReadToEnd();
            p.WaitForExit(5000);
            if (p.ExitCode != 0) return null;
            var mib = output.Split('\n').Select(l => long.TryParse(l.Trim(), out var v) ? v : 0).DefaultIfEmpty(0).Max();
            return mib > 0 ? mib * 1024 * 1024 : null;
        }
        catch (Exception e)
        {
            Log.Warn("Couldn't read the GPU's memory: " + e.Message);
            return null;
        }
    }

    public static bool HasNvidiaGpu()
    {
        if (Environment.GetEnvironmentVariable("DICTATION_FORCE_CPU") == "1") return false; // testing the CPU-only path
        try
        {
            // The driver's own copy, by full path (never whatever "nvidia-smi" is first on PATH).
            var exe = new[]
            {
                Path.Combine(Environment.SystemDirectory, "nvidia-smi.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "NVIDIA Corporation", "NVSMI", "nvidia-smi.exe"),
            }.FirstOrDefault(File.Exists);
            if (exe == null) return false;
            var psi = new ProcessStartInfo(exe, "-L")
                { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            using var p = Process.Start(psi)!;
            var output = p.StandardOutput.ReadToEnd();
            p.WaitForExit(5000);
            return p.ExitCode == 0 && output.Contains("GPU", StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    /// <summary>Default models for the detected hardware.</summary>
    public static (string Whisper, string Llm, string Device) DefaultsFor(bool gpu) =>
        gpu ? ("large-v3-turbo", "qwen2.5:3b", "auto") : ("small.en", "qwen2.5:3b", "cpu");

    /// <summary>Sets the models for the hardware once, on the first setup of new settings; a repair, or settings from an
    /// earlier setup, keep the user's own choices. True if anything was set.</summary>
    internal static bool ChooseModels(AppSettings s, bool gpu)
    {
        if (s.ModelsChosen) return false;
        (s.Asr.Model, s.Llm.DefaultModel, s.Asr.Device) = DefaultsFor(gpu);
        s.ModelsChosen = true;
        return true;
    }

    /// <summary>Rough download size in GB, for the welcome text.</summary>
    public static double EstimatedDownloadGb(bool gpu) => gpu ? 5.5 : 3.0;

    public async Task RunAsync(IProgress<SetupProgress> progress, CancellationToken ct)
    {
        Directory.CreateDirectory(AppPaths.RuntimeDir);
        Directory.CreateDirectory(WhisperDir);
        var gpu = HasNvidiaGpu();
        var s = _settings.Current;
        if (ChooseModels(s, gpu)) _settings.Save();
        Log.Info($"Runtime setup starting (NVIDIA GPU: {gpu}, speech model {s.Asr.Model}, AI model {s.Llm.DefaultModel})");

        // 1. uv (Python installer)
        Report(progress, 1, "Downloading Python tools", 0, "");
        if (!File.Exists(UvExe))
        {
            var zip = Path.Combine(AppPaths.RuntimeDir, "uv.zip");
            await DownloadAsync(UvUrl, zip, f => Report(progress, 1, "Downloading Python tools", f, ""), ct, UvSha256);
            ZipFile.ExtractToDirectory(zip, Path.GetDirectoryName(UvExe)!, true);
            File.Delete(zip);
        }

        // 2. Python + speech engine packages
        var pyDir = Path.GetDirectoryName(AppPaths.PythonExe)!;
        if (!File.Exists(AppPaths.PythonExe))
        {
            var tgz = Path.Combine(AppPaths.RuntimeDir, "python.tar.gz");
            await DownloadAsync(PythonUrl, tgz, f => Report(progress, 2, "Downloading Python", f, ""), ct, PythonSha256);
            Report(progress, 2, "Unpacking Python", null, "");
            var tmp = Path.Combine(AppPaths.RuntimeDir, "py-tmp");
            if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
            Directory.CreateDirectory(tmp);
            await Task.Run(() =>
            {
                using var gz = new GZipStream(File.OpenRead(tgz), CompressionMode.Decompress);
                System.Formats.Tar.TarFile.ExtractToDirectory(gz, tmp, true);
            }, ct);
            if (Directory.Exists(pyDir)) Directory.Delete(pyDir, true);
            Directory.Move(Path.Combine(tmp, "python"), pyDir);
            Directory.Delete(tmp, true);
            File.Delete(tgz);
        }
        var sitePackages = Path.Combine(pyDir, "Lib", "site-packages");
        if (!Directory.Exists(Path.Combine(sitePackages, "faster_whisper")) || (gpu && !Directory.Exists(Path.Combine(sitePackages, "nvidia"))))
        {
            var args = new List<string>
            {
                "pip", "install", "--python", AppPaths.PythonExe, "--system", "--break-system-packages",
                "-r", Path.Combine(AppPaths.InferenceDir, "requirements.txt"),
            };
            if (gpu) { args.Add("-r"); args.Add(Path.Combine(AppPaths.InferenceDir, "requirements-cuda.txt")); }
            await RunToolAsync(UvExe, args, UvEnvironment(), pyDir, gpu ? 2250 : 300,
                f => Report(progress, 2, "Installing the speech engine", f, gpu ? "Including NVIDIA GPU support" : "CPU version (no NVIDIA GPU found)"),
                "Installing the speech engine", ct);
        }
        // 3. Ollama
        if (!File.Exists(AppPaths.OllamaExe))
        {
            var zip = Path.Combine(AppPaths.RuntimeDir, "ollama.zip");
            await DownloadAsync(OllamaUrl, zip, f => Report(progress, 3, "Downloading the AI runtime (Ollama)", f, ""), ct, OllamaSha256);
            Report(progress, 3, "Unpacking the AI runtime", null, "");
            var dest = Path.Combine(AppPaths.RuntimeDir, "ollama");
            await Task.Run(() => ZipFile.ExtractToDirectory(zip, dest, true), ct);
            File.Delete(zip);
        }

        // 4. Speech model
        var whisper = s.Asr.Model;
        if (!WhisperModelPresent(whisper))
            await DownloadWhisperAsync(whisper, (f, detail) => Report(progress, 4, $"Downloading the speech model ({whisper})", f, detail), ct);

        // 5. Language model
        var llm = s.Llm.DefaultModel;
        Report(progress, 5, $"Downloading the AI model ({llm})", null, "Starting the AI runtime…");
        await _ollama.EnsureRunningAsync(ct);
        await PullAsync(llm, f => Report(progress, 5, $"Downloading the AI model ({llm})", f, ""), ct);

        // 6. Finish
        Report(progress, 6, "Finishing up", null, "");
        // Free disk space: the download cache, and the virtualenv layout used by versions before 1.0.
        foreach (var leftover in new[] { "uv-cache", "venv", "python" })
            try { var d = Path.Combine(AppPaths.RuntimeDir, leftover); if (Directory.Exists(d)) Directory.Delete(d, true); }
            catch (Exception e) { Log.Warn($"Could not remove {leftover}: {e.Message}"); }
        JsonStore.Save(Marker, new { installedAt = DateTime.Now, appVersion = AppInfo.VersionText, nvidiaGpu = gpu, speechModel = whisper, aiModel = llm });
        Log.Info("Runtime setup complete");
        Report(progress, 6, "Done", 1, "");
    }

    public static string KokoroDir => Path.Combine(AppPaths.ModelsDir, "kokoro");
    public static string KokoroModel => Path.Combine(KokoroDir, "kokoro-v1.0.onnx");
    public static string KokoroVoices => Path.Combine(KokoroDir, "voices-v1.0.bin");
    static string SitePackages => Path.Combine(Path.GetDirectoryName(AppPaths.PythonExe)!, "Lib", "site-packages");

    /// <summary>The local voice server's Python packages (kokoro-onnx, which brings ONNX Runtime and espeak-ng) are
    /// installed. Kokoro and Piper both need them.</summary>
    public static bool VoiceEngineInstalled => Directory.Exists(Path.Combine(SitePackages, "kokoro_onnx"));

    /// <summary>Kokoro is ready: the voice engine and both of its model files are present.</summary>
    public static bool ReadAloudInstalled => File.Exists(KokoroModel) && File.Exists(KokoroVoices) && VoiceEngineInstalled;

    /// <summary>Approximate one-time download for Kokoro, in MB.</summary>
    public const int ReadAloudDownloadMb = 370;

    /// <summary>Piper voices: models\piper\&lt;name&gt;.onnx with &lt;name&gt;.onnx.json.</summary>
    public static string PiperDir => Path.Combine(AppPaths.ModelsDir, "piper");
    static string PiperFile(string name) => Path.Combine(PiperDir, name + ".onnx");

    public static bool PiperVoiceInstalled(string name) =>
        VoiceEngineInstalled && File.Exists(PiperFile(name)) && File.Exists(PiperFile(name) + ".json");

    /// <summary>Install the voice server's Python packages if they aren't there yet (shared by Kokoro and Piper).</summary>
    async Task EnsureVoiceEngineAsync(Action<double?> progress, CancellationToken ct)
    {
        if (!File.Exists(AppPaths.PythonExe))
            throw new UserFacingException("Oberton's speech engine isn't set up yet, so Read aloud can't be installed. Restart Oberton to finish setup.");
        if (!File.Exists(UvExe))
        {
            var zip = Path.Combine(AppPaths.RuntimeDir, "uv.zip");
            await DownloadAsync(UvUrl, zip, progress, ct, UvSha256);
            ZipFile.ExtractToDirectory(zip, Path.GetDirectoryName(UvExe)!, true);
            File.Delete(zip);
        }
        if (VoiceEngineInstalled) return;
        var pyDir = Path.GetDirectoryName(AppPaths.PythonExe)!;
        await RunToolAsync(UvExe, new[]
            {
                "pip", "install", "--python", AppPaths.PythonExe, "--system", "--break-system-packages",
                "-r", Path.Combine(AppPaths.InferenceDir, "requirements-tts.txt"),
            },
            UvEnvironment(), pyDir, 60, progress, "Installing the voice engine", ct);
        try { var cache = Path.Combine(AppPaths.RuntimeDir, "uv-cache"); if (Directory.Exists(cache)) Directory.Delete(cache, true); }
        catch (Exception e) { Log.Warn("Could not remove uv-cache: " + e.Message); }
    }

    /// <summary>
    /// Kokoro is installed on first use rather than during setup: the voice package into the private Python,
    /// and the Kokoro model and voices into models\kokoro. Resumable like the main setup.
    /// </summary>
    public async Task InstallReadAloudAsync(IProgress<SetupProgress> progress, CancellationToken ct)
    {
        const int total = 3;
        void Step(int step, string title, double? f, string detail = "") => progress.Report(new SetupProgress(step, total, title, f, detail));
        await EnsureVoiceEngineAsync(f => Step(1, "Installing the voice engine", f), ct);
        Directory.CreateDirectory(KokoroDir);
        if (!File.Exists(KokoroModel))
            await DownloadAsync(KokoroModelUrl, KokoroModel, f => Step(2, "Downloading the voice model", f, "About 325 MB"), ct);
        if (!File.Exists(KokoroVoices))
            await DownloadAsync(KokoroVoicesUrl, KokoroVoices, f => Step(3, "Downloading the voices", f, "About 28 MB"), ct);
        Log.Info("Read aloud installed");
        Step(3, "Done", 1);
    }

    /// <summary>Download one Piper voice (and the voice engine, the first time) into models\piper.</summary>
    public async Task InstallPiperVoiceAsync(PiperVoice voice, IProgress<SetupProgress> progress, CancellationToken ct)
    {
        const int total = 2;
        void Step(int step, string title, double? f, string detail = "") => progress.Report(new SetupProgress(step, total, title, f, detail));
        await EnsureVoiceEngineAsync(f => Step(1, "Installing the voice engine", f), ct);
        Directory.CreateDirectory(PiperDir);
        var file = PiperFile(voice.Name);
        if (!File.Exists(file + ".json")) await DownloadAsync(voice.Url + ".json", file + ".json", _ => { }, ct);
        if (!File.Exists(file))
            await DownloadAsync(voice.Url, file, f => Step(2, $"Downloading the Piper voice {voice.Label}", f, $"About {voice.Mb} MB"), ct);
        Log.Info("Piper voice installed: " + voice.Name);
        Step(2, "Done", 1);
    }

    /// <summary>Approximate download size of a speech model, in MB.</summary>
    public static int WhisperModelMb(string model) => model switch
    {
        "large-v3-turbo" => 1550, "large-v3" => 3000, "distil-large-v3" => 1500, "medium.en" or "medium" => 1500,
        "small.en" or "small" => 470, "base.en" or "base" => 145, "tiny.en" or "tiny" => 75, _ => 1000,
    };

    /// <summary>Download one speech (Whisper) model into models\whisper. Used by setup and the Models page.</summary>
    public async Task DownloadWhisperAsync(string model, Action<double?, string> progress, CancellationToken ct)
    {
        if (!File.Exists(AppPaths.PythonExe))
            throw new UserFacingException("Oberton's speech engine isn't set up yet. Restart Oberton to finish setup.");
        Directory.CreateDirectory(WhisperDir);
        var mb = WhisperModelMb(model);
        await RunToolAsync(AppPaths.PythonExe,
            new[] { "-u", Path.Combine(AppPaths.InferenceDir, "asr_server.py"), "--download", "--model", model, "--model-dir", WhisperDir },
            new Dictionary<string, string> { ["PYTHONUTF8"] = "1", ["HF_HUB_DISABLE_TELEMETRY"] = "1", ["DICTATION_ROOT"] = AppPaths.Root },
            WhisperDir, mb, f => progress(f, $"About {mb:N0} MB"), "Downloading the speech model", ct);
    }

    /// <summary>Download one local AI model through Ollama. Used by setup and the Models page.</summary>
    public async Task DownloadAiModelAsync(string model, Action<double?> progress, CancellationToken ct)
    {
        await _ollama.EnsureRunningAsync(ct);
        await PullAsync(model, progress, ct);
    }

    static void Report(IProgress<SetupProgress> p, int step, string title, double? fraction, string detail) =>
        p.Report(new SetupProgress(step, Steps, title, fraction, detail));

    static Dictionary<string, string> UvEnvironment() => new()
    {
        ["UV_CACHE_DIR"] = Path.Combine(AppPaths.RuntimeDir, "uv-cache"),
        ["UV_LINK_MODE"] = "copy",
        ["UV_PYTHON_DOWNLOADS"] = "never",
        ["UV_NO_PROGRESS"] = "1",
    };

    public static bool WhisperModelPresent(string model)
    {
        if (!Directory.Exists(WhisperDir)) return false;
        // Hugging Face cache folders end in the repository name: faster-whisper-<model>, except the distilled models,
        // which live in Systran/faster-distil-whisper-<size>.
        var names = new List<string> { "faster-whisper-" + model };
        if (model.StartsWith("distil-", StringComparison.OrdinalIgnoreCase)) names.Add("faster-distil-whisper-" + model["distil-".Length..]);
        return Directory.GetDirectories(WhisperDir, "models--*").Any(d =>
            names.Any(n => d.EndsWith(n, StringComparison.OrdinalIgnoreCase)) &&
            Directory.GetFiles(d, "model.bin", SearchOption.AllDirectories).Length > 0);
    }

    /// <param name="sha256">For a runtime that is unpacked and run: the pinned hash the download must have; it is checked
    /// before the file takes its name (so a bad one is never unpacked) and deleted when it doesn't match.</param>
    async Task DownloadAsync(string url, string target, Action<double?> progress, CancellationToken ct, string? sha256 = null)
    {
        try
        {
            using var resp = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
            resp.EnsureSuccessStatusCode();
            var total = resp.Content.Headers.ContentLength;
            var part = target + ".part";
            await using (var src = await resp.Content.ReadAsStreamAsync(ct))
            await using (var dst = File.Create(part))
            {
                var buf = new byte[1 << 16];
                long done = 0, lastReport = 0;
                int n;
                while ((n = await src.ReadAsync(buf, ct)) > 0)
                {
                    await dst.WriteAsync(buf.AsMemory(0, n), ct);
                    done += n;
                    if (done - lastReport > 1 << 20) { lastReport = done; progress(total > 0 ? (double)done / total.Value : null); }
                }
            }
            if (sha256 != null)
            {
                progress(null); // checking a large download takes a few seconds
                await Task.Run(() => Verify(part, sha256, Path.GetFileName(new Uri(url).LocalPath)), ct);
            }
            File.Move(part, target, true);
        }
        catch (HttpRequestException e)
        {
            throw new UserFacingException("A download failed. Check your internet connection and click Retry.", e);
        }
    }

    /// <summary>A download whose SHA-256 isn't <paramref name="sha256"/> is deleted and not used.</summary>
    internal static void Verify(string path, string sha256, string what)
    {
        var actual = Checksum.Sha256(path);
        if (actual == Checksum.Normalize(sha256)) return;
        try { File.Delete(path); } catch (Exception e) { Log.Warn($"Could not delete {path}: {e.Message}"); }
        Log.Warn($"Download check failed: {what} has SHA-256 {actual}, expected {sha256}; deleted");
        throw new UserFacingException($"The download of {what} isn't the file Oberton expects (its checksum doesn't match), so " +
                                      "it was deleted and not installed. Click Retry; if it keeps happening, something on this network (a proxy or " +
                                      "security software) may be changing downloads.");
    }

    /// <summary>Run a command-line tool; progress is estimated from how much its target folder has grown.</summary>
    static async Task RunToolAsync(string exe, IEnumerable<string> args, IDictionary<string, string> env, string watchDir,
        double expectedMb, Action<double?> progress, string what, CancellationToken ct)
    {
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = AppPaths.Root,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        foreach (var (k, v) in env) psi.Environment[k] = v;
        var tail = new Queue<string>();
        void Collect(string? line)
        {
            if (string.IsNullOrWhiteSpace(line)) return;
            Log.Info("setup: " + line);
            lock (tail) { tail.Enqueue(line); while (tail.Count > 6) tail.Dequeue(); }
        }

        using var p = new Process { StartInfo = psi };
        p.OutputDataReceived += (_, e) => Collect(e.Data);
        p.ErrorDataReceived += (_, e) => Collect(e.Data);
        p.Start();
        ChildProcessJob.Add(p);
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        var startMb = DirSizeMb(watchDir);
        using (ct.Register(() => { try { p.Kill(true); } catch { } }))
        {
            while (!p.HasExited)
            {
                await Task.Delay(1000, CancellationToken.None);
                var grown = DirSizeMb(watchDir) - startMb;
                progress(Math.Clamp(grown / expectedMb, 0, 0.99));
            }
        }
        ct.ThrowIfCancellationRequested();
        if (p.ExitCode != 0)
        {
            string detail;
            lock (tail) detail = string.Join("\n", tail);
            throw new UserFacingException($"{what} failed. Check your internet connection and click Retry.\n\n{detail}");
        }
        progress(1);
    }

    static double DirSizeMb(string dir)
    {
        try
        {
            return Directory.Exists(dir)
                ? new DirectoryInfo(dir).EnumerateFiles("*", SearchOption.AllDirectories).Sum(f => f.Length) / 1048576.0
                : 0;
        }
        catch { return 0; }
    }

    /// <summary>Ollama /api/pull streams JSON lines with per-layer byte counts, which gives real progress.</summary>
    async Task PullAsync(string model, Action<double?> progress, CancellationToken ct)
    {
        var url = _settings.Current.Llm.Endpoint.TrimEnd('/') + "/api/pull";
        using var req = new HttpRequestMessage(HttpMethod.Post, url) { Content = JsonContent.Create(new { model, stream = true }) };
        HttpResponseMessage resp;
        try { resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct); }
        catch (HttpRequestException e) { throw new UserFacingException("Couldn't reach the AI runtime to download the model.", e); }
        using (resp)
        {
            resp.EnsureSuccessStatusCode();
            using var reader = new StreamReader(await resp.Content.ReadAsStreamAsync(ct));
            var layers = new Dictionary<string, (long Done, long Total)>();
            string? line;
            while ((line = await reader.ReadLineAsync(ct)) != null)
            {
                if (line.Length == 0) continue;
                var o = JsonNode.Parse(line)!.AsObject();
                if (o["error"] is { } err)
                    throw new UserFacingException($"Downloading the AI model failed: {err.GetValue<string>()}. Click Retry.");
                if (o["digest"]?.GetValue<string>() is { } digest && o["total"] is { } total)
                {
                    layers[digest] = (o["completed"]?.GetValue<long>() ?? 0, total.GetValue<long>());
                    var t = layers.Values.Sum(l => l.Total);
                    progress(t > 0 ? (double)layers.Values.Sum(l => l.Done) / t : null);
                }
                if (o["status"]?.GetValue<string>() == "success") { progress(1); return; }
            }
        }
        throw new UserFacingException("Downloading the AI model stopped unexpectedly. Click Retry.");
    }
}
