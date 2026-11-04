import ObertonCore
import SwiftUI

// MARK: - D // App

/// D.3 Updates (Windows UpdatesPage.xaml). The direct download checks, downloads and installs updates itself, as Windows
/// does (`Updater`, Sparkle). The App Store build has an information page instead: the App Store and TestFlight update
/// it, and an app from either may not update itself.
struct UpdatesSection: View {
    /// "OBERTON 5.18.1", with "  // DEVELOPMENT COPY" for a Debug build.
    static var versionLine: String {
        ("Oberton \(Distribution.version)" + (Distribution.isDevelopmentCopy ? "  // development copy" : "")).uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.versionLine).font(Ob.mono(13, .bold)).textSelection(.enabled).padding(.bottom, 4)
            #if OBERTON_DIRECT
            DirectUpdates()
            #else
            Caption("New versions come through the App Store, or through TestFlight while you test a beta. They install by themselves, or when you choose Update there. Updating keeps your settings, profiles, history and notes.")
                .padding(.bottom, 8)
            FieldLabel("Where to look")
            #if os(macOS)
            Caption("App Store › Updates (turn on automatic updates under App Store › Settings), or the TestFlight app for a beta.")
            #else
            Caption("App Store › your account › Updates (turn on automatic updates under Settings › App Store), or the TestFlight app for a beta.")
            #endif
            #endif
        }
    }
}

#if OBERTON_DIRECT
/// CHECK FOR UPDATES, DOWNLOAD AND INSTALL (N MB), the 360 × 4 progress bar, the status, the release notes (75%
/// opacity, at most 220 high) and the check-at-startup switch.
private struct DirectUpdates: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var updater = Updater.shared
    @Environment(\.ob) private var ob

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("New versions are published on GitHub. Updating downloads the installer and updates Oberton in place.", bottom: 8)
            // The FieldLabel style with Windows' own margin here (0,0,0,10).
            Text("CHECK FOR UPDATES").font(Ob.mono(12, .bold)).padding(.bottom, 10)
            HStack(spacing: 10) {
                Button("Check for updates") { updater.check() }.buttonStyle(.primary).disabled(updater.busy)
                if let title = updater.installTitle {
                    Button(title) { updater.install() }.buttonStyle(.quiet).disabled(updater.busy)
                }
            }
            if let progress = updater.progress {
                ZStack(alignment: .leading) {
                    Rectangle().fill(ob.divider)
                    Rectangle().fill(ob.ink).frame(width: 360 * max(0, min(1, progress)))
                }
                .frame(width: 360, height: 4)
                .padding(.top, 12)
            }
            // Plain text in the window's size, each always taking its line (empty TextBlocks keep their height).
            Text(updater.status.isEmpty ? " " : updater.status).font(Ob.sans(Ob.body)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            Text(updater.notes.isEmpty ? " " : updater.notes).font(Ob.sans(Ob.body)).opacity(0.75).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 220, alignment: .topLeading).clipped().padding(.top, 8)
            SwitchCard {
                ObSwitch("Check for updates when Oberton starts",
                         detail: "Checking contacts github.com only to read the list of releases. Nothing about you or your dictation is sent. Updating keeps your settings, profiles and downloaded models.",
                         isOn: $model.settings.checkUpdatesOnStartup)
            }
            .padding(.top, 16)
        }
        .onAppear { updater.pageOpened() }
    }
}
#endif

#if DEBUG && OBERTON_DIRECT && os(macOS)
/// Settings › Updates in the direct build, for the snapshots (OBERTON_SNAPSHOT): an update found, downloading, up to date.
@MainActor
enum UpdatesSnapshots {
    static func write(to dir: String, model: AppModel) {
        for state in [Updater.SnapshotState.available, .downloading, .upToDate] {
            Updater.shared.snapshot(state)
            for dark in [false, true] {
                var s = model.settings
                s.theme = dark ? .dark : .light
                let view = RootView(start: Place(section: .settings, settings: .updates)).environmentObject(model).obertonTheme(s)
                    .frame(width: 1200, height: 780)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "settings-updates-direct-\(state)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
#endif
