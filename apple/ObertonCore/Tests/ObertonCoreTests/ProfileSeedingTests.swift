import Foundation
@testable import ObertonCore
import Testing

/// Windows' ProfileService start-up and SettingsService.EnforceLocalEndpoint.
struct ProfileSeedingTests {
    @Test func aLaterBuiltInShowsUpOnce() {
        var profiles = BuiltInProfiles.create().filter { $0.id != BuiltInProfiles.rawID }
        var added: [String] = []
        let first = BuiltInProfiles.addMissing(to: &profiles, added: &added)
        #expect(first)
        #expect(profiles.contains { $0.id == BuiltInProfiles.rawID })
        #expect(added == [BuiltInProfiles.rawID])
        // Deleted after it was offered: it stays deleted.
        profiles.removeAll { $0.id == BuiltInProfiles.rawID }
        let again = BuiltInProfiles.addMissing(to: &profiles, added: &added)
        #expect(!again)
        #expect(!profiles.contains { $0.id == BuiltInProfiles.rawID })
    }

    @Test func aBuiltInAlreadyThereIsOnlyNoted() {
        var profiles = BuiltInProfiles.create()
        let count = profiles.count
        var added: [String] = []
        let noted = BuiltInProfiles.addMissing(to: &profiles, added: &added)
        #expect(noted)
        #expect(profiles.count == count)
        #expect(added == [BuiltInProfiles.rawID])
    }

    @Test func aNewProfileHasWindowsDefaults() {
        let p = BuiltInProfiles.newProfile()
        #expect(p.name == "New Profile")
        #expect(p.description == "Custom editing profile.")
        #expect(p.maxChangeRatio == 0.5)
        #expect(p.prompt == BuiltInProfiles.customPrompt)
    }

    @Test func aRemoteOllamaAddressIsReset() {
        var s = AppSettings()
        s.ollamaEndpoint = "http://192.168.1.20:11434"
        let reset = s.enforceLocalEndpoint()
        #expect(reset)
        #expect(s.ollamaEndpoint == AppSettings().ollamaEndpoint)
        for local in ["http://localhost:11434", "http://127.0.0.1:9999", "http://[::1]:11434"] {
            s.ollamaEndpoint = local
            let changed = s.enforceLocalEndpoint()
            #expect(!changed)
            #expect(s.ollamaEndpoint == local)
        }
    }
}
