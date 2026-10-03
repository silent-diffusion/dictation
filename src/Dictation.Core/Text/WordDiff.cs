namespace Dictation.Core.Text;

public enum DiffKind { Same, Removed, Added }

/// <summary>One word of a diff. Same and Added words carry the edited text's spelling, so reading only those
/// gives back the edited text; Removed words carry the original's.</summary>
public readonly record struct DiffToken(string Word, DiffKind Kind);

/// <summary>Word-level diff between a raw transcript and the AI's edit, used to show what the cleanup changed.</summary>
public static class WordDiff
{
    /// <summary>Larger inputs skip the diff (it is quadratic) and come back as unchanged edited text.</summary>
    const long MaxCells = 400_000;

    public static IReadOnlyList<DiffToken> Compute(string original, string edited)
    {
        var a = Split(original);
        var b = Split(edited);
        if ((long)a.Length * b.Length > MaxCells)
            return b.Select(w => new DiffToken(w, DiffKind.Same)).ToList();

        var na = a.Select(Normalize).ToArray();
        var nb = b.Select(Normalize).ToArray();

        // lcs[i, j] = length of the longest common subsequence of a[i..] and b[j..]
        var lcs = new int[a.Length + 1, b.Length + 1];
        for (var i = a.Length - 1; i >= 0; i--)
            for (var j = b.Length - 1; j >= 0; j--)
                lcs[i, j] = na[i] == nb[j] ? lcs[i + 1, j + 1] + 1 : Math.Max(lcs[i + 1, j], lcs[i, j + 1]);

        var result = new List<DiffToken>(a.Length + b.Length);
        int x = 0, y = 0;
        while (x < a.Length || y < b.Length)
        {
            if (x < a.Length && y < b.Length && na[x] == nb[y])
            {
                result.Add(new DiffToken(b[y], DiffKind.Same));
                x++; y++;
            }
            else if (y >= b.Length || (x < a.Length && lcs[x + 1, y] >= lcs[x, y + 1]))
                result.Add(new DiffToken(a[x++], DiffKind.Removed));
            else
                result.Add(new DiffToken(b[y++], DiffKind.Added));
        }
        return result;
    }

    /// <summary>True when the edit changed anything beyond capitalization and punctuation.</summary>
    public static bool HasChanges(IReadOnlyList<DiffToken> diff) => diff.Any(t => t.Kind != DiffKind.Same);

    static string[] Split(string s) => s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    /// <summary>Compare words ignoring case and surrounding punctuation, so "so" and "So," count as the same word.</summary>
    static string Normalize(string w)
    {
        var t = w.Trim().Trim('.', ',', ';', ':', '!', '?', '"', '\'', '“', '”', '‘', '’', '(', ')', '…', '-', '—');
        return (t.Length == 0 ? w : t).ToLowerInvariant();
    }
}
