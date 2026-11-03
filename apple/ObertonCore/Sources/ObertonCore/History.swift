import AVFoundation
import Foundation

/// One past dictation: what was heard, what the AI made of it, where it went (Dictation.Core/Session/History.cs).
public struct HistoryEntry: Codable, Identifiable, Sendable, Hashable {
    public var id = UUID()
    public var date = Date()
    public var transcription: String
    public var aiEdit: String?
    public var inserted: String
    public var profileName: String
    public var model: String?
    public var appName: String?
    public var seconds: Double
    public var turnaroundSeconds: Double
    public var warning: String?
    /// The safety net rejected the AI's edit (all of it or some parts); nil in entries saved before this was kept.
    public var safetyNet: Bool?
    /// The text went in; false when inserting failed. nil in entries saved before this was kept (they all went in).
    public var wasInserted: Bool?
    /// When it was last run again from its recording (History › Run again); nil if never.
    public var runAgainAt: Date?
    /// The other version of its text: from before it was run again, or, once that is put back, the rerun's.
    public var earlier: HistoryVersion?
    /// True while the text shown is the one from before the rerun (put back).
    public var showingEarlier: Bool?
    /// The entry's folder under history/ (entry.json and audio.wav); nil when it isn't kept on disk.
    public var folder: URL?

    enum CodingKeys: String, CodingKey {
        case id, date, transcription, aiEdit, inserted, profileName, model, appName, seconds, turnaroundSeconds, warning, safetyNet
        case wasInserted, runAgainAt, earlier, showingEarlier
    }

    public init(transcription: String, aiEdit: String?, inserted: String, profileName: String, model: String?, appName: String?,
                seconds: Double, turnaroundSeconds: Double, warning: String?, safetyNet: Bool = false, wasInserted: Bool = true) {
        self.transcription = transcription
        self.aiEdit = aiEdit
        self.inserted = inserted
        self.profileName = profileName
        self.model = model
        self.appName = appName
        self.seconds = seconds
        self.turnaroundSeconds = turnaroundSeconds
        self.warning = warning
        self.safetyNet = safetyNet
        self.wasInserted = wasInserted
    }

    /// Words in what went in, or in what was heard when nothing went in (HistoryEntry.Words).
    public var words: Int { (inserted.isEmpty ? transcription : inserted).split(whereSeparator: \.isWhitespace).count }
    public var didInsert: Bool { wasInserted ?? true }
    /// The AI's own output (Windows' AiOutput): nil when no AI edit was used, or when the AI step gave back the words
    /// unchanged with a warning (a failure in entries saved before failures were kept as nil: nothing of the AI's went in).
    public var aiOutput: String? { aiEdit == transcription && warning != nil ? nil : aiEdit }
    /// The safety net rejected the AI's edit (all of it or some parts); entries from before it was kept fall back to
    /// what their text shows.
    public var isSafetyNet: Bool { safetyNet ?? (aiEdit != nil && aiEdit == transcription && warning != nil) }
    /// The app's name, or "Unknown app".
    public var appLabel: String { appName.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown app" }
    public var audioURL: URL? { folder?.appending(path: "audio.wav") }
    /// The words heard with when each was said, beside the recording (playback lights the word being said).
    public var wordsURL: URL? { folder?.appending(path: "words.json") }

    /// The recording's words; none for entries from before they were kept, or a file that can't be read.
    public var spokenWords: [SpokenWord] {
        guard let url = wordsURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SpokenWord].self, from: data)) ?? []
    }
    public var hasAudio: Bool { audioURL.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false }

    /// This entry's text as one version (for keeping it while a rerun's result is shown).
    var version: HistoryVersion {
        HistoryVersion(transcription: transcription, aiEdit: aiEdit, inserted: inserted, safetyNet: safetyNet ?? false,
                       warning: warning, profileName: profileName, wasInserted: didInsert)
    }

    mutating func apply(_ v: HistoryVersion) {
        transcription = v.transcription
        aiEdit = v.aiEdit
        inserted = v.inserted
        safetyNet = v.safetyNet
        warning = v.warning
        profileName = v.profileName
        wasInserted = v.wasInserted
    }
}

/// One version of a dictation's text (see `HistoryEntry.earlier`).
public struct HistoryVersion: Codable, Sendable, Hashable {
    public var transcription: String
    public var aiEdit: String?
    public var inserted: String
    public var safetyNet: Bool
    public var warning: String?
    public var profileName: String
    public var wasInserted: Bool

    public init(transcription: String, aiEdit: String?, inserted: String, safetyNet: Bool, warning: String?, profileName: String, wasInserted: Bool) {
        self.transcription = transcription
        self.aiEdit = aiEdit
        self.inserted = inserted
        self.safetyNet = safetyNet
        self.warning = warning
        self.profileName = profileName
        self.wasInserted = wasInserted
    }
}

/// Recent dictations, kept in history/ in the data folder (one folder each: entry.json and the recording as audio.wav),
/// as on Windows. Only what the settings say is kept (by number or by age), and recordings maybe for less. Use from the
/// main thread.
public final class HistoryStore {
    /// nil: kept in memory only.
    public let dir: URL?
    public private(set) var entries: [HistoryEntry] = []

    public static var defaultDir: URL { AppPaths.dataDir.appending(path: "history", directoryHint: .isDirectory) }

    /// `legacyFile`: the single history.json earlier versions kept; its entries move into folders once, and the file is
    /// renamed history.json.moved (not deleted).
    public init(dir: URL?, legacyFile: URL? = nil) {
        self.dir = dir
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let legacyFile, FileManager.default.fileExists(atPath: legacyFile.path(percentEncoded: false)) { migrate(legacyFile) }
        let folders = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appending(path: "entry.json")),
                  var e = try? Self.decoder.decode(HistoryEntry.self, from: data) else { continue }
            e.folder = folder
            entries.append(e)
        }
        entries.sort { $0.date > $1.date }
    }

    private func migrate(_ file: URL) {
        guard let data = try? Data(contentsOf: file) else { return }
        // Written with ISO 8601 dates; very old files may have the default.
        let old = (try? Self.decoder.decode([HistoryEntry].self, from: data)) ?? (try? JSONDecoder().decode([HistoryEntry].self, from: data))
        guard let old else { return }
        for e in old { write(e, pcm: nil) }
        try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("moved"))
    }

    /// Keep a finished dictation, with its recording (16 kHz mono 16-bit PCM) if recordings are kept, and the words
    /// heard with their times (kept with the recording only).
    public func add(_ entry: HistoryEntry, pcm: Data?, words: [SpokenWord] = []) {
        entries.insert(write(entry, pcm: pcm, words: words), at: 0)
    }

    @discardableResult private func write(_ entry: HistoryEntry, pcm: Data?, words: [SpokenWord] = []) -> HistoryEntry {
        var entry = entry
        guard let dir else { return entry }
        var folder = dir.appending(path: Self.folderName(entry.date), directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            folder = dir.appending(path: Self.folderName(entry.date) + "-" + entry.id.uuidString.prefix(4), directoryHint: .isDirectory)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        entry.folder = folder
        saveJSON(entry)
        if let pcm, !pcm.isEmpty, let url = entry.audioURL {
            try? WavFile.data(pcm: pcm).write(to: url, options: .atomic)
            if !words.isEmpty, let w = entry.wordsURL, let data = try? JSONEncoder().encode(words) { try? data.write(to: w, options: .atomic) }
        }
        return entry
    }

    /// Write a changed entry back to its entry.json (after it was run again).
    public func save(_ entry: HistoryEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var entry = entry
        entry.folder = entries[i].folder
        entries[i] = entry
        saveJSON(entry)
    }

    private func saveJSON(_ entry: HistoryEntry) {
        guard let folder = entry.folder, let data = try? Self.encoder.encode(entry) else { return }
        try? data.write(to: folder.appending(path: "entry.json"), options: .atomic)
    }

    /// How many dictations keeping the newest `limit` or the last `days` days would delete now (for the confirmation).
    public func wouldDelete(limit: Int, days: Int, now: Date = Date()) -> Int {
        if limit > 0 { return max(0, entries.count - limit) }
        if days > 0 { return entries.filter { $0.date < now.addingTimeInterval(-Double(days) * 86400) }.count }
        return 0
    }

    /// Drop the entries beyond what is kept (by number or by age), and the recordings beyond what is kept of them; on
    /// each new dictation, when either is lowered, and every hour (for keeping by age).
    public func prune(_ s: AppSettings, now: Date = Date()) {
        if s.historyLimit > 0, entries.count > s.historyLimit { delete(Set(entries[s.historyLimit...].map(\.id))) }
        if s.historyDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(s.historyDays) * 86400)
            delete(Set(entries.filter { $0.date < cutoff }.map(\.id)))
        }
        guard s.audioLimit > 0 || s.audioDays > 0 else { return } // recordings: as long as the text
        let cutoff = now.addingTimeInterval(-Double(s.audioDays) * 86400)
        for (i, e) in entries.enumerated() {
            let drop = (s.audioLimit > 0 && i >= s.audioLimit) || (s.audioDays > 0 && e.date < cutoff)
            if drop, e.hasAudio, let url = e.audioURL {
                try? FileManager.default.removeItem(at: url)
                if let w = e.wordsURL { try? FileManager.default.removeItem(at: w) } // its words go with it
            }
        }
    }

    public func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for e in entries where ids.contains(e.id) {
            if let folder = e.folder { try? FileManager.default.removeItem(at: folder) }
        }
        entries.removeAll { ids.contains($0.id) }
    }

    public func clear() { delete(Set(entries.map(\.id))) }

    /// Bytes on disk under history/ (texts and recordings), for "N dictations, X MB."
    public var sizeBytes: Int64 {
        guard let dir, let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }

    /// What a days setting says: "24 hours", "week", "2 weeks", "month"… (HistoryStore.DaysLabel).
    public static func daysLabel(_ days: Int) -> String {
        switch days {
        case 1: "24 hours"
        case 7: "week"
        case 14: "2 weeks"
        case 30: "month"
        case 90: "3 months"
        case 180: "6 months"
        case 365: "year"
        case _ where days % 7 == 0: "\(days / 7) weeks"
        default: "\(days) days"
        }
    }

    static func folderName(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: d)
    }

    static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()
}

public enum WavFile {
    /// 16-bit mono PCM as a .wav file.
    public static func data(pcm: Data, sampleRate: Int = 16000) -> Data {
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(pcm.count)
        d.append(pcm)
        return d
    }
}

/// Keeps the microphone audio of the dictation running now as 16 kHz mono 16-bit PCM, for History's audio.wav. Fed from
/// the audio thread; `begin` and `finish` from the main thread.
public final class HistoryAudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pcm = Data()
    private var recording = false
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    public init() {}

    public func begin() { lock.withLock { pcm = Data(); recording = true; converter = nil } }

    /// The recording so far; stops keeping more.
    public func finish() -> Data { lock.withLock { recording = false; defer { pcm = Data() }; return pcm } }

    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard recording, buffer.frameLength > 0 else { return }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        pcm.append(UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
    }
}
