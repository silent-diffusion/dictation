namespace Dictation.Core.Notes;

/// <summary>Extended Notes over a period, for Analytics (worked out from the sessions kept, so it follows deletions).</summary>
/// <param name="Seconds">Time recorded.</param>
/// <param name="WordsHeard">Words the speech engine heard; <paramref name="WordsTyped"/> are the listener's own.</param>
/// <param name="Steps">Formatting steps, and <paramref name="StepsKept"/> of them whose AI edit was used (not rejected or failed).</param>
/// <param name="Sources">Sessions and seconds per source (Mic, Computer, Both).</param>
public sealed record NotesFigures(
    int Sessions, double Seconds, int WordsHeard, int WordsTyped, int Markers, int Steps, int StepsKept,
    IReadOnlyList<NoteSession> Longest, IReadOnlyDictionary<NotesSource, (int Sessions, double Seconds)> Sources)
{
    /// <summary>Words heard per minute recorded: how much talk a session holds.</summary>
    public double? WordsPerMinute => Seconds >= 60 ? WordsHeard / (Seconds / 60) : null;
}

public static class NotesStats
{
    /// <summary>The finished sessions started on or after <paramref name="from"/> (all of them when null).</summary>
    public static NotesFigures Compute(IEnumerable<NoteSession> sessions, DateTime? from, int longest = 5)
    {
        var list = sessions.Where(s => s.Finished && (from == null || s.Started >= from.Value)).ToList();
        var sources = new Dictionary<NotesSource, (int Sessions, double Seconds)>();
        foreach (var s in list)
        {
            var (n, sec) = sources.GetValueOrDefault(s.Source);
            sources[s.Source] = (n + 1, sec + s.Seconds);
        }
        int heard = 0, typed = 0;
        foreach (var s in list)
        {
            var h = NoteSession.Words(s.Heard);
            heard += h;
            typed += Math.Max(0, NoteSession.Words(s.Transcript) - h);
        }
        return new NotesFigures(
            list.Count,
            list.Sum(s => s.Seconds),
            heard,
            typed,
            list.Sum(s => s.Markers.Count),
            list.Sum(s => s.Chunks.Count),
            list.Sum(s => s.Chunks.Count(c => !c.AiFailed)),
            list.OrderByDescending(s => s.Seconds).Take(longest).ToList(),
            sources);
    }
}
