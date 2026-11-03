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
        guard let colon = raw.firstIndex(of: ":"), let p = Provider(rawValue: String(raw[..<colon])) else { return nil }
        self.init(provider: p, name: String(raw[raw.index(after: colon)...]))
    }

    public var description: String { "\(provider.rawValue):\(name)" }

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
        guard let id = ModelID(raw) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: raw)) }
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
        guard let url = URL(string: s), let host = url.host(), ["127.0.0.1", "localhost", "::1"].contains(host) else {
            throw UserFacingError("The Ollama address must be on this Mac (http://127.0.0.1:11434).")
        }
        return url
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
        var req = URLRequest(url: endpoint.appending(path: "api/chat"), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch let e as URLError {
            throw UserFacingError(e.code == .timedOut ? "The AI model took too long to respond."
                : "Couldn't reach Ollama. Is it running? Get it from ollama.com, then: ollama pull \(model)")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UserFacingError("The AI model '\(model)' isn't installed. Install it with:  ollama pull \(model)") }
        guard (200..<300).contains(status) else { throw UserFacingError("Ollama returned an error (\(status)).") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["message"] as? [String: Any])?["content"] as? String ?? ""
    }

    /// Load the model into memory without generating anything (an empty chat request), so the first dictation doesn't
    /// wait for it. Returns whether Ollama answered.
    @discardableResult
    public static func warmUp(endpoint: URL, model: String, keepAlive: String? = nil) async -> Bool {
        var req = URLRequest(url: endpoint.appending(path: "api/chat"), timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "messages": [] as [Any], "options": ["num_ctx": 4096]]
        if let keepAlive { body["keep_alive"] = keepAlive }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
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
        sizesLock.withLock { sizes[model] = size }
        return size
    }

    /// The installed models with their size on disk, parameters and family.
    static func details(endpoint: URL) async -> [LocalModel] {
        guard let (data, _) = try? await URLSession.shared.data(from: endpoint.appending(path: "api/tags")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
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

    /// Ask Ollama to let every model it holds go now (keep_alive 0). Returns how many it let go.
    public static func unloadAll(endpoint: URL) async -> Int {
        var count = 0
        for name in await loadedModels(endpoint: endpoint) where await unload(endpoint: endpoint, model: name) { count += 1 }
        return count
    }

    /// Ask Ollama to let one model go now (keep_alive 0).
    @discardableResult
    public static func unload(endpoint: URL, model: String) async -> Bool {
        var req = URLRequest(url: endpoint.appending(path: "api/generate"), timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0] as [String: Any])
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
    }

    /// The models installed in Ollama, or empty when it isn't running.
    public static func installedModels(endpoint: URL) async -> [String] {
        guard let (data, _) = try? await URLSession.shared.data(from: endpoint.appending(path: "api/tags")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
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
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: timeout)
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": id.name, "max_tokens": maxTokens, "temperature": 0, "system": system, "messages": turns,
            ] as [String: Any])
        case .openai:
            label = "OpenAI"
            // The key and the text go to this address: over TLS, unless it is a server on this Mac.
            guard let base = URL(string: openAIBaseURL), base.scheme == "https" || ["127.0.0.1", "localhost"].contains(base.host() ?? "") else {
                throw UserFacingError("The OpenAI-compatible address must start with https:// (http:// only for a server on this Mac).")
            }
            req = URLRequest(url: base.appending(path: "chat/completions"), timeoutInterval: timeout)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            // OpenAI itself wants max_completion_tokens; compatible services still use max_tokens.
            let tokensKey = openAIBaseURL.contains("api.openai.com") ? "max_completion_tokens" : "max_tokens"
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": id.name, "messages": [["role": "system", "content": system]] + turns, tokensKey: maxTokens,
            ] as [String: Any])
        default:
            throw UserFacingError("\(id) is not a cloud model.")
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch let e as URLError {
            throw UserFacingError(e.code == .timedOut ? "The cloud model took too long to respond."
                : "Couldn't reach the cloud AI service. Check your internet connection.")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            if status == 401 || status == 403 { throw UserFacingError("\(label) rejected the API key. Check it in Settings › Cloud AI.") }
            var detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data, as: UTF8.self)
            if detail.count > 200 { detail = String(detail.prefix(200)) + "…" }
            throw UserFacingError("\(label) returned an error: \(detail)")
        }
        if id.provider == .anthropic {
            let blocks = json?["content"] as? [[String: Any]] ?? []
            return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        }
        let choices = json?["choices"] as? [[String: Any]]
        return (choices?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
    }
}
