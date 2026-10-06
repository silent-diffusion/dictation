using System.Text.Json.Serialization;
using Dictation.Core.Infrastructure;

namespace Dictation.Core.Session;

/// <summary>
/// One day of use, as counts only: never any text, audio or window titles. The dashboard is drawn from these, so it
/// keeps its numbers when History is off, cleared, or trimmed to its limit.
/// </summary>
public sealed class UsageDay
{
    public DateTime Day { get; set; }
    public int Dictations { get; set; }
    public int Words { get; set; }
    /// <summary>Seconds of speech recorded.</summary>
    public double SpeakingSeconds { get; set; }
    /// <summary>Sum and count of "stop pressed → text in place" times, for an average.</summary>
    public double FinishSeconds { get; set; }
    public int FinishCount { get; set; }
    /// <summary>Dictations the AI worked on, and how many of those kept its edit (not rejected by the safety net).</summary>
    public int AiEdited { get; set; }
    public int AiKept { get; set; }
    /// <summary>Texts read aloud, and their words.</summary>
    public int Readings { get; set; }
    public int WordsRead { get; set; }
    /// <summary>Dictations per app (process name, e.g. "slack"); no window titles.</summary>
    public Dictionary<string, int> Apps { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

/// <summary>Daily usage counts in data\usage.json (outside the program folder, so updates keep it).</summary>
public sealed class UsageStore
{
    /// <summary>About two years; older days are dropped.</summary>
    public const int KeepDays = 750;

    public sealed class FileData
    {
        public int Version { get; set; } = 1;
        public List<UsageDay> Days { get; set; } = new();
    }

    readonly string? _path;
    readonly FileData _data;

    public static string DefaultPath => Path.Combine(AppPaths.DataDir, "usage.json");

    /// <param name="path">Where to keep the counts; null keeps them in memory only (tests).</param>
    /// <param name="seed">Used once, when there is no file yet: dictations already in History, so the dashboard doesn't
    /// start from zero after updating.</param>
    public UsageStore(string? path, IEnumerable<HistoryEntry>? seed = null)
    {
        _path = path;
        var loaded = path == null ? null : JsonStore.Load<FileData>(path);
        _data = loaded ?? new FileData();
        if (loaded == null && seed != null)
        {
            foreach (var e in seed.OrderBy(e => e.Time)) Count(e);
            Save();
        }
    }

    public IReadOnlyList<UsageDay> Days => _data.Days;

    /// <summary>Count a finished dictation.</summary>
    public void Record(HistoryEntry e)
    {
        Count(e);
        Save();
    }

    void Count(HistoryEntry e)
    {
        var d = DayOf(e.Time);
        d.Dictations++;
        d.Words += e.Words;
        d.SpeakingSeconds += e.Seconds;
        if (e.FinishSeconds > 0) { d.FinishSeconds += e.FinishSeconds; d.FinishCount++; }
        if (e.AiOutput != null || e.SafetyNet)
        {
            d.AiEdited++;
            if (e.AiOutput != null && !e.SafetyNet) d.AiKept++;
        }
        var app = e.AppName;
        d.Apps[app] = d.Apps.GetValueOrDefault(app) + 1;
    }

    /// <summary>Count a text read aloud.</summary>
    public void RecordReading(int words, DateTime? when = null)
    {
        var d = DayOf(when ?? DateTime.Now);
        d.Readings++;
        d.WordsRead += words;
        Save();
    }

    /// <summary>Forget every count (Settings › History).</summary>
    public void Clear()
    {
        _data.Days.Clear();
        Save();
    }

    UsageDay DayOf(DateTime time)
    {
        var day = time.Date;
        var d = _data.Days.FirstOrDefault(x => x.Day == day);
        if (d != null) return d;
        d = new UsageDay { Day = day };
        _data.Days.Add(d);
        _data.Days.Sort((a, b) => a.Day.CompareTo(b.Day));
        var cutoff = DateTime.Today.AddDays(-KeepDays);
        _data.Days.RemoveAll(x => x.Day < cutoff);
        return d;
    }

    void Save()
    {
        if (_path == null) return;
        try { JsonStore.Save(_path, _data); }
        catch (Exception e) { Log.Warn("Saving usage counts failed: " + e.Message); }
    }

    // ----- figures for the dashboard -----

    IEnumerable<UsageDay> Since(DateTime today, int days) => _data.Days.Where(d => d.Day > today.Date.AddDays(-days) && d.Day <= today.Date);

    /// <summary>Words and dictations per day for the last <paramref name="days"/> days, oldest first, ending today.</summary>
    public IReadOnlyList<DayTotal> PerDay(DateTime today, int days = 14) =>
        Enumerable.Range(0, days).Select(i => today.Date.AddDays(i - days + 1)).Select(day =>
        {
            var d = _data.Days.FirstOrDefault(x => x.Day == day);
            return new DayTotal(day, d?.Words ?? 0, d?.Dictations ?? 0, d?.WordsRead ?? 0);
        }).ToList();

    /// <summary>The apps dictated into most over the last <paramref name="days"/> days.</summary>
    public IReadOnlyList<(string App, int Count)> TopApps(DateTime today, int days = 30, int count = 5) =>
        Since(today, days).SelectMany(d => d.Apps).GroupBy(kv => kv.Key, StringComparer.OrdinalIgnoreCase)
            .Select(g => (g.Key, g.Sum(kv => kv.Value))).OrderByDescending(x => x.Item2).ThenBy(x => x.Key).Take(count).ToList();

    /// <summary>Average seconds from stop to text in place over the last <paramref name="days"/> days; null if none.</summary>
    public double? AverageFinishSeconds(DateTime today, int days = 7)
    {
        var recent = Since(today, days).ToList();
        var n = recent.Sum(d => d.FinishCount);
        return n == 0 ? null : recent.Sum(d => d.FinishSeconds) / n;
    }

    /// <summary>Of the dictations the AI worked on in the last <paramref name="days"/> days, the share whose edit was kept.</summary>
    public double? AiKeptShare(DateTime today, int days = 30)
    {
        var recent = Since(today, days).ToList();
        var n = recent.Sum(d => d.AiEdited);
        return n == 0 ? null : recent.Sum(d => d.AiKept) / (double)n;
    }

    /// <summary>Days in a row, up to today (or yesterday, if nothing yet today), with at least one dictation.</summary>
    public int Streak(DateTime today)
    {
        var active = _data.Days.Where(d => d.Dictations > 0).Select(d => d.Day).ToHashSet();
        var day = today.Date;
        if (!active.Contains(day)) day = day.AddDays(-1);
        var n = 0;
        while (active.Contains(day)) { n++; day = day.AddDays(-1); }
        return n;
    }

    /// <summary>All-time totals.</summary>
    [JsonIgnore] public int TotalWords => _data.Days.Sum(d => d.Words);
    [JsonIgnore] public int TotalDictations => _data.Days.Sum(d => d.Dictations);
    [JsonIgnore] public double TotalSpeakingSeconds => _data.Days.Sum(d => d.SpeakingSeconds);
    public UsageDay? Today(DateTime today) => _data.Days.FirstOrDefault(d => d.Day == today.Date);
}
