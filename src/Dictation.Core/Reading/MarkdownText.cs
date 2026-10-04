using System.Text.RegularExpressions;

namespace Dictation.Core.Reading;

/// <summary>
/// Read aloud gets a lot of Markdown (from chat assistants, READMEs, notes apps). Read as is, the voice says
/// "hash hash", "asterisk" and whole URLs. When text clearly is Markdown it is turned into the plain text a reader
/// would see; anything else is left alone, so a stray asterisk or "#1" in ordinary text is never touched.
/// </summary>
public static class MarkdownText
{
    static readonly RegexOptions M = RegexOptions.Multiline;

    // Strong signs: hardly ever found outside Markdown.
    static readonly Regex Heading = new(@"^ {0,3}#{1,6}[ \t]+\S", M);
    static readonly Regex Fence = new(@"^ {0,3}(```|~~~)", M);
    static readonly Regex Link = new(@"!?\[[^\]\n]+\]\([^)\s]+(?:\s+""[^""]*"")?\)");
    static readonly Regex TableRule = new(@"^ {0,3}\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$", M);
    static readonly Regex Bold = new(@"(\*\*|__)(?=\S)[^\n]+?(?<=\S)\1");

    // Weak signs: common in Markdown, but plain text has them too.
    static readonly Regex Bullet = new(@"^ {0,3}[-*+][ \t]+\S", M);
    static readonly Regex Code = new(@"`[^`\n]+`");
    static readonly Regex Quote = new(@"^ {0,3}>[ \t]?\S", M);
    static readonly Regex Italic = new(@"(?<![\w*])\*(?=\S)[^*\n]+?(?<=\S)\*(?![\w*])");

    /// <summary>True when the text has a strong Markdown sign, or two different weak ones.</summary>
    public static bool LooksLikeMarkdown(string text)
    {
        if (Heading.IsMatch(text) || Fence.IsMatch(text) || Link.IsMatch(text) || TableRule.IsMatch(text) || Bold.IsMatch(text))
            return true;
        var weak = 0;
        foreach (var r in new[] { Bullet, Code, Quote, Italic })
            if (r.IsMatch(text)) weak++;
        return weak >= 2;
    }

    /// <summary>Plain text for reading aloud: <paramref name="text"/> unchanged unless it looks like Markdown.</summary>
    public static string ForReading(string text) => LooksLikeMarkdown(text) ? ToPlain(text) : text;

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
        s = Regex.Replace(s, @"^ {0,3}#{1,6}[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$", "$1", M);
        // Setext heading underlines ("Title" followed by "=====")
        s = Regex.Replace(s, @"^ {0,3}=+[ \t]*$\n?", "", M);
        // Block quotes, then list markers and task boxes
        s = Regex.Replace(s, @"^([ \t]*>)+[ \t]?", "", M);
        s = Regex.Replace(s, @"^([ \t]*)[-*+][ \t]+(\[[ xX]\][ \t]+)?", "$1", M);

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

        // A few HTML bits that turn up in Markdown, and backslash escapes
        s = Regex.Replace(s, @"<br\s*/?>", "\n", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"</?(sup|sub|kbd|em|strong|b|i|u|span|details|summary)\b[^>]*>", "", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"\\([\\`*_{}\[\]()#+\-.!|>~])", "$1");

        // Tidy: no trailing spaces, at most one blank line in a row
        s = Regex.Replace(s, @"[ \t]+$", "", M);
        s = Regex.Replace(s, @"\n{3,}", "\n\n");
        return s.Trim();
    }
}
