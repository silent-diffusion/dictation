using System.Globalization;
using System.Speech.AudioFormat;
using System.Speech.Synthesis;
using Dictation.Core.Infrastructure;
using Dictation.Core.Setup;

namespace Dictation.Core.Speech;

/// <summary>A voice that Read aloud can use. <paramref name="Model"/> is the id of its <see cref="TtsModel"/>.</summary>
public sealed record VoiceOption(string Id, string Name, string Model = VoiceCatalog.Kokoro);

/// <summary>A text-to-speech model (engine) with its own voices.</summary>
public sealed record TtsModel(string Id, string Name, string Description);

/// <summary>A downloadable Piper voice: one ONNX file (plus its JSON config) from rhasspy/piper-voices.</summary>
public sealed record PiperVoice(string Name, string Label, string Kind, int Mb)
{
    public string Id => VoiceCatalog.PiperPrefix + Name;
    /// <summary>"en_US-lessac-medium" → en/en_US/lessac/medium/en_US-lessac-medium.onnx on Hugging Face.</summary>
    public string Url
    {
        get
        {
            var parts = Name.Split('-'); // locale, speaker, quality
            return $"https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/{parts[0][..2]}/{parts[0]}/{parts[1]}/{parts[2]}/{Name}.onnx";
        }
    }
}

/// <summary>Turns one short piece of text into mono float samples at <see cref="KokoroSpeech.SampleRate"/>.</summary>
public interface ISpeechSynthesizer
{
    Task<float[]> SynthesizeAsync(string text, string voice, double speed, CancellationToken ct = default);
}

/// <summary>
/// The text-to-speech models Read aloud can use, and their voices: Kokoro (natural, one download), Piper (light and
/// fast, one small download per voice) and the voices installed with Windows (no download).
/// </summary>
public static class VoiceCatalog
{
    public const string Kokoro = "kokoro", Piper = "piper", Windows = "windows";
    public const string PiperPrefix = "piper:";

    public static readonly IReadOnlyList<TtsModel> Models = new[]
    {
        new TtsModel(Kokoro, "Kokoro v1.0", "The most natural voices. One download of about 370 MB; runs on this PC."),
        new TtsModel(Piper, "Piper", "Light and fast, even on slower PCs. Each voice is a separate download of 60 to 120 MB; runs on this PC."),
        new TtsModel(Windows, "Windows voices", "The voices that come with Windows. Nothing to download; more robotic."),
    };

    /// <summary>A short list of Kokoro v1.0's best English voices.</summary>
    public static readonly IReadOnlyList<VoiceOption> KokoroVoices = new[]
    {
        new VoiceOption("af_heart", "Heart (American, female)"),
        new VoiceOption("af_bella", "Bella (American, female)"),
        new VoiceOption("af_nicole", "Nicole (American, female, soft)"),
        new VoiceOption("am_michael", "Michael (American, male)"),
        new VoiceOption("am_fenrir", "Fenrir (American, male)"),
        new VoiceOption("bf_emma", "Emma (British, female)"),
        new VoiceOption("bm_george", "George (British, male)"),
        new VoiceOption("bm_fable", "Fable (British, male)"),
    };

    public static readonly IReadOnlyList<PiperVoice> PiperVoices = new[]
    {
        new PiperVoice("en_US-lessac-medium", "Lessac", "American, female", 63),
        new PiperVoice("en_US-amy-medium", "Amy", "American, female", 63),
        new PiperVoice("en_US-ryan-high", "Ryan", "American, male, high quality", 121),
        new PiperVoice("en_US-joe-medium", "Joe", "American, male", 63),
        new PiperVoice("en_GB-jenny_dioco-medium", "Jenny", "British, female", 63),
        new PiperVoice("en_GB-alan-medium", "Alan", "British, male", 63),
    };

    public static bool IsWindowsVoice(string? id) => id?.StartsWith(WindowsSpeech.Prefix, StringComparison.Ordinal) == true;
    public static bool IsPiperVoice(string? id) => id?.StartsWith(PiperPrefix, StringComparison.Ordinal) == true;

    /// <summary>The model a voice belongs to.</summary>
    public static string ModelOf(string? voiceId) => IsWindowsVoice(voiceId) ? Windows : IsPiperVoice(voiceId) ? Piper : Kokoro;

    public static TtsModel Model(string id) => Models.FirstOrDefault(m => m.Id == id) ?? Models[0];

    /// <summary>Every voice of a model, downloaded or not.</summary>
    public static IReadOnlyList<VoiceOption> VoicesOf(string model) => model switch
    {
        Piper => PiperVoices.Select(v => new VoiceOption(v.Id, $"{v.Label} ({v.Kind})", Piper)).ToList(),
        Windows => WindowsSpeech.InstalledVoices(),
        _ => KokoroVoices,
    };

    /// <summary>The voice can be used right now (its model or file is downloaded).</summary>
    public static bool IsInstalled(string? voiceId) => ModelOf(voiceId) switch
    {
        Windows => WindowsSpeech.InstalledVoices().Any(v => v.Id == voiceId),
        Piper => RuntimeInstaller.PiperVoiceInstalled(voiceId![PiperPrefix.Length..]),
        _ => RuntimeInstaller.ReadAloudInstalled,
    };

    /// <summary>The voices that can be used right now.</summary>
    public static IReadOnlyList<VoiceOption> Available() =>
        Models.SelectMany(m => VoicesOf(m.Id)).Where(v => IsInstalled(v.Id)).ToList();

    public static PiperVoice? FindPiper(string? voiceId) => PiperVoices.FirstOrDefault(v => v.Id == voiceId);

    /// <summary>A short display name: "Heart", "Lessac", "Zira".</summary>
    public static string ShortName(string id)
    {
        var v = VoicesOf(ModelOf(id)).FirstOrDefault(v => v.Id == id);
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
            : _kokoro.SynthesizeAsync(text, voice, speed, ct); // Kokoro and Piper both run in the local voice server
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
                .Select(i => new VoiceOption(Prefix + i.Name, $"{Nice(i.Name)} ({Language(i.Culture)}, {i.Gender.ToString().ToLowerInvariant()})",
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
            // Like the other voices, SAPI paces itself up to 2× either way and a pitch-safe stretch does the rest.
            var native = Math.Clamp(speed, 0.5, 2.0);
            synth.Rate = RateFor(native);
            using var ms = new MemoryStream();
            synth.SetOutputToAudioStream(ms, new SpeechAudioFormatInfo(KokoroSpeech.SampleRate, AudioBitsPerSample.Sixteen, AudioChannel.Mono));
            synth.Speak(text);
            synth.SetOutputToNull();
            var pcm = ms.ToArray();
            var samples = new float[pcm.Length / 2];
            for (var i = 0; i < samples.Length; i++) samples[i] = BitConverter.ToInt16(pcm, i * 2) / 32768f;
            return TimeStretch.Apply(samples, speed / native);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            throw new UserFacingException("The Windows voice couldn't read that: " + e.Message, e);
        }
    }, ct);
}
