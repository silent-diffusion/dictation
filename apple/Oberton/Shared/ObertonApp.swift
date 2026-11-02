import ObertonCore
import SwiftUI

@main
struct ObertonApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }
    #else
    @StateObject private var model = AppModel()
    @State private var platform = PhonePlatform()
    #endif

    #if os(macOS)
    var body: some Scene {
        WindowGroup("Oberton", id: "main") {
            ContentView().environmentObject(model)
        }
        .defaultSize(width: 980, height: 700)

        MenuBarExtra("Oberton", systemImage: "waveform") {
            MenuBarContent().environmentObject(model)
        }
    }
    #else
    var body: some Scene {
        WindowGroup("Oberton", id: "main") {
            ContentView()
                .environmentObject(model)
                .task {
                    model.platform = platform
                    await platform.requestPermissions()
                }
        }
    }
    #endif
}

#if os(macOS)
import AppKit

/// Owns what lives as long as the app: the hotkeys and the overlay. Closing the window keeps Oberton running in the
/// menu bar, as the Windows app keeps running in the tray.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private lazy var platform = MacPlatform { [unowned self] in self.model.settings }
    private let hotkeys = HotkeyManager()
    private var overlay: OverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.platform = platform
        overlay = OverlayController(model: model)
        registerHotkeys()
        Task { await platform.requestPermissions() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func registerHotkeys() {
        let s = model.settings
        let failed = hotkeys.register([
            (s.hotkey, { [weak self] in self?.model.toggleDictation() }),
            (s.cycleProfileHotkey, { [weak self] in self?.model.cycleProfile() }),
            (s.speakHotkey, { [weak self] in self?.model.readSelection() }),
        ])
        if !failed.isEmpty { NSLog("Oberton: couldn't register hotkeys %@", failed.joined(separator: ", ")) }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.phase == .recording ? "Stop dictating" : "Dictate") { model.toggleDictation() }
        Text(model.phase.label)
        Divider()
        Picker("Profile", selection: Binding(get: { model.activeProfile.id }, set: { id in
            if let p = model.profiles.first(where: { $0.id == id }) { model.activeProfile = p }
        })) {
            ForEach(model.profiles) { Text($0.name).tag($0.id) }
        }
        Button("Read selection aloud") { model.readSelection() }
        if let last = model.lastEntry { Button("Copy last dictation") { Clipboard.copy(last.inserted) } }
        Divider()
        Button("Open Oberton") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Quit Oberton") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
#endif
