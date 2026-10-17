namespace Dictation.Core.Text;

/// <summary>
/// Word diff for long texts (an hour of notes is ten thousand words): Myers' O(N·D) algorithm, which is fast when the
/// two texts are mostly alike, after trimming what they share at both ends. Same output shape as <see cref="WordDiff"/>:
/// Same and Added carry the edited text's spelling, Removed the original's. Words compare ignoring case and the
/// punctuation around them.
/// </summary>
public static class LongDiff
{
    /// <summary>Beyond this many differences the middle is reported as replaced wholesale (it would cost too much).</summary>
    const int MaxEdits = 6000;

    public static IReadOnlyList<DiffToken> Compute(string original, string edited) =>
        Compute(Split(original), Split(edited));

    public static IReadOnlyList<DiffToken> Compute(IReadOnlyList<string> a, IReadOnlyList<string> b)
    {
        var na = a.Select(Normalize).ToArray();
        var nb = b.Select(Normalize).ToArray();
        var result = new List<DiffToken>(a.Count + b.Count);

        var start = 0;
        while (start < na.Length && start < nb.Length && na[start] == nb[start]) result.Add(new DiffToken(b[start++], DiffKind.Same));
        var endA = na.Length;
        var endB = nb.Length;
        var tail = new List<DiffToken>();
        while (endA > start && endB > start && na[endA - 1] == nb[endB - 1])
        {
            endA--;
            endB--;
            tail.Add(new DiffToken(b[endB], DiffKind.Same));
        }

        var middle = new List<DiffToken>();
        try { Middle(a, b, na, nb, start, endA, start, endB, middle); }
        catch (IndexOutOfRangeException) { middle.Clear(); }
        catch (ArgumentOutOfRangeException) { middle.Clear(); }
        // The edit script must give back both texts exactly; if it doesn't (a corner case of the walk-back), report the
        // middle as replaced rather than show a wrong diff.
        if (!Reproduces(middle, na, nb, start, endA, endB))
        {
            middle.Clear();
            for (var i = start; i < endA; i++) middle.Add(new DiffToken(a[i], DiffKind.Removed));
            for (var j = start; j < endB; j++) middle.Add(new DiffToken(b[j], DiffKind.Added));
        }
        result.AddRange(middle);
        tail.Reverse();
        result.AddRange(tail);
        return result;
    }

    static bool Reproduces(List<DiffToken> middle, string[] na, string[] nb, int start, int endA, int endB)
    {
        int i = start, j = start;
        foreach (var t in middle)
        {
            var w = Normalize(t.Word);
            switch (t.Kind)
            {
                case DiffKind.Same:
                    if (i >= endA || j >= endB || na[i] != nb[j] || nb[j] != w) return false;
                    i++; j++;
                    break;
                case DiffKind.Removed:
                    if (i >= endA || na[i] != w) return false;
                    i++;
                    break;
                default:
                    if (j >= endB || nb[j] != w) return false;
                    j++;
                    break;
            }
        }
        return i == endA && j == endB;
    }

    static void Middle(IReadOnlyList<string> a, IReadOnlyList<string> b, string[] na, string[] nb,
        int a0, int a1, int b0, int b1, List<DiffToken> output)
    {
        int n = a1 - a0, m = b1 - b0;
        if (n == 0) { for (var j = b0; j < b1; j++) output.Add(new DiffToken(b[j], DiffKind.Added)); return; }
        if (m == 0) { for (var i = a0; i < a1; i++) output.Add(new DiffToken(a[i], DiffKind.Removed)); return; }

        var max = Math.Min(n + m, MaxEdits);
        var offset = max + 1;
        var v = new int[2 * max + 3];
        var trace = new List<int[]>();
        var found = -1;
        for (var d = 0; d <= max && found < 0; d++)
        {
            // Keep only the diagonals reachable at this step: about D² ints in all.
            var snapshot = new int[2 * d + 1];
            for (var k = -d; k <= d; k += 2)
            {
                int x;
                if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) x = v[offset + k + 1];
                else x = v[offset + k - 1] + 1;
                var y = x - k;
                while (x < n && y < m && na[a0 + x] == nb[b0 + y]) { x++; y++; }
                v[offset + k] = x;
                if (x >= n && y >= m) found = d;
            }
            for (var k = -d; k <= d; k++) snapshot[k + d] = v[offset + k];
            trace.Add(snapshot);
        }

        if (found < 0)
        {
            // Too different to be worth the cost: report the middle as replaced.
            for (var i = a0; i < a1; i++) output.Add(new DiffToken(a[i], DiffKind.Removed));
            for (var j = b0; j < b1; j++) output.Add(new DiffToken(b[j], DiffKind.Added));
            return;
        }

        // Walk back through the snapshots to recover the edit script.
        var steps = new List<DiffToken>();
        int cx = n, cy = m;
        for (var d = found; d > 0; d--)
        {
            var prev = trace[d - 1];
            int At(int kk) => kk < -(d - 1) || kk > d - 1 ? -1 : prev[kk + d - 1];
            var k = cx - cy;
            var down = k == -d || (k != d && At(k - 1) < At(k + 1));
            var pk = down ? k + 1 : k - 1;
            var px = At(pk);
            var py = px - pk;
            while (cx > px + (down ? 0 : 1) && cy > py + (down ? 1 : 0))
            {
                steps.Add(new DiffToken(b[b0 + cy - 1], DiffKind.Same));
                cx--; cy--;
            }
            if (down) { steps.Add(new DiffToken(b[b0 + cy - 1], DiffKind.Added)); cy--; }
            else { steps.Add(new DiffToken(a[a0 + cx - 1], DiffKind.Removed)); cx--; }
        }
        while (cx > 0 && cy > 0) { steps.Add(new DiffToken(b[b0 + cy - 1], DiffKind.Same)); cx--; cy--; }
        steps.Reverse();
        output.AddRange(steps);
    }

    public static string[] Split(string s) => s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    static string Normalize(string w)
    {
        var t = w.Trim().Trim('.', ',', ';', ':', '!', '?', '"', '\'', '“', '”', '‘', '’', '(', ')', '…', '-', '—');
        return (t.Length == 0 ? w : t).ToLowerInvariant();
    }
}
