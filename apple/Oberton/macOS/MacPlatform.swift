#if os(macOS)
import AppKit
import ApplicationServices
import AVFoundation
import ObertonCore

/// Puts text where the cursor was when the hotkey was pressed, as the Windows `TextInserter`: by pasting (Cmd+V,
/// atomic, so it is reliable in Electron and browser apps) or by typing Unicode keystrokes, per the TEXT INSERTION
/// METHOD and the per-app overrides, falling back to the other way when the first one fails. The user's clipboard is
/// put back afterwards.
///
/// The target is the window that was in front (Windows' `InsertionTarget`), and in it the control and caret the
/// dictation started at (`PasteSpot`), when Accessibility can tell (the direct build); in the App Store build it is the
/// app, and the text goes to its caret wherever that is now.
@MainActor
final class MacPlatform: PlatformServices {
    /// The window the dictation started in.
    struct Target {
        let app: NSRunningApplication
        /// What Accessibility could tell, read in the background at the hotkey press (nil until then, and always in
        /// the App Store build).
        var window: AXRef?
        var title: String?
    }

    private var target: Target?
    /// Where the cursor was, and the text around it, read while the target still had the focus.
    private var spot: Task<PasteSpot, Never> = Task { .unknown }
    private var context: Task<InsertionContext?, Never> = Task { nil }
    private var capture = 0
    private let settings: () -> AppSettings

    init(settings: @escaping () -> AppSettings) { self.settings = settings }

    var targetAppName: String? { target?.app.localizedName }

    /// The dictation window's title, when Accessibility could read it (the direct build): for History.
    var targetWindowTitle: String? { target?.title }

    /// Nothing to type into had the cursor when the dictation started (Windows `PasteSpotKind.None`).
    var nowhereToPaste: Bool {
        get async {
            guard target != nil else { return true }
            return await spot.value.kind == .none
        }
    }

    func insertionContext() async -> InsertionContext? { await context.value }

    func captureTarget() { captureTarget(readContext: false) }

    func captureTarget(readContext: Bool) {
        let front = NSWorkspace.shared.frontmostApplication
        target = front.flatMap { Self.isNowhere($0) ? nil : Target(app: $0) }
        guard let app = target?.app else {
            spot = Task { PasteSpot(kind: .none) }
            context = Task { nil }
            return
        }
        // Down to the caret position and the text around it, read now, while the app still has the focus.
        let (pid, bundleID) = (app.processIdentifier, app.bundleIdentifier)
        capture += 1
        let mine = capture
        struct Read: @unchecked Sendable { var window: AXRef?; var title: String?; var spot: PasteSpot; var context: InsertionContext? }
        let read = Task {
            await AXReader.bounded(.milliseconds(400), fallback: Read(spot: .unknown)) {
                let window = AXReader.focusedWindow(pid)
                return Read(window: window, title: window.flatMap(AXReader.title), spot: AXReader.spot(pid, bundleID: bundleID),
                            context: readContext ? AXReader.context(pid) : nil)
            }
        }
        spot = Task { @MainActor [weak self] in
            let r = await read.value
            if let self, self.capture == mine { self.target?.window = r.window; self.target?.title = r.title }
            return r.spot
        }
        context = Task { await read.value.context }
    }

    /// Never somewhere to type: the Dock, Control Center and Notification Center (Windows: the taskbar, Start, Search).
    /// Without Accessibility, also the Finder (its desktop; Windows: the desktop), and Oberton itself unless one of its
    /// own text fields has the focus. With Accessibility, the focused control decides instead (`AXReader.spot`).
    private static func isNowhere(_ app: NSRunningApplication) -> Bool {
        let shell = ["com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver"]
        if let id = app.bundleIdentifier, shell.contains(id) { return true }
        if app == NSRunningApplication.current { return !ownTextFieldHasFocus }
        return app.bundleIdentifier == "com.apple.finder" && !AXReader.available
    }

    /// One of Oberton's own text fields has the keyboard focus (Windows can dictate into its own window's fields too).
    private static var ownTextFieldHasFocus: Bool {
        guard let view = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return view.isEditable
    }

    /// Waits for the user to click into somewhere to type, up to `timeout` (Windows `WatchForPlaceAsync`): every 250 ms,
    /// an app that isn't the desktop or the Dock, in front for two ticks with the mouse released, and (with
    /// Accessibility) a focused control that takes text. That place becomes the target.
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
            captureTarget(readContext: false)
            guard await spot.value.kind != .none, !Task.isCancelled else { continue }
            return target != nil
        }
        return false
    }

    func insert(_ text: String) async throws -> String {
        // History's insert: whatever was in front when asked (Oberton, usually) comes back afterwards.
        let returnToOberton = NSApp.isActive && target?.app != NSRunningApplication.current
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
            try await insert(text, into: target, spot: await spot.value)
            // The caret has moved on: History's "insert into the last app" goes to wherever it is now (Windows passes
            // no spot there).
            spot = Task { .unknown }
        } catch {
            // Last resort so the dictation isn't lost: leave it on the clipboard.
            keep(text)
            throw UserFacingError(error.localizedDescription + " The text was copied to your clipboard.")
        }
        if returnToOberton {
            try? await Task.sleep(for: .milliseconds(250)) // the paste lands first
            NSApp.activate()
        }
        return "Inserted into \(target.app.localizedName ?? "the app")"
    }

    /// Windows `TextInserter.InsertAsync`. `keepClipboard`: don't put the clipboard back (live typing holds it).
    /// `spot`: the caret goes back there first, even if the user clicked elsewhere meanwhile.
    fileprivate func insert(_ text: String, into target: Target, keepClipboard: Bool = false, spot: PasteSpot? = nil) async throws {
        if !isAlive(target) { throw UserFacingError("The window you were dictating into was closed.") }
        await waitForModifiersReleased()
        guard await bringToFront(target) else {
            throw UserFacingError("Couldn't switch back to the app you were typing in. Click into it and try again.")
        }
        try? await Task.sleep(for: .milliseconds(40))
        if let spot, spot.kind == .caret {
            let pid = target.app.processIdentifier
            let ok = await AXReader.bounded(.milliseconds(800), fallback: false) { AXReader.restore(spot, pid: pid) }
            Log.info(ok ? "Pasting at the cursor position the dictation started at" : "The cursor position couldn't be restored; pasting at the current caret")
        }

        let s = settings()
        var mode = target.app.bundleIdentifier.flatMap { s.appOverrides[$0] } ?? s.insertion
        // Auto = paste: one atomic operation, reliable in every kind of app. Typing is a fallback (or a per-app choice).
        if mode == .auto { mode = .clipboard }
        let multiLine = text.contains(where: \.isNewline)
        var typeFirst = mode == .typing
        // Enter would submit chat boxes, so multi-line text is always pasted; so is text too long to type.
        if typeFirst && (multiLine || text.count > s.typingMaxChars) { typeFirst = false }
        do {
            if typeFirst { try await type(text) } else { try await paste(text, restore: !keepClipboard) }
        } catch {
            if !typeFirst && multiLine { throw UserFacingError("Text could not be inserted into that application.") }
            do {
                if typeFirst { try await paste(text, restore: !keepClipboard) } else { try await type(text) }
            } catch {
                throw UserFacingError("Text could not be inserted. Check that Oberton is allowed in System Settings › Privacy & Security › Accessibility.")
            }
        }
    }

    /// The window (or, without Accessibility, the app) is still there.
    fileprivate func isAlive(_ target: Target) -> Bool {
        if target.app.isTerminated { return false }
        guard let window = target.window, AXReader.available else { return true }
        return AXReader.isAlive(window)
    }

    /// The dictation's window is the one in front: its app is frontmost and (when Accessibility knows the window) it is
    /// that app's focused window.
    fileprivate func isInFront(_ target: Target) -> Bool {
        guard NSWorkspace.shared.frontmostApplication == target.app else { return false }
        guard let window = target.window, AXReader.available else { return true }
        return window.same(AXReader.focusedWindow(target.app.processIdentifier))
    }

    /// Bring the target back to the front (it normally still is): the app activated, and its window brought out of the
    /// Dock if minimised and raised. False when it didn't come within half a second.
    fileprivate func bringToFront(_ target: Target) async -> Bool {
        if isInFront(target) { return true }
        if target.app.isHidden { target.app.unhide() }
        if let window = target.window {
            _ = await AXReader.bounded(.milliseconds(400), fallback: ()) { AXReader.restore(window) }
        }
        target.app.activate()
        for _ in 0..<20 {
            if isInFront(target) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    /// The hotkey's own modifiers may still be down; they would turn the text into shortcuts (Ctrl+Cmd+V).
    fileprivate func waitForModifiersReleased() async {
        for _ in 0..<40 where !CGEventSource.flagsState(.combinedSessionState).intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]).isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private struct PostFailed: LocalizedError {
        var errorDescription: String? { "The keystrokes could not be sent." }
    }

    /// The clipboard's change count right after Oberton last put text on it (to tell whether the user copied since).
    fileprivate var ourClipboard = -1

    /// Cmd+V with the text on the clipboard, then the user's clipboard back (Windows `ClipboardPasteStrategy`).
    fileprivate func paste(_ text: String, restore: Bool = true) async throws {
        let pb = NSPasteboard.general
        let saved = restore && settings().restoreClipboard ? snapshot(pb) : nil
        put(text, on: pb)
        try sendKey(0x09, flags: .maskCommand) // V
        if let saved {
            let count = pb.changeCount
            // Give the app time to read the paste before the old clipboard comes back.
            try? await Task.sleep(for: .milliseconds(min(1300, 450 + text.count / 20)))
            if pb.changeCount == count { self.restore(saved, to: pb) }
        }
    }

    /// Unicode keystrokes, a few at a time (Windows `UnicodeTypingStrategy`): Chromium and Electron apps drop or repeat
    /// characters when flooded. Doesn't touch the clipboard.
    fileprivate func type(_ text: String) async throws {
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

    /// `count` Backspaces, a few at a time like typing (Windows `TextInserter.EraseAsync`).
    fileprivate func backspace(_ count: Int) async throws {
        for start in stride(from: 0, to: count, by: 4) {
            try Task.checkCancellation()
            for _ in start..<min(start + 4, count) { try sendKey(0x33, flags: []) } // Delete (Backspace)
            if start + 4 < count { try? await Task.sleep(for: .milliseconds(10)) }
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
    fileprivate func keep(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func put(_ text: String, on pb: NSPasteboard) {
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Clipboard managers that follow nspasteboard.org leave the temporary text out of their history.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        ourClipboard = pb.changeCount
    }

    // MARK: Type as you speak

    /// The window this dictation types into while the user speaks; nil when there is none (Windows' `IsNowhere` check
    /// at the start: the desktop, the Dock).
    func liveTarget() -> LiveTarget? {
        guard let target else { return nil }
        return MacLiveTarget(platform: self, target: { [weak self] in self?.target ?? target }, spot: spot)
    }

    // MARK: Read aloud

    /// The selected text, as the Windows `SelectionReader`: asked through Accessibility first (the direct build only; no
    /// side effects), else copied with Cmd+C and the user's clipboard put back. nil when nothing is selected.
    func selectedText() async -> String? {
        if NSApp.isActive {
            // Oberton's own window is in front: ask it directly.
            return await copySelection()
        }
        if let text = await SelectionReader.accessibility() { return text.isEmpty ? nil : text }
        return await copySelection()
    }

    /// Cmd+C, then the clipboard back. nil if the app copied nothing (nothing selected).
    private func copySelection() async -> String? {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        let saved = snapshot(pb)
        if NSApp.isActive {
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

    /// The clipboard's text, trimmed (Windows `SelectionReader.ClipboardText`).
    func clipboardText() -> String? { NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) }

    func requestPermissions() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
    }

    fileprivate func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
    }

    fileprivate func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { types in
            let item = NSPasteboardItem()
            for (t, d) in types { item.setData(d, forType: t) }
            return item
        })
    }
}

/// "Type as you speak"'s way into the dictation's window (Windows' `TextInserter` live calls and `InsertionContext`'s
/// checks). The checks and selections need Accessibility (the direct build); without it every check is `.unreadable`,
/// so the final pass erases with Backspace and pastes, as Windows does in apps that don't show their text, but only
/// while the user hasn't clicked anywhere since the typing began (nothing else can tell whether the caret moved).
@MainActor
final class MacLiveTarget: LiveTarget {
    private unowned let platform: MacPlatform
    private let currentTarget: () -> MacPlatform.Target
    private let spot: Task<PasteSpot, Never>
    private var savedClipboard: [[NSPasteboard.PasteboardType: Data]]?
    private var clicked = false
    nonisolated(unsafe) private var monitor: Any?

    init(platform: MacPlatform, target: @escaping () -> MacPlatform.Target, spot: Task<PasteSpot, Never>) {
        self.platform = platform
        self.currentTarget = target
        self.spot = spot
        if !AXReader.available {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.clicked = true }
            }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private var target: MacPlatform.Target { currentTarget() }
    private var pid: pid_t { target.app.processIdentifier }

    var isInFront: Bool { platform.isInFront(target) }
    var mayEraseUnread: Bool { AXReader.available || !clicked }

    func nowhere() async -> Bool { await spot.value.kind == .none }

    private static let notInFront = "The app you were dictating into isn't in front any more."

    private func ready() async throws {
        await platform.waitForModifiersReleased()
        guard platform.isAlive(target), isInFront else { throw UserFacingError(Self.notInFront) }
    }

    func insert(_ text: String) async throws {
        try await platform.insert(text, into: target, keepClipboard: true)
    }

    func paste(_ text: String) async throws {
        try await ready()
        do { try await platform.paste(text, restore: false) } catch is CancellationError { throw CancellationError() } catch {
            throw UserFacingError("Pasting into that app failed: " + error.localizedDescription)
        }
    }

    func type(_ text: String) async throws {
        let s = platform.settingsNow
        if text.contains(where: \.isNewline) || target.app.bundleIdentifier.flatMap({ s.appOverrides[$0] }) == .clipboard {
            try await platform.insert(text, into: target)
            return
        }
        try await ready()
        try await platform.type(text)
    }

    func erase(_ text: String) async throws {
        let count = text.count // one Backspace takes a whole character (an emoji, a letter with its accent)
        guard count > 0 else { return }
        try await ready()
        try await platform.backspace(count)
    }

    func focus() async -> Bool {
        guard platform.isAlive(target) else { return false }
        await platform.waitForModifiersReleased()
        return await platform.bringToFront(target)
    }

    func deleteSelection() async throws {
        await platform.waitForModifiersReleased()
        try await platform.backspace(1)
    }

    func checkBeforeCaret(_ expected: String, timeout: Duration) async -> LiveText {
        let pid = pid
        return await AXReader.bounded(timeout, fallback: .unreadable) { AXReader.checkBeforeCaret(pid, expected) }
    }

    func selectBeforeCaret(_ expected: String, timeout: Duration) async -> Bool {
        let pid = pid, abandoned = AXReader.Abandoned()
        // A check that times out keeps running; it must not select anything after this has moved on.
        defer { abandoned.set() }
        let ok = await AXReader.bounded(timeout, fallback: false) { AXReader.selectBeforeCaret(pid, expected, select: true, abandoned: abandoned) }
        if !ok, AXReader.available { CoreLog.info("The live text couldn't be confirmed through Accessibility") }
        return ok
    }

    func selectDoubled(_ first: String, _ second: String, timeout: Duration) async -> Bool {
        let pid = pid, abandoned = AXReader.Abandoned()
        defer { abandoned.set() }
        return await AXReader.bounded(timeout, fallback: false) { AXReader.selectDoubled(pid, first, second, abandoned: abandoned) }
    }

    func holdClipboard() { savedClipboard = platform.snapshot(NSPasteboard.general) }

    /// The user's clipboard back, unless they copied something else meanwhile (then theirs stays).
    func restoreClipboard() {
        guard let saved = savedClipboard else { return }
        savedClipboard = nil
        let pb = NSPasteboard.general
        if pb.changeCount == platform.ourClipboard { platform.restore(saved, to: pb) }
    }

    func forgetClipboard() { savedClipboard = nil }

    func copy(_ text: String) { platform.keep(text) }
}

extension MacPlatform {
    fileprivate var settingsNow: AppSettings { settings() }
}
#endif
