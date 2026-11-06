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
    /// The window's title at the time (Windows' WindowTitle), when it could be read: the Mac's direct build with
    /// Accessibility. nil otherwise, and in entries from before titles were kept.
    public var windowTitle: String?
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
        case id, date, transcription, aiEdit, inserted, profileName, model, appName, windowTitle, seconds, turnaroundSeconds, warning, safetyNet
        case wasInserted, runAgainAt, earlier, showingEarlier
    }

    public init(transcription: String, aiEdit: String?, inserted: String, profileName: String, model: String?, appName: String?,
                windowTitle: String? = nil, seconds: Double, turnaroundSeconds: Double, warning: String?, safetyNet: Bool = false,
                wasInserted: Bool = true) {
        self.transcription = transcription
        self.aiEdit = aiEdit
        self.inserted = inserted
        self.profileName = profileName
        self.model = model
        self.appName = appName
        self.windowTitle = windowTitle.map(Self.keptTitle)
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

    /// The list's text: what went in (or what was heard), on one line, at most 120 characters (HistoryEntry.Preview:
    /// .NET's ReplaceLineEndings, UTF-16 lengths, the cut trimmed at its end).
    public var preview: String {
        var t = inserted.isEmpty ? transcription : inserted
        t = t.replacingOccurrences(of: "\r\n", with: " ")
        for c in ["\r", "\n", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] { t = t.replacingOccurrences(of: c, with: " ") }
        let utf16 = t as NSString
        if utf16.length <= 120 { return t }
        var cut = utf16.substring(to: 117)
        while let last = cut.unicodeScalars.last, last.properties.isWhitespace { cut.unicodeScalars.removeLast() }
        return cut + "…"
    }

    /// "14:32", "Yesterday 14:32" or "3 Nov, 14:32" (HistoryEntry.When), day before month as on Windows.
    public static func when(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return DateText.time(d) }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: yesterday) { return "Yesterday " + DateText.time(d) }
        return DateText.dayMonthTime(d)
    }

    /// "40 s" or "1:05 min" (HistoryEntry.Duration).
    public static func duration(_ s: Double) -> String {
        s < 60 ? "\(Int(s.rounded())) s" : String(format: "%d:%02d min", Int(s) / 60, Int(s) % 60)
    }
    /// The browser site it went to, by name only (`WebSites`); nil when it didn't go into a browser, or when its
    /// window title was never read (the App Store build, and entries from before titles were kept).
    public var site: String? { windowTitle == nil ? nil : WebSites.site(appName, windowTitle) }

    /// As much of a window title as Windows keeps: GetWindowText into 256 characters, so the first 255 (UTF-16 units,
    /// without a half character at the cut).
    public static func keptTitle(_ title: String) -> String {
        guard title.utf16.count > 255 else { return title }
        var units = Array(title.utf16.prefix(255))
        if let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
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
    /// The folder itself is made only when the first dictation is saved into it (as Windows' HistoryStore).
    public init(dir: URL?, legacyFile: URL? = nil) {
        self.dir = dir
        guard let dir else { return }
        if let legacyFile, FileManager.default.fileExists(atPath: legacyFile.path(percentEncoded: false)) { migrate(legacyFile) }
        // Folders in name order (Directory.GetDirectories), then newest first; dictations at the same moment keep that
        // order (a stable sort, as OrderByDescending).
        let folders = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var loaded: [HistoryEntry] = []
        for folder in folders {
            guard var e = Self.load(folder.appending(path: "entry.json")) else { continue }
            e.folder = folder
            loaded.append(e)
        }
        entries = loaded.enumerated().sorted { $0.element.date != $1.element.date ? $0.element.date > $1.element.date : $0.offset < $1.offset }
            .map(\.element)
    }

    /// One entry.json, or nil when it is missing or can't be read. An unreadable one is logged and kept beside itself as
    /// entry.json.bad (Windows' JsonStore.Load).
    static func load(_ url: URL) -> HistoryEntry? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        do {
            return try decoder.decode(HistoryEntry.self, from: Data(contentsOf: url))
        } catch {
            CoreLog.error("Could not read \(url.path(percentEncoded: false)); keeping a .bad copy: \(error)")
            let bad = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.copyItem(at: url, to: bad)
            return nil
        }
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
        entry.folder = folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeJSON(entry, to: folder)
            if let pcm, !pcm.isEmpty, let url = entry.audioURL {
                try WavFile.data(pcm: pcm).write(to: url, options: .atomic)
                if !words.isEmpty, let w = entry.wordsURL, let data = try? JSONEncoder().encode(words) { try? data.write(to: w, options: .atomic) }
            }
        } catch {
            CoreLog.error("Saving a dictation to History failed: \(error)")
        }
        return entry
    }

    /// Write a changed entry back to its entry.json (after it was run again).
    public func save(_ entry: HistoryEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var entry = entry
        entry.folder = entries[i].folder
        entries[i] = entry
        guard let folder = entry.folder else { return }
        do { try writeJSON(entry, to: folder) } catch { CoreLog.error("Saving a changed dictation to History failed: \(error)") }
    }

    private func writeJSON(_ entry: HistoryEntry, to folder: URL) throws {
        try Self.encoder.encode(entry).write(to: folder.appending(path: "entry.json"), options: .atomic)
    }

    /// How many dictations keeping the newest `limit` or the last `days` days would delete now (for the confirmation).
    public func wouldDelete(limit: Int, days: Int, now: Date = Date()) -> Int {
        if limit > 0 { return max(0, entries.count - limit) }
        if days > 0 { return entries.filter { $0.date < Self.cutoff(days, now) }.count }
        return 0
    }

    /// `days` calendar days before `now`, on the local clock (DateTime.Now.AddDays(-days)): the same time of day,
    /// whatever daylight saving did in between.
    static func cutoff(_ days: Int, _ now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now.addingTimeInterval(-Double(days) * 86400)
    }

    /// Drop the entries beyond what is kept (by number or by age), and the recordings beyond what is kept of them; on
    /// each new dictation, when either is lowered, and every hour (for keeping by age).
    public func prune(_ s: AppSettings, now: Date = Date()) {
        if s.historyLimit > 0, entries.count > s.historyLimit { delete(Set(entries[s.historyLimit...].map(\.id))) }
        if s.historyDays > 0 {
            let cutoff = Self.cutoff(s.historyDays, now)
            delete(Set(entries.filter { $0.date < cutoff }.map(\.id)))
        }
        guard s.audioLimit > 0 || s.audioDays > 0 else { return } // recordings: as long as the text
        let cutoff = Self.cutoff(s.audioDays, now)
        for (i, e) in entries.enumerated() {
            let drop = (s.audioLimit > 0 && i >= s.audioLimit) || (s.audioDays > 0 && e.date < cutoff)
            if drop, e.hasAudio, let url = e.audioURL {
                do { try FileManager.default.removeItem(at: url) } catch {
                    CoreLog.warn("Could not delete a History recording: \(error.localizedDescription)")
                    continue
                }
                if let w = e.wordsURL { try? FileManager.default.removeItem(at: w) } // its words go with it
            }
        }
    }

    public func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for e in entries where ids.contains(e.id) {
            guard let folder = e.folder, FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { continue }
            do { try FileManager.default.removeItem(at: folder) } catch {
                CoreLog.warn("Could not delete a History entry: \(error.localizedDescription)")
            }
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

    /// Dates to the millisecond (as the folder names), so dictations a moment apart keep their order after a restart
    /// (Windows keeps the full time); entries from before were written in whole seconds and still read.
    static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        return enc
    }()

    static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return d }
            if let d = try? Date.ISO8601FormatStyle().parse(text) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        return dec
    }()
}

public enum WavFile {
    /// The header's length: NAudio's WaveFileWriter (Windows) writes an 18-byte fmt chunk (WAVEFORMATEX with
    /// cbSize 0), so the samples start at byte 46.
    public static let headerSize = 46

    /// 16-bit mono PCM as a .wav file, byte for byte as Windows writes it.
    public static func data(pcm: Data, sampleRate: Int = 16000) -> Data {
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(headerSize - 8 + pcm.count); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(18); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16); u16(0)
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
