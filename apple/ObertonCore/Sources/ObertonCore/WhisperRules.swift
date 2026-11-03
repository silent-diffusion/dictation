import Accelerate
import Foundation
import zlib

/// Windows' guards against Whisper's quirks, from inference/asr_server.py: the stock phrases it makes up on noise or
/// silence, its loops, and what is fed back to it as a prompt. Pure text rules, used by `WhisperEngine` and
/// `WhisperLiveStream`.
public enum WhisperText {
    /// Whisper's stock phrases on noise or silence (it learnt them from video subtitles), as `norm` leaves them. Kept
    /// when clearly said; dropped when Whisper itself doubts there was speech, or when a couple of words are stretched
    /// over seconds of audio (asr_server.py `PHANTOM_PHRASES`).
    public static let phantomPhrases: Set<String> = [
        "thank you", "thank you very much", "thank you so much", "thanks", "thanks for watching",
        "thank you for watching", "thanks for listening", "thank you for listening", "please subscribe", "you", "bye",
        "bye bye",
    ]

    private static let notWord = try! NSRegularExpression(pattern: #"[^\w\s']"#)
    private static let sentenceGap = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+"#)

    /// Lower case, punctuation gone: for comparing phrases (asr_server.py `norm`).
    public static func norm(_ text: String) -> String {
        let lower = text.lowercased()
        return notWord.stringByReplacingMatches(in: lower, range: NSRange(lower.startIndex..., in: lower), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// At least one letter or digit.
    public static func hasContent(_ text: String) -> Bool { OutputSanitizer.hasContent(text) }

    /// A subtitle credit ("Subtitles by …", "amara.org").
    public static func isSubtitleCredit(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechGuard.subtitleCredit.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    /// How well the text compresses (zlib, as faster-whisper's `get_compression_ratio`): above 2.4, the same words over
    /// and over.
    public static func compressionRatio(_ text: String) -> Double {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return 0 }
        var size = compressBound(uLong(bytes.count))
        var out = [UInt8](repeating: 0, count: Int(size))
        guard compress2(&out, &size, bytes, uLong(bytes.count), 6) == Z_OK, size > 0 else { return 0 }
        return Double(bytes.count) / Double(size)
    }

    /// What Whisper reported about a stretch of speech it decoded.
    public struct Segment: Sendable, Equatable {
        public var text: String
        public var start: Double
        public var end: Double
        /// How likely the window held no speech at all (0…1).
        public var noSpeechProb: Double
        /// The decoder's mean log probability per token over the window.
        public var avgLogprob: Double
        /// `compressionRatio` of the window's whole text.
        public var compressionRatio: Double
        public init(text: String, start: Double, end: Double, noSpeechProb: Double = 0, avgLogprob: Double = 0, compressionRatio: Double = 1) {
            self.text = text; self.start = start; self.end = end
            self.noSpeechProb = noSpeechProb; self.avgLogprob = avgLogprob; self.compressionRatio = compressionRatio
        }
    }

    /// A segment Whisper made up rather than heard (asr_server.py `is_phantom`).
    public static func isPhantom(_ seg: Segment) -> Bool {
        let text = norm(seg.text)
        if text.isEmpty { return true }
        if seg.compressionRatio > 2.4 { return true } // the same words over and over: a decoding loop
        if seg.noSpeechProb > 0.6 && seg.avgLogprob < -0.5 { return true } // probably no speech, and unsure of the words
        if phantomPhrases.contains(text) || isSubtitleCredit(seg.text) {
            return seg.noSpeechProb > 0.2 || seg.avgLogprob < -0.6 || seg.end - seg.start > 2.5
        }
        return false
    }

    /// The text cut into sentences after ".", "!" or "?" (asr_server.py `sentences`).
    public static func sentences(_ text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        var out: [String] = [], from = t.startIndex
        for m in sentenceGap.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let r = Range(m.range, in: t) else { continue }
            out.append(String(t[from..<r.lowerBound]))
            from = r.upperBound
        }
        out.append(String(t[from...]))
        return out.filter { !$0.isEmpty }
    }

    /// A sentence said three or more times in a row is kept once (Whisper's loops); said twice, it stays twice
    /// (asr_server.py `collapse_repeats`).
    public static func collapseRepeats(_ text: String) -> String {
        var out: [String] = [], run: [String] = []
        for x in sentences(text) {
            if let first = run.first, norm(x) == norm(first) { run.append(x); continue }
            out += run.count >= 3 ? [run[0]] : run
            run = [x]
        }
        out += run.count >= 3 ? [run[0]] : run
        return out.joined(separator: " ")
    }

    /// The last `count` characters (Python's `s[-count:]`).
    static func tail(_ s: String, _ count: Int) -> String { String(String.UnicodeScalarView(s.unicodeScalars.suffix(count))) }

    /// The prompt for the next piece of a session: the vocabulary hint plus the end of what was committed, with
    /// repeats and stock phrases left out (fed back to Whisper, those would prime it to make up more of them)
    /// (asr_server.py `prompt_for`).
    public static func prompt(vocabulary: String, committed: String) -> String {
        let recent = sentences(collapseRepeats(tail(committed, 600))).filter { !phantomPhrases.contains(norm($0)) }
        let end = tail(recent.joined(separator: " "), 200)
        return [vocabulary, end].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What a new piece adds after `committed`: loops collapsed, and nothing at all when it only repeats a stock phrase
    /// that was just committed (the "Thank you. Thank you. Thank you." of a quiet room) (asr_server.py `new_text`).
    public static func newText(_ text: String, after committed: String) -> String {
        let text = collapseRepeats(text)
        let said = sentences(text).map(norm)
        let before = sentences(tail(committed, 200))
        if !said.isEmpty, let last = before.last, said.allSatisfy(phantomPhrases.contains), Set(said) == [norm(last)] { return "" }
        return text
    }
}

/// Windows' "even out quiet speech" and its speech detection for Whisper (asr_server.py `level`, `speech_regions`,
/// `evened`): the whole recording is levelled (every stretch of speech brought to about −20 dBFS), cut down to where
/// it stands above the room's noise floor, and only decoded at all when a voice detector hears speech in it.
public enum WhisperPrep {
    public static let rate = 16_000
    static let frame = 320 // 20 ms
    static let targetDB = -20.0, maxBoostDB = 50.0, maxCutDB = 12.0, noiseMarginDB = 8.0, noiseCeilingDB = -55.0
    /// Less speech than this (seconds) counts as "nothing was said" (asr_server.py `MIN_SPEECH_SECONDS`).
    public static let minSpeechSeconds = 0.3

    /// The audio to decode and where it came from, or nil when nothing was said.
    public struct Prepared: Sendable {
        public var audio: [Float]
        /// The stretches kept, in samples of the original audio.
        public var regions: [Range<Int>]
        /// A time in `audio` (seconds), as a time in the original (asr_server.py `original_time`).
        public func originalTime(_ t: Double) -> Double {
            guard let lastRegion = regions.last else { return t }
            let at = t * Double(WhisperPrep.rate)
            var done = 0.0
            for r in regions {
                if at <= done + Double(r.count) { return (Double(r.lowerBound) + at - done) / Double(WhisperPrep.rate) }
                done += Double(r.count)
            }
            return Double(lastRegion.upperBound) / Double(WhisperPrep.rate)
        }
    }

    /// Each 20 ms frame's level, dBFS.
    static func frameDB(_ audio: [Float]) -> [Double] {
        let n = audio.count / frame
        return (0..<n).map { k in
            var ms: Float = 0
            audio.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + k * frame, 1, &ms, vDSP_Length(frame)) }
            return 20 * log10(max(Double(ms).squareRoot(), 1e-9))
        }
    }

    /// The 10th percentile of the frame levels (NumPy's linear percentile), digital silence left out; nil when there
    /// are fewer than 10 frames.
    static func noiseFloor(_ db: [Double]) -> Double? {
        let live = db.filter { $0 > -90 }.sorted()
        guard live.count >= 10 else { return nil }
        let pos = Double(live.count - 1) * 0.10
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, live.count - 1)
        return live[lo] + (live[hi] - live[lo]) * (pos - Double(lo))
    }

    /// Bring every stretch of speech to about the same loudness (asr_server.py `level`). The gain follows the speech's
    /// loudness over about 0.4 s, is held through the pauses but limited there so background noise isn't raised to
    /// speech level, and changes smoothly: quickly down, slower up. A soft limiter keeps peaks from clipping.
    public static func level(_ audio: [Float]) -> [Float] {
        let db = frameDB(audio)
        let n = db.count
        guard n >= 10, let floor = noiseFloor(db) else { return audio }
        let speech = db.map { $0 > floor + noiseMarginDB }
        guard speech.filter({ $0 }).count >= 5 else { return audio }
        // Centred sums over 21 frames (np.convolve(…, ones(21), mode="same")).
        var count = [Double](repeating: 0, count: n), power = [Double](repeating: 0, count: n)
        for i in 0..<n {
            for j in max(0, i - 10)...min(n - 1, i + 10) where speech[j] {
                count[i] += 1
                power[i] += pow(10, db[j] / 10)
            }
        }
        // Pauses take the gain of the speech before them (at the start, of the first speech).
        let firstSpeech = speech.firstIndex(of: true) ?? 0
        var lastSpeech = -1
        var gain = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if speech[i] { lastSpeech = i }
            let k = lastSpeech >= 0 ? lastSpeech : firstSpeech
            let local = 10 * log10(max(power[k], 1e-18) / max(count[k], 1))
            var g = min(max(targetDB - local, -maxCutDB), maxBoostDB)
            if !speech[i] { g = min(g, max(0, noiseCeilingDB - floor)) }
            gain[i] = g
        }
        var smooth = [Double](repeating: 0, count: n)
        var g = gain[0]
        for i in 0..<n {
            g += (gain[i] - g) * (gain[i] < g ? 0.5 : 0.15)
            smooth[i] = g
        }
        let lin = smooth.map { pow(10, $0 / 20) }
        var out = audio
        let half = Double(frame) / 2
        for i in 0..<out.count {
            let gi: Double
            if i >= n * frame {
                gi = lin[n - 1]
            } else {
                // np.interp over the frame centres, held at the ends.
                let x = (Double(i) - half) / Double(frame)
                if x <= 0 { gi = lin[0] } else if x >= Double(n - 1) { gi = lin[n - 1] } else {
                    let k = Int(x)
                    gi = lin[k] + (lin[k + 1] - lin[k]) * (x - Double(k))
                }
            }
            var v = Double(audio[i]) * gi
            let a = abs(v)
            if a > 0.9 { v = (v < 0 ? -1 : 1) * (0.9 + 0.1 * tanh((a - 0.9) / 0.1)) }
            out[i] = Float(v)
        }
        return out
    }

    /// Where words are being said, in samples: stretches well above the noise floor of the audio as recorded, joined
    /// across gaps of up to `gap` seconds, `pad` seconds either side; blips shorter than `shortest` left out
    /// (asr_server.py `speech_regions`).
    public static func speechRegions(_ audio: [Float], gap: Double = 0.5, pad: Double = 0.2, shortest: Double = 0.25) -> [Range<Int>] {
        let db = frameDB(audio)
        guard db.count >= 10, let floor = noiseFloor(db) else { return [] }
        var runs: [(Int, Int)] = []
        var start: Int?
        for (i, d) in db.enumerated() {
            let on = d > floor + noiseMarginDB
            if on, start == nil { start = i }
            if !on, let s = start { runs.append((s, i)); start = nil }
        }
        if let s = start { runs.append((s, db.count)) }
        var merged: [(Int, Int)] = []
        for (a, b) in runs {
            if let last = merged.last, Double(a - last.1) <= gap * Double(rate) / Double(frame) {
                merged[merged.count - 1].1 = b
            } else {
                merged.append((a, b))
            }
        }
        var out: [Range<Int>] = []
        let p = Int(pad * Double(rate))
        for (a, b) in merged {
            if Double((b - a) * frame) < shortest * Double(rate) { continue }
            let s = max(0, a * frame - p), e = min(audio.count, b * frame + p)
            if let last = out.last, s <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<e
            } else {
                out.append(s..<e)
            }
        }
        return out
    }

    /// Seconds of voiced speech in the audio: 32 ms frames that are loud enough (above −50 dBFS) and periodic at a
    /// voice's pitch (50–500 Hz), at least two in a row (a click or a knock can look voiced for one). The stand-in for Windows' Silero VAD (faster-whisper's `get_speech_timestamps`),
    /// which WhisperKit doesn't have: it tells speech from silence, hiss, hum and clicks, not from singing.
    public static func voicedSeconds(_ audio: [Float]) -> Double {
        let size = 512, minLag = rate / 500, maxLag = rate / 50
        var voiced = 0, run = 0
        var frame = [Float](repeating: 0, count: size)
        var k = 0
        while k + size <= audio.count {
            for i in 0..<size { frame[i] = audio[k + i] }
            k += size
            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, vDSP_Length(size))
            var negMean = -mean
            vDSP_vsadd(frame, 1, &negMean, &frame, 1, vDSP_Length(size))
            var ms: Float = 0
            vDSP_measqv(frame, 1, &ms, vDSP_Length(size))
            guard 10 * log10(max(Double(ms), 1e-18)) > -50 else { run = 0; continue }
            var best: Float = 0
            frame.withUnsafeBufferPointer { f in
                let base = f.baseAddress!
                for lag in minLag...maxLag {
                    let len = vDSP_Length(size - lag)
                    var r: Float = 0, e0: Float = 0, e1: Float = 0
                    vDSP_dotpr(base, 1, base + lag, 1, &r, len)
                    vDSP_svesq(base, 1, &e0, len)
                    vDSP_svesq(base + lag, 1, &e1, len)
                    let d = (e0 * e1).squareRoot()
                    if d > 0 { best = max(best, r / d) }
                }
            }
            if best >= 0.6 {
                run += 1
                voiced += run == 2 ? 2 : run > 2 ? 1 : 0
            } else {
                run = 0
            }
        }
        return Double(voiced * size) / Double(rate)
    }

    /// Whether anyone spoke at all: some voiced speech (a few frames; Silero, with its padding, passes any speech it
    /// detects as more than `minSpeechSeconds`).
    static func heardSpeech(_ audio: [Float]) -> Bool { voicedSeconds(audio) >= 0.09 }

    /// The audio levelled and cut down to where words are said, with the regions it came from; nil when nothing was
    /// said (asr_server.py `evened`).
    public static func evened(_ audio: [Float]) -> Prepared? {
        guard Double(audio.count) >= Double(rate) * 0.3 else { return nil }
        let levelled = level(audio)
        guard heardSpeech(levelled) else { return nil }
        let regions = speechRegions(audio)
        guard !regions.isEmpty else { return nil }
        return Prepared(audio: regions.flatMap { levelled[$0] }, regions: regions)
    }

    /// Without evening out: the audio as recorded, cut to where words are said (faster-whisper's `vad_filter` with
    /// `min_silence_duration_ms=400` and its 0.4 s padding, Silero replaced as in `evened`); nil when nothing was said.
    public static func voiceOnly(_ audio: [Float]) -> Prepared? {
        guard Double(audio.count) >= Double(rate) * 0.3, heardSpeech(audio) else { return nil }
        let regions = speechRegions(audio, gap: 0.4, pad: 0.4, shortest: 0)
        let kept = regions.reduce(0) { $0 + $1.count }
        guard Double(kept) >= minSpeechSeconds * Double(rate) else { return nil }
        return Prepared(audio: regions.flatMap { audio[$0] }, regions: regions)
    }

    /// `evened` or `voiceOnly`, as Settings › Speech › Even out the volume says.
    public static func prepare(_ audio: [Float], even: Bool) -> Prepared? { even ? evened(audio) : voiceOnly(audio) }
}
