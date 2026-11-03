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
                Decor("口述").padding(.bottom, 3)
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            #if os(macOS)
            Caption("Press \(model.settings.hotkey) in any app to dictate, and again to stop. The active profile decides what happens to your words.", size: 12)
                .padding(EdgeInsets(top: 0, leading: 12, bottom: 16, trailing: 8))
            #else
            Caption("Tap Dictate on the dashboard to dictate. The active profile decides what happens to your words.", size: 12)
                .padding(EdgeInsets(top: 0, leading: 12, bottom: 16, trailing: 8))
            #endif
            HStack(alignment: .firstTextBaseline) {
                Readout("Profiles").padding(.leading, 12)
                Spacer()
                #if os(macOS)
                // Empty when there is no cycle hotkey (SpeechToTextPage.xaml.cs).
                if !model.settings.cycleProfileHotkey.isEmpty {
                    Readout("\(model.settings.cycleProfileHotkey) cycles")
                        .padding(.trailing, 12)
                        .help("Press this shortcut in any app to switch to the next profile.")
                }
                #endif
            }
            .padding(.bottom, 8)
            Rule()
            VStack(spacing: 0) {
                ForEach(model.profiles) { p in
                    ProfileRow(profile: p, active: p.id == model.activeProfile.id, selected: sizeClass != .compact && p.id == model.profiles[selectedIndex ?? 0].id) {
                        nav.goProfile(p.id)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Profiles")
            Button {
                let p = BuiltInProfiles.newProfile()
                model.profiles.append(p)
                nav.goProfile(p.id)
            } label: {
                HStack(spacing: 8) {
                    // A fixed muted plus, as Windows draws it (the label turns ink on hover, the plus doesn't).
                    Path { p in
                        p.move(to: CGPoint(x: 6, y: 1)); p.addLine(to: CGPoint(x: 6, y: 11))
                        p.move(to: CGPoint(x: 1, y: 6)); p.addLine(to: CGPoint(x: 11, y: 6))
                    }
                    .stroke(ob.muted, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: 12, height: 12)
                    Text("New profile")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.dashed)
            .accessibilityLabel("New profile")
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
    @State private var trial = Trial()
    @State private var running = false
    @State private var confirmDelete = false
    @State private var onlyOne = false
    /// The preview Try it waits on (the profile shows a preview before inserting), and where its choice goes.
    @State private var preview: HistoryEntry?
    @State private var previewChoice: CheckedContinuation<String?, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tryIt.padding(.top, 24)
            switches.padding(.top, 24)
            modelsCard.padding(.top, 12)
            if profile.autoProcess {
                Group {
                    if sizeClass == .compact {
                        VStack(alignment: .leading, spacing: 24) { instructions; behaviour }
                    } else {
                        // Windows' 3* : 24 : 2* grid, the second column at least 260.
                        RatioColumns(gutter: 24, minSecond: 260) { instructions; behaviour }
                    }
                }
                .padding(.top, 24)
            }
        }
        .onChange(of: profile.autoProcess) { trial = Trial() }
        .onChange(of: profile.id) { trial = Trial() }
        .alert("Delete the profile \"\(profile.name)\"?", isPresented: $confirmDelete) {
            Button("Yes", role: .destructive) {
                // As ProfileService.Delete: the default moves to the first profile, and if this one was active, the
                // default becomes active.
                let id = profile.id, wasActive = isActive
                nav.goProfile(nil)
                model.profiles.removeAll { $0.id == id }
                if model.settings.defaultProfileID == id { model.settings.defaultProfileID = model.profiles.first?.id }
                if wasActive { model.settings.activeProfileID = model.settings.defaultProfileID }
            }
            Button("No", role: .cancel) {}
        }
        .alert("You need at least one profile.", isPresented: $onlyOne) { Button("OK") {} }
        .sheet(item: $preview) { entry in
            // Windows opens its preview window for the trial; here it is the same card, over the page.
            PreviewPill(entry: entry, profile: profile.name, hotkey: "", opacity: 1,
                        onInsert: { choose(entry.inserted) }, onOriginal: { choose(entry.transcription) }, onDiscard: { choose(nil) })
                .padding(16)
                .presentationBackground(.clear)
                .interactiveDismissDisabled()
                #if os(macOS)
                .onExitCommand { choose(nil) }
                #endif
        }
    }

    private var isActive: Bool { profile.id == model.activeProfile.id }
    private var isDefault: Bool { profile.id == model.settings.defaultProfileID }

    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Name", text: $profile.name).textFieldStyle(.plain).font(Ob.mono(30, .bold)).padding(.vertical, 2)
                    .help("Click to rename").accessibilityLabel("Profile name")
                TextField("Description", text: $profile.description, axis: .vertical).textFieldStyle(.plain).font(Ob.sans(14))
                    .foregroundStyle(ob.muted).padding(.vertical, 2)
                    .help("Description").accessibilityLabel("Description")
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                if isActive { Chip(text: "ACTIVE", filled: true) }
                // The profile active at every start.
                if isDefault { Chip(text: "DEFAULT", filled: false).help("Oberton starts with this profile") }
                if !isActive {
                    Button("Use this profile") { model.activeProfile = profile }.buttonStyle(.primary)
                }
                Menu {
                    Button(isDefault ? "Default profile" : "Make default") { model.settings.defaultProfileID = profile.id }.disabled(isDefault)
                    Button("Delete profile…", role: .destructive) {
                        if model.profiles.count <= 1 { onlyOne = true } else { confirmDelete = true }
                    }
                } label: {
                    HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 3.5, height: 3.5) } }
                        .frame(width: 36, height: 34)
                        .overlay(Capsule().strokeBorder(ob.ink, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("More")
                .accessibilityLabel("More profile actions")
            }
            .padding(.top, 6)
        }
    }

    // MARK: Try it

    /// What Try it shows: the AI Edit box (a diff, a placeholder or a problem), the Inserted box, and the meta line.
    struct Trial {
        enum Box: Equatable { case placeholder(String), diff(String), text(String), problem(String) }
        var edit: Box?
        var output: Box = .text("")
        var meta = ""
        /// What each COPY takes: the AI's own text, and what would be inserted.
        var aiText = "", inserted = ""
    }

    private var tryIt: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("TRY IT").font(Ob.mono(12, .bold))
                Text("Edit the sample, then run this profile on it.").font(Ob.sans(12)).foregroundStyle(ob.muted).lineLimit(1)
                Spacer()
                Button("Run") { run() }.buttonStyle(.primary).frame(minHeight: 32).disabled(running)
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 12))
            Hairline()
            let layout = sizeClass == .compact ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            layout {
                trialColumn("01 // Transcription", copy: sample.trimmingCharacters(in: .whitespacesAndNewlines), copyName: "Copy Transcription") {
                    TextEditor(text: $sample)
                        .font(Ob.mono(13)).scrollContentBackground(.hidden).frame(minHeight: 72)
                        .accessibilityLabel("Sample transcript")
                }
                Hairline(vertical: sizeClass != .compact)
                trialColumn("02 // AI Edit", copy: trial.aiText, copyName: "Copy AI Edit", meta: trial.meta) {
                    box(trial.edit ?? .placeholder(profile.autoProcess ? "Run the profile to see what it changes." : "No AI edit: this profile doesn't use AI."))
                }
                Hairline(vertical: sizeClass != .compact)
                trialColumn("03 // Inserted", copy: trial.inserted, copyName: "Copy Inserted") { box(trial.output) }
            }
        }
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
    }

    private func trialColumn<C: View>(_ title: String, copy: String, copyName: String, meta: String = "", @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Readout(title)
                Spacer(minLength: 8)
                if !meta.isEmpty { Readout(meta).lineLimit(1).help(meta) }
                TextCopyButton(text: copy).padding(.leading, 10).help("Copy this box").accessibilityLabel(copyName)
            }
            content().textSelection(.enabled)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func box(_ b: Trial.Box) -> some View {
        Group {
            switch b {
            case .placeholder(let t): Text(t).foregroundStyle(ob.muted)
            case .diff(let edited): DiffText(original: sample, edited: edited, size: 15)
            case .text(let t): Text(t).foregroundStyle(ob.ink)
            case .problem(let t): Text(t).foregroundStyle(ob.accent)
            }
        }
        .font(Ob.sans(15)).lineSpacing(5)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// ProfilePage.Run_Click: the profile on the sample, honouring its own switches. The preview decides what goes in,
    /// and Read aloud reads it; an AI problem shows in red instead of an unchanged edit.
    private func run() {
        running = true
        let p = profile, input = sample
        trial = Trial(edit: p.autoProcess ? .placeholder("Processing…") : nil)
        Task {
            defer { running = false }
            let result = p.autoProcess ? await model.processor.process(input, profile: p)
                : ProcessResult(text: FragmentStitcher.tidy(input), modified: false) // no AI: only spacing and the first capital
            if let problem = result.error {
                var t = Trial()
                if p.autoProcess { t.edit = .problem(problem) } else { t.output = .problem(problem) }
                trial = t
                return
            }
            var t = Trial()
            if p.autoProcess {
                t.edit = .diff(result.text)
                t.aiText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                t.meta = !result.safetyNet ? Self.lengthChange(input, result.text)
                    : result.modified ? "safety net: some parts kept as spoken" : "safety net: original kept"
                if let w = result.warning, !result.safetyNet { t.meta = w }
            }
            var final = result.text
            if p.showPreview {
                t.output = .placeholder("Waiting for your choice in the preview…")
                trial = t
                let chosen = await withCheckedContinuation { c in
                    previewChoice = c
                    preview = HistoryEntry(transcription: input, aiEdit: p.autoProcess ? result.text : nil, inserted: result.text,
                                           profileName: p.name, model: nil, appName: nil, seconds: 0, turnaroundSeconds: 0,
                                           warning: nil, safetyNet: result.safetyNet, wasInserted: false)
                }
                guard let chosen else {
                    t.output = .placeholder("Discarded in the preview: nothing would be inserted.")
                    trial = t
                    return
                }
                final = chosen
            }
            t.output = .text(final)
            t.inserted = final.trimmingCharacters(in: .whitespacesAndNewlines)
            trial = t
            if p.readAloudAfterInsert && !t.inserted.isEmpty {
                model.reader.read(t.inserted, voice: p.voice ?? model.settings.ttsVoice, speed: model.settings.ttsBaseSpeed)
            }
        }
    }

    private func choose(_ text: String?) {
        preview = nil
        previewChoice?.resume(returning: text)
        previewChoice = nil
    }

    /// "−52% length · within limit": the same word-count measure the safety net uses ("+0%" when it is the same).
    static func lengthChange(_ input: String, _ output: String) -> String {
        func words(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }
        let wi = words(input)
        guard wi > 0 else { return "" }
        let change = Double(words(output)) / Double(wi) - 1
        return "\(change < 0 ? "−" : "+")\(Int((abs(change) * 100).rounded()))% length · within limit"
    }

    // MARK: Switches

    private var switches: some View {
        VStack(spacing: 0) {
            ObSwitch("Use AI", isOn: $profile.autoProcess).padding(.horizontal, 14).accessibilityLabel("Use AI")
            Caption(profile.autoProcess
                    ? "Your words go to the local AI model with these instructions before they are inserted."
                    : "Your words are inserted as the speech recognizer heard them, with the pieces typed while you speak joined into clean sentences. Nothing goes to the AI model.",
                    size: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 0, leading: 14, bottom: 12, trailing: 14))
            Hairline()
            ObSwitch("Preview before inserting", isOn: $profile.showPreview).padding(.horizontal, 14)
            Hairline()
            ObSwitch("Read aloud after inserting", detail: "Once the text is in place, Read aloud reads it to you with the voice chosen under Models. \(stopHint)",
                     isOn: $profile.readAloudAfterInsert)
                .padding(.horizontal, 14).padding(.vertical, 4)
            #if os(macOS)
            // Without AI: how the words go into the app while you speak (Settings › General › Type as you speak).
            if !profile.autoProcess {
                Hairline()
                ObSwitch("Type the words in, instead of pasting them",
                         detail: "While you speak, your words go into the app as they are heard. Off (recommended): each new bit is pasted. On: it is typed key by key, which some apps (browsers, chat apps, editors with autocomplete) can garble.",
                         isOn: $profile.liveTyping)
                    .padding(.horizontal, 14).padding(.vertical, 4)
            }
            #endif
        }
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
    }

    private var stopHint: String {
        #if os(macOS)
        "Press the Read aloud hotkey to stop it."
        #else
        "Tap Stop in the player to stop it."
        #endif
    }

    // MARK: Models

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MODELS").font(Ob.mono(12, .bold))
            Text("What this profile listens, edits and reads with. Only models on this \(Device.noun) are listed (download more under Settings › Models); cloud AI models appear once you add a key and turn off \"Keep everything offline\".")
                .font(Ob.sans(12)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 2).padding(.bottom, 10)
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 8) {
                GridRow {
                    Readout("Speech to text").frame(width: 140, alignment: .leading)
                    ObMenu(options: speechChoices, selection: Binding(get: { profile.speechModel ?? "" }, set: { profile.speechModel = $0.isEmpty ? nil : $0 }))
                        .frame(maxWidth: 528).accessibilityLabel("Speech-to-text model")
                }
                if profile.autoProcess {
                    GridRow {
                        Readout("AI edit").frame(width: 140, alignment: .leading)
                        ObMenu(options: aiChoices, selection: Binding(get: { profile.model ?? "" }, set: { profile.model = $0.isEmpty ? nil : $0 }))
                            .frame(maxWidth: 528).accessibilityLabel("AI model")
                    }
                }
                GridRow {
                    Readout("Read aloud").frame(width: 140, alignment: .leading)
                    ProfileVoicePicker(voice: $profile.voice)
                }
            }
            Text("Switching to a profile with a different speech model loads it; recording starts right away meanwhile. The Read aloud voice also reads this profile's dictations back, and is used by the Read aloud hotkey while this profile is active.")
                .font(Ob.sans(12)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            if let problem { Text(problem).font(Ob.sans(12)).foregroundStyle(ob.accent).fixedSize(horizontal: false, vertical: true).padding(.top, 6) }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
        .task { await model.refreshOllama() }
    }

    /// ProfilePage.FillSpeechModels: "the one in Settings", then what is on this device (Apple Speech and the downloaded
    /// Whisper models); a model the profile names that isn't downloaded any more stays listed, marked.
    private var speechChoices: [(String, String)] {
        let settingsName = model.settings.whisperModel.map(WhisperModels.name(of:)) ?? "Apple Speech"
        var choices = [("", "Same as Settings › Models (\(settingsName))"), (Profile.appleSpeech, "Apple Speech")]
        choices += WhisperModels.all.filter { WhisperModels.isDownloaded($0.id) }.map { ($0.id, $0.name) }
        if let own = profile.speechModel, !own.isEmpty, !choices.contains(where: { $0.0.caseInsensitiveCompare(own) == .orderedSame }) {
            choices.append((own, WhisperModels.name(of: own) + " (not downloaded)"))
        }
        return choices
    }

    /// ProfilePage.FillModels: only what can actually run. Apple Intelligence when it is ready, the models Ollama has,
    /// and cloud models that have a key while "Keep everything offline" is off; a model the profile names that isn't
    /// available any more stays listed, marked.
    private var aiChoices: [(String, String)] {
        let s = model.settings
        var choices = [("", "Active model (\(s.defaultModel.shortName))")]
        if AppleIntelligenceBackend.unavailableReason == nil { choices.append((ModelID.appleOnDevice.description, "Apple Intelligence")) }
        choices += model.ollamaModels.map { (ModelID(provider: .ollama, name: $0).description, $0) }
        if !s.cloud.keepOffline {
            let cloud = CloudCatalog.anthropic.map { ($0.id, $0.title) } + [(ModelID(provider: .openai, name: s.cloud.openAIModel), s.cloud.openAIModel)]
            choices += cloud.filter { KeyStore.get($0.0.provider) != nil }.map { ($0.0.description, "\($0.1) · cloud") }
        }
        if let own = profile.model, !own.isEmpty, !choices.contains(where: { $0.0.caseInsensitiveCompare(own) == .orderedSame }) {
            choices.append((own, (ModelID(own)?.shortName ?? own) + " (not available)"))
        }
        return choices
    }

    /// Why this profile's AI can't run now (the Mac's addition: Windows only marks the model "(not available)").
    private var problem: String? {
        guard profile.autoProcess else { return nil }
        let id = model.processor.model(for: profile)
        switch id.provider {
        case .apple: return AppleIntelligenceBackend.unavailableReason
        case .anthropic, .openai:
            return model.settings.cloud.keepOffline ? "\"Keep everything offline\" is on, so this profile's dictations go in as spoken." : nil
        case .ollama: return model.ollamaModels.contains { LocalCatalog.same($0, id.name) } ? nil : "The local AI runtime isn't running, or this model isn't downloaded (Settings › Models)."
        }
    }

    // MARK: Instructions and behaviour

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("INSTRUCTIONS").font(Ob.mono(12, .bold)).padding(.bottom, 8)
            TextEditor(text: $profile.prompt)
                .font(Ob.sans(13))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 240, maxHeight: 420)
                .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
                .accessibilityLabel("Instructions")
            Caption("Sent to the local AI model along with your transcript. It is told to reply with only the edited text.").padding(.top, 6)
        }
    }

    private var behaviour: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("BEHAVIOUR").font(Ob.mono(12, .bold)).padding(.bottom, 8)
            VStack(spacing: 0) {
                ObSwitch("Rewrite the whole dictation", isOn: $profile.rewriteWhole).padding(.horizontal, 14)
                Caption("For instructions that reshape what you say, like turning your thoughts into an email. The AI gets everything at once when you stop. While you speak, your words are typed as spoken, then replaced by the rewrite. Off: long dictation is edited a few sentences at a time, which keeps the wording closer to yours.",
                        size: 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 0, leading: 14, bottom: 12, trailing: 14))
                Hairline()
                ObSwitch("Keep paragraph breaks", isOn: $profile.preserveParagraphs).padding(.horizontal, 14)
                Hairline()
                ObSwitch("Remove filler words", isOn: $profile.removeFillers).padding(.horizontal, 14)
                Hairline()
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("SAFETY NET").font(Ob.mono(12, .bold))
                        Spacer()
                        Text("±\(Int((profile.maxChangeRatio * 100).rounded()))%").font(Ob.mono(12))
                    }
                    Slider(value: $profile.maxChangeRatio, in: 0.1...0.9, step: 0.1).disabled(profile.rewriteWhole)
                        .padding(.top, 6).padding(.bottom, 4).accessibilityLabel("Safety net")
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

/// Windows' chip (App.xaml "Chip"): mono 11 in a capsule, filled ink for ACTIVE, an outline for DEFAULT.
private struct Chip: View {
    var text: String
    var filled: Bool
    @Environment(\.ob) private var ob

    var body: some View {
        Text(text).font(Ob.mono(11))
            .foregroundStyle(filled ? ob.onInk : ob.ink)
            .padding(.horizontal, 9).padding(.vertical, 2)
            .background(Capsule().fill(filled ? ob.ink : .clear))
            .overlay(Capsule().strokeBorder(filled ? .clear : ob.divider, lineWidth: 1))
    }
}

/// Two columns sharing the width 3 : 2 with a gutter, the second never narrower than `minSecond` (a WPF star grid).
private struct RatioColumns: Layout {
    var gutter: CGFloat
    var minSecond: CGFloat

    private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let room = max(0, total - gutter)
        let second = max(minSecond, room * 2 / 5)
        return (max(0, room - second), second)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 900
        let (a, b) = widths(total)
        let ha = subviews.first?.sizeThatFits(ProposedViewSize(width: a, height: nil)).height ?? 0
        let hb = subviews.count > 1 ? subviews[1].sizeThatFits(ProposedViewSize(width: b, height: nil)).height : 0
        return CGSize(width: total, height: max(ha, hb))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (a, b) = widths(bounds.width)
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: a, height: nil))
        if subviews.count > 1 {
            subviews[1].place(at: CGPoint(x: bounds.minX + a + gutter, y: bounds.minY), proposal: ProposedViewSize(width: b, height: nil))
        }
    }
}
