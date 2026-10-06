using Dictation.Core.Reading;
using Xunit;

namespace Dictation.Tests;

/// <summary>The formatted view of a reading: the plain text is what is read, the lines and spans say how to show it.</summary>
public class MarkdownDocTests
{
    [Theory]
    [InlineData("Hello there. How are you?")]
    [InlineData("We came #1 in the league, 5*3 = 15, and my_file_name stays.")]
    [InlineData("Shopping:\n- milk\n- eggs")]
    [InlineData("I *really* mean it.")]
    [InlineData("Two steps:\n1. **Install** it\n2. Run it")]
    [InlineData("## Getting started\n\n1. Install it\n- **Fast** and _simple_\n- [ ] Not done yet\n> A quote with `code`\n\n---\n\nDone ~~soon~~ now.")]
    [InlineData("Read [the guide](https://x.org/a?b=c \"Guide\") and look at ![the chart](img/c.png).")]
    public void Reads_the_same_plain_text_as_before(string md) => Assert.Equal(MarkdownText.ToPlain(md), MarkdownDoc.Parse(md).Plain);

    [Fact]
    public void Lines_know_what_they_are()
    {
        var doc = MarkdownDoc.Parse("# Title\nSome text.\n- one\n  - nested\n1. first\n> quoted\n```\nvar x = 1;\n```");
        Assert.Equal(new[] { "Title", "Some text.", "one", "nested", "1. first", "quoted", "var x = 1;" },
            doc.Lines.Select(l => doc.Plain.Substring(l.Start, l.Length)));
        Assert.Equal(new[] { MdLineKind.Heading, MdLineKind.Paragraph, MdLineKind.Bullet, MdLineKind.Bullet, MdLineKind.Numbered,
            MdLineKind.Quote, MdLineKind.Code }, doc.Lines.Select(l => l.Kind));
        Assert.Equal(1, doc.Lines[0].Level);
        Assert.Equal(0, doc.Lines[2].Level);
        Assert.Equal(1, doc.Lines[3].Level);
    }

    [Fact]
    public void Inline_styles_point_at_the_plain_text()
    {
        var doc = MarkdownDoc.Parse("Use **bold**, *italic*, `code` and [a link](https://x.org).");
        Assert.Equal("Use bold, italic, code and a link.", doc.Plain);
        MdStyle At(string word) => doc.StyleAt(doc.Plain.IndexOf(word, StringComparison.Ordinal));
        Assert.Equal(MdStyle.Bold, At("bold"));
        Assert.Equal(MdStyle.Italic, At("italic"));
        Assert.Equal(MdStyle.Code, At("code"));
        Assert.Equal(MdStyle.Link, At("a link"));
        Assert.Equal(MdStyle.None, At("Use"));
    }

    [Fact]
    public void Nested_emphasis_and_setext_headings()
    {
        var doc = MarkdownDoc.Parse("Title\n=====\n**very *important* note**");
        Assert.Equal("Title\nvery important note", doc.Plain);
        Assert.Equal(MdLineKind.Heading, doc.Lines[0].Kind);
        Assert.Equal(MdStyle.Bold | MdStyle.Italic, doc.StyleAt(doc.Plain.IndexOf("important", StringComparison.Ordinal)));
        Assert.Equal(MdStyle.Bold, doc.StyleAt(doc.Plain.IndexOf("very", StringComparison.Ordinal)));
    }

    [Fact]
    public void Every_sentence_falls_inside_one_line()
    {
        var doc = MarkdownDoc.Parse("# Notes\nFirst point. Second point.\n- item one\n- item two\n\nEnd.");
        foreach (var s in ReadAloudText.Split(doc.Plain))
        {
            var line = doc.LineAt(s.Start);
            Assert.NotNull(line);
            Assert.True(s.Start + s.Length <= line!.Start + line.Length);
        }
    }
}

public class WordsReadPerDayTests
{
    [Fact]
    public void Words_read_aloud_are_counted_per_day_next_to_words_dictated()
    {
        var now = DateTime.Today.AddHours(12);
        var u = new Dictation.Core.Session.UsageStore(null);
        u.RecordReading(120, now);
        u.RecordReading(30, now.AddDays(-1));
        u.Record(new Dictation.Core.Session.HistoryEntry { Time = now, Final = "one two three", Transcript = "one two three" });
        var days = u.PerDay(now);
        Assert.Equal(120, days[^1].WordsRead);
        Assert.Equal(3, days[^1].Words);
        Assert.Equal(30, days[^2].WordsRead);
        Assert.Equal(0, days[^2].Words);
    }
}
