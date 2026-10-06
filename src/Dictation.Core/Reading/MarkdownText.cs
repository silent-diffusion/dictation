using System.Text.RegularExpressions;

namespace Dictation.Core.Reading;

/// <summary>
/// Read aloud gets a lot of Markdown (from chat assistants, READMEs, notes apps). Read as is, the voice says
/// "hash hash", "asterisk" and whole URLs. Every text is turned into the plain text a reader would see. Guessing
/// whether a text "is Markdown" missed too often (a chat answer may have only a list and some bold), and the rules
/// are written so ordinary text comes through unchanged: "#1", "5*3" and snake_case names are left alone.
/// </summary>
public static class MarkdownText
{
    static readonly RegexOptions M = RegexOptions.Multiline;

    /// <summary>Plain text for reading aloud.</summary>
    public static string ForReading(string text) => ToPlain(text);

    /// <summary>Strip Markdown syntax, keeping the words and the line structure (one heading or item per line).</summary>
    public static string ToPlain(string text)
    {
        var s = text.Replace("\r\n", "\n");

        // Fence lines go; the code inside stays (it is still what the reader would see).
        s = Regex.Replace(s, @"^ {0,3}(```|~~~).*$\n?", "", M);
        // Link reference definitions: "[1]: https://..."
        s = Regex.Replace(s, @"^ {0,3}\[[^\]\n]+\]:\s*\S+.*$\n?", "", M);
        // Horizontal rules
        s = Regex.Replace(s, @"^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$", "", M);
        // Table separator rows go; cells become a comma-separated line.
        s = Regex.Replace(s, @"^ {0,3}\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$\n?", "", M);
        s = Regex.Replace(s, @"^ {0,3}\|(.*)\|[ \t]*$", m =>
            string.Join(", ", m.Groups[1].Value.Split('|').Select(c => c.Trim()).Where(c => c.Length > 0)), M);

        // Headings (and the optional closing hashes)
        s = Regex.Replace(s, @"^[ \t]*#{1,6}[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$", "$1", M);
        // Setext heading underlines ("Title" followed by "=====")
        s = Regex.Replace(s, @"^ {0,3}=+[ \t]*$\n?", "", M);
        // Block quotes, then list markers and task boxes
        s = Regex.Replace(s, @"^([ \t]*>)+[ \t]?", "", M);
        s = Regex.Replace(s, @"^([ \t]*)[-*+•◦▪‣][ \t]+(\[[ xX]\][ \t]+)?", "$1", M);

        s = InlineToPlain(s);

        // Tidy: no trailing spaces, at most one blank line in a row
        s = Regex.Replace(s, @"[ \t]+$", "", M);
        s = Regex.Replace(s, @"\n{3,}", "\n\n");
        return s.Trim();
    }

    /// <summary>The inline part of <see cref="ToPlain"/>: links, code, emphasis, stray symbols, HTML bits and escapes.
    /// Works on a whole text or on one piece of a line, and keeps surrounding spaces.</summary>
    public static string InlineToPlain(string s)
    {
        // Images and links keep their text; bare autolinks keep the address.
        s = Regex.Replace(s, @"!\[([^\]\n]*)\]\([^)\n]*\)", "$1");
        s = Regex.Replace(s, @"\[([^\]\n]+)\]\([^)\n]*\)", "$1");
        s = Regex.Replace(s, @"\[([^\]\n]+)\]\[[^\]\n]*\]", "$1");
        s = Regex.Replace(s, @"<((?:https?|mailto):[^>\s]+)>", "$1");

        // Inline code, then emphasis (bold before italic), strikethrough
        s = Regex.Replace(s, @"`+([^`\n]+?)`+", "$1");
        s = Regex.Replace(s, @"(\*\*|__)(?=\S)(.+?)(?<=\S)\1", "$2");
        s = Regex.Replace(s, @"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])", "$1");
        s = Regex.Replace(s, @"(?<![\w_])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])", "$1");
        s = Regex.Replace(s, @"~~(?=\S)(.+?)(?<=\S)~~", "$1");

        // Leftover symbols the voice would name: stray asterisks (not "5*3"), backticks, heading marks without a
        // space ("##Title"), table pipes and underline runs. Before escapes are resolved, so an escaped "\*" stays a star.
        s = Regex.Replace(s, @"(?<![\d\\])\*+|(?<!\\)\*+(?!\d)", "");
        s = s.Replace("`", "").Replace("~~", "");
        s = Regex.Replace(s, @"^[ \t]*#{1,6}(?=[A-Za-z])", "", M);
        s = Regex.Replace(s, @"[ \t]+\|[ \t]+", ", ");
        s = Regex.Replace(s, @"^[ \t]*\|[ \t]*|[ \t]*\|[ \t]*$", "", M);
        s = Regex.Replace(s, @"_{2,}", "");

        // A few HTML bits that turn up in Markdown, and backslash escapes
        s = Regex.Replace(s, @"<br\s*/?>", "\n", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"</?(sup|sub|kbd|em|strong|b|i|u|span|details|summary)\b[^>]*>", "", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"\\([\\`*_{}\[\]()#+\-.!|>~])", "$1");
        return s;
    }
}
