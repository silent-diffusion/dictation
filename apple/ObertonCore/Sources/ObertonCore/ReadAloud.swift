import AVFoundation
import Foundation

/// A question the player asks before it reads ("Nothing is selected. Read your clipboard?"), why it couldn't start,
/// or a voice download under way (then it has no buttons; `progress` fills the bar and ✕ cancels).
public struct ReaderQuestion {
    public var title: String
    public var body: String
    /// The primary button's label ("Read clipboard", "Download", "OK").
    public var primary: String
    public var action: @MainActor () -> Void
    /// A download is running: how far it is (nil inside while unknown).
    public var progress: Double?? = nil
}

/// Reads text aloud (Windows' ReaderWindow and ReadAloudSession): Kokoro, Piper or the system's voices, one sentence
/// at a time, through `ReadAloudSession`. It reports the sentence and the word being spoken, for the player's
/// highlight: the word the system's voices say they are on, or, for Kokoro and Piper, the word as far into the
/// sentence as the audio is (as Windows estimates it). Before a voice that isn't downloaded it asks to download it.
/// After the last sentence the reading stays open (DONE, ▶ reads it again) until the player closes it.
@MainActor
public final class ReadAloudPlayer: ObservableObject {
    public enum Status: Equatable { case preparing, playing, paused, ended }

    nonisolated public static let minSpeed = 0.25, maxSpeed = 4.0, speedStep = 0.1

    /// The text being read, as plain text (Markdown taken out).
    @Published public private(set) var text = ""
    /// The text with its formatting (headings, lists, quotes, bold, links…), for the player's whole-text view; its
    /// `plain` is `text`.
    @Published public private(set) var doc = MarkdownDoc.parse("")
    /// Its sentences (and lines), as ranges of `text`.
    @Published public private(set) var sentences: [NSRange] = []
    /// The sentence being read.
    @Published public private(set) var index = 0
    /// The word being spoken, as a range of `text`; nil after the end.
    @Published public private(set) var spokenRange: NSRange?
    /// A reading is open: preparing, playing, paused, or ended and still showing.
    @Published public private(set) var isOpen = false
    @Published public private(set) var status = Status.ended
    @Published public private(set) var question: ReaderQuestion?
    @Published public private(set) var speed: Double = 1.0
    /// A voice download (from here, the Read aloud page or Models): which voice, and how it is going.
    @Published public private(set) var install: (voice: String, progress: VoiceProgress)?
    /// Called when a reading is closed with how many words it had and how long the voice spoke (pauses excluded).
    public var onFinishedReading: ((Int, Double) -> Void)?
    /// The voice being read with, for the dashboard ("Heart", "Samantha").
    public private(set) var voiceName = ""

    /// Playing or paused: a reading is open and hasn't reached its end.
    public var isSpeaking: Bool { isOpen && status != .ended }
    public var isPaused: Bool { status == .paused }
    /// The player is showing: a reading or a question (or a download it started).
    public var isShowing: Bool { isOpen || question != nil }

    private var session: ReadAloudSession?
    private var tick: Timer?
    private var installTask: Task<Void, Never>?
    /// The player asked for the download running now (so ✕ cancels it and the reading follows).
    private var installFromPlayer = false

    public init() {}

    /// A voice is in memory (it has read something since it was last let go).
    public var isLoaded: Bool { SpeechVoices.shared.isLoaded }

    /// Let the voices go (Settings › Model unloading); they load again on the next reading. Not while reading.
    public func unload() {
        guard !isSpeaking else { return }
        SpeechVoices.shared.unload()
    }

    // MARK: Starting and stopping

    /// Read `raw` aloud (Markdown is read as the plain text it stands for), downloading the voice first if needed,
    /// after asking. A text with nothing to read shows an error.
    public func read(_ raw: String, voice: String?, speed: Double) {
        let voice = voice?.isEmpty == false ? voice! : VoiceCatalog.defaultVoice
        guard VoiceCatalog.isInstalled(voice) else { askToDownload(raw, voice: voice, speed: speed); return }
        start(raw, voice: voice, speed: speed)
    }

    private func start(_ raw: String, voice: String, speed: Double) {
        stop()
        let parsed = MarkdownDoc.parse(raw)
        let plain = parsed.plain
        let s = ReadAloudSession(text: plain, voice: voice, speed: speed)
        guard !s.sentences.isEmpty else { showError("There's nothing to read in that text."); return }
        doc = parsed
        text = plain
        sentences = s.sentences
        voiceName = VoiceCatalog.shortName(voice)
        self.speed = ReadAloudSession.clamp(speed)
        s.onFinished = { [weak self] in self?.refresh() }
        s.onFailed = { [weak self] message in self?.showError(message) }
        do {
            try s.start()
        } catch {
            CoreLog.error("Read aloud playback failed to start: \(error.localizedDescription)")
            showError("Playback failed: \(error.localizedDescription)")
            return
        }
        session = s
        isOpen = true
        index = 0
        spokenRange = nil
        status = .preparing
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Nothing was selected: offer to read the clipboard instead, with a preview, its length and about how long it takes.
    public func askToReadClipboard(_ clipboard: String, voice: String?, speed: Double) {
        stop()
        let plain = MarkdownText.forReading(clipboard) // so the preview, word count and estimate match what is read
        let words = ReadAloudText.words(plain)
        let units = plain.utf16.count
        let minutes = Double(units) * ReadAloudText.defaultSecondsPerChar / 60 / max(speed, Self.minSpeed)
        var preview = units > 200 ? String(utf16CodeUnits: Array(plain.utf16.prefix(200)), count: 200) : plain
        if units > 200 { preview = preview.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "…" }
        preview = preview.replacingOccurrences(of: #"\r\n|[\r\n\u{2028}\u{2029}\u{85}]"#, with: " ", options: .regularExpression)
        let about = max(1, Int(minutes.rounded(.toNearestOrEven)))
        question = ReaderQuestion(title: "Nothing is selected. Read your clipboard?",
                                  body: "“\(preview)”\n\(words.formatted()) words · about \(about) min",
                                  primary: "Read clipboard") { [weak self] in self?.read(plain, voice: voice, speed: speed) }
    }

    /// The voice isn't here: say why, or offer its one-time download (ReaderWindow.Read).
    private func askToDownload(_ raw: String, voice: String, speed: Double) {
        let noun = VoiceCatalog.deviceNoun
        switch VoiceCatalog.modelOf(voice) {
        case VoiceCatalog.system:
            showError("The \(noun) voice \"\(VoiceCatalog.shortName(voice))\" isn't installed on this \(noun) any more. Pick another voice under Read aloud.")
        case VoiceCatalog.piper:
            guard let piper = VoiceCatalog.findPiper(voice) else {
                showError("That voice isn't available. Pick another voice under Read aloud.")
                return
            }
            stop()
            question = ReaderQuestion(title: "The voice \(piper.label) needs a one-time download",
                                      body: "It's a Piper voice of about \(piper.mb) MB. It runs entirely on this \(noun), so after this nothing you read leaves it.",
                                      primary: "Download") { [weak self] in self?.downloadThenRead(raw, voice: voice, speed: speed) }
        default:
            stop()
            question = ReaderQuestion(title: "Read aloud needs a one-time download",
                                      body: "Oberton's voice (Kokoro) is about \(VoiceInstaller.kokoroDownloadMb) MB. It runs entirely on this \(noun), so after this nothing you read leaves it.",
                                      primary: "Download") { [weak self] in self?.downloadThenRead(raw, voice: voice, speed: speed) }
        }
    }

    private func downloadThenRead(_ raw: String, voice: String, speed: Double) {
        installFromPlayer = true
        showDownload(VoiceProgress(step: 1, totalSteps: 1, title: "", fraction: nil, detail: ""))
        installVoice(voice) { [weak self] result in
            guard let self else { return }
            self.installFromPlayer = false
            switch result {
            case .success: self.start(raw, voice: voice, speed: speed)
            case .failure(let error as UserFacingError): self.showError(error.message)
            case .failure(is CancellationError): self.stop()
            case .failure(let error):
                CoreLog.error("Read aloud install failed: \(error.localizedDescription)")
                self.showError("The voice download failed. See the log for details, and try again.")
            }
        }
    }

    private func showDownload(_ p: VoiceProgress) {
        let detail = p.title + (p.detail.isEmpty ? "" : " · " + p.detail)
        question = ReaderQuestion(title: "Downloading the voice…", body: detail, primary: "", action: {}, progress: .some(p.fraction))
    }

    /// Download a voice's model (Kokoro, or one Piper voice) and report back on the main thread. One at a time.
    public func installVoice(_ voice: String, done: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }) {
        guard install == nil else { done(.failure(UserFacingError("Another voice is downloading. Wait for it to finish, and try again."))); return }
        install = (voice, VoiceProgress(step: 1, totalSteps: 1, title: "Starting the download", fraction: nil, detail: ""))
        // The player lives as long as the app, so the download may hold on to it.
        installTask = Task { [self] in
            let report: @Sendable (VoiceProgress) -> Void = { p in
                Task { @MainActor in
                    guard self.install?.voice == voice else { return }
                    self.install = (voice, p)
                    if self.installFromPlayer, self.question?.progress != nil { self.showDownload(p) }
                }
            }
            let result: Result<Void, Error>
            do {
                if let piper = VoiceCatalog.findPiper(voice) { try await VoiceInstaller.installPiper(piper, progress: report) }
                else { try await VoiceInstaller.installKokoro(progress: report) }
                result = .success(())
            } catch {
                result = .failure(Task.isCancelled ? CancellationError() : error)
            }
            self.install = nil
            self.installTask = nil
            done(result)
        }
    }

    /// Stop the voice download (the player's ✕, leaving the Read aloud page).
    public func cancelInstall() { installTask?.cancel() }

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

    /// Stop reading (or cancel the question or the player's download) and close the player.
    public func stop() {
        if installFromPlayer { installTask?.cancel() }
        tick?.invalidate()
        tick = nil
        if let s = session {
            s.stop()
            onFinishedReading?(ReadAloudText.words(text), s.spokenSeconds)
        }
        session = nil
        isOpen = false
        question = nil
        status = .ended
        spokenRange = nil
    }

    #if DEBUG
    /// Puts the player in a state without speaking, for the snapshots: `word` is a word of the text (its first
    /// occurrence), nil = the end.
    public func showForSnapshot(_ raw: String, word: String?, status: Status, speed: Double = 1, voice: String = "Heart") {
        stop()
        doc = MarkdownDoc.parse(raw)
        text = doc.plain
        sentences = ReadAloudText.split(text)
        self.speed = speed
        voiceName = voice
        isOpen = true
        self.status = status
        snapshotFraction = nil
        if let word {
            let r = (text as NSString).range(of: word)
            spokenRange = r
            index = sentences.lastIndex { $0.location <= r.location } ?? 0
            let s = sentences[index]
            snapshotFraction = s.length > 0 ? Double(r.location - s.location) / Double(s.length) : 0
        } else {
            index = sentences.count - 1
        }
    }

    /// Puts a download on the player's card, for the snapshots.
    public func showDownloadForSnapshot(_ p: VoiceProgress) {
        stop()
        showDownload(p)
    }

    private var snapshotFraction: Double?
    #endif

    // MARK: Controls

    /// Play/pause; at the end, read it again from the start.
    public func togglePause() {
        guard let s = session else { return }
        if s.isEnded { s.skip(-1e9) } else { s.togglePause() }
        refresh()
    }

    /// Change the reading speed; the current sentence goes on from the same point at the new pace. Ignored once
    /// the reading has ended, as on Windows.
    public func setSpeed(_ new: Double) {
        guard let s = session else { return }
        s.setSpeed(new)
        refresh()
    }

    /// Jump by this many seconds of speech, forwards or back (the player's ↺15 / ↻15), on the timeline of all the
    /// sentences. Skipping back from the end reads on from there.
    public func skip(seconds: Double) {
        session?.skip(seconds)
        refresh()
    }

    /// Read from a character of `text` (a word clicked in the player), forwards or backwards, also from the end.
    /// Only a click inside a sentence counts. A click means "read this", so a paused reading plays.
    public func jump(to location: Int) {
        guard let s = session, let i = sentences.firstIndex(where: { $0.location <= location && location <= NSMaxRange($0) }) else { return }
        let span = sentences[i]
        let ns = text as NSString
        var at = min(location, NSMaxRange(span))
        while at > span.location, !ReadAloudText.isSpace(ns.character(at: at - 1)) { at -= 1 }
        s.jump(to: i, fraction: span.length == 0 ? 0 : Double(at - span.location) / Double(span.length))
        if s.isPaused { s.togglePause() }
        refresh()
    }

    // MARK: Where it is

    /// How far into the current sentence the voice is, 0…1.
    public var fraction: Double {
        #if DEBUG
        if session == nil, let f = snapshotFraction { return status == .ended ? 1 : f }
        #endif
        guard let s = session else { return status == .ended && isOpen ? 1 : 0 }
        return s.isEnded ? 1 : s.position.fraction
    }

    /// How much of the whole reading is done, 0…1, by time.
    public var progress: Double {
        #if DEBUG
        if session == nil, isOpen { return status == .ended ? 1 : (Double(index) + fraction) / Double(max(1, sentences.count)) }
        #endif
        return session?.progress ?? 0
    }

    /// Seconds left at the current speed: real durations for the sentences made so far, estimates for the rest.
    public var secondsLeft: Double {
        #if DEBUG
        if session == nil, isOpen, status != .ended {
            return Double((text as NSString).length) * (1 - progress) * ReadAloudText.defaultSecondsPerChar / max(speed, Self.minSpeed)
        }
        #endif
        return session?.remaining ?? 0
    }

    /// Bring the published state up to date with the audio (ten times a second while reading).
    private func refresh() {
        guard let s = session else { return }
        let ended = s.isEnded
        let (i, f, word) = s.position
        let newStatus: Status = ended ? .ended : s.isPaused ? .paused : s.isBuffering ? .preparing : .playing
        if status != newStatus { status = newStatus }
        if index != i { index = i }
        if abs(speed - s.currentSpeed) > 0.0001 { speed = s.currentSpeed }
        let range = ended ? nil : word ?? estimatedWord(i, f)
        if spokenRange != range { spokenRange = range }
        objectWillChange.send() // time left and progress
    }

    /// The word as far into the sentence as the audio is: from the space before that point to the next one
    /// (ReaderWindow.ShowLines).
    private func estimatedWord(_ i: Int, _ fraction: Double) -> NSRange? {
        guard sentences.indices.contains(i) else { return nil }
        let span = sentences[i]
        let ns = text as NSString
        let upto = Int((fraction * Double(span.length)).rounded())
        var start = span.location + min(upto, span.length)
        while start > span.location, !ReadAloudText.isSpace(ns.character(at: start - 1)) { start -= 1 }
        var end = span.location + min(upto, span.length)
        while end < NSMaxRange(span), !ReadAloudText.isSpace(ns.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }
}
