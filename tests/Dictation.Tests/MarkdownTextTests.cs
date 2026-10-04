using Dictation.Core.Reading;
using Xunit;

namespace Dictation.Tests;

public class MarkdownTextTests
{
    [Theory]
    [InlineData("# Title\nSome text.")]
    [InlineData("See [the docs](https://example.com/docs) for more.")]
    [InlineData("This is **important** to know.")]
    [InlineData("```\ncode\n```")]
    [InlineData("| a | b |\n|---|---|\n| 1 | 2 |")]
    [InlineData("- one\n- two\n\nUse `npm install` first.")]
    public void Recognizes_markdown(string text) => Assert.True(MarkdownText.LooksLikeMarkdown(text));

    [Theory]
    [InlineData("Hello there. How are you?")]
    [InlineData("We came #1 in the league, 5*3 = 15, and my_file_name stays.")]
    [InlineData("Shopping:\n- milk\n- eggs")]               // a dash list on its own is ordinary text too
    [InlineData("I *really* mean it.")]                    // one emphasis alone isn't enough
    public void Leaves_ordinary_text_alone(string text) => Assert.Equal(text, MarkdownText.ForReading(text));

    [Fact]
    public void Headings_lists_and_emphasis_become_plain_lines()
    {
        var md = "## Getting started\n\n1. Install it\n- **Fast** and _simple_\n- [ ] Not done yet\n> A quote with `code`\n\n---\n\nDone ~~soon~~ now.";
        Assert.Equal("Getting started\n\n1. Install it\nFast and simple\nNot done yet\nA quote with code\n\nDone soon now.",
            MarkdownText.ToPlain(md));
    }

    [Fact]
    public void Links_and_images_keep_their_text_not_the_address()
    {
        Assert.Equal("Read the guide and look at the chart.",
            MarkdownText.ToPlain("Read [the guide](https://x.org/a?b=c \"Guide\") and look at ![the chart](img/c.png)."));
        Assert.Equal("See the spec.", MarkdownText.ToPlain("See [the spec][1].\n\n[1]: https://example.com/spec"));
    }

    [Fact]
    public void Code_fences_go_but_the_code_stays() =>
        Assert.Equal("Run this:\nnpm test", MarkdownText.ToPlain("Run this:\n```bash\nnpm test\n```"));

    [Fact]
    public void Table_rows_are_read_as_lists_of_cells() =>
        Assert.Equal("Name, Age\nAda, 36", MarkdownText.ToPlain("| Name | Age |\n|:-----|----:|\n| Ada | 36 |"));

    [Fact]
    public void Heading_keeps_a_trailing_hash_that_is_part_of_a_word() =>
        Assert.Equal("Learn C#\nIntro", MarkdownText.ToPlain("# Learn C#\n# Intro ##"));

    [Fact]
    public void Escapes_and_line_break_tags_are_resolved() =>
        Assert.Equal("2 * 3 is 6\nnext", MarkdownText.ToPlain("2 \\* 3 is 6<br>next"));

    [Fact]
    public void Plain_markdown_text_splits_into_readable_pieces()
    {
        var plain = MarkdownText.ForReading("# Notes\n\n- **First** point.\n- Second point.");
        var pieces = ReadAloudText.Split(plain).Select(s => plain.Substring(s.Start, s.Length)).ToList();
        Assert.Equal(new[] { "Notes", "First point.", "Second point." }, pieces);
    }
}
