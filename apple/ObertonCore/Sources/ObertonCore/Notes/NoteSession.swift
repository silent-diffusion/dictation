import Foundation

/// What Extended Notes listens to.
public enum NotesSource: String, Codable, Sendable, CaseIterable {
    case mic = "Mic", computer = "Computer", both = "Both"
}

/// The texts of a session, as the tabs show them (Edited is worked out from the others).
public enum NoteDoc: Sendable { case transcript, formatted, summary }

/// A place in a text and the moment of the recording it belongs to.
public struct NoteAnchor: Codable, Sendable, Equatable {
    public var offset: Int
    public var seconds: Double
    /// Where the piece begins in `NoteSession.heard` (transcript anchors; nil for markers), so a part of the transcript
    /// can be lined up with what was heard.
    public var heardOffset: Int?
}

/// A moment the listener marked (the marker hotkey or the Mark button) while the session recorded. The transcript has a
/// line for it: `NoteSession.markerFlag` and `label`.
public struct NoteMarker: Codable, Sendable, Equatable {
    public var seconds: Double
    /// The time as its line shows it: 12:34, or 1:02:03 once there are hours.
    public var label: String
}

/// One formatting step: what had been heard, what the transcript said (the user's edits included) when it was sent to
/// the AI, and what the AI made of it. The Edited tab is built from these.
public struct NoteChunk: Codable, Sendable, Equatable {
    public var heard: String
    public var sent: String
    public var ai: String
    public var seconds: Double
    /// The AI was unavailable or its output was rejected: `ai` is the text as sent.
    public var aiFailed: Bool

    public init(heard: String, sent: String, ai: String, seconds: Double, aiFailed: Bool) {
        self.heard = heard; self.sent = sent; self.ai = ai; self.seconds = seconds; self.aiFailed = aiFailed
    }
}

/// A summary of part of the session, kept in the background. Level 0 sums up a section of the formatted text; a higher
/// level sums up several consecutive summaries. The Summary tab is written from the ones not folded into a higher level.
public struct NoteDigest: Codable, Sendable, Equatable {
    public var level: Int
    /// The sections it covers, numbered in order (a level 0 digest covers one).
    public var first: Int
    public var last: Int
    /// The part of the recording it covers, in seconds.
    public var start: Double
    public var end: Double
    public var text: String
    /// Folded into a higher-level digest.
    public var merged = false

    public init(level: Int, first: Int, last: Int, start: Double, end: Double, text: String, merged: Bool = false) {
        self.level = level; self.first = first; self.last = last; self.start = start; self.end = end; self.text = text; self.merged = merged
    }
}

/// Offsets in session texts are UTF-16 code units, as on Windows and in the text views' selections.
extension String {
    var u16: Int { utf16.count }

    /// The text between two UTF-16 offsets (clamped).
    func u16(_ from: Int, _ to: Int? = nil) -> String {
        let n = utf16.count
        let a = Swift.max(0, Swift.min(from, n)), b = Swift.max(a, Swift.min(to ?? n, n))
        let ua = utf16.index(utf16.startIndex, offsetBy: a), ub = utf16.index(utf16.startIndex, offsetBy: b)
        return String(utf16[ua..<ub]) ?? String(self[(ua.samePosition(in: self) ?? startIndex)..<(ub.samePosition(in: self) ?? endIndex)])
    }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// One Extended Notes session: a lecture or meeting, transcribed as it goes. `heard` is what the recognizer produced
/// (never changed); `transcript`, `formatted` and `summary` are the texts as the user edited them. Time anchors map
/// text positions to the recording and move with the user's edits (NoteSession.cs).
public final class NoteSession: Codable, Identifiable, @unchecked Sendable {
    public var title = ""
    public var started = Date()
    /// Seconds recorded (pauses not counted); the length of audio.wav.
    public var seconds = 0.0
    public var source = NotesSource.mic
    /// False while recording (and after a crash until the next start, which closes it).
    public var finished = false
    public var formatVersion = NotesFormat.version

    public var heard = ""
    public var transcript = ""
    public var formatted = ""
    public var summary = ""

    /// How much of `transcript` (and of `heard`) has been formatted.
    public var formattedThrough = 0
    public var heardFormattedThrough = 0
    /// How much of `formatted` the section summaries cover.
    public var summarizedThrough = 0
    public var digests: [NoteDigest] = []
    /// The summary as the AI last wrote it: when `summary` differs, the user edited it, and the next summary keeps it.
    public var summaryByAi = ""

    public var chunks: [NoteChunk] = []
    public var transcriptAnchors: [NoteAnchor] = []
    public var formattedAnchors: [NoteAnchor] = []
    public var markers: [NoteMarker] = []

    /// The session's folder (session.json and audio.wav); not saved.
    public var folder: URL?
    public var audioURL: URL? { folder?.appending(path: "audio.wav") }
    public var id: String { folder?.lastPathComponent ?? title }

    /// A text changed; the argument is whoever changed it, so it can skip its own change.
    public var changed: ((NoteDoc, AnyObject?) -> Void)?

    // Ends of a formatting or summary request still on its way, moved with the user's edits meanwhile; -1 when none.
    private var pendingFormatEnd = -1
    private var pendingSummaryEnd = -1

    enum CodingKeys: String, CodingKey {
        case title, started, seconds, source, finished, formatVersion, heard, transcript, formatted, summary, formattedThrough,
             heardFormattedThrough, summarizedThrough, digests, summaryByAi, chunks, transcriptAnchors, formattedAnchors, markers
    }

    public init() {}

    public func get(_ doc: NoteDoc) -> String {
        switch doc {
        case .formatted: formatted
        case .summary: summary
        case .transcript: transcript
        }
    }

    /// A finished piece from the recognizer, at `seconds` into the recording.
    public func appendHeard(_ text: String, seconds: Double, source: AnyObject? = nil) {
        let text = text.trimmed
        if text.isEmpty { return }
        let heardAt = heard.isEmpty ? 0 : heard.u16 + 1
        heard = heard.isEmpty ? text : heard + " " + text
        let sep = transcript.isEmpty || transcript.last!.isWhitespace ? "" : " "
        transcriptAnchors.append(NoteAnchor(offset: transcript.u16 + sep.u16, seconds: seconds, heardOffset: heardAt))
        transcript += sep + text
        changed?(.transcript, source)
    }

    /// Begins a marker's line in the transcript (the AI is told to keep such lines as they are).
    public static let markerFlag = "⚑"

    /// A marker's time as its line shows it: m:ss, with the hours once there are any (12:34; 1:02:03).
    public static func markerLabel(_ seconds: Double) -> String {
        let t = Int(max(0, seconds))
        let h = t / 3600, m = t / 60 % 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The listener marked `seconds` into the recording: a "⚑ m:ss" line of its own goes on the end of the transcript,
    /// with an anchor. Like `appendHeard` it only appends, so how far formatting got stays where it is.
    public func addMarker(_ seconds: Double, source: AnyObject? = nil) {
        appendMarkerLine(seconds)
        markers.append(NoteMarker(seconds: seconds, label: Self.markerLabel(seconds)))
        changed?(.transcript, source)
    }

    private func appendMarkerLine(_ seconds: Double) {
        let sep = transcript.isEmpty || transcript.hasSuffix("\n") ? "" : "\n"
        transcriptAnchors.append(NoteAnchor(offset: transcript.u16 + sep.u16, seconds: seconds, heardOffset: nil))
        transcript += sep + Self.markerFlag + " " + Self.markerLabel(seconds) + "\n"
    }

    // MARK: Redoing a step (a finished session)

    /// A new transcript, from the recording transcribed again: these pieces, with the markers back in place by their
    /// time. What was formatted and summed up goes with the old one.
    public func replaceTranscript(_ pieces: [(seconds: Double, text: String)], source: AnyObject? = nil) {
        heard = ""
        transcript = ""
        transcriptAnchors = []
        resetFormatting(source: source)
        let marks = markers.sorted { $0.seconds < $1.seconds }
        var next = 0
        for piece in pieces.sorted(by: { $0.seconds < $1.seconds }) {
            while next < marks.count && marks[next].seconds <= piece.seconds { appendMarkerLine(marks[next].seconds); next += 1 }
            appendHeard(piece.text, seconds: piece.seconds)
        }
        while next < marks.count { appendMarkerLine(marks[next].seconds); next += 1 }
        changed?(.transcript, source)
    }

    /// Formatting from scratch: the Formatted text, its steps and the summary go.
    public func resetFormatting(source: AnyObject? = nil) {
        formatted = ""
        chunks = []
        formattedAnchors = []
        formattedThrough = 0
        heardFormattedThrough = 0
        pendingFormatEnd = -1
        resetSummary(source: source)
        changed?(.formatted, source)
    }

    /// Summing up from scratch.
    public func resetSummary(source: AnyObject? = nil) {
        digests = []
        summarizedThrough = 0
        summary = ""
        summaryByAi = ""
        pendingSummaryEnd = -1
        changed?(.summary, source)
    }

    /// The user edited a text: keep the anchors and the formatting marks in step.
    public func set(_ doc: NoteDoc, _ text: String, source: AnyObject?) {
        let old = get(doc)
        if old == text { return }
        let (offset, removed, added) = Self.change(old, text)
        switch doc {
        case .transcript:
            transcript = text
            Self.shift(&transcriptAnchors, offset, removed, added)
            formattedThrough = Self.move(formattedThrough, offset, removed, added)
            if pendingFormatEnd >= 0 { pendingFormatEnd = Self.move(pendingFormatEnd, offset, removed, added) }
        case .formatted:
            formatted = text
            Self.shift(&formattedAnchors, offset, removed, added)
            summarizedThrough = Self.move(summarizedThrough, offset, removed, added)
            if pendingSummaryEnd >= 0 { pendingSummaryEnd = Self.move(pendingSummaryEnd, offset, removed, added) }
        case .summary:
            summary = text
        }
        changed?(doc, source)
    }

    /// The one edit that turns `old` into `now`: where, how much went, how much came (UTF-16 units).
    public static func change(_ old: String, _ now: String) -> (offset: Int, removed: Int, added: Int) {
        let a = Array(old.utf16), b = Array(now.utf16)
        var prefix = 0
        let most = min(a.count, b.count)
        while prefix < most && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < most - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return (prefix, a.count - prefix - suffix, b.count - prefix - suffix)
    }

    /// Where a position ends up after an edit: before it, it stays; after it, it moves by the change in length; inside
    /// what was removed, it lands at the edit. Text typed right at a boundary stays after it, so it is formatted next.
    public static func move(_ pos: Int, _ offset: Int, _ removed: Int, _ added: Int) -> Int {
        pos <= offset ? pos : pos >= offset + removed ? pos + added - removed : offset + added
    }

    /// The same for a time anchor: text typed right at the start of a piece goes before it.
    public static func moveAnchor(_ pos: Int, _ offset: Int, _ removed: Int, _ added: Int) -> Int {
        pos < offset ? pos : pos >= offset + removed ? pos + added - removed : offset + added
    }

    private static func shift(_ anchors: inout [NoteAnchor], _ offset: Int, _ removed: Int, _ added: Int) {
        for i in anchors.indices { anchors[i].offset = moveAnchor(anchors[i].offset, offset, removed, added) }
    }

    /// The moment of the recording that the text at `caret` was said. In the transcript, the start of the piece it is
    /// in. In the formatted text, where each AI step covers a minute or so, the position within that step, in proportion.
    public func secondsAt(_ doc: NoteDoc, _ caret: Int) -> Double {
        if doc != .formatted {
            var seconds = 0.0
            for a in transcriptAnchors {
                if a.offset > caret { break }
                seconds = a.seconds
            }
            return seconds
        }
        var at: NoteAnchor?, next: NoteAnchor?
        for a in formattedAnchors {
            if a.offset <= caret { at = a } else { next = a; break }
        }
        guard let at else { return next?.seconds ?? 0 }
        let endOffset = next?.offset ?? formatted.u16
        let endSeconds = next?.seconds ?? formattedEndSeconds()
        if endOffset <= at.offset || endSeconds <= at.seconds { return at.seconds }
        let f = min(max(Double(caret - at.offset) / Double(endOffset - at.offset), 0), 1)
        return at.seconds + f * (endSeconds - at.seconds)
    }

    /// Where the formatted text ends in the recording: where the transcript not formatted yet begins.
    public func formattedEndSeconds() -> Double {
        transcriptAnchors.first { $0.offset >= formattedThrough }?.seconds ?? seconds
    }

    // MARK: Formatting and summary steps

    /// Words not formatted yet.
    public func unformattedWords() -> Int { Self.words(transcript.u16(formattedThrough)) }

    public static func words(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }

    /// Take the transcript not formatted yet (to send to the AI); nil when there is none.
    public func beginFormat() -> (heard: String, sent: String, seconds: Double)? {
        let from = min(formattedThrough, transcript.u16)
        let sent = transcript.u16(from)
        if sent.trimmed.isEmpty { return nil }
        pendingFormatEnd = transcript.u16
        let heardPart = heard.u16(heardFormattedThrough)
        heardFormattedThrough = heard.u16
        let secs = transcriptAnchors.first { $0.offset >= from }?.seconds ?? seconds
        return (heardPart.trimmed, sent.trimmed, secs)
    }

    /// Like `beginFormat`, but at most about `maxWords` words, ending where a piece ends (at the end of a sentence if one
    /// does), for formatting a whole transcript again part by part.
    public func beginFormatPart(maxWords: Int) -> (heard: String, sent: String, seconds: Double)? {
        let from = min(formattedThrough, transcript.u16)
        if transcript.u16(from).trimmed.isEmpty { return nil }
        var any: NoteAnchor?, sentence: NoteAnchor?, first: NoteAnchor?
        for a in transcriptAnchors.filter({ $0.offset > from && $0.offset <= transcript.u16 }).sorted(by: { $0.offset < $1.offset }) {
            let n = Self.words(transcript.u16(from, a.offset))
            if n == 0 { continue }
            if first == nil { first = a }
            if n > maxWords { break }
            any = a
            let before = transcript.u16(0, a.offset).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let lastLine = (before.components(separatedBy: "\n").last ?? "").trimmingCharacters(in: .whitespaces)
            if let c = before.last, ".!?\"”".contains(c) || lastLine.hasPrefix(Self.markerFlag) { sentence = a }
        }
        // All the rest when it fits; otherwise to a sentence's end, else a piece's; a first piece longer than the limit whole.
        let cut = Self.words(transcript.u16(from)) <= maxWords ? nil : sentence ?? any ?? first
        let end = cut?.offset ?? transcript.u16
        let sent = transcript.u16(from, end)
        pendingFormatEnd = end
        let heardFrom = min(heardFormattedThrough, heard.u16)
        let heardPart: String
        if cut == nil {
            heardPart = heard.u16(heardFrom)
            heardFormattedThrough = heard.u16
        } else if let h = cut?.heardOffset, h >= heardFrom, h <= heard.u16 {
            heardPart = heard.u16(heardFrom, h)
            heardFormattedThrough = h
        } else {
            heardPart = sent
        }
        let secs = transcriptAnchors.first { $0.offset >= from }?.seconds ?? seconds
        return (heardPart.trimmed, sent.trimmed, secs)
    }

    /// The AI's formatting of what `beginFormat` took: appended to `formatted`.
    public func endFormat(heard: String, sent: String, ai: String, seconds: Double, failed: Bool, source: AnyObject? = nil) {
        let ai = ai.trimmed
        chunks.append(NoteChunk(heard: heard, sent: sent, ai: ai, seconds: seconds, aiFailed: failed))
        formattedThrough = pendingFormatEnd >= 0 ? pendingFormatEnd : transcript.u16
        pendingFormatEnd = -1
        // A part that carries on a sentence the last one left open joins it; otherwise it starts a paragraph.
        let continues = !formatted.isEmpty && (ai.first?.isLowercase ?? false) &&
            ((formatted.last?.isLetter ?? false) || (formatted.last?.isNumber ?? false) || formatted.last == ",")
        let sep = formatted.isEmpty ? "" : continues ? " " : formatted.hasSuffix("\n\n") ? "" : formatted.hasSuffix("\n") ? "\n" : "\n\n"
        formattedAnchors.append(NoteAnchor(offset: formatted.u16 + sep.u16, seconds: seconds, heardOffset: nil))
        formatted += sep + ai
        changed?(.formatted, source)
    }

    /// Formatted text no section summary covers yet.
    public func unsummarizedChars() -> Int { formatted.u16 - min(summarizedThrough, formatted.u16) }

    /// The next section to summarize: the formatted text not covered yet, at most `maxChars` (cut at a paragraph or
    /// sentence), with the part of the recording it covers; nil when there is none.
    public func beginSection(maxChars: Int) -> (text: String, start: Double, end: Double)? {
        let from = min(summarizedThrough, formatted.u16)
        let end = NotesSummary.sectionEnd(formatted, from: from, maxChars: maxChars)
        let text = formatted.u16(from, end)
        if text.trimmed.isEmpty { return nil }
        pendingSummaryEnd = end
        let start = secondsAt(.formatted, from)
        let stop = end >= formatted.u16 ? formattedEndSeconds() : secondsAt(.formatted, end)
        return (text.trimmed, start, max(start, stop))
    }

    /// The summary of what `beginSection` took; nil when it failed (the same text is tried again next time).
    public func endSection(_ digest: String?, start: Double, end: Double) {
        let through = pendingSummaryEnd
        pendingSummaryEnd = -1
        guard let digest, !digest.trimmed.isEmpty else { return }
        let number = digests.filter { $0.level == 0 }.count
        digests.append(NoteDigest(level: 0, first: number, last: number, start: start, end: end, text: digest.trimmed))
        summarizedThrough = through >= 0 ? through : formatted.u16
    }

    /// The digests not folded into a higher level, in order: together they cover everything summarized.
    public func frontier() -> [NoteDigest] { digests.filter { !$0.merged }.sorted { $0.first < $1.first } }

    /// Several consecutive digests summed up in one, a level up.
    public func merge(_ parts: [NoteDigest], text: String) {
        for i in digests.indices where parts.contains(where: { $0.level == digests[i].level && $0.first == digests[i].first && !digests[i].merged }) {
            digests[i].merged = true
        }
        digests.append(NoteDigest(level: (parts.map(\.level).max() ?? 0) + 1, first: parts.map(\.first).min() ?? 0, last: parts.map(\.last).max() ?? 0,
                                  start: parts.map(\.start).min() ?? 0, end: parts.map(\.end).max() ?? 0, text: text.trimmed))
    }

    /// The new summary for the Summary tab. Skipped (false) when the user changed the summary meanwhile.
    @discardableResult
    public func endSummary(_ text: String, basedOn: String, source: AnyObject? = nil) -> Bool {
        if summary != basedOn || text.trimmed.isEmpty { return false }
        summary = text.trimmed
        summaryByAi = summary
        changed?(.summary, source)
        return true
    }
}
