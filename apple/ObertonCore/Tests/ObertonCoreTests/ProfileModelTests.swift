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

// The AI step: errors, budgets, safety nets (Windows' TextProcessingTests, RewriteWholeTests, ThreeZeroTests).

/// A back end that records the token budgets it was given.
final class BudgetBackend: LanguageModelBackend, @unchecked Sendable {
    var budgets: [Int] = []
    var fail: (String) -> Error? = { _ in nil }
    func complete(system: String, examples: [(input: String, output: String)], user: String, maxTokens: Int) async throws -> String {
        budgets.append(maxTokens)
        if let e = fail(user) { throw e }
        return user.replacingOccurrences(of: "<transcript>\n", with: "").replacingOccurrences(of: "\n</transcript>", with: "")
    }
}

@Suite struct AIStepTests {
    let processor = TextProcessor(settings: AppSettings())
    let profile = BuiltInProfiles.create()[0]
    static let long = (0..<60).map { "This is sentence number \($0) of a long dictation." }.joined(separator: " ")

    /// Windows throws for the whole dictation (ProcessAsync), and DictationController inserts the original words.
    @Test func anAIErrorInOnePartKeepsTheWholeDictationAsSpoken() async {
        let b = BudgetBackend()
        b.fail = { $0.contains("number 30 ") ? UserFacingError("The AI model took too long to respond.") : nil }
        let r = await processor.process(Self.long, profile: profile, backend: b)
        #expect(r.text == Self.long && !r.modified && !r.safetyNet)
        #expect(r.error == "The AI model took too long to respond.")
        #expect(r.warning == "The AI model took too long to respond. Inserting your original words.")
    }

    @Test func aSafetyNetIsNotAnError() async {
        let r = await processor.process("i went to the store yesterday and bought apples and oranges for the party", profile: profile,
                                        backend: FakeBackend { _ in "Fruit." })
        #expect(r.safetyNet && r.error == nil)
    }

    @Test func localAndCloudModelsGetWindowsTokenBudgets() async {
        let local = BudgetBackend(), cloud = BudgetBackend()
        _ = await processor.process("hello there everyone", profile: profile, backend: local)
        _ = await processor.process("hello there everyone", profile: profile, backend: cloud, cloud: true)
        let n = "hello there everyone".count // the text itself, as Windows counts it
        #expect(local.budgets == [min(4096, n / 2 + 256)])
        #expect(cloud.budgets == [min(8192, n / 2 + 512)])
        var rewrite = profile
        rewrite.rewriteWhole = true
        let big = BudgetBackend()
        _ = await processor.process(String(repeating: "word ", count: 4000), profile: rewrite, backend: big, cloud: true)
        #expect(big.budgets.first! > 4096) // a long cloud rewrite isn't capped at the local 4096
    }

    @Test func aRawProfileAndEmptyTextNeverReachTheAI() async {
        let raw = BuiltInProfiles.create().first { $0.isRaw }!
        let r = await processor.process("  hello  ", profile: raw)
        #expect(r.text == "hello" && r.error == nil && r.warning == nil)
    }

    @Test func cloudModelsAreBlockedOfflineWithWindowsWords() async {
        var p = profile
        p.model = "anthropic:claude-haiku-4-5-20251001"
        let r = await processor.process("hello there", profile: p)
        #expect(r.error == "This profile uses a cloud model, but \"Keep everything offline\" is on. Turn it off under Settings › Cloud AI, or pick a local model.")
    }

    /// Windows: cloud vs local ids, with the provider in any case.
    @Test func providersAreReadInAnyCase() {
        #expect(ModelID("OpenAI:gpt-4.1-mini") == ModelID(provider: .openai, name: "gpt-4.1-mini"))
        #expect(ModelID("ANTHROPIC:claude-opus-5-5")?.isCloud == true)
        #expect(ModelID("ollama:qwen2.5:3b")?.isCloud == false)
    }

    /// Windows' Uri.IsLoopback: any 127.x address, localhost and ::1 are on this device.
    @Test func onlyLoopbackAddressesAreLocal() {
        for ok in ["http://127.0.0.1:11434", "http://127.0.0.2:11435", "http://localhost:11434", "http://[::1]:11434"] {
            #expect(OllamaBackend.isLoopback(URL(string: ok)!), "\(ok)")
        }
        for bad in ["http://192.168.1.2:11434", "http://example.com", "http://127.0.0.1.example.com", "http://1270.0.0.1"] {
            #expect(!OllamaBackend.isLoopback(URL(string: bad)!), "\(bad)")
        }
        var s = AppSettings()
        s.ollamaEndpoint = "http://10.0.0.5:11434"
        #expect(s.enforceLocalEndpoint() && s.ollamaEndpoint == AppSettings().ollamaEndpoint)
    }

    /// Windows: Long_dictation_splits_into_small_segments_and_joins_back_exactly.
    @Test func longDictationSplitsIntoSmallSegmentsAndJoinsBackExactly() {
        let segments = TextChunker.segment(Self.long)
        #expect(segments.count > 3)
        #expect(segments.allSatisfy { $0.text.count <= TextChunker.segmentChars && $0.text.hasSuffix(".") })
        #expect(TextChunker.join(segments, segments.map(\.text)) == Self.long)
    }
}

/// Windows' RewriteWholeTests (the parts that don't need type-while-speaking).
@Suite struct RewriteWholeTests {
    static let rambling = "okay so I need to tell Mark that the report is going to be late because the numbers from finance " +
        "came in on Thursday instead of Monday and um I think we can have it to him by next Wednesday " +
        "and also ask if he wants the summary slides too or just the spreadsheet"
    static let email = "Hi Mark,\n\nThe report will be a few days late: finance sent the numbers on Thursday instead of Monday. " +
        "I expect to have it to you by next Wednesday.\n\nWould you like summary slides as well, or just the spreadsheet?\n\nThanks"

    @Test func aReshapedEmailPassesTheRewriteSafetyNet() {
        #expect(OutputSanitizer.rewriteImplausibility(input: Self.rambling, output: Self.email) == nil)
    }
    @Test func aShortNoteMayGrowIntoAFullEmail() {
        #expect(OutputSanitizer.rewriteImplausibility(input: "tell mark the report is late",
            output: "Hi Mark,\n\nI wanted to let you know that the report will be a little late. I'll send it as soon as it's ready.\n\nBest regards") == nil)
    }
    @Test(arguments: ["", "Late."]) func emptyOrNearlyNothingIsRejected(_ output: String) {
        #expect(OutputSanitizer.rewriteImplausibility(input: Self.rambling, output: output) != nil)
    }
    @Test func runawayOutputIsRejected() {
        #expect(OutputSanitizer.rewriteImplausibility(input: "tell mark the report is late",
                                                      output: Array(repeating: "word", count: 80).joined(separator: " ")) != nil)
    }
    @Test func rewritingProfilesAreToldToLayTheTextOut() {
        var p = Profile(prompt: "Turn this into an email.", rewriteWhole: true)
        #expect(PromptBuilder.systemPrompt(for: p).contains("Lay the text out"))
        p.rewriteWhole = false
        #expect(PromptBuilder.systemPrompt(for: p).contains("Preserve any paragraph breaks"))
    }
}

/// A broken settings.json or profiles.json must not cost the user their data (Windows' JsonStore.Load).
@Suite(.serialized) struct BrokenFileTests {
    @Test func anUnreadableFileIsKeptAsBadAndLogged() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "oberton-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "profiles.json")
        let broken = Data(#"[{"name": "Mine", "prompt": "Keep it"#.utf8)
        try broken.write(to: url)
        var logged: [String] = []
        CoreLog.sink = { level, message in logged.append(level + " " + message) }
        defer { CoreLog.sink = nil }
        #expect(JSONFile<[Profile]>(url: url).load() == nil)
        #expect(try Data(contentsOf: url.appendingPathExtension("bad")) == broken)
        #expect(logged.contains { $0.hasPrefix("ERROR Could not read profiles.json; keeping a .bad copy") })
        // A file that is fine loads as before, dates included.
        JSONFile<[TurnaroundSample]>(url: dir.appending(path: "t.json")).save([TurnaroundSample(speechModel: "s", aiModel: "", seconds: 1, modelLoaded: false)])
        #expect(JSONFile<[TurnaroundSample]>(url: dir.appending(path: "t.json")).load()?.count == 1)
    }

}
