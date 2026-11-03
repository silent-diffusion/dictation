import AVFoundation
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

    /// Hears only English: the language setting doesn't apply.
    public var englishOnly: Bool { id.hasSuffix(".en") || id.hasPrefix("distil") }
}

/// The Whisper models, where they are kept (Application Support/Oberton/models/whisper) and their downloads.
public enum WhisperModels {
    /// Windows' list and wording; the GPU notes are for Apple's chips (CoreML runs these on the Neural Engine and GPU).
    public static let all: [WhisperModel] = [
        WhisperModel(id: "large-v3-turbo", name: "Whisper large-v3 turbo",
                     description: "The best balance: nearly the accuracy of large-v3, several times faster.", size: "1.6 GB",
                     variant: "openai_whisper-large-v3-v20240930_turbo", tokenizer: .largev3),
        WhisperModel(id: "large-v3", name: "Whisper large-v3", description: "The most accurate, and the slowest.", size: "3 GB",
                     variant: "openai_whisper-large-v3", tokenizer: .largev3),
        WhisperModel(id: "distil-large-v3", name: "Distil-Whisper large-v3", description: "English only. Fast and accurate.", size: "1.5 GB",
                     variant: "distil-whisper_distil-large-v3", tokenizer: .largev3),
        WhisperModel(id: "medium.en", name: "Whisper medium (English)", description: "Good accuracy; slower to load and to run.", size: "1.5 GB",
                     variant: "openai_whisper-medium.en", tokenizer: .mediumEn),
        WhisperModel(id: "small.en", name: "Whisper small (English)", description: "The pick for an iPhone or an older Mac.", size: "470 MB",
                     variant: "openai_whisper-small.en", tokenizer: .smallEn),
        WhisperModel(id: "base.en", name: "Whisper base (English)", description: "Tiny and quick; makes more mistakes.", size: "145 MB",
                     variant: "openai_whisper-base.en", tokenizer: .baseEn),
    ]

    public static func model(_ id: String) -> WhisperModel? { all.first { $0.id.caseInsensitiveCompare(id) == .orderedSame } }

    /// The name for display ("Whisper base (English)"), or the id itself.
    public static func name(of id: String) -> String { model(id)?.name ?? id }

    static let repo = "argmaxinc/whisperkit-coreml"
    /// Where downloads go: WhisperKit's hub layout under models/whisper (models/<repo>/<variant>, and the tokenizers).
    static var baseDir: URL { AppPaths.dataDir.appending(path: "models/whisper", directoryHint: .isDirectory) }
    static func folder(_ m: WhisperModel) -> URL { baseDir.appending(path: "models/\(repo)/\(m.variant)", directoryHint: .isDirectory) }
    /// Written once the model and its tokenizer are both down, so a cancelled download doesn't count.
    private static func marker(_ m: WhisperModel) -> URL { folder(m).appending(path: ".oberton-complete") }

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
            throw UserFacingError("The download of \(m.name) failed (\(error.localizedDescription)).")
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
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

// WhisperKit isn't marked Sendable; Oberton only touches it inside `WhisperEngine`, one call at a time.
extension WhisperKit: @retroactive @unchecked Sendable {}

/// The one Whisper model in memory, shared by dictation, Extended Notes and History's Run again (Windows' sidecar
/// keeps one too). Decodes run one at a time. `unload()` frees it; the next use loads it again.
public actor WhisperEngine {
    public static let shared = WhisperEngine()

    private var kit: WhisperKit?
    private var kitID: String?
    private var loading: Task<WhisperKit, Error>?
    private var loadingID: String?

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
            throw UserFacingError("\(m.name) isn't downloaded. Download it under Settings › Speech recognition, or pick another model.")
        }
        // Let go of the model loaded now (and any other load) before this one comes in. Nothing here waits between
        // checking `loading` and setting it, so two callers for the same model share one load.
        loading?.cancel()
        let old = kit
        kit = nil
        kitID = nil
        Self.lock.withLock { Self.loadedID = nil }
        let folder = WhisperModels.folder(m).path, tokenizers = WhisperModels.baseDir
        let task = Task<WhisperKit, Error> {
            if let old { await old.unloadModels() }
            let config = WhisperKitConfig(modelFolder: folder, tokenizerFolder: tokenizers, verbose: false, logLevel: .none,
                                          prewarm: false, load: true, download: false)
            return try await WhisperKit(config)
        }
        loading = task
        loadingID = id
        defer { if loadingID == id { loading = nil; loadingID = nil } }
        let loaded: WhisperKit
        do { loaded = try await task.value } catch {
            throw UserFacingError("\(m.name) couldn't be loaded (\(error.localizedDescription)).")
        }
        kit = loaded
        kitID = id
        Self.lock.withLock { Self.loadedID = id }
        return loaded
    }

    /// Free the model's memory now; the downloaded files stay.
    public func unload() async {
        loading?.cancel()
        loading = nil
        loadingID = nil
        if let kit { await kit.unloadModels() }
        kit = nil
        kitID = nil
        Self.lock.withLock { Self.loadedID = nil }
    }

    /// Transcribe 16 kHz mono samples. `language` nil = detect it. `prompt`: the vocabulary hint (and, for a piece of
    /// a longer session, the words just before it), so names come out as written there. `quick`: one decoding pass,
    /// for the running transcript while the user speaks.
    public func transcribe(_ samples: [Float], model id: String, language: String?, prompt: String, quick: Bool = false) async throws -> [WhisperPiece] {
        let kit = try await kit(for: id)
        guard samples.count >= WhisperKit.sampleRate / 4 else { return [] }
        var promptTokens: [Int]?
        if let tokenizer = kit.tokenizer, !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            // The last 200 or so tokens: Whisper's prompt holds about half its context.
            promptTokens = Array(tokenizer.encode(text: " " + prompt.trimmingCharacters(in: .whitespaces))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }.suffix(200))
        }
        let options = DecodingOptions(language: language, temperatureFallbackCount: quick ? 0 : 3, usePrefillPrompt: true,
                                      detectLanguage: language == nil, skipSpecialTokens: true, promptTokens: promptTokens,
                                      chunkingStrategy: samples.count > WhisperKit.sampleRate * 30 ? .vad : nil)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap(\.segments).map {
            WhisperPiece(text: Self.clean($0.text), start: Double($0.start), end: Double($0.end))
        }
    }

    /// The text of the whole of `samples`.
    public func text(_ samples: [Float], model id: String, language: String?, prompt: String, quick: Bool = false) async throws -> String {
        FragmentStitcher.join(try await transcribe(samples, model: id, language: language, prompt: prompt, quick: quick).map(\.text))
    }

    /// Whisper's markers ("[BLANK_AUDIO]", "(music)", "<|…|>") aren't words.
    static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[[^\]]*\]|\((?:music|applause|laughter|silence|inaudible|blank_audio)\)"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
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
    private let model: String, language: String?, vocabulary: String
    private let onPiece: @Sendable (String, Double) -> Void
    private let lock = NSLock()
    /// The audio not committed yet, and where it starts in the stream (samples).
    private var pending: [Float] = []
    private var dropped = 0
    private var committedText = ""
    private var loop: Task<Void, Never>?
    private static let rate = Double(WhisperKit.sampleRate)

    public init(model: String, language: String?, vocabulary: String, onPiece: @escaping @Sendable (String, Double) -> Void) {
        self.model = model; self.language = language; self.vocabulary = vocabulary; self.onPiece = onPiece
    }

    /// 16 kHz mono samples (any thread).
    public func append(_ samples: [Float]) { lock.withLock { pending.append(contentsOf: samples) } }

    public func start() {
        loop = Task { [weak self] in
            var decodedAt = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                let (audio, total) = self.lock.withLock { (self.pending, self.dropped + self.pending.count) }
                // Once 5 s of new audio have built up, and not again before 2 s more.
                guard audio.count >= Int(Self.rate * WhisperLive.chunkSeconds), total - decodedAt >= Int(Self.rate * 2) else { continue }
                decodedAt = total
                if let (text, at) = await self.commit(audio, final: false) { self.onPiece(text, at) }
            }
        }
    }

    /// Decode the audio not committed yet and commit what is finished: its text and where it starts, or nil.
    private func commit(_ audio: [Float], final: Bool) async -> (String, Double)? {
        let (start, prompt) = lock.withLock { (dropped, vocabulary + " " + committedText.suffix(400)) }
        guard let pieces = try? await WhisperEngine.shared.transcribe(audio, model: model, language: language, prompt: prompt) else { return nil }
        let duration = Double(audio.count) / Self.rate
        var release = 0, text = "", at = 0.0
        if final {
            text = pieces.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            at = pieces.first { !$0.text.isEmpty }?.start ?? 0
            release = audio.count
        } else if let pick = WhisperLive.chooseCommit(pieces, duration: duration) {
            text = pick.text
            at = pieces.first { !$0.text.isEmpty }?.start ?? 0
            release = min(audio.count, Int(pick.end * Self.rate))
        } else if !pieces.contains(where: { !$0.text.isEmpty }), duration >= WhisperLive.forceSeconds {
            // Nothing heard for a while: let that audio go too, keeping the last moments in case speech is starting.
            release = audio.count - Int((WhisperLive.commitMargin + 1) * Self.rate)
        }
        guard release > 0 else { return nil }
        lock.withLock {
            pending.removeFirst(min(release, pending.count))
            dropped += release
            if !text.isEmpty { committedText = (committedText + " " + text).trimmingCharacters(in: .whitespaces) }
        }
        return text.isEmpty ? nil : (text, Double(start) / Self.rate + at)
    }

    /// Stop listening and transcribe what is left: returned (not sent to `onPiece`), so the caller has it at once.
    public func finish() async -> (text: String, at: Double)? {
        loop?.cancel()
        await loop?.value
        let rest = lock.withLock { pending }
        guard rest.count >= Int(Self.rate * 0.3), let (text, at) = await commit(rest, final: true) else { return nil }
        return (text, at)
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

    /// A whole recording transcribed in 5-minute parts (each part's pieces timed from the recording's start), with the
    /// fraction done after each part.
    public static func transcribe(_ url: URL, model: String, language: String?, prompt: String,
                                  progress: @Sendable (Double) async -> Void = { _ in }) async throws -> [WhisperPiece] {
        let all = try samples(url)
        let part = WhisperKit.sampleRate * 300
        var pieces: [WhisperPiece] = []
        var from = 0
        while from < all.count {
            try Task.checkCancellation()
            let to = min(all.count, from + part)
            let offset = Double(from) / Double(WhisperKit.sampleRate)
            let context = pieces.suffix(8).map(\.text).joined(separator: " ")
            pieces += try await WhisperEngine.shared.transcribe(Array(all[from..<to]), model: model, language: language, prompt: prompt + " " + context)
                .map { WhisperPiece(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
            from = to
            await progress(Double(to) / Double(max(1, all.count)))
        }
        return pieces.filter { !$0.text.isEmpty }
    }
}
