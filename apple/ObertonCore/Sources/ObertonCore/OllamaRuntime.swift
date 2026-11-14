import Foundation
#if os(macOS)
import CryptoKit
import Security
#endif

/// The local AI runtime (Windows' OllamaHost and RuntimeInstaller step 3). Ollama answering at the address in Settings
/// is used as it is, whoever started it. Outside the App Store sandbox (the direct download), Oberton can also install
/// its own copy of Ollama (application data's runtime/ollama, models in models/ollama) and start it when nothing
/// answers, on that address's port, with cloud models switched off: as the Windows app does with the copy it bundles.
/// The App Store build can't run a downloaded program, so there the user installs Ollama themselves.
public enum OllamaRuntime {
    /// The same release the Windows app bundles.
    public static let version = "0.35.1"
    static let download = URL(string: "https://github.com/ollama/ollama/releases/download/v\(version)/ollama-darwin.tgz")!
    /// The SHA-256 of `ollama-darwin.tgz` for each pinned release (as GitHub lists it for the asset, and checked against
    /// a download). A version without one is never installed.
    static let sha256 = ["0.35.1": "3137dbf28948ee844e0fb3e584d9b5de6879d73d9f0cb7eff3ad64930601d307"]
    /// The Developer ID team that signs Ollama's macOS builds ("Infra Technologies, Inc").
    static let teamID = "3MU9H2V9Y9"

    public static var dir: URL { AppPaths.dataDir.appending(path: "runtime/ollama", directoryHint: .isDirectory) }
    static var executable: URL { dir.appending(path: "ollama") }
    static var modelsDir: URL { AppPaths.dataDir.appending(path: "models/ollama", directoryHint: .isDirectory) }

    /// Oberton's own copy is installed.
    public static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    /// This build may install and start a runtime of its own: not in the sandbox (and not on iOS).
    public static var canManage: Bool {
        #if os(macOS)
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
        #else
        false
        #endif
    }

    /// Make sure the runtime answers: start Oberton's own copy if nothing does (Windows' EnsureRunningAsync). One
    /// caller at a time (Windows' SemaphoreSlim), so a warm-up, a dictation and the Models page never start two copies.
    public static func ensureRunning(settings: AppSettings) async throws {
        let (previous, done) = gate.enqueue()
        defer { done() }
        await previous?.value
        try await ensureRunningNow(settings: settings)
    }

    private static let gate = Gate()

    /// A first-come, first-served async lock: each caller waits for the one before it.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var tail: Task<Void, Never>?

        func enqueue() -> (previous: Task<Void, Never>?, done: @Sendable () -> Void) {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            let mine = Task { for await _ in stream {} }
            let previous = lock.withLock { () -> Task<Void, Never>? in
                let p = tail
                tail = mine
                return p
            }
            return (previous, { continuation.finish() })
        }
    }

    private static func ensureRunningNow(settings: AppSettings) async throws {
        let endpoint = try OllamaBackend.validated(settings.ollamaEndpoint)
        if await OllamaBackend.ping(endpoint: endpoint) { return }
        #if os(macOS)
        if canManage && isInstalled && settings.startOllama {
            try await Host.shared.start(endpoint: endpoint, keepAlive: settings.ollamaKeepAlive)
            return
        }
        #endif
        throw UserFacingError(OllamaBackend.notRunning)
    }

    #if os(macOS)
    /// Download and unpack Oberton's own copy (about 190 MB). `progress` gets the fraction (nil while unknown).
    /// `unpacking` is called once the download is in and it is being unpacked.
    public static func install(progress: @escaping @Sendable (Double?) -> Void, unpacking: @Sendable () -> Void = {}) async throws {
        guard canManage else { throw UserFacingError("Install Ollama from ollama.com; this version of Oberton can't install it itself.") }
        let fm = FileManager.default
        let tgz = AppPaths.dataDir.appending(path: "runtime/ollama-darwin.tgz")
        try fm.createDirectory(at: tgz.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tgz) }
        do {
            try await FileDownload.run(download, to: tgz, progress: progress)
        } catch let e as URLError where e.code != .cancelled {
            throw UserFacingError("Downloading the AI runtime (Ollama) failed. Check your internet connection and try again.")
        }
        progress(nil)
        // Nothing from the download is unpacked, let alone run, unless it is exactly the pinned file.
        do {
            try RuntimeIntegrity.checkSHA256(of: tgz, expected: sha256[version])
        } catch {
            CoreLog.error("The AI runtime download was refused: \(error)")
            throw UserFacingError(RuntimeIntegrity.refusedDownload)
        }
        unpacking()
        let tmp = AppPaths.dataDir.appending(path: "runtime/ollama-tmp", directoryHint: .isDirectory)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", tgz.path, "-C", tmp.path]
        try tar.run()
        await Task.detached { tar.waitUntilExit() }.value
        guard tar.terminationStatus == 0, fm.isExecutableFile(atPath: tmp.appending(path: "ollama").path) else {
            try? fm.removeItem(at: tmp)
            throw UserFacingError("Unpacking the AI runtime (Ollama) failed. Try again.")
        }
        // Every program and library in it signed by Ollama's developer, and no link pointing out of the folder, before
        // it takes the place of the copy there now.
        do {
            try RuntimeIntegrity.checkSignatures(in: tmp, team: teamID)
        } catch {
            try? fm.removeItem(at: tmp)
            CoreLog.error("The AI runtime was refused: \(error)")
            throw UserFacingError(RuntimeIntegrity.refusedSignature)
        }
        try? fm.removeItem(at: dir)
        try fm.moveItem(at: tmp, to: dir)
        CoreLog.info("Installed the AI runtime (Ollama \(version))")
    }

    /// Stop the copy Oberton started (at quit; Windows ties it to the app with a job object).
    public static func stop() { Host.shared.stop() }

    /// Windows' words when its runtime didn't come up, with the Mac's log (in the data folder's logs, as Windows').
    static let didntStart = "The local AI runtime (Ollama) didn't start. See logs/dictation.log."

    /// The running `ollama serve`, at most one.
    final class Host: @unchecked Sendable {
        static let shared = Host()
        private let lock = NSLock()
        private var process: Process?

        func start(endpoint: URL, keepAlive: String) async throws {
            // The program about to run is still the one Ollama's developer signed (nothing replaced it since install).
            let check = RuntimeIntegrity.checkSignature(of: OllamaRuntime.executable, team: OllamaRuntime.teamID)
            guard check == errSecSuccess else {
                CoreLog.error("The AI runtime wasn't started: its signature didn't check out (\(check))")
                throw UserFacingError(RuntimeIntegrity.refusedSignature)
            }
            // Through a small shell that ends `ollama serve` when Oberton goes, also when it crashes (Windows puts the
            // runtime in a job object that dies with the app).
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", Self.watchdog, "oberton-ollama", OllamaRuntime.executable.path, String(getpid())]
            var env = ProcessInfo.processInfo.environment
            env["OLLAMA_HOST"] = "127.0.0.1:\(endpoint.port ?? 11434)"
            env["OLLAMA_MODELS"] = OllamaRuntime.modelsDir.path
            env["OLLAMA_NO_CLOUD"] = "1"
            env["OLLAMA_KEEP_ALIVE"] = keepAlive
            p.environment = env
            p.currentDirectoryURL = OllamaRuntime.dir
            try? FileManager.default.createDirectory(at: OllamaRuntime.modelsDir, withIntermediateDirectories: true)
            // Its output goes into Oberton's log line by line, "ollama: …", as Windows logs it (the runtime logs
            // requests, never their text).
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            let lines = LineSplitter()
            out.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty { h.readabilityHandler = nil; lines.flush { CoreLog.info("ollama: " + $0) }; return }
                lines.add(data) { CoreLog.info("ollama: " + $0) }
            }
            lock.withLock { stopLocked(); process = p }
            do { try p.run() } catch {
                CoreLog.error("The AI runtime didn't start: \(error)")
                throw UserFacingError(OllamaRuntime.didntStart)
            }
            Self.killAtExit()
            for _ in 0..<60 {
                if !p.isRunning { break }
                if await OllamaBackend.ping(endpoint: endpoint) { return }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw UserFacingError(OllamaRuntime.didntStart)
        }

        /// `sh -c <this> oberton-ollama <ollama> <oberton's pid>`: runs `ollama serve`, and stops it when Oberton is
        /// gone or this shell is told to stop.
        static let watchdog = """
            "$1" serve & c=$!
            trap 'kill $c 2>/dev/null; wait $c; exit 0' TERM INT HUP
            while kill -0 "$2" 2>/dev/null && kill -0 $c 2>/dev/null; do sleep 1; done
            kill $c 2>/dev/null; wait $c
            """

        func stop() { lock.withLock { stopLocked() } }

        private func stopLocked() {
            if let p = process, p.isRunning { p.terminate() }
            process = nil
        }

        nonisolated(unsafe) private static var registered = false
        /// When Oberton quits (exit runs these), the runtime goes too.
        private static func killAtExit() {
            guard !registered else { return }
            registered = true
            atexit { OllamaRuntime.Host.shared.stop() }
        }
    }
    #endif
}

#if os(macOS)
/// Checks on the AI runtime Oberton downloads and runs (security audit 2026-11-07): the archive's SHA-256 against the
/// pinned one, and each program's code signature against Ollama's Developer ID. Fails closed.
enum RuntimeIntegrity {
    static let refusedDownload = "The downloaded AI runtime (Ollama) isn't the file this version of Oberton expects, so it wasn't installed. Try again later; if it keeps happening, the download is being changed on the way."
    static let refusedSignature = "The AI runtime (Ollama) isn't signed by Ollama's developer, so Oberton won't run it. Install it again from Settings › Models."

    enum Problem: Error, CustomStringConvertible, Equatable {
        case noPinnedHash
        case hashMismatch(actual: String)
        case badSignature(file: String, status: OSStatus)
        case linkOutside(file: String)
        case unreadable(file: String)

        var description: String {
            switch self {
            case .noPinnedHash: "no SHA-256 is pinned for this version"
            case .hashMismatch(let actual): "SHA-256 \(actual) isn't the pinned one"
            case .badSignature(let file, let status): "\(file): code signature check failed (\(status))"
            case .linkOutside(let file): "\(file): a link pointing out of the folder"
            case .unreadable(let file): "\(file): couldn't be read, so its signature wasn't checked"
            }
        }
    }

    /// The file's SHA-256, in lower-case hex, read a megabyte at a time.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func checkSHA256(of file: URL, expected: String?) throws {
        guard let expected else { throw Problem.noPinnedHash }
        let actual = try sha256(of: file)
        guard actual == expected.lowercased() else { throw Problem.hashMismatch(actual: actual) }
    }

    /// Developer ID Application, signed by that team: what `codesign` shows as Ollama's designated requirement.
    static func requirement(team: String) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// One file's signature: valid (every architecture, strictly) and from `team`. errSecSuccess when it is.
    static func checkSignature(of file: URL, team: String) -> OSStatus {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(file as CFURL, [], &code)
        guard status == errSecSuccess, let code else { return status }
        var req: SecRequirement?
        status = SecRequirementCreateWithString(requirement(team: team) as CFString, [], &req)
        guard status == errSecSuccess, let req else { return status }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, req)
    }

    /// Every Mach-O file under `dir` (programs, .dylib, .so, in subfolders too) signed by `team`, and every symbolic
    /// link resolving inside `dir`.
    static func checkSignatures(in dir: URL, team: String) throws {
        let root = dir.resolvingSymlinksInPath().standardizedFileURL.path
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey]
        // Fails closed: a folder that can't be walked, or a part of it that can't be read, is a failed check, not
        // an empty one.
        var unreadable: String?
        guard let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, errorHandler: { url, _ in
            unreadable = unreadable ?? url.lastPathComponent
            return true
        }) else { throw Problem.unreadable(file: dir.lastPathComponent) }
        for case let url as URL in walk {
            let values = try url.resourceValues(forKeys: Set(keys))
            // Its path inside `dir` ("mlx_metal_v3/libmlx.dylib"), from the resolved folder it sits in.
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            let name = (parent == root ? "" : String(parent.dropFirst(root.count + 1)) + "/") + url.lastPathComponent
            if values.isSymbolicLink == true {
                // Where the link says it points (whether or not that exists), from the folder it sits in; a link to
                // another link inside is checked when that one comes up.
                let written = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                let target = (written.hasPrefix("/") ? URL(fileURLWithPath: written) : URL(fileURLWithPath: parent).appending(path: written))
                    .standardizedFileURL.path
                guard target == root || target.hasPrefix(root + "/") else { throw Problem.linkOutside(file: name) }
                continue
            }
            guard values.isRegularFile == true, isMachO(url) else { continue }
            let status = checkSignature(of: url, team: team)
            guard status == errSecSuccess else { throw Problem.badSignature(file: name, status: status) }
        }
        if let unreadable { throw Problem.unreadable(file: unreadable) }
    }

    /// A Mach-O file (thin or universal), by its first four bytes.
    static func isMachO(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let magic = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return [0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA].contains(magic)
    }
}

/// Bytes from a pipe as whole lines.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func add(_ data: Data, _ line: (String) -> Void) {
        let done: [String] = lock.withLock {
            pending.append(data)
            var out: [String] = []
            while let nl = pending.firstIndex(of: 0x0A) {
                out.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                pending.removeSubrange(pending.startIndex...nl)
            }
            return out
        }
        done.forEach(line)
    }

    func flush(_ line: (String) -> Void) {
        let rest = lock.withLock { () -> String in defer { pending = Data() }; return String(decoding: pending, as: UTF8.self) }
        if !rest.isEmpty { line(rest) }
    }
}

/// One file download with progress (URLSession's delegate API), for the runtime.
final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double?) -> Void
    private let target: URL
    private var continuation: CheckedContinuation<Void, Error>?

    private init(target: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.target = target
        self.progress = progress
    }

    static func run(_ url: URL, to target: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        let d = FileDownload(target: target, progress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                d.continuation = c
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status / 100 != 2 { throw URLError(.badServerResponse) }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        continuation = nil
    }
}
#endif
