using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;
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
    // Pinned, tested versions. Bump deliberately.
    const string UvUrl = "https://github.com/astral-sh/uv/releases/download/0.12.22/uv-x86_64-pc-windows-msvc.zip";
    // Standalone CPython (the build uv itself uses): a plain folder, no virtualenv and no links, so it is relocatable.
    const string PythonUrl = "https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.12.15%2B20261003-x86_64-pc-windows-msvc-install_only.tar.gz";
    const string OllamaUrl = "https://github.com/ollama/ollama/releases/download/v0.35.1/ollama-windows-amd64.zip";
    const int Steps = 6;

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

    public static bool HasNvidiaGpu()
    {
        if (Environment.GetEnvironmentVariable("DICTATION_FORCE_CPU") == "1") return false; // testing the CPU-only path
        try
        {
            var psi = new ProcessStartInfo("nvidia-smi", "-L")
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

    /// <summary>Rough download size in GB, for the welcome text.</summary>
    public static double EstimatedDownloadGb(bool gpu) => gpu ? 5.5 : 3.0;

    public async Task RunAsync(IProgress<SetupProgress> progress, CancellationToken ct)
    {
        Directory.CreateDirectory(AppPaths.RuntimeDir);
        Directory.CreateDirectory(WhisperDir);
        var gpu = HasNvidiaGpu();
        var firstRun = !File.Exists(Marker);
        var (whisperDefault, llmDefault, device) = DefaultsFor(gpu);
        var s = _settings.Current;
        // Only choose models on the very first setup; a repair keeps the user's own choices.
        if (firstRun && !File.Exists(Path.Combine(AppPaths.DataDir, "settings.json")))
        {
            s.Asr.Model = whisperDefault;
            s.Asr.Device = device;
            s.Llm.DefaultModel = llmDefault;
            _settings.Save();
        }
        Log.Info($"Runtime setup starting (NVIDIA GPU: {gpu}, speech model {s.Asr.Model}, AI model {s.Llm.DefaultModel})");

        // 1. uv (Python installer)
        Report(progress, 1, "Downloading Python tools", 0, "");
        if (!File.Exists(UvExe))
        {
            var zip = Path.Combine(AppPaths.RuntimeDir, "uv.zip");
            await DownloadAsync(UvUrl, zip, f => Report(progress, 1, "Downloading Python tools", f, ""), ct);
            ZipFile.ExtractToDirectory(zip, Path.GetDirectoryName(UvExe)!, true);
            File.Delete(zip);
        }

        // 2. Python + speech engine packages
        var pyDir = Path.GetDirectoryName(AppPaths.PythonExe)!;
        if (!File.Exists(AppPaths.PythonExe))
        {
            var tgz = Path.Combine(AppPaths.RuntimeDir, "python.tar.gz");
            await DownloadAsync(PythonUrl, tgz, f => Report(progress, 2, "Downloading Python", f, ""), ct);
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
            await DownloadAsync(OllamaUrl, zip, f => Report(progress, 3, "Downloading the AI runtime (Ollama)", f, ""), ct);
            Report(progress, 3, "Unpacking the AI runtime", null, "");
            var dest = Path.Combine(AppPaths.RuntimeDir, "ollama");
            await Task.Run(() => ZipFile.ExtractToDirectory(zip, dest, true), ct);
            File.Delete(zip);
        }

        // 4. Speech model
        var whisper = s.Asr.Model;
        if (!WhisperModelPresent(whisper))
        {
            var mb = whisper switch { "large-v3-turbo" => 1550, "large-v3" => 3000, "distil-large-v3" => 1500, "medium.en" or "medium" => 1500, "small.en" or "small" => 470, "base.en" or "base" => 145, _ => 1000 };
            await RunToolAsync(AppPaths.PythonExe,
                new[] { "-u", Path.Combine(AppPaths.InferenceDir, "asr_server.py"), "--download", "--model", whisper, "--model-dir", WhisperDir },
                new Dictionary<string, string> { ["PYTHONUTF8"] = "1", ["HF_HUB_DISABLE_TELEMETRY"] = "1", ["DICTATION_ROOT"] = AppPaths.Root },
                WhisperDir, mb, f => Report(progress, 4, $"Downloading the speech model ({whisper})", f, $"About {mb:N0} MB"),
                "Downloading the speech model", ct);
        }

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

    static void Report(IProgress<SetupProgress> p, int step, string title, double? fraction, string detail) =>
        p.Report(new SetupProgress(step, Steps, title, fraction, detail));

    static Dictionary<string, string> UvEnvironment() => new()
    {
        ["UV_CACHE_DIR"] = Path.Combine(AppPaths.RuntimeDir, "uv-cache"),
        ["UV_LINK_MODE"] = "copy",
        ["UV_PYTHON_DOWNLOADS"] = "never",
        ["UV_NO_PROGRESS"] = "1",
    };

    public static bool WhisperModelPresent(string model) =>
        Directory.Exists(WhisperDir) &&
        Directory.GetDirectories(WhisperDir, "models--*").Any(d =>
            d.EndsWith("faster-whisper-" + model, StringComparison.OrdinalIgnoreCase) &&
            Directory.GetFiles(d, "model.bin", SearchOption.AllDirectories).Length > 0);

    async Task DownloadAsync(string url, string target, Action<double?> progress, CancellationToken ct)
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
            File.Move(part, target, true);
        }
        catch (HttpRequestException e)
        {
            throw new UserFacingException("A download failed. Check your internet connection and click Retry.", e);
        }
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
