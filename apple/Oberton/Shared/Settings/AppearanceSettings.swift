import ObertonCore
import SwiftUI

// MARK: - C // Look & feel

/// C.1 Appearance (AppearancePage.xaml): THEME cards with miniatures, ACCENT cards with the colour on light and dark
/// paper, TEXT SIZE, and the Japanese words switch.
struct AppearanceSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Follows \(Device.system) by default. Pick Light or Dark to override it.")
            FieldLabel("Theme")
            // A UniformGrid of three, card margins 0,0,8,0 / 4,0 / 8,0,0,0: 12 between the cards.
            uniformGrid(AppTheme.allCases, outer: 8, inner: 4) { t in
                ChoiceCard(chosen: model.settings.theme == t, action: { model.settings.theme = t }) {
                    VStack(alignment: .leading, spacing: 0) {
                        ThemePreview(theme: t).frame(height: 84)
                        Text(t.rawValue.uppercased()).font(Ob.mono(12, .bold)).noWrap().padding(EdgeInsets(top: 10, leading: 4, bottom: 2, trailing: 0))
                        // The SYSTEM card says what the system is now, while it is the one chosen (a MonoLabel); LIGHT
                        // and DARK hold a blank line in the window's 12, which sets the row's height for all three.
                        ZStack(alignment: .leading) {
                            Text(" ").font(Ob.sans(Ob.body)).hidden()
                            if t == .system {
                                Readout(model.settings.theme == .system ? (scheme == .dark ? "Dark right now" : "Light right now") : " ").noWrap()
                            }
                        }
                        .padding(EdgeInsets(top: 0, leading: 4, bottom: 2, trailing: 0))
                    }
                }
                .accessibilityLabel(t.rawValue.capitalized)
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Theme")
            FieldLabel("Accent").padding(.top, 8)
            // Five columns, card margins 0,0,4,0 / 4,0 / … / 4,0,0,0: the outer two are 4 wider than the middle three.
            uniformGrid(AccentChoice.allCases, outer: 4, inner: 4) { a in
                ChoiceCard(chosen: model.settings.accent == a, action: { model.settings.accent = a }) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 4) {
                            swatch(Color(hex: a.hex.light), paper: Color(hex: 0xE8E7E3))
                            swatch(Color(hex: a.hex.dark), paper: Color(hex: 0x0E0E0D))
                        }
                        .padding(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 0))
                        Text(a.title.uppercased()).font(Ob.mono(11, .bold)).noWrap()
                            .padding(EdgeInsets(top: 10, leading: 4, bottom: 2, trailing: 0))
                    }
                }
                .accessibilityLabel(a.title)
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Accent color")
            Caption("Oberton is ink on paper. The accent marks what is live or matters most right now: today's word count, the unload countdown, the word being read, words the AI added, and errors. Each accent has a version for light and for dark paper. Red is not offered: it means the microphone is recording.", bottom: 0)
                .padding(.top, 6)
            FieldLabel("Text size").padding(.top, 8)
            textSize
            #if os(macOS)
            Caption("Everything in this window grows or shrinks together, from 70% to 200%. Anywhere in the app: ⌘ and + makes it larger, ⌘ and − smaller, ⌘ and 0 puts it back to 100%.", bottom: 0)
                .padding(.top, 6)
            #else
            Caption("Everything in this window grows or shrinks together, from 70% to 200%. With a keyboard: ⌘ and + makes it larger, ⌘ and − smaller, ⌘ and 0 puts it back to 100%.", bottom: 0)
                .padding(.top, 6)
            #endif
            FieldLabel("Japanese words").padding(.top, 8)
            SwitchCard {
                ObSwitch("Show the Japanese words beside labels",
                         detail: "Small decorative words such as 設定 (settings) next to page titles, the menu and the dictation pill. They are decoration only; turning them off changes nothing else.",
                         isOn: $model.settings.showJapanese)
            }
        }
    }

    /// A− 125% A+ RESET (AppearancePage's TEXT SIZE row); the window shows the new size for a moment.
    private var textSize: some View {
        let scale = TextSize.clamped(model.settings.uiScale)
        return HStack(spacing: 0) {
            Button("A−") { model.settings.uiScale = TextSize.step(from: scale, -1) }
                .buttonStyle(CapsuleButtonStyle(kind: .quiet, minWidth: 52))
                .disabled(scale <= TextSize.min + 0.001)
                .help("Smaller (⌘+minus)").accessibilityLabel("Make the text smaller")
            Text(Fmt.percent(scale)).font(Ob.mono(14, .bold)).frame(minWidth: 64).padding(.horizontal, 8)
            Button("A+") { model.settings.uiScale = TextSize.step(from: scale, +1) }
                .buttonStyle(CapsuleButtonStyle(kind: .quiet, minWidth: 52))
                .disabled(scale >= TextSize.max - 0.001)
                .help("Larger (⌘+plus)").accessibilityLabel("Make the text larger")
            Button("Reset") { model.settings.uiScale = 1 }
                .buttonStyle(.quiet).padding(.leading, 12)
                .help("Back to 100% (\(TextSize.resetKey))")
        }
    }

    /// 22×22 of paper in a faint grey 1 px frame, Padding 5 inside the frame: a 10×10 square of the accent.
    private func swatch(_ c: Color, paper: Color) -> some View {
        Rectangle().fill(paper).frame(width: 22, height: 22)
            .overlay(Rectangle().fill(c).frame(width: 10, height: 10))
            .overlay(Rectangle().strokeBorder(Color(hex: 0x808080, alpha: 0x55 / 255.0), lineWidth: 1))
    }

    /// A UniformGrid row: equal columns, each card inset by its margin (`outer` at the row's ends' far sides is 0, the
    /// first card's right and the last card's left use `outer`, the others `inner` on both sides).
    private func uniformGrid<Item: Hashable, Card: View>(_ items: [Item], outer: CGFloat, inner: CGFloat,
                                                        @ViewBuilder card: @escaping (Item) -> Card) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { i, item in
                let first = i == 0, last = i == items.count - 1
                card(item)
                    .padding(.leading, first ? 0 : last ? outer : inner)
                    .padding(.trailing, last ? 0 : first ? outer : inner)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// A miniature of the window in a theme (AppearancePage's PreviewFrame, fixed colours on purpose): LIGHT and DARK a
/// 36-wide sidebar line, a 56×6 title, a rule and two 4-high muted lines; SYSTEM half light (an 18-wide sidebar line and
/// a 40×6 title) and half dark (the title only).
private struct ThemePreview: View {
    var theme: AppTheme

    var body: some View {
        Group {
            if theme == .system {
                HStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        Color(hex: 0xE8E7E3)
                        Rectangle().fill(Color(hex: 0x0D0D0C)).frame(width: 1).frame(maxHeight: .infinity).padding(.leading, 17)
                        Rectangle().fill(Color(hex: 0x0D0D0C)).frame(width: 40, height: 6).padding(EdgeInsets(top: 14, leading: 26, bottom: 0, trailing: 0))
                    }
                    ZStack(alignment: .topLeading) {
                        Color(hex: 0x0E0E0D)
                        Rectangle().fill(Color(hex: 0xE8E7E3)).frame(width: 40, height: 6).padding(EdgeInsets(top: 14, leading: 10, bottom: 0, trailing: 0))
                    }
                }
            } else {
                sheet(dark: theme == .dark)
            }
        }
        // PreviewFrame lays the drawing inside its 1 px line (and clips it there).
        .clipShape(Rectangle())
        .padding(Ob.border)
        .background(theme == .system ? Color.clear : theme == .dark ? Color(hex: 0x0E0E0D) : Color(hex: 0xE8E7E3), in: RoundedRectangle(cornerRadius: 2))
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color(hex: 0x808080, alpha: 0x55 / 255.0), lineWidth: 1))
    }

    private func sheet(dark: Bool) -> some View {
        let paper = Color(hex: dark ? 0x0E0E0D : 0xE8E7E3), ink = Color(hex: dark ? 0xE8E7E3 : 0x0D0D0C)
        let muted = Color(hex: dark ? 0x8F8D87 : 0x5C5B57)
        return ZStack(alignment: .topLeading) {
            paper
            Rectangle().fill(ink).frame(width: 1).frame(maxHeight: .infinity).padding(.leading, 35)
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(ink).frame(width: 56, height: 6)
                Rectangle().fill(ink).frame(height: 1).padding(.top, 6)
                Rectangle().fill(muted).frame(height: 4).padding(.top, 8)
                Rectangle().fill(muted).frame(height: 4).padding(.top, 6).padding(.trailing, 20)
            }
            .padding(EdgeInsets(top: 14, leading: 46, bottom: 0, trailing: 12))
        }
    }
}
