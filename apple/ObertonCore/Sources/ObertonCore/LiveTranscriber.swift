import AVFoundation
import Foundation
import Speech

/// Microphone → Apple's on-device speech recognizer (SpeechAnalyzer + SpeechTranscriber). The words recognized so far
/// come back while the user speaks, for the overlay; `stop()` returns the whole transcript once the recognizer has
/// finished with the last of the audio. Nothing leaves the device.
public final class LiveTranscriber: @unchecked Sendable {
    /// Called on the main queue with the transcript so far (settled words plus the recognizer's current guess).
    public var onText: ((String) -> Void)?
    /// Called on the main queue with the microphone level, 0…1, for the meter.
    public var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Error>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private let lock = NSLock()
    private var settled = ""
    private var volatile = ""

    public init() {}

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

    public func start(locale: Locale, vocabulary: [String]) async throws {
        let locale = try await Self.prepare(locale: locale)
        Self.markInUse()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        lock.withLock { settled = ""; volatile = "" }
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.input = continuation
        self.analyzerFormat = format

        resultsTask = Task { [weak self] in
            for try await result in transcriber.results {
                guard let self else { return }
                let text = String(result.text.characters)
                let full: String = self.lock.withLock {
                    if result.isFinal { self.settled += text; self.volatile = "" } else { self.volatile = text }
                    return self.settled + self.volatile
                }
                let cb = self.onText
                DispatchQueue.main.async { cb?(full.trimmingCharacters(in: .whitespaces)) }
            }
        }

        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)

        let node = engine.inputNode
        let micFormat = node.outputFormat(forBus: 0)
        if let format, micFormat != format { converter = AVAudioConverter(from: micFormat, to: format) }
        node.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            self?.feed(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        if let data = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            let level = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 55) / 50)) // -55 dB … -5 dB → 0…1
            let cb = onLevel
            DispatchQueue.main.async { cb?(level) }
        }
        guard let converter, let format = analyzerFormat else { input?.yield(AnalyzerInput(buffer: buffer)); return }
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
        if error == nil, out.frameLength > 0 { input?.yield(AnalyzerInput(buffer: out)) }
    }

    /// Stop listening and wait for the recognizer to settle the last words. Returns the whole transcript.
    public func stop() async -> String {
        stopAudio()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = try? await resultsTask?.value
        let text = lock.withLock { settled + volatile }
        reset()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Throw the recording away.
    public func cancel() async {
        stopAudio()
        input?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        reset()
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        #if os(iOS)
        // Extended Notes may still be recording through the same audio session.
        if !Self.audioSessionHeld { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
    }

    /// Set while something else (an Extended Notes session) records, so a dictation ending leaves the audio session on.
    nonisolated(unsafe) public static var audioSessionHeld = false

    private func reset() {
        analyzer = nil
        transcriber = nil
        input = nil
        resultsTask = nil
        converter = nil
    }
}
