using Dictation.Core.Insertion;
using Dictation.Core.Session;
using Xunit;

namespace Dictation.Tests;

/// <summary>The dashboard's turnaround: the last three warm runs with the models in use now.</summary>
public class TurnaroundTests
{
    static TurnaroundSample S(double seconds, string speech = "large-v3-turbo", string ai = "qwen2.5:3b", bool loaded = false) =>
        new() { Time = DateTime.Now, SpeechModel = speech, AiModel = ai, Seconds = seconds, ModelLoaded = loaded };

    [Fact]
    public void Averages_the_last_three_with_the_same_models()
    {
        var u = new UsageStore(null);
        foreach (var s in new[] { 9.0, 1.0, 2.0, 3.0 }) u.RecordTurnaround(S(s));
        var (avg, n) = u.RecentTurnaround("large-v3-turbo", "qwen2.5:3b");
        Assert.Equal(3, n);
        Assert.Equal(2.0, avg!.Value, 3); // 1, 2, 3: the 9 s is older than the last three
    }

    [Fact]
    public void Runs_that_loaded_a_model_are_left_out()
    {
        var u = new UsageStore(null);
        u.RecordTurnaround(S(1.0));
        u.RecordTurnaround(S(12.0, loaded: true));
        var (avg, n) = u.RecentTurnaround("large-v3-turbo", "qwen2.5:3b");
        Assert.Equal(1, n);
        Assert.Equal(1.0, avg!.Value, 3);
    }

    [Fact]
    public void Other_models_dont_count_and_no_ai_is_its_own_pair()
    {
        var u = new UsageStore(null);
        u.RecordTurnaround(S(1.5, speech: "small.en"));
        u.RecordTurnaround(S(4.0, ai: "qwen2.5:7b"));
        u.RecordTurnaround(S(0.6, ai: ""));
        Assert.Null(u.RecentTurnaround("large-v3-turbo", "qwen2.5:3b").Seconds);
        Assert.Equal(0.6, u.RecentTurnaround("large-v3-turbo", "").Seconds!.Value, 3);
        Assert.Equal(1.5, u.RecentTurnaround("SMALL.EN", "qwen2.5:3b").Seconds!.Value, 3);
    }

    [Fact]
    public void Only_the_latest_hundred_are_kept()
    {
        var u = new UsageStore(null);
        for (var i = 0; i < UsageStore.KeepTurnarounds + 20; i++) u.RecordTurnaround(S(i + 1));
        var (avg, _) = u.RecentTurnaround("large-v3-turbo", "qwen2.5:3b");
        Assert.Equal(UsageStore.KeepTurnarounds + 19.0, avg!.Value, 3); // the last three: 118, 119, 120
    }

    [Fact]
    public void No_window_is_nowhere_to_type() => Assert.True(PasteSpot.IsNowhere(IntPtr.Zero));
}
