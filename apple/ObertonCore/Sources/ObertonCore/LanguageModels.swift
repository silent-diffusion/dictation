import Foundation
import FoundationModels
#if canImport(Metal)
import Metal
#endif

/// An error worth showing to the user as it is.
public struct UserFacingError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Which AI a profile uses, written as one string so settings stay plain JSON:
/// `apple:on-device`, `ollama:<tag>`, `anthropic:<model>` or `openai:<model>`.
public struct ModelID: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Provider: String, Sendable, Codable, CaseIterable {
        case apple, ollama, anthropic, openai
    }

    public var provider: Provider
    public var name: String

    public static let appleOnDevice = ModelID(provider: .apple, name: "on-device")

    public init(provider: Provider, name: String) {
        self.provider = provider
        self.name = name
    }

    public init?(_ raw: String) {
        // The provider in any case, as Windows' CloudModels.Split ("OpenAI:gpt-4.1-mini").
        guard let colon = raw.firstIndex(of: ":"), let p = Provider(rawValue: String(raw[..<colon]).lowercased()) else { return nil }
        self.init(provider: p, name: String(raw[raw.index(after: colon)...]))
    }

    /// A model as a profile or the settings store it (Windows' `ModelFor`/`string.IsNullOrWhiteSpace(p.Model)`): nil
    /// when blank, "provider:name" as usual, and anything else as an Ollama tag, the way Windows writes local models
    /// ("qwen2.5:3b"), so a profiles.json from Windows keeps its model.
    public init?(stored raw: String?) {
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let id = ModelID(t) {
            guard !id.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self = id
        } else {
            self.init(provider: .ollama, name: t)
        }
    }

    public var description: String { "\(provider.rawValue):\(name)" }

    /// The id as Windows writes and shows it: an Ollama model by its bare tag, a cloud model as "provider:name".
    public var windowsForm: String { provider == .ollama ? name : description }

    /// Anthropic or OpenAI(-compatible): the text goes to that service with the user's key.
    public var isCloud: Bool { provider == .anthropic || provider == .openai }

    /// Runs on this device (or on this Mac, for Ollama), so it is allowed while "Keep everything offline" is on.
    public var isLocal: Bool { provider == .apple || (provider == .ollama && !isOllamaCloud) }

    /// An Ollama model that Ollama runs on ollama.com rather than on this Mac (its names end in "-cloud" or ":cloud").
    /// It goes through the local Ollama like any other model, but "Keep everything offline" blocks it all the same.
    public var isOllamaCloud: Bool { provider == .ollama && Self.isOllamaCloud(name) }

    public static func isOllamaCloud(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix("-cloud") || n.hasSuffix(":cloud") || n.contains("-cloud:")
    }

    public var displayName: String {
        switch provider {
        case .apple: "Apple Intelligence (on-device)"
        case .ollama: name
        case .anthropic: CloudCatalog.anthropic.first { $0.id == self }?.title ?? name
        case .openai: name
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = ModelID(stored: raw) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: raw)) }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

public struct CloudModel: Sendable, Identifiable {
    public var id: ModelID
    public var title: String
    public var blurb: String
}

public enum CloudCatalog {
    public static let anthropic: [CloudModel] = [
        CloudModel(id: ModelID(provider: .anthropic, name: "claude-haiku-4-5-20251001"), title: "Claude Haiku 4.5", blurb: "Fast and inexpensive; plenty for cleanup."),
        CloudModel(id: ModelID(provider: .anthropic, name: "claude-sonnet-5-5"), title: "Claude Sonnet 5.5", blurb: "Stronger rewriting, e.g. emails from rambling."),
        CloudModel(id: ModelID(provider: .anthropic, name: "claude-opus-5-5"), title: "Claude Opus 5.5", blurb: "The most capable; slower and pricier."),
    ]

    /// Windows' CloudModels.Catalog: Anthropic's models, then the OpenAI(-compatible) model set under Settings › Cloud AI.
    public static func models(_ cloud: CloudSettings) -> [CloudModel] {
        anthropic + [CloudModel(id: ModelID(provider: .openai, name: cloud.openAIModel), title: cloud.openAIModel,
                                blurb: "From \(cloud.openAIBaseURL)")]
    }
}

/// A local model offered for download through Ollama (Windows' ModelsPage `LocalModels`), word for word, with "PC"
/// read as "Mac".
public struct LocalCatalogModel: Sendable, Identifiable, Equatable {
    /// The Ollama tag.
    public var id: String
    public var name: String
    public var description: String
    public var size: String
    /// The memory it needs (a model that runs from memory), 0 for none.
    public var minRamGB: Double = 0

    public init(id: String, name: String, description: String, size: String, minRamGB: Double = 0) {
        self.id = id; self.name = name; self.description = description; self.size = size; self.minRamGB = minRamGB
    }
}

public enum LocalCatalog {
    /// Windows' default local AI model (Llm.DefaultModel, and what setup downloads).
    public static let defaultModel = "qwen2.5:3b"

    public static let all: [LocalCatalogModel] = [
        LocalCatalogModel(id: "qwen2.5:3b", name: "Qwen 2.5 3B", description: "Fast, faithful cleanup. The default.", size: "1.9 GB"),
        LocalCatalogModel(id: "llama3.2:3b", name: "Llama 3.2 3B", description: "Fast, natural phrasing.", size: "2.0 GB"),
        LocalCatalogModel(id: "phi4-mini", name: "Phi-4 mini", description: "Good at following instructions.", size: "2.5 GB"),
        LocalCatalogModel(id: "gemma3:4b", name: "Gemma 3 4B", description: "Strong writing for its size.", size: "3.3 GB"),
        LocalCatalogModel(id: "qwen2.5:7b", name: "Qwen 2.5 7B",
                          description: "Better rewriting (emails, summaries). Needs about 8 GB of GPU memory to be quick.", size: "4.7 GB"),
        LocalCatalogModel(id: "qwen3:30b-a3b-instruct-2507-q4_K_M", name: "Qwen3 30B-A3B",
                          description: "By far the smartest here: the best for Extended Notes' formatting and summaries. A mixture of experts: 30B parameters, " +
                              "but only 3B work on each word, so it runs from the Mac's memory, with as much of it on the GPU as there is room for. " +
                              "Needs 32 GB of RAM. For dictation it is slower (several seconds a paragraph).", size: "19 GB", minRamGB: 30),
        LocalCatalogModel(id: "qwen3.8:27b-q4_K_M", name: "Qwen3.8 27B",
                          description: "The newest and strongest writer here, but an ordinary model: all 27B parameters work on each word. Quick only on a " +
                              "graphics card with 24 GB; with less, most of it runs from the Mac's memory on the processor and is very slow " +
                              "(a minute or more for each notes step, several for a summary). Needs 32 GB of RAM. Chosen by hand for " +
                              "Extended Notes (Best on this Mac passes it over when it doesn't fit the GPU).", size: "18 GB", minRamGB: 30),
    ]

    /// Ollama names a model without a tag "name:latest": both are the same model (Windows' `Same`).
    public static func same(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame || a.caseInsensitiveCompare(b + ":latest") == .orderedSame
            || b.caseInsensitiveCompare(a + ":latest") == .orderedSame
    }

    /// " · this Mac has 16 GB of RAM: too little", for a model that needs more memory and isn't downloaded yet.
    public static func ramWarning(_ m: LocalCatalogModel, downloaded: Bool, ramBytes: Int64 = LocalModel.systemRam) -> String {
        let gb = Double(ramBytes) / (1024 * 1024 * 1024)
        guard m.minRamGB > 0, !downloaded, gb < m.minRamGB else { return "" }
        return " · this Mac has \(Int(gb.rounded())) GB of RAM: too little"
    }
}

/// One chat completion: instructions, optional before/after examples, the user's text.
public protocol LanguageModelBackend: Sendable {
    func complete(system: String, examples: [(input: String, output: String)], user: String, maxTokens: Int) async throws -> String
}

// MARK: - Apple Intelligence

/// Apple's on-device foundation model (Apple Intelligence). Nothing leaves the device; nothing to download beyond
/// what macOS/iOS already manages.
public struct AppleIntelligenceBackend: LanguageModelBackend {
    public init() {}

    /// Nil when ready; otherwise why it can't be used, in words for the user.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is turned off. Turn it on in System Settings › Apple Intelligence & Siri."
        case .unavailable(.modelNotReady): "Apple Intelligence is still getting ready (downloading its model). Try again in a few minutes."
        case .unavailable: "Apple Intelligence isn't available right now."
        }
    }

    /// Apple Intelligence can't run now but will by itself soon (its model is still downloading).
    public static var isGettingReady: Bool {
        if case .unavailable(.modelNotReady) = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// This device can never run Apple Intelligence.
    public static var isUnsupported: Bool {
        if case .unavailable(.deviceNotEligible) = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Load the on-device model ahead of the first dictation.
    public static func warmUp() {
        guard unavailableReason == nil else { return }
        LanguageModelSession(model: .default).prewarm()
    }

    public func complete(system: String, examples: [(input: String, output: String)], user: String, maxTokens: Int) async throws -> String {
        if let reason = Self.unavailableReason { throw UserFacingError(reason) }
        // The on-device model takes examples best inside its instructions; the chat-turn form the other back ends use
        // would need a hand-built Transcript for the same effect.
        var instructions = system
        if !examples.isEmpty {
            instructions += "\nExamples of input and the reply expected:\n"
            for e in examples { instructions += "\nInput:\n\(e.input)\nReply:\n\(e.output)\n" }
        }
        let session = LanguageModelSession(model: .default, instructions: instructions)
        // The 27 SDKs (Swift 6.4, Xcode 27) renamed `sampling:` to `samplingMode:` and deprecated the old label;
        // the 26 SDKs (Swift 6.2–6.3, Xcode 26.x) only have `sampling:`.
        #if compiler(>=6.4)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxTokens)
        #else
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)
        #endif
        do {
            let response = try await session.respond(to: user, options: options)
            return response.content
        } catch let e as LanguageModelSession.GenerationError {
            switch e {
            case .guardrailViolation: throw UserFacingError("Apple Intelligence declined to edit this text.")
            case .exceededContextWindowSize: throw UserFacingError("This dictation is too long for Apple Intelligence in one piece.")
            default: throw UserFacingError("Apple Intelligence couldn't edit this text (\(e.localizedDescription)).")
            }
        }
    }
}

// MARK: - Ollama

/// A local Ollama server on this Mac. The endpoint must be a loopback address, as on Windows.
public struct OllamaBackend: LanguageModelBackend {
    public var endpoint: URL
    public var model: String
    public var timeout: TimeInterval
    /// How long Ollama keeps the model loaded after this request (Settings › Model unloading); nil = Ollama's default.
    public var keepAlive: String?

    public init(endpoint: URL, model: String, timeout: TimeInterval = 60, keepAlive: String? = nil) {
        self.endpoint = endpoint
        self.model = model
        self.timeout = timeout
        self.keepAlive = keepAlive
    }

    public static func validated(_ s: String) throws -> URL {
        guard let url = URL(string: s), isLoopback(url) else {
            throw UserFacingError("The Ollama address must be on this Mac (\(AppSettings().ollamaEndpoint)).")
        }
        return url
    }

    /// An address on this device (Windows' `Uri.IsLoopback`): localhost, ::1, or any 127.x.x.x, written in any of the
    /// forms .NET's Uri reads as IPv4 ("127.1", "0x7f.0.0.1", "2130706433" too).
    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              !host.isEmpty else { return false }
        if host == "localhost" { return true }
        if host.contains(":") {
            var v6 = in6_addr()
            guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
            return withUnsafeBytes(of: &v6) { Array($0) } == [UInt8](repeating: 0, count: 15) + [1]
        }
        guard host.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" }) else { return false }
        var v4 = in_addr()
        guard inet_aton(host, &v4) == 1 else { return false }
        return UInt32(bigEndian: v4.s_addr) >> 24 == 127
    }

    public func complete(system: String, examples: [(input: String, output: String)], user: String, maxTokens: Int) async throws -> String {
        var messages: [[String: String]] = [["role": "system", "content": system]]
        for e in examples {
            messages.append(["role": "user", "content": e.input])
            messages.append(["role": "assistant", "content": e.output])
        }
        messages.append(["role": "user", "content": user])
        var body: [String: Any] = [
            "model": model, "stream": false, "think": false, "messages": messages,
            "options": ["temperature": 0, "num_predict": maxTokens, "num_ctx": 4096],
        ]
        if let keepAlive { body["keep_alive"] = keepAlive }
        var req = URLRequest(url: endpoint.appending(path: "api/chat"), timeoutInterval: timeout + 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp): (Data, URLResponse)
        // Windows' CancelAfter: a deadline over the whole request, not an idle timeout. The runtime was checked before
        // this request (TextProcessor.backend), so any network failure here is "Couldn't reach" (HttpRequestException).
        let request = req
        do { (data, resp) = try await Deadline.run(seconds: timeout) { try await URLSession.shared.data(for: request) } } catch let e as URLError {
            throw UserFacingError(e.code == .timedOut ? "The AI model took too long to respond." : "Couldn't reach the local AI runtime.")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UserFacingError("The AI model '\(model)' isn't installed. Install it with:  ollama pull \(model)") }
        guard (200..<300).contains(status) else { throw UserFacingError("Couldn't reach the local AI runtime.") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["message"] as? [String: Any])?["content"] as? String ?? ""
    }

    /// Windows' "The local AI runtime (Ollama) isn't running. Run scripts\\setup.ps1, or start Ollama and check the
    /// endpoint under Settings > AI Models.", with the Mac's way to get it: the direct download can install its own
    /// copy under Settings › Models; the App Store version can't, so there the user starts their own Ollama.
    public static var notRunning: String {
        OllamaRuntime.canManage
            ? "The local AI runtime (Ollama) isn't running. Start Ollama (or install it under Settings › Models), and check the endpoint under Settings › Models."
            : "The local AI runtime (Ollama) isn't running. Start Ollama, and check the endpoint under Settings › Models."
    }

    /// Load the model into memory without generating anything (an empty chat request), so the first dictation doesn't
    /// wait for it. Returns whether Ollama answered.
    @discardableResult
    public static func warmUp(endpoint: URL, model: String, keepAlive: String? = nil) async -> Bool {
        // No time limit, as on Windows (its HttpClient waits however long a model takes to load): a 19 GB model read
        // from a slow disk can take minutes.
        var req = URLRequest(url: endpoint.appending(path: "api/chat"), timeoutInterval: 24 * 3600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "messages": [] as [Any], "options": ["num_ctx": 4096]]
        if let keepAlive { body["keep_alive"] = keepAlive }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
    }

    /// Whether the runtime answers at all (Windows' OllamaHost.PingAsync: /api/version within 2 s).
    public static func ping(endpoint: URL) async -> Bool {
        let req = URLRequest(url: endpoint.appending(path: "api/version"), timeoutInterval: 2)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
    }

    /// Download a model (Windows' RuntimeInstaller.PullAsync): /api/pull streams JSON lines with per-layer byte
    /// counts, which gives real progress (nil while unknown). Cancelling the task stops it.
    public static func pull(endpoint: URL, model: String, progress: @escaping @Sendable (Double?) -> Void) async throws {
        var req = URLRequest(url: endpoint.appending(path: "api/pull"), timeoutInterval: 3600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true] as [String: Any])
        let bytes: URLSession.AsyncBytes, resp: URLResponse
        do { (bytes, resp) = try await URLSession.shared.bytes(for: req) } catch let e as URLError where e.code != .cancelled {
            throw UserFacingError("Couldn't reach the AI runtime to download the model.")
        }
        // Windows' EnsureSuccessStatusCode and JsonNode.Parse sit outside its "Couldn't reach" catch: a bad status or
        // a line that isn't JSON is the generic "The download failed. See the log for details."
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status / 100 == 2 else { throw PullFailed(reason: "the runtime answered \(status)") }
        var layers: [String: (done: Double, total: Double)] = [:]
        for try await line in bytes.lines {
            if line.isEmpty { continue }
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                throw PullFailed(reason: "a progress line wasn't JSON")
            }
            if let err = o["error"] as? String { throw UserFacingError("Downloading the AI model failed: \(err). Click Retry.") }
            if let digest = o["digest"] as? String, let total = (o["total"] as? NSNumber)?.doubleValue {
                layers[digest] = ((o["completed"] as? NSNumber)?.doubleValue ?? 0, total)
                let t = layers.values.reduce(0) { $0 + $1.total }
                progress(t > 0 ? layers.values.reduce(0) { $0 + $1.done } / t : nil)
            }
            if o["status"] as? String == "success" { progress(1); return }
        }
        try Task.checkCancellation()
        throw UserFacingError("Downloading the AI model stopped unexpectedly. Click Retry.")
    }

    /// A download through the runtime that failed in a way Windows doesn't put into words (logged; the page says
    /// "The download failed. See the log for details.").
    public struct PullFailed: Error, CustomStringConvertible {
        public var reason: String
        public var description: String { "Downloading the AI model failed: \(reason)" }
    }

    /// How much of a loaded model sits in GPU memory, as a percentage (/api/ps size_vram of size), or nil when it
    /// isn't loaded. The name as given, in any case (Windows' DescribeLoadedAsync: no ":latest" twin).
    public static func gpuShare(endpoint: URL, model: String) async -> Int? {
        guard let (data, _) = try? await URLSession.shared.data(from: endpoint.appending(path: "api/ps")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]],
              let m = models.first(where: { (($0["name"] as? String) ?? "").caseInsensitiveCompare(model) == .orderedSame }) else { return nil }
        let size = (m["size"] as? NSNumber)?.doubleValue ?? 0, vram = (m["size_vram"] as? NSNumber)?.doubleValue ?? 0
        return size <= 0 ? 0 : Int((100 * vram / size).rounded())
    }

    /// Whether Ollama has this model in memory right now.
    public static func isLoaded(endpoint: URL, model: String) async -> Bool {
        let loaded = await loadedModels(endpoint: endpoint).map { $0.lowercased() }
        return loaded.contains(model.lowercased()) || loaded.contains(model.lowercased() + ":latest")
    }

    private static let sizesLock = NSLock()
    nonisolated(unsafe) private static var sizes: [String: ModelSize] = [:]

    /// Whether a model is held in memory beyond what the GPU can work on ("large"), and whether every parameter works on
    /// each word ("dense"), from its listing; for the request timeouts. Remembered once known.
    public static func size(endpoint: URL, model: String) async -> ModelSize {
        if ModelID.isOllamaCloud(model) { return ModelSize() }
        if let known = sizesLock.withLock({ sizes[model] }) { return known }
        guard let m = await details(endpoint: endpoint).first(where: {
            $0.name.caseInsensitiveCompare(model) == .orderedSame || $0.name.caseInsensitiveCompare(model + ":latest") == .orderedSame
        }) else { return ModelSize() } // not installed (yet): ask again next time
        let size = ModelSize(large: m.heldInRam(gpuBytes: ModelSize.gpuBytes), dense: !m.isMixture)
        if size.large {
            func b(_ x: Double) -> String { String(format: "%g", (x * 10).rounded() / 10) }
            CoreLog.info(m.isMixture
                ? "LLM \(model): a mixture of experts (\(b(m.activeBillions))B of \(b(m.billions))B at work), run from memory, with what fits on the GPU"
                : "LLM \(model): \(b(m.billions))B, too big for the GPU: held in memory with what fits on the GPU, and slow (all of it works on each word)")
        }
        sizesLock.withLock { sizes[model] = size }
        return size
    }

    /// /api/tags's models, or nil when the runtime can't be listed; that is logged, as Windows' ListModelsAsync and
    /// ListModelDetailsAsync do ("Listing models failed: …").
    static func tags(endpoint: URL) async -> [[String: Any]]? {
        do {
            let (data, resp) = try await URLSession.shared.data(from: endpoint.appending(path: "api/tags"))
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status / 100 == 2 else { throw ListingFailed(message: "Response status code does not indicate success: \(status).") }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return json["models"] as? [[String: Any]] ?? []
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
            CoreLog.warn("Listing models failed: " + listingMessage(error))
            return nil
        }
    }

    private struct ListingFailed: Error { var message: String }

    static func listingMessage(_ error: Error) -> String {
        if let e = error as? UserFacingError { return e.message }
        if let e = error as? ListingFailed { return e.message }
        return error.localizedDescription
    }

    /// Windows' ListModelsAsync: start Oberton's own runtime if nothing answers, then list. A runtime that can't be
    /// started or listed is logged ("Listing models failed: …") and lists nothing.
    public static func listModels(settings: AppSettings) async -> [String] {
        do {
            let endpoint = try validated(settings.ollamaEndpoint)
            try await OllamaRuntime.ensureRunning(settings: settings)
            return await installedModels(endpoint: endpoint)
        } catch {
            if !(error is CancellationError) { CoreLog.warn("Listing models failed: " + listingMessage(error)) }
            return []
        }
    }

    /// The installed models with their size on disk, parameters and family.
    static func details(endpoint: URL) async -> [LocalModel] {
        guard let models = await tags(endpoint: endpoint) else { return [] }
        return models.compactMap { m in
            guard let name = m["name"] as? String else { return nil }
            let size = (m["size"] as? NSNumber)?.int64Value ?? 0
            let d = m["details"] as? [String: Any]
            return LocalModel(name: name, billions: LocalModel.parseBillions(d?["parameter_size"] as? String, bytes: size), bytes: size,
                              family: d?["family"] as? String ?? "")
        }
    }

    /// The installed models with their size on disk, parameters (billions) and family, for Extended Notes' "best on this Mac".
    public static func installedDetails(endpoint: URL) async -> [NotesModels.Installed] { await details(endpoint: endpoint) }

    /// The models Ollama has in memory right now, or empty when it isn't running.
    public static func loadedModels(endpoint: URL) async -> [String] {
        guard let (data, _) = try? await URLSession.shared.data(from: endpoint.appending(path: "api/ps")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    /// Ask Ollama to let every model it holds go now (keep_alive 0). Returns how many it let go. A request that fails
    /// is logged, as Windows' UnloadAllAsync ("Unloading {model} failed: …"); a refusal only isn't counted.
    public static func unloadAll(endpoint: URL) async -> Int {
        var count = 0
        for name in await loadedModels(endpoint: endpoint) {
            do {
                if try await unloadRequest(endpoint: endpoint, model: name) { count += 1 }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { continue }
                CoreLog.warn("Unloading \(name) failed: \(error.localizedDescription)")
            }
        }
        return count
    }

    /// Ask Ollama to let one model go now (keep_alive 0).
    @discardableResult
    public static func unload(endpoint: URL, model: String) async -> Bool {
        (try? await unloadRequest(endpoint: endpoint, model: model)) ?? false
    }

    private static func unloadRequest(endpoint: URL, model: String) async throws -> Bool {
        var req = URLRequest(url: endpoint.appending(path: "api/generate"), timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0] as [String: Any])
        let (_, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
    }

    /// The models installed in Ollama, or empty when it can't be listed (logged).
    public static func installedModels(endpoint: URL) async -> [String] {
        guard let models = await tags(endpoint: endpoint) else { return [] }
        return sortedLikeWindows(models.compactMap { $0["name"] as? String })
    }

    /// Windows' `OrderBy(n => n)`: the culture's order (':' before '.', "Llama" among the l's), not code points.
    public static func sortedLikeWindows(_ names: [String]) -> [String] {
        names.sorted { $0.compare($1, locale: Locale.current) == .orderedAscending }
    }
}

/// How a local model sits in memory, for the request timeouts (Windows' `SizeAsync`).
public struct ModelSize: Sendable, Equatable {
    /// Too big for what the GPU can work on, so it runs partly from memory on the processor: slow to load and to answer.
    public var large = false
    /// An ordinary model (not a mixture of experts): every parameter works on each word.
    public var dense = false

    public init(large: Bool = false, dense: Bool = false) {
        self.large = large
        self.dense = dense
    }

    /// What the GPU can work on: on Apple silicon, the share of the unified memory Metal recommends.
    public static var gpuBytes: Int64? {
        #if canImport(Metal)
        if let d = MTLCreateSystemDefaultDevice() { return Int64(d.recommendedMaxWorkingSetSize) }
        #endif
        return nil
    }

    /// The request timeout for a dictation: at least 180 s for a large model, 300 s for a large dense one, else 10 s;
    /// the setting when that is more (as on Windows).
    public func dictationTimeout(setting: Double) -> Double { max(large ? (dense ? 300 : 180) : 10, setting) }

    /// The request timeout for background work on long text (Extended Notes): at least 180 s, 420 s for a large model,
    /// 900 s for a large dense one.
    public func askTimeout(setting: Double) -> Double { max(!large ? 180 : dense ? 900 : 420, setting) }
}

/// An installed Ollama model (Windows' `LocalModel`).
public struct LocalModel: Sendable, Equatable {
    public var name: String
    public var billions: Double
    /// Its size on disk, about what it takes in memory.
    public var bytes: Int64
    public var family: String

    /// Ollama's "parameter_size" ("7.6B", "494.03M") in billions; without one, estimated from the file (a 4-bit model
    /// takes about 0.6 bytes a parameter).
    public static func parseBillions(_ parameterSize: String?, bytes: Int64) -> Double {
        let t = (parameterSize ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        if t.count > 1, let n = Double(t.dropLast()) {
            switch t.last {
            case "B": return n
            case "M": return n / 1000
            case "K": return n / 1_000_000
            case "T": return n * 1000
            default: break
            }
        }
        return (Double(bytes) / 6e8 * 10).rounded() / 10
    }

    /// A mixture-of-experts model (Qwen3 30B-A3B, gpt-oss): only a few of its parameters work on each word.
    public var isMixture: Bool {
        name.firstMatch(of: #/(?i)-a\d+(?:\.\d+)?b\b/#) != nil || family.lowercased().hasSuffix("moe") || family.lowercased() == "gptoss"
    }

    /// Too big for the GPU (or, with no GPU figure, over 8 GB), so most of it is held in memory.
    public func heldInRam(gpuBytes: Int64?) -> Bool { gpuBytes.map { bytes > $0 } ?? (bytes > 8 * 1024 * 1024 * 1024) }

    public init(name: String, billions: Double, bytes: Int64, family: String) {
        self.name = name; self.billions = billions; self.bytes = bytes; self.family = family
    }

    /// Without a family (Extended Notes' tests and older callers).
    public init(name: String, bytes: Int64, billions: Double) { self.init(name: name, billions: billions, bytes: bytes, family: "") }

    /// The parameters that work on each word, in billions: what decides the speed. All of them for an ordinary model; for
    /// a mixture of experts the "a3b" in its name, or else about what its family uses.
    public var activeBillions: Double {
        if let m = name.firstMatch(of: #/(?i)-a(\d+(?:\.\d+)?)b\b/#), let a = Double(m.1) { return a }
        func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
        if family.lowercased() == "qwen3moe" { return round1(billions * 0.108) } // 30.5B, 3.3B at work
        if family.lowercased() == "gptoss" { return round1(billions * 0.17) }    // 20.9B, 3.6B at work
        return isMixture ? round1(billions * 0.15) : billions
    }

    /// What a mixture model leaves free in memory for macOS, speech and the other apps.
    public static let memoryHeadroom: Int64 = 10 * 1024 * 1024 * 1024
    /// The most parameters at work per word that the processor alone keeps up with.
    public static let maxActiveBillionsOnProcessor = 4.5
    /// This Mac's memory in bytes.
    public static var systemRam: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }

    /// Whether this runs from memory rather than from what the GPU works on: a mixture of experts too big for the GPU
    /// that fits in memory with room to spare and has few enough parameters at work to be quick.
    public func runsFromMemory(gpuBytes: Int64?, ramBytes: Int64?) -> Bool {
        guard isMixture, heldInRam(gpuBytes: gpuBytes), let r = ramBytes else { return false }
        return bytes + Self.memoryHeadroom <= r && activeBillions <= Self.maxActiveBillionsOnProcessor
    }
}

// MARK: - Cloud

/// Anthropic's Messages API or any OpenAI-compatible chat completions API, with the user's own key.
public struct CloudBackend: LanguageModelBackend {
    public var id: ModelID
    public var apiKey: String
    public var openAIBaseURL: String
    public var timeout: TimeInterval

    public init(id: ModelID, apiKey: String, openAIBaseURL: String = "https://api.openai.com/v1", timeout: TimeInterval = 60) {
        self.id = id
        self.apiKey = apiKey
        self.openAIBaseURL = openAIBaseURL
        self.timeout = timeout
    }

    public func complete(system: String, examples: [(input: String, output: String)], user: String, maxTokens: Int) async throws -> String {
        var turns: [[String: String]] = []
        for e in examples {
            turns.append(["role": "user", "content": e.input])
            turns.append(["role": "assistant", "content": e.output])
        }
        turns.append(["role": "user", "content": user])

        var req: URLRequest
        let label: String
        switch id.provider {
        case .anthropic:
            label = "Anthropic"
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: timeout + 5)
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": id.name, "max_tokens": maxTokens, "temperature": 0, "system": system, "messages": turns,
            ] as [String: Any])
        case .openai:
            label = "OpenAI"
            // The key and the text go to this address: over TLS, unless it is a server on this Mac.
            guard let base = URL(string: openAIBaseURL), base.scheme?.lowercased() == "https" || OllamaBackend.isLoopback(base) else {
                throw UserFacingError("The OpenAI-compatible address must start with https:// (http:// only for a server on this Mac). " +
                                      "Check it under Settings › Cloud AI.")
            }
            req = URLRequest(url: base.appending(path: "chat/completions"), timeoutInterval: timeout + 5)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            // OpenAI itself wants max_completion_tokens; compatible services still use max_tokens.
            let tokensKey = openAIBaseURL.range(of: "api.openai.com", options: .caseInsensitive) != nil ? "max_completion_tokens" : "max_tokens"
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": id.name, "messages": [["role": "system", "content": system]] + turns, tokensKey: maxTokens,
            ] as [String: Any])
        default:
            throw UserFacingError("\(id) is not a cloud model.")
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, resp): (Data, URLResponse)
        // A deadline over the whole request (Windows' CancelAfter), so a service that trickles keep-alive bytes still
        // gives up in time. A service that never takes the connection is "Couldn't reach" after Windows' TCP connect
        // limit (about 21 s), as there, not "took too long".
        let request = req, watch = ConnectWatch()
        do {
            (data, resp) = try await Deadline.run(seconds: timeout, connectWithin: ConnectWatch.windowsConnectLimit, connected: { watch.connected }) {
                try await URLSession.shared.data(for: request, delegate: watch)
            }
        } catch let e as URLError {
            throw UserFacingError(e.code == .timedOut ? "The cloud model took too long to respond."
                : "Couldn't reach the cloud AI service. Check your internet connection.")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            CoreLog.warn("\(label) returned \(status)") // the message is shown, not logged: it can echo the text
            if status == 401 || status == 403 { throw UserFacingError("\(label) rejected the API key. Check it under Settings › Cloud AI.") }
            var detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data, as: UTF8.self)
            if detail.count > 200 { detail = String(detail.prefix(200)) + "…" }
            throw UserFacingError("\(label) returned an error: \(detail)")
        }
        guard json != nil else { throw UserFacingError("\(label) sent an empty reply.") }
        if id.provider == .anthropic {
            let blocks = json?["content"] as? [[String: Any]] ?? []
            return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        }
        let choices = json?["choices"] as? [[String: Any]]
        return (choices?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
    }
}

/// A deadline over a whole piece of async work (.NET's CancellationTokenSource.CancelAfter): past it the work is
/// cancelled and `URLError(.timedOut)` thrown. Cancelling the caller still ends in `CancellationError`.
enum Deadline {
    /// `connectWithin`: when `connected` still says no by then, the work is given up as `URLError(.cannotConnectToHost)`.
    static func run<T: Sendable>(seconds: Double, connectWithin: Double? = nil, connected: @escaping @Sendable () -> Bool = { true },
                                 _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            if let connectWithin, connectWithin < seconds {
                group.addTask {
                    try await Task.sleep(for: .seconds(connectWithin))
                    if !connected() { throw URLError(.cannotConnectToHost) }
                    try await Task.sleep(for: .seconds(seconds)) // connected: the other two decide
                    return nil
                }
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next(), let value = first else { throw URLError(.timedOut) }
                return value
            } catch let e as URLError where e.code == .cancelled {
                try Task.checkCancellation()
                throw e
            }
        }
    }
}

/// Whether a request got as far as sending: its body goes out once the connection (and TLS) is up.
final class ConnectWatch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Windows gives up a TCP connection that nobody answers after about 21 s (3 tries: 3 + 6 + 12 s).
    static let windowsConnectLimit = 21.0
    private let lock = NSLock()
    private var task: URLSessionTask?

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) { lock.withLock { self.task = task } }

    var connected: Bool {
        lock.withLock { task.map { $0.countOfBytesSent > 0 || $0.countOfBytesReceived > 0 || $0.response != nil } ?? false }
    }
}
