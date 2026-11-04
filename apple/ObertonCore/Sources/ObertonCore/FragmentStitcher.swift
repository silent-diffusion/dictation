import Foundation

/// Joins the pieces the recognizer settles one at a time into one text, without the AI (Windows' `FragmentStitcher`).
/// Each piece is transcribed on its own, so its seams show the usual artifacts: a piece cut mid-sentence still starts
/// with a capital ("…went to the | Store and…"), one cut at a pause may end in a full stop that isn't one
/// ("…the store. | and bought…"), and a word said across the cut can come out twice ("…the | the store…").
public enum FragmentStitcher {
    /// Words that are lowercase mid-sentence. A capitalized word at a cut is lowercased only if it is one of these, or
    /// appears lowercase elsewhere in the dictation; anything else might be a name, so it keeps its capital.
    static let commonWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "nor", "so", "yet", "for", "because", "if", "then", "than", "that", "this",
        "these", "those", "which", "who", "whom", "whose", "what", "when", "where", "while", "why", "how", "as", "at",
        "by", "from", "in", "into", "of", "on", "onto", "to", "with", "without", "about", "after", "before", "over",
        "under", "up", "down", "out", "off", "through", "between", "during", "since", "until", "it", "its", "it's",
        "we", "you", "he", "she", "they", "them", "us", "him", "her", "his", "our", "your", "their", "my", "me",
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "have", "has", "had", "will",
        "would", "can", "could", "should", "shall", "may", "might", "must", "not", "no", "yes", "also", "just",
        "really", "very", "maybe", "probably", "actually", "basically", "like", "well", "now", "there", "here",
        "some", "any", "all", "each", "every", "both", "either", "neither", "more", "most", "much", "many", "other",
        "another", "such", "only", "even", "still", "again", "too", "already", "though", "although", "unless",
        "whether", "get", "got", "go", "going", "make", "made", "say", "said", "think", "know", "want", "need",
        "one", "two", "three", "first", "next", "last", "new", "good", "lot", "thing", "things", "way", "time",
    ]

    static let abbreviations: Set<String> = [
        "e.g.", "i.e.", "etc.", "vs.", "mr.", "mrs.", "ms.", "dr.", "st.", "no.", "approx.", "a.m.", "p.m.",
    ]

    /// Join pieces transcribed separately, in order, fixing what the cuts between them broke.
    public static func join(_ pieces: [String]) -> String {
        let everything = pieces.joined(separator: " ")
        var out = ""
        for raw in pieces {
            var piece = raw.replacing(#/[ \t]+/#, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.isEmpty { continue }
            if out.isEmpty { out = piece; continue }

            piece = dropRepeatedWord(before: out, piece: piece)
            if piece.isEmpty { continue }

            let last = lastMeaningfulChar(out)
            if last.isLetter || last.isNumber || ",;-—–".contains(last) {
                // Cut mid-sentence: the next piece continues it.
                if lowercaseAtCut(piece, everything: everything) { piece = piece.prefix(1).lowercased() + piece.dropFirst() }
            } else if last == ".", firstLetter(piece)?.isLowercase == true, !endsWithAbbreviationOrEllipsis(out) {
                // A full stop the recognizer added at the cut, before words that clearly continue the sentence.
                out = String(out.reversed().drop(while: \.isWhitespace).reversed())
                if out.hasSuffix(".") { out.removeLast() }
            }
            out += " " + piece
        }
        return tidy(out)
    }

    static func lowercaseAtCut(_ piece: String, everything: String) -> Bool {
        let word = String(piece.prefix { $0.isLetter || $0 == "'" })
        guard let first = word.first, first.isUppercase, !word.dropFirst().contains(where: \.isUppercase) else { return false } // NASA, iPhone
        if word == "I" || word.hasPrefix("I'") { return false }
        if commonWords.contains(word.lowercased()) { return true }
        let lower = word.prefix(1).lowercased() + word.dropFirst()
        return everything.range(of: "\\b" + NSRegularExpression.escapedPattern(for: lower) + "\\b", options: .regularExpression) != nil
    }

    /// Spacing around punctuation, and a capital at the very start.
    public static func tidy(_ text: String) -> String {
        var s = text.replacing(#/[ \t]+/#, with: " ")
        s = s.replacing(#/ +([,.!?;:])/#) { String($0.output.1) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = s.first, f.isLowercase { s = f.uppercased() + s.dropFirst() }
        return s
    }

    /// "…the" + "the store" → "store": the same word on both sides of a cut was said once.
    static func dropRepeatedWord(before: String, piece: String) -> String {
        // Only when nothing ends the sentence in between ("…the. The…" is two sentences).
        if before.firstMatch(of: #/[.!?]\W*$/#) != nil { return piece }
        // `\b` as .NET reads it (between a word character and any other), not Swift's default Unicode word rule, which
        // keeps "3.5" as one word: "version 3" + "3.5 percent" drops the repeated "3" on both.
        guard let lastWord = before.firstMatch(of: #/([\p{L}\p{N}']+)\W*$/#)?.output.1,
              let first = piece.firstMatch(of: #/^([\p{L}\p{N}']+)\b,?\s*/#.wordBoundaryKind(.simple)) else { return piece }
        return lastWord.lowercased() == first.output.1.lowercased() ? String(piece[first.range.upperBound...]) : piece
    }

    static func lastMeaningfulChar(_ s: String) -> Character {
        let t = s.reversed().drop(while: \.isWhitespace).drop(while: { "\"'”’)".contains($0) })
        return t.first ?? "\0"
    }

    static func firstLetter(_ s: String) -> Character? { s.first(where: \.isLetter) }

    static func endsWithAbbreviationOrEllipsis(_ s: String) -> Bool {
        let t = String(s.reversed().drop(while: \.isWhitespace).reversed())
        if t.hasSuffix("..") || t.hasSuffix("…") { return true }
        let lastToken = String(t.split(separator: " ").last ?? "")
        return abbreviations.contains(lastToken.lowercased()) || lastToken.wholeMatch(of: #/(?:\p{L}\.){2,}/#) != nil // U.S.
    }
}
