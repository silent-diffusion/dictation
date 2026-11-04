import Foundation
import Testing
@testable import ObertonCore

/// Windows' ReadAloudSessionTests and ReadAloudJumpTests that read the session's own output (before the time-stretch),
/// sample for sample: the runway, the dither, sentences back to back, waiting on a slow voice, stale audio.
@Suite(.serialized) @MainActor struct ReadAloudRawTests {
    static let rate = SpeechAudio.sampleRate
    static func ramp(_ n: Int) -> [Float] { (1...n).map { Float($0) / Float(n) } }
    static func long(_ c: Character) -> String {
        String(repeating: c, count: 3) + " " + Array(repeating: "words that take a while to say", count: 6).joined(separator: " ") + "."
    }

    private func session(_ text: String) -> ReadAloudSession {
        ReadAloudSession(text: text, voice: "af_heart", speed: 1, offline: true, synthesize: { _, _, _ in SpeechAudio(samples: []) })
    }

    private func provide(_ s: ReadAloudSession, _ i: Int, _ samples: [Float], generation: Int? = nil, seconds: Double = 0) {
        s.provide(i, SpeechAudio(samples: samples), generation: generation ?? s.currentGeneration, native: 1, seconds: seconds)
    }

    private func skipLeadIn(_ s: ReadAloudSession) { _ = s.renderRaw(ReadAloudSession.leadInAtOne) }

    private func expectQuiet(_ a: [Float], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(a.allSatisfy { abs($0) <= 1e-4 }, sourceLocation: sourceLocation)
        #expect(a.contains { $0 != 0 }, sourceLocation: sourceLocation) // a dither, never digital silence
    }

    @Test func playsTheSentenceThenSilenceAndFinishes() async throws {
        let s = session("Hello there.")
        var finished = false
        s.onFinished = { finished = true }
        let audio = Self.ramp(1000)
        provide(s, 0, audio)
        skipLeadIn(s)
        let played = s.renderRaw(1800) // the buffer starts out NaN: everything is written
        #expect(Array(played[..<1000]) == audio)
        expectQuiet(Array(played[1000...]))
        #expect(s.isEnded)
        for _ in 0..<100 where !finished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(finished)
    }

    @Test func continuesAcrossReadsAndSentences() {
        let s = session("One sentence here. And another one.")
        #expect(s.sentences.count == 2)
        let first = Self.ramp(600), second = Self.ramp(600).map { -$0 }
        provide(s, 0, first)
        provide(s, 1, second)
        skipLeadIn(s)
        let a = s.renderRaw(800), b = s.renderRaw(800)
        // Sentences that are ready follow each other with no runway in between.
        #expect(Array((a + b).prefix(1200)) == first + second)
        expectQuiet(Array(b[400...]))
        #expect(s.isEnded)
    }

    @Test func quietWhileWaitingForAudioOrPaused() {
        let s = session("Hello there.")
        expectQuiet(s.renderRaw(100))
        #expect(s.isBuffering)
        provide(s, 0, Self.ramp(100))
        s.togglePause()
        expectQuiet(s.renderRaw(100))
        #expect(!s.isEnded)
    }

    @Test func speechAfterAWaitGetsTheRunwayFirst() {
        let s = session("One sentence here. And another one.")
        let first = Self.ramp(200)
        provide(s, 0, first)
        skipLeadIn(s)
        #expect(s.renderRaw(200) == first)
        // The second sentence isn't ready: the player waits...
        _ = s.renderRaw(100)
        #expect(s.isBuffering)
        // ...and when it arrives, the runway plays before it.
        let second = Self.ramp(300)
        provide(s, 1, second)
        expectQuiet(s.renderRaw(ReadAloudSession.leadInAtOne))
        #expect(s.renderRaw(300) == second)
    }

    @Test func audioFromBeforeASpeedChangeIsDropped() {
        let s = session("Hello there.")
        let stale = s.currentGeneration
        s.setSpeed(1.5)
        provide(s, 0, Self.ramp(100), generation: stale)
        #expect(s.isBuffering)
    }

    @Test func theVoiceKeepsThirtySecondsReadyAhead() {
        let s = session((0..<6).map { Self.long(Character(UnicodeScalar(97 + $0)!)) }.joined(separator: " "))
        #expect(s.nextToSynthesizeLocked() == 0)
        provide(s, 0, [Float](repeating: 0, count: Self.rate * 5))
        provide(s, 1, [Float](repeating: 0, count: Self.rate * 5))
        #expect(s.nextToSynthesizeLocked() == 2) // 10 s ready: keep going
        provide(s, 2, [Float](repeating: 0, count: Self.rate * 25))
        #expect(s.nextToSynthesizeLocked() == nil) // 35 s ready: enough
    }

    @Test func aSlowVoiceWaitsUntilEnoughIsReadyThenReadsOn() {
        let s = session((0..<4).map { Self.long(Character(UnicodeScalar(97 + $0)!)) }.joined(separator: " "))
        let first = Self.ramp(Self.rate)
        // The voice makes 1 s of audio in 2 s: slower than real time.
        for _ in 0..<6 { provide(s, 0, first, seconds: 2) }
        expectQuiet(s.renderRaw(ReadAloudSession.leadInAtOne + 1000)) // 1 s ready of a long reading: not enough
        provide(s, 1, [Float](repeating: 0, count: Self.rate * 20))
        skipLeadIn(s)
        #expect(s.renderRaw(100) == Array(first.prefix(100))) // enough now: reads on
    }

    @Test func aFastVoiceReadsAsSoonAsTheSentenceIsThere() {
        let s = session((0..<4).map { Self.long(Character(UnicodeScalar(97 + $0)!)) }.joined(separator: " "))
        let first = Self.ramp(Self.rate)
        provide(s, 0, first, seconds: 0.3)
        skipLeadIn(s)
        #expect(s.renderRaw(100) == Array(first.prefix(100)))
    }

    @Test func jumpingToAWordPlaysFromThereForwardsAndBackwards() {
        let s = session("One sentence here. And another one.")
        let first = Self.ramp(400), second = Self.ramp(400).map { -$0 }
        provide(s, 0, first)
        provide(s, 1, second)
        s.jump(to: 1, fraction: 0.5) // forwards: halfway into the second sentence
        #expect(s.position.sentence == 1 && s.position.fraction == 0.5)
        let played = s.renderRaw(ReadAloudSession.leadInAtOne + 200)
        #expect(Array(played[ReadAloudSession.leadInAtOne...]) == Array(second[200...])) // after the runway, from the jump point
        #expect(s.isEnded)
        s.jump(to: 0, fraction: 0) // backwards, even from the end
        #expect(!s.isEnded)
        #expect(s.position.sentence == 0 && s.position.fraction == 0)
    }

    @Test func theStartingSpeedIsClampedNotRounded() {
        let s = ReadAloudSession(text: "Hello.", voice: "af_heart", speed: 1.125, offline: true, synthesize: { _, _, _ in SpeechAudio(samples: []) })
        #expect(s.currentSpeed == 1.125)
        #expect(ReadAloudSession.clamp(1.125) == 1.12) // Math.Round(1.125, 2): half to even
        #expect(ReadAloudSession.clamp(9) == 4 && ReadAloudSession.clamp(0.1) == 0.25)
    }

    @Test func anOutputThatCantPlayEndsTheReadingWithAnError() async throws {
        let s = session("Hello there.")
        var message: String?
        s.onFailed = { message = $0 }
        s.recoverOutput(isRunning: false) {} // another output took over: reads on
        #expect(!s.isEnded)
        struct Gone: LocalizedError { var errorDescription: String? { "the output device is gone" } }
        s.recoverOutput(isRunning: false) { throw Gone() }
        #expect(s.isEnded)
        for _ in 0..<100 where message == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(message == "Playback failed: the output device is gone")
        // Reported once, and nothing after the reading is closed.
        message = nil
        s.recoverOutput(isRunning: false) { throw Gone() }
        s.stop()
        s.recoverOutput(isRunning: false) { throw Gone() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(message == nil)
    }
}

@Suite @MainActor struct ReadAloudPlayerTextTests {
    @Test func theClipboardQuestionFlattensLineBreaksAndUsesTheBaseSpeed() {
        let p = ReadAloudPlayer()
        p.baseSpeed = { 2 }
        p.askToReadClipboard("Dear John,\nthanks\u{2028}for the notes.")
        #expect(p.question?.body.hasPrefix("“Dear John, thanks for the notes.”\n6 words") == true)
        let long = String(repeating: "word ", count: 400) // 2000 characters: 2.2 min at 1×, 1.1 at 2×
        p.askToReadClipboard(long)
        #expect(p.question?.body.hasSuffix("400 words · about 1 min") == true)
        p.stop()
    }

    @Test func lineEndingsAsDotNetKnowsThem() {
        #expect(ReadAloudText.replacingLineEndings("a\r\nb\rc\u{2028}d\u{2029}e\u{85}f\u{0C}g\nh") == "a b c d e f g h")
        #expect(ReadAloudText.lineEndingsAsSpaces("a\u{2028}b\nc") == "a b c")
        #expect(ReadAloudText.replacingLineEndings("plain") == "plain")
    }

    @Test func onlyNewlineEndsAMarkdownLine() {
        // A soft line break (U+2028, from Mail or TextEdit) is inside the line, as in .NET.
        #expect(MarkdownText.forReading("Shopping:\u{2028}- milk\u{2028}- eggs") == "Shopping:\u{2028}- milk\u{2028}- eggs")
        #expect(MarkdownText.forReading("Intro\r# Title").contains("# Title"))
        let doc = MarkdownDoc.parse("- buy milk\u{2028}and eggs\n# Title\u{2028}Subtitle")
        #expect(doc.lines[0].kind == .bullet)
        #expect(doc.lines[1].kind == .heading)
        #expect(!doc.plain.contains("- ") && !doc.plain.contains("# "))
    }

    @Test func lettersOutsideTheBasicPlaneDontMakeASentence() {
        // Windows tests UTF-16 units; half a surrogate pair is never a letter.
        let text = "𝐇𝐞𝐥𝐥𝐨. Hi there."
        let spans = ReadAloudText.split(text)
        #expect(spans.count == 1)
        #expect((text as NSString).substring(with: spans[0]) == "Hi there.")
    }

    @Test func piperVoicesDownloadFromThePiperVoicesRepository() {
        let lessac = VoiceCatalog.findPiper("piper:en_US-lessac-medium")
        #expect(lessac?.url.absoluteString == "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/lessac/medium/en_US-lessac-medium.onnx")
        let jenny = VoiceCatalog.piperVoices.first { $0.label == "Jenny" }
        #expect(jenny?.url.absoluteString == "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_GB/jenny_dioco/medium/en_GB-jenny_dioco-medium.onnx")
        #expect(VoiceCatalog.findPiper(lessac?.id) == lessac)
        #expect(VoiceCatalog.findPiper("piper:nobody") == nil)
    }

    @Test func kokoroBatchesAtPunctuationAndTrimsSilence() {
        #expect(KokoroSpeech.batches("həlˈO, wˈɜɹld. ðɛɹ!") == ["həlˈO, wˈɜɹld. ðɛɹ!"])
        let long = Array(repeating: "ɑbɑbɑbɑbɑb,", count: 80).joined(separator: " ") // 960 phonemes
        let batches = KokoroSpeech.batches(long)
        #expect(batches.count == 2)
        #expect(batches.allSatisfy { $0.unicodeScalars.count < KokoroSpeech.maxTokens && $0.hasSuffix(",") })
        let tone = (0..<12000).map { Float(0.5 * sin(Double($0) / 10)) }
        let padded = [Float](repeating: 0, count: 6000) + tone + [Float](repeating: 0, count: 6000)
        let trimmed = KokoroSpeech.trimSilence(padded)
        #expect(trimmed.count >= 12000 && trimmed.count <= 12000 + 2 * 2048)
        #expect(KokoroSpeech.trimSilence([Float](repeating: 0, count: 4000)).isEmpty)
    }
}
