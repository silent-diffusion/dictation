import ObertonCore
import SwiftUI

// Oberton is drawn like a printed instrument panel: black ink on gray paper, 1px lines, capitalized monospaced labels and
// readouts, rings of dots and block bars for numbers; dark mode is the same sheet inverted. Color is a signal: the accent
// marks what is live or most important, and red means the microphone is recording, nowhere else.
// The tokens are the Windows app's own (src/Dictation.App/Themes/Light.xaml, Dark.xaml, App.xaml).

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// The colors of one sheet of paper: light or dark, with the chosen accent.
struct Palette {
    var dark: Bool
    var accentChoice: AccentChoice

    /// Paper: page and sidebar background.
    var paper: Color { dark ? Color(hex: 0x0E0E0D) : Color(hex: 0xE8E7E3) }
    /// Ink: body text, frames, rules, filled capsules.
    var ink: Color { dark ? Color(hex: 0xE8E7E3) : Color(hex: 0x0D0D0C) }
    /// Secondary text and readouts; empty dots; switch outlines when off.
    var muted: Color { dark ? Color(hex: 0x8F8D87) : Color(hex: 0x5C5B57) }
    /// Hairlines between cells and rows.
    var divider: Color { dark ? Color(hex: 0xE8E7E3, alpha: 0.24) : Color(hex: 0x0D0D0C, alpha: 0.22) }
    /// Faint wash: hovered rows, previews.
    var subtle: Color { dark ? Color(hex: 0xE8E7E3, alpha: 0.10) : Color(hex: 0x0D0D0C, alpha: 0.10) }
    /// Text on ink.
    var onInk: Color { paper }
    var record: Color { dark ? Color(hex: 0xFF4636) : Color(hex: 0xE3261A) }
    var accent: Color { Color(hex: dark ? accentChoice.hex.dark : accentChoice.hex.light) }
    var accentWash: Color { Color(hex: dark ? accentChoice.hex.dark : accentChoice.hex.light, alpha: dark ? 0.16 : 0.12) }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(dark: false, accentChoice: .violet)
}

private struct ShowJapaneseKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var ob: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }

    var showJapanese: Bool {
        get { self[ShowJapaneseKey.self] }
        set { self[ShowJapaneseKey.self] = newValue }
    }
}

/// The type: a monospaced face for the interface (Cascadia Mono, bundled as on Windows; SF Mono if it didn't load), a
/// sans for prose, and a Japanese face for the decorative words.
enum Ob {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        hasCascadia ? .custom("Cascadia Mono", fixedSize: size).weight(weight) : .system(size: size, weight: weight, design: .monospaced)
    }

    /// `mono` for the TextKit views (Extended Notes' Markdown, the reader): the same face at a weight, which the
    /// variable font gives as its named instances (CascadiaMono-Regular_Bold…).
    static func monoFont(_ size: CGFloat, _ weight: PlatformFont.Weight = .regular) -> PlatformFont {
        guard hasCascadia else { return .monospacedSystemFont(ofSize: size, weight: weight) }
        #if os(macOS)
        let d = NSFontDescriptor(fontAttributes: [.family: "Cascadia Mono", .traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: d, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
        #else
        let d = UIFontDescriptor(fontAttributes: [.family: "Cascadia Mono", .traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: d, size: size)
        #endif
    }

    /// Whether the bundled Cascadia Mono (Resources/Fonts, copied to the bundle's Resources and registered through Info.plist) is available.
    static let hasCascadia: Bool = {
        #if os(macOS)
        NSFont(name: "CascadiaMono-Regular", size: 12) != nil
        #else
        UIFont(name: "CascadiaMono-Regular", size: 12) != nil
        #endif
    }()

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    /// The window's own text size: WPF draws text without a size of its own at 12 (MainWindow sets none).
    static let body: CGFloat = 12
    /// Extra space between lines for text set at `size` to land on a WPF LineHeight of `lineHeight`. The natural line
    /// is the face's own: about 1.2× for the sans, 1.162× for Cascadia Mono ((1900 + 480) / 2048, its hhea).
    static func lineSpacing(_ size: CGFloat, lineHeight: CGFloat, mono: Bool = false) -> CGFloat {
        max(0, lineHeight - size * (mono && hasCascadia ? 1.162 : 1.2))
    }
    /// Windows' "Yu Gothic UI, Yu Gothic, Meiryo": Yu Gothic when this Mac has it (macOS offers it as a download in Font
    /// Book; Oberton doesn't fetch it, so it makes no request Windows doesn't), else Hiragino Sans, the system's own.
    static func jp(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom(jpFamily, size: size).weight(weight) }
    static let jpFamily: String = {
        #if os(macOS)
        NSFont(name: "YuGothic-Medium", size: 12) != nil ? "YuGothic" : "Hiragino Sans"
        #else
        UIFont(name: "YuGothic-Medium", size: 12) != nil ? "YuGothic" : "Hiragino Sans"
        #endif
    }()
    /// A WPF Border's 1 px line. WPF lays a Border's Padding out INSIDE its BorderThickness, so content sits padding + 1
    /// from the outer edge, where SwiftUI's overlaid stroke would sit on the padding: the shared boxes add it.
    static let border: CGFloat = 1
}

/// Applies the paper, the palette and the Japanese setting from Settings to everything inside.
struct ObertonTheme: ViewModifier {
    var settings: AppSettings
    @Environment(\.colorScheme) private var system

    func body(content: Content) -> some View {
        let dark = settings.theme == .dark || (settings.theme == .system && system == .dark)
        let palette = Palette(dark: dark, accentChoice: settings.accent)
        content
            .environment(\.ob, palette)
            .environment(\.showJapanese, settings.showJapanese)
            .tint(palette.ink) // the system controls' own accent is ink, so that color stays a signal (Light/Dark.xaml's Fluent keys)
            .foregroundStyle(palette.ink)
            // Windows draws keyboard focus itself, as an accent border on each styled control (App.xaml's
            // IsKeyboardFocused triggers), so the system's ring is off; the controls draw theirs.
            .focusEffectDisabled()
            .preferredColorScheme(settings.theme == .system ? nil : dark ? .dark : .light)
    }
}

extension View {
    func obertonTheme(_ settings: AppSettings) -> some View { modifier(ObertonTheme(settings: settings)) }
}

/// The text size: the whole window scaled, 70% to 200% in Windows' steps (MainWindow.Zoom), saved as `uiScale`.
enum TextSize {
    static let steps = [0.7, 0.8, 0.9, 1.0, 1.1, 1.25, 1.4, 1.5, 1.75, 2.0]
    static let min = 0.7, max = 2.0

    static func clamped(_ scale: Double) -> Double {
        Swift.min(Swift.max(scale.isFinite && scale > 0 ? scale : 1, min), max)
    }

    /// One step larger (+1) or smaller (-1) than `scale`.
    static func step(from scale: Double, _ direction: Int) -> Double {
        let now = clamped(scale)
        return direction > 0 ? steps.first { $0 > now + 0.001 } ?? max : steps.last { $0 < now - 0.001 } ?? min
    }

    // The shortcuts as tooltips and captions name them (Windows: Ctrl+0, Ctrl+B, Alt+Left; Ctrl → ⌘, the "+" kept).
    /// Settings › Appearance's A−, A+ and RESET go through the window, as Windows' Main.Zoom / Main.SetZoom: the toast
    /// shows even when the size doesn't change (RESET at 100%). RootView answers it.
    static let request = Notification.Name("ObertonSetTextSize")
    static func set(_ scale: Double) { NotificationCenter.default.post(name: request, object: nil, userInfo: ["scale": scale]) }

    static let resetKey = "⌘+0"
    static let menuKey = "⌘+B"
    static let backKey = "⌘+["
}

/// Numbers as Windows formats them: in the user's region ("1,75", "125 %"), a half rounded away from zero (.NET's
/// format strings); `Fmt.banker` is Math.Round's default, half to even, for counts Windows rounds in code.
enum Fmt {
    private static func formatter(_ style: NumberFormatter.Style, _ digits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = .current
        f.numberStyle = style
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        f.roundingMode = .halfUp
        return f
    }

    /// "P0": 0.9 → "90%" (or "90 %").
    static func percent(_ value: Double, digits: Int = 0) -> String {
        formatter(.percent, digits).string(from: NSNumber(value: value)) ?? "\(Int((value * 100).rounded()))%"
    }

    /// "N0", "N1"…: grouped, with the region's decimal mark.
    static func number(_ value: Double, digits: Int = 0) -> String {
        formatter(.decimal, digits).string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "F2": no grouping, the region's decimal mark ("1,75").
    static func fixed(_ value: Double, digits: Int) -> String {
        let f = formatter(.decimal, digits)
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    /// Math.Round(x): a half goes to the even neighbour (2.5 → 2, 3.5 → 4).
    static func banker(_ value: Double) -> Double { value.rounded(.toNearestOrEven) }
}

/// Lays the window out at 1/scale of its size and scales it up to fill (WPF's LayoutTransform on the root), so
/// everything grows or shrinks together.
struct ZoomedWindow<Content: View>: View {
    var scale: Double
    @ViewBuilder var content: Content

    var body: some View {
        if abs(scale - 1) < 0.001 {
            content
        } else {
            GeometryReader { geo in
                content
                    .frame(width: geo.size.width / scale, height: geo.size.height / scale)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Text

/// A readout: small capitals in the mono face, muted, letter-spaced ("SIGNAL PATH", "ENGINE // STATUS").
struct Readout: View {
    var text: String
    var size: CGFloat = 10.5
    var color: Color?
    var weight: Font.Weight = .regular
    /// Capitals (the Windows XAML writes its labels in capitals); false shows a text as it is (a MonoLabel set from code).
    var caps = true
    @Environment(\.ob) private var ob

    init(_ text: String, size: CGFloat = 10.5, color: Color? = nil, weight: Font.Weight = .regular, caps: Bool = true) {
        self.text = text
        self.size = size
        self.color = color
        self.weight = weight
        self.caps = caps
    }

    var body: some View {
        Text(caps ? text.uppercased() : text)
            .font(Ob.mono(size, weight))
            .foregroundStyle(color ?? ob.muted)
    }
}

/// A decorative Japanese word (倍音 overtone, 計器 instrument…): hidden from screen readers, and from everyone when
/// Settings › Appearance turns them off.
struct Decor: View {
    var text: String
    var size: CGFloat = 11
    var color: Color?
    var weight: Font.Weight = .regular
    @Environment(\.ob) private var ob
    @Environment(\.showJapanese) private var show

    init(_ text: String, size: CGFloat = 11, color: Color? = nil, weight: Font.Weight = .regular) {
        self.text = text
        self.size = size
        self.color = color
        self.weight = weight
    }

    var body: some View {
        if show {
            Text(text).font(Ob.jp(size, weight)).foregroundStyle(color ?? ob.muted).accessibilityHidden(true)
        }
    }
}

/// A page's title: "HISTORY 履歴" (the Japanese word large and faint), a readout at the right, an ink rule under it, and
/// a line of summary (Decor.cs PageHeader; the dashboard's is a little smaller).
struct PageTitle<Trailing: View>: View {
    var title: String
    var japanese: String?
    var summary: String?
    var size: CGFloat = 34
    @ViewBuilder var trailing: Trailing
    @Environment(\.ob) private var ob

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Decor.cs PageHeader: the title at the top of the row, cut with "…"; the decor 14 after it and 2 above the
            // row's bottom; the readout right-aligned, 16 from the rest and 6 above the bottom.
            HeaderRow(decorGap: 14, decorBottom: 2, trailingGap: 16, trailingBottom: 6) {
                // Windows cuts a long title with "…"; the Mac wraps it so the whole title shows.
                Text(title.uppercased()).font(Ob.mono(size, .bold)).fixedSize(horizontal: false, vertical: true)
                    .layoutValue(key: HeaderRow.RoleKey.self, value: .title)
                if let japanese {
                    Decor(japanese, size: size - 4, color: ob.divider, weight: .bold).noWrap()
                        .layoutValue(key: HeaderRow.RoleKey.self, value: .decor)
                }
                VStack(alignment: .trailing, spacing: 0) { trailing }.multilineTextAlignment(.trailing).fixedSize()
                    .layoutValue(key: HeaderRow.RoleKey.self, value: .trailing)
            }
            Rule().padding(.top, 6)
            if let summary {
                Caption(summary).padding(.top, 14)
            }
        }
    }
}

/// A page header's row as Windows lays it out (Decor.cs PageHeader's DockPanel, and the horizontal StackPanels of the
/// Dashboard, Analytics and Extended Notes headers): the readout docked right is measured first, then the title takes what
/// it needs of the rest, and the decor gets what is left (squeezed out before the title is cut). The title sits at the TOP
/// of the row (a TextBlock left at Stretch); the decor and the readout sit at its bottom.
struct HeaderRow: Layout {
    enum Role { case title, decor, trailing }
    struct RoleKey: LayoutValueKey { static let defaultValue = Role.title }
    var decorGap: CGFloat
    var decorBottom: CGFloat
    var trailingGap: CGFloat
    var trailingBottom: CGFloat

    private struct Frames { var title: CGSize = .zero, decor: CGSize = .zero, trailing: CGSize = .zero, height: CGFloat = 0 }

    private func measure(_ width: CGFloat?, _ subviews: Subviews) -> Frames {
        var f = Frames()
        var room = width ?? .infinity
        func fit(_ v: LayoutSubview, _ gap: CGFloat) -> CGSize {
            let avail = max(0, room - gap)
            var size = v.sizeThatFits(ProposedViewSize(width: avail.isFinite ? avail : nil, height: nil))
            size.width = min(size.width, avail)
            room = max(0, room - (size.width > 0 ? size.width + gap : 0))
            return size
        }
        for v in subviews where v[RoleKey.self] == .trailing { f.trailing = fit(v, trailingGap) }
        for v in subviews where v[RoleKey.self] == .title { f.title = fit(v, 0) }
        for v in subviews where v[RoleKey.self] == .decor { f.decor = fit(v, decorGap) }
        f.height = max(f.title.height, f.decor.height > 0 ? f.decor.height + decorBottom : 0,
                       f.trailing.height > 0 ? f.trailing.height + trailingBottom : 0)
        return f
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let f = measure(proposal.width, subviews)
        let used = f.title.width + (f.decor.width > 0 ? decorGap + f.decor.width : 0) + (f.trailing.width > 0 ? trailingGap + f.trailing.width : 0)
        return CGSize(width: proposal.width ?? used, height: f.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let f = measure(bounds.width, subviews)
        for v in subviews {
            switch v[RoleKey.self] {
            case .title:
                v.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(f.title))
            case .decor:
                v.place(at: CGPoint(x: bounds.minX + f.title.width + decorGap, y: bounds.maxY - decorBottom), anchor: .bottomLeading,
                        proposal: ProposedViewSize(f.decor))
            case .trailing:
                v.place(at: CGPoint(x: bounds.maxX, y: bounds.maxY - trailingBottom), anchor: .bottomTrailing, proposal: ProposedViewSize(f.trailing))
            }
        }
    }
}

extension PageTitle where Trailing == Readout {
    init(title: String, japanese: String? = nil, readout: String, summary: String? = nil, size: CGFloat = 34) {
        self.init(title: title, japanese: japanese, summary: summary, size: size) { Readout(readout) }
    }
}

/// A field's label: mono 12 bold ink, with room above it ("MODEL", "THEME").
struct FieldLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        // NoWrap: a label too long for its column is cut off, not wrapped (WPF's TextBlock default).
        Text(text.uppercased()).font(Ob.mono(12, .bold)).noWrap().padding(.top, 20).padding(.bottom, 6)
    }
}

/// Helper prose under a control (App.xaml's Caption): the window's 12, muted, wrapping, every line 19 tall, and 12 below
/// it unless the Windows page sets its own margin (`bottom: 0`).
struct Caption: View {
    var text: String
    var size: CGFloat = Ob.body
    var bottom: CGFloat = 12
    @Environment(\.ob) private var ob
    init(_ text: String, size: CGFloat = Ob.body, bottom: CGFloat = 12) { self.text = text; self.size = size; self.bottom = bottom }
    var body: some View {
        Text(text).font(Ob.sans(size)).foregroundStyle(ob.muted).wpfLineHeight(19, size: size)
            .fixedSize(horizontal: false, vertical: true).padding(.bottom, bottom)
    }
}

extension View {
    /// Text set on a WPF LineHeight: every line `lineHeight` tall, the first and last included. WPF's TextBlock (the
    /// default MaxHeight stacking) draws each line at the top of its line box, so the extra space falls below each line;
    /// `.lineSpacing` gives it between lines only, so the last line's share is added under the block.
    func wpfLineHeight(_ lineHeight: CGFloat, size: CGFloat, mono: Bool = false) -> some View {
        let extra = Ob.lineSpacing(size, lineHeight: lineHeight, mono: mono)
        return self.lineSpacing(extra).padding(.bottom, extra)
    }

    /// A WPF TextBlock without TextTrimming (NoWrap): one line at its own width. Where Windows then cuts it off at the
    /// end of the room, the Mac wraps it onto another line instead, so every word shows.
    func noWrap() -> some View {
        NoWrapLine { self.fixedSize(horizontal: false, vertical: true) }
    }
}

/// Lays its one subview out at its ideal width and reports no more than the width offered, so the overflow can be cut.
private struct NoWrapLine: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let v = subviews.first else { return .zero }
        let ideal = v.sizeThatFits(.unspecified)
        let width = min(ideal.width, proposal.width ?? ideal.width)
        return width >= ideal.width ? ideal : v.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let v = subviews.first else { return }
        v.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

// MARK: - Lines

/// An ink line: under page titles and bars.
struct Rule: View {
    @Environment(\.ob) private var ob
    var body: some View { Rectangle().fill(ob.ink).frame(height: 1) }
}

/// A hairline between cells and rows.
struct Hairline: View {
    var vertical = false
    @Environment(\.ob) private var ob
    var body: some View {
        Rectangle().fill(ob.divider).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// A cell of the instrument panel. Cells share hairline edges instead of floating as cards: the panel draws its top and
/// left edge, each cell its right and bottom edge. A cell that is a link gets the accent wash on hover. `padding` is the
/// Windows Padding; the right and bottom lines (BorderThickness 0,0,1,1) sit outside it, as in WPF.
struct Cell<Content: View>: View {
    var link = false
    var padding = EdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 16)
    @ViewBuilder var content: Content
    @State private var hover = false
    @Environment(\.ob) private var ob

    var body: some View {
        content
            .padding(padding)
            .padding(.trailing, Ob.border).padding(.bottom, Ob.border)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(link && hover ? ob.accentWash : .clear)
            .overlay(alignment: .trailing) { Hairline(vertical: true) }
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

/// A hairline box (the Windows "Card"): no fill, no shadow, square corners. `padding` is the Windows Padding, inside the line.
struct Box<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    @Environment(\.ob) private var ob

    var body: some View {
        content
            .padding(padding + Ob.border)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: Ob.border))
    }
}

// MARK: - Buttons

#if os(macOS)
/// On the Mac the capsules are a PrimitiveButtonStyle, so the keyboard can press them (SYS-007, see `tabStop`).
typealias ObButtonStyle = PrimitiveButtonStyle
#else
typealias ObButtonStyle = ButtonStyle
#endif

/// Capsules (App.xaml's PrimaryButton, QuietButton, DashedButton). Filled ink = the main action; ink outline = the
/// others; dashed = something to add. Always at least 34 tall with CornerRadius 17 (a capsule at 34; Setup's 40-tall
/// ones keep 17), the hand cursor over them, and an accent border while they have the keyboard focus. On the Mac each is
/// a Tab stop, takes the focus when clicked, and Space or Return presses it, as a WPF Button.
struct CapsuleButtonStyle: ObButtonStyle {
    enum Kind { case primary, quiet, dashed }
    var kind: Kind = .quiet
    var size: CGFloat = 12
    var compact = false
    /// The space left and right of the text, when a page sets its own (Windows' Padding="12,6").
    var padding: CGFloat?
    /// Windows' MinHeight: 34, or 40 in the setup window.
    var height: CGFloat = 34
    /// Windows' MinWidth on the button itself (the capsule grows to it).
    var minWidth: CGFloat? = nil
    @Environment(\.ob) private var ob
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        Pressable(trigger: configuration.trigger) { pressed, keyFocused in
            Face(label: configuration.label, kind: kind, size: size, padding: padding ?? (compact ? 10 : 16), height: height,
                 minWidth: minWidth, ob: ob, enabled: enabled, focused: focused || keyFocused, pressed: pressed)
        }
        #else
        Face(label: configuration.label, kind: kind, size: size, padding: padding ?? (compact ? 10 : 16), height: height,
             minWidth: minWidth, ob: ob, enabled: enabled, focused: focused, pressed: configuration.isPressed)
        #endif
    }

    private struct Face<Label: View>: View {
        var label: Label
        var kind: Kind
        var size: CGFloat
        var padding: CGFloat
        var height: CGFloat
        var minWidth: CGFloat?
        var ob: Palette
        var enabled: Bool
        var focused: Bool
        var pressed: Bool
        @State private var hover = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 17)
            label
                .font(Ob.mono(size, kind == .primary ? .semibold : .regular))
                .textCase(.uppercase)
                .lineLimit(1)
                .foregroundStyle(kind == .primary ? ob.onInk : kind == .dashed && !hover ? ob.muted : ob.ink)
                // The small ones are Windows' QuietButton with FontSize 10 and Padding 10,3: smaller text, same height.
                // The Padding sits inside the 1 px border (the dashed one has none: its template ignores Padding).
                .padding(.horizontal, kind == .dashed ? padding : padding + Ob.border)
                .frame(minWidth: minWidth, minHeight: height)
                .background {
                    switch kind {
                    case .primary: shape.fill(ob.ink)
                    case .quiet: shape.fill(hover ? ob.subtle : .clear)
                    case .dashed: Color.clear
                    }
                }
                .overlay {
                    switch kind {
                    case .primary, .quiet: shape.strokeBorder(focused ? ob.accent : ob.ink, lineWidth: 1)
                    // The dashed stroke stays muted on hover; only the text turns ink.
                    case .dashed: shape.strokeBorder(ob.muted, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .contentShape(shape)
                // App.xaml's triggers: hover .82 / pressed .66 (primary), pressed .7 (quiet), disabled .4; the dashed
                // template has only its hover colour.
                .opacity(kind == .dashed ? 1 : !enabled ? 0.4 : pressed ? (kind == .quiet ? 0.7 : 0.66) : kind == .primary && hover ? 0.82 : 1)
                .onHover { hover = $0 }
                .handCursor(enabled) // WPF shows no hand over a disabled control
        }
    }
}

extension ObButtonStyle where Self == CapsuleButtonStyle {
    static var primary: CapsuleButtonStyle { CapsuleButtonStyle(kind: .primary) }
    static var quiet: CapsuleButtonStyle { CapsuleButtonStyle(kind: .quiet) }
    static var dashed: CapsuleButtonStyle { CapsuleButtonStyle(kind: .dashed) }
    static var quietSmall: CapsuleButtonStyle { CapsuleButtonStyle(kind: .quiet, size: 10, compact: true) }
    /// A QuietButton with Padding="12,6" (Hotkeys' RESET and CLEAR, and others).
    static var quietNarrow: CapsuleButtonStyle { CapsuleButtonStyle(kind: .quiet, padding: 12) }
}

#if os(macOS)
/// A button's press as WPF's ButtonBase does it, for a PrimitiveButtonStyle: pressed while the pointer is down on it,
/// the action on release inside, and a Tab stop (`tabStop`) whatever macOS's Keyboard navigation setting.
private struct Pressable<Content: View>: View {
    var trigger: () -> Void
    @ViewBuilder var content: (_ pressed: Bool, _ keyFocused: Bool) -> Content
    @State private var pressed = false
    @State private var keyFocused = false
    @State private var size = CGSize.zero
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        content(pressed, keyFocused)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in pressed = enabled && CGRect(origin: .zero, size: size).contains(v.location) }
                .onEnded { v in
                    let inside = CGRect(origin: .zero, size: size).contains(v.location)
                    pressed = false
                    if inside && enabled { trigger() }
                })
            .tabStop(focused: $keyFocused) { if enabled { trigger() } }
    }
}
#endif

/// Windows' keyboard focus for a control the Mac would skip (SYS-007): with macOS's Keyboard navigation off (the
/// default), SwiftUI buttons are no Tab stops and clicking doesn't focus them. This makes the control a Tab stop, gives
/// it the focus when clicked, and lets Space or Return press it, as a WPF Button / CheckBox / RadioButton. With Keyboard
/// navigation on, the control keeps macOS's own focus (Tab stop, Space), but a control that is no Tab stop (`isStop:
/// false`, a ListBox entry that isn't chosen) leaves the Tab order as on Windows, and `claim` still moves the focus to it.
/// `focused` mirrors the focus for the control's look.
private struct TabStop: ViewModifier {
    var isStop: Bool
    /// Take the focus now (a ListBox entry the arrow keys just chose).
    var claim = false
    @Binding var focused: Bool
    var action: () -> Void
    #if os(macOS)
    @FocusState private var own: Bool
    @Environment(\.isEnabled) private var enabled
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        if !isStop {
            // Out of the Tab order whichever way macOS's Keyboard navigation is set (with it on, a Button is a stop).
            content.modifier(NotAStop())
                .onAppear { focused = false }
        } else if NSApp?.isFullKeyboardAccessEnabled == true {
            content
                .focused($own)
                .onChange(of: own) { _, now in focused = now }
                .onAppear { if claim { own = true } }
                .onChange(of: claim) { _, now in if now { own = true } }
        } else {
            content
                .focusable(enabled)
                .focused($own)
                .onChange(of: own) { _, now in focused = now }
                .onKeyPress(keys: [.space, .return]) { _ in
                    guard enabled else { return .ignored }
                    action()
                    return .handled
                }
                .simultaneousGesture(TapGesture().onEnded { if enabled { own = true } })
                .onAppear { if claim { own = true } }
                .onChange(of: claim) { _, now in if now { own = true } }
        }
        #else
        content
        #endif
    }
}

#if os(macOS)
/// With Keyboard navigation on, macOS makes every button a Tab stop: this one isn't (a ListBox entry that isn't chosen).
private struct NotAStop: ViewModifier {
    func body(content: Content) -> some View {
        if NSApp?.isFullKeyboardAccessEnabled == true { content.focusable(false) } else { content }
    }
}
#endif

/// `tabStop` for a bare button with no focus look of its own: an accent outline around it while it has the focus.
private struct KeyTabStop: ViewModifier {
    var radius: CGFloat
    var action: () -> Void
    @State private var focused = false
    @Environment(\.ob) private var ob

    func body(content: Content) -> some View {
        content
            .tabStop(focused: $focused, action: action)
            .overlay { if focused { RoundedRectangle(cornerRadius: radius).strokeBorder(ob.accent, lineWidth: 1).padding(-2).allowsHitTesting(false) } }
    }
}

extension View {
    /// A bare button as a WPF Tab stop (see `TabStop`), outlined in the accent while focused.
    func keyTabStop(radius: CGFloat = 4, action: @escaping () -> Void) -> some View {
        modifier(KeyTabStop(radius: radius, action: action))
    }

    /// A Tab stop with WPF's keyboard behaviour; see `TabStop`. `isStop: false` leaves it out of the Tab order.
    func tabStop(_ isStop: Bool = true, claim: Bool = false, focused: Binding<Bool>, action: @escaping () -> Void) -> some View {
        modifier(TabStop(isStop: isStop, claim: claim, focused: focused, action: action))
    }
}

extension View {
    /// The pointing hand over something clickable (Windows sets Cursor="Hand" on every styled control).
    func handCursor(_ on: Bool = true) -> some View {
        #if os(macOS)
        pointerStyle(on ? .link : nil)
        #else
        self
        #endif
    }
}

/// A key on the keyboard, as a chip: CTRL + D.
struct KeyChips: View {
    var hotkey: String
    var size: CGFloat = 12
    @Environment(\.ob) private var ob

    var body: some View {
        // DashboardPage.SignalPath's chips: corner radius 9, padding 8,1, and a "+" readout 4 either side.
        // Never wrapped: the chips keep one line at their own width (F7).
        HStack(spacing: 0) {
            ForEach(Array(hotkey.split(separator: "+").enumerated()), id: \.offset) { i, part in
                if i > 0 { Readout("+").padding(.horizontal, 4) }
                Text(part.trimmingCharacters(in: .whitespaces).uppercased())
                    .font(Ob.mono(size))
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 8 + Ob.border).padding(.vertical, 1 + Ob.border)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ob.ink, lineWidth: Ob.border))
            }
        }
    }
}

// MARK: - Switch

/// A switch, label on the left, the whole row clickable (App.xaml's Switch): off, a muted outline with a hollow knob
/// (the outline turns ink under the pointer); on, filled ink. An accent outline while it has the keyboard focus.
struct ObSwitch: View {
    var title: String
    var detail: String?
    /// The title's weight (Cloud's "Keep everything offline" is SemiBold).
    var titleWeight: Font.Weight = .regular
    /// The detail is a Caption on the Windows page (Speech's quiet-speech switch): every line 19 tall.
    var detailIsCaption = false
    @Binding var isOn: Bool
    @Environment(\.ob) private var ob
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    @FocusState private var focused
    @State private var keyFocused = false

    init(_ title: String, detail: String? = nil, titleWeight: Font.Weight = .regular, detailIsCaption: Bool = false, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.titleWeight = titleWeight
        self.detailIsCaption = detailIsCaption
        _isOn = isOn
    }

    var body: some View {
        Button { isOn.toggle() } label: { // the knob jumps, as the template has no animation
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Ob.sans(Ob.body, titleWeight)).fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail).font(Ob.sans(12)).foregroundStyle(ob.muted)
                            .wpfLineHeight(detailIsCaption ? 19 : 0, size: 12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? ob.ink : .clear)
                    // The Switch template's triggers in order: hover (Ob.Border), keyboard focus (accent), then IsChecked
                    // (Ob.Strong), which wins: a switch that is on keeps its ink line even with the focus.
                    Capsule().strokeBorder(isOn ? ob.ink : focused || keyFocused ? ob.accent : hover ? ob.ink : ob.muted, lineWidth: 1)
                    Group {
                        if isOn { Circle().fill(ob.onInk) } else { Circle().strokeBorder(ob.muted, lineWidth: 1) }
                    }
                    .frame(width: 12, height: 12).padding(.horizontal, 4 + Ob.border) // Margin 4,0 inside the track's line
                }
                .frame(width: 42, height: 22)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .tabStop(focused: $keyFocused) { isOn.toggle() }
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover = $0 }
        .handCursor(enabled)
        .accessibilityRepresentation { Toggle(title, isOn: $isOn) }
    }
}

// MARK: - Meters

/// A meter: a ring of 32 dots from the top, clockwise, lit to the fraction (lit ones filled, the rest small and
/// hollow), the number in the middle, the label under it. Drawn at a fixed design size and scaled to its cell.
struct RingMeter: View {
    var fraction: Double
    var value: String
    var label: String
    var sub: String
    var accent = false
    /// The number is its own button (underlined); the rest of the meter still opens its page.
    var valueAction: (() -> Void)? = nil
    var valueTip: String? = nil
    @Environment(\.ob) private var ob
    @State private var valueHover = false

    var body: some View {
        DesignSize(width: 150, height: 150) {
            ZStack(alignment: .top) {
                Canvas { ctx, _ in
                    // Math.Round: a half goes to the even count, as Windows rounds it.
                    let n = 32, lit = Int(Fmt.banker(min(max(fraction, 0), 1) * Double(n)))
                    for i in 0..<n {
                        let a = -Double.pi / 2 + Double(i) * 2 * .pi / Double(n)
                        let on = i < lit, d = on ? 6.0 : 3.6
                        let rect = CGRect(x: 75 + 52 * cos(a) - d / 2, y: 64 + 52 * sin(a) - d / 2, width: d, height: d)
                        if on { ctx.fill(Path(ellipseIn: rect), with: .color(accent ? ob.accent : ob.ink)) }
                        // WPF keeps an Ellipse's stroke inside its 3.6 box.
                        else { ctx.stroke(Path(ellipseIn: rect.insetBy(dx: 0.45, dy: 0.45)), with: .color(ob.muted), lineWidth: 0.9) }
                    }
                }
                VStack(spacing: 2) {
                    if let valueAction {
                        // Only the number itself is the button (a centred TextBlock), not the room beside it.
                        Text(value).font(Ob.mono(21, .bold)).underline().foregroundStyle(accent || valueHover ? ob.accent : ob.ink).lineLimit(1)
                            .fixedSize()
                            .contentShape(Rectangle())
                            .onHover { valueHover = $0 }
                            .onTapGesture { valueAction() }
                            .help(valueTip ?? "")
                            .frame(minWidth: 0, maxWidth: 150).clipped()
                    } else {
                        // Full size, centred; a number wider than the 150 canvas is cut by it (never shrunk).
                        Text(value).font(Ob.mono(21, .bold)).foregroundStyle(accent ? ob.accent : ob.ink).lineLimit(1)
                            .fixedSize()
                            .frame(minWidth: 0, maxWidth: 150).clipped()
                    }
                    Readout(label, size: 8.5)
                }
                .padding(.top, 46)
                Text(sub).font(Ob.sans(10)).foregroundStyle(ob.muted).lineLimit(1)
                    .frame(maxWidth: 144, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 2)
            }
        }
        .help("\(label): \(value) (\(sub))") // DashboardPage's dial tooltip
    }
}

/// The turnaround gauge: a half fan of ticks and a needle, the value under the hub and the label at the bottom.
struct FanMeter: View {
    var fraction: Double
    var value: String
    var label: String
    var sub = ""
    @Environment(\.ob) private var ob

    var body: some View {
        DesignSize(width: 150, height: 150) {
            ZStack(alignment: .top) {
                Canvas { ctx, _ in
                    let cx = 75.0, cy = 92.0, n = 19
                    for i in 0..<n {
                        let a = Double.pi + Double(i) * .pi / Double(n - 1), major = i % 3 == 0
                        var p = Path()
                        p.move(to: CGPoint(x: cx + 36 * cos(a), y: cy + 36 * sin(a)))
                        p.addLine(to: CGPoint(x: cx + (major ? 58 : 50) * cos(a), y: cy + (major ? 58 : 50) * sin(a)))
                        ctx.stroke(p, with: .color(ob.ink), lineWidth: major ? 1.4 : 0.8)
                    }
                    let na = Double.pi + min(max(fraction, 0), 1) * .pi
                    var needle = Path()
                    needle.move(to: CGPoint(x: cx, y: cy))
                    needle.addLine(to: CGPoint(x: cx + 62 * cos(na), y: cy + 62 * sin(na)))
                    ctx.stroke(needle, with: .color(ob.ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - 4, y: cy - 4, width: 8, height: 8)), with: .color(ob.ink))
                }
                Text(value).font(Ob.mono(21, .bold)).padding(.top, 98)
                // Only the label on the face; the sub line is in the tooltip (DashboardPage.Dial with fan).
                Readout(label, size: 8.5).lineLimit(1).frame(maxWidth: 144, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 2)
            }
        }
        .help(sub.isEmpty ? "\(label): \(value)" : "\(label): \(value) (\(sub))")
    }
}

/// Lays its content out at a fixed design size and scales it uniformly to fit the space offered (WPF's Viewbox).
struct DesignSize<Content: View>: View {
    var width: CGFloat
    var height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / width, geo.size.height / height)
            content
                .frame(width: width, height: height)
                .scaleEffect(scale)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// A status dot: ready = filled ink (Ob.Ok), busy = filled accent (Ob.Busy), off = a hollow ring. Still, as on Windows.
enum DotState { case ok, busy, off }

struct StatusDot: View {
    var state: DotState
    var size: CGFloat = 7
    @Environment(\.ob) private var ob

    var body: some View {
        Group {
            switch state {
            case .ok: Circle().fill(ob.ink)
            case .busy: Circle().fill(ob.accent)
            case .off: Circle().strokeBorder(ob.muted, lineWidth: 1)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Shared bits

enum Clipboard {
    /// False when the pasteboard wouldn't take the text.
    @discardableResult
    static func copy(_ s: String) -> Bool {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        return true
        #endif
    }
}

/// COPY that flashes what happened for 1.5 s: COPIED ✓, NOTHING YET, or BUSY, TRY AGAIN (DashboardPage.CopyShown).
struct CopyButton: View {
    var text: String
    var small = true
    @State private var flash: String?

    var body: some View {
        Button(flash ?? "Copy") {
            let label = text.isEmpty ? "Nothing yet" : Clipboard.copy(text) ? "Copied ✓" : "Busy, try again"
            flash = label
            Task { try? await Task.sleep(for: .seconds(1.5)); if flash == label { flash = nil } }
        }
        .buttonStyle(small ? .quietSmall : .quiet)
        .help("Copy the text shown")
    }
}

/// A page's scrolling area. (The debug snapshots lay pages out flat, since the image renderer can't draw scroll views.)
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    static var flat: Bool { ProcessInfo.processInfo.environment["OBERTON_SNAPSHOT"] != nil }

    var body: some View {
        if Self.flat { content.fixedSize(horizontal: false, vertical: true).frame(maxHeight: .infinity, alignment: .top) } else { ScrollView { content } }
    }
}
