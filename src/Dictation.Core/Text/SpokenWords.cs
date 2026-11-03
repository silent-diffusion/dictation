using Dictation.Core.Speech;

namespace Dictation.Core.Text;

/// <summary>A word of a shown text that was matched to a heard word: where it is (its letters and digits, without the
/// punctuation or Markdown around it) and when it was said.</summary>
public readonly record struct SpokenWord(int Offset, int Length, double Start, double End);

/// <summary>
/// Where the heard words (<see cref="WordTiming"/>) are in a text as it is shown now, which may have been edited or
/// reworded since: the words of the text are lined up with the heard ones in order (case and punctuation ignored), and
/// each match takes its timing. Words with no match (typed in, changed, the AI's own) just have none. During playback,
/// <see cref="At"/> says which word is being said.
/// </summary>
public sealed class SpokenWords
{
    /// <summary>A word stays lit this long after it ends, so the light doesn't flicker off in the gaps between words.</summary>
    public const double Hold = 0.3;
    /// <summary>Above this many cells the line-up is first cut at words both texts have only once (it is quadratic).</summary>
    const long MaxCells = 4_000_000;

    public static readonly SpokenWords None = new(Array.Empty<SpokenWord>());

    /// <summary>The matched words, in the order of the text (and so of time).</summary>
    public IReadOnlyList<SpokenWord> Words { get; }

    SpokenWords(IReadOnlyList<SpokenWord> words) => Words = words;

    /// <param name="minRun">Only runs of at least this many words matched one after another count: 1 for a transcript
    /// or its tidied copy; more for a text that only borrows some phrases (a summary), where a single common word would
    /// light up wherever it happens to be said.</param>
    public static SpokenWords Map(string text, IReadOnlyList<WordTiming> heard, int minRun = 1)
    {
        if (string.IsNullOrEmpty(text) || heard.Count == 0) return None;
        var shown = Tokens(text);
        if (shown.Count == 0) return None;
        var heardKeys = new List<string>(heard.Count);
        var heardAt = new List<int>(heard.Count);
        for (var i = 0; i < heard.Count; i++)
        {
            var key = Key(heard[i].Text);
            if (key.Length == 0) continue;
            heardKeys.Add(key);
            heardAt.Add(i);
        }
        var a = shown.Select(t => t.Key).ToArray();
        var b = heardKeys.ToArray();
        var pairs = new List<(int A, int B)>();
        Match(a, 0, a.Length, b, 0, b.Length, pairs, 0);

        var words = new List<SpokenWord>(pairs.Count);
        for (var i = 0; i < pairs.Count;)
        {
            // A run: matched words next to each other in both texts.
            var j = i + 1;
            while (j < pairs.Count && pairs[j].A == pairs[j - 1].A + 1 && pairs[j].B == pairs[j - 1].B + 1) j++;
            if (j - i >= minRun)
                for (var k = i; k < j; k++)
                {
                    var t = shown[pairs[k].A];
                    var w = heard[heardAt[pairs[k].B]];
                    words.Add(new SpokenWord(t.Offset, t.Length, w.Start, w.End));
                }
            i = j;
        }
        return words.Count == 0 ? None : new SpokenWords(words);
    }

    /// <summary>The index in <see cref="Words"/> of the word being said at <paramref name="seconds"/>: the last one to
    /// have begun, while it lasts (and <see cref="Hold"/> after); -1 in a pause, before the first, or when none match.</summary>
    public int At(double seconds)
    {
        var words = Words;
        int lo = 0, hi = words.Count - 1, found = -1;
        // Matched in the text's order, which is the order they were said in, so their starts only go up.
        while (lo <= hi)
        {
            var mid = (lo + hi) / 2;
            if (words[mid].Start <= seconds) { found = mid; lo = mid + 1; }
            else hi = mid - 1;
        }
        if (found < 0) return -1;
        return seconds < words[found].End + Hold ? found : -1;
    }

    // ===== the words of a text =====

    readonly record struct Token(string Key, int Offset, int Length);

    /// <summary>The text's words (split at white space), each as its letters and digits, lower case, and the stretch
    /// from its first letter or digit to its last; tokens with none (a dash, a Markdown mark, "⚑") are left out.</summary>
    static List<Token> Tokens(string text)
    {
        var list = new List<Token>();
        var i = 0;
        while (i < text.Length)
        {
            while (i < text.Length && char.IsWhiteSpace(text[i])) i++;
            var start = i;
            while (i < text.Length && !char.IsWhiteSpace(text[i])) i++;
            int first = -1, last = -1;
            for (var k = start; k < i; k++)
                if (char.IsLetterOrDigit(text[k])) { if (first < 0) first = k; last = k; }
            if (first < 0) continue;
            list.Add(new Token(Key(text.AsSpan(first, last - first + 1)), first, last - first + 1));
        }
        return list;
    }

    /// <summary>A word as compared: lower case, letters and digits only ("Don't," and "dont" are the same word).</summary>
    public static string Key(ReadOnlySpan<char> word)
    {
        Span<char> buffer = word.Length <= 64 ? stackalloc char[word.Length] : new char[word.Length];
        var n = 0;
        foreach (var c in word)
            if (char.IsLetterOrDigit(c)) buffer[n++] = char.ToLowerInvariant(c);
        return new string(buffer[..n]);
    }

    public static string Key(string word) => Key(word.AsSpan());

    // ===== lining up two lists of words =====

    /// <summary>The pairs (in order) of a longest run of words the two share, in a[a0..a1) and b[b0..b1). What both begin
    /// and end with is matched first; a small middle is lined up exactly; a large one is first cut at the words each
    /// has only once (taken in the longest order both agree on), and each piece between them lined up the same way.</summary>
    static void Match(string[] a, int a0, int a1, string[] b, int b0, int b1, List<(int A, int B)> pairs, int depth)
    {
        while (a0 < a1 && b0 < b1 && a[a0] == b[b0]) pairs.Add((a0++, b0++));
        var ends = new List<(int, int)>();
        while (a0 < a1 && b0 < b1 && a[a1 - 1] == b[b1 - 1]) ends.Add((--a1, --b1));
        if (a0 < a1 && b0 < b1)
        {
            if ((long)(a1 - a0) * (b1 - b0) <= MaxCells) Lcs(a, a0, a1, b, b0, b1, pairs);
            else if (depth < 64 && Anchors(a, a0, a1, b, b0, b1) is { Count: > 0 } anchors)
            {
                var (pa, pb) = (a0, b0);
                foreach (var (x, y) in anchors)
                {
                    Match(a, pa, x, b, pb, y, pairs, depth + 1);
                    pairs.Add((x, y));
                    (pa, pb) = (x + 1, y + 1);
                }
                Match(a, pa, a1, b, pb, b1, pairs, depth + 1);
            }
            // else: too large, and no word to cut it at: that stretch stays unmatched.
        }
        ends.Reverse();
        pairs.AddRange(ends);
    }

    /// <summary>Words found exactly once in each stretch, as pairs, kept in the longest order both agree on.</summary>
    static List<(int A, int B)> Anchors(string[] a, int a0, int a1, string[] b, int b0, int b1)
    {
        var inA = new Dictionary<string, (int Count, int At)>();
        for (var i = a0; i < a1; i++) inA[a[i]] = inA.TryGetValue(a[i], out var c) ? (c.Count + 1, c.At) : (1, i);
        var inB = new Dictionary<string, (int Count, int At)>();
        for (var i = b0; i < b1; i++) inB[b[i]] = inB.TryGetValue(b[i], out var c) ? (c.Count + 1, c.At) : (1, i);
        var both = new List<(int A, int B)>();
        foreach (var (key, x) in inA)
            if (x.Count == 1 && inB.TryGetValue(key, out var y) && y.Count == 1) both.Add((x.At, y.At));
        both.Sort((p, q) => p.A.CompareTo(q.A));
        // The longest run of them whose places in b go up as well (patience sorting).
        var tops = new List<int>();       // tops[k]: index into both of the smallest end of a run of length k + 1
        var before = new int[both.Count];
        for (var i = 0; i < both.Count; i++)
        {
            int lo = 0, hi = tops.Count;
            while (lo < hi)
            {
                var mid = (lo + hi) / 2;
                if (both[tops[mid]].B < both[i].B) lo = mid + 1; else hi = mid;
            }
            before[i] = lo > 0 ? tops[lo - 1] : -1;
            if (lo == tops.Count) tops.Add(i); else tops[lo] = i;
        }
        var run = new List<(int A, int B)>(tops.Count);
        for (var i = tops.Count > 0 ? tops[^1] : -1; i >= 0; i = before[i]) run.Add(both[i]);
        run.Reverse();
        return run;
    }

    /// <summary>A longest common run of words, exactly (dynamic programming over the two stretches).</summary>
    static void Lcs(string[] a, int a0, int a1, string[] b, int b0, int b1, List<(int A, int B)> pairs)
    {
        int n = a1 - a0, m = b1 - b0, w = m + 1;
        // At most MaxCells cells, so no run is longer than 2,000 words: a short holds it.
        var lcs = new short[(n + 1) * w];
        for (var i = n - 1; i >= 0; i--)
            for (var j = m - 1; j >= 0; j--)
                lcs[i * w + j] = a[a0 + i] == b[b0 + j] ? (short)(lcs[(i + 1) * w + j + 1] + 1) : Math.Max(lcs[(i + 1) * w + j], lcs[i * w + j + 1]);
        int x = 0, y = 0;
        while (x < n && y < m)
        {
            if (a[a0 + x] == b[b0 + y]) { pairs.Add((a0 + x, b0 + y)); x++; y++; }
            else if (lcs[(x + 1) * w + y] >= lcs[x * w + y + 1]) x++;
            else y++;
        }
    }
}
