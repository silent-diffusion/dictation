import AVFoundation
import Foundation
import Testing
@testable import ObertonCore

/// Runs the real voices once (Kokoro, a Piper voice, a system voice) and writes what they said as WAV files, to
/// listen to and to check the timings. Needs the downloaded files in the data folder:
/// `OBERTON_VOICE_CHECK=<folder for the WAVs> OBERTON_DATA_DIR=<data folder> swift test --filter VoiceCheck`.
@Suite struct VoiceCheck {
    static let out = ProcessInfo.processInfo.environment["OBERTON_VOICE_CHECK"]

    @Test(.enabled(if: out != nil)) func speaksWithEveryEngine() async throws {
        let text = "Hello! This is how Oberton sounds when it reads to you. Select any text and press the shortcut to hear it."
        print("US:", try Phonemizer.shared(british: false).kokoro(text))
        print("GB:", try Phonemizer.shared(british: true).kokoro(text))
        print("Piper:", try Phonemizer.shared(british: false).piper(text))
        print("Odd:", try Phonemizer.shared(british: false).kokoro("In 1984, Dr. Oberton paid $3.50 for 25% of the USA's 2nd-best widgets."))
        var voices = ["af_heart", "bm_george"]
        if VoiceInstaller.piperInstalled("en_US-lessac-medium") { voices.append("piper:en_US-lessac-medium") }
        if let system = VoiceCatalog.systemVoices().first { voices.append(system.id) }
        for voice in voices {
            for speed in [1.0, 2.0] {
                let start = Date()
                let audio = try await SpeechVoices.shared.synthesize(text, voice: voice, speed: speed)
                let took = Date().timeIntervalSince(start)
                let rms = sqrt(audio.samples.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, audio.samples.count)))
                print(String(format: "%@ ×%.1f: %.2f s of audio in %.2f s, rms %.3f, %d word marks", voice, speed, audio.seconds, took, rms, audio.words.count))
                #expect(audio.seconds > 2 / speed)
                #expect(rms > 0.01)
                try write(audio.samples, to: URL(fileURLWithPath: Self.out!).appending(path: "\(voice.replacingOccurrences(of: ":", with: "_"))-\(speed).wav"))
            }
        }
    }

    private func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(SpeechAudio.sampleRate), channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        for (i, s) in samples.enumerated() { buffer.floatChannelData![0][i] = s }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
