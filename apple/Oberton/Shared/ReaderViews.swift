import ObertonCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Read aloud player (ReaderWindow.xaml): ↺15 ▶ ↻15, − 1.0× +, the time left with LEFT / PAUSED / PREPARING VOICE… /
/// DONE, ⌄ and ✕; a ruler that fills as it reads; then the sentence being read (at most two lines), or, expanded, the
/// whole text, which follows the reading and reads from a clicked word. Read so far in white, the word being read in
/// the accent, the rest dimmed. It also asks before reading the clipboard, and says why a reading couldn't start.
/// An ink card in both themes, at the player's own opacity.
struct ReaderCard: View {
    @ObservedObject var player: ReadAloudPlayer
    var opacity: Double
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @State private var speeds = false
    @State private var hover = false
    @Environment(\.overlayRoom) private var room

    /// The text's width (Windows' Root); the card adds its padding.
    static let compactWidth: CGFloat = 520, expandedWidth: CGFloat = 640

    var body: some View {
        if player.isShowing {
            let expanded = model.settings.readerExpanded
            // The padding plus WPF's 1 px border, which sits outside it (16,12,12,14 inside a 1 px line).
            WidthCap(width: min((expanded ? Self.expandedWidth : Self.compactWidth) + 30, room.width)) {
                Group {
                    if let q = player.question { question(q) } else { playerView(expanded: expanded) }
                }
                .padding(EdgeInsets(top: 13, leading: 17, bottom: 15, trailing: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16).fill(darkInk.opacity(min(max(opacity, 0.3), 1))))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Self.ink.opacity(0.14), lineWidth: 1))
                // WPF's DropShadowEffect: 24 blur, 4 deep at 315°, so it falls right and down.
                .shadow(color: .black.opacity(0.35), radius: 12, x: 2.83, y: 2.83)
            }
            .onHover { hover = $0 }
            // After the end the card stays a moment (to read again or skip back), and longer while the pointer is on it.
            .task(id: player.status == .ended && player.isOpen) {
                guard player.status == .ended, player.isOpen else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled, !hover { player.stop() }
            }
        }
    }

    static let ink = Color(hex: 0xE8E7E3)
    private var accent: Color { Color(hex: ob.accentChoice.hex.dark) }

    // MARK: Player

    private func playerView(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                HStack(spacing: 8) {
                    RoundButton(size: 36, help: "Back 15 seconds") { player.skip(seconds: -15) } label: { fifteen("arrow.uturn.backward") }
                    Button { player.togglePause() } label: {
                        Image(systemName: player.status == .playing || player.status == .preparing ? "pause.fill" : "play.fill")
                            .font(.system(size: 17)).foregroundStyle(darkInk)
                            .frame(width: 44, height: 44).background(Circle().fill(Self.ink))
                    }
                    .buttonStyle(ReaderPress())
                    .help(playHelp).accessibilityLabel("Play or pause")
                    RoundButton(size: 36, help: "Forward 15 seconds") { player.skip(seconds: 15) } label: { fifteen("arrow.uturn.forward") }
                }
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    RoundButton(size: 30, help: "Slower") { setSpeed(player.speed - ReadAloudPlayer.speedStep) } label: {
                        Image(systemName: "minus").font(.system(size: 11))
                    }
                    .disabled(player.speed <= ReadAloudPlayer.minSpeed + 0.001)
                    Button { speeds.toggle() } label: {
                        Text(Self.speedText(player.speed)).font(Ob.mono(12.5)).foregroundStyle(Self.ink)
                            .frame(width: 54, height: 30)
                            .overlay(Capsule().strokeBorder(Self.ink.opacity(0.22), lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(SpeedPress())
                    .help("Choose a speed").accessibilityLabel("Choose a speed")
                    #if os(macOS)
                    .background(FloatingMenu(isPresented: $speeds) { speedGrid })
                    #else
                    .popover(isPresented: $speeds, arrowEdge: .top) { speedGrid }
                    #endif
                    RoundButton(size: 30, help: "Faster") { setSpeed(player.speed + ReadAloudPlayer.speedStep) } label: {
                        Image(systemName: "plus").font(.system(size: 11))
                    }
                    .disabled(player.speed >= ReadAloudPlayer.maxSpeed - 0.001)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Self.clock(player.secondsLeft)).font(Ob.mono(15)).foregroundStyle(Self.ink).help("Estimated time left")
                    Text(statusWord).font(Ob.mono(10)).foregroundStyle(Self.ink.opacity(0.6)).lineLimit(1)
                }
                .padding(.trailing, 12)
                HStack(spacing: 6) {
                    let help = expanded ? "Show the current sentence only" : "Show the whole text"
                    RoundButton(size: 30, help: help) { model.settings.readerExpanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 11))
                    }
                    RoundButton(size: 30, help: "Stop", name: "Stop reading") { player.stop() } label: { cross }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
            Ruler(progress: player.progress, accent: accent).frame(height: 6).padding(EdgeInsets(top: 12, leading: 2, bottom: 10, trailing: 2))
            if expanded {
                ReaderFullText(doc: player.doc, sentences: player.sentences, sentence: player.index, word: currentWord, accent: accent) {
                    player.jump(to: $0)
                }
                    .padding(.leading, 2)
            } else {
                // Every line 24 high, a one-line sentence too (LineHeight 24, MaxHeight 48).
                Text(sentenceLine).font(Ob.sans(16)).lineSpacing(Ob.lineSpacing(16, lineHeight: 24)).lineLimit(2).truncationMode(.tail)
                    .padding(.vertical, (24 - 16 * 1.2) / 2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusWord: String {
        switch player.status {
        case .ended: "DONE"
        case .paused: "PAUSED"
        case .preparing: "PREPARING VOICE…"
        case .playing: "LEFT"
        }
    }

    private var playHelp: String {
        player.status == .ended ? "Read again" : player.status == .paused ? "Play" : "Pause"
    }

    /// The − and + buttons and the speed menu: the new speed is also the speed every reading starts at.
    private func setSpeed(_ s: Double) {
        player.setSpeed(s)
        model.settings.ttsBaseSpeed = player.speed
    }

    private func fifteen(_ arrow: String) -> some View {
        VStack(spacing: 1) {
            Text("15").font(.system(size: 10, weight: .semibold)).frame(height: 11)
            // Windows' Undo/Redo hooks (E7A7/E7A6) at 12.
            Image(systemName: arrow).font(.system(size: 12))
        }
    }

    private var cross: some View {
        Path { p in
            p.move(to: CGPoint(x: 1, y: 1)); p.addLine(to: CGPoint(x: 9, y: 9))
            p.move(to: CGPoint(x: 9, y: 1)); p.addLine(to: CGPoint(x: 1, y: 9))
        }
        .stroke(Self.ink, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        .frame(width: 10, height: 10)
    }

    private var speedGrid: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SPEED").font(Ob.mono(10.5)).foregroundStyle(Self.ink.opacity(0.6)).padding(EdgeInsets(top: 0, leading: 4, bottom: 6, trailing: 0))
            // A UniformGrid of pills with Margin 3: 6 between them, 3 more to the edge and under "SPEED".
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(Self.presets[row * 4 ..< row * 4 + 4], id: \.self) { s in
                            let on = abs(s - player.speed) < 0.001
                            Button { speeds = false; setSpeed(s) } label: {
                                Text(String(format: "%g×", s)).font(Ob.mono(11.5)).foregroundStyle(on ? darkInk : Self.ink)
                                    .frame(minWidth: 56).frame(height: 30)
                                    .background(Capsule().fill(on ? Self.ink : Self.ink.opacity(0.1)))
                            }
                            .buttonStyle(PillPress())
                            .accessibilityLabel(String(format: "%g times speed", s))
                            .padding(3)
                        }
                    }
                }
            }
        }
        .padding(8)
        // Windows' popup: #F20D0D0C, a 22 % ink line, corner 10.
        .background(RoundedRectangle(cornerRadius: 10).fill(darkInk.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Self.ink.opacity(0.22), lineWidth: 1))
        .presentationBackground(darkInk.opacity(0.95))
    }

    static let presets: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 3.5, 4]

    /// "1.0×", "1.25×", "1.65×" (Windows' `{0:0.0#}×`).
    static func speedText(_ s: Double) -> String {
        let two = String(format: "%.2f", s)
        return (two.hasSuffix("0") ? String(two.dropLast()) : two) + "×"
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The word being read: the voice's word, or where reading will pick up; after the end, past the last sentence.
    private var currentWord: NSRange {
        if player.status == .ended, let last = player.sentences.last { return NSRange(location: NSMaxRange(last), length: 0) }
        if let r = player.spokenRange { return r }
        guard player.sentences.indices.contains(player.index) else { return NSRange(location: 0, length: 0) }
        let s = player.sentences[player.index]
        return NSRange(location: s.location + Int(player.fraction * Double(s.length)), length: 0)
    }

    /// Compact: the current sentence only; a long one shows a window of 150 characters around the word, with "…".
    private var sentenceLine: AttributedString {
        guard player.sentences.indices.contains(player.index) else { return AttributedString() }
        let span = player.sentences[player.index]
        let sentence = ReadAloudText.lineEndingsAsSpaces((player.text as NSString).substring(with: span)) as NSString
        let word = currentWord
        let n = sentence.length
        let wordStart = min(max(word.location - span.location, 0), n)
        let wordEnd = min(max(NSMaxRange(word) - span.location, wordStart), n)
        var from = 0, to = n
        let window = 150
        if n > window {
            from = min(max(wordStart - window / 3, 0), n - window)
            if from > 0 {
                // As Windows: no space after it means from the start (IndexOf gives −1, plus one).
                let space = sentence.range(of: " ", range: NSRange(location: from, length: n - from)).location
                from = space == NSNotFound ? 0 : space + 1
            }
            to = min(n, from + window)
        }
        let upcoming = Self.ink.opacity(0.45)
        func run(_ a: Int, _ b: Int, _ color: Color) -> AttributedString {
            guard b > a else { return AttributedString() }
            var r = AttributedString(sentence.substring(with: NSRange(location: a, length: b - a)))
            r.foregroundColor = color
            return r
        }
        var out = AttributedString()
        if from > 0 {
            var head = AttributedString("… ")
            head.foregroundColor = upcoming
            out += head
        }
        out += run(from, min(wordStart, to), Self.ink)
        out += run(max(from, wordStart), min(wordEnd, to), accent)
        out += run(max(from, wordEnd), to, upcoming)
        if to < n {
            var tail = AttributedString(" …")
            tail.foregroundColor = upcoming
            out += tail
        }
        return out
    }

    // MARK: Question

    private func question(_ q: ReaderQuestion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Text(q.title).font(Ob.sans(15, .semibold)).foregroundStyle(Self.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).padding(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 12))
                RoundButton(size: 30, help: "Close") { player.stop() } label: { cross }.accessibilityLabel("Close")
            }
            if !q.body.isEmpty {
                Text(q.body).font(Ob.sans(13.5)).foregroundStyle(Self.ink.opacity(0.7))
                    .lineSpacing(Ob.lineSpacing(13.5, lineHeight: 20)).padding(.vertical, (20 - 13.5 * 1.2) / 2)
                    .lineLimit(4).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 8, leading: 2, bottom: 0, trailing: 12))
            }
            if let progress = q.progress {
                // Downloading the voice: a 4 pt bar instead of the buttons; ✕ cancels.
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Self.ink.opacity(0x26 / 255.0))
                        Rectangle().fill(Self.ink).frame(width: g.size.width * min(1, max(0, progress ?? 0)))
                    }
                }
                .frame(height: 4).padding(EdgeInsets(top: 12, leading: 2, bottom: 0, trailing: 12))
            } else {
                questionButtons(q)
            }
        }
    }

    private func questionButtons(_ q: ReaderQuestion) -> some View {
            HStack(spacing: 8) {
                Button { q.action() } label: {
                    pill(q.primary.uppercased(), fill: Self.ink, text: darkInk, weight: .semibold)
                }
                .buttonStyle(PillPress())
                Button { player.stop() } label: { pill("CANCEL", fill: Self.ink.opacity(0.1), text: Self.ink, weight: .regular) }
                    .buttonStyle(PillPress())
            }
            .padding(.top, 14)
    }

    private func pill(_ title: String, fill: Color, text: Color, weight: Font.Weight) -> some View {
        Text(title).font(Ob.mono(11.5, weight)).foregroundStyle(text)
            .padding(.horizontal, 16).frame(height: 34).background(Capsule().fill(fill))
    }
}

/// The player's round buttons: ink at 10 % behind a light glyph; dimmed when they can't be used.
private struct RoundButton<Label: View>: View {
    var size: CGFloat
    var help: String
    /// What a screen reader calls it, when that isn't the tooltip ("Stop reading" for the ✕ "Stop").
    var name: String? = nil
    var action: () -> Void
    @ViewBuilder var label: Label
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            label.foregroundStyle(ReaderCard.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(ReaderCard.ink.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(ReaderPress())
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(name ?? help)
    }
}

/// Hover 0.8, pressed 0.6, the hand cursor, as on Windows; a disabled button doesn't react. The cursor is pushed on
/// hover, since the player's panel is never key and cursor rects don't apply there.
private struct ReaderPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration) }

    private struct Look: View {
        let configuration: Configuration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.6 : hover && enabled ? 0.8 : 1)
                .onHover { hover = $0 }
                .overlayHandCursor(enabled)
        }
    }
}

/// Windows' PillButton (READ CLIPBOARD, CANCEL, the speed choices): 0.85 under the pointer, no pressed look.
private struct PillPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration) }

    private struct Look: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .opacity(hover ? 0.85 : 1)
                .onHover { hover = $0 }
                .overlayHandCursor()
        }
    }
}

/// The speed button: a 10 % white wash under the pointer, and the hand cursor.
private struct SpeedPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration) }

    private struct Look: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(Capsule().fill(Color.white.opacity(hover ? 0.1 : 0)))
                .onHover { hover = $0 }
                .overlayHandCursor()
        }
    }
}

#if os(macOS)
/// Windows' speed Popup: a flat panel 6 pt above its button that fades in, never takes the keyboard focus from the app
/// being read (a SwiftUI popover is a window that can), moves with the player, and closes on any click elsewhere.
private struct FloatingMenu<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ anchor: NSView, context: Context) {
        let c = context.coordinator
        c.close = { isPresented = false }
        if isPresented { c.show(AnyView(content), above: anchor) } else { c.hide() }
    }

    static func dismantleNSView(_ anchor: NSView, coordinator: Coordinator) { coordinator.hide() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var close: () -> Void = {}
        private var panel: NSPanel?
        private var monitors: [Any] = []

        func show(_ content: AnyView, above anchor: NSView) {
            guard let parent = anchor.window else { return }
            let host = NSHostingView(rootView: content.fixedSize())
            let size = host.fittingSize
            let panel = self.panel ?? {
                let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
                p.isOpaque = false
                p.backgroundColor = .clear
                p.hasShadow = false
                p.becomesKeyOnlyIfNeeded = true
                p.allowsToolTipsWhenApplicationIsInactive = true
                p.level = parent.level
                return p
            }()
            panel.contentView = host
            // WPF's Placement="Top": the menu's left edge on the button's, 6 above it; below it when there is no room
            // above, and kept on the screen.
            let button = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
            var frame = CGRect(x: button.minX.rounded(), y: button.maxY + 6, width: size.width, height: size.height)
            if frame.maxY > screen.maxY { frame.origin.y = button.minY - 6 - size.height }
            frame.origin.x = max(screen.minX, min(frame.origin.x, screen.maxX - size.width))
            panel.setFrame(frame, display: true)
            if self.panel == nil {
                self.panel = panel
                panel.alphaValue = 0
                parent.addChildWindow(panel, ordered: .above)
                NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
                // A click anywhere but on the menu closes it (the button's own click toggles it).
                let outside: (NSEvent) -> Void = { [weak self, weak anchor] e in
                    guard let self, e.window !== self.panel else { return }
                    if e.window === parent, let anchor, anchor.bounds.contains(anchor.convert(e.locationInWindow, from: nil)) { return }
                    DispatchQueue.main.async { self.close() }
                }
                if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: outside) { monitors.append(m) }
                if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { outside($0); return $0 }) { monitors.append(m) }
            } else {
                panel.orderFront(nil)
            }
        }

        func hide() {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
        }
    }
}
#endif

/// Progress through the whole text: a ruler (a tick every 8 pt over a hairline), filled in the accent as it reads.
private struct Ruler: View {
    var progress: Double
    var accent: Color

    var body: some View {
        Canvas { ctx, size in
            let faint = ReaderCard.ink.opacity(0.25)
            var x: CGFloat = 0
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(faint))
                x += 8
            }
            ctx.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(faint))
            ctx.fill(Path(CGRect(x: 0, y: size.height - 2, width: size.width * min(max(progress, 0), 1), height: 2)), with: .color(accent))
        }
    }
}

// MARK: Whole text

#if os(macOS)
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

/// Expanded: the whole text, at most 380 high. Read so far in white, the word being read in the accent, the rest dimmed.
/// It keeps the word in view (a third of the way down, only when it nears an edge), except for 5 s after the user
/// scrolls; a click on a word reads from there. TextKit, for the click's character and the word's place.
struct ReaderFullText {
    var doc: MarkdownDoc
    /// The reading's sentences and the one being read: those before it are white, text between sentences stays dim.
    var sentences: [NSRange] = []
    var sentence = 0
    var word: NSRange
    var accent: Color
    var onClick: (Int) -> Void

    static let maxHeight: CGFloat = 380
    nonisolated(unsafe) static var userScrolledAt = Date.distantPast
    static let followPause: TimeInterval = 5
    private static let dim = ReaderCard.ink.opacity(0.45)

    final class Coordinator: NSObject {
        var shown: MarkdownDoc?
        /// When the user last scrolled the text: kept by the one player (Windows' ReaderWindow), so closing the card,
        /// a new reading or switching the view doesn't forget it.
        var userScrolledAt: Date {
            get { ReaderFullText.userScrolledAt }
            set { ReaderFullText.userScrolledAt = newValue }
        }
        /// The follow is scrolling (that isn't the user's).
        var following = false
        var onClick: (Int) -> Void = { _ in }
        var display = ReaderDisplay(doc: MarkdownDoc.parse(""))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    var text: String { doc.plain }

    /// Colour the sentences read so far white, the current one white up to the word, the word in the accent, and
    /// the rest dimmed; bullets, quote bars and text between sentences (rules, wordless lines) stay dimmed, as on
    /// Windows, where only sentence spans change colour.
    func paint(_ storage: NSTextStorage, _ display: ReaderDisplay) {
        let n = storage.length
        let start = min(display.toDisplay(word.location), n), end = min(max(start, display.toDisplay(NSMaxRange(word))), n)
        func shown(_ r: NSRange) -> NSRange {
            let a = min(display.toDisplay(r.location), n)
            return NSRange(location: a, length: max(0, min(display.toDisplay(NSMaxRange(r)), n) - a))
        }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: PlatformColor(Self.dim), range: NSRange(location: 0, length: n))
        for (i, r) in sentences.enumerated() where i < sentence {
            storage.addAttribute(.foregroundColor, value: PlatformColor(ReaderCard.ink), range: shown(r))
        }
        if sentences.indices.contains(sentence) {
            let s = shown(sentences[sentence])
            let spoken = NSRange(location: s.location, length: max(0, min(start, NSMaxRange(s)) - s.location))
            storage.addAttribute(.foregroundColor, value: PlatformColor(ReaderCard.ink), range: spoken)
        } else if sentences.isEmpty {
            storage.addAttribute(.foregroundColor, value: PlatformColor(ReaderCard.ink), range: NSRange(location: 0, length: start))
        }
        storage.addAttribute(.foregroundColor, value: PlatformColor(accent), range: NSRange(location: start, length: end - start))
        for r in display.prefixes { storage.addAttribute(.foregroundColor, value: PlatformColor(Self.dim), range: r) }
        storage.endEditing()
    }

    func height(width: CGFloat, _ display: ReaderDisplay) -> CGFloat {
        let r = display.attributed.boundingRect(with: CGSize(width: max(width - 12, 10), height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return min(Self.maxHeight, ceil(r.height) + 4)
    }

    /// Where the word is, in the text view's coordinates.
    func wordRect(_ layout: NSLayoutManager, _ container: NSTextContainer, _ display: ReaderDisplay) -> CGRect? {
        guard layout.numberOfGlyphs > 0 else { return nil }
        let start = display.toDisplay(word.location)
        let at = NSRange(location: min(start, max(0, display.attributed.length - 1)), length: max(1, display.toDisplay(NSMaxRange(word)) - start))
        let glyphs = layout.glyphRange(forCharacterRange: at, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container)
    }

    /// The vertical offset that brings the word a third of the way down, or nil if it is well inside the view.
    func followOffset(rect: CGRect, visible: CGRect, content: CGFloat) -> CGFloat? {
        let y = rect.minY - visible.minY
        if y >= 8, y + rect.height <= visible.height - 28 { return nil }
        return max(0, min(rect.minY - visible.height / 3, content - visible.height))
    }
}

/// The reading's plain text laid out with its Markdown as formatting (Windows' ReaderWindow.BuildFull): headings
/// larger with room above, "  •  " bullets and indented numbers, "▍ " quotes in italics, code in mono, bold, italic,
/// underlined links. The bullets and bars are extra characters, so positions are mapped between the plain text (what
/// the voice reads) and the shown text.
struct ReaderDisplay {
    let attributed: NSAttributedString
    /// The added characters (bullets, bars), kept dimmed.
    let prefixes: [NSRange]
    /// Per line: where it starts in the plain text, and how far the shown text has moved by then.
    private let starts: [(plain: Int, delta: Int, shown: Int)]

    init(doc: MarkdownDoc) {
        let out = NSMutableAttributedString()
        var prefixes: [NSRange] = []
        var starts: [(Int, Int, Int)] = []
        let plain = doc.plain as NSString
        var delta = 0
        for (i, line) in doc.lines.enumerated() {
            let prefix: String = switch line.kind {
            case .bullet: String(repeating: " ", count: 4 * line.level) + "  •  "
            case .numbered: String(repeating: " ", count: 4 * line.level) + "  "
            case .quote: "▍ "
            default: ""
            }
            let size: CGFloat = line.kind == .heading ? (line.level == 1 ? 21 : line.level == 2 ? 18.5 : line.level == 3 ? 16.5 : 15.5) : 15
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = max(23, (size * 1.35).rounded())
            p.maximumLineHeight = p.minimumLineHeight
            // Room above a heading: Windows adds an empty line (23 high).
            if line.kind == .heading, i > 0, doc.lines[i - 1].length > 0 { p.paragraphSpacingBefore = 23 }
            let base: [NSAttributedString.Key: Any] = [.font: PlatformFont.systemFont(ofSize: 15), .paragraphStyle: p]
            let lineShown = out.length
            if !prefix.isEmpty {
                prefixes.append(NSRange(location: out.length, length: (prefix as NSString).length))
                out.append(NSAttributedString(string: prefix, attributes: base))
                delta += (prefix as NSString).length
            }
            starts.append((line.start, delta, lineShown))
            // The line's text, split wherever the inline style changes.
            var at = line.start
            let end = line.start + line.length
            while at < end {
                let style = doc.styleAt(at)
                var j = at + 1
                while j < end, doc.styleAt(j) == style { j += 1 }
                var a = base
                // Inline code keeps the line's size (15, or the heading's) in mono; bold on a code line stays mono.
                let isMono = line.kind == .code || style.contains(.code)
                let monoSize = line.kind == .code ? 13.5 : size
                let weight: PlatformFont.Weight = style.contains(.bold) ? .bold : line.kind == .heading ? .semibold : .regular
                var font: PlatformFont = isMono ? Ob.monoFont(monoSize, weight) : .systemFont(ofSize: size, weight: weight)
                if style.contains(.code) { a[.backgroundColor] = PlatformColor(white: 1, alpha: 0x1F / 255.0) }
                if line.kind == .quote || style.contains(.italic) { font = Self.italic(font) }
                // WPF's strike replaces a link's underline rather than adding to it.
                if style.contains(.strike) { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                else if style.contains(.link) { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                a[.font] = font
                out.append(NSAttributedString(string: plain.substring(with: NSRange(location: at, length: j - at)), attributes: a))
                at = j
            }
            if i < doc.lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        attributed = out
        self.prefixes = prefixes
        self.starts = starts
    }

    /// A position of the plain text in the shown text.
    func toDisplay(_ plain: Int) -> Int {
        guard let line = starts.last(where: { $0.plain <= plain }) else { return plain }
        return plain + line.delta
    }

    /// A position of the shown text is a bullet, number indent or quote bar.
    func isPrefix(_ shown: Int) -> Bool { prefixes.contains { NSLocationInRange(shown, $0) } }

    /// A position of the shown text (a click) in the plain text; a click on a bullet is the start of its line.
    func toPlain(_ shown: Int) -> Int {
        guard let line = starts.last(where: { $0.shown <= shown }) ?? starts.first else { return shown }
        return max(line.plain, shown - line.delta)
    }

    /// The font's italic, or, for a font without one (the bundled Cascadia Mono), the upright face slanted, as WPF
    /// draws an italic it has no face for.
    static func italic(_ f: PlatformFont) -> PlatformFont {
        #if os(macOS)
        if let i = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic)), size: f.pointSize),
           i.fontDescriptor.symbolicTraits.contains(.italic), i.familyName == f.familyName { return i }
        return NSFont(descriptor: f.fontDescriptor.withMatrix(AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)), size: f.pointSize) ?? f
        #else
        if let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            let i = UIFont(descriptor: d, size: f.pointSize)
            if i.fontDescriptor.symbolicTraits.contains(.traitItalic), i.familyName == f.familyName { return i }
        }
        return UIFont(descriptor: f.fontDescriptor.withMatrix(CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)), size: f.pointSize)
        #endif
    }
}

#if os(macOS)
extension ReaderFullText: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let textView = ClickTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.toolTip = "Click a word to read from there"
        let coordinator = context.coordinator
        // Any click on the text follows the reading again at once, even one that misses the words (as Windows).
        textView.onPress = { coordinator.userScrolledAt = .distantPast }
        textView.onClick = { coordinator.onClick($0) }
        let scroll = FollowScrollView()
        // Any scroll that isn't the follow's (wheel, bar, arrows, page clicks) pauses the follow.
        scroll.onUserScroll = { if !coordinator.following { coordinator.userScrolledAt = Date() } }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        // A scroll bar whenever the text overflows, as WPF's Auto.
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .legacy
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 12)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, let storage = textView.textStorage,
              let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let coordinator = context.coordinator
        if coordinator.shown != doc {
            coordinator.shown = doc
            coordinator.display = ReaderDisplay(doc: doc)
            storage.setAttributedString(coordinator.display.attributed)
            coordinator.following = true
            scroll.contentView.scroll(to: .zero)
            coordinator.following = false
        }
        let display = coordinator.display
        // Only a click on a sentence's words reads from there; bullets and numbers don't count.
        coordinator.onClick = { at in if !display.isPrefix(at) { onClick(display.toPlain(at)) } }
        paint(storage, display)
        DispatchQueue.main.async {
            guard Date().timeIntervalSince(coordinator.userScrolledAt) >= Self.followPause,
                  let rect = wordRect(layout, container, display) else { return }
            let visible = scroll.contentView.bounds
            guard let y = followOffset(rect: rect, visible: visible, content: textView.frame.height) else { return }
            coordinator.following = true
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            coordinator.following = false
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? ReaderCard.expandedWidth - 30
        return CGSize(width: width, height: height(width: width, context.coordinator.shown == doc ? context.coordinator.display : ReaderDisplay(doc: doc)))
    }

    /// Reports the user's own scrolling (wheel, trackpad, scroll bar, keys), not the follow's, and not the text being
    /// rebuilt or resized (Windows ignores a scroll that comes with an extent or viewport change).
    final class FollowScrollView: NSScrollView {
        var onUserScroll: () -> Void = {}
        private var last = (y: CGFloat(0), viewport: CGFloat(0), extent: CGFloat(0))
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
            remember()
        }
        @objc private func scrolled() {
            let before = last
            remember()
            guard last.y != before.y, last.viewport == before.viewport, last.extent == before.extent else { return }
            onUserScroll()
        }
        private func remember() {
            last = (contentView.bounds.origin.y, contentView.bounds.height, documentView?.frame.height ?? 0)
        }
    }

    /// A click reads from the word under the pointer.
    final class ClickTextView: NSTextView {
        var onClick: (Int) -> Void = { _ in }
        var onPress: () -> Void = {}
        private var pushed = false
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(visibleRect, cursor: .pointingHand) }
        // The hand while another app is active too: the panel is never key, so cursor rects alone don't show it.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.filter { $0.owner === self && $0.userInfo?["hand"] != nil }.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: ["hand": true]))
        }
        override func mouseEntered(with event: NSEvent) {
            if !pushed { NSCursor.pointingHand.push(); pushed = true }
        }
        override func mouseExited(with event: NSEvent) {
            if pushed { NSCursor.pop(); pushed = false }
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, pushed { NSCursor.pop(); pushed = false }
            super.viewWillMove(toWindow: newWindow)
        }
        override func mouseDown(with event: NSEvent) {
            // The player can be dragged by its text too (Windows' WindowDrag): a press that moves drags the panel; one
            // that doesn't is a click on a word.
            guard let window else { return }
            let start = event.locationInWindow
            while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                if next.type == .leftMouseUp { break }
                // Windows' system drag distance: 4 either way.
                if abs(next.locationInWindow.x - start.x) >= 4 || abs(next.locationInWindow.y - start.y) >= 4 {
                    window.performDrag(with: event)
                    return
                }
            }
            onPress()
            guard let layout = layoutManager, let container = textContainer else { return }
            var point = convert(event.locationInWindow, from: nil)
            point.x -= textContainerOrigin.x
            point.y -= textContainerOrigin.y
            // Only a click on a character counts (GetPositionFromPoint with snapToText false).
            let glyph = layout.glyphIndex(for: point, in: container)
            guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point)
            else { return }
            onClick(layout.characterIndexForGlyph(at: glyph))
        }
    }
}
#else
extension ReaderFullText: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 4, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        let coordinator = context.coordinator
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        textView.addGestureRecognizer(tap)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.shown != doc {
            coordinator.shown = doc
            coordinator.display = ReaderDisplay(doc: doc)
            textView.attributedText = coordinator.display.attributed
            textView.setContentOffset(.zero, animated: false)
        }
        let display = coordinator.display
        coordinator.onClick = { at in if !display.isPrefix(at) { onClick(display.toPlain(at)) } }
        paint(textView.textStorage, display)
        DispatchQueue.main.async {
            guard Date().timeIntervalSince(coordinator.userScrolledAt) >= Self.followPause,
                  var rect = wordRect(textView.layoutManager, textView.textContainer, display) else { return }
            rect.origin.y += textView.textContainerInset.top
            let visible = CGRect(origin: textView.contentOffset, size: textView.bounds.size)
            guard let y = followOffset(rect: rect, visible: visible, content: textView.contentSize.height) else { return }
            textView.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 340
        return CGSize(width: width, height: height(width: width, context.coordinator.shown == doc ? context.coordinator.display : ReaderDisplay(doc: doc)))
    }
}

extension ReaderFullText.Coordinator: UITextViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { userScrolledAt = Date() }

    @objc func tapped(_ tap: UITapGestureRecognizer) {
        guard let textView = tap.view as? UITextView else { return }
        var point = tap.location(in: textView)
        point.x -= textView.textContainerInset.left
        point.y -= textView.textContainerInset.top
        let layout = textView.layoutManager
        let glyph = layout.glyphIndex(for: point, in: textView.textContainer)
        userScrolledAt = .distantPast
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textView.textContainer)
            .insetBy(dx: -4, dy: -6).contains(point) else { return }
        onClick(layout.characterIndexForGlyph(at: glyph))
    }
}
#endif

// MARK: Settings

/// Where the player sits and how solid it is, on Settings › Layout and the Read aloud page: "Same place as the dictation
/// overlay", or a place of its own on the 3×3 picker (dimmed and fixed while it follows the overlay).
struct ReaderPositionPicker: View {
    @EnvironmentObject var model: AppModel
    /// The Read aloud page draws the miniature screen as a rounded Border on Window (radius 8); Layout as ink.
    var stroke: Color? = nil
    var fill: Color? = nil
    var radius: CGFloat = 2
    /// The grid's name: "Player position" on the Read aloud page, "Read aloud player position" in Settings › Layout.
    var name = "Player position"

    var body: some View {
        PositionPicker(position: Binding(get: { place }, set: { model.settings.readerPosition = .at($0) }),
                       name: name, describe: Self.describe, radius: radius, stroke: stroke, fill: fill)
            .disabled(samePlace)
            .opacity(samePlace ? 0.45 : 1)
    }

    var samePlace: Bool { model.settings.readerPosition == .withOverlay }

    var place: OverlayPosition {
        if case .at(let p) = model.settings.readerPosition { return p }
        return model.settings.overlayPosition
    }

    /// "Same place as the dictation overlay": off keeps the place it had (the overlay's).
    static func samePlaceBinding(_ model: AppModel) -> Binding<Bool> {
        Binding(get: { model.settings.readerPosition == .withOverlay },
                set: { model.settings.readerPosition = $0 ? .withOverlay : .at(model.settings.overlayPosition) })
    }

    static func placeName(_ s: AppSettings) -> String {
        if case .at(let p) = s.readerPosition { return Self.describe(p) }
        return Self.describe(s.overlayPosition)
    }

    /// Windows' names: "Center of the screen", "Bottom left"…
    static func describe(_ p: OverlayPosition) -> String { p == .center ? "Center of the screen" : p.title }
}

/// Settings › Layout's live preview of the player over placeholder text: a sentence with the word being read in the
/// accent, a play button, the track and "1.0×", at the player's opacity.
struct ReaderPreview: View {
    var opacity: Double
    @Environment(\.ob) private var ob

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 3).fill(ob.muted).frame(width: 120, height: 7)
                ForEach([0, 30, 10, 50] as [CGFloat], id: \.self) { trailing in
                    // Windows' Ob.Track lines (the muted tone).
                    RoundedRectangle(cornerRadius: 2).fill(ob.muted).frame(height: 5).padding(.trailing, trailing).padding(.top, trailing == 0 ? 12 : 8)
                }
            }
            .padding(EdgeInsets(top: 22, leading: 20, bottom: 0, trailing: 20))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 8) {
                (Text("Select any text and press the shortcut ").foregroundStyle(ReaderCard.ink)
                 + Text("to").foregroundStyle(Color(hex: ob.accentChoice.hex.dark))
                 + Text(" hear it read aloud.").foregroundStyle(ReaderCard.ink.opacity(0.45)))
                    .font(Ob.sans(12))
                    // TextBlock MaxWidth 220: only as wide as its longest line.
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(CapWidth(width: 220))
                HStack(spacing: 10) {
                    // Windows' sharp triangle, M 8,6 L 16,11 L 8,16.
                    Path { p in p.move(to: CGPoint(x: 8, y: 6)); p.addLine(to: CGPoint(x: 16, y: 11)); p.addLine(to: CGPoint(x: 8, y: 16)); p.closeSubpath() }
                        .fill(darkInk).frame(width: 22, height: 22).background(Circle().fill(ReaderCard.ink))
                    Rectangle().fill(ReaderCard.ink.opacity(0.22)).frame(width: 120, height: 1)
                    Text("1.0×").font(Ob.mono(11)).foregroundStyle(ReaderCard.ink.opacity(0.72))
                }
            }
            // Padding 14,10 inside WPF's 1 px border.
            .padding(EdgeInsets(top: 11, leading: 15, bottom: 11, trailing: 15))
            .background(RoundedRectangle(cornerRadius: 16).fill(darkInk.opacity(opacity)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .padding(EdgeInsets(top: 0, leading: 20, bottom: 18, trailing: 20))
        }
        .clipped()
        .background(ob.subtle)
    }
}

/// At most `width` wide, and no wider than the content needs (WPF's MaxWidth on a TextBlock).
private struct CapWidth: ViewModifier {
    var width: CGFloat
    func body(content: Content) -> some View { WidthCap(width: width) { content } }
}
