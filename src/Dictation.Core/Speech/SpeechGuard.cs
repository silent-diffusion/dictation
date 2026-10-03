namespace Dictation.Core.Speech;

/// <summary>
/// Decides whether a finished recording held real speech. Whisper is known to invent short stock phrases
/// ("Thank you.", "Thanks for watching!") for silence, breathing or a stray click, and those must never be typed.
/// </summary>
public static class SpeechGuard
{
    /// <summary>Recordings shorter than this are only kept when the microphone clearly heard speech.</summary>
    public static readonly TimeSpan ShortRecording = TimeSpan.FromSeconds(1);
    /// <summary>Stock phrases are only trusted from recordings at least this long and this loud.</summary>
    static readonly TimeSpan PhraseRecording = TimeSpan.FromSeconds(2.5);
    /// <summary>Peak input level (0..1, as reported by the microphone meter) that counts as clearly spoken.</summary>
    public const float SpeechLevel = 0.2f;

    static readonly HashSet<string> Hallucinations = new(StringComparer.Ordinal)
    {
        "thank you", "thank you very much", "thanks", "thank you for watching", "thanks for watching",
        "thank you so much for watching", "please subscribe", "subscribe", "bye", "bye bye", "goodbye", "you",
        "okay", "ok", "so", "um", "uh", "hmm", "oh", "the end",
    };

    /// <param name="text">The raw transcript.</param>
    /// <param name="recorded">How long the user recorded.</param>
    /// <param name="peakLevel">The loudest input level seen while recording.</param>
    /// <returns>True when nothing should be inserted.</returns>
    public static bool ShouldDiscard(string text, TimeSpan recorded, float peakLevel)
    {
        if (!text.Any(char.IsLetterOrDigit)) return true;
        var heardSpeech = peakLevel >= SpeechLevel;
        if (recorded < ShortRecording && !heardSpeech) return true;
        if (IsStockPhrase(text) && (recorded < PhraseRecording || !heardSpeech)) return true;
        return false;
    }

    public static bool IsStockPhrase(string text)
    {
        var words = text.ToLowerInvariant()
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Select(w => new string(w.Where(char.IsLetter).ToArray()))
            .Where(w => w.Length > 0);
        return Hallucinations.Contains(string.Join(' ', words));
    }
}
