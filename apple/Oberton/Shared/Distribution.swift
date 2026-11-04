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

    #if os(macOS)
    /// Oberton has what it needs from Privacy & Security › Accessibility: in the App Store build, pressing ⌘V (and ⌘C)
    /// in other apps; in the direct build also reading their text (`axTrusted`), which the same switch allows.
    static var accessibilityAllowed: Bool {
        isDirect && !isSandboxed ? AXIsProcessTrusted() && CGPreflightPostEventAccess() : CGPreflightPostEventAccess()
    }

    /// Asks macOS for Accessibility: the system's prompt, which adds Oberton to Privacy & Security › Accessibility. The
    /// direct build asks with AXIsProcessTrustedWithOptions, which covers reading other apps' text too.
    static func requestAccessibility() {
        if isDirect && !isSandboxed {
            if !AXIsProcessTrusted() {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            } else if !CGPreflightPostEventAccess() {
                CGRequestPostEventAccess()
            }
        } else if !CGPreflightPostEventAccess() {
            CGRequestPostEventAccess()
        }
    }
    #endif

    /// The version as Windows writes it on Settings › Updates and About: "Oberton 5.18.1".
    static var version: String {
        threePart(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
    }

    /// A version in three parts, as Windows prints them (AppInfo.VersionText, Version.ToString(3)): "5.19" is "5.19.0".
    /// Anything that isn't numbers and dots is shown as it is.
    static func threePart(_ version: String) -> String {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return version }
        return (parts.compactMap { Int($0) } + [0, 0, 0]).prefix(3).map(String.init).joined(separator: ".")
    }
}
