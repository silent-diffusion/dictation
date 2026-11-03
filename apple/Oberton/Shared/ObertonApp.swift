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
            // The speech engine couldn't start at launch (Windows' message box).
            .alert("Oberton", isPresented: Binding(get: { model.startupProblem != nil }, set: { if !$0 { model.startupProblem = nil } })) {
                Button("OK") { model.startupProblem = nil }
            } message: {
                Text(model.startupProblem ?? "")
            }
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
            }
            OverlayPill(reader: model.reader, open: $showReceipt)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .scaleEffect(0.92)
        .animation(.easeOut(duration: 0.2), value: model.phase)
        .onChange(of: model.phase) { _, new in if case .done = new {} else { showReceipt = false } }
    }
}
#endif

#if os(macOS)
import AppKit
import Combine

/// Owns what lives as long as the app: the hotkeys and the overlay. Closing the window keeps Oberton running in the
/// menu bar, as the Windows app keeps running in the tray.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private lazy var platform = MacPlatform { [unowned self] in self.model.settings }
    private let hotkeys = HotkeyManager()
    private var overlay: OverlayController?
    private var reader: ReaderController?
    private var watch: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["OBERTON_SNAPSHOT"] != nil { Snapshots.write(to: ProcessInfo.processInfo.environment["OBERTON_SNAPSHOT"]!, model: model); return }
        #endif
        model.platform = platform
        overlay = OverlayController(model: model)
        reader = ReaderController(model: model)
        // Re-register as soon as a shortcut changes in Settings, and let go of them while one is being recorded.
        // (@Published sends before the value is stored, so the values come from the publishers.) The Extended Notes
        // marker key is held only while a session records (paused or not); the rest of the time it stays with
        // whatever app uses it.
        watch = model.$settings.map { [$0.hotkey, $0.cycleProfileHotkey, $0.speakHotkey, $0.notesMarkerHotkey] }.removeDuplicates()
            .combineLatest(HotkeyStatus.shared.$recording.map { $0 != nil }.removeDuplicates(),
                           model.notes.$current.map { $0 != nil }.removeDuplicates())
            .sink { [weak self] keys, paused, notes in self?.registerHotkeys(keys, paused: paused, notesRecording: notes) }
        Task { await platform.requestPermissions() }
    }

    /// Keep a session that is recording, up to now, and the notes draft.
    func applicationWillTerminate(_ notification: Notification) { model.notes.shutdown() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func registerHotkeys(_ keys: [String], paused: Bool, notesRecording: Bool) {
        guard !paused else { hotkeys.register([]); return }
        let errors = hotkeys.register([
            (keys[0], "the dictation shortcut", { [weak self] in self?.model.toggleDictation() }),
            (keys[1], "the profile-switching shortcut", { [weak self] in self?.model.cycleProfile() }),
            (keys[2], "the Read aloud shortcut", { [weak self] in self?.model.readSelection() }),
            (notesRecording ? keys[3] : "", "the Extended Notes marker shortcut", { [weak self] in self?.model.notes.addMarker() }),
        ])
        HotkeyStatus.shared.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if !errors.isEmpty { NSLog("Oberton: %@", errors.joined(separator: " ")) }
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
            ("settings-general", Place(section: .settings, settings: .general)),
            ("settings-appearance", Place(section: .settings, settings: .appearance)),("settings-history", Place(section: .settings, settings: .history)),
            ("settings-models", Place(section: .settings, settings: .models)), ("settings-layout", Place(section: .settings, settings: .layout)),
            ("settings-about", Place(section: .settings, settings: .about)), ("settings-hotkeys", Place(section: .settings, settings: .hotkeys)),
            ("settings-speech", Place(section: .settings, settings: .speech)), ("settings-microphone", Place(section: .settings, settings: .microphone)),
            ("settings-general", Place(section: .settings, settings: .general)),
            ("notes", Place(section: .notes)), ("notes-session", Place(section: .notes, noteSessionID: "20261102-1015")),
            ("notes-edited", Place(section: .notes, noteSessionID: "20261102-1015")),
        ]
        for dark in [false, true] {
            var s = model.settings
            s.theme = dark ? .dark : .light
            for (name, place) in pages {
                NoteSessionView.snapshotTab = name == "notes-edited" ? .edited : .transcript
                // Analytics is long: drawn taller so every section shows.
                let view = RootView(start: place).environmentObject(model).obertonTheme(s).frame(width: 1200, height: name == "analytics" ? 2000 : 780)
                save(view, to: dir, name: "\(name)-\(dark ? "dark" : "light")")
            }
            // Analytics at iPhone width, its cells stacked.
            var phone = s
            phone.sidebarCollapsed = true
            let narrow = AnalyticsView().environmentObject(model).environmentObject(Navigator()).environment(\.horizontalSizeClass, .compact)
                .obertonTheme(phone).frame(width: 390, height: 2900).background(Palette(dark: dark, accentChoice: s.accent).paper)
            save(narrow, to: dir, name: "analytics-phone-\(dark ? "dark" : "light")")
        }
        // Hotkeys with a combination another app holds, and the dictation box recording.
        HotkeyStatus.shared.error = "Ctrl+Alt+D is already used by another app. Choose a different shortcut under Settings › Hotkeys."
        HotkeyStatus.shared.recording = "Start / stop dictation"
        save(RootView(start: Place(section: .settings, settings: .hotkeys)).environmentObject(model).obertonTheme(model.settings).frame(width: 1200, height: 780),
             to: dir, name: "settings-hotkeys-taken")
        HotkeyStatus.shared.error = nil
        HotkeyStatus.shared.recording = nil
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
