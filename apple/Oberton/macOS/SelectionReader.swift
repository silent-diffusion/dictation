#if os(macOS)
import ApplicationServices
import Foundation

/// The text selected in the app in front, for Read aloud (Windows' SelectionReader). The direct build asks the focused
/// control through Accessibility first, which has no side effects; the App Store build can't read other apps (the
/// sandbox), so it, and any app that doesn't answer, goes straight to MacPlatform's ⌘C fallback.
enum SelectionReader {
    static let maxChars = 100_000
    /// How long an app may take to answer, as Windows waits for UI Automation.
    static let timeout: Float = 0.6

    /// The selection as the focused control reports it: nil when it can't be asked (App Store build, no
    /// Accessibility permission, a control without text, an app that doesn't answer in time), "" when it says nothing
    /// is selected.
    static func accessibility() async -> String? {
        guard Distribution.axTrusted else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, timeout)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            let element = focused as! AXUIElement
            AXUIElementSetMessagingTimeout(element, timeout)
            var selected: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
                  let text = selected as? String else { return nil }
            return String(text.prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
#endif
