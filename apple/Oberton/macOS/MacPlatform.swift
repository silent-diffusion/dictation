#if os(macOS)
import AppKit
import ApplicationServices
import AVFoundation
import ObertonCore

/// Puts text where the cursor was when the hotkey was pressed, as the Windows `TextInserter`: by pasting (Cmd+V,
/// atomic, so it is reliable in Electron and browser apps) or by typing Unicode keystrokes, per the TEXT INSERTION
/// METHOD and the per-app overrides, falling back to the other way when the first one fails. The user's clipboard is
/// put back afterwards.
@MainActor
final class MacPlatform: PlatformServices {
    private var target: NSRunningApplication?
    /// Nothing to type into had the cursor when the dictation started (Windows `PasteSpotKind.None`).
    private var nowhere = false
    private let settings: () -> AppSettings

    init(settings: @escaping () -> AppSettings) { self.settings = settings }

    var targetAppName: String? { target?.localizedName }

    var nowhereToPaste: Bool { nowhere }

    func captureTarget() {
        let front = NSWorkspace.shared.frontmostApplication
        target = front.flatMap { Self.isNowhere($0) ? nil : $0 }
        nowhere = target == nil
    }

    /// Apps that are never somewhere to type: Oberton itself, and the Finder (the desktop; Windows: the desktop, the
    /// taskbar). The sandbox can't ask another app which control has focus, so this is decided by app, not by control.
    private static func isNowhere(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == Bundle.main.bundleIdentifier || app.bundleIdentifier == "com.apple.finder"
    }

    /// Waits for the user to click into another app (Windows: into a text field), up to `timeout`. The sandbox can't
    /// read which control has focus, so the closest reliable signal is used: an app other than Oberton or the Finder
    /// comes to the front and stays there for half a second with the mouse released. That app becomes the target.
    func waitForPlace(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        var seen: NSRunningApplication?
        var steady = 0
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return false }
            let front = NSWorkspace.shared.frontmostApplication
            guard let front, !Self.isNowhere(front), NSEvent.pressedMouseButtons == 0, front == seen else {
                seen = front
                steady = 0
                continue
            }
            steady += 1
            guard steady >= 2 else { continue }
            target = front
            nowhere = false
            return true
        }
        return false
    }

    func insert(_ text: String) async throws -> String {
        // History's insert: whatever was in front when asked (Oberton, usually) comes back afterwards.
        let returnToOberton = NSApp.isActive
        guard let target else {
            keep(text)
            return "Copied to the clipboard" // nothing to go back to
        }
        guard CGPreflightPostEventAccess() else {
            CGRequestPostEventAccess()
            keep(text)
            throw UserFacingError("Copied to the clipboard. To paste at the cursor, allow Oberton in System Settings › Privacy & Security › Accessibility.")
        }
        do {
            try await insert(text, into: target)
        } catch {
            // Last resort so the dictation isn't lost: leave it on the clipboard.
            keep(text)
            throw UserFacingError(error.localizedDescription + " The text was copied to your clipboard.")
        }
        if returnToOberton {
            try? await Task.sleep(for: .milliseconds(250)) // the paste lands first
            NSApp.activate()
        }
        return "Inserted into \(target.localizedName ?? "the app")"
    }

    private func insert(_ text: String, into target: NSRunningApplication) async throws {
        if target.isTerminated { throw UserFacingError("The app you were dictating into was closed.") }
        await waitForModifiersReleased()
        guard await bringToFront(target) else {
            throw UserFacingError("Couldn't switch back to the app you were typing in. Click into it and try again.")
        }
        try? await Task.sleep(for: .milliseconds(40))

        let s = settings()
        var mode = target.bundleIdentifier.flatMap { s.appOverrides[$0] } ?? s.insertion
        // Auto = paste: one atomic operation, reliable in every kind of app. Typing is a fallback (or a per-app choice).
        if mode == .auto { mode = .clipboard }
        let multiLine = text.contains(where: \.isNewline)
        var typeFirst = mode == .typing
        // Enter would submit chat boxes, so multi-line text is always pasted; so is text too long to type.
        if typeFirst && (multiLine || text.count > s.typingMaxChars) { typeFirst = false }
        do {
            if typeFirst { try await type(text) } else { try await paste(text) }
        } catch {
            if !typeFirst && multiLine { throw UserFacingError("Text could not be inserted into that application.") }
            do {
                if typeFirst { try await paste(text) } else { try await type(text) }
            } catch {
                throw UserFacingError("Text could not be inserted. Check that Oberton is allowed in System Settings › Privacy & Security › Accessibility.")
            }
        }
    }

    /// Bring the target back to the front (it normally still is). False when it didn't come within half a second.
    private func bringToFront(_ target: NSRunningApplication) async -> Bool {
        if NSWorkspace.shared.frontmostApplication == target { return true }
        if target.isHidden { target.unhide() }
        target.activate()
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication == target { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    /// The hotkey's own modifiers may still be down; they would turn the text into shortcuts (Ctrl+Cmd+V).
    private func waitForModifiersReleased() async {
        for _ in 0..<40 where !CGEventSource.flagsState(.combinedSessionState).intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]).isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private struct PostFailed: LocalizedError {
        var errorDescription: String? { "The keystrokes could not be sent." }
    }

    /// Cmd+V with the text on the clipboard, then the user's clipboard back (Windows `ClipboardPasteStrategy`).
    private func paste(_ text: String) async throws {
        let pb = NSPasteboard.general
        let saved = settings().restoreClipboard ? snapshot(pb) : nil
        put(text, on: pb)
        try sendKey(0x09, flags: .maskCommand) // V
        if let saved {
            let count = pb.changeCount
            // Give the app time to read the paste before the old clipboard comes back.
            try? await Task.sleep(for: .milliseconds(min(1300, 450 + text.count / 20)))
            if pb.changeCount == count { restore(saved, to: pb) }
        }
    }

    /// Unicode keystrokes, a few at a time (Windows `UnicodeTypingStrategy`): Chromium and Electron apps drop or repeat
    /// characters when flooded. Doesn't touch the clipboard.
    private func type(_ text: String) async throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let characters = Array(text) // one keystroke per character, so a surrogate pair or emoji is never split
        for start in stride(from: 0, to: characters.count, by: 4) {
            try Task.checkCancellation()
            for c in characters[start..<min(start + 4, characters.count)] {
                let units = Array(String(c).utf16)
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { throw PostFailed() }
                    e.flags = []
                    e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    e.post(tap: .cghidEventTap)
                }
            }
            if start + 4 < characters.count { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    private func sendKey(_ key: CGKeyCode, flags: CGEventFlags) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { throw PostFailed() }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    func copy(_ text: String) {
        put(text, on: NSPasteboard.general)
    }

    /// The text left on the clipboard as a last resort, when it couldn't go in: an ordinary copy, so clipboard managers
    /// keep it too (Windows' Clipboard.SetText in DictationController.InsertPendingAsync).
    private func keep(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func put(_ text: String, on pb: NSPasteboard) {
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Clipboard managers that follow nspasteboard.org leave the temporary text out of their history.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    /// The selected text, as the Windows `SelectionReader`: asked through Accessibility first (no side effects; only
    /// outside the sandbox), else copied with Cmd+C and the user's clipboard put back. nil when nothing is selected.
    func selectedText() async -> String? {
        if let text = accessibilitySelection() { return text.isEmpty ? nil : text }
        return await copySelection()
    }

    /// nil when the focused control can't be asked (always, in the sandbox); "" when it says nothing is selected.
    private func accessibilitySelection() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cmd+C, then the clipboard back. nil if the app copied nothing (nothing selected).
    private func copySelection() async -> String? {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        let saved = snapshot(pb)
        if NSApp.isActive {
            // Oberton's own window is in front: ask it directly.
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        } else {
            guard CGPreflightPostEventAccess() else { return nil }
            // The Read aloud hotkey's own modifiers may still be held; Cmd+Shift+C means something else in many apps.
            await waitForModifiersReleased()
            try? sendKey(0x08, flags: .maskCommand) // C
        }
        for _ in 0..<20 where pb.changeCount == before { try? await Task.sleep(for: .milliseconds(25)) }
        guard pb.changeCount != before else { return nil }
        try? await Task.sleep(for: .milliseconds(30)) // let the app finish writing all formats
        let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        restore(saved, to: pb)
        return text?.isEmpty == false ? text : nil
    }

    func clipboardText() -> String? { NSPasteboard.general.string(forType: .string) }

    func requestPermissions() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
    }

    private func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
    }

    private func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { types in
            let item = NSPasteboardItem()
            for (t, d) in types { item.setData(d, forType: t) }
            return item
        })
    }
}
#endif
