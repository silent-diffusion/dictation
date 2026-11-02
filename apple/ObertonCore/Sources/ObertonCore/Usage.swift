import Foundation

/// One day's counts. Numbers only: never any text, audio or window titles (as Windows' data\usage.json).
public struct UsageDay: Codable, Sendable, Equatable {
    public var dictations = 0
    public var words = 0
    public var secondsSpoken = 0.0
    public var wordsRead = 0
    public var secondsRead = 0.0
    /// Dictations a profile with AI edited, and how many of those kept the AI's edit (didn't fall back to the raw words).
    public var aiEdits = 0
    public var aiKept = 0
    /// Dictations per app name.
    public var apps: [String: Int] = [:]

    public init() {}
}

/// Daily counts behind the dashboard meters, so they survive History being trimmed, cleared or off.
public struct UsageLog: Codable, Sendable, Equatable {
    /// Keyed by local date, "yyyy-MM-dd".
    public var days: [String: UsageDay] = [:]
    /// The last few turnarounds (stop → text in place), newest last.
    public var turnarounds: [Double] = []
    public var totalWords = 0

    public init() {}

    public static func key(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public mutating func recordDictation(words: Int, seconds: Double, turnaround: Double, usedAI: Bool, keptAI: Bool, app: String?, on date: Date = Date()) {
        var d = days[Self.key(date)] ?? UsageDay()
        d.dictations += 1
        d.words += words
        d.secondsSpoken += seconds
        if usedAI { d.aiEdits += 1; if keptAI { d.aiKept += 1 } }
        if let app { d.apps[app, default: 0] += 1 }
        days[Self.key(date)] = d
        totalWords += words
        turnarounds.append(turnaround)
        if turnarounds.count > 20 { turnarounds.removeFirst(turnarounds.count - 20) }
    }

    public mutating func recordReading(words: Int, seconds: Double, on date: Date = Date()) {
        var d = days[Self.key(date)] ?? UsageDay()
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

    /// The average of the last three turnarounds, or nil before the first dictation.
    public var recentTurnaround: Double? {
        let last = turnarounds.suffix(3)
        return last.isEmpty ? nil : last.reduce(0, +) / Double(last.count)
    }
}
