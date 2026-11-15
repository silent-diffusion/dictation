import Foundation

/// English text → phonemes for Kokoro and Piper. Windows phonemizes with espeak-ng (through kokoro-onnx); the Mac
/// can't ship espeak-ng (GPL) in the App Store build, so it follows misaki instead, the phonemizer Kokoro was trained
/// with (hexgrad/misaki `en.py`, Apache 2.0): its gold and silver dictionaries (downloaded with the voice), its rules
/// for -s, -ed and -ing, a/an/the/to/I, numbers and acronyms, and stress. Words in no dictionary get simple
/// spelling rules (misaki uses a neural fallback there). misaki's part-of-speech tagging is left out: a word with
/// several readings ("read") takes its usual one. Piper wants espeak-style IPA; `espeak(_:british:)` converts.
public final class Phonemizer: @unchecked Sendable {
    public let british: Bool
    private var golds: [String: String] = [:]
    private var silvers: [String: String] = [:]

    /// The dictionaries for one accent, loaded once each and kept while a voice is in memory.
    private static let cache = NSLock()
    nonisolated(unsafe) private static var loaded: [Bool: Phonemizer] = [:]

    public static func shared(british: Bool) throws -> Phonemizer {
        try cache.withLock {
            if let p = loaded[british] { return p }
            let p = try Phonemizer(british: british, directory: VoiceInstaller.lexiconDir)
            loaded[british] = p
            return p
        }
    }

    /// Let the dictionaries go (with the voices; Settings › Model unloading).
    public static func unload() { cache.withLock { loaded = [:] } }

    public init(british: Bool, directory: URL) throws {
        self.british = british
        let prefix = british ? "gb" : "us"
        golds = try Self.load(directory.appending(path: "\(prefix)_gold.json"))
        silvers = try Self.load(directory.appending(path: "\(prefix)_silver.json"))
    }

    /// For tests: dictionaries given directly.
    init(british: Bool, golds: [String: String], silvers: [String: String] = [:]) {
        self.british = british
        self.golds = Self.grow(golds)
        self.silvers = Self.grow(silvers)
    }

    private static func load(_ url: URL) throws -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // The dictionary is part of the voice download here (Windows' phonemizer comes with its engine): its
            // load-failure text.
            throw UserFacingError("The voice model could not be loaded. Try downloading the voice again under Read aloud.")
        }
        var out: [String: String] = [:]
        out.reserveCapacity(json.count)
        for (k, v) in json {
            if let s = v as? String { out[k] = s }
            else if let d = v as? [String: Any], let s = d["DEFAULT"] as? String { out[k] = s }
        }
        return grow(out)
    }

    /// misaki's grow_dictionary: "hello" is also found as "Hello", and "London" as "london".
    private static func grow(_ d: [String: String]) -> [String: String] {
        var e: [String: String] = [:]
        for (k, v) in d where k.count >= 2 {
            if k == k.lowercased() {
                let cap = k.prefix(1).uppercased() + k.dropFirst()
                if k != cap { e[cap] = v }
            } else if k == k.lowercased().prefix(1).uppercased() + k.lowercased().dropFirst() {
                e[k.lowercased()] = v
            }
        }
        return e.merging(d) { _, new in new }
    }

    // MARK: Phonemes for Kokoro

    /// Kokoro v1.0's phonemes for a piece of text (misaki's `G2P(version=None)`: flaps as "T", glottal stops as "t").
    public func kokoro(_ text: String) -> String {
        raw(text).replacingOccurrences(of: "ɾ", with: "T").replacingOccurrences(of: "ʔ", with: "t")
    }

    /// Piper's phonemes: espeak-ng's way of writing the same sounds.
    public func piper(_ text: String) -> String { Self.espeak(raw(text), british: british) }

    // MARK: Tokens

    private enum Token { case word(String), number(String, currency: Character?), punct(String), space, hyphen }

    static let puncts: Set<Character> = [";", ":", ",", ".", "!", "?", "—", "…", "\"", "“", "”"]
    private static let symbols: [Character: String] = ["%": "percent", "&": "and", "+": "plus", "@": "at"]
    private static let currencies: [Character: (String, String)] = ["$": ("dollar", "cent"), "£": ("pound", "pence"), "€": ("euro", "cent")]

    private static let tokenRegex = try! NSRegularExpression(pattern:
        #"[$£€]?(?:(?<=^|\s)-)?\d+(?:,\d{3})*(?:\.\d+)?(?:st|nd|rd|th|s|'s|ed|ing)?|\p{L}+(?:['’]\p{L}+)*['’]?|\s+|."#)

    private func tokenize(_ text: String) -> [Token] {
        let ns = text as NSString
        var out: [Token] = []
        for m in Self.tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let t = ns.substring(with: m.range)
            guard let first = t.first else { continue }
            if first.isWhitespace { out.append(.space); continue }
            if first.isNumber || (t.count > 1 && (Self.currencies[first] != nil || first == "-") && t.dropFirst().first(where: { $0 != "-" })?.isNumber == true) {
                if let c = Self.currencies[first] != nil ? first : nil { out.append(.number(String(t.dropFirst()), currency: c)) }
                else { out.append(.number(t, currency: nil)) }
            } else if first.isLetter {
                out.append(.word(t.replacingOccurrences(of: "’", with: "'")))
            } else if Self.puncts.contains(first) {
                out.append(.punct(String(first)))
            } else if first == "-" || first == "–" {
                // A dash between words is a pause; a hyphen inside a word ("well-known") just joins it.
                out.append(first == "-" ? .hyphen : .punct("—"))
            } else if let s = Self.symbols[first] {
                out.append(.word(s))
            } else if first == "(" || first == ")" {
                out.append(.punct(","))
            }
            // Anything else (/, #, *, emoji…) is not spoken.
        }
        return out
    }

    /// misaki's phonemes before the version-specific flap step.
    func raw(_ text: String) -> String {
        let tokens = tokenize(text.precomposedStringWithCompatibilityMapping)
        var parts = [String](repeating: "", count: tokens.count)
        // Right to left, as misaki: "the" and "to" depend on whether a vowel comes next.
        var futureVowel: Bool?
        for i in tokens.indices.reversed() {
            switch tokens[i] {
            case .space:
                parts[i] = " "
            case .hyphen:
                let joined = i > 0 && i + 1 < tokens.count && !Self.isGap(tokens[i - 1]) && !Self.isGap(tokens[i + 1])
                parts[i] = joined ? " " : "—"
                if !joined { futureVowel = nil }
            case .punct(let p):
                parts[i] = p
                if p != "\"" && p != "“" && p != "”" { futureVowel = nil }
            case .number(let n, let currency):
                let ps = number(n, currency: currency)
                parts[i] = ps
                futureVowel = Self.startsWithVowel(ps) ?? futureVowel
            case .word(let w):
                let ps = word(w, futureVowel: futureVowel) ?? fallback(w)
                parts[i] = ps
                futureVowel = Self.startsWithVowel(ps) ?? futureVowel
            }
        }
        // Spaces collapse, and none before punctuation that closes ("word ," → "word,").
        var out = ""
        for (i, p) in parts.enumerated() {
            if p == " " {
                if out.isEmpty || out.hasSuffix(" ") { continue }
                if i + 1 < parts.count, let next = parts[i + 1].first, [",", ".", ";", ":", "!", "?", "…"].contains(next) { continue }
            }
            if p.isEmpty { continue }
            // Two words with nothing between them ("25%", "R2D2") still need a space.
            if let last = out.last, let first = p.first, Self.isPhoneme(last), Self.isPhoneme(first) { out += " " }
            out += p
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func isGap(_ t: Token) -> Bool {
        switch t { case .space, .punct, .hyphen: true; default: false }
    }

    private static func isPhoneme(_ c: Character) -> Bool { !c.isWhitespace && !puncts.contains(c) }

    private static func startsWithVowel(_ ps: String) -> Bool? {
        for c in ps {
            if vowels.contains(c) { return true }
            if consonants.contains(c) { return false }
            if puncts.contains(c) { return nil }
        }
        return nil
    }

    // MARK: Words (misaki's Lexicon)

    static let vowels: Set<Character> = Set("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")
    static let consonants: Set<Character> = Set("bdfhjklmnpstvwzðŋɡɹɾʃʒʤʧθ")
    static let primary: Character = "ˈ", secondary: Character = "ˌ"
    private static let usTaus: Set<Character> = Set("AIOWYiuæɑəɛɪɹʊʌ")

    func word(_ raw: String, futureVowel: Bool?) -> String? {
        var w = raw
        let stress: Double? = w == w.lowercased() ? nil : (w == w.uppercased() ? 2 : 0.5)
        if let special = special(w, futureVowel: futureVowel) { return special }
        let wl = w.lowercased()
        if w.count > 1, w != wl, golds[w] == nil, silvers[w] == nil,
           w == w.uppercased() || w.dropFirst() == w.dropFirst().lowercased(),
           golds[wl] != nil || silvers[wl] != nil || stemS(wl, nil) != nil || stemEd(wl, nil) != nil || stemIng(wl, nil) != nil {
            w = wl
        }
        if isKnown(w) { return lookup(w, stress) }
        if w.hasSuffix("s'"), isKnown(String(w.dropLast(2)) + "'s") { return lookup(String(w.dropLast(2)) + "'s", stress) }
        if w.hasSuffix("'"), isKnown(String(w.dropLast())) { return lookup(String(w.dropLast()), stress) }
        if let s = stemS(w, stress) { return s }
        if let s = stemEd(w, stress) { return s }
        if let s = stemIng(w, stress ?? 0.5) { return s }
        return nil
    }

    private func special(_ w: String, futureVowel: Bool?) -> String? {
        switch w {
        case "a", "A": return "ɐ"
        case "an", "An", "AN": return "ɐn"
        case "I": return "ˌI"
        case "to", "To", "TO":
            guard let fv = futureVowel else { return golds["to"] }
            return fv ? "tʊ" : "tə"
        case "the", "The", "THE": return futureVowel == true ? "ði" : "ðə"
        case "in", "In", "IN": return "ɪn"
        case "am", "Am": return futureVowel == nil ? golds["am"] : "ɐm"
        default:
            // "U.S.", "e.g.": letters with dots.
            let letters = w.replacingOccurrences(of: ".", with: "")
            if w.contains("."), letters.allSatisfy(\.isLetter), w.split(separator: ".").allSatisfy({ $0.count < 3 }) { return spellOut(letters) }
            return nil
        }
    }

    private func isKnown(_ w: String) -> Bool {
        if golds[w] != nil || silvers[w] != nil { return true }
        guard w.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'" || $0 == "-") }) else { return false }
        if w.count == 1 { return true }
        if w == w.uppercased(), golds[w.lowercased()] != nil { return true }
        return w.dropFirst() == w.dropFirst().uppercased() // an acronym: spelled out
    }

    private func lookup(_ word: String, _ stress: Double?) -> String? {
        var w = word
        if w == w.uppercased(), golds[w] == nil { w = w.lowercased() }
        guard let ps = golds[w] ?? silvers[w] else { return spellOut(word) }
        return Self.applyStress(ps, stress)
    }

    /// Letter by letter ("USA" → "jˌuˌɛsˈA"), stress on the last.
    private func spellOut(_ word: String) -> String? {
        var ps = ""
        for c in word where c.isLetter {
            guard let p = golds[String(c).uppercased()] else { return nil }
            ps += p
        }
        let s = Self.applyStress(ps, 0)
        guard let r = s.range(of: String(Self.secondary), options: .backwards) else { return s }
        return s.replacingCharacters(in: r, with: String(Self.primary))
    }

    private func suffixS(_ stem: String?) -> String? {
        guard let stem, let last = stem.last else { return nil }
        if "ptkfθ".contains(last) { return stem + "s" }
        if "szʃʒʧʤ".contains(last) { return stem + (british ? "ɪ" : "ᵻ") + "z" }
        return stem + "z"
    }

    private func stemS(_ w: String, _ stress: Double?) -> String? {
        guard w.count >= 3, w.hasSuffix("s") else { return nil }
        let stem: String
        if !w.hasSuffix("ss"), isKnown(String(w.dropLast())) { stem = String(w.dropLast()) }
        else if w.hasSuffix("'s") || (w.count > 4 && w.hasSuffix("es") && !w.hasSuffix("ies")), isKnown(String(w.dropLast(2))) { stem = String(w.dropLast(2)) }
        else if w.count > 4, w.hasSuffix("ies"), isKnown(String(w.dropLast(3)) + "y") { stem = String(w.dropLast(3)) + "y" }
        else { return nil }
        return suffixS(lookup(stem, stress))
    }

    private func suffixEd(_ stem: String?) -> String? {
        guard let stem, let last = stem.last else { return nil }
        if "pkfθʃsʧ".contains(last) { return stem + "t" }
        if last == "d" { return stem + (british ? "ɪ" : "ᵻ") + "d" }
        if last != "t" { return stem + "d" }
        if british || stem.count < 2 { return stem + "ɪd" }
        if Self.usTaus.contains(stem[stem.index(stem.endIndex, offsetBy: -2)]) { return stem.dropLast() + "ɾᵻd" }
        return stem + "ᵻd"
    }

    private func stemEd(_ w: String, _ stress: Double?) -> String? {
        guard w.count >= 4, w.hasSuffix("d") else { return nil }
        let stem: String
        if !w.hasSuffix("dd"), isKnown(String(w.dropLast())) { stem = String(w.dropLast()) }
        else if w.count > 4, w.hasSuffix("ed"), !w.hasSuffix("eed"), isKnown(String(w.dropLast(2))) { stem = String(w.dropLast(2)) }
        else { return nil }
        return suffixEd(lookup(stem, stress))
    }

    private func suffixIng(_ stem: String?) -> String? {
        guard let stem, let last = stem.last else { return nil }
        if british { if "əː".contains(last) { return nil } }
        else if stem.count > 1, last == "t", Self.usTaus.contains(stem[stem.index(stem.endIndex, offsetBy: -2)]) { return stem.dropLast() + "ɾɪŋ" }
        return stem + "ɪŋ"
    }

    private func stemIng(_ w: String, _ stress: Double?) -> String? {
        guard w.count >= 5, w.hasSuffix("ing") else { return nil }
        let base = String(w.dropLast(3))
        let stem: String
        if w.count > 5, isKnown(base) { stem = base }
        else if isKnown(base + "e") { stem = base + "e" }
        else if w.count > 5, w.range(of: #"([bcdgklmnprstvxz])\1ing$|cking$"#, options: .regularExpression) != nil, isKnown(String(w.dropLast(4))) {
            stem = String(w.dropLast(4))
        } else { return nil }
        return suffixIng(lookup(stem, stress))
    }

    /// misaki's apply_stress.
    static func applyStress(_ ps: String, _ stress: Double?) -> String {
        guard let stress else { return ps }
        let hasPrimary = ps.contains(primary), hasSecondary = ps.contains(secondary)
        let hasVowel = ps.contains { vowels.contains($0) }
        if stress < -1 { return ps.filter { $0 != primary && $0 != secondary } }
        if stress == -1 || ((stress == 0 || stress == -0.5) && hasPrimary) {
            return String(ps.filter { $0 != secondary }.map { $0 == primary ? secondary : $0 })
        }
        if [0, 0.5, 1].contains(stress), !hasPrimary, !hasSecondary {
            return hasVowel ? restress(String(secondary) + ps) : ps
        }
        if stress >= 1, !hasPrimary, hasSecondary { return String(ps.map { $0 == secondary ? primary : $0 }) }
        if stress > 1, !hasPrimary, !hasSecondary { return hasVowel ? restress(String(primary) + ps) : ps }
        return ps
    }

    /// A stress mark moves to just before the next vowel.
    private static func restress(_ ps: String) -> String {
        var chars = Array(ps)
        var i = 0
        while i < chars.count {
            if chars[i] == primary || chars[i] == secondary, let j = chars[i...].firstIndex(where: { vowels.contains($0) }), j > i + 1 {
                let mark = chars.remove(at: i)
                chars.insert(mark, at: j - 1)
            }
            i += 1
        }
        return String(chars)
    }

    // MARK: Numbers

    private static let spell: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .spellOut
        return f
    }()

    private func number(_ token: String, currency: Character?) -> String {
        var t = token
        var suffix = ""
        for s in ["'s", "st", "nd", "rd", "th", "ing", "ed", "s"] where t.hasSuffix(s) && t.count > s.count {
            suffix = s
            t = String(t.dropLast(s.count))
            break
        }
        var words: [String] = []
        if t.hasPrefix("-") { words.append("minus"); t.removeFirst() }
        let plain = t.replacingOccurrences(of: ",", with: "")
        if ["st", "nd", "rd", "th"].contains(suffix), let n = Int(plain) {
            words += Self.ordinal(Self.spell.string(from: NSNumber(value: n)) ?? plain)
        } else if currency == nil, words.isEmpty, t.count == 4, let n = Int(t), !t.hasPrefix("0") {
            words += Self.year(n)
        } else if let c = currency.flatMap({ Self.currencies[$0] }) {
            let halves = plain.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
            let main = halves.first ?? 0, cents = halves.count > 1 ? halves[1] : 0
            if main != 0 || cents == 0 {
                words += Self.cardinal(main)
                words.append(main == 1 ? c.0 : c.0 + "s")
            }
            if cents != 0 {
                if main != 0 { words.append("and") }
                words += Self.cardinal(cents)
                words.append(cents == 1 || c.1 == "pence" ? c.1 : c.1 + "s")
            }
        } else if plain.contains(".") {
            let halves = plain.split(separator: ".", omittingEmptySubsequences: false)
            if let whole = Int(halves[0]) { words += Self.cardinal(whole) }
            words.append("point")
            for d in halves.dropFirst().joined() { if let n = Int(String(d)) { words += Self.cardinal(n) } }
        } else if let n = Int(plain) {
            words += Self.cardinal(n)
        } else {
            for d in plain where d.isNumber { if let n = Int(String(d)) { words += Self.cardinal(n) } }
        }
        let ps = words.map { w in (w == "point" ? lookup(w, -2) : word(w, futureVowel: nil)) ?? fallback(w) }.joined(separator: " ")
        switch suffix {
        case "s", "'s": return suffixS(ps) ?? ps
        case "ed": return suffixEd(ps) ?? ps
        case "ing": return suffixIng(ps) ?? ps
        default: return ps
        }
    }

    static func cardinal(_ n: Int) -> [String] {
        (spell.string(from: NSNumber(value: n)) ?? String(n)).split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// 1984 → nineteen eighty-four; 2005 → two thousand five; 2024 → twenty twenty-four.
    static func year(_ n: Int) -> [String] {
        if n % 1000 < 10 || (n >= 2000 && n < 2010) { return cardinal(n) }
        let hi = n / 100, lo = n % 100
        return cardinal(hi) + (lo == 0 ? ["hundred"] : lo < 10 ? ["O"] + cardinal(lo) : cardinal(lo))
    }

    static func ordinal(_ spelled: String) -> [String] {
        var words = spelled.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let last = words.popLast() else { return [] }
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth", "nine": "ninth", "twelve": "twelfth"]
        let o = irregular[last] ?? (last.hasSuffix("y") ? String(last.dropLast()) + "ieth" : last + "th")
        return words + [o]
    }

    // MARK: Words in no dictionary

    /// Spelling rules for a word in no dictionary (names, made-up words), then stress on the first vowel. Rough, but
    /// close enough to be understood; misaki uses a small neural network here.
    func fallback(_ word: String) -> String {
        let w = word.lowercased().filter { $0.isLetter || $0 == "'" }
        guard !w.isEmpty else { return "" }
        // A short all-caps word is an acronym: spell it.
        if word.count <= 4, word == word.uppercased(), word.count > 1, let s = spellOut(word) { return s }
        let chars = Array(w)
        var out = ""
        var i = 0
        func isVowel(_ c: Character?) -> Bool { c.map { "aeiouy".contains($0) } ?? false }
        while i < chars.count {
            let rest = String(chars[i...])
            if let (g, p) = Self.graphemes.first(where: { rest.hasPrefix($0.0) }) {
                out += p
                i += g.count
                continue
            }
            let c = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            switch c {
            case "c": out += next.map { "eiy".contains($0) } == true ? "s" : "k"
            case "g": out += next.map { "eiy".contains($0) } == true && i > 0 ? "ʤ" : "ɡ"
            case "e" where i == chars.count - 1 && i > 1: break // silent final e
            case "y": out += i == 0 ? "j" : i == chars.count - 1 ? "i" : "ɪ"
            case "'": break
            case "a", "e", "i", "o", "u":
                // Magic e: a vowel, one consonant, then a final e (made → mAd).
                if let long = Self.longVowels[c], i + 3 == chars.count, !isVowel(chars[i + 1]), chars[i + 2] == "e" { out += long }
                else { out += Self.letters[c] ?? "" }
            default: out += Self.letters[c] ?? ""
            }
            i += 1
        }
        guard let v = out.firstIndex(where: { Self.vowels.contains($0) }) else { return out }
        out.insert(Self.primary, at: v)
        return out
    }

    /// Longest first.
    private static let graphemes: [(String, String)] = [
        ("tion", "ʃən"), ("sion", "ʒən"), ("ough", "O"), ("eigh", "A"), ("augh", "ɔ"), ("igh", "I"), ("tch", "ʧ"),
        ("sch", "sk"), ("ture", "ʧəɹ"), ("ph", "f"), ("th", "θ"), ("sh", "ʃ"), ("ch", "ʧ"), ("ck", "k"), ("ng", "ŋ"),
        ("qu", "kw"), ("wh", "w"), ("wr", "ɹ"), ("kn", "n"), ("gh", "ɡ"), ("ee", "i"), ("ea", "i"), ("oo", "u"),
        ("ai", "A"), ("ay", "A"), ("ei", "A"), ("ey", "A"), ("oa", "O"), ("ow", "W"), ("ou", "W"), ("oi", "Y"),
        ("oy", "Y"), ("au", "ɔ"), ("aw", "ɔ"), ("ie", "i"), ("ue", "u"), ("ew", "u"), ("ar", "ɑɹ"), ("or", "ɔɹ"),
        ("er", "əɹ"), ("ir", "ɜɹ"), ("ur", "ɜɹ"), ("ll", "l"), ("ss", "s"), ("tt", "t"), ("pp", "p"), ("mm", "m"),
        ("nn", "n"), ("rr", "ɹ"), ("ff", "f"), ("dd", "d"), ("bb", "b"), ("gg", "ɡ"), ("zz", "z"), ("x", "ks"),
    ]
    private static let longVowels: [Character: String] = ["a": "A", "e": "i", "i": "I", "o": "O", "u": "u"]
    private static let letters: [Character: String] = [
        "a": "æ", "b": "b", "d": "d", "e": "ɛ", "f": "f", "h": "h", "i": "ɪ", "j": "ʤ", "k": "k", "l": "l", "m": "m",
        "n": "n", "o": "ɑ", "p": "p", "q": "k", "r": "ɹ", "s": "s", "t": "t", "u": "ʌ", "v": "v", "w": "w", "z": "z",
    ]

    // MARK: espeak-style IPA for Piper

    /// misaki's phonemes written as espeak-ng writes them, for Piper's phoneme table: its letters for diphthongs and
    /// affricates spelled out, long vowels marked where espeak marks them, r-coloured vowels.
    public static func espeak(_ ps: String, british: Bool) -> String {
        var out = ""
        let chars = Array(ps)
        for (i, c) in chars.enumerated() {
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            let stressed = prev == primary || prev == secondary
            switch c {
            case "A": out += "eɪ"
            case "I": out += "aɪ"
            case "W": out += "aʊ"
            case "Y": out += "ɔɪ"
            case "O": out += british ? "əʊ" : "oʊ"
            case "Q": out += "əʊ"
            case "ʤ": out += "dʒ"
            case "ʧ": out += "tʃ"
            case "ᵊ": out += "ə"
            case "ᵻ": out += "ɪ"
            case "T": out += "ɾ"
            case "ɜ" where !british && next == "ɹ": out += "ɜː"
            case "ɹ" where !british && prev == "ɜ": break
            case "ə" where !british && next == "ɹ" && !stressed: out += "ɚ"
            case "ɹ" where !british && prev == "ə" && !(i >= 2 && (chars[i - 2] == primary || chars[i - 2] == secondary)): break
            default:
                // Long vowels espeak marks: stressed i, u, ɑ, ɔ in American English.
                if !british && stressed && next != "ː" && "iuɑɔ".contains(c) { out += String(c) + "ː" } else { out.append(c) }
            }
        }
        return out
    }
}
