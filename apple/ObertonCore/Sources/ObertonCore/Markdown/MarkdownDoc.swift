import Foundation

/// A Markdown text as the plain text read aloud, plus where its headings, list items, quotes, code and bold, italic and
/// link runs are in that plain text, so the player can show it formatted while it highlights what is being read.
/// The plain text follows the same rules as `MarkdownText.toPlain` (it uses its inline rules), worked out line by line
/// so every position is known. (Windows' Reading/MarkdownDoc.cs. Positions are UTF-16 units, like the player's ranges.)
public struct MarkdownDoc: Sendable, Equatable {
    /// What a line of a Markdown text is.
    public enum LineKind: Sendable, Equatable { case paragraph, heading, bullet, numbered, quote, code, table }

    /// Inline formatting.
    public struct Style: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let bold = Style(rawValue: 1)
        public static let italic = Style(rawValue: 2)
        public static let code = Style(rawValue: 4)
        public static let link = Style(rawValue: 8)
        public static let strike = Style(rawValue: 16)
    }

    /// A line of `plain`: where it is, what it is, how deep (heading level 1-6, list nesting from 0).
    public struct Line: Sendable, Equatable {
        public var start: Int
        public var length: Int
        public var kind: LineKind
        public var level: Int
    }

    /// A formatted stretch of `plain`.
    public struct Span: Sendable, Equatable {
        public var start: Int
        public var length: Int
        public var style: Style
    }

    public let plain: String
    public let lines: [Line]
    public let spans: [Span]

    /// Only "\n" ends a line for `.` and `$`, as in .NET: a U+2028 or NEL inside a line (a soft break from Mail or
    /// TextEdit) stays part of the item or heading.
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: .useUnixLineSeparators) }
    private static let fence = re(#"^ {0,3}(```|~~~)"#)
    private static let linkDef = re(#"^ {0,3}\[[^\]\n]+\]:\s*\S+"#)
    private static let rule = re(#"^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let tableSep = re(#"^ {0,3}\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$"#)
    private static let tableRow = re(#"^ {0,3}\|(.*)\|[ \t]*$"#)
    private static let heading = re(#"^[ \t]*(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$"#)
    private static let setext = re(#"^ {0,3}(=+|-{2,})[ \t]*$"#)
    private static let quote = re(#"^([ \t]*>)+[ \t]?(.*)$"#)
    private static let bullet = re(#"^([ \t]*)[-*+•◦▪‣][ \t]+(?:\[[ xX]\][ \t]+)?(.*)$"#)
    private static let number = re(#"^([ \t]*)(\d{1,3}[.)])[ \t]+(.*)$"#)

    /// The inline marks, tried left to right; named groups say what each is and hold its text.
    private static let inlineMarks = re(
        #"(?<code>`+(?<ct>[^`\n]+?)`+)"# +
        #"|!\[(?<img>[^\]\n]*)\]\([^)\n]*\)"# +
        #"|\[(?<lt>[^\]\n]+)\]\([^)\n]*\)"# +
        #"|<(?<auto>(?:https?|mailto):[^>\s]+)>"# +
        #"|(?<bm>\*\*|__)(?=\S)(?<b>.+?)(?<=\S)\k<bm>"# +
        #"|~~(?=\S)(?<st>.+?)(?<=\S)~~"# +
        #"|(?<![\w*])\*(?=\S)(?<i1>[^*\n]+?)(?<=\S)\*(?![\w*])"# +
        #"|(?<![\w_])_(?=\S)(?<i2>[^_\n]+?)(?<=\S)_(?![\w_])"# +
        #"|(?<url>https?://[^\s)<>]+)"#)

    public static func parse(_ markdown: String) -> MarkdownDoc {
        let plain = NSMutableString()
        var lines: [Line] = []
        var spans: [Span] = []
        let raw = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var inCode = false
        var blankRun = 0

        func addLine(_ kind: LineKind, _ level: Int, _ write: () -> Void) {
            let start = plain.length
            write()
            // No trailing spaces (the plain text never has them)
            while plain.length > start, [0x20, 0x09].contains(plain.character(at: plain.length - 1)) {
                plain.deleteCharacters(in: NSRange(location: plain.length - 1, length: 1))
            }
            let length = plain.length - start
            if length == 0 && kind != .code {
                if lines.isEmpty { return } // no leading blank lines, at most one in a row
                blankRun += 1
                if blankRun > 1 { return }
                plain.append("\n")
                lines.append(Line(start: start, length: 0, kind: .paragraph, level: 0))
                return
            }
            blankRun = 0
            plain.append("\n")
            lines.append(Line(start: start, length: length, kind: kind, level: level))
        }

        func emit(_ text: String, _ style: Style, raw: Bool = false) {
            let t = (raw ? text : MarkdownText.inlineToPlain(text)).replacingOccurrences(of: "\n", with: " ")
            let n = t.utf16.count
            if n == 0 { return }
            if !style.isEmpty { spans.append(Span(start: plain.length, length: n, style: style)) }
            plain.append(t)
        }

        // Inline text: formatted runs into the plain text, each run's text made plain by the shared inline rules.
        func inline(_ text: String, _ outer: Style = []) {
            let ns = text as NSString
            var pos = 0
            for m in inlineMarks.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if m.range.location > pos { emit(ns.substring(with: NSRange(location: pos, length: m.range.location - pos)), outer) }
                func g(_ name: String) -> String? {
                    let r = m.range(withName: name)
                    return r.location == NSNotFound ? nil : ns.substring(with: r)
                }
                if let ct = g("ct") { emit(ct, outer.union(.code), raw: true) }
                else if let img = g("img") { emit(img, outer) }
                else if let lt = g("lt") { emit(lt, outer.union(.link)) }
                else if let auto = g("auto") { emit(auto, outer.union(.link)) }
                else if let b = g("b") { inline(b, outer.union(.bold)) } // **a *b* c**
                else if let st = g("st") { inline(st, outer.union(.strike)) }
                else if let i = g("i1") ?? g("i2") { inline(i, outer.union(.italic)) }
                else if let url = g("url") { emit(url, outer.union(.link), raw: true) }
                pos = m.range.location + m.range.length
            }
            if pos < ns.length { emit(ns.substring(from: pos), outer) }
        }

        var i = 0
        while i < raw.count {
            let line = raw[i]
            defer { i += 1 }
            if test(fence, line) { inCode.toggle(); continue }
            if inCode {
                addLine(.code, 0) { plain.append(trimEnd(line)) }
                continue
            }
            if test(linkDef, line) || test(rule, line) || test(tableSep, line) { continue }
            // "Title" underlined with ===== (or ---) on the next line: a heading
            if i + 1 < raw.count, !NotesMarkdown.trim(line).isEmpty, test(setext, raw[i + 1]), !test(bullet, line) {
                let level = raw[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix("=") ? 1 : 2
                addLine(.heading, level) { inline(NotesMarkdown.trim(line)) }
                i += 1
                continue
            }
            if let m = first(tableRow, line) {
                let cells = group(line, m, 1).components(separatedBy: "|").map(NotesMarkdown.trim).filter { !$0.isEmpty }.joined(separator: ", ")
                addLine(.table, 0) { inline(cells) }
            } else if let m = first(heading, line) {
                addLine(.heading, m.range(at: 1).length) { inline(group(line, m, 2)) }
            } else if let m = first(quote, line) {
                addLine(.quote, 0) { inline(group(line, m, 2)) }
            } else if let m = first(bullet, line) {
                addLine(.bullet, indent(group(line, m, 1))) { inline(group(line, m, 2)) }
            } else if let m = first(number, line) {
                // The number stays in the text (it is read out: "1. First step").
                addLine(.numbered, indent(group(line, m, 1))) { plain.append(group(line, m, 2) + " "); inline(group(line, m, 3)) }
            } else {
                addLine(.paragraph, 0) { inline(NotesMarkdown.trim(line)) }
            }
        }

        // Drop trailing blank lines and the final line break.
        while let last = lines.last, last.length == 0 {
            plain.deleteCharacters(in: NSRange(location: last.start, length: plain.length - last.start))
            lines.removeLast()
        }
        if plain.length > 0, plain.character(at: plain.length - 1) == 0x0A { plain.deleteCharacters(in: NSRange(location: plain.length - 1, length: 1)) }
        return MarkdownDoc(plain: plain as String, lines: lines, spans: spans)
    }

    private static func indent(_ ws: String) -> Int { min(4, ws.replacingOccurrences(of: "\t", with: "    ").utf16.count / 2) }

    private static func test(_ re: NSRegularExpression, _ s: String) -> Bool { first(re, s) != nil }
    private static func first(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? { NotesMarkdown.matches(re, s) }
    private static func group(_ s: String, _ m: NSTextCheckingResult, _ i: Int) -> String { NotesMarkdown.group(s, m.range(at: i)) }

    private static func trimEnd(_ s: String) -> String {
        var u = Array(s.utf16)
        while let last = u.last, NotesMarkdown.white(last) { u.removeLast() }
        return String(decoding: u, as: UTF16.self)
    }

    /// The line holding position `pos` of `plain`.
    public func lineAt(_ pos: Int) -> Line? {
        var lo = 0, hi = lines.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let l = lines[mid]
            if pos < l.start { hi = mid - 1 } else if pos > l.start + l.length { lo = mid + 1 } else { return l }
        }
        return nil
    }

    /// The inline style at `pos`.
    public func styleAt(_ pos: Int) -> Style {
        var style: Style = []
        for s in spans {
            if s.start > pos { break }
            if pos < s.start + s.length { style.formUnion(s.style) }
        }
        return style
    }
}
