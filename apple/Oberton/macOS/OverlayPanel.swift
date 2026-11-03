#if os(macOS)
import AppKit
import Combine
import ObertonCore
import SwiftUI

/// The pill: always on top, on every Space and over full-screen apps, and never takes focus from the app being
/// dictated into. Shown while dictating or reading aloud.
///
/// The panel is exactly as big as what it shows (plus room for the shadows): SwiftUI reports the content's size, and
/// the panel is resized around it, anchored at the chosen corner or edge and clamped into the screen's visible area.
/// A fixed large window can't do that: content bigger than it is clipped, and its empty parts sit over other apps.
@MainActor
final class OverlayController {
    private let panel: NSPanel
    private let host: NSHostingView<AnyView>
    private let model: AppModel
    private var bag: Set<AnyCancellable> = []
    private var contentSize: CGSize?
    private var room: CGSize?
    static let margin: CGFloat = 8
    static let padding: CGFloat = 16

    init(model: AppModel) {
        self.model = model
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["OBERTON_OVERLAY_SNAPSHOT"] { OverlaySnapshots.write(to: dir, model: model) }
        #endif
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        host = NSHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        panel.contentView = host

        model.$phase.combineLatest(model.reader.$isSpeaking, model.$settings)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, speaking, settings in self?.update(visible: settings.showOverlay && (phase != .idle || speaking), settings: settings) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in if self?.panel.isVisible == true { self?.layout(fresh: false) } }
            .store(in: &bag)
    }

    private var screen: CGRect? { (panel.isVisible ? panel.screen : nil)?.visibleFrame ?? NSScreen.main?.visibleFrame }

    private func update(visible: Bool, settings: AppSettings) {
        guard visible else { panel.orderOut(nil); return }
        if !panel.isVisible { layout(fresh: true) }
        panel.orderFrontRegardless()
    }

    /// Hands the content the room the screen has, then sizes and places the panel. `fresh` places it at the chosen
    /// position; otherwise it keeps its corner or edge where it is now (it may have been dragged) and stays on screen.
    private func layout(fresh: Bool) {
        guard let screen else { return }
        let inset = 2 * (Self.margin + Self.padding)
        let room = CGSize(width: screen.width - inset, height: screen.height - inset)
        if room != self.room {
            self.room = room
            host.rootView = AnyView(OverlayView { [weak self] in self?.fit($0) }
                .environmentObject(model).environment(\.overlayRoom, room))
        }
        let size = contentSize ?? host.fittingSize
        panel.setFrame(Self.frame(size: size, position: model.settings.overlayPosition, screen: screen,
                                  current: fresh ? nil : panel.frame), display: true)
    }

    private func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        // Not in the middle of SwiftUI's layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            layout(fresh: !panel.isVisible)
        }
    }

    /// Where a panel of `size` goes: anchored at the position's corner or edge of the screen (or, when `current` is
    /// given, of the panel's current frame), then kept inside the screen; if it can't fit, its top-left stays on screen.
    static func frame(size: CGSize, position: OverlayPosition, screen: CGRect, current: CGRect? = nil) -> CGRect {
        let i = OverlayPosition.allCases.firstIndex(of: position) ?? 7
        let (col, row) = (i % 3, i / 3)
        let m = current == nil ? margin : 0
        let box = current ?? screen
        var x = [box.minX + m, box.midX - size.width / 2, box.maxX - size.width - m][col]
        var y = [box.maxY - size.height - m, box.midY - size.height / 2, box.minY + m][row]
        x = max(screen.minX + margin, min(x, screen.maxX - margin - size.width))
        y = min(screen.maxY - margin - size.height, max(y, screen.minY + margin))
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }
}

#if DEBUG
/// Draws the pill in its states to PNGs, checks the panel's frame at all nine positions, and quits
/// (OBERTON_OVERLAY_SNAPSHOT=<folder>).
@MainActor
enum OverlaySnapshots {
    static func write(to dir: String, model: AppModel) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let room = CGSize(width: 1512 - 48, height: 945 - 48)
        let error = "Copied to the clipboard. To paste at the cursor, allow Oberton in System Settings › Privacy & Security › Accessibility."
        let opacity = model.settings.overlayOpacity
        let entry = HistoryEntry(transcription: "um so the plan for friday is we ship the beta to the uh first ten testers and then we collect feedback",
                                 aiEdit: "The plan for Friday is to ship the beta to the first ten testers, and then collect feedback.",
                                 inserted: "The plan for Friday is to ship the beta to the first ten testers, and then collect feedback.",
                                 profileName: "Light Cleanup", model: nil, appName: "Microsoft Outlook (Work Account)", seconds: 14,
                                 turnaroundSeconds: 1.2, warning: error)
        let long = String(repeating: "and then we collect feedback from all of them over the following week, ", count: 30)
        let shots: [(String, CGSize, AnyView)] = [
            ("pill-recording", room, AnyView(PillContent(phase: .recording, profile: "Light Cleanup", startedAt: .now, opacity: opacity))),
            ("pill-short", room, AnyView(PillContent(phase: .done("Inserted into Mail"), profile: "", opacity: opacity))),
            ("pill-transcribing", room, AnyView(PillContent(phase: .transcribing, profile: "", opacity: opacity))),
            ("pill-accessibility", room, AnyView(PillContent(phase: .done(error), profile: "", opacity: opacity))),
            ("pill-accessibility-narrow", CGSize(width: 340, height: 600), AnyView(PillContent(phase: .done(error), profile: "", opacity: opacity))),
            ("pill-long-profile", room, AnyView(PillContent(phase: .recording, profile: "Formal email to the leadership team, with British spelling and no contractions", startedAt: .now, opacity: opacity))),
            ("pill-before-accessibility", room, AnyView(
                HStack(spacing: 14) {
                    Text("✓")
                    Text(error.uppercased()).lineLimit(2).frame(maxWidth: 320, alignment: .leading)
                    Text("挿入")
                }
                .font(Ob.mono(11, .medium)).foregroundStyle(Color(hex: 0xE8E7E3))
                .padding(EdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 8)).frame(minHeight: 40)
                .background(Capsule().fill(Color(hex: 0x0D0D0C).opacity(opacity))))),
            ("pill-live-short", room, AnyView(PillContent(phase: .recording, profile: "Light Cleanup", startedAt: .now,
                                                          live: "so the plan for friday is", opacity: opacity))),
            ("pill-live-long", room, AnyView(PillContent(phase: .recording, profile: "Light Cleanup", startedAt: .now,
                                                         live: "um so the plan for friday is we ship the beta to the uh first ten testers " + long, opacity: opacity))),
            ("pill-live-transcribing", room, AnyView(PillContent(phase: .transcribing, profile: "", live: long, opacity: opacity))),
            ("pill-live-narrow", CGSize(width: 340, height: 600), AnyView(PillContent(phase: .recording, profile: "Light Cleanup", startedAt: .now,
                                                                                      live: long, opacity: opacity))),
            ("receipt-done", room, AnyView(VStack(spacing: 10) {
                ReceiptCard(entry: entry) {}
                PillContent(phase: .done("Inserted into Microsoft Outlook (Work Account)"), profile: "", opacity: opacity)
            })),
            ("receipt-long-short-screen", CGSize(width: 420, height: 480), AnyView(VStack(spacing: 10) {
                ReceiptCard(entry: HistoryEntry(transcription: long, aiEdit: nil, inserted: long, profileName: "Raw", model: nil,
                                                appName: "Notes", seconds: 90, turnaroundSeconds: 1, warning: nil)) {}
                PillContent(phase: .done("Inserted into Notes"), profile: "", opacity: opacity)
            })),
        ]
        for (name, room, view) in shots {
            let content = view.environment(\.overlayRoom, room).padding(OverlayController.padding).fixedSize()
                .background(Color(hex: 0xC9C7C1)).environmentObject(model).obertonTheme(model.settings)
            // Through a real hosting view in a window: ImageRenderer leaves a ScrollView's content out.
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
                print("\(name).png \(Int(host.bounds.width))×\(Int(host.bounds.height))")
            }
        }
        // Every position keeps the panel inside the visible frame, also when the content is bigger than the screen.
        let screen = CGRect(x: 0, y: 25, width: 1512, height: 920)
        for size in [CGSize(width: 552, height: 72), CGSize(width: 1600, height: 1000)] {
            for p in OverlayPosition.allCases {
                for current in [nil, CGRect(x: 1400, y: -50, width: 300, height: 100)] {
                    let f = OverlayController.frame(size: size, position: p, screen: screen, current: current)
                    let inside = f.minX >= screen.minX && f.minY >= screen.minY && f.maxX <= screen.maxX && f.maxY <= screen.maxY
                    let topLeftOn = f.minX >= screen.minX && f.maxY <= screen.maxY
                    print("\(p.rawValue) \(current == nil ? "fresh" : "moved") \(Int(size.width))×\(Int(size.height)) → \(f) \(inside ? "inside" : topLeftOn ? "too big, top-left on screen" : "OFF SCREEN")")
                }
            }
        }
        exit(0)
    }
}
#endif

struct OverlayView: View {
    var onSize: (CGSize) -> Void = { _ in }
    @EnvironmentObject var model: AppModel
    @State private var showReceipt = false

    var body: some View {
        let alignment = model.settings.overlayPosition.alignment
        VStack(alignment: alignment.horizontal, spacing: 10) {
            if model.phase == .preview, let pending = model.pending {
                ReceiptCard(entry: pending, preview: true) { model.cancel() }
            } else if showReceipt, let receipt = model.receipt {
                ReceiptCard(entry: receipt) { showReceipt = false }
            }
            if model.phase != .idle && model.phase != .preview {
                OverlayPill { if case .done = model.phase { showReceipt = true } }
            }
            ReaderCard(player: model.reader, opacity: model.settings.overlayOpacity)
        }
        .padding(OverlayController.padding)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .obertonTheme(model.settings)
        .onChange(of: model.phase) { _, new in if new == .recording { showReceipt = false } }
    }
}
#endif
