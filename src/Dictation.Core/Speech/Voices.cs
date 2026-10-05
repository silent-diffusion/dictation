using System.Globalization;
using System.Speech.AudioFormat;
using System.Speech.Synthesis;
using Dictation.Core.Infrastructure;
using Dictation.Core.Setup;

namespace Dictation.Core.Speech;

/// <summary>A voice that Read aloud can use. <paramref name="Engine"/> is "Kokoro" or "Windows".</summary>
public sealed record VoiceOption(string Id, string Name, string Engine = VoiceCatalog.Kokoro);

/// <summary>Turns one short piece of text into mono float samples at <see cref="KokoroSpeech.SampleRate"/>.</summary>
public interface ISpeechSynthesizer
{
    Task<float[]> SynthesizeAsync(string text, string voice, double speed, CancellationToken ct = default);
}

/// <summary>Every voice Read aloud can use: Kokoro's (one download, runs on this PC) and the voices installed with Windows.</summary>
public static class VoiceCatalog
{
    public const string Kokoro = "Kokoro", Windows = "Windows";

    /// <summary>Kokoro v1.0's voices in the languages its bundled phonemizer handles. The first letter is the
    /// language (a American, b British, e Spanish, f French, h Hindi, i Italian, p Brazilian Portuguese), the second
    /// the voice (f female, m male).</summary>
    public static readonly IReadOnlyList<VoiceOption> KokoroVoices = new[]
    {
        K("af_heart", "Heart", "American, female"), K("af_bella", "Bella", "American, female"),
        K("af_nicole", "Nicole", "American, female, soft"), K("af_sarah", "Sarah", "American, female"),
        K("af_sky", "Sky", "American, female"), K("af_nova", "Nova", "American, female"),
        K("af_alloy", "Alloy", "American, female"), K("af_aoede", "Aoede", "American, female"),
        K("af_jessica", "Jessica", "American, female"), K("af_kore", "Kore", "American, female"),
        K("af_river", "River", "American, female"),
        K("am_michael", "Michael", "American, male"), K("am_fenrir", "Fenrir", "American, male"),
        K("am_adam", "Adam", "American, male"), K("am_echo", "Echo", "American, male"),
        K("am_eric", "Eric", "American, male"), K("am_liam", "Liam", "American, male"),
        K("am_onyx", "Onyx", "American, male"), K("am_puck", "Puck", "American, male"),
        K("bf_emma", "Emma", "British, female"), K("bf_alice", "Alice", "British, female"),
        K("bf_isabella", "Isabella", "British, female"), K("bf_lily", "Lily", "British, female"),
        K("bm_george", "George", "British, male"), K("bm_fable", "Fable", "British, male"),
        K("bm_daniel", "Daniel", "British, male"), K("bm_lewis", "Lewis", "British, male"),
        K("ef_dora", "Dora", "Spanish, female"), K("em_alex", "Alex", "Spanish, male"),
        K("ff_siwis", "Siwis", "French, female"),
        K("if_sara", "Sara", "Italian, female"), K("im_nicola", "Nicola", "Italian, male"),
        K("pf_dora", "Dora", "Portuguese (Brazil), female"), K("pm_alex", "Alex", "Portuguese (Brazil), male"),
        K("hf_alpha", "Alpha", "Hindi, female"), K("hm_omega", "Omega", "Hindi, male"),
    };

    static VoiceOption K(string id, string name, string kind) => new(id, $"{name} ({kind})");

    public static bool IsWindowsVoice(string? id) => id?.StartsWith(WindowsSpeech.Prefix, StringComparison.Ordinal) == true;

    /// <summary>The voices that can be used right now: Kokoro's once downloaded, and Windows' always.</summary>
    public static IReadOnlyList<VoiceOption> Available() =>
        (RuntimeInstaller.ReadAloudInstalled ? KokoroVoices : Array.Empty<VoiceOption>()).Concat(WindowsSpeech.InstalledVoices()).ToList();

    /// <summary>Every voice, downloaded or not (for the Read aloud page, which can download Kokoro).</summary>
    public static IReadOnlyList<VoiceOption> All() => KokoroVoices.Concat(WindowsSpeech.InstalledVoices()).ToList();

    /// <summary>A short display name: "Heart", "Zira".</summary>
    public static string ShortName(string id)
    {
        var v = KokoroVoices.FirstOrDefault(v => v.Id == id) ?? WindowsSpeech.InstalledVoices().FirstOrDefault(v => v.Id == id);
        return v == null ? id : v.Name.Split(" (")[0];
    }
}

/// <summary>Sends each request to the engine that owns the voice.</summary>
public sealed class SpeechVoices : ISpeechSynthesizer
{
    readonly KokoroSpeech _kokoro;
    readonly WindowsSpeech _windows = new();

    public SpeechVoices(KokoroSpeech kokoro) => _kokoro = kokoro;

    public Task<float[]> SynthesizeAsync(string text, string voice, double speed, CancellationToken ct = default) =>
        VoiceCatalog.IsWindowsVoice(voice)
            ? _windows.SynthesizeAsync(text, voice, speed, ct)
            : _kokoro.SynthesizeAsync(text, voice, speed, ct);
}

/// <summary>
/// The voices that come with Windows (SAPI: Microsoft David, Zira, Hazel… plus any language packs installed).
/// No download, nothing leaves the PC; they sound more robotic than Kokoro but start instantly.
/// </summary>
public sealed class WindowsSpeech : ISpeechSynthesizer
{
    public const string Prefix = "win:";
    static IReadOnlyList<VoiceOption>? _installed;

    public static IReadOnlyList<VoiceOption> InstalledVoices()
    {
        if (_installed != null) return _installed;
        try
        {
            using var synth = new SpeechSynthesizer();
            _installed = synth.GetInstalledVoices().Where(v => v.Enabled).Select(v => v.VoiceInfo)
                .Select(i => new VoiceOption(Prefix + i.Name, $"{Nice(i.Name)} (Windows · {Language(i.Culture)}, {i.Gender.ToString().ToLowerInvariant()})",
                    VoiceCatalog.Windows))
                .OrderBy(v => v.Name).ToList();
        }
        catch (Exception e)
        {
            Log.Warn("Couldn't list the Windows voices: " + e.Message);
            _installed = Array.Empty<VoiceOption>();
        }
        return _installed;
    }

    /// <summary>"Microsoft Zira Desktop" → "Zira".</summary>
    internal static string Nice(string name) =>
        name.Replace("Microsoft ", "").Replace(" Desktop", "").Trim();

    static string Language(CultureInfo c)
    {
        try { return c.DisplayName; } catch { return c.Name; }
    }

    /// <summary>SAPI's rate goes from −10 (a third of normal) to 10 (three times); map a speed factor onto it.</summary>
    public static int RateFor(double speed) =>
        (int)Math.Clamp(Math.Round(10 * Math.Log(Math.Max(speed, 0.1)) / Math.Log(3)), -10, 10);

    public Task<float[]> SynthesizeAsync(string text, string voice, double speed, CancellationToken ct = default) => Task.Run(() =>
    {
        ct.ThrowIfCancellationRequested();
        try
        {
            using var synth = new SpeechSynthesizer();
            var name = voice.StartsWith(Prefix, StringComparison.Ordinal) ? voice[Prefix.Length..] : voice;
            try { synth.SelectVoice(name); }
            catch (ArgumentException) { Log.Warn($"Windows voice \"{name}\" isn't installed; using the default one"); }
            synth.Rate = RateFor(speed);
            using var ms = new MemoryStream();
            synth.SetOutputToAudioStream(ms, new SpeechAudioFormatInfo(KokoroSpeech.SampleRate, AudioBitsPerSample.Sixteen, AudioChannel.Mono));
            synth.Speak(text);
            synth.SetOutputToNull();
            var pcm = ms.ToArray();
            var samples = new float[pcm.Length / 2];
            for (var i = 0; i < samples.Length; i++) samples[i] = BitConverter.ToInt16(pcm, i * 2) / 32768f;
            return samples;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            throw new UserFacingException("The Windows voice couldn't read that: " + e.Message, e);
        }
    }, ct);
}
