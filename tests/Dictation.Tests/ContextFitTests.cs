using Dictation.Core.Insertion;
using Xunit;

namespace Dictation.Tests;

public class ContextFitTests
{
    static string Fit(string text, string before, string after) => ContextFit.Apply(text, new InsertionContext(before, after));

    [Fact]
    public void Without_context_the_text_is_unchanged() =>
        Assert.Equal("Hello there.", ContextFit.Apply("Hello there.", null));

    [Fact]
    public void Short_phrase_mid_sentence_is_lowercased_without_a_period() =>
        Assert.Equal("quickly ", Fit("Quickly.", "We need to finish this ", "before Friday."));

    [Fact]
    public void Word_at_the_end_of_an_unfinished_sentence_gets_no_period() =>
        Assert.Equal("groceries", Fit("Groceries.", "Remember to buy the ", ""));

    [Fact]
    public void New_sentence_after_a_full_stop_keeps_capital_and_period() =>
        Assert.Equal("This is new.", Fit("this is new.", "The first sentence ends here. ", ""));

    [Fact]
    public void Empty_document_starts_a_sentence() =>
        Assert.Equal("Hello world.", Fit("hello world.", "", ""));

    [Fact]
    public void Spaces_are_added_where_words_would_touch() =>
        Assert.Equal(" brown ", Fit("Brown.", "The quick", "fox jumps."));

    [Fact]
    public void Period_is_kept_when_the_next_sentence_follows() =>
        Assert.Equal("and that was it. ", Fit("And that was it.", "We waited ", "Then we left."));

    [Fact]
    public void Names_acronyms_and_I_keep_their_capitals()
    {
        Assert.StartsWith("I think", Fit("I think so.", "Well, ", ""));
        Assert.StartsWith("NASA", Fit("NASA launched it.", "Yesterday ", ""));
        Assert.StartsWith("Sarah", Fit("Sarah agreed.", "We asked Sarah and ", ""));
    }

    [Fact]
    public void Trim_keeps_two_sentences_before_and_one_after()
    {
        var c = InsertionContext.Trim("One. Two. Three. Four ", "five. Six. Seven.");
        Assert.Equal("Three. Four ", c.Before);
        Assert.Equal("five.", c.After);
    }
}
