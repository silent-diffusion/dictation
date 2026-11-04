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

    /// .NET's "P0": a whole percent in the region's percent pattern. A standard format on .NET Core 3.0 and later
    /// rounds the exact binary value, an exact half to the even neighbour: 0.125 (exactly 12.5 %) is "12%", 0.135 (just
    /// under 13.5 %) "13%", 0.285 (just under 28.5 %) "28%".
    public static func percent(_ x: Double, locale: Locale = .current) -> String {
        guard x.isFinite else { return String(x) }
        let whole = wholePercent(x)
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .percent
        f.multiplier = 1
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: whole)) ?? "\(whole)%"
    }

    /// x × 100 rounded to a whole number from the double's exact value (significand × 2^exponent), ties to even.
    static func wholePercent(_ x: Double) -> Int {
        let magnitude = abs(x)
        guard magnitude != 0 else { return 0 }
        guard magnitude < 1e15 else { return Int((x * 100).rounded(.toNearestOrEven)) }
        // magnitude = sig × 2^exp exactly, sig < 2^53, so sig × 100 < 2^60 fits.
        let exp = Int(magnitude.exponent) - Double.significandBitCount
        let sig = UInt64(magnitude.significandBitPattern) | (magnitude.isNormal ? UInt64(1) << UInt64(Double.significandBitCount) : 0)
        let scaled = sig * 100
        var whole: UInt64
        if exp >= 0 {
            whole = scaled << UInt64(exp)
        } else if -exp >= 64 {
            whole = 0 // below 2^60 / 2^64 of a percent: rounds to 0
        } else {
            let shift = UInt64(-exp)
            whole = scaled >> shift
            let rest = scaled & ((UInt64(1) << shift) - 1), half = UInt64(1) << (shift - 1)
            if rest > half || (rest == half && whole % 2 == 1) { whole += 1 }
        }
        return x < 0 ? -Int(whole) : Int(whole)
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
