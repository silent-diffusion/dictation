import ObertonCore
import SwiftUI

// MARK: - C // Look & feel

struct AppearanceSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @Environment(\.colorScheme) private var scheme

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
                            // The SYSTEM card says what the system is now, while it is the one chosen.
                            Readout(t == .system && model.settings.theme == .system ? (scheme == .dark ? "Dark right now" : "Light right now") : " ")
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
            Caption("Oberton is ink on paper. The accent marks what is live or matters most right now: today's word count, the unload countdown, the word being read, words the AI added, and errors. Each accent has a version for light and for dark paper. Red is not offered: it means the microphone is recording.", size: 12.5)
                .padding(.top, 8)
            FieldLabel("Text size")
            textSize
            #if os(macOS)
            Caption("Everything in this window grows or shrinks together, from 70% to 200%. Anywhere in the app: ⌘ and + makes it larger, ⌘ and − smaller, ⌘ and 0 puts it back to 100%.", size: 12.5)
                .padding(.top, 6)
            #else
            Caption("Everything in this window grows or shrinks together, from 70% to 200%. With a keyboard: ⌘ and + makes it larger, ⌘ and − smaller, ⌘ and 0 puts it back to 100%.", size: 12.5)
                .padding(.top, 6)
            #endif
            FieldLabel("Japanese words")
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
                .buttonStyle(.quiet).frame(minWidth: 52)
                .disabled(scale <= TextSize.min + 0.001)
                .help("Smaller (⌘−)").accessibilityLabel("Make the text smaller")
            Text("\(Int((scale * 100).rounded()))%").font(Ob.mono(14, .bold)).frame(minWidth: 64).padding(.horizontal, 8)
            Button("A+") { model.settings.uiScale = TextSize.step(from: scale, +1) }
                .buttonStyle(.quiet).frame(minWidth: 52)
                .disabled(scale >= TextSize.max - 0.001)
                .help("Larger (⌘+)").accessibilityLabel("Make the text larger")
            Button("Reset") { model.settings.uiScale = 1 }
                .buttonStyle(.quiet).padding(.leading, 12)
                .help("Back to 100% (\(TextSize.resetKey))")
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
