import AVFoundation
import Foundation

/// One sentence's audio: mono floats at `sampleRate`, and, for the system's voices, where each word starts (sample,
/// and its range in the text that was spoken). Kokoro and Piper don't say where their words are; the player estimates
/// them from how far into the sentence it is, as Windows does.
public struct SpeechAudio: Sendable {
    public static let sampleRate = 24000

    public var samples: [Float]
    public var words: [(sample: Int, range: NSRange)] = []

    public var seconds: Double { Double(samples.count) / Double(Self.sampleRate) }

    /// Linear resampling to 24 kHz (as Windows' voice server does for Piper).
    static func resample(_ audio: [Float], from rate: Int) -> [Float] {
        guard rate != sampleRate, audio.count > 1, rate > 0 else { return audio }
        let n = Int((Double(audio.count) * Double(sampleRate) / Double(rate)).rounded())
        let step = Double(audio.count - 1) / Double(max(1, n - 1))
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let x = Double(i) * step
            let j = Int(x)
            let f = Float(x - Double(j))
            out[i] = j + 1 < audio.count ? audio[j] * (1 - f) + audio[j + 1] * f : audio[j]
        }
        return out
    }
}

/// Speaks one short piece of text with any of Read aloud's voices (Windows' SpeechVoices): Kokoro and Piper on ONNX
/// Runtime, the system's voices through AVSpeechSynthesizer, rendered to audio rather than played, so every voice
/// goes through the same player (true speeds, ±15 s, immediate pause). One request at a time, off the main thread.
/// The voices stay loaded until `unload()`.
public final class SpeechVoices: @unchecked Sendable {
    public static let shared = SpeechVoices()

    private let queue = DispatchQueue(label: "oberton.voices", qos: .userInitiated)
    private let lock = NSLock()
    private let kokoro = KokoroSpeech()
    private var pipers: [String: PiperSpeech] = [:]
    private var lastUsedAt = Date()

    /// The voice engine has a model in memory (Kokoro or a Piper voice; the system's voices are the system's).
    public var isLoaded: Bool { lock.withLock { kokoro.isLoaded || !pipers.isEmpty } }
    /// When a voice was last asked to speak, for unloading it when idle (Windows' `Tts.LastUsed`).
    public var lastUsed: Date { lock.withLock { lastUsedAt } }

    /// The pace a voice reads at itself for `speed`; the player stretches the rest without changing the pitch.
    /// Kokoro and Piper pace themselves naturally between 0.5× and 2× (as on Windows); the system's voices read at
    /// their normal pace, so every speed is an exact multiple of it.
    public static func nativeSpeed(voice: String, speed: Double) -> Double {
        VoiceCatalog.modelOf(voice) == VoiceCatalog.system ? 1 : min(max(speed, 0.5), 2)
    }

    /// Free the voices' memory; they load again on the next reading.
    public func unload() {
        queue.sync {
            lock.withLock {
                kokoro.unload()
                pipers = [:]
            }
            Phonemizer.unload()
        }
    }

    /// Speak one sentence at the voice's own pace for `speed` (`nativeSpeed`).
    public func synthesize(_ text: String, voice: String, speed: Double) async throws -> SpeechAudio {
        try await withCheckedThrowingContinuation { c in
            queue.async { [self] in
                lock.withLock { lastUsedAt = Date() }
                do { c.resume(returning: try synthesizeNow(text, voice: voice, speed: speed)) }
                catch { c.resume(throwing: error) }
            }
        }
    }

    private func synthesizeNow(_ text: String, voice: String, speed: Double) throws -> SpeechAudio {
        switch VoiceCatalog.modelOf(voice) {
        case VoiceCatalog.system:
            return try SystemSpeech.synthesize(text, voice: voice)
        case VoiceCatalog.piper:
            let name = String(voice.dropFirst(VoiceCatalog.piperPrefix.count))
            // A voice in memory reads on even if its files went meanwhile (as the Windows server).
            let piper = try lock.withLock { () throws -> PiperSpeech in
                if let p = pipers[name] { return p }
                guard VoiceInstaller.piperInstalled(name) else {
                    throw UserFacingError("The voice engine couldn't read that: the Piper voice \(name) isn't downloaded")
                }
                let p = try PiperSpeech(name: name)
                pipers[name] = p
                return p
            }
            do { return SpeechAudio(samples: try piper.synthesize(text, speed: speed)) }
            catch let e as UserFacingError { throw e }
            catch { throw UserFacingError("The voice engine couldn't read that: \(error.localizedDescription)") }
        default:
            guard kokoro.isLoaded || VoiceInstaller.kokoroInstalled else { throw UserFacingError("Read aloud isn't installed yet.") }
            do { return SpeechAudio(samples: try kokoro.synthesize(text, voice: voice.isEmpty ? VoiceCatalog.defaultVoice : voice, speed: speed)) }
            catch let e as UserFacingError { throw e }
            catch { throw UserFacingError("The voice engine couldn't read that: \(error.localizedDescription)") }
        }
    }
}

/// The system's voices, rendered to audio with their word positions (AVSpeechSynthesizer.write).
enum SystemSpeech {
    static func synthesize(_ text: String, voice: String) throws -> SpeechAudio {
        // Gone since the reading started (the player checks before it starts): the default voice reads on, as SAPI's.
        var v = AVSpeechSynthesisVoice(identifier: voice)
        if v == nil {
            CoreLog.warn("\(VoiceCatalog.deviceNoun) voice \"\(voice)\" isn't installed; using the default one")
            v = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = v
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let synth = AVSpeechSynthesizer()
        let done = DispatchSemaphore(value: 0)
        let state = Collected()
        synth.write(utterance, toBufferCallback: { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { done.signal(); return } // the end
            state.add(pcm)
        }, toMarkerCallback: { markers in
            state.add(markers)
        })
        // A sentence takes a fraction of a second; a voice that never answers mustn't hang the reading.
        guard done.wait(timeout: .now() + 30) == .success else {
            synth.stopSpeaking(at: .immediate)
            throw UserFacingError("The \(VoiceCatalog.deviceNoun) voice couldn't read that: it didn't answer.")
        }
        return state.result()
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        private var rate = SpeechAudio.sampleRate
        private var bytesPerFrame = 2
        private var markers: [(offset: Int, range: NSRange)] = []

        func add(_ pcm: AVAudioPCMBuffer) {
            let n = Int(pcm.frameLength)
            var chunk = [Float](repeating: 0, count: n)
            if let f = pcm.floatChannelData {
                for i in 0..<n { chunk[i] = f[0][i] }
            } else if let s = pcm.int16ChannelData {
                for i in 0..<n { chunk[i] = Float(s[0][i]) / 32768 }
            } else if let s = pcm.int32ChannelData {
                for i in 0..<n { chunk[i] = Float(s[0][i]) / 2_147_483_648 }
            }
            lock.withLock {
                rate = Int(pcm.format.sampleRate)
                bytesPerFrame = max(1, Int(pcm.format.streamDescription.pointee.mBytesPerFrame))
                samples += chunk
            }
        }

        func add(_ m: [AVSpeechSynthesisMarker]) {
            lock.withLock {
                markers += m.filter { $0.mark == .word }.map { (Int($0.byteSampleOffset), $0.textRange) }
            }
        }

        func result() -> SpeechAudio {
            lock.withLock {
                let audio = SpeechAudio.resample(samples, from: rate)
                // The offsets are bytes into the audio on some systems and samples on others: tell by their reach.
                let perSample = markers.contains { $0.offset > samples.count } ? Double(bytesPerFrame) : 1
                let scale = Double(SpeechAudio.sampleRate) / Double(rate) / perSample
                let words = markers.map { (sample: Int(Double($0.offset) * scale), range: $0.range) }.sorted { $0.sample < $1.sample }
                return SpeechAudio(samples: audio, words: words)
            }
        }
    }
}
