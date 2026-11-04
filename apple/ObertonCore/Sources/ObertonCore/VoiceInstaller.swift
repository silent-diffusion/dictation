import Foundation

/// How a voice download is going (Windows' SetupProgress): step N of M, its title ("Downloading the voice model"),
/// how far (nil while unknown) and a detail ("About 325 MB").
public struct VoiceProgress: Equatable, Sendable {
    public var step: Int
    public var totalSteps: Int
    public var title: String
    public var fraction: Double?
    public var detail: String

    public init(step: Int, totalSteps: Int, title: String, fraction: Double?, detail: String) {
        self.step = step
        self.totalSteps = totalSteps
        self.title = title
        self.fraction = fraction
        self.detail = detail
    }
}

extension VoiceProgress {
    /// A download that hasn't reported yet: no title, an empty bar.
    public static let waiting = VoiceProgress(step: 1, totalSteps: 1, title: "", fraction: 0, detail: "")
}

/// One voice download under way: which voice, which files it fetches (all of Kokoro's voices share one model), and
/// how it is going.
public struct VoiceDownload: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let voice: String
    let files: String
    public var progress: VoiceProgress

    static func files(_ voice: String) -> String { VoiceCatalog.findPiper(voice)?.id ?? VoiceCatalog.kokoro }
}

/// Downloads Read aloud's voices as data into models/kokoro and models/piper (Windows' RuntimeInstaller
/// InstallReadAloudAsync / InstallPiperVoiceAsync): the same Kokoro v1.0 model and voices, and the same Piper files.
/// Instead of Windows' voice engine (Python with espeak-ng), the Mac fetches the pronunciation dictionary its own
/// phonemizer reads (misaki's, the one Kokoro was trained with); it is shared by Kokoro and Piper.
public enum VoiceInstaller {
    // Read aloud: Kokoro v1.0 (Apache 2.0), full-precision model for the best voice quality.
    static let kokoroModelURL = URL(string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx")!
    static let kokoroVoicesURL = URL(string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin")!
    /// misaki's English lexicons (Apache 2.0), pinned to one commit.
    static let lexiconBase = "https://raw.githubusercontent.com/hexgrad/misaki/fba1236595f2d2bf21d414ba6e57d25256afada3/misaki/data/"
    static let lexiconFiles = ["us_gold.json", "us_silver.json", "gb_gold.json", "gb_silver.json"]

    /// Approximate one-time download for Kokoro, in MB (model 325, voices 28, dictionary 13).
    public static let kokoroDownloadMb = 370

    static var modelsDir: URL { AppPaths.dataDir.appending(path: "models", directoryHint: .isDirectory) }
    public static var kokoroDir: URL { modelsDir.appending(path: "kokoro", directoryHint: .isDirectory) }
    public static var kokoroModel: URL { kokoroDir.appending(path: "kokoro-v1.0.onnx") }
    public static var kokoroVoices: URL { kokoroDir.appending(path: "voices-v1.0.bin") }
    /// The pronunciation dictionary (models/lexicon/us_gold.json…).
    public static var lexiconDir: URL { modelsDir.appending(path: "lexicon", directoryHint: .isDirectory) }
    /// Piper voices: models/piper/<name>.onnx with <name>.onnx.json.
    public static var piperDir: URL { modelsDir.appending(path: "piper", directoryHint: .isDirectory) }
    static func piperFile(_ name: String) -> URL { piperDir.appending(path: name + ".onnx") }
    static func piperConfig(_ name: String) -> URL { piperDir.appending(path: name + ".onnx.json") }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The phonemizer's dictionary is here (Kokoro and Piper both need it).
    public static var lexiconInstalled: Bool { lexiconFiles.allSatisfy { exists(lexiconDir.appending(path: $0)) } }

    /// Kokoro is ready: its model, its voices and the dictionary are present.
    public static var kokoroInstalled: Bool { exists(kokoroModel) && exists(kokoroVoices) && lexiconInstalled }

    public static func piperInstalled(_ name: String) -> Bool {
        lexiconInstalled && exists(piperFile(name)) && exists(piperConfig(name))
    }

    /// Download Kokoro (and the dictionary, the first time). Cancel the task to stop; finished files stay.
    public static func installKokoro(progress: @escaping @Sendable (VoiceProgress) -> Void) async throws {
        let total = 3
        @Sendable func step(_ n: Int, _ title: String, _ f: Double?, _ detail: String = "") {
            progress(VoiceProgress(step: n, totalSteps: total, title: title, fraction: f, detail: detail))
        }
        try await ensureLexicon { step(1, "Downloading the pronunciation dictionary", $0, "About 13 MB") }
        if !exists(kokoroModel) {
            try await download(kokoroModelURL, to: kokoroModel) { step(2, "Downloading the voice model", $0, "About 325 MB") }
        }
        if !exists(kokoroVoices) {
            try await download(kokoroVoicesURL, to: kokoroVoices) { step(3, "Downloading the voices", $0, "About 28 MB") }
        }
        CoreLog.info("Read aloud installed")
        step(3, "Done", 1)
    }

    /// Download one Piper voice (and the dictionary, the first time).
    public static func installPiper(_ voice: PiperVoice, progress: @escaping @Sendable (VoiceProgress) -> Void) async throws {
        let total = 2
        @Sendable func step(_ n: Int, _ title: String, _ f: Double?, _ detail: String = "") {
            progress(VoiceProgress(step: n, totalSteps: total, title: title, fraction: f, detail: detail))
        }
        try await ensureLexicon { step(1, "Downloading the pronunciation dictionary", $0, "About 13 MB") }
        if !exists(piperConfig(voice.name)) {
            try await download(URL(string: voice.url.absoluteString + ".json")!, to: piperConfig(voice.name)) { _ in }
        }
        if !exists(piperFile(voice.name)) {
            try await download(voice.url, to: piperFile(voice.name)) {
                step(2, "Downloading the Piper voice \(voice.label)", $0, "About \(voice.mb) MB")
            }
        }
        CoreLog.info("Piper voice installed: " + voice.name)
        step(2, "Done", 1)
    }

    private static func ensureLexicon(_ progress: @escaping @Sendable (Double?) -> Void) async throws {
        let missing = lexiconFiles.filter { !exists(lexiconDir.appending(path: $0)) }
        for (i, file) in missing.enumerated() {
            try await download(URL(string: lexiconBase + file)!, to: lexiconDir.appending(path: file)) { f in
                progress((Double(i) + (f ?? 0)) / Double(missing.count))
            }
        }
    }

    /// Fetch `url` into `destination`, reporting the fraction done (nil while the size is unknown) each time another
    /// MB has arrived, as Windows' DownloadAsync (so nothing before the first MB, and nothing at the end). The file only
    /// appears once it is complete. A network or server failure gives Windows' message.
    static func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fetcher = Fetcher(progress: progress)
        let temp: URL
        do {
            temp = try await fetcher.fetch(url)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            guard error is URLError else { throw error }
            throw UserFacingError(networkFailure)
        }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch where FileManager.default.fileExists(atPath: destination.path) {
            // Another download (the dictionary is shared by Kokoro and Piper) put it there first.
            try? FileManager.default.removeItem(at: temp)
        }
    }

    /// RuntimeInstaller's text for a failed download (HttpRequestException).
    static let networkFailure = "A download failed. Check your internet connection and click Retry."

    /// One download with progress, on its own URLSession (its delegate gets the byte counts).
    final class Fetcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double?) -> Void
        private var continuation: CheckedContinuation<URL, Error>?
        private let lock = NSLock()
        private var lastReport: Int64 = 0

        init(progress: @escaping @Sendable (Double?) -> Void) { self.progress = progress }

        func fetch(_ url: URL) async throws -> URL {
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let task = session.downloadTask(with: url)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { c in
                    lock.withLock { continuation = c }
                    task.resume()
                }
            } onCancel: { task.cancel() }
        }

        private func finish(_ result: Result<URL, Error>) {
            let c = lock.withLock { () -> CheckedContinuation<URL, Error>? in
                defer { continuation = nil }
                return continuation
            }
            c?.resume(with: result)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            // Once more than 1 MB has come since the last report (`done - lastReport > 1 << 20`).
            guard Self.shouldReport(written: totalBytesWritten, last: &lastReport) else { return }
            progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
        }

        static func shouldReport(written: Int64, last: inout Int64) -> Bool {
            guard written - last > 1 << 20 else { return false }
            last = written
            return true
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                finish(.failure(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])))
                return
            }
            // The file is deleted when this returns: keep it.
            let keep = FileManager.default.temporaryDirectory.appending(path: "oberton-voice-" + UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: location, to: keep)
                finish(.success(keep))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)) }
        }
    }
}
