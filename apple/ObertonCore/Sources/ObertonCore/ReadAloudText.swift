import Foundation

/// Read aloud gets a lot of Markdown (from chat assistants, READMEs, notes apps). Read as is, the voice says
/// "hash hash", "asterisk" and whole URLs. Every text is turned into the plain text a reader would see. Guessing
/// whether a text "is Markdown" missed too often (a chat answer may have only a list and some bold), and the rules
/// are written so ordinary text comes through unchanged: "#1", "5*3" and snake_case names are left alone.
/// (Windows' Reading/MarkdownText.cs, rule for rule.)
public enum MarkdownText {
    /// Plain text for reading aloud.
    public static func forReading(_ text: String) -> String { toPlain(text) }

    /// Strip Markdown syntax, keeping the words and the line structure (one heading or item per line).
    public static func toPlain(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n")

        // Fence lines go; the code inside stays (it is still what the reader would see).
        s = s.regexReplacing(#"^ {0,3}(```|~~~).*$\n?"#, with: "", lines: true)
        // Link reference definitions: "[1]: https://..."
        s = s.regexReplacing(#"^ {0,3}\[[^\]\n]+\]:\s*\S+.*$\n?"#, with: "", lines: true)
        // Horizontal rules
        s = s.regexReplacing(#"^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#, with: "", lines: true)
        // Table separator rows go; cells become a comma-separated line.
        s = s.regexReplacing(#"^ {0,3}\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$\n?"#, with: "", lines: true)
        s = s.regexReplacing(#"^ {0,3}\|(.*)\|[ \t]*$"#, lines: true) { groups in
            groups[1].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
        }

        // Headings (and the optional closing hashes)
        s = s.regexReplacing(#"^[ \t]*#{1,6}[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$"#, with: "$1", lines: true)
        // Setext heading underlines ("Title" followed by "=====")
        s = s.regexReplacing(#"^ {0,3}=+[ \t]*$\n?"#, with: "", lines: true)
        // Block quotes, then list markers and task boxes
        s = s.regexReplacing(#"^([ \t]*>)+[ \t]?"#, with: "", lines: true)
        s = s.regexReplacing(#"^([ \t]*)[-*+•◦▪‣][ \t]+(\[[ xX]\][ \t]+)?"#, with: "$1", lines: true)

        s = inlineToPlain(s)

        // Tidy: no trailing spaces, at most one blank line in a row
        s = s.regexReplacing(#"[ \t]+$"#, with: "", lines: true)
        s = s.regexReplacing(#"\n{3,}"#, with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The inline part of `toPlain`: links, code, emphasis, stray symbols, HTML bits and escapes.
    /// Works on a whole text or on one piece of a line, and keeps surrounding spaces.
    public static func inlineToPlain(_ text: String) -> String {
        var s = text
        // Images and links keep their text; bare autolinks keep the address.
        s = s.regexReplacing(#"!\[([^\]\n]*)\]\([^)\n]*\)"#, with: "$1")
        s = s.regexReplacing(#"\[([^\]\n]+)\]\([^)\n]*\)"#, with: "$1")
        s = s.regexReplacing(#"\[([^\]\n]+)\]\[[^\]\n]*\]"#, with: "$1")
        s = s.regexReplacing(#"<((?:https?|mailto):[^>\s]+)>"#, with: "$1")

        // Inline code, then emphasis (bold before italic), strikethrough
        s = s.regexReplacing(#"`+([^`\n]+?)`+"#, with: "$1")
        s = s.regexReplacing(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, with: "$2")
        s = s.regexReplacing(#"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#, with: "$1")
        s = s.regexReplacing(#"(?<![\w_])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])"#, with: "$1")
        s = s.regexReplacing(#"~~(?=\S)(.+?)(?<=\S)~~"#, with: "$1")

        // Leftover symbols the voice would name: stray asterisks (not "5*3"), backticks, heading marks without a
        // space ("##Title"), table pipes and underline runs. Before escapes are resolved, so an escaped "\*" stays a star.
        s = s.regexReplacing(#"(?<![\d\\])\*+|(?<!\\)\*+(?!\d)"#, with: "")
        s = s.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "~~", with: "")
        s = s.regexReplacing(#"^[ \t]*#{1,6}(?=[A-Za-z])"#, with: "", lines: true)
        s = s.regexReplacing(#"[ \t]+\|[ \t]+"#, with: ", ")
        s = s.regexReplacing(#"^[ \t]*\|[ \t]*|[ \t]*\|[ \t]*$"#, with: "", lines: true)
        s = s.regexReplacing(#"_{2,}"#, with: "")

        // A few HTML bits that turn up in Markdown, and backslash escapes
        s = s.regexReplacing(#"<br\s*/?>"#, with: "\n", ignoreCase: true)
        s = s.regexReplacing(#"</?(sup|sub|kbd|em|strong|b|i|u|span|details|summary)\b[^>]*>"#, with: "", ignoreCase: true)
        s = s.regexReplacing(#"\\([\\`*_{}\[\]()#+\-.!|>~])"#, with: "$1")
        return s
    }
}

/// Splits text into pieces small enough to speak one at a time, at natural breaks (Windows' Reading/ReadAloudText.cs).
/// Ranges are in UTF-16 units, like the voice's word ranges.
public enum ReadAloudText {
    /// The longest piece, in characters.
    public static let maxPieceChars = 260
    /// About 165 words a minute for typical English text, at 1×; used until the voice has read some of the text.
    public static let defaultSecondsPerChar = 0.066

    /// Text is read as plain text: Markdown (headings, lists, emphasis, links, code fences) and stray symbols are dropped.
    public static func plain(_ s: String) -> String { MarkdownText.forReading(s) }

    /// Sentences (and lines, for lists and headings), with long ones broken at commas or spaces.
    /// Pieces without any letter or digit are skipped.
    public static func split(_ text: String) -> [NSRange] {
        let ns = text as NSString
        var spans: [NSRange] = []
        var start = 0
        // A sentence ends after . ! ? … (and any closing quotes or brackets) followed by space, or at a line break.
        for m in sentenceEnd.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            addPiece(ns, start, m.range.location, &spans)
            start = m.range.location + m.range.length
        }
        addPiece(ns, start, ns.length, &spans)
        return spans
    }

    /// The words of a piece for the voice: its line breaks and runs of spaces collapsed.
    public static func speakable(_ text: String, _ span: NSRange) -> String {
        (text as NSString).substring(with: span).regexReplacing(#"\s+"#, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// How many words a text has, as the usage counts them.
    public static func words(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    private static let sentenceEnd = try! NSRegularExpression(pattern: #"(?<=[.!?…]{1,20}["'”’)\]]{0,20})\s+|\n\s*"#)

    private static func addPiece(_ text: NSString, _ start: Int, _ end: Int, _ spans: inout [NSRange]) {
        var (start, end) = (start, end)
        while start < end, isSpace(text.character(at: start)) { start += 1 }
        while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
        while end - start > maxPieceChars {
            let cut = breakPoint(text, start, start + maxPieceChars)
            addIfSpoken(text, start, cut, &spans)
            start = cut
            while start < end, isSpace(text.character(at: start)) { start += 1 }
        }
        addIfSpoken(text, start, end, &spans)
    }

    /// Where to break an over-long sentence: after the last comma, semicolon, colon or dash, else the last space.
    private static func breakPoint(_ text: NSString, _ start: Int, _ limit: Int) -> Int {
        var i = limit - 1
        while i > start + maxPieceChars / 3 {
            if [",", ";", ":", "—", "–"].contains(Character(UnicodeScalar(text.character(at: i)) ?? " ")),
               i + 1 < text.length, isSpace(text.character(at: i + 1)) { return i + 1 }
            i -= 1
        }
        let space = text.range(of: " ", options: .backwards, range: NSRange(location: start, length: limit - start)).location
        return space != NSNotFound && space > start ? space : limit
    }

    private static func addIfSpoken(_ text: NSString, _ start: Int, _ end: Int, _ spans: inout [NSRange]) {
        guard end > start else { return }
        let piece = text.substring(with: NSRange(location: start, length: end - start))
        if piece.unicodeScalars.contains(where: isLetterOrDigit) {
            spans.append(NSRange(location: start, length: end - start))
        }
    }

    /// .NET's char.IsLetterOrDigit: letters (L*) and decimal digits (Nd); not marks, "²", "½" or "Ⅻ".
    static func isLetterOrDigit(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: true
        default: false
        }
    }

    static func isSpace(_ c: unichar) -> Bool {
        UnicodeScalar(c).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }
}

extension String {
    /// .NET-style `Regex.Replace` with ICU patterns (which, unlike Swift's regex literals, have lookbehind).
    func regexReplacing(_ pattern: String, with template: String, lines: Bool = false, ignoreCase: Bool = false) -> String {
        let re = Self.regex(pattern, lines: lines, ignoreCase: ignoreCase)
        return re.stringByReplacingMatches(in: self, range: NSRange(location: 0, length: (self as NSString).length), withTemplate: template)
    }

    /// The same, with each match's replacement worked out from its groups (index 0 = the whole match).
    func regexReplacing(_ pattern: String, lines: Bool = false, by replacement: ([String]) -> String) -> String {
        let re = Self.regex(pattern, lines: lines, ignoreCase: false)
        let ns = self as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
            out += replacement(groups)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    private static func regex(_ pattern: String, lines: Bool, ignoreCase: Bool) -> NSRegularExpression {
        var options: NSRegularExpression.Options = []
        if lines { options.insert(.anchorsMatchLines) }
        if ignoreCase { options.insert(.caseInsensitive) }
        return try! NSRegularExpression(pattern: pattern, options: options)
    }
}
