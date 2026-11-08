using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json.Nodes;
using Dictation.Core.Infrastructure;

namespace Dictation.Core.Setup;

/// <param name="Sha256">The installer's SHA-256 as GitHub publishes it with the release (the asset's digest); null when
/// GitHub gave none.</param>
/// <param name="Sha256Url">Otherwise, the release's own checksum file for the installer (&lt;installer&gt;.sha256).</param>
public sealed record UpdateInfo(Version Version, string Tag, string InstallerUrl, string InstallerName, long Size, string PageUrl, string Notes,
    string? Sha256 = null, string? Sha256Url = null);

/// <summary>
/// Checks GitHub Releases for a newer version and installs it. Only contacts GitHub when the user clicks
/// "Check for updates", or at startup if they enabled that option. Sends nothing but a plain request for the
/// public release list. The installer is run only if its SHA-256 is the one published with the release (releases are
/// not code-signed, so there is no Authenticode signature to check).
/// </summary>
public sealed class UpdateService
{
    readonly HttpClient _http = new() { Timeout = TimeSpan.FromMinutes(30) };

    public UpdateService()
    {
        _http.DefaultRequestHeaders.UserAgent.ParseAdd($"LocalDictation/{AppInfo.VersionText}");
        _http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
    }

    public static Version? ParseTag(string? tag)
    {
        if (string.IsNullOrWhiteSpace(tag)) return null;
        var core = tag.Trim().TrimStart('v', 'V').Split('-', '+')[0];
        return Version.TryParse(core, out var v) ? Normalize(v) : null;
    }

    static Version Normalize(Version v) => new(v.Major, v.Minor, Math.Max(0, v.Build));

    /// <summary>Returns the newer release, or null if this copy is up to date.</summary>
    public async Task<UpdateInfo?> CheckAsync(CancellationToken ct = default)
    {
        JsonObject? json;
        try
        {
            using var resp = await _http.GetAsync($"https://api.github.com/repos/{AppInfo.Repository}/releases/latest", ct);
            if (resp.StatusCode == HttpStatusCode.NotFound) return null; // no releases published yet
            resp.EnsureSuccessStatusCode();
            json = await resp.Content.ReadFromJsonAsync<JsonObject>(cancellationToken: ct);
        }
        catch (HttpRequestException e)
        {
            throw new UserFacingException("Couldn't reach GitHub to check for updates. Check your internet connection.", e);
        }
        return FromRelease(json, AppInfo.Version);
    }

    /// <summary>The update a release (GitHub's JSON for it) offers over <paramref name="current"/>; null when it is not
    /// newer, or has no installer on GitHub.</summary>
    internal static UpdateInfo? FromRelease(JsonObject? json, Version current)
    {
        var tag = json?["tag_name"]?.GetValue<string>();
        var latest = ParseTag(tag);
        if (latest == null || latest <= Normalize(current)) return null;

        var asset = json!["assets"]?.AsArray()
            .Select(a => a!.AsObject())
            .FirstOrDefault(a => a["name"]!.GetValue<string>().EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                                 && a["name"]!.GetValue<string>().Contains("Setup", StringComparison.OrdinalIgnoreCase));
        if (asset == null) return null; // release exists but its installer isn't uploaded yet

        var url = asset["browser_download_url"]!.GetValue<string>();
        if (!OnGitHub(url))
        {
            Log.Warn("Update: the installer link is not on GitHub; ignored");
            return null;
        }
        var name = asset["name"]!.GetValue<string>();
        // The installer's SHA-256: GitHub's digest of the asset ("sha256:…"), else the release's <installer>.sha256.
        var digest = Checksum.Normalize(asset["digest"]?.GetValue<string>());
        var sums = json["assets"]!.AsArray().Select(a => a!.AsObject())
            .FirstOrDefault(a => string.Equals(a["name"]?.GetValue<string>(), name + ".sha256", StringComparison.OrdinalIgnoreCase))
            ?["browser_download_url"]?.GetValue<string>();
        return new UpdateInfo(latest, tag!, url, name,
            asset["size"]?.GetValue<long>() ?? 0, json["html_url"]?.GetValue<string>() ?? AppInfo.RepositoryUrl + "/releases",
            json["body"]?.GetValue<string>() ?? "", digest, sums != null && OnGitHub(sums) ? sums : null);
    }

    /// <summary>Only the places GitHub serves release assets from, over TLS: a release list pointing anywhere else is not
    /// followed.</summary>
    static bool OnGitHub(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps
        && uri.Host is "github.com" or "objects.githubusercontent.com" or "release-assets.githubusercontent.com";

    public async Task<string> DownloadAsync(UpdateInfo info, IProgress<double> progress, CancellationToken ct = default)
    {
        var dir = Path.Combine(Path.GetTempPath(), "LocalDictation-update");
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, info.InstallerName);
        try
        {
            using var resp = await _http.GetAsync(info.InstallerUrl, HttpCompletionOption.ResponseHeadersRead, ct);
            resp.EnsureSuccessStatusCode();
            var total = resp.Content.Headers.ContentLength ?? info.Size;
            await using var src = await resp.Content.ReadAsStreamAsync(ct);
            await using var dst = File.Create(path);
            var buf = new byte[1 << 16];
            long done = 0;
            int n;
            while ((n = await src.ReadAsync(buf, ct)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n), ct);
                done += n;
                if (total > 0) progress.Report((double)done / total);
            }
        }
        catch (HttpRequestException e)
        {
            throw new UserFacingException("Downloading the update failed. Check your internet connection and try again.", e);
        }
        // A truncated or substituted download is not run.
        if (info.Size > 0 && new FileInfo(path).Length != info.Size)
        {
            Discard(path);
            throw new UserFacingException("The downloaded installer is not the size the release lists, so it was not run. Try again.");
        }
        string? expected;
        try { expected = info.Sha256 ?? await PublishedSumAsync(info, ct); }
        catch { Discard(path); throw; } // not checked: not kept
        if (expected == null)
        {
            Discard(path);
            throw new UserFacingException("This release doesn't publish a checksum for its installer, so the download couldn't be " +
                                          "checked and was not run. Download it from the release page instead.");
        }
        var actual = await Task.Run(() => Checksum.Sha256(path), ct);
        if (actual != expected)
        {
            Discard(path);
            Log.Warn($"Update: {info.InstallerName} has SHA-256 {actual}, the release lists {expected}; deleted, not run");
            throw new UserFacingException("The downloaded installer isn't the one the release published (its checksum doesn't " +
                                          "match), so it was deleted and not run. Try again; if this keeps happening, download it from the release page.");
        }
        Log.Info($"Update: {info.InstallerName} matches the release's SHA-256");
        return path;
    }

    /// <summary>The installer's hash from the release's own checksum file; null when there is none.</summary>
    async Task<string?> PublishedSumAsync(UpdateInfo info, CancellationToken ct)
    {
        if (info.Sha256Url == null) return null;
        try { return Checksum.FromSumsFile(await _http.GetStringAsync(info.Sha256Url, ct), info.InstallerName); }
        catch (HttpRequestException e)
        {
            throw new UserFacingException("Couldn't download the update's checksum to check the installer. Check your internet connection and try again.", e);
        }
    }

    static void Discard(string path)
    {
        try { File.Delete(path); } catch (Exception e) { Log.Warn("Update: couldn't delete the downloaded installer: " + e.Message); }
    }

    /// <summary>Start the installer in silent mode. It closes this app, replaces the program files
    /// (settings, models and runtimes are kept) and starts the new version.</summary>
    public static void LaunchInstaller(string path)
    {
        Log.Info($"Launching update installer {Path.GetFileName(path)}");
        Process.Start(new ProcessStartInfo(path, "/SILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS") { UseShellExecute = true });
    }
}
