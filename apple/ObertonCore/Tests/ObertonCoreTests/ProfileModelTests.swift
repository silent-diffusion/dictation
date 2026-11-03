import Foundation
import Testing
@testable import ObertonCore

// Which models a profile works with (Windows' SpeechModelTests and ThreeFourTests).

@Suite struct ProfileModelTests {
    /// Windows: A_profile_uses_its_own_speech_model_or_the_one_in_settings.
    @Test func aProfileUsesItsOwnSpeechModelOrTheOneInSettings() {
        var s = AppSettings()
        s.speechModel = "large-v3-turbo"
        #expect(s.speechModel(for: Profile()) == "large-v3-turbo")
        var blank = Profile()
        blank.speechModel = " "
        #expect(s.speechModel(for: blank) == "large-v3-turbo")
        var own = Profile()
        own.speechModel = "small.en"
        #expect(s.speechModel(for: own) == "small.en")
        #expect(s.speechModel(for: nil) == "large-v3-turbo")
    }

    /// The Mac's extra: a profile can pick Apple Speech while Settings has a Whisper model, and the other way round.
    @Test func aProfileCanPickAppleSpeech() {
        var s = AppSettings()
        s.speechModel = "large-v3-turbo"
        var apple = Profile()
        apple.speechModel = Profile.appleSpeech
        #expect(s.speechModel(for: apple) == "")
        #expect(s.dictating(with: apple).whisperModel == nil)
        s.speechModel = ""
        var whisper = Profile()
        whisper.speechModel = "base.en"
        #expect(s.dictating(with: whisper).whisperModel == "base.en")
        #expect(s.dictating(with: whisper).whisperLanguage == "en") // English-only: the language follows the model
        #expect(s.dictating(with: Profile()).whisperModel == nil)
    }

    @Test func speechModelsHaveNames() {
        #expect(WhisperModels.name(of: "small.en") == "Whisper small (English)")
    }

    /// Windows: Profiles_use_the_read_aloud_voice_unless_they_pick_one.
    @Test func profilesUseTheReadAloudVoiceUnlessTheyPickOne() {
        let p = Profile()
        #expect(p.voice == nil)
        #expect(p.speechModel == nil)
        #expect(p.model == nil)
        #expect(p.liveTyping == false)
        #expect(AppSettings().readerPosition == .at(.topRight))
        #expect(AppSettings().overlayPosition == .bottomLeft)
    }
}
