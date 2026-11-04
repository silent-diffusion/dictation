#if os(macOS)
import AppKit
import ApplicationServices
import ObertonCore

/// An Accessibility element handed between threads (a CF object; Accessibility calls may come from any thread).
struct AXRef: @unchecked Sendable {
    let element: AXUIElement
    func same(_ other: AXRef?) -> Bool { other.map { CFEqual(element, $0.element) } ?? false }
}

/// Where the cursor was when a dictation started (Windows `PasteSpot`): a text control and its caret, so the text goes
/// back to exactly that spot; a window whose caret Accessibility can't tell; or nothing to type into.
struct PasteSpot: @unchecked Sendable {
    enum Kind: Sendable { case caret, window, none }
    var kind: Kind
    var element: AXUIElement?
    var range: CFRange?

    static let unknown = PasteSpot(kind: .window)
}

/// Other apps' text and windows through Accessibility, as Windows reads them through UI Automation: the text around the
/// caret (`InsertionContext`), the focused control and its caret (`PasteSpot`), the dictation's window and its title,
/// and live typing's checks and selections (Read aloud's selection: `SelectionReader`). Only the direct build may (outside the App
/// Store sandbox, once Oberton is allowed in Privacy & Security › Accessibility): every call answers nil, false or
/// `.unreadable` otherwise, and callers fall back to what the sandbox can do. Nothing read here is stored, logged or
/// sent anywhere.
///
/// The calls go into the other app and can block, so they run off the main thread with a time limit (`bounded`).
enum AXReader {
    /// Accessibility may be used now (the direct build, trusted).
    static var available: Bool { Distribution.axTrusted }

    /// How much text is read on each side of the caret (Windows `InsertionContext.ReadChars`).
    static let readChars = 240

    // MARK: Running the calls

    /// Every Accessibility call answers within a second, whatever the app does (the system-wide element's timeout is
    /// the global one).
    private static let timeoutSet: Void = { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0); return () }()

    /// Runs `work` off the main thread; `fallback` if it hasn't answered within `timeout` (it may still finish later:
    /// work that changes something checks an abandoned flag first).
    static func bounded<T: Sendable>(_ timeout: Duration, fallback: T, _ work: @escaping @Sendable () -> T) async -> T {
        guard available else { return fallback }
        _ = timeoutSet
        return await withCheckedContinuation { continuation in
            let once = Once()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = work()
                if once.claim() { continuation.resume(returning: result) }
            }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.claim() { continuation.resume(returning: fallback) }
            }
        }
    }

    /// The first caller wins (the work or the time limit).
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    /// Set when a bounded call was given up on: it must not change anything any more.
    final class Abandoned: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    // MARK: Attributes

    static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ e: AXUIElement, _ name: String) -> String? { attribute(e, name) as? String }

    static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(e, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func bool(_ e: AXUIElement, _ name: String) -> Bool? { (attribute(e, name) as? NSNumber)?.boolValue }

    @discardableResult
    static func set(_ e: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(e, name as CFString, value) == .success
    }

    /// The selection (a caret is an empty one), in UTF-16 units.
    static func selectedRange(_ e: AXUIElement) -> CFRange? {
        guard let value = attribute(e, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    @discardableResult
    static func select(_ e: AXUIElement, _ range: CFRange) -> Bool {
        var r = range
        guard let value = AXValueCreate(.cfRange, &r) else { return false }
        return set(e, kAXSelectedTextRangeAttribute, value)
    }

    static func characterCount(_ e: AXUIElement) -> Int? {
        (attribute(e, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
            ?? (string(e, kAXValueAttribute)).map { ($0 as NSString).length }
    }

    /// The control's text in `range` (clamped to the text), asked for that range only where the app allows, else cut
    /// from its whole value.
    static func text(_ e: AXUIElement, in range: CFRange) -> String? {
        guard range.length >= 0, range.location >= 0 else { return nil }
        if range.length == 0 { return "" }
        var r = range
        if let value = AXValueCreate(.cfRange, &r) {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(e, kAXStringForRangeParameterizedAttribute as CFString, value, &out) == .success,
               let s = out as? String {
                return s
            }
        }
        guard let all = string(e, kAXValueAttribute) as NSString? else { return nil }
        let start = min(range.location, all.length), end = min(range.location + range.length, all.length)
        return all.substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: Apps and windows

    static func app(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    /// The app's focused window: the window a dictation goes back to.
    static func focusedWindow(_ pid: pid_t) -> AXRef? {
        let app = app(pid)
        return (element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)).map(AXRef.init)
    }

    /// A window's title ("Notes — Draft", "Inbox – Mail"), or nil.
    static func title(_ window: AXRef) -> String? {
        string(window.element, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The title of the frontmost app's front window, or nil (not readable, or no window). For History's window title
    /// and the web sites in Analytics (lane J). Blocks for at most about a second; call off the main thread, or use
    /// `frontWindowTitle()`.
    static func frontWindowTitleNow() -> String? {
        guard available, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let window = focusedWindow(pid) else { return nil }
        return title(window)
    }

    /// `frontWindowTitleNow`, off the main thread and bounded (400 ms).
    static func frontWindowTitle() async -> String? {
        await bounded(.milliseconds(400), fallback: nil) { frontWindowTitleNow() }
    }

    /// The window still exists.
    static func isAlive(_ window: AXRef) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window.element, kAXRoleAttribute as CFString, &value)
        return error != .invalidUIElement
    }

    /// Brings the window back: its app to the front, the window out of the Dock if minimised, raised and made the main
    /// window (Windows' `IsIconic → ShowWindow(SW_RESTORE)` then `SetForegroundWindow`).
    static func restore(_ window: AXRef) {
        var pid: pid_t = 0
        // Its app to the front too: an app that isn't active itself may not activate another one any more.
        if AXUIElementGetPid(window.element, &pid) == .success { set(app(pid), kAXFrontmostAttribute, kCFBooleanTrue) }
        if bool(window.element, kAXMinimizedAttribute) == true { set(window.element, kAXMinimizedAttribute, kCFBooleanFalse) }
        set(window.element, kAXMainAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    // MARK: The focused control

    /// The control with the keyboard focus in the app.
    static func focusedElement(_ pid: pid_t) -> AXUIElement? { element(app(pid), kAXFocusedUIElementAttribute) }

    /// Controls that hold no caret: focused, they mean nothing to type into was selected (Windows `PasteSpot.NonText`,
    /// in macOS's roles).
    static let nonTextRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXRadioGroupRole, kAXRowRole, kAXListRole, kAXOutlineRole,
        kAXBrowserRole, kAXTableRole, kAXColumnRole, kAXCellRole, kAXMenuRole, kAXMenuItemRole, kAXMenuBarRole,
        kAXMenuBarItemRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXTabGroupRole, "AXLink", kAXImageRole,
        kAXScrollBarRole, kAXSliderRole, kAXToolbarRole, kAXDisclosureTriangleRole, kAXIncrementorRole, kAXColorWellRole,
        "AXDockItem", "AXLevelIndicator", kAXValueIndicatorRole, kAXBusyIndicatorRole, kAXProgressIndicatorRole,
    ]

    /// Where the text should go, read while the app still has the focus (Windows `PasteSpot.Read`).
    static func spot(_ pid: pid_t, bundleID: String?) -> PasteSpot {
        guard let focused = focusedElement(pid) else {
            // The Finder with nothing focused is the desktop; any other app gets its window back and a paste.
            return bundleID == "com.apple.finder" ? PasteSpot(kind: .none) : .unknown
        }
        if let range = selectedRange(focused), isTextControl(focused) { return PasteSpot(kind: .caret, element: focused, range: range) }
        if let role = string(focused, kAXRoleAttribute), nonTextRoles.contains(role) { return PasteSpot(kind: .none) }
        return .unknown
    }

    /// A control that holds a caret: editable text, or anything that reports a text selection and isn't one of the
    /// non-text roles.
    static func isTextControl(_ e: AXUIElement) -> Bool {
        guard let role = string(e, kAXRoleAttribute) else { return true }
        return !nonTextRoles.contains(role)
    }

    /// Put the caret back where it was, in its own control (the window must already be in front). True when it is
    /// there now; false when the app wouldn't take it (the text then goes wherever the caret is).
    static func restore(_ spot: PasteSpot, pid: pid_t) -> Bool {
        guard spot.kind == .caret, let element = spot.element, let range = spot.range else { return false }
        func there() -> Bool { selectedRange(element).map { $0.location == range.location && $0.length == range.length } ?? false }
        if let now = focusedElement(pid), CFEqual(now, element), there() { return true } // still there
        set(element, kAXFocusedAttribute, kCFBooleanTrue)
        select(element, range)
        return there()
    }

    // MARK: The text around the caret

    /// The text around the caret in the app's focused control, two sentences before and one after (Windows
    /// `InsertionContext.Read`). An empty field that shows a placeholder or keeps an invisible character counts as
    /// empty. nil when the control's text can't be read: only a control with a text selection (Windows: one with a
    /// TextPattern) gives any context, an empty one included.
    static func context(_ pid: pid_t) -> InsertionContext? {
        guard let focused = focusedElement(pid), let selection = selectedRange(focused) else { return nil }
        if isEmptyField(focused) { return InsertionContext(before: "", after: "") }
        let start = max(0, selection.location - readChars)
        guard let before = text(focused, in: CFRange(location: start, length: selection.location - start)) else { return nil }
        let end = selection.location + selection.length
        let count = characterCount(focused) ?? end + readChars
        let after = text(focused, in: CFRange(location: end, length: max(0, min(readChars, count - end)))) ?? ""
        return InsertionContext.trim(before: before, after: after)
    }

    /// Empty, or showing only a placeholder ("Type a message"), or an invisible character a web editor keeps in its
    /// empty paragraph (Windows `IsEmptyField`).
    static func isEmptyField(_ e: AXUIElement) -> Bool {
        let count = characterCount(e) ?? 0
        let shown = text(e, in: CFRange(location: 0, length: min(readChars, count))) ?? string(e, kAXValueAttribute) ?? ""
        return InsertionContext.isEmptyField(shown: shown, value: string(e, kAXValueAttribute),
                                             labels: [kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].map { string(e, $0) })
    }

    // MARK: Live typing's checks

    /// Only the letters and digits, lower-cased: the words, whatever the spacing and punctuation styles.
    static func letters(_ s: String) -> String { String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)).lowercased() }

    /// The caret (the end of the selection) and the focused control.
    private static func caret(_ pid: pid_t) -> (AXUIElement, Int)? {
        guard let focused = focusedElement(pid), let selection = selectedRange(focused) else { return nil }
        return (focused, selection.location + selection.length)
    }

    private static func before(_ e: AXUIElement, caret: Int, _ n: Int) -> String? {
        text(e, in: CFRange(location: max(0, caret - n), length: min(n, caret)))
    }

    /// What the focused control shows right before the caret, compared with what live dictation typed (Windows
    /// `CheckBeforeCaret`).
    static func checkBeforeCaret(_ pid: pid_t, _ expected: String) -> LiveText {
        guard let (focused, caret) = caret(pid) else { return .unreadable }
        let n = expected.utf16.count
        guard let shown = before(focused, caret: caret, n) else { return .unreadable }
        if InsertionContext.sameText(shown, expected) { return .matches }
        if InsertionContext.visible(shown).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || letters(shown) == letters(expected) {
            return .unreadable
        }
        // Some apps count characters differently (line breaks, emoji); look a little further back for the words.
        let wider = letters(before(focused, caret: caret, n + 16) ?? "")
        return wider.hasSuffix(letters(expected)) ? .unreadable : .differs
    }

    /// Select `expected` in the focused control if it is exactly the text right before the caret (Windows
    /// `SelectBeforeCaret`); `select: false` only checks. False, with nothing selected, whenever that can't be confirmed.
    static func selectBeforeCaret(_ pid: pid_t, _ expected: String, select doSelect: Bool, abandoned: Abandoned) -> Bool {
        guard let (focused, caret) = caret(pid) else { return false }
        let n = expected.utf16.count
        guard caret >= n, let shown = before(focused, caret: caret, n), InsertionContext.sameText(shown, expected) else { return false }
        if !doSelect { return true }
        if abandoned.isSet { return false }
        select(focused, CFRange(location: caret - n, length: n))
        // Some apps accept the call without moving their selection; pasting then would add the text a second time.
        if isSelected(focused, expected) { return true }
        CoreLog.info("The app didn't take the live text's selection")
        select(focused, CFRange(location: caret, length: 0))
        return false
    }

    private static func isSelected(_ e: AXUIElement, _ expected: String) -> Bool {
        guard let range = selectedRange(e), range.length > 0, let shown = text(e, in: range) else { return false }
        return InsertionContext.sameText(shown.trimmingTrailingWhitespace, expected.trimmingTrailingWhitespace)
    }

    /// After live dictation's final pass: if the text before the caret reads `first` then `second` (the replacement went
    /// in without replacing), select `first` so it can be removed (Windows `SelectDoubled`).
    static func selectDoubled(_ pid: pid_t, _ first: String, _ second: String, abandoned: Abandoned) -> Bool {
        guard !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !second.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let (focused, caret) = caret(pid) else { return false }
        let both = first + second, n = both.utf16.count, m = first.utf16.count
        guard caret >= n, let shown = before(focused, caret: caret, n), InsertionContext.sameText(shown, both),
              let head = text(focused, in: CFRange(location: caret - n, length: m)), InsertionContext.sameText(head, first),
              !abandoned.isSet else { return false }
        select(focused, CFRange(location: caret - n, length: m))
        if isSelected(focused, first) { return true }
        select(focused, CFRange(location: caret, length: 0))
        return false
    }
}

private extension String {
    var trimmingTrailingWhitespace: String {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}
#endif
