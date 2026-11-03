import ObertonCore
import SwiftUI

// MARK: - D // App

/// D.1 Advanced (Windows AdvancedPage.xaml): what is installed, where things are stored, privacy. There is no models
/// or runtimes folder: Apple's speech models live with the system, and Ollama keeps its own.
struct AdvancedSection: View {
    @EnvironmentObject var model: AppModel
    @State private var localModels = ""

    private var paths: String {
        let data = AppPaths.dataDir
        func path(_ url: URL) -> String { url.path(percentEncoded: false) }
        return """
            Data:       \(path(data))
            Settings:   \(path(data.appending(path: "settings.json")))
            Profiles:   \(path(data.appending(path: "profiles.json")))
            History:    \(path(HistoryStore.defaultDir))
            Notes:      \(path(NotesStore.defaultDir))
            Logs:       \(path(Log.dir))
            """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Where things are stored on this \(Device.noun), and what is installed.")

            FieldLabel("Local models")
            Text(localModels.isEmpty ? "…" : localModels).font(Ob.sans(13.5)).fixedSize(horizontal: false, vertical: true)

            FieldLabel("Locations")
            Text(paths).font(Ob.mono(12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            HStack(spacing: 8) {
                Button("Open data folder") { NSWorkspace.shared.open(AppPaths.dataDir) }.buttonStyle(.quiet)
                Button("Open logs") { NSWorkspace.shared.open(Log.dir) }.buttonStyle(.quiet)
            }
            .padding(.top, 10)
            #endif

            FieldLabel("Privacy")
            Caption("No accounts, analytics or telemetry. Speech is recognized on this \(Device.noun), and Apple Intelligence edits it here too. Nothing is sent anywhere unless a profile picks a cloud model and “Keep everything offline” is off. Ollama is only reached on this \(Device.noun). Logs record timings and sizes, never what you said.")
        }
        .task { await listModels() }
    }

    /// Windows lists the downloaded Whisper and Ollama models; here: the speech languages installed on the device,
    /// and Ollama's models.
    private func listModels() async {
        let speech = await LiveTranscriber.installedLanguages()
        await model.refreshOllama()
        let names = speech.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }
        localModels = "Speech (Apple Speech):  " + (names.isEmpty ? "none yet (downloads on the first dictation)" : names.joined(separator: ", ")) + "\n"
            + "Language models (Ollama):  " + (model.ollamaModels.isEmpty ? "none (or Ollama isn't running)" : model.ollamaModels.joined(separator: ", "))
    }
}
