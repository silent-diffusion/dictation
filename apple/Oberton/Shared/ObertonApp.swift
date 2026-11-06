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
        // The windows are AppKit's, owned by the delegate (MacAppDelegate): the main window hides when closed, as
        // Windows' does, and the first-run setup is a window of its own. This scene only carries the menu commands.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { delegate.showMain(settings: .general) }.keyboardShortcut(",")
                }
                CommandGroup(replacing: .newItem) {}
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
            #if os(iOS)
            .overlay(alignment: .bottom) { PhoneOverlay() }
            #endif
            .obertonTheme(model.settings)
            // The speech engine couldn't start at launch (Windows' message box).
            .alert("Oberton", isPresented: Binding(get: { model.startupProblem != nil }, set: { if !$0 { model.startupProblem = nil } })) {
                Button("OK") { model.startupProblem = nil }
            } message: {
                Text(model.startupProblem ?? "")
            }
            .dialogLook(.warning, shown: model.startupProblem != nil) // App.Controller_NoticeBridge: MessageBoxImage.Warning
    }
}

#if os(iOS)
struct PhoneOverlay: View {
    @EnvironmentObject var model: AppModel
    @State private var showReceipt = false
    /// The width the pill may take (the screen's, less the margins, before the 92% scale), so it fits rather than
    /// running off the side.
    @State private var room = CGSize(width: 10_000, height: 10_000)

    var body: some View {
        VStack(spacing: 10) {
            OverlayPill(reader: model.reader, open: $showReceipt)
        }
        .environment(\.overlayRoom, room)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            room = CGSize(width: max(80, size.width - 24) / 0.92, height: 10_000)
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

/// Owns what lives as long as the app: the main window and the first-run setup, the hotkeys, the overlay, the reader
/// and the menu bar icon. As on Windows (App.xaml.cs), the hotkeys, overlay, reader and icon start only once the setup
/// is done, and closing the setup quits. Closing the main window hides it while Oberton keeps running in the menu bar
/// (Settings › General), so it opens again as it was; the Dock icon shows only while a window is open, as Windows'
/// taskbar button does.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    /// Start-up timing (App.xaml.cs' _startClock): from here, how long the services (AppModel) and the windows took.
    private let startClock = Date()
    private var servicesMs = 0, windowsMs = 0
    private var startupReported = false
    let model: AppModel
    private lazy var platform = MacPlatform { [unowned self] in self.model.settings }
    private let hotkeys = HotkeyManager()
    private var overlay: OverlayController?
    private var reader: ReaderController?
    private var watches: [AnyCancellable] = []
    private var windowWatches: [NSObjectProtocol] = []
    /// The shortcuts last applied: a change to them shows any problem on the overlay (App.ApplyHotkeys).
    private var appliedKeys: [String]?
    private var mainWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var setupFinished = false
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var startedHidden = false
    private var servicesStarted = false
    /// The marker key is held (an Extended Notes session records).
    private var markerHeld = false
    /// The start-up card, while it shows.
    private var splash: NSWindow?

    override init() {
        // Before the services, as App.OnStartup logs it before `new AppServices()`: what they log comes after it.
        if !AppModel.snapshotMode { Log.info("=== Oberton starting ===") }
        let before = Date()
        model = AppModel()
        servicesMs = Int(Date().timeIntervalSince(before) * 1000)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Opened by the login item: start hidden in the menu bar (Windows' --minimized). Asked here, while the launch
        // event is still the current one.
        let event = NSAppleEventManager.shared().currentAppleEvent
        startedHidden = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            // Any start with --minimized, as on Windows (`open -a Oberton --args --minimized`).
            || CommandLine.arguments.contains("--minimized")
        NSApp.setActivationPolicy(.accessory)
        // The "Oberton · starting" card until the window is drawn (App.OnStartup's SplashScreen): not when starting
        // hidden, and closed before a first-run setup (Windows shows the setup without it).
        if !startedHidden, OnboardingView.isDone, !Self.debugRun { splash = StartupCard.show() }
    }

    /// A DEBUG run that draws or checks something and quits (snapshots, stress and live checks): no start-up card.
    private static var debugRun: Bool {
        let env = ProcessInfo.processInfo.environment
        return ["OBERTON_SNAPSHOT", "OBERTON_STRESS", "OBERTON_WHISPER_CHECK", "OBERTON_WORDS_CHECK", "OBERTON_LIVE_CHECK"].contains { env[$0] != nil }
    }

    /// CloseSplash: fades out over 250 ms.
    private func closeSplash() {
        guard let card = splash else { return }
        splash = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            card.animator().alphaValue = 0
        }, completionHandler: { card.orderOut(nil) })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["OBERTON_SNAPSHOT"] != nil { Snapshots.write(to: ProcessInfo.processInfo.environment["OBERTON_SNAPSHOT"]!, model: model); return }
        #endif
        // Objective-C exceptions only: a Swift trap can't be caught and kept running as Windows' handlers do.
        NSSetUncaughtExceptionHandler { e in Log.error("Unhandled UI exception: \(e.name.rawValue): \(e.reason ?? "")") }
        #if DEBUG
        // No platform: nothing is typed into other apps.
        if let rounds = ProcessInfo.processInfo.environment["OBERTON_STRESS"] {
            overlay = OverlayController(model: model)
            StressTest.run(model, rounds: Int(rounds) ?? 30)
            return
        }
        if let id = ProcessInfo.processInfo.environment["OBERTON_WHISPER_CHECK"] {
            WhisperCheck.run(model, id: id)
            return
        }
        if let engine = ProcessInfo.processInfo.environment["OBERTON_WORDS_CHECK"] {
            WordsCheck.run(model, engine: engine)
            return
        }
        if let folder = ProcessInfo.processInfo.environment["OBERTON_LIVE_CHECK"] {
            model.platform = platform
            LiveCheck.run(model, folder: folder)
            return
        }
        #endif
        InkSelection.start()
        // The theme applies to every window, the title bars and menus included (ThemeManager).
        watches.append(model.$settings.map(\.theme).removeDuplicates().sink { theme in
            NSApp.appearance = theme == .system ? nil : NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        })
        // The Dock icon follows the windows.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            windowWatches.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { MacAppDelegate.updateDockIcon() } }
            })
        }
        // First run (or a setup left unfinished): the setup before anything else.
        if !OnboardingView.isDone {
            closeSplash()
            showSetup()
            return
        }
        startServices()
        if !startedHidden { showMain() }
    }

    /// The hotkeys, overlay, reader and menu bar icon, started once (after the setup on a first run).
    private func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
        let before = Date()
        model.platform = platform
        overlay = OverlayController(model: model)
        reader = ReaderController(model: model)
        makeStatusItem()
        windowsMs += Int(Date().timeIntervalSince(before) * 1000)
        #if OBERTON_DIRECT
        // The direct download's startup update check (lane A's Updater), after the setup as on Windows.
        Updater.shared.start(model: model)
        #endif
        // Re-register as soon as a shortcut changes in Settings (App.OnSettingsChanged), and only then; they stay held
        // while a Hotkeys box records, as on Windows. (@Published sends before the value is stored, so the values come
        // from the publishers.) The Extended Notes marker key is held only while a session records (paused or not);
        // the rest of the time it stays with whatever app uses it (App.ApplyMarkerHotkey).
        watches.append(model.$settings.map { [$0.hotkey, $0.cycleProfileHotkey, $0.speakHotkey, $0.notesMarkerHotkey] }.removeDuplicates()
            .sink { [weak self] keys in self?.registerHotkeys(keys) })
        watches.append(model.notes.$current.map { $0 != nil }.removeDuplicates()
            .sink { [weak self] recording in self?.applyMarkerHotkey(recording) })
        // Esc discards, held only while the overlay waits for a decision (App.xaml.cs).
        watches.append(model.$phase.map { $0 == .preview || $0 == .placing }.removeDuplicates()
            .sink { [weak self] waiting in
                guard let self else { return }
                if let error = hotkeys.holdEscape(waiting ? { [weak self] in self?.model.cancel() } : nil) { Log.warn(error) }
            })
        // Applied again at every settings change, as App.OnSettingsChanged calls Autostart.Apply: a login item removed in
        // System Settings comes back with the next change, not only at the next launch.
        watches.append(model.$settings.map(\.startAtLogin).sink { Self.applyLoginItem($0) })
        if startedHidden { startupReported = true; closeSplash() } // started hidden: no opening time to report
        // The speech engine couldn't start: the window opens with the message (App.xaml.cs, also when started hidden).
        watches.append(model.$startupProblem.compactMap { $0 }.sink { [weak self] problem in
            Log.warn("Speech init: " + problem)
            self?.showMain()
        })
        // The icon's tooltip names the active profile (TrayIcon.SetTooltip).
        watches.append(model.$settings.map(\.activeProfileID).removeDuplicates().combineLatest(model.$profiles)
            .sink { [weak self] id, profiles in
                let name = (profiles.first { $0.id == id } ?? profiles.first)?.name ?? ""
                let text = "Oberton · \(name)"
                // Cut at 60 UTF-16 units, as `text[..60]` (a tooltip can't take more on Windows).
                self?.statusItem?.button?.toolTip = text.utf16.count > 60 ? String(decoding: Array(text.utf16.prefix(60)), as: UTF16.self) : text
            })
    }

    // MARK: Windows

    /// Open (or bring forward) the main window, optionally at a Settings section (App.ShowMain): shown, un-minimized
    /// and in front, also when it is open already. During the first-run setup only the setup comes forward.
    func showMain(settings: SettingsSection? = nil) {
        guard OnboardingView.isDone, servicesStarted || setupFinished || setupWindow == nil else {
            setupWindow?.makeKeyAndOrderFront(nil)
            return
        }
        if let settings { model.requestedSettings = settings }
        let before = Date()
        let window = mainWindow ?? makeMainWindow()
        if !startupReported { windowsMs += Int(Date().timeIntervalSince(before) * 1000) }
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if !startupReported {
            startupReported = true
            // Once the window is drawn (the next turn of the run loop), as Windows' ContentRendered.
            DispatchQueue.main.async { [self] in
                closeSplash() // ContentRendered
                let elapsed = Int(Date().timeIntervalSince(startClock) * 1000)
                let total = Self.processStart.map { Int(Date().timeIntervalSince($0) * 1000) } ?? elapsed
                Log.info("Startup: window drawn \(total) ms after opening (runtime \(total - elapsed) ms, services \(servicesMs) ms, "
                         + "windows \(windowsMs) ms, the rest \(elapsed - servicesMs - windowsMs) ms)")
            }
        }
    }

    /// When this process started (Process.StartTime).
    private static var processStart: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    /// WindowStartupLocation="CenterScreen": the middle of the screen the mouse is on (AppKit's center() sits higher).
    private static func centerOnScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let area = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded()))
    }

    /// "Oberton", 1200×780 (at least 960×600), centred, its title in the paper-coloured title bar. Not remembered
    /// between launches, as on Windows.
    private func makeMainWindow() -> NSWindow {
        let host = NSHostingController(rootView: MainWindowContent().environmentObject(model))
        // MinWidth 960 / MinHeight 600 are the whole window's, its title bar included (WPF's Window sizes): set on the
        // window, not taken from the content, which sits below the title bar's safe area.
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = host
        window.title = "Oberton"
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 1200, height: 780))
        window.minSize = NSSize(width: 960, height: 600)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.delegate = self
        Self.centerOnScreen(window)
        mainWindow = window
        return window
    }

    /// The first-run setup: "Oberton setup", 640 wide (its frame included), as tall as it needs, centred.
    private func showSetup() {
        let host = NSHostingController(rootView: SetupWindowContent { [weak self] in self?.finishSetup() }.environmentObject(model))
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Oberton setup"
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("setup")
        window.delegate = self
        window.layoutIfNeeded()
        Self.centerOnScreen(window)
        setupWindow = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// START USING OBERTON: now the hotkeys, overlay and menu bar icon start, and the main window opens.
    func finishSetup() {
        setupFinished = true
        model.startupProblem = nil // the launch's warm-up, from before the speech model was there
        startServices()
        showMain()
        setupWindow?.close()
        setupWindow = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === mainWindow {
            // Kept running in the menu bar: the window only hides, its page as it was (MainWindow.OnClosing);
            // otherwise closing it quits.
            if model.settings.minimizeToTray {
                sender.orderOut(nil)
                Self.updateDockIcon()
            } else {
                NSApp.terminate(nil)
            }
            return false
        }
        if sender === setupWindow, !setupFinished {
            // Closing the setup cancels it, and Oberton doesn't start without it (App.xaml.cs exits).
            Log.info("Setup not completed; exiting")
            model.cancelWhisperDownload()
            NSApp.terminate(nil)
            return false
        }
        return true
    }

    /// Opening Oberton again (Finder, Spotlight, the Dock) shows the window, as Windows' second launch does; during the
    /// setup it only comes forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if OnboardingView.isDone { showMain() } else { setupWindow?.makeKeyAndOrderFront(nil) }
        return false
    }

    /// App.Quit: keep a session that is recording, up to now, and the notes draft; stop a reading (so its time is
    /// counted); then the log line. Quitting from the setup logs only "Setup not completed; exiting", as on Windows.
    func applicationWillTerminate(_ notification: Notification) {
        model.notes.shutdown()
        model.reader.stop()
        model.saveProfilesNow()
        if servicesStarted { Log.info("=== Oberton exiting ===") }
    }

    /// Closing a window is handled above (hide, or quit).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A Dock icon while a window (not the overlay or reader panels) is open or minimized; none otherwise.
    private static func updateDockIcon() {
        let open = NSApp.windows.contains { w in
            !(w is NSPanel) && w.styleMask.contains(.titled) && w.canBecomeMain && (w.isVisible || w.isMiniaturized)
        }
        let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    // MARK: Menu bar icon

    /// The tray icon's behaviour: a click opens the window, a right-click (or Control-click) shows the menu.
    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusMark.image
        item.button?.setAccessibilityLabel("Oberton")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.delegate = self
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem?.menu = menu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else {
            showMain()
        }
    }

    /// Windows' tray menu, rebuilt each time it opens: Start / stop dictation, Profile ▸ (the active one checked), Open
    /// settings, Check for updates… (Settings › Updates), Quit.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(ActionItem("Start / stop dictation") { [weak self] in self?.model.toggleDictation() })
        let profiles = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        profiles.submenu = NSMenu()
        let active = model.activeProfile.id
        for p in model.profiles {
            let item = ActionItem(p.name) { [weak self] in self?.model.activeProfile = p }
            item.state = p.id == active ? .on : .off
            profiles.submenu?.addItem(item)
        }
        menu.addItem(profiles)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Open settings") { [weak self] in self?.showMain() })
        menu.addItem(ActionItem("Check for updates…") { [weak self] in self?.showMain(settings: .updates) })
        menu.addItem(ActionItem("Quit") { NSApp.terminate(nil) })
    }

    // MARK: Hotkeys and login

    /// Settings › General › "Start when you log in" (Windows' Autostart.Apply): the app itself as a login item.
    private static func applyLoginItem(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on, service.status != .enabled { try service.register() }
            else if !on, service.status == .enabled { try service.unregister() }
        } catch {
            Log.warn("Autostart change failed: \(error.localizedDescription)")
        }
        if on, service.status == .requiresApproval { Log.warn("Login item waits for approval in System Settings › General › Login Items") }
    }

    /// App.ApplyHotkeys: the dictation, profile and Read aloud keys, then the marker key while a session records.
    private func registerHotkeys(_ keys: [String]) {
        var errors = hotkeys.register([
            (keys[0], { [weak self] in self?.model.toggleDictation() }),
            (keys[1], { [weak self] in self?.model.cycleProfile() }),
            (keys[2], { [weak self] in self?.model.readSelection() }),
        ])
        // The marker key is checked against the others always, not only while a session records (App.MarkerClash).
        if let clash = HotkeyManager.markerClash(marker: keys[3], dictation: keys[0], speak: keys[2], cycle: keys[1]) {
            // Only the error: a marker key held while a session records keeps its earlier key, as on Windows.
            errors.append(clash)
        } else if markerHeld, let error = hotkeys.holdMarker(keys[3], { [weak self] in self?.model.notes.addMarker() }) {
            errors.append(error)
        }
        let error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        HotkeyStatus.shared.error = error
        // Logged, and shown on the overlay as an error notice, whenever the shortcuts are applied (at start, and when
        // one changes).
        guard keys != appliedKeys else { return }
        appliedKeys = keys
        if let error {
            Log.warn(error)
            model.notice(error, kind: .error)
        }
    }

    /// App.ApplyMarkerHotkey: a session started or stopped. A problem is only logged; the Hotkeys page's line is left
    /// as it was.
    private func applyMarkerHotkey(_ recording: Bool) {
        guard recording != markerHeld else { return }
        markerHeld = recording
        hotkeys.holdMarker(nil)
        guard recording else { return }
        let s = model.settings
        let error = HotkeyManager.markerClash(marker: s.notesMarkerHotkey, dictation: s.hotkey, speak: s.speakHotkey, cycle: s.cycleProfileHotkey)
            ?? hotkeys.holdMarker(s.notesMarkerHotkey) { [weak self] in self?.model.notes.addMarker() }
        if let error { Log.warn(error) }
    }
}

/// Windows' Assets/splash.png (480×160): the mark, OBERTON, "STARTING // ONE MOMENT", a rule and "LOCAL DICTATION" on
/// paper in a 1 px frame, centred on the screen, in front, until the main window is drawn.
enum StartupCard {
    static func show() -> NSWindow {
        let card = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        card.contentView = NSHostingView(rootView: Face())
        card.isOpaque = true
        card.hasShadow = true
        card.level = .floating
        card.isReleasedWhenClosed = false
        if let area = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            card.setFrameOrigin(NSPoint(x: (area.midX - 240).rounded(), y: (area.midY - 80).rounded()))
        }
        card.orderFrontRegardless()
        card.display()
        return card
    }

    /// The image's own colours (it doesn't follow the theme).
    struct Face: View {
        var body: some View {
            let ink = Color(hex: 0x0D0D0C), muted = Color(hex: 0x5C5B57)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    Rectangle().fill(ink).frame(width: 14, height: 14)
                    Text("OBERTON").font(Ob.mono(24, .bold)).foregroundStyle(ink)
                }
                .padding(.top, 28)
                Text("STARTING  //  ONE MOMENT").font(Ob.mono(11)).foregroundStyle(muted).padding(.leading, 4).padding(.top, 15)
                Rectangle().fill(ink).frame(height: 1).padding(.top, 18)
                Text("LOCAL DICTATION").font(Ob.mono(11)).foregroundStyle(muted).padding(.leading, 4).padding(.top, 11)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .frame(width: 480, height: 160, alignment: .topLeading)
            .background(Color(hex: 0xE8E7E3))
            .overlay(Rectangle().strokeBorder(muted, lineWidth: 1))
        }
    }
}

/// Selected text in every text box as the Windows themes draw it (Light/Dark.xaml's
/// AccentFillColorSelectedTextBackgroundBrush is the ink, under WPF's SelectionOpacity 0.4), not macOS's Highlight
/// colour: each text view (a field's editor or a text area) takes it when its selection first changes.
enum InkSelection {
    private static var watch: NSObjectProtocol?

    static func start() {
        guard watch == nil else { return }
        watch = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let view = note.object as? NSTextView else { return }
                apply(to: view)
            }
        }
    }

    @MainActor static func apply(to view: NSTextView) {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink = dark ? NSColor(srgbRed: 0xE8 / 255, green: 0xE7 / 255, blue: 0xE3 / 255, alpha: 0.4)
            : NSColor(srgbRed: 0x0D / 255, green: 0x0D / 255, blue: 0x0C / 255, alpha: 0.4)
        if view.selectedTextAttributes[.backgroundColor] as? NSColor != ink {
            view.selectedTextAttributes = [.backgroundColor: ink]
        }
    }
}

/// The setup window's content, themed live from Settings.
private struct SetupWindowContent: View {
    var finish: () -> Void
    @EnvironmentObject var model: AppModel

    var body: some View {
        OnboardingView(finish: finish).obertonTheme(model.settings)
    }
}

/// A menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

/// The menu bar icon: the Oberton mark as Windows' tray draws it (TrayIcon.CreateIcon): an ink square (#0D0D0C) with
/// a faint white edge, so it shows on a dark menu bar too, and a paper dot (#E8E7E3; red is only for recording), on 16 pt
/// as Windows' 32 px. In colour, not a template image, so it looks the same on every menu bar.
enum StatusMark {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            let square = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 15, height: 15), xRadius: 2.5, yRadius: 2.5)
            NSColor(srgbRed: 0x0D / 255, green: 0x0D / 255, blue: 0x0C / 255, alpha: 1).setFill()
            square.fill()
            NSColor(white: 1, alpha: 70 / 255).setStroke()
            square.lineWidth = 0.5
            square.stroke()
            NSColor(srgbRed: 0xE8 / 255, green: 0xE7 / 255, blue: 0xE3 / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 5.25, y: 5.25, width: 5.5, height: 5.5)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Oberton"
        return image
    }()
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
            folded.collapsedSettingsGroups = ["DictationGroup", "LookGroup"]
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
        HotkeyStatus.shared.error = "Ctrl+Alt+D is already used by another application. Choose a different shortcut under Settings > Hotkeys."
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
        MarkdownEditorSnapshots.write(to: dir, model: model)
        DashboardSnapshots.write(to: dir, model: model)
        #if OBERTON_DIRECT
        UpdatesSnapshots.write(to: dir, model: model)
        #endif
        NSApp.terminate(nil)
    }

    /// The menu bar mark at 1× and 4×, on light and dark.
    private struct MenuBarMarkPreview: View {
        var body: some View {
            HStack(spacing: 16) {
                ForEach([false, true], id: \.self) { dark in
                    HStack(spacing: 12) {
                        Image(nsImage: StatusMark.image)
                        Image(nsImage: StatusMark.image).resizable().interpolation(.high).frame(width: 64, height: 64)
                    }
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
