using Dictation.Core.Text;
using Xunit;

namespace Dictation.Tests;

public class WordDiffTests
{
    static string Kept(IEnumerable<DiffToken> d) =>
        string.Join(' ', d.Where(t => t.Kind != DiffKind.Removed).Select(t => t.Word));

    static string Removed(IEnumerable<DiffToken> d) =>
        string.Join(' ', d.Where(t => t.Kind == DiffKind.Removed).Select(t => t.Word));

    [Fact]
    public void Kept_words_read_back_as_the_edited_text()
    {
        const string raw = "um so yesterday I I went to the the store and and bought uh three apples no wait four apples";
        const string edited = "Yesterday I went to the store and bought four apples.";
        var d = WordDiff.Compute(raw, edited);
        Assert.Equal(edited, Kept(d));
        Assert.Contains("um", Removed(d).Split(' '));
        Assert.Contains("uh", Removed(d).Split(' '));
        Assert.True(WordDiff.HasChanges(d));
    }

    [Fact]
    public void Case_and_punctuation_changes_are_not_edits()
    {
        var d = WordDiff.Compute("so i think we should meet", "So I think we should meet.");
        Assert.All(d, t => Assert.Equal(DiffKind.Same, t.Kind));
        Assert.False(WordDiff.HasChanges(d));
    }

    [Fact]
    public void Replaced_words_show_as_removed_then_added()
    {
        var d = WordDiff.Compute("fifty dollars", "sixty dollars");
        Assert.Equal(new[] { DiffKind.Removed, DiffKind.Added, DiffKind.Same }, d.Select(t => t.Kind));
        Assert.Equal("fifty", d[0].Word);
        Assert.Equal("sixty", d[1].Word);
    }

    [Fact]
    public void Empty_inputs_are_handled()
    {
        Assert.Empty(WordDiff.Compute("", ""));
        Assert.All(WordDiff.Compute("", "hello there"), t => Assert.Equal(DiffKind.Added, t.Kind));
        Assert.All(WordDiff.Compute("hello there", ""), t => Assert.Equal(DiffKind.Removed, t.Kind));
    }
}
