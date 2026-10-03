using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json.Nodes;
using Dictation.Core.Infrastructure;

namespace Dictation.Core.Setup;

public sealed record UpdateInfo(Version Version, string Tag, string InstallerUrl, string InstallerName, long Size, string PageUrl, string Notes);

/// <summary>
/// Checks GitHub Releases for a newer version and installs it. Only contacts GitHub when the user clicks
/// "Check for updates", or at startup if they enabled that option. Sends nothing but a plain request for the
/// public release list.
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

        var tag = json?["tag_name"]?.GetValue<string>();
        var latest = ParseTag(tag);
        if (latest == null || latest <= Normalize(AppInfo.Version)) return null;

        var asset = json!["assets"]?.AsArray()
            .Select(a => a!.AsObject())
            .FirstOrDefault(a => a["name"]!.GetValue<string>().EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                                 && a["name"]!.GetValue<string>().Contains("Setup", StringComparison.OrdinalIgnoreCase));
        if (asset == null) return null; // release exists but its installer isn't uploaded yet

        return new UpdateInfo(latest, tag!, asset["browser_download_url"]!.GetValue<string>(), asset["name"]!.GetValue<string>(),
            asset["size"]?.GetValue<long>() ?? 0, json["html_url"]?.GetValue<string>() ?? AppInfo.RepositoryUrl + "/releases",
            json["body"]?.GetValue<string>() ?? "");
    }

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
        return path;
    }

    /// <summary>Start the installer in silent mode. It closes this app, replaces the program files
    /// (settings, models and runtimes are kept) and starts the new version.</summary>
    public static void LaunchInstaller(string path)
    {
        Log.Info($"Launching update installer {Path.GetFileName(path)}");
        Process.Start(new ProcessStartInfo(path, "/SILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS") { UseShellExecute = true });
    }
}
