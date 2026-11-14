import AVFoundation
import Testing
@testable import ObertonCore

/// The microphone tap's one walk over a buffer gives what its two walks gave: the same meter levels, the same peak.
@Suite struct AudioMeasureTests {
    static func buffer(_ samples: [Float], rate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
        b.frameLength = AVAudioFrameCount(samples.count)
        for (i, s) in samples.enumerated() { b.floatChannelData![0][i] = s }
        return b
    }

    @Test func oneWalkGivesTheLevelsAndThePeak() throws {
        let samples = (0..<4096).map { Float(sin(Double($0) * 0.05)) * ($0 < 2400 ? 0.1 : 0.6) }
        let b = Self.buffer(samples)
        let measured = try #require(LiveTranscriber.measure(b))
        let two = try #require(LiveTranscriber.rms(b))
        #expect(measured.peak == two.peak)
        #expect(measured.levels == LiveTranscriber.meterLevels(b))
        #expect(measured.levels.count == 2) // 4096 frames at 48 kHz: one full 50 ms and the rest
        #expect(measured.levels[1] > measured.levels[0])
        // Silence: levels of zero and no signal seen; an empty buffer: nothing.
        let silence = try #require(LiveTranscriber.measure(Self.buffer([Float](repeating: 0, count: 2400))))
        #expect(silence.peak == 0 && silence.levels == [0])
        #expect(LiveTranscriber.measure(Self.buffer([])) == nil)
    }

    @Test func aPartialIsDueAfterEnoughNewAudio() {
        let new = Int(16_000 * WhisperDictation.partialNew), first = Int(16_000 * WhisperDictation.partialFirst)
        #expect(!WhisperDictation.partialDue(count: 0, last: 0))
        #expect(WhisperDictation.partialDue(count: max(new, first), last: 0))
        #expect(!WhisperDictation.partialDue(count: max(new, first) + new - 1, last: max(new, first)))
        #expect(WhisperDictation.partialDue(count: max(new, first) + new, last: max(new, first)))
    }
}
