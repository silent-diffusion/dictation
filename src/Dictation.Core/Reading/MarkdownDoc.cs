using System.Text;
using System.Text.RegularExpressions;

namespace Dictation.Core.Reading;

/// <summary>What a line of a Markdown text is.</summary>
public enum MdLineKind { Paragraph, Heading, Bullet, Numbered, Quote, Code, Table }

/// <summary>Inline formatting.</summary>
[Flags]
public enum MdStyle { None = 0, Bold = 1, Italic = 2, Code = 4, Link = 8, Strike = 16 }

/// <summary>A line of <see cref="MarkdownDoc.Plain"/>: where it is, what it is, how deep (heading level 1-6, list
/// nesting from 0).</summary>
public sealed record MdLine(int Start, int Length, MdLineKind Kind, int Level);

/// <summary>A formatted stretch of <see cref="MarkdownDoc.Plain"/>.</summary>
public sealed record MdSpan(int Start, int Length, MdStyle Style);

/// <summary>
/// A Markdown text as the plain text read aloud, plus where its headings, list items, quotes, code and bold, italic and
/// link runs are in that plain text, so the player can show it formatted while it highlights what is being read.
/// The plain text follows the same rules as <see cref="MarkdownText.ToPlain"/> (it uses its inline rules), worked out
/// line by line so every position is known.
/// </summary>
public sealed class MarkdownDoc
{
    public string Plain { get; }
    public IReadOnlyList<MdLine> Lines { get; }
    public IReadOnlyList<MdSpan> Spans { get; }

    MarkdownDoc(string plain, List<MdLine> lines, List<MdSpan> spans) { Plain = plain; Lines = lines; Spans = spans; }

    static readonly Regex Fence = new(@"^ {0,3}(```|~~~)");
    static readonly Regex LinkDef = new(@"^ {0,3}\[[^\]\n]+\]:\s*\S+");
    static readonly Regex Rule = new(@"^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$");
    static readonly Regex TableSep = new(@"^ {0,3}\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$");
    static readonly Regex TableRow = new(@"^ {0,3}\|(.*)\|[ \t]*$");
    static readonly Regex Heading = new(@"^[ \t]*(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$");
    static readonly Regex Setext = new(@"^ {0,3}(=+|-{2,})[ \t]*$");
    static readonly Regex Quote = new(@"^([ \t]*>)+[ \t]?(.*)$");
    static readonly Regex Bullet = new(@"^([ \t]*)[-*+•◦▪‣][ \t]+(?:\[[ xX]\][ \t]+)?(.*)$");
    static readonly Regex Number = new(@"^([ \t]*)(\d{1,3}[.)])[ \t]+(.*)$");

    /// <summary>The inline marks, tried left to right; named groups say what each is and hold its text.</summary>
    static readonly Regex InlineMarks = new(
        @"(?<code>`+(?<ct>[^`\n]+?)`+)" +
        @"|!\[(?<img>[^\]\n]*)\]\([^)\n]*\)" +
        @"|\[(?<lt>[^\]\n]+)\]\([^)\n]*\)" +
        @"|<(?<auto>(?:https?|mailto):[^>\s]+)>" +
        @"|(?<bm>\*\*|__)(?=\S)(?<b>.+?)(?<=\S)\k<bm>" +
        @"|~~(?=\S)(?<st>.+?)(?<=\S)~~" +
        @"|(?<![\w*])\*(?=\S)(?<i1>[^*\n]+?)(?<=\S)\*(?![\w*])" +
        @"|(?<![\w_])_(?=\S)(?<i2>[^_\n]+?)(?<=\S)_(?![\w_])" +
        @"|(?<url>https?://[^\s)<>]+)");

    public static MarkdownDoc Parse(string markdown)
    {
        var plain = new StringBuilder();
        var lines = new List<MdLine>();
        var spans = new List<MdSpan>();
        var raw = markdown.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        var inCode = false;
        var blankRun = 0;

        void AddLine(MdLineKind kind, int level, Action<StringBuilder> write)
        {
            var start = plain.Length;
            write(plain);
            // No trailing spaces (the plain text never has them)
            while (plain.Length > start && plain[^1] is ' ' or '\t') plain.Length--;
            var length = plain.Length - start;
            if (length == 0 && kind != MdLineKind.Code)
            {
                if (lines.Count == 0 || ++blankRun > 1) return; // no leading blank lines, at most one in a row
                plain.Append('\n');
                lines.Add(new MdLine(start, 0, MdLineKind.Paragraph, 0));
                return;
            }
            blankRun = 0;
            plain.Append('\n');
            lines.Add(new MdLine(start, length, kind, level));
        }

        // Inline text: formatted runs into the plain text, each run's text made plain by the shared inline rules.
        void Inline(StringBuilder sb, string text, MdStyle outer = MdStyle.None)
        {
            var pos = 0;
            foreach (Match m in InlineMarks.Matches(text))
            {
                if (m.Index > pos) Emit(sb, text[pos..m.Index], outer);
                var (inner, style) =
                    m.Groups["ct"].Success ? (m.Groups["ct"].Value, MdStyle.Code) :
                    m.Groups["img"].Success ? (m.Groups["img"].Value, MdStyle.None) :
                    m.Groups["lt"].Success ? (m.Groups["lt"].Value, MdStyle.Link) :
                    m.Groups["auto"].Success ? (m.Groups["auto"].Value, MdStyle.Link) :
                    m.Groups["b"].Success ? (m.Groups["b"].Value, MdStyle.Bold) :
                    m.Groups["st"].Success ? (m.Groups["st"].Value, MdStyle.Strike) :
                    m.Groups["i1"].Success ? (m.Groups["i1"].Value, MdStyle.Italic) :
                    m.Groups["i2"].Success ? (m.Groups["i2"].Value, MdStyle.Italic) :
                    (m.Groups["url"].Value, MdStyle.Link);
                if (style == MdStyle.Code || style == MdStyle.Link && m.Groups["url"].Success) Emit(sb, inner, outer | style, raw: true);
                else if (style is MdStyle.Bold or MdStyle.Italic or MdStyle.Strike) Inline(sb, inner, outer | style); // **a *b* c**
                else Emit(sb, inner, outer | style);
                pos = m.Index + m.Length;
            }
            if (pos < text.Length) Emit(sb, text[pos..], outer);
        }

        void Emit(StringBuilder sb, string text, MdStyle style, bool raw = false)
        {
            var t = (raw ? text : MarkdownText.InlineToPlain(text)).Replace('\n', ' ');
            if (t.Length == 0) return;
            if (style != MdStyle.None) spans.Add(new MdSpan(sb.Length, t.Length, style));
            sb.Append(t);
        }

        for (var i = 0; i < raw.Length; i++)
        {
            var line = raw[i];
            if (Fence.IsMatch(line)) { inCode = !inCode; continue; }
            if (inCode) { AddLine(MdLineKind.Code, 0, sb => sb.Append(line.TrimEnd())); continue; }
            if (LinkDef.IsMatch(line) || Rule.IsMatch(line) || TableSep.IsMatch(line)) continue;
            // "Title" underlined with ===== (or ---) on the next line: a heading
            if (i + 1 < raw.Length && line.Trim().Length > 0 && Setext.IsMatch(raw[i + 1]) && !Bullet.IsMatch(line))
            {
                var level = raw[i + 1].TrimStart().StartsWith('=') ? 1 : 2;
                AddLine(MdLineKind.Heading, level, sb => Inline(sb, line.Trim()));
                i++;
                continue;
            }
            Match m;
            if ((m = TableRow.Match(line)).Success)
            {
                var cells = string.Join(", ", m.Groups[1].Value.Split('|').Select(c => c.Trim()).Where(c => c.Length > 0));
                AddLine(MdLineKind.Table, 0, sb => Inline(sb, cells));
            }
            else if ((m = Heading.Match(line)).Success)
                AddLine(MdLineKind.Heading, m.Groups[1].Length, sb => Inline(sb, m.Groups[2].Value));
            else if ((m = Quote.Match(line)).Success)
                AddLine(MdLineKind.Quote, 0, sb => Inline(sb, m.Groups[2].Value));
            else if ((m = Bullet.Match(line)).Success)
                AddLine(MdLineKind.Bullet, Indent(m.Groups[1].Value), sb => Inline(sb, m.Groups[2].Value));
            else if ((m = Number.Match(line)).Success)
                // The number stays in the text (it is read out: "1. First step").
                AddLine(MdLineKind.Numbered, Indent(m.Groups[1].Value), sb => { sb.Append(m.Groups[2].Value).Append(' '); Inline(sb, m.Groups[3].Value); });
            else
                AddLine(MdLineKind.Paragraph, 0, sb => Inline(sb, line.Trim()));
        }

        // Drop trailing blank lines and the final line break.
        while (lines.Count > 0 && lines[^1].Length == 0) { plain.Length = lines[^1].Start; lines.RemoveAt(lines.Count - 1); }
        if (plain.Length > 0 && plain[^1] == '\n') plain.Length--;
        return new MarkdownDoc(plain.ToString(), lines, spans);
    }

    static int Indent(string ws) => Math.Min(4, ws.Replace("\t", "    ").Length / 2);

    /// <summary>The line holding position <paramref name="pos"/> of <see cref="Plain"/>.</summary>
    public MdLine? LineAt(int pos)
    {
        int lo = 0, hi = Lines.Count - 1;
        while (lo <= hi)
        {
            var mid = (lo + hi) / 2;
            var l = Lines[mid];
            if (pos < l.Start) hi = mid - 1;
            else if (pos > l.Start + l.Length) lo = mid + 1;
            else return l;
        }
        return null;
    }

    /// <summary>The inline style at <paramref name="pos"/>.</summary>
    public MdStyle StyleAt(int pos)
    {
        var style = MdStyle.None;
        foreach (var s in Spans)
        {
            if (s.Start > pos) break;
            if (pos < s.Start + s.Length) style |= s.Style;
        }
        return style;
    }
}
