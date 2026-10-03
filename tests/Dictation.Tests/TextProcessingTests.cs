using Dictation.Core.Settings;
using Dictation.Core.Text;
using Xunit;

namespace Dictation.Tests;

public class OutputSanitizerTests
{
    [Fact]
    public void Strips_transcript_tags_and_whitespace() =>
        Assert.Equal("Hello there.", OutputSanitizer.Clean("<transcript>\nHello there.\n</transcript>\n", "hello there"));

    [Fact]
    public void Strips_preamble_the_model_added() =>
        Assert.Equal("Meet at three.", OutputSanitizer.Clean("Here is the cleaned transcript:\n\nMeet at three.", "meet at three"));

    [Fact]
    public void Keeps_text_that_merely_starts_like_a_preamble_when_input_did() =>
        Assert.StartsWith("Here is", OutputSanitizer.Clean("Here is the plan: ship it.", "Here is the plan: ship it"));

    [Fact]
    public void Removes_wrapping_quotes_only_when_input_had_none() =>
        Assert.Equal("Hello.", OutputSanitizer.Clean("\"Hello.\"", "hello"));

    [Fact]
    public void Keeps_quotes_when_user_dictated_them() =>
        Assert.Equal("\"Hello,\" she said.", OutputSanitizer.Clean("\"Hello,\" she said.", "\"hello\" she said"));

    [Fact]
    public void Removes_think_blocks_and_code_fences() =>
        Assert.Equal("Done.", OutputSanitizer.Clean("<think>hmm</think>```text\nDone.\n```", "done"));
}

public class PlausibilityTests
{
    const string Input = "so I went to the store yesterday and bought some apples and oranges for the party";

    [Fact]
    public void Accepts_light_edits() =>
        Assert.True(OutputSanitizer.IsPlausible(Input, "I went to the store yesterday and bought apples and oranges for the party.", 0.4, out _));

    [Fact]
    public void Rejects_empty() =>
        Assert.False(OutputSanitizer.IsPlausible(Input, "  ", 0.4, out var why) || why == "");

    [Fact]
    public void Rejects_summaries() =>
        Assert.False(OutputSanitizer.IsPlausible(Input, "Bought fruit.", 0.4, out _));

    [Fact]
    public void Rejects_rambling_answers() =>
        Assert.False(OutputSanitizer.IsPlausible(Input, string.Join(' ', Enumerable.Repeat("Sure! I would be happy to help with that.", 6)), 0.4, out _));

    [Fact]
    public void Short_inputs_only_guard_against_runaway_output()
    {
        Assert.True(OutputSanitizer.IsPlausible("um yes", "Yes.", 0.4, out _));
        Assert.False(OutputSanitizer.IsPlausible("um yes", string.Join(' ', Enumerable.Repeat("word", 40)), 0.4, out _));
    }
}

public class ChunkerTests
{
    [Fact]
    public void Short_text_is_one_chunk() => Assert.Single(TextChunker.Split("Short text."));

    [Fact]
    public void Long_text_splits_on_sentences_without_losing_content()
    {
        var text = string.Join(' ', Enumerable.Range(0, 400).Select(i => $"This is sentence number {i}."));
        var chunks = TextChunker.Split(text, 1000);
        Assert.True(chunks.Count > 5);
        Assert.All(chunks, c => Assert.True(c.Length <= 1000));
        Assert.All(chunks, c => Assert.EndsWith(".", c));
        Assert.Equal(text, string.Join(' ', chunks));
    }

    [Fact]
    public void Text_without_punctuation_is_still_split() =>
        Assert.True(TextChunker.Split(new string('a', 5000), 2000).Count >= 3);
}

public class PromptTests
{
    [Fact]
    public void System_prompt_contains_profile_prompt_and_option_lines()
    {
        var p = new Profile { Prompt = "Be careful.", RemoveFillers = false, PreserveParagraphs = false };
        var s = OllamaTextProcessor.BuildSystemPrompt(p);
        Assert.Contains("Be careful.", s);
        Assert.Contains("Do not remove filler words", s);
        Assert.Contains("single paragraph", s);
        Assert.Contains("only the processed text", s);
    }

    [Fact]
    public void Built_in_profiles_match_the_spec()
    {
        var names = BuiltInProfiles.Create().Select(p => p.Name).ToArray();
        Assert.Equal(new[] { "Light Cleanup", "Grammar & Clarity", "Natural Phrasing", "Custom" }, names);
        Assert.Contains("conservative dictation editor", BuiltInProfiles.Create()[0].Prompt);
    }
}

public class GarbageGuardTests
{
    [Theory]
    [InlineData("... ... ... ... ...")]
    [InlineData("")]
    [InlineData(" . . . ")]
    public void Dots_only_is_not_content(string s) => Assert.False(OutputSanitizer.HasContent(OutputSanitizer.CollapseDots(s)));

    [Fact]
    public void Real_text_survives_and_hallucinated_dots_are_collapsed() =>
        Assert.Equal("Hello there. And more", OutputSanitizer.CollapseDots("Hello there. ... ... ... And more"));

    [Fact]
    public void A_single_trailing_ellipsis_is_kept() =>
        Assert.Equal("Well...", OutputSanitizer.CollapseDots("Well..."));
}

public class SegmentTests
{
    [Fact]
    public void Short_dictation_is_one_segment() => Assert.Single(TextChunker.Segment("Just one short sentence."));

    [Fact]
    public void Long_dictation_splits_into_small_segments_and_joins_back_exactly()
    {
        var text = string.Join(' ', Enumerable.Range(0, 60).Select(i => $"This is sentence number {i} of a long dictation."));
        var segments = TextChunker.Segment(text);
        Assert.True(segments.Count > 3);
        Assert.All(segments, s => Assert.True(s.Text.Length <= TextChunker.SegmentChars));
        Assert.All(segments, s => Assert.EndsWith(".", s.Text)); // whole sentences only
        Assert.Equal(text, TextChunker.Join(segments, segments.Select(s => s.Text).ToList()));
    }

    [Fact]
    public void Paragraph_breaks_start_new_segments_and_survive_the_join()
    {
        const string text = "First topic, short.\n\nSecond topic, also short.";
        var segments = TextChunker.Segment(text);
        Assert.Equal(2, segments.Count);
        Assert.False(segments[0].StartsParagraph);
        Assert.True(segments[1].StartsParagraph);
        Assert.Equal(text, TextChunker.Join(segments, segments.Select(s => s.Text).ToList()));
    }

    [Fact]
    public void Unpunctuated_run_breaks_between_words()
    {
        var text = string.Join(' ', Enumerable.Repeat("word", 600));
        var pieces = TextChunker.Split(text, 200);
        Assert.All(pieces, p => Assert.True(p.Length <= 200));
        Assert.All(pieces, p => Assert.DoesNotContain("wor ", p + " ")); // never cuts a word in half
        Assert.Equal(text, string.Join(' ', pieces));
    }
}
