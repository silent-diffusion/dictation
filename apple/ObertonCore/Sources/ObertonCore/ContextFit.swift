import Foundation

/// The text immediately around the caret in the target app (Windows `InsertionContext`). Only a sentence or two on
/// each side is kept. Nothing on the Mac reads it yet: the App Store sandbox can't read other apps' text, so the
/// "Fit dictation into the surrounding text" setting has no source. The rules are here for whatever source comes
/// (an iOS keyboard's document context, or a non-sandboxed Mac build).
public struct InsertionContext: Equatable, Sendable {
    public var before: String
    public var after: String

    public init(before: String, after: String) {
        self.before = before
        self.after = after
    }

    /// Without the invisible characters editors leave around (zero-width spaces, BOM, object replacement).
    public static func visible(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: s.unicodeScalars.filter { !(0x200B...0x200D).contains($0.value) && ![0x2060, 0xFEFF, 0xFFFC].contains($0.value) })
        return String(scalars)
    }

    /// Equal once editors' substitutions are undone: line-break styles, non-breaking spaces, smart quotes.
    public static func sameText(_ inDocument: String, _ typed: String) -> Bool {
        func n(_ s: String) -> String {
            s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
                .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        }
        return n(inDocument) == n(typed)
    }

    private static let sentenceStarts = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+|\n"#)
    private static let sentenceEnd = try! NSRegularExpression(pattern: #"[.!?](\s|$)|\n"#)

    /// Keep at most the last two sentences before the caret and the first sentence after it.
    public static func trim(before: String, after: String) -> InsertionContext {
        var before = visible(before) as NSString
        var after = visible(after) as NSString
        // Only blanks before the caret: still the start of the text.
        if (before as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { before = "" }
        let starts = sentenceStarts.matches(in: before as String, range: NSRange(location: 0, length: before.length))
            .map { $0.range.location + $0.range.length }
        if starts.count >= 2 { before = before.substring(from: starts[starts.count - 2]) as NSString }
        if let end = sentenceEnd.firstMatch(in: after as String, range: NSRange(location: 0, length: after.length)) {
            after = after.substring(to: end.range.location + 1) as NSString
        }
        return InsertionContext(before: before as String, after: after as String)
    }
}

/// Adjusts dictated text so it fits where it is inserted: capitalization, a trailing period and spacing (Windows
/// `ContextFit`).
public enum ContextFit {
    /// Up to this many words count as a "short phrase" that should not get its own period mid-sentence.
    static let shortPhraseWords = 6

    /// Fit text to its surroundings; `space` only, when `spacingOnly`.
    public static func fit(_ text: String, context: InsertionContext?, spacingOnly: Bool) -> String {
        spacingOnly ? space(text, context: context) : apply(text, context: context)
    }

    public static func apply(_ text: String, context: InsertionContext?) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let context, !text.isEmpty else { return text }
        let before = context.before, after = context.after

        let lastBefore = before.reversed().first { !" \t\u{00A0}".contains($0) }
        let atSentenceStart = lastBefore.map { ".!?".contains($0) || $0.isNewline } ?? true
        let nextChar = after.first { !" \t".contains($0) }

        // Capitalization of the first word
        if atSentenceStart { text = text.prefix(1).uppercased() + text.dropFirst() }
        else if shouldLowercase(text, before: before) { text = text.prefix(1).lowercased() + text.dropFirst() }

        // Trailing period: drop it when the sentence clearly continues, or when a short phrase lands mid-sentence
        // (unless what follows is the start of a new sentence).
        if text.hasSuffix("."), !text.hasSuffix("...") {
            let continues = nextChar.map { $0.isLowercase || $0.isWholeNumber || ",;:.)!?".contains($0) } ?? false
            let shortFragment = !atSentenceStart && isSingleSentence(text) && wordCount(text) <= shortPhraseWords
                && !(nextChar?.isUppercase ?? false)
            if continues || shortFragment { text.removeLast() }
        }
        return space(text, context: context)
    }

    /// Only the spacing part of `apply`: for text that was laid out on purpose (a rewritten email, say), whose
    /// capitalization and punctuation must stay as they are.
    public static func space(_ text: String, context: InsertionContext?) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let context, let first = text.first else { return text }
        // Spacing, so the new words don't run into the old ones
        if let prev = context.before.last, !prev.isWhitespace, !"([{\"“'/-".contains(prev), first.isLetter || first.isNumber {
            text = " " + text
        }
        if let next = context.after.first, next.isLetter || next.isNumber { text += " " }
        return text
    }

    /// Lowercase the first word mid-sentence, unless it looks like a name, an acronym or "I".
    static func shouldLowercase(_ text: String, before: String) -> Bool {
        let first = String(text.prefix { $0.isLetter || $0 == "'" })
        guard let initial = first.first, initial.isUppercase else { return false }
        if first == "I" || first.hasPrefix("I'") { return false }
        if first.dropFirst().contains(where: \.isUppercase) { return false } // NASA, iPhone-style, McDonald
        // A word that is capitalized elsewhere mid-sentence (in the dictation or around it) is probably a name.
        let elsewhere = before + " " + text.dropFirst(first.count)
        return !capitalizedMidSentence(first, in: elsewhere)
    }

    /// `word` appears as a whole word somewhere other than the start of the text or of a sentence.
    private static func capitalizedMidSentence(_ word: String, in s: String) -> Bool {
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var from = s.startIndex
        while let r = s.range(of: word, range: from..<s.endIndex) {
            from = s.index(after: r.lowerBound)
            if r.upperBound < s.endIndex, isWordChar(s[r.upperBound]) { continue }
            guard r.lowerBound > s.startIndex else { continue } // the start of the text
            let preceding = s[..<r.lowerBound]
            if let c = preceding.last, isWordChar(c) { continue }
            if let end = preceding.reversed().first(where: { !$0.isWhitespace }), ".!?".contains(end) { continue }
            return true
        }
        return false
    }

    static func isSingleSentence(_ text: String) -> Bool {
        let core = String(text.reversed().drop { ".!?".contains($0) }.reversed())
        return !core.contains(#/[.!?]\s/#)
    }

    static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }
}
