import Accelerate
import Foundation

/// Speeds audio up or slows it down without changing the pitch (Windows' TimeStretch and the voice server's
/// `stretch`): WSOLA, 40 ms windows overlap-added, each nudged to where it lines up best with the last so voices don't
/// warble. Used past the 0.5×–2× the voices pace themselves.
enum TimeStretch {
    static let window = 960, hop = window / 2, tolerance = hop / 2

    /// `factor` 2 plays twice as fast, 0.5 half as fast. Within 1 % of 1, or for less than two windows of audio, the
    /// audio comes back as it is. `everySample` compares every sample when lining windows up (the voice server's
    /// np.correlate, for Kokoro and Piper); otherwise every other one (TimeStretch.cs, for the system's voices).
    static func apply(_ audio: [Float], factor: Double, everySample: Bool = false) -> [Float] {
        if abs(factor - 1) < 0.01 || audio.count < window * 2 { return audio }
        let outLength = Int(Double(audio.count) / factor)
        let frames = outLength / hop + 1
        // In doubles, as the sums are on Windows.
        var x = [Double](repeating: 0, count: tolerance + audio.count + window * 2 + Int(Double(hop) * factor) + tolerance * 2)
        x.replaceSubrange(tolerance..<(tolerance + audio.count), with: audio.map(Double.init))
        let win = (0..<window).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(window)) }
        var y = [Double](repeating: 0, count: frames * hop + window)
        var weight = [Double](repeating: 0, count: y.count)
        let stride = everySample ? 1 : 2
        let terms = vDSP_Length((window + stride - 1) / stride)
        x.withUnsafeBufferPointer { xs in
            let base = xs.baseAddress!
            var prev = tolerance
            for k in 0..<frames {
                let nominal = Int(Double(k * hop) * factor) + tolerance
                var pos = nominal
                if k > 0 {
                    let target = prev + hop
                    var best = -Double.infinity
                    for lag in (nominal - tolerance)...(nominal + tolerance) {
                        var sum = 0.0
                        vDSP_dotprD(base + lag, vDSP_Stride(stride), base + target, vDSP_Stride(stride), &sum, terms)
                        if sum > best { best = sum; pos = lag } // the first best, as both
                    }
                }
                let at = k * hop
                for i in 0..<window {
                    y[at + i] += base[pos + i] * win[i]
                    weight[at + i] += win[i]
                }
                prev = pos
            }
        }
        return (0..<outLength).map { Float(y[$0] / max(weight[$0], 1e-3)) }
    }
}
