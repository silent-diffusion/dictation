using Dictation.Core.Setup;
using Xunit;

namespace Dictation.Tests;

public class UpdateTests
{
    [Theory]
    [InlineData("v1.2.3", "1.2.3")]
    [InlineData("1.2.3", "1.2.3")]
    [InlineData("v2.0", "2.0.0")]
    [InlineData("v1.4.0-beta.1", "1.4.0")]
    public void Parses_release_tags(string tag, string expected) =>
        Assert.Equal(Version.Parse(expected), UpdateService.ParseTag(tag));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("latest")]
    public void Rejects_non_version_tags(string? tag) => Assert.Null(UpdateService.ParseTag(tag));

    [Fact]
    public void Newer_patch_compares_greater() =>
        Assert.True(UpdateService.ParseTag("v1.0.10") > UpdateService.ParseTag("v1.0.9"));

    [Fact]
    public void Hardware_defaults_pick_a_lighter_speech_model_for_cpu()
    {
        Assert.Equal("large-v3-turbo", RuntimeInstaller.DefaultsFor(gpu: true).Whisper);
        Assert.Equal("small.en", RuntimeInstaller.DefaultsFor(gpu: false).Whisper);
        Assert.Equal("cpu", RuntimeInstaller.DefaultsFor(gpu: false).Device);
    }
}
