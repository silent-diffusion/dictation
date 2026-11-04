#if os(macOS)
import AppKit
import Combine
import ObertonCore
import SwiftUI

/// The pill: always on top, on every Space and over full-screen apps, and never takes focus from the app being
/// dictated into. Shown while dictating, and for notices.
///
/// The panel is exactly as big as what it shows (plus room for the shadows): SwiftUI reports the content's size, and
/// the panel is resized around it, anchored at the chosen corner or edge and clamped into the screen's visible area.
/// A fixed large window can't do that: content bigger than it is clipped, and its empty parts sit over other apps.
///
/// Dragged somewhere, it stays there until Oberton quits or Settings › Layout moves it (Windows' WindowDrag): it keeps
/// its centre and, in the lower half of the screen, its bottom edge (the top edge in the upper half), so it grows away
/// from the edge it is near.
@MainActor
final class OverlayController {
    private let panel: NSPanel
    private let host: NSHostingView<AnyView>
    private let model: AppModel
    private var bag: Set<AnyCancellable> = []
    private var contentSize: CGSize?
    private var room: CGSize?
    /// Where it was dragged to: centre x, and the bottom or top edge (`fromBottom`) — nil until it is dragged.
    private var anchor: CGPoint?
    private var fromBottom = true
    /// The frame is being set by `layout`, not dragged by the user.
    private var placing = false
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
        // Tooltips while another app is in front, as Windows shows them on its never-activated overlay; and a name for
        // VoiceOver (Windows' window Title).
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.title = "Oberton overlay"
        panel.setAccessibilityTitle("Oberton overlay")
        host = NSHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        panel.contentView = host

        // After each change has landed (objectWillChange fires before it; the hop to the main run loop waits it out).
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &bag)
        // Settings › Layout moved the overlay (or the player, which can follow it): forget the dragged spot and flash
        // the pill at the new one (App.PreviewOverlay).
        // A player position picked on the Read aloud page flashes too; the Layout page's "Same place as the dictation
        // overlay" switch (the player's own position set or cleared) doesn't (LayoutPage.SamePlace_Changed).
        model.$settings.map { PositionPair(overlay: $0.overlayPosition, reader: $0.readerPosition) }
            .removeDuplicates()
            .scan([PositionPair]()) { last, new in Array((last + [new]).suffix(2)) }
            .filter { pairs in pairs.count == 2 && Self.flashes(from: pairs[0], to: pairs[1]) }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.previewPosition() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in if self?.panel.isVisible == true { self?.layout(fresh: false) } }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .sink { [weak self] _ in self?.moved() }
            .store(in: &bag)
    }

    struct PositionPair: Equatable {
        var overlay: OverlayPosition
        var reader: ReaderPosition
    }

    /// The overlay moved, or the player was given another spot of its own (not following the overlay or stopping to).
    static func flashes(from old: PositionPair, to new: PositionPair) -> Bool {
        if old.overlay != new.overlay { return true }
        if case .at = old.reader, case .at = new.reader { return old.reader != new.reader }
        return false
    }

    /// The screen it is on, or the one it was dragged to, or the primary one (the menu bar's), as Windows places it on
    /// the primary monitor's work area.
    private var screen: CGRect? {
        if panel.isVisible, let s = panel.screen { return s.visibleFrame }
        if let anchor, let s = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(anchor) }) { return s.visibleFrame }
        return (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame
    }

    /// Shown while dictating (with "Show overlay" on); the preview, NO PLACE TO PASTE, notices, the
    /// profile switch and the position flash show either way, as on Windows.
    private func update() {
        let phase = model.phase
        let done = { if case .done = phase { true } else { false } }()
        let visible = phase == .preview || phase == .placing || model.overlayNotice != nil || model.profileNotice || model.positionFlash
            || { if case .failed = phase { true } else { false } }()
            || (model.settings.showOverlay && phase != .idle && (!done || model.receipt != nil)) // no receipt: read aloud took its place
        guard visible else { panel.orderOut(nil); return }
        if !panel.isVisible { layout(fresh: true) }
        panel.orderFrontRegardless()
    }

    /// ● DICTATION APPEARS HERE for 1.5 s at the new position, unless a dictation is showing. It takes the place of
    /// a receipt, notice or profile pill, which don't come back after (OverlayWindow.ShowPositionPreview).
    private func previewPosition() {
        anchor = nil
        guard !model.overlayPinned else { return }
        model.flashPosition()
        if panel.isVisible { layout(fresh: true) }
    }

    /// The user dragged it: remember the spot (WindowDrag.Remember).
    private func moved() {
        guard !placing, panel.isVisible, let screen else { return }
        let f = panel.frame
        fromBottom = f.midY < screen.midY
        anchor = CGPoint(x: f.midX, y: fromBottom ? f.minY : f.maxY)
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
        let frame = anchor.map { Self.frame(size: size, anchor: $0, fromBottom: fromBottom, screen: screen) }
            ?? Self.frame(size: size, position: model.settings.overlayPosition, screen: screen, current: fresh ? nil : panel.frame)
        placing = true
        panel.setFrame(frame, display: true)
        placing = false
    }

    /// Where a panel of `size` goes when it was dragged: centred on `anchor.x`, its bottom (or top) edge on `anchor.y`,
    /// kept inside the screen.
    static func frame(size: CGSize, anchor: CGPoint, fromBottom: Bool, screen: CGRect) -> CGRect {
        var x = anchor.x - size.width / 2
        var y = fromBottom ? anchor.y : anchor.y - size.height
        x = max(screen.minX, min(x, screen.maxX - size.width))
        y = min(screen.maxY - size.height, max(y, screen.minY))
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
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
        var clean = entry
        clean.warning = nil
        var rejected = entry
        rejected.inserted = entry.transcription
        rejected.warning = "The AI's edit failed the safety net, so your original words were inserted unchanged."
        rejected.safetyNet = true
        var partly = entry
        partly.warning = "The AI's edit of 1 of 3 parts failed the safety net; those parts were inserted unchanged."
        partly.safetyNet = true
        let long = String(repeating: "and then we collect feedback from all of them over the following week, ", count: 30)
        let narrow = CGSize(width: 340, height: 600)
        var raw = clean
        raw.aiEdit = nil
        raw.inserted = raw.transcription
        let hotkey = model.settings.hotkey
        let model8b = "qwen3:8b"
        // A burst of speech then quiet, as AppModel.meter holds it (√ level, oldest first).
        let meter = (0..<22).map { i in i < 14 ? sqrt(0.15 + 0.5 * abs(sin(Double(i) * 0.9))) : 0 }
        var failedAI = clean
        failedAI.aiEdit = nil
        failedAI.inserted = failedAI.transcription
        let around = InsertionContext(before: "Hi all,\n\nQuick update on the launch. ", after: " Let me know if that works.")
        let shots: [(String, CGSize, AnyView)] = [
            ("pill-starting", room, AnyView(PillContent(phase: .starting, profile: "Light Cleanup", opacity: opacity))),
            ("pill-recording", room, AnyView(PillContent(phase: .recording, profile: "Light Cleanup", meter: meter, startedAt: .now - 7, opacity: opacity))),
            ("pill-recording-silent", room, AnyView(PillContent(phase: .recording, profile: "Light Cleanup", meter: [Double](repeating: 0, count: 22), startedAt: .now - 7, opacity: opacity))),
            ("pill-recording-loading", room, AnyView(PillContent(phase: .recording, profile: "Light Cleanup", startedAt: .now - 3, opacity: opacity, loadingSpeech: true))),
            ("pill-transcribing", room, AnyView(PillContent(phase: .transcribing, profile: "Light Cleanup", opacity: opacity, audioSeconds: 7.4))),
            ("pill-transcribing-loading", room, AnyView(PillContent(phase: .transcribing, profile: "Light Cleanup", opacity: opacity, audioSeconds: 3, loadingSpeech: true))),
            ("pill-processing", room, AnyView(PillContent(phase: .processing, profile: "Light Cleanup", live: entry.transcription, opacity: opacity, aiModel: model8b))),
            ("pill-final-pass", room, AnyView(PillContent(phase: .processing, profile: "Light Cleanup", live: long, opacity: opacity, aiModel: model8b, finalPass: true))),
            ("pill-inserting", room, AnyView(PillContent(phase: .inserting, profile: "Light Cleanup", opacity: opacity))),
            ("pill-long-profile", room, AnyView(PillContent(phase: .recording, profile: "Formal email to the leadership team, with British spelling and no contractions", startedAt: .now, opacity: opacity))),
            ("pill-live-short", room, AnyView(PillContent(phase: .recording, profile: "Light Cleanup", startedAt: .now,
                                                          live: "so the plan for friday is", opacity: opacity))),
            ("pill-live-long", room, AnyView(PillContent(phase: .recording, profile: "Light Cleanup", startedAt: .now,
                                                         live: "um so the plan for friday is we ship the beta to the uh first ten testers " + long, opacity: opacity))),
            ("pill-live-transcribing", room, AnyView(PillContent(phase: .transcribing, profile: "Light Cleanup", live: long, opacity: opacity, audioSeconds: 64))),
            ("pill-live-narrow", narrow, AnyView(PillContent(phase: .recording, profile: "Light Cleanup", startedAt: .now, live: long, opacity: opacity))),
            ("preview", room, AnyView(PreviewPill(entry: clean, profile: "Light Cleanup", hotkey: hotkey, opacity: opacity))),
            ("preview-no-ai", room, AnyView(PreviewPill(entry: raw, profile: "Raw", hotkey: hotkey, opacity: opacity))),
            ("preview-ai-failed", room, AnyView(PreviewPill(entry: { var e = failedAI; e.model = "ollama:qwen3:8b"; return e }(), profile: "Light Cleanup", hotkey: hotkey, opacity: opacity))),
            ("pill-processing-long-profile", room, AnyView(PillContent(phase: .processing, profile: "Formal email to the leadership team, with British spelling and no contractions", live: entry.transcription, opacity: opacity, aiModel: "anthropic:claude-haiku-4-5-20251001"))),
            ("notice-ai-failed", room, AnyView(NoticePill(text: AppModel.aiFailureNotice("The AI model took too long to respond. Your original words were inserted."), kind: .warning, opacity: opacity))),
            ("notice-insert-failed", room, AnyView(NoticePill(text: "Couldn't switch back to the app you were typing in. Click into it and try again. The text was copied to your clipboard.", kind: .warning, opacity: opacity))),
            ("notice-generic-error", room, AnyView(NoticePill(text: "Something went wrong during dictation. See \(AppModel.logPath).", kind: .error, opacity: opacity))),
            ("preview-long", room, AnyView(PreviewPill(entry: HistoryEntry(transcription: long, aiEdit: long.capitalized, inserted: long.capitalized,
                                                                         profileName: "Light Cleanup", model: nil, appName: "Notes", seconds: 90,
                                                                         turnaroundSeconds: 1, warning: nil),
                                                       profile: "Light Cleanup", hotkey: hotkey, opacity: opacity))),
            ("preview-narrow", CGSize(width: 600, height: 700), AnyView(PreviewPill(entry: clean, profile: "Light Cleanup", hotkey: hotkey, opacity: opacity))),
            ("placing", room, AnyView(PlacingPill(profile: "Light Cleanup", hotkey: hotkey, opacity: opacity))),
            ("notice-info", room, AnyView(NoticePill(text: "Copied to your clipboard. Paste it wherever you like.", kind: .info, opacity: opacity))),
            ("notice-warning", room, AnyView(NoticePill(text: "The microphone is silent. Check the microphone in System Settings › Privacy & Security, or pick another mic.", kind: .warning, opacity: opacity))),
            ("notice-error", room, AnyView(NoticePill(text: error, kind: .error, opacity: opacity))),
            ("notice-hotkey", room, AnyView(NoticePill(text: "Ctrl+Alt+D is already used by another app. Choose a different shortcut under Settings › Hotkeys.", kind: .error, opacity: opacity))),
            ("position", room, AnyView(PositionPill(opacity: opacity))),
            ("profile-notice", room, AnyView(ProfilePill(name: "Light Cleanup", index: 1, count: 4, opacity: opacity))),
            ("profile-notice-long", room, AnyView(ProfilePill(name: "Formal email to the leadership team, with British spelling and no contractions",
                                                              index: 3, count: 6, opacity: opacity))),
            ("receipt", room, AnyView(ReceiptPill(entry: clean, opacity: opacity))),
            ("receipt-open", room, AnyView(ReceiptPill(entry: clean, opacity: opacity, open: true))),
            ("receipt-safety-net", room, AnyView(ReceiptPill(entry: rejected, opacity: opacity))),
            ("receipt-safety-net-open", room, AnyView(ReceiptPill(entry: rejected, opacity: opacity, open: true))),
            ("receipt-partly-edited", room, AnyView(ReceiptPill(entry: partly, opacity: opacity))),
            ("receipt-note", room, AnyView(ReceiptPill(entry: entry, opacity: opacity))),
            // The text around the cursor (read in the direct build) either side of the AI edit (DICT-054).
            ("preview-context", room, AnyView(PreviewPill(entry: clean, profile: "Light Cleanup", hotkey: hotkey, opacity: opacity,
                                                          context: around))),
            ("receipt-open-context", room, AnyView(ReceiptPill(entry: clean, opacity: opacity, open: true, context: around))),
            ("receipt-open-context-long", room, AnyView(ReceiptPill(entry: clean, opacity: opacity, open: true,
                                                                    context: InsertionContext(before: long, after: long)))),
            ("receipt-open-long-short-screen", CGSize(width: 420, height: 480), AnyView(ReceiptPill(
                entry: HistoryEntry(transcription: long, aiEdit: nil, inserted: long, profileName: "Raw", model: nil,
                                    appName: "Notes", seconds: 90, turnaroundSeconds: 1, warning: nil), opacity: opacity, open: true))),
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
        // The meter keeps moving with no audio at all: a burst, then silence, settles to flat and keeps scrolling.
        let meterCheck = LevelMeter()
        var t = Date()
        for i in 0..<30 {
            if i < 6 { meterCheck.hear(0.5) }
            meterCheck.tick(now: t)
            t += 0.05
        }
        print("meter after a burst and 1.2 s of nothing: " + meterCheck.columns.map { String(format: "%.2f", $0) }.joined(separator: " "))
        // A box's COPY takes the selected part; AI EDIT's leaves out the struck-through words.
        let selection = OverlayTextSelection()
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(OverlayRichText.diff("um so the plan is fine", "So the plan is fine.", accent: .blue).nsAttributed)
        selection.view = textView
        print("copy, nothing selected: \(selection.selected(dropStruck: true) ?? "nil (whole box)")")
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.count))
        print("copy, all selected: '\(selection.selected(dropStruck: true) ?? "nil")' (shown: '\(textView.string)')")
        textView.setSelectedRange(NSRange(location: 3, length: 9))
        print("copy, part selected: '\(selection.selected() ?? "nil")'")
        // A dragged pill keeps its centre and its bottom (or top) edge as it grows, and stays on screen.
        for (anchor, bottom) in [(CGPoint(x: 700, y: 60), true), (CGPoint(x: 700, y: 900), false), (CGPoint(x: 1500, y: 30), true)] {
            for size in [CGSize(width: 552, height: 90), CGSize(width: 924, height: 400)] {
                let f = OverlayController.frame(size: size, anchor: anchor, fromBottom: bottom, screen: screen)
                let inside = f.minX >= screen.minX && f.minY >= screen.minY && f.maxX <= screen.maxX && f.maxY <= screen.maxY
                print("anchor \(anchor) \(bottom ? "bottom" : "top") \(Int(size.width))×\(Int(size.height)) → \(f) midX \(f.midX) \(bottom ? "minY \(f.minY)" : "maxY \(f.maxY)") \(inside ? "inside" : "OFF SCREEN")")
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
            if model.positionFlash, !model.overlayPinned {
                PositionPill(opacity: model.settings.overlayOpacity)
            } else {
                OverlayPill(reader: model.reader, open: $showReceipt)
            }
        }
        .padding(OverlayController.padding)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .obertonTheme(model.settings)
        .onChange(of: model.phase) { _, new in if case .done = new {} else { showReceipt = false } }
    }
}
#endif
