import ObertonCore
import SwiftUI

/// Settings › Models › READ ALOUD VOICE (ModelsPage.RebuildAsync): Kokoro v1.0 with Download, each Piper voice with
/// Download or Use this, and the system's voices. A download shows its progress in the row and can be cancelled.
struct ReadAloudVoiceRows: View {
    @EnvironmentObject var model: AppModel
    /// Another download runs on the page (Windows allows one at a time).
    var busy = false

    var body: some View { Rows(reader: model.reader, busy: busy) }

    private struct Rows: View {
        @EnvironmentObject var model: AppModel
        @ObservedObject var reader: ReadAloudPlayer
        var busy: Bool
        @State private var failure: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                kokoroRow
                ForEach(VoiceCatalog.piperVoices, id: \.id) { piperRow($0) }
                systemRow
            }
            .alert("Oberton", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK") {}
            } message: { Text(failure ?? "") }
            .dialogLook(.warning, shown: failure != nil)
        }

        private var voice: String { model.settings.ttsVoice ?? VoiceCatalog.defaultVoice }
        private var activeModel: String { VoiceCatalog.modelOf(voice) }
        private var disabled: Bool { busy || reader.install != nil }

        private var kokoroRow: some View {
            let installed = VoiceInstaller.kokoroInstalled
            var badges: [(String, Badge.Kind)] = []
            if installed && activeModel == VoiceCatalog.kokoro { badges.append(("Active", .active)) }
            if SpeechVoices.shared.isLoaded { badges.append(("Loaded", .ok)) }
            badges.append(installed ? ("Downloaded", .plain) : ("Not downloaded", .outline))
            let model = VoiceCatalog.model(VoiceCatalog.kokoro)
            return row("Kokoro v1.0", badges: badges, detail: "\(model.description) \(VoiceCatalog.kokoroVoices.count) voices.",
                       voice: VoiceCatalog.defaultVoice, installed: installed, canUse: false)
        }

        private func piperRow(_ p: PiperVoice) -> some View {
            let installed = VoiceInstaller.piperInstalled(p.name)
            var badges: [(String, Badge.Kind)] = voice == p.id ? [("Active", .active)] : []
            badges.append(installed ? ("Downloaded", .plain) : ("Not downloaded", .outline))
            return row("Piper · \(p.label)", badges: badges, detail: "\(p.kind) · light and fast · \(p.mb) MB",
                       voice: p.id, installed: installed, canUse: voice != p.id)
        }

        private var systemRow: some View {
            let voices = VoiceCatalog.systemVoices()
            var seen = Set<String>()
            let names = voices.map { VoiceCatalog.shortName($0.id) }.filter { seen.insert($0).inserted } // one per name
            var badges: [(String, Badge.Kind)] = activeModel == VoiceCatalog.system ? [("Active", .active)] : []
            badges.append(voices.isEmpty ? ("None", .outline) : ("Installed", .plain))
            #if os(macOS)
            let add = "System Settings › Accessibility › Spoken Content"
            #else
            let add = "Settings › Accessibility › Spoken Content"
            #endif
            return ModelRow(name: "\(Device.noun) voices", badges: badges,
                            detail: voices.isEmpty ? "No \(Device.noun) voices found. Add some under \(add)."
                                : "\(names.count) installed with \(Device.system) (\(names.joined(separator: ", "))); instant, no download")
        }

        private func row(_ name: String, badges: [(String, Badge.Kind)], detail: String, voice id: String, installed: Bool, canUse: Bool) -> ModelRow {
            let fetching = reader.install.map { VoiceCatalog.findPiper($0.voice)?.id ?? VoiceCatalog.defaultVoice == id } ?? false
            let action: (String, () -> Void)?
            if fetching { action = ("Cancel", { reader.cancelInstall() }) }
            else if !installed { action = ("Download", { download(id) }) }
            else if canUse { action = ("Use this", { model.settings.ttsVoice = id }) }
            else { action = nil }
            return ModelRow(name: name, badges: badges, detail: detail, action: action,
                            progress: fetching ? .some(reader.install?.progress.fraction) : nil,
                            primary: canUse && installed, enabled: fetching || !disabled)
        }

        private func download(_ id: String) {
            reader.installVoice(id) { result in
                switch result {
                case .success, .failure(is CancellationError): break
                case .failure(let error as UserFacingError): failure = error.message
                case .failure(let error):
                    Log.error("Model download failed", error)
                    failure = "The download failed. See the log for details."
                }
            }
        }
    }
}

/// A profile's Read aloud model and voice, side by side (ProfilePage.FillVoices): "Same as Read aloud (Kokoro v1.0 ·
/// Heart)" or a model with downloaded voices, then that model's downloaded voices. A voice the profile names that
/// isn't downloaded any more stays listed, marked.
struct ProfileVoicePicker: View {
    @Binding var voice: String?
    @EnvironmentObject var model: AppModel
    /// The model picked here before a voice of it is chosen (one with nothing downloaded keeps the list empty).
    @State private var picked: String?

    var body: some View {
        HStack(spacing: 8) {
            ObMenu(options: models, selection: modelBinding, width: 260).accessibilityLabel("Read aloud model")
            ObMenu(options: voices.isEmpty ? [("", "No voices downloaded")] : voices, selection: voiceBinding, width: 260, maxListHeight: 420)
                .disabled(currentModel.isEmpty).accessibilityLabel("Read aloud voice")
        }
    }

    private var own: String { voice ?? "" }
    private var currentModel: String { picked ?? (own.isEmpty ? "" : VoiceCatalog.modelOf(own)) }

    private var models: [(String, String)] {
        let readAloud = model.settings.ttsVoice
        let available = VoiceCatalog.available()
        return [("", "Same as Read aloud (\(VoiceCatalog.model(VoiceCatalog.modelOf(readAloud)).name) · \(VoiceCatalog.shortName(readAloud)))")]
            + VoiceCatalog.models.filter { m in available.contains { $0.model == m.id } || (!own.isEmpty && VoiceCatalog.modelOf(own) == m.id) }
                .map { ($0.id, $0.name) }
    }

    private var voices: [(String, String)] {
        guard !currentModel.isEmpty else { return [("", VoiceCatalog.shortName(model.settings.ttsVoice))] }
        var list = VoiceCatalog.available().filter { $0.model == currentModel }.map { ($0.id, $0.name) }
        if !own.isEmpty, VoiceCatalog.modelOf(own) == currentModel, !list.contains(where: { $0.0 == own }) {
            list.append((own, VoiceCatalog.shortName(own) + " (not downloaded)"))
        }
        return list
    }

    private var modelBinding: Binding<String> {
        Binding(get: { currentModel }, set: { m in
            picked = m
            if m.isEmpty { voice = nil; picked = nil; return }
            // A new model: its first voice.
            if VoiceCatalog.modelOf(own) != m || own.isEmpty, let first = voices.first?.0, !first.isEmpty { voice = first }
        })
    }

    private var voiceBinding: Binding<String> {
        Binding(get: { currentModel.isEmpty ? "" : own }, set: { if !$0.isEmpty { voice = $0 } })
    }
}
