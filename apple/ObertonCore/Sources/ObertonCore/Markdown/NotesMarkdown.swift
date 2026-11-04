import Foundation

/// The Markdown Extended Notes renders, for reading: headings, bullet and numbered lists, block quotes, code, rules,
/// **bold**, *italic* and `code`, links as their text, and the listener's ⚑ markers. A short label at the start of a
/// paragraph or a list item ("Main idea:", "Todo:") is shown in bold. Lines are kept as written (a line break is a
/// line break, as in a chat), since notes are typed line by line. The text itself stays plain; this only reads it.
/// (Windows' Text/NotesMarkdown.cs, rule for rule. Offsets are UTF-16 units, like the session's carets.)
public enum NotesMarkdown {
    public enum Kind: Sendable, Equatable { case paragraph, heading, bullet, numbered, quote, code, rule, marker }

    /// A piece of a block's text. `offset` is where it starts in the source, so a click on the rendered text can be
    /// taken back to the same place in the plain text. `isBreak` is a line break.
    public struct Span: Sendable, Equatable {
        public var text: String
        public var offset: Int
        public var bold = false
        public var italic = false
        public var code = false
        public var isBreak = false

        public init(_ text: String, _ offset: Int, bold: Bool = false, italic: Bool = false, code: Bool = false, isBreak: Bool = false) {
            self.text = text; self.offset = offset; self.bold = bold; self.italic = italic; self.code = code; self.isBreak = isBreak
        }

        static func lineBreak(_ offset: Int) -> Span { Span("", offset, isBreak: true) }
    }

    /// `level`: a heading's level (1 to 6), or a list item's indent (0, 1, …). `number`: a numbered item's number as written.
    public struct Block: Sendable, Equatable {
        public var kind: Kind
        public var spans: [Span]
        public var offset: Int
        public var level = 0
        public var number = ""

        public init(_ kind: Kind, _ spans: [Span], _ offset: Int, level: Int = 0, number: String = "") {
            self.kind = kind; self.spans = spans; self.offset = offset; self.level = level; self.number = number
        }
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let heading = re(#"^(#{1,6})\s+(.*?)\s*#*\s*$"#)
    private static let bullet = re(#"^(\s*)[-*+•]\s+(.*)$"#)
    private static let numbered = re(#"^(\s*)(\d{1,3})[.)]\s+(.*)$"#)
    private static let quote = re(#"^\s*>\s?(.*)$"#)
    private static let rule = re(#"^\s*([-*_])(?:\s*\1){2,}\s*$"#)
    private static let fence = re(#"^\s*```"#)
    private static let label = re(#"^\p{Lu}[\p{L}'’]*(?:\s[\p{L}'’]+){0,3}:(?=\s|$)"#)

    public static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [Span] = [], paraOffset = 0
        var code: [Span]? = nil, codeOffset = 0
        var quoted: [Span] = [], quoteOffset = 0

        func endParagraph() {
            if !para.isEmpty { blocks.append(Block(.paragraph, para, paraOffset)) }
            para.removeAll()
        }
        func endQuote() {
            if !quoted.isEmpty { blocks.append(Block(.quote, quoted, quoteOffset)) }
            quoted.removeAll()
        }

        var pos = 0
        for raw in text.components(separatedBy: "\n") {
            let lineStart = pos
            pos += raw.utf16.count + 1
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw

            if code != nil {
                if matches(fence, line) != nil {
                    blocks.append(Block(.code, code!, codeOffset))
                    code = nil
                } else {
                    if !code!.isEmpty { code!.append(.lineBreak(lineStart)) }
                    code!.append(Span(line, lineStart, code: true))
                }
                continue
            }
            if matches(fence, line) != nil {
                endParagraph(); endQuote()
                code = []
                codeOffset = lineStart
                continue
            }
            let trimmed = trim(line)
            if trimmed.isEmpty { endParagraph(); endQuote(); continue }

            let lead = leadingSpace(line)
            if trimmed.hasPrefix("⚑") {
                endParagraph(); endQuote()
                blocks.append(Block(.marker, [Span(trimmed, lineStart + lead)], lineStart))
                continue
            }
            if matches(rule, line) != nil {
                endParagraph(); endQuote()
                blocks.append(Block(.rule, [], lineStart))
                continue
            }
            if let h = matches(heading, line) {
                endParagraph(); endQuote()
                let r = h.range(at: 2)
                blocks.append(Block(.heading, inline(group(line, r), lineStart + r.location), lineStart, level: h.range(at: 1).length))
                continue
            }
            if let b = matches(bullet, line) {
                endParagraph(); endQuote()
                let r = b.range(at: 2)
                blocks.append(Block(.bullet, labelled(group(line, r), lineStart + r.location), lineStart, level: b.range(at: 1).length / 2))
                continue
            }
            if let n = matches(numbered, line) {
                endParagraph(); endQuote()
                let r = n.range(at: 3)
                blocks.append(Block(.numbered, labelled(group(line, r), lineStart + r.location), lineStart,
                                    level: n.range(at: 1).length / 2, number: group(line, n.range(at: 2))))
                continue
            }
            if let q = matches(quote, line) {
                endParagraph()
                if quoted.isEmpty { quoteOffset = lineStart } else { quoted.append(.lineBreak(lineStart)) }
                let r = q.range(at: 1)
                quoted += inline(group(line, r), lineStart + r.location)
                continue
            }
            endQuote()
            if para.isEmpty {
                paraOffset = lineStart
                para += labelled(trimmed, lineStart + lead)
            } else {
                para.append(.lineBreak(lineStart))
                para += inline(trimmed, lineStart + lead)
            }
        }
        if let code { blocks.append(Block(.code, code, codeOffset)) }
        endParagraph()
        endQuote()
        return blocks
    }

    /// A line whose start is a short label: the label in bold, then the rest.
    static func labelled(_ s: String, _ offset: Int) -> [Span] {
        if let m = matches(label, s), !s.lowercased().hasPrefix("http") {
            let n = m.range.length
            let u = Array(s.utf16)
            return [Span(text(u, 0, n), offset, bold: true)] + inline(text(u, n, u.count), offset + n)
        }
        return inline(s, offset)
    }

    /// The inline markup of a line: `code`, **bold** or __bold__, *italic* or _italic_, [text](link) as its text, and
    /// backslash escapes. Markup that doesn't close is shown as written.
    public static func inline(_ str: String, _ offset: Int, bold: Bool = false, italic: Bool = false) -> [Span] {
        let s = Array(str.utf16)
        var spans: [Span] = []
        var plain: [UInt16] = []
        var plainStart = 0
        func flush(_ at: Int) {
            if !plain.isEmpty { spans.append(Span(String(decoding: plain, as: UTF16.self), offset + plainStart, bold: bold, italic: italic)) }
            plain.removeAll()
            plainStart = at
        }
        let escapable = Array("\\`*_[]()#+-.!>".utf16)
        let star = UInt16(UInt8(ascii: "*")), under = UInt16(UInt8(ascii: "_")), tick = UInt16(UInt8(ascii: "`"))
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == UInt16(UInt8(ascii: "\\")), i + 1 < s.count, escapable.contains(s[i + 1]) {
                // A span of its own (Windows adds it to the plain run): every span's offset then points at its own text,
                // so the editor knows the backslash is markup.
                flush(i)
                spans.append(Span(text(s, i + 1, i + 2), offset + i + 1, bold: bold, italic: italic))
                i += 2
                plainStart = i
                continue
            }
            if c == tick, case let close = index(s, [tick], i + 1), close > 0 {
                flush(i)
                spans.append(Span(text(s, i + 1, close), offset + i + 1, bold: bold, italic: italic, code: true))
                i = close + 1
                plainStart = i
                continue
            }
            if c == star || c == under, i + 1 < s.count, s[i + 1] == c, case let end2 = closing(s, i + 2, [c, c]), end2 > 0 {
                flush(i)
                spans += inline(text(s, i + 2, end2), offset + i + 2, bold: true, italic: italic)
                i = end2 + 2
                plainStart = i
                continue
            }
            if c == star || c == under, c == star || i == 0 || !letterOrDigit(s[i - 1]),
               case let end1 = closing(s, i + 1, [c]), end1 > 0, c == star || end1 + 1 >= s.count || !letterOrDigit(s[end1 + 1]) {
                flush(i)
                spans += inline(text(s, i + 1, end1), offset + i + 1, bold: bold, italic: true)
                i = end1 + 1
                plainStart = i
                continue
            }
            if c == UInt16(UInt8(ascii: "[")), case let mid = index(s, Array("](".utf16), i + 1), mid > 0,
               case let paren = index(s, [UInt16(UInt8(ascii: ")"))], mid + 2), paren > 0 {
                flush(i)
                spans += inline(text(s, i + 1, mid), offset + i + 1, bold: bold, italic: italic)
                i = paren + 1
                plainStart = i
                continue
            }
            if plain.isEmpty { plainStart = i }
            plain.append(c)
            i += 1
        }
        flush(s.count)
        return spans
    }

    /// Where the marker that closes an emphasis starting at `from` is: the content must not begin or end with a space,
    /// and not be empty. -1 when there is none.
    private static func closing(_ s: [UInt16], _ from: Int, _ marker: [UInt16]) -> Int {
        if from >= s.count || white(s[from]) { return -1 }
        var at = index(s, marker, from + 1)
        while at > 0 {
            if !white(s[at - 1]) && (marker.count == 2 || at + 1 >= s.count || s[at + 1] != marker[0]) { return at }
            at = index(s, marker, at + 1)
        }
        return -1
    }

    // MARK: Helpers (UTF-16, as .NET strings are)

    static func matches(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count))
    }

    static func group(_ s: String, _ r: NSRange) -> String { r.location == NSNotFound ? "" : (s as NSString).substring(with: r) }

    private static func text(_ s: [UInt16], _ from: Int, _ to: Int) -> String { String(decoding: s[from..<to], as: UTF16.self) }

    /// The first `needle` in `s` at or after `from`, or -1.
    private static func index(_ s: [UInt16], _ needle: [UInt16], _ from: Int) -> Int {
        guard !needle.isEmpty, from >= 0 else { return -1 }
        var i = from
        while i + needle.count <= s.count {
            if s[i] == needle[0] && (needle.count == 1 || Array(s[i..<i + needle.count]) == needle) { return i }
            i += 1
        }
        return -1
    }

    public static func white(_ u: UInt16) -> Bool { Unicode.Scalar(u).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false }
    /// .NET's char.IsLetterOrDigit on a UTF-16 unit (letters and decimal digits; not "²", "½" or a combining mark).
    static func letterOrDigit(_ u: UInt16) -> Bool { Unicode.Scalar(u).map(NotesFormat.letterOrDigit) ?? false }

    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// How many UTF-16 units of white space a line starts with.
    static func leadingSpace(_ s: String) -> Int {
        var n = 0
        for u in s.utf16 { if white(u) { n += 1 } else { break } }
        return n
    }
}
