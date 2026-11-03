import AVFoundation
import Foundation
import os

/// Plays one text aloud (Windows' ReadAloudSession). The text is split into sentences, synthesized in order and played
/// back to back; reading starts as soon as the first is ready, and the voice keeps up to `bufferAheadSeconds` of audio
/// ready ahead, so a long sentence after short ones (or a busy moment) doesn't leave a gap. When the voice is slower
/// than real time, a wait lasts until enough is ready to read on without stopping again soon (`enoughReady`): one
/// longer pause rather than a gap at every sentence. Skipping works on the timeline of all sentences, using real
/// durations where the audio exists and estimates elsewhere.
///
/// Speed: each voice reads at its own pace for the speed (`SpeechVoices.nativeSpeed`: Kokoro and Piper between 0.5×
/// and 2×, the system's voices at 1×) and an AVAudioUnitTimePitch stretches the rest without changing the pitch, so
/// 0.25× to 4× are true multiples. A speed change within the same pace only changes the stretch; otherwise the audio
/// is made again from the current sentence. Like Windows, the audio is pulled by the output (an AVAudioSourceNode), so
/// pause and skips act at once, and silence is a faint dither with a quarter-second runway before speech, because
/// Bluetooth headsets that power down on digital silence swallow the first word otherwise.
/// Public members are safe to call from the main thread; the audio runs on Core Audio's thread.
final class ReadAloudSession: @unchecked Sendable {
    static let bufferAheadSeconds = 30.0
    /// The longest a wait on a slow device lasts to build up audio before reading on, in seconds of audio.
    static let maxCatchUpSeconds = 20.0
    static let rate = SpeechAudio.sampleRate

    let text: String
    let sentences: [NSRange]
    let voice: String
    /// Each sentence as the voice gets it (whitespace collapsed), and where each of its UTF-16 units is in `text`.
    private let speakable: [String]
    private let maps: [[Int]]
    private let synthesize: @Sendable (String, String, Double) async throws -> SpeechAudio

    /// Called on the main thread once the last sentence has played, or when the voice or playback fails.
    var onFinished: (@MainActor () -> Void)?
    var onFailed: (@MainActor (String) -> Void)?

    // State shared with the audio thread, under `lock`.
    private let lock = OSAllocatedUnfairLock()
    private var audio: [SpeechAudio?]
    private var speed: Double
    private var native: Double
    private var generation = 0   // bumps when the voice's own pace changes; audio from an older one is dropped
    private var index = 0        // sentence being played
    private var pos = 0          // sample position in it
    private var resumeAt = -1.0  // fraction of the current sentence to start from once its audio arrives
    private var paused = false, ended = false
    private var secondsPerChar = ReadAloudText.defaultSecondsPerChar // at speed 1, learned from the real audio
    private var realTime = 1.5   // seconds of audio the voice makes per second, learned as it goes (1.5 until known)
    private var starved = true   // the current sentence wasn't ready when it was needed (true at the start)
    private var starvedAt: Date?
    private var waits = 0
    private var waitedSeconds = 0.0
    private var spoken = 0.0     // seconds the voice has spoken, in real time (at the reading's speed)
    private var leadIn = 0       // samples of runway still to play before the current audio
    private var noise: UInt32 = 0x9E37_79B9
    private var reported = false

    private let engine = AVAudioEngine()
    private let pitch = AVAudioUnitTimePitch()
    private var source: AVAudioSourceNode?
    private var loop: Task<Void, Never>?
    private let wake: AsyncStream<Void>
    private let wakeUp: AsyncStream<Void>.Continuation
    /// Tests render the output themselves (`renderOffline`) instead of playing it.
    private let offline: Bool

    init(text: String, voice: String, speed: Double, offline: Bool = false,
         synthesize: @escaping @Sendable (String, String, Double) async throws -> SpeechAudio = { try await SpeechVoices.shared.synthesize($0, voice: $1, speed: $2) }) {
        self.text = text
        self.voice = voice
        self.synthesize = synthesize
        self.offline = offline
        let s = Self.clamp(speed)
        self.speed = s
        native = SpeechVoices.nativeSpeed(voice: voice, speed: s)
        sentences = ReadAloudText.split(text)
        var spoken: [String] = [], maps: [[Int]] = []
        for span in sentences {
            let (s, m) = Self.speakable(text, span)
            spoken.append(s)
            maps.append(m)
        }
        speakable = spoken
        self.maps = maps
        audio = Array(repeating: nil, count: sentences.count)
        (wake, wakeUp) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        leadIn = leadInSamples
    }

    static func clamp(_ s: Double) -> Double {
        (min(ReadAloudPlayer.maxSpeed, max(ReadAloudPlayer.minSpeed, s)) * 100).rounded() / 100
    }

    // MARK: State for the player

    var currentSpeed: Double { lock.withLock { speed } }
    var isPaused: Bool { lock.withLock { paused } }
    var isEnded: Bool { lock.withLock { ended } }
    /// Playing, but the current sentence's audio isn't ready yet.
    var isBuffering: Bool { lock.withLock { !ended && index < audio.count && audio[index] == nil } }
    /// How long the voice has spoken so far, in real time, without pauses, waits or the runway.
    var spokenSeconds: Double { lock.withLock { spoken } }

    /// The sentence being read and how far into it (0…1), and the word being spoken there as a range of `text` when
    /// the voice said where its words are (the system's voices).
    var position: (sentence: Int, fraction: Double, word: NSRange?) {
        lock.withLock {
            let i = min(index, sentences.count - 1)
            var word: NSRange?
            if !ended, let a = audio[i], !a.words.isEmpty, let w = a.words.last(where: { $0.sample <= pos }) {
                let map = maps[i]
                let start = map[min(w.range.location, map.count - 1)]
                let end = map[min(NSMaxRange(w.range), map.count - 1)]
                word = NSRange(location: start, length: max(0, end - start))
            }
            return (i, fractionLocked(), word)
        }
    }

    /// Time left at the current speed: real durations where synthesized, estimates elsewhere.
    var remaining: Double {
        lock.withLock {
            if ended { return 0 }
            var seconds = durationLocked(index) * (1 - fractionLocked())
            for i in (index + 1)..<max(index + 1, audio.count) { seconds += durationLocked(i) }
            return seconds
        }
    }

    /// How much of the whole reading is done (0…1), by time.
    var progress: Double {
        lock.withLock {
            var before = 0.0, total = 0.0
            for i in audio.indices {
                let d = durationLocked(i)
                total += d
                if i < index { before += d }
            }
            if ended || total <= 0 { return 1 }
            return min(max((before + durationLocked(index) * fractionLocked()) / total, 0), 1)
        }
    }

    // MARK: Controls

    func start() throws {
        guard !sentences.isEmpty else { ended = true; return }
        #if os(iOS)
        // Spoken audio that plays with the ring switch off; a recording (Extended Notes) keeps its own category.
        let audioSession = AVAudioSession.sharedInstance()
        if !offline, audioSession.category != .playAndRecord, audioSession.category != .record {
            try? audioSession.setCategory(.playback, mode: .spokenAudio)
        }
        if !offline { try? audioSession.setActive(true) }
        #endif
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(Self.rate), channels: 1)!
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frames, buffers -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard let data = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            render(into: data, count: Int(frames))
            return noErr
        }
        source = node
        engine.attach(node)
        engine.attach(pitch)
        engine.connect(node, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        pitch.rate = Float(speed / native)
        pitch.overlap = 16 // smoother at the far speeds
        if offline { try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096) }
        engine.prepare()
        try engine.start()
        let wake = wake
        loop = Task.detached(priority: .userInitiated) { [weak self] in
            var it = wake.makeAsyncIterator()
            while !Task.isCancelled {
                guard let self else { return }
                guard let job = self.nextJob() else {
                    if await it.next() == nil { return }
                    continue
                }
                let started = Date()
                do {
                    let a = try await self.synthesize(self.speakable[job.index], self.voice, job.native)
                    self.provide(job.index, a, generation: job.generation, native: job.native, seconds: Date().timeIntervalSince(started))
                } catch {
                    if Task.isCancelled { return }
                    let message = (error as? UserFacingError)?.message ?? "The voice engine stopped unexpectedly."
                    CoreLog.warn("Read aloud stopped: \(error.localizedDescription)")
                    self.lock.withLock { self.ended = true }
                    let failed = self.onFailed
                    await MainActor.run { failed?(message) }
                    return
                }
            }
        }
    }

    /// Pause at once, as Windows does: the time-stretch holds a moment of audio it has taken but not played yet, so
    /// that is dropped and the place moves back by as much, to be heard on resume.
    func togglePause() {
        let pausing: Bool = lock.withLock {
            guard !ended else { return false }
            paused.toggle()
            if paused, audio[index] != nil, resumeAt < 0 {
                pos = max(0, pos - Int(heldSeconds * Double(Self.rate) * speed / native))
            }
            return paused
        }
        if pausing { flush() }
    }

    /// What the time-stretch holds, in seconds of output (measured about 90 ms).
    private var heldSeconds: Double { max(pitch.latency, 0.1) }

    /// Drop the audio the time-stretch holds (after a pause or a jump, so the old place isn't heard).
    private func flush() { pitch.reset() }

    /// Jump forwards or backwards in time, e.g. ±15 seconds.
    func skip(_ seconds: Double) {
        lock.withLock {
            if ended && seconds > 0 { return }
            ended = false // skipping back from the end resumes reading (the position stays at the very end)
            var now = 0.0
            for i in 0..<index { now += durationLocked(i) }
            now += durationLocked(index) * fractionLocked()
            let target = max(0, now + seconds)
            var start = 0.0
            for i in audio.indices {
                let d = durationLocked(i)
                if target < start + d || i == audio.count - 1 {
                    seekLocked(i, d > 0 ? min(max((target - start) / d, 0), 0.999) : 0)
                    break
                }
                start += d
            }
        }
        flush()
        wakeUp.yield()
    }

    /// Jump to a spot in the text (a word clicked in the player): `sentence`, a fraction of the way into it. Works
    /// forwards and backwards, and from the end (reading resumes).
    func jump(to sentence: Int, fraction: Double) {
        lock.withLock {
            guard audio.indices.contains(sentence) else { return }
            ended = false
            seekLocked(sentence, min(max(fraction, 0), 0.999))
            leadIn = leadInSamples // a small runway, so the first word isn't clipped
        }
        flush()
        wakeUp.yield()
    }

    /// Change the reading speed. Within the voice's own pace range only the stretch changes; otherwise the current
    /// sentence is made again and read from the same point.
    func setSpeed(_ s: Double) {
        let s = Self.clamp(s)
        let rate: Float? = lock.withLock {
            if abs(s - speed) < 0.001 || ended { return nil }
            let fraction = fractionLocked()
            speed = s
            let n = SpeechVoices.nativeSpeed(voice: voice, speed: s)
            if abs(n - native) > 0.001 {
                native = n
                generation += 1
                audio = Array(repeating: nil, count: audio.count)
                seekLocked(index, fraction)
            }
            return Float(speed / native)
        }
        if let rate { pitch.rate = rate }
        wakeUp.yield()
    }

    func stop() {
        lock.withLock {
            if !reported, spoken > 0 {
                CoreLog.info(String(format: "Read aloud: %d sentence(s), the voice at %.1fx real time; ", sentences.count, realTime)
                             + (waits == 0 ? "no waits" : String(format: "waited %d time(s), %.1f s in all", waits, waitedSeconds))
                             + " after the first words")
            }
            reported = true
            ended = true
        }
        loop?.cancel()
        wakeUp.finish()
        engine.stop()
    }

    /// Tests: pull `seconds` of output through the time-stretch, as the speakers would.
    func renderOffline(seconds: Double) throws -> [Float] {
        let format = engine.manualRenderingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var out: [Float] = []
        var left = Int(seconds * format.sampleRate)
        while left > 0 {
            let n = AVAudioFrameCount(min(left, Int(buffer.frameCapacity)))
            guard try engine.renderOffline(n, to: buffer) == .success else { break }
            out += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            left -= Int(buffer.frameLength)
        }
        return out
    }

    // MARK: Inside

    private var leadInSamples: Int { Int(Double(Self.rate) / 4 * max(speed / native, 0.25)) }

    private func seekLocked(_ i: Int, _ fraction: Double) {
        index = i
        starved = true // a jump (or a new speed) may have to wait for audio; that isn't the voice falling behind
        starvedAt = nil
        if let a = audio[i] { pos = Int(fraction * Double(a.samples.count)); resumeAt = -1 }
        else { pos = 0; resumeAt = fraction }
    }

    private func fractionLocked() -> Double {
        guard index < audio.count else { return 1 }
        guard let a = audio[index] else { return resumeAt > 0 ? resumeAt : 0 }
        return a.samples.isEmpty ? 1 : Double(pos) / Double(a.samples.count)
    }

    /// One sentence's duration in real time at the current speed.
    private func durationLocked(_ i: Int) -> Double {
        guard audio.indices.contains(i) else { return 0 }
        if let a = audio[i] { return a.seconds * native / speed }
        return Double(speakable[i].utf16.count) * secondsPerChar / speed
    }

    private struct Job { let index: Int; let generation: Int; let native: Double }

    private func nextJob() -> Job? {
        lock.withLock {
            guard !ended, let i = nextToSynthesizeLocked() else { return nil }
            return Job(index: i, generation: generation, native: native)
        }
    }

    /// The first sentence from the current one on that has no audio yet, while less than `bufferAheadSeconds` is
    /// ready ahead; nil when there is enough (or nothing left).
    func nextToSynthesizeLocked() -> Int? {
        var ahead = 0.0
        for i in index..<audio.count {
            if audio[i] == nil { return i == index || ahead < Self.bufferAheadSeconds ? i : nil }
            ahead += i == index ? durationLocked(i) * (1 - fractionLocked()) : durationLocked(i)
            if ahead >= Self.bufferAheadSeconds { return nil }
        }
        return nil
    }

    /// After a wait: whether to read on now. Always, when the voice is faster than real time or everything left is
    /// ready. Otherwise only once the audio ready ahead will last while the rest is made.
    private func enoughReadyLocked() -> Bool {
        if realTime >= 1 { return true }
        var ready = 0.0
        var i = index
        while i < audio.count, audio[i] != nil {
            ready += i == index ? durationLocked(i) * (1 - fractionLocked()) : durationLocked(i)
            i += 1
        }
        if i >= audio.count { return true }
        var rest = ready
        for j in i..<audio.count { rest += durationLocked(j) }
        return ready >= min(rest * (1 - realTime), Self.maxCatchUpSeconds)
    }

    /// Store a sentence's audio, unless the pace changed since it was asked for.
    func provide(_ i: Int, _ a: SpeechAudio, generation g: Int, native n: Double, seconds: Double = 0) {
        lock.withLock {
            guard g == generation, audio.indices.contains(i) else { return }
            audio[i] = a
            if seconds > 0.05, !a.samples.isEmpty { realTime = 0.7 * realTime + 0.3 * (a.seconds / n / seconds) }
            let chars = speakable[i].utf16.count
            if chars > 20 { secondsPerChar = 0.7 * secondsPerChar + 0.3 * (a.seconds * n / Double(chars)) }
        }
        wakeUp.yield()
    }

    /// Core Audio pulls the audio here. Always fills the buffer; waits and pauses get a faint dither.
    private func render(into out: UnsafeMutablePointer<Float>, count wanted: Int) {
        var written = 0
        var finished = false, advanced = false
        lock.lock()
        while written < wanted && !paused && !ended {
            guard let a = audio[index], !(starved && !enoughReadyLocked()) else {
                // Still being made (or, on a slow device, not enough ready yet): wait, with a runway once it is.
                if !starved { starved = true; starvedAt = Date() }
                leadIn = leadInSamples
                break
            }
            if starved {
                starved = false
                if spoken > 0, let at = starvedAt { waits += 1; waitedSeconds += Date().timeIntervalSince(at) }
            }
            if leadIn > 0 {
                let n = min(leadIn, wanted - written)
                fill(out + written, n)
                leadIn -= n
                written += n
                continue
            }
            if resumeAt >= 0 { pos = Int(resumeAt * Double(a.samples.count)); resumeAt = -1 }
            let n = min(wanted - written, a.samples.count - pos)
            if n > 0 {
                a.samples.withUnsafeBufferPointer { src in (out + written).update(from: src.baseAddress! + pos, count: n) }
                pos += n
                written += n
                spoken += Double(n) / Double(Self.rate) * native / speed
            }
            if pos >= a.samples.count {
                index += 1
                pos = 0
                advanced = true
                if index >= audio.count { ended = true; index = audio.count - 1; pos = a.samples.count; finished = true }
            }
        }
        if paused { leadIn = leadInSamples } // resuming from a pause gets the runway too
        if written < wanted { fill(out + written, wanted - written) }
        lock.unlock()
        if advanced { wakeUp.yield() }
        if finished, let done = onFinished { Task { @MainActor in done() } }
    }

    /// Inaudible noise (about −80 dB), never exact zeros.
    private func fill(_ p: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n {
            noise ^= noise << 13; noise ^= noise >> 17; noise ^= noise << 5 // xorshift
            p[i] = (Float(noise & 0xFFFF) / 32768 - 1) * 1e-4
        }
    }

    /// A sentence with its runs of whitespace collapsed (`ReadAloudText.speakable`), and for each of its UTF-16 units
    /// (and its end) where it is in `text`.
    static func speakable(_ text: String, _ span: NSRange) -> (String, [Int]) {
        let ns = text as NSString
        var units: [unichar] = [], map: [Int] = []
        var space = false
        for i in span.location..<NSMaxRange(span) {
            let c = ns.character(at: i)
            if ReadAloudText.isSpace(c) { space = true; continue }
            if space, !units.isEmpty { units.append(0x20); map.append(i - 1) }
            space = false
            units.append(c)
            map.append(i)
        }
        map.append(NSMaxRange(span))
        return (String(utf16CodeUnits: units, count: units.count), map)
    }
}
