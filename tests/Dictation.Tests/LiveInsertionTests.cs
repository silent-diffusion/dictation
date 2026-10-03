using Dictation.Core.Insertion;
using Dictation.Core.Session;
using Xunit;

namespace Dictation.Tests;

public class LiveInsertionTests
{
    [Theory]
    [InlineData("Hello there.\r\nNext line", "Hello there.\nNext line")]
    [InlineData("It’s “fine”", "It's \"fine\"")]
    [InlineData("a b", "a b")]
    public void Editor_substitutions_still_count_as_the_same_text(string inDocument, string typed) =>
        Assert.True(InsertionContext.SameText(inDocument, typed));

    [Fact]
    public void Different_text_is_not_the_same() =>
        Assert.False(InsertionContext.SameText("Hello there", "Hello their"));

    [Fact]
    public void Final_pass_may_tidy_the_typed_text() =>
        Assert.True(LiveInsertion.IsPlausibleReplacement(
            "So I think we should meet on Tuesday.", "So I think, um, we should meet on on Tuesday."));

    [Theory]
    [InlineData("")]
    [InlineData("Meeting Tuesday.")]
    public void Final_pass_never_replaces_with_much_less(string finalText) =>
        Assert.False(LiveInsertion.IsPlausibleReplacement(
            finalText, "So I think we should meet on Tuesday because Sarah is free that afternoon."));
}
