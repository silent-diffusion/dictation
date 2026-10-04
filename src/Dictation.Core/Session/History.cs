using System.Collections.ObjectModel;
using System.Text.Json.Serialization;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;
using NAudio.Wave;

namespace Dictation.Core.Session;

/// <summary>Everything about one finished dictation, as kept in History.</summary>
public sealed class HistoryEntry
{
    public DateTime Time { get; set; } = DateTime.Now;
    public string Profile { get; set; } = "";
    /// <summary>The app the text went into (process name), and its window title at the time.</summary>
    public string App { get; set; } = "";
    public string WindowTitle { get; set; } = "";
    /// <summary>What the speech recognizer heard (pieces joined).</summary>
    public string Transcript { get; set; } = "";
    /// <summary>The AI's own output, before it was fitted into the surrounding text; null when no AI edit was used.</summary>
    public string? AiOutput { get; set; }
    /// <summary>The text that went in (or would have, if inserting failed).</summary>
    public string Final { get; set; } = "";
    public bool WasInserted { get; set; }
    public bool SafetyNet { get; set; }
    public string? Note { get; set; }
    /// <summary>Length of the recording.</summary>
    public double Seconds { get; set; }

    /// <summary>The entry's folder under data\history (entry.json and audio.wav).</summary>
    [JsonIgnore] public string Folder { get; set; } = "";
    [JsonIgnore] public string AudioPath => Path.Combine(Folder, "audio.wav");
    [JsonIgnore] public bool HasAudio => Folder.Length > 0 && File.Exists(AudioPath);
    [JsonIgnore] public string AppName => string.IsNullOrEmpty(App) ? "Unknown app" : App;
    [JsonIgnore] public string Preview
    {
        get
        {
            var t = (Final.Length > 0 ? Final : Transcript).ReplaceLineEndings(" ");
            return t.Length <= 120 ? t : t[..117].TrimEnd() + "…";
        }
    }
    [JsonIgnore] public string When => Time.Date == DateTime.Today ? Time.ToString("t")
        : Time.Date == DateTime.Today.AddDays(-1) ? "Yesterday " + Time.ToString("t")
        : $"{Time:d MMM}, {Time:t}";
    [JsonIgnore] public string Duration => Seconds < 60 ? $"{Seconds:0} s" : $"{(int)(Seconds / 60)}:{(int)Seconds % 60:00} min";
}

/// <summary>
/// Recent dictations, kept in data\history (one folder each: entry.json and the recording as audio.wav). The data folder
/// lives outside the program folder, so app updates never touch it. Only the newest <see cref="AppSettings.HistoryLimit"/>
/// are kept. Use from the UI thread.
/// </summary>
public sealed class HistoryStore
{
    readonly SettingsService _settings;
    public ObservableCollection<HistoryEntry> Entries { get; } = new();
    public static string Dir => Path.Combine(AppPaths.DataDir, "history");

    public HistoryStore(SettingsService settings)
    {
        _settings = settings;
        Load();
    }

    void Load()
    {
        if (!Directory.Exists(Dir)) return;
        var loaded = new List<HistoryEntry>();
        foreach (var folder in Directory.GetDirectories(Dir))
        {
            var e = JsonStore.Load<HistoryEntry>(Path.Combine(folder, "entry.json"));
            if (e == null) continue;
            e.Folder = folder;
            loaded.Add(e);
        }
        foreach (var e in loaded.OrderByDescending(e => e.Time)) Entries.Add(e);
        Prune();
    }

    /// <summary>Keep a finished dictation, with its recording (16 kHz mono 16-bit PCM) if audio is kept.</summary>
    public void Add(HistoryEntry entry, byte[]? pcm)
    {
        if (!_settings.Current.KeepHistory) return;
        try
        {
            var folder = Path.Combine(Dir, entry.Time.ToString("yyyyMMdd-HHmmss-fff"));
            Directory.CreateDirectory(folder);
            entry.Folder = folder;
            JsonStore.Save(Path.Combine(folder, "entry.json"), entry);
            if (pcm is { Length: > 0 } && _settings.Current.SaveHistoryAudio) WavFile.Write(entry.AudioPath, pcm);
        }
        catch (Exception e) { Log.Error("Saving a dictation to History failed", e); }
        Entries.Insert(0, entry);
        Prune();
    }

    /// <summary>Drop the oldest entries beyond the limit (also when the limit is lowered).</summary>
    public void Prune()
    {
        var limit = Math.Max(1, _settings.Current.HistoryLimit);
        while (Entries.Count > limit) Delete(Entries[^1]);
    }

    public void Delete(HistoryEntry entry)
    {
        Entries.Remove(entry);
        try { if (entry.Folder.Length > 0 && Directory.Exists(entry.Folder)) Directory.Delete(entry.Folder, true); }
        catch (Exception e) { Log.Warn("Could not delete a History entry: " + e.Message); }
    }

    public void Clear()
    {
        foreach (var e in Entries.ToList()) Delete(e);
    }
}

public static class WavFile
{
    /// <summary>Write 16-bit mono PCM as a .wav file.</summary>
    public static void Write(string path, byte[] pcm, int sampleRate = 16000)
    {
        using var w = new WaveFileWriter(path, new WaveFormat(sampleRate, 16, 1));
        w.Write(pcm, 0, pcm.Length);
    }
}
