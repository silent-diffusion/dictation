import Foundation

/// Word diff for long texts (an hour of notes is ten thousand words): Myers' O(N·D) algorithm, which is fast when the two
/// texts are mostly alike, after trimming what they share at both ends (LongDiff.cs). Same output shape as `WordDiff`:
/// Same and Added carry the edited text's spelling, Removed the original's.
public enum LongDiff {
    /// Beyond this many differences the middle is reported as replaced wholesale: the walk-back keeps about D² ints,
    /// and a diff that different is no use to read anyway.
    static let maxEdits = 3000

    public static func split(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

    public static func compute(_ original: String, _ edited: String) -> [DiffToken] { compute(split(original), split(edited)) }

    public static func compute(_ a: [String], _ b: [String]) -> [DiffToken] {
        let na = a.map(WordDiff.normalize), nb = b.map(WordDiff.normalize)
        var result: [DiffToken] = []
        result.reserveCapacity(a.count + b.count)
        var start = 0
        while start < na.count && start < nb.count && na[start] == nb[start] { result.append(DiffToken(word: b[start], kind: .same)); start += 1 }
        var endA = na.count, endB = nb.count
        var tail: [DiffToken] = []
        while endA > start && endB > start && na[endA - 1] == nb[endB - 1] {
            endA -= 1; endB -= 1
            tail.append(DiffToken(word: b[endB], kind: .same))
        }
        if let middle = myers(a, b, na, nb, start, endA, endB) {
            result += middle
        } else {
            for i in start..<endA { result.append(DiffToken(word: a[i], kind: .removed)) }
            for j in start..<endB { result.append(DiffToken(word: b[j], kind: .added)) }
        }
        result += tail.reversed()
        return result
    }

    /// The edit script between a[start..<endA] and b[start..<endB]; nil when it has more than `maxEdits` edits.
    static func myers(_ a: [String], _ b: [String], _ na: [String], _ nb: [String], _ start: Int, _ endA: Int, _ endB: Int) -> [DiffToken]? {
        let n = endA - start, m = endB - start
        if n == 0 && m == 0 { return [] }
        let most = min(n + m, maxEdits)
        let offset = most + 1
        var v = [Int](repeating: 0, count: 2 * most + 3)
        var trace: [[Int]] = []
        var found = false
        for d in 0...most {
            trace.append(Array(v[(offset - d - 1)...(offset + d + 1)]))
            var k = -d
            while k <= d {
                var x = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n && y < m && na[start + x] == nb[start + y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m { found = true; break }
                k += 2
            }
            if found { break }
        }
        guard found else { return nil }
        // Walk back through the saved rows.
        var out: [DiffToken] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let row = trace[d] // v[-d-1 ... d+1] before step d
            func at(_ k: Int) -> Int { row[k + d + 1] }
            let k = x - y
            if d == 0 {
                while x > 0 && y > 0 { out.append(DiffToken(word: b[start + y - 1], kind: .same)); x -= 1; y -= 1 }
                break
            }
            let down = k == -d || (k != d && at(k - 1) < at(k + 1))
            let prevK = down ? k + 1 : k - 1
            let prevX = at(prevK), prevY = prevX - prevK
            while x > prevX && y > prevY { out.append(DiffToken(word: b[start + y - 1], kind: .same)); x -= 1; y -= 1 }
            if down { out.append(DiffToken(word: b[start + y - 1], kind: .added)); y -= 1 }
            else { out.append(DiffToken(word: a[start + x - 1], kind: .removed)); x -= 1 }
        }
        return out.reversed()
    }
}

/// How a word shows on the Edited tab.
public enum EditMark: Sendable, Equatable {
    /// As heard, unchanged.
    case plain
    /// A paragraph break that was already there.
    case paragraph
    case aiRemoved, aiAdded
    /// A paragraph break the AI made.
    case aiParagraph
    case userRemoved
    /// A word the user put in place of another.
    case userChanged
    /// Words the user typed (a note).
    case userNote
}

/// A word on the Edited tab and about when in the recording it was said.
public struct EditPiece: Sendable, Equatable {
    public var text: String
    public var mark: EditMark
    public var seconds: Double
}

/// The Edited tab: one text in which every change is marked, the AI's apart from the user's (NotesEdits.cs). For each
/// formatting step it lines up what was heard, the transcript as sent (the user's edits) and the AI's output; then the
/// user's edits in the Formatted tab; then the part of the transcript not formatted yet.
public enum NotesEdits {
    public static let para = "¶"

    /// Words, with each line or paragraph break as a `para` token.
    public static func tokens(_ text: String) -> [String] {
        LongDiff.split(text.trimmed.replacingOccurrences(of: #"\s*\n\s*"#, with: " \(para) ", options: .regularExpression))
    }

    struct Item {
        var text: String
        var mark: EditMark
        var inAi: Bool
        var userOrigin: Bool
        var seconds = 0.0
    }

    public static func build(_ s: NoteSession) -> [EditPiece] {
        var items: [Item] = []
        var aiTokens: [String] = []
        for (c, chunk) in s.chunks.enumerated() {
            if !items.isEmpty { items.append(Item(text: para, mark: .paragraph, inAi: true, userOrigin: false, seconds: chunk.seconds)); aiTokens.append(para) }
            // A step covers a minute or so: its words are spread over that time, in proportion.
            let merged = mergeChunk(chunk)
            let end = c + 1 < s.chunks.count ? s.chunks[c + 1].seconds : s.formattedEndSeconds()
            for (i, var it) in merged.enumerated() {
                it.seconds = chunk.seconds + max(0, end - chunk.seconds) * Double(i) / Double(merged.count)
                items.append(it)
                if it.inAi { aiTokens.append(it.text) }
            }
        }

        // The user's edits in the Formatted tab, lined up with the AI's text.
        let formatted = tokens(s.formatted)
        var withFormatted = aiTokens.isEmpty && formatted.isEmpty ? items : mergeFormatted(items, aiTokens, formatted)

        // The transcript not formatted yet: the user's edits of what was heard.
        let heardRest = tokens(s.heard.u16(s.heardFormattedThrough))
        let tailFrom = min(s.formattedThrough, s.transcript.u16)
        let tail = s.transcript.u16(tailFrom)
        let transcriptRest = tokens(tail)
        let offs = offsets(tail, transcriptRest)
        var rest: [Item] = []
        var j = 0
        var seconds = s.formattedEndSeconds()
        for t in LongDiff.compute(heardRest, transcriptRest) {
            // Words in the transcript have their moment; a word the user removed takes its neighbour's.
            if t.kind != .removed && j < offs.count { seconds = s.secondsAt(.transcript, tailFrom + offs[j]); j += 1 }
            switch t.kind {
            case .same: rest.append(Item(text: t.word, mark: t.word == para ? .paragraph : .plain, inAi: false, userOrigin: false, seconds: seconds))
            case .removed: rest.append(Item(text: t.word, mark: .userRemoved, inAi: false, userOrigin: false, seconds: seconds))
            case .added: rest.append(Item(text: t.word, mark: t.word == para ? .paragraph : .userNote, inAi: false, userOrigin: true, seconds: seconds))
            }
        }
        classify(&rest)
        if !withFormatted.isEmpty, let first = rest.first { withFormatted.append(Item(text: para, mark: .paragraph, inAi: false, userOrigin: false, seconds: first.seconds)) }
        withFormatted += rest

        return withFormatted.filter { !($0.text == para && ($0.mark == .userRemoved || $0.mark == .aiRemoved)) }
            .map { EditPiece(text: $0.text, mark: $0.mark, seconds: $0.seconds) }
    }

    /// Where each token begins in the text it came from (UTF-16 offsets).
    static func offsets(_ text: String, _ tokens: [String]) -> [Int] {
        let ns = text as NSString
        var result: [Int] = []
        var pos = text.u16 - text.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression).u16
        for t in tokens {
            let from = min(pos, ns.length)
            var at: Int
            if t == para {
                let r = ns.range(of: "\n", range: NSRange(location: from, length: ns.length - from))
                at = r.location == NSNotFound ? from : r.location
                pos = at + 1
            } else {
                let r = ns.range(of: t, range: NSRange(location: from, length: ns.length - from))
                at = r.location == NSNotFound ? from : r.location
                pos = at + (t as NSString).length
            }
            result.append(min(at, ns.length))
        }
        return result
    }

    /// One formatting step: heard → sent (the user's edits) and sent → AI (the AI's edits), merged along the words that
    /// were sent. Between them sit the heard words the user removed and the words the AI added.
    static func mergeChunk(_ c: NoteChunk) -> [Item] {
        let user = LongDiff.compute(tokens(c.heard), tokens(c.sent))
        let aiDiff = LongDiff.compute(tokens(c.sent), tokens(c.ai))
        var output: [Item] = []
        var i = 0, j = 0
        while i < user.count || j < aiDiff.count {
            while i < user.count && user[i].kind == .removed { output.append(Item(text: user[i].word, mark: .userRemoved, inAi: false, userOrigin: false)); i += 1 }
            while j < aiDiff.count && aiDiff[j].kind == .added {
                let w = aiDiff[j].word
                output.append(Item(text: w, mark: w == para ? .aiParagraph : .aiAdded, inAi: true, userOrigin: false))
                j += 1
            }
            if i >= user.count || j >= aiDiff.count {
                // Out of step (shouldn't happen): keep what is left of the AI's text, so nothing goes missing.
                while j < aiDiff.count {
                    if aiDiff[j].kind != .removed { output.append(Item(text: aiDiff[j].word, mark: .plain, inAi: true, userOrigin: false)) }
                    j += 1
                }
                break
            }
            let typedByUser = user[i].kind == .added
            let word = aiDiff[j].word
            if aiDiff[j].kind == .removed {
                output.append(Item(text: word, mark: .aiRemoved, inAi: false, userOrigin: typedByUser))
            } else {
                output.append(Item(text: word, mark: word == para ? .paragraph : typedByUser ? .userNote : .plain, inAi: true, userOrigin: typedByUser))
            }
            i += 1; j += 1
        }
        classify(&output)
        return output
    }

    /// The user's edits in the Formatted tab: the AI's words they removed, and what they typed.
    static func mergeFormatted(_ items: [Item], _ aiTokens: [String], _ formatted: [String]) -> [Item] {
        let diff = LongDiff.compute(aiTokens, formatted)
        var output: [Item] = []
        var j = 0
        func typed() {
            while j < diff.count && diff[j].kind == .added {
                let w = diff[j].word
                output.append(Item(text: w, mark: w == para ? .paragraph : .userNote, inAi: false, userOrigin: true, seconds: output.last?.seconds ?? 0))
                j += 1
            }
        }
        for it in items {
            if !it.inAi { output.append(it); continue }
            typed()
            if j < diff.count && diff[j].kind == .removed {
                var removed = it
                removed.mark = .userRemoved
                removed.inAi = false
                output.append(removed)
                j += 1
            } else {
                output.append(it)
                if j < diff.count { j += 1 }
            }
        }
        typed()
        classify(&output)
        return output
    }

    /// A run of typed words right next to words the user removed replaced them: "changed", not a note.
    static func classify(_ items: inout [Item]) {
        var i = 0
        while i < items.count {
            guard items[i].mark == .userNote else { i += 1; continue }
            let start = i
            while i + 1 < items.count && items[i + 1].mark == .userNote { i += 1 }
            let before = start > 0 && items[start - 1].mark == .userRemoved
            let after = i + 1 < items.count && items[i + 1].mark == .userRemoved
            if before || after { for k in start...i { items[k].mark = .userChanged } }
            i += 1
        }
    }
}
