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
    /// Called when a reading ends (or is stopped) with how many words were heard and for how long.
    public var onFinishedReading: ((Int, Double) -> Void)?
    /// What is being read, for the player's header ("SAMANTHA").
    public private(set) var voiceName = ""

    /// Made on first use and let go by `unload()`, so the voice's memory can be freed between readings.
    private var voiceEngine: AVSpeechSynthesizer?
    private var synth: AVSpeechSynthesizer {
        if let voiceEngine { return voiceEngine }
        let s = AVSpeechSynthesizer()
        s.delegate = self
        voiceEngine = s
        return s
    }
    private var voiceID: String?
    /// Where the current utterance starts in `text`, so a restart from a word keeps highlights aligned.
    private var offset = 0
    private var startedAt: Date?
    private var furthest = 0

    public override init() {
        super.init()
    }

    /// The voice is loaded (it has read something since it was last let go).
    public var isLoaded: Bool { voiceEngine != nil }

    /// Let the voice go (the dashboard's Unload everything); it loads again on the next reading. Not while reading.
    public func unload() {
        guard !isSpeaking, let engine = voiceEngine else { return }
        engine.stopSpeaking(at: .immediate)
        engine.delegate = nil
        voiceEngine = nil
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
        startedAt = Date()
        furthest = 0
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
        voiceName = u.voice?.name ?? "System voice"
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
        guard let synth = voiceEngine else { return }
        if synth.isPaused { synth.continueSpeaking(); isPaused = false } else if synth.isSpeaking { synth.pauseSpeaking(at: .word); isPaused = true }
    }

    public func stop() {
        finishCounting()
        voiceEngine?.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
        spokenRange = nil
    }

    /// How far through the text the voice is, 0…1.
    public var progress: Double {
        let n = (text as NSString).length
        guard n > 0, let r = spokenRange else { return 0 }
        return Double(r.location) / Double(n)
    }

    /// Seconds left at the current speed (about 15 characters a second at 1×).
    public var secondsLeft: Double {
        let n = (text as NSString).length
        return Double(n - (spokenRange?.location ?? 0)) / (15 * speed)
    }

    /// Jump by about this many seconds of speech, forwards or back (the player's −15 / +15).
    public func skip(seconds: Double) {
        let n = (text as NSString).length
        let here = spokenRange?.location ?? offset
        var target = max(0, min(n - 1, here + Int(seconds * 15 * speed)))
        // Start on a word, not in the middle of one.
        let ns = text as NSString
        while target > 0, let c = Unicode.Scalar(ns.character(at: target - 1)), !CharacterSet.whitespacesAndNewlines.contains(c) { target -= 1 }
        speak(from: target)
    }

    private func finishCounting() {
        guard let startedAt else { return }
        let read = (text as NSString).substring(to: min(furthest, (text as NSString).length))
        onFinishedReading?(read.split(whereSeparator: \.isWhitespace).count, Date().timeIntervalSince(startedAt))
        self.startedAt = nil
    }

    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            spokenRange = NSRange(location: range.location + offset, length: range.length)
            furthest = max(furthest, range.location + offset + range.length)
        }
    }

    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            // A restart (speed change, clicked word) also finishes the old utterance; only a real end clears the player.
            if !s.isSpeaking {
                furthest = (text as NSString).length
                finishCounting()
                isSpeaking = false
                spokenRange = nil
            }
        }
    }
}
