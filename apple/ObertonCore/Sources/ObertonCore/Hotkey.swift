import Foundation

/// A shortcut as the settings store it, in the Windows app's words: "Ctrl+D", "Ctrl+Alt+D", "Ctrl+Space", "F9", with
/// WPF's key names ("Ctrl+D1", "Ctrl+OemMinus", "Ctrl+Back"), as HotkeyManager.Format writes them.
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

    /// Reads "Ctrl+Alt+D" (any case, spaces allowed), with WPF's key names or the characters themselves ("Ctrl+1",
    /// "Ctrl+-", as earlier Mac versions stored them). Nil when a part isn't a modifier or a known key, or there is no key.
    public init?(_ text: String) {
        var mods: Modifiers = []
        var key: String?
        // "Ctrl++" (an earlier Mac's plus key) splits into empty parts: read it as the plus key.
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if parts.count >= 2, parts.suffix(2) == ["", ""] { parts.removeLast(2); parts.append("=") }
        for part in parts where !part.isEmpty {
            switch part {
            case "ctrl", "control": mods.insert(.control)
            case "alt", "option", "opt": mods.insert(.option)
            case "shift": mods.insert(.shift)
            case "cmd", "command", "win", "windows": mods.insert(.command)
            default:
                guard key == nil else { return nil } // two keys
                key = Self.aliases[part] ?? part
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

    /// Carbon's modifier bits (controlKey, optionKey, shiftKey, cmdKey), as RegisterEventHotKey and the system's own
    /// shortcuts (CopySymbolicHotKeys) write them.
    public var carbonModifiers: UInt32 {
        var mods: UInt32 = 0
        if modifiers.contains(.control) { mods |= 0x1000 }
        if modifiers.contains(.option) { mods |= 0x0800 }
        if modifiers.contains(.shift) { mods |= 0x0200 }
        if modifiers.contains(.command) { mods |= 0x0100 }
        return mods
    }

    /// The key for a Mac virtual key code, from a key press; nil for keys a shortcut can't use (modifiers, Fn, …).
    public static func keyName(forKeyCode code: UInt16) -> String? { keys.first { $0.code == UInt32(code) }?.name }

    /// Two stored shortcuts are the same combination ("ctrl+d" is "Ctrl+D").
    public static func same(_ a: String, _ b: String) -> Bool {
        guard let a = Hotkey(a), let b = Hotkey(b) else { return false }
        return a == b
    }

    /// Every key a shortcut can use, by WPF's name (System.Windows.Input.Key, as Windows stores it), with its Mac virtual
    /// key code (Carbon's kVK_ANSI_* and kVK_* constants). The first entry for a code is the one a key press records.
    /// A Mac has no F21–F24, PrintScreen or Pause; Help sits where Insert is.
    public static let keys: [(name: String, code: UInt32)] = [
        ("A", 0x00), ("B", 0x0B), ("C", 0x08), ("D", 0x02), ("E", 0x0E), ("F", 0x03), ("G", 0x05), ("H", 0x04), ("I", 0x22),
        ("J", 0x26), ("K", 0x28), ("L", 0x25), ("M", 0x2E), ("N", 0x2D), ("O", 0x1F), ("P", 0x23), ("Q", 0x0C), ("R", 0x0F),
        ("S", 0x01), ("T", 0x11), ("U", 0x20), ("V", 0x09), ("W", 0x0D), ("X", 0x07), ("Y", 0x10), ("Z", 0x06),
        ("D0", 0x1D), ("D1", 0x12), ("D2", 0x13), ("D3", 0x14), ("D4", 0x15), ("D5", 0x17), ("D6", 0x16), ("D7", 0x1A), ("D8", 0x1C),
        ("D9", 0x19),
        ("F1", 0x7A), ("F2", 0x78), ("F3", 0x63), ("F4", 0x76), ("F5", 0x60), ("F6", 0x61), ("F7", 0x62), ("F8", 0x64), ("F9", 0x65),
        ("F10", 0x6D), ("F11", 0x67), ("F12", 0x6F), ("F13", 0x69), ("F14", 0x6B), ("F15", 0x71), ("F16", 0x6A), ("F17", 0x40),
        ("F18", 0x4F), ("F19", 0x50), ("F20", 0x5A),
        ("Space", 0x31), ("Return", 0x24), ("Tab", 0x30), ("Back", 0x33), ("Delete", 0x75), ("Escape", 0x35), ("Insert", 0x72),
        ("Home", 0x73), ("End", 0x77), ("PageUp", 0x74), ("PageDown", 0x79), ("Left", 0x7B), ("Right", 0x7C), ("Down", 0x7D), ("Up", 0x7E),
        ("OemMinus", 0x1B), ("OemPlus", 0x18), ("OemOpenBrackets", 0x21), ("OemCloseBrackets", 0x1E), ("OemSemicolon", 0x29),
        ("OemQuotes", 0x27), ("OemComma", 0x2B), ("OemPeriod", 0x2F), ("OemQuestion", 0x2C), ("OemPipe", 0x2A), ("OemTilde", 0x32),
        ("OemBackslash", 0x0A),
        ("NumPad0", 0x52), ("NumPad1", 0x53), ("NumPad2", 0x54), ("NumPad3", 0x55), ("NumPad4", 0x56), ("NumPad5", 0x57),
        ("NumPad6", 0x58), ("NumPad7", 0x59), ("NumPad8", 0x5B), ("NumPad9", 0x5C), ("Multiply", 0x43), ("Add", 0x45),
        ("Subtract", 0x4E), ("Divide", 0x4B), ("Decimal", 0x41), ("Clear", 0x47), ("Return", 0x4C),
    ]

    /// Other spellings: WPF's aliases (Oem1…, Enter, Prior, Next), and the characters and words earlier Mac versions stored.
    static let aliases: [String: String] = [
        "enter": "Return", "backspace": "Back", "esc": "Escape", "help": "Insert", "prior": "PageUp", "next": "PageDown",
        "pgup": "PageUp", "pgdn": "PageDown", "oem1": "OemSemicolon", "oem2": "OemQuestion", "oem3": "OemTilde",
        "oem4": "OemOpenBrackets", "oem5": "OemPipe", "oem6": "OemCloseBrackets", "oem7": "OemQuotes", "oem102": "OemBackslash",
        "0": "D0", "1": "D1", "2": "D2", "3": "D3", "4": "D4", "5": "D5", "6": "D6", "7": "D7", "8": "D8", "9": "D9",
        "-": "OemMinus", "=": "OemPlus", "[": "OemOpenBrackets", "]": "OemCloseBrackets", ";": "OemSemicolon", "'": "OemQuotes",
        ",": "OemComma", ".": "OemPeriod", "/": "OemQuestion", "\\": "OemPipe", "`": "OemTilde",
    ]
}
