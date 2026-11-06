import ObertonCore
import SwiftUI

/// The AI model a new install starts with, and getting it ready (Windows: Llm.DefaultModel "qwen2.5:3b", which setup
/// installs together with the Ollama runtime it bundles).
/// - Direct download: the same qwen2.5:3b, on Oberton's own copy of Ollama at Windows' private port. Setup can't bundle
///   it, so once setup is done the runtime (about 190 MB) and the model (1.9 GB) download in the background, with their
///   progress on Settings › Models. A download that didn't finish carries on at the next launch.
/// - App Store: the sandbox can't run a downloaded runtime, so Apple Intelligence stays the default; where it can't run
///   (and won't by itself soon), an Ollama the user has installed is used instead, if it has a model.
@MainActor
final class LocalAISetup: ObservableObject {
    static let shared = LocalAISetup()

    /// Oberton's own runtime in the direct download listens here, as Windows' bundled copy does, so an Ollama the user
    /// runs on its own port (11434) is left alone.
    static let ownEndpoint = "http://127.0.0.1:11435"

    /// The runtime's download, then its default model's: nil when none runs, else the fraction done (nil while unknown).
    @Published private(set) var progress: Double?? = nil
    var isRunning: Bool { progress != nil }
    private var task: Task<Void, Never>?

    /// A new install's model still to get ready (survives a quit).
    private struct Pending: Codable { var model: String }
    private static let pendingFile = JSONFile<Pending>("ai-setup.json")

    /// Set a new install's model (before the first save of its settings).
    static func newInstall(_ settings: inout AppSettings) {
        #if os(macOS)
        if Distribution.isDirect {
            settings.defaultModel = ModelID(provider: .ollama, name: LocalCatalog.defaultModel)
            settings.ollamaEndpoint = ownEndpoint
            pendingFile.save(Pending(model: LocalCatalog.defaultModel))
            return
        }
        #endif
        settings.defaultModel = .appleOnDevice
        pendingFile.save(Pending(model: ""))
    }

    /// At launch: finish a new install's model once setup is done.
    func resume(_ model: AppModel) {
        let pending = Self.pendingFile.load()
        #if os(macOS)
        if Distribution.isDirect {
            guard let pending, !pending.model.isEmpty else { return }
            task = Task { [weak self] in
                // After setup (it has its own downloads to show first).
                while !OnboardingView.isDone { try? await Task.sleep(for: .seconds(5)); if Task.isCancelled { return } }
                try? await Task.sleep(for: .seconds(8)) // after launch's own work
                guard let self, model.settings.defaultModel == ModelID(provider: .ollama, name: pending.model) else { Self.clearPending(); return }
                do {
                    try await self.install(model)
                } catch {
                    Log.info("Getting the local AI ready failed (tried again at the next launch): \(error.localizedDescription)")
                }
            }
            return
        }
        #endif
        // App Store: Apple Intelligence can't run here and won't by itself soon (a new install), or never will.
        guard settings(model).defaultModel == .appleOnDevice, AppleIntelligenceBackend.unavailableReason != nil,
              !AppleIntelligenceBackend.isGettingReady, pending != nil || AppleIntelligenceBackend.isUnsupported else {
            if pending != nil { Self.clearPending() }
            return
        }
        Task {
            guard let endpoint = try? OllamaBackend.validated(model.settings.ollamaEndpoint), await OllamaBackend.ping(endpoint: endpoint) else { return }
            let installed = await OllamaBackend.installedModels(endpoint: endpoint).filter { !ModelID.isOllamaCloud($0) }
            guard let pick = installed.first(where: { LocalCatalog.same($0, LocalCatalog.defaultModel) }) ?? installed.first else { return }
            Log.info("Apple Intelligence can't run on this \(Device.noun): using the installed Ollama model \(pick)")
            model.settings.defaultModel = ModelID(provider: .ollama, name: pick)
            // A new install that started on Raw for want of an AI starts on Grammar & Clarity after all.
            if pending != nil, model.settings.defaultProfileID == BuiltInProfiles.rawID,
               let gc = model.profiles.first(where: { $0.name == BuiltInProfiles.defaultName })?.id {
                model.settings.defaultProfileID = gc
                model.settings.activeProfileID = gc
            }
            Self.clearPending()
        }
    }

    private func settings(_ model: AppModel) -> AppSettings { model.settings }

    private static func clearPending() { try? FileManager.default.removeItem(at: pendingFile.url) }

    #if os(macOS)
    /// Where `install` is, for setup's progress panel.
    enum Stage: Int, Comparable {
        case downloadingRuntime, unpackingRuntime, startingRuntime, downloadingModel
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    /// Install Oberton's own runtime (if it isn't), start it, and download the default model (if it isn't in), as
    /// Windows' setup does (RuntimeInstaller steps 3 and 5); setup runs this, and Settings › Models' Download on the
    /// runtime row. `report` follows it: the stage and how far it got (nil while unknown).
    func install(_ model: AppModel, report: (@MainActor (Stage, Double?) -> Void)? = nil) async throws {
        guard !isRunning else { return }
        progress = .some(nil)
        defer { progress = nil }
        if !OllamaRuntime.isInstalled {
            report?(.downloadingRuntime, nil)
            try await OllamaRuntime.install(progress: { f in Task { @MainActor in LocalAISetup.shared.report(f); report?(.downloadingRuntime, f) } },
                                            unpacking: { Task { @MainActor in report?(.unpackingRuntime, nil) } })
        }
        let qwen = LocalCatalog.defaultModel
        report?(.startingRuntime, nil)
        try await OllamaRuntime.ensureRunning(settings: model.settings)
        let endpoint = try OllamaBackend.validated(model.settings.ollamaEndpoint)
        if !(await OllamaBackend.installedModels(endpoint: endpoint)).contains(where: { LocalCatalog.same($0, qwen) }) {
            progress = .some(0)
            report?(.downloadingModel, nil)
            try await OllamaBackend.pull(endpoint: endpoint, model: qwen) { f in
                Task { @MainActor in LocalAISetup.shared.report(f); report?(.downloadingModel, f) }
            }
            Log.info("Downloaded the AI model \(qwen)")
        }
        Self.clearPending()
        // Windows' local default, unless the model in use already works.
        if model.settings.defaultModel == .appleOnDevice && AppleIntelligenceBackend.unavailableReason != nil {
            model.settings.defaultModel = ModelID(provider: .ollama, name: qwen)
        } else {
            model.rewarmAI()
        }
        await model.refreshOllama()
    }

    /// A new install of the direct download still has its local AI to get: setup does it (Windows' setup steps 3 and 5,
    /// "Downloading the AI runtime (Ollama)" and "Downloading the AI model (qwen2.5:3b)").
    var setupGetsAI: Bool {
        guard Distribution.isDirect, let pending = Self.pendingFile.load() else { return false }
        return !pending.model.isEmpty
    }

    /// Setup's AI steps: the runtime (when it isn't installed) and then the model, each a step of setup's own.
    /// `begin` starts a step (`next`: it is the next step, not the same one with a new title), with its title and
    /// detail; `progress` moves the bar.
    func runInSetup(_ model: AppModel, begin: @escaping @MainActor (_ next: Bool, _ title: String, _ detail: String) -> Void,
                    progress: @escaping @MainActor (_ fraction: Double?) -> Void) async throws {
        final class Seen { var stage: Stage? }
        let seen = Seen(), qwen = LocalCatalog.defaultModel
        do {
            try await install(model) { stage, f in
                if let s = seen.stage, stage < s { return } // a late report of a step already done
                if stage != seen.stage {
                    seen.stage = stage
                    switch stage {
                    case .downloadingRuntime: begin(true, "Downloading the AI runtime (Ollama)", "")
                    case .unpackingRuntime: begin(false, "Unpacking the AI runtime", "")
                    case .startingRuntime: begin(true, "Downloading the AI model (\(qwen))", "Starting the AI runtime…")
                    case .downloadingModel: begin(false, "Downloading the AI model (\(qwen))", "")
                    }
                }
                progress(f)
            }
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        }
    }

    /// Setup's step names for its "Step n of N".
    static func setupSteps(runtimeInstalled: Bool) -> [String] {
        (runtimeInstalled ? [] : ["AI runtime"]) + ["AI model"]
    }

    /// Run `install` for Settings › Models, which shows a failure; Cancel stops it.
    func start(_ model: AppModel, failed: @escaping @MainActor (Error) -> Void) {
        guard !isRunning else { return }
        task?.cancel()
        task = Task {
            do { try await install(model) } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch { failed(error) }
        }
    }

    func cancel() { task?.cancel() }

    private func report(_ f: Double?) { if isRunning { progress = .some(f) } }
    #endif
}
