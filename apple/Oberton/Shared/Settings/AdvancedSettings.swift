import ObertonCore
import SwiftUI

// MARK: - D // App

/// D.1 Advanced (Windows AdvancedPage.xaml): what is installed, where things are stored, privacy. There is no
/// runtimes folder: the Mac's speech engines come with the app and the system, and Ollama keeps its own.
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
            """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Where things are stored on this computer, and what is installed.")

            FieldLabel("Local models")
            Text(localModels).font(Ob.sans(Ob.body)).fixedSize(horizontal: false, vertical: true)

            FieldLabel("Locations")
            Text(paths).font(Ob.mono(12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            HStack(spacing: 8) {
                Button("Open data folder") { open(AppPaths.dataDir) }.buttonStyle(.quietNarrow)
                Button("Open logs") { open(Log.dir) }.buttonStyle(.quietNarrow)
                Button("Open models folder") { open(Self.modelsDir) }.buttonStyle(.quietNarrow)
            }
            .padding(.top, 10)
            #endif

            FieldLabel("Privacy")
            Text("No cloud services, accounts, analytics or telemetry. The speech engine runs offline (models are only downloaded when you pick them) and the AI runtime is only reached on 127.0.0.1. Logs record timings and sizes, never what you said. Audio is never written to disk.")
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
        let whisper = WhisperModels.downloaded()
        localModels = "Speech (models/whisper):  " + (whisper.isEmpty ? "none" : whisper.joined(separator: ", ")) + "\n"
            + "Speech (Apple Speech):  " + (names.isEmpty ? "none" : names.joined(separator: ", ")) + "\n"
            + "Language models (Ollama):  " + (model.ollamaModels.isEmpty ? "none (or runtime not running)" : model.ollamaModels.joined(separator: ", "))
    }
}
