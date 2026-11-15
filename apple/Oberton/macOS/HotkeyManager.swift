#if os(macOS)
import Carbon.HIToolbox
import Foundation
import ObertonCore

/// What the Hotkeys settings page shows: whether every shortcut is held (App.HotkeyError on Windows), and which box is
/// recording. The shortcuts stay held meanwhile, as on Windows: pressing one that is in use does what it does there.
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
    /// The combinations `register` holds, so the marker key can't take one of them a second time.
    private var held: [Hotkey] = []
    /// The Extended Notes marker key, held only while a session records (App.ApplyMarkerHotkey), apart from the others.
    private var markerRef: EventHotKeyRef?
    private var markerAction: (() -> Void)?
    private static let markerID: UInt32 = 1001
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
            DispatchQueue.main.async {
                switch id.id {
                case HotkeyManager.escapeID: me.escapeAction?()
                case HotkeyManager.markerID: me.markerAction?()
                default: me.actions[id.id]?()
                }
            }
            return noErr
        }, 1, &spec, me, &handler)
    }

    /// Replace the dictation, profile and Read aloud hotkeys: (shortcut, action); an empty shortcut is intentionally
    /// unset. Returns a user-readable error for each one that couldn't be registered, as on Windows.
    @discardableResult
    func register(_ bindings: [(text: String, action: () -> Void)]) -> [String] {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        held = []
        var errors: [String] = []
        for (i, b) in bindings.enumerated() where !Self.isUnset(b.text) {
            let id = EventHotKeyID(signature: OSType(0x4F42_5254), id: UInt32(i + 1)) // 'OBRT'
            switch take(b.text, id: id) {
            case .success(let (ref, hotkey)):
                refs.append(ref)
                held.append(hotkey)
                actions[UInt32(i + 1)] = b.action
            case .failure(let error):
                errors.append(error.message)
            }
        }
        return errors
    }

    /// Take the Extended Notes marker key (`text`), or let it go (nil). Returns the error, if any.
    @discardableResult
    func holdMarker(_ text: String?, _ action: (() -> Void)? = nil) -> String? {
        if let markerRef { UnregisterEventHotKey(markerRef) }
        markerRef = nil
        markerAction = nil
        guard let text, !Self.isUnset(text) else { return nil }
        switch take(text, id: EventHotKeyID(signature: OSType(0x4F42_5254), id: Self.markerID)) {
        case .success(let (ref, _)):
            markerRef = ref
            markerAction = action
            return nil
        case .failure(let error):
            return error.message
        }
    }

    /// Blank (or only white space) is intentionally unset (string.IsNullOrWhiteSpace).
    private static func isUnset(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private struct Refused: Error { var message: String }

    /// RegisterHotKey: exclusive, so a combination another app holds is refused rather than shared. A combination
    /// Oberton holds already is refused the same way (Windows' second RegisterHotKey fails with 1409).
    private func take(_ text: String, id: EventHotKeyID) -> Result<(EventHotKeyRef, Hotkey), Refused> {
        guard let hotkey = Hotkey(text) else { return .failure(Refused(message: "'\(text)' isn't a valid shortcut.")) }
        if held.contains(hotkey) { return .failure(Refused(message: Self.taken(text))) }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        if status == noErr, let ref { return .success((ref, hotkey)) }
        if status == eventHotKeyExistsErr { return .failure(Refused(message: Self.taken(text))) }
        if hotkey.isOptionOnly {
            return .failure(Refused(message: "macOS doesn't allow \(text): a shortcut with only Alt (Option), or Alt and Shift, isn't allowed. Add Ctrl or Cmd."))
        }
        return .failure(Refused(message: "macOS refused the shortcut \(text) (error \(status))."))
    }

    private static func taken(_ text: String) -> String {
        "\(text) is already used by another application. Choose a different shortcut under Settings > Hotkeys."
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
        // Exclusive, as every hotkey on Windows: Escape held by another app is refused, with Windows' texts.
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4F42_5254), id: Self.escapeID)
        let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else {
            return status == eventHotKeyExistsErr ? Self.taken("Escape") : "macOS refused the shortcut Escape (error \(status))."
        }
        escapeRef = ref
        return nil
    }

    /// The marker key must differ from the other shortcuts (App.MarkerClash); registering it second would only say
    /// "used by another application".
    static func markerClash(marker: String, dictation: String, speak: String, cycle: String) -> String? {
        guard !isUnset(marker) else { return nil }
        // Windows' Same: the text without spaces, any case ("Alt+Ctrl+M" isn't "Ctrl+Alt+M" here; registering it then
        // fails as taken).
        func same(_ a: String, _ b: String) -> Bool {
            a.replacingOccurrences(of: " ", with: "").caseInsensitiveCompare(b.replacingOccurrences(of: " ", with: "")) == .orderedSame
        }
        let other = same(marker, dictation) ? "the dictation shortcut" : same(marker, speak) ? "the Read aloud shortcut"
            : same(marker, cycle) ? "the profile-switching shortcut" : nil
        return other.map { "\(marker) is already \($0). Choose a different marker shortcut under Settings > Hotkeys." }
    }

    /// Whether one of macOS's own keyboard shortcuts that is turned on (System Settings › Keyboard › Keyboard
    /// Shortcuts) is this combination; macOS then acts on it first. Ctrl+Space is "Select the previous input source".
    static func systemShortcutTaken(_ text: String) -> Bool {
        guard let hotkey = Hotkey(text) else { return false }
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let all = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        return all.contains { entry in
            (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (entry[kHISymbolicHotKeyCode as String] as? Int).map(UInt32.init) == hotkey.keyCode
                && ((entry[kHISymbolicHotKeyModifiers as String] as? Int).map(UInt32.init) ?? 0) & mask == hotkey.carbonModifiers
        }
    }
}
#endif
