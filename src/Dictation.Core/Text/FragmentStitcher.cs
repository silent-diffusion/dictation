using System.Text;
using System.Text.RegularExpressions;

namespace Dictation.Core.Text;

/// <summary>
/// Joins the pieces that live dictation transcribes one at a time (about every 5 seconds) into one text, without the
/// AI. Each piece is transcribed on its own, so its seams show the usual artifacts: a piece cut mid-sentence still
/// starts with a capital ("…went to the | Store and…"), one cut at a pause may end in a full stop that isn't one
/// ("…the store. | and bought…"), and a word said across the cut can come out twice ("…the | the store…").
/// </summary>
public static class FragmentStitcher
{
    /// <summary>Words that are lowercase mid-sentence. A capitalized word at a cut is lowercased only if it is one of
    /// these, or appears lowercase elsewhere in the dictation; anything else might be a name, so it keeps its capital.</summary>
    static readonly HashSet<string> CommonWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "a", "an", "the", "and", "but", "or", "nor", "so", "yet", "for", "because", "if", "then", "than", "that", "this",
        "these", "those", "which", "who", "whom", "whose", "what", "when", "where", "while", "why", "how", "as", "at",
        "by", "from", "in", "into", "of", "on", "onto", "to", "with", "without", "about", "after", "before", "over",
        "under", "up", "down", "out", "off", "through", "between", "during", "since", "until", "it", "its", "it's",
        "we", "you", "he", "she", "they", "them", "us", "him", "her", "his", "our", "your", "their", "my", "me",
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "have", "has", "had", "will",
        "would", "can", "could", "should", "shall", "may", "might", "must", "not", "no", "yes", "also", "just",
        "really", "very", "maybe", "probably", "actually", "basically", "like", "well", "now", "there", "here",
        "some", "any", "all", "each", "every", "both", "either", "neither", "more", "most", "much", "many", "other",
        "another", "such", "only", "even", "still", "again", "too", "already", "though", "although", "unless",
        "whether", "get", "got", "go", "going", "make", "made", "say", "said", "think", "know", "want", "need",
        "one", "two", "three", "first", "next", "last", "new", "good", "lot", "thing", "things", "way", "time",
    };

    static readonly HashSet<string> Abbreviations = new(StringComparer.OrdinalIgnoreCase)
    {
        "e.g.", "i.e.", "etc.", "vs.", "mr.", "mrs.", "ms.", "dr.", "st.", "no.", "approx.", "a.m.", "p.m.",
    };

    /// <summary>Join pieces transcribed separately, in order, fixing what the cuts between them broke.</summary>
    public static string Join(IEnumerable<string> pieces)
    {
        var list = pieces.ToList();
        var everything = string.Join(" ", list);
        var sb = new StringBuilder();
        foreach (var raw in list)
        {
            var piece = Regex.Replace(raw, @"[ \t]+", " ").Trim();
            if (piece.Length == 0) continue;
            if (sb.Length == 0) { sb.Append(piece); continue; }

            var before = sb.ToString();
            piece = DropRepeatedWord(before, piece);
            if (piece.Length == 0) continue;

            var last = LastMeaningfulChar(before);
            if (char.IsLetterOrDigit(last) || last is ',' or ';' or '-' or '—' or '–')
            {
                // Cut mid-sentence: the next piece continues it.
                if (LowercaseAtCut(piece, everything)) piece = char.ToLower(piece[0]) + piece[1..];
            }
            else if (last == '.' && char.IsLower(FirstLetter(piece)) && !EndsWithAbbreviationOrEllipsis(before))
            {
                // A full stop the recognizer added at the cut, before words that clearly continue the sentence.
                sb.Length = before.TrimEnd().Length;
                if (sb[^1] == '.') sb.Length--;
            }
            sb.Append(' ').Append(piece);
        }
        return Tidy(sb.ToString());
    }

    static bool LowercaseAtCut(string piece, string everything)
    {
        var word = Regex.Match(piece, @"^[\p{L}']+").Value;
        if (word.Length < 1 || !char.IsUpper(word[0]) || word.Skip(1).Any(char.IsUpper)) return false; // NASA, iPhone
        if (word == "I" || word.StartsWith("I'")) return false;
        var lower = char.ToLower(word[0]) + word[1..];
        return CommonWords.Contains(word) || Regex.IsMatch(everything, @"\b" + Regex.Escape(lower) + @"\b");
    }

    /// <summary>Spacing around punctuation, and a capital at the very start.</summary>
    public static string Tidy(string text)
    {
        var s = Regex.Replace(text, @"[ \t]+", " ");
        s = Regex.Replace(s, @" +([,.!?;:])", "$1");
        s = s.Trim();
        if (s.Length > 0 && char.IsLower(s[0])) s = char.ToUpper(s[0]) + s[1..];
        return s;
    }

    /// <summary>"…the" + "the store" → "store": the same word on both sides of a cut was said once.</summary>
    static string DropRepeatedWord(string before, string piece)
    {
        var lastWord = Regex.Match(before, @"([\p{L}\p{N}']+)\W*$").Groups[1].Value;
        var first = Regex.Match(piece, @"^([\p{L}\p{N}']+)\b[,]?\s*");
        if (lastWord.Length == 0 || !first.Success) return piece;
        // Only when nothing ends the sentence in between ("…the. The…" is two sentences).
        if (Regex.IsMatch(before, @"[.!?]\W*$")) return piece;
        return string.Equals(lastWord, first.Groups[1].Value, StringComparison.OrdinalIgnoreCase) ? piece[first.Length..] : piece;
    }

    static char LastMeaningfulChar(string s)
    {
        var t = s.TrimEnd().TrimEnd('"', '\'', '”', '’', ')');
        return t.Length == 0 ? '\0' : t[^1];
    }

    static char FirstLetter(string s) => s.FirstOrDefault(char.IsLetter);

    static bool EndsWithAbbreviationOrEllipsis(string s)
    {
        var t = s.TrimEnd();
        if (t.EndsWith("..") || t.EndsWith('…')) return true;
        var lastToken = t[(t.LastIndexOf(' ') + 1)..];
        return Abbreviations.Contains(lastToken) || Regex.IsMatch(lastToken, @"^(?:\p{L}\.){2,}$"); // U.S.
    }
}
