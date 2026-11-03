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
            MainWindowContent().environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 780)
        .windowResizability(.contentMinSize)

        MenuBarExtra("Oberton", systemImage: "waveform") {
            MenuBarContent().environmentObject(model)
        }
    }
    #else
    var body: some Scene {
        WindowGroup("Oberton", id: "main") {
            MainWindowContent()
                .environmentObject(model)
                .task {
                    model.platform = platform
                    await platform.requestPermissions()
                }
        }
    }
    #endif
}

/// The main window: the shell, themed from Settings; on iPhone the dictation pill and receipt float over it.
struct MainWindowContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        RootView()
            #if os(macOS)
            .frame(minWidth: 960, minHeight: 600)
            #else
            .overlay(alignment: .bottom) { PhoneOverlay() }
            #endif
            .obertonTheme(model.settings)
    }
}

#if os(iOS)
struct PhoneOverlay: View {
    @EnvironmentObject var model: AppModel
    @State private var showReceipt = false

    var body: some View {
        VStack(spacing: 10) {
            if model.phase == .preview, let pending = model.pending {
                ReceiptCard(entry: pending, preview: true) { model.cancel() }.frame(maxWidth: 360)
            } else if showReceipt, let r = model.receipt {
                ReceiptCard(entry: r) { showReceipt = false }.frame(maxWidth: 360)
            }
            if model.phase != .idle && model.phase != .preview {
                OverlayPill { if case .done = model.phase { showReceipt = true } }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .scaleEffect(0.92)
        .animation(.easeOut(duration: 0.2), value: model.phase)
    }
}
#endif

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
        #if DEBUG
        if ProcessInfo.processInfo.environment["OBERTON_SNAPSHOT"] != nil { Snapshots.write(to: ProcessInfo.processInfo.environment["OBERTON_SNAPSHOT"]!, model: model); return }
        #endif
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

#if DEBUG && os(macOS)
/// Draws each page to a PNG and quits (OBERTON_SNAPSHOT=<folder>), to check the design without a screen recording.
@MainActor
enum Snapshots {
    static func write(to dir: String, model: AppModel) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        model.settings.sidebarCollapsed = false
        model.seedSnapshotData()
        let pages: [(String, Place)] = [
            ("dashboard", Place()), ("profiles", Place(section: .speechToText)), ("readaloud", Place(section: .readAloud)),
            ("history", Place(section: .history)), ("analytics", Place(section: .analytics)),
            ("settings-appearance", Place(section: .settings, settings: .appearance)), ("settings-history", Place(section: .settings, settings: .history)),
            ("settings-models", Place(section: .settings, settings: .models)), ("settings-layout", Place(section: .settings, settings: .layout)),
            ("settings-about", Place(section: .settings, settings: .about)),
        ]
        for dark in [false, true] {
            var s = model.settings
            s.theme = dark ? .dark : .light
            for (name, place) in pages {
                // Analytics is long: drawn taller so every section shows.
                let view = RootView(start: place).environmentObject(model).obertonTheme(s).frame(width: 1200, height: name == "analytics" ? 1500 : 780)
                save(view, to: dir, name: "\(name)-\(dark ? "dark" : "light")")
            }
            // Analytics at iPhone width, its cells stacked.
            var phone = s
            phone.sidebarCollapsed = true
            let narrow = AnalyticsView().environmentObject(model).environmentObject(Navigator()).environment(\.horizontalSizeClass, .compact)
                .obertonTheme(phone).frame(width: 390, height: 2900).background(Palette(dark: dark, accentChoice: s.accent).paper)
            save(narrow, to: dir, name: "analytics-phone-\(dark ? "dark" : "light")")
        }
        let overlay = VStack(spacing: 16) {
            ReceiptCard(entry: HistoryEntry(transcription: "um so the plan for friday is we ship the beta to the uh first ten testers and then we collect feedback",
                                            aiEdit: "The plan for Friday is to ship the beta to the first ten testers, and then collect feedback.",
                                            inserted: "The plan for Friday is to ship the beta to the first ten testers, and then collect feedback.",
                                            profileName: "Light Cleanup", model: nil, appName: "Mail", seconds: 14, turnaroundSeconds: 1.2, warning: nil)) {}
            PillContent(phase: .recording, profile: "Light Cleanup", startedAt: .now,
                        live: "so the plan for friday is we ship the beta to the first ten testers and", opacity: model.settings.overlayOpacity)
        }
        .padding(30).background(Color(hex: 0xC9C7C1)).environmentObject(model).obertonTheme(model.settings)
        let r = ImageRenderer(content: overlay)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "overlay.png"))
        }
        NSApp.terminate(nil)
    }

    private static func save(_ view: some View, to dir: String, name: String) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
    }
}
#endif
