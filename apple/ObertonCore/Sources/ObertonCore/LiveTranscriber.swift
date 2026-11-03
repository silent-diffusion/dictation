import AVFoundation
import Foundation
import Speech

/// Microphone → Apple's on-device speech recognizer (SpeechAnalyzer + SpeechTranscriber), or a downloaded Whisper
/// model (`startWhisper`). Recording starts at once (`startRecording`); the recognizer gets ready meanwhile
/// (`startRecognizer` / `startWhisper`) and catches up on what was said, as on Windows. The words recognized so far come back while the user speaks, for the overlay; `stop()` returns the whole
/// transcript once the recognizer has finished with the last of the audio. Nothing leaves the device.
///
/// The engine is started and stopped on the main actor only, in the order the calls come: a stop or cancel running on
/// another thread could otherwise stop the next recording's engine, or start and stop it at the same time.
public final class LiveTranscriber: @unchecked Sendable {
    /// Called on the main queue with the transcript so far (settled words plus the recognizer's current guess).
    public var onText: ((String) -> Void)?
    /// Called on the main queue with the microphone level, 0…1, for the meter.
    public var onLevel: ((Float) -> Void)?
    /// Called on the audio thread with each microphone buffer as it comes in (History keeps the recording).
    public var onAudio: ((AVAudioPCMBuffer) -> Void)?
    /// Called on the main queue, once per recording, when the microphone has given 2 s of pure zeros and nothing else:
    /// usually microphone access blocked in Privacy & Security.
    public var onSilence: (() -> Void)?
    /// Live mode ("type as you speak"): a finished piece of the speech, whole sentences about every 5 s (Windows'
    /// `Committed`), on the main queue, in order.
    public var onPiece: ((String) -> Void)?
    /// Live mode: the recognizer's running guess at the speech since the last piece (Windows' `PartialTranscript`),
    /// on the main queue. Empty right after a piece.
    public var onGuess: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Error>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    /// Evens out the volume for Apple's recognizer as the audio comes in. Whisper gets the audio as recorded and evens
    /// out the whole of it before each decode (`WhisperPrep.evened`), as Windows' speech engine does.
    private var leveller: VolumeLeveller?
    private var evenOut = true
    /// Set instead of `analyzer` when this recording goes to Whisper.
    private var whisper: WhisperDictation?
    private let lock = NSLock()
    /// The pieces the recognizer settled, in order, and its running guess at the rest.
    private var pieces: [String] = []
    private var volatile = ""
    /// The finished pieces' words, timed from the recording's start.
    private var heardWords: [SpokenWord] = []
    /// The words of the transcript the last `stop()` returned, timed from its recording's start (History keeps them, so
    /// playback can light the word being said). Empty when the engine gave none.
    @MainActor public private(set) var lastWords: [SpokenWord] = []
    /// Live mode: pieces are handed out (`onPiece`) while recording. `heldText` is what Apple's recognizer settled since
    /// the last piece, ending at `heldEnd` seconds into the recording; the last piece ended at `pieceEnd`.
    private var live = false
    private var stopping = false
    private var heldText = ""
    private var heldEnd = 0.0, pieceEnd = 0.0
    private var tail = ""
    /// Audio recorded before the recognizer was ready, fed to it once it is.
    private var waiting: [AVAudioPCMBuffer] = []
    private var streaming = false
    /// Changes with every recording, so a recognizer that gets ready after its recording was thrown away stands down.
    private var generation = 0
    private var peakLevel: Float = 0
    private var silentFrames = 0
    private var sawSignal = false

    public init() {}

    /// Live mode: the speech after the last piece, once `stop()` has returned (Windows' `FinalTail`): what live typing
    /// still has to add when its final pass can't replace what it typed.
    public var finalTail: String { lock.withLock { tail } }

    /// The loudest input level of this recording, on Windows' meter scale (`SpeechGuard.speechLevel`).
    public var peak: Float { lock.withLock { peakLevel } }

    private static let retainedLock = NSLock()
    nonisolated(unsafe) private static var retained = false

    /// The speech model has been used since it was last let go: the system keeps it in memory for a while after each
    /// use. Extended Notes' own analyzer counts too (`markInUse`).
    public static var modelRetained: Bool { retainedLock.withLock { retained } }
    public static func markInUse() { retainedLock.withLock { retained = true } }

    /// Free the speech model's memory now (the dashboard's Unload everything); it loads again on the next dictation.
    /// The downloaded model stays on the device.
    public static func unloadModel() async {
        await SpeechModels.endRetention()
        retainedLock.withLock { retained = false }
    }

    /// The languages whose speech model is on the device (Settings › Advanced › LOCAL MODELS), as identifiers.
    public static func installedLanguages() async -> [String] {
        await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
    }

    /// Make sure the speech model for this language is on the device (downloads it once, through the system).
    public static func prepare(locale: Locale) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw UserFacingError("On-device speech recognition isn't available on this device.") }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw UserFacingError("Speech recognition doesn't support \(locale.identifier) yet.")
        }
        let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        return supported
    }

    /// The first-run setup: download the speech model for this language if it isn't on the device yet, reporting the
    /// fraction done (nil while unknown). Returns false when it was already there.
    public static func download(locale: Locale, progress: @escaping @MainActor (Double?) -> Void) async throws -> Bool {
        guard SpeechTranscriber.isAvailable else { throw UserFacingError("On-device speech recognition isn't available on this device.") }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw UserFacingError("Speech recognition doesn't support \(locale.identifier) yet.")
        }
        let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return false }
        let watch = Task { @MainActor in
            while !Task.isCancelled {
                let p = request.progress
                progress(p.totalUnitCount > 0 ? p.fractionCompleted : nil)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watch.cancel() }
        try await request.downloadAndInstall()
        await progress(1)
        return true
    }

    /// Load the speech model ahead of the first dictation (at launch, and when the profile or language changes), so the
    /// first hotkey press is quick. Downloads it first if needed.
    public static func warmUp(locale: Locale) async throws {
        let locale = try await prepare(locale: locale)
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]))
        await analyzer.cancelAndFinishNow()
        markInUse()
    }

    /// Start listening now. Audio is kept until `startRecognizer` has the recognizer ready. `microphone`: a device name
    /// from `Microphones.names`, nil for the system default. `evenOut`: level the volume before the recognizer hears it.
    @MainActor public func startRecording(microphone: String?, evenOut: Bool) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        Microphones.use(microphone, on: engine)
        lock.withLock {
            generation += 1
            pieces = []; volatile = ""; heardWords = []; waiting = []; streaming = false
            live = false; stopping = false; heldText = ""; heldEnd = 0; pieceEnd = 0; tail = ""
            peakLevel = 0; silentFrames = 0; sawSignal = false
            self.evenOut = evenOut
        }
        #if DEBUG
        if let url = Self.fakeAudio { try playFake(url, evenOut: evenOut); return }
        #endif
        let node = engine.inputNode
        let micFormat = node.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw UserFacingError(Self.noMicrophone)
        }
        let leveller = evenOut ? VolumeLeveller(sampleRate: micFormat.sampleRate) : nil
        lock.withLock { self.leveller = leveller }
        try Microphones.tap(node, bufferSize: 4096) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            node.removeTap(onBus: 0)
            throw UserFacingError(Self.micWontOpen)
        }
    }

    /// Get the recognizer ready (downloading and loading its model if needed), then hand it everything recorded so far.
    /// `live`: hand out finished pieces and the running guess while recording (`onPiece`, `onGuess`).
    public func startRecognizer(locale: Locale, vocabulary: [String], live: Bool = false) async throws {
        let mine = lock.withLock { generation }
        let locale = try await Self.prepare(locale: locale)
        Self.markInUse()
        // Audio time ranges: when each word was said, for History's playback.
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        guard lock.withLock({ generation == mine }) else { await analyzer.cancelAndFinishNow(); return }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task { [weak self] in
            for try await result in transcriber.results {
                guard let self else { return }
                let text = String(result.text.characters)
                let (full, piece, guess): (String, String?, String?) = self.lock.withLock {
                    if result.isFinal { self.pieces.append(text); self.volatile = ""; self.heardWords += WordTimes.words(result.text) }
                    else { self.volatile = text }
                    let full = FragmentStitcher.join(self.pieces + [self.volatile])
                    guard self.live else { return (full, nil, nil) }
                    let (piece, guess) = self.livePiece(text, final: result.isFinal, end: result.range.end.seconds)
                    return (full, piece, guess)
                }
                let (cb, onPiece, onGuess) = (self.onText, self.onPiece, self.onGuess)
                DispatchQueue.main.async {
                    cb?(full)
                    if let piece { onPiece?(piece) }
                    if let guess { onGuess?(guess) }
                }
            }
        }
        do { try await analyzer.start(inputSequence: stream) } catch { results.cancel(); throw error }
        let current = lock.withLock {
            guard generation == mine else { return false }
            self.live = live
            self.analyzer = analyzer
            self.analyzerFormat = format
            self.input = continuation
            self.resultsTask = results
            for buffer in waiting { feed(buffer) }
            waiting = []
            streaming = true
            return true
        }
        if !current { results.cancel(); await analyzer.cancelAndFinishNow() }
    }

    /// Get the Whisper model ready (loading it if needed), then hand it everything recorded so far. While the user
    /// speaks, the running transcript of the last 28 s comes back about once a second (asr_server.py's partials).
    /// `prompt`: the vocabulary hint as typed. `live`: asr_server.py's live mode instead, finished sentences handed out
    /// about every 5 s (`onPiece`) and the running guess at the rest in between (`onGuess`).
    public func startWhisper(model: String, language: String?, prompt: String, live: Bool = false) async throws {
        let (mine, even) = lock.withLock { (generation, evenOut) }
        try await WhisperEngine.shared.load(model)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else { return }
        let dictation = WhisperDictation(model: model, language: language, prompt: prompt, even: even, live: live) { [weak self] text in
            let cb = self?.onText
            DispatchQueue.main.async { cb?(text) }
        }
        // A piece decoded just after the stop still counts (it isn't in the tail); the caller ignores late guesses.
        dictation.onPiece = { [weak self] piece in
            let cb = self?.onPiece
            DispatchQueue.main.async { cb?(piece) }
        }
        dictation.onGuess = { [weak self] guess in
            let cb = self?.onGuess
            DispatchQueue.main.async { cb?(guess) }
        }
        let current = lock.withLock {
            guard generation == mine else { return false }
            self.live = live
            whisper = dictation
            analyzerFormat = format
            for buffer in waiting { feed(buffer) }
            waiting = []
            streaming = true
            return true
        }
        if current { dictation.startPartials() }
    }

    /// Live mode with Apple's recognizer (called with the lock held): what it settled builds up until it ends a sentence
    /// at least 5 s after the last piece, or runs 12 s without one (asr_server.py's commit rule); that is the next piece.
    /// Returns the piece, if one is due, and the running guess at the speech since the last piece. Once the user has
    /// stopped, nothing more is handed out: the rest is the final tail.
    private func livePiece(_ text: String, final: Bool, end: Double) -> (String?, String?) {
        guard !stopping else { return (nil, nil) }
        if final {
            heldText = FragmentStitcher.join([heldText, text].filter { !$0.isEmpty })
            heldEnd = end.isFinite ? end : heldEnd
            let pending = heldEnd - pieceEnd
            let sentence = heldText.trimmingCharacters(in: CharacterSet(charactersIn: "\"')").union(.whitespaces))
            let ends = sentence.hasSuffix(".") || sentence.hasSuffix("!") || sentence.hasSuffix("?")
            if !heldText.isEmpty, (ends && pending >= WhisperLive.chunkSeconds) || pending >= WhisperLive.forceSeconds {
                let piece = heldText
                heldText = ""
                pieceEnd = heldEnd
                return (piece, "")
            }
        }
        let guess = [heldText, final ? "" : text].filter { !$0.isEmpty }
        return (nil, guess.isEmpty ? "" : FragmentStitcher.join(guess))
    }

    /// The level on Windows' meter scale (`sqrt(rms) · 1.8`), used for the speech guard's peak.
    static func speechLevel(rms: Float) -> Float { min(1, rms.squareRoot() * 1.8) }

    /// The level for Settings › Microphone's test bar: −55 dB … −5 dB → 0…1.
    static func meterLevel(rms: Float) -> Float { min(1, max(0, (20 * log10(max(rms, 1e-6)) + 55) / 50)) }

    /// MicCapture's messages, in the Mac's words.
    #if os(macOS)
    static let noMicrophone = "No microphone was found. Plug one in or enable it in System Settings › Sound."
    static let micWontOpen = "Could not open the microphone. Check that it is connected and that macOS allows Oberton to use it (System Settings › Privacy & Security › Microphone)."
    #else
    static let noMicrophone = "No microphone was found. Plug one in, or check Settings › Privacy & Security › Microphone."
    static let micWontOpen = "Could not open the microphone. Check that Oberton may use it (Settings › Privacy & Security › Microphone)."
    #endif

    /// The meter's levels for a buffer, one per 50 ms of it, on Windows' scale (MicCapture: `min(1, √rms · 1.8)`, about
    /// 20 a second); the overlay takes √ again.
    static func meterLevels(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
        let n = Int(buffer.frameLength), step = max(1, Int(buffer.format.sampleRate * 0.05))
        return stride(from: 0, to: n, by: step).map { start in
            let end = min(n, start + step)
            var sum: Float = 0
            for i in start..<end { sum += data[i] * data[i] }
            return speechLevel(rms: (sum / Float(end - start)).squareRoot())
        }
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float)? {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        var sum: Float = 0, peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i]; peak = max(peak, abs(data[i])) }
        return ((sum / Float(buffer.frameLength)).squareRoot(), peak)
    }

    /// Microphone audio (the audio thread): metered, levelled, and passed to the recognizer, or kept until it's ready.
    private func capture(_ tap: AVAudioPCMBuffer) {
        guard let buffer = Self.copy(tap) else { return }
        var silent = false
        if let (rms, peak) = Self.rms(buffer) {
            let meter = Self.meterLevels(buffer), spoken = Self.speechLevel(rms: rms)
            silent = lock.withLock {
                peakLevel = max(peakLevel, spoken)
                if peak > 0 { sawSignal = true; return false }
                guard !sawSignal else { return false }
                silentFrames += Int(buffer.frameLength)
                let twoSeconds = Int(buffer.format.sampleRate * 2)
                return silentFrames >= twoSeconds && silentFrames - Int(buffer.frameLength) < twoSeconds
            }
            let cb = onLevel
            DispatchQueue.main.async { for level in meter { cb?(level) } }
        }
        if silent { let cb = onSilence; DispatchQueue.main.async { cb?() } }
        onAudio?(buffer) // as recorded: History's "Run again" evens it out afresh
        lock.withLock {
            if streaming { feed(buffer) } else { waiting.append(buffer) }
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let n = Int(buffer.frameLength)
        if let from = buffer.floatChannelData, let to = out.floatChannelData {
            for c in 0..<Int(buffer.format.channelCount) { to[c].update(from: from[c], count: n) }
        } else if let from = buffer.int16ChannelData, let to = out.int16ChannelData {
            for c in 0..<Int(buffer.format.channelCount) { to[c].update(from: from[c], count: n) }
        } else {
            return nil
        }
        return out
    }

    /// Hand one buffer to the recognizer (called with the lock held): evened out first for Apple's.
    private func feed(_ buffer: AVAudioPCMBuffer) {
        if whisper == nil, let leveller, let channels = buffer.floatChannelData {
            leveller.process((0..<Int(buffer.format.channelCount)).map { channels[$0] }, count: Int(buffer.frameLength))
        }
        guard let format = analyzerFormat, buffer.format != format else { deliver(buffer); return }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { deliver(out) }
    }

    /// A buffer in the recognizer's format, to Apple's analyzer or to Whisper (called with the lock held).
    private func deliver(_ buffer: AVAudioPCMBuffer) {
        if let whisper { whisper.append(buffer) } else { input?.yield(AnalyzerInput(buffer: buffer)) }
    }

    /// Stop listening now (the recognizer may still be getting ready; `stop()` then collects the transcript).
    @MainActor public func stopRecording() {
        stopAudio()
        lock.withLock { stopping = true }
    }

    /// Stop listening and wait for the recognizer to settle the last words. Returns the whole transcript, its pieces
    /// stitched (`FragmentStitcher`). Call once the recognizer has started (or failed to). A recording started while
    /// this waits (after a `cancel`) is left alone.
    @MainActor public func stop() async -> String {
        stopAudio()
        let (mine, analyzer, results, whisper) = lock.withLock {
            input?.finish()
            return (generation, self.analyzer, resultsTask, self.whisper)
        }
        lock.withLock { stopping = true }
        if let whisper {
            let (text, tail) = await whisper.finish()
            lastWords = whisper.words
            lock.withLock { if generation == mine { self.tail = tail; clear() } }
            return text
        }
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = try? await results?.value
        let (parts, words) = lock.withLock {
            defer { if generation == mine { clear() } }
            // What was settled since the last piece, and the last guess: the speech live typing hasn't had yet.
            if live { tail = FragmentStitcher.join([heldText, volatile].filter { !$0.isEmpty }) }
            return (pieces + [volatile], heardWords)
        }
        lastWords = words
        return FragmentStitcher.join(parts)
    }

    /// Throw the recording away, at once: a recording started right after it is not touched.
    @MainActor public func cancel() {
        stopAudio()
        let (analyzer, results, whisper) = lock.withLock {
            input?.finish()
            defer { clear() }
            return (self.analyzer, resultsTask, self.whisper)
        }
        whisper?.cancel()
        results?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }

    #if DEBUG
    /// Debug: a recording played in place of the microphone, in real time (Windows' DICTATION_FAKE_AUDIO).
    nonisolated(unsafe) public static var fakeAudio: URL?
    private var fakeTask: Task<Void, Never>?

    @MainActor private func playFake(_ url: URL, evenOut: Bool) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let leveller = evenOut ? VolumeLeveller(sampleRate: file.processingFormat.sampleRate) : nil
        lock.withLock { self.leveller = leveller }
        fakeTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
                      (try? file.read(into: buffer, frameCount: 4096)) != nil, buffer.frameLength > 0 else { return }
                self?.capture(buffer)
                try? await Task.sleep(for: .seconds(Double(buffer.frameLength) / file.processingFormat.sampleRate))
            }
        }
    }
    #endif

    @MainActor private func stopAudio() {
        #if DEBUG
        fakeTask?.cancel()
        fakeTask = nil
        #endif
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        #if os(iOS)
        // Extended Notes may still be recording through the same audio session.
        if !Self.audioSessionHeld { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
    }

    /// Set while something else (an Extended Notes session) records, so a dictation ending leaves the audio session on.
    nonisolated(unsafe) public static var audioSessionHeld = false

    /// Forget the recording (called with the lock held).
    private func clear() {
        generation += 1
        analyzer = nil
        whisper = nil
        input = nil
        resultsTask = nil
        converter = nil
        waiting = []
        streaming = false
        leveller = nil
    }
}

/// One dictation's audio for Whisper: kept whole for the final pass at the end, with the running transcript of the last
/// 28 s refreshed about once a second meanwhile. In live mode ("type as you speak", asr_server.py's live loop) the
/// finished sentences are handed out as pieces about every 5 s instead, and only the speech after the last one is
/// decoded at the end.
final class WhisperDictation: @unchecked Sendable {
    static let partialEvery = 1.0
    static let partialWindow = 28 * 16_000

    private let model: String, language: String?, prompt: String, even: Bool, live: Bool
    private let onText: (String) -> Void
    /// Live mode: a finished piece, and the running guess at the speech after it.
    var onPiece: ((String) -> Void)?
    var onGuess: ((String) -> Void)?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var latest = ""
    private var finalWords: [SpokenWord] = []
    /// The final pass's words, timed from the recording's start (none when it failed).
    var words: [SpokenWord] { lock.withLock { finalWords } }
    private var partials: Task<Void, Never>?
    /// Live mode: samples already handed out as pieces, and those pieces.
    private var committed = 0
    private var committedPieces: [String] = []

    init(model: String, language: String?, prompt: String, even: Bool, live: Bool = false, onText: @escaping (String) -> Void) {
        self.model = model; self.language = language; self.prompt = prompt; self.even = even; self.live = live; self.onText = onText
    }

    /// 16 kHz mono float audio (the audio thread).
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
    }

    func startPartials() {
        if live { partials = Task { [weak self] in await self?.liveLoop() }; return }
        partials = Task { [weak self] in
            var last = 0
            // A slow model (a large one, or one still being prepared) refreshes less often, and stops refreshing when
            // a refresh takes longer than the user is likely to wait: the final pass then has the model to itself.
            var every = Self.partialEvery
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                let (count, tail) = self.lock.withLock { (self.samples.count, Array(self.samples.suffix(Self.partialWindow))) }
                guard count - last >= Int(16_000 * every), count >= 16_000 * 6 / 10 else { continue }
                last = count
                let started = Date()
                guard let heard = try? await WhisperEngine.shared.transcribe(tail, model: self.model, language: self.language, prompt: self.prompt,
                                                                             final: false, even: self.even),
                      !Task.isCancelled else { continue }
                let text = FragmentStitcher.tidy(heard)
                let took = Date().timeIntervalSince(started)
                if !text.isEmpty { // nothing heard (yet): the last running transcript stays, as on Windows
                    self.lock.withLock { self.latest = text }
                    self.onText(text)
                }
                if took > Self.slowPartial { NSLog("Whisper: a running transcript took %.1f s; no more until the end", took); return }
                every = max(Self.partialEvery, took * 2)
            }
        }
    }

    /// A running transcript slower than this ends the running transcripts for this dictation.
    static let slowPartial = 4.0

    /// Live mode: about every second (less often for a slow model), decode the speech not handed out yet; once 5 s of
    /// it have built up, hand out its finished sentences (`WhisperLive.chooseCommit`) as a piece. In between, the rest is
    /// the running guess.
    private func liveLoop() async {
        var last = 0
        var every = Self.partialEvery
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let (count, start, committedText) = lock.withLock { (samples.count, committed, committedPieces.joined(separator: " ")) }
            let pending = count - start
            guard count - last >= Int(16_000 * every), pending >= 16_000 * 6 / 10 else { continue }
            last = count
            let due = pending >= Int(16_000 * WhisperLive.chunkSeconds)
            let audio = lock.withLock { Array(samples[start..<count]) }
            let began = Date()
            guard let found = try? await WhisperEngine.shared.segments(audio, model: model, language: language,
                                                                        prompt: WhisperText.prompt(vocabulary: prompt, committed: committedText), even: even),
                  !Task.isCancelled else { continue }
            every = min(6, max(Self.partialEvery, Date().timeIntervalSince(began) * 2))
            let duration = Double(audio.count) / 16_000
            var rest = found, release = 0, piece = ""
            if due, let pick = WhisperLive.chooseCommit(found, duration: duration) {
                piece = WhisperText.newText(pick.text, after: committedText)
                release = min(audio.count, Int(pick.end * 16_000))
                rest = found.filter { $0.end > pick.end }
            } else if due, !found.contains(where: { !$0.text.isEmpty }), duration >= WhisperLive.forceSeconds {
                // Nothing heard for a while (silence, or only made-up phrases): let go of that audio too, keeping the
                // last moments in case speech is just starting.
                release = audio.count - Int((WhisperLive.commitMargin + 1) * 16_000)
                rest = []
            }
            let guess = rest.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            let shown: String = lock.withLock {
                if release > 0 { committed += release }
                if !piece.isEmpty { committedPieces.append(piece) }
                return FragmentStitcher.join(committedPieces + [guess])
            }
            if !piece.isEmpty { onPiece?(piece) }
            onGuess?(FragmentStitcher.tidy(guess))
            if !shown.isEmpty { lock.withLock { latest = shown }; onText(shown) }
        }
    }

    /// The whole recording's transcript (a full pass; the running transcript if that fails), tidied as Windows tidies
    /// a dictation decoded at once (`FragmentStitcher.join` of the one piece). A running transcript still being worked
    /// out is stopped first, so the final pass doesn't wait for it.
    /// Live mode: the pieces already handed out plus the speech after them, decoded once (Whisper's made-up phrases and
    /// loops left out, as asr_server.py's live stop); the second value is that speech after the last piece (the tail).
    func finish() async -> (text: String, tail: String) {
        partials?.cancel()
        await partials?.value
        let (all, latest, start, pieces) = lock.withLock { (samples, self.latest, committed, committedPieces) }
        if live, !pieces.isEmpty {
            let rest = Array(all[min(start, all.count)...])
            var tail = ""
            if rest.count >= 16_000 * 3 / 10 {
                let committedText = pieces.joined(separator: " ")
                let heard = try? await WhisperEngine.shared.transcribeTimed(rest, model: model, language: language,
                                                                            prompt: WhisperText.prompt(vocabulary: prompt, committed: committedText),
                                                                            final: true, dropPhantoms: true, even: even)
                tail = WhisperText.newText(heard?.text ?? "", after: committedText)
                // Only the tail was decoded at the end (the pieces had no word times): its words, timed from the
                // recording's start.
                let offset = Double(start) / 16_000
                lock.withLock { finalWords = (heard?.words ?? []).map { SpokenWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) } }
            }
            let text = FragmentStitcher.join(pieces + [tail])
            onText(text)
            return (text, tail)
        }
        do {
            let heard = try await WhisperEngine.shared.transcribeTimed(all, model: model, language: language, prompt: prompt, final: true,
                                                                       dropPhantoms: live, even: even)
            var text = FragmentStitcher.join([heard.text])
            if live { text = WhisperText.collapseRepeats(text) }
            lock.withLock { finalWords = heard.words }
            onText(text)
            return (text, live ? text : "")
        } catch {
            NSLog("Whisper: the final pass failed (%@); keeping the running transcript", error.localizedDescription)
            return (latest, live ? latest : "")
        }
    }

    func cancel() { partials?.cancel() }
}
