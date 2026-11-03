import ObertonCore
import SwiftUI

/// SPEECH TO TEXT 口述: the profiles in a menu of their own at the left, the chosen one's page at the right
/// (SpeechToTextPage.xaml + ProfilePage.xaml). On iPhone the menu is a page and a profile opens over it.
struct SpeechToTextView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .compact {
            if let i = selectedIndex, nav.place.profileID != nil {
                PageScroll { ProfilePage(profile: $model.profiles[i]).padding(16) }
            } else {
                PageScroll { menu.padding(16) }
            }
        } else {
            HStack(spacing: 0) {
                PageScroll { menu.padding(EdgeInsets(top: 26, leading: 12, bottom: 16, trailing: 12)) }
                    .frame(width: 260)
                    .overlay(alignment: .trailing) { Rectangle().fill(ob.ink).frame(width: 1) }
                PageScroll {
                    if let i = selectedIndex {
                        ProfilePage(profile: $model.profiles[i])
                            .padding(EdgeInsets(top: 32, leading: 40, bottom: 40, trailing: 40))
                            .frame(maxWidth: 980, alignment: .leading)
                    }
                }
            }
        }
    }

    private var selectedIndex: Int? {
        let id = nav.place.profileID ?? model.activeProfile.id
        return model.profiles.firstIndex { $0.id == id } ?? (model.profiles.isEmpty ? nil : 0)
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                Text("SPEECH TO TEXT").font(Ob.mono(18, .bold))
                Spacer()
                Decor("口述")
            }
            #if os(macOS)
            Caption("Press \(model.settings.hotkey) in any app to dictate, and again to stop. The active profile decides what happens to your words.", size: 12)
                .padding(.top, 10)
            #else
            Caption("Tap Dictate on the dashboard to dictate. The active profile decides what happens to your words.", size: 12).padding(.top, 10)
            #endif
            HStack {
                Readout("Profiles")
                Spacer()
                #if os(macOS)
                Readout("\(model.settings.cycleProfileHotkey) cycles")
                #endif
            }
            .padding(.top, 18).padding(.bottom, 6).padding(.horizontal, 10)
            Rule()
            ForEach(model.profiles) { p in
                ProfileRow(profile: p, active: p.id == model.activeProfile.id, selected: sizeClass != .compact && p.id == model.profiles[selectedIndex ?? 0].id) {
                    nav.goProfile(p.id)
                }
            }
            Button {
                let p = BuiltInProfiles.newProfile()
                model.profiles.append(p)
                nav.goProfile(p.id)
            } label: {
                Label("New profile", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.dashed)
            .padding(.top, 10)
        }
    }
}

/// A two-line row: square, a hairline under it, a 3px ink bar beside the selected one.
struct ProfileRow: View {
    var profile: Profile
    var active: Bool
    var selected: Bool
    var action: () -> Void
    @Environment(\.ob) private var ob
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(Ob.sans(13.5, .semibold)).lineLimit(1)
                    Text(profile.description).font(Ob.sans(12)).foregroundStyle(ob.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                if active {
                    HStack(spacing: 5) {
                        Circle().fill(ob.accent).frame(width: 6, height: 6)
                        Readout("Active", color: ob.accent)
                    }
                    .padding(.top, 3)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected || hover ? ob.subtle : .clear)
            .overlay(alignment: .leading) { if selected { Rectangle().fill(ob.ink).frame(width: 3) } }
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ProfilePage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Binding var profile: Profile
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var sample = "um so yesterday I I went to the the store and and bought uh three apples no wait four apples"
    @State private var result: ProcessResult?
    @State private var running = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tryIt.padding(.top, 24)
            switches.padding(.top, 24)
            modelsCard.padding(.top, 12)
            if profile.autoProcess {
                let layout = sizeClass == .compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 24)) : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                layout {
                    instructions.frame(maxWidth: .infinity).layoutPriority(3)
                    behaviour.frame(minWidth: 260, maxWidth: .infinity).layoutPriority(2)
                }
                .padding(.top, 24)
            }
        }
        .confirmationDialog("Delete \(profile.name)?", isPresented: $confirmDelete) {
            Button("Delete profile", role: .destructive) {
                // As ProfileService.Delete: the default moves to the first profile, and if this one was active, the
                // default becomes active.
                let id = profile.id, wasActive = isActive
                nav.goProfile(nil)
                model.profiles.removeAll { $0.id == id }
                if model.settings.defaultProfileID == id { model.settings.defaultProfileID = model.profiles.first?.id }
                if wasActive { model.settings.activeProfileID = model.settings.defaultProfileID }
            }
        }
    }

    private var isActive: Bool { profile.id == model.activeProfile.id }
    private var isDefault: Bool { profile.id == model.settings.defaultProfileID }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $profile.name).textFieldStyle(.plain).font(Ob.mono(30, .bold))
                TextField("Description", text: $profile.description).textFieldStyle(.plain).font(Ob.sans(14)).foregroundStyle(ob.muted)
            }
            Spacer()
            if isActive { Badge(text: "Active", kind: .active) }
            // The profile active at every start.
            if isDefault {
                Text("DEFAULT").font(Ob.mono(11)).padding(.horizontal, 8).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(ob.ink, lineWidth: 1))
                    .help("Oberton starts with this profile")
            }
            if !isActive {
                Button("Use this profile") { model.activeProfile = profile }.buttonStyle(.primary)
            }
            Menu {
                Button(isDefault ? "Default profile" : "Make default") { model.settings.defaultProfileID = profile.id }.disabled(isDefault)
                Button("Delete profile…", role: .destructive) { confirmDelete = true }.disabled(model.profiles.count < 2)
            } label: {
                HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 3.5, height: 3.5) } }
                    .frame(width: 36, height: 34)
                    .overlay(Capsule().strokeBorder(ob.ink, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More")
        }
    }

    // MARK: Try it

    private var tryIt: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("TRY IT").font(Ob.mono(12, .bold))
                Text("Edit the sample, then run this profile on it.").font(Ob.sans(12)).foregroundStyle(ob.muted).lineLimit(1)
                Spacer()
                Button(running ? "Running…" : "Run") { run() }.buttonStyle(.primary).disabled(running || sample.isEmpty)
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 12))
            Hairline()
            ThreeBoxes(transcription: sample, aiEdit: profile.autoProcess ? (running ? nil : result?.text) : nil,
                       inserted: result?.text ?? "", editMeta: editMeta,
                       editPlaceholder: running ? "Processing…" : profile.autoProcess ? "Run the profile to see what it changes." : "This profile doesn't use AI.",
                       safetyNet: result?.safetyNet == true && result?.modified == false,
                       transcriptionEditor: $sample, boxed: false)
        }
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
    }

    private var editMeta: String? {
        guard let result, profile.autoProcess else { return nil }
        if result.safetyNet && !result.modified { return "safety net: original kept" }
        let a = sample.split(whereSeparator: \.isWhitespace).count, b = result.text.split(whereSeparator: \.isWhitespace).count
        guard a > 0 else { return nil }
        let change = Int((Double(b - a) / Double(a) * 100).rounded())
        return "\(change > 0 ? "+" : change < 0 ? "−" : "")\(abs(change))% length · within limit"
    }

    private func run() {
        running = true
        let p = profile
        Task {
            let r = await model.processor.process(sample, profile: p)
            result = r
            running = false
            if p.readAloudAfterInsert { model.reader.read(r.text, voice: p.voice ?? model.settings.ttsVoice, speed: model.settings.ttsBaseSpeed) }
        }
    }

    // MARK: Switches

    private var switches: some View {
        SwitchCard {
            ObSwitch("Use AI", detail: profile.autoProcess
                     ? "Your words go to the AI model with these instructions before they are inserted."
                     : "Your words are inserted as the speech recognizer heard them. Nothing goes to the AI model.",
                     isOn: $profile.autoProcess)
            ObSwitch("Preview before inserting", isOn: $profile.showPreview)
            ObSwitch("Read aloud after inserting", detail: "Once the text is in place, Read aloud reads it to you with the voice chosen under Models. \(stopHint)", isOn: $profile.readAloudAfterInsert)
        }
    }

    private var stopHint: String {
        #if os(macOS)
        "Press the Read aloud hotkey to stop it."
        #else
        "Tap Stop in the player to stop it."
        #endif
    }

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MODELS").font(Ob.mono(12, .bold))
            Text("What this profile listens, edits and reads with. Speech recognition is the model in Settings › Speech recognition, on this \(Device.noun).")
                .font(Ob.sans(12)).foregroundStyle(ob.muted).padding(.top, 4).padding(.bottom, 10)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Readout("Speech to text").frame(width: 140, alignment: .leading)
                    Text(model.speechEngineName + " · on-device").font(Ob.sans(13.5)).padding(.vertical, 6)
                }
                if profile.autoProcess {
                    GridRow {
                        Readout("AI edit").frame(width: 140, alignment: .leading)
                        ObMenu(options: [("", "Default model (\(model.settings.defaultModel.shortName))")] + model.availableModels.map { ($0.description, label(for: $0)) },
                               selection: Binding(get: { profile.model ?? "" }, set: { profile.model = $0.isEmpty ? nil : $0 }))
                            .frame(maxWidth: 528)
                    }
                }
                GridRow {
                    Readout("Read aloud").frame(width: 140, alignment: .leading)
                    ObMenu(options: [("", "Same as Read aloud")] + ReadAloudPlayer.voices.map { ($0.identifier, $0.name) },
                           selection: Binding(get: { profile.voice ?? "" }, set: { profile.voice = $0.isEmpty ? nil : $0 }))
                        .frame(maxWidth: 260)
                }
            }
            if let problem { Text(problem).font(Ob.sans(12)).foregroundStyle(ob.accent).padding(.top, 10) }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
    }

    private func label(for m: ModelID) -> String {
        switch m.provider {
        case .apple: "Apple Intelligence · on-device"
        case .ollama: "\(m.name) · Ollama"
        case .anthropic, .openai: "\(m.displayName) · cloud"
        }
    }

    private var problem: String? {
        guard profile.autoProcess else { return nil }
        let id = model.processor.model(for: profile)
        switch id.provider {
        case .apple: return AppleIntelligenceBackend.unavailableReason
        case .anthropic, .openai:
            return model.settings.cloud.keepOffline ? "\"Keep everything offline\" is on, so this profile's dictations go in as spoken." : nil
        case .ollama: return model.ollamaModels.contains(id.name) ? nil : "Ollama isn't running on this Mac, or this model isn't installed."
        }
    }

    // MARK: Instructions and behaviour

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel("Instructions")
            TextEditor(text: $profile.prompt)
                .font(Ob.mono(12.5))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 240, maxHeight: 420)
                .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
            Caption("Sent to the AI model along with your transcript. It is told to reply with only the edited text.").padding(.top, 8)
        }
    }

    private var behaviour: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel("Behaviour")
            VStack(spacing: 0) {
                ObSwitch("Rewrite the whole dictation",
                         detail: "For instructions that reshape what you say, like turning your thoughts into an email. The AI gets everything at once when you stop. Off: long dictation is edited a few sentences at a time, which keeps the wording closer to yours.",
                         isOn: $profile.rewriteWhole).padding(.horizontal, 14)
                Hairline()
                ObSwitch("Keep paragraph breaks", isOn: $profile.preserveParagraphs).padding(.horizontal, 14)
                Hairline()
                ObSwitch("Remove filler words", isOn: $profile.removeFillers).padding(.horizontal, 14)
                Hairline()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("SAFETY NET").font(Ob.mono(12, .bold))
                        Spacer()
                        Text("±\(Int((profile.maxChangeRatio * 100).rounded()))%").font(Ob.mono(12))
                    }
                    Slider(value: $profile.maxChangeRatio, in: 0.1...0.9, step: 0.1).disabled(profile.rewriteWhole)
                    Caption(profile.rewriteWhole
                            ? "A rewrite may change the length a lot, so only an empty or runaway result falls back to your original words."
                            : "If the AI changes the length by more than this, your original words are inserted instead.", size: 12)
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
            }
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
        }
    }
}
