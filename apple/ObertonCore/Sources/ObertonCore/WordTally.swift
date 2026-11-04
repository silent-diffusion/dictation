import Foundation

/// How one profile was used on a day and how much it edited.
public struct ProfileTally: Codable, Sendable, Equatable {
    public var dictations = 0
    /// Dictations the AI worked on, and how many kept its edit (not rejected by the safety net).
    public var aiEdited = 0
    public var aiKept = 0
    /// Words heard, and how many of them the AI changed (removed or replaced) or added.
    public var wordsHeard = 0
    public var wordsChanged = 0
    public var turnaroundSeconds = 0.0
    public var turnaroundCount = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dictations = (try? c.decode(Int.self, forKey: .dictations)) ?? 0
        aiEdited = (try? c.decode(Int.self, forKey: .aiEdited)) ?? 0
        aiKept = (try? c.decode(Int.self, forKey: .aiKept)) ?? 0
        wordsHeard = (try? c.decode(Int.self, forKey: .wordsHeard)) ?? 0
        wordsChanged = (try? c.decode(Int.self, forKey: .wordsChanged)) ?? 0
        turnaroundSeconds = (try? c.decode(Double.self, forKey: .turnaroundSeconds)) ?? 0
        turnaroundCount = (try? c.decode(Int.self, forKey: .turnaroundCount)) ?? 0
    }
}

/// One app's (or site's) share of a day of the word tally.
public struct TallyPart: Codable, Sendable, Equatable {
    public var dictations = 0
    public var words: [String: Int] = [:]
    public var phrases: [String: Int] = [:]
    public var corrections: [String: Int] = [:]
    public var fillers: [String: Int] = [:]
    public var hours = [Int](repeating: 0, count: 24)

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dictations = (try? c.decode(Int.self, forKey: .dictations)) ?? 0
        words = (try? c.decode([String: Int].self, forKey: .words)) ?? [:]
        phrases = (try? c.decode([String: Int].self, forKey: .phrases)) ?? [:]
        corrections = (try? c.decode([String: Int].self, forKey: .corrections)) ?? [:]
        fillers = (try? c.decode([String: Int].self, forKey: .fillers)) ?? [:]
        hours = TallyDay.fit((try? c.decode([Int].self, forKey: .hours)) ?? [])
    }
}

/// One day of the word tally: counts only, never sentences.
public struct TallyDay: Codable, Sendable, Equatable {
    /// The local date, "yyyy-MM-dd" (`UsageLog.key`).
    public var day: String
    /// Words that went in (common words left out), lower case.
    public var words: [String: Int] = [:]
    /// Three- and four-word phrases that went in, lower case.
    public var phrases: [String: Int] = [:]
    /// "heard → written" pairs: what the recognizer heard and what the AI wrote instead.
    public var corrections: [String: Int] = [:]
    /// Filler words the AI took out (um, uh, like…).
    public var fillers: [String: Int] = [:]
    /// Dictations per hour of the day (0–23).
    public var hours = [Int](repeating: 0, count: 24)
    /// Per profile name: how it was used and how much it edited.
    public var profiles: [String: ProfileTally] = [:]
    /// The same counts per app ("Mail") and per browser site ("Safari › Gmail", see `WordTally.appKey`), so Analytics
    /// can show one app's (or site's) words.
    public var apps: [String: TallyPart] = [:]
    /// The profiles in the order they were first used that day (Windows' Profiles dictionary keeps that order, also in
    /// words.json), so equally used ones are listed the same way; empty in days from before it was kept.
    public var profileOrder: [String] = []

    public init(day: String) { self.day = day }

    /// The day's profiles in the order they were first used (days from before that was kept: by name, after the rest).
    public var profilesInOrder: [(name: String, tally: ProfileTally)] {
        let known = profileOrder.filter { profiles[$0] != nil }
        let rest = profiles.keys.filter { !known.contains($0) }.sorted(by: WordTally.before)
        return (known + rest).map { ($0, profiles[$0]!) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        words = (try? c.decode([String: Int].self, forKey: .words)) ?? [:]
        phrases = (try? c.decode([String: Int].self, forKey: .phrases)) ?? [:]
        corrections = (try? c.decode([String: Int].self, forKey: .corrections)) ?? [:]
        fillers = (try? c.decode([String: Int].self, forKey: .fillers)) ?? [:]
        hours = Self.fit((try? c.decode([Int].self, forKey: .hours)) ?? [])
        profiles = (try? c.decode([String: ProfileTally].self, forKey: .profiles)) ?? [:]
        apps = (try? c.decode([String: TallyPart].self, forKey: .apps)) ?? [:]
        profileOrder = (try? c.decode([String].self, forKey: .profileOrder)) ?? []
    }

    /// The day as a date (local midnight).
    public var date: Date { UsageLog.date(day) ?? .distantPast }

    static func fit(_ hours: [Int]) -> [Int] {
        hours.count == 24 ? hours : Array((hours + [Int](repeating: 0, count: 24)).prefix(24))
    }
}

/// What one dictation adds to the tally; worked out without touching any store, so it can be tested.
public struct TallyItem: Sendable, Equatable {
    public var words: [String]
    public var phrases: [String]
    public var corrections: [String]
    public var fillers: [String]
    public var wordsHeard: Int
    public var wordsChanged: Int
}

/// The Analytics word tally, in words.json (WordTally.cs): per day, the words and phrases you dictate, the words the AI
/// corrects, the fillers it removes, when you dictate and how each profile edits. Counts only: no sentence is ever kept,
/// so a dictation can't be pieced back together from it. On by default (Settings › History); updated after every
/// dictation; seeded once from History so it doesn't start empty.
public struct WordTally: Codable, Sendable, Equatable {
    /// About thirteen months; older days are dropped.
    public static let keepDays = 400
    public static let arrow = " → "

    public var version = 1
    /// Oldest first.
    public var days: [TallyDay] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        days = (try? c.decode([TallyDay].self, forKey: .days)) ?? []
    }

    /// A tally seeded from the dictations already in History.
    public init(seed: [HistoryEntry], now: Date = Date()) {
        for e in seed.sorted(by: { $0.date < $1.date }) { count(e) }
        compact(now: now)
    }

    /// words.json as the app starts with it (WordTally's constructor): what the file holds, or, when there is none yet
    /// (or it can't be read, then kept as words.json.bad), a tally seeded once from the dictations in History, if the
    /// tally is on. `persist` false (snapshots) leaves the file alone.
    public static func load(_ file: JSONFile<WordTally>, seed history: [HistoryEntry], enabled: Bool, persist: Bool = true,
                            now: Date = Date()) -> WordTally {
        if let loaded = file.load() { return loaded }
        guard enabled else { return WordTally() }
        let seeded = WordTally(seed: history, now: now)
        if persist { seeded.save(to: file) }
        return seeded
    }

    /// Write the tally to its file (as `JSONFile.save`), logging a failure as Windows does.
    public func save(to file: JSONFile<WordTally>) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        do { try enc.encode(self).write(to: file.url, options: .atomic) } catch {
            CoreLog.warn("Saving the word tally failed: " + error.localizedDescription)
        }
    }

    /// Count a finished dictation.
    public mutating func record(_ e: HistoryEntry, now: Date = Date()) {
        count(e)
        compact(now: now)
    }

    /// The days from `from` on (all of them when nil), oldest first.
    public func days(from: Date?) -> [TallyDay] {
        guard let from else { return days }
        let key = UsageLog.key(from)
        return days.filter { $0.day >= key }
    }

    /// The key a dictation's app (and, in a browser, its site) is counted under: "Mail", "Safari › Gmail"
    /// (WordTally.AppKey). The app is its name, or "Unknown app".
    public static func appKey(_ app: String, _ site: String? = nil) -> String { site.map { app + " › " + $0 } ?? app }

    /// The tally of one app or site (`appKey`), as days of its own (without profiles), so the figures work on it as on
    /// the whole. Keys are told apart ignoring case.
    public static func forApp(_ days: [TallyDay], _ app: String) -> [TallyDay] {
        days.compactMap { d in
            guard let p = d.apps[app] ?? d.apps.first(where: { $0.key.caseInsensitiveCompare(app) == .orderedSame })?.value else { return nil }
            var t = TallyDay(day: d.day)
            t.words = p.words; t.phrases = p.phrases; t.corrections = p.corrections; t.fillers = p.fillers; t.hours = p.hours
            return t
        }
    }

    private mutating func count(_ e: HistoryEntry) {
        // As Windows: the AI's output is what is analyzed, also when the safety net kept part of it; the AI worked on a
        // dictation when it has an output or the safety net stepped in, and its edit was kept when it has one and the
        // safety net didn't.
        let safetyNet = e.isSafetyNet, aiOutput = e.aiOutput
        let item = Self.analyze(transcript: e.transcription, aiOutput: aiOutput, final: e.inserted)
        let key = UsageLog.key(e.date)
        let hour = min(max(Calendar.current.component(.hour, from: e.date), 0), 23)
        var d = days.first { $0.day == key } ?? TallyDay(day: key)
        for w in item.words { d.words[w, default: 0] += 1 }
        for p in item.phrases { d.phrases[p, default: 0] += 1 }
        for c in item.corrections { d.corrections[c, default: 0] += 1 }
        for f in item.fillers { d.fillers[f, default: 0] += 1 }
        d.hours[hour] += 1

        let name = e.profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown profile" : e.profileName
        if d.profiles[name] == nil { d.profileOrder.append(name) }
        var p = d.profiles[name] ?? ProfileTally()
        p.dictations += 1
        if aiOutput != nil || safetyNet {
            p.aiEdited += 1
            if aiOutput != nil && !safetyNet { p.aiKept += 1 }
        }
        p.wordsHeard += item.wordsHeard
        p.wordsChanged += item.wordsChanged
        if e.turnaroundSeconds > 0 { p.turnaroundSeconds += e.turnaroundSeconds; p.turnaroundCount += 1 }
        d.profiles[name] = p

        // The dictation's words again, under its app, and under its site when it went into a browser.
        for k in [Self.appKey(e.appLabel)] + (e.site.map { [Self.appKey(e.appLabel, $0)] } ?? []) {
            let app = d.apps.keys.first { $0.caseInsensitiveCompare(k) == .orderedSame } ?? k
            var a = d.apps[app] ?? TallyPart()
            a.dictations += 1
            for w in item.words { a.words[w, default: 0] += 1 }
            for x in item.phrases { a.phrases[x, default: 0] += 1 }
            for c in item.corrections { a.corrections[c, default: 0] += 1 }
            for f in item.fillers { a.fillers[f, default: 0] += 1 }
            a.hours[hour] += 1
            d.apps[app] = a
        }

        if let i = days.firstIndex(where: { $0.day == key }) { days[i] = d } else {
            days.append(d)
            days.sort { $0.day < $1.day }
        }
    }

    /// Keep the file small: drop old days, and from days before today the phrases said only once (most three-word runs
    /// never repeat, and only repeats are worth showing).
    mutating func compact(now: Date) {
        let cutoff = UsageLog.key(Calendar.current.date(byAdding: .day, value: -Self.keepDays, to: now)!)
        let today = UsageLog.key(now)
        days.removeAll { $0.day < cutoff }
        for i in days.indices where days[i].day < today {
            days[i].phrases = days[i].phrases.filter { $0.value >= 2 }
            for k in days[i].apps.keys { days[i].apps[k]!.phrases = days[i].apps[k]!.phrases.filter { $0.value >= 2 } }
        }
    }

    // MARK: Working out what a dictation adds

    /// Common words that would crowd every list; left out of "most used words".
    static let commonWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "nor", "so", "yet", "for", "if", "then", "than", "that", "this", "these",
        "those", "which", "who", "whom", "whose", "what", "when", "where", "why", "how", "as", "at", "by", "from", "in",
        "into", "of", "on", "onto", "to", "with", "without", "about", "after", "before", "over", "under", "up", "down",
        "out", "off", "through", "it", "its", "it's", "i", "i'm", "i've", "i'll", "i'd", "me", "my", "we", "we're",
        "our", "us", "you", "you're", "your", "he", "she", "him", "her", "his", "they", "them", "their", "there",
        "here", "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "don't", "doesn't",
        "didn't", "have", "has", "had", "will", "would", "can", "could", "should", "shall", "may", "might", "must",
        "not", "no", "yes", "also", "just", "very", "too", "all", "any", "some", "each", "every", "both", "more",
        "most", "much", "many", "other", "such", "only", "even", "still", "again", "now", "well", "okay", "ok",
        "like", "really", "get", "got", "go", "going", "let", "let's", "that's", "there's", "what's", "can't",
        "won't", "isn't", "aren't", "wasn't", "one", "two", "because", "while", "though", "per", "via",
    ]

    /// Words the AI removes as fillers; counted when they disappear in its edit.
    static let fillerWords: Set<String> = [
        "um", "umm", "uh", "uhh", "er", "erm", "ah", "eh", "hmm", "mm", "like", "basically", "literally", "actually",
        "so", "okay", "well",
    ]

    private static let wordRx = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}]+)*")
    private static let sentenceRx = try! NSRegularExpression(pattern: "(?<=[.!?;:])\\s+|\\n")

    /// The words of a text, lower case, apostrophes straightened, punctuation dropped.
    static func tokens(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        let ns = text as NSString
        return wordRx.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            lowerInvariant(ns.substring(with: $0.range).replacingOccurrences(of: "’", with: "'"))
        }
    }

    /// .NET's ToLowerInvariant: each character on its own (simple case mapping, never changing the length), and İ
    /// (U+0130) left as it is, as .NET's invariant casing does; Swift's `lowercased()` would make it "i̇".
    static func lowerInvariant(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let lower = u.properties.lowercaseMapping.unicodeScalars
            if u.value == 0x130 || lower.count != 1 { out.append(u) } else { out.append(lower.first!) }
        }
        return String(out)
    }

    /// .NET's `t.All(char.IsDigit)`: every UTF-16 unit a decimal digit (a digit outside the BMP is two surrogates there,
    /// which aren't digits).
    static func allDigits(_ s: String) -> Bool {
        s.utf16.allSatisfy { Unicode.Scalar($0)?.properties.generalCategory == .decimalNumber }
    }

    static func sentences(_ text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = [], start = 0
        for m in sentenceRx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + m.range.length
        }
        out.append(ns.substring(from: start))
        return out
    }

    /// What one dictation adds: its words and phrases (from the text that went in), and from the AI's edit of what was
    /// heard, the corrections and the fillers taken out.
    public static func analyze(transcript: String, aiOutput: String?, final: String) -> TallyItem {
        let text = final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? transcript : final
        // .NET: at least two UTF-16 units, and not all decimal digits (char.IsDigit).
        let words = tokens(text).filter {
            $0.utf16.count >= 2 && !commonWords.contains($0) && !allDigits($0)
        }

        var phrases: [String] = []
        for sentence in sentences(text) {
            let s = tokens(sentence)
            for n in 3...4 where s.count >= n {
                for i in 0...(s.count - n) {
                    let run = s[i..<(i + n)]
                    // At least one word that carries meaning: "and it was" isn't a phrase anyone reaches for.
                    if run.allSatisfy(commonWords.contains) { continue }
                    phrases.append(run.joined(separator: " "))
                }
            }
        }

        let heard = tokens(transcript).count
        var corrections: [String] = [], fillers: [String] = [], changed = 0
        if let aiOutput, !aiOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let diff = WordDiff.compute(transcript, aiOutput)
            var i = 0
            while i < diff.count {
                if diff[i].kind == .same { i += 1; continue }
                var removed: [String] = [], added: [String] = []
                while i < diff.count && diff[i].kind != .same {
                    if diff[i].kind == .removed { removed.append(diff[i].word) } else { added.append(diff[i].word) }
                    i += 1
                }
                changed += max(removed.count, added.count)
                let removedWords = removed.flatMap { tokens($0) }
                fillers += removedWords.filter(fillerWords.contains)
                if removedWords.count > 1 {
                    for k in 0..<(removedWords.count - 1) where removedWords[k] == "you" && removedWords[k + 1] == "know" { fillers.append("you know") }
                }
                if let pair = correction(removed: removed, added: added) { corrections.append(pair) }
            }
        }
        return TallyItem(words: words, phrases: phrases, corrections: corrections, fillers: fillers, wordsHeard: heard, wordsChanged: changed)
    }

    /// "heard → written" when a short run of heard words was replaced by a short run of other words that carry meaning
    /// (a name, a product, a term); nil for grammar fixes, fillers and punctuation.
    static func correction(removed: [String], added: [String]) -> String? {
        guard (1...3).contains(removed.count), (1...3).contains(added.count) else { return nil }
        let heard = clean(removed.joined(separator: " ")), written = clean(added.joined(separator: " "))
        guard !heard.isEmpty, !written.isEmpty else { return nil }
        let heardWords = tokens(heard), writtenWords = tokens(written)
        if heardWords.allSatisfy(fillerWords.contains) { return nil }
        guard writtenWords.contains(where: { $0.utf16.count >= 3 && !commonWords.contains($0) }) else { return nil }
        // Only capitals or punctuation changed: not a correction anyone needs to teach.
        if heardWords == writtenWords { return nil }
        return lowerInvariant(heard) + arrow + written
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'“”‘’()…-—"))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Figures for the Analytics page

    public static func top(_ days: [TallyDay], _ pick: (TallyDay) -> [String: Int], _ count: Int) -> [(key: String, count: Int)] {
        var sum: [String: Int] = [:]
        for d in days { for (k, v) in pick(d) { sum[k, default: 0] += v } }
        return sum.sorted { $0.value != $1.value ? $0.value > $1.value : before($0.key, $1.key) }.prefix(count).map { ($0.key, $0.value) }
    }

    /// .NET's default string order (culture-aware, as `ThenBy(key)` sorts), with a plain order for ties.
    static func before(_ a: String, _ b: String) -> Bool {
        switch a.compare(b, locale: .current) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a < b
        }
    }

    /// The most repeated phrases, without one that is only part of a longer phrase shown above it ("go ahead" under
    /// "go ahead and").
    public static func topPhrases(_ days: [TallyDay], _ count: Int) -> [(phrase: String, count: Int)] {
        var picked: [(phrase: String, count: Int)] = []
        for (p, n) in top(days, \.phrases, count * 6) {
            if n < 2 { break }
            if picked.contains(where: { (" " + $0.phrase + " ").contains(" " + p + " ") || (" " + p + " ").contains(" " + $0.phrase + " ") }) { continue }
            picked.append((p, n))
            if picked.count == count { break }
        }
        return picked
    }

    /// Dictations by weekday (Monday first) and hour: seven rows of 24.
    public static func weekHours(_ days: [TallyDay]) -> [[Int]] {
        var grid = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 7)
        for d in days {
            let row = UsageLog.weekdayRow(d.date)
            for h in 0..<min(24, d.hours.count) { grid[row][h] += d.hours[h] }
        }
        return grid
    }

    /// Profiles summed over the days, busiest first; equal ones in the order they were first met (Windows' stable
    /// sort), oldest day first and in the order they were first used within a day.
    public static func byProfile(_ days: [TallyDay]) -> [(profile: String, total: ProfileTally)] {
        var sum: [String: ProfileTally] = [:]
        var order: [String] = []
        for d in days {
            for (name, p) in d.profilesInOrder {
                if sum[name] == nil { order.append(name) }
                var t = sum[name] ?? ProfileTally()
                t.dictations += p.dictations; t.aiEdited += p.aiEdited; t.aiKept += p.aiKept
                t.wordsHeard += p.wordsHeard; t.wordsChanged += p.wordsChanged
                t.turnaroundSeconds += p.turnaroundSeconds; t.turnaroundCount += p.turnaroundCount
                sum[name] = t
            }
        }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return sum.sorted { $0.value.dictations != $1.value.dictations ? $0.value.dictations > $1.value.dictations : rank[$0.key]! < rank[$1.key]! }
            .map { ($0.key, $0.value) }
    }
}

/// The speech vocabulary is the recognizer's hint (Settings › Speech recognition): a comma-separated list of words it
/// should expect, read at the start of every dictation, so an addition works right away.
public enum Vocabulary {
    /// The word anywhere in the hint, as a whole word, ignoring case (AnalyticsPage.InVocabulary): "Oberton" is in
    /// "Oberton Pro, Kubernetes".
    public static func contains(_ hint: String, _ word: String) -> Bool {
        let pattern = "(^|[\\s,;])" + NSRegularExpression.escapedPattern(for: word) + "($|[\\s,;.])"
        guard let rx = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        return rx.firstMatch(in: hint, range: NSRange(location: 0, length: (hint as NSString).length)) != nil
    }

    /// The hint with the word appended ("Kubernetes, Oberton"); unchanged when it is already there. The hint is trimmed,
    /// then any , or ; at its end (`hint.Trim().TrimEnd(',', ';')`).
    public static func adding(_ word: String, to hint: String) -> String {
        if contains(hint, word) { return hint }
        var h = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = h.last, last == "," || last == ";" { h.removeLast() }
        return h.isEmpty ? word : h + ", " + word
    }
}
