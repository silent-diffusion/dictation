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

/// The type: a monospaced face for the interface (Cascadia Mono on Windows, SF Mono here), a sans for prose, and a
/// Japanese face for the decorative words.
enum Ob {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func jp(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Hiragino Sans", size: size).weight(weight) }
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
            .tint(palette.ink) // the system controls' own accent is ink, so that color stays a signal
            .foregroundStyle(palette.ink)
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

    // The shortcuts as tooltips and captions name them (Windows: Ctrl+0, Ctrl+B, Alt+Left).
    static let resetKey = "⌘0"
    static let menuKey = "⌘B"
    static let backKey = "⌘["
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
    @Environment(\.ob) private var ob

    init(_ text: String, size: CGFloat = 10.5, color: Color? = nil, weight: Font.Weight = .regular) {
        self.text = text
        self.size = size
        self.color = color
        self.weight = weight
    }

    var body: some View {
        Text(text.uppercased())
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
            HStack(alignment: .bottom, spacing: 14) {
                Text(title.uppercased()).font(Ob.mono(size, .bold)).lineLimit(1).minimumScaleFactor(0.5)
                if let japanese { Decor(japanese, size: size - 4, color: ob.divider, weight: .bold) }
                Spacer(minLength: 16)
                trailing.padding(.bottom, 4)
            }
            Rule().padding(.top, 6)
            if let summary {
                Text(summary).font(Ob.sans(13)).foregroundStyle(ob.muted).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
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
        Text(text.uppercased()).font(Ob.mono(12, .bold)).padding(.top, 20).padding(.bottom, 6)
    }
}

/// Helper prose under a control: sans, muted, wrapping.
struct Caption: View {
    var text: String
    var size: CGFloat = 13
    @Environment(\.ob) private var ob
    init(_ text: String, size: CGFloat = 13) { self.text = text; self.size = size }
    var body: some View {
        Text(text).font(Ob.sans(size)).foregroundStyle(ob.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
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
/// left edge, each cell its right and bottom edge. A cell that is a link gets the accent wash on hover.
struct Cell<Content: View>: View {
    var link = false
    var padding = EdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 16)
    @ViewBuilder var content: Content
    @State private var hover = false
    @Environment(\.ob) private var ob

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(link && hover ? ob.accentWash : .clear)
            .overlay(alignment: .trailing) { Hairline(vertical: true) }
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

/// A hairline box (the Windows "Card"): no fill, no shadow, square corners.
struct Box<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    @Environment(\.ob) private var ob

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
    }
}

// MARK: - Buttons

/// Capsules. Filled ink = the main action; ink outline = the others; dashed = something to add.
struct CapsuleButtonStyle: ButtonStyle {
    enum Kind { case primary, quiet, dashed }
    var kind: Kind = .quiet
    var size: CGFloat = 12
    var compact = false
    @Environment(\.ob) private var ob
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, kind: kind, size: size, compact: compact, ob: ob, enabled: enabled)
    }

    private struct Face: View {
        var configuration: Configuration
        var kind: Kind
        var size: CGFloat
        var compact: Bool
        var ob: Palette
        var enabled: Bool
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(Ob.mono(size, kind == .primary ? .semibold : .regular))
                .textCase(.uppercase)
                .lineLimit(1)
                .foregroundStyle(kind == .primary ? ob.onInk : kind == .dashed && !hover ? ob.muted : ob.ink)
                .padding(.horizontal, compact ? 12 : 16)
                .frame(minHeight: compact ? 26 : 34)
                .background {
                    switch kind {
                    case .primary: Capsule().fill(ob.ink)
                    case .quiet: Capsule().fill(hover ? ob.subtle : .clear)
                    case .dashed: Color.clear
                    }
                }
                .overlay {
                    switch kind {
                    case .primary: Capsule().strokeBorder(ob.ink, lineWidth: 1)
                    case .quiet: Capsule().strokeBorder(ob.ink, lineWidth: 1)
                    case .dashed: Capsule().strokeBorder(hover ? ob.ink : ob.muted, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .contentShape(Capsule())
                .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.66 : kind == .primary && hover ? 0.82 : 1)
                .onHover { hover = $0 }
        }
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static var primary: CapsuleButtonStyle { CapsuleButtonStyle(kind: .primary) }
    static var quiet: CapsuleButtonStyle { CapsuleButtonStyle(kind: .quiet) }
    static var dashed: CapsuleButtonStyle { CapsuleButtonStyle(kind: .dashed) }
    static var quietSmall: CapsuleButtonStyle { CapsuleButtonStyle(kind: .quiet, size: 10, compact: true) }
}

/// A key on the keyboard, as a chip: CTRL + D.
struct KeyChips: View {
    var hotkey: String
    var size: CGFloat = 12
    @Environment(\.ob) private var ob

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(hotkey.split(separator: "+").enumerated()), id: \.offset) { i, part in
                if i > 0 { Readout("+", size: size) }
                Text(part.trimmingCharacters(in: .whitespaces).uppercased())
                    .font(Ob.mono(size))
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(ob.ink, lineWidth: 1))
            }
        }
    }
}

// MARK: - Switch

/// A switch, label on the left, the whole row clickable: an ink outline when off, filled ink when on.
struct ObSwitch: View {
    var title: String
    var detail: String?
    @Binding var isOn: Bool
    @Environment(\.ob) private var ob
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Ob.sans(13.5))
                    if let detail { Text(detail).font(Ob.sans(12)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? ob.ink : .clear)
                    Capsule().strokeBorder(isOn ? ob.ink : hover ? ob.accent : ob.muted, lineWidth: 1)
                    Circle().fill(isOn ? ob.onInk : ob.muted).frame(width: 12, height: 12).padding(.horizontal, 4)
                }
                .frame(width: 42, height: 22)
            }
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover = $0 }
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
                    let n = 32, lit = Int((min(max(fraction, 0), 1) * Double(n)).rounded())
                    for i in 0..<n {
                        let a = -Double.pi / 2 + Double(i) * 2 * .pi / Double(n)
                        let on = i < lit, d = on ? 6.0 : 3.6
                        let rect = CGRect(x: 75 + 52 * cos(a) - d / 2, y: 64 + 52 * sin(a) - d / 2, width: d, height: d)
                        if on { ctx.fill(Path(ellipseIn: rect), with: .color(accent ? ob.accent : ob.ink)) }
                        else { ctx.stroke(Path(ellipseIn: rect), with: .color(ob.muted), lineWidth: 0.9) }
                    }
                }
                VStack(spacing: 2) {
                    if let valueAction {
                        Text(value).font(Ob.mono(21, .bold)).underline().foregroundStyle(accent || valueHover ? ob.accent : ob.ink).lineLimit(1)
                            .minimumScaleFactor(0.5).frame(maxWidth: 92)
                            .contentShape(Rectangle())
                            .onHover { valueHover = $0 }
                            .onTapGesture { valueAction() }
                            .help(valueTip ?? "")
                    } else {
                        Text(value).font(Ob.mono(21, .bold)).foregroundStyle(accent ? ob.accent : ob.ink).lineLimit(1).minimumScaleFactor(0.5)
                            .frame(maxWidth: 92)
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

/// The turnaround gauge: a half fan of ticks and a needle.
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
                VStack(spacing: 2) {
                    Readout(label, size: 8.5)
                    if !sub.isEmpty { Text(sub).font(Ob.sans(10)).foregroundStyle(ob.muted).lineLimit(1).truncationMode(.tail).frame(maxWidth: 144) }
                }
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 2)
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

/// A status dot: ready = filled ink, busy = the accent (pulsing), off = a hollow ring. The shape carries the state.
enum DotState { case ok, busy, off }

struct StatusDot: View {
    var state: DotState
    var size: CGFloat = 7
    @Environment(\.ob) private var ob
    @State private var pulse = false

    var body: some View {
        Group {
            switch state {
            case .ok: Circle().fill(ob.ink)
            case .busy: Circle().fill(ob.accent).opacity(pulse ? 0.25 : 1)
            case .off: Circle().strokeBorder(ob.muted, lineWidth: 1)
            }
        }
        .frame(width: size, height: size)
        .onAppear { if state == .busy { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { pulse = true } } }
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
