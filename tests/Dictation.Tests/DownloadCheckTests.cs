using System.Text.Json.Nodes;
using Dictation.Core.Infrastructure;
using Dictation.Core.Setup;
using Xunit;

namespace Dictation.Tests;

/// <summary>What Oberton downloads and then runs or unpacks is checked against a SHA-256 first.</summary>
public class DownloadCheckTests
{
    // SHA-256 of the ASCII text "hello\n".
    const string HelloSha256 = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03";

    static string TempFile(string text)
    {
        var path = Path.Combine(Path.GetTempPath(), "oberton-check-" + Guid.NewGuid().ToString("N"));
        File.WriteAllText(path, text);
        return path;
    }

    [Fact]
    public void A_file_matches_its_own_hash_in_any_spelling()
    {
        var path = TempFile("hello\n");
        try
        {
            Assert.Equal(HelloSha256, Checksum.Sha256(path));
            Assert.True(Checksum.Matches(path, HelloSha256));
            Assert.True(Checksum.Matches(path, "SHA256:" + HelloSha256.ToUpperInvariant()));
            Assert.False(Checksum.Matches(path, "0" + HelloSha256[1..]));
            Assert.False(Checksum.Matches(path, "not a hash"));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void A_runtime_download_that_matches_is_kept()
    {
        var path = TempFile("hello\n");
        try
        {
            RuntimeInstaller.Verify(path, HelloSha256, "uv-x86_64-pc-windows-msvc.zip");
            Assert.True(File.Exists(path));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void A_runtime_download_that_does_not_match_is_deleted_and_refused()
    {
        var path = TempFile("hello, but changed\n");
        var e = Assert.Throws<UserFacingException>(() => RuntimeInstaller.Verify(path, HelloSha256, "ollama-windows-amd64.zip"));
        Assert.Contains("ollama-windows-amd64.zip", e.Message);
        Assert.False(File.Exists(path));
    }

    [Fact]
    public void The_pinned_runtime_hashes_are_sha256s()
    {
        foreach (var h in new[] { RuntimeInstaller.UvSha256, RuntimeInstaller.PythonSha256, RuntimeInstaller.OllamaSha256 })
            Assert.Equal(h, Checksum.Normalize(h));
    }

    [Theory]
    [InlineData(HelloSha256 + "  Oberton-Setup-5.19.0.exe\n")]
    [InlineData(HelloSha256 + " *Oberton-Setup-5.19.0.exe\r\n")]
    [InlineData("1111111111111111111111111111111111111111111111111111111111111111  other.zip\n" + HelloSha256 + "  ./Oberton-Setup-5.19.0.exe\n")]
    [InlineData(HelloSha256 + "\n")]
    public void Checksum_files_give_the_installers_hash(string text) =>
        Assert.Equal(HelloSha256, Checksum.FromSumsFile(text, "Oberton-Setup-5.19.0.exe"));

    [Fact]
    public void A_checksum_file_for_other_files_gives_nothing() =>
        Assert.Null(Checksum.FromSumsFile("1111111111111111111111111111111111111111111111111111111111111111  other.zip\n", "Oberton-Setup-5.19.0.exe"));

    static JsonObject Release(params JsonObject[] assets) => new()
    {
        ["tag_name"] = "v9.0.0",
        ["html_url"] = "https://github.com/silent-diffusion/dictation/releases/tag/v9.0.0",
        ["body"] = "notes",
        ["assets"] = new JsonArray(assets.Cast<JsonNode>().ToArray()),
    };

    static JsonObject Asset(string name, string? digest = null) => new()
    {
        ["name"] = name,
        ["size"] = 123L,
        ["digest"] = digest,
        ["browser_download_url"] = "https://github.com/silent-diffusion/dictation/releases/download/v9.0.0/" + name,
    };

    [Fact]
    public void An_update_takes_githubs_digest_of_the_installer()
    {
        var info = UpdateService.FromRelease(Release(Asset("Oberton-Setup-9.0.0.exe", "sha256:" + HelloSha256)), new Version(5, 18, 1));
        Assert.NotNull(info);
        Assert.Equal(HelloSha256, info!.Sha256);
    }

    [Fact]
    public void Without_a_digest_an_update_takes_the_releases_checksum_file()
    {
        var info = UpdateService.FromRelease(Release(Asset("Oberton-Setup-9.0.0.exe"), Asset("Oberton-Setup-9.0.0.exe.sha256")), new Version(5, 18, 1));
        Assert.NotNull(info);
        Assert.Null(info!.Sha256);
        Assert.EndsWith("/Oberton-Setup-9.0.0.exe.sha256", info.Sha256Url);
        Assert.Equal("Oberton-Setup-9.0.0.exe", info.InstallerName); // the .sha256 is never taken for the installer
    }

    [Fact]
    public void A_release_with_no_checksum_offers_none()
    {
        var info = UpdateService.FromRelease(Release(Asset("Oberton-Setup-9.0.0.exe", "md5:abc")), new Version(5, 18, 1));
        Assert.NotNull(info);
        Assert.Null(info!.Sha256);
        Assert.Null(info.Sha256Url); // DownloadAsync then refuses to run it
    }

    [Fact]
    public void An_older_release_is_no_update() =>
        Assert.Null(UpdateService.FromRelease(Release(Asset("Oberton-Setup-9.0.0.exe", "sha256:" + HelloSha256)), new Version(9, 0, 0)));
}
