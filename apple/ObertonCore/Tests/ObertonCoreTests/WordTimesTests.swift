import Foundation
import Testing
@testable import ObertonCore

/// The words heard with their times, lined up with the texts shown, and kept with the recordings (playback highlighting).
@Suite struct WordTimesTests {
    static func heard(_ text: String, every step: Double = 0.5, from: Double = 0) -> [SpokenWord] {
        text.split(separator: " ").enumerated().map { i, w in
            SpokenWord(text: String(w), start: from + Double(i) * step, end: from + Double(i) * step + step * 0.8)
        }
    }

    static func lit(_ text: String, _ spans: [TimedSpan], at t: Double) -> String? {
        WordTimes.current(spans, at: t).map { (text as NSString).substring(with: $0.range) }
    }

    @Test func keysIgnoreCaseAndPunctuation() {
        #expect(WordTimes.key("Hello,") == "hello")
        #expect(WordTimes.key("don't") == "dont")
        #expect(WordTimes.key("—") == "")
        #expect(WordTimes.key("1550") == "1550")
    }

    @Test func theTranscriptLightsEachWordAsItIsSaid() {
        let text = "okay so the beta goes out on friday"
        let spans = WordTimes.align(text, Self.heard(text))
        #expect(spans.count == 8)
        #expect(Self.lit(text, spans, at: 0.1) == "okay")
        #expect(Self.lit(text, spans, at: 1.05) == "the")
        #expect(Self.lit(text, spans, at: 3.6) == "friday")
        #expect(Self.lit(text, spans, at: 10) == nil) // long after the last word: nothing
    }

    @Test func theFormattedTextLightsTheWordsItKept() {
        let said = "okay so um the overton beta goes out on friday"
        let formatted = "The Oberton beta goes out on Friday."
        let spans = WordTimes.align(formatted, Self.heard(said))
        // "okay so um" were cut; "overton" became "Oberton" (no time); the rest keep theirs, punctuation not lit.
        #expect(Self.lit(formatted, spans, at: 1.6) == "The")
        #expect(Self.lit(formatted, spans, at: 2.3) == nil) // "overton": changed, so unlit
        #expect(Self.lit(formatted, spans, at: 4.6) == "Friday")
        #expect(WordTimes.current(spans, at: 0.2) == nil)
    }

    @Test func typedNotesHaveNoTime() {
        let said = "we ship on friday"
        let text = "Agenda: beta dates\nwe ship on friday\nmy note here"
        let spans = WordTimes.align(text, Self.heard(said))
        let shown = spans.map { (text as NSString).substring(with: $0.range) }
        #expect(shown == ["we", "ship", "on", "friday"])
    }

    @Test func aSummaryLightsOnlyPhrasesThatWereSaid() {
        let said = "the team agreed that the beta ships to ten testers on friday and the budget is final"
        let summary = "Main idea: the beta ships to ten testers. The budget is set."
        let all = WordTimes.align(summary, Self.heard(said))
        let phrases = WordTimes.align(summary, Self.heard(said), minRun: 3)
        let words = phrases.map { (summary as NSString).substring(with: $0.range) }
        #expect(words == ["beta", "ships", "to", "ten", "testers", "The", "budget", "is"], "\(words)")
        #expect(all.count > phrases.count) // "Main", "idea", "set" and a stray "the" don't count
    }

    @Test func aWordWithSpacesIsSplitAcrossItsTime() {
        let spans = WordTimes.align("new york city", [SpokenWord(text: "new york", start: 1, end: 2), SpokenWord(text: "city", start: 2, end: 2.5)])
        #expect(spans.count == 3)
        #expect(spans[0].start == 1 && spans[1].start == 1.5 && spans[2].start == 2)
    }

    @Test func aWordStaysLitBetweenWordsButNotOverAPause() {
        let spans = [TimedSpan(range: NSRange(location: 0, length: 2), start: 1, end: 1.4)]
        #expect(WordTimes.current(spans, at: 1.5) != nil) // within the hold
        #expect(WordTimes.current(spans, at: 2.0) == nil)
        #expect(WordTimes.current(spans, at: 0.9) == nil)
    }

    @Test func wordsAreStoredWithShortKeysAndShift() throws {
        let w = SpokenWord(text: "hello", start: 1.25, end: 1.5)
        let json = String(decoding: try JSONEncoder().encode(w), as: UTF8.self)
        #expect(json.contains("\"w\"") && json.contains("\"s\"") && json.contains("\"e\""))
        #expect(try JSONDecoder().decode(SpokenWord.self, from: Data(json.utf8)) == w)
        #expect(w.shifted(by: 10) == SpokenWord(text: "hello", start: 11.25, end: 11.5))
    }

    @Test func aStretchTimedOnlyAsAWholeIsSpreadByLength() {
        let w = WordTimes.spread("a longer word", start: 2, end: 4)
        #expect(w.map(\.text) == ["a", "longer", "word"])
        #expect(w.first?.start == 2 && abs((w.last?.end ?? 0) - 4) < 1e-9)
        #expect(w[1].end - w[1].start > w[0].end - w[0].start) // longer words take longer
        #expect(zip(w, w.dropFirst()).allSatisfy { abs($0.end - $1.start) < 1e-9 })
        #expect(WordTimes.spread("", start: 0, end: 1).isEmpty)
    }

    @Test func whisperTimesInTheCutAudioGoBackToTheRecording() {
        // Speech kept from 1 s to 2 s and from 5 s to 6 s: 1.5 s into the cut audio is 5.5 s into the recording.
        let p = WhisperPrep.Prepared(audio: [], regions: [16_000..<32_000, 80_000..<96_000])
        let words = p.originalWords([SpokenWord(text: "a", start: 0.5, end: 0.9), SpokenWord(text: "b", start: 1.5, end: 1.8)])
        #expect(abs(words[0].start - 1.5) < 1e-9 && abs(words[1].start - 5.5) < 1e-9 && abs(words[1].end - 5.8) < 1e-9)
    }
}

@Suite struct WordTimesStorageTests {
    @Test func aSessionKeepsItsWordsAndAnOlderOneHasNone() throws {
        let s = NoteSession()
        s.appendHeard("hello there", seconds: 0)
        s.appendWords([SpokenWord(text: "hello", start: 0, end: 0.4), SpokenWord(text: "there", start: 0.5, end: 0.9)])
        let data = try NotesStore.encoder.encode(s)
        #expect(try NotesStore.decoder.decode(NoteSession.self, from: data).words?.count == 2)
        // A session.json written before words were kept still opens.
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        old["words"] = nil
        let older = try NotesStore.decoder.decode(NoteSession.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(older.words == nil && older.transcript == "hello there")
    }

    @Test func historyKeepsTheWordsBesideTheRecordingAndDropsThemWithIt() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "oberton-words-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(dir: dir)
        let words = [SpokenWord(text: "hi", start: 0.1, end: 0.3)]
        store.add(HistoryEntry(transcription: "hi", aiEdit: nil, inserted: "Hi.", profileName: "Raw", model: nil, appName: nil,
                               seconds: 1, turnaroundSeconds: 0.2, warning: nil), pcm: Data(count: 3200), words: words)
        let e = try #require(store.entries.first)
        #expect(e.spokenWords == words)
        // No recording kept: no words either.
        store.add(HistoryEntry(transcription: "yo", aiEdit: nil, inserted: "Yo.", profileName: "Raw", model: nil, appName: nil,
                               seconds: 1, turnaroundSeconds: 0.2, warning: nil), pcm: nil, words: words)
        #expect(store.entries.first?.spokenWords == [])
        // An entry from before words were kept, or a broken file: none, and it still plays.
        try Data("not json".utf8).write(to: e.wordsURL!)
        #expect(e.spokenWords == [])
    }
}
