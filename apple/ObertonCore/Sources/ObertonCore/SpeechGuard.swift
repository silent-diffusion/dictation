import Foundation

/// Decides whether a finished recording held real speech (Windows' `SpeechGuard`). Speech recognizers are known to
/// invent short stock phrases ("Thank you.", "Thanks for watching!") for silence, breathing or a stray click, and those
/// must never be typed.
public enum SpeechGuard {
    /// Recordings shorter than this are only kept when the microphone clearly heard speech.
    public static let shortRecording: Double = 1
    /// Stock phrases are only trusted from recordings at least this long and this loud.
    static let phraseRecording: Double = 2.5
    /// Peak input level (0…1, on Windows' meter scale: `LiveTranscriber.speechLevel`) that counts as clearly spoken.
    public static let speechLevel: Float = 0.2

    static let hallucinations: Set<String> = [
        "thank you", "thank you very much", "thanks", "thank you for watching", "thanks for watching",
        "thank you so much for watching", "please subscribe", "subscribe", "bye", "bye bye", "goodbye", "you",
        "okay", "ok", "so", "um", "uh", "hmm", "oh", "the end",
    ]

    /// A subtitle credit ("Subtitles by …", "amara.org"): learnt from video subtitles, never dictated.
    static let subtitleCredit = try! NSRegularExpression(
        pattern: #"^(subtitles?|captions?|transcri(bed|ption)|translat(ed|ion))\b.*\bby\b|amara\.org"#, options: [.caseInsensitive])

    /// True when nothing should be inserted. `recorded`: seconds the user recorded; `peakLevel`: the loudest level seen.
    public static func shouldDiscard(_ text: String, recorded: Double, peakLevel: Float) -> Bool {
        if !hasLetterOrDigit(text) { return true }
        let heardSpeech = peakLevel >= speechLevel
        if recorded < shortRecording && !heardSpeech { return true }
        if isStockPhrase(text) && (recorded < phraseRecording || !heardSpeech) { return true }
        return false
    }

    /// .NET's `text.Any(char.IsLetterOrDigit)`: a UTF-16 unit that is a letter (any L category) or a decimal digit (Nd).
    /// "²", "½" or "Ⅻ" alone don't count, and neither do letters outside the Basic Multilingual Plane ("𠀀", "𝐀"):
    /// .NET sees only their surrogate halves, which are no letters.
    static func hasLetterOrDigit(_ text: String) -> Bool {
        text.utf16.contains { unit in
            guard let scalar = Unicode.Scalar(unit) else { return false } // a surrogate half
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: return true
            default: return false
            }
        }
    }

    /// Windows' stock phrases; a subtitle credit too, which Windows checks only on Whisper's segments (asr_server.py
    /// SUBTITLE_CREDIT): a Mac addition, kept by the user's decision 3 (the subtitle-credit and marker filters).
    public static func isStockPhrase(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if subtitleCredit.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return true }
        let words = t.lowercased().split(whereSeparator: \.isWhitespace)
            .map { String($0.filter(\.isLetter)) }.filter { !$0.isEmpty }
        return hallucinations.contains(words.joined(separator: " "))
    }
}
