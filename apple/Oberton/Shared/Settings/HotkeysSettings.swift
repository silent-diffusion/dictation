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
            Caption("Click a box and press the shortcut you want. Shortcuts work in every app. Use at least one of Ctrl (⌃), Alt (⌥), Shift (⇧) or Cmd (⌘), or an F-key.")
            row("Start / stop dictation", $model.settings.hotkey, reset: ("Reset", AppSettings.defaultHotkey))
            row("Switch to next profile", $model.settings.cycleProfileHotkey, reset: ("Clear", ""))
            row("Read selected text aloud", $model.settings.speakHotkey, reset: ("Reset", AppSettings.defaultSpeakHotkey))
            row("Extended notes marker", $model.settings.notesMarkerHotkey, reset: ("Clear", ""))
            Caption("Drops a time marker (⚑ m:ss) into the transcript while an extended notes session records, from whatever app you are in. The key is only taken while a session records; the rest of the time it stays with the app that uses it.", size: 12.5)
                .padding(.top, 6)
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
