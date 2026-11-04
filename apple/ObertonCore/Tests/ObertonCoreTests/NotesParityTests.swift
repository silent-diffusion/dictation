import Foundation
import Testing
@testable import ObertonCore

// Extended Notes assertions from the Windows tests (tests/Dictation.Tests/ExtendedNotesTests.cs, NotesUsageTests.cs,
// NotesDocxExportTests.cs, NotesMarkersTests.cs, NotesModelTests.cs) that ExtendedNotesTests.swift and MarkdownTests.swift
// don't cover yet, so both apps hold Extended Notes to the same rules.

/// A seeded generator (SplitMix64), so a "random" test sees the same words every run (Windows' `new Random(7)`).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// .NET's `new Random(seed)` (the seeded, Net5-compatible generator: Knuth's subtractive method), so a test pinned
/// with Windows' seed sees Windows' very numbers.
struct DotNetRandom {
    private var seeds = [Int](repeating: 0, count: 56)
    private var inext = 0, inextp = 21
    private static let big = Int(Int32.max), seed0 = 161_803_398

    init(_ seed: Int32) {
        let subtraction = seed == Int32.min ? Self.big : Int(abs(seed))
        var mj = Self.seed0 - subtraction
        seeds[55] = mj
        var mk = 1
        for i in 1..<55 {
            let ii = (21 * i) % 55
            seeds[ii] = mk
            mk = mj - mk
            if mk < 0 { mk += Self.big }
            mj = seeds[ii]
        }
        for _ in 1..<5 {
            for i in 1..<56 {
                seeds[i] -= seeds[1 + (i + 30) % 55]
                if seeds[i] < 0 { seeds[i] += Self.big }
            }
        }
    }

    private mutating func sample() -> Double {
        inext += 1; if inext >= 56 { inext = 1 }
        inextp += 1; if inextp >= 56 { inextp = 1 }
        var r = seeds[inext] - seeds[inextp]
        if r == Self.big { r -= 1 }
        if r < 0 { r += Self.big }
        seeds[inext] = r
        return Double(r) * (1.0 / Double(Self.big))
    }

    /// `Next(maxValue)`.
    mutating func next(_ maxValue: Int) -> Int { Int(sample() * Double(maxValue)) }
}

/// A local date and time (Windows' `new DateTime(y, m, d, h, min, 0)`).
private func localDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

// MARK: - NotesMixer (ExtendedNotesTests.cs, NotesAudioTests)

@Suite struct NotesMixerParityTests {
    // Windows: Computer_audio_alone_is_padded_with_silence_and_never_clips (TakeComputer(3) == {32767, 0, 0}).
    @Test func computerAudioAloneIsPaddedWithSilenceAndNeverClips() {
        let m = NotesMixer()
        m.addComputer([2])
        let out = m.takeComputer(3)
        #expect(out == [1, 0, 0])
        #expect(out.map { Int16(($0 * 32767).rounded(.toNearestOrEven)) } == [32767, 0, 0])
    }

    // Windows: A_runaway_computer_backlog_is_trimmed_to_a_second.
    @Test func aRunawayComputerBacklogIsTrimmedToASecond() {
        let m = NotesMixer()
        m.addComputer([Float](repeating: 0.25, count: NotesMixer.maxBacklog * 3))
        _ = m.mix(withMic: [Float](repeating: 0, count: 100))
        // After the trim, about a second waits: the next second is still computer audio, then silence.
        let out = m.takeComputer(NotesMixer.maxBacklog + 500)
        #expect(out.contains(0))
        #expect(out[NotesMixer.maxBacklog - 1] == 0.25)
        #expect(out[NotesMixer.maxBacklog] == 0)
    }
}

// MARK: - NoteSession and NotesEdits (ExtendedNotesTests.cs)

@Suite struct NoteSessionParityTests {
    // Windows: Formatting_takes_what_is_new_and_appends_the_ai_output, `UnformattedWords() > 0`.
    @Test func whatArrivedWhileTheAIWorkedIsStillUnformatted() {
        let s = NoteSession()
        s.appendHeard("so the plan is simple", seconds: 0)
        let take = s.beginFormat()!
        s.appendHeard("and then more", seconds: 30) // arrives while the AI works
        s.endFormat(heard: take.heard, sent: take.sent, ai: "The plan is simple.", seconds: take.seconds, failed: false)
        #expect(s.unformattedWords() > 0)
        #expect(s.unformattedWords() == 3)
    }

    // Windows: Notes_typed_before_the_session_are_the_users_own, the SecondsAt assertions.
    @Test func notesTypedBeforeTheSessionHaveNoMomentAndHeardTextHasItsOwn() {
        let s = NoteSession()
        s.set(.transcript, "Agenda: budget\n", source: nil)
        s.appendHeard("so the budget is final", seconds: 2)
        #expect(s.secondsAt(.transcript, 3) == 0)
        #expect(s.secondsAt(.transcript, s.transcript.utf16.count - 1) == 2)
    }

    // Windows: NotesPlaybackTests.Edited_pieces_carry_the_moment_they_were_said.
    @Test func editedPiecesCarryTheMomentTheyWereSaid() {
        let s = NoteSession()
        s.appendHeard("hello there", seconds: 5)
        let t = s.beginFormat()!
        s.endFormat(heard: t.heard, sent: t.sent, ai: "Hello there.", seconds: t.seconds, failed: false)
        s.appendHeard("later words", seconds: 40)
        s.seconds = 60
        let pieces = NotesEdits.build(s)
        #expect(abs(pieces[0].seconds - 5) < 0.001)
        #expect(abs(pieces[pieces.count - 1].seconds - 40) < 0.001)
    }
}

// MARK: - LongDiff (ExtendedNotesTests.cs, LongDiffTests)

@Suite struct LongDiffParityTests {
    static func edits(_ d: [DiffToken]) -> Int { d.filter { $0.kind != .same }.count }

    /// The diff gives back the original (ignoring case and end punctuation) and the edited text word for word.
    static func reproduces(_ a: String, _ b: String, _ d: [DiffToken]) -> Bool {
        func n(_ w: String) -> String { w.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?")).lowercased() }
        return LongDiff.split(a).map(n) == d.filter { $0.kind != .added }.map { n($0.word) }
            && LongDiff.split(b) == d.filter { $0.kind != .removed }.map(\.word)
    }

    // Windows: Matches_the_short_diff (5 cases).
    @Test(arguments: [
        ("the cat sat on the mat", "the cat sat on a mat"),
        ("um so we ship it on Monday", "We ship it on Tuesday."),
        ("a b c d e f", "x a c d y f z"),
        ("", "new words here"),
        ("old words gone", ""),
    ])
    func matchesTheShortDiff(a: String, b: String) {
        let d = LongDiff.compute(a, b)
        #expect(Self.reproduces(a, b, d))
        #expect(Self.edits(WordDiff.compute(a, b)) == Self.edits(d)) // just as few changes
    }

    // Windows: Copes_with_ten_thousand_words_and_few_edits, with Windows' own generator and seed, so the same words and
    // the same edit positions.
    @Test func copesWithTenThousandWordsAndFewEditsSeeded() {
        var rng = DotNetRandom(7)
        let words = (0..<10_000).map { _ in "w\(rng.next(500))" }
        var edited = words
        for k in 0..<40 { edited[rng.next(edited.count)] = "CHANGED\(k)" }
        edited.insert("inserted", at: 5000)
        edited.remove(at: 100)
        let a = words.joined(separator: " "), b = edited.joined(separator: " ")
        let d = LongDiff.compute(a, b)
        #expect(Self.reproduces(a, b, d))
        #expect((2...90).contains(Self.edits(d)))
    }
}

// MARK: - NotesSummary, NotesFormat (ExtendedNotesTests.cs, NotesMarkersTests.cs)

@Suite struct NotesSummaryParityTests {
    // Windows: The_summary_is_shaped_into_main_idea_points_and_paragraphs, `DoesNotContain("Summary\n")`.
    @Test func theSummaryHeadingIsDropped() {
        let raw = "**Summary**\nMain idea: The launch moves to May.\n\n- Budget approved\n- Hiring paused\n- QA needs two weeks\n- Extra point\n\n" +
            "First para.\n\nSecond para.\n\nThird para.\n\nFourth para."
        let shaped = NotesSummary.shape(raw)!
        #expect(!shaped.contains("Summary\n"))
        #expect(!shaped.contains("Summary"))
    }
}

@Suite struct NotesFormatParityTests {
    // Windows: The_ai_is_told_to_keep_the_markers_lines_only_when_there_are_some ("own line").
    @Test func theAIIsToldToKeepMarkerLinesOnTheirOwnLine() {
        let with = NotesFormat.instructions("We start.\n⚑ 1:23\nWe go on.")
        #expect(with.contains("⚑"))
        #expect(with.contains("own line"))
        #expect(!NotesFormat.instructions("We start and we go on.").contains("⚑"))
    }

    // Windows' NotesFormat.Key and IsJunkLine use .NET char.IsLetterOrDigit: a letter or a decimal digit in one UTF-16
    // unit. "½" is a number but not a digit, and an emoji is a surrogate pair, so a line of "🎉 ½" is junk.
    @Test func letterAndDigitRulesFollowDotNet() {
        #expect(NotesFormat.isJunkLine("🎉 ½", keepCJK: false))
        #expect(NotesFormat.isJunkLine("⚠️ 00:03:15", keepCJK: false))
        #expect(!NotesFormat.isJunkLine("🎉 Party at 5", keepCJK: false))
        #expect(!NotesFormat.isJunkLine("½ cup", keepCJK: false)) // nothing foreign in it: not junk
        #expect(NotesFormat.clean("Hello there.\n🎉 ½", sent: "hello there") == "Hello there.")
        #expect(NotesFormat.key("½ Hello, 🎉 World!") == "hello world")
        #expect(NotesFormat.letterOrDigit("a") && NotesFormat.letterOrDigit("Ж") && NotesFormat.letterOrDigit("会"))
        #expect(NotesFormat.letterOrDigit("7") && NotesFormat.letterOrDigit("٣")) // decimal digits (Nd)
        #expect(!NotesFormat.letterOrDigit("½") && !NotesFormat.letterOrDigit("²") && !NotesFormat.letterOrDigit("Ⅻ")) // No, Nl
        #expect(!NotesFormat.letterOrDigit("\u{0301}")) // a combining mark
        #expect(!NotesFormat.letterOrDigit("𝐀")) // a letter, but beyond one UTF-16 unit
    }
}

// MARK: - Markers (NotesMarkersTests.cs)

@Suite struct NotesMarkersParityTests {
    // Windows: A_marker_is_a_flagged_line_with_its_time_an_anchor_and_a_change.
    @Test func aMarkerIsAFlaggedLineWithItsTimeAnAnchorAndAChange() {
        let s = NoteSession()
        let by = NSObject()
        var changed: [(NoteDoc, AnyObject?)] = []
        s.changed = { doc, source in changed.append((doc, source)) }
        s.addMarker(754, source: by)
        #expect(s.transcript == "⚑ 12:34\n")
        #expect(s.transcriptAnchors.count == 1)
        #expect(s.transcriptAnchors.first?.offset == 0 && s.transcriptAnchors.first?.seconds == 754)
        #expect(s.markers == [NoteMarker(seconds: 754, label: "12:34")])
        #expect(changed.count == 1)
        #expect(changed.first?.0 == .transcript)
        #expect(changed.first?.1 === by)
        #expect(s.heard.isEmpty) // what was heard never changes
    }

    // Windows: The_hours_show_once_there_are_any (6 cases).
    @Test(arguments: [(5.0, "0:05"), (754.0, "12:34"), (3599.9, "59:59"), (3600.0, "1:00:00"), (3723.0, "1:02:03"), (37230.0, "10:20:30")])
    func theHoursShowOnceThereAreAny(seconds: Double, label: String) {
        #expect(NoteSession.markerLabel(seconds) == label)
    }

    // Windows: An_hour_in_the_line_has_the_hours.
    @Test func anHourInTheLineHasTheHours() {
        let s = NoteSession()
        s.addMarker(3723)
        #expect(s.transcript == "⚑ 1:02:03\n")
    }

    // Windows: A_marker_after_heard_text_starts_a_new_line_and_the_next_piece_follows_on_one.
    @Test func aMarkerAfterHeardTextStartsANewLineAndTheNextPieceFollowsOnOne() {
        let s = NoteSession()
        s.appendHeard("hello world", seconds: 1)
        s.addMarker(12.5)
        s.appendHeard("next piece", seconds: 15)
        #expect(s.transcript == "hello world\n⚑ 0:12\nnext piece")
        #expect(s.transcriptAnchors.map(\.offset) == [0, 12, 19])
        #expect(s.secondsAt(.transcript, 5) == 1)
        #expect(s.secondsAt(.transcript, 14) == 12.5) // a right-click on the marker's line
        #expect(s.secondsAt(.transcript, 20) == 15)
        #expect(s.heard == "hello world next piece")
    }

    // Windows: A_marker_after_a_typed_line_doesnt_double_the_break.
    @Test func aMarkerAfterATypedLineDoesntDoubleTheBreak() {
        let s = NoteSession()
        s.set(.transcript, "Agenda: budget\n", source: nil) // the dashboard draft, as a new session takes it
        s.addMarker(3)
        #expect(s.transcript == "Agenda: budget\n⚑ 0:03\n")
        #expect(s.transcriptAnchors.map(\.offset) == [15])
    }

    // Windows: A_marker_while_the_ai_works_is_formatted_next_time.
    @Test func aMarkerWhileTheAIWorksIsFormattedNextTime() {
        let s = NoteSession()
        s.appendHeard("first part", seconds: 0)
        let take = s.beginFormat()!
        s.addMarker(30)
        s.endFormat(heard: take.heard, sent: take.sent, ai: "First part.", seconds: take.seconds, failed: false)
        #expect(s.formatted == "First part.")
        #expect(s.formattedThrough == "first part".utf16.count)
        #expect(s.beginFormat()?.sent == "⚑ 0:30") // the marker's line goes to the AI with the next piece
        #expect(s.beginFormat()?.seconds == 30)
    }

    // Windows: Markers_are_kept_in_the_session_file (the store's own encoder and decoder).
    @Test func markersAreKeptInTheSessionFile() throws {
        let s = NoteSession()
        s.addMarker(754)
        s.addMarker(3723)
        let back = try NotesStore.decoder.decode(NoteSession.self, from: try NotesStore.encoder.encode(s))
        #expect(back.markers.map(\.seconds) == [754, 3723])
        #expect(back.markers.map(\.label) == ["12:34", "1:02:03"])
        #expect(back.transcript == s.transcript)
    }

    static func session() -> NoteSession {
        let s = NoteSession()
        s.title = "Product sync"; s.summary = "Ship Monday."; s.formatted = "We ship on Monday."; s.transcript = "we ship on monday"; s.seconds = 3725
        s.started = localDate(2026, 10, 17, 9, 0) // fixed: the export's date line must never read a marker's time
        return s
    }

    // Windows: Everything_lists_the_markers_after_the_summary.
    @Test func everythingListsTheMarkersAfterTheSummary() {
        let s = Self.session()
        s.markers.append(NoteMarker(seconds: 754, label: "12:34"))
        s.markers.append(NoteMarker(seconds: 3723, label: "1:02:03"))
        let md = NotesExport.build(s, part: .everything, markdown: true)
        #expect(md.contains("## Markers\n\n- 12:34\n- 1:02:03\n\n## Formatted"))
        #expect(md.range(of: "## Summary")!.lowerBound < md.range(of: "## Markers")!.lowerBound)
        let txt = NotesExport.build(s, part: .everything, markdown: false)
        #expect(txt.contains("MARKERS\n\n12:34\n1:02:03\n\nFORMATTED"))
        // One text alone has no markers section.
        #expect(!NotesExport.build(s, part: .transcript, markdown: false).contains("12:34"))
        #expect(!NotesExport.build(s, part: .summary, markdown: true).contains("Markers"))
    }

    // Windows: Everything_is_unchanged_without_markers.
    @Test func everythingIsUnchangedWithoutMarkers() {
        let md = NotesExport.build(Self.session(), part: .everything, markdown: true)
        #expect(!md.contains("Markers"))
        #expect(md.contains("## Summary\n\nShip Monday.\n\n## Formatted\n\nWe ship on Monday.\n\n## Transcript\n\nwe ship on monday"))
        let txt = NotesExport.build(Self.session(), part: .everything, markdown: false)
        #expect(txt.contains("SUMMARY\n\nShip Monday.\n\nFORMATTED\n\n"))
    }
}

// MARK: - Exports (ExtendedNotesTests.cs NotesExportTests, NotesDocxExportTests.cs)

/// The files of a zip whose entries are stored (method 0) or deflated (method 8, as `Zip.deflated` writes them), by name.
private func storedZipEntries(_ zip: Data) -> [String: Data] {
    let d = [UInt8](zip)
    func u16(_ at: Int) -> Int { Int(d[at]) | Int(d[at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    var entries: [String: Data] = [:]
    var at = 0
    while at + 30 <= d.count && u32(at) == 0x0403_4B50 {
        let method = u16(at + 8), size = u32(at + 18), nameLength = u16(at + 26), extra = u16(at + 28)
        let name = String(decoding: d[(at + 30)..<(at + 30 + nameLength)], as: UTF8.self)
        let start = at + 30 + nameLength + extra
        let body = Data(d[start..<(start + size)])
        entries[name] = method == 8 ? ((try? (body as NSData).decompressed(using: .zlib)) as Data?) ?? Data() : body
        at = start + size
    }
    return entries
}

/// Each entry's compression method and DOS date and time, by name.
private func zipEntryHeaders(_ zip: Data) -> [String: (method: Int, time: Int, date: Int, flags: Int)] {
    let d = [UInt8](zip)
    func u16(_ at: Int) -> Int { Int(d[at]) | Int(d[at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    var out: [String: (method: Int, time: Int, date: Int, flags: Int)] = [:]
    var at = 0
    while at + 30 <= d.count && u32(at) == 0x0403_4B50 {
        let size = u32(at + 18), nameLength = u16(at + 26), extra = u16(at + 28)
        let name = String(decoding: d[(at + 30)..<(at + 30 + nameLength)], as: UTF8.self)
        out[name] = (u16(at + 8), u16(at + 10), u16(at + 12), u16(at + 6))
        at = at + 30 + nameLength + extra + size
    }
    return out
}

/// A WordprocessingML body's paragraphs: each one's style and its text, with a line break for every w:br (the Windows
/// test's `Paragraphs`). Nil when the XML doesn't parse.
private final class DocxParagraphs: NSObject, XMLParserDelegate {
    var paragraphs: [(style: String?, text: String)] = []
    private var style: String?
    private var text = ""
    private var inParagraph = false, inText = false

    static func read(_ xml: Data) -> [(style: String?, text: String)]? {
        let reader = DocxParagraphs()
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        return parser.parse() ? reader.paragraphs : nil
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "w:p": inParagraph = true; style = nil; text = ""
        case "w:pStyle": style = attributes["w:val"]
        case "w:t": inText = true
        case "w:br": if inParagraph { text += "\n" }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "w:p": paragraphs.append((style, text)); inParagraph = false
        case "w:t": inText = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { text += string } }
}

@Suite struct NotesExportParityTests {
    // Windows: Everything_as_markdown_has_the_title_and_each_part, the transcript-only export.
    @Test func theTranscriptAloneHasTheTranscript() {
        let s = NoteSession()
        s.title = "Product sync"; s.summary = "Ship Monday."; s.formatted = "We ship on Monday."; s.transcript = "we ship on monday"; s.seconds = 3725
        let txt = NotesExport.build(s, part: .transcript, markdown: false)
        #expect(!txt.contains("Ship Monday."))
        #expect(txt.contains("we ship on monday"))
    }
}

// The date line is checked only for the length ("1:02:05", written with String(format:)), which no locale changes, so
// these tests leave NotesExport.locale alone: it is a global the other export tests read while these run in parallel.
@Suite struct NotesDocxParityTests {
    static func sample() -> NoteSession {
        let s = NoteSession()
        s.title = "Product sync"; s.started = localDate(2026, 10, 17, 9, 30); s.seconds = 3725
        s.summary = "Main idea: ship Monday.\n\n- Budget approved\n- Hiring paused"
        s.formatted = "We ship on Monday.\nThe budget is approved.\n\n\nHiring is paused."
        s.transcript = "we ship on monday the budget is approved hiring is paused"
        return s
    }

    static func paragraphs(_ docx: Data) -> [(style: String?, text: String)] {
        guard let xml = storedZipEntries(docx)["word/document.xml"], let p = DocxParagraphs.read(xml) else {
            Issue.record("word/document.xml is missing or isn't well-formed XML")
            return []
        }
        return p
    }

    // Windows: Everything_is_a_package_with_the_title_the_headings_and_the_text.
    @Test func everythingIsAPackageWithTheTitleTheHeadingsAndTheText() {
        let docx = NotesExport.buildDocx(Self.sample(), part: .everything)
        let entries = storedZipEntries(docx)
        for name in ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/_rels/document.xml.rels"] {
            #expect(entries[name] != nil, "missing \(name)")
        }
        let xml = String(decoding: entries["word/document.xml"] ?? Data(), as: UTF8.self)
        #expect(xml.contains("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"))
        let p = Self.paragraphs(docx)
        guard p.count > 2 else { Issue.record("too few paragraphs"); return }
        #expect(p[0].style == "Title" && p[0].text == "Product sync")
        #expect(p[1].style == nil && p[1].text.contains("1:02:05"))
        #expect(p.filter { $0.style == "Heading1" }.map(\.text) == ["Summary", "Formatted", "Transcript"])
        #expect(p.contains { $0.text == "We ship on Monday.\nThe budget is approved." }) // a line break is kept
        #expect(p.contains { $0.text == "Hiring is paused." }) // blank lines make a new paragraph
        #expect(p.contains { $0.text == "- Budget approved\n- Hiring paused" })
        #expect(p.contains { $0.text == "we ship on monday the budget is approved hiring is paused" })
        #expect(p.firstIndex { $0.text == "Summary" }! < p.firstIndex { $0.text == "Formatted" }!)

        let styles = String(decoding: entries["word/styles.xml"] ?? Data(), as: UTF8.self)
        let ids = styles.matches(of: #/w:styleId="([^"]+)"/#).map { String($0.1) }
        #expect(ids == ["Normal", "Title", "Heading1"])
        let rels = String(decoding: entries["_rels/.rels"] ?? Data(), as: UTF8.self)
        #expect(rels.matches(of: #/<Relationship /#).count == 1 && rels.contains("Target=\"word/document.xml\""))
        #expect(String(decoding: entries["[Content_Types].xml"] ?? Data(), as: UTF8.self).contains("wordprocessingml.document.main+xml"))
        let docRels = String(decoding: entries["word/_rels/document.xml.rels"] ?? Data(), as: UTF8.self)
        #expect(docRels.matches(of: #/<Relationship /#).count == 1 && docRels.contains("relationships/styles\""))
    }

    // Windows: Special_characters_are_escaped_and_control_characters_dropped.
    @Test func specialCharactersAreEscapedAndControlCharactersDropped() {
        let s = NoteSession()
        s.title = "A & B <c> \"d\""
        s.transcript = "Smile \u{1F600} here\u{7} and\u{1} \"quoted\" <tag> & co\ttab"
        let docx = NotesExport.buildDocx(s, part: .transcript)
        let raw = String(decoding: storedZipEntries(docx)["word/document.xml"] ?? Data(), as: UTF8.self)
        #expect(raw.contains("&amp;"))
        #expect(raw.contains("&lt;c&gt;"))
        #expect(!raw.unicodeScalars.contains("\u{7}"))
        #expect(!raw.unicodeScalars.contains("\u{1}"))
        let p = Self.paragraphs(docx)
        guard p.count > 2 else { Issue.record("too few paragraphs"); return }
        #expect(p[0].text == "A & B <c> \"d\"")
        #expect(p[2].text == "Smile \u{1F600} here and \"quoted\" <tag> & co\ttab")
        #expect(!p.contains { $0.style == "Heading1" }) // one part: no headings
    }

    // Windows: XmlSafe_keeps_tabs_and_newlines_and_drops_the_rest (all but the lone-surrogate case, below).
    @Test func xmlSafeKeepsTabsAndNewlinesAndDropsTheRest() {
        #expect(NotesExport.xmlSafe("a\r\nb\rc") == "a\nb\nc")
        #expect(NotesExport.xmlSafe("tab\tkept\u{0}\u{1F} gone\u{1B}") == "tab\tkept gone")
        #expect(NotesExport.xmlSafe("whole \u{1F600} emoji") == "whole \u{1F600} emoji")
        #expect(NotesExport.xmlSafe("not\u{FFFE} xml\u{FFFF}") == "not xml")
    }

    // Windows: XmlSafe("half \uD83D of an emoji") == "half  of an emoji". A Swift String can't hold half a surrogate pair:
    // made from UTF-16 (or bridged from an NSString that has one) it reads U+FFFD there, which is valid XML, so the Mac
    // keeps a replacement character where Windows drops the half emoji.
    @Test(.disabled("Mac differs: a lone surrogate becomes U+FFFD in a Swift String, and xmlSafe keeps it; Windows drops it"))
    func xmlSafeDropsHalfAnEmoji() {
        let half = String(decoding: Array("half ".utf16) + [0xD83D] + Array(" of an emoji".utf16), as: UTF16.self)
        #expect(NotesExport.xmlSafe(half) == "half  of an emoji")
    }

    // Windows: An_empty_session_is_still_a_valid_document.
    @Test func anEmptySessionIsStillAValidDocument() {
        let p = Self.paragraphs(NotesExport.buildDocx(NoteSession(), part: .everything))
        #expect(p.count == 5) // the title, the date line, three headings and no text
        #expect(p.first?.style == "Title" && p.first?.text == "")
        #expect(p.filter { $0.style == "Heading1" }.count == 3)
    }

    // Windows: One_part_has_no_headings_and_none_of_the_other_texts.
    @Test func onePartHasNoHeadingsAndNoneOfTheOtherTexts() {
        let p = Self.paragraphs(NotesExport.buildDocx(Self.sample(), part: .formatted))
        #expect(!p.isEmpty)
        #expect(!p.contains { $0.style == "Heading1" })
        #expect(!p.contains { $0.text.contains("we ship on monday") })
        #expect(!p.contains { $0.text.contains("Main idea") })
        #expect(p.contains { $0.text.hasPrefix("We ship on Monday.") })
    }
}

// MARK: - Playback copy (ExtendedNotesTests.cs, NotesPlaybackTests)

@Suite struct NotesAudioParityTests {
    // Windows: The_prepared_copy_is_kept_for_the_next_time.
    @Test func thePreparedCopyIsKeptForTheNextTime() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "oberton-notes-test-\(UUID().uuidString)")
        let id = "test-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            NotesAudio.forget(id)
        }
        let src = dir.appending(path: "audio.wav")
        let w = try WavWriter(url: src)
        w.write([Float](repeating: 0, count: 16_000))
        w.close()
        let first = try NotesAudio.prepareCached(src, sessionID: id)
        func modified(_ u: URL) -> Date? { try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let madeAt = modified(first.url)
        let again = try NotesAudio.prepareCached(src, sessionID: id)
        #expect(first.url == again.url)
        #expect(FileManager.default.fileExists(atPath: again.url.path))
        #expect((0.99...1.01).contains(again.seconds))
        #expect(modified(again.url) == madeAt) // found again, not made again
        NotesAudio.forget(id)
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
    }
}

// MARK: - Usage (ExtendedNotesTests.cs NotesUsageTests, NotesUsageTests.cs)

@Suite struct NotesUsageParityTests {
    // Windows: A_finished_session_is_counted_on_its_day_apart_from_dictation (the day row).
    @Test func twoSessionsOnOneDayShareItsRow() {
        let usage = NotesUsage(url: nil)
        let s = NoteSession()
        s.started = localDate(2026, 10, 17, 9, 0); s.seconds = 3600; s.source = .both
        s.heard = "one two three"; s.transcript = "one two three my note"
        usage.record(s, formatRequests: 12, summaryRequests: 4)
        let later = NoteSession()
        later.started = localDate(2026, 10, 17, 14, 0); later.seconds = 60
        usage.record(later, formatRequests: 1, summaryRequests: 0)
        #expect(usage.days.count == 1)
        guard let day = usage.days.first else { return }
        #expect(day.day == Calendar.current.startOfDay(for: s.started))
        #expect(day.sessions == 2 && day.seconds == 3660 && day.wordsHeard == 3 && day.wordsTyped == 2)
        #expect(day.formatRequests == 13 && day.summaryRequests == 4)
        #expect(day.sources["Both"] == 1)
        #expect(day.sources["Mic"] == 1)
    }

    static let now = localDate(2026, 10, 17, 15, 30)

    static func session(_ daysFromNow: Int, seconds: Double = 600, source: NotesSource = .mic, typed: String = "") -> NoteSession {
        let s = NoteSession()
        s.started = Calendar.current.date(byAdding: .day, value: daysFromNow, to: now)!
        s.seconds = seconds; s.source = source
        s.heard = "one two three"; s.transcript = typed.isEmpty ? "one two three" : "one two three " + typed
        return s
    }

    /// Four sessions: the day before a 30-day window, its first day, today, and tomorrow (a clock set back).
    static func fourDays() -> NotesUsage {
        let usage = NotesUsage(url: nil)
        usage.record(session(-30, seconds: 1000), formatRequests: 1, summaryRequests: 0)
        usage.record(session(-29, seconds: 100), formatRequests: 2, summaryRequests: 1)
        usage.record(session(0, seconds: 200, typed: "my note"), formatRequests: 3, summaryRequests: 2)
        usage.record(session(1, seconds: 1000), formatRequests: 1, summaryRequests: 1)
        return usage
    }

    // NotesUsageTests.cs: A_window_counts_only_the_days_inside_it.
    @Test func aWindowCountsOnlyTheDaysInsideIt() {
        let t = Self.fourDays().totals(now: Self.now, days: 30)
        #expect(t.sessions == 2)
        #expect(t.seconds == 300)
        #expect(t.wordsHeard == 6)
        #expect(t.wordsTyped == 2)
        #expect(t.aiRequests == 8) // formatting and summary steps together
    }

    // NotesUsageTests.cs: A_window_of_one_day_is_today.
    @Test func aWindowOfOneDayIsToday() {
        let t = Self.fourDays().totals(now: Self.now, days: 1)
        #expect(t.sessions == 1)
        #expect(t.seconds == 200)
    }

    // NotesUsageTests.cs: All_time_counts_every_day.
    @Test(arguments: [0, -1])
    func allTimeCountsEveryDay(days: Int) {
        let t = Self.fourDays().totals(now: Self.now, days: days)
        #expect(t.sessions == 4)
        #expect(t.seconds == 2300)
        #expect(t.wordsHeard == 12)
        #expect(t.wordsTyped == 2)
        #expect(t.aiRequests == 11)
    }

    // NotesUsageTests.cs: Sources_are_summed_across_days.
    @Test func sourcesAreSummedAcrossDays() {
        let usage = NotesUsage(url: nil)
        usage.record(Self.session(-2, source: .mic), formatRequests: 0, summaryRequests: 0)
        usage.record(Self.session(-1, source: .both), formatRequests: 0, summaryRequests: 0)
        usage.record(Self.session(0, source: .mic), formatRequests: 0, summaryRequests: 0)
        let sources = usage.totals(now: Self.now, days: 0).sources
        #expect(sources["Mic"] == 2)
        #expect(sources["Both"] == 1)
        #expect(sources["Computer"] == nil) // only the sources used
    }

    // NotesUsageTests.cs: Nothing_recorded_is_all_zeros.
    @Test func nothingRecordedIsAllZeros() {
        let t = NotesUsage(url: nil).totals(now: Self.now, days: 30)
        #expect(t.sessions == 0 && t.seconds == 0 && t.wordsHeard == 0 && t.wordsTyped == 0 && t.aiRequests == 0)
        #expect(t.sources.isEmpty)
    }

    // NotesUsageTests.cs: Seconds_show_as_hours_and_whole_minutes (4 cases).
    @Test(arguments: [(0.0, "0:00"), (59.0, "0:00"), (3660.0, "1:01"), (90000.0, "25:00")])
    func secondsShowAsHoursAndWholeMinutes(seconds: Double, expected: String) {
        #expect(NotesUsage.hoursMinutes(seconds) == expected)
    }

    // The Mac's own file format: a usage.json from before the day was a calendar date (an ISO-8601 instant of its
    // midnight) still loads, two rows that fall on one day are merged, and the file is written back with "yyyy-MM-dd".
    @Test func anOlderUsageFileStillLoadsAndIsWrittenWithCalendarDays() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "oberton-notes-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "usage.json")

        let instant = ISO8601DateFormatter().date(from: "2026-11-02T23:00:00Z")!
        let day = Calendar.current.startOfDay(for: instant)
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.calendar = Calendar(identifier: .gregorian)
        dayFormat.dateFormat = "yyyy-MM-dd"
        let dayString = dayFormat.string(from: day)
        let old = """
            {"version":1,"days":[
              {"day":"2026-11-02T23:00:00Z","sessions":1,"seconds":600,"wordsHeard":3,"wordsTyped":0,"formatRequests":2,"summaryRequests":1,"sources":{"Mic":1}},
              {"day":"\(dayString)","sessions":1,"seconds":60,"wordsHeard":1,"wordsTyped":1,"formatRequests":0,"summaryRequests":0,"sources":{"Both":1}}
            ]}
            """
        try Data(old.utf8).write(to: url)

        let usage = NotesUsage(url: url)
        #expect(usage.days.count == 1)
        #expect(usage.days.first?.day == day)
        #expect(usage.days.first?.sessions == 2 && usage.days.first?.seconds == 660 && usage.days.first?.formatRequests == 2)
        #expect(usage.days.first?.sources == ["Mic": 1, "Both": 1])
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("bad").path))

        let s = NoteSession()
        s.started = day.addingTimeInterval(3600); s.seconds = 30; s.heard = "a b"; s.transcript = "a b"
        usage.record(s, formatRequests: 1, summaryRequests: 0) // writes the file
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(!written.contains("T23:00:00Z"))
        #expect(written.firstMatch(of: #/"day"\s*:\s*"\d{4}-\d{2}-\d{2}"/#) != nil)
        #expect(written.contains("\"\(dayString)\""))

        let again = NotesUsage(url: url)
        #expect(again.days.count == 1)
        #expect(again.days.first?.day == day)
        #expect(again.days.first?.sessions == 3)
    }
}

// MARK: - Models (NotesModelTests.cs)

@Suite struct NotesModelParityTests {
    static let gb: Int64 = 1024 * 1024 * 1024
    static func size(_ g: Double) -> Int64 { Int64(g * Double(gb)) }

    // Windows: An_ollama_cloud_model_is_never_the_best, with its model and figures.
    @Test func anOllamaCloudModelIsNeverTheBest() {
        let cloud = LocalModel(name: "gpt-oss:120b-cloud", billions: 116.8, bytes: 384, family: "gptoss") // listed like an installed one
        #expect(NotesModels.pickBest([cloud, Self.qwen7B], gpuBytes: 6 * Self.gb) == Self.qwen7B)
        #expect(NotesModels.pickBest([cloud], gpuBytes: 6 * Self.gb) == nil)
    }

    // System.Text.Json fills a missing field with its default: a session.json missing some still loads.
    @Test func aSessionMissingFieldsStillLoads() throws {
        let raw = #"{"title":"Old one","transcript":"hello there","finished":true}"#
        let s = try JSONDecoder().decode(NoteSession.self, from: Data(raw.utf8))
        #expect(s.title == "Old one" && s.transcript == "hello there" && s.finished)
        #expect(s.formatted == "" && s.chunks.isEmpty && s.words == nil)
    }

    // Windows writes a usage day as a DateTime at its midnight; the Mac reads it as that day.
    @Test func aWindowsUsageDayIsReadAsThatDay() throws {
        let raw = #"{"day":"2026-11-03T00:00:00","sessions":2}"#
        let d = try JSONDecoder().decode(NotesUsageDay.self, from: Data(raw.utf8))
        #expect(NotesUsageDay.dayFormat.string(from: d.day) == "2026-11-03")
        #expect(d.sessions == 2)
        let withOffset = try JSONDecoder().decode(NotesUsageDay.self, from: Data(#"{"day":"2026-11-03T00:00:00+01:00"}"#.utf8))
        #expect(NotesUsageDay.dayFormat.string(from: withOffset.day) == "2026-11-03")
    }

    static let qwen3B = LocalModel(name: "qwen2.5:3b", billions: 3.1, bytes: size(1.9), family: "qwen2")
    static let qwen7B = LocalModel(name: "qwen2.5:7b", billions: 7.6, bytes: size(4.7), family: "qwen2")
    static let qwen3_4B = LocalModel(name: "qwen3:4b-instruct-2507-q4_K_M", billions: 4.0, bytes: size(2.5), family: "qwen3")
    static let big = LocalModel(name: "qwen2.5:14b", billions: 14.8, bytes: 9 * gb, family: "qwen2")
    static let embed = LocalModel(name: "nomic-embed-text", billions: 0.137, bytes: size(0.27), family: "nomic-bert")
    static let installed = [qwen3B, qwen7B, qwen3_4B, big, embed]
    static let qwen30A3 = LocalModel(name: "qwen3:30b-a3b-instruct-2507-q4_K_M", billions: 30.5, bytes: size(17.3), family: "qwen3moe")

    // Windows: Parameter_sizes_are_read_or_estimated (4 cases).
    @Test(arguments: [("7.6B" as String?, Int64(0), 7.6), ("494.03M", 0, 0.49403), ("27B", 0, 27), (nil, 4_800_000_000, 8.0)])
    func parameterSizesAreReadOrEstimated(size: String?, bytes: Int64, billions: Double) {
        #expect(abs(LocalModel.parseBillions(size, bytes: bytes) - billions) < 0.0005)
    }

    // Windows: The_best_is_the_largest_that_fits_the_gpu.
    @Test func theBestIsTheLargestThatFitsTheGpu() {
        let i = Self.installed
        #expect(NotesModels.pickBest(i, gpuBytes: 6 * Self.gb) == Self.qwen7B)
        #expect(NotesModels.pickBest(i, gpuBytes: 12 * Self.gb) == Self.big)
        #expect(NotesModels.pickBest(i, gpuBytes: 4 * Self.gb) == Self.qwen3_4B)
        #expect(NotesModels.pickBest(i, gpuBytes: nil) == Self.qwen3_4B) // no GPU: up to 4.5B
        #expect(NotesModels.pickBest([Self.qwen3B, Self.embed], gpuBytes: nil) == Self.qwen3B)
        #expect(NotesModels.pickBest([Self.big, Self.qwen3B], gpuBytes: 1 * Self.gb) == Self.qwen3B) // nothing fits: the smallest
        #expect(NotesModels.pickBest([Self.embed], gpuBytes: 6 * Self.gb) == nil) // an embedding model can't write
    }

    // Windows: A_mixture_of_experts_counts_its_working_parameters.
    @Test func aMixtureOfExpertsCountsItsWorkingParameters() {
        #expect(Self.qwen30A3.isMixture)
        #expect(Self.qwen30A3.activeBillions == 3)
        let noA3b = LocalModel(name: "qwen3:30b", billions: 30.5, bytes: 19 * Self.gb, family: "qwen3moe") // no "a3b" in the name
        #expect(abs(noA3b.activeBillions - 3.3) < 0.05)
        #expect(LocalModel(name: "qwen3:235b-a22b-instruct-2507-q4_K_M", billions: 235, bytes: 142 * Self.gb, family: "qwen3moe").activeBillions == 22)
        #expect(!Self.qwen7B.isMixture)
        #expect(Self.qwen7B.activeBillions == 7.6)
        #expect(!Self.qwen3_4B.isMixture) // "-instruct" isn't "-a4b"
    }

    // Windows: A_mixture_runs_from_memory_when_the_pc_has_room.
    @Test func aMixtureRunsFromMemoryWhenTheMacHasRoom() {
        let gb = Self.gb
        #expect(Self.qwen30A3.runsFromMemory(gpuBytes: 6 * gb, ramBytes: 40 * gb))
        #expect(Self.qwen30A3.runsFromMemory(gpuBytes: nil, ramBytes: 32 * gb))
        #expect(!Self.qwen30A3.runsFromMemory(gpuBytes: 6 * gb, ramBytes: 16 * gb)) // too little RAM
        #expect(!Self.qwen30A3.runsFromMemory(gpuBytes: 6 * gb, ramBytes: nil)) // RAM not known
        #expect(!Self.qwen30A3.runsFromMemory(gpuBytes: 24 * gb, ramBytes: 40 * gb)) // fits the GPU: runs there instead
        #expect(!Self.big.runsFromMemory(gpuBytes: 6 * gb, ramBytes: 64 * gb)) // an ordinary 14B on the processor is too slow
        #expect(!LocalModel(name: "qwen3:235b-a22b", billions: 235, bytes: 142 * gb, family: "qwen3moe")
            .runsFromMemory(gpuBytes: 6 * gb, ramBytes: 256 * gb)) // 22B at work
    }

    // Windows: With_enough_memory_the_mixture_is_the_best (with Fits).
    @Test func withEnoughMemoryTheMixtureIsTheBest() {
        let gb = Self.gb
        let installed = Self.installed + [Self.qwen30A3]
        #expect(NotesModels.pickBest(installed, gpuBytes: 6 * gb, ramBytes: 40 * gb) == Self.qwen30A3)
        #expect(NotesModels.pickBest(installed, gpuBytes: 6 * gb, ramBytes: 16 * gb) == Self.qwen7B)
        #expect(NotesModels.pickBest(installed, gpuBytes: 6 * gb) == Self.qwen7B) // RAM not known: as before
        #expect(NotesModels.fits(Self.qwen30A3, gpuBytes: 6 * gb, ramBytes: 40 * gb))
        #expect(!NotesModels.fits(Self.qwen30A3, gpuBytes: 6 * gb, ramBytes: 16 * gb))
    }

    // Windows: A_model_too_big_for_the_gpu_is_held_in_ram.
    @Test func aModelTooBigForTheGpuIsHeldInRam() {
        let gb = Self.gb
        let dense27 = LocalModel(name: "qwen3.8:27b-q4_K_M", billions: 27.8, bytes: 17 * gb, family: "qwen35")
        #expect(dense27.heldInRam(gpuBytes: 6 * gb))
        #expect(!dense27.isMixture)
        #expect(!dense27.runsFromMemory(gpuBytes: 6 * gb, ramBytes: 40 * gb)) // all of it works on each word: too slow to be the best
        #expect(NotesModels.pickBest(Self.installed + [dense27], gpuBytes: 6 * gb, ramBytes: 40 * gb) == Self.qwen7B)
        #expect(!dense27.heldInRam(gpuBytes: 24 * gb))
        #expect(Self.qwen30A3.heldInRam(gpuBytes: 6 * gb))
        #expect(!Self.qwen7B.heldInRam(gpuBytes: 6 * gb))
        #expect(!Self.qwen7B.heldInRam(gpuBytes: nil)) // no GPU: only over 8 GB
        #expect(dense27.heldInRam(gpuBytes: nil))
    }

    // Windows: The_setting_resolves_to_a_model. The Mac takes the installed list itself (Windows a function that may
    // throw), so "Ollama unreachable" and "nothing installed" are both an empty list; the active model is a ModelID.
    @Test func theSettingResolvesToAModel() {
        let active = ModelID(provider: .ollama, name: "qwen3:4b")
        func resolve(_ setting: String, _ installed: [LocalModel] = Self.installed) -> ModelID {
            NotesModels.resolve(setting, activeModel: active, installed: installed, gpuBytes: 6 * Self.gb).model
        }
        #expect(resolve("") == ModelID(provider: .ollama, name: "qwen2.5:7b"))
        #expect(resolve(NotesModels.active) == active)
        #expect(resolve("qwen2.5:3b") == ModelID(provider: .ollama, name: "qwen2.5:3b"))
        #expect(resolve("llama3.2:3b") == ModelID(provider: .ollama, name: "qwen2.5:7b")) // not installed
        #expect(resolve("openai:gpt-4o-mini") == ModelID(provider: .openai, name: "gpt-4o-mini"))
        #expect(resolve("", []) == active) // Ollama unreachable, or no model installed
    }

    // Windows: The_setting_resolves_to_a_model's last case: the list throws (InvalidOperationException) → the active model.
    struct ListFailed: Error {}
    @Test func aListThatFailsLeavesTheActiveModel() async {
        let active = ModelID(provider: .ollama, name: "qwen3:4b")
        let r = await NotesModels.resolve("", activeModel: active, list: { throw ListFailed() }, gpuBytes: 6 * Self.gb)
        #expect(r.model == active)
        #expect(r.why == "the active model; the models couldn't be listed")
        // The active model and a cloud model never ask for the list.
        var asked = false
        _ = await NotesModels.resolve("active", activeModel: active, list: { asked = true; return [] }, gpuBytes: nil)
        _ = await NotesModels.resolve("openai:gpt-4o-mini", activeModel: active, list: { asked = true; return [] }, gpuBytes: nil)
        #expect(!asked)
        let named = await NotesModels.resolve("qwen2.5:3b", activeModel: active, list: { Self.installed }, gpuBytes: 6 * Self.gb)
        #expect(named.model == ModelID(provider: .ollama, name: "qwen2.5:3b"))
    }

    // NOTES-138: with nothing installed, Windows' why ("no local model is installed"); figures in the user's decimal mark.
    @Test func noModelInstalledReadsAsWindowsSaysIt() {
        let active = ModelID(provider: .ollama, name: "qwen3:4b")
        #expect(NotesModels.resolve("", activeModel: active, installed: [], gpuBytes: nil).why == "the active model; no local model is installed")
        let de = Locale(identifier: "de_DE")
        #expect(NotesModels.gb(Int64(5.3 * Double(Self.gb)), locale: de) == "5,3 GB")
        #expect(NotesModels.gb(Int64(5.0 * Double(Self.gb)), locale: de) == "5 GB")
        #expect(NotesModels.gb(Int64(12.5 * Double(Self.gb)), locale: de) == "13 GB") // {0:0}: a half away from zero
        #expect(NotesAudio.oneDecimal(12.25, locale: de) == "12,3")
        #expect(NotesAudio.oneDecimal(12.25, locale: Locale(identifier: "en_US")) == "12.3")
    }

    // Windows: Gpu_memory_reads_as_gigabytes.
    @Test func gpuMemoryReadsAsGigabytes() {
        #expect(NotesModels.gb(6 * Self.gb) == "6 GB")
    }
}

// MARK: - Round 3: the store, the recording's details, the Word file

private func notesTempDir() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "oberton-notes-r3-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func writeSession(_ dir: URL, _ folder: String, _ json: String) throws -> URL {
    let f = dir.appending(path: folder, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
    let file = f.appending(path: "session.json")
    try Data(json.utf8).write(to: file)
    return file
}

// These catch the log through CoreLog.sink, which BrokenFileTests' serialized suite keeps to one test at a time.
extension BrokenFileTests {
    // Regression #12: a session.json with none of the Mac's keys (Windows' own, "Title", "Finished": false…) is kept as
    // session.json.bad and skipped, never taken for an empty session, closed and saved over.
    @Test func aWindowsSessionFileIsKeptAsBadAndNeverSavedOver() throws {
        let dir = notesTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let windows = #"{"Title":"Lecture","Started":"2026-11-03T10:15:00","Finished":false,"Transcript":"hello there","FormatVersion":2}"#
        let file = try writeSession(dir, "20261103-101500", windows)
        var lines: [String] = []
        CoreLog.sink = { level, message in lines.append(level + " " + message) }
        defer { CoreLog.sink = nil }
        let store = NotesStore(dir: dir)
        #expect(store.sessions.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("bad").path))
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == windows) // untouched
        #expect(lines.contains { $0.hasPrefix("ERROR Could not read ") && $0.contains("session.json; keeping a .bad copy: ") })
        #expect(!lines.contains { $0.contains("closed a session left open") })
    }

    // NOTES-099: JsonStore reads trailing commas and comments; "null" is skipped without a word; a missing formatVersion
    // is 0, so the session is repaired once and saved with the version.
    @Test func aSessionFileIsReadAsTolerantlyAsJsonStore() throws {
        let dir = notesTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeSession(dir, "20261101-090000", """
            {
              // written by hand
              "title": "Commented", "finished": true, "formatVersion": 2,
              "transcript": "one two",
            }
            """)
        let nullFile = try writeSession(dir, "20261101-100000", "null")
        let oldFile = try writeSession(dir, "20261101-110000", #"{"title":"Old","finished":true,"formatted":"Kept text.   \n\n\n\nMore."}"#)
        var lines: [String] = []
        CoreLog.sink = { level, message in lines.append(level + " " + message) }
        defer { CoreLog.sink = nil }
        let store = NotesStore(dir: dir)
        #expect(Set(store.sessions.map(\.title)) == ["Commented", "Old"])
        #expect(!FileManager.default.fileExists(atPath: nullFile.appendingPathExtension("bad").path))
        #expect(!lines.contains { $0.contains("20261101-100000") })
        let old = try #require(store.sessions.first { $0.title == "Old" })
        #expect(old.formatVersion == NotesFormat.version)
        #expect(old.formatted == "Kept text.\n\nMore.") // spaces before a break and the extra blank lines out
        #expect(lines.contains { $0 == "INFO Extended notes: repaired the formatted text of 20261101-110000" })
        // Saved in the background with the version: read again, nothing left to repair.
        Thread.sleep(forTimeInterval: 0.3)
        let again = try NotesStore.decoder.decode(NoteSession.self, from: Data(contentsOf: oldFile))
        #expect(again.formatVersion == NotesFormat.version)
    }

    // NOTES-101: a session whose folder is already gone is deleted without a warning (Windows checks Directory.Exists).
    @Test func deletingASessionAlreadyGoneLogsNothing() throws {
        let dir = notesTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesStore(dir: dir)
        let s = try store.create(source: .mic)
        try FileManager.default.removeItem(at: s.folder!)
        var lines: [String] = []
        CoreLog.sink = { level, message in lines.append(level + " " + message) }
        defer { CoreLog.sink = nil }
        store.delete(s)
        #expect(!lines.contains { $0.contains("couldn't delete a session") })
        #expect(store.sessions.isEmpty)
    }

    // NOTES-154: an unreadable usage.json says why, as JsonStore.Load's "…; keeping a .bad copy: <exception>".
    @Test func anUnreadableUsageFileSaysWhy() throws {
        let dir = notesTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "usage.json")
        try Data("{ not json".utf8).write(to: url)
        var lines: [String] = []
        CoreLog.sink = { level, message in lines.append(level + " " + message) }
        defer { CoreLog.sink = nil }
        let usage = NotesUsage(url: url)
        #expect(usage.days.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bad").path))
        #expect(lines.contains { $0.hasPrefix("ERROR Could not read ") && $0.contains("usage.json; keeping a .bad copy: ") })
    }
}

@Suite struct NotesRoundThreeTests {
    // NOTES-102: the draft is written at exit only when the box was typed in this time (FlushDraft does nothing when
    // SetDraft never ran): Windows' draft.txt, BOM and all, keeps its bytes.
    @Test func theDraftIsLeftAloneAtExitWhenNotTypedIn() throws {
        let dir = notesTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let draft = dir.appending(path: "draft.txt")
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("Agenda".utf8)
        try bytes.write(to: draft)
        let store = NotesStore(dir: dir)
        store.flushDraft()
        #expect(try Data(contentsOf: draft) == bytes)
        store.setDraft("Agenda, budget")
        store.flushDraft()
        #expect(String(decoding: try Data(contentsOf: draft), as: UTF8.self) == "Agenda, budget")
    }

    // NOTES-103: the prepared recording's details as Windows keeps them ({"Path","Seconds","GainDb","Silences"}).
    @Test func thePreparedDetailsUseWindowsKeys() throws {
        let p = PreparedAudio(url: URL(fileURLWithPath: "/tmp/x.wav"), seconds: 12.5, gainDb: 6, silences: [AudioPause(start: 1, end: 2)])
        let json = try JSONSerialization.jsonObject(with: NotesAudio.metaEncoder.encode(p)) as! [String: Any]
        #expect(Set(json.keys) == ["Path", "Seconds", "GainDb", "Silences"])
        #expect(json["Path"] as? String == "/tmp/x.wav")
        #expect((json["Silences"] as? [[String: Any]])?.first.map { Set($0.keys) } == ["Start", "End"])
        let back = try JSONDecoder().decode(PreparedAudio.self, from: NotesAudio.metaEncoder.encode(p))
        #expect(back.seconds == 12.5 && back.silences == p.silences && back.url.path == "/tmp/x.wav")
    }

    // NOTES-093: the Word file's entries are deflated and dated now, as ZipArchive (CompressionLevel.Optimal) writes
    // them, with XmlWriter's declaration in document.xml.
    @Test func theWordFileIsDeflatedAndDated() throws {
        let s = NoteSession()
        s.title = "Product sync"
        s.transcript = String(repeating: "The beta ships to ten testers on Friday. ", count: 40)
        let docx = NotesExport.buildDocx(s, part: .everything)
        let headers = zipEntryHeaders(docx)
        #expect(headers.count == 5)
        #expect(headers.values.allSatisfy { $0.method == 8 && $0.flags == 0 })
        let now = Zip.dosTime(Date())
        #expect(headers.values.allSatisfy { $0.date == now.date })
        let xml = try #require(storedZipEntries(docx)["word/document.xml"])
        #expect(String(decoding: xml, as: UTF8.self).hasPrefix(#"<?xml version="1.0" encoding="utf-8" standalone="yes"?>"#))
        #expect(String(decoding: try #require(storedZipEntries(docx)["word/styles.xml"]), as: UTF8.self).contains(#"encoding="UTF-8""#))
        #expect(docx.count < 4000) // the repeated transcript is compressed
    }

    // Windows' DOS date and time: 2026-11-03 14:05:07 → time 14<<11 | 5<<5 | 3, date 46<<9 | 11<<5 | 3.
    @Test func dosTimeIsWindowsZipDate() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let d = c.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 14, minute: 5, second: 7))!
        let t = Zip.dosTime(d, calendar: c)
        #expect(t.time == 14 << 11 | 5 << 5 | 3)
        #expect(t.date == 46 << 9 | 11 << 5 | 3)
    }

    // The repair of an old session (NotesFormat.Repair): junk lines and loops out of the formatted text and each step.
    @Test func anOldSessionIsRepaired() {
        let s = NoteSession()
        s.transcript = "We met today. We met today. We met today. Then we left."
        s.formatted = "We met today. 🎉🎉\n🎉🎉\nWe met today.   \n\n\n\nThen we left."
        s.chunks = [NoteChunk(heard: "x", sent: "x", ai: "Hello there.  \n\n\n\nBye.", seconds: 0, aiFailed: false)]
        #expect(NotesFormat.repair(s))
        #expect(!s.formatted.contains("\n🎉🎉\n")) // the junk line; a line with words keeps them
        #expect(!s.formatted.contains("\n\n\n"))
        #expect(s.chunks[0].ai == "Hello there.\n\nBye.")
        let clean = NoteSession()
        clean.formatted = "Fine as it is."
        #expect(!NotesFormat.repair(clean))
    }
}
