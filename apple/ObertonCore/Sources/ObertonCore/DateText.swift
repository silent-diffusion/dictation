import Foundation

/// Dates as the Windows app writes them: day before month, whatever the region's usual order ("Tuesday 3 November",
/// "3 Nov"), with the month and day names in the user's language, and times in the region's short style (.NET "t").
/// The patterns are .NET's custom formats spelled for ICU (dddd → EEEE).
public enum DateText {
    /// "Tuesday 3 November" (Dashboard clock, History title: `{0:dddd d MMMM}`).
    public static func weekdayDayMonth(_ date: Date, locale: Locale = .current) -> String { format(date, "EEEE d MMMM", locale) }
    /// "Tuesday 3 November 2026, 14:05" (Notes header: `{0:dddd d MMMM yyyy, HH:mm}`).
    public static func weekdayDayMonthYearTime(_ date: Date, locale: Locale = .current) -> String {
        format(date, "EEEE d MMMM yyyy, HH:mm", locale)
    }
    /// "3 Nov" (History rows, Run again, Analytics: `{0:d MMM}`).
    public static func dayMonth(_ date: Date, locale: Locale = .current) -> String { format(date, "d MMM", locale) }
    /// "3 Nov 14:05" (a new notes session's title: `{0:d MMM HH:mm}`).
    public static func dayMonthTime24(_ date: Date, locale: Locale = .current) -> String { format(date, "d MMM HH:mm", locale) }
    /// "Nov" (Analytics' month buckets: `{0:MMM}`).
    public static func month(_ date: Date, locale: Locale = .current) -> String { format(date, "MMM", locale) }
    /// The time in the region's short style, "2:05 PM" or "14:05" (.NET's "t").
    public static func time(_ date: Date, locale: Locale = .current) -> String {
        formatter(key: "t|\(locale.identifier)") { f in f.locale = locale; f.dateStyle = .none; f.timeStyle = .short }.string(from: date)
    }
    /// "3 Nov, 2:05 PM" (History rows and the Notes list: `{0:d MMM}, {0:t}`).
    public static func dayMonthTime(_ date: Date, locale: Locale = .current) -> String { dayMonth(date, locale: locale) + ", " + time(date, locale: locale) }

    /// Any fixed ICU pattern, in the user's language.
    public static func format(_ date: Date, _ pattern: String, _ locale: Locale = .current) -> String {
        formatter(key: pattern + "|" + locale.identifier) { f in f.locale = locale; f.dateFormat = pattern }.string(from: date)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    private static func formatter(key: String, _ make: (DateFormatter) -> Void) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let f = cache[key] { return f }
        let f = DateFormatter()
        make(f)
        cache[key] = f
        return f
    }
}
