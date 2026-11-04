#if os(macOS)
import AppKit
import Combine
import ObertonCore
import SwiftUI

/// The Read aloud player's own floating panel (ReaderWindow): always on top, on every Space, never takes focus from the
/// app being read. It sits at the player's position (Settings › Layout › READ ALOUD PLAYER, or with the dictation
/// overlay) at its own opacity, on the primary screen as Windows' work area, and is shown while it reads or asks. It
/// can be dragged by any part that isn't a button; the spot is kept (same centre, and in the lower half of the primary
/// screen the same bottom edge, so it grows upwards) until Oberton quits or a position is picked (App.PreviewOverlay).
@MainActor
final class ReaderController {
    private let panel: NSPanel
    private let host: NSHostingView<AnyView>
    private let model: AppModel
    private var bag: Set<AnyCancellable> = []
    private var contentSize: CGSize?
    private var room: CGSize?
    /// Where it was dragged: the centre's x, and the bottom (lower half) or top edge's y.
    private var anchor: (x: CGFloat, y: CGFloat, fromBottom: Bool)?
    private var placing = false
    static let margin: CGFloat = 8
    static let padding: CGFloat = 16

    init(model: AppModel) {
        self.model = model
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["OBERTON_READER_SNAPSHOT"] { ReaderSnapshots.write(to: dir, model: model) }
        #endif
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 160),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        // Its tooltips ("Estimated time left", "Stop"…) show while the app being read is in front, as on Windows.
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.isMovableByWindowBackground = true
        panel.title = "Oberton read aloud"
        host = NSHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        panel.contentView = host

        model.reader.$isOpen.combineLatest(model.reader.$question.map { $0 != nil })
            .map { $0 || $1 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] showing in self?.update(visible: showing) }
            .store(in: &bag)
        // A position picked (overlay or player) or the Read aloud page's "Same place" switch forgets where it was dragged
        // (App.PreviewOverlay → ReaderWindow.ResetPosition); the Layout page's switch doesn't. Then it moves there now.
        NotificationCenter.default.publisher(for: ReaderPositionPicker.previewOverlay)
            .sink { [weak self] _ in self?.anchor = nil }
            .store(in: &bag)
        // Any change of position moves a player that wasn't dragged.
        model.$settings.map { [$0.overlayPosition.rawValue, Self.key($0.readerPosition)] }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { if self?.panel.isVisible == true { self?.layout() } }
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .sink { [weak self] _ in self?.remember() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in if self?.panel.isVisible == true { self?.layout() } }
            .store(in: &bag)
    }

    private static func key(_ p: ReaderPosition) -> String {
        if case .at(let o) = p { return o.rawValue }
        return "withOverlay"
    }

    /// The primary screen's (the menu bar's) visible part: Windows places it in SystemParameters.WorkArea, the primary
    /// monitor's, wherever it is shown.
    private var screen: CGRect? { (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame }

    private func update(visible: Bool) {
        guard visible else { panel.orderOut(nil); return }
        layout()
        panel.orderFrontRegardless()
    }

    private func layout() {
        guard let screen else { return }
        let inset = 2 * (Self.margin + Self.padding)
        let room = CGSize(width: screen.width - inset, height: screen.height - inset)
        if room != self.room {
            self.room = room
            host.rootView = AnyView(ReaderPanelView { [weak self] in self?.fit($0) }
                .environmentObject(model).environment(\.overlayRoom, room))
        }
        let size = contentSize ?? host.fittingSize
        placing = true
        panel.setFrame(frame(size: size, screen: screen), display: true)
        placing = false
    }

    private func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        DispatchQueue.main.async { [weak self] in self?.layout() }
    }

    /// At the chosen corner or edge of the screen, or where it was dragged; always inside the screen.
    private func frame(size: CGSize, screen: CGRect) -> CGRect {
        let s = model.settings
        let position: OverlayPosition = if case .at(let p) = s.readerPosition { p } else { s.overlayPosition }
        let i = OverlayPosition.allCases.firstIndex(of: position) ?? 2
        let (col, row) = (i % 3, i / 3)
        var x: CGFloat, y: CGFloat
        if let anchor {
            x = anchor.x - size.width / 2
            y = anchor.fromBottom ? anchor.y : anchor.y - size.height
        } else {
            // The panel's padding is its own margin from the screen's edge, as on Windows (8 pt + the card's 16).
            x = [screen.minX + Self.margin, screen.midX - size.width / 2, screen.maxX - size.width - Self.margin][col]
            y = [screen.maxY - size.height - Self.margin, screen.midY - size.height / 2, screen.minY + Self.margin][row]
        }
        // Once dragged, kept on the desktop (all screens) as it grows, as Windows' WindowDrag.Place.
        if anchor != nil {
            let bounds = NSScreen.screens.reduce(screen) { $0.union($1.frame) }
            x = max(bounds.minX, min(x, bounds.maxX - size.width))
            y = min(bounds.maxY - size.height, max(y, bounds.minY))
        }
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }

    /// The user dragged it: keep the spot; "lower half" is of the primary screen (WindowDrag.Remember's WorkArea).
    private func remember() {
        guard !placing, panel.isVisible, let screen else { return }
        let f = panel.frame
        let fromBottom = f.midY < screen.midY
        anchor = (f.midX, fromBottom ? f.minY : f.maxY, fromBottom)
    }
}

#if DEBUG
/// Draws the player in its states to PNGs and quits (OBERTON_READER_SNAPSHOT=<folder>).
@MainActor
enum ReaderSnapshots {
    static func write(to dir: String, model: AppModel) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let player = model.reader
        let md = """
        ## Getting started

        Oberton reads any text you select, in the voice you picked under Read aloud. Press the shortcut again to stop.
        - **Fast** and _simple_: the my_file_name stays as it is, and so do #1 and 5*3.
        - See [the guide](https://example.com/guide) for more.

        1. Select some text in any app.
        2. Press the shortcut. The player opens at its own place on the screen, and follows the words as they are read. You can click any word to read from there, or skip back and forth by fifteen seconds at a time.
        """
        let long = "This is a very long sentence that goes on and on, with clause after clause, so that the compact view has to show a window around the word being read rather than the whole thing, and it keeps going for a while longer still, past where any player could show it on two lines."
        func askOnly(_ voice: String) {
            if VoiceCatalog.isInstalled(voice) { player.showMessage("(\(voice) is downloaded in this data folder)") }
            else { player.read(md, voice: voice, speed: 1) }
        }
        let shots: [(String, () -> Void, Bool)] = [
            ("reader-playing", { player.showForSnapshot(md, word: "text", status: .playing) }, false),
            ("reader-paused", { player.showForSnapshot(md, word: "shortcut", status: .paused, speed: 1.25) }, false),
            ("reader-preparing", { player.showForSnapshot(md, word: "Getting", status: .preparing) }, false),
            ("reader-done", { player.showForSnapshot(md, word: nil, status: .ended) }, false),
            ("reader-long-sentence", { player.showForSnapshot(long, word: "whole", status: .playing, speed: 1.65) }, false),
            ("reader-expanded", { player.showForSnapshot(md, word: "Press", status: .playing) }, true),
            // Longer than the 380 the whole text may take: WPF's classic scroll bar at the edge.
            ("reader-expanded-scroll", { player.showForSnapshot(md + "\n\n" + md + "\n\n" + md, word: "Press", status: .playing) }, true),
            ("reader-clipboard", { player.askToReadClipboard(md, voice: nil, speed: 1) }, false),
            ("reader-nothing", { player.read("--- * * *", voice: VoiceCatalog.systemVoices().first?.id, speed: 1) }, false),
            // Only when the voice isn't here (otherwise this would really read aloud).
            ("reader-download-kokoro", { askOnly("af_heart") }, false),
            ("reader-download-piper", { askOnly("piper:en_US-ryan-high") }, false),
            ("reader-downloading", { player.showDownloadForSnapshot(VoiceProgress(step: 2, totalSteps: 3, title: "Downloading the voice model", fraction: 0.42, detail: "About 325 MB")) }, false),
            ("reader-clipboard-expanded", { player.askToReadClipboard(md, voice: nil, speed: 1) }, true),
            ("reader-select-notice", { player.showMessage("Select some text, then press \(model.settings.speakHotkey) to hear it read aloud.") }, false),
        ]
        for (name, setUp, expanded) in shots {
            setUp()
            model.settings.readerExpanded = expanded
            let content = ReaderCard(player: player, opacity: model.settings.readerOpacity)
                .padding(ReaderController.padding).fixedSize()
                .background(Color(hex: 0xC9C7C1)).environmentObject(model).obertonTheme(model.settings)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2)) // the text view paints after the first pass
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
                print("\(name).png \(Int(host.bounds.width))×\(Int(host.bounds.height))")
            }
        }
        // Settings › Models › READ ALOUD VOICE and a profile's voice pickers, which the page snapshots cut off.
        for (name, dark) in [("models-voices-light", false), ("models-voices-dark", true)] {
            var settings = model.settings
            settings.theme = dark ? .dark : .light
            let content = VStack(alignment: .leading, spacing: 16) {
                ReadAloudVoiceRows()
                ProfileVoicePicker(voice: .constant("piper:en_US-amy-medium"))
            }
            .padding(24).frame(width: 760).environmentObject(model).obertonTheme(settings)
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
                print("\(name).png")
            }
        }
        exit(0)
    }
}
#endif

/// The player at its own opacity, sized to what it shows.
struct ReaderPanelView: View {
    var onSize: (CGSize) -> Void = { _ in }
    @EnvironmentObject var model: AppModel

    var body: some View {
        ReaderCard(player: model.reader, opacity: model.settings.readerOpacity)
            .padding(ReaderController.padding)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .obertonTheme(model.settings)
    }
}
#endif
