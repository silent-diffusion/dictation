import ObertonCore
import SwiftUI

/// The main window's sections, as in the Windows sidebar.
enum Section: String, CaseIterable, Hashable {
    case dashboard, speechToText, readAloud, history, settings

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .speechToText: "Speech to text"
        case .readAloud: "Read aloud"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var japanese: String {
        switch self {
        case .dashboard: "計器"
        case .speechToText: "口述"
        case .readAloud: "読上"
        case .history: "履歴"
        case .settings: "設定"
        }
    }
}

/// Settings' own sections, grouped and addressed as on Windows ("A // DICTATION", "SECTION A.1").
enum SettingsSection: String, CaseIterable, Hashable {
    case general, hotkeys, microphone, history, models, speech, cloud, appearance, layout, advanced, about

    var group: String {
        switch self {
        case .general, .hotkeys, .microphone, .history: "A // Dictation"
        case .models, .speech, .cloud: "B // Models & AI"
        case .appearance, .layout: "C // Look & feel"
        case .advanced, .about: "D // App"
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
        case .appearance: "C.1"
        case .layout: "C.2"
        case .advanced: "D.1"
        case .about: "D.2"
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
        case .appearance: "Appearance"
        case .layout: "Layout"
        case .advanced: "Advanced"
        case .about: "About"
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
}

@MainActor
final class Navigator: ObservableObject {
    @Published private(set) var place: Place
    @Published private(set) var back: [Place] = []
    /// iPhone: the drawer is open over the page.
    @Published var drawerOpen = false

    init(place: Place = Place()) { self.place = place }

    func go(_ section: Section) { go { $0.section = section } }
    func goSettings(_ s: SettingsSection) { go { $0.section = .settings; $0.settings = s } }
    func goProfile(_ id: String?) { go { $0.section = .speechToText; $0.profileID = id } }
    func goHistory(_ id: UUID?) { go { $0.section = .history; $0.historyID = id } }

    private func go(_ change: (inout Place) -> Void) {
        var next = place
        change(&next)
        drawerOpen = false
        guard next != place else { return }
        back.append(place)
        if back.count > 50 { back.removeFirst() }
        place = next
    }

    func goBack() {
        guard let last = back.popLast() else { return }
        place = last
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The page: below the top bar while the sidebar is hidden, beside the sidebar while it is open.
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, !compact && sidebarOpen ? 232 : 0)
                .padding(.top, sidebarOpen && !compact ? 0 : topBarHeight)

            if !sidebarOpen || compact {
                // A solid bar across the top holding the menu and Back, so pages scroll under nothing.
                ob.paper
                    .frame(height: topBarHeight)
                    .overlay(alignment: .bottom) { Rule() }
                    .background(ob.paper.ignoresSafeArea(edges: .top))
            }

            if compact && nav.drawerOpen {
                Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { withAnimation(.easeOut(duration: 0.2)) { nav.drawerOpen = false } }
            }

            Sidebar()
                .frame(width: compact ? 260 : 232)
                .offset(x: sidebarOpen ? 0 : -(compact ? 260 : 232) - 1)
                .opacity(sidebarOpen ? 1 : 0)

            menuAndBack
        }
        .background(ob.paper.ignoresSafeArea())
        .environmentObject(nav)
        .animation(.easeOut(duration: 0.22), value: sidebarOpen)
        #if os(macOS)
        .background {
            // Back: Cmd+[ (and the mouse's back button through the menu command); the sidebar: Cmd+B.
            Button("") { nav.goBack() }.keyboardShortcut("[", modifiers: .command).hidden()
            Button("") { model.settings.sidebarCollapsed.toggle() }.keyboardShortcut("b", modifiers: .command).hidden()
        }
        #endif
    }

    private var topBarHeight: CGFloat { 56 }

    /// The menu button (☰, folding into ✕ while the sidebar is open) and Back, always at the top left.
    private var menuAndBack: some View {
        HStack(spacing: 6) {
            MenuGlyphButton(open: sidebarOpen) {
                if compact { nav.drawerOpen.toggle() } else { model.settings.sidebarCollapsed.toggle() }
            }
            if nav.place.section != .dashboard && !nav.back.isEmpty && !(sidebarOpen && compact) {
                Button { nav.goBack() } label: {
                    Image(systemName: "arrow.left").font(.system(size: 13)).frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back")
                .accessibilityLabel("Back")
            }
        }
        .padding(.leading, leadingInset)
        .padding(.top, 10)
    }

    /// On the Mac the window's close/minimize/zoom buttons sit at the top left; the menu button goes after them.
    private var leadingInset: CGFloat {
        #if os(macOS)
        78
        #else
        12
        #endif
    }

    @ViewBuilder private var page: some View {
        switch nav.place.section {
        case .dashboard: DashboardView()
        case .speechToText: SpeechToTextView()
        case .readAloud: ReadAloudView()
        case .history: HistoryView()
        case .settings: SettingsView()
        }
    }
}

/// ☰ that folds into ✕: three ink bars, the outer two turning.
struct MenuGlyphButton: View {
    var open: Bool
    var action: () -> Void
    @Environment(\.ob) private var ob

    var body: some View {
        Button(action: action) {
            ZStack {
                Rectangle().frame(width: 16, height: 1.5).rotationEffect(.degrees(open ? 45 : 0)).offset(y: open ? 0 : -6)
                Rectangle().frame(width: 16, height: 1.5).opacity(open ? 0 : 1)
                Rectangle().frame(width: 16, height: 1.5).rotationEffect(.degrees(open ? -45 : 0)).offset(y: open ? 0 : 6)
            }
            .foregroundStyle(ob.ink)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "Hide the menu" : "Show the menu")
        .accessibilityLabel(open ? "Hide the menu" : "Show the menu")
    }
}

/// The sidebar: paper like the page, set off by an ink line. The logo, the sections as capsules (the chosen one filled
/// with ink), and at the foot the engine status as a readout.
struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Logo(recording: model.phase == .recording)
                .padding(.top, 56)
                .padding(.leading, 6)
                .padding(.bottom, 24)
            VStack(spacing: 2) {
                ForEach(Section.allCases, id: \.self) { s in
                    NavCapsule(title: s.title, japanese: s.japanese, icon: s.icon, selected: nav.place.section == s) { nav.go(s) }
                }
            }
            Spacer(minLength: 12)
            engineStatus
        }
        .padding(EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ob.paper.ignoresSafeArea())
        .overlay(alignment: .trailing) { Rectangle().fill(ob.ink).frame(width: 1).ignoresSafeArea() }
    }

    private var engineStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Readout("Engine // Status")
                Spacer()
                Decor("倍音", size: 10.5)
            }
            .padding(.bottom, 2)
            statusRow(model.phase == .recording || model.phase == .transcribing ? .busy : .ok, "Speech · on-device")
            let profile = model.activeProfile
            statusRow(profile.isRaw ? .off : model.phase == .processing ? .busy : model.aiReady ? .ok : .off,
                      "AI · " + (profile.isRaw ? "off (Raw)" : model.processor.model(for: profile).shortName))
            Readout(model.settings.cloud.keepOffline ? "On-device // offline\nEverything stays on this \(Device.noun)" : "Cloud AI allowed",
                    size: 10)
                .lineSpacing(3)
                .padding(.top, 6)
        }
        .padding(.horizontal, 2)
        .padding(.top, 12)
        .overlay(alignment: .top) { Hairline() }
    }

    private func statusRow(_ state: DotState, _ text: String) -> some View {
        HStack(spacing: 8) {
            StatusDot(state: state)
            Text(text).font(Ob.mono(11.5)).lineLimit(1).truncationMode(.tail)
        }
        .padding(.vertical, 2)
    }
}

extension Section {
    var icon: String {
        switch self {
        case .dashboard: "gauge.with.needle"
        case .speechToText: "mic"
        case .readAloud: "speaker.wave.2"
        case .history: "text.alignleft"
        case .settings: "gearshape"
        }
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

/// A menu entry: a capsule; the chosen one is filled with ink.
struct NavCapsule: View {
    var title: String
    var japanese: String?
    var icon: String?
    var size: CGFloat = 12
    var selected: Bool
    var action: () -> Void
    @Environment(\.ob) private var ob
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .light)).frame(width: 16) }
                Text(title.uppercased()).font(Ob.mono(size, selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if let japanese { Decor(japanese, size: 10.5, color: selected ? ob.onInk : ob.ink).opacity(0.6) }
            }
            .foregroundStyle(selected ? ob.onInk : ob.ink)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(selected ? ob.ink : hover ? ob.subtle : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
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
