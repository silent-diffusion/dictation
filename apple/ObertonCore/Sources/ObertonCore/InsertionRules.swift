import Foundation

/// The Mac inserter's rules that need no AppKit (Windows' `TextInserter`, `PasteSpot.IsNowhere` and `SelectionReader`),
/// kept here so they can be tested.
public enum InsertionRules {
    // MARK: Nowhere to type (Windows PasteSpot.IsNowhere)

    /// The app in front when a dictation starts, as far as the "nowhere to type" check needs it.
    public enum FrontApp: Sendable {
        /// No app at all (Windows: no window, `IntPtr.Zero`).
        case none
        /// Oberton itself; `textFieldFocused`: one of its own text fields has the keyboard focus.
        case oberton(textFieldFocused: Bool)
        case other(bundleID: String?)
    }

    /// Never somewhere to type: the Dock, Control Center, Notification Center and the menu bar's extras (Windows: the
    /// taskbar, Start, Search).
    public static let shellApps: Set<String> = [
        "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver",
    ]

    public static let finder = "com.apple.finder"

    /// The app is never somewhere to type (Windows `PasteSpot.IsNowhere`, quick, no Accessibility). Without
    /// Accessibility (the App Store build) the Finder counts as the desktop too, since nothing can tell its desktop
    /// from its windows; with it, the focused control decides (`AXReader.spot`). Oberton itself only when none of its
    /// own text fields has the focus.
    public static func isNowhere(_ app: FrontApp, accessibility: Bool) -> Bool {
        switch app {
        case .none: return true
        case .oberton(let focused): return !focused
        case .other(let id):
            guard let id else { return false }
            return shellApps.contains(id) || (id == finder && !accessibility)
        }
    }

    // MARK: Paste or type (Windows TextInserter.InsertAsync)

    /// Text with a line break goes in by pasting, never typing (Enter would submit chat boxes). As Windows'
    /// `text.Contains('\n')`: a line feed, also inside "\r\n", but not a lone CR or another separator.
    public static func isMultiLine(_ text: String) -> Bool { text.utf16.contains(10) }

    /// How long the app gets to read a paste before the clipboard changes again: min(1300, 450 + length/20) ms, the
    /// length in UTF-16 units as Windows' `text.Length`.
    public static func pasteWait(_ text: String) -> Duration { .milliseconds(min(1300, 450 + text.utf16.count / 20)) }

    /// Typing's batches (Windows `UnicodeTypingStrategy`): 4 UTF-16 units each, one more when the 4th would split a
    /// surrogate pair. Each batch holds one keystroke per code point (a pair stays one keystroke: macOS apps don't
    /// put halves back together).
    public static func typingBatches(_ text: String) -> [[[UInt16]]] {
        var batches: [[[UInt16]]] = []
        var batch: [[UInt16]] = []
        var units = 0
        for scalar in text.unicodeScalars {
            let u = Array(String(scalar).utf16)
            batch.append(u)
            units += u.count
            // A pair that would start at the 4th unit is taken whole (n++ on Windows), so a batch ends at 4 or 5 units.
            if units >= 4 {
                batches.append(batch)
                batch = []
                units = 0
            }
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }

    // MARK: Keystrokes (Windows VK_V / VK_C)

    /// The key code that gives `character` with ⌘ held on the current keyboard layout, so ⌘V and ⌘C are the
    /// shortcuts whatever the layout (Windows sends the virtual key V, which follows the layout). `translate` gives a
    /// key code's character with ⌘ held (nil when none); `preferred` (the ANSI key) is tried first, so QWERTY layouts
    /// and "… – QWERTY ⌘" layouts keep it. nil when no key on the layout gives it.
    public static func keyCode(for character: Character, preferred: UInt16, translate: (UInt16) -> String?) -> UInt16? {
        let wanted = String(character).lowercased()
        func gives(_ key: UInt16) -> Bool { translate(key)?.lowercased() == wanted }
        if gives(preferred) { return preferred }
        return (0..<128).first(where: gives)
    }

    // MARK: Read aloud's selection (Windows SelectionReader)

    /// At most this many UTF-16 units of a selection range are read (Windows `GetText(MaxChars)`).
    public static let selectionMaxChars = 100_000

    /// `text` cut to `max` UTF-16 units, one less where the cut would split a surrogate pair.
    public static func capped(_ text: String, max: Int = selectionMaxChars) -> String {
        let units = text.utf16
        guard units.count > max else { return text }
        var end = units.index(units.startIndex, offsetBy: max)
        if UTF16.isTrailSurrogate(units[end]) { end = units.index(before: end) }
        return String(decoding: units[..<end], as: UTF16.self)
    }
}
