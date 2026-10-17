using System.IO.Compression;
using System.Xml.Linq;
using Dictation.Core.Notes;
using Xunit;

namespace Dictation.Tests;

public class NotesDocxExportTests
{
    static readonly XNamespace W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";

    static NoteSession Sample() => new()
    {
        Title = "Product sync", Started = new DateTime(2026, 10, 17, 9, 30, 0), Seconds = 3725,
        Summary = "Main idea: ship Monday.\n\n- Budget approved\n- Hiring paused",
        Formatted = "We ship on Monday.\nThe budget is approved.\n\n\nHiring is paused.",
        Transcript = "we ship on monday the budget is approved hiring is paused",
    };

    static ZipArchive Open(byte[] docx) => new(new MemoryStream(docx), ZipArchiveMode.Read);

    static XDocument Xml(ZipArchive zip, string name)
    {
        var entry = zip.GetEntry(name);
        Assert.NotNull(entry);
        using var stream = entry!.Open();
        return XDocument.Load(stream);
    }

    /// <summary>The body's paragraphs: each one's style and its text, with a line break for every w:br.</summary>
    static (string? Style, string Text)[] Paragraphs(XDocument doc) => doc.Root!.Element(W + "body")!.Elements(W + "p")
        .Select(p => (p.Element(W + "pPr")?.Element(W + "pStyle")?.Attribute(W + "val")?.Value,
                      string.Concat(p.Descendants().Select(e => e.Name == W + "t" ? e.Value : e.Name == W + "br" ? "\n" : ""))))
        .ToArray();

    [Fact]
    public void Everything_is_a_package_with_the_title_the_headings_and_the_text()
    {
        using var zip = Open(NotesExport.BuildDocx(Sample(), NotesExport.Part.Everything));
        foreach (var name in new[] { "[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml" })
            Assert.NotNull(zip.GetEntry(name));
        var doc = Xml(zip, "word/document.xml");
        Assert.Equal(W + "document", doc.Root!.Name);
        var paragraphs = Paragraphs(doc);
        Assert.Equal("Title", paragraphs[0].Style);
        Assert.Equal("Product sync", paragraphs[0].Text);
        Assert.Null(paragraphs[1].Style);
        Assert.Contains("1:02:05", paragraphs[1].Text);
        Assert.Equal(new[] { "Summary", "Formatted", "Transcript" }, paragraphs.Where(p => p.Style == "Heading1").Select(p => p.Text));
        Assert.Contains(paragraphs, p => p.Text == "We ship on Monday.\nThe budget is approved."); // a line break is kept
        Assert.Contains(paragraphs, p => p.Text == "Hiring is paused."); // blank lines make a new paragraph
        Assert.Contains(paragraphs, p => p.Text == "- Budget approved\n- Hiring paused");
        Assert.Contains(paragraphs, p => p.Text == "we ship on monday the budget is approved hiring is paused");
        Assert.True(Array.FindIndex(paragraphs, p => p.Text == "Summary") < Array.FindIndex(paragraphs, p => p.Text == "Formatted"));

        var styles = Xml(zip, "word/styles.xml");
        Assert.Equal(new[] { "Normal", "Title", "Heading1" }, styles.Root!.Elements(W + "style").Select(s => s.Attribute(W + "styleId")!.Value));
        var rels = Xml(zip, "_rels/.rels");
        Assert.Equal("word/document.xml", rels.Root!.Elements().Single().Attribute("Target")!.Value);
        Assert.Contains("wordprocessingml.document.main+xml", Xml(zip, "[Content_Types].xml").ToString());
        Assert.EndsWith("/styles", Xml(zip, "word/_rels/document.xml.rels").Root!.Elements().Single().Attribute("Type")!.Value);
    }

    [Fact]
    public void Special_characters_are_escaped_and_control_characters_dropped()
    {
        var s = new NoteSession { Title = "A & B <c> \"d\"", Transcript = "Smile \U0001F600 here\u0007 and\u0001 \"quoted\" <tag> & co\ttab" };
        using var zip = Open(NotesExport.BuildDocx(s, NotesExport.Part.Transcript));
        using var reader = new StreamReader(zip.GetEntry("word/document.xml")!.Open());
        var raw = reader.ReadToEnd();
        Assert.Contains("&amp;", raw);
        Assert.Contains("&lt;c&gt;", raw);
        Assert.DoesNotContain("\u0007", raw);
        var paragraphs = Paragraphs(XDocument.Parse(raw));
        Assert.Equal("A & B <c> \"d\"", paragraphs[0].Text);
        Assert.Equal("Smile \U0001F600 here and \"quoted\" <tag> & co\ttab", paragraphs[2].Text);
        Assert.DoesNotContain(paragraphs, p => p.Style == "Heading1"); // one part: no headings
    }

    [Fact]
    public void XmlSafe_keeps_tabs_and_newlines_and_drops_the_rest()
    {
        Assert.Equal("a\nb\nc", NotesExport.XmlSafe("a\r\nb\rc"));
        Assert.Equal("tab\tkept gone", NotesExport.XmlSafe("tab\tkept\u0000\u001F gone\u001B"));
        Assert.Equal("half  of an emoji", NotesExport.XmlSafe("half \uD83D of an emoji"));
        Assert.Equal("whole \U0001F600 emoji", NotesExport.XmlSafe("whole \U0001F600 emoji"));
    }

    [Fact]
    public void An_empty_session_is_still_a_valid_document()
    {
        using var zip = Open(NotesExport.BuildDocx(new NoteSession(), NotesExport.Part.Everything));
        var paragraphs = Paragraphs(Xml(zip, "word/document.xml"));
        Assert.Equal(5, paragraphs.Length); // the title, the date line, three headings and no text
        Assert.Equal("Title", paragraphs[0].Style);
        Assert.Equal("", paragraphs[0].Text);
        Assert.Equal(3, paragraphs.Count(p => p.Style == "Heading1"));
    }

    [Fact]
    public void One_part_has_no_headings_and_none_of_the_other_texts()
    {
        using var zip = Open(NotesExport.BuildDocx(Sample(), NotesExport.Part.Formatted));
        var paragraphs = Paragraphs(Xml(zip, "word/document.xml"));
        Assert.DoesNotContain(paragraphs, p => p.Style == "Heading1");
        Assert.DoesNotContain(paragraphs, p => p.Text.Contains("we ship on monday"));
        Assert.DoesNotContain(paragraphs, p => p.Text.Contains("Main idea"));
        Assert.Contains(paragraphs, p => p.Text.StartsWith("We ship on Monday."));
    }
}
