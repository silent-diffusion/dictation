import AVFoundation
import ObertonCore
import SwiftUI

/// SETTINGS 設定: a menu of its own at the left, in four foldable groups, and the chosen section at the right
/// (SettingsPage.xaml). On iPhone the menu is a page and a section opens over it.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var folded: Set<String> = []
    @State private var phoneShowsSection = false

    var body: some View {
        if sizeClass == .compact {
            if phoneShowsSection {
                PageScroll { section.padding(16) }
            } else {
                PageScroll { menu.padding(16) }
            }
        } else {
            HStack(spacing: 0) {
                PageScroll { menu.padding(EdgeInsets(top: 26, leading: 12, bottom: 16, trailing: 12)) }
                    .frame(width: 220)
                    .overlay(alignment: .trailing) { Rectangle().fill(ob.ink).frame(width: 1) }
                PageScroll {
                    section
                        .padding(EdgeInsets(top: 32, leading: 40, bottom: 40, trailing: 40))
                        .frame(maxWidth: nav.place.settings.wide ? 820 : 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                Text("SETTINGS").font(Ob.mono(18, .bold))
                Spacer()
                Decor("設定")
            }
            .padding(.bottom, 10)
            ForEach(SettingsSection.groups, id: \.0) { group, sections in
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        if folded.contains(group) { folded.remove(group) } else { folded.insert(group) }
                    } label: {
                        HStack {
                            Text(group.uppercased()).font(Ob.mono(15, .bold))
                            Spacer()
                            Text(folded.contains(group) ? "+" : "−").font(Ob.mono(12)).foregroundStyle(ob.muted)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if !folded.contains(group) {
                        ForEach(sections, id: \.self) { s in
                            NavCapsule(title: s.title, size: 11.5, selected: nav.place.settings == s && sizeClass != .compact) {
                                nav.goSettings(s)
                                phoneShowsSection = true
                            }
                            .padding(.leading, 18)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var section: some View {
        let s = nav.place.settings
        VStack(alignment: .leading, spacing: 0) {
            if sizeClass == .compact {
                Button("‹ Settings") { phoneShowsSection = false }.buttonStyle(.quietSmall).padding(.bottom, 12)
            }
            PageTitle(title: s == .about ? "Oberton" : s.title, japanese: s == .about ? "倍音" : "設定",
                      readout: "Section \(s.address)" + (s == .about ? "\nAbout" : ""))
                .padding(.bottom, 14)
            switch s {
            case .general: GeneralSection()
            case .hotkeys: HotkeysSection()
            case .microphone: MicrophoneSection()
            case .history: HistorySettingsSection()
            case .models: ModelsSection()
            case .speech: SpeechSection()
            case .cloud: CloudSection()
            case .appearance: AppearanceSection()
            case .layout: LayoutSection()
            case .advanced: AdvancedSection()
            case .about: AboutSection()
            }
        }
    }
}

extension SettingsSection {
    var wide: Bool { [.models, .appearance, .layout].contains(self) }
}

// MARK: - A // Dictation

private struct GeneralSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Everything runs on this \(Device.noun). No audio or text is sent anywhere unless you allow cloud AI (Settings › Cloud AI), and there is no telemetry.")
                .padding(.bottom, 16)
            #if os(macOS)
            SwitchCard {
                ObSwitch("Put my clipboard back after inserting",
                         detail: "Oberton pastes the text at the cursor, then puts back what you had copied.", isOn: $model.settings.restoreClipboard)
            }
            #endif
            FieldLabel("Maximum length of one dictation (minutes)")
            HStack(spacing: 10) {
                Button("−") { model.settings.maxRecordingSeconds = max(60, model.settings.maxRecordingSeconds - 60) }.buttonStyle(.quiet)
                Text("\(Int(model.settings.maxRecordingSeconds / 60))").font(Ob.mono(14, .bold)).frame(width: 40)
                Button("+") { model.settings.maxRecordingSeconds = min(3600, model.settings.maxRecordingSeconds + 60) }.buttonStyle(.quiet)
            }
        }
    }
}

/// Hotkeys (HotkeysPage.xaml): click a box and press the shortcut you want; RESET puts the default back, CLEAR leaves
/// one unset. A change is registered at once, and the line under the boxes says whether macOS gave Oberton every one.
private struct HotkeysSection: View {
    @EnvironmentObject var model: AppModel
    #if os(macOS)
    @ObservedObject private var status = HotkeyStatus.shared
    @Environment(\.ob) private var ob
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(macOS)
            Caption("Click a box and press the shortcut you want. Shortcuts work in every app. Use at least one of Ctrl (⌃), Alt (⌥), Shift (⇧) or Cmd (⌘), or an F-key.")
            row("Start / stop dictation", $model.settings.hotkey, reset: ("Reset", AppSettings.defaultHotkey))
            row("Switch to next profile", $model.settings.cycleProfileHotkey, reset: ("Clear", ""))
            row("Read selected text aloud", $model.settings.speakHotkey, reset: ("Reset", AppSettings.defaultSpeakHotkey))
            Text(status.error ?? "✓ Shortcuts are registered.")
                .font(Ob.sans(13.5)).foregroundStyle(status.error == nil ? ob.ink : ob.record)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            Caption("Tip: a hotkey here is taken from every other app while Oberton runs. If one doesn't fire, or you miss what it did, pick another combination such as F9.", size: 12.5)
                .padding(.top, 16)
            Caption("Ctrl+Space is also macOS's shortcut for the previous input source. If you use more than one keyboard layout, change that one in System Settings › Keyboard › Keyboard Shortcuts › Input Sources.", size: 12.5)
                .padding(.top, 8)
            #else
            Caption("iPhone has no system-wide shortcuts. Dictate from the dashboard, or add Oberton to the Action button or Control Center in a later version.")
            #endif
        }
    }

    #if os(macOS)
    private func row(_ title: String, _ key: Binding<String>, reset: (label: String, value: String)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel(title)
            HStack(spacing: 8) {
                HotkeyBox(id: title, hotkey: key)
                Button(reset.label) { key.wrappedValue = reset.value }.buttonStyle(.quietSmall)
            }
        }
    }
    #endif
}

#if os(macOS)
/// The box a shortcut is recorded in: a hairline box showing the keys as chips (or "(none)"). Clicked, it outlines in
/// the accent and takes the next key press with Ctrl, Alt, Shift or Cmd, or an F-key; Esc or a click elsewhere stops.
private struct HotkeyBox: View {
    var id: String
    @Binding var hotkey: String
    @ObservedObject private var status = HotkeyStatus.shared
    @Environment(\.ob) private var ob
    @State private var monitor: Any?

    private var recording: Bool { status.recording == id }

    var body: some View {
        Group {
            if recording {
                Text("Press a shortcut…").font(Ob.mono(12.5)).foregroundStyle(ob.muted)
            } else if hotkey.isEmpty {
                Text("(none)").font(Ob.mono(12.5)).foregroundStyle(ob.muted)
            } else {
                KeyChips(hotkey: hotkey, size: 12.5)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(width: 240, height: 32, alignment: .leading)
        .overlay(Rectangle().strokeBorder(recording ? ob.accent : ob.divider, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { start() }
        .onDisappear { stop() }
        .onChange(of: status.recording) { if status.recording != id { removeMonitor() } }
        .accessibilityElement()
        .accessibilityLabel(hotkey.isEmpty ? "None" : hotkey)
        .accessibilityHint("Click, then press the shortcut you want")
        .accessibilityAddTraits(.isButton)
    }

    private func start() {
        guard !recording else { return }
        status.recording = id
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            guard event.type == .keyDown else { stop(); return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods: Hotkey.Modifiers = []
            if flags.contains(.control) { mods.insert(.control) }
            if flags.contains(.option) { mods.insert(.option) }
            if flags.contains(.shift) { mods.insert(.shift) }
            if flags.contains(.command) { mods.insert(.command) }
            if mods.isEmpty, event.keyCode == 0x35 { stop(); return nil } // Esc on its own: keep the shortcut
            // As on Windows, a press that can't be a shortcut (a plain letter) is swallowed and the box keeps waiting.
            if let name = Hotkey.keyName(forKeyCode: event.keyCode), let key = Hotkey(modifiers: mods, key: name), key.isAllowed {
                hotkey = key.text
                stop()
            }
            return nil
        }
    }

    private func stop() {
        removeMonitor()
        if status.recording == id { status.recording = nil }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif

private struct MicrophoneSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Audio is held in memory only while you dictate, and recognized on this \(Device.noun). Nothing is recorded to disk.")
            FieldLabel("Microphone")
            Text(defaultMic).font(Ob.sans(13.5))
            Caption("Oberton uses the input chosen in \(Device.noun == "Mac" ? "System Settings › Sound › Input" : "Control Center").", size: 12.5).padding(.top, 6)
            FieldLabel("Input level")
            LevelBar(level: model.phase == .recording ? model.level : 0).frame(width: 400, height: 10)
            Caption("Moves while you dictate.", size: 12.5).padding(.top, 6)
        }
    }

    private var defaultMic: String {
        #if os(macOS)
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default microphone"
        #else
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "iPhone microphone"
        #endif
    }
}

/// A level as a block bar.
struct LevelBar: View {
    var level: Float
    @Environment(\.ob) private var ob

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<40, id: \.self) { i in
                    Rectangle().fill(Float(i) / 40 < level ? ob.ink : ob.subtle)
                }
            }
            .frame(width: geo.size.width)
        }
    }
}

private struct HistorySettingsSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @State private var confirmClear = false
    @State private var confirmReset = false
    @State private var confirmResetTally = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SwitchCard {
                ObSwitch("Keep a history of dictations", detail: "What was heard, the AI's edit, and where it went. On this \(Device.noun) only.",
                         isOn: $model.settings.keepHistory)
            }
            FieldLabel("How long to keep")
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Text").font(Ob.sans(13.5))
                    Caption("The dictation itself: what was heard, the AI's edit, and where it went.", size: 12)
                }
                Spacer()
                ObMenu(options: [(0, "Everything (never delete)")] + [10, 25, 50, 100, 200, 500].map { ($0, "The newest \($0)") },
                       selection: $model.settings.historyLimit, width: 240)
            }
            .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
            FieldLabel("Stored in")
            Text(AppPaths.dataDir.path(percentEncoded: false)).font(Ob.mono(12)).textSelection(.enabled)
            HStack(spacing: 8) {
                #if os(macOS)
                Button("Open folder") { NSWorkspace.shared.open(AppPaths.dataDir) }.buttonStyle(.quiet)
                #endif
                Button("Delete all history…") { confirmClear = true }.buttonStyle(.quiet).disabled(model.history.isEmpty)
            }
            .padding(.top, 10)
            FieldLabel("Dashboard counts")
            Caption("The meters on the dashboard come from daily counts (numbers only, never text), so they survive History being cleared.", size: 12.5)
            Button("Reset dashboard counts…") { confirmReset = true }.buttonStyle(.quiet).padding(.top, 10)
            FieldLabel("Word tally")
            SwitchCard {
                ObSwitch("Keep a word tally for Analytics",
                         detail: "Counts of the words and phrases you dictate, the words the AI corrects and the fillers it removes, saved in words.json. Counts only, never sentences.",
                         isOn: $model.settings.keepWordTally)
            }
            Button("Reset word tally…") { confirmResetTally = true }.buttonStyle(.quiet).padding(.top, 10)
                .disabled(model.words.days.isEmpty)
        }
        .confirmationDialog("Delete every dictation in History?", isPresented: $confirmClear) {
            Button("Delete all history", role: .destructive) { model.clearHistory() }
        }
        .confirmationDialog("Reset the dashboard counts?", isPresented: $confirmReset) {
            Button("Reset counts", role: .destructive) { model.resetUsage() }
        }
        .confirmationDialog("Forget every word, phrase and correction counted for Analytics?", isPresented: $confirmResetTally) {
            Button("Reset word tally", role: .destructive) { model.resetWordTally() }
        }
    }
}

// MARK: - B // Models & AI

private struct ModelsSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Readout("Speech recognition").padding(.top, 4)
            ModelRow(name: "Apple Speech", badges: [("Active", .active), ("Installed", .plain)],
                     detail: "Apple's on-device speech recognizer. Downloads its language once, through the system.")
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

private struct SpeechSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Apple's speech recognizer, on this \(Device.noun). The first time you dictate in a language, the system downloads it once.")
            FieldLabel("Engine")
            Text("Apple Speech (SpeechAnalyzer)").font(Ob.sans(13.5))
            FieldLabel("Language")
            ObMenu(options: ["en-US", "en-GB", "en-AU", "en-IN", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR", "ja-JP", "zh-CN", "ko-KR"]
                .map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }, selection: $model.settings.language, width: 260)
            FieldLabel("Vocabulary hint")
            ObField("Kubernetes, Dr. Nguyen, Oberton", text: $model.settings.vocabularyHint).frame(maxWidth: 560)
            Caption("Names and words the recognizer should expect, separated by commas.", size: 12.5).padding(.top, 6)
        }
    }
}

private struct CloudSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @State private var anthropic = KeyStore.get(.anthropic) ?? ""
    @State private var openai = KeyStore.get(.openai) ?? ""
    @State private var saved: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SwitchCard {
                ObSwitch("Keep everything offline",
                         detail: "While on, nothing is sent to a cloud model, whatever a profile picks. Apple Intelligence and Ollama run on this \(Device.noun) and stay allowed.",
                         isOn: $model.settings.cloud.keepOffline)
            }
            FieldLabel("Anthropic (Claude)")
            keyCard(text: $anthropic, provider: .anthropic) { EmptyView() }
            FieldLabel("OpenAI or a compatible service")
            keyCard(text: $openai, provider: .openai) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Model").font(Ob.sans(13)).padding(.top, 12).padding(.bottom, 4)
                    ObField("gpt-4.1-mini", text: $model.settings.cloud.openAIModel, mono: true, width: 280)
                    Text("Service address").font(Ob.sans(13)).padding(.top, 12).padding(.bottom, 4)
                    ObField("https://api.openai.com/v1", text: $model.settings.cloud.openAIBaseURL, mono: true)
                    Caption("https://api.openai.com/v1 for OpenAI, or another service's address (OpenRouter, Groq…).", size: 12).padding(.top, 6)
                }
            }
            Caption("Keys are kept in the Keychain on this \(Device.noun), never in Oberton's settings file.").padding(.top, 16)
        }
    }

    private func keyCard<Extra: View>(text: Binding<String>, provider: ModelID.Provider, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("API key").font(Ob.sans(13)).padding(.bottom, 4)
            HStack(spacing: 8) {
                ObField("Paste your key", text: text, mono: true, secure: true)
                Button("Save key") { KeyStore.set(provider, text.wrappedValue); saved = provider.rawValue }.buttonStyle(.primary)
                Button("Remove") { KeyStore.set(provider, nil); text.wrappedValue = ""; saved = nil }.buttonStyle(.quiet)
            }
            Caption(KeyStore.get(provider) != nil ? (saved == provider.rawValue ? "Saved." : "A key is set.") : "No key set.", size: 12).padding(.top, 6)
            extra()
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
    }
}

// MARK: - C // Look & feel

private struct AppearanceSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Follows the \(Device.noun)'s appearance by default. Pick Light or Dark to override it.")
            FieldLabel("Theme")
            HStack(spacing: 8) {
                ForEach(AppTheme.allCases, id: \.self) { t in
                    ChoiceCard(chosen: model.settings.theme == t, action: { model.settings.theme = t }) {
                        VStack(alignment: .leading, spacing: 6) {
                            ThemePreview(theme: t).frame(height: 84)
                            Text(t.rawValue.uppercased()).font(Ob.mono(12, .bold))
                            Readout(t == .system ? "Follows the \(Device.noun)" : " ")
                        }
                    }
                }
            }
            FieldLabel("Accent")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(AccentChoice.allCases, id: \.self) { a in
                    ChoiceCard(chosen: model.settings.accent == a, action: { model.settings.accent = a }) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 5) {
                                swatch(Color(hex: a.hex.light), paper: Color(hex: 0xE8E7E3))
                                swatch(Color(hex: a.hex.dark), paper: Color(hex: 0x0E0E0D))
                            }
                            Text(a.title.uppercased()).font(Ob.mono(11, .bold)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                }
            }
            Caption("Oberton is ink on paper. The accent marks what is live or matters most: today's count, the word being read, words the AI added. Red is not offered: it means the microphone is recording.", size: 12.5)
                .padding(.top, 8)
            FieldLabel("Japanese words")
            SwitchCard {
                ObSwitch("Show the Japanese words beside labels",
                         detail: "Small decorative words such as 設定 (settings). They are decoration only, and hidden from screen readers.",
                         isOn: $model.settings.showJapanese)
            }
        }
    }

    private func swatch(_ c: Color, paper: Color) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(paper).frame(width: 22, height: 22)
            .overlay(Circle().fill(c).frame(width: 12, height: 12))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.gray.opacity(0.5), lineWidth: 1))
    }
}

/// A miniature of the window in a theme: a sidebar line, a title, a rule and lines of text.
private struct ThemePreview: View {
    var theme: AppTheme

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                sheet(dark: theme == .dark)
                if theme == .system { sheet(dark: true) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.gray.opacity(0.5), lineWidth: 1))
    }

    private func sheet(dark: Bool) -> some View {
        let paper = Color(hex: dark ? 0x0E0E0D : 0xE8E7E3), ink = Color(hex: dark ? 0xE8E7E3 : 0x0D0D0C)
        return HStack(spacing: 0) {
            Rectangle().fill(paper).frame(width: 18).overlay(alignment: .trailing) { Rectangle().fill(ink).frame(width: 1) }
            VStack(alignment: .leading, spacing: 4) {
                Rectangle().fill(ink).frame(width: 34, height: 5)
                Rectangle().fill(ink).frame(height: 1)
                ForEach([0.8, 0.6, 0.7], id: \.self) { w in
                    GeometryReader { g in Rectangle().fill(ink.opacity(0.35)).frame(width: g.size.width * w, height: 3) }.frame(height: 3)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(paper)
        }
    }
}

private struct LayoutSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(macOS)
            Caption("Where the dictation overlay and the Read aloud player appear, and how solid they look. Drag either one to move it until Oberton restarts.")
            FieldLabel("Dictation overlay")
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ObSwitch("Show the overlay while dictating", isOn: $model.settings.showOverlay)
                    Hairline()
                    HStack {
                        Text("Opacity").font(Ob.sans(13.5))
                        Spacer()
                        Text("\(Int((model.settings.overlayOpacity * 100).rounded()))%").font(Ob.mono(12))
                    }
                    .padding(.top, 12)
                    Slider(value: $model.settings.overlayOpacity, in: 0.3...1).padding(.bottom, 12)
                    Hairline()
                    HStack {
                        Text("Position").font(Ob.sans(13.5))
                        Spacer()
                        Text(model.settings.overlayPosition.title).font(Ob.sans(12)).foregroundStyle(ob.muted)
                    }
                    .padding(.top, 12).padding(.bottom, 8)
                    PositionPicker(position: $model.settings.overlayPosition)
                    Caption("The overlay stays dark in both themes, so it reads over any app.", size: 12).padding(.top, 10)
                }
                .padding(EdgeInsets(top: 6, leading: 18, bottom: 16, trailing: 18))
                .frame(maxWidth: .infinity)
                Hairline(vertical: true)
                preview.frame(maxWidth: .infinity, minHeight: 200)
            }
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
            #else
            Caption("On iPhone the dictation pill appears at the bottom of Oberton's own screen.")
            #endif
        }
    }

    /// A live preview: placeholder lines of an app, and the pill at the slider's opacity.
    private var preview: some View {
        ZStack(alignment: model.settings.overlayPosition.alignment) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach([0.9, 0.7, 0.8, 0.5], id: \.self) { w in
                    GeometryReader { g in Rectangle().fill(ob.divider).frame(width: g.size.width * w, height: 6) }.frame(height: 6)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 10) {
                Circle().fill(Color(hex: 0xFF4636)).frame(width: 8, height: 8)
                Text("0:07").font(Ob.mono(12)).foregroundStyle(Color(hex: 0xE8E7E3))
                Text(model.activeProfile.name.uppercased()).font(Ob.mono(11)).foregroundStyle(Color(hex: 0xE8E7E3, alpha: 0.72)).lineLimit(1)
            }
            .padding(.horizontal, 16).frame(height: 40)
            .background(Capsule().fill(Color(hex: 0x0D0D0C, alpha: model.settings.overlayOpacity)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .padding(12)
        }
        .background(ob.subtle)
    }
}

// MARK: - D // App

private struct AdvancedSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel("Locations")
            Text(AppPaths.dataDir.path(percentEncoded: false)).font(Ob.mono(12)).textSelection(.enabled)
            Caption("settings.json, profiles.json, history.json and usage.json.", size: 12.5).padding(.top, 6)
            #if os(macOS)
            Button("Open data folder") { NSWorkspace.shared.open(AppPaths.dataDir) }.buttonStyle(.quiet).padding(.top, 10)
            #endif
            FieldLabel("Privacy")
            Caption("Speech is recognized on this \(Device.noun), and Apple Intelligence edits it here too. Nothing is sent anywhere unless a profile picks a cloud model and “Keep everything offline” is off. History and the daily counts stay in the folder above; the counts are numbers only, never text.")
        }
    }
}

private struct AboutSection: View {
    @Environment(\.ob) private var ob

    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        VStack(alignment: .leading, spacing: 0) {
            Text("Oberton \(version) for \(Device.noun)").font(Ob.mono(13, .bold))
            Caption("Local, private dictation and read aloud.").padding(.top, 4)
            Hairline().padding(.vertical, 16)
            part("D.2.1", "What it is", "概要",
                 "The name is German for overtone: the AI adds a layer of polish on top of your own voice. You speak, Oberton writes it down and tidies it up, and the text goes where your cursor was.")
            part("D.2.2", "How it works", "口述", nil) {
                steps([("01 Listen", "The microphone, while you hold the floor."), ("02 Transcribe", "Apple Speech, on this \(Device.noun)."),
                       ("03 Tidy up", "Your profile's AI: Apple Intelligence by default."), ("04 Insert", Device.noun == "Mac" ? "Pasted at the cursor." : "Copied, ready to paste.")])
            }
            part("D.2.3", "What it keeps", "履歴", nil) {
                VStack(alignment: .leading, spacing: 0) {
                    keep("History", "Your recent dictations: what was heard, the AI's edit, what went in, and the app.")
                    keep("Daily counts", "Numbers only: words, dictations, turnaround. Never text.")
                    keep("Settings", "Profiles and settings. API keys are in the Keychain.")
                }
            }
            part("D.2.4", "Design language", "計器",
                 "Oberton is drawn like a printed instrument panel: black ink on gray paper, 1px lines, capitalized monospaced labels and readouts, rings of dots for numbers. Dark mode is the same sheet inverted. Color is a signal: the accent marks what is live or matters most, and red means the microphone is recording, nowhere else.") {
                glossary
            }
        }
    }

    private func part<Extra: View>(_ address: String, _ title: String, _ jp: String, _ body: String?, @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Readout(address).frame(width: 64, alignment: .leading).padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(title.uppercased()).font(Ob.mono(12, .bold))
                        Spacer()
                        Decor(jp)
                    }
                    if let body { Text(body).font(Ob.sans(14)).lineSpacing(8).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true) }
                    extra()
                }
            }
            Hairline().padding(.vertical, 16)
        }
    }

    private func steps(_ s: [(String, String)]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(s.enumerated()), id: \.offset) { i, step in
                if i > 0 { Hairline(vertical: true) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.0.uppercased()).font(Ob.mono(11, .bold))
                    Text(step.1).font(Ob.sans(12.5)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .overlay(Rectangle().strokeBorder(ob.ink, lineWidth: 1))
    }

    private func keep(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Readout(k).frame(width: 150, alignment: .leading)
            Text(v).font(Ob.sans(13)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private var glossary: some View {
        let words: [(String, String, String, String)] = [
            ("倍音", "baion", "overtone", "Sidebar, About"), ("計器", "keiki", "instrument", "Dashboard"),
            ("口述", "kōjutsu", "dictation", "Speech to text"), ("読上", "yomiage", "reading aloud", "Read aloud"),
            ("履歴", "rireki", "history", "History"), ("設定", "settei", "settings", "Settings"), ("概要", "gaiyō", "overview", "This page"),
            ("録音", "rokuon", "recording", "Overlay while recording"), ("処理中", "shorichū", "processing", "Overlay while processing"),
            ("挿入", "sōnyū", "insertion", "Overlay after inserting"), ("記録", "kiroku", "record", "Notepad"),
        ]
        return VStack(spacing: 0) {
            HStack { Readout("Word").frame(width: 70, alignment: .leading); Readout("Reading").frame(width: 90, alignment: .leading)
                Readout("English").frame(width: 120, alignment: .leading); Readout("Where you see it"); Spacer() }
                .padding(.vertical, 6)
            ForEach(words, id: \.0) { w in
                Hairline()
                HStack {
                    Text(w.0).font(Ob.jp(16, .bold)).frame(width: 70, alignment: .leading)
                    Text(w.1).font(Ob.sans(13).italic()).foregroundStyle(ob.muted).frame(width: 90, alignment: .leading)
                    Text(w.2).font(Ob.mono(12)).frame(width: 120, alignment: .leading)
                    Readout(w.3)
                    Spacer()
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.top, 8)
    }
}

