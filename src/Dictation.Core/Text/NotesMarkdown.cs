using System.Text;
using System.Text.RegularExpressions;

namespace Dictation.Core.Text;

public enum MdKind { Paragraph, Heading, Bullet, Numbered, Quote, Code, Rule, Marker }

/// <summary>A piece of a block's text. <paramref name="Offset"/> is where it starts in the source, so a click on the
/// rendered text can be taken back to the same place in the plain text. <paramref name="Break"/> is a line break.</summary>
public sealed record MdSpan(string Text, int Offset, bool Bold = false, bool Italic = false, bool Code = false, bool Break = false);

/// <param name="Level">A heading's level (1 to 6), or a list item's indent (0, 1, …).</param>
/// <param name="Number">A numbered item's number as written.</param>
public sealed record MdBlock(MdKind Kind, IReadOnlyList<MdSpan> Spans, int Offset, int Level = 0, string Number = "");

/// <summary>
/// The Markdown Extended Notes renders, for reading: headings, bullet and numbered lists, block quotes, code, rules,
/// **bold**, *italic* and `code`, links as their text, and the listener's ⚑ markers. A short label at the start of a
/// paragraph or a list item ("Main idea:", "Todo:") is shown in bold. Lines are kept as written (a line break is a
/// line break, as in a chat), since notes are typed line by line. The text itself stays plain; this only reads it.
/// </summary>
public static class NotesMarkdown
{
    static readonly Regex Heading = new(@"^(#{1,6})\s+(.*?)\s*#*\s*$", RegexOptions.Compiled);
    static readonly Regex Bullet = new(@"^(\s*)[-*+•]\s+(.*)$", RegexOptions.Compiled);
    static readonly Regex Numbered = new(@"^(\s*)(\d{1,3})[.)]\s+(.*)$", RegexOptions.Compiled);
    static readonly Regex Quote = new(@"^\s*>\s?(.*)$", RegexOptions.Compiled);
    static readonly Regex Rule = new(@"^\s*([-*_])(?:\s*\1){2,}\s*$", RegexOptions.Compiled);
    static readonly Regex Fence = new(@"^\s*```", RegexOptions.Compiled);
    static readonly Regex Label = new(@"^\p{Lu}[\p{L}'’]*(?:\s[\p{L}'’]+){0,3}:(?=\s|$)", RegexOptions.Compiled);

    public static List<MdBlock> Parse(string text)
    {
        var blocks = new List<MdBlock>();
        var para = new List<MdSpan>();
        var paraOffset = 0;
        var code = (List<MdSpan>?)null;
        var codeOffset = 0;
        var quote = new List<MdSpan>();
        var quoteOffset = 0;

        void EndParagraph()
        {
            if (para.Count > 0) blocks.Add(new MdBlock(MdKind.Paragraph, para.ToList(), paraOffset));
            para.Clear();
        }
        void EndQuote()
        {
            if (quote.Count > 0) blocks.Add(new MdBlock(MdKind.Quote, quote.ToList(), quoteOffset));
            quote.Clear();
        }

        var pos = 0;
        foreach (var rawLine in text.Split('\n'))
        {
            var lineStart = pos;
            pos += rawLine.Length + 1;
            var line = rawLine.TrimEnd('\r');

            if (code != null)
            {
                if (Fence.IsMatch(line))
                {
                    blocks.Add(new MdBlock(MdKind.Code, code.ToList(), codeOffset));
                    code = null;
                }
                else
                {
                    if (code.Count > 0) code.Add(new MdSpan("", lineStart, Break: true));
                    code.Add(new MdSpan(line, lineStart, Code: true));
                }
                continue;
            }
            if (Fence.IsMatch(line))
            {
                EndParagraph(); EndQuote();
                code = new List<MdSpan>();
                codeOffset = lineStart;
                continue;
            }
            if (line.Trim().Length == 0) { EndParagraph(); EndQuote(); continue; }

            var lead = line.Length - line.TrimStart().Length;
            if (line.TrimStart().StartsWith('⚑'))
            {
                EndParagraph(); EndQuote();
                blocks.Add(new MdBlock(MdKind.Marker, new[] { new MdSpan(line.Trim(), lineStart + lead) }, lineStart));
                continue;
            }
            if (Rule.IsMatch(line))
            {
                EndParagraph(); EndQuote();
                blocks.Add(new MdBlock(MdKind.Rule, Array.Empty<MdSpan>(), lineStart));
                continue;
            }
            if (Heading.Match(line) is { Success: true } h)
            {
                EndParagraph(); EndQuote();
                blocks.Add(new MdBlock(MdKind.Heading, Inline(h.Groups[2].Value, lineStart + h.Groups[2].Index), lineStart, h.Groups[1].Length));
                continue;
            }
            if (Bullet.Match(line) is { Success: true } b)
            {
                EndParagraph(); EndQuote();
                blocks.Add(new MdBlock(MdKind.Bullet, Labelled(b.Groups[2].Value, lineStart + b.Groups[2].Index), lineStart, b.Groups[1].Length / 2));
                continue;
            }
            if (Numbered.Match(line) is { Success: true } n)
            {
                EndParagraph(); EndQuote();
                blocks.Add(new MdBlock(MdKind.Numbered, Labelled(n.Groups[3].Value, lineStart + n.Groups[3].Index), lineStart,
                    n.Groups[1].Length / 2, n.Groups[2].Value));
                continue;
            }
            if (Quote.Match(line) is { Success: true } q)
            {
                EndParagraph();
                if (quote.Count == 0) quoteOffset = lineStart;
                else quote.Add(new MdSpan("", lineStart, Break: true));
                quote.AddRange(Inline(q.Groups[1].Value, lineStart + q.Groups[1].Index));
                continue;
            }
            EndQuote();
            if (para.Count == 0)
            {
                paraOffset = lineStart;
                para.AddRange(Labelled(line.Trim(), lineStart + lead));
            }
            else
            {
                para.Add(new MdSpan("", lineStart, Break: true));
                para.AddRange(Inline(line.Trim(), lineStart + lead));
            }
        }
        if (code != null) blocks.Add(new MdBlock(MdKind.Code, code, codeOffset));
        EndParagraph();
        EndQuote();
        return blocks;
    }

    /// <summary>A line whose start is a short label: the label in bold, then the rest.</summary>
    static List<MdSpan> Labelled(string s, int offset)
    {
        if (Label.Match(s) is { Success: true } m && !s.StartsWith("http", StringComparison.OrdinalIgnoreCase))
        {
            var spans = new List<MdSpan> { new(m.Value, offset, Bold: true) };
            spans.AddRange(Inline(s[m.Length..], offset + m.Length));
            return spans;
        }
        return Inline(s, offset);
    }

    /// <summary>The inline markup of a line: `code`, **bold** or __bold__, *italic* or _italic_, [text](link) as its
    /// text, and backslash escapes. Markup that doesn't close is shown as written.</summary>
    public static List<MdSpan> Inline(string s, int offset, bool bold = false, bool italic = false)
    {
        var spans = new List<MdSpan>();
        var plain = new StringBuilder();
        var plainStart = 0;
        void Flush(int at)
        {
            if (plain.Length > 0) spans.Add(new MdSpan(plain.ToString(), offset + plainStart, bold, italic));
            plain.Clear();
            plainStart = at;
        }
        var i = 0;
        while (i < s.Length)
        {
            var c = s[i];
            if (c == '\\' && i + 1 < s.Length && "\\`*_[]()#+-.!>".Contains(s[i + 1]))
            {
                if (plain.Length == 0) plainStart = i + 1;
                plain.Append(s[i + 1]);
                i += 2;
                continue;
            }
            if (c == '`' && s.IndexOf('`', i + 1) is var close and > 0)
            {
                Flush(i);
                spans.Add(new MdSpan(s[(i + 1)..close], offset + i + 1, bold, italic, Code: true));
                i = close + 1;
                plainStart = i;
                continue;
            }
            if ((c == '*' || c == '_') && i + 1 < s.Length && s[i + 1] == c && Closing(s, i + 2, new string(c, 2)) is var end2 and > 0)
            {
                Flush(i);
                spans.AddRange(Inline(s[(i + 2)..end2], offset + i + 2, true, italic));
                i = end2 + 2;
                plainStart = i;
                continue;
            }
            if ((c == '*' || c == '_') && (c == '*' || i == 0 || !char.IsLetterOrDigit(s[i - 1])) &&
                Closing(s, i + 1, c.ToString()) is var end1 and > 0 && (c == '*' || end1 + 1 >= s.Length || !char.IsLetterOrDigit(s[end1 + 1])))
            {
                Flush(i);
                spans.AddRange(Inline(s[(i + 1)..end1], offset + i + 1, bold, true));
                i = end1 + 1;
                plainStart = i;
                continue;
            }
            if (c == '[' && s.IndexOf("](", i + 1, StringComparison.Ordinal) is var mid and > 0 && s.IndexOf(')', mid + 2) is var paren and > 0)
            {
                Flush(i);
                spans.AddRange(Inline(s[(i + 1)..mid], offset + i + 1, bold, italic));
                i = paren + 1;
                plainStart = i;
                continue;
            }
            if (plain.Length == 0) plainStart = i;
            plain.Append(c);
            i++;
        }
        Flush(s.Length);
        return spans;
    }

    /// <summary>Where the marker that closes an emphasis starting at <paramref name="from"/> is: the content must not begin
    /// or end with a space, and not be empty. -1 when there is none.</summary>
    static int Closing(string s, int from, string marker)
    {
        if (from >= s.Length || char.IsWhiteSpace(s[from])) return -1;
        var at = s.IndexOf(marker, from + 1, StringComparison.Ordinal);
        while (at > 0)
        {
            if (!char.IsWhiteSpace(s[at - 1]) && (marker.Length == 2 || at + 1 >= s.Length || s[at + 1] != marker[0])) return at;
            at = s.IndexOf(marker, at + 1, StringComparison.Ordinal);
        }
        return -1;
    }
}
