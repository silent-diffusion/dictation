import Foundation

/// The AI status line, as Windows' OllamaTextProcessor reports it while it warms a model up (WarmUpAsync) and once it
/// is loaded (DescribeLoadedAsync): "Starting AI runtime…", "Loading qwen2.5:3b…", "Ready · qwen2.5:3b · GPU". Each
/// line comes with whether it is a good state (the status dot).
public enum AIStatus {
    /// Before anything was loaded (Windows' first status).
    public static let notLoaded = "AI model not loaded"

    /// Load the model now so the first dictation doesn't wait, reporting each step. A cloud model has nothing to load.
    public static func warmUp(_ id: ModelID, settings: AppSettings, report: @escaping @Sendable (String, Bool) async -> Void) async {
        switch id.provider {
        case .apple:
            if let reason = AppleIntelligenceBackend.unavailableReason { await report(reason, false); return }
            AppleIntelligenceBackend.warmUp()
            await report("Ready · Apple Intelligence", true)
        case .anthropic, .openai:
            await report(cloudLine(id, settings: settings), !settings.cloud.keepOffline)
        case .ollama:
            // Every Ollama model goes through the runtime, its cloud ones ("…-cloud") too (Windows' WarmUpAsync only
            // short-circuits Anthropic and OpenAI).
            do {
                await report("Starting AI runtime…", false)
                let endpoint = try OllamaBackend.validated(settings.ollamaEndpoint)
                try await OllamaRuntime.ensureRunning(settings: settings)
                let installed = await OllamaBackend.installedModels(endpoint: endpoint)
                guard installed.contains(where: { LocalCatalog.same($0, id.name) }) else {
                    await report("AI model '\(id.name)' not installed", false)
                    return
                }
                await report("Loading \(id.name)…", false)
                let size = await OllamaBackend.size(endpoint: endpoint, model: id.name)
                guard await OllamaBackend.warmUp(endpoint: endpoint, model: id.name, keepAlive: settings.ollamaKeepAlive(large: size.large)) else {
                    CoreLog.warn("LLM warm-up failed: the runtime didn't load \(id.name)")
                    await report("AI runtime error", false)
                    return
                }
                await report(await describeLoaded(id.name, endpoint: endpoint, large: size.large, log: true), true)
            } catch is CancellationError {
            } catch {
                CoreLog.warn("LLM warm-up failed: \(error.localizedDescription)")
                await report(error is UserFacingError ? "AI runtime unavailable" : "AI runtime error", false)
            }
        }
    }

    /// The line for the model as it is now, without loading anything (for polling): its "Ready · …" line when it is
    /// in memory, otherwise `notLoaded` (Apple Intelligence: ready or why not; cloud: its cloud line).
    public static func current(_ id: ModelID, settings: AppSettings) async -> (text: String, ok: Bool) {
        switch id.provider {
        case .apple:
            return AppleIntelligenceBackend.unavailableReason.map { ($0, false) } ?? ("Ready · Apple Intelligence", true)
        case .anthropic, .openai:
            return (cloudLine(id, settings: settings), !settings.cloud.keepOffline)
        case .ollama:
            guard let endpoint = try? OllamaBackend.validated(settings.ollamaEndpoint),
                  await OllamaBackend.isLoaded(endpoint: endpoint, model: id.name) else { return (notLoaded, false) }
            let large = await OllamaBackend.size(endpoint: endpoint, model: id.name).large
            return (await describeLoaded(id.name, endpoint: endpoint, large: large), true)
        }
    }

    /// Windows names the model by its stored id here ("anthropic:claude-haiku-4-5-20251001").
    static func cloudLine(_ id: ModelID, settings: AppSettings) -> String {
        settings.cloud.keepOffline ? "\(id.windowsForm) is a cloud model; \"Keep everything offline\" blocks it" : "Ready · \(id.windowsForm) (cloud)"
    }

    /// How much of the loaded model landed in GPU memory (Windows' DescribeLoadedAsync).
    static func describeLoaded(_ model: String, endpoint: URL, large: Bool, log: Bool = false) async -> String {
        guard let pct = await OllamaBackend.gpuShare(endpoint: endpoint, model: model) else { return "Ready · \(model)" }
        if log { CoreLog.info("LLM \(model) loaded: \(pct)% in GPU memory") }
        return describe(model, gpuPercent: pct, large: large)
    }

    public static func describe(_ model: String, gpuPercent pct: Int, large: Bool) -> String {
        if large {
            return pct > 0 ? "Ready · \(model) · \(pct)% on the GPU, the rest in memory" : "Ready · \(model) · in memory, on the processor (no GPU memory free)"
        }
        return pct >= 90 ? "Ready · \(model) · GPU" : "Ready · \(model) · \(pct)% GPU (slower: free up GPU memory or pick a smaller model)"
    }
}
