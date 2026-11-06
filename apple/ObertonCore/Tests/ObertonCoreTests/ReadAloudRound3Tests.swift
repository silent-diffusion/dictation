import AVFoundation
import Foundation
import Testing
@testable import ObertonCore

/// Windows' TimeStretchTests, word for word (READ-115, READ-070): length exactly (int)(len / factor), 220 Hz kept,
/// level kept, and 1.0 leaves the audio alone. Both comparisons: every other sample (TimeStretch.cs) and every sample
/// (the voice server).
@Suite struct TimeStretchTests {
    static func tone(_ hz: Double, _ samples: Int) -> [Float] {
        (0..<samples).map { Float(sin(2 * Double.pi * hz * Double($0) / 24000)) }
    }

    static func crossings(_ a: [Float], _ from: Int, _ to: Int) -> Int {
        var n = 0
        for i in (from + 1)..<to where a[i - 1] < 0 && a[i] >= 0 { n += 1 }
        return n
    }

    @Test(arguments: [0.25, 0.5, 2.0, 4.0], [false, true])
    func changesTheLengthButNotThePitch(factor: Double, everySample: Bool) {
        let tone = Self.tone(220, 24000 * 2)
        let stretched = TimeStretch.apply(tone, factor: factor, everySample: everySample)
        #expect(stretched.count == Int(Double(tone.count) / factor))
        let mid = stretched.count / 2
        #expect((53...57).contains(Self.crossings(stretched, mid - 3000, mid + 3000)))
        #expect((0.8...1.1).contains(stretched.max()!))
    }

    @Test func leavesNormalSpeedAlone() {
        let tone = Self.tone(220, 24000)
        #expect(TimeStretch.apply(tone, factor: 1.0) == tone)
        #expect(TimeStretch.apply(tone, factor: 1.005) == tone) // within 1 %
        #expect(TimeStretch.apply(Array(tone.prefix(1900)), factor: 2) == Array(tone.prefix(1900))) // under two windows
    }

    /// A system voice's word positions move with its audio.
    @Test func wordPositionsFollowTheStretch() {
        let a = SpeechAudio(samples: Self.tone(220, 48000), words: [(24000, NSRange(location: 4, length: 3))])
        let fast = SpeechVoices.stretched(a, native: 2, speed: 4, everySample: false)
        #expect(fast.samples.count == 24000)
        #expect(fast.words.first?.sample == 12000)
    }
}

/// R14/R15 (READ-018/020) and SYS-010 on the player: the readouts and keys as Windows has them.
@Suite struct ReadAloudSlidersTests {
    @Test func readoutsAreEnUSInEveryRegion() {
        // XAML StringFormat: the element's Language (en-US), not the region.
        #expect(ReadAloudSliders.speedReadout(1.75) == "1.75×")
        #expect(ReadAloudSliders.speedReadout(1) == "1.00×")
        #expect(ReadAloudSliders.opacityReadout(0.9) == "90%")
        #expect(ReadAloudSliders.opacityReadout(1) == "100%")
    }

    @Test func thePlayersSpeedsFollowTheRegion() {
        let de = Locale(identifier: "de_DE"), us = Locale(identifier: "en_US")
        #expect(ReadAloudSliders.playerSpeed(1, locale: us) == "1.0×")
        #expect(ReadAloudSliders.playerSpeed(1.65, locale: us) == "1.65×")
        #expect(ReadAloudSliders.playerSpeed(1.25, locale: de) == "1,25×")
        #expect(ReadAloudSliders.playerSpeed(1.5, locale: de) == "1,5×")
        #expect(ReadAloudSliders.presetSpeed(1, locale: us) == "1×")
        #expect(ReadAloudSliders.presetSpeed(0.25, locale: de) == "0,25×")
    }

    /// An arrow press moves by SmallChange 0.1 and lands on a tick (the old 0.007 step snapped back to where it was).
    @Test func arrowKeysMoveByTheSmallChange() {
        let o = ReadAloudSliders.self
        #expect(o.smallChange == 0.1 && o.largeChange == 1)
        #expect(o.step(0.9, by: o.smallChange, range: o.opacityRange, tick: o.opacityTick) == 1)
        #expect(o.step(0.5, by: -o.smallChange, range: o.opacityRange, tick: o.opacityTick) == 0.4)
        #expect(o.step(0.3, by: -o.smallChange, range: o.opacityRange, tick: o.opacityTick) == 0.3)
        #expect(o.step(1.75, by: o.smallChange, range: o.speedRange, tick: o.speedTick) == 1.85)
        #expect(o.step(3.95, by: o.smallChange, range: o.speedRange, tick: o.speedTick) == 4)
        #expect(o.step(0.9, by: 0.007, range: o.opacityRange, tick: o.opacityTick) == 0.9) // why R15 did nothing
    }
}

/// READ-007/046/SHELL-143, READ-006/045 (the installer), READ-106, READ-088.
@Suite struct ReadAloudRound3Tests {
    @Test func aDownloadReportsEachMegabyte() {
        var last: Int64 = 0
        #expect(!VoiceInstaller.Fetcher.shouldReport(written: 65536, last: &last)) // nothing before the first MB
        #expect(!VoiceInstaller.Fetcher.shouldReport(written: 1 << 20, last: &last)) // more than 1 MB, as Windows
        #expect(VoiceInstaller.Fetcher.shouldReport(written: (1 << 20) + 1, last: &last))
        #expect(last == (1 << 20) + 1)
        #expect(!VoiceInstaller.Fetcher.shouldReport(written: (2 << 20), last: &last))
    }

    @Test func aFailedDownloadSaysWhatWindowsSays() async throws {
        let target = FileManager.default.temporaryDirectory.appending(path: "oberton-test-\(UUID().uuidString)/x.bin")
        await #expect(throws: UserFacingError.self) {
            try await VoiceInstaller.download(URL(string: "http://127.0.0.1:9/nothing")!, to: target) { _ in }
        }
        do {
            try await VoiceInstaller.download(URL(string: "http://127.0.0.1:9/nothing")!, to: target) { _ in }
        } catch let e as UserFacingError {
            #expect(e.message == "A download failed. Check your internet connection and click Retry.")
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    /// Two voices can download at once (the page's and the player's installers); the same files can't.
    @MainActor @Test func twoVoicesCanDownloadAtOnce() async throws {
        let player = ReadAloudPlayer()
        player.installer = { _, report in // a download that reports once and runs until cancelled
            report(VoiceProgress(step: 2, totalSteps: 3, title: "Downloading the voice model", fraction: 0.5, detail: ""))
            try await Task.sleep(for: .seconds(60))
        }
        var refused: String?
        let a = player.installVoice("piper:en_US-amy-medium")
        let b = player.installVoice("af_heart")
        let c = player.installVoice("af_bella") { if case .failure(let e as UserFacingError) = $0 { refused = e.message } }
        #expect(a != nil && b != nil && a != b)
        #expect(c == nil)
        #expect(refused == "This voice is already downloading. Wait for it to finish, and try again.")
        #expect(player.downloads.count == 2)
        #expect(player.install?.voice == "af_heart") // the latest
        for _ in 0..<200 where player.progress(of: a!)?.title.isEmpty != false { try await Task.sleep(for: .milliseconds(5)) }
        #expect(player.progress(of: a!)?.fraction == 0.5)
        player.cancelInstall(a)
        player.cancelInstall(b)
        for _ in 0..<500 where !player.downloads.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(player.downloads.isEmpty)
    }

    /// READ-106: Windows' lookbehind has no length limit: a sentence still ends after 25 closing quotes.
    @Test func sentencesEndAfterAnyNumberOfClosingMarks() {
        let quotes = String(repeating: "”", count: 25)
        let text = "He said it!!" + quotes + " Then he left."
        let spans = ReadAloudText.split(text).map { (text as NSString).substring(with: $0) }
        #expect(spans == ["He said it!!" + quotes, "Then he left."])
        #expect(ReadAloudText.split("One. Two.\nThree").count == 3)
        #expect(ReadAloudText.split("Wait… what?) No.").map { (("Wait… what?) No.") as NSString).substring(with: $0) } == ["Wait…", "what?)", "No."]) // "…" then a space ends one too
    }
}

/// READ-070/069: a system voice paces itself (its rate) and the stretch makes the speed exact.
@Suite(.serialized) struct SystemVoicePaceTests {
    @Test(arguments: [0.5, 0.75, 1.5, 2.0, 3.0])
    func systemVoicesReadAtTrueSpeeds(speed: Double) async throws {
        guard let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix("en") && $0.identifier.contains(".compact.") })
                ?? AVSpeechSynthesisVoice.speechVoices().first else { return }
        let text = "Every reading starts at this speed, and the next reading starts where you left it."
        let normal = try await SpeechVoices.shared.synthesize(text, voice: voice.identifier, speed: 1).seconds
        let paced = try await SpeechVoices.shared.synthesize(text, voice: voice.identifier, speed: speed).seconds
        let got = normal / paced
        #expect(abs(got - speed) / speed < 0.12, "\(voice.identifier) ×\(speed): \(got)")
    }
}
