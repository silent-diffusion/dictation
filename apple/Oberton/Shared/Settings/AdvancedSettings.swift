import ObertonCore
import SwiftUI

// MARK: - D // App

/// D.1 Advanced (Windows AdvancedPage.xaml): what is installed, where things are stored, privacy. Runtimes: the direct
/// download's own Ollama (runtime/ollama, its models in models/ollama); the App Store build has no runtimes folder (the
/// speech engines come with the app and the system, and an Ollama the user installed keeps its own models).
struct AdvancedSection: View {
    @EnvironmentObject var model: AppModel
    @State private var localModels = ""

    private static var modelsDir: URL { AppPaths.dataDir.appending(path: "models", directoryHint: .isDirectory) }

    private var paths: String {
        let data = AppPaths.dataDir
        func path(_ url: URL) -> String { url.path(percentEncoded: false) }
        return """
            App root:   \(path(data))
            Settings:   \(path(data.appending(path: "settings.json")))
            Profiles:   \(path(data.appending(path: "profiles.json")))
            Logs:       \(path(Log.dir))
            Models:     \(path(Self.modelsDir))
            """ + (OllamaRuntime.canManage ? "\nRuntimes:   \(path(AppPaths.dataDir.appending(path: "runtime", directoryHint: .isDirectory)))" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Where things are stored on this computer, and what is installed.")

            FieldLabel("Local models")
            Text(localModels).font(Ob.sans(Ob.body)).fixedSize(horizontal: false, vertical: true)

            FieldLabel("Locations")
            Text(paths).font(Ob.mono(12)).fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            HStack(spacing: 8) {
                Button("Open data folder") { open(AppPaths.dataDir) }.buttonStyle(.quietNarrow)
                Button("Open logs") { open(Log.dir) }.buttonStyle(.quietNarrow)
                Button("Open models folder") { open(Self.modelsDir) }.buttonStyle(.quietNarrow)
            }
            .padding(.top, 10)
            #endif

            FieldLabel("Privacy")
            // Whisper loads with downloads off, as Windows' HF_HUB_OFFLINE. The direct build runs the AI runtime itself
            // (it listens on 127.0.0.1, as Windows'); the App Store build uses the user's own Ollama, which it only
            // reaches there.
            Text("No cloud services, accounts, analytics or telemetry. The speech engine runs offline (Hugging Face access is disabled at runtime) and the AI runtime "
                 + (OllamaRuntime.canManage ? "only listens on 127.0.0.1" : "is only reached on 127.0.0.1")
                 + ". Logs record timings and sizes, never what you said. Audio is never written to disk.")
                .font(Ob.sans(Ob.body)).fixedSize(horizontal: false, vertical: true)
        }
        .task { await listModels() }
    }

    #if os(macOS)
    /// The folder, made first if it isn't there yet.
    private func open(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
    #endif

    /// The downloaded speech models (Whisper's, and Apple Speech's languages) and Ollama's models, as Windows.
    private func listModels() async {
        let speech = await LiveTranscriber.installedLanguages()
        await model.refreshOllama()
        let names = speech.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }
        // As Windows lists the model folders by their repository ids ("Systran/faster-whisper-small.en"): every model
        // folder there, by its place in WhisperKit's repository.
        let repo = "argmaxinc/whisperkit-coreml"
        let folder = Self.modelsDir.appending(path: "whisper/models/\(repo)", directoryHint: .isDirectory)
        let whisper = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { "\(repo)/\($0.lastPathComponent)" }.sorted()
        localModels = "Speech (models/whisper):  " + (whisper.isEmpty ? "none" : whisper.joined(separator: ", ")) + "\n"
            + "Speech (Apple Speech):  " + (names.isEmpty ? "none" : names.joined(separator: ", ")) + "\n"
            + "Language models (\(OllamaRuntime.canManage ? "models/ollama" : "Ollama")):  " + (model.ollamaModels.isEmpty ? "none (or runtime not running)" : model.ollamaModels.joined(separator: ", "))
    }
}
