import AVFoundation
import Foundation
import os

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
/// The voices stay loaded until `unload()`. Each sentence comes back at the reading's speed: the voice paces itself
/// up to 2× either way and Windows' WSOLA stretch does the rest (the voice server's `speak`, WindowsSpeech).
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

    /// The pace a voice reads at itself for `speed`: every voice paces itself between 0.5× and 2× (Kokoro and Piper
    /// natively, the system's voices through their rate, as SAPI's Rate on Windows); the rest is stretched.
    public static func nativeSpeed(voice: String, speed: Double) -> Double { min(max(speed, 0.5), 2) }

    /// The voice's audio at its own pace `native`, stretched to `speed` without changing the pitch; a system voice's
    /// word positions move with it.
    static func stretched(_ a: SpeechAudio, native: Double, speed: Double, everySample: Bool) -> SpeechAudio {
        let samples = TimeStretch.apply(a.samples, factor: speed / native, everySample: everySample)
        guard samples.count != a.samples.count, !a.samples.isEmpty else { return SpeechAudio(samples: samples, words: a.words) }
        let scale = Double(samples.count) / Double(a.samples.count)
        return SpeechAudio(samples: samples, words: a.words.map { (Int(Double($0.sample) * scale), $0.range) })
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

    /// Speak one sentence at `speed` (0.25–4).
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
        let speed = min(max(speed, 0.25), 4)
        let native = Self.nativeSpeed(voice: voice, speed: speed)
        if VoiceCatalog.modelOf(voice) == VoiceCatalog.system {
            // TimeStretch.Apply(samples, speed / native) in WindowsSpeech; the voice's real pace at its rate is measured.
            let (audio, paced) = try SystemSpeech.synthesize(text, voice: voice, pace: native)
            return Self.stretched(audio, native: paced, speed: speed, everySample: false)
        }
        // The voice server's stretch(audio, speed / native).
        return Self.stretched(try synthesizeLocal(text, voice: voice, speed: native), native: native, speed: speed, everySample: true)
    }

    /// Kokoro or Piper at its own pace.
    private func synthesizeLocal(_ text: String, voice: String, speed: Double) throws -> SpeechAudio {
        switch VoiceCatalog.modelOf(voice) {
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
    /// Speak `text` paced as close to `pace` (0.5–2) as the voice's rate goes (WindowsSpeech's SAPI Rate), and say how
    /// fast that really is against the voice's normal rate, so the stretch makes the rest exact.
    static func synthesize(_ text: String, voice: String, pace: Double = 1) throws -> (SpeechAudio, pace: Double) {
        // Gone since the reading started (the player checks before it starts): the default voice reads on, as SAPI's.
        var v = AVSpeechSynthesisVoice(identifier: voice)
        if v == nil {
            CoreLog.warn("\(VoiceCatalog.deviceNoun) voice \"\(voice)\" isn't installed; using the default one")
            v = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }
        let rate = rate(for: pace)
        let audio = try render(text, voice: v, rate: rate)
        return (audio, measuredPace(v, rate: rate) ?? pace)
    }

    /// AVSpeechUtterance's rate for a pace: the Mac's standard voices read 0.56× at rate 0, 1× at 0.5 (the default) and
    /// about 2.5× at 0.75 (measured; between the points it's interpolated). Other voices differ, which `measuredPace`
    /// finds out.
    static func rate(for pace: Double) -> Float {
        let curve: [(rate: Double, pace: Double)] = [(0, 0.56), (0.1, 0.67), (0.25, 0.77), (0.3, 0.83), (0.4, 0.91), (0.5, 1),
                                                     (0.55, 1.29), (0.6, 1.59), (0.65, 1.83), (0.7, 2.11), (0.75, 2.48)]
        if abs(pace - 1) < 0.001 { return AVSpeechUtteranceDefaultSpeechRate }
        guard pace > curve[0].pace else { return Float(curve[0].rate) }
        for (a, b) in zip(curve, curve.dropFirst()) where pace <= b.pace {
            return Float(a.rate + (b.rate - a.rate) * (pace - a.pace) / (b.pace - a.pace))
        }
        return Float(curve.last!.rate)
    }

    /// How fast `voice` reads at `rate` against its default rate, from a test sentence, once per voice and rate. Nil
    /// when it couldn't be measured.
    static func measuredPace(_ voice: AVSpeechSynthesisVoice?, rate: Float) -> Double? {
        if rate == AVSpeechUtteranceDefaultSpeechRate { return 1 }
        let key = "\(voice?.identifier ?? "") \(rate)"
        if let known = paces.withLock({ $0[key] }) { return known }
        let sample = "The quick brown fox jumps over the lazy dog, and then it runs far away into the forest to find its friends."
        guard let normal = try? render(sample, voice: voice, rate: AVSpeechUtteranceDefaultSpeechRate).seconds,
              let paced = try? render(sample, voice: voice, rate: rate).seconds, normal > 0, paced > 0 else { return nil }
        let pace = normal / paced
        paces.withLock { $0[key] = pace }
        return pace
    }

    private static let paces = OSAllocatedUnfairLock(initialState: [String: Double]())

    private static func render(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float) throws -> SpeechAudio {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
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
