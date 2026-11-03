import AVFoundation
import Foundation

/// A question the player asks before it reads ("Nothing is selected. Read your clipboard?") or why it couldn't start.
public struct ReaderQuestion {
    public var title: String
    public var body: String
    /// The primary button's label ("Read clipboard", "OK").
    public var primary: String
    public var action: @MainActor () -> Void
}

/// Reads text aloud with the system's voices, one sentence at a time (Windows' ReadAloudSession and ReaderWindow).
/// It reports the sentence and the word being spoken, for the player's highlight. Time left and the ±15 s skips use
/// the time the voice really took for the sentences it has read at this speed, and an estimate from its pace so far
/// for the rest. After the last sentence the reading stays open (DONE, ▶ reads it again) until the player closes it.
@MainActor
public final class ReadAloudPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    public enum Status: Equatable { case preparing, playing, paused, ended }

    public static let minSpeed = 0.25, maxSpeed = 4.0, speedStep = 0.1

    /// The text being read, as plain text (Markdown taken out).
    @Published public private(set) var text = ""
    /// Its sentences (and lines), as ranges of `text`.
    @Published public private(set) var sentences: [NSRange] = []
    /// The sentence being read.
    @Published public private(set) var index = 0
    /// The word being spoken, as a range of `text`; nil before the voice starts a sentence and after the end.
    @Published public private(set) var spokenRange: NSRange?
    /// A reading is open: preparing, playing, paused, or ended and still showing.
    @Published public private(set) var isOpen = false
    @Published public private(set) var status = Status.ended
    @Published public private(set) var question: ReaderQuestion?
    @Published public private(set) var speed: Double = 1.0
    /// Called when a reading is closed with how many words it had and how long the voice spoke (pauses excluded).
    public var onFinishedReading: ((Int, Double) -> Void)?
    /// What is being read, for the player's header ("SAMANTHA").
    public private(set) var voiceName = ""

    /// Playing or paused: a reading is open and hasn't reached its end.
    public var isSpeaking: Bool { isOpen && status != .ended }
    public var isPaused: Bool { status == .paused }
    /// The player is showing: a reading or a question.
    public var isShowing: Bool { isOpen || question != nil }

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
    /// The utterances queued now: which sentence each one reads and where in `text` it starts.
    private var queued: [ObjectIdentifier: (sentence: Int, start: Int)] = [:]
    /// Where reading picks up when a paused reading is played again after a skip, a click or a speed change.
    private var resumeAt: Int?
    /// Seconds the voice took for each sentence it read whole at the current speed.
    private var measured: [Int: Double] = [:] {
        didSet {
            let n = measured.keys.reduce(0) { $0 + chars[$1] }
            let seconds = measured.values.reduce(0, +)
            pace = n > 20 && seconds > 0 ? seconds / Double(n) : nil
        }
    }
    /// Speaking time of the current utterance so far, and since when it has been running (nil while paused or waiting).
    private var utteranceSeconds = 0.0
    private var runningSince: Date?
    /// The utterance being spoken started at the beginning of its sentence (so its time is the sentence's).
    private var utteranceWhole = false
    /// How long the voice has spoken in this reading, without pauses and waits.
    private var spokenSeconds = 0.0
    /// Each sentence's length as the voice gets it, and seconds per character at this speed once it has read some.
    private var chars: [Int] = []
    private var pace: Double?

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

    // MARK: Starting and stopping

    /// Read `raw` (Markdown is read as the plain text it stands for). A text with nothing to read shows an error.
    public func read(_ raw: String, voice: String?, speed: Double) {
        stop()
        let plain = MarkdownText.forReading(raw)
        let pieces = ReadAloudText.split(plain)
        guard !pieces.isEmpty else { showError("There's nothing to read in that text."); return }
        text = plain
        sentences = pieces
        chars = pieces.map { ReadAloudText.speakable(plain, $0).count }
        voiceID = voice
        voiceName = voice.flatMap(AVSpeechSynthesisVoice.init(identifier:))?.name
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())?.name ?? "System voice"
        self.speed = Self.clamp(speed)
        measured = [:]
        spokenSeconds = 0
        isOpen = true
        speak(from: 0)
    }

    /// Nothing was selected: offer to read the clipboard instead, with a preview, its length and about how long it takes.
    public func askToReadClipboard(_ clipboard: String, voice: String?, speed: Double) {
        stop()
        let plain = MarkdownText.forReading(clipboard) // so the preview, word count and estimate match what is read
        let words = ReadAloudText.words(plain)
        let minutes = Double((plain as NSString).length) * ReadAloudText.defaultSecondsPerChar / 60 / max(speed, Self.minSpeed)
        let flat = plain.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        let preview = flat.count > 200 ? String(flat.prefix(200)).trimmingCharacters(in: .whitespaces) + "…" : flat
        question = ReaderQuestion(title: "Nothing is selected. Read your clipboard?",
                                  body: "“\(preview)”\n\(words.formatted()) words · about \(max(1, Int(minutes.rounded()))) min",
                                  primary: "Read clipboard") { [weak self] in self?.read(clipboard, voice: voice, speed: speed) }
    }

    /// The player's error card: "Read aloud couldn't start", the reason, and OK.
    public func showError(_ message: String) {
        stop()
        question = ReaderQuestion(title: "Read aloud couldn't start", body: message, primary: "OK") { [weak self] in self?.stop() }
    }

    /// A plain message on the player's card with OK (for when there is nothing else to show it on).
    public func showMessage(_ message: String) {
        stop()
        question = ReaderQuestion(title: message, body: "", primary: "OK") { [weak self] in self?.stop() }
    }

    /// Stop reading (or close the question) and close the player.
    public func stop() {
        voiceEngine?.stopSpeaking(at: .immediate)
        queued = [:]
        pauseClock()
        if isOpen { onFinishedReading?(ReadAloudText.words(text), spokenSeconds) }
        isOpen = false
        question = nil
        status = .ended
        spokenRange = nil
        resumeAt = nil
    }

    #if DEBUG
    /// Puts the player in a state without speaking, for the snapshots: `word` is a word of the text (its first
    /// occurrence), nil = the end.
    public func showForSnapshot(_ raw: String, word: String?, status: Status, speed: Double = 1, voice: String = "Samantha") {
        stop()
        text = MarkdownText.forReading(raw)
        sentences = ReadAloudText.split(text)
        chars = sentences.map { ReadAloudText.speakable(text, $0).count }
        self.speed = speed
        voiceName = voice
        isOpen = true
        self.status = status
        if let word {
            let r = (text as NSString).range(of: word)
            spokenRange = r
            index = sentences.lastIndex { $0.location <= r.location } ?? 0
        } else {
            index = sentences.count - 1
        }
    }
    #endif

    // MARK: Controls

    /// Play/pause; at the end, read it again from the start.
    public func togglePause() {
        switch status {
        case .ended: if isOpen { speak(from: 0) }
        case .paused:
            if let at = resumeAt { speak(from: at) } else if let synth = voiceEngine { synth.continueSpeaking(); status = .playing; startClock() }
        case .playing, .preparing:
            synth.pauseSpeaking(at: .word)
            pauseClock()
            status = .paused
        }
    }

    /// Change the reading speed; the current sentence is read again from the same word at the new pace.
    public func setSpeed(_ s: Double) {
        let new = Self.clamp(s)
        guard abs(new - speed) > 0.001 else { return }
        speed = new
        measured = [:] // timings at the old speed no longer hold
        guard isOpen, status != .ended else { return }
        if status == .paused { resumeAt = position } else { speak(from: position) }
    }

    /// Jump by this many seconds of speech, forwards or back (the player's ↺15 / ↻15), on the timeline of all the
    /// sentences. Skipping back from the end reads on from there.
    public func skip(seconds: Double) {
        guard isOpen, !sentences.isEmpty, !(status == .ended && seconds > 0) else { return }
        var now = (0..<index).reduce(0) { $0 + duration($1) } + duration(index) * fraction
        if status == .ended { now = (0..<sentences.count).reduce(0) { $0 + duration($1) } }
        let target = max(0, now + seconds)
        var start = 0.0
        for i in sentences.indices {
            let d = duration(i)
            if target < start + d || i == sentences.count - 1 {
                let f = d > 0 ? min(max((target - start) / d, 0), 0.999) : 0
                go(to: wordStart(sentences[i].location + Int(f * Double(sentences[i].length)), in: i))
                return
            }
            start += d
        }
    }

    /// Read from a character of `text` (a word clicked in the player), forwards or backwards, also from the end.
    /// A click means "read this", so a paused reading plays.
    public func jump(to location: Int) {
        guard isOpen, let i = sentences.lastIndex(where: { $0.location <= location }) ?? sentences.indices.first else { return }
        speak(from: wordStart(min(location, NSMaxRange(sentences[i])), in: i))
    }

    // MARK: Where it is

    /// How far into the current sentence the voice is, 0…1.
    public var fraction: Double {
        guard sentences.indices.contains(index) else { return 0 }
        if status == .ended { return 1 }
        let s = sentences[index]
        let at = spokenRange?.location ?? resumeAt ?? s.location
        return s.length == 0 ? 0 : min(max(Double(at - s.location) / Double(s.length), 0), 1)
    }

    /// How much of the whole reading is done, 0…1, by time.
    public var progress: Double {
        guard isOpen, !sentences.isEmpty else { return 0 }
        if status == .ended { return 1 }
        var before = 0.0, total = 0.0
        for i in sentences.indices {
            let d = duration(i)
            total += d
            if i < index { before += d }
        }
        return total > 0 ? min(max((before + duration(index) * fraction) / total, 0), 1) : 1
    }

    /// Seconds left at the current speed: real durations for the sentences read at this speed, estimates for the rest.
    public var secondsLeft: Double {
        guard isOpen, status != .ended, sentences.indices.contains(index) else { return 0 }
        return duration(index) * (1 - fraction) + (index + 1 ..< sentences.count).reduce(0) { $0 + duration($1) }
    }

    /// One sentence's speaking time at the current speed: as measured, or from the voice's pace so far.
    private func duration(_ i: Int) -> Double {
        guard sentences.indices.contains(i) else { return 0 }
        return measured[i] ?? Double(chars[i]) * (pace ?? ReadAloudText.defaultSecondsPerChar / speed)
    }

    /// Where the voice is now, as a character of `text`.
    private var position: Int {
        spokenRange?.location ?? resumeAt ?? (sentences.indices.contains(index) ? sentences[index].location : 0)
    }

    // MARK: Speaking

    /// Move to a character: read from there, or, while paused, wait there.
    private func go(to location: Int) {
        if status == .paused {
            index = sentences.lastIndex { $0.location <= location } ?? 0
            spokenRange = nil
            resumeAt = location
        } else {
            speak(from: location)
        }
    }

    /// Read from a character of `text`: the rest of its sentence, then every sentence after it, one utterance each.
    private func speak(from location: Int) {
        guard !sentences.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        queued = [:]
        pauseClock()
        let first = sentences.lastIndex { $0.location <= location } ?? 0
        let voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        // AVSpeechUtterance's rate is not linear in speed; default 0.5 ≈ 1×, max 1.0 ≈ 2×+.
        let rate = Float(min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate,
                                                                     AVSpeechUtteranceDefaultSpeechRate * Float(pow(speed, 0.6)))))
        let ns = text as NSString
        for i in first..<sentences.count {
            let s = sentences[i]
            let start = i == first ? min(max(location, s.location), NSMaxRange(s)) : s.location
            let u = AVSpeechUtterance(string: ns.substring(with: NSRange(location: start, length: NSMaxRange(s) - start)))
            u.voice = voice
            u.rate = rate
            queued[ObjectIdentifier(u)] = (i, start)
            synth.speak(u)
        }
        index = first
        spokenRange = nil
        resumeAt = nil
        status = .preparing
        utteranceWhole = false
    }

    private func startClock() { if runningSince == nil { runningSince = Date() } }

    private func pauseClock() {
        guard let since = runningSince else { return }
        let t = Date().timeIntervalSince(since)
        utteranceSeconds += t
        spokenSeconds += t
        runningSince = nil
    }

    /// The start of the word at `location`, not before its sentence.
    private func wordStart(_ location: Int, in sentence: Int) -> Int {
        let ns = text as NSString
        var at = location
        let floor = sentences[sentence].location
        while at > floor, !ReadAloudText.isSpace(ns.character(at: at - 1)) { at -= 1 }
        return at
    }

    private static func clamp(_ s: Double) -> Double { (min(maxSpeed, max(minSpeed, s)) * 100).rounded() / 100 }

    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        MainActor.assumeIsolated {
            guard let q = queued[id] else { return }
            index = q.sentence
            utteranceWhole = q.start == sentences[q.sentence].location
            utteranceSeconds = 0
            runningSince = nil
            startClock()
            if status != .paused { status = .playing }
        }
    }

    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        MainActor.assumeIsolated {
            guard let q = queued[id] else { return }
            spokenRange = NSRange(location: range.location + q.start, length: range.length)
        }
    }

    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { pauseClock() }
    }

    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { if status == .playing { startClock() } }
    }

    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        MainActor.assumeIsolated {
            guard let q = queued.removeValue(forKey: id) else { return } // a restart (speed, skip, click) cancelled it
            pauseClock()
            if utteranceWhole { measured[q.sentence] = utteranceSeconds }
            if queued.isEmpty {
                // The end: the card stays (DONE, ▶ = read again) until the player closes it.
                index = sentences.count - 1
                spokenRange = nil
                status = .ended
            }
        }
    }
}
