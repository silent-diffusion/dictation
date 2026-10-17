using Dictation.Core.Session;
using Dictation.Core.Settings;
using Xunit;

namespace Dictation.Tests;

/// <summary>The Analytics word tally: what one dictation adds, and the figures read back from it.</summary>
public class WordTallyTests
{
    [Fact]
    public void A_misheard_name_fixed_by_the_ai_is_a_correction()
    {
        var item = WordTally.Analyze("I opened Overton today", "I opened Oberton today.", "I opened Oberton today.");
        Assert.Equal(new[] { "overton" + WordTally.Arrow + "Oberton" }, item.Corrections);
    }

    [Fact]
    public void Capitals_and_punctuation_alone_are_not_corrections()
    {
        var item = WordTally.Analyze("whisper is great", "Whisper is great.", "Whisper is great.");
        Assert.Empty(item.Corrections);
        Assert.Equal(0, item.WordsChanged);
    }

    [Fact]
    public void Grammar_fixes_with_only_common_words_are_not_corrections() =>
        Assert.Null(WordTally.Correction(new[] { "a" }, new[] { "the" }));

    [Fact]
    public void Fillers_the_ai_removed_are_counted_and_are_not_corrections()
    {
        var item = WordTally.Analyze("um I think uh we should you know go", "I think we should go.", "I think we should go.");
        Assert.Equal(new[] { "uh", "um", "you know" }, item.Fillers.OrderBy(f => f == "you know").ThenBy(f => f, StringComparer.Ordinal).ToArray());
        Assert.Empty(item.Corrections);
    }

    [Fact]
    public void Without_an_ai_edit_there_are_no_corrections_or_fillers()
    {
        var item = WordTally.Analyze("um the Overton release", null, "um the Overton release");
        Assert.Empty(item.Corrections);
        Assert.Empty(item.Fillers);
    }

    [Fact]
    public void Words_come_from_the_text_that_went_in_without_common_words()
    {
        var item = WordTally.Analyze("oberton reads the release notes", null, "Oberton reads the release notes.");
        Assert.Equal(new[] { "oberton", "reads", "release", "notes" }, item.Words);
    }

    [Fact]
    public void Phrases_are_three_and_four_words_with_meaning_and_stay_inside_a_sentence()
    {
        var item = WordTally.Analyze("", null, "Go ahead and publish it. And it was done.");
        Assert.Contains("go ahead and", item.Phrases);
        Assert.Contains("go ahead and publish", item.Phrases);
        Assert.DoesNotContain("and it was", item.Phrases);      // only common words
        Assert.DoesNotContain("publish it and", item.Phrases);  // crosses a sentence end
    }

    [Fact]
    public void Top_phrases_need_repeats_and_skip_parts_of_longer_ones()
    {
        var day = new TallyDay
        {
            Day = DateTime.Today,
            Phrases = new() { ["go ahead and"] = 5, ["go ahead and publish"] = 4, ["make sure that"] = 3, ["said once only"] = 1 },
        };
        var top = WordTally.TopPhrases(new[] { day }, 5);
        Assert.Equal(new[] { "go ahead and", "make sure that" }, top.Select(t => t.Phrase));
    }

    [Fact]
    public void Hours_are_laid_out_monday_first()
    {
        var monday = new DateTime(2026, 10, 12);
        Assert.Equal(DayOfWeek.Monday, monday.DayOfWeek);
        var day = new TallyDay { Day = monday };
        day.Hours[9] = 3;
        var sunday = new TallyDay { Day = monday.AddDays(6) };
        sunday.Hours[22] = 1;
        var grid = WordTally.WeekHours(new[] { day, sunday });
        Assert.Equal(3, grid[0, 9]);
        Assert.Equal(1, grid[6, 22]);
    }

    [Fact]
    public void Profiles_are_summed_across_days_busiest_first()
    {
        TallyDay D(int offset, string name, int n) => new()
        {
            Day = DateTime.Today.AddDays(-offset),
            Profiles = new() { [name] = new ProfileTally { Dictations = n, AiEdited = n, AiKept = n - 1, WordsHeard = 100, WordsChanged = 10 } },
        };
        var rows = WordTally.ByProfile(new[] { D(0, "Raw", 2), D(1, "Light Cleanup", 3), D(2, "Light Cleanup", 4) });
        Assert.Equal("Light Cleanup", rows[0].Profile);
        Assert.Equal(7, rows[0].Total.Dictations);
        Assert.Equal(200, rows[0].Total.WordsHeard);
    }

    [Fact]
    public void The_tally_is_on_by_default() => Assert.True(new AppSettings().KeepWordTally);

    [Fact]
    public void Seeding_from_history_counts_once_and_keeps_no_sentences()
    {
        var path = Path.Combine(Path.GetTempPath(), "oberton-words-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var history = new[]
            {
                new HistoryEntry { Time = DateTime.Today.AddHours(10), Profile = "Light Cleanup", Transcript = "the Overton release is ready",
                    AiOutput = "The Oberton release is ready.", Final = "The Oberton release is ready." },
            };
            var tally = new WordTally(path, history);
            var day = Assert.Single(tally.Days());
            Assert.Equal(1, day.Words["oberton"]);
            Assert.Equal(1, day.Corrections["overton" + WordTally.Arrow + "Oberton"]);
            Assert.Equal(1, day.Hours[10]);
            Assert.DoesNotContain("release is ready.", File.ReadAllText(path));
            Assert.Single(new WordTally(path, history).Days()); // loads back; not seeded twice
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Each_dictation_is_announced_and_counted_again()
    {
        var tally = new WordTally(null);
        var changed = new SemaphoreSlim(0);
        tally.Changed += () => changed.Release();
        HistoryEntry E() => new() { Time = DateTime.Now, Profile = "Raw", Transcript = "release notes", Final = "Release notes." };
        tally.Record(E());
        Assert.True(changed.Wait(TimeSpan.FromSeconds(10)));
        tally.Record(E());
        Assert.True(changed.Wait(TimeSpan.FromSeconds(10)));
        Assert.Equal(2, tally.Days().Single().Words["release"]);
    }

    [Fact]
    public void Usage_announces_every_change()
    {
        var u = new UsageStore(null);
        var n = 0;
        u.Changed += () => n++;
        u.Record(new HistoryEntry { Time = DateTime.Now, Final = "one" });
        u.RecordReading(5);
        Assert.Equal(2, n);
    }

    [Fact]
    public void Usage_counts_can_be_read_for_a_period_or_all()
    {
        var u = new UsageStore(null);
        u.Record(new HistoryEntry { Time = DateTime.Today.AddHours(9), Final = "one two" });
        u.Record(new HistoryEntry { Time = DateTime.Today.AddDays(-40).AddHours(9), Final = "three" });
        Assert.Equal(2, u.InPeriod(DateTime.Today, 30).Sum(d => d.Words));
        Assert.Equal(3, u.InPeriod(DateTime.Today, null).Sum(d => d.Words));
    }
}
