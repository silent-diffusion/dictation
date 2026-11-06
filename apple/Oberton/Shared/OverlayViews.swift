import ObertonCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

// The overlay and the Read aloud player stay dark in both themes, as on Windows: ink at the chosen opacity, paper-colored
// text, the accent's dark-paper version for highlights, red only for the recording dot.

let darkInk = Color(hex: 0x0D0D0C)
let lightText = Color(hex: 0xE8E7E3)
let dimText = Color(hex: 0xE8E7E3, alpha: 0.6)
let mutedText = Color(hex: 0xE8E7E3, alpha: 0.7)
let darkLine = Color(hex: 0xE8E7E3, alpha: 0.22)
let recordRed = Color(hex: 0xFF4636)

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

// MARK: - The pill

/// What the overlay shows, newest first as on Windows: the profile just switched to, a notice, the preview waiting for
/// a decision, NO PLACE TO PASTE, the receipt after a dictation went in, or the dictation under way. The preview and
/// NO PLACE TO PASTE (and notices) show even with "Show overlay" off.
struct OverlayPill: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var reader: ReadAloudPlayer
    /// The receipt's three boxes are open.
    @Binding var open: Bool

    private var hotkey: String {
        #if os(macOS)
        model.settings.hotkey
        #else
        ""
        #endif
    }

    var body: some View {
        let opacity = model.settings.overlayOpacity
        let phase = model.phase
        // The pill names the profile active when its state began (Windows' ShowState), not one cycled to since.
        let profile = model.stateProfile ?? model.activeProfile
        if model.profileNotice, !model.overlayPinned {
            let i = model.profiles.firstIndex { $0.id == model.activeProfile.id } ?? 0
            ProfilePill(name: model.activeProfile.name, index: i, count: model.profiles.count, opacity: opacity)
        } else if let notice = model.overlayNotice {
            NoticePill(text: notice.text, kind: notice.kind, opacity: opacity)
        } else if let trial = model.trialPreview {
            TrialPreviewPill(trial: trial, opacity: opacity) // a profile's Try it (TrialPreview.swift)
        } else if phase == .preview, let pending = model.pending {
            PreviewPill(entry: pending, profile: profile.name, hotkey: hotkey, opacity: opacity, context: model.insertionContext,
                        usesAI: !profile.isRaw,
                        onInsert: { model.confirmPreview() }, onOriginal: { model.confirmPreview(useOriginal: true) },
                        onDiscard: { model.cancel() })
        } else if phase == .placing {
            PlacingPill(profile: profile.name, hotkey: hotkey, opacity: opacity,
                        onCopy: { model.copyPlacingToClipboard() }, onDiscard: { model.cancel() })
        } else if case .failed(let message) = phase {
            NoticePill(text: message, kind: .error, opacity: opacity)
        } else if case .done = phase {
            // A profile can read what went in aloud: the player then takes the receipt's place, unless it has a warning
            // (AppModel decided, and left `receipt` nil).
            if model.settings.showOverlay, let entry = model.receipt {
                ReceiptPill(entry: entry, opacity: opacity, open: open, context: model.insertionContext, onOpen: { open = true },
                            onHover: { model.holdReceipt($0, release: open ? 4 : 2) }, onClose: { model.dismissReceipt() })
            }
        } else if model.settings.showOverlay, phase != .idle {
            let live = [.recording, .transcribing, .processing].contains(phase) ? model.liveText : ""
            PillContent(phase: phase, profile: profile.name, meterFeed: model.meter, startedAt: model.startedAt,
                        live: live, opacity: opacity, aiModel: Self.chip(model.processor.model(for: profile)),
                        audioSeconds: model.stoppedAt.map { $0.timeIntervalSince(model.startedAt ?? $0) },
                        loadingSpeech: model.speechLoading, finalPass: model.finalPass, onCancel: { model.cancel() })
        }
    }

    /// The model as the processing chip names it: as stored, the way Windows shows `profile.Model` ("qwen3:8b",
    /// "anthropic:claude-haiku-4-5-20251001"); Apple Intelligence by its name.
    static func chip(_ id: ModelID) -> String {
        switch id.provider {
        case .ollama: id.name
        case .apple: id.displayName
        case .anthropic, .openai: id.description
        }
    }
}

/// Windows' body widths (OverlayWindow.xaml.cs): compact while dictating, wide for messages and the cleanup, narrow for
/// the receipt and the profile, the preview's three columns, and the opened receipt's stacked boxes.
enum PillWidth {
    static let compact: CGFloat = 440, wide: CGFloat = 470, narrow: CGFloat = 360
    static let compareWide: CGFloat = 860, compareStack: CGFloat = 560
}

/// The overlay's card: a body of a fixed width (less if the screen is smaller), padded 18, 8, 8, 8 inside a 1 pt
/// paper edge at 14%, ink at the chosen opacity, a soft shadow. 28 pt corners on one line, 20 when it grows (expanded).
struct PillCard: ViewModifier {
    var width: CGFloat
    var expanded = false
    var opacity: Double
    @Environment(\.overlayRoom) private var room

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: expanded ? 20 : 28, style: .circular)
        content
            .frame(width: max(40, min(width, room.width - 28)), alignment: .leading)
            .foregroundStyle(lightText)
            .padding(EdgeInsets(top: 9, leading: 19, bottom: 9, trailing: 9))
            // WPF's DropShadowEffect (BlurRadius 24, ShadowDepth 4 at 315°, Opacity .35): its blur radius spans three
            // standard deviations (σ 8); SwiftUI's shadow radius is the standard deviation itself (measured: the edge's
            // shadow falls to 16 % at one radius out), so 8.
            .background(shape.fill(darkInk.opacity(min(1, max(0.3, opacity)))).shadow(color: .black.opacity(0.35), radius: 8, x: 2.8, y: 2.8))
            .overlay(shape.strokeBorder(Color(hex: 0xE8E7E3, alpha: 0x24 / 255), lineWidth: 1))
            .contentShape(shape)
    }
}

/// The left-hand mark: the recording dot (red, pulsing), a grey dot (an info notice), the spinner, ✓ or ⚠.
enum PillIndicator {
    case dot(Color, pulse: Bool)
    case spinner
    case check
    case warning(Color)
}

/// The trailing button: "✕ CANCEL" while dictating, a plain ✕ when it closes the opened receipt.
enum PillTrailing {
    case cancel(() -> Void)
    case close(() -> Void)
}

/// The pill's one row, laid out as Windows' grid: indicator · TITLE · (meter, subtitle or dots) · decor · chip · button,
/// at least 40 pt tall.
struct PillRow<Title: View, Middle: View>: View {
    var indicator: PillIndicator?
    var decor: String?
    var chip: String?
    var trailing: PillTrailing?
    var title: Title
    var middle: Middle

    init(indicator: PillIndicator? = nil, decor: String? = nil, chip: String? = nil, trailing: PillTrailing? = nil,
         @ViewBuilder title: () -> Title, @ViewBuilder middle: () -> Middle) {
        self.indicator = indicator
        self.decor = decor
        self.chip = chip
        self.trailing = trailing
        self.title = title()
        self.middle = middle()
    }

    var body: some View {
        // Windows' grid: indicator, title, decor and chip, and the button are Auto columns, shown whole; the star column
        // in the middle (meter, subtitle or dots, 12 in from either side) takes what is left, nothing when they need it
        // all. What doesn't fit then is cut off at the right edge, without "…" (WPF clips a grid that overflows).
        PillGrid {
            if let indicator {
                IndicatorView(kind: indicator).frame(width: 16, height: 16).padding(.trailing, 12)
            }
            title
                .font(Ob.mono(13, .semibold))
                .lineLimit(1)
                .fixedSize()
            // Never empty (an empty view would drop out of the grid), and cut to its column even when its content is wider.
            HStack(spacing: 0) {
                middle
                Spacer(minLength: 0)
            }
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                .padding(.horizontal, 12)
                .layoutValue(key: PillStar.self, value: true)
            HStack(spacing: 0) {
                if let decor {
                    Decor(decor, size: 10.5, color: lightText.opacity(0.5)).fixedSize().padding(.trailing, 10)
                }
                if let chip, !chip.isEmpty {
                    Text(chip).font(Ob.mono(11)).foregroundStyle(lightText.opacity(0.8))
                        .lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .circular).strokeBorder(darkLine, lineWidth: 1))
                        .padding(.trailing, 8)
                }
            }
            .fixedSize()
            switch trailing {
            case .cancel(let action):
                Button(action: action) {
                    HStack(spacing: 7) {
                        Cross().stroke(lightText, style: StrokeStyle(lineWidth: 1.4, lineCap: .round)).frame(width: 11, height: 11)
                        Text("CANCEL")
                    }
                }
                .buttonStyle(PillButtonStyle(height: 36, padding: 12))
                .fixedSize()
                .help("Cancel this dictation")
                .accessibilityLabel("Cancel dictation")
            case .close(let action):
                Button(action: action) {
                    Cross().stroke(lightText, style: StrokeStyle(lineWidth: 1.4, lineCap: .round)).frame(width: 11, height: 11)
                }
                .buttonStyle(PillButtonStyle(height: 36, padding: 0))
                .fixedSize()
                .help("Close")
                .accessibilityLabel("Close")
            case nil:
                EmptyView()
            }
        }
        .frame(minHeight: 40)
        .clipped()
    }
}

/// Marks the pill row's star column.
private struct PillStar: LayoutValueKey {
    static let defaultValue = false
}

/// The pill row as Windows' Grid lays it out: every column but the star one at its own size, left to right, centred
/// vertically; the star column gets the width left over (none if there is none), so what follows it sits at the right.
private struct PillGrid: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0[PillStar.self] ? CGSize.zero : $0.sizeThatFits(.unspecified) }
        let fixed = sizes.reduce(0) { $0 + $1.width }
        let star = subviews.first { $0[PillStar.self] }
        let width: CGFloat
        if let w = proposal.width, w.isFinite { width = w } else { width = fixed + (star?.sizeThatFits(.unspecified).width ?? 0) }
        let starHeight = star?.sizeThatFits(ProposedViewSize(width: max(0, width - fixed), height: nil)).height ?? 0
        return CGSize(width: width, height: max(starHeight, sizes.map(\.height).max() ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0[PillStar.self] ? CGSize.zero : $0.sizeThatFits(.unspecified) }
        let starWidth = max(0, bounds.width - sizes.reduce(0) { $0 + $1.width })
        var x = bounds.minX
        for (subview, size) in zip(subviews, sizes) {
            let width = subview[PillStar.self] ? starWidth : size.width
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: subview[PillStar.self] ? nil : size.height))
            x += width
        }
    }
}

extension PillRow where Middle == EmptyView {
    init(indicator: PillIndicator? = nil, decor: String? = nil, chip: String? = nil, trailing: PillTrailing? = nil,
         @ViewBuilder title: () -> Title) {
        self.init(indicator: indicator, decor: decor, chip: chip, trailing: trailing, title: title) { EmptyView() }
    }
}

private struct IndicatorView: View {
    var kind: PillIndicator
    @Environment(\.ob) private var ob

    var body: some View {
        switch kind {
        case .dot(let color, let pulse): PulsingDot(color: color, pulse: pulse)
        case .spinner: RingSpinner(accent: Color(hex: ob.accentChoice.hex.dark))
        case .check:
            CheckMark().stroke(lightText, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        case .warning(let color):
            WarningMark().stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The recording dot: 10 pt, fading to 35% and back every 700 ms while it records.
private struct PulsingDot: View {
    var color: Color
    var pulse: Bool
    @State private var dim = false

    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
            .opacity(pulse && dim ? 0.35 : 1)
            .onAppear {
                guard pulse else { return }
                withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Windows' spinner: a faint 14 pt ring with a quarter arc in the accent, one turn a second.
private struct RingSpinner: View {
    var accent: Color

    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            ZStack {
                Circle().strokeBorder(lightText.opacity(0.2), lineWidth: 1.5).frame(width: 14, height: 14) // stroke inside, as WPF
                Circle().trim(from: 0, to: 0.25)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(-90 + turn * 360))
            }
        }
        .accessibilityLabel("Working")
    }
}

/// Windows' drawn marks, on a 16 pt grid.
private struct CheckMark: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 2.5, y: 8.5))
            p.addLine(to: CGPoint(x: 6.2, y: 12))
            p.addLine(to: CGPoint(x: 13.5, y: 4.5))
        }
    }
}

private struct WarningMark: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 8, y: 1.8))
            p.addLine(to: CGPoint(x: 14.8, y: 14))
            p.addLine(to: CGPoint(x: 1.2, y: 14))
            p.closeSubpath()
            p.move(to: CGPoint(x: 8, y: 6.5))
            p.addLine(to: CGPoint(x: 8, y: 9.6))
            p.move(to: CGPoint(x: 8, y: 11.8))
            p.addLine(to: CGPoint(x: 8, y: 11.9))
        }
    }
}

private struct Cross: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 1, y: 1))
            p.addLine(to: CGPoint(x: 10, y: 10))
            p.move(to: CGPoint(x: 10, y: 1))
            p.addLine(to: CGPoint(x: 1, y: 10))
        }
    }
}

/// The overlay's buttons (Windows' PillButton styles): 32 pt capsules in mono 11.5. `accent` is filled paper (Insert),
/// `outline` a faint edge (Use original), `ghost` no edge (Discard), `plain` the Cancel / ✕ button.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case plain, accent, outline, ghost }
    var kind = Kind.plain
    var height: CGFloat = 32
    var padding: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, style: self)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: PillButtonStyle
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .circular)
        let accent = style.kind == .accent
        configuration.label
            .font(Ob.mono(11.5, accent ? .semibold : .regular))
            .foregroundStyle(accent ? darkInk : style.kind == .ghost ? lightText.opacity(0xC8 / 255) : lightText)
            .lineLimit(1)
            .padding(.horizontal, style.padding + 1) // WPF lays the padding inside the 1 pt border
            .frame(minWidth: style.height, minHeight: style.height, maxHeight: style.height)
            // Windows' PillButton template sets the faint hover fill for every style, the filled Insert one included.
            .background(shape.fill(hovering ? lightText.opacity(0x1A / 255) : accent ? lightText : .clear))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .overlayHandCursor()
    }

    private var border: Color {
        switch style.kind {
        case .accent: lightText
        case .outline: Color.white.opacity(0x38 / 255)
        case .plain: darkLine
        case .ghost: .clear
        }
    }
}

/// A message under the row: 15 pt on 22 pt lines, at most 112 pt tall, the end of it if it is long.
private struct PillBodyText: View {
    var text: String
    var color = lightText

    var body: some View {
        Text(LiveWords.tail(text, 260))
            .font(Ob.sans(15)).lineSpacing(4).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2) // WPF's LineHeight 22 holds the first and last line too
            .frame(maxWidth: .infinity, maxHeight: 112, alignment: .topLeading).clipped()
            .padding(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 10))
    }
}

// MARK: Dictating

/// The pill while dictating, drawn from plain values (Windows' ShowState):
/// STARTING · ● 0:07 ⠿⠿⠿ 録音 Light Cleanup ✕ CANCEL · TRANSCRIBING 7 S OF AUDIO · TIDYING // LIGHT CLEANUP with the AI
/// model's chip and the transcript under it · INSERTING 挿入. The words recognized so far sit above the row.
struct PillContent: View {
    var phase: AppModel.Phase
    var profile: String
    /// The level meter's columns, fixed (snapshots), or the live meter, which moves by itself.
    var meter: [Double] = []
    var meterFeed: LevelMeter?
    var startedAt: Date?
    var live = ""
    var opacity: Double
    /// The AI model tidying up (the processing chip).
    var aiModel: String?
    /// How long the recording was (TRANSCRIBING's "N S OF AUDIO").
    var audioSeconds: Double?
    /// The speech model is still loading.
    var loadingSpeech = false
    /// The text was already typed while speaking: this is the final pass over it.
    var finalPass = false
    var onCancel: () -> Void = {}

    private var processing: Bool { phase == .processing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if phase == .recording || phase == .transcribing {
                if !live.isEmpty {
                    LiveWords(text: live)
                } else if loadingSpeech {
                    LiveWords(text: "Loading the speech model… keep talking, it will catch up.", color: mutedText)
                }
            }
            row
            if processing, !live.isEmpty { PillBodyText(text: live, color: mutedText) }
        }
        .modifier(PillCard(width: processing ? PillWidth.wide : PillWidth.compact, expanded: processing, opacity: opacity))
        .opacity(isDone ? 0.75 : 1)
    }

    @ViewBuilder private var row: some View {
        switch phase {
        case .starting:
            PillRow(indicator: .spinner, decor: "処理中", chip: profile, trailing: .cancel(onCancel)) { Text("STARTING") }
        case .recording:
            PillRow(indicator: .dot(recordRed, pulse: true), decor: "録音", chip: profile, trailing: .cancel(onCancel)) {
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    Text(clock).font(Ob.mono(13)).monospacedDigit()
                }
                .fixedSize()
            } middle: {
                if let meterFeed { LiveDotMeter(meter: meterFeed) } else { DotMeter(levels: meter) }
            }
        case .transcribing:
            PillRow(indicator: .spinner, decor: "処理中", chip: profile, trailing: .cancel(onCancel)) {
                Text(loadingSpeech ? "LOADING SPEECH MODEL" : "TRANSCRIBING")
            } middle: {
                if let audioSeconds {
                    // Math.Round: half to even.
                    Text("\(max(1, Int(audioSeconds.rounded(.toNearestOrEven)))) S OF AUDIO")
                        .font(Ob.mono(11.5)).foregroundStyle(mutedText).truncationMode(.tail)
                }
            }
        case .processing:
            PillRow(indicator: .spinner, decor: "処理中", chip: aiModel, trailing: .cancel(onCancel)) {
                Text((finalPass ? "FINAL PASS // " : "TIDYING // ") + profile.uppercased())
            }
        case .inserting:
            PillRow(indicator: .spinner, decor: "挿入") { Text("INSERTING") }
        case .done(let message):
            PillRow(indicator: .check, decor: "挿入") { Text(message.uppercased()) }
        case .failed(let message):
            PillRow(indicator: .warning(lightText)) { Text(message) }
        case .idle, .preview, .placing:
            PillRow { Text(phase.label.uppercased()) }
        }
    }

    private var isDone: Bool { if case .done = phase { true } else { false } }

    /// m:ss, as on Windows (0:07).
    private var clock: String {
        let s = max(0, Int(Date().timeIntervalSince(startedAt ?? Date())))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// The running meter: redraws on the meter's own tick.
private struct LiveDotMeter: View {
    @ObservedObject var meter: LevelMeter
    var body: some View { DotMeter(levels: meter.columns) }
}

/// The level meter: 22 columns of 5 dots, lit from the bottom as far as each moment's level reaches (√level, so quiet
/// speech still moves it; at least one dot, so silence reads as a row of dots).
private struct DotMeter: View {
    /// 22 columns, oldest first, already √-scaled (`LevelMeter`, which moves on a steady tick).
    var levels: [Double]

    var body: some View {
        let levels = levels.count == 22 ? levels : Array((levels + [Double](repeating: 0, count: 22)).prefix(22))
        HStack(spacing: 3) {
            ForEach(0..<levels.count, id: \.self) { i in
                let lit = max(1, Int((levels[i] * 5).rounded()))
                VStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { d in
                        Circle().fill(lightText).frame(width: 3, height: 3).opacity(5 - d <= lit ? 0.95 : 0.2)
                    }
                }
            }
        }
        .frame(height: 28)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// The words recognized so far, at the top of the pill's box: 14 pt text on 21 pt lines, at most 430 pt wide and three
/// lines tall. The newest words stay in view; older lines move up and out, as on Windows.
struct LiveWords: View {
    var text: String
    var color = lightText.opacity(0.85)
    @Environment(\.overlayRoom) private var room

    private static let lineHeight: CGFloat = 21
    #if os(macOS)
    private static let fontHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 14))
    #else
    private static let fontHeight = UIFont.systemFont(ofSize: 14).lineHeight
    #endif
    private static let spacing = max(0, lineHeight - fontHeight)
    /// Three lines (spacing goes between lines only; the half gaps above and below are padding), and a little for rounding.
    private static let maxHeight = 3 * lineHeight - spacing + 0.5

    var body: some View {
        WidthCap(width: min(430, room.width)) {
            Text(LiveTail.tail(text))
                .font(Ob.sans(14))
                .foregroundStyle(color)
                .lineSpacing(Self.spacing)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: Self.maxHeight, alignment: .bottomLeading)
                .clipped()
                .padding(.vertical, Self.spacing / 2) // WPF's LineHeight 21 holds the first and last line too: n × 21
        }
        .padding(EdgeInsets(top: 6, leading: 0, bottom: 4, trailing: 10))
    }

    /// The last `max` characters, starting at a word when one starts soon enough, with "…" in front if cut.
    static func tail(_ text: String, _ max: Int) -> String { LiveTail.tail(text, max) }
}

// MARK: Waiting for a decision

/// ✓ READY TO INSERT with the profile, then 01 // TRANSCRIPTION · 02 // AI EDIT · 03 // INSERTED side by side with
/// the one that goes in brought forward, then INSERT <hotkey>, USE ORIGINAL and, at the right, DISCARD ESC. 860 pt wide;
/// stacked at 560 where there isn't room (iPhone).
struct PreviewPill: View {
    var entry: HistoryEntry
    var profile: String
    var hotkey: String
    var opacity: Double
    /// The text around the cursor, shown either side of the AI edit (none for a profile's Try it).
    var context: InsertionContext?
    /// The profile active when the preview showed uses AI (Windows' `usesAi = Active.AutoProcess`); nil: as the entry says.
    var usesAI: Bool?
    var onInsert: () -> Void = {}
    var onOriginal: () -> Void = {}
    var onDiscard: () -> Void = {}
    @Environment(\.overlayRoom) private var room

    var body: some View {
        let stacked = room.width < 640
        let width = stacked ? PillWidth.compareStack : PillWidth.compareWide
        let inner = max(40, min(width, room.width - 28))
        VStack(alignment: .leading, spacing: 0) {
            PillRow(indicator: .check, chip: profile) { Text("READY TO INSERT") }
            // The diff is between what was heard and what goes in; a profile without AI has none. One with AI shows it
            // even when the AI failed or changed nothing (an unchanged diff), as on Windows (`usesAi`).
            CompareBoxes(raw: entry.transcription, edit: (usesAI ?? (entry.model != nil)) ? entry.inserted : nil, inserted: entry.inserted,
                         noEdit: "No AI edit: this profile doesn't use AI.", context: context, stacked: stacked, focus: true, width: inner - 10)
                .padding(EdgeInsets(top: 6, leading: 0, bottom: 8, trailing: 10))
            HStack(spacing: 8) {
                Button(hotkey.isEmpty ? "INSERT" : "INSERT   \(hotkey.uppercased())", action: onInsert)
                    .buttonStyle(PillButtonStyle(kind: .accent))
                Button("USE ORIGINAL", action: onOriginal).buttonStyle(PillButtonStyle(kind: .outline))
                Spacer(minLength: 8)
                Button(discardLabel, action: onDiscard).buttonStyle(PillButtonStyle(kind: .ghost)).padding(.trailing, 4)
            }
            .padding(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
        }
        .modifier(PillCard(width: width, expanded: true, opacity: opacity))
    }
}

/// "DISCARD   ESC" on the Mac, where Esc discards; the iPhone has no Esc.
private var discardLabel: String {
    #if os(macOS)
    "DISCARD   ESC"
    #else
    "DISCARD"
    #endif
}

/// ⚠ NO PLACE TO PASTE: nothing that takes text had the cursor when the dictation started. A click into a text field
/// puts it there (the platform watches for that), or COPY TO CLIPBOARD <hotkey>; DISCARD ESC at the right.
struct PlacingPill: View {
    var profile: String
    var hotkey: String
    var opacity: Double
    var onCopy: () -> Void = {}
    var onDiscard: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PillRow(indicator: .warning(lightText), chip: profile) { Text("NO PLACE TO PASTE") }
            PillBodyText(text: "Nothing to type into had the cursor when you started. Click into a text field and the text goes in there, or copy it to the clipboard.")
            HStack(spacing: 8) {
                Button(hotkey.isEmpty ? "COPY TO CLIPBOARD" : "COPY TO CLIPBOARD   \(hotkey.uppercased())", action: onCopy)
                    .buttonStyle(PillButtonStyle(kind: .accent))
                Spacer(minLength: 8)
                Button(discardLabel, action: onDiscard).buttonStyle(PillButtonStyle(kind: .ghost)).padding(.trailing, 4)
            }
            .padding(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
        }
        .modifier(PillCard(width: PillWidth.wide, expanded: true, opacity: opacity))
    }
}

// MARK: Messages

/// A notice (Windows' ShowMessage): ● OBERTON for information, ⚠ HEADS UP for a warning, ⚠ SOMETHING WENT WRONG (in the
/// accent) for an error, with the message under it. 470 pt wide.
struct NoticePill: View {
    var text: String
    var kind: AppModel.NoticeKind
    var opacity: Double
    @Environment(\.ob) private var ob

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PillRow(indicator: indicator) { Text(title) }
            PillBodyText(text: text)
        }
        .modifier(PillCard(width: PillWidth.wide, expanded: true, opacity: opacity))
        .accessibilityElement(children: .combine)
    }

    private var indicator: PillIndicator {
        switch kind {
        case .info: .dot(mutedText, pulse: false)
        case .warning: .warning(lightText)
        case .error: .warning(Color(hex: ob.accentChoice.hex.dark))
        }
    }

    private var title: String {
        switch kind {
        case .info: "OBERTON"
        case .warning: "HEADS UP"
        case .error: "SOMETHING WENT WRONG"
        }
    }
}

/// ● DICTATION APPEARS HERE: for a moment after Settings › Layout moves the overlay, at the new spot.
struct PositionPill: View {
    var opacity: Double

    var body: some View {
        PillRow(indicator: .dot(recordRed, pulse: false)) { Text("DICTATION APPEARS HERE") }
            .modifier(PillCard(width: PillWidth.narrow, opacity: opacity))
    }
}

/// PROFILE   Formal email  ▬ • • •  (the cycle-profile hotkey): the profile's name, and a dot for each profile with the
/// current one drawn long. 360 pt wide, as on Windows.
struct ProfilePill: View {
    var name: String
    var index: Int
    var count: Int
    var opacity: Double

    var body: some View {
        PillRow {
            Text("PROFILE   ").fontWeight(.regular).foregroundStyle(mutedText) + Text(name)
        } middle: {
            if count > 1 {
                HStack(spacing: 5) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule().fill(i == index ? lightText : lightText.opacity(0x4D / 255)).frame(width: i == index ? 16 : 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHidden(true)
            }
        }
        .modifier(PillCard(width: PillWidth.narrow, opacity: opacity))
        .accessibilityElement(children: .combine)
    }
}

// MARK: After a dictation

/// ✓ INSERTED  17 WORDS // 1.2 S  挿入 — after a dictation went in. Dimmed so it doesn't compete with the text; the
/// pointer on it brings it back and keeps it. When the safety net stepped in (or there is a note), a warning and the
/// note instead. Clicking it opens 01 // TRANSCRIPTION, 02 // AI EDIT, 03 // INSERTED, read top to bottom, with ✕.
struct ReceiptPill: View {
    var entry: HistoryEntry
    var opacity: Double
    var open = false
    /// The text around the cursor when the dictation started, either side of the AI edit.
    var context: InsertionContext?
    var onOpen: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onClose: () -> Void = {}
    @Environment(\.overlayRoom) private var room
    @State private var hovering = false

    private var safetyNet: Bool { entry.safetyNet ?? false }
    private var noted: Bool { safetyNet || entry.warning != nil }
    private var edited: Bool { entry.inserted != entry.transcription }
    /// The words that went in (InsertReceipt.Words: the inserted text split at white space), 0 when nothing did.
    private var words: Int { entry.inserted.split(whereSeparator: \.isWhitespace).count }

    var body: some View {
        // Windows' widths: 360 for the receipt, 470 with a note, 560 with the boxes open.
        let width = open ? PillWidth.compareStack : noted ? PillWidth.wide : PillWidth.narrow
        VStack(alignment: .leading, spacing: 0) {
            PillRow(indicator: noted ? .warning(lightText) : .check, decor: noted ? nil : "挿入", trailing: open ? .close(onClose) : nil) {
                Text(title)
            } middle: {
                if !noted {
                    Text("\(words) \(words == 1 ? "WORD" : "WORDS") // \(Self.seconds(entry.turnaroundSeconds)) S")
                        .font(Ob.mono(11.5)).foregroundStyle(mutedText).lineLimit(1).truncationMode(.tail)
                }
            }
            if open {
                CompareBoxes(raw: entry.transcription, edit: hasEdit ? entry.aiEdit : nil, inserted: entry.inserted,
                             noEdit: safetyNet ? "The safety net rejected the AI's edit, so your words went in as spoken." : "No AI edit for this dictation.",
                             context: context, stacked: true, width: max(40, min(width, room.width - 28)) - 10)
                    .padding(EdgeInsets(top: 6, leading: 0, bottom: 8, trailing: 10))
            } else if noted {
                PillBodyText(text: entry.warning ?? "The AI's edit changed too much (or came back empty), so your words went in unchanged. "
                    + "You can adjust the safety net on the profile's page.")
            }
        }
        .modifier(PillCard(width: width, expanded: open || noted, opacity: opacity))
        .opacity(noted || open || hovering ? 1 : 0.55)
        .onHover { on in
            hovering = on
            onHover(on)
        }
        .overlayHandCursor(!open)
        .onTapGesture { if !open { onOpen() } }
    }

    private var title: String {
        #if os(iOS)
        // The iPhone can't type into another app: the text went to the clipboard, ready to paste.
        !safetyNet ? "COPIED" : edited ? "PARTLY EDITED" : "ORIGINAL WORDS COPIED"
        #else
        !safetyNet ? "INSERTED" : edited ? "PARTLY EDITED" : "ORIGINAL WORDS INSERTED"
        #endif
    }

    /// "1.2" or "1,2" as the region writes it (.NET's {0:0.0} in the current culture: half away from zero).
    static func seconds(_ s: Double) -> String {
        s.formatted(.number.precision(.fractionLength(1)).rounded(rule: .awayFromZero).grouping(.never))
    }

    /// The AI's edit is shown as a diff whenever there is one (Windows: `AiEdit != null`, set when the AI changed the text).
    private var hasEdit: Bool { entry.aiEdit != nil }
}

// MARK: The three boxes

/// 01 // TRANSCRIPTION · 02 // AI EDIT (struck through / added) · 03 // INSERTED. Side by side in the preview, with
/// INSERTED brought forward (wider, framed, larger, the others at 45%) and up to 220 pt tall; stacked after a dictation
/// went in, up to 130 pt each. Each box's COPY takes the part selected in it, or the whole box; AI EDIT's leaves out
/// the struck-through words.
struct CompareBoxes: View {
    var raw: String
    /// The text the AI made of `raw`; nil when there was no AI edit (`noEdit` shows instead).
    var edit: String?
    var inserted: String
    var noEdit: String
    /// The text around the cursor, in its own colour either side of the AI edit, so the edit reads in place.
    var context: InsertionContext?
    var stacked: Bool
    var focus = false
    /// The width the boxes fill.
    var width: CGFloat
    @Environment(\.ob) private var ob
    @State private var selections = [OverlayTextSelection(), OverlayTextSelection(), OverlayTextSelection()]
    @State private var popped = false

    private var maxHeight: CGFloat { stacked ? 130 : 220 }

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 0) {
                rawBox(width: width)
                rule
                editBox(width: width)
                rule
                insertedBox(width: width)
            }
        } else {
            let unit = max(20, (width - 40) / (focus ? 3.4 : 3))
            HStack(alignment: .top, spacing: 0) {
                rawBox(width: unit)
                divider(hidden: false)
                editBox(width: unit)
                divider(hidden: focus)
                insertedBox(width: unit * (focus ? 1.4 : 1))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rule: some View { Rectangle().fill(darkLine).frame(height: 1).padding(.vertical, 9) }

    private func divider(hidden: Bool) -> some View {
        Rectangle().fill(hidden ? .clear : darkLine).frame(width: 1).frame(width: 20).frame(maxHeight: .infinity)
    }

    private func rawBox(width: CGFloat) -> some View {
        box("01 // TRANSCRIPTION", name: "Copy Transcription", copy: { selections[0].selected() ?? raw }) {
            OverlayText(text: .plain(raw, color: lightText.opacity(0.85)), maxHeight: maxHeight, selection: selections[0])
        }
        .frame(width: width, alignment: .topLeading)
        .opacity(focus ? 0.45 : 1)
    }

    private func editBox(width: CGFloat) -> some View {
        let trimmed = edit?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A selected part copies as shown, struck words included (Windows' Selection.Text); the whole box leaves them out.
        return box("02 // AI EDIT", name: "Copy AI Edit", copy: { selections[1].selected() ?? trimmed ?? "" }) {
            if let trimmed {
                OverlayText(text: .diff(raw, trimmed, accent: Color(hex: ob.accentChoice.hex.dark), context: context), maxHeight: maxHeight,
                            selection: selections[1])
            } else {
                // In the same selectable box, on its 21 pt lines (Windows' paragraph, muted).
                OverlayText(text: OverlayRichText(runs: [(noEdit, .plain)], color: mutedText, isDiff: true), maxHeight: maxHeight,
                            selection: selections[1])
            }
        }
        .frame(width: width, alignment: .topLeading)
        .opacity(focus ? 0.45 : 1)
    }

    private func insertedBox(width: CGFloat) -> some View {
        let text = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        let shape = RoundedRectangle(cornerRadius: 6, style: .circular)
        return box("03 // INSERTED", name: "Copy Inserted", label: focus ? lightText : dimText, copy: { selections[2].selected() ?? text }) {
            OverlayText(text: .plain(text, color: lightText, size: focus ? 15.5 : 14), maxHeight: maxHeight, selection: selections[2])
        }
        // Inside the frame's 1 pt border, which is there (transparent) even when it isn't focused, as WPF lays it out.
        .padding(focus ? EdgeInsets(top: 11, leading: 15, bottom: 13, trailing: 15) : EdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1))
        .background(shape.fill(focus ? lightText.opacity(0x1F / 255) : .clear))
        .overlay(shape.strokeBorder(focus ? lightText.opacity(0x66 / 255) : .clear, lineWidth: 1))
        .frame(width: width, alignment: .topLeading)
        // The box that goes in pops out a little (0.96 → 1.02 over 220 ms) and stays there.
        .scaleEffect(focus ? (popped ? 1.02 : 0.96) : 1)
        .onAppear {
            guard focus else { return }
            withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.22)) { popped = true } // CubicEase EaseOut
        }
    }

    /// A box: its name and COPY, then its text.
    private func box<C: View>(_ title: String, name: String, label: Color = dimText, copy: @escaping () -> String,
                              @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Ob.mono(10.5)).foregroundStyle(label)
                Spacer(minLength: 8)
                CopyLink(text: copy).accessibilityLabel(name)
            }
            content()
        }
    }
}

/// COPY next to a box's name; COPIED ✓ for a moment after.
private struct CopyLink: View {
    var text: () -> String
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button {
            let t = text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            Clipboard.copy(t)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
        } label: {
            Text(copied ? "COPIED ✓" : "COPY").font(Ob.mono(10.5)).foregroundStyle(lightText.opacity(0.8))
                .padding(.horizontal, 9).padding(.vertical, 2) // 8,1 inside the 1 pt border
                .background(Capsule().fill(hovering ? Color.white.opacity(0x1A / 255) : .clear))
                .overlay(Capsule().strokeBorder(darkLine, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlayHandCursor()
        .help("Copy this box (or just the part you selected)")
    }
}

/// A box's text as runs: plain, or the AI edit's diff (removed words struck through, added ones in the accent).
struct OverlayRichText {
    enum Style { case plain, removed, added, context }
    var runs: [(String, Style)]
    var color: Color
    var accent: Color = lightText
    var size: CGFloat = 14
    /// Windows' line heights: AI EDIT's diff sets 21; TRANSCRIPTION and INSERTED are TextBoxes at the font's own
    /// height, about 1.33 × the size (18.6 at 14, 20.6 at 15.5).
    var lineHeight: CGFloat { isDiff ? 21 : (size * 1.33).rounded(.toNearestOrEven) }
    var isDiff = false

    static func plain(_ text: String, color: Color, size: CGFloat = 14) -> OverlayRichText {
        OverlayRichText(runs: [(text, .plain)], color: color, size: size)
    }

    static func diff(_ original: String, _ edited: String, accent: Color, context: InsertionContext? = nil) -> OverlayRichText {
        var runs: [(String, Style)] = []
        // The text around the cursor, in its own colour either side of the edit, so it reads in place.
        let before = around(context?.before, fromEnd: true), after = around(context?.after, fromEnd: false)
        if let last = before.last { runs.append((before + (last.isWhitespace ? "" : " "), .context)) }
        for (i, token) in WordDiff.compute(original, edited).enumerated() {
            if i > 0 { runs.append((" ", .plain)) }
            runs.append((token.word, token.kind == .same ? .plain : token.kind == .removed ? .removed : .added))
        }
        if let first = after.first { runs.append(((first.isWhitespace || first.isPunctuation ? "" : " ") + after, .context)) }
        return OverlayRichText(runs: runs, color: lightText, accent: accent, isDiff: true)
    }

    /// At most ~160 characters of the surrounding text, cut at a word, with "…" where it was cut (Windows `Around`):
    /// every line ending .NET's ReplaceLineEndings knows (CR, LF, CRLF, NEL, LS, PS, FF) made a space, and the 160
    /// counted in UTF-16 units, as .NET counts a string's length.
    static func around(_ text: String?, fromEnd: Bool) -> String {
        var text = (text ?? "").replacingOccurrences(of: "\r\n", with: " ")
        for ending in ["\r", "\n", "\u{85}", "\u{2028}", "\u{2029}", "\u{0C}"] { text = text.replacingOccurrences(of: ending, with: " ") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let max = 160, units = Array(text.utf16), space = UInt16(32)
        if units.count <= max {
            return fromEnd ? String(text.drop(while: \.isWhitespace)) : String(text.reversed().drop(while: \.isWhitespace).reversed())
        }
        if fromEnd {
            let cut = units.suffix(max)
            if let i = cut.firstIndex(of: space) { return "…" + String(decoding: cut[(i + 1)...], as: UTF16.self) }
            return "…" + String(decoding: cut, as: UTF16.self)
        }
        let head = units.prefix(max)
        if let i = head.lastIndex(of: space), i > 0 { return String(decoding: head[..<i], as: UTF16.self) + "…" }
        return String(decoding: head, as: UTF16.self) + "…"
    }

    private static let removedColor = Color(hex: 0xE8E7E3, alpha: 0x70 / 255)
    /// The surrounding text: a cool grey-blue, apart from the edit (Windows `ContextInk`, #A69FB4D0), in italics.
    static let contextColor = Color(hex: 0x9FB4D0, alpha: 0xA6 / 255)

    var attributed: AttributedString {
        var out = AttributedString()
        for (text, style) in runs {
            var run = AttributedString(text)
            switch style {
            case .plain: run.foregroundColor = color
            case .removed:
                run.foregroundColor = Self.removedColor
                run.strikethroughStyle = .single
            case .added: run.foregroundColor = accent
            case .context:
                run.foregroundColor = Self.contextColor
                run.inlinePresentationIntent = .emphasized
            }
            out += run
        }
        return out
    }

    #if os(macOS)
    var nsAttributed: NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight
        let font = NSFont.systemFont(ofSize: size)
        let out = NSMutableAttributedString()
        for (text, style) in runs {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
            switch style {
            case .plain: attrs[.foregroundColor] = NSColor(color)
            case .removed:
                attrs[.foregroundColor] = NSColor(Self.removedColor)
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .added: attrs[.foregroundColor] = NSColor(accent)
            case .context:
                attrs[.foregroundColor] = NSColor(Self.contextColor)
                attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }
    #endif
}

/// What is selected in a box, for its COPY. The overlay never takes keyboard focus, so ⌘C can't copy; COPY does.
final class OverlayTextSelection {
    #if os(macOS)
    weak var view: NSTextView?
    #endif

    /// The selected text, or nil when nothing is selected. `dropStruck` leaves out struck-through (removed) words.
    func selected(dropStruck: Bool = false) -> String? {
        #if os(macOS)
        guard let view, let storage = view.textStorage else { return nil }
        let range = view.selectedRange()
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
        let part = storage.attributedSubstring(from: range)
        guard dropStruck else { return part.string }
        var kept = ""
        part.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 0, length: part.length)) { value, r, _ in
            if (value as? Int ?? 0) == 0 { kept += (part.string as NSString).substring(with: r) }
        }
        return kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #else
        return nil
        #endif
    }
}

#if os(macOS)
/// A box's text: selectable with the mouse (in the panel that never becomes key), scrolling past `maxHeight`.
struct OverlayText: NSViewRepresentable {
    var text: OverlayRichText
    var maxHeight: CGFloat
    var selection: OverlayTextSelection

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // Windows' box shows its light scrollbar for as long as the text overflows (VerticalScrollBarVisibility Auto).
        // WPF's classic bar in the overlay (ThemeMode None): always light, 17 wide, whatever the app's theme. (Its arrow
        // buttons have no counterpart: macOS scrollers have drawn none since 10.7.) The style is set after the scroller,
        // which comes with the system's overlay style.
        scroll.verticalScroller = ClassicScroller()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .legacy
        scroll.appearance = NSAppearance(named: .aqua)
        scroll.scrollerKnobStyle = .dark
        let view = OverlayTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.insertionPointColor = .clear
        // Windows' selection: paper at 30%.
        view.selectedTextAttributes = [.backgroundColor: NSColor(Color(hex: 0xE8E7E3, alpha: 0.3))]
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let new = text.nsAttributed
        if view.textStorage?.isEqual(to: new) != true { view.textStorage?.setAttributedString(new) }
        selection.view = view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        return CGSize(width: width, height: min(Self.height(of: text.nsAttributed, width: width), maxHeight))
    }

    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }
}

/// WPF's classic scrollbar width (SystemParameters.VerticalScrollBarWidth, 17).
private final class ClassicScroller: NSScroller {
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 17 }
}

/// Takes the first click (the panel is never key) and never drags the panel: a drag in it selects. The I-beam shows
/// over its text, as Windows' boxes (Cursor="IBeam"); pushed on hover, since the panel is never key and cursor rects
/// don't apply there.
private final class OverlayTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    private var beam = false
    private var hover: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hover { removeTrackingArea(hover) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hover = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if !beam { NSCursor.iBeam.push(); beam = true }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if beam { NSCursor.pop(); beam = false }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, beam { NSCursor.pop(); beam = false }
        super.viewWillMove(toWindow: newWindow)
    }

    /// A read-only WPF box's menu: Cut, Copy, Paste, with only Copy enabled (and only with a selection).
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // With their shortcuts shown, as WPF's items show Ctrl+X, Ctrl+C, Ctrl+V.
        for (title, action, key, on) in [("Cut", #selector(cut(_:)), "x", false), ("Copy", #selector(copy(_:)), "c", selectedRange().length > 0),
                                         ("Paste", #selector(paste(_:)), "v", false)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.isEnabled = on
            menu.addItem(item)
        }
        return menu
    }
}
#else
/// A box's text on iPhone: selectable, scrolling past `maxHeight`. COPY copies the whole box.
struct OverlayText: View {
    var text: OverlayRichText
    var maxHeight: CGFloat
    var selection: OverlayTextSelection

    var body: some View {
        let content = Text(text.attributed).font(Ob.sans(text.size)).lineSpacing(text.lineHeight - text.size * 1.2)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        HeightCap(height: maxHeight) {
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }.scrollIndicators(.automatic)
            }
        }
    }
}
#endif

extension View {
    /// The pointing hand over something clickable in the overlay, as Windows' Cursor="Hand". Pushed on hover, since the
    /// panel is never key and cursor rects don't apply there.
    func overlayHandCursor(_ on: Bool = true) -> some View {
        #if os(macOS)
        modifier(OverlayHandCursor(on: on))
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct OverlayHandCursor: ViewModifier {
    var on: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, on, !pushed { NSCursor.pointingHand.push(); pushed = true }
                else if !inside, pushed { NSCursor.pop(); pushed = false }
            }
            // Turned off under the pointer (the receipt opened): the arrow is back at once (Windows' Card.Cursor = null).
            .onChange(of: on) { _, on in if !on, pushed { NSCursor.pop(); pushed = false } }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}
#endif
