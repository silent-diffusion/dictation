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
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
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
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host

        model.$phase.combineLatest(model.reader.$isSpeaking, model.$settings)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, speaking, settings in self?.update(visible: settings.showOverlay && (phase != .idle || speaking), settings: settings) }
            .store(in: &bag)
    }

    private func update(visible: Bool, settings: AppSettings) {
        guard visible else { panel.orderOut(nil); return }
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        if !panel.isVisible { place(settings.overlayPosition) }
        panel.orderFrontRegardless()
    }

    private func place(_ position: OverlayPosition) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size, m: CGFloat = 24
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

    var body: some View {
        VStack(spacing: 8) {
            if !model.liveText.isEmpty, [.recording, .transcribing, .processing].contains(model.phase) {
                Text(model.liveText.suffix(280))
                    .font(.callout)
                    .lineLimit(4)
                    .padding(10)
                    .frame(maxWidth: 440, alignment: .leading)
                    .background(.regularMaterial.opacity(model.settings.overlayOpacity), in: RoundedRectangle(cornerRadius: 10))
            }
            if model.phase == .preview, let pending = model.pending {
                VStack(alignment: .leading, spacing: 8) {
                    Text(pending.inserted).font(.title3).textSelection(.enabled)
                    HStack {
                        Button("Insert") { model.confirmPreview() }
                        Button("Use original") { model.confirmPreview(useOriginal: true) }
                        Button("Discard") { model.cancel() }
                    }
                }
                .padding(12)
                .frame(maxWidth: 440, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            if model.phase != .idle { pill }
            OverlayPlayer(player: model.reader, opacity: model.settings.overlayOpacity)
        }
        .padding(8)
        .fixedSize()
    }

    private var pill: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .recording:
                Circle().fill(.red).frame(width: 9, height: 9)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(elapsed).font(.system(.callout, design: .monospaced)).monospacedDigit()
                }
                LevelMeter(level: model.level)
            case .starting, .transcribing, .processing, .inserting:
                ProgressView().controlSize(.small)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            default:
                Image(systemName: "checkmark").foregroundStyle(.secondary)
            }
            Text(model.phase == .recording ? model.activeProfile.name : model.phase.label)
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: 300, alignment: .leading)
            if model.phase.isBusy {
                Button { model.cancel() } label: { Label("Cancel", systemImage: "xmark") }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial.opacity(model.settings.overlayOpacity), in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .opacity(isDone ? 0.7 : 1)
    }

    private var isDone: Bool { if case .done = model.phase { true } else { false } }

    private var elapsed: String {
        let s = Int(Date().timeIntervalSince(model.startedAt ?? Date()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The read-aloud player in the overlay: the sentence being read, play/pause, speed and stop.
private struct OverlayPlayer: View {
    @ObservedObject var player: ReadAloudPlayer
    var opacity: Double

    var body: some View {
        if player.isSpeaking {
            PlayerView(player: player)
                .frame(width: 440)
                .background(.regularMaterial.opacity(opacity), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
#endif
