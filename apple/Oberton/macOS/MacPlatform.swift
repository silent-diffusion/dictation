#if os(macOS)
import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import ObertonCore

/// Puts text where the cursor was when the hotkey was pressed, as the Windows `TextInserter`: by pasting (Cmd+V,
/// atomic, so it is reliable in Electron and browser apps) or by typing Unicode keystrokes, per the TEXT INSERTION
/// METHOD and the per-app overrides, falling back to the other way when the first one fails. The user's clipboard is
/// put back afterwards.
///
/// The target is the window that was in front (Windows' `InsertionTarget`), and in it the control and caret the
/// dictation started at (`PasteSpot`), when Accessibility can tell (the direct build); in the App Store build it is the
/// app's front window as the window server lists it, and the text goes to its caret wherever that is now.
@MainActor
final class MacPlatform: PlatformServices {
    /// The window the dictation started in.
    struct Target {
        let app: NSRunningApplication
        /// What Accessibility could tell, read in the background at the hotkey press (nil until then, and always in
        /// the App Store build).
        var window: AXRef?
        var title: String?
        /// The app's windows on screen then, front to back, as the window server lists them: how the App Store build
        /// (no Accessibility) tells the dictation's window from the app's others, and the direct build's fallback when
        /// Accessibility didn't answer in time.
        var windows: [WindowList.Window] = []
        /// Never somewhere to type (the Dock, the desktop…). Kept anyway, as Windows keeps the desktop as its target:
        /// History saves its app and "insert into the last app" goes there; a dictation waits for a click instead.
        var nowhere = false

        init(app: NSRunningApplication, nowhere: Bool) {
            self.app = app
            self.nowhere = nowhere
            windows = WindowList.onScreen(app.processIdentifier)
        }

        /// The dictation's window as the window server knows it: the front one then, or, if that one has gone (a
        /// pop-up list or sheet that was open), the next one that is still there.
        var windowID: CGWindowID? { windows.first { WindowList.exists($0.id) }?.id }
    }

    private var target: Target?
    /// Where the cursor was, and the text around it, read while the target still had the focus.
    private var spot: Task<PasteSpot, Never> = Task { .unknown }
    private var context: Task<InsertionContext?, Never> = Task { nil }
    /// The window and the title, each written into `target` once read.
    private var details: Task<Void, Never> = Task {}
    private var title: Task<Void, Never> = Task {}
    private var capture = 0
    private let settings: () -> AppSettings

    init(settings: @escaping () -> AppSettings) {
        self.settings = settings
        // Windows captures a target at startup (`_target = InsertionTarget.Capture()`), so History's "insert into the
        // last app" always has one.
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            target = Target(app: front, nowhere: InsertionRules.isNowhere(.other(bundleID: front.bundleIdentifier), accessibility: AXReader.available))
        }
    }

    /// History's app (Windows' ProcessName): the program's own name, the same in every language.
    var targetAppName: String? { target.map { Self.processName($0.app) } }
    /// The name in a sentence (Windows' DisplayName, the program's description): the app's name as macOS shows it.
    var targetDisplayName: String? { target?.app.localizedName }

    /// The dictation window's title, when Accessibility could read it (the direct build): for History and the web
    /// sites. "" for a window without one (as Windows' GetWindowText); nil without Accessibility (the App Store build).
    /// Read from the hotkey press on, for as long as the app takes to answer (each Accessibility call answers within a
    /// second): Windows' GetWindowText always has it, so a slow app isn't cut off at 400 ms here; only once the text
    /// is ready does it wait at most 400 ms more, so a hung app doesn't hold the dictation up.
    var targetWindowTitle: String? {
        get async {
            let title = self.title
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await title.value }
                group.addTask { try? await Task.sleep(for: .milliseconds(400)) }
                await group.next()
                group.cancelAll()
            }
            return target?.title
        }
    }

    /// Nothing to type into had the cursor when the dictation started (Windows `PasteSpotKind.None`).
    var nowhereToPaste: Bool {
        get async {
            guard let target, !target.nowhere else { return true }
            return await spot.value.kind == .none
        }
    }

    func insertionContext() async -> InsertionContext? { await context.value }

    func captureTarget() { captureTarget(readContext: false) }

    func captureTarget(readContext: Bool) { commit(read(readContext: readContext)) }

    /// What was read at a hotkey press (or a click, while placing): the app and window at once, the rest in the
    /// background.
    private struct Capture {
        var target: Target?
        var details: Task<Details, Never>
        var title: Task<String?, Never>
        var spot: Task<PasteSpot, Never>
        var context: Task<InsertionContext?, Never>
    }

    private struct Details: @unchecked Sendable {
        var window: AXRef?
    }

    /// The app in front now, down to the caret position and the text around it, read while it still has the focus.
    /// Each Accessibility read has its own 400 ms, as Windows reads the spot and the context side by side.
    private func read(readContext: Bool) -> Capture {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return Capture(target: nil, details: Task { Details() }, title: Task { nil }, spot: Task { PasteSpot(kind: .none) }, context: Task { nil })
        }
        let nowhere = InsertionRules.isNowhere(Self.frontApp(app), accessibility: AXReader.available)
        let (pid, bundleID) = (app.processIdentifier, app.bundleIdentifier)
        let details = Task {
            await AXReader.bounded(.milliseconds(400), fallback: Details()) { Details(window: AXReader.focusedWindow(pid)) }
        }
        // The title has no 400 ms limit of its own (see `targetWindowTitle`): two Accessibility calls, a second each.
        let title = Task {
            await AXReader.bounded(.seconds(3), fallback: nil) { AXReader.focusedWindow(pid).map { AXReader.title($0) ?? "" } }
        }
        // A window that is never somewhere to type has no spot to read (Windows `PasteSpot.CaptureAsync`).
        let spot = nowhere ? Task { PasteSpot(kind: .none) }
            : Task { await AXReader.bounded(.milliseconds(400), fallback: PasteSpot.unknown) { AXReader.spot(pid, bundleID: bundleID) } }
        let context = readContext && !nowhere
            ? Task { await AXReader.bounded(.milliseconds(400), fallback: nil) { AXReader.context(pid) } }
            : Task<InsertionContext?, Never> { nil }
        return Capture(target: Target(app: app, nowhere: nowhere), details: details, title: title, spot: spot, context: context)
    }

    /// The capture becomes the dictation's target. `keepContext`: a placed dictation keeps the text read at the hotkey
    /// press (Windows replaces only `_target` and `_spot` there).
    private func commit(_ c: Capture, keepContext: Bool = false) {
        target = c.target
        capture += 1
        let mine = capture
        details = Task { @MainActor [weak self] in
            let d = await c.details.value
            if let self, self.capture == mine { self.target?.window = d.window }
        }
        title = Task { @MainActor [weak self] in
            let t = await c.title.value
            if let self, self.capture == mine { self.target?.title = t }
        }
        spot = c.spot
        if !keepContext { context = c.context }
    }

    private static func frontApp(_ app: NSRunningApplication) -> InsertionRules.FrontApp {
        app == NSRunningApplication.current ? .oberton(textFieldFocused: ownTextFieldHasFocus) : .other(bundleID: app.bundleIdentifier)
    }

    /// One of Oberton's own text fields has the keyboard focus (Windows can dictate into its own window's fields too).
    private static var ownTextFieldHasFocus: Bool {
        guard let view = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return view.isEditable
    }

    /// The app's process name, as Windows logs and keeps it ("notepad"): its executable's name.
    private static func processName(_ app: NSRunningApplication) -> String {
        app.executableURL?.lastPathComponent ?? app.localizedName ?? "?"
    }

    /// Waits for the user to click into somewhere to type, up to `timeout` (Windows `WatchForPlaceAsync`): every 250 ms,
    /// a window that isn't the desktop or the Dock, in front for two ticks with the mouse released, and (with
    /// Accessibility) a focused control that takes text. That place becomes the target; until then the dictation's
    /// own target stays (History's "insert into the last app" still goes there after a copy or a time-out).
    func waitForPlace(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        var seen: (app: NSRunningApplication, window: CGWindowID?)?
        var steady = 0
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return false }
            let front = NSWorkspace.shared.frontmostApplication
            // Steady per window, as Windows compares window handles.
            let window = front.flatMap { WindowList.onScreen($0.processIdentifier).first?.id }
            let nowhere = front.map { InsertionRules.isNowhere(Self.frontApp($0), accessibility: AXReader.available) } ?? true
            // The left or right button still held: the user is still clicking (Windows `PasteSpot.MouseDown`).
            let clicking = NSEvent.pressedMouseButtons & 0b11 != 0
            guard let front, !nowhere, !clicking, front == seen?.app, window == seen?.window else {
                seen = front.map { ($0, window) }
                steady = 0
                continue
            }
            steady += 1
            guard steady >= 2 else { continue }
            let found = read(readContext: false)
            guard await found.spot.value.kind != .none, !Task.isCancelled else { continue }
            Log.info("Placing the dictation where the user clicked: \(Self.processName(front))")
            commit(found, keepContext: true)
            return true
        }
        return false
    }

    /// A dictation's text (Windows `DictationController.InsertPendingAsync`): into the target at the spot it started
    /// at; when that fails, onto the clipboard so it isn't lost.
    func insert(_ text: String) async throws -> String {
        guard let target else {
            keep(text)
            throw UserFacingError("The window you were dictating into was closed. The text was copied to your clipboard.")
        }
        guard CGPreflightPostEventAccess() else {
            CGRequestPostEventAccess()
            keep(text)
            throw UserFacingError("Copied to the clipboard. To paste at the cursor, " + Distribution.allowAccessibility)
        }
        do {
            try await insert(text, into: target, spot: await spot.value)
        } catch {
            // Last resort so the dictation isn't lost: leave it on the clipboard.
            keep(text)
            throw UserFacingError(error.localizedDescription + " The text was copied to your clipboard.")
        }
        return "Inserted into \(target.app.localizedName ?? "the app")"
    }

    /// History's and the dashboard's "insert into the last app" (Windows `InsertIntoLastTargetAsync`): no caret spot,
    /// nothing copied when it fails, and the window that was in front when asked (Oberton, usually) comes back 250 ms
    /// after the paste.
    func insertIntoLastTarget(_ text: String) async throws -> String {
        let front = await frontTarget()
        guard let target else { throw UserFacingError("The window you were dictating into was closed.") }
        guard CGPreflightPostEventAccess() else {
            CGRequestPostEventAccess()
            throw UserFacingError("Text could not be inserted. To paste at the cursor, " + Distribution.allowAccessibility)
        }
        try await insert(text, into: target)
        if let front, !isSame(front, target), isAlive(front) {
            try? await Task.sleep(for: .milliseconds(250)) // the paste lands first
            if front.app == NSRunningApplication.current {
                NSApp.activate()
            } else {
                await waitForModifiersReleased()
                _ = await bringToFront(front)
            }
        }
        return "Inserted into \(target.app.localizedName ?? "the app")"
    }

    /// The window in front now, to come back to.
    private func frontTarget() async -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var front = Target(app: app, nowhere: false)
        if app != NSRunningApplication.current {
            let pid = app.processIdentifier
            front.window = await AXReader.bounded(.milliseconds(400), fallback: nil) { AXReader.focusedWindow(pid) }
        }
        return front
    }

    /// The same window (Windows compares window handles).
    private func isSame(_ a: Target, _ b: Target) -> Bool {
        guard a.app == b.app else { return false }
        if let x = a.window, let y = b.window, AXReader.available { return x.same(y) }
        if let x = a.windowID, let y = b.windowID { return x == y }
        return true
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
        var mode = target.app.bundleIdentifier.flatMap { s.insertionOverride(for: $0) } ?? s.insertion
        // Auto = paste: one atomic operation, reliable in every kind of app. Typing is a fallback (or a per-app choice).
        if mode == .auto { mode = .clipboard }
        let multiLine = InsertionRules.isMultiLine(text)
        var primary: Way = mode == .clipboard ? .paste : .type
        let fallback: Way = mode == .clipboard ? .type : .paste
        if primary == .type && multiLine { primary = .paste } // Enter would submit chat boxes; paste keeps breaks intact
        // Keystrokes may not reach the app while another app has secure keyboard entry on (nothing reports it).
        if IsSecureEventInputEnabled() { Log.info("Secure keyboard entry is on; the keystrokes may not reach \(Self.processName(target.app))") }

        let length = text.utf16.count, process = Self.processName(target.app)
        do {
            try await run(primary, text, keepClipboard: keepClipboard)
            Log.info("Inserted \(length) chars into \(process) via \(primary.name)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.warn("\(primary.name) insertion failed (\(error.localizedDescription)); trying \(fallback.name)")
            if fallback == .type && multiLine { throw UserFacingError("Text could not be inserted into that application.") }
            do {
                try await run(fallback, text, keepClipboard: keepClipboard)
                Log.info("Inserted \(length) chars into \(process) via \(fallback.name) (fallback)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw UserFacingError("Text could not be inserted. Check that Oberton is allowed in System Settings › Privacy & Security › Accessibility.")
            }
        }
    }

    /// The two ways in (Windows' strategies, named as it logs them).
    private enum Way {
        case paste, type
        var name: String { self == .paste ? "Clipboard" : "Typing" }
    }

    private func run(_ way: Way, _ text: String, keepClipboard: Bool) async throws {
        switch way {
        case .paste: try await paste(text, restore: !keepClipboard)
        case .type: try await type(text)
        }
    }

    /// The window (or, without Accessibility, the app's window as the window server lists it) is still there
    /// (Windows `IsWindow`).
    fileprivate func isAlive(_ target: Target) -> Bool {
        if target.app.isTerminated { return false }
        if let window = target.window, AXReader.available { return AXReader.isAlive(window) }
        return WindowList.isAlive(target.windows)
    }

    /// The dictation's window is the one in front: its app is frontmost and that app's focused window is the
    /// dictation's (Accessibility), or, without Accessibility, the window is on screen and no other window the app had
    /// open then has come in front of it.
    fileprivate func isInFront(_ target: Target) -> Bool {
        guard NSWorkspace.shared.frontmostApplication == target.app else { return false }
        if let window = target.window, AXReader.available { return window.same(AXReader.focusedWindow(target.app.processIdentifier)) }
        return WindowList.isFront(target.windows, of: target.app.processIdentifier)
    }

    /// Bring the target back to the front (it normally still is): the app activated, and its window brought out of the
    /// Dock if minimised and raised. False when it didn't come within half a second (the App Store build can't bring a
    /// minimised window back, so it says so rather than typing into another window).
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

    /// Cmd+V with the text on the clipboard, then the user's clipboard back (Windows `ClipboardPasteStrategy`). The app
    /// gets min(1300, 450 + length/20) ms to read it first, also when the clipboard isn't put back right away (live
    /// pastes); the clipboard comes back even when the keystroke couldn't be sent.
    fileprivate func paste(_ text: String, restore: Bool = true) async throws {
        let pb = NSPasteboard.general
        let saved = restore && settings().restoreClipboard ? snapshot(pb) : nil
        put(text, on: pb)
        do {
            try sendShortcut("v", ansi: CGKeyCode(kVK_ANSI_V))
            try await Task.sleep(for: InsertionRules.pasteWait(text)) // let the app read the clipboard first
        } catch {
            if let saved { self.restore(saved, to: pb) }
            throw error
        }
        if let saved { self.restore(saved, to: pb) }
    }

    /// Unicode keystrokes, a few at a time (Windows `UnicodeTypingStrategy`): Chromium and Electron apps drop or repeat
    /// characters when flooded. Batches of 4 UTF-16 units as on Windows, one keystroke per code point so a surrogate
    /// pair is never split. Doesn't touch the clipboard.
    fileprivate func type(_ text: String) async throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let batches = InsertionRules.typingBatches(text)
        for (i, batch) in batches.enumerated() {
            try Task.checkCancellation()
            for units in batch {
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { throw PostFailed() }
                    e.flags = []
                    e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    e.post(tap: .cghidEventTap)
                }
            }
            if i + 1 < batches.count { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    /// `count` Backspaces, a few at a time like typing (Windows `TextInserter.EraseAsync`).
    fileprivate func backspace(_ count: Int) async throws {
        for start in stride(from: 0, to: count, by: 4) {
            try Task.checkCancellation()
            for _ in start..<min(start + 4, count) { try sendKey(CGKeyCode(kVK_Delete)) } // Backspace
            if start + 4 < count { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    private func sendKey(_ key: CGKeyCode) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { throw PostFailed() }
            e.flags = []
            e.post(tap: .cghidEventTap)
        }
    }

    /// ⌘ down, the letter down and up, ⌘ up (Windows: Ctrl, VK_V, VK_V up, Ctrl up). The letter's key is the one
    /// that gives it with ⌘ held on the current keyboard layout, so the shortcut is ⌘V on Dvorak or AZERTY too.
    private func sendShortcut(_ letter: Character, ansi: CGKeyCode) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = Self.keyCode(for: letter, ansi: ansi), command = CGKeyCode(kVK_Command)
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false) else { throw PostFailed() }
        for e in [commandDown, down, up] { e.flags = .maskCommand }
        commandUp.flags = []
        for e in [commandDown, down, up, commandUp] { e.post(tap: .cghidEventTap) }
    }

    /// The key that gives `letter` with ⌘ held on the current keyboard layout (else its ASCII-capable one), as
    /// Windows' virtual key follows the layout. The ANSI key when the layout has none (or can't be read).
    static func keyCode(for letter: Character, ansi: CGKeyCode) -> CGKeyCode {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                       TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()]
        for case let source? in sources {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { continue }
            let found = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                InsertionRules.keyCode(for: letter, preferred: ansi) { character(layout, key: $0) }
            }
            if let found { return CGKeyCode(found) }
        }
        return ansi
    }

    /// What `key` types with ⌘ held on `layout` (dead keys left out), or nil.
    private static func character(_ layout: UnsafePointer<UCKeyboardLayout>, key: UInt16) -> String? {
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF), UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    func copy(_ text: String) {
        // DictationController.CopyPlacingToClipboard logs a clipboard that wouldn't take it.
        if !put(text, on: NSPasteboard.general) { Log.warn("Copying the dictation failed: the clipboard didn't take the text") }
    }

    /// The text left on the clipboard as a last resort, when it couldn't go in: an ordinary copy, so clipboard managers
    /// keep it too (Windows' Clipboard.SetText in DictationController.InsertPendingAsync).
    fileprivate func keep(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @discardableResult
    private func put(_ text: String, on pb: NSPasteboard) -> Bool {
        pb.clearContents()
        guard pb.setString(text, forType: .string) else { return false }
        // Clipboard managers that follow nspasteboard.org leave the temporary text out of their history.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        return true
    }

    // MARK: Type as you speak

    /// The window this dictation types into while the user speaks; nil when there is none (Windows' `IsNowhere` check
    /// at the start: the desktop, the Dock).
    func liveTarget() -> LiveTarget? {
        guard let target, !target.nowhere else { return nil }
        return MacLiveTarget(platform: self, target: { [weak self] in self?.target ?? target }, spot: spot)
    }

    // MARK: Read aloud

    /// The selected text, as the Windows `SelectionReader`: asked through Accessibility first (the direct build only; no
    /// side effects), else copied with Cmd+C and the user's clipboard put back. nil when nothing is selected.
    func selectedText() async -> String? {
        if NSApp.isActive {
            // Oberton's own window is in front: its text view is asked directly, with no side effects, as Windows' UI
            // Automation reads its own window; anything else (no text view has the focus) is copied, as Windows copies
            // when the focused control has no text pattern.
            if let text = Self.ownSelection() { return text.isEmpty ? nil : text }
            return await copySelection()
        }
        if let text = await SelectionReader.accessibility() { return text.isEmpty ? nil : text }
        return await copySelection()
    }

    /// The selection in Oberton's own focused text view (Windows' SelectionReader through UI Automation): each range up
    /// to 100,000 UTF-16 units, joined and trimmed; "" when nothing is selected; nil when no text view has the focus.
    private static func ownSelection() -> String? {
        guard let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder as? NSTextView else { return nil }
        let text = view.string as NSString
        let parts = view.selectedRanges.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= text.length }
            .map { InsertionRules.capped(text.substring(with: $0)) }
        return parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Without Accessibility, another app's selection can be neither asked for nor copied (Windows needs no permission).
    var selectionUnavailable: String? {
        NSApp.isActive || CGPreflightPostEventAccess() ? nil
            : "To read the selected text aloud, allow Oberton in System Settings › Privacy & Security › Accessibility."
    }

    /// Cmd+C, then the clipboard back. nil if the app copied nothing (nothing selected).
    private func copySelection() async -> String? {
        let pb = NSPasteboard.general
        if !NSApp.isActive {
            guard CGPreflightPostEventAccess() else {
                CGRequestPostEventAccess()
                return nil
            }
            // The Read aloud hotkey's own modifiers may still be held; Cmd+Shift+C means something else in many apps.
            await waitForModifiersReleased()
        }
        // Taken after the wait, as Windows does: a clipboard change while the keys were held isn't the copy.
        let before = pb.changeCount
        let saved = snapshot(pb)
        if NSApp.isActive {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        } else {
            try? sendShortcut("c", ansi: CGKeyCode(kVK_ANSI_C))
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

    /// The clipboard's items, to put back afterwards; a type the app on the clipboard couldn't give is logged
    /// (TextInserter's "Could not snapshot clipboard: …") and left out.
    fileprivate func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        var missing: [NSPasteboard.PasteboardType] = []
        let items = (pb.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in
                if let data = item.data(forType: t) { return (t, data) }
                missing.append(t)
                return nil
            })
        }
        if !missing.isEmpty {
            Log.warn("Could not snapshot clipboard: no data for \(missing.map(\.rawValue).joined(separator: ", "))")
        }
        return items
    }

    /// The saved clipboard back, whatever is on it now (Windows `ClipboardSnapshot.Restore`); empty → cleared.
    fileprivate func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let written = pb.writeObjects(items.map { types in
            let item = NSPasteboardItem()
            for (t, d) in types { item.setData(d, forType: t) }
            return item
        })
        if !written { Log.warn("Could not restore clipboard: the saved items could not be written") }
    }
}

/// The window server's list of windows: ids, owners, layers, bounds and order only, which needs no permission (the App
/// Store build too). How a dictation's window is told from its app's others without Accessibility.
enum WindowList {
    struct Window {
        let id: CGWindowID
        let bounds: CGRect
    }

    /// The app's ordinary windows on screen (layer 0, visible, not a sliver), front to back.
    static func onScreen(_ pid: pid_t) -> [Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? Int) == Int(pid), (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0, let id = w[kCGWindowNumber as String] as? Int,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width >= 2, bounds.height >= 2 else { return nil }
            return Window(id: CGWindowID(id), bounds: bounds)
        }
    }

    /// The window still exists (minimised, hidden or on another Space included).
    static func exists(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == Int(id) }
    }

    /// The dictation's window is still there (Windows `IsWindow`), from the app's windows when it started, front to
    /// back: closed when a window in front of the first one still there has gone and wasn't just a pop-up or sheet
    /// lying inside one of the app's other windows (those come and go with what the user types). True when the app had
    /// no window to tell.
    static func isAlive(_ windows: [Window]) -> Bool {
        for (i, window) in windows.enumerated() {
            if exists(window.id) { return true }
            let popUp = windows[(i + 1)...].contains { $0.bounds.contains(window.bounds) }
            if !popUp { return false }
        }
        return windows.isEmpty
    }

    /// The dictation's window is the app's front one (Windows: GetForegroundWindow() is the target's window): the first
    /// of the app's windows on screen now is the first of those it had when the dictation started that is still there,
    /// or a window opened since that lies inside it (a pop-up list, a completion list, a sheet: without Accessibility
    /// the window server can't tell those apart, and a pop-up list must not stop the typing). Another window opened
    /// since (a new document, a new message) is in front instead, as on Windows; one minimised or on another Space isn't
    /// in front.
    static func isFront(_ windows: [Window], of pid: pid_t) -> Bool {
        isFront(windows, now: onScreen(pid), exists: exists)
    }

    static func isFront(_ windows: [Window], now: [Window], exists: (CGWindowID) -> Bool) -> Bool {
        guard let mine = windows.first(where: { exists($0.id) }) else { return true }
        let then = Set(windows.map(\.id))
        for window in now {
            if window.id == mine.id { return true }
            if then.contains(window.id) { return false }
            if !mine.bounds.contains(window.bounds) { return false } // a new window of its own in front
        }
        return false
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
        if InsertionRules.isMultiLine(text) || target.app.bundleIdentifier.flatMap({ s.insertionOverride(for: $0) }) == .clipboard {
            try await platform.insert(text, into: target)
            return
        }
        try await ready()
        try await platform.type(text)
    }

    func erase(_ text: String) async throws {
        // One Backspace per Character: macOS editors delete a whole emoji, flag or accented letter with one (Windows
        // counts code points, which here would also take the characters before it).
        let count = text.count
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

    /// The user's clipboard back, whatever is on it now (Windows `ReleaseClipboardAsync` → `snapshot.Restore()`).
    func restoreClipboard() {
        guard let saved = savedClipboard else { return }
        savedClipboard = nil
        platform.restore(saved, to: NSPasteboard.general)
    }

    func forgetClipboard() { savedClipboard = nil }

    func copy(_ text: String) { platform.keep(text) }
}

extension MacPlatform {
    fileprivate var settingsNow: AppSettings { settings() }
}
#endif
