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
    /// <summary>From pressing stop until the text was in place (0 for entries from before this was recorded).</summary>
    public double FinishSeconds { get; set; }
    [JsonIgnore] public int Words => (Final.Length > 0 ? Final : Transcript).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;

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

    readonly System.Windows.Threading.DispatcherTimer _hourly = new() { Interval = TimeSpan.FromHours(1) };

    public HistoryStore(SettingsService settings)
    {
        _settings = settings;
        Load();
        // Kept by age: what has grown too old goes even when nothing new comes in.
        _hourly.Tick += (_, _) => Prune();
        _hourly.Start();
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

    /// <summary>Drop the entries beyond what is kept (by number or by age), and the recordings beyond what is kept of
    /// them; also when either is lowered, and every hour (for keeping by age).</summary>
    public void Prune()
    {
        var s = _settings.Current;
        var now = DateTime.Now;
        if (s.HistoryLimit > 0)
            while (Entries.Count > s.HistoryLimit) Delete(Entries[^1]);
        if (s.HistoryDays > 0)
            foreach (var old in Entries.Where(e => e.Time < now.AddDays(-s.HistoryDays)).ToList()) Delete(old);
        if (s.AudioLimit <= 0 && s.AudioDays <= 0) return; // recordings: as long as the text
        for (var i = 0; i < Entries.Count; i++)
        {
            var e = Entries[i];
            var drop = (s.AudioLimit > 0 && i >= s.AudioLimit) || (s.AudioDays > 0 && e.Time < now.AddDays(-s.AudioDays));
            if (!drop || !e.HasAudio) continue;
            try { File.Delete(e.AudioPath); }
            catch (Exception ex) { Log.Warn("Could not delete a History recording: " + ex.Message); }
        }
    }

    /// <summary>What a keep setting says: "50 dictations", "2 weeks", or "" when everything is kept.</summary>
    public static string KeepLabel(int count, int days) =>
        count > 0 ? $"{count} dictation{(count == 1 ? "" : "s")}" : days > 0 ? DaysLabel(days) : "";

    public static string DaysLabel(int days) => days switch
    {
        1 => "24 hours", 7 => "week", 14 => "2 weeks", 30 => "month", 90 => "3 months", 180 => "6 months", 365 => "year",
        _ when days % 7 == 0 => $"{days / 7} weeks",
        _ => $"{days} days",
    };

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
