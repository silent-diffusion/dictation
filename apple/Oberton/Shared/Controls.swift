import ObertonCore
import SwiftUI

/// A text box as WPF's Fluent theme draws the Windows app's TextBox and PasswordBox (SYS-008): 14 pt, a faint fill with
/// 4-pt corners and a hairline edge, a darker bottom line that turns into the 2-pt accent line while typing, at least 32
/// tall, Padding 10,5,6,6 inside the 1 px edge (CloudPage's PasswordBox sets 6,5).
struct ObField: View {
    var placeholder: String
    @Binding var text: String
    var mono = false
    var secure = false
    var width: CGFloat?
    var padding = ObField.fluentPadding
    @FocusState private var focused: Bool

    /// Fluent's TextControlThemePadding.
    static let fluentPadding = EdgeInsets(top: 5, leading: 10, bottom: 6, trailing: 6)

    init(_ placeholder: String, text: Binding<String>, mono: Bool = false, secure: Bool = false, width: CGFloat? = nil,
         padding: EdgeInsets = ObField.fluentPadding) {
        self.placeholder = placeholder
        _text = text
        self.mono = mono
        self.secure = secure
        self.width = width
        self.padding = padding
    }

    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain)
        .font(mono ? Ob.mono(14) : Ob.sans(14))
        .focused($focused)
        .fluentBox(focused: focused, padding: padding, width: width)
    }
}

extension View {
    /// The Fluent text box around a field: Padding inside the 1 px edge, at least 32 tall, `width` its own (WPF Width).
    func fluentBox(focused: Bool, padding: EdgeInsets = ObField.fluentPadding, width: CGFloat? = nil) -> some View {
        self.padding(EdgeInsets(top: padding.top + Ob.border, leading: padding.leading + Ob.border,
                                bottom: padding.bottom + Ob.border, trailing: padding.trailing + Ob.border))
            .frame(minHeight: 32)
            .frame(width: width)
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .modifier(FluentField(focused: focused))
    }
}

/// Windows' MessageBoxImage for an alert: its icon in the dialog, and the system sound Windows plays with it
/// (Question has none by default; Warning, Error and Information sound).
enum DialogKind {
    case question, warning, error, information

    var symbol: String {
        switch self {
        case .question: "questionmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .information: "info.circle.fill"
        }
    }

    /// The alert sound, played as the dialog opens.
    func sound() {
        #if os(macOS)
        if self != .question { NSSound.beep() }
        #endif
    }
}

extension View {
    /// Gives the alerts in this view Windows' MessageBox icon, and its sound when `shown` turns true (SYS-015).
    func dialogLook(_ kind: DialogKind, shown: Bool) -> some View {
        self.dialogIcon(Image(systemName: kind.symbol))
            .onChange(of: shown) { _, now in if now { kind.sound() } }
    }
}

/// A dropdown as WPF's Fluent theme draws the Windows app's ComboBox (App.xaml doesn't restyle it): 14 pt, a faint fill
/// with 4-pt corners, a hairline edge a little darker along the bottom, a lighter fill under the pointer, Padding
/// 12,5,0,7 inside the 1 px edge, the chevron 10 from the right, at least 32 tall; the focus ring while it has the
/// keyboard focus.
struct ObMenu<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value
    var width: CGFloat?
    @Environment(\.ob) private var ob
    @FocusState private var focused
    @State private var hover = false

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    if value == selection { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            HStack(spacing: 0) {
                Text(options.first { $0.0 == selection }?.1 ?? "—").font(Ob.sans(14)).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .regular)).foregroundStyle(ob.ink.opacity(0.62))
                    .padding(.trailing, 10)
            }
            .foregroundStyle(ob.ink)
            .padding(EdgeInsets(top: 5 + Ob.border, leading: 12 + Ob.border, bottom: 7 + Ob.border, trailing: Ob.border))
            .frame(minHeight: 32)
            // A given width is the combo's own (WPF ComboBox Width), not just a cap.
            .frame(minWidth: width, maxWidth: width ?? .infinity)
            .background { FluentComboFace(hover: hover, focused: focused) }
            .contentShape(Rectangle())
        }
        .onHover { hover = $0 }
        .focused($focused)
        .handCursor()
        .accessibilityValue(options.first { $0.0 == selection }?.1 ?? "") // a label set on the menu still reads its choice
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: width == nil ? false : true, vertical: true)
    }
}

/// The Fluent ComboBox's face: ControlFillColorDefault (Secondary under the pointer), ControlElevationBorder (the bottom
/// a shade darker), corner radius 4, and the 2 pt focus ring outside it while it has the keyboard focus.
private struct FluentComboFace: View {
    var hover: Bool
    var focused: Bool
    @Environment(\.ob) private var ob

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        ZStack(alignment: .bottom) {
            if ob.dark {
                shape.fill(Color.white.opacity(hover ? 0.08 : 0.06))
            } else {
                shape.fill(Color.white.opacity(hover ? 0.5 : 0.7))
            }
            shape.strokeBorder(ob.dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06), lineWidth: 1)
            Rectangle().fill(ob.dark ? Color.white.opacity(0.09) : Color.black.opacity(0.16)).frame(height: 1)
        }
        .clipShape(shape)
        .overlay { if focused { RoundedRectangle(cornerRadius: 6).strokeBorder(ob.ink, lineWidth: 2).padding(-3) } }
    }
}

/// A hairline-boxed group of switch rows with hairlines between them (the Windows "Card" around switches). A single
/// switch has Margin 18,4; several share a StackPanel with Margin 18,0. Both inside the card's 1 px line.
struct SwitchCard<Content: View>: View {
    var horizontal: CGFloat = 18
    @ViewBuilder var content: Content
    @Environment(\.ob) private var ob

    var body: some View {
        Group(subviews: content) { rows in
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Hairline() }
                    row
                }
            }
            .padding(.horizontal, horizontal + Ob.border)
            .padding(.vertical, (rows.count > 1 ? 0 : 4) + Ob.border)
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: Ob.border))
        }
    }
}

/// A badge beside a model's name: ACTIVE (filled ink), CLOUD (accent), and quieter states.
struct Badge: View {
    enum Kind { case active, ok, cloud, plain, outline }
    var text: String
    var kind: Kind
    @Environment(\.ob) private var ob

    var body: some View {
        Text(text.uppercased())
            .font(Ob.mono(10))
            .foregroundStyle(kind == .active ? ob.onInk : kind == .cloud ? ob.accent : kind == .outline ? ob.muted : ob.ink)
            // ModelsPage.Badge: CornerRadius 9, Padding 8,1, inside a 1 px line (text + 18 by text + 4).
            .padding(.horizontal, 8 + Ob.border).padding(.vertical, 1 + Ob.border)
            .background(Capsule().fill(kind == .active ? ob.ink : kind == .plain ? ob.subtle : .clear))
            .overlay(Capsule().strokeBorder(kind == .cloud ? ob.accent : kind == .plain ? ob.divider : ob.ink, lineWidth: 1))
    }
}

/// A large selectable card: a hairline box with a small dot in the corner, filled ink (and an ink border) when chosen.
struct ChoiceCard<Content: View>: View {
    var chosen: Bool
    var action: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.ob) private var ob
    @State private var hover = false
    @FocusState private var focused

    var body: some View {
        Button(action: action) {
            content
                .padding(10 + Ob.border) // Padding 10 inside the 1 px line
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hover ? ob.subtle : .clear)
                .overlay(Rectangle().strokeBorder(chosen ? ob.ink : focused ? ob.accent : ob.divider, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    Group {
                        if chosen { Circle().fill(ob.ink) } else { Circle().strokeBorder(ob.muted, lineWidth: 1) }
                    }
                    .frame(width: 8, height: 8).padding(8)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hover = $0 }
        .handCursor()
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Nine spots on a miniature screen, for where the overlay or player appears (LayoutPage's UniformGrid of PositionCells,
/// Margin 4 inside the frame's 1 px line, each pill centred in its cell).
struct PositionPicker: View {
    @Binding var position: OverlayPosition
    /// The grid's accessible name ("Overlay position", "Read aloud player position").
    var name: String = "Position"
    /// Each spot's tooltip and name: LayoutPage's overlay grid says "Center"; the player grids use Describe ("Center
    /// of the screen").
    var describe: (OverlayPosition) -> String = { $0.title }
    var radius: CGFloat = 2
    /// The frame's line and ground: ink and none by default; the Read aloud page's is a rounded Border on Window.
    var stroke: Color? = nil
    var fill: Color? = nil
    @Environment(\.ob) private var ob

    var body: some View {
        let all = OverlayPosition.allCases
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { col in
                        PositionCell(place: all[row * 3 + col], position: $position, name: describe(all[row * 3 + col]))
                    }
                }
            }
        }
        .padding(4 + Ob.border)
        .frame(width: 220, height: 124)
        .background(RoundedRectangle(cornerRadius: radius).fill(fill ?? .clear))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(stroke ?? ob.ink, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }
}

/// One spot (App.xaml's PositionCell): a 34×10 pill, outlined muted, ink under the pointer, filled ink when chosen;
/// 40 wide with an accent outline while it has the keyboard focus. The tooltip names the spot.
private struct PositionCell: View {
    var place: OverlayPosition
    @Binding var position: OverlayPosition
    var name: String
    @Environment(\.ob) private var ob
    @State private var hover = false
    @FocusState private var focused

    var body: some View {
        let chosen = place == position
        Button { position = place } label: {
            Capsule().fill(chosen ? ob.ink : .clear)
                .overlay(Capsule().strokeBorder(focused ? ob.accent : chosen || hover ? ob.ink : ob.muted, lineWidth: 1))
                .frame(width: focused ? 40 : 34, height: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hover = $0 }
        .handCursor()
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

extension OverlayPosition {
    var title: String {
        switch self {
        case .topLeft: "Top left"
        case .topCenter: "Top center"
        case .topRight: "Top right"
        case .middleLeft: "Middle left"
        case .center: "Center"
        case .middleRight: "Middle right"
        case .bottomLeft: "Bottom left"
        case .bottomCenter: "Bottom center"
        case .bottomRight: "Bottom right"
        }
    }
}

/// The AI's edit drawn against what was heard: removed words struck through (muted), added words in the accent.
struct DiffText: View {
    var original: String
    var edited: String
    var size: CGFloat = 15
    var onDark = false
    /// The space between lines; half the size unless given (History's boxes: a WPF LineHeight of 21).
    var lineSpacing: CGFloat?
    @Environment(\.ob) private var ob

    var body: some View {
        Text(attributed).font(Ob.sans(size)).lineSpacing(lineSpacing ?? size * 0.5)
    }

    private var attributed: AttributedString {
        let added = onDark ? Color(hex: ob.accentChoice.hex.dark) : ob.accent
        let removed = onDark ? Color(hex: 0xE8E7E3, alpha: 0.45) : ob.muted
        var out = AttributedString()
        let same = onDark ? Color(hex: 0xE8E7E3) : ob.ink
        for (i, token) in WordDiff.compute(original, edited).enumerated() {
            if i > 0 { out += AttributedString(" ") }
            var word = AttributedString(token.word)
            switch token.kind {
            case .same: word.foregroundColor = same
            case .removed:
                word.strikethroughStyle = .single
                word.foregroundColor = removed
            case .added:
                word.foregroundColor = added
            }
            out += word
        }
        return out
    }
}

/// 01 // TRANSCRIPTION, 02 // AI EDIT, 03 // INSERTED: three columns split by hairlines in a hairline box (History, Try
/// it). On a narrow screen they stack.
struct ThreeBoxes: View {
    var transcription: String
    var aiEdit: String?
    var inserted: String
    var editMeta: String?
    var editPlaceholder = "No AI edit for this dictation."
    /// With no AI edit: the safety net rejected it (says so instead of the placeholder).
    var safetyNet = false
    var transcriptionEditor: Binding<String>? = nil
    /// Draw the hairline box around the three (off when a card around them already does).
    var boxed = true
    /// The word being said while the recording plays, lit in the accent (UTF-16 ranges in the transcription and in
    /// what went in; nil: none).
    var transcriptionLit: NSRange? = nil
    var insertedLit: NSRange? = nil
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// HistoryPage's boxes: 14 pt text, lines 21 apart.
    private static let size: CGFloat = 14
    private static let spacing = Ob.lineSpacing(14, lineHeight: 21)

    var body: some View {
        let layout = sizeClass == .compact ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        layout {
            column("01 // Transcription", copy: transcription, copyName: "Copy Transcription", copyHelp: "Copy what you said") {
                if let transcriptionEditor {
                    TextEditor(text: transcriptionEditor)
                        .font(Ob.mono(13)).scrollContentBackground(.hidden).frame(minHeight: 72)
                } else {
                    box(Text(lit(transcription, transcriptionLit)))
                }
            }
            separator
            // AI EDIT's COPY copies the AI's own output, and can't be used when there is none (HistoryPage: 35 %).
            column("02 // AI Edit", copy: aiEdit ?? "", copyName: "Copy AI Edit",
                   copyHelp: "Copy the AI's own output, before it was fitted into the surrounding text",
                   copyEnabled: !(aiEdit ?? "").isEmpty, meta: editMeta) {
                if let aiEdit {
                    DiffText(original: transcription, edited: aiEdit, size: Self.size, lineSpacing: Self.spacing).padding(.bottom, Self.spacing)
                } else {
                    box(Text(safetyNet ? "The safety net rejected the AI's edit, so your words went in as spoken." : editPlaceholder), muted: true)
                }
            }
            separator
            column("03 // Inserted", copy: inserted, copyName: "Copy Inserted", copyHelp: "Copy the text that went in") {
                box(Text(lit(inserted, insertedLit)))
            }
        }
        .overlay(Rectangle().strokeBorder(boxed ? ob.divider : .clear, lineWidth: 1))
    }

    /// LineHeight 21: every line 21 tall, the last included.
    private func box(_ text: Text, muted: Bool = false) -> some View {
        text.font(Ob.sans(Self.size)).foregroundStyle(muted ? ob.muted : ob.ink).wpfLineHeight(21, size: Self.size).fixedSize(horizontal: false, vertical: true)
    }

    /// The text with `range` in the accent (only the colour, so nothing moves).
    private func lit(_ text: String, _ range: NSRange?) -> AttributedString {
        var a = AttributedString(text)
        if let range, let r = Range(range, in: text), let lo = AttributedString.Index(r.lowerBound, within: a),
           let hi = AttributedString.Index(r.upperBound, within: a) {
            a[lo..<hi].foregroundColor = ob.accent
        }
        return a
    }

    @ViewBuilder private var separator: some View {
        Hairline(vertical: sizeClass != .compact)
    }

    /// One box: its name and COPY on one line (6 above the text), then the text (Margin 14,12,14,14).
    private func column<C: View>(_ title: String, copy: String, copyName: String, copyHelp: String, copyEnabled: Bool = true,
                                 meta: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Readout(title).noWrap() // cut at the column, no "…"
                if let meta { Readout(meta, size: 10).lineLimit(1).padding(.leading, 8) }
                Spacer(minLength: 0)
                TextCopyButton(text: copy, enabled: copyEnabled).padding(.leading, 10).help(copyHelp).accessibilityLabel(copyName)
            }
            content()
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A bare COPY in the readout face, as at the top of each of the three boxes: flashes COPIED ✓ or NOTHING YET for 1.5 s;
/// dimmed to 35 % when there is nothing it could copy.
struct TextCopyButton: View {
    var text: String
    var onDark = false
    var enabled = true
    @State private var label = "COPY"
    @Environment(\.ob) private var ob

    var body: some View {
        Button {
            let shown = text.isEmpty ? "NOTHING YET" : Clipboard.copy(text) ? "COPIED ✓" : "BUSY, TRY AGAIN"
            label = shown
            // Each click starts its own 1.5 s timer and none is stopped, so an earlier click's timer puts COPY back.
            Task { try? await Task.sleep(for: .seconds(1.5)); label = "COPY" }
        } label: {
            Text(label).font(Ob.mono(10.5)).foregroundStyle(onDark ? Color(hex: 0xE8E7E3) : ob.muted)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .handCursor(enabled)
    }
}

/// A slider as WPF's Fluent theme draws it with the app's ink accent (LOOK-N007): a 4-pt track, filled in ink up to the
/// thumb; the thumb a 20-pt disc (white, or #454545 on dark paper) with a hairline edge and an ink dot in the middle,
/// 12 across (14 under the pointer, 10 while dragged). Click or drag anywhere on it; ←/→ step it.
struct FluentSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    /// Snaps what is set (Windows' TickFrequency with IsSnapToTickEnabled), without drawing ticks.
    var step: Double? = nil
    @Environment(\.ob) private var ob
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    @State private var dragging = false

    private static let thumb: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width - Self.thumb)
            let f = range.upperBound > range.lowerBound ? (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound) : 0
            let x = Self.thumb / 2 + w * f
            ZStack(alignment: .leading) {
                Capsule().fill(ob.dark ? Color.white.opacity(0.55) : Color.black.opacity(0.45)).frame(height: 4)
                    .padding(.horizontal, Self.thumb / 2)
                Capsule().fill(ob.ink).frame(width: max(0, x - Self.thumb / 2), height: 4).padding(.leading, Self.thumb / 2)
                Circle().fill(ob.dark ? Color(hex: 0x454545) : .white)
                    .overlay(Circle().strokeBorder(ob.dark ? Color.white.opacity(0.09) : Color.black.opacity(0.12), lineWidth: 1))
                    .overlay(Circle().fill(ob.ink).frame(width: dragging ? 10 : hover ? 14 : 12, height: dragging ? 10 : hover ? 14 : 12))
                    .frame(width: Self.thumb, height: Self.thumb)
                    .offset(x: x - Self.thumb / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    dragging = true
                    set(range.lowerBound + Double(min(max(0, g.location.x - Self.thumb / 2), w) / w) * (range.upperBound - range.lowerBound))
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: 32)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hover = $0 }
        .accessibilityRepresentation { Slider(value: $value, in: range) }
        #if os(macOS)
        .focusable()
        .onMoveCommand { d in
            let small = step ?? (range.upperBound - range.lowerBound) / 100
            if d == .left || d == .down { set(value - small) } else if d == .right || d == .up { set(value + small) }
        }
        #endif
    }

    private func set(_ v: Double) {
        var v = min(max(v, range.lowerBound), range.upperBound)
        if let step { v = min(max(range.lowerBound + ((v - range.lowerBound) / step).rounded() * step, range.lowerBound), range.upperBound) }
        value = v
    }
}

/// A slider with its value as a mono readout, drawn in ink.
struct ObSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double?
    var format: (Double) -> String
    var width: CGFloat = 300
    /// The slider's accessible name (AutomationProperties.Name); the readout beside it keeps its own text.
    var name: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            FluentSlider(value: $value, range: range, step: step)
            .frame(width: width)
            .accessibilityLabel(name ?? "")
            .accessibilityValue(format(value)) // the value itself ("1.75×"), not a percentage of the range
            Text(format(value)).font(Ob.mono(12)).monospacedDigit().frame(width: 60, alignment: .leading)
        }
    }
}

extension OverlayPosition {
    var alignment: Alignment {
        let all = OverlayPosition.allCases
        let i = all.firstIndex(of: self) ?? 7
        return Alignment(horizontal: [.leading, .center, .trailing][i % 3], vertical: [.top, .center, .bottom][i / 3])
    }
}
