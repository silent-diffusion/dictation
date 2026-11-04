import AVFoundation
import CoreML
import Foundation
import WhisperKit

/// A Whisper speech model Oberton offers (SpeechRecognizer.cs `SpeechModels.All`), as WhisperKit's CoreML build of it.
public struct WhisperModel: Identifiable, Sendable, Equatable {
    /// Windows' id, kept in `AppSettings.speechModel` ("base.en").
    public let id: String
    public let name: String
    public let description: String
    public let size: String
    /// Its folder in WhisperKit's model repository (argmaxinc/whisperkit-coreml).
    let variant: String
    /// The tokenizer it uses (downloaded with it, so loading never needs the internet).
    let tokenizer: ModelVariant

    /// Where its audio encoder runs. The Neural Engine is quickest for the small models, but CoreML has to compile a
    /// model for it once, and for a large encoder that took more than 50 minutes on an M-series Mac (with the model running on
    /// the CPU meanwhile, minutes per sentence). The large encoders run on the GPU instead; every decoder runs on the
    /// Neural Engine. Measured on Apple M6 (24 s of speech): base.en 0.8 s, small.en 1.2 s, large-v3 turbo 4.3 s.
    let encoderCompute: MLComputeUnits

    /// Hears only English: the language setting doesn't apply.
    public var englishOnly: Bool { id.hasSuffix(".en") || id.hasPrefix("distil") }
}

/// The Whisper models, where they are kept (Application Support/Oberton/models/whisper) and their downloads.
public enum WhisperModels {
    /// Windows' list and wording (SpeechModels.All). Only the hardware clauses are the Mac's: where Windows names an
    /// NVIDIA GPU, the Mac's own rule for the pick (`SpeechModelChoice`: large-v3 turbo on Apple silicon with 16 GB of
    /// memory, small.en below that and on iPhone and iPad); medium.en runs on the GPU here, not a CPU.
    public static let all: [WhisperModel] = [
        WhisperModel(id: "large-v3-turbo", name: "Whisper large-v3 turbo",
                     description: "The best balance: nearly the accuracy of large-v3, several times faster. Needs an Apple silicon Mac with 16 GB of memory to keep up.", size: "1.6 GB",
                     variant: "openai_whisper-large-v3-v20240930_turbo", tokenizer: .largev3, encoderCompute: .cpuAndGPU),
        WhisperModel(id: "large-v3", name: "Whisper large-v3", description: "The most accurate, and the slowest. GPU only.", size: "3 GB",
                     variant: "openai_whisper-large-v3", tokenizer: .largev3, encoderCompute: .cpuAndGPU),
        WhisperModel(id: "distil-large-v3", name: "Distil-Whisper large-v3", description: "English only. Fast and accurate on a GPU.", size: "1.5 GB",
                     variant: "distil-whisper_distil-large-v3", tokenizer: .largev3, encoderCompute: .cpuAndGPU),
        WhisperModel(id: "medium.en", name: "Whisper medium (English)", description: "Good accuracy; slower to load and to run.", size: "1.5 GB",
                     variant: "openai_whisper-medium.en", tokenizer: .mediumEn, encoderCompute: .cpuAndGPU),
        WhisperModel(id: "small.en", name: "Whisper small (English)", description: "The pick for Macs with less than 16 GB of memory, and for iPhone and iPad.", size: "470 MB",
                     variant: "openai_whisper-small.en", tokenizer: .smallEn, encoderCompute: .cpuAndNeuralEngine),
        WhisperModel(id: "base.en", name: "Whisper base (English)", description: "Tiny and quick; makes more mistakes.", size: "145 MB",
                     variant: "openai_whisper-base.en", tokenizer: .baseEn, encoderCompute: .cpuAndNeuralEngine),
    ]

    public static func model(_ id: String) -> WhisperModel? { all.first { $0.id.caseInsensitiveCompare(id) == .orderedSame } }

    /// Where a model's audio encoder runs, for the status line ("Ready · large-v3-turbo on GPU", as Windows names its
    /// CUDA device "GPU").
    public static func device(of id: String) -> String { model(id)?.encoderCompute == .cpuAndNeuralEngine ? "Neural Engine" : "GPU" }

    /// The name for display ("Whisper base (English)"), or the id itself.
    public static func name(of id: String) -> String { model(id)?.name ?? id }

    static let repo = "argmaxinc/whisperkit-coreml"
    /// Where downloads go: WhisperKit's hub layout under models/whisper (models/<repo>/<variant>, and the tokenizers).
    static var baseDir: URL { AppPaths.dataDir.appending(path: "models/whisper", directoryHint: .isDirectory) }
    static func folder(_ m: WhisperModel) -> URL { baseDir.appending(path: "models/\(repo)/\(m.variant)", directoryHint: .isDirectory) }
    /// Written once the model and its tokenizer are both down, so a cancelled download doesn't count.
    private static func marker(_ m: WhisperModel) -> URL { folder(m).appending(path: ".oberton-complete") }

    /// Loaded once on this device: CoreML has prepared it, so the next load is quick.
    public static func isPrepared(_ id: String) -> Bool { model(id).map(isPrepared) ?? false }
    static func isPrepared(_ m: WhisperModel) -> Bool { FileManager.default.fileExists(atPath: prepared(m).path) }
    static func markPrepared(_ m: WhisperModel) { FileManager.default.createFile(atPath: prepared(m).path, contents: Data()) }
    private static func prepared(_ m: WhisperModel) -> URL { folder(m).appending(path: ".oberton-prepared") }

    public static func isDownloaded(_ id: String) -> Bool {
        guard let m = model(id) else { return false }
        return FileManager.default.fileExists(atPath: marker(m).path)
    }

    /// The downloaded models' ids, in the catalogue's order.
    public static func downloaded() -> [String] { all.map(\.id).filter(isDownloaded) }

    /// Whether this device can run it (WhisperKit's list per chip: an iPhone can't hold the large models in memory).
    public static func runsHere(_ id: String) -> Bool {
        guard let m = model(id) else { return false }
        return !WhisperKit.recommendedModels().disabled.contains(m.variant)
    }

    /// Download a model and its tokenizer, reporting the fraction done (nil while unknown). Cancel the task to stop;
    /// what was fetched so far stays, and the next download picks up from there.
    public static func download(_ id: String, progress: @escaping @Sendable (Double?) -> Void) async throws {
        guard let m = model(id) else { throw UserFacingError("Oberton doesn't know the speech model \(id).") }
        progress(nil)
        do {
            let folder = try await WhisperKit.download(variant: m.variant, downloadBase: baseDir, from: repo) { p in
                progress(p.totalUnitCount > 0 ? p.fractionCompleted : nil)
            }
            try Task.checkCancellation()
            _ = try await ModelUtilities.loadTokenizer(for: m.tokenizer, tokenizerFolder: baseDir)
            try Task.checkCancellation()
            guard folder.standardizedFileURL.path == Self.folder(m).standardizedFileURL.path else {
                throw UserFacingError("The download of \(m.name) landed in an unexpected place (\(folder.path)).")
            }
            FileManager.default.createFile(atPath: marker(m).path, contents: Data())
            progress(1)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as UserFacingError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // Anything else: the details go to the log and the user reads Windows' "The download failed. See the log
            // for details." (ModelsPage.RunDownloadAsync).
            CoreLog.error("Model download failed: \(m.id): \(error)")
            throw UserFacingError("The download failed. See the log for details.")
        }
    }

    /// Delete a downloaded model (its tokenizer is small and may be shared, so it stays).
    public static func remove(_ id: String) throws {
        guard let m = model(id) else { return }
        if FileManager.default.fileExists(atPath: folder(m).path) { try FileManager.default.removeItem(at: folder(m)) }
    }

    /// The language to tell Whisper: none for auto-detect (an empty setting), "en" for the English-only models,
    /// otherwise the setting's language code ("de-DE" → "de").
    public static func language(for setting: String, model id: String) -> String? {
        if model(id)?.englishOnly == true { return "en" }
        let code = setting.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? ""
        return code.isEmpty ? nil : code
    }
}

/// One stretch of speech Whisper heard, with where it ends in the audio it was given (seconds).
public struct WhisperPiece: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    /// Its words, timed in the audio it was given (none for a made-up phrase).
    public var words: [SpokenWord]
    public init(text: String, start: Double, end: Double, words: [SpokenWord] = []) { self.text = text; self.start = start; self.end = end; self.words = words }
}

// WhisperKit isn't marked Sendable; Oberton only touches it inside `WhisperEngine`, one call at a time.
extension WhisperKit: @retroactive @unchecked Sendable {}

/// The one Whisper model in memory, shared by dictation, Extended Notes and History's Run again (Windows' sidecar
/// keeps one too). Decodes run one at a time. `unload()` frees it; the next use loads it again.
public actor WhisperEngine {
    public static let shared = WhisperEngine()

    /// A model being loaded: since when, and whether it is the first time on this device (CoreML then prepares it for
    /// the Neural Engine, which takes from a few seconds to minutes for the large models, with nothing to report).
    public struct Loading: Sendable, Equatable {
        public let model: String
        public let since: Date
        public let firstTime: Bool
        public init(model: String, since: Date, firstTime: Bool) { self.model = model; self.since = since; self.firstTime = firstTime }
    }

    nonisolated(unsafe) private static var loadingNow: Loading?
    /// The load under way, or nil (for the status line, the badges and the pill).
    public nonisolated static var loadingModel: Loading? { lock.withLock { loadingNow } }
    /// Called (on any thread) when a load starts or ends, or the model in memory changes.
    nonisolated(unsafe) public static var onChange: (@Sendable () -> Void)?
    private static func changed() { onChange?() }

    private var kit: WhisperKit?
    private var kitID: String?
    private var loading: Task<WhisperKit, Error>?
    private var loadingID: String?
    /// The loaded model's no-speech probability, which WhisperKit doesn't work out (see `NoSpeechProbe`).
    private var probe: NoSpeechProbe?
    /// The loaded model's tokens for symbols and sound markers, never sampled (faster-whisper's `suppress_tokens=[-1]`).
    private var nonSpeech: [Int] = []
    /// One decode at a time (Windows' `gpu_lock`): Extended Notes, a dictation and Run again share the model, and the
    /// probe follows one decode.
    private var decoding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func beginDecode() async {
        if decoding { await withCheckedContinuation { waiting.append($0) } } else { decoding = true }
    }

    private func endDecode() {
        if waiting.isEmpty { decoding = false } else { waiting.removeFirst().resume() }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loadedID: String?

    /// The id of the model in memory now, or nil (readable from anywhere, for the badges and the unload timer).
    public nonisolated static var loadedModel: String? { lock.withLock { loadedID } }

    /// Load this model (letting go of another one first). Quick when it is already loaded.
    public func load(_ id: String) async throws {
        _ = try await kit(for: id)
    }

    private func kit(for id: String) async throws -> WhisperKit {
        if let kit, kitID == id { return kit }
        if let loading, loadingID == id { return try await loading.value }
        guard let m = WhisperModels.model(id) else { throw UserFacingError("Oberton doesn't know the speech model \(id).") }
        guard WhisperModels.isDownloaded(id) else {
            // Windows: "The speech engine isn't installed yet. Run scripts\setup.ps1 once (it needs internet), then
            // restart the app." The Mac has no engine to install, only the model to download.
            throw UserFacingError("The speech model (\(id)) isn't downloaded yet. Download it under Settings › Models (it needs internet), or pick another model.")
        }
        // Let go of the model loaded now (and any other load) before this one comes in. Nothing here waits between
        // checking `loading` and setting it, so two callers for the same model share one load.
        loading?.cancel()
        let old = kit
        if let kitID { CoreLog.info("Switching the speech model from \(kitID) to \(id)") } // SpeechRecognizer.InitializeAsync
        if let old { Self.unwrap(old) }
        kit = nil; probe = nil
        kitID = nil
        Self.lock.withLock { Self.loadedID = nil }
        let task = Task<WhisperKit, Error> {
            if let old { await old.unloadModels() }
            return try await WhisperKit(Self.config(m, prewarm: false))
        }
        loading = task
        loadingID = id
        Self.lock.withLock { Self.loadingNow = Loading(model: id, since: Date(), firstTime: !WhisperModels.isPrepared(m)) }
        Self.changed()
        defer {
            if loadingID == id {
                loading = nil; loadingID = nil
                Self.lock.withLock { Self.loadingNow = nil }
                Self.changed()
            }
        }
        let loaded: WhisperKit
        let started = Date()
        do { loaded = try await task.value } catch {
            if error is CancellationError { throw error }
            // Windows: "The speech model could not be loaded. Is it installed? Run scripts\setup.ps1. ({detail})"
            CoreLog.error("asr: \(id) could not be loaded: \(error)")
            throw UserFacingError("The speech model could not be loaded. Is it downloaded? See Settings › Speech recognition. (\(error.localizedDescription))")
        }
        WhisperModels.markPrepared(m)
        // asr_server.py's "Loaded {model} on {device} ({compute type})", in dictation.log as Windows' "asr: " lines.
        CoreLog.info(String(format: "asr: Loaded %@ on %@ (CoreML) in %.1f s", id, WhisperModels.device(of: id), Date().timeIntervalSince(started)))
        if let tokenizer = loaded.tokenizer {
            let probe = NoSpeechProbe(tokenizer: tokenizer)
            loaded.textDecoder.logitsFilters = [probe]
            loaded.segmentDiscoveryCallback = { probe.found($0) }
            // faster-whisper's rule for when a window is decoded again at a higher temperature (see `FallbackRule`).
            loaded.textDecoder = FallbackRule(loaded.textDecoder, probe: probe)
            self.probe = probe
            nonSpeech = Self.nonSpeechTokens(tokenizer)
        }
        kit = loaded
        kitID = id
        Self.lock.withLock { Self.loadedID = id }
        return loaded
    }

    /// The decoder as WhisperKit made it, so `unloadModels` lets go of it (it only unloads its own model types).
    private static func unwrap(_ kit: WhisperKit) {
        if let rule = kit.textDecoder as? FallbackRule { kit.textDecoder = rule.inner }
    }

    /// Free the model's memory now; the downloaded files stay.
    public func unload() async {
        loading?.cancel()
        loading = nil
        loadingID = nil
        if let kit { Self.unwrap(kit); await kit.unloadModels() }
        kit = nil; probe = nil
        kitID = nil
        Self.lock.withLock { Self.loadedID = nil; Self.loadingNow = nil }
        Self.changed()
    }

    static func config(_ m: WhisperModel, prewarm: Bool) -> WhisperKitConfig {
        WhisperKitConfig(modelFolder: WhisperModels.folder(m).path, tokenizerFolder: WhisperModels.baseDir,
                         computeOptions: ModelComputeOptions(audioEncoderCompute: m.encoderCompute, textDecoderCompute: .cpuAndNeuralEngine),
                         verbose: false, logLevel: .none, prewarm: prewarm, load: !prewarm, download: false)
    }

    /// Prepare a model for this device without keeping it (right after its download), so choosing it later loads
    /// in a second or two. Runs beside the model in memory; nothing is let go.
    public nonisolated static func prepare(_ id: String) async {
        guard let m = WhisperModels.model(id), WhisperModels.isDownloaded(id), !WhisperModels.isPrepared(m) else { return }
        lock.withLock { if loadingNow == nil { loadingNow = Loading(model: id, since: Date(), firstTime: true) } }
        changed()
        let started = Date()
        do {
            let kit = try await WhisperKit(config(m, prewarm: true))
            await kit.unloadModels()
            WhisperModels.markPrepared(m)
            CoreLog.info(String(format: "asr: Prepared %@ for this device in %.1f s", id, Date().timeIntervalSince(started)))
        } catch {
            CoreLog.warn("asr: Preparing \(id) failed: \(error.localizedDescription)")
        }
        lock.withLock { if loadingNow?.model == id { loadingNow = nil } }
        changed()
    }

    /// One decode of audio already cut to speech (faster-whisper's `model.transcribe` as asr_server.py calls it:
    /// `condition_on_previous_text=False`, `initial_prompt`, temperatures 0, `step`, 2·`step`), with Whisper's own
    /// segments and what it reported about each.
    ///
    /// faster-whisper's defaults are set to match where WhisperKit has them: non-speech tokens suppressed, no blank
    /// first token, the first timestamp within 1 s, the prompt's last 223 tokens. Its temperature fallback runs here
    /// rather than in WhisperKit (whose compression ratio counts token bytes, not text, and which has no no-speech
    /// probability), so the thresholds are faster-whisper's: text compression ratio 2.4, mean log probability −1, and
    /// no fallback for a window that is silence.
    ///
    /// `words`: WhisperKit's word timestamps. Only without a prompt: WhisperKit 1.1.1 lines the words up with the
    /// decoder's attention as if the prompt weren't there, which pulls every word early. They also move the segments'
    /// own start and end to the words', so live mode, which commits by segment ends, never asks for them. Without them,
    /// each segment's words are spread over its time (`WordTimes.spread`).
    func decode(_ audio: [Float], model id: String, language: String?, prompt: String, step: Float, words: Bool = false,
                onWindow: (@Sendable (Int) -> Void)? = nil) async throws -> [WhisperText.Segment] {
        let kit = try await kit(for: id)
        guard !audio.isEmpty else { return [] }
        var promptTokens: [Int]?
        if let tokenizer = kit.tokenizer, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            promptTokens = Array(tokenizer.encode(text: " " + prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }.suffix(223))
        }
        // WhisperKit decodes nothing within 1 s of the end of the audio (`windowClipTime`), so a short word is padded
        // with the silence Whisper pads every window with anyway. Only to 1.25 s: past that, WhisperKit would go on to
        // decode the padding as a window of its own, where Whisper makes up words.
        let padded = audio + [Float](repeating: 0, count: max(0, WhisperKit.sampleRate * 5 / 4 - audio.count))
        let long = audio.count > WhisperKit.sampleRate * 30
        func options(_ temperature: Float) -> DecodingOptions {
            DecodingOptions(language: language, temperature: temperature, temperatureIncrementOnFallback: step,
                            // Past one window, WhisperKit decodes window by window and falls back for each window on
                            // its own, as faster-whisper does; with `FallbackRule`, by faster-whisper's rule.
                            temperatureFallbackCount: long ? 2 : 0,
                            usePrefillPrompt: true, detectLanguage: language == nil, skipSpecialTokens: true,
                            // Word times for highlighting the word being said in playback (WordTimes); the text is the same.
                            withoutTimestamps: false, wordTimestamps: words, maxInitialTimestamp: 1.0,
                            promptTokens: promptTokens, suppressBlank: true, suppressTokens: nonSpeech,
                            compressionRatioThreshold: nil, logProbThreshold: nil,
                            firstTokenLogProbThreshold: nil, noSpeechThreshold: nil, chunkingStrategy: nil)
        }
        func run(_ temperature: Float) async throws -> [WhisperText.Segment] {
            await beginDecode()
            defer { endDecode() }
            try Task.checkCancellation()
            let kit = try await self.kit(for: id) // the same one, unless the model was switched meanwhile
            probe?.begin()
            // A cancelled caller (a running transcript the user stopped speaking over) stops at the next token.
            let results = try await kit.transcribe(audioArray: padded, decodeOptions: options(temperature)) { progress in
                onWindow?(progress.windowId)
                return Task.isCancelled ? false : nil
            }
            try Task.checkCancellation()
            return Self.segments(results.flatMap(\.segments), noSpeech: probe?.noSpeech ?? [:])
        }
        var segments: [WhisperText.Segment]
        if long {
            segments = try await run(0)
        } else {
            // faster-whisper's generate_with_fallback, for the one window.
            var tried: [(segments: [WhisperText.Segment], ratio: Double, logprob: Double)] = []
            segments = []
            for k in 0...2 {
                let found = try await run(step * Float(k))
                let text = found.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                let ratio = WhisperText.compressionRatio(text)
                let logprob = found.first?.avgLogprob ?? 0, noSpeech = found.first?.noSpeechProb ?? 0
                tried.append((found, ratio, logprob))
                var fallback = ratio > 2.4 || logprob < -1.0
                if noSpeech > 0.6 && logprob < -1.0 { fallback = false } // silence: a hotter decode only makes things up
                if !fallback { segments = found; break }
                if k == 2 {
                    let below = tried.filter { $0.ratio <= 2.4 }
                    segments = (below.isEmpty ? tried : below).max { $0.logprob < $1.logprob }!.segments
                }
            }
        }
        // A window Whisper itself thinks is silence, decoded without confidence, is skipped (faster-whisper's
        // no_speech_threshold 0.6 with log_prob_threshold −1).
        return segments.filter { !($0.noSpeechProb > 0.6 && $0.avgLogprob <= -1.0) }
    }

    /// WhisperKit's segments with what is known about their window: the no-speech probability from the probe, and the
    /// compression ratio of the window's whole text (as faster-whisper reports it). Sound markers are not words.
    static func segments(_ found: [TranscriptionSegment], noSpeech: [Int: Double]) -> [WhisperText.Segment] {
        var windowText: [Int: String] = [:]
        for s in found { windowText[s.seek, default: ""] += s.text }
        return found.map { s in
            WhisperText.Segment(text: clean(s.text), start: Double(s.start), end: Double(s.end), noSpeechProb: noSpeech[s.id] ?? 0,
                                avgLogprob: Double(s.avgLogprob),
                                compressionRatio: WhisperText.compressionRatio(clean(windowText[s.seek] ?? s.text)),
                                words: s.words.map { ws in
                                    ws.compactMap { w in
                                        // Markers and special tokens aren't words.
                                        let t = clean(w.word)
                                        return t.isEmpty ? nil : SpokenWord(text: t, start: Double(w.start), end: Double(w.end))
                                    }
                                } ?? WordTimes.spread(clean(s.text), start: Double(s.start), end: Double(s.end)))
        }
    }

    /// Text from `samples` (asr_server.py `transcribe`): cut to speech (and levelled, when `even`), nothing at all when
    /// no one spoke, Whisper's runs of dots collapsed, and, with `dropPhantoms`, the phrases it made up rather than heard
    /// left out. `final`: the whole recording at the end, decoded again more freely when the first pass gave only
    /// punctuation. The text is as Whisper wrote it, segments joined with spaces.
    public func transcribe(_ samples: [Float], model id: String, language: String?, prompt: String, final: Bool,
                           dropPhantoms: Bool = false, even: Bool, onWindow: (@Sendable (Int) -> Void)? = nil) async throws -> String {
        try await transcribeTimed(samples, model: id, language: language, prompt: prompt, final: final, dropPhantoms: dropPhantoms,
                                  even: even, exactWords: false, onWindow: onWindow).text
    }

    /// `transcribe`, with the words of the segments kept (left-out segments' words left out too), timed in `samples`.
    /// `exactWords` (nil: whenever there is no prompt): WhisperKit's word timestamps rather than words spread over
    /// each segment (see `decode`).
    public func transcribeTimed(_ samples: [Float], model id: String, language: String?, prompt: String, final: Bool,
                                dropPhantoms: Bool = false, even: Bool, exactWords: Bool? = nil,
                                onWindow: (@Sendable (Int) -> Void)? = nil) async throws -> (text: String, words: [SpokenWord]) {
        let exact = exactWords ?? prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // No speech: decoding anyway is exactly how Whisper produces "Thank you." on silence.
        guard let prepared = WhisperPrep.prepare(samples, even: even) else { return ("", []) }
        // `cut`: the segments are timed in the audio cut down to speech. A made-up phrase stretched over seconds is
        // judged by its time in the audio Windows' faster-whisper reports it in: the evened, cut audio it decoded, or,
        // without evening out, the recording as made (its voice filter puts the times back).
        func kept(_ segments: [WhisperText.Segment], cut: Bool) -> [WhisperText.Segment] {
            segments.filter { !(dropPhantoms && WhisperText.isPhantom(cut && !even ? prepared.originalTimes($0) : $0)) }
        }
        func text(_ segments: [WhisperText.Segment], cut: Bool) -> String {
            OutputSanitizer.collapseDots(kept(segments, cut: cut).map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ").trimmingCharacters(in: .whitespaces))
        }
        var segments = try await decode(prepared.audio, model: id, language: language, prompt: prompt, step: 0.2, words: exact, onWindow: onWindow)
        var result = text(segments, cut: true)
        var words = prepared.originalWords(kept(segments, cut: true).flatMap(\.words))
        if final && !WhisperText.hasContent(result) {
            // Only "..." on long or odd audio: twice more, more freely (and without the cut, when it was only the voice
            // detector's: asr_server.py's (beam 1, no VAD), then (beam 5, no VAD), at temperatures 0, 0.3, 0.6). WhisperKit
            // decodes greedily only, so the second is greedy too; it differs from the first only where a hotter decode
            // samples differently. As a last resort nothing rather than junk.
            let again = even ? prepared.audio : samples
            for _ in 0..<2 {
                segments = try await decode(again, model: id, language: language, prompt: prompt, step: 0.3, words: exact, onWindow: onWindow)
                result = text(segments, cut: even)
                words = kept(segments, cut: even).flatMap(\.words)
                if even { words = prepared.originalWords(words) }
                if WhisperText.hasContent(result) { break }
            }
            if !WhisperText.hasContent(result) {
                CoreLog.warn(String(format: "asr: final decode produced no usable text for %.1fs of audio", Double(again.count) / 16_000))
            }
        }
        return WhisperText.hasContent(result) ? (result, words) : ("", [])
    }

    /// Live mode (asr_server.py `segments`): each phrase Whisper finds in `samples`, with where it starts and ends in
    /// `samples`, silence skipped. A phrase it made up rather than heard comes back empty, so its audio can still be let go of.
    public func segments(_ samples: [Float], model id: String, language: String?, prompt: String, even: Bool) async throws -> [WhisperPiece] {
        guard let prepared = WhisperPrep.prepare(samples, even: even) else { return [] }
        return try await decode(prepared.audio, model: id, language: language, prompt: prompt, step: 0.2).map { s in
            // Judged in the time Windows' faster-whisper reports (see `transcribeTimed`).
            let t = WhisperText.isPhantom(even ? s : prepared.originalTimes(s)) ? "" : OutputSanitizer.collapseDots(s.text.trimmingCharacters(in: .whitespaces))
            let heard = WhisperText.hasContent(t)
            return WhisperPiece(text: heard ? t : "", start: prepared.originalTime(s.start), end: prepared.originalTime(s.end),
                                words: heard ? prepared.originalWords(s.words) : [])
        }
    }

    /// Whisper's markers ("[BLANK_AUDIO]", "(music)", "<|…|>", a segment that is only "(clapping)" or "♪") aren't
    /// words. (faster-whisper suppresses the tokens these start with, as `decode` does; this catches what gets through.)
    static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[[^\]]*\]|\((?:music|applause|laughter|silence|inaudible|blank_audio)\)"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: #"^(?:\([^()]*\)|\*[^*]*\*|[♩♪♫♬\s]+)$"#, options: .regularExpression) != nil { return "" }
        return t
    }

    /// The tokens faster-whisper never samples by default (`suppress_tokens=[-1]`, OpenAI's `non_speech_tokens`):
    /// symbols that begin sound markers such as "[Music]", "(applause)" or "♪", kept out of the text.
    static func nonSpeechTokens(_ tokenizer: any WhisperTokenizer) -> [Int] {
        let special = tokenizer.specialTokens.specialTokenBegin
        func encode(_ s: String) -> [Int] { tokenizer.encode(text: s).filter { $0 < special } }
        var symbols = "\"#()*+/:;<=>@[\\]^_`{|}~「」『』".map(String.init)
        symbols += "<< >> <<< >>> -- --- -( -[ (' (\" (( )) ((( ))) [[ ]] {{ }} ♪♪ ♪♪♪".split(separator: " ").map(String.init)
        let misc = "♩♪♫♬♭♮♯".map(String.init)
        var result = Set([encode(" -").first, encode(" '").first].compactMap { $0 })
        for symbol in symbols + misc {
            for tokens in [encode(symbol), encode(" " + symbol)] where tokens.count == 1 || (misc.contains(symbol) && !tokens.isEmpty) {
                result.insert(tokens[0])
            }
        }
        return result.sorted()
    }
}

/// Whisper's no-speech probability, which WhisperKit 1.1.1 leaves at 0: the probability of the `<|nospeech|>` token
/// right after `<|startoftranscript|>`, as OpenAI's and faster-whisper's decoders work it out. It sits first among
/// the decoder's logits filters, so it sees each step's logits unfiltered; it counts the steps itself (a new decode
/// starts when the tokens don't follow on), and pairs each window's value with that window's segments as WhisperKit
/// reports them (`segmentDiscoveryCallback`).
final class NoSpeechProbe: LogitsFiltering, @unchecked Sendable {
    private let sot: Int, noSpeechToken: Int
    private let lock = NSLock()
    private var step = 0, prompt: [Int] = [], sotIndex = -1
    private var current = 0.0
    private var bySegment: [Int: Double] = [:]

    init(tokenizer: any WhisperTokenizer) {
        sot = tokenizer.specialTokens.startOfTranscriptToken
        // English-only models call it <|nocaptions|>. A name the tokenizer doesn't know comes back as <|endoftext|>.
        let special = tokenizer.specialTokens
        func id(_ name: String) -> Int? { tokenizer.convertTokenToId(name).flatMap { $0 > special.endToken ? $0 : nil } }
        noSpeechToken = id("<|nospeech|>") ?? id("<|nocaptions|>") ?? special.noSpeechToken
    }

    /// Before a transcription: forget the last one's.
    func begin() { lock.withLock { bySegment = [:]; current = 0; prompt = []; step = 0 } }

    /// Each segment's window's no-speech probability, by segment id, for the transcription since `begin`.
    var noSpeech: [Int: Double] { lock.withLock { bySegment } }

    func found(_ segments: [TranscriptionSegment]) { lock.withLock { for s in segments { bySegment[s.id] = current } } }

    /// The last decode's no-speech probability.
    var latest: Double { lock.withLock { current } }

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        lock.withLock {
            // During the prompt the tokens are the whole prompt; after it, one more each step.
            let next = step + 1, promptCount = prompt.count
            let expected = next < promptCount - 1 ? promptCount : next + 1
            if promptCount > 0, tokens.count == expected, tokens.starts(with: prompt) {
                step = next
            } else {
                step = 0
                prompt = tokens
                sotIndex = tokens.firstIndex(of: sot) ?? -1
            }
            if step == sotIndex { current = Self.probability(of: noSpeechToken, in: logits) }
        }
        return logits
    }

    /// Softmax probability of `token` in the step's logits.
    static func probability(of token: Int, in logits: MLMultiArray) -> Double {
        let n = logits.count
        guard token >= 0, token < n else { return 0 }
        var values = [Float](repeating: 0, count: n)
        switch logits.dataType {
        case .float16:
            #if arch(arm64)
            let p = logits.dataPointer.bindMemory(to: Float16.self, capacity: n)
            for i in 0..<n { values[i] = Float(p[i]) }
            #else
            for i in 0..<n { values[i] = logits[i].floatValue } // no Float16 on Intel Macs
            #endif
        case .float32:
            let p = logits.dataPointer.bindMemory(to: Float.self, capacity: n)
            for i in 0..<n { values[i] = p[i] }
        default:
            for i in 0..<n { values[i] = logits[i].floatValue }
        }
        let top = values.filter(\.isFinite).max() ?? 0
        var sum = 0.0
        for v in values where v.isFinite { sum += exp(Double(v - top)) }
        guard sum > 0, values[token].isFinite else { return 0 }
        return exp(Double(values[token] - top)) / sum
    }
}

/// faster-whisper's rule for decoding a window again at a higher temperature (`generate_with_fallback`), for the
/// windows WhisperKit decodes one after another past 30 s: again when the window's text compresses more than 2.4 times
/// (a loop) or its mean log probability is below −1, but not when Whisper itself thinks the window is silence (no-speech
/// probability above 0.6, from `NoSpeechProbe`). WhisperKit's own rule counts the compression of token bytes, not text,
/// and knows no no-speech probability. The one difference left: when every temperature fails, faster-whisper keeps the
/// most confident decode that isn't a loop, WhisperKit the last one. (Within one window `WhisperEngine.decode` runs
/// faster-whisper's fallback itself, that choice included.)
final class FallbackRule: TextDecoding, @unchecked Sendable {
    private(set) var inner: any TextDecoding
    private let probe: NoSpeechProbe

    init(_ inner: any TextDecoding, probe: NoSpeechProbe) { self.inner = inner; self.probe = probe }

    var tokenizer: (any WhisperTokenizer)? { get { inner.tokenizer } set { inner.tokenizer = newValue } }
    var isModelMultilingual: Bool { get { inner.isModelMultilingual } set { inner.isModelMultilingual = newValue } }
    var supportsWordTimestamps: Bool { inner.supportsWordTimestamps }
    var logitsSize: Int? { inner.logitsSize }
    var logitsFilters: [any LogitsFiltering]? { get { inner.logitsFilters } set { inner.logitsFilters = newValue } }
    var kvCacheEmbedDim: Int? { inner.kvCacheEmbedDim }
    var kvCacheMaxSequenceLength: Int? { inner.kvCacheMaxSequenceLength }
    var windowSize: Int? { inner.windowSize }
    var embedSize: Int? { inner.embedSize }

    func predictLogits(_ inputs: any TextDecoderInputType) async throws -> TextDecoderOutputType? {
        try await inner.predictLogits(inputs)
    }

    func prepareDecoderInputs(withPrompt initialPrompt: [Int]) throws -> any DecodingInputsType {
        try inner.prepareDecoderInputs(withPrompt: initialPrompt)
    }

    func prefillDecoderInputs(_ decoderInputs: any DecodingInputsType, withOptions options: DecodingOptions?) async throws -> any DecodingInputsType {
        try await inner.prefillDecoderInputs(decoderInputs, withOptions: options)
    }

    func detectLanguage(from encoderOutput: any AudioEncoderOutputType, using decoderInputs: any DecodingInputsType,
                        sampler tokenSampler: TokenSampling, options: DecodingOptions, temperature: FloatType) async throws -> DecodingResult {
        try await inner.detectLanguage(from: encoderOutput, using: decoderInputs, sampler: tokenSampler, options: options, temperature: temperature)
    }

    func decodeText(from encoderOutput: any AudioEncoderOutputType, using decoderInputs: any DecodingInputsType,
                    sampler tokenSampler: TokenSampling, options decoderOptions: DecodingOptions,
                    callback: TranscriptionCallback?) async throws -> DecodingResult {
        var result = try await inner.decodeText(from: encoderOutput, using: decoderInputs, sampler: tokenSampler,
                                                options: decoderOptions, callback: callback)
        guard let tokenizer = inner.tokenizer else { return result }
        let text = tokenizer.decode(tokens: result.tokens.filter { $0 < tokenizer.specialTokens.specialTokenBegin })
        let ratio = WhisperText.compressionRatio(text), noSpeech = probe.latest
        result.compressionRatio = Float(ratio)
        result.noSpeechProb = Float(noSpeech)
        let reason = Self.fallback(ratio: ratio, avgLogprob: Double(result.avgLogProb), noSpeech: noSpeech)
        result.fallback = reason.map { DecodingFallback(needsFallback: true, fallbackReason: $0) }
        return result
    }

    /// Why a window is decoded again, or nil (faster-whisper's `generate_with_fallback` with compression_ratio_threshold
    /// 2.4, log_prob_threshold −1, no_speech_threshold 0.6).
    static func fallback(ratio: Double, avgLogprob: Double, noSpeech: Double) -> String? {
        if noSpeech > 0.6, avgLogprob < -1 { return nil } // silence: a hotter decode only makes things up
        if ratio > 2.4 { return "compressionRatioThreshold" }
        if avgLogprob < -1 { return "logProbThreshold" }
        return nil
    }
}

/// Extended Notes with Whisper (asr_server.py live mode): every few seconds, the audio not yet committed is decoded and
/// its finished sentences committed; committed audio is let go, so an hour-long session stays light.
public enum WhisperLive {
    /// Look for something to commit once this much new audio has built up (seconds).
    public static let chunkSeconds = 5.0
    /// …and commit at a phrase boundary even without a sentence end after this long.
    public static let forceSeconds = 12.0
    /// Never commit a phrase ending this close to the newest audio: it may be cut off.
    public static let commitMargin = 0.8
    /// How often the speech not committed yet is decoded (asr_server.py `_live_loop`: LIVE_PARTIAL_SECONDS on a GPU, 2.5
    /// times that on a CPU). Apple silicon's GPU and Neural Engine are the GPU here; an Intel Mac counts as a CPU.
    public static let interval = SpeechModelChoice.isAppleSilicon ? 1.0 : 2.5

    /// How much of `pieces` (decoded from `duration` seconds of audio) to commit: the text and where it ends, or nil.
    /// Prefers the last phrase that ends a sentence; after a long stretch without one, the last phrase boundary.
    public static func chooseCommit(_ pieces: [WhisperPiece], duration: Double) -> (text: String, end: Double)? {
        let ready = pieces.filter { $0.end <= duration - commitMargin }
        guard !ready.isEmpty else { return nil }
        let ends = ready.indices.filter { i in
            let t = ready[i].text.trimmingCharacters(in: CharacterSet(charactersIn: "\"')").union(.whitespaces))
            return t.hasSuffix(".") || t.hasSuffix("!") || t.hasSuffix("?")
        }
        let last: Int
        if let end = ends.last { last = end } else if duration >= forceSeconds { last = ready.count - 1 } else { return nil }
        return (ready[...last].map(\.text).filter { !$0.isEmpty }.joined(separator: " "), ready[last].end)
    }
}

/// Extended Notes' audio to Whisper as it comes in (asr_server.py live mode). Finished sentences come back through
/// `onPiece` with where they start, in seconds from the stream's start; `finish()` hands over the rest.
public final class WhisperLiveStream: @unchecked Sendable {
    private let model: String, language: String?, vocabulary: String, even: Bool
    private let onPiece: @Sendable (String, Double) -> Void
    private let lock = NSLock()
    /// The audio not committed yet, and where it starts in the stream (samples).
    private var pending: [Float] = []
    private var dropped = 0
    private var committedText = ""
    /// The committed pieces' words, timed from the stream's start, until `takeWords`.
    private var committedWords: [SpokenWord] = []
    private var loop: Task<Void, Never>?
    private static let rate = Double(WhisperKit.sampleRate)

    /// `vocabulary`: the vocabulary hint as typed; `even`: even out quiet speech first (Settings › Speech).
    public init(model: String, language: String?, vocabulary: String, even: Bool = true, onPiece: @escaping @Sendable (String, Double) -> Void) {
        self.model = model; self.language = language; self.vocabulary = vocabulary; self.even = even; self.onPiece = onPiece
    }

    /// 16 kHz mono samples (any thread).
    public func append(_ samples: [Float]) { lock.withLock { pending.append(contentsOf: samples) } }

    public func start() {
        // asr_server.py `_live_loop`: every quarter second, once `WhisperLive.interval` of new audio has come in (and 0.6 s
        // waits), the speech not committed yet is decoded; with 5 s of it built up, its finished sentences are committed.
        // Windows decodes in between too, for the running guess; Extended Notes on the Mac shows none, so only the
        // decodes that can commit are run, on the same beat.
        loop = Task { [weak self] in
            var decodedAt = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                let (audio, total) = self.lock.withLock { (self.pending, self.dropped + self.pending.count) }
                guard Double(total - decodedAt) >= Self.rate * WhisperLive.interval, Double(audio.count) >= Self.rate * 0.6 else { continue }
                decodedAt = total
                guard audio.count >= Int(Self.rate * WhisperLive.chunkSeconds) else { continue }
                if let (text, at) = await self.commit(audio) { self.onPiece(text, at) }
            }
        }
    }

    /// Decode the audio not committed yet and commit what is finished: its text and where it starts, or nil.
    private func commit(_ audio: [Float]) async -> (String, Double)? {
        // The text committed so far (plus the vocabulary hint) keeps casing and names consistent across pieces.
        let (start, prompt) = lock.withLock { (dropped, WhisperText.prompt(vocabulary: vocabulary, committed: committedText)) }
        guard let pieces = try? await WhisperEngine.shared.segments(audio, model: model, language: language, prompt: prompt, even: even) else { return nil }
        let duration = Double(audio.count) / Self.rate
        var release = 0, text = "", at = 0.0
        var words: [SpokenWord] = []
        if let pick = WhisperLive.chooseCommit(pieces, duration: duration) {
            text = lock.withLock { WhisperText.newText(pick.text, after: committedText) }
            at = pieces.first { !$0.text.isEmpty }?.start ?? 0
            release = min(audio.count, Int(pick.end * Self.rate))
            words = pieces.filter { $0.end <= pick.end }.flatMap(\.words).map { $0.shifted(by: Double(start) / Self.rate) }
        } else if !pieces.contains(where: { !$0.text.isEmpty }), duration >= WhisperLive.forceSeconds {
            // Nothing heard for a while (silence, or only made-up phrases): let go of that audio too, keeping the last
            // moments in case speech is just starting.
            release = audio.count - Int((WhisperLive.commitMargin + 1) * Self.rate)
        }
        guard release > 0 else { return nil }
        lock.withLock {
            pending.removeFirst(min(release, pending.count))
            dropped += release
            if !text.isEmpty { committedText = (committedText + " " + text).trimmingCharacters(in: .whitespaces); committedWords += words }
        }
        return text.isEmpty ? nil : (text, Double(start) / Self.rate + at)
    }

    /// The words of what was committed since the last call, timed from the stream's start (for playback highlighting).
    public func takeWords() -> [SpokenWord] { lock.withLock { defer { committedWords = [] }; return committedWords } }

    /// Stop listening and transcribe what is left (the speech after the last piece, decoded once, Whisper's made-up
    /// phrases and loops left out): returned (not sent to `onPiece`), so the caller has it at once.
    public func finish() async -> (text: String, at: Double)? {
        loop?.cancel()
        await loop?.value
        let (rest, start, prompt) = lock.withLock { (pending, dropped, WhisperText.prompt(vocabulary: vocabulary, committed: committedText)) }
        guard rest.count >= Int(Self.rate * 0.3),
              let heard = try? await WhisperEngine.shared.transcribeTimed(rest, model: model, language: language, prompt: prompt, final: true,
                                                                          dropPhantoms: true, even: even) else { return nil }
        let text = lock.withLock { WhisperText.newText(heard.text, after: committedText) }
        lock.withLock {
            pending = []
            dropped += rest.count
            if !text.isEmpty {
                committedText = (committedText + " " + text).trimmingCharacters(in: .whitespaces)
                committedWords += heard.words.map { $0.shifted(by: Double(start) / Self.rate) }
            }
        }
        return text.isEmpty ? nil : (text, Double(start) / Self.rate)
    }

    public func cancel() { loop?.cancel() }
}

/// Audio files for Whisper: 16 kHz mono samples.
public enum WhisperAudio {
    public static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(WhisperKit.sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw UserFacingError("This recording can't be read.")
        }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * target.sampleRate / file.processingFormat.sampleRate) + 1024)
        let chunk: AVAudioFrameCount = 65_536
        var done = false
        while !done {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunk) else { break }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { count, status in
                guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
                      (try? file.read(into: input, frameCount: count)) != nil, input.frameLength > 0 else {
                    status.pointee = .endOfStream
                    return nil
                }
                status.pointee = .haveData
                return input
            }
            if let error { throw error }
            if let data = buffer.floatChannelData?[0] { out.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))) }
            done = status == .endOfStream || status == .error || buffer.frameLength == 0
        }
        return out
    }

    /// A kept dictation transcribed again (HistoryRerun.cs): the whole recording at once, as the final pass of a
    /// dictation does it, with the vocabulary hint; its text tidied (`FragmentStitcher.tidy`), or "" when nothing was heard.
    public static func rerun(_ url: URL, model: String, language: String?, vocabulary: String, even: Bool) async throws -> String {
        let all = try samples(url)
        let heard = try await WhisperEngine.shared.transcribe(all, model: model, language: language, prompt: vocabulary, final: true, even: even)
        return FragmentStitcher.tidy(heard)
    }

    /// An Extended Notes recording transcribed again (NotesRecorder.cs `RetranscribeAsync`): in parts of about 15 s cut
    /// in its pauses (`NotesRedo.planParts`), like a live session's pieces; each with the vocabulary hint and the end of
    /// the part before (loops left out) as its prompt, Whisper's made-up phrases and loops left out. Returns each part's
    /// text with where it starts, and reports the fraction done after each part.
    public static func redo(_ url: URL, model: String, language: String?, vocabulary: String, even: Bool,
                            progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws -> [(seconds: Double, text: String)] {
        try await redoTimed(url, model: model, language: language, vocabulary: vocabulary, even: even, progress: progress).pieces
    }

    /// `redo`, with the words heard, timed in the recording.
    public static func redoTimed(_ url: URL, model: String, language: String?, vocabulary: String, even: Bool,
                                 progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws
        -> (pieces: [(seconds: Double, text: String)], words: [SpokenWord]) {
        let all = try samples(url)
        let rate = Double(WhisperKit.sampleRate)
        let pauses = (try? NotesAudio.pauses(url)) ?? []
        let parts = NotesRedo.planParts(seconds: Double(all.count) / rate, pauses: pauses)
        try await WhisperEngine.shared.load(model) // first, so the caller's "loading" shows until it is in
        var pieces: [(seconds: Double, text: String)] = []
        var words: [SpokenWord] = []
        var previous = ""
        for (i, part) in parts.enumerated() {
            try Task.checkCancellation()
            let tail = WhisperText.tail(NotesFormat.collapseRepeats(previous), 200)
            let prompt = [vocabulary, tail].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
            let from = min(all.count, Int(part.start * rate)), to = min(all.count, Int(part.end * rate))
            let heard = try await WhisperEngine.shared.transcribeTimed(Array(all[from..<to]), model: model, language: language, prompt: prompt,
                                                                       final: true, dropPhantoms: true, even: even)
            let text = WhisperText.collapseRepeats(heard.text).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                pieces.append((part.start, text))
                words += heard.words.map { $0.shifted(by: Double(from) / rate) }
                previous = text
            }
            await progress(Double(i + 1) / Double(max(1, parts.count)))
        }
        return (pieces, words)
    }
}
