import Foundation

/// Extended Notes exports: one text, or all of them, as plain text, Markdown or a Word document (NotesExport in NotesStore.cs).
public enum NotesExport {
    public enum Part: String, CaseIterable, Sendable { case everything = "Everything", formatted = "Formatted", summary = "Summary", transcript = "Transcript" }

    public static func build(_ s: NoteSession, part: Part, markdown: Bool) -> String {
        var out = ""
        let w = when(s)
        if markdown { out += "# \(s.title)\n\n_\(w)_\n\n" } else { out += "\(s.title)\n\(w)\n\n" }
        sections(s, part, markerBullet: markdown ? "- " : "") { name, text in
            if part == .everything { out += markdown ? "## \(name)\n\n" : "\(name.uppercased())\n\n" }
            out += text.trimmed + "\n\n"
        }
        return out.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "\n"
    }

    /// The language dates are written in (tests pin one): the user's own, as Windows' current culture. Oberton itself is
    /// in English only, which `Locale.current` would follow, so the language is the user's first preferred one, with
    /// their region; digits are always 0-9, as .NET's custom date formats write them.
    nonisolated(unsafe) public static var locale = userLocale

    public static var userLocale: Locale {
        var c = Locale.Components(locale: .current)
        if let first = Locale.preferredLanguages.first, let lang = Locale(identifier: first).language.languageCode {
            c.languageComponents.languageCode = lang
            c.languageComponents.script = Locale(identifier: first).language.script
        }
        c.numberingSystem = "latn"
        return Locale(components: c)
    }

    /// The line under the title: the date and the length recorded.
    static func when(_ s: NoteSession) -> String {
        let t = Int(s.seconds)
        let f = DateFormatter()
        f.locale = locale // the day and month named in the user's language, as Windows' current culture
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        return f.string(from: s.started) + String(format: " · %d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }

    /// The parts an export includes, in the order they are written: Summary, (Markers), Formatted, Transcript.
    static func sections(_ s: NoteSession, _ part: Part, markerBullet: String, _ section: (String, String) -> Void) {
        if part == .summary || part == .everything { section("Summary", s.summary) }
        if part == .everything && !s.markers.isEmpty {
            section("Markers", s.markers.map { markerBullet + NoteSession.markerLabel($0.seconds) }.joined(separator: "\n"))
        }
        if part == .formatted || part == .everything { section("Formatted", s.formatted) }
        if part == .transcript || part == .everything { section("Transcript", s.transcript) }
    }

    // MARK: Word (.docx): a minimal WordprocessingML package, no library

    static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
        """
    static let packageRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
    static let documentRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """
    // Title, Heading 1 and Normal as Word's own built-in styles, so the document shows real headings.
    static let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="240"/></w:pPr><w:rPr><w:sz w:val="48"/><w:szCs w:val="48"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="360" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr></w:style></w:styles>
        """

    /// The same export as a Word document: the title, the date line, then each part under a heading (Everything), with
    /// the text's blank lines as paragraph breaks and its other line breaks kept.
    public static func buildDocx(_ s: NoteSession, part: Part) -> Data {
        var body = paragraph("Title", xmlSafe(s.title)) + paragraph(nil, xmlSafe(when(s)))
        sections(s, part, markerBullet: "") { name, text in
            if part == .everything { body += paragraph("Heading1", name) }
            for p in paragraphs(xmlSafe(text)) { body += paragraph(nil, p) }
        }
        // XmlWriter's own declaration names the encoding in lower case (the fixed parts keep Windows' "UTF-8").
        let document = "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?>" +
            "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(body)</w:body></w:document>"
        return Zip.deflated([("[Content_Types].xml", contentTypes), ("_rels/.rels", packageRels), ("word/_rels/document.xml.rels", documentRels),
                           ("word/styles.xml", styles), ("word/document.xml", document)].map { ($0.0, Data($0.1.utf8)) })
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// One paragraph in the given style (nil: Normal); its line breaks become <w:br/>.
    static func paragraph(_ style: String?, _ text: String) -> String {
        let runs = text.components(separatedBy: "\n").map { "<w:t xml:space=\"preserve\">\(escape($0))</w:t>" }.joined(separator: "<w:br/>")
        return "<w:p>" + (style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? "") + "<w:r>\(runs)</w:r></w:p>"
    }

    /// The text's paragraphs: runs of lines between blank lines; none for an empty text.
    static func paragraphs(_ text: String) -> [String] {
        var result: [String] = [], lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if !line.trimmed.isEmpty { lines.append(line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)); continue }
            if !lines.isEmpty { result.append(lines.joined(separator: "\n")); lines = [] }
        }
        if !lines.isEmpty { result.append(lines.joined(separator: "\n")) }
        return result
    }

    /// The text with its line breaks as \n and without what XML 1.0 can't carry: control characters other than tab and newline.
    static func xmlSafe(_ text: String) -> String {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return String(String.UnicodeScalarView(t.unicodeScalars.filter { $0.value >= 32 || $0 == "\t" || $0 == "\n" }
            .filter { $0.value != 0xFFFE && $0.value != 0xFFFF }))
    }
}

/// A zip archive written by hand: all a .docx needs, without a library. Windows' ZipArchive deflates each entry
/// (CompressionLevel.Optimal) and dates it now; `stored` keeps them as they are.
enum Zip {
    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func stored(_ files: [(String, Data)]) -> Data { archive(files, deflate: false, date: nil) }

    /// Each entry deflated (raw DEFLATE, method 8) and dated `date` in local time, as ZipArchive writes them.
    static func deflated(_ files: [(String, Data)], date: Date = Date()) -> Data { archive(files, deflate: true, date: date) }

    /// MS-DOS time and date (two-second steps, from 1980), local time.
    static func dosTime(_ date: Date, calendar: Calendar = .current) -> (time: Int, date: Int) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max((c.year ?? 1980) - 1980, 0), 127)
        return ((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2, year << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
    }

    private static func archive(_ files: [(String, Data)], deflate: Bool, date: Date?) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8 & 0xFF)) }
        func u32(_ v: UInt32, _ d: inout Data) { for i in 0..<4 { d.append(UInt8(v >> (8 * UInt32(i)) & 0xFF)) } }
        // A date of 1980-01-01 00:00 when none is given (a stored archive that is the same every time).
        let (time, day) = date.map { dosTime($0) } ?? (0, 0x21)
        for (name, data) in files {
            let n = Data(name.utf8), crc = crc32(data), offset = UInt32(out.count)
            // ZipArchive marks a name as UTF-8 only when it isn't plain ASCII.
            let flags = n.allSatisfy { $0 < 0x80 } ? 0 : 0x0800
            let packed = deflate ? ((try? (data as NSData).compressed(using: .zlib)) as Data?) : nil
            let body = packed ?? data, method = packed == nil ? 0 : 8
            u32(0x0403_4B50, &out); u16(20, &out); u16(flags, &out); u16(method, &out); u16(time, &out); u16(day, &out)
            u32(crc, &out); u32(UInt32(body.count), &out); u32(UInt32(data.count), &out); u16(n.count, &out); u16(0, &out)
            out.append(n); out.append(body)
            u32(0x0201_4B50, &central); u16(20, &central); u16(20, &central); u16(flags, &central); u16(method, &central); u16(time, &central); u16(day, &central)
            u32(crc, &central); u32(UInt32(body.count), &central); u32(UInt32(data.count), &central); u16(n.count, &central)
            u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central); u32(0, &central); u32(offset, &central)
            central.append(n)
        }
        let start = UInt32(out.count)
        out.append(central)
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
        u32(UInt32(central.count), &out); u32(start, &out); u16(0, &out)
        return out
    }
}
