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
    [InlineData(0, "-1m")]
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

public class HistoryStatsTests
{
    static HistoryEntry E(DateTime t, string text, string app = "notepad", double finish = 0, string? ai = null, bool net = false) =>
        new() { Time = t, Final = text, Transcript = text, App = app, FinishSeconds = finish, AiOutput = ai, SafetyNet = net };

    static readonly DateTime Today = new(2026, 10, 5, 15, 0, 0);

    [Fact]
    public void Words_are_counted_per_day_ending_today()
    {
        var days = HistoryStats.PerDay(new[]
        {
            E(Today, "one two three"), E(Today.AddHours(-2), "four five"), E(Today.AddDays(-1), "six"), E(Today.AddDays(-30), "old"),
        }, Today, 14);
        Assert.Equal(14, days.Count);
        Assert.Equal(Today.Date, days[^1].Day);
        Assert.Equal(5, days[^1].Words);
        Assert.Equal(2, days[^1].Dictations);
        Assert.Equal(1, days[^2].Words);
        Assert.Equal(6, days.Sum(d => d.Words)); // the 30-day-old one is outside the window
    }

    [Fact]
    public void Top_apps_are_ordered_by_count()
    {
        var top = HistoryStats.TopApps(new[] { E(Today, "a", "slack"), E(Today, "b", "word"), E(Today, "c", "slack"), E(Today, "d", "") });
        Assert.Equal(("slack", 2), top[0]);
        Assert.Contains(("Unknown app", 1), top);
    }

    [Fact]
    public void Turnaround_and_ai_share_skip_what_wasnt_recorded()
    {
        var entries = new[]
        {
            E(Today, "a", finish: 2, ai: "A"), E(Today, "b", finish: 4, net: true), E(Today, "c"), E(Today, "d", ai: "D"),
        };
        Assert.Equal(3.0, HistoryStats.AverageFinishSeconds(entries)!.Value);
        Assert.Equal(2 / 3.0, HistoryStats.AiKeptShare(entries)!.Value, 3);
        Assert.Null(HistoryStats.AverageFinishSeconds(new[] { E(Today, "x") }));
        Assert.Null(HistoryStats.AiKeptShare(new[] { E(Today, "x") }));
    }
}
