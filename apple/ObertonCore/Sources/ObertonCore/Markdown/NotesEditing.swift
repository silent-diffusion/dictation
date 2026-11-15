import Foundation

// The rules of Extended Notes' line-at-a-time editing and of its "Jump to this moment" menu that don't depend on the
// screen (Windows' MarkdownPresenter.Split and NotesPage.SummaryMoment).

extension NotesMarkdown {
    /// What Enter does on a line.
    public enum Enter: Sendable, Equatable {
        /// An ordinary line break.
        case plain
        /// An empty list item: it is cleared, and the list ends here.
        case endList
        /// A list goes on: the line breaks and the new line begins with this (the next bullet, the next number).
        case `continue`(String)
    }

    private static let listItem = try! NSRegularExpression(pattern: #"^(\s*)(?:([-*+•])|(\d{1,3})([.)]))\s+"#)

    /// Enter on `line` with the cursor at `caret` (UTF-16): a list goes on; Enter on an empty list item ends the list.
    public static func enter(line: String, caret: Int) -> Enter {
        guard let m = matches(listItem, line), caret >= m.range.length else { return .plain }
        let mark = group(line, m.range)
        if trim(line) == trim(mark) { return .endList }
        if m.range(at: 2).location != NSNotFound { return .continue(group(line, m.range(at: 1)) + group(line, m.range(at: 2)) + " ") }
        let n = (Int(group(line, m.range(at: 3))) ?? 0) + 1
        return .continue(group(line, m.range(at: 1)) + String(n) + group(line, m.range(at: 4)) + " ")
    }
}

extension NoteSession {
    /// The summary doesn't follow the recording in order, so a sentence in it leads to the section whose own summary
    /// shares the most words with it. `caret` is a position in `summary` (UTF-16); nil when nothing matches.
    public func summaryMoment(_ summary: String, caret: Int) -> Double? {
        let sections = digests.filter { $0.level == 0 }
        let t = Array(summary.utf16)
        guard !t.isEmpty, !sections.isEmpty else { return nil }
        let caret = min(max(caret, 0), t.count)
        let ends = Set(Array("\n.!?".utf16))
        var start = 0
        var i = max(0, caret - 1)
        while i >= 0 { if ends.contains(t[i]) { start = i + 1; break }; i -= 1 }
        var end = t.count
        if caret < t.count, let e = t[caret...].firstIndex(where: ends.contains) { end = e }
        let words = Self.keywords(String(decoding: t[min(start, end)..<end], as: UTF16.self))
        if words.isEmpty { return nil }
        var best: NoteDigest?
        var bestScore = 0
        for d in sections {
            let score = Self.keywords(d.text).filter(words.contains).count
            if score > bestScore { bestScore = score; best = d }
        }
        return best?.start
    }

    static func keywords(_ s: String) -> Set<String> {
        let strip = CharacterSet(charactersIn: ".,;:!?\"'()-–")
        return Set(s.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: strip).lowercased() }.filter { $0.utf16.count >= 4 })
    }
}
