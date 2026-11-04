import Testing
@testable import ObertonCore

// Windows: RuntimeInstallerTests (hardware defaults: GPU → large-v3-turbo, CPU → small.en).
@Suite struct SpeechModelChoiceTests {
    static let gb: UInt64 = 1 << 30

    @Test func appleSiliconWithRoomGetsTurbo() {
        #expect(SpeechModelChoice.recommended(language: "en", memory: 16 * Self.gb, appleSilicon: true, phone: false) == "large-v3-turbo")
        #expect(SpeechModelChoice.recommended(language: "de", memory: 32 * Self.gb, appleSilicon: true, phone: false) == "large-v3-turbo")
    }
    @Test func smallerMacsAndPhonesGetSmallEnglish() {
        #expect(SpeechModelChoice.recommended(language: "en", memory: 8 * Self.gb, appleSilicon: true, phone: false) == "small.en")
        #expect(SpeechModelChoice.recommended(language: "en", memory: 32 * Self.gb, appleSilicon: false, phone: false) == "small.en")
        #expect(SpeechModelChoice.recommended(language: "en", memory: 8 * Self.gb, appleSilicon: true, phone: true) == "small.en")
    }
    @Test func otherLanguagesWithoutRoomStayOnAppleSpeech() {
        #expect(SpeechModelChoice.recommended(language: "fr", memory: 8 * Self.gb, appleSilicon: true, phone: false) == "")
    }
    @Test func noLanguageSetFollowsTheSystem() {
        #expect(SpeechModelChoice.recommended(language: "", memory: 8 * Self.gb, appleSilicon: true, phone: false, systemLanguage: "en") == "small.en")
        #expect(SpeechModelChoice.recommended(language: "", memory: 8 * Self.gb, appleSilicon: true, phone: false, systemLanguage: "ja") == "")
    }
}
