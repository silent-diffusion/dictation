import Foundation
import Speech

/// A word as the speech engine heard it, and when: seconds into the recording. Kept with each recording (an Extended
/// Notes session's session.json, a History entry's words.json) so playback can light the word being said.
public struct SpokenWord: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }

    // Short keys: an hour of notes is ten thousand words.
    enum CodingKeys: String, CodingKey { case text = "w", start = "s", end = "e" }

    /// The same word, `seconds` later (times from a stream that started part way into the recording).
    public func shifted(by seconds: Double) -> SpokenWord { SpokenWord(text: text, start: start + seconds, end: end + seconds) }
}

/// A stretch of a text (UTF-16 range) and when it was said.
public struct TimedSpan: Sendable, Equatable {
    public var range: NSRange
    public var start: Double
    public var end: Double
}

/// Lines the words heard up with a text shown (the transcript, or what became of it: the formatted text, an AI edit,
/// the user's edits), and finds the word being said at a moment of the playback.
public enum WordTimes {
    /// A word is still lit this long after its end, so it doesn't flicker off between words.
    public static let hold = 0.25

    /// A word for matching: lower case, letters and digits only ("Hello," and "hello" match; "—" has none and is skipped).
    public static func key(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The words of a text with their UTF-16 ranges, the ones that have a key.
    public static func tokens(_ text: String) -> [(range: NSRange, key: String)] {
        let ns = text as NSString
        var out: [(NSRange, String)] = []
        var i = 0
        let n = ns.length
        let space = CharacterSet.whitespacesAndNewlines
        func isSpace(_ c: unichar) -> Bool { Unicode.Scalar(c).map { space.contains($0) } ?? false }
        while i < n {
            while i < n && isSpace(ns.character(at: i)) { i += 1 }
            let start = i
            while i < n && !isSpace(ns.character(at: i)) { i += 1 }
            if i > start {
                let r = NSRange(location: start, length: i - start)
                let k = key(ns.substring(with: r))
                if !k.isEmpty { out.append((trimmedToWord(r, ns), k)) }
            }
        }
        return out
    }

    /// The range without the punctuation around the word ("(hello," lights "hello").
    static func trimmedToWord(_ r: NSRange, _ ns: NSString) -> NSRange {
        var a = r.location, b = NSMaxRange(r)
        func isWordChar(_ c: unichar) -> Bool { Unicode.Scalar(c).map { CharacterSet.alphanumerics.contains($0) } ?? true } // surrogates: keep
        while a < b && !isWordChar(ns.character(at: a)) { a += 1 }
        while b > a && !isWordChar(ns.character(at: b - 1)) { b -= 1 }
        return a < b ? NSRange(location: a, length: b - a) : r
    }

    /// The spoken words split into single words with keys (an engine's "word" may hold a space, or none).
    static func spoken(_ words: [SpokenWord]) -> [(key: String, start: Double, end: Double)] {
        var out: [(String, Double, Double)] = []
        for w in words {
            let parts = w.text.split(whereSeparator: \.isWhitespace).map { key(String($0)) }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }
            let step = (w.end - w.start) / Double(parts.count)
            for (i, p) in parts.enumerated() { out.append((p, w.start + step * Double(i), w.start + step * Double(i + 1))) }
        }
        return out
    }

    /// The words of `text` that line up with words heard (a word-level diff of the two), with when each was said, in
    /// the text's order. Words of the text with no match (typed, or changed beyond recognition) have none. `minRun`:
    /// only matches in runs of at least that many words in a row count (a summary shares a phrase with what was said,
    /// not a stray "the").
    public static func align(_ text: String, _ words: [SpokenWord], minRun: Int = 1) -> [TimedSpan] {
        let shown = tokens(text), heard = spoken(words)
        guard !shown.isEmpty, !heard.isEmpty else { return [] }
        var spans: [TimedSpan] = []
        var run: [TimedSpan] = []
        func endRun() { if run.count >= minRun { spans += run }; run = [] }
        var a = 0, b = 0
        for t in LongDiff.compute(heard.map(\.key), shown.map(\.key)) {
            switch t.kind {
            case .same:
                run.append(TimedSpan(range: shown[b].range, start: heard[a].start, end: heard[a].end))
                a += 1; b += 1
            case .removed: endRun(); a += 1
            case .added: endRun(); b += 1
            }
        }
        endRun()
        return spans
    }

    /// A stretch of speech's words spread over its time by their length (when the engine timed only the stretch).
    public static func spread(_ text: String, start: Double, end: Double) -> [SpokenWord] {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty, end >= start else { return [] }
        let weights = parts.map { Double($0.count) + 1 }, total = weights.reduce(0, +)
        var at = start
        return zip(parts, weights).map { w, weight in
            let next = at + (end - start) * weight / total
            defer { at = next }
            return SpokenWord(text: w, start: at, end: next)
        }
    }

    /// The span being said at `seconds`: the last one started by then, while it lasts (plus `hold`).
    public static func current(_ spans: [TimedSpan], at seconds: Double) -> TimedSpan? {
        var best: TimedSpan?
        for s in spans where s.start <= seconds && seconds <= s.end + hold {
            if best == nil || s.start >= best!.start { best = s }
        }
        return best
    }

    /// The words of a recognizer's result, from its audio time ranges (Apple's SpeechTranscriber with
    /// `attributeOptions: [.audioTimeRange]`), `offset` seconds added.
    public static func words(_ text: AttributedString, offset: Double = 0) -> [SpokenWord] {
        var out: [SpokenWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let word = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            let start = range.start.seconds, end = range.end.seconds
            guard !word.isEmpty, start.isFinite, end.isFinite else { continue }
            out.append(SpokenWord(text: word, start: start + offset, end: max(start, end) + offset))
        }
        return out
    }
}
