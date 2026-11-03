import Foundation

/// "Even out the volume before transcribing": brings every stretch of speech to about the same loudness (−20 dBFS), so
/// a quiet microphone, or turning away from it, doesn't lose whole sentences. The same rules as Windows' `level()` in
/// asr_server.py (20 ms frames, speech = 8 dB above the room's noise floor, at most +50/−12 dB, pauses held at the
/// gain before them but never raising the noise above −55 dBFS, quickly down and slowly up, a soft limiter at 0.9),
/// worked out as the audio arrives instead of over the whole recording. Silence stays silence; SpeechAnalyzer's own
/// voice detection then decides whether anything was said.
public final class VolumeLeveller {
    static let targetDB: Float = -20, maxBoostDB: Float = 50, maxCutDB: Float = 12
    static let noiseMarginDB: Float = 8, noiseCeilingDB: Float = -55

    private let frame: Int
    /// The last 5 s of frame levels (dBFS), for the noise floor.
    private var recent: [Float] = []
    /// The last ~0.4 s: whether each frame was speech, and its power.
    private var window: [(speech: Bool, power: Float)] = []
    private var speechGain: Float?
    private var gain: Float = 0

    public init(sampleRate: Double) { frame = max(1, Int(sampleRate * 0.02)) }

    /// Level these channels in place (−1…1): the first one is measured, all of them get the same gain.
    public func process(_ channels: [UnsafeMutablePointer<Float>], count: Int) {
        guard let samples = channels.first else { return }
        var start = 0
        while start < count {
            let n = min(frame, count - start)
            var sum: Float = 0
            for i in 0..<n { sum += samples[start + i] * samples[start + i] }
            let db = 20 * log10(max((sum / Float(n)).squareRoot(), 1e-9))
            let before = gain
            let wanted = target(db)
            gain += (wanted - gain) * (wanted < gain ? 0.5 : 0.15)
            for i in 0..<n {
                let g = pow(10, (before + (gain - before) * Float(i + 1) / Float(n)) / 20)
                for channel in channels {
                    var v = channel[start + i] * g
                    let a = abs(v)
                    if a > 0.9 { v = (v < 0 ? -1 : 1) * (0.9 + 0.1 * tanh((a - 0.9) / 0.1)) }
                    channel[start + i] = v
                }
            }
            start += n
        }
    }

    public func process(_ samples: inout [Float]) {
        let count = samples.count
        samples.withUnsafeMutableBufferPointer { if let p = $0.baseAddress { process([p], count: count) } }
    }

    /// The gain this frame calls for, in dB.
    private func target(_ db: Float) -> Float {
        if db > -90 { // digital silence (before the mic opens) isn't the room's noise
            recent.append(db)
            if recent.count > 250 { recent.removeFirst(recent.count - 250) }
        }
        guard recent.count >= 10 else { return speechGain ?? 0 }
        let floor = recent.sorted()[recent.count / 10]
        let speech = db > floor + Self.noiseMarginDB
        window.append((speech, speech ? pow(10, db / 10) : 0))
        if window.count > 21 { window.removeFirst(window.count - 21) }
        if speech {
            let spoken = window.filter(\.speech)
            let local = 10 * log10(max(spoken.reduce(0) { $0 + $1.power } / Float(spoken.count), 1e-18))
            speechGain = min(max(Self.targetDB - local, -Self.maxCutDB), Self.maxBoostDB)
            return speechGain!
        }
        // A pause keeps the speech's gain, limited so the background noise isn't raised to speech level.
        return min(speechGain ?? 0, max(0, Self.noiseCeilingDB - floor))
    }
}
