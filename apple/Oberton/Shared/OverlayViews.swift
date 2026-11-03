import ObertonCore
import SwiftUI

// The overlay and the Read aloud player stay dark in both themes, as on Windows: ink at 88% (the pill) or 94% (cards),
// paper-colored text, the accent's dark-paper version for highlights, red only for the recording dot.

private let darkInk = Color(hex: 0x0D0D0C)
private let lightText = Color(hex: 0xE8E7E3)
private let dimText = Color(hex: 0xE8E7E3, alpha: 0.6)
private let darkLine = Color(hex: 0xE8E7E3, alpha: 0.22)
private let recordRed = Color(hex: 0xFF4636)

/// How much room the overlay has: the screen's visible area less the margins on the Mac. Everything in the overlay
/// keeps within it, wrapping onto more lines rather than running off the edge.
extension EnvironmentValues {
    @Entry var overlayRoom = CGSize(width: 10_000, height: 10_000)
}

/// Proposes at most `width` to its content and takes the content's own size: short text hugs, long text wraps at
/// `width`. Unlike `.frame(maxWidth:)`, it never stretches short content out to the maximum.
struct WidthCap: Layout {
    var width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = min(proposal.width ?? width, width)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: w, height: nil)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Proposes at most `height` to its content, so a `ViewThatFits` inside can fall back to scrolling.
private struct HeightCap: Layout {
    var height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: min(proposal.height ?? height, height))) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// The pill: ● 00:14 ▮▮▮ LIGHT CLEANUP 録音 ✕ CANCEL. Clicking it after a dictation shows the receipt.
struct OverlayPill: View {
    @EnvironmentObject var model: AppModel
    var onTap: () -> Void = {}

    var body: some View {
        let live = [.recording, .transcribing, .processing].contains(model.phase) ? model.liveText : ""
        PillContent(phase: model.phase, profile: model.activeProfile.name, level: model.level, startedAt: model.startedAt,
                    live: live, opacity: model.settings.overlayOpacity, onCancel: { model.cancel() })
            .onTapGesture(perform: onTap)
    }
}

/// The pill itself, drawn from plain values. It grows with its text up to 520 pt (or the room there is), then wraps;
/// a 20 pt corner radius on a pill at least 40 pt tall is a capsule on one line and a rounded rectangle on more.
/// While dictating, the words recognized so far sit in the same box, above the row, as on Windows.
struct PillContent: View {
    var phase: AppModel.Phase
    var profile: String
    var level: Float = 0
    var startedAt: Date?
    var live = ""
    var opacity: Double
    var onCancel: () -> Void = {}
    @Environment(\.ob) private var ob
    @Environment(\.overlayRoom) private var room

    private static let shape = RoundedRectangle(cornerRadius: 20, style: .circular)

    var body: some View {
        WidthCap(width: min(520, room.width)) {
            VStack(alignment: .leading, spacing: 0) {
                if !live.isEmpty { LiveWords(text: live) }
                row
            }
            .foregroundStyle(lightText)
            .padding(EdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 8))
            .frame(minHeight: 40)
            .background(Self.shape.fill(darkInk.opacity(opacity)))
            .overlay(Self.shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 15, y: 8)
            .opacity(isDone ? 0.75 : 1)
            .contentShape(Self.shape)
        }
    }

    /// ● 00:14 ▮▮▮ LIGHT CLEANUP 録音 ✕ CANCEL
    private var row: some View {
        HStack(spacing: 14) {
            switch phase {
            case .recording:
                Circle().fill(recordRed).frame(width: 10, height: 10)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(elapsed).font(Ob.mono(11, .medium)).monospacedDigit()
                }
                .fixedSize()
                Wave(level: level)
            case .starting, .transcribing, .processing, .inserting:
                ProgressView().controlSize(.small).tint(lightText)
            case .failed:
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Color(hex: ob.accentChoice.hex.dark))
            default:
                Text("✓").font(Ob.mono(11, .semibold)).fixedSize()
            }
            Group {
                switch phase {
                case .recording, .starting: chipLabel(profile)
                default: Text(phase.label.uppercased()).font(Ob.mono(11, .medium)).lineSpacing(3)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            if let jp { Decor(jp, size: 10, color: lightText.opacity(0.55)).fixedSize() }
            if phase.isBusy {
                Button(action: onCancel) { chipLabel("✕  Cancel") }.buttonStyle(.plain).fixedSize()
            }
        }
        .frame(minHeight: 24)
    }

    private var jp: String? {
        switch phase {
        case .recording: "録音"
        case .transcribing, .processing: "処理中"
        case .done: "挿入"
        default: nil
        }
    }

    private var isDone: Bool { if case .done = phase { true } else { false } }

    private var elapsed: String {
        let s = Int(Date().timeIntervalSince(startedAt ?? Date()))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// A chip; a long profile name wraps inside it, and the 12 pt radius keeps a one-line chip a capsule.
    private func chipLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(Ob.mono(11, .medium))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .circular).strokeBorder(lightText.opacity(0.25), lineWidth: 1))
    }
}

/// The level as a short waveform of bars.
private struct Wave: View {
    var level: Float
    @State private var history: [Float] = Array(repeating: 0, count: 14)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(history.enumerated()), id: \.offset) { _, v in
                Capsule().fill(lightText).frame(width: 2.5, height: 4 + CGFloat(v) * 14)
            }
        }
        .frame(height: 18)
        .onChange(of: level) { _, new in
            history.removeFirst()
            history.append(new)
        }
        .accessibilityHidden(true)
    }
}

/// The words recognized so far, at the top of the pill's box: 14 pt text on 21 pt lines, at most 430 pt wide and three
/// lines tall. The newest words stay in view; older lines move up and out, as on Windows.
private struct LiveWords: View {
    var text: String
    @Environment(\.overlayRoom) private var room

    private static let lineHeight: CGFloat = 21
    #if os(macOS)
    private static let fontHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 14))
    #else
    private static let fontHeight = UIFont.systemFont(ofSize: 14).lineHeight
    #endif
    private static let spacing = max(0, lineHeight - fontHeight)
    /// Three lines (spacing goes between lines only), plus half a gap so rounding never cuts the last line.
    private static let maxHeight = 3 * lineHeight - spacing / 2

    var body: some View {
        WidthCap(width: min(430, room.width)) {
            Text(Self.tail(text, 180))
                .font(Ob.sans(14))
                .foregroundStyle(lightText.opacity(0.85))
                .lineSpacing(Self.spacing)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: Self.maxHeight, alignment: .bottomLeading)
                .clipped()
        }
        .padding(EdgeInsets(top: 6, leading: 0, bottom: 4, trailing: 10))
    }

    /// The last `max` characters, starting at a word when one starts soon enough, with "…" in front if cut.
    static func tail(_ text: String, _ max: Int) -> String {
        guard text.count > max else { return text }
        let tail = text.suffix(max)
        if let sp = tail.firstIndex(of: " "), (1..<40).contains(tail.distance(from: tail.startIndex, to: sp)) {
            return "…" + tail[tail.index(after: sp)...]
        }
        return "…" + tail
    }
}

/// ✓ INSERTED  MAIL // 17 WORDS, then 01 // TRANSCRIPTION, 02 // AI EDIT, 03 // INSERTED (or the preview, with
/// INSERTED brought forward and the buttons to decide).
struct ReceiptCard: View {
    var entry: HistoryEntry
    var preview = false
    var onClose: () -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob

    @Environment(\.overlayRoom) private var room

    var body: some View {
        WidthCap(width: min(440, room.width)) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(preview ? "PREVIEW" : "✓ INSERTED").font(Ob.mono(10.5, .semibold)).foregroundStyle(lightText).fixedSize()
                    Text(((entry.appName.map { [$0] } ?? []) + ["\(entry.words) words"]).joined(separator: " // ").uppercased())
                        .font(Ob.mono(10.5, .medium)).foregroundStyle(dimText).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: onClose) {
                        Text("✕").font(Ob.mono(10.5)).foregroundStyle(lightText)
                            .padding(.horizontal, 10).padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(lightText.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                // A long dictation scrolls inside the card rather than running the card off the screen.
                HeightCap(height: max(120, room.height - (preview ? 210 : 160))) {
                    ViewThatFits(in: .vertical) {
                        sections
                        ScrollView { sections }.scrollIndicators(.automatic)
                    }
                }
                if preview {
                    HStack(spacing: 8) {
                        Button("Insert") { model.confirmPreview() }.buttonStyle(DarkCapsule(filled: true))
                        Button("Use original") { model.confirmPreview(useOriginal: true) }.buttonStyle(DarkCapsule())
                        Button("Discard   Esc") { model.cancel() }.buttonStyle(DarkCapsule())
                    }
                    .padding(.top, 12)
                }
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(darkInk.opacity(0.94)))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            sep
            box("01 // Transcription", copy: entry.transcription) {
                Text(entry.transcription).foregroundStyle(lightText.opacity(0.85))
            }
            .opacity(preview ? 0.6 : 1)
            if let edit = entry.aiEdit {
                sep
                box("02 // AI Edit", copy: edit) { DiffText(original: entry.transcription, edited: edit, size: 13.5, onDark: true) }
                    .opacity(preview ? 0.6 : 1)
            }
            sep
            box("03 // Inserted", copy: entry.inserted) {
                Text(entry.inserted).foregroundStyle(lightText).font(Ob.sans(preview ? 16 : 14))
            }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 10, trailing: 10))
            .background(RoundedRectangle(cornerRadius: 8).fill(lightText.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(lightText.opacity(0.25), lineWidth: 1))
            if let warning = entry.warning {
                Text(warning).font(Ob.sans(12)).foregroundStyle(Color(hex: ob.accentChoice.hex.dark))
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
        }
    }

    private var sep: some View { Rectangle().fill(darkLine).frame(height: 1).padding(.vertical, 10) }

    private func box<C: View>(_ title: String, copy: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title.uppercased()).font(Ob.mono(10.5, .medium)).foregroundStyle(dimText)
                Spacer()
                TextCopyButton(text: copy, onDark: true)
            }
            content().font(Ob.sans(13.5)).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A capsule on the dark overlay.
struct DarkCapsule: ButtonStyle {
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Ob.mono(11, filled ? .semibold : .medium))
            .textCase(.uppercase)
            .foregroundStyle(filled ? darkInk : lightText)
            .padding(.horizontal, 14).frame(minHeight: 28)
            .background(Capsule().fill(filled ? lightText : .clear))
            .overlay(Capsule().strokeBorder(lightText.opacity(filled ? 1 : 0.25), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// The Read aloud player: READING  VOICE, the text with what has been read bright, the word being spoken in the accent,
/// the rest dim; a progress line; −15 ▮▮ +15, − 1.25× +, and the time left. The speed opens a grid of speeds.
struct ReaderCard: View {
    @ObservedObject var player: ReadAloudPlayer
    var opacity: Double
    @Environment(\.ob) private var ob
    @State private var all = false
    @State private var speeds = false
    @Environment(\.overlayRoom) private var room

    var body: some View {
        if player.isSpeaking {
            WidthCap(width: min(520, room.width)) { card }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("READING").font(Ob.mono(10.5, .semibold)).foregroundStyle(lightText)
                Text(player.voiceName.uppercased()).font(Ob.mono(10.5, .medium)).foregroundStyle(dimText).lineLimit(1)
                Spacer()
                Button { all.toggle() } label: {
                    Text(all ? "⌃ LESS" : "⌄ ALL").font(Ob.mono(10.5)).foregroundStyle(lightText)
                        .padding(.horizontal, 10).padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(lightText.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button { player.stop() } label: { Text("✕").font(Ob.mono(11)).foregroundStyle(lightText) }
                    .buttonStyle(.plain).accessibilityLabel("Stop")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(attributed).font(Ob.sans(15)).lineSpacing(7).frame(maxWidth: .infinity, alignment: .leading).id("text")
                }
                .frame(maxHeight: all ? 320 : 96)
            }
            .padding(.top, 10).padding(.bottom, 12)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(lightText.opacity(0.25))
                    Rectangle().fill(lightText).frame(width: geo.size.width * player.progress)
                }
            }
            .frame(height: 2).padding(.bottom, 12)
            HStack(spacing: 8) {
                round("−15") { player.skip(seconds: -15) }
                Button { player.togglePause() } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill").font(.system(size: 15))
                        .foregroundStyle(Color(hex: 0x161618))
                        .frame(width: 42, height: 42).background(Circle().fill(lightText))
                }
                .buttonStyle(.plain).accessibilityLabel(player.isPaused ? "Play" : "Pause")
                round("+15") { player.skip(seconds: 15) }
                Spacer().frame(width: 14)
                round("−") { player.setSpeed(player.speed - 0.25) }
                Button { speeds.toggle() } label: {
                    Text(speedText(player.speed)).font(Ob.mono(11, .medium)).foregroundStyle(lightText)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $speeds) { speedGrid }
                round("+") { player.setSpeed(player.speed + 0.25) }
                Spacer()
                Text(left).font(Ob.mono(11, .medium)).foregroundStyle(dimText)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(darkInk.opacity(max(opacity, 0.94))))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
    }

    private func round(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(Ob.mono(12, .medium)).foregroundStyle(lightText)
                .frame(width: 30, height: 30).background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    private var speedGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speed").font(Ob.sans(11)).foregroundStyle(Color.white.opacity(0.6)).padding(.leading, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 6), count: 4), spacing: 6) {
                ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 3.5, 4], id: \.self) { s in
                    let on = abs(s - player.speed) < 0.01
                    Button { player.setSpeed(s); speeds = false } label: {
                        Text(speedText(s)).font(Ob.mono(12)).foregroundStyle(on ? Color(hex: 0x161618) : lightText)
                            .frame(width: 58, height: 30).background(Capsule().fill(on ? .white : Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .background(Color(hex: 0x202024))
        .presentationBackground(Color(hex: 0x202024))
    }

    private func speedText(_ s: Double) -> String {
        (s == s.rounded() ? String(format: "%.0f", s) : s * 4 == (s * 4).rounded() && s * 2 != (s * 2).rounded() ? String(format: "%.2f", s) : String(format: "%.1f", s)) + "×"
    }

    private var left: String {
        let s = Int(player.secondsLeft.rounded())
        return String(format: "%d:%02d LEFT", s / 60, s % 60)
    }

    private var attributed: AttributedString {
        var s = AttributedString(player.text)
        s.foregroundColor = lightText.opacity(0.45)
        guard let r = player.spokenRange else { return s }
        if let read = Range(NSRange(location: 0, length: r.location), in: s) { s[read].foregroundColor = lightText }
        if let now = Range(r, in: s) {
            s[now].foregroundColor = Color(hex: ob.accentChoice.hex.dark)
            s[now].font = Ob.sans(15, .semibold)
        }
        return s
    }
}
