#if OBERTON_DIRECT
import AppKit
import Combine
import ObertonCore
import Sparkle

/// Updates for the direct download (Windows' UpdateService, UpdatesPage and the startup check in App.xaml.cs), on
/// Sparkle. Sparkle finds, downloads, checks the signature of and installs the update; Oberton draws it the Windows
/// way, on Settings › Updates (CHECK FOR UPDATES, the status line, DOWNLOAD AND INSTALL (N MB), the progress bar and
/// the release notes) instead of Sparkle's own windows. The App Store build has none of this: the App Store updates it.
///
/// As on Windows, Oberton never updates by itself: the startup check (20 s after start, when "Check for updates when
/// Oberton starts" is on) only tells, and installing is always the user's click. Sparkle's own scheduled checks are off
/// (Info-Direct.plist).
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    /// Settings › Updates: the status line (Windows' StatusText), the release notes, the DOWNLOAD AND INSTALL title
    /// (nil = the button is hidden), the download's progress (nil = the bar is hidden).
    @Published private(set) var status = ""
    @Published private(set) var notes = ""
    @Published private(set) var installTitle: String?
    @Published private(set) var progress: Double?
    /// A check or an install is under way: CHECK FOR UPDATES is disabled.
    @Published private(set) var busy = false

    private var updater: SPUUpdater?
    private var startError: Error?
    private weak var model: AppModel?
    /// Sparkle waits for the user's DOWNLOAD AND INSTALL with this.
    private var reply: ((SPUUserUpdateChoice) -> Void)?
    /// What the user asked for, so an error is worded for it, and the startup check stays quiet about its errors.
    private enum Asked { case nothing, check, install }
    private var asked = Asked.nothing
    /// CHECK FOR UPDATES was clicked while Sparkle was still busy (the startup check, or showing an update); it checks
    /// as soon as Sparkle is free.
    private var checkWhenFree = false
    private var expectedBytes: UInt64 = 0, receivedBytes: UInt64 = 0
    private var freeWatch: AnyCancellable?

    /// Starts Sparkle, and the startup check when it is on. Called once at launch.
    func start(model: AppModel) {
        self.model = model
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        do {
            try updater.start()
            self.updater = updater
        } catch {
            startError = error
            Log.warn("Updates: Sparkle didn't start: \(error.localizedDescription)")
            return
        }
        freeWatch = updater.publisher(for: \.canCheckForUpdates).combineLatest(updater.publisher(for: \.sessionInProgress))
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.checkIfWaiting() } }
        guard model.settings.checkUpdatesOnStartup else { return }
        Task {
            try? await Task.sleep(for: .seconds(20)) // let the models load first
            self.updater?.checkForUpdatesInBackground()
        }
    }

    // MARK: Settings › Updates

    /// CHECK FOR UPDATES.
    func check() {
        asked = .check
        busy = true
        installTitle = nil
        notes = ""
        status = "Checking…"
        guard let updater else {
            Log.warn("Update check failed: Sparkle didn't start: \(startError?.localizedDescription ?? "unknown")")
            finish("The update check failed. See the log for details.")
            return
        }
        checkWhenFree = true
        if let reply {
            // Showing an update found earlier: let that go and ask again.
            self.reply = nil
            reply(.dismiss)
        }
        DispatchQueue.main.async { self.checkIfWaiting() }
    }

    /// Runs the check CHECK FOR UPDATES asked for once Sparkle is free.
    private func checkIfWaiting() {
        guard checkWhenFree, let updater, updater.canCheckForUpdates, !updater.sessionInProgress else { return }
        checkWhenFree = false
        updater.checkForUpdates()
    }

    /// DOWNLOAD AND INSTALL.
    func install() {
        guard let reply else { return }
        self.reply = nil
        asked = .install
        busy = true
        installTitle = nil
        progress = 0
        status = "Downloading the update…"
        reply(.install)
    }

    private func finish(_ text: String) {
        status = text
        busy = false
        progress = nil
    }

    /// Windows' `Show(UpdateInfo)`: the version, the release notes (at most 1,500 characters) and DOWNLOAD AND INSTALL
    /// with the download's size. A development copy (a Debug build) is told to update from the repository instead.
    private func show(_ item: SUAppcastItem) {
        busy = false
        status = "Version \(item.displayVersionString) is available (you have \(Distribution.version))."
        if let description = item.itemDescription { notes = Self.plainNotes(description, format: item.itemDescriptionFormat) }
        if Distribution.isDevelopmentCopy {
            status += " This is a development copy: update it with \"git pull\" instead."
            return
        }
        installTitle = item.contentLength > 0
            ? "Download and install (\(String(format: "%.0f", Double(item.contentLength) / 1_048_576)) MB)"
            : "Download and install"
    }

    static func plainNotes(_ text: String, format: String?) -> String {
        var plain = text
        if format == nil || format == "html",
           let html = try? NSAttributedString(data: Data(text.utf8), options: [.documentType: NSAttributedString.DocumentType.html,
                                                                              .characterEncoding: String.Encoding.utf8.rawValue],
                                              documentAttributes: nil) {
            plain = html.string
        }
        plain = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.count > 1500 ? String(plain.prefix(1500)) + "…" : plain
    }

    /// Windows' wording for what went wrong, by what the user asked for.
    private func message(for error: Error) -> String {
        let chain = Self.chain(error)
        let offline = chain.contains { $0.domain == NSURLErrorDomain }
        switch asked {
        case .install:
            if offline { return "Downloading the update failed. Check your internet connection and try again." }
            if chain.contains(where: { $0.domain == SUSparkleErrorDomain && $0.code == Int(SUError.signatureError.rawValue) }) {
                return "The downloaded update is not signed the way Oberton's updates are, so it was not installed. Try again."
            }
            return "The update could not be installed: \(error.localizedDescription)"
        case .check, .nothing:
            if offline { return "Couldn't reach GitHub to check for updates. Check your internet connection." }
            return "The update check failed. See the log for details."
        }
    }

    /// The error and the errors under it.
    private static func chain(_ error: Error) -> [NSError] {
        var all: [NSError] = []
        var next: NSError? = error as NSError
        while let e = next, all.count < 8 {
            all.append(e)
            next = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return all
    }

    /// No list of updates published yet (the feed is "Not Found"): Windows treats a 404 as up to date.
    private static func nothingPublished(_ error: Error) -> Bool {
        chain(error).contains { $0.localizedDescription.hasSuffix("(404)") }
    }
}

// MARK: - Sparkle's user driver

extension Updater: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Oberton's own switch decides; Sparkle never schedules checks or sends a system profile.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        status = "Checking…"
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.reply = reply
        let startup = asked == .nothing && !checkWhenFree
        checkWhenFree = false
        show(appcastItem)
        Log.info("Update available: \(appcastItem.displayVersionString)")
        if startup {
            model?.notice("Oberton \(appcastItem.displayVersionString) is available. Open Settings > Updates to install it.")
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard notes.isEmpty, let text = String(data: downloadData.data, encoding: .utf8) else { return }
        notes = Self.plainNotes(text, format: downloadData.mimeType == "text/plain" ? "plain-text" : "html")
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        Log.warn("Update release notes: \(error.localizedDescription)")
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if asked == .check { finish("You're up to date (\(Distribution.version)).") }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if asked == .nothing {
            Log.warn("Startup update check failed: \(error.localizedDescription)")
        } else if asked == .check, Self.nothingPublished(error) {
            finish("You're up to date (\(Distribution.version)).")
        } else {
            Log.error("Update \(asked == .install ? "install" : "check") failed: \(error.localizedDescription)")
            finish(message(for: error))
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedBytes = 0
        receivedBytes = 0
        progress = 0
        status = "Downloading the update…"
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        if expectedBytes > 0 { progress = min(1, Double(receivedBytes) / Double(expectedBytes)) }
    }

    func showDownloadDidStartExtractingUpdate() {
        progress = 1
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        status = "Installing… Oberton will restart by itself."
        Log.info("Installing the update; Oberton restarts")
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        status = "Installing… Oberton will restart by itself."
        // Windows' installer closes Oberton whatever it is doing; ask once more if something kept it open.
        if !applicationTerminated { retryTerminatingApplication() }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    /// The update session ended (nothing found, dismissed, failed or installed): DOWNLOAD AND INSTALL no longer works.
    func dismissUpdateInstallation() {
        reply = nil
        installTitle = nil
        if asked == .install, progress != nil { progress = nil }
        if !checkWhenFree {
            busy = false
            asked = .nothing
        }
    }
}

#if DEBUG
extension Updater {
    /// The states Settings › Updates draws, for the snapshots: found, downloading, up to date.
    enum SnapshotState { case available, downloading, upToDate }

    func snapshot(_ state: SnapshotState) {
        busy = state == .downloading
        progress = state == .downloading ? 0.42 : nil
        notes = state == .upToDate ? "" : "Settings › Updates installs new versions in place.\nFixed: the overlay keeps its place after waking from sleep."
        switch state {
        case .available:
            status = "Version 5.19.0 is available (you have \(Distribution.version))."
            installTitle = "Download and install (24 MB)"
        case .downloading:
            status = "Downloading the update…"
            installTitle = nil
        case .upToDate:
            status = "You're up to date (\(Distribution.version))."
            installTitle = nil
        }
    }
}
#endif
#endif
