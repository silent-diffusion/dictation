#if os(macOS)
import ApplicationServices
import Foundation
import ObertonCore

/// The text selected in the app in front, for Read aloud (Windows' SelectionReader). The direct build asks the focused
/// control through Accessibility first, which has no side effects; the App Store build can't read other apps (the
/// sandbox), so it, and any app that doesn't answer, goes straight to MacPlatform's ⌘C fallback.
enum SelectionReader {
    /// How long the app may take to answer in all, as Windows waits 600 ms for UI Automation.
    static let timeout: Duration = .milliseconds(600)

    /// The selection as the focused control reports it: nil when it can't be asked (App Store build, no
    /// Accessibility permission, a control without text, an app that doesn't answer in time), "" when it says nothing
    /// is selected.
    static func accessibility() async -> String? {
        guard Distribution.axTrusted else { return nil }
        return await AXReader.bounded(timeout, fallback: nil) { read() }
    }

    /// Each range read up to 100,000 UTF-16 units, several ranges (a multiple selection) joined, then trimmed
    /// (Windows `string.Concat(selection.Select(r => r.GetText(MaxChars))).Trim()`).
    private static func read() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let found = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard found == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            unreadable(found)
            return nil
        }
        let element = focused as! AXUIElement
        if let ranges = AXReader.attribute(element, kAXSelectedTextRangesAttribute) as? [AXValue], ranges.count > 1 {
            var parts: [String] = []
            for value in ranges {
                var range = CFRange()
                guard AXValueGetValue(value, .cfRange, &range), let text = AXReader.text(element, in: range) else { continue }
                parts.append(InsertionRules.capped(text))
            }
            if !parts.isEmpty { return parts.joined().trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        var selected: CFTypeRef?
        let asked = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected)
        guard asked == .success, let text = selected as? String else {
            unreadable(asked)
            return nil
        }
        return InsertionRules.capped(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Windows logs "Selection not readable via UI Automation: {exception}" only when asking the app failed; a control
    /// that has no text to give (no focused element, no text pattern) and an app that doesn't answer in time fall back
    /// to the copy without a line. So here: a failed request is logged, a missing attribute or value isn't.
    private static func unreadable(_ error: AXError) {
        guard shouldLog(error) else { return }
        Log.info("Selection not readable via Accessibility: \(name(error))")
    }

    /// Whether an answer is a failure (logged) rather than "this control has no selected text" (silent).
    static func shouldLog(_ error: AXError) -> Bool {
        switch error {
        case .success, .attributeUnsupported, .noValue, .parameterizedAttributeUnsupported: false
        default: true
        }
    }

    private static func name(_ error: AXError) -> String {
        switch error {
        case .success: return "noText"
        case .attributeUnsupported: return "attributeUnsupported"
        case .noValue: return "noValue"
        case .cannotComplete: return "cannotComplete"
        case .apiDisabled: return "apiDisabled"
        case .notImplemented: return "notImplemented"
        case .invalidUIElement: return "invalidUIElement"
        case .failure: return "failure"
        default: return "error \(error.rawValue)"
        }
    }
}
#endif
