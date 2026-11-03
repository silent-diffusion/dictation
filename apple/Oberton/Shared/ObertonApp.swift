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
        // One main window, as on Windows: opening it again brings it forward. It opens from the delegate at launch
        // (not when Oberton started hidden at login, or the first-run setup shows instead).
        Window("Oberton", id: "main") {
            MainWindowContent().environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 780)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.showMain(settings: .general) }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {}
        }

        Window("Oberton setup", id: "setup") {
            OnboardingView { delegate.finishSetup() }
                .environmentObject(model)
                .obertonTheme(model.settings)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarContent(delegate: delegate).environmentObject(model)
        } label: {
            MenuBarLabel(delegate: delegate)
        }
    }
    #else
    @State private var showSetup = !OnboardingView.isDone && !AppModel.snapshotMode

    var body: some Scene {
        WindowGroup("Oberton", id: "main") {
            MainWindowContent()
                .environmentObject(model)
                .task { model.platform = platform }
                .fullScreenCover(isPresented: $showSetup) {
                    ScrollView { OnboardingView { showSetup = false } }
                        .environmentObject(model)
                        .obertonTheme(model.settings)
                        .background(Palette(dark: model.settings.theme == .dark, accentChoice: model.settings.accent).paper.ignoresSafeArea())
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
import ServiceManagement

/// Owns what lives as long as the app: the hotkeys, the overlay and the menu bar icon. Closing the window keeps
/// Oberton running in the menu bar (Settings › General, as Windows keeps running in the tray); the Dock icon shows only
/// while a window is open, as Windows' taskbar button does.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private lazy var platform = MacPlatform { [unowned self] in self.model.settings }
    private let hotkeys = HotkeyManager()
    private var overlay: OverlayController?
    private var reader: ReaderController?
    private var watch: AnyCancellable?
    private var escapeWatch: AnyCancellable?
    private var loginWatch: AnyCancellable?
    private var problemWatch: AnyCancellable?
    private var windowWatches: [NSObjectProtocol] = []
    private var shownHotkeyError: String?
    /// Opens a window by its scene id; set by the menu bar icon, the first view SwiftUI draws.
    private var openWindow: ((String) -> Void)?
    private var startedHidden = false
    private var launched = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Opened by the login item: start hidden in the menu bar (Windows' --minimized). Asked here, while the launch
        // event is still the current one.
        let event = NSAppleEventManager.shared().currentAppleEvent
        startedHidden = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["OBERTON_SNAPSHOT"] != nil { Snapshots.write(to: ProcessInfo.processInfo.environment["OBERTON_SNAPSHOT"]!, model: model); return }
        #endif
        Log.info("=== Oberton \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") starting" + (startedHidden ? " (at login, hidden)" : "") + " ===")
        NSSetUncaughtExceptionHandler { e in Log.error("Unhandled exception: \(e.name.rawValue): \(e.reason ?? "")") }
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
        // Esc discards, held only while the overlay waits for a decision (App.xaml.cs).
        escapeWatch = model.$phase.map { $0 == .preview || $0 == .placing }.removeDuplicates()
            .sink { [weak self] waiting in
                guard let self else { return }
                if let error = hotkeys.holdEscape(waiting ? { [weak self] in self?.model.cancel() } : nil) { Log.warn(error) }
            }
        loginWatch = model.$settings.map(\.startAtLogin).removeDuplicates().sink { Self.applyLoginItem($0) }
        problemWatch = model.$startupProblem.compactMap { $0 }.sink { Log.warn("Speech init: " + $0) }
        // The Dock icon follows the windows.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            windowWatches.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { MacAppDelegate.updateDockIcon() } }
            })
        }
        launched = true
        showAtLaunch()
    }

    /// The menu bar icon was drawn: from now on windows can be opened.
    func windowOpener(_ open: @escaping (String) -> Void) {
        openWindow = open
        showAtLaunch()
    }

    private var shownAtLaunch = false

    /// At launch: the first-run setup, or the main window unless Oberton started hidden at login.
    private func showAtLaunch() {
        guard launched, let openWindow, !shownAtLaunch else { return }
        shownAtLaunch = true
        if !OnboardingView.isDone {
            open("setup", with: openWindow)
        } else if !startedHidden {
            open("main", with: openWindow)
        }
    }

    private func open(_ id: String, with openWindow: (String) -> Void) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id)
        NSApp.activate()
    }

    /// Open (or bring forward) the main window, optionally at a Settings section.
    func showMain(settings: SettingsSection? = nil) {
        if let settings { model.requestedSettings = settings }
        if let openWindow { open("main", with: openWindow) }
    }

    /// START USING OBERTON: the main window opens before the setup closes (closing the last window may quit).
    func finishSetup() {
        showMain()
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("setup") == true }?.close()
    }

    /// Opening Oberton again (Finder, Spotlight, the Dock) brings the window forward, as Windows' second launch does.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { OnboardingView.isDone ? showMain() : openWindow.map { open("setup", with: $0) } }
        return true
    }

    /// Keep a session that is recording, up to now, and the notes draft.
    func applicationWillTerminate(_ notification: Notification) {
        model.notes.shutdown()
        Log.info("Oberton quitting")
    }

    /// "Keep running in the menu bar when the window is closed" off: closing the window quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !model.settings.minimizeToTray }

    /// A Dock icon while a window (not the overlay or reader panels) is open or minimized; none otherwise.
    private static func updateDockIcon() {
        let open = NSApp.windows.contains { w in
            !(w is NSPanel) && w.styleMask.contains(.titled) && w.canBecomeMain && (w.isVisible || w.isMiniaturized)
        }
        let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// Settings › General › "Start when you log in" (Windows' Autostart.Apply): the app itself as a login item.
    private static func applyLoginItem(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on, service.status != .enabled { try service.register() }
            else if !on, service.status == .enabled { try service.unregister() }
        } catch {
            Log.warn("Login item (\(on ? "on" : "off")): \(error.localizedDescription)")
        }
        if on, service.status == .requiresApproval { Log.warn("Login item waits for approval in System Settings › General › Login Items") }
    }

    private func registerHotkeys(_ keys: [String], paused: Bool, notesRecording: Bool) {
        guard !paused else { hotkeys.register([]); return }
        let errors = hotkeys.register([
            (keys[0], "the dictation shortcut", { [weak self] in self?.model.toggleDictation() }),
            (keys[1], "the profile-switching shortcut", { [weak self] in self?.model.cycleProfile() }),
            (keys[2], "the Read aloud shortcut", { [weak self] in self?.model.readSelection() }),
            (notesRecording ? keys[3] : "", "the Extended Notes marker shortcut", { [weak self] in self?.model.notes.addMarker() }),
        ])
        HotkeyStatus.shared.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if !errors.isEmpty { Log.warn(errors.joined(separator: " ")) }
        // Also on the overlay, as an error notice (App.xaml.cs ApplyHotkeys), once per new problem.
        let error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if let error, error != shownHotkeyError { model.notice(error, kind: .error) }
        shownHotkeyError = error
    }
}

/// The menu bar icon: the Oberton mark (TrayIcon.cs), as a template image so it follows the menu bar's colour. It is
/// the first view SwiftUI draws, so it hands the delegate the way to open windows.
struct MenuBarLabel: View {
    let delegate: MacAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: Self.mark)
            .accessibilityLabel("Oberton")
            .onAppear { delegate.windowOpener { openWindow(id: $0) } }
    }

    /// A rounded square with the dot cut out of it, 16 pt.
    static let mark: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let square = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3.5, yRadius: 3.5)
            square.append(NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 6, height: 6)))
            square.windingRule = .evenOdd
            NSColor.black.setFill()
            square.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// The menu bar's menu, as Windows' tray menu: "Oberton · <profile>" (the tray icon's tooltip, which a menu bar icon
/// can't have), Start / stop dictation, Profile ▸, Open settings, Check for updates… (the D.3 page), Quit.
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    let delegate: MacAppDelegate

    var body: some View {
        Text("Oberton · \(model.activeProfile.name)")
        Divider()
        Button("Start / stop dictation") { model.toggleDictation() }
        Picker("Profile", selection: Binding(get: { model.activeProfile.id }, set: { id in
            if let p = model.profiles.first(where: { $0.id == id }) { model.activeProfile = p }
        })) {
            ForEach(model.profiles) { Text($0.name).tag($0.id) }
        }
        Divider()
        Button("Open settings") { delegate.showMain() }
        Button("Check for updates…") { delegate.showMain(settings: .updates) }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
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
            ("settings-models", Place(section: .settings, settings: .models)), ("settings-cloud", Place(section: .settings, settings: .cloud)),
            ("settings-layout", Place(section: .settings, settings: .layout)),
            ("settings-about", Place(section: .settings, settings: .about)), ("settings-hotkeys", Place(section: .settings, settings: .hotkeys)),
            ("settings-speech", Place(section: .settings, settings: .speech)), ("settings-microphone", Place(section: .settings, settings: .microphone)),
            ("settings-unloading", Place(section: .settings, settings: .unloading)),
            ("settings-updates", Place(section: .settings, settings: .updates)),
            ("settings-advanced", Place(section: .settings, settings: .advanced)),
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
            // The first-run setup: before, while downloading, and done.
            let setups: [(String, OnboardingView)] = [
                ("setup", OnboardingView(finish: {})),
                ("setup-running", OnboardingView(snapshot: .running, step: 3, title: "Step 3 of 4: Speech model", fraction: 0.42,
                                                 detail: "Downloading the English (United States) speech model  (42%)")),
                ("setup-done", OnboardingView(snapshot: .done, step: 4, title: "All set!", fraction: 1,
                                              detail: "Press \(model.settings.hotkey) in any app to start dictating, and press it again to stop.")),
            ]
            for (name, view) in setups {
                save(view.environmentObject(model).obertonTheme(s).fixedSize(horizontal: false, vertical: true), to: dir, name: "\(name)-\(dark ? "dark" : "light")")
            }
            // A folded group stays folded; the open section's group unfolds.
            var folded = s
            let kept = model.settings.collapsedSettingsGroups
            folded.collapsedSettingsGroups = ["A // Dictation", "C // Look & feel"]
            model.settings.collapsedSettingsGroups = folded.collapsedSettingsGroups
            save(RootView(start: Place(section: .settings, settings: .unloading)).environmentObject(model).obertonTheme(folded).frame(width: 1200, height: 780),
                 to: dir, name: "settings-folded-\(dark ? "dark" : "light")")
            model.settings.collapsedSettingsGroups = kept
        }
        save(MenuBarMarkPreview(), to: dir, name: "menubar-mark")
        // The text size at 125% (Appearance › TEXT SIZE, ⌘+).
        let scale = model.settings.uiScale
        model.settings.uiScale = 1.25
        save(RootView(start: Place()).environmentObject(model).obertonTheme(model.settings).frame(width: 1200, height: 780), to: dir, name: "dashboard-zoom125")
        model.settings.uiScale = scale
        // Hotkeys with a combination another app holds, and the dictation box recording.
        HotkeyStatus.shared.error = "Ctrl+Alt+D is already used by another app. Choose a different shortcut under Settings › Hotkeys."
        HotkeyStatus.shared.recording = "Start / stop dictation"
        save(RootView(start: Place(section: .settings, settings: .hotkeys)).environmentObject(model).obertonTheme(model.settings).frame(width: 1200, height: 780),
             to: dir, name: "settings-hotkeys-taken")
        HotkeyStatus.shared.error = nil
        HotkeyStatus.shared.recording = nil
        let overlay = VStack(spacing: 16) {
            ReceiptPill(entry: HistoryEntry(transcription: "um so the plan for friday is we ship the beta to the uh first ten testers and then we collect feedback",
                                            aiEdit: "The plan for Friday is to ship the beta to the first ten testers, and then collect feedback.",
                                            inserted: "The plan for Friday is to ship the beta to the first ten testers, and then collect feedback.",
                                            profileName: "Light Cleanup", model: nil, appName: "Mail", seconds: 14, turnaroundSeconds: 1.2, warning: nil),
                        opacity: model.settings.overlayOpacity)
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

    /// The menu bar mark at 1× and 4×, on light and dark.
    private struct MenuBarMarkPreview: View {
        var body: some View {
            HStack(spacing: 16) {
                ForEach([false, true], id: \.self) { dark in
                    HStack(spacing: 12) {
                        Image(nsImage: MenuBarLabel.mark).renderingMode(.template)
                        Image(nsImage: MenuBarLabel.mark).renderingMode(.template).resizable().interpolation(.high).frame(width: 64, height: 64)
                    }
                    .foregroundStyle(dark ? Color.white : Color.black)
                    .padding(12).background(dark ? Color(white: 0.15) : Color(white: 0.92))
                }
            }
        }
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
