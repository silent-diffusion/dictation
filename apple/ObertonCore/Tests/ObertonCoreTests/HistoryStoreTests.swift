import Foundation
import Testing
@testable import ObertonCore

@Suite struct HistoryStoreTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "oberton-history-tests-\(UUID().uuidString)")

    func entry(_ text: String, daysAgo: Double, now: Date) -> HistoryEntry {
        var e = HistoryEntry(transcription: text, aiEdit: nil, inserted: text, profileName: "Raw", model: nil, appName: "Mail",
                             seconds: 2, turnaroundSeconds: 0.5, warning: nil)
        e.date = now.addingTimeInterval(-daysAgo * 86400)
        return e
    }

    @Test func keepsOneFolderPerEntryWithItsRecording() {
        let now = Date()
        let store = HistoryStore(dir: dir)
        store.add(entry("one", daysAgo: 1, now: now), pcm: Data(repeating: 1, count: 3200))
        store.add(entry("two", daysAgo: 0, now: now), pcm: nil)
        let reloaded = HistoryStore(dir: dir)
        #expect(reloaded.entries.map(\.transcription) == ["two", "one"])
        #expect(reloaded.entries[1].hasAudio)
        #expect(!reloaded.entries[0].hasAudio)
        let wav = try? Data(contentsOf: reloaded.entries[1].audioURL!)
        #expect(wav?.count == 46 + 3200) // NAudio's header: an 18-byte fmt chunk
        #expect(wav.map { String(decoding: $0.prefix(4), as: UTF8.self) } == "RIFF")
    }

    @Test func savingAChangedEntryKeepsItsRecording() {
        let now = Date()
        let store = HistoryStore(dir: dir)
        store.add(entry("heard", daysAgo: 0, now: now), pcm: Data(repeating: 1, count: 320))
        var e = store.entries[0]
        e.earlier = e.version
        e.transcription = "rerun"
        e.runAgainAt = now
        store.save(e)
        let swapped = HistoryRerun.swapEarlier(HistoryStore(dir: dir).entries[0])
        #expect(swapped.transcription == "heard")
        #expect(swapped.earlier?.transcription == "rerun")
        #expect(swapped.showingEarlier == true)
        #expect(swapped.hasAudio)
    }

    @Test func prunesByNumberAgeAndRecordings() {
        let now = Date()
        let store = HistoryStore(dir: dir)
        for d in [10.0, 5, 2, 0] { store.add(entry("\(Int(d))", daysAgo: d, now: now), pcm: Data(repeating: 1, count: 32)) }
        #expect(store.wouldDelete(limit: 3, days: 0) == 1)
        #expect(store.wouldDelete(limit: 0, days: 3, now: now) == 2)
        var s = AppSettings()
        s.audioLimit = 0; s.audioDays = 3
        store.prune(s, now: now)
        #expect(store.entries.map(\.hasAudio) == [true, true, false, false])
        s.historyDays = 7
        store.prune(s, now: now)
        #expect(store.entries.map(\.transcription) == ["0", "2", "5"])
        s.historyDays = 0; s.historyLimit = 1
        store.prune(s, now: now)
        #expect(HistoryStore(dir: dir).entries.map(\.transcription) == ["0"])
    }

    @Test func movesTheOldHistoryFileIntoFolders() throws {
        let now = Date()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appending(path: "history.json")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode([entry("a", daysAgo: 0, now: now), entry("b", daysAgo: 1, now: now)]).write(to: legacy)
        let store = HistoryStore(dir: dir.appending(path: "history"), legacyFile: legacy)
        #expect(store.entries.map(\.transcription) == ["a", "b"])
        #expect(store.entries.allSatisfy { $0.didInsert && $0.folder != nil })
        #expect(!FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)))
    }

    // ThreeZeroTests.HistoryEntryTests
    @Test func previewPrefersTheInsertedTextAndIsShort() {
        var e = HistoryEntry(transcription: "raw words", aiEdit: nil, inserted: String(repeating: "a", count: 300), profileName: "Raw",
                             model: nil, appName: nil, seconds: 1, turnaroundSeconds: 0, warning: nil)
        #expect(e.preview.utf16.count <= 120)
        #expect(e.preview.hasPrefix("aaa"))
        e.inserted = ""
        #expect(e.preview == "raw words")
    }

    @Test func durationReadsNaturally() {
        #expect(HistoryEntry.duration(12.4) == "12 s")
        #expect(HistoryEntry.duration(75) == "1:15 min")
    }

    @Test func anUnknownAppStillHasAName() {
        let e = HistoryEntry(transcription: "", aiEdit: nil, inserted: "", profileName: "", model: nil, appName: nil, seconds: 0,
                             turnaroundSeconds: 0, warning: nil)
        #expect(e.appLabel == "Unknown app")
        var named = e
        named.appName = ""
        #expect(named.appLabel == "Unknown app")
    }

    @Test func recordingsAreWrittenAs16kHzMonoWav() {
        let bytes = [UInt8](WavFile.data(pcm: Data(count: 32000))) // one second
        #expect(String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF")
        func i32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        #expect(i32(24) == 16000) // sample rate
        #expect(Int(bytes[22]) | Int(bytes[23]) << 8 == 1) // channels
        #expect(bytes.count >= 32044)
        #expect(i32(16) == 18 && i32(4) == bytes.count - 8 && i32(42) == 32000) // NAudio's fmt chunk, RIFF and data sizes
        let url = dir.appending(path: "check.wav")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(bytes).write(to: url)
        #expect((try? HistoryRerun.checkFormat(url)) != nil)
    }

    @Test func theFolderIsMadeOnlyWhenSomethingIsSaved() {
        let store = HistoryStore(dir: dir)
        #expect(!FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))
        store.add(entry("one", daysAgo: 0, now: Date()), pcm: nil)
        #expect(FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))
    }

    @Test func dictationsMomentsApartKeepTheirOrderAfterARestart() {
        let store = HistoryStore(dir: dir)
        let now = Date(timeIntervalSince1970: 1_800_000_000.25)
        let first = entry("first", daysAgo: 0, now: now)
        var second = entry("second", daysAgo: 0, now: now)
        second.date = now.addingTimeInterval(0.4) // the same second
        store.add(first, pcm: nil)
        store.add(second, pcm: nil)
        let reloaded = HistoryStore(dir: dir).entries
        #expect(reloaded.map(\.transcription) == ["second", "first"])
        #expect(abs(reloaded[1].date.timeIntervalSince(now)) < 0.002)
    }

    @Test func entriesWrittenInWholeSecondsStillLoad() throws {
        let folder = dir.appending(path: "20261103-124100-000")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var e = entry("old", daysAgo: 0, now: Date())
        e.date = Date(timeIntervalSince1970: 1_800_000_000)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(e).write(to: folder.appending(path: "entry.json"))
        #expect(HistoryStore(dir: dir).entries.first?.date == e.date)
    }

    @Test func keepingByAgeCountsCalendarDays() {
        // N days back on the local clock: the same time of day, also across a change of daylight saving time.
        let now = Date()
        let cutoff = HistoryStore.cutoff(30, now)
        #expect(cutoff == Calendar.current.date(byAdding: .day, value: -30, to: now))
        let cal = Calendar.current
        #expect(cal.component(.hour, from: cutoff) == cal.component(.hour, from: now))
    }

    @Test func daysLabels() {
        #expect([1, 3, 7, 14, 30, 90, 365, 21].map(HistoryStore.daysLabel) == ["24 hours", "3 days", "week", "2 weeks", "month", "3 months", "year", "3 weeks"])
    }
}

// These catch the log through CoreLog.sink, which BrokenFileTests' serialized suite keeps to one test at a time.
extension BrokenFileTests {
    @Test func anUnreadableEntryIsSkippedAndKeptAsBad() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "oberton-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(dir: dir)
        var e = HistoryEntry(transcription: "good", aiEdit: nil, inserted: "good", profileName: "Raw", model: nil, appName: nil,
                             seconds: 1, turnaroundSeconds: 0, warning: nil)
        e.date = Date()
        store.add(e, pcm: nil)
        let broken = dir.appending(path: "20260101-120000-000")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken.appending(path: "entry.json"))
        var lines: [String] = []
        CoreLog.sink = { level, message in lines.append(level + " " + message) }
        defer { CoreLog.sink = nil }
        #expect(HistoryStore(dir: dir).entries.map(\.transcription) == ["good"])
        #expect(FileManager.default.fileExists(atPath: broken.appending(path: "entry.json.bad").path(percentEncoded: false)))
        #expect(lines.contains { $0.hasPrefix("ERROR Could not read ") && $0.contains("entry.json; keeping a .bad copy") })
    }
}

/// .NET's culture number formats (SYS-010), as History settings and Analytics use them.
@Suite struct NetNumberTests {
    let us = Locale(identifier: "en_US"), de = Locale(identifier: "de_DE")

    @Test func customFormatsRoundAt15DigitsHalfAwayFromZero() {
        #expect(NetNumber.fixed(5220.0 / 3600, digits: 1, locale: us) == "1.5")
        #expect(NetNumber.fixed(1.4, digits: 1, locale: de) == "1,4")
        #expect(NetNumber.fixed(2.0, digits: 1, optional: true, locale: us) == "2")
        #expect(NetNumber.fixed(2.25, digits: 1, optional: true, locale: us) == "2.3")
        #expect(NetNumber.fixed(0.04, digits: 1, optional: true, locale: us) == "0")
        #expect(NetNumber.fixed(12345.6, digits: 1, locale: us) == "12345.6")
    }

    @Test func percentAndGroupingFollowTheRegion() {
        #expect(NetNumber.percent(0.06, locale: us) == "6%")
        #expect(NetNumber.percent(0.125, locale: us) == "13%")
        #expect(NetNumber.percent(0.06, locale: de).hasPrefix("6") && NetNumber.percent(0.06, locale: de).hasSuffix("%")
                && NetNumber.percent(0.06, locale: de).count == 3)
        #expect(NetNumber.n0(1234, locale: us) == "1,234")
        #expect(NetNumber.n0(1234, locale: de) == "1.234")
    }
}
