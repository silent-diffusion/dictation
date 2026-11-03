import ObertonCore
import SwiftUI

/// The main window's sections, as in the Windows sidebar.
enum Section: String, CaseIterable, Hashable {
    case dashboard, notes, speechToText, readAloud, history, analytics, settings

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .notes: "Extended notes"
        case .speechToText: "Speech to text"
        case .readAloud: "Read aloud"
        case .history: "History"
        case .analytics: "Analytics"
        case .settings: "Settings"
        }
    }

    var japanese: String {
        switch self {
        case .dashboard: "計器"
        case .notes: "記録"
        case .speechToText: "口述"
        case .readAloud: "読上"
        case .history: "履歴"
        case .analytics: "分析"
        case .settings: "設定"
        }
    }
}

/// Settings' own sections, grouped and addressed as on Windows ("A // DICTATION", "SECTION A.1").
enum SettingsSection: String, CaseIterable, Hashable {
    case general, hotkeys, microphone, history, models, speech, cloud, unloading, appearance, layout, advanced, about, updates

    var group: String {
        switch self {
        case .general, .hotkeys, .microphone, .history: "A // Dictation"
        case .models, .speech, .cloud, .unloading: "B // Models & AI"
        case .appearance, .layout: "C // Look & feel"
        case .advanced, .about, .updates: "D // App"
        }
    }

    var address: String {
        switch self {
        case .general: "A.1"
        case .hotkeys: "A.2"
        case .microphone: "A.3"
        case .history: "A.4"
        case .models: "B.1"
        case .speech: "B.2"
        case .cloud: "B.3"
        case .unloading: "B.4"
        case .appearance: "C.1"
        case .layout: "C.2"
        case .advanced: "D.1"
        case .about: "D.2"
        case .updates: "D.3"
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .hotkeys: "Hotkeys"
        case .microphone: "Microphone"
        case .history: "History"
        case .models: "Models"
        case .speech: "Speech recognition"
        case .cloud: "Cloud AI"
        case .unloading: "Model unloading"
        case .appearance: "Appearance"
        case .layout: "Layout"
        case .advanced: "Advanced"
        case .about: "About"
        case .updates: "Updates"
        }
    }

    static var groups: [(String, [SettingsSection])] {
        var out: [(String, [SettingsSection])] = []
        for s in allCases {
            if out.last?.0 == s.group { out[out.count - 1].1.append(s) } else { out.append((s.group, [s])) }
        }
        return out
    }
}

/// Where the main window is, and where Back goes.
struct Place: Equatable {
    var section: Section = .dashboard
    var profileID: String?
    var settings: SettingsSection = .general
    var historyID: UUID?
    /// Extended Notes: the session open (its folder's name), or nil for the landing page.
    var noteSessionID: String?

    /// What Back remembers (MainWindow.Visit): the page, or "Settings/<section>"; not the profile, entry or session
    /// open in it.
    var visit: String { section == .settings ? "settings/" + settings.rawValue : section.rawValue }
}

@MainActor
final class Navigator: ObservableObject {
    @Published private(set) var place: Place
    @Published private(set) var back: [Place] = []
    /// iPhone: the drawer is open over the page.
    @Published var drawerOpen = false

    init(place: Place = Place()) { self.place = place }

    /// A page from the sidebar, opened fresh as Windows builds a new page: Settings on GENERAL, Extended Notes on its
    /// landing page. The page already shown stays as it is (its sidebar entry is already selected).
    func open(_ section: Section) {
        guard section != place.section else { drawerOpen = false; return }
        go { $0 = Place(section: section) }
    }

    /// ShowPage(tag) for a page: the same as its sidebar entry.
    func go(_ section: Section) { open(section) }
    func goSettings(_ s: SettingsSection) { go { $0.section = .settings; $0.settings = s } }
    func goProfile(_ id: String?) { go { $0.section = .speechToText; $0.profileID = id } }
    func goHistory(_ id: UUID?) { go { $0.section = .history; $0.historyID = id } }
    /// Extended Notes: a session (the live one, or one from the list), or the landing page.
    func goNotes(_ sessionID: String?) { go { $0.section = .notes; $0.noteSessionID = sessionID } }

    private func go(_ change: (inout Place) -> Void) {
        var next = place
        change(&next)
        drawerOpen = false
        guard next != place else { return }
        // Only a new page or Settings section is a step back (a profile or History entry opened in a page isn't).
        if next.visit != place.visit {
            back.append(place)
            if back.count > 50 { back.removeFirst() }
        }
        place = next
    }

    /// To the page shown before this one, or the dashboard when there is none (MainWindow.GoBack): places equal to this
    /// one are skipped, and the page opens fresh.
    func goBack() {
        guard place.section != .dashboard else { return }
        drawerOpen = false
        var target = Place()
        while let last = back.popLast() {
            if last.visit != place.visit { target = last; break }
        }
        place = Place(section: target.section, settings: target.settings)
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var nav: Navigator

    init(start: Place = Place()) { _nav = StateObject(wrappedValue: Navigator(place: start)) }
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.ob) private var ob

    private var compact: Bool { sizeClass == .compact }
    private var sidebarOpen: Bool { compact ? nav.drawerOpen : !model.settings.sidebarCollapsed }

    /// The text size (Settings › Appearance, ⌘+ / ⌘− / ⌘0), shown for a moment after it changes.
    @State private var zoomToast: String?
    @State private var zoomToastShown = false
    /// Each change restarts the 1.2 s hold (Windows restarts its timer).
    @State private var zoomToastCount = 0
    #if os(macOS)
    @State private var mouseBack: Any?
    #endif

    var body: some View {
        ZoomedWindow(scale: TextSize.clamped(model.settings.uiScale)) { window }
            .overlay(alignment: .bottom) {
                if let zoomToast {
                    Text(zoomToast).font(Ob.mono(12)).foregroundStyle(ob.onInk)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Capsule().fill(ob.ink))
                        .opacity(zoomToastShown ? 1 : 0)
                        .padding(.bottom, 28)
                        .allowsHitTesting(false)
                }
            }
            .background(ob.paper.ignoresSafeArea())
            .onChange(of: model.settings.uiScale) { showZoomToast(TextSize.clamped(model.settings.uiScale)) }
            #if os(macOS)
            .onAppear {
                // The mouse's back button (button 3) goes back, as on Windows.
                mouseBack = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [nav] event in
                    if event.buttonNumber == 3 { MainActor.assumeIsolated { nav.goBack() }; return nil }
                    return event
                }
            }
            .onDisappear { if let mouseBack { NSEvent.removeMonitor(mouseBack) }; mouseBack = nil }
            #endif
    }

    /// "TEXT SIZE 125%  //  ⌘0 RESETS" for 1.2 s, then a fade.
    private func showZoomToast(_ scale: Double) {
        let text = "TEXT SIZE \(Int((scale * 100).rounded()))%" + (abs(scale - 1) < 0.001 ? "" : "  //  \(TextSize.resetKey) RESETS")
        zoomToast = text
        zoomToastCount += 1
        let count = zoomToastCount
        withAnimation(.linear(duration: 0.12)) { zoomToastShown = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard zoomToastCount == count else { return }
            withAnimation(.linear(duration: 0.3)) { zoomToastShown = false }
        }
    }

    private var window: some View {
        ZStack(alignment: .topLeading) {
            // The page: below the top bar while the sidebar is hidden, beside the sidebar while it is open.
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, !compact && sidebarOpen ? Sidebar.width : 0)
                .padding(.top, sidebarOpen && !compact ? 0 : topBarHeight)

            if !sidebarOpen || compact {
                // A solid bar across the top holding the menu and Back, so pages scroll under nothing.
                ob.paper
                    .frame(height: topBarHeight)
                    .overlay(alignment: .bottom) { Rule() }
                    .background(ob.paper.ignoresSafeArea(edges: .top))
                    .transition(.opacity)
            }

            if compact && nav.drawerOpen {
                Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { withAnimation(.easeOut(duration: 0.2)) { nav.drawerOpen = false } }
            }

            // Slides off to the left as the page's margin shrinks to match (MainWindow.SlideSidebar); off screen it
            // leaves the tab order.
            Sidebar()
                .frame(width: compact ? 260 : Sidebar.width)
                .offset(x: sidebarOpen ? 0 : -(compact ? 260 : Sidebar.width) - 1)
                .allowsHitTesting(sidebarOpen)
                .accessibilityHidden(!sidebarOpen)

            menuAndBack
        }
        .background(ob.paper.ignoresSafeArea())
        .environmentObject(nav)
        // About a quarter second, cubic ease-out, as Windows moves it frame by frame.
        .animation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.26), value: sidebarOpen)
        // ⌘, and the menu bar's "Check for updates…" open a Settings section (also when they opened this window).
        .onChange(of: model.requestedSettings, initial: true) { _, s in
            if let s { nav.goSettings(s); model.requestedSettings = nil }
        }
        #if os(macOS)
        .background {
            // Back: Cmd+[ (the mouse's back button: the monitor above); the sidebar: Cmd+B; the text size: Cmd+plus/minus/0.
            Button("") { nav.goBack() }.keyboardShortcut("[", modifiers: .command).hidden()
            Button("") { model.settings.sidebarCollapsed.toggle() }.keyboardShortcut("b", modifiers: .command).hidden()
            Button("") { zoom(+1) }.keyboardShortcut("=", modifiers: .command).hidden()
            Button("") { zoom(+1) }.keyboardShortcut("+", modifiers: .command).hidden()
            Button("") { zoom(-1) }.keyboardShortcut("-", modifiers: .command).hidden()
            Button("") { setZoom(1) }.keyboardShortcut("0", modifiers: .command).hidden()
        }
        #else
        .background {
            // A hardware keyboard on iPad: the same shortcuts.
            Button("") { zoom(+1) }.keyboardShortcut("=", modifiers: .command).hidden()
            Button("") { zoom(-1) }.keyboardShortcut("-", modifiers: .command).hidden()
            Button("") { setZoom(1) }.keyboardShortcut("0", modifiers: .command).hidden()
        }
        #endif
    }

    private func zoom(_ direction: Int) { setZoom(TextSize.step(from: model.settings.uiScale, direction)) }

    /// A change to the same size still shows the toast (Windows' SetZoom always shows it).
    private func setZoom(_ scale: Double) {
        if abs(model.settings.uiScale - scale) < 0.001 { showZoomToast(scale) } else { model.settings.uiScale = scale }
    }

    private var topBarHeight: CGFloat { 56 }

    /// The menu button (☰, folding into ✕ while the sidebar is open) and Back, always at the top left, 12 in. While the
    /// sidebar is open Back sits at its right edge, after the logo; folded, it slides along to beside the menu button.
    private var menuAndBack: some View {
        HStack(spacing: 6) {
            MenuGlyphButton(open: sidebarOpen) {
                if compact { nav.drawerOpen.toggle() } else { model.settings.sidebarCollapsed.toggle() }
            }
            // Back is everywhere except the dashboard (where the app starts), as on Windows.
            if nav.place.section != .dashboard && !(sidebarOpen && compact) {
                IconButton(help: "Back (\(TextSize.backKey))", label: "Back") {
                    Image(systemName: "arrow.left").font(.system(size: 13))
                } action: { nav.goBack() }
                .offset(x: sidebarOpen && !compact ? Self.backOpenShift : 0)
            }
        }
        .padding(.leading, 12)
        .padding(.top, 12)
    }

    /// Back's move while the sidebar is open: from beside the menu button to the sidebar's right edge (BackOpenShift).
    static let backOpenShift: CGFloat = Sidebar.width - 14 - 36 - (12 + 36 + 6)

    @ViewBuilder private var page: some View {
        switch nav.place.section {
        case .dashboard: DashboardView()
        case .notes: NotesView()
        case .speechToText: SpeechToTextView()
        case .readAloud: ReadAloudView()
        case .history: HistoryView()
        case .analytics: AnalyticsView()
        case .settings: SettingsView()
        }
    }
}

/// ☰ that folds into ✕: three ink bars, the outer two meeting and turning ±45°, the middle one fading (240 ms).
struct MenuGlyphButton: View {
    var open: Bool
    var action: () -> Void
    @Environment(\.ob) private var ob

    var body: some View {
        IconButton(help: (open ? "Hide the menu" : "Show the menu") + " (\(TextSize.menuKey))", label: open ? "Hide the menu" : "Show the menu") {
            ZStack {
                Rectangle().frame(width: 16, height: 1.5).rotationEffect(.degrees(open ? 45 : 0)).offset(y: open ? 0 : -6)
                Rectangle().frame(width: 16, height: 1.5).opacity(open ? 0 : 1)
                Rectangle().frame(width: 16, height: 1.5).rotationEffect(.degrees(open ? -45 : 0)).offset(y: open ? 0 : 6)
            }
            .foregroundStyle(ob.ink)
            .animation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.24), value: open)
        } action: { action() }
    }
}

/// MainWindow's IconButton: a 36 pt quiet button with no outline, the hover wash in a capsule, an accent outline while
/// it has the keyboard focus, and the hand cursor.
struct IconButton<Glyph: View>: View {
    var help: String
    var label: String
    @ViewBuilder var glyph: Glyph
    var action: () -> Void
    @Environment(\.ob) private var ob
    @State private var hover = false
    @FocusState private var focused

    var body: some View {
        Button(action: action) {
            glyph
                .frame(width: 36, height: 36)
                .background(Capsule().fill(hover ? ob.subtle : .clear))
                .overlay(Capsule().strokeBorder(focused ? ob.accent : .clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hover = $0 }
        .handCursor()
        .help(help)
        .accessibilityLabel(label)
    }
}

/// The sidebar: paper like the page, set off by an ink line. The logo, the sections as capsules (the chosen one filled
/// with ink), and at the foot the engine status as a readout.
struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob

    static let width: CGFloat = 216

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The logo to the right of the menu button, on its row (MainWindow's Header, margin 42,6,0,24).
            Logo(recording: model.phase == .recording)
                .padding(.top, 6)
                .padding(.leading, 42)
                .padding(.bottom, 24)
            VStack(spacing: 2) {
                ForEach(Section.allCases, id: \.self) { s in
                    NavCapsule(title: s.title, japanese: s.japanese, icon: s, selected: nav.place.section == s) { nav.open(s) }
                }
            }
            Spacer(minLength: 12)
            engineStatus
        }
        .padding(EdgeInsets(top: 18, leading: 14, bottom: 14, trailing: 14))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ob.paper.ignoresSafeArea())
        .overlay(alignment: .trailing) { Rectangle().fill(ob.ink).frame(width: 1).ignoresSafeArea() }
    }

    private var engineStatus: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Readout("Engine // Status")
                Spacer()
                Decor("倍音", size: 10.5)
            }
            .padding(.bottom, 6)
            // Windows' Status.Speech / Status.Ai: the model and whether it is loaded, the dot filled when it is fine.
            statusRow(model.speechOK ? .ok : .busy, model.speechStatus)
            statusRow(model.aiStatusLine.ok ? .ok : .busy, model.aiStatusLine.text)
            Readout(model.settings.cloud.keepOffline
                        ? "127.0.0.1 // offline\nEverything stays on this \(Device.noun)"
                        : "Cloud AI allowed\nProfiles with a cloud model send their text to it",
                    size: 10)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(.horizontal, 2)
        .padding(.top, 12)
        .overlay(alignment: .top) { Hairline() }
    }

    private func statusRow(_ state: DotState, _ text: String) -> some View {
        HStack(spacing: 8) {
            StatusDot(state: state)
            // 11.5, cut with "…" at 160 (the full text as the tooltip).
            Text(text).font(Ob.sans(11.5)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 160, alignment: .leading).help(text)
        }
        .padding(.vertical, 2)
    }
}

extension AppModel {
    /// Windows' Status.Ai line ("AI: Ready · qwen3:8b · GPU", "AI: Loading …"), kept by the engine: the sidebar's
    /// footer and Settings › Model unloading's "Now:" lines.
    var aiStatusLine: (text: String, ok: Bool) { (aiStatus, aiStatusOK) }
}

/// The sidebar's line icons, drawn on a 16 pt square from MainWindow.xaml's paths (stroke 1.2, round caps).
struct NavIcon: Shape {
    var section: Section

    func path(in rect: CGRect) -> Path {
        var p = Path()
        func line(_ pts: (Double, Double)...) { p.addLines(pts.map { CGPoint(x: $0.0, y: $0.1) }) }
        func circle(_ x: Double, _ y: Double, _ r: Double) { p.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
        /// An arc around (x, y), from one angle to the other in degrees (0 = right, 90 = down), as points (no flip
        /// questions about which way "clockwise" goes).
        func arc(_ x: Double, _ y: Double, _ r: Double, _ from: Double, _ to: Double, move: Bool = true) {
            let n = 24
            for i in 0...n {
                let a = (from + (to - from) * Double(i) / Double(n)) * .pi / 180
                let pt = CGPoint(x: x + r * cos(a), y: y + r * sin(a))
                if i == 0 && move { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
        switch section {
        case .dashboard:
            circle(8, 8, 6.5); line((8, 8), (11, 5)); circle(8, 8, 1)
        case .notes:
            line((3, 1.5), (13, 1.5), (13, 14.5), (3, 14.5)); p.closeSubpath()
            line((5.5, 5), (10.5, 5)); line((5.5, 8), (10.5, 8)); line((5.5, 11), (8.5, 11))
        case .speechToText:
            arc(8, 4, 2.5, 180, 360); p.addLine(to: CGPoint(x: 10.5, y: 7.5)); arc(8, 7.5, 2.5, 0, 180, move: false); p.closeSubpath()
            arc(8, 7.5, 5, 180, 0); line((8, 12.5), (8, 15))
        case .readAloud:
            line((1.5, 6), (1.5, 10), (4.5, 10), (8.5, 13), (8.5, 3), (4.5, 6)); p.closeSubpath()
            arc(8.551, 8, 3.5, -45.58, 45.58); arc(9.031, 8, 6, -48.59, 48.59)
        case .history:
            line((2, 4), (14, 4)); line((2, 8), (14, 8)); line((2, 12), (9, 12))
        case .analytics:
            line((2.5, 14.5), (2.5, 9)); line((6.5, 14.5), (6.5, 4)); line((10.5, 14.5), (10.5, 7)); line((14, 14.5), (14, 1.5))
        case .settings:
            circle(8, 8, 2)
            line((8, 1), (8, 4)); line((8, 12), (8, 15)); line((1, 8), (4, 8)); line((12, 8), (15, 8))
            line((3, 3), (5, 5)); line((11, 11), (13, 13)); line((13, 3), (11, 5)); line((5, 11), (3, 13))
        }
        return p.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width / 16, y: rect.height / 16))
    }
}

/// The logo: an ink square with a paper dot (red while the microphone is open), and OBERTON.
struct Logo: View {
    var recording: Bool
    @Environment(\.ob) private var ob

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4).fill(ob.ink).frame(width: 24, height: 24)
                .overlay(Circle().fill(recording ? ob.record : ob.paper).frame(width: 8, height: 8))
            Text("OBERTON").font(Ob.mono(14, .bold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Oberton")
    }
}

/// A menu entry (App.xaml's NavItem): a capsule, 12,7 inside a 1 pt border that turns accent with the keyboard focus;
/// the chosen one is filled with ink. Settings' entries are 11.5 with 12,6 (SettingsNavItem).
struct NavCapsule: View {
    var title: String
    var japanese: String?
    var icon: Section?
    var size: CGFloat = 12
    var selected: Bool
    var action: () -> Void
    @Environment(\.ob) private var ob
    @State private var hover = false
    @FocusState private var focused

    var body: some View {
        Button(action: action) {
            // A DockPanel: the icon (12 after it), the decor docked right, the label filling the rest.
            HStack(spacing: 0) {
                if let icon {
                    NavIcon(section: icon).stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                        .frame(width: 16, height: 16).padding(.trailing, 12)
                }
                Text(title.uppercased()).font(Ob.mono(size, selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 2)
                if let japanese { Decor(japanese, size: 10.5, color: selected ? ob.onInk : ob.ink).opacity(0.6) }
            }
            .foregroundStyle(selected ? ob.onInk : ob.ink)
            .padding(.horizontal, 13).padding(.vertical, size < 12 ? 7 : 8)
            .background(Capsule().fill(selected ? ob.ink : hover ? ob.subtle : .clear))
            .overlay(Capsule().strokeBorder(focused ? ob.accent : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hover = $0 }
        .handCursor()
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

enum Device {
    static var noun: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone"
        #endif
    }

    /// The system, where Windows' copy says "Windows".
    static var system: String {
        #if os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }
}

extension ModelID {
    /// The model as the signal path and status lines name it.
    var shortName: String {
        switch provider {
        case .apple: "Apple Intelligence"
        case .ollama: name
        case .anthropic, .openai: displayName
        }
    }
}
