import ObertonCore
import SwiftUI

/// A text field drawn as on Windows: a hairline box, square, the text in the sans (or mono).
struct ObField: View {
    var placeholder: String
    @Binding var text: String
    var mono = false
    var secure = false
    var width: CGFloat?
    @Environment(\.ob) private var ob
    @FocusState private var focused: Bool

    init(_ placeholder: String, text: Binding<String>, mono: Bool = false, secure: Bool = false, width: CGFloat? = nil) {
        self.placeholder = placeholder
        _text = text
        self.mono = mono
        self.secure = secure
        self.width = width
    }

    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain)
        .font(mono ? Ob.mono(12.5) : Ob.sans(Ob.body))
        .focused($focused)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: width ?? .infinity, alignment: .leading)
        .overlay(Rectangle().strokeBorder(focused ? ob.accent : ob.divider, lineWidth: 1))
    }
}

/// A dropdown drawn as a hairline box with a chevron (an accent border while it has the keyboard focus).
struct ObMenu<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value
    var width: CGFloat?
    @Environment(\.ob) private var ob
    @FocusState private var focused

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    if value == selection { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            HStack {
                Text(options.first { $0.0 == selection }?.1 ?? "—").font(Ob.sans(Ob.body)).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(ob.muted)
            }
            .foregroundStyle(ob.ink)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: width ?? .infinity)
            .overlay(Rectangle().strokeBorder(focused ? ob.accent : ob.divider, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .focused($focused)
        .handCursor()
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: width == nil ? false : true, vertical: true)
    }
}

/// A hairline-boxed group of switch rows with hairlines between them (the Windows "Card" around switches, each
/// switch with Margin 18,4).
struct SwitchCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.ob) private var ob

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Hairline() }
                    row
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
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
            .padding(.horizontal, 9).padding(.vertical, 2) // App.xaml's Chip
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
                .padding(10)
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
/// 4 in from the frame, each pill centred in its cell).
struct PositionPicker: View {
    @Binding var position: OverlayPosition
    var radius: CGFloat = 2
    @Environment(\.ob) private var ob

    var body: some View {
        let all = OverlayPosition.allCases
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { col in
                        PositionCell(place: all[row * 3 + col], position: $position)
                    }
                }
            }
        }
        .padding(4)
        .frame(width: 220, height: 124)
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(ob.ink, lineWidth: 1))
    }
}

/// One spot (App.xaml's PositionCell): a 34×10 pill, outlined muted, ink under the pointer, filled ink when chosen;
/// 40 wide with an accent outline while it has the keyboard focus. The tooltip names the spot.
private struct PositionCell: View {
    var place: OverlayPosition
    @Binding var position: OverlayPosition
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
        .help(place.title)
        .accessibilityLabel(place.title)
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
    @Environment(\.ob) private var ob

    var body: some View {
        Text(attributed).font(Ob.sans(size)).lineSpacing(size * 0.5)
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
    var safetyNet = false
    var transcriptionEditor: Binding<String>? = nil
    /// Draw the hairline box around the three (off when a card around them already does).
    var boxed = true
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let layout = sizeClass == .compact ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        layout {
            column("01 // Transcription", copy: transcription) {
                if let transcriptionEditor {
                    TextEditor(text: transcriptionEditor)
                        .font(Ob.mono(13)).scrollContentBackground(.hidden).frame(minHeight: 72)
                } else {
                    Text(transcription).font(Ob.sans(14)).lineSpacing(6)
                }
            }
            separator
            column("02 // AI Edit", copy: aiEdit ?? "", meta: editMeta) {
                if let aiEdit, !aiEdit.isEmpty {
                    if safetyNet {
                        Text("The safety net rejected the AI's edit, so your words went in as spoken.").font(Ob.sans(14)).foregroundStyle(ob.muted)
                    } else {
                        DiffText(original: transcription, edited: aiEdit, size: 14)
                    }
                } else {
                    Text(editPlaceholder).font(Ob.sans(14)).foregroundStyle(ob.muted)
                }
            }
            separator
            column("03 // Inserted", copy: inserted) {
                Text(inserted).font(Ob.sans(14)).lineSpacing(6)
            }
        }
        .overlay(Rectangle().strokeBorder(boxed ? ob.divider : .clear, lineWidth: 1))
    }

    @ViewBuilder private var separator: some View {
        Hairline(vertical: sizeClass != .compact)
    }

    private func column<C: View>(_ title: String, copy: String, meta: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Readout(title)
                if let meta { Readout(meta, size: 10) }
                Spacer()
                TextCopyButton(text: copy)
            }
            content().textSelection(.enabled)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
    }
}

/// A bare COPY in the readout face, as at the top of each of the three boxes.
struct TextCopyButton: View {
    var text: String
    var onDark = false
    @State private var label = "COPY"
    @Environment(\.ob) private var ob

    var body: some View {
        Button {
            if text.isEmpty { label = "NOTHING YET" } else { Clipboard.copy(text); label = "COPIED ✓" }
            Task { try? await Task.sleep(for: .seconds(1.2)); label = "COPY" }
        } label: {
            Text(label).font(Ob.mono(10.5)).foregroundStyle(onDark ? Color(hex: 0xE8E7E3) : ob.muted)
        }
        .buttonStyle(.plain)
    }
}

/// A slider with its value as a mono readout, drawn in ink.
struct ObSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double?
    var format: (Double) -> String
    var width: CGFloat = 300

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let step { Slider(value: $value, in: range, step: step) } else { Slider(value: $value, in: range) }
            }
            .frame(width: width)
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
