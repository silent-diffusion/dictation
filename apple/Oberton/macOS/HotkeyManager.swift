#if os(macOS)
import Carbon.HIToolbox
import Foundation

/// System-wide hotkeys through Carbon's RegisterEventHotKey: no Accessibility permission needed, and allowed in the
/// App Sandbox. Hotkeys are written as on Windows ("Ctrl+D", "Ctrl+Alt+D"); Cmd is accepted too.
final class HotkeyManager {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<HotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { me.actions[id.id]?() }
            return noErr
        }, 1, &spec, me, &handler)
    }

    /// Replace every hotkey. Returns the ones that couldn't be registered (taken by another app, or not understood).
    @discardableResult
    func register(_ bindings: [(String, () -> Void)]) -> [String] {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        var failed: [String] = []
        for (i, (text, action)) in bindings.enumerated() where !text.isEmpty {
            guard let (key, mods) = Self.parse(text) else { failed.append(text); continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4F42_5254), id: UInt32(i + 1)) // 'OBRT'
            if RegisterEventHotKey(key, mods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                actions[UInt32(i + 1)] = action
            } else {
                failed.append(text)
            }
        }
        return failed
    }

    static func parse(_ text: String) -> (UInt32, UInt32)? {
        var mods: UInt32 = 0
        var key: UInt32?
        for part in text.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch part {
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "alt", "option", "opt": mods |= UInt32(optionKey)
            case "shift": mods |= UInt32(shiftKey)
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "space": key = UInt32(kVK_Space)
            default:
                guard part.count == 1, let k = letters[part] else { return nil }
                key = k
            }
        }
        return key.map { ($0, mods) }
    }

    private static let letters: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C), "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E),
        "f": UInt32(kVK_ANSI_F), "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I), "j": UInt32(kVK_ANSI_J),
        "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L), "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
        "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R), "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T),
        "u": UInt32(kVK_ANSI_U), "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X), "y": UInt32(kVK_ANSI_Y),
        "z": UInt32(kVK_ANSI_Z), "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
        "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5), "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
        "9": UInt32(kVK_ANSI_9),
    ]
}
#endif
