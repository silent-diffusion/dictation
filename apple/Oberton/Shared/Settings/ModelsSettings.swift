import ObertonCore
import SwiftUI

// MARK: - B // Models & AI

struct ModelsSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Readout("Speech recognition").padding(.top, 4)
            ModelRow(name: "Apple Speech", badges: [("Active", .active), ("Installed", .plain)],
                     detail: "Apple's on-device speech recognizer. Downloads its language once, through the system.")
            Readout("Extended notes · AI").padding(.top, 16)
            NotesModelMenu(width: 528)
            Caption("Extended Notes formats and sums up long sessions in the background, so it can use a bigger model than dictation needs. " +
                    "Best on this \(Device.noun) is the largest installed Ollama model that fits in the memory the GPU may use" +
                    (NotesRecorder.gpuBytes.map { " (\(NotesModels.gb($0)) here)" } ?? "") +
                    "; with no Ollama model, the active model. A cloud model would send the whole transcript to that service.", size: 12.5)
                .padding(.top, 2)
            HStack {
                Readout("AI cleanup · on this \(Device.noun)")
                Spacer()
                #if os(macOS)
                Button("Refresh") { Task { await model.refreshOllama() } }.buttonStyle(.quietSmall)
                #endif
            }
            .padding(.top, 16)
            ModelRow(name: "Apple Intelligence", badges: appleBadges,
                     detail: AppleIntelligenceBackend.unavailableReason ?? "Apple's on-device model. Nothing to install; nothing leaves this \(Device.noun).",
                     action: isDefault(.appleOnDevice) ? nil : ("Use this", { model.settings.defaultModel = .appleOnDevice }))
            #if os(macOS)
            ForEach(model.ollamaModels, id: \.self) { name in
                let id = ModelID(provider: .ollama, name: name)
                ModelRow(name: name, badges: (isDefault(id) ? [("Active", .active)] : []) + [("Ollama", .plain)],
                         detail: "Served by Ollama on this Mac.", action: isDefault(id) ? nil : ("Use this", { model.settings.defaultModel = id }))
            }
            if model.ollamaModels.isEmpty {
                Caption("Ollama models appear here when Ollama is running on this Mac (ollama.com, then e.g. ollama pull qwen2.5:3b).", size: 12.5)
            }
            #endif
            Readout("AI cleanup · cloud").padding(.top, 16)
            Caption("Used only by profiles that pick them, and only while “Keep everything offline” is off (Settings › Cloud AI).", size: 12.5)
            ForEach(CloudCatalog.anthropic) { m in
                ModelRow(name: m.title, badges: cloudBadges(m.id), detail: m.blurb,
                         action: isDefault(m.id) ? nil : ("Use this", { model.settings.defaultModel = m.id }))
            }
            let openai = ModelID(provider: .openai, name: model.settings.cloud.openAIModel)
            ModelRow(name: openai.name, badges: cloudBadges(openai), detail: "OpenAI or a compatible service.",
                     action: isDefault(openai) ? nil : ("Use this", { model.settings.defaultModel = openai }))
            #if os(macOS)
            FieldLabel("Ollama address")
            ObField("http://127.0.0.1:11434", text: $model.settings.ollamaEndpoint, mono: true, width: 300)
            Caption("Must be on this Mac.", size: 12.5).padding(.top, 6)
            #endif
        }
    }

    private func isDefault(_ id: ModelID) -> Bool { model.settings.defaultModel == id }

    private var appleBadges: [(String, Badge.Kind)] {
        (isDefault(.appleOnDevice) ? [("Active", .active)] : []) + [AppleIntelligenceBackend.unavailableReason == nil ? ("Ready", .ok) : ("Unavailable", .outline)]
    }

    private func cloudBadges(_ id: ModelID) -> [(String, Badge.Kind)] {
        var b: [(String, Badge.Kind)] = isDefault(id) ? [("Active", .active)] : []
        b.append(("Cloud", .cloud))
        b.append(KeyStore.get(id.provider) != nil ? ("Key set", .plain) : ("No key", .outline))
        if model.settings.cloud.keepOffline { b.append(("Blocked · offline", .outline)) }
        return b
    }
}

/// A model as a row in a hairline box: its name in mono with badges, a line about it, and one capsule at the right.
struct ModelRow: View {
    var name: String
    var badges: [(String, Badge.Kind)]
    var detail: String
    var action: (String, () -> Void)? = nil
    @Environment(\.ob) private var ob

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name).font(Ob.mono(13.5, .bold))
                    ForEach(Array(badges.enumerated()), id: \.offset) { _, b in Badge(text: b.0, kind: b.1) }
                }
                Text(detail).font(Ob.sans(12)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action { Button(action.0, action: action.1).buttonStyle(.quiet) }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 14))
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
    }
}
