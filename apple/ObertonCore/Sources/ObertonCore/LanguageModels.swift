import Foundation
import FoundationModels

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
    public var isLocal: Bool { provider == .apple || provider == .ollama }

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

    public init(endpoint: URL, model: String, timeout: TimeInterval = 60) {
        self.endpoint = endpoint
        self.model = model
        self.timeout = timeout
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
        let body: [String: Any] = [
            "model": model, "stream": false, "think": false, "messages": messages,
            "options": ["temperature": 0, "num_predict": maxTokens, "num_ctx": 4096],
        ]
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
        for name in await loadedModels(endpoint: endpoint) {
            var req = URLRequest(url: endpoint.appending(path: "api/generate"), timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "keep_alive": 0] as [String: Any])
            if let (_, resp) = try? await URLSession.shared.data(for: req), ((resp as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2 { count += 1 }
        }
        return count
    }

    /// The models installed in Ollama, or empty when it isn't running.
    public static func installedModels(endpoint: URL) async -> [String] {
        guard let (data, _) = try? await URLSession.shared.data(from: endpoint.appending(path: "api/tags")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
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
