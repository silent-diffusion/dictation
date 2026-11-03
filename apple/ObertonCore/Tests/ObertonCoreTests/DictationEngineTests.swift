import AVFoundation
import Foundation
import Testing
@testable import ObertonCore

// Ported from tests/Dictation.Tests/SpeechGuardTests.cs, FragmentStitcherTests.cs and TurnaroundTests.cs, plus the
// usage keeping (ThreeFourTests) and the offline rule for Ollama cloud models.

@Suite struct SpeechGuardTests {
    static let short = 0.6, medium = 1.5, long = 6.0

    @Test(arguments: ["Thank you.", "Thanks for watching!", "you"])
    func stockPhrasesFromShortRecordingsAreDropped(_ text: String) {
        #expect(SpeechGuard.shouldDiscard(text, recorded: Self.medium, peakLevel: 0.5))
    }
    @Test func stockPhraseFromAQuietRecordingIsDroppedEvenWhenLong() { #expect(SpeechGuard.shouldDiscard("Thank you.", recorded: Self.long, peakLevel: 0.05)) }
    @Test func aClearlySpokenThankYouIsKept() { #expect(!SpeechGuard.shouldDiscard("Thank you.", recorded: Self.long, peakLevel: 0.6)) }
    @Test func aShortQuietRecordingIsDropped() { #expect(SpeechGuard.shouldDiscard("Yes.", recorded: Self.short, peakLevel: 0.05)) }
    @Test func aShortButClearlySpokenWordIsKept() { #expect(!SpeechGuard.shouldDiscard("Yes.", recorded: Self.short, peakLevel: 0.5)) }
    @Test func normalDictationIsKept() {
        #expect(!SpeechGuard.shouldDiscard("Thank you for the update, I'll reply tomorrow.", recorded: Self.long, peakLevel: 0.4))
    }
    @Test func punctuationOnlyIsDropped() { #expect(SpeechGuard.shouldDiscard("...", recorded: Self.long, peakLevel: 0.6)) }
    @Test func subtitleCreditsAreStockPhrases() {
        #expect(SpeechGuard.isStockPhrase("Subtitles by the Amara.org community"))
        #expect(!SpeechGuard.isStockPhrase("Subtitles are on the left"))
    }
}

@Suite struct FragmentStitcherTests {
    static func join(_ pieces: String...) -> String { FragmentStitcher.join(pieces) }

    @Test func wholeSentencesAreJoinedWithASpace() { #expect(Self.join("I went to the store.", "Then I went home.") == "I went to the store. Then I went home.") }
    @Test func aPieceCutMidSentenceContinuesInLowercase() {
        #expect(Self.join("I went to the store", "And then bought milk.") == "I went to the store and then bought milk.")
    }
    @Test func namesAtACutKeepTheirCapital() { #expect(Self.join("Yesterday we talked to", "Sarah about it.") == "Yesterday we talked to Sarah about it.") }
    @Test func aWordLowercaseElsewhereIsLowercasedAtACut() {
        #expect(Self.join("The budget for the", "Project is fine, and the project starts soon.")
            == "The budget for the project is fine, and the project starts soon.")
    }
    @Test func aFullStopBeforeALowercaseContinuationGoes() {
        #expect(Self.join("I went to the store.", "and bought milk.") == "I went to the store and bought milk.")
    }
    @Test func abbreviationsKeepTheirDot() { #expect(Self.join("Bring fruit, e.g.", "apples and pears.") == "Bring fruit, e.g. apples and pears.") }
    @Test func aWordSaidAcrossTheCutAppearsOnce() { #expect(Self.join("Put it on the", "the table please.") == "Put it on the table please.") }
    @Test func iKeepsItsCapital() { #expect(Self.join("Tomorrow", "I think I will go.") == "Tomorrow I think I will go.") }
    @Test func emptyPiecesAndExtraSpacesAreIgnored() { #expect(Self.join("  hello  ", "", " there .") == "Hello there.") }
    @Test func piecesWithTheirOwnLeadingSpaceDontDoubleIt() { #expect(Self.join("Hello there.", " How are you?", "") == "Hello there. How are you?") }
}

@Suite struct TurnaroundTests {
    static func sample(_ seconds: Double, speech: String = "apple-speech:en-US", ai: String = "ollama:qwen2.5:3b", loaded: Bool = false) -> TurnaroundSample {
        TurnaroundSample(speechModel: speech, aiModel: ai, seconds: seconds, modelLoaded: loaded)
    }

    @Test func averagesTheLastThreeWithTheSameModels() {
        var u = UsageLog()
        for s in [9.0, 1, 2, 3] { u.recordTurnaround(Self.sample(s)) }
        let (avg, n) = u.recentTurnaround(speechModel: "apple-speech:en-US", aiModel: "ollama:qwen2.5:3b")
        #expect(n == 3)
        #expect(abs(avg! - 2) < 0.001) // 1, 2, 3: the 9 s is older than the last three
    }

    @Test func runsThatLoadedAModelAreLeftOut() {
        var u = UsageLog()
        u.recordTurnaround(Self.sample(1))
        u.recordTurnaround(Self.sample(12, loaded: true))
        let (avg, n) = u.recentTurnaround(speechModel: "apple-speech:en-US", aiModel: "ollama:qwen2.5:3b")
        #expect(n == 1)
        #expect(abs(avg! - 1) < 0.001)
    }

    @Test func otherModelsDontCountAndNoAIIsItsOwnPair() {
        var u = UsageLog()
        u.recordTurnaround(Self.sample(1.5, speech: "apple-speech:de-DE"))
        u.recordTurnaround(Self.sample(4, ai: "ollama:qwen2.5:7b"))
        u.recordTurnaround(Self.sample(0.6, ai: ""))
        #expect(u.recentTurnaround(speechModel: "apple-speech:en-US", aiModel: "ollama:qwen2.5:3b").seconds == nil)
        #expect(abs(u.recentTurnaround(speechModel: "apple-speech:en-US", aiModel: "").seconds! - 0.6) < 0.001)
        #expect(abs(u.recentTurnaround(speechModel: "APPLE-SPEECH:DE-DE", aiModel: "ollama:qwen2.5:3b").seconds! - 1.5) < 0.001)
    }

    @Test func onlyTheLatestHundredAreKept() {
        var u = UsageLog()
        for i in 0..<(UsageLog.keepTurnarounds + 20) { u.recordTurnaround(Self.sample(Double(i + 1))) }
        #expect(u.samples.count == UsageLog.keepTurnarounds)
        #expect(abs(u.recentTurnaround(speechModel: "apple-speech:en-US", aiModel: "ollama:qwen2.5:3b").seconds! - 119) < 0.001)
    }
}

@Suite struct UsageKeepingTests {
    static func entry(_ daysAgo: Int, aiEdit: String? = nil, safetyNet: Bool = false) -> HistoryEntry {
        var e = HistoryEntry(transcription: "hello there", aiEdit: aiEdit, inserted: aiEdit ?? "hello there", profileName: "P", model: nil,
                             appName: "Mail", seconds: 2, turnaroundSeconds: 1, warning: nil, safetyNet: safetyNet)
        e.date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return e
    }

    @Test func usageIsSeededFromHistory() {
        let log = UsageLog(seed: [Self.entry(0, aiEdit: "Hello there."), Self.entry(1), Self.entry(1, safetyNet: true)])
        #expect(log.days.values.reduce(0) { $0 + $1.dictations } == 3)
        #expect(log.totalWords == 6)
        let today = log.days[UsageLog.key(Date())]!
        #expect(today.aiEdits == 1 && today.aiKept == 1)
        // A safety-net rejection counts as worked on, not kept; no AI at all counts as neither.
        let yesterday = log.days[UsageLog.key(Calendar.current.date(byAdding: .day, value: -1, to: Date())!)]!
        #expect(yesterday.aiEdits == 1 && yesterday.aiKept == 0)
    }

    @Test func daysOlderThan750ArePruned() {
        var log = UsageLog(seed: [Self.entry(800), Self.entry(700)])
        log.prune()
        #expect(log.days.count == 1)
        log.record(Self.entry(900))
        #expect(log.days.count == 1)
    }

    @Test func theStreakCountsDaysInARow() {
        #expect(UsageLog().streak() == 0)
        #expect(UsageLog(seed: [Self.entry(0), Self.entry(1), Self.entry(2), Self.entry(4)]).streak() == 3)
        // Nothing yet today: the streak up to yesterday still stands.
        #expect(UsageLog(seed: [Self.entry(1), Self.entry(2)]).streak() == 2)
        #expect(UsageLog(seed: [Self.entry(2)]).streak() == 0)
    }

    @Test func oldTurnaroundListsStillLoad() throws {
        let json = #"{"days":{},"turnarounds":[1.5,2.0],"totalWords":12}"#
        let log = try JSONDecoder().decode(UsageLog.self, from: Data(json.utf8))
        #expect(log.totalWords == 12)
        #expect(log.samples.isEmpty)
    }
}

@Suite struct OfflineAndTimeoutTests {
    @Test func ollamaCloudModelsAreRecognized() {
        #expect(ModelID.isOllamaCloud("gpt-oss:120b-cloud"))
        #expect(ModelID.isOllamaCloud("kimi-k2:cloud"))
        #expect(ModelID.isOllamaCloud("qwen3-coder:480b-cloud:latest") || ModelID.isOllamaCloud("deepseek-v3.1:671b-cloud:latest"))
        #expect(!ModelID.isOllamaCloud("qwen2.5:3b"))
        #expect(!ModelID(provider: .ollama, name: "gpt-oss:120b-cloud").isLocal)
    }

    @Test func offlineBlocksOllamaCloudModels() async {
        var settings = AppSettings()
        settings.cloud.keepOffline = true
        let p = TextProcessor(settings: settings)
        #expect(throws: UserFacingError.self) { try p.backend(for: ModelID(provider: .ollama, name: "gpt-oss:120b-cloud")) }
        #expect((try? p.backend(for: ModelID(provider: .ollama, name: "qwen2.5:3b"))) != nil)
        var profile = BuiltInProfiles.create().first { !$0.isRaw }!
        profile.model = "ollama:gpt-oss:120b-cloud"
        let r = await p.process("make sure the build is green", profile: profile)
        #expect(r.text == "make sure the build is green")
        #expect(!r.modified)
        #expect(r.warning?.contains("ollama.com") == true)
    }

    @Test func timeoutsGrowForModelsHeldInMemory() {
        #expect(ModelSize().dictationTimeout(setting: 60) == 60)
        #expect(ModelSize().dictationTimeout(setting: 5) == 10)
        #expect(ModelSize(large: true, dense: false).dictationTimeout(setting: 60) == 180)
        #expect(ModelSize(large: true, dense: true).dictationTimeout(setting: 60) == 300)
        #expect(ModelSize().askTimeout(setting: 60) == 180)
        #expect(ModelSize(large: true, dense: false).askTimeout(setting: 60) == 420)
        #expect(ModelSize(large: true, dense: true).askTimeout(setting: 60) == 900)
    }

    @Test func modelSizesAreParsed() {
        #expect(LocalModel.parseBillions("7.6B", bytes: 0) == 7.6)
        #expect(abs(LocalModel.parseBillions("494.03M", bytes: 0) - 0.49403) < 1e-9)
        #expect(LocalModel.parseBillions(nil, bytes: 6_000_000_000) == 10)
        #expect(LocalModel(name: "qwen3:30b-a3b", billions: 30.5, bytes: 0, family: "qwen3moe").isMixture)
        #expect(LocalModel(name: "gpt-oss:20b", billions: 20.9, bytes: 0, family: "gptoss").isMixture)
        #expect(!LocalModel(name: "gemma3:27b", billions: 27, bytes: 0, family: "gemma3").isMixture)
        #expect(LocalModel(name: "x", billions: 27, bytes: 17_000_000_000, family: "").heldInRam(gpuBytes: 12_000_000_000))
        #expect(!LocalModel(name: "x", billions: 3, bytes: 2_000_000_000, family: "").heldInRam(gpuBytes: nil))
    }
}

@Suite struct VolumeLevellerTests {
    /// A tone at this amplitude for this long, at 16 kHz.
    static func tone(_ amplitude: Float, seconds: Double) -> [Float] {
        (0..<Int(16000 * seconds)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16000) }
    }
    static func rmsDB(_ s: ArraySlice<Float>) -> Float { 20 * log10((s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()) }

    @Test func quietSpeechIsBroughtUpAndSilenceStaysSilent() {
        let leveller = VolumeLeveller(sampleRate: 16000)
        // A quiet room (−70 dBFS noise), then quiet speech at about −46 dBFS.
        var audio = (0..<16000).map { _ in Float.random(in: -0.0004...0.0004) } + Self.tone(0.007, seconds: 3)
        leveller.process(&audio)
        let speech = Self.rmsDB(audio[(16000 + 32000)...])
        #expect(speech > -26 && speech < -14) // near −20 dBFS
        #expect(Self.rmsDB(audio[..<16000]) < -60)
    }

    @Test func loudSpeechIsNotClipped() {
        let leveller = VolumeLeveller(sampleRate: 16000)
        var audio = (0..<8000).map { _ in Float.random(in: -0.0004...0.0004) } + Self.tone(0.99, seconds: 2)
        leveller.process(&audio)
        #expect(audio.allSatisfy { abs($0) <= 1 })
    }
}

/// The overlay's level meter, as MicCapture feeds it: one level per 50 ms of audio, `min(1, √rms · 1.8)`, silence 0.
@Suite struct MeterLevelTests {
    static func buffer(_ samples: [Float], rate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        b.frameLength = AVAudioFrameCount(samples.count)
        for (i, s) in samples.enumerated() { b.floatChannelData![0][i] = s }
        return b
    }

    @Test func oneLevelPer50Milliseconds() {
        // A 4096-frame tap at 48 kHz (85 ms) gives two levels, as Windows' 50 ms buffers would.
        #expect(LiveTranscriber.meterLevels(Self.buffer([Float](repeating: 0.01, count: 4096))).count == 2)
        #expect(LiveTranscriber.meterLevels(Self.buffer([Float](repeating: 0.01, count: 800), rate: 16_000)).count == 1)
    }

    @Test func windowsScale() {
        let quiet: Float = LiveTranscriber.meterLevels(Self.buffer([Float](repeating: 0.04, count: 2400)))[0]
        let expected: Float = 0.36 // √0.04 · 1.8
        #expect(abs(quiet - expected) < 0.0001)
        let loud: Float = LiveTranscriber.meterLevels(Self.buffer([Float](repeating: 0.5, count: 2400)))[0]
        #expect(loud == 1)
        let silent: Float = LiveTranscriber.meterLevels(Self.buffer([Float](repeating: 0, count: 2400)))[0]
        #expect(silent == 0)
    }
}
