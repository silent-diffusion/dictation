#if os(iOS)
import AVFoundation
import ObertonCore
import UIKit

/// iOS doesn't let one app type into another, so a dictation goes to the clipboard, ready to paste. (Inserting at the
/// cursor in any app needs Oberton's own keyboard extension, which is the next step.)
@MainActor
final class PhonePlatform: PlatformServices {
    var targetAppName: String? { nil }

    func captureTarget() {}

    func insert(_ text: String) async throws -> String {
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return "Copied, ready to paste"
    }

    func selectedText() async -> String? { nil }

    func clipboardText() -> String? { UIPasteboard.general.string }

    func requestPermissions() async {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
    }
}
#endif
