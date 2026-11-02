import Foundation

/// Turns a raw transcript into a processed one according to a profile, with the same safety net as Windows: a piece
/// the model mangled (or failed on) falls back to the raw words, so dictation is never lost.
public struct TextProcessor: Sendable {
    public var settings: AppSettings

    public init(settings: AppSettings) { self.settings = settings }

    public func model(for profile: Profile) -> ModelID {
        profile.model.flatMap(ModelID.init) ?? settings.defaultModel
    }

    public func backend(for id: ModelID) throws -> LanguageModelBackend {
        switch id.provider {
        case .apple:
            return AppleIntelligenceBackend()
        case .ollama:
            return OllamaBackend(endpoint: try OllamaBackend.validated(settings.ollamaEndpoint), model: id.name,
                                 timeout: settings.aiTimeoutSeconds)
        case .anthropic, .openai:
            if settings.cloud.keepOffline {
                throw UserFacingError("\(id.displayName) is a cloud model, but \"Keep everything offline\" is on. " +
                                      "Turn it off in Settings › Cloud AI, or pick a model that runs on this device.")
            }
            guard let key = KeyStore.get(id.provider) else {
                throw UserFacingError("No API key is set for \(id.provider == .anthropic ? "Anthropic" : "OpenAI"). Add one in Settings › Cloud AI.")
            }
            return CloudBackend(id: id, apiKey: key, openAIBaseURL: settings.cloud.openAIBaseURL, timeout: settings.aiTimeoutSeconds)
        }
    }

    public func process(_ raw: String, profile: Profile) async -> ProcessResult {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || profile.isRaw { return ProcessResult(text: raw, modified: false) }
        let backend: LanguageModelBackend
        do { backend = try self.backend(for: model(for: profile)) } catch {
            return ProcessResult(text: raw, modified: false, warning: error.localizedDescription + " Your original words were inserted.")
        }
        return await process(raw, profile: profile, backend: backend)
    }

    /// The work itself, with the back end given (tests pass a fake).
    public func process(_ raw: String, profile: Profile, backend: LanguageModelBackend) async -> ProcessResult {
        let system = PromptBuilder.systemPrompt(for: profile)
        if profile.rewriteWhole {
            // No conservative-edit examples: they would pull the model towards keeping the wording.
            do {
                let text = OutputSanitizer.clean(try await backend.complete(system: system, examples: [], user: PromptBuilder.wrap(raw),
                                                                            maxTokens: min(4096, raw.count / 2 + 512)), input: raw)
                if OutputSanitizer.rewriteImplausibility(input: raw, output: text) == nil { return ProcessResult(text: text, modified: true) }
                return ProcessResult(text: raw, modified: false,
                                     warning: "The AI's rewrite failed the safety net, so your original words were inserted unchanged.", safetyNet: true)
            } catch {
                return ProcessResult(text: raw, modified: false, warning: error.localizedDescription + " Your original words were inserted.")
            }
        }

        let examples = PromptBuilder.examples.map { (input: PromptBuilder.wrap($0.input), output: $0.output) }
        let segments = TextChunker.segment(raw)
        var output: [String] = []
        var rejected = 0
        var lastError: Error?
        for segment in segments {
            do {
                let reply = try await backend.complete(system: system, examples: examples, user: PromptBuilder.wrap(segment.text),
                                                       maxTokens: min(4096, segment.text.count / 2 + 256))
                let cleaned = OutputSanitizer.clean(reply, input: segment.text)
                if OutputSanitizer.implausibility(input: segment.text, output: cleaned, maxChange: profile.maxChangeRatio) == nil {
                    output.append(cleaned)
                    continue
                }
            } catch {
                if error is CancellationError { return ProcessResult(text: raw, modified: false) }
                lastError = error
            }
            // The safety net works per segment: only the piece the model mangled falls back to the raw words.
            output.append(segment.text)
            rejected += 1
        }
        let text = TextChunker.join(segments, output)
        if rejected == 0 { return ProcessResult(text: text, modified: true) }
        if rejected == segments.count {
            if let lastError { return ProcessResult(text: raw, modified: false, warning: lastError.localizedDescription + " Your original words were inserted.") }
            return ProcessResult(text: raw, modified: false,
                                 warning: "The AI's edit failed the safety net, so your original words were inserted unchanged.", safetyNet: true)
        }
        return ProcessResult(text: text, modified: true,
                             warning: "The AI's edit of \(rejected) of \(segments.count) parts failed the safety net; those parts were inserted unchanged.",
                             safetyNet: true)
    }
}

/// One past dictation: what was heard, what the AI made of it, where it went.
public struct HistoryEntry: Codable, Identifiable, Sendable, Hashable {
    public var id = UUID()
    public var date = Date()
    public var transcription: String
    public var aiEdit: String?
    public var inserted: String
    public var profileName: String
    public var model: String?
    public var appName: String?
    public var seconds: Double
    public var turnaroundSeconds: Double
    public var warning: String?

    public init(transcription: String, aiEdit: String?, inserted: String, profileName: String, model: String?, appName: String?,
                seconds: Double, turnaroundSeconds: Double, warning: String?) {
        self.transcription = transcription
        self.aiEdit = aiEdit
        self.inserted = inserted
        self.profileName = profileName
        self.model = model
        self.appName = appName
        self.seconds = seconds
        self.turnaroundSeconds = turnaroundSeconds
        self.warning = warning
    }

    public var words: Int { inserted.split(whereSeparator: \.isWhitespace).count }
}
