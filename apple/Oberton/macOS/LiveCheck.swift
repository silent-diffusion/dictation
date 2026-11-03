#if os(macOS) && DEBUG
import AppKit
import ApplicationServices
import ObertonCore

/// Debug only: drives real dictations into TextEdit and Notes, a WAV made with `say` played in place of the microphone,
/// and reads the documents back through Accessibility, to check the direct build's Accessibility paths: type as you
/// speak (streaming, final pass, cancel), fitting into the surrounding text, the caret put back (PasteSpot), the window
/// target (another window, a minimised one), the selection for Read aloud, the window title and placeholder detection.
/// `OBERTON_LIVE_CHECK=<folder with doc1.txt and doc2.txt> OBERTON_DATA_DIR=<scratch>` (`OBERTON_LIVE_CHECK_NOTES=0`
/// leaves Notes out: each run leaves a new note there); needs Oberton allowed in
/// Accessibility, so launch it with `open -n` (Oberton is then the responsible process). Results go to the log
/// (`logs/dictation.log` in the data folder), one "LiveCheck:" line per check.
@MainActor
enum LiveCheck {
    private static var failures = 0

    static func run(_ model: AppModel, folder: String) {
        Task { @MainActor in
            log("start; direct \(Distribution.isDirect), sandboxed \(Distribution.isSandboxed), AX trusted \(AXIsProcessTrusted()), post events \(CGPreflightPostEventAccess())")
            guard Distribution.axTrusted, CGPreflightPostEventAccess() else {
                log("FAIL: Oberton isn't allowed in Accessibility; nothing to check")
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                try? await Task.sleep(for: .seconds(1))
                exit(2)
            }
            let dir = URL(fileURLWithPath: folder)
            if ProcessInfo.processInfo.environment["OBERTON_LIVE_CHECK_ACTIVATE"] == "1" { return await activation(dir) }
            let rawID = BuiltInProfiles.rawID
            let cleanup = model.profiles.first { !$0.isRaw && !$0.showPreview && !$0.rewriteWhole }?.id
            log("AI: Apple Intelligence \(AppleIntelligenceBackend.unavailableReason ?? "available"); cleanup profile \(model.profiles.first { $0.id == cleanup }?.name ?? "none")")
            model.settings.restoreClipboard = true

            let long = try! wav(dir, "long", "This is the first sentence of the live check. It keeps going for a little while so that the recognizer settles it. "
                + "Here is a second sentence that arrives a few seconds later. And this third sentence ends the whole test.")
            let short = try! wav(dir, "short", "Quickly.")

            // Earlier runs' test windows are saved and closed first, so typing can't go into one of them.
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first {
                let windows = (AXReader.attribute(AXReader.app(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]) ?? []
                for w in windows where ["doc1", "doc2"].contains(where: { AXReader.string(w, kAXTitleAttribute)?.contains($0) == true }) {
                    log("closing an earlier test window: \(AXReader.string(w, kAXTitleAttribute) ?? "?")")
                    await close(Doc(pid: app.processIdentifier, window: w, text: w))
                }
            }

            // TextEdit: one document, its text at a known place.
            guard let edit = await open(dir.appending(path: "doc1.txt"), app: "com.apple.TextEdit") else { return finish() }
            let clipboardBefore = "clipboard before the checks"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(clipboardBefore, forType: .string)

            // 1. Type as you speak, Raw profile: the running guess streams in, the final pass replaces it.
            model.settings.typeWhileSpeaking = true
            model.settings.activeProfileID = rawID
            setText(edit, "Start. ")
            var snapshots: [String] = []
            await dictate(model, long, tick: { snapshots.append(text(edit)) })
            let distinct = snapshots.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
            check("raw live: text appeared while speaking (\(distinct.count) states)", distinct.contains { $0.count > "Start. ".count })
            check("raw live: document = start + what was inserted", text(edit) == "Start. " + (model.lastEntry?.inserted ?? "?"), text(edit))
            log("raw live states: " + distinct.map { "\"\($0)\"" }.joined(separator: " → "))
            try? await Task.sleep(for: .seconds(1.5))
            check("raw live: clipboard put back", NSPasteboard.general.string(forType: .string) == clipboardBefore,
                  NSPasteboard.general.string(forType: .string) ?? "nil")

            // 2. Type as you speak with an AI profile: finished pieces typed, then the final pass replaces them.
            if let cleanup {
                model.settings.activeProfileID = cleanup
                setText(edit, "Second check. ")
                snapshots = []
                await dictate(model, long, tick: { snapshots.append(text(edit)) })
                let typedLive = snapshots.contains { $0.count > "Second check. ".count }
                check("AI live: a piece was typed while speaking", typedLive, snapshots.last ?? "")
                check("AI live: document = start + final pass", text(edit) == "Second check. " + (model.lastEntry?.inserted ?? "?"), text(edit))
                log("AI live: document ends \"\(text(edit).suffix(12))\", inserted ends \"\((model.lastEntry?.inserted ?? "").suffix(12))\"")
                try? await Task.sleep(for: .seconds(2))
                log("AI live: 2 s later the document ends \"\(text(edit).suffix(12))\"")
                check("AI live: no note (final pass replaced the live text)", model.lastEntry?.warning == nil, model.lastEntry?.warning ?? "")
            }

            // 3. Cancel during a live dictation removes what was typed.
            model.settings.activeProfileID = rawID
            setText(edit, "Cancel check. ")
            LiveTranscriber.fakeAudio = long
            model.start()
            var typedBeforeCancel = ""
            for _ in 0..<80 {
                try? await Task.sleep(for: .milliseconds(250))
                typedBeforeCancel = text(edit)
                if typedBeforeCancel.count > "Cancel check. ".count + 20 { break }
            }
            model.cancel()
            LiveTranscriber.fakeAudio = nil
            try? await Task.sleep(for: .seconds(3))
            check("cancel: text was typed before the cancel", typedBeforeCancel.count > "Cancel check. ".count, typedBeforeCancel)
            check("cancel: typed text removed", text(edit) == "Cancel check. ", text(edit))

            // 4. Fit into the surrounding text (live typing off): "Quickly." mid-sentence goes in as "quickly".
            model.settings.typeWhileSpeaking = false
            model.settings.matchSurroundingText = true
            setText(edit, "We need to finish this before Friday.")
            setCaret(edit, ("We need to finish this " as NSString).length)
            await dictate(model, short)
            check("fit: mid-sentence phrase lowercased, no period", text(edit).hasPrefix("We need to finish this quickly"), text(edit))
            log("fit: \"\(text(edit))\", context was \(String(describing: model.insertionContext))")

            // 5. PasteSpot: the caret is moved while recording; the text goes where the dictation started.
            model.settings.matchSurroundingText = false
            setText(edit, "Alpha. Omega.")
            setCaret(edit, ("Alpha. " as NSString).length)
            await dictate(model, short, during: { setCaret(edit, (text(edit) as NSString).length) })
            check("caret restored: text went after Alpha", text(edit).hasPrefix("Alpha. Quickly") || text(edit).hasPrefix("Alpha. quickly"), text(edit))

            // 6. The window, not the app: another TextEdit window comes to the front while recording.
            if let other = await open(dir.appending(path: "doc2.txt"), app: "com.apple.TextEdit") {
                setText(other, "Other window. ")
                raise(edit)
                try? await Task.sleep(for: .milliseconds(500))
                setText(edit, "Window check. ")
                await dictate(model, short, during: { raise(other) })
                check("window target: text went into the first window", text(edit).hasPrefix("Window check. Quickly"), "first: \(text(edit)) / other: \(text(other))")
                check("window target: the other window untouched", text(other) == "Other window. ", text(other))

                // 7. The window minimised to the Dock while recording comes back for the paste.
                setText(edit, "Minimised check. ")
                await dictate(model, short, during: {
                    AXReader.set(edit.window, kAXMinimizedAttribute, kCFBooleanTrue)
                })
                check("minimised: window restored and text inserted", text(edit).hasPrefix("Minimised check. Quickly"), text(edit))
                check("minimised: window not minimised now", AXReader.bool(edit.window, kAXMinimizedAttribute) == false)
            }

            // 8. Read aloud's selection through Accessibility: no clipboard change.
            setText(edit, "Read this part only, not the rest.")
            raise(edit)
            try? await Task.sleep(for: .milliseconds(400))
            AXReader.select(edit.text, CFRange(location: 0, length: ("Read this part only" as NSString).length))
            let changeCount = NSPasteboard.general.changeCount
            let selected = await model.platform?.selectedText()
            check("selection read through Accessibility", selected == "Read this part only", selected ?? "nil")
            check("selection: clipboard untouched", NSPasteboard.general.changeCount == changeCount)

            // 9. The front window's title (for History, lane J).
            let title = await AXReader.frontWindowTitle()
            check("front window title read", title?.contains("doc1") == true, title ?? "nil")

            // 10. Notes: type as you speak into a new note.
            if ProcessInfo.processInfo.environment["OBERTON_LIVE_CHECK_NOTES"] != "0", let notes = await openNotes() {
                model.settings.typeWhileSpeaking = true
                model.settings.activeProfileID = rawID
                let before = text(notes)
                await dictate(model, long)
                let after = text(notes)
                check("Notes: live dictation went in", after.contains(model.lastEntry?.inserted ?? "\u{1}"), after)
                check("Notes: final pass replaced the live text (no note)", model.lastEntry?.warning == nil, model.lastEntry?.warning ?? "")
                log("Notes before \"\(before)\" after \"\(after)\"")
                // Placeholder detection: Notes' search field shows "Search" but is empty.
                key(0x03, [.maskCommand, .maskAlternate]) // ⌥⌘F
                try? await Task.sleep(for: .milliseconds(800))
                if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, let field = AXReader.focusedElement(pid) {
                    let ctx = AXReader.context(pid)
                    log("Notes search field: role \(AXReader.string(field, kAXRoleAttribute) ?? "?"), placeholder \(AXReader.string(field, kAXPlaceholderValueAttribute) ?? "nil"), value \(AXReader.string(field, kAXValueAttribute) ?? "nil")")
                    check("placeholder: an empty field with a placeholder reads as empty", ctx == InsertionContext(before: "", after: ""), String(describing: ctx))
                }
                key(0x35, []) // Esc
            }

            // 11. Nowhere to type by control type: the Finder's desktop and a Finder window's file list.
            if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                let spot = await AXReader.bounded(.milliseconds(400), fallback: PasteSpot.unknown) { AXReader.spot(finder.processIdentifier, bundleID: "com.apple.finder") }
                log("Finder (not in front) spot: \(spot.kind)")
            }

            check("clipboard is the user's at the end", NSPasteboard.general.string(forType: .string) == clipboardBefore,
                  NSPasteboard.general.string(forType: .string) ?? "nil")
            // The test documents are saved (they are scratch files) and closed, so TextEdit is left as it was.
            for doc in opened { await close(doc) }
            finish()
        }
    }

    /// Which ways of bringing an app back to the front work for Oberton (an accessory app, not active itself).
    private static func activation(_ dir: URL) async {
        guard let edit = await open(dir.appending(path: "doc1.txt"), app: "com.apple.TextEdit"),
              let textEdit = NSRunningApplication(processIdentifier: edit.pid),
              let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { return finish() }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let ways: [(String, () async -> Void)] = [
            ("NSRunningApplication.activate()", { textEdit.activate() }),
            ("activate(options: .activateAllWindows)", { textEdit.activate(options: [.activateAllWindows]) }),
            ("AXFrontmost", { AXReader.set(AXReader.app(edit.pid), kAXFrontmostAttribute, kCFBooleanTrue) }),
            ("AXRaise + AXMain + AXFrontmost", { AXReader.restore(AXRef(element: edit.window)) }),
        ]
        for (name, way) in ways {
            _ = try? await NSWorkspace.shared.openApplication(at: finderURL, configuration: config)
            try? await Task.sleep(for: .seconds(1))
            let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            await way()
            try? await Task.sleep(for: .milliseconds(500))
            log("activation by \(name): front before \(before), after \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
        }
        for doc in opened { await close(doc) }
        finish()
    }

    // MARK: Helpers

    struct Doc { let pid: pid_t; let window: AXUIElement; let text: AXUIElement }

    private static func log(_ s: String) { Log.info("LiveCheck: " + s) }

    private static var opened: [Doc] = []

    private static func close(_ doc: Doc) async {
        raise(doc)
        try? await Task.sleep(for: .milliseconds(400))
        key(0x01, .maskCommand) // ⌘S
        try? await Task.sleep(for: .milliseconds(600))
        if let button = AXReader.element(doc.window, kAXCloseButtonAttribute) { AXUIElementPerformAction(button, kAXPressAction as CFString) }
        try? await Task.sleep(for: .milliseconds(400))
    }

    private static func check(_ what: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        log((ok ? "PASS " : "FAIL ") + what + (ok || detail.isEmpty ? "" : " — got \"\(detail)\""))
    }

    private static func finish() {
        log("done, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    private static func wav(_ dir: URL, _ name: String, _ words: String) throws -> URL {
        let url = dir.appending(path: "\(name).wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEI16@16000", words]
        try say.run()
        say.waitUntilExit()
        return url
    }

    /// Run one dictation of `audio`; `during` runs a second into the recording, `tick` every 250 ms while it runs.
    private static func dictate(_ model: AppModel, _ audio: URL, during: (() -> Void)? = nil, tick: (() -> Void)? = nil) async {
        if let app = NSWorkspace.shared.frontmostApplication, let w = AXReader.focusedWindow(app.processIdentifier) {
            log("before dictating: front \(app.bundleIdentifier ?? "?"), focused window \"\(AXReader.title(w) ?? "?")\"")
        }
        LiveTranscriber.fakeAudio = audio
        let seconds = (try? WhisperAudio.samples(audio).count).map { Double($0) / 16_000 } ?? 5
        model.start()
        let started = Date()
        var did = false
        while Date().timeIntervalSince(started) < seconds + 0.8 {
            try? await Task.sleep(for: .milliseconds(250))
            tick?()
            if !did, Date().timeIntervalSince(started) > 1 { did = true; during?() }
        }
        model.stop()
        for _ in 0..<400 where model.phase.isBusy {
            try? await Task.sleep(for: .milliseconds(100))
            tick?()
        }
        LiveTranscriber.fakeAudio = nil
        try? await Task.sleep(for: .milliseconds(900)) // the paste lands and the clipboard comes back
        log("dictation ended \(model.phase.label): heard \"\(model.lastEntry?.transcription ?? "")\", inserted \"\(model.lastEntry?.inserted ?? "")\"")
    }

    private static func open(_ file: URL, app bundleID: String) async -> Doc? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: config)
        let name = file.deletingPathExtension().lastPathComponent
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let windows = (AXReader.attribute(AXReader.app(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]) ?? []
            guard let window = windows.first(where: { AXReader.string($0, kAXTitleAttribute)?.contains(name) == true }),
                  let text = find(kAXTextAreaRole, in: window) else { continue }
            raise(Doc(pid: app.processIdentifier, window: window, text: text))
            AXReader.set(text, kAXFocusedAttribute, kCFBooleanTrue)
            try? await Task.sleep(for: .milliseconds(400))
            log("opened \(file.lastPathComponent) in \(bundleID); front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
            let doc = Doc(pid: app.processIdentifier, window: window, text: text)
            opened.append(doc)
            return doc
        }
        let front = NSWorkspace.shared.frontmostApplication
        let titles = front.flatMap { (AXReader.attribute(AXReader.app($0.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]) }?
            .compactMap { AXReader.string($0, kAXTitleAttribute) } ?? []
        check("open \(file.lastPathComponent)", false, "front \(front?.bundleIdentifier ?? "?"), windows \(titles)")
        return nil
    }

    private static func find(_ role: String, in e: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if AXReader.string(e, kAXRoleAttribute) == role { return e }
        guard depth < 8, let children = AXReader.attribute(e, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children { if let found = find(role, in: child, depth: depth + 1) { return found } }
        return nil
    }

    /// Notes with a new note (⌘N), its body focused.
    private static func openNotes() async -> Doc? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else { return nil }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.Notes" {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(1))
        key(0x2D, .maskCommand) // ⌘N
        try? await Task.sleep(for: .seconds(1.5))
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.Notes",
              let window = AXReader.focusedWindow(app.processIdentifier)?.element,
              let text = AXReader.focusedElement(app.processIdentifier) else {
            check("open a new note", false)
            return nil
        }
        log("new note: focused role \(AXReader.string(text, kAXRoleAttribute) ?? "?")")
        return Doc(pid: app.processIdentifier, window: window, text: text)
    }

    private static func text(_ doc: Doc) -> String { AXReader.string(doc.text, kAXValueAttribute) ?? "" }

    private static func setText(_ doc: Doc, _ s: String) {
        AXReader.set(doc.text, kAXValueAttribute, s as CFString)
        setCaret(doc, (s as NSString).length)
    }

    private static func setCaret(_ doc: Doc, _ at: Int) { AXReader.select(doc.text, CFRange(location: at, length: 0)) }

    private static func raise(_ doc: Doc) {
        AXReader.set(AXReader.app(doc.pid), kAXFrontmostAttribute, kCFBooleanTrue)
        AXReader.restore(AXRef(element: doc.window))
    }

    private static func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .combinedSessionState), virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}
#endif
