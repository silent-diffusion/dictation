using Dictation.Core.Notes;
using Xunit;

namespace Dictation.Tests;

/// <summary>The sums the Extended Notes landing page shows (the USAGE strip): over a window of days, and all time.</summary>
public class NotesUsageTotalsTests
{
    static readonly DateTime Now = new(2026, 10, 17, 15, 30, 0);

    static NoteSession Session(DateTime started, double seconds = 600, NotesSource source = NotesSource.Mic, string typed = "") => new()
    {
        Started = started, Seconds = seconds, Source = source,
        Heard = "one two three", Transcript = typed.Length == 0 ? "one two three" : "one two three " + typed,
    };

    /// <summary>Four sessions: the day before a 30-day window, its first day, today, and tomorrow (a clock set back).</summary>
    static NotesUsage FourDays()
    {
        var usage = new NotesUsage(null);
        usage.Record(Session(Now.AddDays(-30), seconds: 1000), formatRequests: 1, summaryRequests: 0);
        usage.Record(Session(Now.AddDays(-29), seconds: 100), formatRequests: 2, summaryRequests: 1);
        usage.Record(Session(Now, seconds: 200, typed: "my note"), formatRequests: 3, summaryRequests: 2);
        usage.Record(Session(Now.AddDays(1), seconds: 1000), formatRequests: 1, summaryRequests: 1);
        return usage;
    }

    [Fact]
    public void A_window_counts_only_the_days_inside_it()
    {
        var t = FourDays().Totals(Now, 30);
        Assert.Equal(2, t.Sessions);
        Assert.Equal(300.0, t.Seconds);
        Assert.Equal(6, t.WordsHeard);
        Assert.Equal(2, t.WordsTyped);
        Assert.Equal(8, t.AiRequests); // formatting and summary steps together
    }

    [Fact]
    public void A_window_of_one_day_is_today()
    {
        var t = FourDays().Totals(Now, 1);
        Assert.Equal(1, t.Sessions);
        Assert.Equal(200.0, t.Seconds);
    }

    [Fact]
    public void All_time_counts_every_day()
    {
        foreach (var days in new[] { 0, -1 })
        {
            var t = FourDays().Totals(Now, days);
            Assert.Equal(4, t.Sessions);
            Assert.Equal(2300.0, t.Seconds);
            Assert.Equal(12, t.WordsHeard);
            Assert.Equal(2, t.WordsTyped);
            Assert.Equal(11, t.AiRequests);
        }
    }

    [Fact]
    public void Sources_are_summed_across_days()
    {
        var usage = new NotesUsage(null);
        usage.Record(Session(Now.AddDays(-2), source: NotesSource.Mic), 0, 0);
        usage.Record(Session(Now.AddDays(-1), source: NotesSource.Both), 0, 0);
        usage.Record(Session(Now, source: NotesSource.Mic), 0, 0);
        var sources = usage.Totals(Now, 0).Sources;
        Assert.Equal(2, sources["Mic"]);
        Assert.Equal(1, sources["Both"]);
        Assert.False(sources.ContainsKey("Computer")); // only the sources used
    }

    [Fact]
    public void Nothing_recorded_is_all_zeros()
    {
        var t = new NotesUsage(null).Totals(Now, 30);
        Assert.Equal((0, 0.0, 0, 0, 0), (t.Sessions, t.Seconds, t.WordsHeard, t.WordsTyped, t.AiRequests));
        Assert.Empty(t.Sources);
    }

    [Theory]
    [InlineData(0.0, "0:00")]
    [InlineData(59.0, "0:00")]     // whole minutes
    [InlineData(3660.0, "1:01")]   // 61 minutes
    [InlineData(90000.0, "25:00")] // 25 hours: never wraps at a day
    public void Seconds_show_as_hours_and_whole_minutes(double seconds, string expected) =>
        Assert.Equal(expected, NotesUsage.HoursMinutes(seconds));
}
