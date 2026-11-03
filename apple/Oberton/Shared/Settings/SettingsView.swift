import ObertonCore
import SwiftUI

/// SETTINGS 設定: a menu of its own at the left, in four foldable groups, and the chosen section at the right
/// (SettingsPage.xaml). Folded groups are remembered (`collapsedSettingsGroups`), and opening a section unfolds its
/// group. On iPhone the menu is a page and a section opens over it.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var phoneShowsSection = false

    private var folded: Set<String> { Set(model.settings.collapsedSettingsGroups) }

    private func setFolded(_ group: String, _ fold: Bool) {
        var groups = model.settings.collapsedSettingsGroups.filter { $0 != group }
        if fold { groups.append(group) }
        if groups != model.settings.collapsedSettingsGroups { model.settings.collapsedSettingsGroups = groups }
    }

    var body: some View {
        content
            .onAppear { setFolded(nav.place.settings.group, false) }
            .onChange(of: nav.place.settings) { _, s in setFolded(s.group, false) }
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
                    section
                        .padding(EdgeInsets(top: 32, leading: 40, bottom: 40, trailing: 40))
                        .frame(maxWidth: nav.place.settings.wide ? 820 : 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                Text("SETTINGS").font(Ob.mono(18, .bold))
                Spacer()
                Decor("設定")
            }
            .padding(.bottom, 10)
            ForEach(SettingsSection.groups, id: \.0) { group, sections in
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        setFolded(group, !folded.contains(group))
                    } label: {
                        HStack {
                            Text(group.uppercased()).font(Ob.mono(15, .bold))
                            Spacer()
                            Text(folded.contains(group) ? "+" : "−").font(Ob.mono(12)).foregroundStyle(ob.muted)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if !folded.contains(group) {
                        ForEach(sections, id: \.self) { s in
                            NavCapsule(title: s.title, size: 11.5, selected: nav.place.settings == s && sizeClass != .compact) {
                                nav.goSettings(s)
                                phoneShowsSection = true
                            }
                            .padding(.leading, 18)
                        }
                    }
                }
            }
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

extension SettingsSection {
    var wide: Bool { [.models, .appearance, .layout].contains(self) }
}
