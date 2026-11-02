#if os(macOS)
import AppKit
import ApplicationServices
import AVFoundation
import ObertonCore

/// Puts text where the cursor was when the hotkey was pressed, by pasting (Cmd+V): atomic, so it is reliable in
/// Electron and browser apps, as on Windows. The user's clipboard is put back afterwards.
@MainActor
final class MacPlatform: PlatformServices {
    private var target: NSRunningApplication?
    private let settings: () -> AppSettings

    init(settings: @escaping () -> AppSettings) { self.settings = settings }

    var targetAppName: String? { target?.localizedName }

    func captureTarget() {
        let front = NSWorkspace.shared.frontmostApplication
        target = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
    }

    func insert(_ text: String) async throws -> String {
        let pb = NSPasteboard.general
        let saved = settings().restoreClipboard ? snapshot(pb) : nil
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Clipboard managers that follow nspasteboard.org leave the temporary text out of their history.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        guard let target else {
            return "Copied to the clipboard" // dictated into Oberton itself, or nothing was in front
        }
        guard CGPreflightPostEventAccess() else {
            CGRequestPostEventAccess()
            throw UserFacingError("Copied to the clipboard. To paste at the cursor, allow Oberton in System Settings › Privacy & Security › Accessibility.")
        }
        if NSWorkspace.shared.frontmostApplication != target {
            target.activate()
            try? await Task.sleep(for: .milliseconds(150))
        }
        // Wait for the hotkey's modifiers to be released, or the app would see Ctrl+Cmd+V.
        for _ in 0..<40 where !CGEventSource.flagsState(.combinedSessionState).intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]).isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: down) // V
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        if let saved {
            let count = pb.changeCount
            // Give the app time to read the paste before the old clipboard comes back.
            try? await Task.sleep(for: .milliseconds(700))
            if pb.changeCount == count { restore(saved, to: pb) }
        }
        return "Inserted into \(target.localizedName ?? "the app")"
    }

    func selectedText() async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.isEmpty else { return nil }
        return text
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
