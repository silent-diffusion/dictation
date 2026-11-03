using System.Text.Json;
using Dictation.Core.Notes;
using Dictation.Core.Speech;
using Dictation.Core.Text;
using Xunit;

namespace Dictation.Tests;

/// <summary>Word timings: words.json, matching them to a text as it is shown now, and the word lit at a moment.</summary>
public class WordTimingsTests
{
    static List<WordTiming> Heard(string text, double start = 0, double each = 0.5) =>
        text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select((w, i) => new WordTiming(w, start + i * each, start + i * each + each * 0.8)).ToList();

    static string Lit(string text, SpokenWords words) => string.Join(" ", words.Words.Select(w => text.Substring(w.Offset, w.Length)));

    static string TempDir()
    {
        var dir = Path.Combine(Path.GetTempPath(), "oberton-words-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        return dir;
    }

    // ===== the file =====

    [Fact]
    public void Words_go_to_disk_and_come_back()
    {
        var dir = TempDir();
        try
        {
            var path = Path.Combine(dir, WordTimings.FileName);
            WordTimings.Save(path, new[] { new WordTiming("Hello,", 0.523, 0.811), new WordTiming("world.", 0.81, 1.24) });
            Assert.StartsWith("{\"Version\":1,\"Words\":[[\"Hello,\",0.52,0.81],", File.ReadAllText(path));
            var back = WordTimings.Load(path);
            Assert.Equal(new[] { new WordTiming("Hello,", 0.52, 0.81), new WordTiming("world.", 0.81, 1.24) }, back);
            WordTimings.Save(path, Array.Empty<WordTiming>());
            Assert.False(File.Exists(path)); // no words: no file
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void Missing_or_damaged_files_give_no_words()
    {
        var dir = TempDir();
        try
        {
            var path = Path.Combine(dir, WordTimings.FileName);
            Assert.Empty(WordTimings.Load(path)); // a session or dictation from before word timings
            File.WriteAllText(path, "{\"Version\":1,\"Words\":[[\"cut off");
            Assert.Empty(WordTimings.Load(path));
            File.WriteAllText(path, "\"just a string\"");
            Assert.Empty(WordTimings.Load(path));
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void Odd_rows_are_skipped_and_the_rest_kept_in_order()
    {
        var dir = TempDir();
        try
        {
            var path = Path.Combine(dir, WordTimings.FileName);
            File.WriteAllText(path, """
                {"Version": 7, "Words": [
                  ["second", 2.0, 2.5],
                  ["first", 1.0, 1.4],
                  ["backwards", 3.0, 2.0],
                  [42, 1, 2], ["no times"], ["  ", 1, 2], ["negative", -1, 2], null, "text",
                  {"Text": "object", "Start": 4, "End": 4.5},
                ]}
                """);
            var words = WordTimings.Load(path);
            Assert.Equal(new[] { "first", "second", "backwards", "object" }, words.Select(w => w.Text));
            Assert.Equal(3.0, words[2].End); // an end before its start is raised to it
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void The_engines_rows_parse_and_shift_into_the_recording()
    {
        using var doc = JsonDocument.Parse("""[["One", 0.1, 0.4], ["two.", 0.4, 0.9]]""");
        var words = WordTimings.Shifted(WordTimings.Parse(doc.RootElement), 30);
        Assert.Equal(new[] { new WordTiming("One", 30.1, 30.4), new WordTiming("two.", 30.4, 30.9) }, words);
        using var none = JsonDocument.Parse("{}");
        Assert.Empty(WordTimings.Parse(none.RootElement));
    }

    // ===== matching to the text shown =====

    [Fact]
    public void An_unchanged_transcript_matches_word_for_word()
    {
        const string text = "So the plan is simple: we start on Monday.";
        var words = SpokenWords.Map(text, Heard("So the plan is simple: we start on Monday."));
        Assert.Equal(9, words.Words.Count);
        Assert.Equal("So the plan is simple we start on Monday", Lit(text, words)); // punctuation is never lit
        Assert.Equal(text.IndexOf("Monday", StringComparison.Ordinal), words.Words[^1].Offset);
    }

    [Fact]
    public void Case_punctuation_and_markdown_are_ignored()
    {
        const string text = "## Plan\n\n- **So**, the PLAN... isn't (simple)!";
        var words = SpokenWords.Map(text, Heard("so the plan isnt simple"));
        Assert.Equal("So the PLAN isn't simple", Lit(text, words));
    }

    [Fact]
    public void Edited_words_have_no_timing_and_the_rest_keep_theirs()
    {
        var heard = Heard("we will meet on tuesday at the office");
        const string text = "We'll meet on Wednesday at the office, I think.";
        var words = SpokenWords.Map(text, heard);
        Assert.Equal("meet on at the office", Lit(text, words));
        // "office" keeps the time it was said, though the text before it changed.
        Assert.Equal(heard[^1].Start, words.Words[^1].Start);
    }

    [Fact]
    public void Typed_notes_and_markers_between_pieces_are_skipped()
    {
        var heard = Heard("first part of the talk", 0).Concat(Heard("second part here", 20)).ToList();
        const string text = "My own note before.\nfirst part of the talk\n⚑ 0:15\nsecond part here";
        var words = SpokenWords.Map(text, heard);
        Assert.Equal("first part of the talk second part here", Lit(text, words));
        Assert.Equal(20, words.Words[5].Start);
    }

    [Fact]
    public void A_summary_only_lights_phrases_it_borrows()
    {
        var heard = Heard("so we agreed that the budget goes up by ten percent next year and the team grows");
        const string text = "The budget goes up by ten percent. The team is happy.";
        var words = SpokenWords.Map(text, heard, minRun: 3);
        Assert.Equal("The budget goes up by ten percent", Lit(text, words)); // "The team" is two words: not enough
    }

    [Fact]
    public void Nothing_heard_or_nothing_shown_matches_nothing()
    {
        Assert.Empty(SpokenWords.Map("some text", Array.Empty<WordTiming>()).Words);
        Assert.Empty(SpokenWords.Map("", Heard("some text")).Words);
        Assert.Empty(SpokenWords.Map("— ⚑ ...", Heard("some text")).Words);
    }

    [Fact]
    public void A_long_session_is_matched_quickly_and_fully()
    {
        // About two hours of speech, with an edit near the start and one near the end: too large to line up cell by cell.
        var rng = new Random(7);
        var vocabulary = Enumerable.Range(0, 4000).Select(i => "w" + i).ToArray();
        var said = Enumerable.Range(0, 18_000).Select(_ => vocabulary[rng.Next(vocabulary.Length)]).ToList();
        var heard = said.Select((w, i) => new WordTiming(w, i * 0.4, i * 0.4 + 0.3)).ToList();
        var shown = said.ToList();
        shown[100] = "typed";
        shown.Insert(17_000, "inserted");
        var text = string.Join(" ", shown);
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var words = SpokenWords.Map(text, heard);
        Assert.True(clock.ElapsedMilliseconds < 2000, $"took {clock.ElapsedMilliseconds} ms");
        Assert.Equal(said.Count - 1, words.Words.Count);
        for (var i = 1; i < words.Words.Count; i++) Assert.True(words.Words[i].Start > words.Words[i - 1].Start);
    }

    // ===== the word at a moment =====

    [Fact]
    public void The_word_said_is_lit_and_held_through_short_gaps()
    {
        var heard = new[] { new WordTiming("one", 1.0, 1.4), new WordTiming("two", 1.5, 1.9), new WordTiming("three", 4.0, 4.5) };
        var words = SpokenWords.Map("one two three", heard);
        Assert.Equal(-1, words.At(0.5));   // before the first word
        Assert.Equal(0, words.At(1.0));
        Assert.Equal(0, words.At(1.45));   // between two words: still the first
        Assert.Equal(1, words.At(1.5));
        Assert.Equal(1, words.At(2.1));    // held a moment after it ends
        Assert.Equal(-1, words.At(3.0));   // a pause: nothing
        Assert.Equal(2, words.At(4.2));
        Assert.Equal(-1, words.At(10));    // after the end
        Assert.Equal(-1, SpokenWords.None.At(1));
    }

    // ===== a Notes session's words =====

    [Fact]
    public void A_session_keeps_its_pieces_words_beside_its_recording()
    {
        var dir = TempDir();
        try
        {
            var store = new NotesStore(load: false);
            var s = new NoteSession { Folder = dir };
            Assert.Empty(s.Timings); // none on disk yet
            s.AppendHeard("hello there", 0, words: Heard("hello there", 0));
            s.AppendHeard("no timings", 5); // a piece the engine sent no words for
            s.AppendHeard("general kenobi", 10, words: Heard("general kenobi", 10));
            Assert.Equal(4, s.Timings.Count);
            Assert.True(s.TimingsDirty);
            store.Save(s);
            Assert.False(s.TimingsDirty);
            var path = Path.Combine(dir, WordTimings.FileName);
            for (var i = 0; i < 50 && !File.Exists(path); i++) Thread.Sleep(50); // written in the background
            var again = new NoteSession { Folder = dir };
            Assert.Equal(s.Timings, again.Timings);
            Assert.Equal("hello there general kenobi", Lit(s.Transcript, SpokenWords.Map(s.Transcript, again.Timings)));
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void Transcribing_again_replaces_the_words()
    {
        var s = new NoteSession();
        s.AppendHeard("old words", 0, words: Heard("old words"));
        s.ReplaceTranscript(new[] { (15.0, "second part"), (0.0, "first part") }, words: Heard("second part", 15).Concat(Heard("first part", 0)).ToList());
        Assert.Equal(new[] { "first", "part", "second", "part" }, s.Timings.Select(w => w.Text));
        Assert.Equal(new[] { "first part", "second part" }, SpokenWords.Map(s.Transcript, s.Timings).Words
            .Select(w => s.Transcript.Substring(w.Offset, w.Length)).Chunk(2).Select(c => string.Join(" ", c)));
        s.ReplaceTranscript(new[] { (0.0, "redone without timings") });
        Assert.Empty(s.Timings);
    }
}
