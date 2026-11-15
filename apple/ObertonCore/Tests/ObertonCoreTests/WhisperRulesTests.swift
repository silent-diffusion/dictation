import Foundation
import Testing
@testable import ObertonCore

// Windows' guards against Whisper's quirks (inference/asr_server.py, which has no tests of its own on Windows), with the
// Windows test inputs where there are any (ExtendedNotesTests.cs for the loops, NotesRedoTests.cs for the parts).

@Suite struct WhisperTextTests {
    static func seg(_ text: String, noSpeech: Double = 0, logprob: Double = -0.2, seconds: Double = 1, ratio: Double? = nil) -> WhisperText.Segment {
        WhisperText.Segment(text: text, start: 0, end: seconds, noSpeechProb: noSpeech, avgLogprob: logprob,
                            compressionRatio: ratio ?? WhisperText.compressionRatio(text))
    }

    @Test func normIsLowerCaseWithoutPunctuation() {
        #expect(WhisperText.norm(" Thank you! ") == "thank you")
        #expect(WhisperText.norm("Thanks for watching.") == "thanks for watching")
        #expect(WhisperText.norm("It's done, isn't it?") == "it's done isn't it")
        #expect(WhisperText.norm("...") == "")
    }

    @Test func compressionRatioIsZlibsAsInPython() {
        // Python: len(t.encode()) / len(zlib.compress(t.encode()))
        #expect(abs(WhisperText.compressionRatio("Thank you. Thank you. Thank you. Thank you. Thank you. Thank you. Thank you.") - 3.4545454545) < 1e-6)
        #expect(abs(WhisperText.compressionRatio("I went to the store this morning. Then I bought some bread and milk.") - 0.9855072464) < 1e-6)
    }

    @Test func aLoopIsAPhantom() {
        #expect(WhisperText.isPhantom(Self.seg(String(repeating: "I'm going to go. ", count: 8))))
    }

    @Test func emptyOrPunctuationOnlyIsAPhantom() {
        #expect(WhisperText.isPhantom(Self.seg("")))
        #expect(WhisperText.isPhantom(Self.seg("...")))
    }

    @Test func unsureWordsOnProbableSilenceAreAPhantom() {
        #expect(WhisperText.isPhantom(Self.seg("The weather is nice.", noSpeech: 0.7, logprob: -0.6)))
        #expect(!WhisperText.isPhantom(Self.seg("The weather is nice.", noSpeech: 0.7, logprob: -0.3)))
        #expect(!WhisperText.isPhantom(Self.seg("The weather is nice.", noSpeech: 0.5, logprob: -0.9)))
    }

    @Test func aStockPhraseIsAPhantomWhenWhisperDoubtsIt() {
        #expect(WhisperText.isPhantom(Self.seg("Thank you.", noSpeech: 0.3)))           // maybe no speech
        #expect(WhisperText.isPhantom(Self.seg("Thanks for watching!", logprob: -0.7))) // unsure of the words
        #expect(WhisperText.isPhantom(Self.seg("Bye.", seconds: 3)))                    // a word stretched over 3 s
        #expect(WhisperText.isPhantom(Self.seg("Subtitles by the Amara.org community", noSpeech: 0.3)))
        #expect(!WhisperText.isPhantom(Self.seg("Subtitles by the Amara.org community"))) // as on Windows: only when doubted
        #expect(WhisperText.isPhantom(Self.seg("Transcribed by ESO, translated by —", noSpeech: 0.25)))
    }

    @Test func aClearlySaidStockPhraseStays() {
        #expect(!WhisperText.isPhantom(Self.seg("Thank you.", noSpeech: 0.05, logprob: -0.2, seconds: 0.8)))
        #expect(!WhisperText.isPhantom(Self.seg("Thank you for the update.", noSpeech: 0.5, logprob: -0.4, seconds: 3)))
    }

    @Test func sentencesSplitAfterTheirEnd() {
        #expect(WhisperText.sentences(" Hello there. How are you?  Fine! ok ") == ["Hello there.", "How are you?", "Fine!", "ok"])
        #expect(WhisperText.sentences("   ") == [])
        #expect(WhisperText.sentences("No end") == ["No end"])
    }

    @Test func loopsAreCollapsedButASentenceSaidTwiceStays() {
        // ExtendedNotesTests.Loops_are_collapsed_but_a_sentence_said_twice_stays (asr_server.py's own rule, one line).
        #expect(WhisperText.collapseRepeats("Hello. Thank you. Thank you. Thank you. Thank you. Bye.") == "Hello. Thank you. Bye.")
        #expect(WhisperText.collapseRepeats("Thank you. Thank you. Bye.") == "Thank you. Thank you. Bye.")
        #expect(WhisperText.collapseRepeats("The plan is simple. the plan is simple! The plan, is simple.") == "The plan is simple.")
        #expect(WhisperText.collapseRepeats("") == "")
    }

    @Test func thePromptLeavesOutLoopsAndStockPhrases() {
        #expect(WhisperText.prompt(vocabulary: "Kubernetes, Oberton", committed: "") == "Kubernetes, Oberton")
        #expect(WhisperText.prompt(vocabulary: "", committed: "We met Anna. Thank you. Thank you. Thank you. Thanks.") == "We met Anna.")
        #expect(WhisperText.prompt(vocabulary: "Oberton", committed: "So we went. Thank you.") == "Oberton So we went.")
        let long = String(repeating: "word ", count: 200) + "The end."
        #expect(WhisperText.prompt(vocabulary: "", committed: long).unicodeScalars.count == 200)
        #expect(WhisperText.prompt(vocabulary: "", committed: long).hasSuffix("word The end."))
    }

    @Test func aStockPhraseRepeatingTheOneJustCommittedAddsNothing() {
        #expect(WhisperText.newText("Thank you. Thank you.", after: "We are done. Thank you.") == "")
        #expect(WhisperText.newText("Thank you.", after: "Thank you.") == "")
        #expect(WhisperText.newText("Thank you.", after: "We are done.") == "Thank you.")   // not just committed
        #expect(WhisperText.newText("Thank you. Bye.", after: "Thank you.") == "Thank you. Bye.")
        #expect(WhisperText.newText("Next point. Next point. Next point.", after: "") == "Next point.")
        #expect(WhisperText.newText("And more.", after: "Thank you.") == "And more.")
    }
}

@Suite struct WhisperMarkerTests {
    @Test func soundMarkersAreNotWords() {
        #expect(WhisperEngine.clean(" (clapping) ") == "")
        #expect(WhisperEngine.clean("♪ ♪") == "")
        #expect(WhisperEngine.clean("*laughs*") == "")
        #expect(WhisperEngine.clean("[Music] Welcome back.") == "Welcome back.")
        #expect(WhisperEngine.clean("We met (briefly) on Monday.") == "We met (briefly) on Monday.")
    }
}

@Suite struct WhisperPrepTests {
    static let rate = 16_000

    /// A voice-like tone (150 Hz with harmonics) at `db` dBFS RMS.
    static func voice(_ seconds: Double, db: Double) -> [Float] {
        let a = pow(10, db / 20) * 2.0.squareRoot() / 1.25
        return (0..<Int(seconds * Double(rate))).map { i in
            let t = Double(i) / Double(rate)
            return Float(a * (sin(2 * .pi * 150 * t) + 0.5 * sin(2 * .pi * 300 * t) + 0.25 * sin(2 * .pi * 450 * t)))
        }
    }

    static func noise(_ seconds: Double, db: Double) -> [Float] {
        var g = SystemRandomNumberGenerator()
        let a = pow(10, db / 20) * 3.0.squareRoot()
        return (0..<Int(seconds * Double(rate))).map { _ in Float(Double.random(in: -a...a, using: &g)) }
    }

    static func rms(_ x: ArraySlice<Float>) -> Double {
        20 * log10((x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot())
    }

    @Test func levelBringsQuietAndLoudSpeechToTheSameLoudness() {
        // Quiet speech, a pause, loud speech, over a quiet room.
        let room = Self.noise(0.5, db: -70)
        let audio = room + Self.voice(1.5, db: -50) + Self.noise(1, db: -70) + Self.voice(1.5, db: -14) + room
        let out = WhisperPrep.level(audio)
        let quiet = Self.rms(out[Int(1.0 * 16_000)..<Int(1.8 * 16_000)]), loud = Self.rms(out[Int(3.3 * 16_000)..<Int(4.2 * 16_000)])
        #expect(abs(quiet - -20) < 3, "quiet speech came out at \(quiet) dBFS")
        #expect(abs(loud - -20) < 3, "loud speech came out at \(loud) dBFS")
        // The room in the pause isn't raised to speech level.
        #expect(Self.rms(out[Int(2.6 * 16_000)..<Int(2.9 * 16_000)]) < -40)
        #expect(out.allSatisfy { abs($0) <= 1 })
    }

    @Test func levelLeavesAudioWithoutSpeechAlone() {
        let audio = Self.noise(2, db: -60)
        #expect(WhisperPrep.level(audio) == audio)
    }

    @Test func speechRegionsAreJoinedAcrossShortGapsAndPadded() {
        let audio = Self.noise(1, db: -70) + Self.voice(1, db: -30) + Self.noise(0.3, db: -70) + Self.voice(1, db: -30)
            + Self.noise(2, db: -70) + Self.voice(0.1, db: -30) + Self.noise(1, db: -70)
        let regions = WhisperPrep.speechRegions(audio)
        #expect(regions.count == 1) // the 0.3 s gap is joined; the 0.1 s blip is left out
        let r = regions[0]
        #expect(abs(Double(r.lowerBound) / 16_000 - 0.8) < 0.05)
        #expect(abs(Double(r.upperBound) / 16_000 - 3.5) < 0.05)
    }

    @Test func originalTimeMapsBackAcrossTheCuts() {
        let p = WhisperPrep.Prepared(audio: [], regions: [16_000..<32_000, 80_000..<96_000])
        #expect(p.originalTime(0.5) == 1.5)
        #expect(p.originalTime(1.0) == 2.0)
        #expect(p.originalTime(1.5) == 5.5)
        #expect(p.originalTime(9) == 6.0)
    }

    @Test func voiceIsHeardButNotNoiseOrSilence() {
        #expect(WhisperPrep.voicedSeconds(Self.voice(1, db: -30)) > 0.9)
        #expect(WhisperPrep.voicedSeconds(Self.noise(2, db: -30)) == 0)
        #expect(WhisperPrep.voicedSeconds([Float](repeating: 0, count: 32_000)) == 0)
        #expect(WhisperPrep.voicedSeconds(Self.voice(1, db: -60)) == 0) // too quiet to count, as recorded
    }

    @Test func nothingIsDecodedWhenNoOneSpoke() {
        #expect(WhisperPrep.evened(Self.noise(5, db: -45)) == nil)
        #expect(WhisperPrep.voiceOnly(Self.noise(5, db: -45)) == nil)
        #expect(WhisperPrep.evened([Float](repeating: 0, count: 80_000)) == nil)
        #expect(WhisperPrep.evened(Self.voice(0.2, db: -20)) == nil) // under 0.3 s
    }

    @Test func evenedKeepsOnlyTheSpeech() throws {
        let audio = Self.noise(2, db: -65) + Self.voice(1, db: -45) + Self.noise(3, db: -65) + Self.voice(1, db: -45) + Self.noise(2, db: -65)
        let p = try #require(WhisperPrep.evened(audio))
        #expect(p.regions.count == 2)
        #expect(Double(p.audio.count) / 16_000 < 3)
        #expect(abs(Self.rms(p.audio[8_000..<16_000]) - -20) < 3) // brought up from −45 dBFS
    }
}

@Suite struct NotesRedoTests {
    @Test func partsAreCutInThePauses() {
        // NotesRedoTests.Parts_are_cut_in_the_pauses
        let pauses = [AudioPause(start: 13, end: 14), AudioPause(start: 40, end: 41)]
        let parts = NotesRedo.planParts(seconds: 60, pauses: pauses)
        #expect(parts[0] == (0.0, 13.5))            // the pause near 15 s
        #expect(parts[1] == (13.5, 28.5))           // no pause near 28.5 s: cut there
        #expect(parts[2] == (28.5, 40.5))           // the pause near 43.5 s
        #expect(parts.last! == (40.5, 60.0))        // the rest, under 23 s, in one
        #expect(NotesRedo.planParts(seconds: 10, pauses: pauses).count == 1)
    }
}
