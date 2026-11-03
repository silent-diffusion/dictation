import AVFoundation
import Foundation
import Testing
@testable import ObertonCore

// The Whisper catalogue, the language it is told, and Extended Notes' commit choice (asr_server.py choose_commit).

@Suite struct WhisperModelTests {
    @Test func windowsModelsInWindowsOrder() {
        #expect(WhisperModels.all.map(\.id) == ["large-v3-turbo", "large-v3", "distil-large-v3", "medium.en", "small.en", "base.en"])
        #expect(WhisperModels.name(of: "base.en") == "Whisper base (English)")
        #expect(WhisperModels.name(of: "nonsense") == "nonsense")
    }

    @Test func englishOnlyModelsAreToldEnglish() {
        #expect(WhisperModels.language(for: "de-DE", model: "base.en") == "en")
        #expect(WhisperModels.language(for: "", model: "distil-large-v3") == "en")
    }

    @Test func multilingualModelsTakeTheLanguageCodeOrDetect() {
        #expect(WhisperModels.language(for: "de-DE", model: "large-v3-turbo") == "de")
        #expect(WhisperModels.language(for: "pt_BR", model: "large-v3") == "pt")
        #expect(WhisperModels.language(for: "", model: "large-v3-turbo") == nil)
    }

    @Test func markersAreNotWords() {
        #expect(WhisperEngine.clean(" [BLANK_AUDIO] ") == "")
        #expect(WhisperEngine.clean("<|startoftranscript|> Hello there. (music)") == "Hello there.")
        #expect(WhisperEngine.clean(" Kubernetes (the cluster) is up.") == "Kubernetes (the cluster) is up.")
    }
}

@Suite struct WhisperLiveTests {
    static func p(_ t: String, _ end: Double) -> WhisperPiece { WhisperPiece(text: t, start: 0, end: end) }

    @Test func commitsUpToTheLastSentenceEnd() {
        let pick = WhisperLive.chooseCommit([Self.p("Hello there.", 2), Self.p("How are you?", 4), Self.p("I was", 5.5)], duration: 7)
        #expect(pick?.text == "Hello there. How are you?")
        #expect(pick?.end == 4)
    }

    @Test func aPhraseEndingAtTheNewestAudioWaits() {
        #expect(WhisperLive.chooseCommit([Self.p("Hello there.", 6.5)], duration: 7) == nil)
    }

    @Test func noSentenceEndWaitsUntilItIsLong() {
        let pieces = [Self.p("and then we", 3), Self.p("went on", 6)]
        #expect(WhisperLive.chooseCommit(pieces, duration: 8) == nil)
        #expect(WhisperLive.chooseCommit(pieces, duration: 13)?.text == "and then we went on")
    }

    @Test func quotedSentenceEndsCount() {
        #expect(WhisperLive.chooseCommit([Self.p("She said \"yes.\"", 2)], duration: 5)?.end == 2)
    }
}

/// Downloads base.en (145 MB) and transcribes a WAV made with `say`. Only when asked:
/// `OBERTON_WHISPER_TEST=<wav> OBERTON_DATA_DIR=<scratch folder> swift test --filter WhisperDownloadTests`.
@Suite struct WhisperDownloadTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OBERTON_WHISPER_TEST"] != nil))
    func downloadsAndTranscribesBaseEnglish() async throws {
        let wav = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OBERTON_WHISPER_TEST"]!)
        if !WhisperModels.isDownloaded("base.en") {
            try await WhisperModels.download("base.en") { _ in }
        }
        #expect(WhisperModels.isDownloaded("base.en"))
        let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let text = try await WhisperEngine.shared.text(samples, model: "base.en", language: "en", prompt: "Oberton")
        print("Whisper heard: \(text)")
        #expect(text.lowercased().contains("quick brown fox"))
        #expect(WhisperEngine.loadedModel == "base.en")
        await WhisperEngine.shared.unload()
        #expect(WhisperEngine.loadedModel == nil)
    }
}
