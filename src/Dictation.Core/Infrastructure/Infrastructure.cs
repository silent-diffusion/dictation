using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Dictation.Core.Infrastructure;

/// <summary>An error whose message is safe and meaningful to show to a normal user.</summary>
public sealed class UserFacingException : Exception
{
    public UserFacingException(string message, Exception? inner = null) : base(message, inner) { }
}

public abstract class Bindable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        return true;
    }

    protected void Raise([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>Where things live. In the dev/portable layout everything is under the project root.</summary>
public static class AppPaths
{
    /// <summary>Home for everything that outlives an app update: runtimes, models, settings, logs.
    /// %LOCALAPPDATA%\LocalDictation by default; override with the DICTATION_ROOT environment variable.</summary>
    public static string Root { get; }
    /// <summary>Where the program itself lives (the folder containing inference\): the install dir, or the repo in development.</summary>
    public static string CodeDir { get; }
    /// <summary>True when running from a source checkout rather than an installed copy.</summary>
    public static bool IsDevelopmentCopy { get; }
    public static string DataDir { get; }
    public static string LogDir { get; }
    public static string ModelsDir { get; }
    public static string RuntimeDir { get; }
    public static string InferenceDir { get; }
    public static string PythonExe => Path.Combine(RuntimeDir, "py", "python.exe");
    public static string OllamaExe => Path.Combine(RuntimeDir, "ollama", "ollama.exe");

    static AppPaths()
    {
        var env = Environment.GetEnvironmentVariable("DICTATION_ROOT");
        Root = !string.IsNullOrWhiteSpace(env)
            ? env
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LocalDictation");
        CodeDir = FindRoot(AppContext.BaseDirectory) ?? AppContext.BaseDirectory;
        IsDevelopmentCopy = File.Exists(Path.Combine(CodeDir, "LocalDictation.slnx"));
        InferenceDir = Path.Combine(CodeDir, "inference");
        RuntimeDir = Path.Combine(Root, "runtime");
        ModelsDir = Path.Combine(Root, "models");
        DataDir = Path.Combine(Root, "data");
        LogDir = Path.Combine(DataDir, "logs");
        Directory.CreateDirectory(LogDir);
    }

    static string? FindRoot(string start)
    {
        for (var d = new DirectoryInfo(start); d != null; d = d.Parent)
            if (File.Exists(Path.Combine(d.FullName, "inference", "asr_server.py"))) return d.FullName;
        return null;
    }
}

public static class AppInfo
{
    public const string Name = "Local Dictation";
    public const string Publisher = "silent-diffusion";
    public const string Repository = "silent-diffusion/dictation";
    public const string RepositoryUrl = "https://github.com/" + Repository;

    /// <summary>The app version (set at build time from the release tag), e.g. 1.2.0.</summary>
    public static Version Version { get; } = ReadVersion();

    static Version ReadVersion()
    {
        var info = System.Reflection.Assembly.GetEntryAssembly()?
            .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
            .OfType<System.Reflection.AssemblyInformationalVersionAttribute>().FirstOrDefault()?.InformationalVersion;
        var core = (info ?? "0.0.0").Split('+', '-')[0];
        return Version.TryParse(core, out var v) ? v : new Version(0, 0, 0);
    }

    public static string VersionText => $"{Version.Major}.{Version.Minor}.{Math.Max(0, Version.Build)}";
}

/// <summary>Tiny file logger. Never logs transcript text (privacy) - only metadata.</summary>
public static class Log
{
    static readonly object Gate = new();
    static string Path_ => Path.Combine(AppPaths.LogDir, "dictation.log");

    public static void Info(string m) => Write("INFO", m);
    public static void Warn(string m) => Write("WARN", m);
    public static void Error(string m, Exception? e = null) => Write("ERROR", e == null ? m : $"{m}: {e}");

    static void Write(string level, string msg)
    {
        try
        {
            lock (Gate)
            {
                var fi = new FileInfo(Path_);
                if (fi.Exists && fi.Length > 2_000_000)
                {
                    var old = Path_ + ".1";
                    if (File.Exists(old)) File.Delete(old);
                    File.Move(Path_, old);
                }
                File.AppendAllText(Path_, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {level,-5} {msg}{Environment.NewLine}");
            }
        }
        catch { /* logging must never crash the app */ }
        Debug.WriteLine($"[{level}] {msg}");
    }
}

public static class JsonStore
{
    public static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        AllowTrailingCommas = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        Converters = { new JsonStringEnumConverter() },
    };

    public static T? Load<T>(string path) where T : class
    {
        try
        {
            if (!File.Exists(path)) return null;
            return JsonSerializer.Deserialize<T>(File.ReadAllText(path), Options);
        }
        catch (Exception e)
        {
            Log.Error($"Could not read {path}; keeping a .bad copy", e);
            try { File.Copy(path, path + ".bad", true); } catch { }
            return null;
        }
    }

    public static void Save<T>(string path, T value)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(value, Options));
        File.Move(tmp, path, true);
    }
}

/// <summary>Kills child processes (Python sidecar, Ollama) when the app exits - even if it crashes.</summary>
public static class ChildProcessJob
{
    static readonly IntPtr Job;

    static ChildProcessJob()
    {
        try
        {
            Job = CreateJobObject(IntPtr.Zero, null);
            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = 0x2000; // KILL_ON_JOB_CLOSE
            var size = Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
            var ptr = Marshal.AllocHGlobal(size);
            Marshal.StructureToPtr(info, ptr, false);
            SetInformationJobObject(Job, 9, ptr, (uint)size);
            Marshal.FreeHGlobal(ptr);
        }
        catch (Exception e) { Log.Warn("Job object unavailable: " + e.Message); }
    }

    public static void Add(Process p)
    {
        try { if (Job != IntPtr.Zero) AssignProcessToJobObject(Job, p.Handle); }
        catch (Exception e) { Log.Warn("Could not attach child to job: " + e.Message); }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attrs, string? name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, uint len);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS { public ulong a, b, c, d, e, f; }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
}
