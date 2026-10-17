using Dictation.Core.Infrastructure;

namespace Dictation.Core.Notes;

/// <summary>One day of Extended Notes, as counts only: never any text or audio.</summary>
public sealed class NotesUsageDay
{
    public DateTime Day { get; set; }
    public int Sessions { get; set; }
    /// <summary>Seconds recorded.</summary>
    public double Seconds { get; set; }
    /// <summary>Words the speech engine heard, and words the listener typed in.</summary>
    public int WordsHeard { get; set; }
    public int WordsTyped { get; set; }
    /// <summary>AI requests: formatting steps, and summary steps (sections, merges and rewrites).</summary>
    public int FormatRequests { get; set; }
    public int SummaryRequests { get; set; }
    /// <summary>Sessions per source: "Mic", "Computer" or "Both".</summary>
    public Dictionary<string, int> Sources { get; set; } = new();
}

/// <summary>
/// Daily counts of Extended Notes, in data\notes\usage.json, kept apart from the dictation counts (data\usage.json): a
/// lecture's hour and its ten thousand words are not dictation, so they never show in the dashboard or Analytics. They
/// are kept so they can be looked at later.
/// </summary>
public sealed class NotesUsage
{
    public sealed class FileData
    {
        public int Version { get; set; } = 1;
        public List<NotesUsageDay> Days { get; set; } = new();
    }

    readonly string? _path;
    readonly FileData _data;

    public static string DefaultPath => Path.Combine(NotesStore.Dir, "usage.json");

    /// <param name="path">Where to keep the counts; null keeps them in memory only (tests).</param>
    public NotesUsage(string? path)
    {
        _path = path;
        _data = (path == null ? null : JsonStore.Load<FileData>(path)) ?? new FileData();
    }

    public IReadOnlyList<NotesUsageDay> Days => _data.Days;

    /// <summary>Count a finished session, on the day it started.</summary>
    public void Record(NoteSession s, int formatRequests, int summaryRequests)
    {
        var day = s.Started.Date;
        var d = _data.Days.FirstOrDefault(x => x.Day == day);
        if (d == null)
        {
            d = new NotesUsageDay { Day = day };
            _data.Days.Add(d);
            _data.Days.Sort((a, b) => a.Day.CompareTo(b.Day));
        }
        d.Sessions++;
        d.Seconds += s.Seconds;
        var heard = NoteSession.Words(s.Heard);
        d.WordsHeard += heard;
        d.WordsTyped += Math.Max(0, NoteSession.Words(s.Transcript) - heard);
        d.FormatRequests += formatRequests;
        d.SummaryRequests += summaryRequests;
        var source = s.Source.ToString();
        d.Sources[source] = d.Sources.GetValueOrDefault(source) + 1;
        if (_path == null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            JsonStore.Save(_path, _data);
        }
        catch (Exception e) { Log.Warn("Extended notes: saving the counts failed: " + e.Message); }
    }
}
