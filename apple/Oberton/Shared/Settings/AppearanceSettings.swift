import ObertonCore
import SwiftUI

// MARK: - C // Look & feel

struct AppearanceSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Follows the \(Device.noun)'s appearance by default. Pick Light or Dark to override it.")
            FieldLabel("Theme")
            HStack(spacing: 8) {
                ForEach(AppTheme.allCases, id: \.self) { t in
                    ChoiceCard(chosen: model.settings.theme == t, action: { model.settings.theme = t }) {
                        VStack(alignment: .leading, spacing: 6) {
                            ThemePreview(theme: t).frame(height: 84)
                            Text(t.rawValue.uppercased()).font(Ob.mono(12, .bold))
                            Readout(t == .system ? "Follows the \(Device.noun)" : " ")
                        }
                    }
                }
            }
            FieldLabel("Accent")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(AccentChoice.allCases, id: \.self) { a in
                    ChoiceCard(chosen: model.settings.accent == a, action: { model.settings.accent = a }) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 5) {
                                swatch(Color(hex: a.hex.light), paper: Color(hex: 0xE8E7E3))
                                swatch(Color(hex: a.hex.dark), paper: Color(hex: 0x0E0E0D))
                            }
                            Text(a.title.uppercased()).font(Ob.mono(11, .bold)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                }
            }
            Caption("Oberton is ink on paper. The accent marks what is live or matters most: today's count, the word being read, words the AI added. Red is not offered: it means the microphone is recording.", size: 12.5)
                .padding(.top, 8)
            FieldLabel("Japanese words")
            SwitchCard {
                ObSwitch("Show the Japanese words beside labels",
                         detail: "Small decorative words such as 設定 (settings). They are decoration only, and hidden from screen readers.",
                         isOn: $model.settings.showJapanese)
            }
        }
    }

    private func swatch(_ c: Color, paper: Color) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(paper).frame(width: 22, height: 22)
            .overlay(Circle().fill(c).frame(width: 12, height: 12))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.gray.opacity(0.5), lineWidth: 1))
    }
}

/// A miniature of the window in a theme: a sidebar line, a title, a rule and lines of text.
private struct ThemePreview: View {
    var theme: AppTheme

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                sheet(dark: theme == .dark)
                if theme == .system { sheet(dark: true) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.gray.opacity(0.5), lineWidth: 1))
    }

    private func sheet(dark: Bool) -> some View {
        let paper = Color(hex: dark ? 0x0E0E0D : 0xE8E7E3), ink = Color(hex: dark ? 0xE8E7E3 : 0x0D0D0C)
        return HStack(spacing: 0) {
            Rectangle().fill(paper).frame(width: 18).overlay(alignment: .trailing) { Rectangle().fill(ink).frame(width: 1) }
            VStack(alignment: .leading, spacing: 4) {
                Rectangle().fill(ink).frame(width: 34, height: 5)
                Rectangle().fill(ink).frame(height: 1)
                ForEach([0.8, 0.6, 0.7], id: \.self) { w in
                    GeometryReader { g in Rectangle().fill(ink.opacity(0.35)).frame(width: g.size.width * w, height: 3) }.frame(height: 3)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(paper)
        }
    }
}
