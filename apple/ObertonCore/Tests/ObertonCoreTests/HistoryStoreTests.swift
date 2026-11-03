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
        #expect(wav?.count == 44 + 3200)
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

    @Test func daysLabels() {
        #expect([1, 3, 7, 14, 30, 90, 365, 21].map(HistoryStore.daysLabel) == ["24 hours", "3 days", "week", "2 weeks", "month", "3 months", "year", "3 weeks"])
    }
}
