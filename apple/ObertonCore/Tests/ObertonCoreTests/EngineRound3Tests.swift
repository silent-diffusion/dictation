import Foundation
import Testing
@testable import ObertonCore

// Windows: tests/Dictation.Tests/FirstRunModelsTests.cs (the new-install pick survives an early settings save and is
// kept), asr_server.py (generate_with_fallback's rule, is_phantom on restored times), SpeechGuard.cs
// (char.IsLetterOrDigit per UTF-16 unit), asr_server.py `_noise_floor` (np.percentile).
@Suite struct EngineRound3Tests {
    @Test func aNewInstallsSpeechModelSurvivesTheLaunchsSettingsSave() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "oberton-firstrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let setup = FirstRunSpeech(file: dir.appending(path: "speech-setup.json"))
        // First launch: no settings.json, so the device's model is picked, and written down at once.
        #expect(setup.atLaunch(newInstall: true) { "small.en" } == "small.en")
        // The launch saves settings.json straight away (startProfiles); the pick lives beside it, untouched.
        let settings = JSONFile<AppSettings>(url: dir.appending(path: "settings.json"))
        #expect(settings.save(AppSettings()))
        // Quit before the download ended, launch again: settings.json is there now, the pick is still waiting.
        #expect(setup.atLaunch(newInstall: false) { "large-v3-turbo" } == "small.en")
        // Downloaded and in use: forgotten.
        setup.pending = nil
        #expect(setup.atLaunch(newInstall: false) { "large-v3-turbo" } == nil)
    }

    @Test func fallbackFollowsFasterWhisper() {
        #expect(FallbackRule.fallback(ratio: 2.5, avgLogprob: -0.2, noSpeech: 0) == "compressionRatioThreshold")
        #expect(FallbackRule.fallback(ratio: 1.2, avgLogprob: -1.2, noSpeech: 0.1) == "logProbThreshold")
        #expect(FallbackRule.fallback(ratio: 2.5, avgLogprob: -1.2, noSpeech: 0.7) == nil) // silence: no hotter decode
        #expect(FallbackRule.fallback(ratio: 2.5, avgLogprob: -0.5, noSpeech: 0.7) == "compressionRatioThreshold")
        #expect(FallbackRule.fallback(ratio: 1.2, avgLogprob: -0.4, noSpeech: 0) == nil)
    }

    @Test func aStockPhraseIsTimedInTheRecordingWithoutEvening() {
        // "Thank you." cut from two short stretches 3 s apart: 1 s in the cut audio, 4 s in the recording. faster-
        // whisper's voice filter reports the recording's times, so the phrase is stretched over seconds: made up.
        let prepared = WhisperPrep.Prepared(audio: [], regions: [0..<8_000, 56_000..<64_000])
        let seg = WhisperText.Segment(text: "Thank you.", start: 0, end: 1.0, noSpeechProb: 0, avgLogprob: -0.2)
        #expect(!WhisperText.isPhantom(seg))
        #expect(WhisperText.isPhantom(prepared.originalTimes(seg)))
    }

    @Test func lettersOutsideTheBMPDontCount() {
        #expect(!SpeechGuard.hasLetterOrDigit("𠀀𝐀"))
        #expect(SpeechGuard.shouldDiscard("𠀀", recorded: 5, peakLevel: 0.9))
        #expect(SpeechGuard.hasLetterOrDigit("a𠀀"))
        #expect(!SpeechGuard.hasLetterOrDigit("² ½ Ⅻ"))
    }

    @Test func theLevellersFloorIsNumPysPercentile() {
        #expect(VolumeLeveller.percentile10((0..<9).map(Float.init)) == nil)
        // np.percentile(range(11), 10) == 1.0; np.percentile(range(10), 10) == 0.9
        #expect(VolumeLeveller.percentile10((0..<11).map(Float.init)) == 1)
        #expect(abs((VolumeLeveller.percentile10((0..<10).map(Float.init)) ?? 0) - 0.9) < 1e-6)
    }

    @Test func liveCadenceIsWindows() {
        #expect(WhisperDictation.partialNew == 0.6 && WhisperDictation.partialFirst == 0.5)
        #expect(WhisperLive.interval == (SpeechModelChoice.isAppleSilicon ? 1.0 : 2.5))
    }
}
