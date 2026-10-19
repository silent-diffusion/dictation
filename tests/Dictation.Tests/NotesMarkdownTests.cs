using Dictation.Core.Text;
using Xunit;

namespace Dictation.Tests;

public class NotesMarkdownTests
{
    static string Show(MdBlock b) => b.Kind + ":" + string.Concat(b.Spans.Select(s =>
        s.Break ? "|" : s.Code ? "`" + s.Text + "`" : s.Bold && s.Italic ? "***" + s.Text + "***" : s.Bold ? "**" + s.Text + "**" : s.Italic ? "_" + s.Text + "_" : s.Text));

    [Fact]
    public void Blocks_are_found()
    {
        var md = "# Title\n\nFirst line\nsecond line\n\n- one\n  - nested\n2. two\n> quoted\n---\n⚑ 12:34\n```\ncode *here*\n```";
        var blocks = NotesMarkdown.Parse(md);
        Assert.Equal(new[] { "Heading:Title", "Paragraph:First line|second line", "Bullet:one", "Bullet:nested", "Numbered:two",
            "Quote:quoted", "Rule:", "Marker:⚑ 12:34", "Code:`code *here*`" }, blocks.Select(Show));
        Assert.Equal(1, blocks[0].Level);
        Assert.Equal(1, blocks[3].Level);
        Assert.Equal("2", blocks[4].Number);
    }

    [Fact]
    public void Inline_markup_and_labels()
    {
        var b = NotesMarkdown.Parse("Main idea: the **launch** moves to *May*, see `plan` and [the doc](http://x)").Single();
        Assert.Equal("Paragraph:**Main idea:** the **launch** moves to _May_, see `plan` and the doc", Show(b));
        Assert.Equal("Paragraph:snake_case_name and 2 * 3 * 4", Show(NotesMarkdown.Parse("snake_case_name and 2 * 3 * 4").Single()));
        Assert.Equal("Paragraph:**not closed", Show(NotesMarkdown.Parse("**not closed").Single()));
        Assert.Equal("Paragraph:*literal*", Show(NotesMarkdown.Parse(@"\*literal\*").Single()));
    }

    [Fact]
    public void Spans_know_where_they_came_from()
    {
        const string md = "Hello **bold** world\n- item";
        var blocks = NotesMarkdown.Parse(md);
        foreach (var span in blocks.SelectMany(b => b.Spans).Where(s => !s.Break && s.Text.Length > 0))
            Assert.Equal(span.Text, md.Substring(span.Offset, span.Text.Length));
    }

    [Fact]
    public void Summary_layout_reads_well()
    {
        var blocks = NotesMarkdown.Parse("Main idea: Plans.\n\n- First point\n- Second point\n\nA paragraph.");
        Assert.Equal(new[] { "Paragraph:**Main idea:** Plans.", "Bullet:First point", "Bullet:Second point", "Paragraph:A paragraph." }, blocks.Select(Show));
    }
}
