using Dictation.Core.Session;
using Dictation.Core.Settings;
using Dictation.Core.Speech;
using Xunit;

namespace Dictation.Tests;

public class UsageStoreTests
{
    static readonly DateTime Now = DateTime.Today.AddHours(15);

    static HistoryEntry E(DateTime t, string text, string app = "notepad", double finish = 0, string? ai = null, bool net = false) =>
        new() { Time = t, Final = text, Transcript = text, App = app, Seconds = 3, FinishSeconds = finish, AiOutput = ai, SafetyNet = net,
                WindowTitle = "Secret plans.docx" };

    [Fact]
    public void Counts_words_and_dictations_per_day()
    {
        var u = new UsageStore(null);
        u.Record(E(Now, "one two three"));
        u.Record(E(Now.AddHours(-2), "four five"));
        u.Record(E(Now.AddDays(-1), "six"));
        var days = u.PerDay(Now);
        Assert.Equal(14, days.Count);
        Assert.Equal(5, days[^1].Words);
        Assert.Equal(2, days[^1].Dictations);
        Assert.Equal(1, days[^2].Words);
        Assert.Equal(6, u.TotalWords);
    }

    [Fact]
    public void Keeps_no_text_and_no_window_titles()
    {
        var path = Path.Combine(Path.GetTempPath(), "oberton-usage-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            new UsageStore(path).Record(E(Now, "my very private words", "winword"));
            var json = File.ReadAllText(path);
            Assert.DoesNotContain("private", json);
            Assert.DoesNotContain("Secret", json);
            Assert.Contains("winword", json);
            Assert.Equal(4, new UsageStore(path).TotalWords); // and it loads back
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Starts_from_history_once_then_keeps_its_own_counts()
    {
        var path = Path.Combine(Path.GetTempPath(), "oberton-usage-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var history = new[] { E(Now, "a b"), E(Now.AddDays(-3), "c") };
            Assert.Equal(3, new UsageStore(path, history).TotalWords);
            // History deleted later: the counts stay, and history isn't counted twice.
            Assert.Equal(3, new UsageStore(path, Array.Empty<HistoryEntry>()).TotalWords);
            Assert.Equal(3, new UsageStore(path, history).TotalWords);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Turnaround_ai_share_apps_and_streak()
    {
        var u = new UsageStore(null);
        u.Record(E(Now, "a", "slack", finish: 2, ai: "A"));
        u.Record(E(Now, "b", "slack", finish: 4, net: true));
        u.Record(E(Now.AddDays(-1), "c", "word"));
        u.Record(E(Now.AddDays(-2), "d", "", ai: "D"));
        u.Record(E(Now.AddDays(-5), "e"));
        Assert.Equal(3.0, u.AverageFinishSeconds(Now)!.Value);
        Assert.Equal(2 / 3.0, u.AiKeptShare(Now)!.Value, 3);
        Assert.Equal(("slack", 2), u.TopApps(Now)[0]);
        Assert.Contains(("Unknown app", 1), u.TopApps(Now));
        Assert.Equal(3, u.Streak(Now));
        Assert.Equal(2, u.Streak(Now.AddDays(-1)));
        Assert.Null(new UsageStore(null).AverageFinishSeconds(Now));
    }

    [Fact]
    public void Readings_are_counted()
    {
        var u = new UsageStore(null);
        u.RecordReading(120, Now);
        u.RecordReading(30, Now);
        Assert.Equal(2, u.Today(Now)!.Readings);
        Assert.Equal(150, u.Today(Now)!.WordsRead);
        Assert.Equal(0, u.TotalDictations);
    }
}

public class VoiceTests
{
    [Fact]
    public void Kokoro_keeps_its_eight_voices()
    {
        var ids = VoiceCatalog.KokoroVoices.Select(v => v.Id).ToList();
        Assert.Equal(8, ids.Count);
        Assert.Contains("af_heart", ids);
        Assert.All(ids, id => Assert.Equal(VoiceCatalog.Kokoro, VoiceCatalog.ModelOf(id)));
    }

    [Fact]
    public void There_are_three_models_and_every_voice_knows_its_model()
    {
        Assert.Equal(new[] { VoiceCatalog.Kokoro, VoiceCatalog.Piper, VoiceCatalog.Windows }, VoiceCatalog.Models.Select(m => m.Id));
        Assert.All(VoiceCatalog.PiperVoices, v => Assert.Equal(VoiceCatalog.Piper, VoiceCatalog.ModelOf(v.Id)));
        Assert.Equal(VoiceCatalog.Windows, VoiceCatalog.ModelOf("win:Microsoft Zira Desktop"));
        Assert.Equal(VoiceCatalog.Kokoro, VoiceCatalog.ModelOf(null));
    }

    [Fact]
    public void Piper_voices_download_from_the_piper_voices_repository()
    {
        var lessac = VoiceCatalog.PiperVoices.First(v => v.Name == "en_US-lessac-medium");
        Assert.Equal("piper:en_US-lessac-medium", lessac.Id);
        Assert.Equal("https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/lessac/medium/en_US-lessac-medium.onnx", lessac.Url);
        Assert.Equal("https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_GB/jenny_dioco/medium/en_GB-jenny_dioco-medium.onnx",
            VoiceCatalog.PiperVoices.First(v => v.Name == "en_GB-jenny_dioco-medium").Url);
        Assert.Same(lessac, VoiceCatalog.FindPiper("piper:en_US-lessac-medium"));
    }

    [Theory]
    [InlineData("win:Microsoft Zira Desktop", true)]
    [InlineData("af_heart", false)]
    [InlineData(null, false)]
    public void Windows_voices_are_told_apart(string? id, bool windows) => Assert.Equal(windows, VoiceCatalog.IsWindowsVoice(id));

    [Theory]
    [InlineData(1.0, 0)]
    [InlineData(3.0, 10)]
    [InlineData(1 / 3.0, -10)]
    [InlineData(2.0, 6)]
    [InlineData(0.5, -6)]
    [InlineData(9.0, 10)]
    public void Speed_maps_onto_the_windows_rate(double speed, int rate) => Assert.Equal(rate, WindowsSpeech.RateFor(speed));

    [Fact]
    public void Windows_voice_names_are_shortened() => Assert.Equal("Zira", WindowsSpeech.Nice("Microsoft Zira Desktop"));

    [Fact]
    public void Profiles_use_the_read_aloud_voice_unless_they_pick_one()
    {
        var p = new Profile();
        Assert.Null(p.Voice);
        Assert.False(p.LiveTyping); // without AI, words are pasted as they are heard unless the profile says type
        Assert.Null(new AppSettings().ReaderPosition); // the player follows the dictation overlay by default
    }
}

public class SpeechModelTests
{
    [Fact]
    public void A_profile_uses_its_own_speech_model_or_the_one_in_settings()
    {
        var asr = new AsrSettings { Model = "large-v3-turbo" };
        Assert.Equal("large-v3-turbo", SpeechModels.For(new Profile(), asr));
        Assert.Equal("large-v3-turbo", SpeechModels.For(new Profile { SpeechModel = " " }, asr));
        Assert.Equal("small.en", SpeechModels.For(new Profile { SpeechModel = "small.en" }, asr));
        Assert.Equal("large-v3-turbo", SpeechModels.For(null, asr));
    }

    [Fact]
    public void Speech_models_have_names() =>
        Assert.Equal("Whisper small (English)", SpeechModels.NameOf("small.en"));
}
