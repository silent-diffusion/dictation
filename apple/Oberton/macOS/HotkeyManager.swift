#if os(macOS)
import Carbon.HIToolbox
import Foundation
import ObertonCore

/// What the Hotkeys settings page shows: whether every shortcut is held (App.HotkeyError on Windows), and which one is
/// being recorded. While one is recorded the shortcuts are let go, so pressing the current one reaches the box.
@MainActor
final class HotkeyStatus: ObservableObject {
    static let shared = HotkeyStatus()
    @Published var error: String?
    @Published var recording: String?
}

/// System-wide hotkeys through Carbon's RegisterEventHotKey: no Accessibility permission needed, and allowed in the
/// App Sandbox. Hotkeys are written as on Windows ("Ctrl+D", "Ctrl+Alt+D"); Cmd is accepted too (see `Hotkey`).
final class HotkeyManager {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    /// Escape, held only while the overlay waits for a decision (preview, no place to paste); apart from the others, so
    /// re-registering them leaves it alone.
    private var escapeRef: EventHotKeyRef?
    private var escapeAction: (() -> Void)?
    private static let escapeID: UInt32 = 1000

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<HotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { id.id == HotkeyManager.escapeID ? me.escapeAction?() : me.actions[id.id]?() }
            return noErr
        }, 1, &spec, me, &handler)
    }

    /// Replace every hotkey: (shortcut, what it is for, action); an empty shortcut is intentionally unset. Returns a
    /// user-readable error for each one that couldn't be registered, as on Windows.
    @discardableResult
    func register(_ bindings: [(text: String, role: String, action: () -> Void)]) -> [String] {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        var errors: [String] = []
        for (i, b) in bindings.enumerated() where !b.text.isEmpty {
            guard let hotkey = Hotkey(b.text) else { errors.append("'\(b.text)' isn't a valid shortcut."); continue }
            if let earlier = bindings[..<i].first(where: { Hotkey.same($0.text, b.text) }) {
                errors.append("\(b.text) is already \(earlier.role). Choose a different shortcut under Settings › Hotkeys.")
                continue
            }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4F42_5254), id: UInt32(i + 1)) // 'OBRT'
            // Exclusive, so a combination another app holds is refused rather than shared, as RegisterHotKey on Windows.
            let status = RegisterEventHotKey(hotkey.keyCode, Self.carbonModifiers(hotkey.modifiers), id, GetApplicationEventTarget(),
                                             OptionBits(kEventHotKeyExclusive), &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[UInt32(i + 1)] = b.action
            } else if status == eventHotKeyExistsErr {
                errors.append("\(b.text) is already used by another app. Choose a different shortcut under Settings › Hotkeys.")
            } else if hotkey.isOptionOnly {
                errors.append("macOS doesn't allow \(b.text): a shortcut with only Alt (Option), or Alt and Shift, isn't allowed. Add Ctrl or Cmd.")
            } else {
                errors.append("macOS refused the shortcut \(b.text) (error \(status)).")
            }
        }
        return errors
    }

    /// Take Escape system-wide while `action` is set (App.xaml.cs registers it only in Confirming and Placing, so the
    /// rest of the time Esc stays with the app in front); nil lets it go. Returns an error to log, if any.
    @discardableResult
    func holdEscape(_ action: (() -> Void)?) -> String? {
        escapeAction = action
        if action == nil {
            if let escapeRef { UnregisterEventHotKey(escapeRef) }
            escapeRef = nil
            return nil
        }
        guard escapeRef == nil else { return nil }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4F42_5254), id: Self.escapeID)
        let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return "macOS refused Escape as a shortcut (error \(status))." }
        escapeRef = ref
        return nil
    }

    private static func carbonModifiers(_ m: Hotkey.Modifiers) -> UInt32 {
        var mods: UInt32 = 0
        if m.contains(.control) { mods |= UInt32(controlKey) }
        if m.contains(.option) { mods |= UInt32(optionKey) }
        if m.contains(.shift) { mods |= UInt32(shiftKey) }
        if m.contains(.command) { mods |= UInt32(cmdKey) }
        return mods
    }
}
#endif
