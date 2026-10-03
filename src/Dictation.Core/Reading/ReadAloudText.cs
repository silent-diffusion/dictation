using System.Text.RegularExpressions;

namespace Dictation.Core.Reading;

/// <summary>A piece of the text being read, by position in the original string (for highlighting).</summary>
public readonly record struct TextSpan(int Start, int Length)
{
    public int End => Start + Length;
}

/// <summary>Splits text into pieces small enough to speak one at a time, at natural breaks.</summary>
public static class ReadAloudText
{
    /// <summary>Kokoro handles about 500 phonemes per call; this many characters stays well under that.</summary>
    public const int MaxPieceChars = 260;

    static readonly Regex SentenceEnd = new(@"(?<=[.!?…]+[""'”’)\]]*)\s+|\n\s*", RegexOptions.Compiled);
    static readonly Regex Spaces = new(@"\s+", RegexOptions.Compiled);

    /// <summary>Sentences (and lines, for lists and headings), with long ones broken at commas or spaces.
    /// Pieces without any letter or digit are skipped.</summary>
    public static List<TextSpan> Split(string text)
    {
        var spans = new List<TextSpan>();
        var start = 0;
        foreach (Match m in SentenceEnd.Matches(text))
        {
            AddPiece(text, start, m.Index, spans);
            start = m.Index + m.Length;
        }
        AddPiece(text, start, text.Length, spans);
        return spans;
    }

    static void AddPiece(string text, int start, int end, List<TextSpan> spans)
    {
        while (start < end && char.IsWhiteSpace(text[start])) start++;
        while (end > start && char.IsWhiteSpace(text[end - 1])) end--;
        while (end - start > MaxPieceChars)
        {
            var cut = BreakPoint(text, start, start + MaxPieceChars);
            AddIfSpoken(text, start, cut, spans);
            start = cut;
            while (start < end && char.IsWhiteSpace(text[start])) start++;
        }
        AddIfSpoken(text, start, end, spans);
    }

    /// <summary>Where to break an over-long sentence: after the last comma, semicolon, colon or dash, else the last space.</summary>
    static int BreakPoint(string text, int start, int limit)
    {
        for (var i = limit - 1; i > start + MaxPieceChars / 3; i--)
            if (text[i] is ',' or ';' or ':' or '—' or '–' && i + 1 < text.Length && char.IsWhiteSpace(text[i + 1])) return i + 1;
        var space = text.LastIndexOf(' ', limit - 1, limit - start);
        return space > start ? space : limit;
    }

    static void AddIfSpoken(string text, int start, int end, List<TextSpan> spans)
    {
        if (end <= start) return;
        for (var i = start; i < end; i++)
            if (char.IsLetterOrDigit(text[i])) { spans.Add(new TextSpan(start, end - start)); return; }
    }

    /// <summary>The words to send to the voice: the piece with its line breaks and runs of spaces collapsed.</summary>
    public static string Speakable(string text, TextSpan span) => Spaces.Replace(text.Substring(span.Start, span.Length), " ").Trim();

    /// <summary>Rough speaking time at normal speed, before the voice has produced the real audio.</summary>
    public static TimeSpan Estimate(int characters, double secondsPerChar = DefaultSecondsPerChar) =>
        TimeSpan.FromSeconds(characters * secondsPerChar);

    /// <summary>About 165 words a minute for typical English text.</summary>
    public const double DefaultSecondsPerChar = 0.066;
}
