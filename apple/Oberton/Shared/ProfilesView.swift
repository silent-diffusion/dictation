import ObertonCore
import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: Profile.ID?

    var body: some View {
        List(selection: $selection) {
            ForEach(model.profiles) { p in
                NavigationLink(value: p.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(p.name).font(.headline)
                            if p.id == model.activeProfile.id { Text("ACTIVE").font(.system(.caption2, design: .monospaced)).foregroundStyle(Color.accentColor) }
                        }
                        Text(p.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .onDelete { model.profiles.remove(atOffsets: $0) }
            .onMove { model.profiles.move(fromOffsets: $0, toOffset: $1) }
        }
        .navigationTitle("Speech to text")
        .navigationDestination(for: Profile.ID.self) { id in
            if let i = model.profiles.firstIndex(where: { $0.id == id }) { ProfileEditor(profile: $model.profiles[i]) }
        }
        .toolbar {
            Button {
                var p = Profile(name: "New Profile", prompt: BuiltInProfiles.customPrompt, maxChangeRatio: 0.6)
                p.description = "Your own instructions."
                model.profiles.append(p)
                selection = p.id
            } label: { Label("New profile", systemImage: "plus") }
        }
        .task { await model.refreshOllama() }
    }
}

struct ProfileEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var profile: Profile
    @State private var sample = "um so i think we should uh meet on tuesday because because sarah is free and and the budget is about fifty no sixty thousand"
    @State private var tryResult: HistoryEntry?
    @State private var trying = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name)
                TextField("Description", text: $profile.description)
                Button(profile.id == model.activeProfile.id ? "Active profile" : "Use this profile") { model.activeProfile = profile }
                    .disabled(profile.id == model.activeProfile.id)
            }
            Section("AI") {
                Toggle("Use AI", isOn: $profile.autoProcess)
                if profile.autoProcess {
                    Picker("Model", selection: Binding(get: { profile.model ?? "" }, set: { profile.model = $0.isEmpty ? nil : $0 })) {
                        Text("Default (\(model.settings.defaultModel.displayName))").tag("")
                        ForEach(model.availableModels, id: \.self) { m in
                            Text(label(for: m)).tag(m.description)
                        }
                    }
                    if let reason = modelProblem { Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                    VStack(alignment: .leading) {
                        Text("Instructions").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $profile.prompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 160)
                    }
                    Toggle("Remove fillers", isOn: $profile.removeFillers)
                    Toggle("Preserve paragraphs", isOn: $profile.preserveParagraphs)
                    Toggle("Rewrite the whole dictation", isOn: $profile.rewriteWhole)
                    if !profile.rewriteWhole {
                        LabeledContent("Safety net") {
                            Slider(value: $profile.maxChangeRatio, in: 0.1...1, step: 0.05)
                            Text("±\(Int(profile.maxChangeRatio * 100))%").monospacedDigit().frame(width: 50)
                        }
                    }
                }
            }
            Section("Inserting") {
                Toggle("Preview before inserting", isOn: $profile.showPreview)
                Toggle("Read aloud after inserting", isOn: $profile.readAloudAfterInsert)
            }
            if profile.autoProcess {
                Section("Try it") {
                    TextEditor(text: $sample).frame(minHeight: 70)
                    Button(trying ? "Running…" : "Run on this text") { runTry() }.disabled(trying || sample.isEmpty)
                    if let tryResult { ReceiptView(entry: tryResult) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(profile.name)
    }

    private func label(for m: ModelID) -> String {
        switch m.provider {
        case .apple: m.displayName
        case .ollama: "\(m.name) · Ollama"
        case .anthropic, .openai: "\(m.displayName) · CLOUD"
        }
    }

    private var modelProblem: String? {
        let id = model.processor.model(for: profile)
        switch id.provider {
        case .apple: return AppleIntelligenceBackend.unavailableReason
        case .anthropic, .openai:
            return model.settings.cloud.keepOffline ? "\"Keep everything offline\" is on, so this profile's dictations will be inserted unedited." : nil
        case .ollama: return model.ollamaModels.contains(id.name) ? nil : "Ollama isn't running, or this model isn't installed."
        }
    }

    private func runTry() {
        trying = true
        let p = profile
        Task {
            let r = await model.processor.process(sample, profile: p)
            tryResult = HistoryEntry(transcription: sample, aiEdit: r.text, inserted: r.text, profileName: p.name, model: nil,
                                     appName: nil, seconds: 0, turnaroundSeconds: 0, warning: r.warning)
            trying = false
            if p.readAloudAfterInsert { model.reader.read(r.text, voice: p.voice ?? model.settings.ttsVoice, speed: model.settings.ttsBaseSpeed) }
        }
    }
}
