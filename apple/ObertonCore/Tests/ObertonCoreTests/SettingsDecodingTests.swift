import Foundation
import Testing
@testable import ObertonCore

// Settings and profiles saved by older versions (or hand-edited) still load: missing keys take Windows' defaults, and a
// bad value spoils only its own key.

@Suite struct SettingsDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func anOldSettingsFileGetsTheWindowsDefaults() throws {
        let s = try decode(AppSettings.self, #"{"hotkey": "Ctrl+K", "keepHistory": false}"#)
        #expect(s.hotkey == "Ctrl+K")
        #expect(s.keepHistory == false)
        #expect(s.startAtLogin == true)
        #expect(s.minimizeToTray == true)
        #expect(s.unloadAfterMinutes == 30)
        #expect(s.microphoneName == nil)
        #expect(s.insertion == .auto)
        #expect(s.appOverrides.isEmpty)
        #expect(s.typingMaxChars == 400)
        #expect(s.matchSurroundingText == true)
        #expect(s.typeWhileSpeaking == false)
        #expect(s.historyDays == 0)
        #expect(s.saveHistoryAudio == true)
        #expect(s.audioLimit == 0)
        #expect(s.audioDays == 7)
        #expect(s.readerPosition == .at(.topRight))
        #expect(s.readerOpacity == 0.9)
        #expect(s.readerExpanded == false)
        #expect(s.collapsedSettingsGroups.isEmpty)
        #expect(s.defaultProfileID == nil)
        #expect(s.builtInProfilesAdded.isEmpty)
        #expect(s.evenOutVolume == true)
    }

    @Test func theNewFieldsSurviveSaving() throws {
        var s = AppSettings()
        s.startAtLogin = false; s.minimizeToTray = false; s.unloadAfterMinutes = AppSettings.unloadImmediately
        s.microphoneName = "USB Mic"; s.insertion = .clipboard; s.appOverrides = ["com.apple.TextEdit": .typing]
        s.typingMaxChars = 120; s.matchSurroundingText = false; s.typeWhileSpeaking = true
        s.historyDays = 30; s.saveHistoryAudio = false; s.audioLimit = 5; s.audioDays = 0
        s.readerPosition = .withOverlay; s.readerOpacity = 0.5; s.readerExpanded = true
        s.collapsedSettingsGroups = ["B // Models & AI"]; s.defaultProfileID = "p1"; s.builtInProfilesAdded = ["builtin-raw"]
        s.evenOutVolume = false
        #expect(try roundTrip(s) == s)

        s.readerPosition = .at(.bottomCenter)
        #expect(try roundTrip(s).readerPosition == .at(.bottomCenter))
    }

    @Test func aBadValueSpoilsOnlyItsOwnKey() throws {
        let s = try decode(AppSettings.self, """
            {"insertion": "teleport", "readerPosition": "nowhere", "typingMaxChars": "many", "audioDays": 3,
             "appOverrides": {"com.apple.TextEdit": "typing", "com.example.Old": "teleport"}}
            """)
        #expect(s.insertion == .auto)
        #expect(s.readerPosition == .at(.topRight))
        #expect(s.typingMaxChars == 400)
        #expect(s.audioDays == 3)
        #expect(s.appOverrides == ["com.apple.TextEdit": .typing])
    }

    @Test func aProfileFromBeforeTheNewFieldsLoads() throws {
        let p = try decode(Profile.self, """
            {"id": "x", "name": "Mine", "description": "", "prompt": "Fix it.", "autoProcess": true, "showPreview": false,
             "preserveParagraphs": true, "removeFillers": false, "rewriteWhole": false, "readAloudAfterInsert": false,
             "maxChangeRatio": 0.4}
            """)
        #expect(p.id == "x")
        #expect(p.name == "Mine")
        #expect(p.removeFillers == false)
        #expect(p.maxChangeRatio == 0.4)
        #expect(p.liveTyping == false)
        #expect(p.speechModel == nil)

        var q = p
        q.liveTyping = true; q.speechModel = "small.en"
        #expect(try roundTrip(q) == q)
    }

    @Test func theBuiltInsStillRoundTrip() throws {
        let profiles = BuiltInProfiles.create()
        #expect(try roundTrip(profiles) == profiles)
    }
}
