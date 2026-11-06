import Foundation
import Testing
@testable import ObertonCore

/// The direct download's local AI end to end: install Oberton's own Ollama, start it, download a small model, edit
/// with it and read the status lines. Downloads and runs Ollama (about 280 MB with the model), so it runs only on
/// request: `OBERTON_OLLAMA_TEST=1 OBERTON_DATA_DIR=<scratch folder> swift test --filter OllamaRuntimeCheck`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OBERTON_OLLAMA_TEST"] != nil && ProcessInfo.processInfo.environment["OBERTON_DATA_DIR"] != nil))
struct OllamaRuntimeCheck {
    @Test(.timeLimit(.minutes(20))) func installStartPullAndEdit() async throws {
        var s = AppSettings()
        s.ollamaEndpoint = "http://127.0.0.1:11439" // away from any Ollama of the user's
        if !OllamaRuntime.isInstalled { try await OllamaRuntime.install { _ in } }
        #expect(OllamaRuntime.isInstalled)
        try await OllamaRuntime.ensureRunning(settings: s)
        defer { OllamaRuntime.stop() }
        let endpoint = try OllamaBackend.validated(s.ollamaEndpoint)
        #expect(await OllamaBackend.ping(endpoint: endpoint))
        let model = "smollm2:135m"
        let seen = Collected<Double?>()
        try await OllamaBackend.pull(endpoint: endpoint, model: model) { seen.add($0) }
        #expect(seen.all.last == 1)
        #expect(await OllamaBackend.installedModels(endpoint: endpoint).contains { LocalCatalog.same($0, model) })
        let lines = Collected<String>()
        await AIStatus.warmUp(ModelID(provider: .ollama, name: model), settings: s) { line, _ in lines.add(line) }
        print("status lines: \(lines.all)")
        #expect(lines.all.first == "Starting AI runtime…")
        #expect(lines.all.last?.hasPrefix("Ready · \(model)") == true)
        var p = BuiltInProfiles.create()[0]
        p.model = "ollama:\(model)"
        let r = await TextProcessor(settings: s).process("um so we meet on tuesday", profile: p)
        #expect(r.error == nil)
    }
}

final class Collected<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [T] = []
    func add(_ v: T) { lock.withLock { values.append(v) } }
    var all: [T] { lock.withLock { values } }
}
