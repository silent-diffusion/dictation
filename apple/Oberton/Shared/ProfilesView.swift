import ObertonCore
import SwiftUI

/// SPEECH TO TEXT 口述: the profiles in a menu of their own at the left, the chosen one's page at the right
/// (SpeechToTextPage.xaml + ProfilePage.xaml). On iPhone the menu is a page and a profile opens over it.
struct SpeechToTextView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass
    @FocusState private var listFocused: Bool
    /// The row that has the keyboard focus when it isn't the open one (⌘ with the arrows moves only the focus, as Ctrl
    /// does in Windows' ListBox); nil: the focus is on the open profile.
    @State private var cursor: String?

    var body: some View {
        if sizeClass == .compact {
            if let i = selectedIndex, nav.place.profileID != nil {
                PageScroll { ProfilePage(profile: $model.profiles[i]).id(model.profiles[i].id).padding(16) }
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
                        // A page of its own for each profile, as Windows makes a new ProfilePage per selection: Try it
                        // starts fresh, and a run still going stays with its own page.
                        ProfilePage(profile: $model.profiles[i])
                            .id(model.profiles[i].id)
                            .padding(EdgeInsets(top: 32, leading: 40, bottom: 40, trailing: 40))
                            .frame(maxWidth: 980, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Where an arrow, Home, End, Page Up or Page Down goes from `i` in a list of `count` (the list is all on screen).
    static func step(_ count: Int, from i: Int, key: KeyEquivalent) -> Int {
        let last = max(0, count - 1)
        return switch key {
        case .upArrow: max(0, i - 1)
        case .downArrow: min(last, i + 1)
        case .home, .pageUp: 0
        default: last
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
            Caption("Press \(model.settings.hotkey) in any app to dictate, and again to stop. The active profile decides what happens to your words.", bottom: 0)
                .padding(EdgeInsets(top: 0, leading: 12, bottom: 16, trailing: 8))
            #else
            Caption("Tap Dictate on the dashboard to dictate. The active profile decides what happens to your words.", bottom: 0)
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
                    let selected = sizeClass != .compact && p.id == model.profiles[selectedIndex ?? 0].id
                    ProfileRow(profile: p, active: p.id == model.activeProfile.id, selected: selected,
                               focused: listFocused && cursor == p.id && !selected) {
                        nav.goProfile(p.id)
                        cursor = nil
                        listFocused = true // a click focuses the list, as in a WPF ListBox
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Profiles")
            // Windows' ListBox: with the list focused, the arrow keys (and Home, End, Page Up, Page Down) open the
            // next profile; with ⌘ (Windows' Ctrl) they move only the keyboard focus, and Space opens the focused one.
            .focusable(sizeClass != .compact)
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .home, .end, .pageUp, .pageDown, .space]) { press in
                guard !model.profiles.isEmpty else { return .ignored }
                let ids = model.profiles.map(\.id)
                let focus = cursor.flatMap { c in ids.firstIndex(of: c) } ?? selectedIndex ?? 0
                if press.key == .space {
                    nav.goProfile(ids[focus])
                    cursor = nil
                    return .handled
                }
                let next = Self.step(ids.count, from: focus, key: press.key)
                if press.modifiers.contains(.command) || press.modifiers.contains(.control) {
                    cursor = ids[next] == model.profiles[selectedIndex ?? 0].id ? nil : ids[next]
                } else {
                    nav.goProfile(ids[next])
                    cursor = nil
                }
                return .handled
            }
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

/// A two-line row: square, a hairline under it, a 3px ink bar beside the selected one, and the accent bar on a row that
/// has the keyboard focus without being selected. Windows' RowItem: its IsSelected trigger comes after
/// IsKeyboardFocused, so the selected row's bar stays ink also while it has the focus.
struct ProfileRow: View {
    var profile: Profile
    var active: Bool
    var selected: Bool
    /// Has the keyboard focus and isn't the selected row.
    var focused = false
    var action: () -> Void
    @Environment(\.ob) private var ob
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name).font(Ob.sans(13.5, .semibold)).lineLimit(1)
                    Text(profile.description).font(Ob.sans(12)).foregroundStyle(ob.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if active {
                    HStack(spacing: 5) {
                        Circle().fill(ob.accent).frame(width: 6, height: 6)
                        Readout("Active", color: ob.accent)
                    }
                    .padding(.top, 3)
                }
            }
            // Windows' 8 padding plus the 1-px bottom border under it.
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 9)
            .background(selected || hover ? ob.subtle : .clear)
            .overlay(alignment: .leading) {
                switch RowMark.of(selected: selected, focused: focused) {
                case .ink: Rectangle().fill(ob.ink).frame(width: 3)
                case .accent: Rectangle().fill(ob.accent).frame(width: 3)
                case .none: EmptyView()
                }
            }
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .handCursor()
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
    @State private var promptFocused = false
    @State private var sampleFocused = false
    @State private var moreHover = false

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
        // A Try it waiting in the preview stays when the page goes: the preview is the app's (TrialPreview).
        .onDisappear { model.saveProfilesNow() } // Windows' AutoSave flushes when the page goes
        // MessageBox: the caption is the app's name, the question the text, with the Question icon.
        .alert("Oberton", isPresented: $confirmDelete) {
            Button("Yes") {
                // As ProfileService.Delete: the default moves to the first profile, and if this one was active, the
                // default becomes active. The page that opens is the one Windows' list picks while the profile goes,
                // before the active one is updated: the active profile, or the first one when the deleted one was active.
                let id = profile.id, wasActive = isActive
                model.profiles.removeAll { $0.id == id }
                nav.goProfile(wasActive ? model.profiles.first?.id : nil)
                if model.settings.defaultProfileID == id { model.settings.defaultProfileID = model.profiles.first?.id }
                if wasActive { model.settings.activeProfileID = model.settings.defaultProfileID }
            }
            Button("No", role: .cancel) {}
        } message: { Text("Delete the profile \"\(profile.name)\"?") }
        .dialogLook(.question, shown: confirmDelete)
        .alert("Oberton", isPresented: $onlyOne) { Button("OK") {} } message: { Text("You need at least one profile.") }
        .dialogLook(.information, shown: onlyOne)
    }

    private var isActive: Bool { profile.id == model.activeProfile.id }

    private func makeDefault() { model.settings.defaultProfileID = profile.id }
    private func askDelete() { if model.profiles.count <= 1 { onlyOne = true } else { confirmDelete = true } }

    /// ⋯: Windows' QuietButton (Width 36, Padding 0: hover fill, pressed at 70 %, the accent border while it has the
    /// keyboard focus), which opens its menu under itself when clicked (ProfilePage.More_Click).
    @ViewBuilder private var moreButton: some View {
        let dots = HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 3.5, height: 3.5) } }
        #if os(macOS)
        Button { moreMenu() } label: { dots }
            .buttonStyle(CapsuleButtonStyle(kind: .quiet, padding: 0, minWidth: 36))
            .background(MenuAnchor(box: moreAnchor))
            .fixedSize()
        #else
        Menu {
            Button(isDefault ? "Default profile" : "Make default") { makeDefault() }.disabled(isDefault)
            Button("Delete profile…", role: .destructive) { askDelete() }
        } label: {
            dots.frame(width: 36, height: 34)
                .background(Capsule().fill(moreHover ? ob.subtle : .clear))
                .overlay(Capsule().strokeBorder(ob.ink, lineWidth: 1))
                .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { moreHover = $0 }
        #endif
    }

    #if os(macOS)
    @State private var moreAnchor = MenuAnchor.Box()

    /// Windows' ContextMenu with Placement Bottom: "Make default" (greyed out as "Default profile" when it is) and
    /// "Delete profile…".
    private func moreMenu() {
        guard let view = moreAnchor.view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let makeDefault = MenuAction(title: isDefault ? "Default profile" : "Make default") { self.makeDefault() }
        makeDefault.isEnabled = !isDefault
        menu.addItem(makeDefault)
        menu.addItem(MenuAction(title: "Delete profile…") { askDelete() })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY : 0), in: view)
    }
    #endif
    private var isDefault: Bool { profile.id == model.settings.defaultProfileID }

    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TextField("", text: $profile.name).textFieldStyle(.plain).font(Ob.mono(30, .bold)).padding(.vertical, 2)
                    .help("Click to rename").accessibilityLabel("Profile name")
                TextField("", text: $profile.description, axis: .vertical).textFieldStyle(.plain).font(Ob.sans(14))
                    .foregroundStyle(ob.muted).padding(.vertical, 2)
                    .help("Description").accessibilityLabel("Description")
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                if isActive { Chip(text: "ACTIVE", filled: true) }
                // The profile active at every start.
                if isDefault { Chip(text: "DEFAULT", filled: false) }
                if !isActive {
                    Button("Use this profile") { model.activeProfile = profile }.buttonStyle(.primary)
                }
                moreButton
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
        /// The sample as it was run: the diff stays against it when the sample is edited afterwards (Windows renders it once).
        var original = ""
        var meta = ""
        /// What each COPY takes: the AI's own text, and what would be inserted.
        var aiText = "", inserted = ""
    }

    private var tryIt: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("TRY IT").font(Ob.mono(12, .bold))
                // A NoWrap TextBlock: cut off where the room ends, no "…".
                Text("Edit the sample, then run this profile on it.").font(Ob.sans(12)).foregroundStyle(ob.muted).noWrap()
                Spacer()
                Button("Run") { run() }.buttonStyle(CapsuleButtonStyle(kind: .primary, height: 32)).disabled(running)
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 12))
            Hairline()
            let layout = sizeClass == .compact ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            layout {
                trialColumn("01 // Transcription", copy: sample.trimmingCharacters(in: .whitespacesAndNewlines), copyName: "Copy Transcription") {
                    PlainTextBox(text: $sample, font: Ob.mono(13), nsFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                 label: "Sample transcript", focused: $sampleFocused)
                        .frame(minHeight: 72, alignment: .topLeading)
                        .modifier(BareFluentField(focused: sampleFocused))
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
            // Windows' DockPanel, all on one line: COPY and the meta docked right at their own width, the title in what
            // is left; short of room the title is cut off first, then the meta (NoWrap, no "…").
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Readout(title).noWrap()
                Spacer(minLength: 0)
                // Windows' MonoLabel keeps the case ("safety net: original kept", "−52% length · within limit").
                if !meta.isEmpty { Text(meta).font(Ob.mono(10.5)).foregroundStyle(ob.muted).noWrap().layoutPriority(1) }
                TextCopyButton(text: copy).padding(.leading, 10).help("Copy this box").accessibilityLabel(copyName)
                    .fixedSize().layoutPriority(2)
            }
            content()
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func box(_ b: Trial.Box) -> some View {
        Group {
            switch b {
            case .placeholder(let t): Text(t).foregroundStyle(ob.muted)
            case .diff(let edited): DiffText(original: trial.original, edited: edited, size: 15, lineSpacing: Ob.lineSpacing(15, lineHeight: 23))
            case .text(let t): Text(t).foregroundStyle(ob.ink)
            case .problem(let t): Text(t).foregroundStyle(ob.accent)
            }
        }
        // LineHeight 23 on every line, the last one too (SYS-002).
        .font(Ob.sans(15)).wpfLineHeight(23, size: 15)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// ProfilePage.Run_Click: the profile on the sample, honouring its own switches. The preview (the app's overlay,
    /// `AppModel.previewTrial`) decides what goes in, and Read aloud reads it; an AI problem shows in red instead of an
    /// edit. The run belongs to the app: opening another profile meanwhile doesn't stop it.
    private func run() {
        running = true
        let p = profile, input = sample
        trial = Trial(edit: p.autoProcess ? .placeholder("Processing…") : nil)
        Task {
            defer { running = false }
            do {
                let result = p.autoProcess ? try await model.processor.processOrThrow(input, profile: p)
                    : ProcessResult(text: FragmentStitcher.tidy(input), modified: false) // no AI: only spacing and the first capital
                var t = Trial(original: input)
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
                    let chosen = await model.previewTrial(profileName: p.name, raw: input, edited: result.text, usesAI: p.autoProcess,
                                                          model: p.autoProcess ? model.processor.model(for: p).description : nil)
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
                    model.reader.read(t.inserted, voice: p.readVoice(fallback: model.settings.ttsVoice))
                }
            } catch let e as UserFacingError {
                showProblem(e.message, p) // in words for the user, not logged (Windows' catch UserFacingException)
            } catch {
                Log.error("Profile test failed", error)
                showProblem(TextProcessor.somethingWentWrong, p)
            }
        }
    }

    /// ProfilePage.ShowProblem: in red in AI EDIT, or in INSERTED for a profile without AI.
    private func showProblem(_ message: String, _ p: Profile) {
        var t = Trial()
        if p.autoProcess { t.edit = .problem(message) } else { t.output = .problem(message) }
        trial = t
    }

    /// "−52% length · within limit": the same word-count measure the safety net uses ("+0%" when it is the same).
    static func lengthChange(_ input: String, _ output: String) -> String {
        func words(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }
        let wi = words(input)
        guard wi > 0 else { return "" }
        let change = Double(words(output)) / Double(wi) - 1
        // {0:P0} in code: the region's percent ("−52 %" in German), rounded from the exact value (SYS-010).
        return "\(change < 0 ? "−" : "+")\(NetNumber.percent(abs(change))) length · within limit"
    }

    // MARK: Switches

    private var switches: some View {
        VStack(spacing: 0) {
            ObSwitch("Use AI", isOn: $profile.autoProcess).padding(.horizontal, 14 + Ob.border).accessibilityLabel("Use AI")
            Caption(profile.autoProcess
                    ? "Your words go to the local AI model with these instructions before they are inserted."
                    : "Your words are inserted as the speech recognizer heard them, with the pieces typed while you speak joined into clean sentences. Nothing goes to the AI model.",
                    bottom: 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 0, leading: 14 + Ob.border, bottom: 12, trailing: 14 + Ob.border))
            Hairline()
            ObSwitch("Preview before inserting", isOn: $profile.showPreview).padding(.horizontal, 14 + Ob.border)
            Hairline()
            ObSwitch("Read aloud after inserting", detail: "Once the text is in place, Read aloud reads it to you with the voice chosen under Models. \(stopHint)",
                     isOn: $profile.readAloudAfterInsert)
                .padding(.horizontal, 14 + Ob.border).padding(.vertical, 4)
            #if os(macOS)
            // Without AI: how the words go into the app while you speak (Settings › General › Type as you speak).
            if !profile.autoProcess {
                Hairline()
                ObSwitch("Type the words in, instead of pasting them",
                         detail: "While you speak, your words go into the app as they are heard. Off (recommended): each new bit is pasted. On: it is typed key by key, which some apps (browsers, chat apps, editors with autocomplete) can garble.",
                         isOn: $profile.liveTyping)
                    .padding(.horizontal, 14 + Ob.border).padding(.vertical, 4)
            }
            #endif
        }
        // A Card: the CheckBoxes' Margin 14,0 and the rows sit inside its 1 px line (SYS-001).
        .padding(.vertical, Ob.border)
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
                        // Matched in any case, as Windows' Select.
                        ObMenu(options: aiChoices, selection: Binding(get: { Self.match(profile.model ?? "", in: aiChoices) },
                                                                    set: { profile.model = $0.isEmpty ? nil : $0 }))
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
        .padding(EdgeInsets(top: 12, leading: 14 + Ob.border, bottom: 14, trailing: 14 + Ob.border))
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
        // Windows labels the default by its stored id ("Active model (anthropic:claude-haiku-4-5-20251001)").
        var choices = [("", "Active model (\(s.defaultModel.provider == .apple ? "Apple Intelligence" : s.defaultModel.windowsForm))")]
        if AppleIntelligenceBackend.unavailableReason == nil { choices.append((ModelID.appleOnDevice.description, "Apple Intelligence")) }
        choices += model.ollamaModels.map { (ModelID(provider: .ollama, name: $0).description, $0) }
        if !s.cloud.keepOffline {
            let cloud = CloudCatalog.anthropic.map { ($0.id, $0.title) } + [(ModelID(provider: .openai, name: s.cloud.openAIModel), s.cloud.openAIModel)]
            choices += cloud.filter { KeyStore.get($0.0.provider) != nil }.map { ($0.0.description, "\($0.1) · cloud") }
        }
        if let own = profile.model, !own.isEmpty, !choices.contains(where: { $0.0.caseInsensitiveCompare(own) == .orderedSame }) {
            choices.append((own, (ModelID(stored: own)?.windowsForm ?? own) + " (not available)"))
        }
        return choices
    }

    static func match(_ value: String, in choices: [(String, String)]) -> String {
        choices.first { $0.0.caseInsensitiveCompare(value) == .orderedSame }?.0 ?? value
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
            // A Fluent-theme TextBox (its 14 pt text), Tab leaving it rather than typing a tab into the instructions.
            PlainTextBox(text: $profile.prompt, font: Ob.sans(14), nsFont: .systemFont(ofSize: 14), label: "Instructions", focused: $promptFocused)
                .padding(10 + Ob.border) // Windows' Padding 10 sits inside the box's 1-px edge
                .frame(minHeight: 240, maxHeight: 420, alignment: .topLeading)
                .modifier(FluentField(focused: promptFocused))
            Caption("Sent to the local AI model along with your transcript. It is told to reply with only the edited text.", bottom: 0).padding(.top, 6)
        }
    }

    private var behaviour: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("BEHAVIOUR").font(Ob.mono(12, .bold)).padding(.bottom, 8)
            VStack(spacing: 0) {
                ObSwitch("Rewrite the whole dictation", isOn: $profile.rewriteWhole).padding(.horizontal, 14 + Ob.border)
                Caption("For instructions that reshape what you say, like turning your thoughts into an email. The AI gets everything at once when you stop. While you speak, your words are typed as spoken, then replaced by the rewrite. Off: long dictation is edited a few sentences at a time, which keeps the wording closer to yours.",
                        bottom: 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 0, leading: 14 + Ob.border, bottom: 12, trailing: 14 + Ob.border))
                Hairline()
                ObSwitch("Keep paragraph breaks", isOn: $profile.preserveParagraphs).padding(.horizontal, 14 + Ob.border)
                Hairline()
                ObSwitch("Remove filler words", isOn: $profile.removeFillers).padding(.horizontal, 14 + Ob.border)
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
                            : "If the AI changes the length by more than this, your original words are inserted instead.", bottom: 0)
                }
                .padding(EdgeInsets(top: 12, leading: 14 + Ob.border, bottom: 14, trailing: 14 + Ob.border))
            }
            .padding(.vertical, Ob.border) // inside the Card's 1 px line
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
            // Padding 9,2; DEFAULT keeps the Chip's 1 px line outside it, ACTIVE has BorderThickness 0 (2 smaller).
            .padding(.horizontal, filled ? 9 : 9 + Ob.border).padding(.vertical, filled ? 2 : 2 + Ob.border)
            .background(Capsule().fill(filled ? ob.ink : .clear))
            .overlay(Capsule().strokeBorder(filled ? .clear : ob.ink, lineWidth: 1)) // Windows' Chip border: Ob.Border, the ink
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

/// The Fluent TextBox look for Try it's sample, which Windows sets to Background Transparent and BorderThickness 0: no
/// fill and no outline at rest, only the template's bottom line; its hover and typing fills and the 2-px ink line while
/// typing stay (`FluentField` without its resting fill and edge).
struct BareFluentField: ViewModifier {
    var focused: Bool
    @Environment(\.ob) private var ob
    @State private var hover = false

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: 4)
            ZStack(alignment: .bottom) {
                if ob.dark {
                    shape.fill(focused ? Color(hex: 0x1E1E1E, alpha: 0.7) : hover ? Color.white.opacity(0.083) : .clear)
                } else {
                    shape.fill(focused ? Color.white : hover ? Color(hex: 0xF9F9F9, alpha: 0.5) : .clear)
                }
                Rectangle().fill(focused ? ob.ink : ob.dark ? Color.white.opacity(0.55) : Color.black.opacity(0.45))
                    .frame(height: focused ? 2 : 1)
            }
            .clipShape(shape)
        }
        .onHover { hover = $0 }
    }
}

#if os(macOS)
/// Hands over the AppKit view behind a SwiftUI control, so a menu can open under it (WPF's Placement Bottom).
struct MenuAnchor: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    var box: Box

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        box.view = v
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

/// A plain multi-line text box (a WPF TextBox that accepts Return but not Tab): Tab and Shift-Tab move to the next and
/// previous control instead of typing a tab, and it is as tall as its text (within the frame it is given). The debug
/// snapshots draw its text instead (the image renderer can't draw an AppKit view).
struct PlainTextBox: View {
    @Binding var text: String
    var font: Font
    var nsFont: NSFont
    var label: String
    var focused: Binding<Bool>?
    @Environment(\.ob) private var ob

    var body: some View {
        if PageScroll<EmptyView>.flat {
            Text(text).font(font).foregroundStyle(ob.ink).frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            TextBoxView(text: $text, nsFont: nsFont, label: label, focused: focused)
        }
    }
}

private struct TextBoxView: NSViewRepresentable {
    @Binding var text: String
    var nsFont: NSFont
    var label: String
    var focused: Binding<Bool>?
    @Environment(\.ob) private var ob

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = TabLeavingTextView()
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.string = text
        view.setAccessibilityLabel(label)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? TabLeavingTextView else { return }
        if view.string != text { view.string = text }
        view.font = nsFont
        view.textColor = NSColor(ob.ink)
        view.insertionPointColor = NSColor(ob.ink)
        view.onFocus = { f in focused?.wrappedValue = f }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let view = nsView.documentView as? NSTextView, let layout = view.layoutManager, let container = view.textContainer else { return nil }
        let width = proposal.width ?? 300
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = max(layout.usedRect(for: container).height, nsFont.boundingRectForFont.height)
        return CGSize(width: width, height: min(height, proposal.height ?? height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextBoxView
        init(_ parent: TextBoxView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

final class TabLeavingTextView: NSTextView {
    var onFocus: ((Bool) -> Void)?
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(nil) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(nil) }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocus?(false) }
        return ok
    }
}
#else
/// On iPhone and iPad a plain TextEditor (a hardware Tab there moves focus already).
struct PlainTextBox: View {
    @Binding var text: String
    var font: Font
    var label: String
    var focused: Binding<Bool>?
    @FocusState private var isFocused: Bool

    init(text: Binding<String>, font: Font, nsFont: UIFont? = nil, label: String, focused: Binding<Bool>? = nil) {
        _text = text
        self.font = font
        self.label = label
        self.focused = focused
    }

    var body: some View {
        TextEditor(text: $text).font(font).scrollContentBackground(.hidden).focused($isFocused)
            .onChange(of: isFocused) { _, f in focused?.wrappedValue = f }
            .accessibilityLabel(label)
    }
}
#endif
