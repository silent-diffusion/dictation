import ObertonCore
import SwiftUI

// MARK: - D // App

/// D.3 Updates (Windows UpdatesPage.xaml), as an information page: the App Store and TestFlight update Oberton, and
/// an app from either may not update itself, so there is no CHECK FOR UPDATES, DOWNLOAD AND INSTALL or startup check.
struct UpdatesSection: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String
        return "Oberton \(short)" + (build.map { " (build \($0))" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(version).font(Ob.mono(13, .bold)).textSelection(.enabled).padding(.bottom, 4)
            Caption("New versions come through the App Store, or through TestFlight while you test a beta. They install by themselves, or when you choose Update there. Updating keeps your settings, profiles, history and notes.")
                .padding(.bottom, 8)
            FieldLabel("Where to look")
            #if os(macOS)
            Caption("App Store › Updates (turn on automatic updates under App Store › Settings), or the TestFlight app for a beta.")
            #else
            Caption("App Store › your account › Updates (turn on automatic updates under Settings › App Store), or the TestFlight app for a beta.")
            #endif
        }
    }
}
