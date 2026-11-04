import Foundation

/// Numbers as .NET formats them for the Windows app, in the user's region (CurrentCulture): its decimal separator, its
/// percent pattern ("6%", "6 %") and its digit grouping.
public enum NetNumber {
    /// A custom format with `digits` decimals, all shown ("0.0") or only as many as needed ("0.#"). As .NET: the value
    /// is first taken to 15 significant digits, then rounded half away from zero (5220 s / 3600 = "1.5", where printf's
    /// exact binary value would give "1.4").
    public static func fixed(_ x: Double, digits: Int, optional: Bool = false, locale: Locale = .current) -> String {
        guard x.isFinite else { return String(x) }
        var d = Decimal(string: String(format: "%.14e", x), locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(x)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &d, digits, .plain)
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = optional ? 0 : digits
        f.maximumFractionDigits = digits
        f.minimumIntegerDigits = 1
        // A value that rounds to zero keeps its sign in .NET only when it is shown as non-zero; "-0.0" never appears.
        if rounded == 0 { rounded = 0 }
        return f.string(from: rounded as NSDecimalNumber) ?? String(describing: rounded)
    }

    /// .NET's "P0": a whole percent, rounded half away from zero, in the region's percent pattern.
    public static func percent(_ x: Double, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .percent
        f.maximumFractionDigits = 0
        f.roundingMode = .halfUp
        return f.string(from: NSNumber(value: x)) ?? "\(Int((x * 100).rounded()))%"
    }

    /// .NET's "N0": a whole number with the region's digit grouping ("1,234").
    public static func n0(_ n: Int, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
}
