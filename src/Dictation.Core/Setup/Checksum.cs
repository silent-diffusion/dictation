using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace Dictation.Core.Setup;

/// <summary>
/// SHA-256 checks for what Oberton downloads and then runs or unpacks (the update installer, the runtimes): a file is
/// used only if it is exactly the one its release published, not whatever arrived. Hashes are lower-case hex.
/// </summary>
public static class Checksum
{
    static readonly Regex Hex64 = new("^[0-9a-f]{64}$", RegexOptions.Compiled);
    static readonly Regex SumLine = new(@"^([0-9a-fA-F]{64})[ \t]+\*?(?:\./)?(.*?)[ \t\r]*$", RegexOptions.Compiled | RegexOptions.Multiline);

    /// <summary>The file's SHA-256.</summary>
    public static string Sha256(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexStringLower(SHA256.HashData(stream));
    }

    /// <summary>A hash as written somewhere (any case, perhaps "sha256:" first, as GitHub's asset digests are) in the
    /// form <see cref="Sha256"/> gives; null when it isn't a SHA-256.</summary>
    public static string? Normalize(string? hash)
    {
        var h = hash?.Trim().ToLowerInvariant();
        if (h == null) return null;
        if (h.StartsWith("sha256:", StringComparison.Ordinal)) h = h[7..];
        return Hex64.IsMatch(h) ? h : null;
    }

    /// <summary>Whether the file's SHA-256 is <paramref name="expected"/> (false when that isn't a SHA-256 at all).</summary>
    public static bool Matches(string path, string expected) =>
        Normalize(expected) is { } want && string.Equals(Sha256(path), want, StringComparison.Ordinal);

    /// <summary>The hash for <paramref name="fileName"/> in a checksum file ("&lt;hash&gt;  &lt;name&gt;" lines, as
    /// sha256sum writes them), or the file's content when that is only a hash; null when it has none for that file.</summary>
    public static string? FromSumsFile(string text, string fileName)
    {
        foreach (Match m in SumLine.Matches(text))
            if (string.Equals(Path.GetFileName(m.Groups[2].Value), fileName, StringComparison.OrdinalIgnoreCase))
                return m.Groups[1].Value.ToLowerInvariant();
        return Normalize(text); // just the hash, nothing else
    }
}
