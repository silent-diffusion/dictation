import Foundation
#if os(macOS)
import ApplicationServices
#endif

/// Which build of Oberton this is. The Mac app ships twice: through the App Store (the "Oberton" target, sandboxed) and
/// as a direct download (the "Oberton Direct" target: Developer ID, notarized, not sandboxed). Only the direct build may
/// read other apps' text through Accessibility (the text around the cursor, the focused control, window titles) and
/// update itself (Sparkle). Features that need either check `isDirect` or `axTrusted`; the App Store build hides them or
/// falls back. The iPhone app is always the App Store build.
enum Distribution {
    /// The direct download (compiled with `OBERTON_DIRECT`).
    #if OBERTON_DIRECT
    static let isDirect = true
    #else
    static let isDirect = false
    #endif

    /// Running inside the App Sandbox: the App Store build, including its Debug runs from Xcode.
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// A Debug build, Windows' "development copy": it shows "// DEVELOPMENT COPY" beside the version and doesn't install
    /// updates over itself.
    #if DEBUG
    static let isDevelopmentCopy = true
    #else
    static let isDevelopmentCopy = false
    #endif

    /// Oberton may read other apps' text through Accessibility: the direct build, outside the sandbox, with Oberton
    /// allowed in System Settings › Privacy & Security › Accessibility. Asked each time (the user can turn it off while
    /// Oberton runs). Always false in the App Store build and on the iPhone.
    static var axTrusted: Bool {
        #if os(macOS)
        isDirect && !isSandboxed && AXIsProcessTrusted()
        #else
        false
        #endif
    }

    /// The version as Windows writes it on Settings › Updates and About: "Oberton 5.18.1".
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
