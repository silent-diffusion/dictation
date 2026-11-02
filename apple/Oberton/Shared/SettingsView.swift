import ObertonCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var anthropicKey = KeyStore.get(.anthropic) ?? ""
    @State private var openAIKey = KeyStore.get(.openai) ?? ""

    var body: some View {
        Form {
            Section("Models & AI") {
                Picker("Default AI model", selection: $model.settings.defaultModel) {
                    ForEach(model.availableModels, id: \.self) { Text($0.displayName).tag($0) }
                }
                LabeledContent("Apple Intelligence") {
                    if let reason = AppleIntelligenceBackend.unavailableReason {
                        Text(reason).foregroundStyle(.orange).multilineTextAlignment(.trailing)
                    } else {
                        Text("Ready · on-device").foregroundStyle(.secondary)
                    }
                }
                #if os(macOS)
                TextField("Ollama address", text: $model.settings.ollamaEndpoint)
                LabeledContent("Ollama models") {
                    Text(model.ollamaModels.isEmpty ? "None found (is Ollama running?)" : model.ollamaModels.joined(separator: ", "))
                        .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                Button("Look for Ollama models") { Task { await model.refreshOllama() } }
                #endif
            }
            Section {
                Toggle("Keep everything offline", isOn: $model.settings.cloud.keepOffline)
                SecureField("Anthropic API key", text: $anthropicKey)
                    .onSubmit { KeyStore.set(.anthropic, anthropicKey) }
                SecureField("OpenAI API key", text: $openAIKey)
                    .onSubmit { KeyStore.set(.openai, openAIKey) }
                TextField("OpenAI-compatible address", text: $model.settings.cloud.openAIBaseURL)
                TextField("OpenAI model", text: $model.settings.cloud.openAIModel)
            } header: {
                Text("Cloud AI")
            } footer: {
                Text("While “Keep everything offline” is on, nothing is sent to a cloud model, whatever a profile picks. Keys are kept in the Keychain.")
            }
            .onDisappear {
                KeyStore.set(.anthropic, anthropicKey)
                KeyStore.set(.openai, openAIKey)
            }
            Section("Speech") {
                Picker("Language", selection: $model.settings.language) {
                    ForEach(["en-US", "en-GB", "en-AU", "en-IN", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR", "ja-JP", "zh-CN", "ko-KR"], id: \.self) {
                        Text(Locale.current.localizedString(forIdentifier: $0) ?? $0).tag($0)
                    }
                }
                TextField("Vocabulary (names, jargon; comma-separated)", text: $model.settings.vocabularyHint)
                LabeledContent("Longest dictation") {
                    Stepper("\(Int(model.settings.maxRecordingSeconds / 60)) min", value: $model.settings.maxRecordingSeconds, in: 60...3600, step: 60)
                }
            }
            #if os(macOS)
            Section("Dictation") {
                Toggle("Show the overlay while dictating", isOn: $model.settings.showOverlay)
                Picker("Overlay position", selection: $model.settings.overlayPosition) {
                    ForEach(OverlayPosition.allCases, id: \.self) { Text(String(describing: $0).capitalizedWords).tag($0) }
                }
                LabeledContent("Overlay opacity") { Slider(value: $model.settings.overlayOpacity, in: 0.3...1) }
                Toggle("Put my clipboard back after inserting", isOn: $model.settings.restoreClipboard)
            }
            Section {
                LabeledContent("Dictate", value: model.settings.hotkey)
                LabeledContent("Next profile", value: model.settings.cycleProfileHotkey)
                LabeledContent("Read aloud", value: model.settings.speakHotkey)
            } header: {
                Text("Hotkeys")
            } footer: {
                Text("Ctrl+Space is also macOS's “previous input source” shortcut; if you use several keyboard layouts, change one of them in System Settings › Keyboard › Keyboard Shortcuts.")
            }
            #endif
            Section("History") {
                Toggle("Keep recent dictations on this device", isOn: $model.settings.keepHistory)
                Stepper("Keep the last \(model.settings.historyLimit)", value: $model.settings.historyLimit, in: 10...500, step: 10)
                Stepper("Typing speed for “time saved”: \(model.settings.typingWPM) wpm", value: $model.settings.typingWPM, in: 10...150, step: 5)
            }
            Section("About") {
                Text("Oberton (倍音, German for overtone): the AI adds a layer of polish on top of your own voice. Speech recognition runs on this device; the AI runs on this device too unless you pick a cloud model and turn off “Keep everything offline”. No accounts, analytics or telemetry.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { await model.refreshOllama() }
    }
}

private extension String {
    /// "bottomCenter" → "Bottom center".
    var capitalizedWords: String {
        let spaced = replacing(#/([a-z])([A-Z])/#) { "\($0.output.1) \($0.output.2.lowercased())" }
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
