import Foundation

/// A shortcut as the settings store it, in the Windows app's words: "Ctrl+D", "Ctrl+Alt+D", "Ctrl+Space", "F9".
/// On the Mac, Ctrl is Control (⌃), Alt is Option (⌥), Shift is Shift (⇧) and Cmd (or Win) is Command (⌘).
public struct Hotkey: Equatable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var modifiers: Modifiers
    /// The key's name as `keys` spells it ("D", "Space", "F9").
    public var key: String

    public init?(modifiers: Modifiers, key: String) {
        guard let name = Self.keys.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame })?.name else { return nil }
        self.modifiers = modifiers
        self.key = name
    }

    /// Reads "Ctrl+Alt+D" (any case, spaces allowed). Nil when a part isn't a modifier or a known key, or there is no key.
    public init?(_ text: String) {
        var mods: Modifiers = []
        var key: String?
        for part in text.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch part {
            case "ctrl", "control": mods.insert(.control)
            case "alt", "option", "opt": mods.insert(.option)
            case "shift": mods.insert(.shift)
            case "cmd", "command", "win", "windows": mods.insert(.command)
            default:
                guard key == nil else { return nil } // two keys
                key = ["enter": "Return", "backspace": "Delete", "back": "Delete", "esc": "Escape"][part] ?? part
            }
        }
        guard let key else { return nil }
        self.init(modifiers: mods, key: key)
    }

    /// As stored and shown, modifiers in the Windows order: "Ctrl+Alt+Shift+Cmd+D".
    public var text: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    public var isFunctionKey: Bool { key.count > 1 && key.hasPrefix("F") && Int(key.dropFirst()) != nil }

    /// As on Windows: a shortcut needs at least one of Ctrl, Alt, Shift or Cmd, or is an F-key on its own.
    public var isAllowed: Bool { !modifiers.isEmpty || isFunctionKey }

    /// macOS refuses system-wide shortcuts whose only modifiers are Option, or Option and Shift.
    public var isOptionOnly: Bool { modifiers == [.option] || modifiers == [.option, .shift] }

    /// The Mac's virtual key code (kVK_*) for `key`.
    public var keyCode: UInt32 { Self.keys.first { $0.name == key }!.code }

    /// The key for a Mac virtual key code, from a key press; nil for keys a shortcut can't use (modifiers, Fn, …).
    public static func keyName(forKeyCode code: UInt16) -> String? { keys.first { $0.code == UInt32(code) }?.name }

    /// Two stored shortcuts are the same combination ("ctrl+d" is "Ctrl+D").
    public static func same(_ a: String, _ b: String) -> Bool {
        guard let a = Hotkey(a), let b = Hotkey(b) else { return false }
        return a == b
    }

    /// Every key a shortcut can use, with its Mac virtual key code (Carbon's kVK_ANSI_* and kVK_* constants).
    public static let keys: [(name: String, code: UInt32)] = [
        ("A", 0x00), ("B", 0x0B), ("C", 0x08), ("D", 0x02), ("E", 0x0E), ("F", 0x03), ("G", 0x05), ("H", 0x04), ("I", 0x22),
        ("J", 0x26), ("K", 0x28), ("L", 0x25), ("M", 0x2E), ("N", 0x2D), ("O", 0x1F), ("P", 0x23), ("Q", 0x0C), ("R", 0x0F),
        ("S", 0x01), ("T", 0x11), ("U", 0x20), ("V", 0x09), ("W", 0x0D), ("X", 0x07), ("Y", 0x10), ("Z", 0x06),
        ("0", 0x1D), ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15), ("5", 0x17), ("6", 0x16), ("7", 0x1A), ("8", 0x1C), ("9", 0x19),
        ("F1", 0x7A), ("F2", 0x78), ("F3", 0x63), ("F4", 0x76), ("F5", 0x60), ("F6", 0x61), ("F7", 0x62), ("F8", 0x64), ("F9", 0x65),
        ("F10", 0x6D), ("F11", 0x67), ("F12", 0x6F), ("F13", 0x69), ("F14", 0x6B), ("F15", 0x71), ("F16", 0x6A), ("F17", 0x40),
        ("F18", 0x4F), ("F19", 0x50), ("F20", 0x5A),
        ("Space", 0x31), ("Return", 0x24), ("Tab", 0x30), ("Delete", 0x33), ("Escape", 0x35),
        ("Home", 0x73), ("End", 0x77), ("PageUp", 0x74), ("PageDown", 0x79), ("Left", 0x7B), ("Right", 0x7C), ("Down", 0x7D), ("Up", 0x7E),
        ("-", 0x1B), ("=", 0x18), ("[", 0x21), ("]", 0x1E), (";", 0x29), ("'", 0x27), (",", 0x2B), (".", 0x2F), ("/", 0x2C),
        ("\\", 0x2A), ("`", 0x32),
    ]
}
