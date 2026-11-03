import Foundation

/// One day's counts. Numbers only: never any text, audio or window titles (as Windows' data\usage.json).
public struct UsageDay: Codable, Sendable, Equatable {
    public var dictations = 0
    public var words = 0
    public var secondsSpoken = 0.0
    /// Sum and count of "stop pressed → text in place" times, for an average.
    public var turnaroundSeconds = 0.0
    public var turnaroundCount = 0
    /// Texts read aloud, their words, and how long the voice spoke.
    public var readings = 0
    public var wordsRead = 0
    public var secondsRead = 0.0
    /// Dictations a profile with AI edited, and how many of those kept the AI's edit (didn't fall back to the raw words).
    public var aiEdits = 0
    public var aiKept = 0
    /// Dictations per app name ("Unknown app" when there is none), names told apart ignoring case.
    public var apps: [String: Int] = [:]
    /// Dictations per hour of the day (0–23), for "when you dictate".
    public var hours = [Int](repeating: 0, count: 24)

    public init() {}

    // Files from older versions are missing newer keys: decode what is there, default the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func take<T: Decodable>(_ key: CodingKeys, _ into: inout T) { if let v = try? c.decode(T.self, forKey: key) { into = v } }
        take(.dictations, &dictations); take(.words, &words); take(.secondsSpoken, &secondsSpoken)
        take(.turnaroundSeconds, &turnaroundSeconds); take(.turnaroundCount, &turnaroundCount)
        take(.readings, &readings); take(.wordsRead, &wordsRead); take(.secondsRead, &secondsRead)
        take(.aiEdits, &aiEdits); take(.aiKept, &aiKept); take(.apps, &apps); take(.hours, &hours)
        hours = TallyDay.fit(hours)
    }
}

/// One dictation's turnaround (stop to text in place) and the models behind it (Windows' `TurnaroundSample`).
public struct TurnaroundSample: Codable, Sendable, Equatable {
    public var date: Date
    public var speechModel: String
    /// The AI model, or "" when the profile uses no AI.
    public var aiModel: String
    public var seconds: Double
    /// The speech model or the AI model wasn't loaded when the dictation started, so the time includes loading.
    public var modelLoaded: Bool

    public init(date: Date = Date(), speechModel: String, aiModel: String, seconds: Double, modelLoaded: Bool) {
        self.date = date
        self.speechModel = speechModel
        self.aiModel = aiModel
        self.seconds = seconds
        self.modelLoaded = modelLoaded
    }
}

/// Daily counts behind the dashboard meters and Analytics, so they survive History being trimmed, cleared or off.
public struct UsageLog: Codable, Sendable, Equatable {
    /// About two years; older days are dropped.
    public static let keepDays = 750
    /// How many recent turnarounds are kept.
    public static let keepTurnarounds = 100

    /// Keyed by local date, "yyyy-MM-dd".
    public var days: [String: UsageDay] = [:]
    /// The latest turnarounds with the models that produced them (no text), newest last.
    public var samples: [TurnaroundSample] = []
    /// Every word dictated, over the days kept (UsageStore.TotalWords: it drops as old days go).
    public var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }

    enum CodingKeys: String, CodingKey { case days, samples }

    public init() {}

    /// A new log counted from what History already has, so the dashboard doesn't start from zero (once, when there is
    /// no usage file yet).
    public init(seed history: [HistoryEntry]) {
        for e in history.sorted(by: { $0.date < $1.date }) { record(e) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = (try? c.decode([String: UsageDay].self, forKey: .days)) ?? [:]
        samples = (try? c.decode([TurnaroundSample].self, forKey: .samples)) ?? []
    }

    public static func key(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The local midnight a key names, or nil for a malformed key.
    public static func date(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// Monday = 0 … Sunday = 6.
    public static func weekdayRow(_ date: Date) -> Int { (Calendar.current.component(.weekday, from: date) + 5) % 7 }

    /// Count a finished dictation, as Windows counts it: the AI worked on it when it has an AI edit or the safety net
    /// stepped in, and kept its edit when nothing was rejected.
    public mutating func record(_ e: HistoryEntry) {
        let safetyNet = e.isSafetyNet, aiOutput = e.aiOutput
        recordDictation(words: e.words, seconds: e.seconds, turnaround: e.turnaroundSeconds, usedAI: aiOutput != nil || safetyNet,
                        keptAI: aiOutput != nil && !safetyNet, app: e.appLabel, on: e.date)
    }

    /// Remember how long a dictation took from stop to text in place, and with which models.
    public mutating func recordTurnaround(_ sample: TurnaroundSample) {
        samples.append(sample)
        if samples.count > Self.keepTurnarounds { samples.removeFirst(samples.count - Self.keepTurnarounds) }
    }

    public mutating func recordDictation(words: Int, seconds: Double, turnaround: Double, usedAI: Bool, keptAI: Bool, app: String?, on date: Date = Date()) {
        var d = days[Self.key(date)] ?? UsageDay()
        d.dictations += 1
        d.words += words
        d.secondsSpoken += seconds
        if turnaround > 0 { d.turnaroundSeconds += turnaround; d.turnaroundCount += 1 }
        if usedAI { d.aiEdits += 1; if keptAI { d.aiKept += 1 } }
        if let app {
            // One app however its name is written ("Slack" and "slack"): counted under the spelling seen first.
            let key = d.apps.keys.first { $0.caseInsensitiveCompare(app) == .orderedSame } ?? app
            d.apps[key, default: 0] += 1
        }
        d.hours[min(max(Calendar.current.component(.hour, from: date), 0), 23)] += 1
        days[Self.key(date)] = d
        prune()
    }

    /// Drop the days older than `keepDays`.
    public mutating func prune(now: Date = Date()) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.keepDays, to: now).map(Self.key) else { return }
        days = days.filter { $0.key >= cutoff }
    }

    /// Days in a row, up to today (or yesterday, if nothing yet today), with at least one dictation.
    public func streak(today: Date = Date()) -> Int {
        let cal = Calendar.current
        var day = today
        if (days[Self.key(day)]?.dictations ?? 0) == 0 { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while (days[Self.key(day)]?.dictations ?? 0) > 0 {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return n
    }

    public mutating func recordReading(words: Int, seconds: Double, on date: Date = Date()) {
        recordReading(words: words, on: date)
        recordReadingTime(seconds, on: date)
    }

    /// Count a text read aloud, when it starts (UsageStore.RecordReading).
    public mutating func recordReading(words: Int, on date: Date = Date()) {
        var d = days[Self.key(date)] ?? UsageDay()
        d.readings += 1
        d.wordsRead += words
        days[Self.key(date)] = d
        prune()
    }

    /// Count how long a reading's voice spoke, when it ends (UsageStore.RecordReadingTime); nothing for no time.
    public mutating func recordReadingTime(_ seconds: Double, on date: Date = Date()) {
        guard seconds > 0 else { return }
        var d = days[Self.key(date)] ?? UsageDay()
        d.secondsRead += seconds
        days[Self.key(date)] = d
        prune()
    }

    /// Forget every daily count (Settings › History); the turnaround samples stay (UsageStore.Clear).
    public mutating func clearDays() { days = [:] }

    /// The last `count` days, oldest first, today last (days with nothing are empty).
    public func perDay(_ count: Int, until now: Date = Date()) -> [UsageDay] {
        (0..<count).reversed().map { back in
            days[Self.key(Calendar.current.date(byAdding: .day, value: -back, to: now)!)] ?? UsageDay()
        }
    }

    /// The days with counts in the last `count` days up to `now` (every day up to `now` when nil), oldest first.
    public func inPeriod(_ count: Int?, until now: Date = Date()) -> [(key: String, day: UsageDay)] {
        let last = Self.key(now)
        let first = count.map { Self.key(Calendar.current.date(byAdding: .day, value: 1 - $0, to: now)!) } ?? ""
        return days.filter { $0.key >= first && $0.key <= last }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Dictations by weekday (Monday first) and hour over these days: seven rows of 24.
    public static func weekHours(_ days: [(key: String, day: UsageDay)]) -> [[Int]] {
        var grid = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 7)
        for (key, d) in days {
            guard let date = date(key) else { continue }
            let row = weekdayRow(date)
            for h in 0..<min(24, d.hours.count) { grid[row][h] += d.hours[h] }
        }
        return grid
    }

    /// The average of the last `count` turnarounds with this speech model and AI model ("" = no AI) where neither model
    /// had to load first; nil when there are none yet. Also how many it averaged.
    public func recentTurnaround(speechModel: String, aiModel: String, count: Int = 3) -> (seconds: Double?, count: Int) {
        let picked = samples.filter {
            !$0.modelLoaded && $0.seconds > 0 && $0.speechModel.caseInsensitiveCompare(speechModel) == .orderedSame
                && $0.aiModel.caseInsensitiveCompare(aiModel) == .orderedSame
        }.suffix(count)
        return (picked.isEmpty ? nil : picked.reduce(0) { $0 + $1.seconds } / Double(picked.count), picked.count)
    }
}
