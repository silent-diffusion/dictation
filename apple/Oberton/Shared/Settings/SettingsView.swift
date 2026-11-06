import ObertonCore
import SwiftUI

/// SETTINGS 設定: a menu of its own at the left, in four foldable groups, and the chosen section at the right
/// (SettingsPage.xaml). Folded groups are remembered (`collapsedSettingsGroups`, by Windows' Expander names), and the
/// open section's group shows unfolded without that being saved (SettingsPage.Show runs before the page has loaded).
/// On iPhone the menu is a page and a section opens over it.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var phoneShowsSection = false
    /// Unfolded only because a section in it was opened.
    @State private var shownOpen: Set<String> = []
    /// ↑/↓ just moved the choice: the newly chosen entry takes the focus.
    @State private var arrowMoved = false

    private func isFolded(_ group: String) -> Bool {
        !shownOpen.contains(group) && model.settings.collapsedSettingsGroups.contains { SettingsSection.groupKey(stored: $0) == group }
    }

    /// The sign clicked: saved, as Windows saves an Expander's state once the page is loaded.
    private func toggle(_ group: String) {
        let fold = !isFolded(group)
        shownOpen.remove(group)
        var groups = model.settings.collapsedSettingsGroups.filter { SettingsSection.groupKey(stored: $0) != group }
        if fold { groups.append(group) }
        if groups != model.settings.collapsedSettingsGroups { model.settings.collapsedSettingsGroups = groups }
    }

    private func reveal(_ s: SettingsSection) { shownOpen.insert(s.groupKey) }

    /// A section opened from elsewhere while the page is up (the menu bar's Updates, Back): Windows' Show() expands the
    /// group after the page has loaded, so Group_Toggled saves the unfold.
    private func open(_ s: SettingsSection) {
        if isFolded(s.groupKey) { toggle(s.groupKey) } else { reveal(s) }
    }

    var body: some View {
        content
            .onAppear { reveal(nav.place.settings) }
            .onChange(of: nav.place.settings) { _, s in open(s) }
    }

    @ViewBuilder private var content: some View {
        if sizeClass == .compact {
            if phoneShowsSection {
                PageScroll { section.padding(16) }
            } else {
                PageScroll { menu.padding(16) }
            }
        } else {
            HStack(spacing: 0) {
                PageScroll { menu.padding(EdgeInsets(top: 26, leading: 12, bottom: 16, trailing: 12)) }
                    .frame(width: 220)
                    .overlay(alignment: .trailing) { Rectangle().fill(ob.ink).frame(width: 1) }
                PageScroll {
                    // MaxWidth 760 (820 for the wide pages) inside the 40,32,40,40 margin.
                    section
                        .frame(maxWidth: nav.place.settings.wide ? 820 : 760, alignment: .leading)
                        .padding(EdgeInsets(top: 32, leading: 40, bottom: 40, trailing: 40))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                Text("SETTINGS").font(Ob.mono(18, .bold))
                Spacer()
                Decor("設定").padding(.bottom, 3)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 18)
            ForEach(SettingsSection.groups, id: \.0) { group, sections in
                let key = sections[0].groupKey
                VStack(alignment: .leading, spacing: 0) {
                    GroupHeader(title: group, folded: isFolded(key)) { toggle(key) }
                    if !isFolded(key) {
                        // A ListBox (Margin 0,4,0,0) of items with Margin 18,1,0,1: 1 above the first, 2 between, 1 after
                        // the last. ↑/↓ move the selection and open the section, as in a ListBox.
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(sections, id: \.self) { s in
                                // One Tab stop per list: its chosen entry, or its first when the choice is in another list.
                                NavCapsule(title: s.title, size: 11.5, selected: nav.place.settings == s && sizeClass != .compact,
                                           tabStop: sections.contains(nav.place.settings) ? nav.place.settings == s : s == sections[0],
                                           claimFocus: arrowMoved && nav.place.settings == s) {
                                    nav.goSettings(s)
                                    phoneShowsSection = true
                                }
                                .padding(.leading, 18)
                            }
                        }
                        .padding(.top, 4 + 1).padding(.bottom, 1)
                        #if os(macOS)
                        .onMoveCommand { direction in
                            guard let i = sections.firstIndex(of: nav.place.settings) else { return }
                            let next = direction == .down ? i + 1 : direction == .up ? i - 1 : i
                            if next != i, sections.indices.contains(next) {
                                // The focus follows the choice, as in a ListBox.
                                arrowMoved = true
                                nav.goSettings(sections[next])
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { arrowMoved = false }
                            }
                        }
                        #endif
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Self.listName(key))
                    }
                }
                .padding(.bottom, 8) // the Expander's Margin 0,0,0,8
            }
        }
    }

    /// The lists' names for screen readers (SettingsPage.xaml's AutomationProperties.Name).
    private static func listName(_ key: String) -> String {
        switch key {
        case "DictationGroup": "Dictation settings"
        case "ModelsGroup": "Models & AI settings"
        case "LookGroup": "Look & feel settings"
        default: "App settings"
        }
    }

    @ViewBuilder private var section: some View {
        let s = nav.place.settings
        VStack(alignment: .leading, spacing: 0) {
            if sizeClass == .compact {
                Button("‹ Settings") { phoneShowsSection = false }.buttonStyle(.quietSmall).padding(.bottom, 12)
            }
            PageTitle(title: s == .about ? "Oberton" : s.title, japanese: s == .about ? "倍音" : "設定",
                      readout: "Section \(s.address)" + (s == .about ? "\nAbout" : ""))
                .padding(.bottom, 14)
            switch s {
            case .general: GeneralSection()
            case .hotkeys: HotkeysSection()
            case .microphone: MicrophoneSection()
            case .history: HistorySettingsSection()
            case .models: ModelsSection()
            case .speech: SpeechSection()
            case .cloud: CloudSection()
            case .unloading: UnloadingSection()
            case .appearance: AppearanceSection()
            case .layout: LayoutSection()
            case .advanced: AdvancedSection()
            case .about: AboutSection()
            case .updates: UpdatesSection()
            }
        }
    }
}

/// A group's heading (NavGroup's ToggleButton with SettingsGroupHeader): mono 15 bold ink, "−" open and "+" folded at
/// the right, the hover wash in a 4-pt-rounded box that outlines in the accent with the keyboard focus.
private struct GroupHeader: View {
    var title: String
    var folded: Bool
    var action: () -> Void
    @Environment(\.ob) private var ob
    @State private var hover = false
    @FocusState private var focused
    @State private var keyFocused = false

    var body: some View {
        Button(action: action) {
            // The sign is docked right at the top of the row; the heading is centred in it (the taller, so also on top).
            HStack(alignment: .top) {
                Text(title.uppercased()).font(Ob.mono(15, .bold))
                Spacer()
                Text(folded ? "+" : "−").font(Ob.mono(12)).foregroundStyle(ob.muted)
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 4).fill(hover ? ob.subtle : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused || keyFocused ? ob.accent : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .tabStop(focused: $keyFocused, action: action)
        .onHover { hover = $0 }
        .handCursor()
        // The Expander's toggle: its heading as written, with its expanded state.
        .accessibilityLabel(title.uppercased())
        .accessibilityValue(folded ? "collapsed" : "expanded")
    }
}

extension SettingsSection {
    /// The pages Windows gives MaxWidth 820 rather than 760.
    var wide: Bool { [.models, .appearance, .layout, .about, .updates].contains(self) }

    /// The group's Expander name on Windows, as `collapsedSettingsGroups` stores it.
    var groupKey: String {
        switch self {
        case .general, .hotkeys, .microphone, .history: "DictationGroup"
        case .models, .speech, .cloud, .unloading: "ModelsGroup"
        case .appearance, .layout: "LookGroup"
        case .advanced, .about, .updates: "AppGroup"
        }
    }

    /// A stored name as a group key; earlier Mac versions stored the heading ("A // Dictation").
    static func groupKey(stored: String) -> String { allCases.first { $0.group == stored }?.groupKey ?? stored }
}
