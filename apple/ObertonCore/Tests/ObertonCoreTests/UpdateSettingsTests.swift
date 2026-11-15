import Foundation
import Testing
@testable import ObertonCore

// Settings › Updates: "Check for updates when Oberton starts" is on by default (Windows' CheckUpdatesOnStartup), also for
// a settings file saved before the switch existed, and turning it off is remembered.
@Suite struct UpdateSettingsTests {
    @Test func checkingAtStartIsOnByDefault() throws {
        #expect(AppSettings().checkUpdatesOnStartup)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hotkey": "Ctrl+K"}"#.utf8))
        #expect(old.checkUpdatesOnStartup)
    }

    @Test func turningItOffIsSaved() throws {
        var s = AppSettings()
        s.checkUpdatesOnStartup = false
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.checkUpdatesOnStartup == false)
    }
}
