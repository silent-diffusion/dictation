import Foundation

/// A pause in a recording, in seconds.
public struct AudioPause: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
}

/// A recording made ready to play (`NotesAudio.prepareCached`): where the louder copy is, and its pauses.
public struct PreparedAudio: Codable, Sendable {
    public var url: URL
    public var seconds: Double
    /// How much the level was raised.
    public var gainDb: Double
    public var silences: [AudioPause]

    /// The pause `seconds` falls in, if any.
    public func silence(at seconds: Double) -> AudioPause? {
        for s in silences {
            if s.start > seconds { break }
            if seconds < s.end { return s }
        }
        return nil
    }
}

/// The session's recording: 16 kHz mono 16-bit PCM, written as it comes in. The header's sizes are put right on every
/// flush, so the file plays even if Oberton stops without closing it.
public final class WavWriter: @unchecked Sendable {
    public static let sampleRate = 16_000
    private let handle: FileHandle
    private var bytes: UInt32 = 0
    private let lock = NSLock()

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: WavWriter.header(dataBytes: 0))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    static func header(dataBytes: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    /// Samples -1…1, appended.
    public func write(_ samples: [Float]) {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            // Rounded to the nearest step, as Windows' writer (Math.Round), not cut towards zero.
            let v = Int16((max(-1, min(1, s)) * 32767).rounded(.toNearestOrEven))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        lock.withLock {
            try? handle.write(contentsOf: pcm)
            bytes += UInt32(pcm.count)
        }
    }

    /// Put the header's sizes right (and keep writing at the end).
    public func flush() {
        do { try flushing() } catch { CoreLog.warn("Extended notes: flushing audio failed: " + error.localizedDescription) }
    }

    private func flushing() throws {
        try lock.withLock {
            let end = try handle.offset()
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: WavWriter.header(dataBytes: bytes))
            try handle.seek(toOffset: end)
            try handle.synchronize()
        }
    }

    public func close() {
        do {
            try flushing()
            try lock.withLock { try handle.close() }
        } catch {
            CoreLog.warn("Extended notes: closing the recording failed: " + error.localizedDescription)
        }
    }
}

/// Gets a recording ready for playback (NotesAudio.cs). Microphone recordings are often very quiet, so the level is
/// raised to bring the speech near full scale (never lowered, never by more than `maxGainDb`), and the pauses are found
/// so playback can skip them. The result is a new file in the temporary folder; the recording itself stays as it is.
public enum NotesAudio {
    public static let targetPeak = 0.89
    public static let maxGainDb = 40.0
    /// A pause counts as a silence from this long.
    public static let minSilence = 0.7
    /// How much of a silence is kept when skipping it, so the speech doesn't run together.
    public static let keepGap = 0.25
    static let windowSeconds = 0.05

    /// The prepared copies, one per session, named by the session's id.
    public static var cacheDir: URL { FileManager.default.temporaryDirectory.appending(path: "oberton-notes", directoryHint: .isDirectory) }

    /// The 16-bit mono samples of a WAV file written by `WavWriter` (or any 16-bit PCM WAV), and its sample rate.
    public static func readWav(_ url: URL) throws -> (samples: [Int16], rate: Int) {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        guard d.count >= 12, String(decoding: d[0..<4], as: UTF8.self) == "RIFF" else { throw UserFacingError("The recording isn't a WAV file.") }
        func u32(_ at: Int) -> Int { Int(d[at]) | Int(d[at + 1]) << 8 | Int(d[at + 2]) << 16 | Int(d[at + 3]) << 24 }
        func u16(_ at: Int) -> Int { Int(d[at]) | Int(d[at + 1]) << 8 }
        var at = 12, rate = WavWriter.sampleRate, channels = 1, bits = 16
        while at + 8 <= d.count {
            let id = String(decoding: d[at..<(at + 4)], as: UTF8.self), size = u32(at + 4)
            if id == "fmt " { channels = u16(at + 10); rate = u32(at + 12); bits = u16(at + 22) }
            if id == "data" {
                guard bits == 16 else { throw UserFacingError("This recording isn't 16-bit audio.") }
                let end = min(d.count, at + 8 + (size == 0 ? d.count : size))
                var samples = [Int16](repeating: 0, count: (end - at - 8) / 2 / channels)
                for i in samples.indices { samples[i] = Int16(bitPattern: UInt16(u16(at + 8 + i * 2 * channels))) }
                return (samples, rate)
            }
            at += 8 + size + (size & 1)
        }
        throw UserFacingError("The recording has no audio in it.")
    }

    /// Per window of 50 ms: the peak (0…1) and the RMS in dB.
    static func scan(_ samples: [Int16], rate: Int) -> (peaks: [Float], levels: [Float]) {
        let window = max(1, Int(Double(rate) * windowSeconds))
        var peaks: [Float] = [], levels: [Float] = []
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + window)
            var peak: Float = 0, sum = 0.0
            for k in i..<end {
                let v = Float(samples[k]) / 32768
                peak = max(peak, abs(v))
                sum += Double(v * v)
            }
            peaks.append(peak)
            levels.append(db((sum / Double(end - i)).squareRoot()))
            i = end
        }
        return (peaks, levels)
    }

    static func db(_ v: Double) -> Float { Float(20 * log10(max(v, 1e-6))) }

    /// The recording's pauses, without making a copy.
    public static func pauses(_ url: URL) throws -> [AudioPause] {
        let (samples, rate) = try readWav(url)
        return findSilences(scan(samples, rate: rate).levels, windowSeconds: windowSeconds)
    }

    /// The gain that brings the loud windows to `targetPeak`: the loudest half-percent of windows don't count, and the
    /// level is never lowered.
    public static func gain(_ windowPeaks: [Float]) -> Float {
        if windowPeaks.isEmpty { return 1 }
        let sorted = windowPeaks.sorted()
        let loud = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.995))]
        if loud <= 0.0005 { return 1 } // silence: nothing to bring up
        return Float(min(max(targetPeak / Double(loud), 1), pow(10, maxGainDb / 20)))
    }

    /// The pauses: runs of windows well under the recording's own speech level and close to its noise floor.
    public static func findSilences(_ levelsDb: [Float], windowSeconds: Double) -> [AudioPause] {
        var result: [AudioPause] = []
        if levelsDb.count < 4 { return result }
        let sorted = levelsDb.sorted()
        let floor = sorted[Int(Double(sorted.count) * 0.2)], speech = sorted[Int(Double(sorted.count) * 0.9)]
        let threshold = max(-65, min(floor + 8, speech - 20))
        let minWindows = Int((minSilence / windowSeconds).rounded(.up))
        var start = -1
        for i in 0...levelsDb.count {
            let quiet = i < levelsDb.count && levelsDb[i] < threshold
            if quiet { if start < 0 { start = i }; continue }
            if start >= 0 && i - start >= minWindows {
                result.append(AudioPause(start: Double(start) * windowSeconds, end: Double(i) * windowSeconds))
            }
            start = -1
        }
        return result
    }

    public static func prepare(_ url: URL, to out: URL) throws -> PreparedAudio {
        let (samples, rate) = try readWav(url)
        let (peaks, levels) = scan(samples, rate: rate)
        let g = gain(peaks)
        let writer = try WavWriter(url: out)
        var chunk: [Float] = []
        chunk.reserveCapacity(rate)
        for (i, s) in samples.enumerated() {
            chunk.append(Float(s) / 32768 * g)
            if chunk.count == rate || i == samples.count - 1 { writer.write(chunk); chunk.removeAll(keepingCapacity: true) }
        }
        writer.close()
        let gainDb = 20 * log10(Double(g)), silences = findSilences(levels, windowSeconds: windowSeconds)
        CoreLog.info("Extended notes: recording prepared, +\(String(format: "%.1f", gainDb)) dB, \(silences.count) pauses")
        return PreparedAudio(url: out, seconds: Double(samples.count) / Double(rate), gainDb: gainDb, silences: silences)
    }

    /// The prepared copy of a session's recording: made the first time, then found again (unless the recording is newer).
    public static func prepareCached(_ url: URL, sessionID: String) throws -> PreparedAudio {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let copy = cacheDir.appending(path: sessionID + ".wav"), meta = cacheDir.appending(path: sessionID + ".json")
        func modified(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        if FileManager.default.fileExists(atPath: copy.path), modified(copy) >= modified(url),
           let data = try? Data(contentsOf: meta), var cached = try? JSONDecoder().decode(PreparedAudio.self, from: data), cached.seconds > 0 {
            cached.url = copy
            return cached
        }
        let tmp = cacheDir.appending(path: sessionID + ".wav.tmp")
        var prepared = try prepare(url, to: tmp)
        _ = try? FileManager.default.removeItem(at: copy)
        try FileManager.default.moveItem(at: tmp, to: copy)
        prepared.url = copy
        do { try JSONEncoder().encode(prepared).write(to: meta) } catch {
            CoreLog.warn("Extended notes: couldn't keep the prepared recording's details: " + error.localizedDescription)
        }
        return prepared
    }

    /// Delete prepared copies whose session no longer exists; not one made in the last 10 minutes (it may be being
    /// prepared right now, for a session another store has).
    public static func sweep(keeping ids: Set<String>) {
        guard FileManager.default.fileExists(atPath: cacheDir.path) else { return }
        // Session ids compared without regard to case (Windows' OrdinalIgnoreCase).
        let keep = Set(ids.map { $0.lowercased() })
        do {
            let files = try FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey])
            for f in files where !keep.contains(String(f.lastPathComponent.prefix { $0 != "." }).lowercased()) {
                let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if Date().timeIntervalSince(modified) > 600 { try FileManager.default.removeItem(at: f) }
            }
        } catch {
            CoreLog.warn("Extended notes: sweeping the playback copies failed: " + error.localizedDescription)
        }
    }

    /// A session was deleted: its prepared copy goes too.
    public static func forget(_ id: String) {
        for ext in [".wav", ".json", ".wav.tmp"] { try? FileManager.default.removeItem(at: cacheDir.appending(path: id + ext)) }
    }
}

/// Which AI model formats and sums up Extended Notes (NotesModels.cs). The default is the best one on this Mac: the
/// largest installed Ollama model that fits in the memory the GPU may use (Metal's recommended working set), since notes
/// run in the background and gain more from a stronger model than they lose to its speed. A mixture-of-experts model
/// (Qwen3 30B-A3B) also fits when it fits in the Mac's memory: only a few billion of its parameters work on each word.
/// With no Ollama model, the active model (Apple Intelligence by default). A model can also be picked by name, or the
/// active model followed.
public enum NotesModels {
    /// The setting's value for "the best model on this Mac" (the default).
    public static let best = ""
    /// The setting's value for "the active model".
    public static let active = "active"
    /// Without a GPU figure, larger models are too slow to keep up with a lecture.
    public static let maxBillionsWithoutGpu = 4.5

    /// An installed Ollama model: its name, size on disk, parameters (billions) and family.
    public typealias Installed = LocalModel

    /// A model that writes text (not an embedding model), and runs here rather than on ollama.com.
    public static func isChatModel(_ m: Installed) -> Bool {
        !m.name.lowercased().contains("embed") && !m.family.lowercased().contains("bert") && !ModelID.isOllamaCloud(m.name)
    }

    /// Whether a model fits: in what the GPU works on when that is known, otherwise small enough for the processor; or a
    /// mixture of experts that runs from memory (`ramBytes`, nil when not known).
    public static func fits(_ m: Installed, gpuBytes: Int64?, ramBytes: Int64? = nil) -> Bool {
        (gpuBytes.map { m.bytes <= $0 } ?? (m.billions <= maxBillionsWithoutGpu)) || m.runsFromMemory(gpuBytes: gpuBytes, ramBytes: ramBytes)
    }

    /// The best installed model: the most parameters among those that fit, then the larger file (a finer quantization);
    /// nothing fits → the smallest; nil when none is installed. Never one of Ollama's cloud models (`-cloud`, `:cloud`,
    /// `-cloud:latest`): they list like installed ones, but run on ollama.com, so the transcript would leave this Mac.
    public static func pickBest(_ installed: [Installed], gpuBytes: Int64?, ramBytes: Int64? = nil) -> Installed? {
        let chat = installed.filter(isChatModel)
        return chat.filter { fits($0, gpuBytes: gpuBytes, ramBytes: ramBytes) }
            .sorted { ($0.billions, $0.bytes, $1.name) > ($1.billions, $1.bytes, $0.name) }.first ?? chat.min { $0.bytes < $1.bytes }
    }

    /// The model the setting means right now, and why (for the log). A model picked by name that is no longer installed
    /// falls back to the best.
    public static func resolve(_ setting: String, activeModel: ModelID, installed: [Installed], gpuBytes: Int64?,
                               ramBytes: Int64? = nil) -> (model: ModelID, why: String) {
        let setting = setting.trimmed
        if setting.lowercased() == active { return (activeModel, "the active model") }
        if let id = ModelID(setting), id.provider != .ollama { return (id, id.isLocal ? "chosen" : "chosen, cloud") }
        let name = ModelID(setting)?.name ?? setting
        func same(_ a: String, _ b: String) -> Bool { let a = a.lowercased(), b = b.lowercased(); return a == b || a == b + ":latest" || a + ":latest" == b }
        if !name.isEmpty, let chosen = installed.first(where: { same($0.name, name) }) {
            return (ModelID(provider: .ollama, name: chosen.name), ModelID.isOllamaCloud(chosen.name) ? "chosen, cloud" : "chosen")
        }
        if let b = pickBest(installed, gpuBytes: gpuBytes, ramBytes: ramBytes) {
            let why = b.runsFromMemory(gpuBytes: gpuBytes, ramBytes: ramBytes) ? "best on this Mac: a mixture of experts that runs from \(gb(ramBytes!)) of memory"
                : gpuBytes.map { "best on this Mac: the largest that fits in \(gb($0)) of GPU memory" } ?? "best on this Mac without a GPU"
            return (ModelID(provider: .ollama, name: b.name), why)
        }
        return (activeModel, "the active model; no Ollama model is installed")
    }

    /// Bytes as "6 GB" (one decimal below 10).
    public static func gb(_ bytes: Int64) -> String {
        let g = Double(bytes) / 1_073_741_824
        return g < 10 ? String(format: "%.1f GB", g).replacingOccurrences(of: ".0 ", with: " ") : String(format: "%.0f GB", g)
    }
}

/// Mixes the computer's audio into the microphone's for "Both" (NotesMixer in LoopbackCapture.cs). Both arrive as
/// 16 kHz mono samples on their own clocks; the computer's wait here until a mic chunk takes them.
public final class NotesMixer: @unchecked Sendable {
    private let lock = NSLock()
    private var computer: [Float] = []
    /// At most about this much computer audio waits for the mic (a second).
    public static let maxBacklog = WavWriter.sampleRate

    public init() {}

    public func addComputer(_ samples: [Float]) {
        lock.withLock {
            computer += samples
            if computer.count > Self.maxBacklog * 4 { computer.removeFirst(computer.count - Self.maxBacklog * 4) }
        }
    }

    /// `count` samples of computer audio alone (clipped to -1…1), silence where none arrived (Windows' TakeComputer):
    /// computer audio alone is paced by a clock, so the recording runs on through silence and a lost device.
    public func takeComputer(_ count: Int) -> [Float] {
        guard count > 0 else { return [] }
        return lock.withLock {
            let n = min(count, computer.count)
            var out = computer.prefix(n).map { max(-1, min(1, $0)) }
            computer.removeFirst(n)
            if n < count { out += [Float](repeating: 0, count: count - n) }
            return out
        }
    }

    /// A mic chunk mixed with the computer audio that arrived meanwhile (clipped to -1…1).
    public func mix(withMic mic: [Float]) -> [Float] {
        lock.withLock {
            // Clocks drift: never fall behind by more than a second.
            if computer.count > Self.maxBacklog + mic.count { computer.removeFirst(computer.count - Self.maxBacklog - mic.count) }
            let n = min(mic.count, computer.count)
            var out = mic
            for i in 0..<n { out[i] = max(-1, min(1, mic[i] + computer[i])) }
            computer.removeFirst(n)
            return out
        }
    }
}
