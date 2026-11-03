import Foundation

/// Turns a raw transcript into a processed one according to a profile, with the same safety net as Windows: a piece
/// the model mangled (or failed on) falls back to the raw words, so dictation is never lost.
public struct TextProcessor: Sendable {
    public var settings: AppSettings

    public init(settings: AppSettings) { self.settings = settings }

    public func model(for profile: Profile) -> ModelID {
        profile.model.flatMap(ModelID.init) ?? settings.defaultModel
    }

    /// The back end for a model, with its request timeout scaled to how the model sits in memory (as on Windows):
    /// `ask` is background work on long text (Extended Notes), which gets longer.
    public func backend(for id: ModelID, ask: Bool) async throws -> LanguageModelBackend {
        guard id.provider == .ollama else { return try plainBackend(for: id) }
        let endpoint = try OllamaBackend.validated(settings.ollamaEndpoint)
        try checkOffline(id)
        let size = await OllamaBackend.size(endpoint: endpoint, model: id.name)
        return OllamaBackend(endpoint: endpoint, model: id.name,
                             timeout: ask ? size.askTimeout(setting: settings.aiTimeoutSeconds) : size.dictationTimeout(setting: settings.aiTimeoutSeconds),
                             keepAlive: settings.ollamaKeepAlive(large: size.large))
    }

    /// "Keep everything offline" also blocks the Ollama models that run on ollama.com.
    func checkOffline(_ id: ModelID) throws {
        if settings.cloud.keepOffline && id.isOllamaCloud {
            throw UserFacingError("\(id.name) runs on ollama.com, but \"Keep everything offline\" is on. " +
                                  "Turn it off under Settings › Cloud AI, or pick a model that runs on this Mac.")
        }
    }

    /// The back end with the timeout as set (no lookup of the model's size).
    public func backend(for id: ModelID) throws -> LanguageModelBackend { try plainBackend(for: id) }

    private func plainBackend(for id: ModelID) throws -> LanguageModelBackend {
        switch id.provider {
        case .apple:
            return AppleIntelligenceBackend()
        case .ollama:
            try checkOffline(id)
            return OllamaBackend(endpoint: try OllamaBackend.validated(settings.ollamaEndpoint), model: id.name,
                                 timeout: max(10, settings.aiTimeoutSeconds), keepAlive: settings.ollamaKeepAlive)
        case .anthropic, .openai:
            if settings.cloud.keepOffline {
                throw UserFacingError("This profile uses a cloud model, but \"Keep everything offline\" is on. " +
                                      "Turn it off under Settings › Cloud AI, or pick a local model.")
            }
            guard let key = KeyStore.get(id.provider) else {
                throw UserFacingError("No API key is set for \(id.provider == .anthropic ? "Anthropic" : "OpenAI"). Add one under Settings › Cloud AI.")
            }
            return CloudBackend(id: id, apiKey: key, openAIBaseURL: settings.cloud.openAIBaseURL, timeout: max(10, settings.aiTimeoutSeconds))
        }
    }

    /// A dictation's AI edit. The AI failing (not running, no key, offline, …) never loses the words: they go in as
    /// spoken, with the reason in `error` and the notice in `warning` (Windows' DictationController catch).
    public func process(_ raw: String, profile: Profile) async -> ProcessResult {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || profile.isRaw { return ProcessResult(text: raw, modified: false) }
        let id = model(for: profile)
        do {
            return try await edit(raw, profile: profile, backend: try await backend(for: id, ask: false), cloud: id.isCloud)
        } catch {
            return Self.failed(raw, error)
        }
    }

    /// The work itself, with the back end given (tests pass a fake). Errors come back as in `process(_:profile:)`.
    public func process(_ raw: String, profile: Profile, backend: LanguageModelBackend, cloud: Bool = false) async -> ProcessResult {
        do { return try await edit(raw, profile: profile, backend: backend, cloud: cloud) } catch { return Self.failed(raw, error) }
    }

    static func failed(_ raw: String, _ error: Error) -> ProcessResult {
        if error is CancellationError { return ProcessResult(text: raw, modified: false) }
        let message = error.localizedDescription
        return ProcessResult(text: raw, modified: false, warning: message + " Inserting your original words.", error: message)
    }

    /// Windows' OllamaTextProcessor.ProcessAsync: an AI error anywhere throws, so the whole dictation falls back.
    /// Token budgets as Windows: a local model gets min(4096, n/2 + 256), a cloud one min(8192, n/2 + 512).
    func edit(_ raw: String, profile: Profile, backend: LanguageModelBackend, cloud: Bool) async throws -> ProcessResult {
        func budget(_ text: String) -> Int { cloud ? min(8192, text.count / 2 + 512) : min(4096, text.count / 2 + 256) }
        let system = PromptBuilder.systemPrompt(for: profile)
        if profile.rewriteWhole {
            // No conservative-edit examples: they would pull the model towards keeping the wording.
            let text = OutputSanitizer.clean(try await backend.complete(system: system, examples: [], user: PromptBuilder.wrap(raw),
                                                                        maxTokens: budget(raw)), input: raw)
            if OutputSanitizer.rewriteImplausibility(input: raw, output: text) == nil { return ProcessResult(text: text, modified: true) }
            return ProcessResult(text: raw, modified: false,
                                 warning: "The AI's rewrite failed the safety net, so your original words were inserted unchanged.", safetyNet: true)
        }

        let examples = PromptBuilder.examples.map { (input: PromptBuilder.wrap($0.input), output: $0.output) }
        let segments = TextChunker.segment(raw)
        var output: [String] = []
        var rejected = 0
        for segment in segments {
            try Task.checkCancellation()
            let reply = try await backend.complete(system: system, examples: examples, user: PromptBuilder.wrap(segment.text),
                                                   maxTokens: budget(segment.text))
            let cleaned = OutputSanitizer.clean(reply, input: segment.text)
            if OutputSanitizer.implausibility(input: segment.text, output: cleaned, maxChange: profile.maxChangeRatio) == nil {
                output.append(cleaned)
                continue
            }
            // The safety net works per segment: only the piece the model mangled falls back to the raw words.
            output.append(segment.text)
            rejected += 1
        }
        let text = TextChunker.join(segments, output)
        if rejected == 0 { return ProcessResult(text: text, modified: true) }
        if rejected == segments.count {
            return ProcessResult(text: raw, modified: false,
                                 warning: "The AI's edit failed the safety net, so your original words were inserted unchanged.", safetyNet: true)
        }
        return ProcessResult(text: text, modified: true,
                             warning: "The AI's edit of \(rejected) of \(segments.count) parts failed the safety net; those parts were inserted unchanged.",
                             safetyNet: true)
    }
}
