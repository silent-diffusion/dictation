namespace Dictation.Core.Session;

/// <summary>A day's dictation, for the dashboard's chart.</summary>
public sealed record DayTotal(DateTime Day, int Words, int Dictations);

/// <summary>Figures for the dashboard, worked out from History.</summary>
public static class HistoryStats
{
    /// <summary>Words and dictations per day for the last <paramref name="days"/> days, oldest first, ending today.</summary>
    public static IReadOnlyList<DayTotal> PerDay(IEnumerable<HistoryEntry> entries, DateTime today, int days = 14)
    {
        var list = entries.ToList();
        return Enumerable.Range(0, days).Select(i => today.Date.AddDays(i - days + 1)).Select(d =>
        {
            var on = list.Where(e => e.Time.Date == d).ToList();
            return new DayTotal(d, on.Sum(e => e.Words), on.Count);
        }).ToList();
    }

    /// <summary>The apps dictated into most, with how many dictations each.</summary>
    public static IReadOnlyList<(string App, int Count)> TopApps(IEnumerable<HistoryEntry> entries, int count = 5) =>
        entries.GroupBy(e => e.AppName).Select(g => (g.Key, g.Count()))
            .OrderByDescending(x => x.Item2).ThenBy(x => x.Key).Take(count).ToList();

    /// <summary>Average seconds from stop to text in place, over the recent dictations that recorded it; null if none.</summary>
    public static double? AverageFinishSeconds(IEnumerable<HistoryEntry> entries, int recent = 20)
    {
        var times = entries.Where(e => e.FinishSeconds > 0).Take(recent).Select(e => e.FinishSeconds).ToList();
        return times.Count == 0 ? null : times.Average();
    }

    /// <summary>Of the dictations the AI worked on, the share whose edit was used (not rejected by the safety net); null if none.</summary>
    public static double? AiKeptShare(IEnumerable<HistoryEntry> entries)
    {
        var ai = entries.Where(e => e.AiOutput != null || e.SafetyNet).ToList();
        return ai.Count == 0 ? null : ai.Count(e => e.AiOutput != null && !e.SafetyNet) / (double)ai.Count;
    }
}
