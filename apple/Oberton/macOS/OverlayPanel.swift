#if os(macOS)
import AppKit
import Combine
import ObertonCore
import SwiftUI

/// The pill: always on top, on every Space and over full-screen apps, and never takes focus from the app being
/// dictated into. Shown while dictating or reading aloud.
@MainActor
final class OverlayController {
    private let panel: NSPanel
    private var bag: Set<AnyCancellable> = []

    init(model: AppModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: OverlayView().environmentObject(model))
        host.sizingOptions = []
        panel.contentView = host

        model.$phase.combineLatest(model.reader.$isSpeaking, model.$settings)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, speaking, settings in self?.update(visible: settings.showOverlay && (phase != .idle || speaking), settings: settings) }
            .store(in: &bag)
    }

    private func update(visible: Bool, settings: AppSettings) {
        guard visible else { panel.orderOut(nil); return }
        // A fixed, transparent window: clicks pass through its empty parts, and the content sits in the chosen corner.
        if !panel.isVisible { place(settings.overlayPosition) }
        panel.orderFrontRegardless()
    }

    private func place(_ position: OverlayPosition) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size, m: CGFloat = 8
        let col = [OverlayPosition.topLeft, .middleLeft, .bottomLeft].contains(position) ? 0
            : [OverlayPosition.topCenter, .center, .bottomCenter].contains(position) ? 1 : 2
        let row = [OverlayPosition.topLeft, .topCenter, .topRight].contains(position) ? 0
            : [OverlayPosition.middleLeft, .center, .middleRight].contains(position) ? 1 : 2
        let x = [screen.minX + m, screen.midX - size.width / 2, screen.maxX - size.width - m][col]
        let y = [screen.maxY - size.height - m, screen.midY - size.height / 2, screen.minY + m][row]
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct OverlayView: View {
    @EnvironmentObject var model: AppModel
    @State private var showReceipt = false

    var body: some View {
        VStack(spacing: 10) {
            if model.phase == .preview, let pending = model.pending {
                ReceiptCard(entry: pending, preview: true) { model.cancel() }
            } else if showReceipt, let receipt = model.receipt {
                ReceiptCard(entry: receipt) { showReceipt = false }
            }
            if !model.liveText.isEmpty, [.recording, .transcribing, .processing].contains(model.phase) {
                LiveWords(text: model.liveText)
            }
            if model.phase != .idle && model.phase != .preview {
                OverlayPill { if case .done = model.phase { showReceipt = true } }
            }
            ReaderCard(player: model.reader, opacity: model.settings.overlayOpacity)
        }
        .padding(16)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.settings.overlayPosition.alignment)
        .obertonTheme(model.settings)
        .onChange(of: model.phase) { _, new in if new == .recording { showReceipt = false } }
    }
}
#endif

