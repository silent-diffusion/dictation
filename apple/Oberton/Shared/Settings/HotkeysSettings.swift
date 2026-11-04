import ObertonCore
import SwiftUI

/// Hotkeys (HotkeysPage.xaml): click a box and press the shortcut you want; RESET puts the default back, CLEAR leaves
/// one unset. A change is registered at once, and the line under the boxes says whether macOS gave Oberton every one.
struct HotkeysSection: View {
    @EnvironmentObject var model: AppModel
    #if os(macOS)
    @ObservedObject private var status = HotkeyStatus.shared
    @Environment(\.ob) private var ob
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(macOS)
            Caption("Click a box and press the shortcut you want. Shortcuts work in every application. Use at least one of Ctrl, Alt, Shift or Cmd (or an F-key).")
            // The start/stop box shows its text as it is, blank included (no "(none)"), as on Windows.
            row("Start / stop dictation", $model.settings.hotkey, reset: ("Reset", AppSettings.defaultHotkey), none: "")
            row("Switch to next profile", $model.settings.cycleProfileHotkey, reset: ("Clear", ""))
            row("Read selected text aloud", $model.settings.speakHotkey, reset: ("Reset", AppSettings.defaultSpeakHotkey))
            row("Extended notes marker", $model.settings.notesMarkerHotkey, reset: ("Clear", ""))
            Caption("Drops a time marker (⚑ h:mm:ss) into the transcript while an extended notes session records, from whatever application you are in. The key is only taken while a session records; the rest of the time it stays with the application that uses it.", bottom: 0)
                .padding(.top, 6)
            // The error is drawn in Ob.Error, which is the accent (red only ever means recording).
            Text(status.error ?? "✓ Shortcuts are registered.")
                .font(Ob.sans(Ob.body)).foregroundStyle(status.error == nil ? ob.ink : ob.accent)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            SystemShortcutClash(top: 12)
            Caption("Tip: a hotkey here is taken from every other app while Oberton runs (Ctrl+D then no longer bookmarks a page in a browser, and Ctrl+Space no longer switches input methods). If one doesn't fire, or you miss what it did, pick another combination such as F9.", bottom: 0)
                .padding(.top, 16)
            #else
            Caption("iPhone has no system-wide shortcuts. Dictate from the dashboard, or add Oberton to the Action button or Control Center in a later version.")
            #endif
        }
    }

    #if os(macOS)
    private func row(_ title: String, _ key: Binding<String>, reset: (label: String, value: String), none: String = "(none)") -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel(title)
            HStack(spacing: 8) {
                HotkeyBox(id: title, hotkey: key, none: none)
                Button(reset.label) { key.wrappedValue = reset.value }.buttonStyle(.quietNarrow)
            }
        }
    }
    #endif
}

#if os(macOS)
/// One of Oberton's shortcuts is also a macOS shortcut that is turned on (Ctrl+Space selects the previous input source),
/// so macOS may act on it first. Says so, with a one-click alternative for Read aloud; nothing changes by itself.
/// Shown under Settings › Hotkeys and in the first-run setup.
struct SystemShortcutClash: View {
    /// Space above it, only while there is something to say.
    var top: CGFloat = 0
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @State private var taken: [String] = []
    private let recheck = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Read aloud's alternatives to Ctrl+Space, first free one wins.
    static let alternatives = ["Ctrl+Shift+Space", "Ctrl+Alt+Shift+Space", "F9"]

    private var keys: [String] {
        [model.settings.hotkey, model.settings.cycleProfileHotkey, model.settings.speakHotkey, model.settings.notesMarkerHotkey]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(taken, id: \.self) { key in
                Text(message(key)).font(Ob.sans(Ob.body)).foregroundStyle(ob.accent).fixedSize(horizontal: false, vertical: true)
                if Hotkey.same(key, model.settings.speakHotkey), let other = alternative {
                    Button("Use \(other) for Read aloud") { model.settings.speakHotkey = other }.buttonStyle(.quietNarrow)
                }
            }
        }
        .padding(.top, taken.isEmpty ? 0 : top)
        .onAppear(perform: check)
        .onChange(of: keys) { check() }
        .onReceive(recheck) { _ in check() }
    }

    private func check() {
        let now = keys.filter { !$0.isEmpty && HotkeyManager.systemShortcutTaken($0) }
        if now != taken { taken = now }
    }

    private var alternative: String? {
        Self.alternatives.first { a in !keys.contains { Hotkey.same($0, a) } && !HotkeyManager.systemShortcutTaken(a) }
    }

    private func message(_ key: String) -> String {
        if Hotkey.same(key, "Ctrl+Space") {
            return "\(key) is also macOS's shortcut for “Select the previous input source”, and it is turned on, so pressing it may switch your keyboard layout instead. Turn it off in System Settings › Keyboard › Keyboard Shortcuts › Input Sources, or use another shortcut."
        }
        return "\(key) is also one of macOS's own shortcuts, and it is turned on, so macOS may act on it instead of Oberton. Turn it off in System Settings › Keyboard › Keyboard Shortcuts, or choose another shortcut here."
    }
}

/// The box a shortcut is recorded in (a read-only Fluent TextBox, 240 wide, 8,6 inside, rounded 4, with an ink line along
/// the bottom while it has the focus): the shortcut as text, or "(none)". Clicked, it takes every key press with Ctrl,
/// Alt, Shift or Cmd, or an F-key, each one replacing the last, until a click elsewhere; other keys (Esc, Tab, a plain
/// letter) are swallowed. A shortcut Oberton holds does what it does instead of reaching the box, as on Windows.
private struct HotkeyBox: View {
    var id: String
    @Binding var hotkey: String
    var none: String
    @ObservedObject private var status = HotkeyStatus.shared
    @Environment(\.ob) private var ob
    @State private var monitor: Any?

    private var recording: Bool { status.recording == id }

    var body: some View {
        Text(hotkey.isEmpty ? (none.isEmpty ? " " : none) : hotkey)
            .font(Ob.sans(Ob.body)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(width: 240, alignment: .leading)
            // Fluent's ControlFillColorDefault: a little lighter than the page (white 70% / 6%).
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(ob.dark ? 0.06 : 0.7)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ob.divider, lineWidth: 1))
            .overlay(alignment: .bottom) {
                Rectangle().fill(recording ? ob.ink : ob.muted).frame(height: recording ? 2 : 1).padding(.horizontal, 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
            // As on Windows, a press that can't be a shortcut (a plain letter, Esc, Tab) is swallowed and the box keeps
            // recording; a shortcut is saved at once and the box keeps recording too (it keeps the focus).
            if let name = Hotkey.keyName(forKeyCode: event.keyCode), let key = Hotkey(modifiers: mods, key: name), key.isAllowed {
                hotkey = key.text
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
