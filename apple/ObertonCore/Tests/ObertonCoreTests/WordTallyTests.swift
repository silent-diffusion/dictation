import Foundation
import Testing
@testable import ObertonCore

// Ported from tests/Dictation.Tests/WordTallyTests.cs: the Analytics word tally, what one dictation adds, and the
// figures read back from it.

@Suite struct WordTallyTests {
    private func entry(_ transcript: String, ai: String? = nil, inserted: String? = nil, profile: String = "Light Cleanup",
                       app: String? = nil, date: Date = Date(), warning: String? = nil, safetyNet: Bool = false) -> HistoryEntry {
        var e = HistoryEntry(transcription: transcript, aiEdit: ai, inserted: inserted ?? ai ?? transcript, profileName: profile, model: nil,
                             appName: app, seconds: 3, turnaroundSeconds: 1.2, warning: warning, safetyNet: safetyNet)
        e.date = date
        return e
    }

    @Test func aMisheardNameFixedByTheAIIsACorrection() {
        let item = WordTally.analyze(transcript: "I opened Overton today", aiOutput: "I opened Oberton today.", final: "I opened Oberton today.")
        #expect(item.corrections == ["overton" + WordTally.arrow + "Oberton"])
    }

    @Test func capitalsAndPunctuationAloneAreNotCorrections() {
        let item = WordTally.analyze(transcript: "whisper is great", aiOutput: "Whisper is great.", final: "Whisper is great.")
        #expect(item.corrections.isEmpty)
        #expect(item.wordsChanged == 0)
    }

    @Test func grammarFixesWithOnlyCommonWordsAreNotCorrections() {
        #expect(WordTally.correction(removed: ["a"], added: ["the"]) == nil)
    }

    @Test func fillersTheAIRemovedAreCountedAndAreNotCorrections() {
        let item = WordTally.analyze(transcript: "um I think uh we should you know go", aiOutput: "I think we should go.", final: "I think we should go.")
        #expect(item.fillers.sorted() == ["uh", "um", "you know"])
        #expect(item.corrections.isEmpty)
    }

    @Test func withoutAnAIEditThereAreNoCorrectionsOrFillers() {
        let item = WordTally.analyze(transcript: "um the Overton release", aiOutput: nil, final: "um the Overton release")
        #expect(item.corrections.isEmpty)
        #expect(item.fillers.isEmpty)
    }

    @Test func wordsComeFromTheTextThatWentInWithoutCommonWords() {
        let item = WordTally.analyze(transcript: "oberton reads the release notes", aiOutput: nil, final: "Oberton reads the release notes.")
        #expect(item.words == ["oberton", "reads", "release", "notes"])
    }

    @Test func curlyApostrophesAreStraightened() {
        #expect(WordTally.tokens("Don’t stop, it’s fine") == ["don't", "stop", "it's", "fine"])
    }

    @Test func phrasesAreThreeAndFourWordsWithMeaningAndStayInsideASentence() {
        let item = WordTally.analyze(transcript: "", aiOutput: nil, final: "Go ahead and publish it. And it was done.")
        #expect(item.phrases.contains("go ahead and"))
        #expect(item.phrases.contains("go ahead and publish"))
        #expect(!item.phrases.contains("and it was"))     // only common words
        #expect(!item.phrases.contains("publish it and")) // crosses a sentence end
    }

    @Test func topPhrasesNeedRepeatsAndSkipPartsOfLongerOnes() {
        var day = TallyDay(day: UsageLog.key(Date()))
        day.phrases = ["go ahead and": 5, "go ahead and publish": 4, "make sure that": 3, "said once only": 1]
        #expect(WordTally.topPhrases([day], 5).map(\.phrase) == ["go ahead and", "make sure that"])
    }

    @Test func hoursAreLaidOutMondayFirst() {
        var monday = TallyDay(day: "2026-10-12")
        monday.hours[9] = 3
        var sunday = TallyDay(day: "2026-10-18")
        sunday.hours[22] = 1
        let grid = WordTally.weekHours([monday, sunday])
        #expect(grid[0][9] == 3)
        #expect(grid[6][22] == 1)
    }

    @Test func profilesAreSummedAcrossDaysBusiestFirst() {
        func d(_ key: String, _ name: String, _ n: Int) -> TallyDay {
            var t = TallyDay(day: key)
            var p = ProfileTally()
            p.dictations = n; p.aiEdited = n; p.aiKept = n - 1; p.wordsHeard = 100; p.wordsChanged = 10
            t.profiles[name] = p
            return t
        }
        let rows = WordTally.byProfile([d("2026-10-01", "Raw", 2), d("2026-10-02", "Light Cleanup", 3), d("2026-10-03", "Light Cleanup", 4)])
        #expect(rows[0].profile == "Light Cleanup")
        #expect(rows[0].total.dictations == 7)
        #expect(rows[0].total.wordsHeard == 200)
    }

    @Test func theTallyIsOnByDefault() { #expect(AppSettings().keepWordTally) }

    @Test func oldSettingsFilesTurnTheTallyOn() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hotkey":"Ctrl+D"}"#.utf8))
        #expect(s.keepWordTally)
    }

    @Test func seedingCountsAndKeepsNoSentences() throws {
        let morning = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        let tally = WordTally(seed: [entry("the Overton release is ready", ai: "The Oberton release is ready.", app: "Mail", date: morning)])
        #expect(tally.days.count == 1)
        let day = try #require(tally.days.first)
        #expect(day.words["oberton"] == 1)
        #expect(day.corrections["overton" + WordTally.arrow + "Oberton"] == 1)
        #expect(day.hours[10] == 1)
        #expect(day.apps["Mail"]?.words["release"] == 1)
        #expect(day.profiles["Light Cleanup"]?.aiKept == 1)
        let json = String(decoding: try JSONEncoder().encode(tally), as: UTF8.self)
        #expect(!json.contains("the oberton release is ready") && !json.contains("release is ready."))
        #expect(try JSONDecoder().decode(WordTally.self, from: Data(json.utf8)) == tally)
    }

    @Test func seedingFromHistoryCountsOnceAndKeepsNoSentences() throws {
        let file = JSONFile<WordTally>(url: FileManager.default.temporaryDirectory.appending(path: "oberton-words-\(UUID().uuidString).json"))
        defer { try? FileManager.default.removeItem(at: file.url) }
        let morning = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        let history = [entry("the Overton release is ready", ai: "The Oberton release is ready.", date: morning)]
        let tally = WordTally.load(file, seed: history, enabled: true)
        let day = try #require(tally.days.first)
        #expect(tally.days.count == 1)
        #expect(day.words["oberton"] == 1)
        #expect(day.corrections["overton" + WordTally.arrow + "Oberton"] == 1)
        #expect(day.hours[10] == 1)
        #expect(!String(decoding: try Data(contentsOf: file.url), as: UTF8.self).contains("release is ready."))
        // Loads back; not seeded twice.
        let again = WordTally.load(file, seed: history + history, enabled: true)
        #expect(again.days.count == 1 && again.days[0].words["oberton"] == 1)
        // Off: no tally and no file.
        let off = JSONFile<WordTally>(url: file.url.appendingPathExtension("off"))
        #expect(WordTally.load(off, seed: history, enabled: false).days.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: off.url.path(percentEncoded: false)))
    }

    @Test func lowerCaseIsDotNetsInvariantOne() {
        // ToLowerInvariant maps each character alone and leaves İ as it is.
        #expect(WordTally.tokens("İstanbul ΣΟΦΙΑ") == ["İstanbul", "σοφια"])
        #expect(WordTally.correction(removed: ["İzmir"], added: ["Izmir"]) == "İzmir" + WordTally.arrow + "Izmir")
    }

    @Test func digitsOutsideTheBasicPlaneAreNotDigitsAsOnWindows() {
        // U+1D7CE MATHEMATICAL BOLD DIGIT ZERO, twice: four UTF-16 surrogates, none a digit to char.IsDigit.
        let item = WordTally.analyze(transcript: "x", aiOutput: nil, final: "\u{1D7CE}\u{1D7CE} 2026")
        #expect(item.words == ["\u{1D7CE}\u{1D7CE}"])
    }

    @Test func aWrittenWordOfThreeUTF16UnitsCarriesMeaning() {
        // Two letters outside the BMP are four UTF-16 units: long enough on Windows (w.Length >= 3).
        #expect(WordTally.correction(removed: ["ab"], added: ["\u{20000}\u{20001}"]) != nil)
    }

    @Test func profilesUsedEquallyOnOneDayKeepTheOrderTheyWereUsed() {
        var tally = WordTally()
        tally.record(entry("one two", profile: "Zebra"))
        tally.record(entry("one two", profile: "Alpha"))
        #expect(WordTally.byProfile(tally.days).map(\.profile) == ["Zebra", "Alpha"])
        let json = try! JSONEncoder().encode(tally)
        let back = try! JSONDecoder().decode(WordTally.self, from: json)
        #expect(WordTally.byProfile(back.days).map(\.profile) == ["Zebra", "Alpha"])
    }

    @Test func eachDictationIsCountedAgainOnTheSameDay() {
        var tally = WordTally()
        tally.record(entry("release notes", inserted: "Release notes.", profile: "Raw"))
        tally.record(entry("release notes", inserted: "Release notes.", profile: "Raw"))
        #expect(tally.days.count == 1)
        #expect(tally.days[0].words["release"] == 2)
        #expect(tally.days[0].profiles["Raw"]?.dictations == 2)
    }

    @Test func aRejectedEditCountsAsEditedButNotKeptAndTeachesNothing() {
        var tally = WordTally()
        // As Windows keeps it: no AI output, the safety net flag set.
        tally.record(entry("the Overton release", profile: "Formal", warning: "The safety net kept your words", safetyNet: true))
        #expect(tally.days[0].profiles["Formal"]?.aiEdited == 1)
        #expect(tally.days[0].profiles["Formal"]?.aiKept == 0)
        #expect(tally.days[0].corrections.isEmpty)
        // An entry from before the flag was kept: the AI gave back the words unchanged, with a warning.
        var old = entry("the Overton release", ai: "the Overton release", profile: "Formal", warning: "The safety net kept your words")
        old.safetyNet = nil
        tally.record(old)
        #expect(tally.days[0].profiles["Formal"]?.aiEdited == 2)
        #expect(tally.days[0].profiles["Formal"]?.aiKept == 0)
    }

    @Test func aPartlyRejectedEditStillTeachesItsCorrections() {
        // WordTally.cs analyzes AiOutput whenever there is one, also when the safety net kept part of it.
        var tally = WordTally()
        tally.record(entry("I opened Overton today", ai: "I opened Oberton today.", profile: "Formal",
                           warning: "The AI's edit of 1 of 2 parts failed the safety net; those parts were inserted unchanged.", safetyNet: true))
        #expect(tally.days[0].corrections == ["overton" + WordTally.arrow + "Oberton": 1])
        #expect(tally.days[0].profiles["Formal"]?.aiEdited == 1)
        #expect(tally.days[0].profiles["Formal"]?.aiKept == 0)
    }

    @Test func appsAreToldApartIgnoringCaseAndAnUnnamedAppIsCounted() {
        var tally = WordTally()
        tally.record(entry("release notes for the team", app: "Mail"))
        tally.record(entry("release notes for the board", app: "mail"))
        tally.record(entry("standup tomorrow morning"))
        #expect(tally.days[0].apps.count == 2)
        #expect(tally.days[0].apps["Mail"]?.dictations == 2)
        #expect(tally.days[0].apps["Unknown app"]?.dictations == 1)
        #expect(WordTally.forApp(tally.days, "MAIL").count == 1)
    }

    @Test func profilesWithTheSameUseKeepTheOrderTheyWereFirstMet() {
        let cal = Calendar.current, now = Date()
        var tally = WordTally()
        tally.record(entry("one two three", profile: "Zebra", date: cal.date(byAdding: .day, value: -2, to: now)!))
        tally.record(entry("one two three", profile: "Alpha", date: cal.date(byAdding: .day, value: -1, to: now)!))
        #expect(WordTally.byProfile(tally.days).map(\.profile) == ["Zebra", "Alpha"])
    }

    @Test func allDigitWordsAreLeftOutButOtherNumbersAreNot() {
        let item = WordTally.analyze(transcript: "", aiOutput: nil, final: "room 42 needs ½½ and x²")
        #expect(item.words.contains("room") && item.words.contains("½½") && !item.words.contains("42"))
    }

    @Test func oldDaysLoseTheirOneOffPhrasesAndVeryOldDaysGo() {
        let now = Date()
        var tally = WordTally()
        var old = TallyDay(day: UsageLog.key(Calendar.current.date(byAdding: .day, value: -500, to: now)!))
        old.words["gone"] = 1
        var yesterday = TallyDay(day: UsageLog.key(Calendar.current.date(byAdding: .day, value: -1, to: now)!))
        yesterday.phrases = ["said once only": 1, "said twice here": 2]
        tally.days = [old, yesterday]
        tally.compact(now: now)
        #expect(tally.days.count == 1)
        #expect(tally.days[0].phrases == ["said twice here": 2])
    }

    @Test func oneAppsWordsAreItsOwn() {
        var tally = WordTally()
        tally.record(entry("release notes for the team", app: "Mail"))
        tally.record(entry("standup tomorrow morning", app: "Slack"))
        let mail = WordTally.forApp(tally.days, "Mail")
        #expect(WordTally.top(mail, \.words, 10).map(\.key).sorted() == ["notes", "release", "team"])
    }

    @Test func vocabularyAddsOnceAndKeepsWhatWasThere() {
        #expect(Vocabulary.adding("Oberton", to: "") == "Oberton")
        #expect(Vocabulary.adding("Oberton", to: "Kubernetes, ") == "Kubernetes, Oberton")
        #expect(Vocabulary.adding("oberton", to: "Kubernetes, Oberton") == "Kubernetes, Oberton")
        #expect(!Vocabulary.contains("Obertonia", "Oberton"))
    }

    @Test func aWordAnywhereInTheHintCountsAsAdded() {
        // AnalyticsPage.InVocabulary: a whole-word match anywhere, ignoring case.
        #expect(Vocabulary.contains("Oberton Pro, Kubernetes", "oberton"))
        #expect(Vocabulary.contains("Kubernetes; Oberton.", "Oberton"))
        #expect(!Vocabulary.contains("Obertonia", "Oberton"))
        // Only the end loses its , and ; (hint.Trim().TrimEnd(',', ';')).
        #expect(Vocabulary.adding("Oberton", to: ", Kubernetes;,") == ", Kubernetes, Oberton")
    }
}

@Suite struct UsageLogTests {
    @Test func readingTimeIsSummedPerDay() {
        // AnalyticsTenTests: one reading, its time counted in three goes (the last of no time).
        var log = UsageLog()
        let now = Date()
        log.recordReading(words: 120, on: now)
        log.recordReadingTime(30, on: now)
        log.recordReadingTime(15.5, on: now)
        log.recordReadingTime(0, on: now)
        let d = log.days[UsageLog.key(now)]!
        #expect(d.readings == 1 && d.wordsRead == 120 && d.secondsRead == 45.5)
    }

    // WordsReadPerDayTests (MarkdownDocTests.cs)
    @Test func wordsReadAloudAreCountedPerDayNextToWordsDictated() {
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        var log = UsageLog()
        log.recordReading(words: 120, on: now)
        log.recordReading(words: 30, on: Calendar.current.date(byAdding: .day, value: -1, to: now)!)
        log.record(HistoryEntry(transcription: "one two three", aiEdit: nil, inserted: "one two three", profileName: "Raw", model: nil,
                                appName: nil, seconds: 1, turnaroundSeconds: 0, warning: nil))
        let days = log.perDay(7, until: now)
        #expect(days[days.count - 1].wordsRead == 120)
        #expect(days[days.count - 1].words == 3)
        #expect(days[days.count - 2].wordsRead == 30)
        #expect(days[days.count - 2].words == 0)
    }

    @Test func appsIgnoreCaseAnUnnamedAppIsCountedAndResetKeepsTheTurnarounds() {
        var log = UsageLog()
        let now = Date()
        log.recordDictation(words: 2, seconds: 1, turnaround: 1, usedAI: false, keptAI: false, app: "Slack", on: now)
        log.recordDictation(words: 3, seconds: 1, turnaround: 1, usedAI: false, keptAI: false, app: "slack", on: now)
        log.record(HistoryEntry(transcription: "one two", aiEdit: nil, inserted: "", profileName: "Raw", model: nil, appName: nil,
                                seconds: 1, turnaroundSeconds: 0, warning: nil))
        let d = log.days[UsageLog.key(now)]!
        #expect(d.apps == ["Slack": 2, "Unknown app": 1])
        // An empty insert counts the words heard (HistoryEntry.Words).
        #expect(log.totalWords == 7)
        log.recordTurnaround(TurnaroundSample(speechModel: "a", aiModel: "", seconds: 1, modelLoaded: false))
        log.clearDays()
        #expect(log.days.isEmpty && log.totalWords == 0 && log.samples.count == 1)
    }

    @Test func oldUsageFilesStillLoad() throws {
        let old = #"{"days":{"2026-10-01":{"dictations":2,"words":30,"secondsSpoken":12,"wordsRead":0,"secondsRead":0,"aiEdits":1,"aiKept":1,"apps":{"Mail":2}}},"turnarounds":[1.1],"totalWords":30}"#
        let log = try JSONDecoder().decode(UsageLog.self, from: Data(old.utf8))
        let d = try #require(log.days["2026-10-01"])
        #expect(d.words == 30)
        #expect(d.apps["Mail"] == 2)
        #expect(d.hours.count == 24)
        #expect(d.turnaroundCount == 0)
        #expect(d.readings == 0)
    }

    @Test func dictationsAreCountedByHourAndPeriod() {
        let now = Calendar.current.date(bySettingHour: 15, minute: 30, second: 0, of: Date())!
        var log = UsageLog()
        log.recordDictation(words: 10, seconds: 5, turnaround: 1.5, usedAI: true, keptAI: true, app: "Notes", on: now)
        log.recordDictation(words: 5, seconds: 2, turnaround: 0.5, usedAI: false, keptAI: false, app: nil,
                            on: Calendar.current.date(byAdding: .day, value: -10, to: now)!)
        log.recordReading(words: 40, seconds: 12, on: now)
        #expect(log.inPeriod(7, until: now).count == 1)
        #expect(log.inPeriod(30, until: now).count == 2)
        #expect(log.inPeriod(nil, until: now).count == 2)
        let today = log.days[UsageLog.key(now)]!
        #expect(today.hours[15] == 1)
        #expect(today.turnaroundCount == 1)
        #expect(today.readings == 1)
        let grid = UsageLog.weekHours(log.inPeriod(7, until: now))
        #expect(grid[UsageLog.weekdayRow(now)][15] == 1)
    }

    @Test func weekdayRowsStartOnMonday() {
        #expect(UsageLog.weekdayRow(UsageLog.date("2026-10-12")!) == 0) // a Monday
        #expect(UsageLog.weekdayRow(UsageLog.date("2026-10-18")!) == 6) // a Sunday
    }
}

extension BrokenFileTests {
    @Test func aUsageFileWithAValueThatWontReadFailsAsAWhole() throws {
        // Windows' strict read: kept as usage.json.bad, logged, and the counts seeded again from History.
        let url = FileManager.default.temporaryDirectory.appending(path: "oberton-usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("bad")) }
        try Data(#"{"version":2,"days":{"2026-10-01":{"dictations":"two"}},"samples":[]}"#.utf8).write(to: url)
        var lines: [String] = []
        CoreLog.sink = { level, message in lines.append(level + " " + message) }
        defer { CoreLog.sink = nil }
        #expect(JSONFile<UsageLog>(url: url).load() == nil)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bad").path(percentEncoded: false)))
        #expect(lines.contains { $0.contains("keeping a .bad copy") })
        // A missing key is fine: it keeps its default.
        #expect(try JSONDecoder().decode(UsageLog.self, from: Data(#"{"days":{"2026-10-01":{"words":3}}}"#.utf8)).days["2026-10-01"]?.words == 3)
    }
}
