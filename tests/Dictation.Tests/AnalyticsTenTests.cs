using Dictation.Core.Notes;
using Dictation.Core.Session;
using Dictation.Core.Settings;
using Xunit;

namespace Dictation.Tests;

/// <summary>5.10.0: words per app, time read aloud, keeping History by age, Extended Notes figures.</summary>
public class AnalyticsTenTests
{
    static HistoryEntry E(string app, string title, string text, int hoursAgo = 1) =>
        new() { Time = DateTime.Now.AddHours(-hoursAgo), App = app, WindowTitle = title, Transcript = text, Final = text, Profile = "Default" };

    [Fact]
    public void The_tally_counts_words_per_app_and_per_site()
    {
        var t = new WordTally(null, new[]
        {
            E("chrome", "Inbox - Gmail - Google Chrome", "quarterly invoices quarterly invoices"),
            E("chrome", "Cats - YouTube - Google Chrome", "kittens"),
            E("notepad", "Untitled - Notepad", "grocery list"),
        });
        var days = t.Days();
        Assert.Equal(2, WordTally.Top(WordTally.ForApp(days, "chrome › Gmail"), d => d.Words, 5).Single(x => x.Key == "invoices").Count);
        Assert.DoesNotContain(WordTally.Top(WordTally.ForApp(days, "chrome › Gmail"), d => d.Words, 5), x => x.Key == "kittens");
        Assert.Contains(WordTally.Top(WordTally.ForApp(days, "chrome"), d => d.Words, 5), x => x.Key == "kittens");
        Assert.Contains(WordTally.Top(WordTally.ForApp(days, "notepad"), d => d.Words, 5), x => x.Key == "grocery");
        Assert.DoesNotContain(WordTally.Top(WordTally.ForApp(days, "notepad"), d => d.Words, 5), x => x.Key == "invoices");
        // Every app together is still the whole.
        Assert.Contains(WordTally.Top(days, d => d.Words, 10), x => x.Key == "grocery");
    }

    [Fact]
    public void An_older_tally_gets_its_apps_from_history_once()
    {
        var path = Path.Combine(Path.GetTempPath(), "oberton-words-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            File.WriteAllText(path, $$$"""{"Version":1,"Days":[{"Day":"{{{DateTime.Today:yyyy-MM-dd}}}T00:00:00","Words":{"grocery":1}}]}""");
            var seed = new[] { E("notepad", "Untitled - Notepad", "grocery list", hoursAgo: 0) };
            var t = new WordTally(path, seed);
            Assert.Equal(1, WordTally.Top(WordTally.ForApp(t.Days(), "notepad"), d => d.Words, 5).Single(x => x.Key == "grocery").Count);
            var again = new WordTally(path, seed);
            Assert.Equal(1, WordTally.Top(WordTally.ForApp(again.Days(), "notepad"), d => d.Words, 5).Single(x => x.Key == "grocery").Count);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Time_read_aloud_is_summed_per_day()
    {
        var u = new UsageStore(null);
        u.RecordReading(100);
        u.RecordReadingTime(30);
        u.RecordReadingTime(15.5);
        u.RecordReadingTime(0);
        Assert.Equal(45.5, u.InPeriod(DateTime.Today, 1).Sum(d => d.SecondsRead), 3);
    }

    [Theory]
    [InlineData(50, 0, "50 dictations")]
    [InlineData(1, 0, "1 dictation")]
    [InlineData(0, 14, "2 weeks")]
    [InlineData(0, 1, "24 hours")]
    [InlineData(0, 30, "month")]
    [InlineData(0, 0, "")]
    public void Keep_settings_read_plainly(int count, int days, string label) =>
        Assert.Equal(label, HistoryStore.KeepLabel(count, days));

    [Fact]
    public void Notes_figures_come_from_finished_sessions_in_the_period()
    {
        NoteSession S(int daysAgo, double seconds, string heard, string transcript, NotesSource source, int markers, int chunks, int failed)
        {
            var s = new NoteSession { Started = DateTime.Now.AddDays(-daysAgo), Seconds = seconds, Heard = heard, Transcript = transcript, Source = source, Finished = true };
            for (var i = 0; i < markers; i++) s.Markers.Add(new NoteMarker { Seconds = i });
            for (var i = 0; i < chunks; i++) s.Chunks.Add(new NoteChunk { AiFailed = i < failed });
            return s;
        }
        var sessions = new[]
        {
            S(1, 600, "one two three four", "one two three four my note", NotesSource.Mic, 2, 4, 1),
            S(2, 1200, "five six", "five six", NotesSource.Both, 1, 2, 0),
            S(40, 3600, "old words here", "old words here", NotesSource.Computer, 5, 3, 0),
            new NoteSession { Started = DateTime.Now, Seconds = 30, Finished = false }, // still recording
        };
        var f = NotesStats.Compute(sessions, DateTime.Today.AddDays(-29));
        Assert.Equal(2, f.Sessions);
        Assert.Equal(1800, f.Seconds);
        Assert.Equal(6, f.WordsHeard);
        Assert.Equal(2, f.WordsTyped);
        Assert.Equal(3, f.Markers);
        Assert.Equal(6, f.Steps);
        Assert.Equal(5, f.StepsKept);
        Assert.Equal(1200, f.Longest[0].Seconds);
        Assert.Equal((1, 600.0), f.Sources[NotesSource.Mic]);
        Assert.False(f.Sources.ContainsKey(NotesSource.Computer));
        Assert.Equal(3, NotesStats.Compute(sessions, null).Sessions); // every finished session
    }
}
