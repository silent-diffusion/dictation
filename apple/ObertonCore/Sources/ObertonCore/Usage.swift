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
    /// Dictations per app name.
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

/// Daily counts behind the dashboard meters and Analytics, so they survive History being trimmed, cleared or off.
public struct UsageLog: Codable, Sendable, Equatable {
    /// Keyed by local date, "yyyy-MM-dd".
    public var days: [String: UsageDay] = [:]
    /// The last few turnarounds (stop → text in place), newest last.
    public var turnarounds: [Double] = []
    public var totalWords = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = (try? c.decode([String: UsageDay].self, forKey: .days)) ?? [:]
        turnarounds = (try? c.decode([Double].self, forKey: .turnarounds)) ?? []
        totalWords = (try? c.decode(Int.self, forKey: .totalWords)) ?? 0
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

    public mutating func recordDictation(words: Int, seconds: Double, turnaround: Double, usedAI: Bool, keptAI: Bool, app: String?, on date: Date = Date()) {
        var d = days[Self.key(date)] ?? UsageDay()
        d.dictations += 1
        d.words += words
        d.secondsSpoken += seconds
        if turnaround > 0 { d.turnaroundSeconds += turnaround; d.turnaroundCount += 1 }
        if usedAI { d.aiEdits += 1; if keptAI { d.aiKept += 1 } }
        if let app { d.apps[app, default: 0] += 1 }
        d.hours[min(max(Calendar.current.component(.hour, from: date), 0), 23)] += 1
        days[Self.key(date)] = d
        totalWords += words
        turnarounds.append(turnaround)
        if turnarounds.count > 20 { turnarounds.removeFirst(turnarounds.count - 20) }
    }

    public mutating func recordReading(words: Int, seconds: Double, on date: Date = Date()) {
        var d = days[Self.key(date)] ?? UsageDay()
        d.readings += 1
        d.wordsRead += words
        d.secondsRead += seconds
        days[Self.key(date)] = d
    }

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

    /// The average of the last three turnarounds, or nil before the first dictation.
    public var recentTurnaround: Double? {
        let last = turnarounds.suffix(3)
        return last.isEmpty ? nil : last.reduce(0, +) / Double(last.count)
    }
}
