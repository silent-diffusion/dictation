using Dictation.Core.Session;
using Dictation.Core.Settings;
using Dictation.Core.Text;
using Xunit;

namespace Dictation.Tests;

public class CloudModelTests
{
    [Theory]
    [InlineData("anthropic:claude-haiku-4-5-20251001", true)]
    [InlineData("openai:gpt-4.1-mini", true)]
    [InlineData("OpenAI:gpt-4.1-mini", true)]
    [InlineData("qwen2.5:3b", false)]
    [InlineData("llama3.2:3b", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void Cloud_models_are_told_apart_from_local_ones(string? model, bool cloud) =>
        Assert.Equal(cloud, CloudModels.IsCloud(model));

    [Fact]
    public void A_cloud_id_splits_into_provider_and_model() =>
        Assert.Equal(("anthropic", "claude-sonnet-5-5"), CloudModels.Split("Anthropic:claude-sonnet-5-5"));

    [Fact]
    public void Offline_is_the_default_and_no_keys_are_set()
    {
        var c = new CloudSettings();
        Assert.True(c.KeepOffline);
        Assert.False(CloudModels.HasKey(c, CloudModels.Anthropic));
        Assert.False(CloudModels.HasKey(c, CloudModels.OpenAi));
    }

    [Fact]
    public void The_catalog_offers_the_configured_openai_model()
    {
        var c = new CloudSettings { OpenAiModel = "my-model" };
        Assert.Contains(CloudModels.Catalog(c), m => m.Id == "openai:my-model");
        Assert.All(CloudModels.Catalog(c), m => Assert.True(CloudModels.IsCloud(m.Id)));
    }
}

public class UnloadingTests
{
    [Theory]
    [InlineData(30, "30m")]
    [InlineData(5, "5m")]
    [InlineData(0, "-1")]
    public void Unload_time_becomes_an_ollama_keep_alive(int minutes, string keepAlive) =>
        Assert.Equal(keepAlive, new AppSettings { UnloadAfterMinutes = minutes }.OllamaKeepAlive);

    [Fact]
    public void History_keeps_50_with_audio_by_default()
    {
        var s = new AppSettings();
        Assert.Equal(50, s.HistoryLimit);
        Assert.True(s.KeepHistory);
        Assert.True(s.SaveHistoryAudio);
        Assert.Equal(HistoryGrouping.Chronological, s.HistoryGrouping);
    }
}

public class HistoryEntryTests
{
    [Fact]
    public void Preview_prefers_the_inserted_text_and_is_short()
    {
        var e = new HistoryEntry { Transcript = "raw words", Final = new string('a', 300) };
        Assert.True(e.Preview.Length <= 120);
        Assert.StartsWith("aaa", e.Preview);
        Assert.Equal("raw words", new HistoryEntry { Transcript = "raw words" }.Preview);
    }

    [Theory]
    [InlineData(12.4, "12 s")]
    [InlineData(75, "1:15 min")]
    public void Duration_reads_naturally(double seconds, string text) =>
        Assert.Equal(text, new HistoryEntry { Seconds = seconds }.Duration);

    [Fact]
    public void An_unknown_app_still_has_a_name() => Assert.Equal("Unknown app", new HistoryEntry().AppName);

    [Fact]
    public void Recordings_are_written_as_16khz_mono_wav()
    {
        var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".wav");
        try
        {
            WavFile.Write(path, new byte[32000]); // one second
            var bytes = File.ReadAllBytes(path);
            Assert.Equal("RIFF", System.Text.Encoding.ASCII.GetString(bytes, 0, 4));
            Assert.Equal(16000, BitConverter.ToInt32(bytes, 24)); // sample rate
            Assert.Equal(1, BitConverter.ToInt16(bytes, 22)); // channels
            Assert.True(bytes.Length >= 32044);
        }
        finally { File.Delete(path); }
    }
}
