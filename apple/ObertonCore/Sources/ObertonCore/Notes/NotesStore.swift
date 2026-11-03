import Foundation

/// Extended Notes sessions on disk: Application Support/Oberton/notes/<yyyyMMdd-HHmmss>/session.json and audio.wav, the
/// dashboard's draft (draft.txt) and the daily counts (usage.json), as data\notes on Windows. Newest first. Use from the
/// main thread (saving writes the file in the background).
public final class NotesStore: @unchecked Sendable {
    public let dir: URL
    public private(set) var sessions: [NoteSession] = []
    /// Daily counts of the sessions, kept apart from the dictation statistics.
    public let usage: NotesUsage
    public private(set) var draft = ""
    private let disk: Bool
    private let writes = DispatchQueue(label: "Oberton.NotesStore")
    private var draftWork: DispatchWorkItem?
    /// The list changed (a session was created or deleted).
    public var sessionsChanged: (() -> Void)?

    /// `dir` nil keeps everything in memory (tests and the snapshots).
    public init(dir: URL?) {
        disk = dir != nil
        self.dir = dir ?? FileManager.default.temporaryDirectory.appending(path: "oberton-notes-memory")
        usage = NotesUsage(url: dir?.appending(path: "usage.json"))
        if disk { load() }
    }

    public static var defaultDir: URL { AppPaths.dataDir.appending(path: "notes", directoryHint: .isDirectory) }

    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private var draftURL: URL { dir.appending(path: "draft.txt") }

    private func load() {
        draft = (try? String(contentsOf: draftURL, encoding: .utf8)) ?? ""
        let folders = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [NoteSession] = []
        for folder in folders where folder.hasDirectoryPath {
            guard let data = try? Data(contentsOf: folder.appending(path: "session.json")),
                  let s = try? Self.decoder.decode(NoteSession.self, from: data) else { continue }
            s.folder = folder
            if !s.finished {
                // Oberton quit (or crashed) while it recorded: everything up to the last save is kept.
                s.finished = true
                save(s)
            }
            loaded.append(s)
        }
        sessions = loaded.sorted { $0.started > $1.started }
        NotesAudio.sweep(keeping: Set(sessions.map(\.id)))
    }

    /// A new session with its folder, first in the list.
    public func create(source: NotesSource, now: Date = Date()) throws -> NoteSession {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        var folder = dir.appending(path: f.string(from: now), directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = dir.appending(path: f.string(from: now) + "-\(n)", directoryHint: .isDirectory); n += 1
        }
        if disk { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let s = NoteSession()
        s.started = now
        s.source = source
        s.folder = folder
        s.title = "Session // " + now.formatted(.dateTime.day().month(.abbreviated)) + " " + now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
        sessions.insert(s, at: 0)
        save(s)
        sessionsChanged?()
        return s
    }

    /// Save a session: encoded here (the main thread owns it), written in the background.
    public func save(_ s: NoteSession) {
        guard disk, let folder = s.folder, let data = try? Self.encoder.encode(s) else { return }
        writes.async { try? data.write(to: folder.appending(path: "session.json"), options: .atomic) }
    }

    /// Write a session now (Oberton is quitting).
    public func saveNow(_ s: NoteSession) {
        guard disk, let folder = s.folder, let data = try? Self.encoder.encode(s) else { return }
        writes.sync { try? data.write(to: folder.appending(path: "session.json"), options: .atomic) }
    }

    public func delete(_ s: NoteSession) {
        sessions.removeAll { $0 === s }
        NotesAudio.forget(s.id)
        if disk, let folder = s.folder { try? FileManager.default.removeItem(at: folder) }
        sessionsChanged?()
    }

    /// Snapshot mode only: sessions shown without touching the disk.
    public func add(_ s: NoteSession) {
        sessions.append(s)
        sessions.sort { $0.started > $1.started }
    }

    // MARK: The dashboard's notes box between sessions

    /// The box changed: kept, and written to draft.txt a moment after the typing stops.
    public func setDraft(_ text: String) {
        if text == draft { return }
        draft = text
        guard disk else { return }
        draftWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeDraft(text) }
        draftWork = work
        writes.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// A session starts: it takes the draft, which is cleared.
    public func takeDraft() -> String {
        let taken = draft
        if taken.isEmpty { return "" }
        draft = ""
        draftWork?.cancel()
        if disk { writes.async { [weak self] in self?.writeDraft("") } }
        return taken
    }

    /// Oberton is quitting: write the draft now.
    public func flushDraft() {
        guard disk else { return }
        draftWork?.cancel()
        let text = draft
        writes.sync { writeDraft(text) }
    }

    private func writeDraft(_ text: String) {
        if text.isEmpty { try? FileManager.default.removeItem(at: draftURL); return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: draftURL, options: .atomic)
    }
}

/// One day of Extended Notes, as counts only: never any text or audio.
public struct NotesUsageDay: Codable, Sendable, Equatable {
    public var day: Date
    public var sessions = 0
    public var seconds = 0.0
    public var wordsHeard = 0
    public var wordsTyped = 0
    public var formatRequests = 0
    public var summaryRequests = 0
    /// Sessions per source: "Mic", "Computer" or "Both".
    public var sources: [String: Int] = [:]
}

/// The counts over a period, summed from its days; `aiRequests` is formatting and summary steps together.
public struct NotesUsageTotals: Sendable, Equatable {
    public var sessions = 0
    public var seconds = 0.0
    public var wordsHeard = 0
    public var wordsTyped = 0
    public var aiRequests = 0
    public var sources: [String: Int] = [:]
}

/// Daily counts of Extended Notes in notes/usage.json, kept apart from the dictation counts (usage.json): a lecture's
/// hour and its ten thousand words are not dictation, so they never show in the dashboard's meters.
public final class NotesUsage: @unchecked Sendable {
    struct FileData: Codable { var version = 1; var days: [NotesUsageDay] = [] }
    private let url: URL?
    private var data: FileData

    /// `url` nil keeps the counts in memory only.
    public init(url: URL?) {
        self.url = url
        data = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? NotesStore.decoder.decode(FileData.self, from: $0) } ?? FileData()
    }

    public var days: [NotesUsageDay] { data.days }

    /// Count a finished session, on the day it started.
    public func record(_ s: NoteSession, formatRequests: Int, summaryRequests: Int) {
        let day = Calendar.current.startOfDay(for: s.started)
        if !data.days.contains(where: { $0.day == day }) {
            data.days.append(NotesUsageDay(day: day))
            data.days.sort { $0.day < $1.day }
        }
        let i = data.days.firstIndex { $0.day == day }!
        let heard = NoteSession.words(s.heard)
        data.days[i].sessions += 1
        data.days[i].seconds += s.seconds
        data.days[i].wordsHeard += heard
        data.days[i].wordsTyped += max(0, NoteSession.words(s.transcript) - heard)
        data.days[i].formatRequests += formatRequests
        data.days[i].summaryRequests += summaryRequests
        data.days[i].sources[s.source.rawValue, default: 0] += 1
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let out = try? NotesStore.encoder.encode(data) { try? out.write(to: url, options: .atomic) }
    }

    /// The counts over the last `days` days up to and including today; 0 or less means all time.
    public func totals(now: Date = Date(), days: Int) -> NotesUsageTotals {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let first = days <= 0 ? Date.distantPast : cal.date(byAdding: .day, value: 1 - days, to: today)!
        var t = NotesUsageTotals()
        for d in data.days where d.day >= first && (days <= 0 || d.day <= today) {
            t.sessions += d.sessions
            t.seconds += d.seconds
            t.wordsHeard += d.wordsHeard
            t.wordsTyped += d.wordsTyped
            t.aiRequests += d.formatRequests + d.summaryRequests
            for (k, v) in d.sources { t.sources[k, default: 0] += v }
        }
        return t
    }

    /// Seconds as hours and whole minutes: 0:45, 12:03.
    public static func hoursMinutes(_ seconds: Double) -> String {
        let t = Int(max(0, seconds))
        return String(format: "%d:%02d", t / 3600, t / 60 % 60)
    }
}

/// Extended Notes over a period, for Analytics (worked out from the sessions kept, so it follows deletions).
public struct NotesFigures: Sendable {
    public var sessions: Int
    public var seconds: Double
    public var wordsHeard: Int
    public var wordsTyped: Int
    public var markers: Int
    public var steps: Int
    public var stepsKept: Int
    public var longest: [NoteSession]
    public var sources: [NotesSource: (sessions: Int, seconds: Double)]

    /// Words heard per minute recorded.
    public var wordsPerMinute: Double? { seconds >= 60 ? Double(wordsHeard) / (seconds / 60) : nil }

    /// The finished sessions started on or after `from` (all of them when nil).
    public static func compute(_ all: [NoteSession], from: Date?, longest n: Int = 5) -> NotesFigures {
        let list = all.filter { $0.finished && (from == nil || $0.started >= from!) }
        var sources: [NotesSource: (sessions: Int, seconds: Double)] = [:]
        var heard = 0, typed = 0
        for s in list {
            let v = sources[s.source] ?? (0, 0)
            sources[s.source] = (v.sessions + 1, v.seconds + s.seconds)
            let h = NoteSession.words(s.heard)
            heard += h
            typed += max(0, NoteSession.words(s.transcript) - h)
        }
        return NotesFigures(sessions: list.count, seconds: list.reduce(0) { $0 + $1.seconds }, wordsHeard: heard, wordsTyped: typed,
                            markers: list.reduce(0) { $0 + $1.markers.count }, steps: list.reduce(0) { $0 + $1.chunks.count },
                            stepsKept: list.reduce(0) { $0 + $1.chunks.filter { !$0.aiFailed }.count },
                            longest: Array(list.sorted { $0.seconds > $1.seconds }.prefix(n)), sources: sources)
    }
}
