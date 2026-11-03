import Foundation
import Testing
@testable import ObertonCore

/// The player's audio (Windows' ReadAloudSessionTests, TimeStretchTests and ReadAloudJumpTests): rendered offline through
/// the same AVAudioEngine and time-stretch the speakers get, with a stand-in voice that hums for 50 ms per character
/// at 1× (and paces itself between 0.5× and 2×, as Kokoro does).
@Suite(.serialized) struct ReadAloudSessionTests {
    static let text = "One two three four five. Six seven eight nine ten."

    /// A voice that hums: `chars × 50 ms ÷ pace` of a 220 Hz tone.
    static let hum: @Sendable (String, String, Double) async throws -> SpeechAudio = { text, _, pace in
        let n = Int(Double(text.utf16.count) * 0.05 / pace * Double(SpeechAudio.sampleRate))
        return SpeechAudio(samples: (0..<n).map { Float(0.5 * sin(2 * Double.pi * 220 * Double($0) / Double(SpeechAudio.sampleRate))) })
    }

    private func session(speed: Double) async throws -> ReadAloudSession {
        let s = ReadAloudSession(text: Self.text, voice: "af_heart", speed: speed, offline: true, synthesize: Self.hum)
        try s.start()
        for _ in 0..<200 where s.isBuffering || s.progress == 0 && s.remaining == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50)) // the second sentence too
        return s
    }

    /// Seconds of the output that are the voice (not the runway, the dither or the end).
    private func voiced(_ audio: [Float]) -> Double {
        // Count 10 ms frames whose level is clearly above the dither.
        let frame = SpeechAudio.sampleRate / 100
        var frames = 0
        for f in stride(from: 0, to: audio.count - frame, by: frame) {
            var peak: Float = 0
            for i in f..<(f + frame) { peak = max(peak, abs(audio[i])) }
            if peak > 0.05 { frames += 1 }
        }
        return Double(frames) / 100
    }

    @Test(arguments: [0.25, 1.0, 1.75, 2.0, 4.0])
    func speedsAreTrueMultiples(speed: Double) async throws {
        let s = try await session(speed: speed)
        let speech = Double(Self.text.utf16.count - 1) * 0.05 // both sentences at 1× (the space between isn't read)
        let out = try s.renderOffline(seconds: speech / speed + 1.5)
        #expect(s.isEnded)
        let got = voiced(out)
        #expect(abs(got - speech / speed) < 0.08 + 0.03 * speech / speed, "×\(speed): \(got) s, expected \(speech / speed)")
        #expect(abs(s.spokenSeconds - speech / speed) < 0.05)
        s.stop()
    }

    @Test func pauseHoldsThePlace() async throws {
        let s = try await session(speed: 1)
        _ = try s.renderOffline(seconds: 0.5)
        s.togglePause()
        let before = s.progress
        let quiet = try s.renderOffline(seconds: 0.5)
        #expect(s.progress == before)
        #expect(voiced(quiet) == 0)
        #expect(quiet.allSatisfy { $0 != 0 }) // a dither, never digital silence
        s.togglePause()
        _ = try s.renderOffline(seconds: 0.5)
        #expect(s.progress > before)
        s.stop()
    }

    @Test func skippingBackFromTheEndReadsOn() async throws {
        let s = try await session(speed: 1)
        _ = try s.renderOffline(seconds: 4)
        #expect(s.isEnded)
        s.skip(-1)
        #expect(!s.isEnded)
        #expect(s.position.sentence == 1)
        #expect(abs(s.remaining - 1) < 0.05)
        s.skip(-1e9)
        #expect(s.position.sentence == 0 && s.position.fraction == 0)
        s.stop()
    }

    @Test func jumpForwardsPlaysFromThereAfterARunway() async throws {
        let s = try await session(speed: 1)
        s.jump(to: 1, fraction: 0.5)
        let out = try s.renderOffline(seconds: 0.2)
        #expect(voiced(out) == 0) // the quarter-second runway first
        #expect(s.position.sentence == 1)
        _ = try s.renderOffline(seconds: 2)
        #expect(s.isEnded)
        s.stop()
    }

    @Test func aSpeedChangeWithinTheVoicesPaceKeepsTheAudio() async throws {
        let s = try await session(speed: 2.5) // the voice at 2×, stretched 1.25×
        _ = try s.renderOffline(seconds: 0.4)
        let at = s.position
        s.setSpeed(4) // still 2× from the voice: only the stretch changes
        #expect(!s.isBuffering)
        #expect(s.position.sentence == at.sentence && abs(s.position.fraction - at.fraction) < 0.001)
        s.setSpeed(1) // the voice's own pace changes: made again, from the same place
        #expect(s.isBuffering)
        #expect(abs(s.position.fraction - at.fraction) < 0.001)
        s.stop()
    }

    @Test func endedIgnoresSpeedChanges() async throws {
        let s = try await session(speed: 1)
        _ = try s.renderOffline(seconds: 4)
        s.setSpeed(2)
        #expect(s.currentSpeed == 1)
        s.stop()
    }

    @Test func speakableMapsBackToTheText() {
        let text = "Hello,\n  big   world."
        let (spoken, map) = ReadAloudSession.speakable(text, NSRange(location: 0, length: (text as NSString).length))
        #expect(spoken == "Hello, big world.")
        #expect(map.count == spoken.utf16.count + 1)
        let world = (spoken as NSString).range(of: "world")
        #expect((text as NSString).substring(with: NSRange(location: map[world.location], length: map[NSMaxRange(world)] - map[world.location])) == "world")
    }

    @Test func voicesPaceThemselvesBetweenHalfAndDouble() {
        #expect(SpeechVoices.nativeSpeed(voice: "af_heart", speed: 4) == 2)
        #expect(SpeechVoices.nativeSpeed(voice: "piper:en_US-amy-medium", speed: 0.25) == 0.5)
        #expect(SpeechVoices.nativeSpeed(voice: "af_heart", speed: 1.75) == 1.75)
        #expect(SpeechVoices.nativeSpeed(voice: "com.apple.voice.compact.en-US.Samantha", speed: 3) == 1)
    }
}

@Suite struct VoiceCatalogTests {
    @Test func aVoiceSaysItsModel() {
        #expect(VoiceCatalog.modelOf(nil) == VoiceCatalog.kokoro)
        #expect(VoiceCatalog.modelOf("af_heart") == VoiceCatalog.kokoro)
        #expect(VoiceCatalog.modelOf("bm_george") == VoiceCatalog.kokoro)
        #expect(VoiceCatalog.modelOf("piper:en_US-lessac-medium") == VoiceCatalog.piper)
        #expect(VoiceCatalog.modelOf("com.apple.voice.compact.en-US.Samantha") == VoiceCatalog.system)
        #expect(VoiceCatalog.shortName("af_heart") == "Heart")
        #expect(VoiceCatalog.shortName(nil) == "Heart")
        #expect(VoiceCatalog.shortName("piper:en_GB-jenny_dioco-medium") == "Jenny")
    }

    @Test func windowsVoiceLists() {
        #expect(VoiceCatalog.kokoroVoices.map(\.id) == ["af_heart", "af_bella", "af_nicole", "am_michael", "am_fenrir", "bf_emma", "bm_george", "bm_fable"])
        #expect(VoiceCatalog.kokoroVoices[0].name == "Heart (American, female)")
        #expect(VoiceCatalog.piperVoices.map(\.label) == ["Lessac", "Amy", "Ryan", "Joe", "Jenny", "Alan"])
        #expect(VoiceCatalog.piperVoices[0].url.absoluteString
                == "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/lessac/medium/en_US-lessac-medium.onnx")
        #expect(VoiceCatalog.models.map(\.name) == ["Kokoro v1.0", "Piper", "Mac voices"])
    }

    @Test func readsANumpyArchive() throws {
        // np.savez layout: a stored zip member "af_test.npy" holding a (2, 1, 2) float32 array.
        var npy = Data([0x93]) + "NUMPY".data(using: .ascii)! + Data([1, 0])
        var header = "{'descr': '<f4', 'fortran_order': False, 'shape': (2, 1, 2), }"
        while (10 + header.utf8.count + 1) % 64 != 0 { header += " " }
        header += "\n"
        npy += Data([UInt8(header.utf8.count & 0xFF), UInt8(header.utf8.count >> 8)]) + header.data(using: .ascii)!
        npy += [Float(1), 2, 3, 4].withUnsafeBytes { Data($0) }
        let file = Data("PK\u{3}\u{4}junk".utf8) + "af_test.npy".data(using: .utf8)! + Data(count: 20) + npy
        #expect(NPZ.array(named: "af_test.npy", in: file) == [1, 2, 3, 4])
        #expect(NPZ.array(named: "af_other.npy", in: file) == nil)
    }

    @Test func kokoroTokensAndChunks() {
        #expect(KokoroSpeech.tokens("həlˈO!") == [50, 83, 54, 156, 31, 5])
        let long: [Int64] = Array(repeating: [Int64(43), Int64(16)], count: 400).flatMap { $0 } // "a a a …", 800 tokens
        let chunks = KokoroSpeech.chunks(long)
        #expect(chunks.allSatisfy { $0.count <= KokoroSpeech.maxTokens })
        #expect(chunks.flatMap { $0 } == long)
        #expect(chunks[0].last == 16) // cut after a space
    }
}

@Suite struct PhonemizerTests {
    let us = Phonemizer(british: false, golds: [
        "hello": "həlˈO", "cat": "kˈæt", "walk": "wˈɔk", "wait": "wˈAt", "read": "ɹˈid", "world": "wˈɜɹld",
        "one": "wˈʌn", "nine": "nˈIn", "teen": "tˈin", "nineteen": "nˌIntˈin", "eighty": "ˈATi", "four": "fˈɔɹ",
        "five": "fˈIv", "twenty": "twˈɛnti", "dollar": "dˈɑləɹ", "percent": "pəɹsˈɛnt", "first": "fˈɜɹst",
        "U": "jˈu", "S": "ˈɛs", "A": "ˈA", "to": "tˈu", "apple": "ˈæpᵊl", "box": "bˈɑks", "fifty": "fˈɪfti",
        "cent": "sˈɛnt", "and": "ænd", "three": "θɹˈi", "point": "pˈYnt", "metal": "mˈɛɾᵊl",
    ])

    @Test func wordsAndTheirEndings() {
        #expect(us.raw("Hello, world.") == "həlˈO, wˈɜɹld.")
        #expect(us.raw("cats") == "kˈæts")
        #expect(us.raw("walked") == "wˈɔkt")
        #expect(us.raw("waited") == "wˈAɾᵻd")
        #expect(us.raw("boxes") == "bˈɑksᵻz")
        #expect(us.raw("reading") == "ɹˈidɪŋ")
    }

    @Test func toAndTheFollowTheNextSound() {
        #expect(us.raw("to apple") == "tʊ ˈæpᵊl")
        #expect(us.raw("to cat") == "tə kˈæt")
        #expect(us.raw("the apple") == "ði ˈæpᵊl")
        #expect(us.raw("the cat") == "ðə kˈæt")
    }

    @Test func numbersAndAcronyms() {
        #expect(us.raw("1984") == "nˌIntˈin ˈATi fˈɔɹ")
        #expect(us.raw("$5") == "fˈIv dˈɑləɹz")
        #expect(us.raw("25%") == "twˈɛnti fˈIv pəɹsˈɛnt")
        #expect(us.raw("1st") == "fˈɜɹst")
        #expect(us.raw("USA") == "jˌuˌɛsˈA")
        #expect(Phonemizer.year(2024) == ["twenty", "twenty", "four"])
        #expect(Phonemizer.year(2005) == ["two", "thousand", "five"])
        #expect(Phonemizer.ordinal("twenty-two") == ["twenty", "second"])
    }

    @Test func kokoroAndPiperForms() {
        #expect(us.kokoro("metal") == "mˈɛTᵊl")
        #expect(Phonemizer.espeak("həlˈO wˈɜɹld", british: false) == "həlˈoʊ wˈɜːld")
        #expect(Phonemizer.espeak("ʧˈIld ʤˈʌʤ", british: false) == "tʃˈaɪld dʒˈʌdʒ")
        #expect(Phonemizer.espeak("sˈi wˈɔɾəɹ", british: false) == "sˈiː wˈɔːɾɚ")
        #expect(Phonemizer.espeak("həlˈQ", british: true) == "həlˈəʊ")
    }

    @Test func wordsInNoDictionaryStillGetSounds() {
        #expect(!us.fallback("Zorblat").isEmpty)
        #expect(us.fallback("Zorblat").contains("ˈ"))
        #expect(us.fallback("make") == "mˈAk")
    }
}
