import AVFoundation
import Foundation

/// Text is read as plain text: Markdown (headings, lists, emphasis, links, code fences) and stray symbols are dropped.
public enum ReadAloudText {
    public static func plain(_ s: String) -> String {
        var t = s.replacing(#/(?m)^```.*$/#, with: "")
        t = t.replacing(#/!?\[([^\]]*)\]\([^)]*\)/#) { String($0.output.1) }      // [text](url) → text
        t = t.replacing(#/(?m)^\s{0,3}#{1,6}\s+/#, with: "")                      // headings
        t = t.replacing(#/(?m)^\s*(?:[-*+]|\d+[.)])\s+/#, with: "")               // list markers
        t = t.replacing(#/(?m)^\s*>\s?/#, with: "")                               // quotes
        t = t.replacing(#/(?m)^\s*\|?(?:\s*:?-{3,}:?\s*\|)+\s*$/#, with: "")       // table rules
        t = t.replacing(#/[*_`~|#]+/#, with: " ")
        t = t.replacing(#/[ \t]{2,}/#, with: " ")
        t = t.replacing(#/\n{3,}/#, with: "\n\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reads text aloud with the system's voices and reports the word being spoken, for the player's highlight.
@MainActor
public final class ReadAloudPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published public private(set) var text = ""
    @Published public private(set) var spokenRange: NSRange?
    @Published public private(set) var isSpeaking = false
    @Published public private(set) var isPaused = false
    @Published public var speed: Double = 1.0

    private let synth = AVSpeechSynthesizer()
    private var voiceID: String?
    /// Where the current utterance starts in `text`, so a restart from a word keeps highlights aligned.
    private var offset = 0

    public override init() {
        super.init()
        synth.delegate = self
    }

    public static var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    public func read(_ raw: String, voice: String?, speed: Double) {
        stop()
        text = ReadAloudText.plain(raw)
        voiceID = voice
        self.speed = speed
        speak(from: 0)
    }

    /// Start reading again from a character offset (a clicked word, or after a speed change).
    public func speak(from location: Int) {
        guard !text.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        let ns = text as NSString
        offset = max(0, min(location, ns.length))
        let u = AVSpeechUtterance(string: ns.substring(from: offset))
        u.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        // AVSpeechUtterance's rate is not linear in speed; default 0.5 ≈ 1×, max 1.0 ≈ 2×+.
        u.rate = Float(min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate,
                                                                   AVSpeechUtteranceDefaultSpeechRate * Float(pow(speed, 0.6)))))
        isSpeaking = true
        isPaused = false
        synth.speak(u)
    }

    public func setSpeed(_ s: Double) {
        speed = min(4, max(0.25, s))
        if isSpeaking, let r = spokenRange { speak(from: r.location) }
    }

    public func togglePause() {
        if synth.isPaused { synth.continueSpeaking(); isPaused = false } else if synth.isSpeaking { synth.pauseSpeaking(at: .word); isPaused = true }
    }

    public func stop() {
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
        spokenRange = nil
    }

    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { spokenRange = NSRange(location: range.location + offset, length: range.length) }
    }

    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            // A restart (speed change, clicked word) also finishes the old utterance; only a real end clears the player.
            if !s.isSpeaking { isSpeaking = false; spokenRange = nil }
        }
    }
}
