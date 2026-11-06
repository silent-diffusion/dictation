import Foundation

/// One day's counts. Numbers only: never any text, audio or window titles (of a browser's tab, only the site's name), as
/// Windows' data\usage.json.
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
    /// For browsers: dictations per site, by browser ("Google Chrome" → "Gmail" → 3). Only the site's name (`WebSites`),
    /// never the tab's title. Browsers and sites told apart ignoring case, as apps.
    public var sites: [String: [String: Int]] = [:]
    /// Dictations per hour of the day (0–23), for "when you dictate".
    public var hours = [Int](repeating: 0, count: 24)

    public init() {}

    // Files from older versions are missing newer keys: those keep their defaults. A value that is there but won't read,
    // null included, fails the whole file, as Windows' strict read does (kept as usage.json.bad, the counts seeded again
    // from History).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func take<T: Decodable>(_ key: CodingKeys, _ into: inout T) throws { if let v = try c.strict(T.self, key) { into = v } }
        try take(.dictations, &dictations); try take(.words, &words); try take(.secondsSpoken, &secondsSpoken)
        try take(.turnaroundSeconds, &turnaroundSeconds); try take(.turnaroundCount, &turnaroundCount)
        try take(.readings, &readings); try take(.wordsRead, &wordsRead); try take(.secondsRead, &secondsRead)
        try take(.aiEdits, &aiEdits); try take(.aiKept, &aiKept); try take(.apps, &apps); try take(.sites, &sites); try take(.hours, &hours)
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

    /// As System.Text.Json reads Windows' TurnaroundSample: a missing key keeps the member's default (DateTime's
    /// 0001-01-01, "", 0, false); a null time, number or flag fails the file; a null model name is taken (as "").
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.strict(Date.self, .date) ?? Self.minDate
        speechModel = try c.decodeIfPresent(String.self, forKey: .speechModel) ?? ""
        aiModel = try c.decodeIfPresent(String.self, forKey: .aiModel) ?? ""
        seconds = try c.strict(Double.self, .seconds) ?? 0
        modelLoaded = try c.strict(Bool.self, .modelLoaded) ?? false
    }

    /// .NET's default(DateTime): 0001-01-01 00:00 of the proleptic Gregorian calendar (62,135,596,800 s before 1970).
    static let minDate = Date(timeIntervalSince1970: -62_135_596_800)
}

extension KeyedDecodingContainer {
    /// A value as System.Text.Json reads it into a .NET number, flag, date or list: nil when the key is missing (the
    /// default stays), an error when it is null or won't read.
    func strict<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) {
            throw DecodingError.valueNotFound(T.self, .init(codingPath: codingPath + [key], debugDescription: "null where a value is needed"))
        }
        return try decode(T.self, forKey: key)
    }
}

/// Daily counts behind the dashboard meters and Analytics, so they survive History being trimmed, cleared or off.
public struct UsageLog: Codable, Sendable, Equatable {
    /// About two years; older days are dropped.
    public static let keepDays = 750
    /// How many recent turnarounds are kept.
    public static let keepTurnarounds = 100

    /// 2: days have `UsageDay.sites` (filled in from History for older days when first loaded, `fillSites`). A new
    /// log starts at 2; a file without one is 1.
    public var version = 2
    /// Keyed by local date, "yyyy-MM-dd".
    public var days: [String: UsageDay] = [:]
    /// The latest turnarounds with the models that produced them (no text), newest last.
    public var samples: [TurnaroundSample] = []
    /// Every word dictated, over the days kept (UsageStore.TotalWords: it drops as old days go).
    public var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }

    enum CodingKeys: String, CodingKey { case version, days, samples }

    public init() {}

    /// A new log counted from what History already has, so the dashboard doesn't start from zero (once, when there is
    /// no usage file yet).
    public init(seed history: [HistoryEntry]) {
        for e in history.sorted(by: { $0.date < $1.date }) { record(e) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Strict, as Windows: a value that won't read fails the file (`JSONFile.load` keeps it as .bad and logs it), and
        // the counts are seeded again from History rather than silently starting from nothing.
        // A null fails too: System.Text.Json refuses it for the version (an int), and a null list of days or samples
        // would leave Windows' store without one.
        version = try c.strict(Int.self, .version) ?? 1
        days = try c.strict([String: UsageDay].self, .days) ?? [:]
        samples = try c.strict([TurnaroundSample].self, .samples) ?? []
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
                        keptAI: aiOutput != nil && !safetyNet, app: e.appLabel, site: e.site, on: e.date)
    }

    /// Sites are new (version 1): fill them in for the dictations History still has (it keeps their window titles);
    /// older ones stay counted under the browser alone. Once (UsageStore's version 2 step); true when it ran.
    @discardableResult
    public mutating func fillSites(from history: [HistoryEntry]) -> Bool {
        guard version < 2 else { return false }
        for e in history {
            guard let site = e.site, var d = days[Self.key(e.date)] else { continue }
            Self.count(site, in: e.appLabel, on: &d)
            days[Self.key(e.date)] = d
        }
        version = 2
        return true
    }

    /// A browser's sites over these days, most dictated first, then by name (UsageStore.SitesOf).
    public static func sitesOf(_ days: [UsageDay], _ app: String) -> [(site: String, count: Int)] {
        var sums: [(site: String, count: Int)] = []
        for d in days {
            guard let sites = d.sites.first(where: { $0.key.caseInsensitiveCompare(app) == .orderedSame })?.value else { continue }
            for (s, n) in sites.sorted(by: { $0.key < $1.key }) {
                if let i = sums.firstIndex(where: { $0.site.caseInsensitiveCompare(s) == .orderedSame }) { sums[i].count += n } else { sums.append((s, n)) }
            }
        }
        return sums.sorted { $0.count != $1.count ? $0.count > $1.count : $0.site.compare($1.site, locale: .current) == .orderedAscending }
    }

    /// A dictation into a browser: which site, by its name only, under the browser's spelling seen first.
    private static func count(_ site: String, in app: String, on d: inout UsageDay) {
        let browser = d.sites.keys.first { $0.caseInsensitiveCompare(app) == .orderedSame } ?? app
        var sites = d.sites[browser] ?? [:]
        let key = sites.keys.first { $0.caseInsensitiveCompare(site) == .orderedSame } ?? site
        sites[key, default: 0] += 1
        d.sites[browser] = sites
    }

    /// Remember how long a dictation took from stop to text in place, and with which models.
    public mutating func recordTurnaround(_ sample: TurnaroundSample) {
        samples.append(sample)
        if samples.count > Self.keepTurnarounds { samples.removeFirst(samples.count - Self.keepTurnarounds) }
    }

    public mutating func recordDictation(words: Int, seconds: Double, turnaround: Double, usedAI: Bool, keptAI: Bool, app: String?,
                                         site: String? = nil, on date: Date = Date()) {
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
            if let site { Self.count(site, in: app, on: &d) }
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
