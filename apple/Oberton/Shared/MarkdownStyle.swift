import SwiftUI
import ObertonCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// How Extended Notes' text looks read as Markdown (Windows' MarkdownRender), as attributes on the text itself: the
// source stays in the text view, every character where it is, and the Markdown syntax of the lines not being edited
// is hidden (null glyphs), a list's "-" drawn as "•". The line being edited shows its syntax. Offsets in the view are
// therefore offsets in the session's text, which the binding, the Play button and the Jump menu rely on.

extension NSAttributedString.Key {
    /// Markdown syntax on a line that is read, not edited: not drawn, and takes no room.
    static let obHidden = NSAttributedString.Key("ob.md.hidden")
    /// A list's marker character, drawn as "•".
    static let obBullet = NSAttributedString.Key("ob.md.bullet")
    /// A numbered item's ")" drawn as "." (Windows writes every number as "N.").
    static let obDot = NSAttributedString.Key("ob.md.dot")
    /// Drawn behind the line: a quote's bar, a code block's ground, a rule, the open line's ground (`MdDecor`).
    static let obDecor = NSAttributedString.Key("ob.md.decor")
}

enum MdDecor: Int { case quote = 1, code, rule, open }

/// The colours and faces the text is drawn in.
struct MarkdownLook: Equatable {
    var size: CGFloat
    var palette: Palette

    static func == (a: MarkdownLook, b: MarkdownLook) -> Bool { a.size == b.size && a.palette.dark == b.palette.dark && a.palette.accentChoice == b.palette.accentChoice }

    var ink: PlatformColor { PlatformColor(palette.ink) }
    var muted: PlatformColor { PlatformColor(palette.muted) }
    var accent: PlatformColor { PlatformColor(palette.accent) }
    var subtle: PlatformColor { PlatformColor(palette.subtle) }
    var divider: PlatformColor { PlatformColor(palette.divider) }
    /// The quote's bar (Windows' Ob.Border: solid ink).
    var border: PlatformColor { PlatformColor(palette.ink) }

    static func headingScale(_ level: Int) -> CGFloat { level == 0 ? 1 : level == 1 ? 1.55 : level == 2 ? 1.32 : level == 3 ? 1.16 : 1.05 }

    func sans(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> PlatformFont {
        let f = PlatformFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        return italic ? Self.italic(f) : f
    }

    /// The interface's mono face (Ob.monoFont).
    func mono(_ size: CGFloat, bold: Bool = false) -> PlatformFont {
        Ob.monoFont(size, bold ? .bold : .regular)
    }

    static func italic(_ f: PlatformFont) -> PlatformFont {
        #if os(macOS)
        return NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic)), size: f.pointSize) ?? f
        #else
        return f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.traitItalic)).map { UIFont(descriptor: $0, size: f.pointSize) } ?? f
        #endif
    }

    func paragraph(lineHeight: CGFloat, before: CGFloat = 0, after: CGFloat = 0, indent: CGFloat = 0, firstIndent: CGFloat? = nil, tail: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.headIndent = indent
        p.firstLineHeadIndent = firstIndent ?? indent
        p.tailIndent = tail
        return p
    }

    /// The open line's look (and what is typed into it): plain text, a heading keeping its size so the text doesn't
    /// jump as the cursor goes in and out. Its height is a TextBox's own line (the face's line spacing, 1.33 of the size)
    /// with the box's 1-px padding above and below.
    func openAttributes(headingLevel: Int) -> [NSAttributedString.Key: Any] {
        let scale = Self.headingScale(headingLevel)
        return [.font: sans(size * scale, bold: headingLevel > 0), .foregroundColor: ink,
                .paragraphStyle: paragraph(lineHeight: size * scale * 1.33 + 2, after: size * 0.3, indent: 0),
                .obDecor: MdDecor.open.rawValue]
    }

    /// New text from elsewhere, before it is styled: not shown, and taking next to no room, until the next restyle
    /// (Windows shows nothing of it, and lays nothing out for it, until its 300 ms render: READ-127).
    var pendingAttributes: [NSAttributedString.Key: Any] {
        [.font: sans(0.1), .foregroundColor: PlatformColor.clear, .paragraphStyle: paragraph(lineHeight: 0.1)]
    }
}

/// Lays the text out with the Markdown decorations drawn behind it, and hides the syntax of the lines being read.
final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var look: MarkdownLook

    init(look: MarkdownLook) {
        self.look = look
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: PlatformFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage, glyphRange.length > 0 else { return 0 }
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        var newProps = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var changed = false
        var bullet: CGGlyph = 0, dot: CGGlyph = 0
        for i in 0..<glyphRange.length {
            let c = charIndexes[i]
            guard c < storage.length else { continue }
            if storage.attribute(.obHidden, at: c, effectiveRange: nil) != nil {
                // A control glyph laid out with no width (not a null glyph, which TextKit may count to the line above).
                newProps[i] = .controlCharacter
                changed = true
            } else if storage.attribute(.obBullet, at: c, effectiveRange: nil) != nil {
                if bullet == 0 {
                    var ch: UniChar = 0x2022
                    CTFontGetGlyphsForCharacters(aFont as CTFont, &ch, &bullet, 1)
                }
                if bullet != 0 { newGlyphs[i] = bullet; changed = true }
            } else if storage.attribute(.obDot, at: c, effectiveRange: nil) != nil {
                if dot == 0 {
                    var ch: UniChar = 0x2E
                    CTFontGetGlyphsForCharacters(aFont as CTFont, &ch, &dot, 1)
                }
                if dot != 0 { newGlyphs[i] = dot; changed = true }
            }
        }
        guard changed else { return 0 }
        setGlyphs(newGlyphs, properties: newProps, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = textStorage, charIndex < storage.length, storage.attribute(.obHidden, at: charIndex, effectiveRange: nil) != nil else { return action }
        return .zeroAdvancement
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let width = container.size.width
        storage.enumerateAttribute(.obDecor, in: chars) { value, range, _ in
            guard let raw = value as? Int, let decor = MdDecor(rawValue: raw) else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = CGRect.null
            enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, _, _ in rect = rect.union(frag) }
            // An empty last line has no fragment of its own.
            if rect.isNull, range.location >= storage.length || glyphs.length == 0 { rect = extraLineFragmentRect }
            guard !rect.isNull, rect.height > 0 else { return }
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            // The space after the block (its margin) belongs to the gap, not to the block: a quote's bar and a code
            // block's ground cover its padding box only, as a WPF paragraph's border and background do.
            let last = max(range.location, NSMaxRange(range) - 1)
            let after = last < storage.length ? ((storage.attribute(.paragraphStyle, at: last, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing ?? 0) : 0
            let before = range.location < storage.length ? ((storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0) : 0
            switch decor {
            case .quote:
                let pad: CGFloat = 2
                let top = rect.minY + max(0, before - pad)
                Self.fill(CGRect(x: rect.minX, y: top, width: 2, height: rect.maxY - max(0, after - pad) - top), look.border)
            case .code:
                Self.fill(CGRect(x: rect.minX, y: rect.minY + before, width: width, height: rect.height - before - after), look.subtle)
            case .rule:
                // A 2-high paragraph with a 1-px line under it (MarkdownRender: FontSize 2, LineHeight 2, bottom border 1).
                Self.fill(CGRect(x: rect.minX, y: (rect.minY + before + 2).rounded(), width: width, height: 1), look.divider)
            case .open:
                Self.fill(CGRect(x: rect.minX - 4, y: rect.minY, width: width + 8, height: rect.height - look.size * 0.3), look.subtle, radius: 3)
            }
        }
    }

    private static func fill(_ r: CGRect, _ color: PlatformColor, radius: CGFloat = 0) {
        color.setFill()
        #if os(macOS)
        (radius > 0 ? NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) : NSBezierPath(rect: r)).fill()
        #else
        (radius > 0 ? UIBezierPath(roundedRect: r, cornerRadius: radius) : UIBezierPath(rect: r)).fill()
        #endif
    }
}

/// Puts the Markdown look on the text, line by line; a line is styled again only when it, its place in a block, or
/// whether it is open changed (new speech at the end restyles only the end).
final class MarkdownStyler {
    var look: MarkdownLook { didSet { if look != oldValue { signatures = [] } } }
    private var signatures: [Int] = []

    init(look: MarkdownLook) { self.look = look }

    /// What a line is, within the blocks.
    private struct LineInfo: Hashable {
        enum Kind: Hashable { case blank, fence, block(NotesMarkdown.Kind) }
        var kind = Kind.blank
        var level = 0
        var first = true
        var last = true
        /// The space before the block once its margin has collapsed with the one after the block above (a WPF
        /// FlowDocument keeps the larger of two touching margins; TextKit would add them).
        var before: CGFloat = 0
    }

    /// A block's own margins (MarkdownRender.MakeParagraph): above its first line, below its last.
    private func margins(_ info: LineInfo) -> (before: CGFloat, after: CGFloat) {
        let size = look.size
        switch info.kind {
        case .blank: return (0, 0)
        case .fence: return (0, info.last ? size * 0.75 : 0)
        case .block(let kind):
            switch kind {
            case .heading: return (info.first ? size * 0.5 : 0, info.last ? size * 0.4 : 0)
            case .bullet, .numbered: return (0, info.last ? size * 0.3 : 0)
            case .rule: return (size * 0.3, size * 0.9)
            case .code: return (0, 0) // its fences carry its space
            case .quote, .marker, .paragraph: return (0, info.last ? size * 0.75 : 0)
            }
        }
    }

    /// The lines of a text: each one's range without its line break (and a "\r" before it), and with it.
    static func lines(_ s: NSString) -> [(content: NSRange, full: NSRange)] {
        var out: [(NSRange, NSRange)] = []
        var start = 0
        while true {
            let nl = s.range(of: "\n", range: NSRange(location: start, length: s.length - start)).location
            let end = nl == NSNotFound ? s.length : nl
            var contentEnd = end
            if contentEnd > start, s.character(at: contentEnd - 1) == 0x0D { contentEnd -= 1 }
            out.append((NSRange(location: start, length: contentEnd - start), NSRange(location: start, length: (nl == NSNotFound ? end : end + 1) - start)))
            if nl == NSNotFound { break }
            start = nl + 1
        }
        return out
    }

    /// The line holding `offset`.
    static func lineIndex(_ lines: [(content: NSRange, full: NSRange)], _ offset: Int) -> Int {
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].full.location <= offset { lo = mid } else { hi = mid - 1 }
        }
        return max(0, lo)
    }

    /// Style the text; `open` is the line being edited. Returns whether anything was restyled.
    @discardableResult
    func apply(_ storage: NSTextStorage, open: Int?) -> Bool {
        let ns = storage.string as NSString
        let lines = Self.lines(ns)
        var info = [LineInfo](repeating: LineInfo(), count: lines.count)
        var spans = [[NotesMarkdown.Span]](repeating: [], count: lines.count)
        var blocks = [NotesMarkdown.Block?](repeating: nil, count: lines.count)
        let fence = try! NSRegularExpression(pattern: #"^\s*```"#)
        func isFence(_ i: Int) -> Bool {
            i < lines.count && fence.firstMatch(in: storage.string, range: lines[i].content) != nil
        }
        for b in NotesMarkdown.parse(storage.string, escapesApart: true) { // rendered in place: each span at its own characters
            let first = Self.lineIndex(lines, b.offset)
            var last = b.spans.last.map { Self.lineIndex(lines, $0.offset) } ?? first
            if b.kind == .code {
                info[first] = LineInfo(kind: .fence, first: true, last: false)
                let inner = b.spans.isEmpty ? first : last
                if inner + 1 < lines.count, isFence(inner + 1) { info[inner + 1] = LineInfo(kind: .fence, first: false, last: true) }
                last = inner
                if b.spans.isEmpty { continue }
            }
            let from = b.kind == .code ? Self.lineIndex(lines, b.spans[0].offset) : first
            for l in from...max(from, last) where l < lines.count {
                info[l] = LineInfo(kind: .block(b.kind), level: b.level, first: l == from, last: l == last)
                blocks[l] = b
            }
            for s in b.spans where !s.isBreak && !s.text.isEmpty { spans[Self.lineIndex(lines, s.offset)].append(s) }
        }
        // Margins collapse across blank lines: the space between two blocks is the larger of the two.
        var above: CGFloat = 0
        for i in info.indices {
            // The open line is Windows' line box (a BlockUIContainer, Margin 0,0,0,0.3 × size): its own gap below
            // collapses with the next block's top margin, whatever block the line belongs to (READ-130, READ-N019).
            if i == open {
                info[i].before = 0
                above = look.size * 0.3
                continue
            }
            if case .blank = info[i].kind { continue }
            let m = margins(info[i])
            info[i].before = max(0, m.before - above)
            above = m.after
        }

        var changed = false
        storage.beginEditing()
        var next: [Int] = []
        next.reserveCapacity(lines.count)
        for (i, line) in lines.enumerated() {
            var h = Hasher()
            h.combine(ns.substring(with: line.full))
            h.combine(info[i])
            h.combine(open == i)
            h.combine(blocks[i]?.number)
            let sig = h.finalize()
            next.append(sig)
            if i < signatures.count, signatures[i] == sig { continue }
            changed = true
            if open == i { styleOpen(storage, ns, line.content, line.full) }
            else { style(storage, ns, line.content, line.full, info[i], blocks[i], spans[i]) }
        }
        storage.endEditing()
        signatures = next
        return changed
    }

    /// Forget what was styled (the text was replaced as a whole, or the look changed).
    func reset() { signatures = [] }

    private func styleOpen(_ storage: NSTextStorage, _ ns: NSString, _ content: NSRange, _ full: NSRange) {
        let level = NotesMarkdown.parse(ns.substring(with: content)).first.map { $0.kind == .heading ? $0.level : 0 } ?? 0
        storage.setAttributes(look.openAttributes(headingLevel: level), range: full)
    }

    private func style(_ storage: NSTextStorage, _ ns: NSString, _ content: NSRange, _ full: NSRange, _ info: LineInfo,
                       _ block: NotesMarkdown.Block?, _ spans: [NotesMarkdown.Span]) {
        let size = look.size
        let after = margins(info).after
        // Windows' FlowDocument line height, size × 1.55, as it is (not rounded).
        let line = size * 1.55
        let body = look.paragraph(lineHeight: line, before: info.before, after: after)
        var base: [NSAttributedString.Key: Any] = [.font: look.sans(size), .foregroundColor: look.ink, .paragraphStyle: body]
        var color = look.ink
        var scale: CGFloat = 1
        var bold = false
        var mono = false
        switch info.kind {
        case .blank:
            // A blank line between blocks takes no room (Windows makes no paragraph of it): the blocks' own margins are
            // the gap.
            base[.font] = look.sans(1)
            base[.paragraphStyle] = look.paragraph(lineHeight: 0.01)
        case .fence:
            // The fences are the code block's padding (6 above and below); the closing one its margin below.
            base[.font] = look.sans(1)
            base[.paragraphStyle] = look.paragraph(lineHeight: 6, before: info.before, after: after)
            base[.obDecor] = MdDecor.code.rawValue
        case .block(let kind):
            switch kind {
            case .heading:
                scale = MarkdownLook.headingScale(info.level)
                bold = true
                base[.paragraphStyle] = look.paragraph(lineHeight: size * scale * 1.3, before: info.before, after: after)
            case .bullet, .numbered:
                let indent = 20 + CGFloat(info.level) * 20
                base[.paragraphStyle] = look.paragraph(lineHeight: line, before: info.before, after: after, indent: indent, firstIndent: indent - 16)
            case .quote:
                // Padding 12,2,0,2 inside a 2-px bar: 2 above the first line and below the last, then the margin.
                color = look.muted
                base[.paragraphStyle] = look.paragraph(lineHeight: line, before: info.first ? info.before + 2 : 0,
                                                       after: info.last ? after + 2 : 0, indent: 14)
                base[.obDecor] = MdDecor.quote.rawValue
            case .code:
                // The code inherits the document's line height (only its size is 0.92).
                mono = true
                base[.paragraphStyle] = look.paragraph(lineHeight: line, indent: 10, tail: -10)
                base[.obDecor] = MdDecor.code.rawValue
            case .rule:
                base[.font] = look.sans(1)
                base[.paragraphStyle] = look.paragraph(lineHeight: 3, before: info.before, after: after)
                base[.obDecor] = MdDecor.rule.rawValue
            case .marker:
                color = look.accent
                base[.paragraphStyle] = look.paragraph(lineHeight: line, before: info.before, after: after)
            case .paragraph:
                break
            }
        }
        base[.foregroundColor] = color
        storage.setAttributes(base, range: full)
        // Everything on the line is syntax unless a span shows it.
        if content.length > 0 { storage.addAttribute(.obHidden, value: true, range: content) }
        for s in spans {
            let r = NSRange(location: s.offset, length: s.text.utf16.count)
            guard NSMaxRange(r) <= NSMaxRange(content) else { continue }
            storage.removeAttribute(.obHidden, range: r)
            var font: PlatformFont
            if case .block(.marker) = info.kind { font = look.mono(size * 0.9, bold: true) }
            else if mono { font = look.mono(size * 0.92) }
            else if s.code {
                // Inline code keeps the run's bold and italic, and a heading's bold (MarkdownRender keeps them on the run).
                font = look.mono(size * 0.92, bold: bold || s.bold)
                if s.italic { font = MarkdownLook.italic(font) }
            }
            else { font = look.sans(size * scale, bold: bold || s.bold, italic: s.italic) }
            storage.addAttribute(.font, value: font, range: r)
            if s.code && !mono { storage.addAttribute(.backgroundColor, value: look.subtle, range: r) }
        }
        // A list item's bullet or number, muted, at the body size, then two spaces' room ("•  ", "N.  "): every
        // number is written with a dot.
        if case .block(let kind) = info.kind, kind == .bullet || kind == .numbered, info.first {
            let lead = (ns.substring(with: content) as String).utf16.prefix { NotesMarkdown.white($0) }.count
            let at = content.location + lead
            let markLength = kind == .bullet ? 1 : (block?.number.utf16.count ?? 1) + 1
            let mark = NSRange(location: at, length: min(markLength + 1, NSMaxRange(content) - at))
            let face = look.sans(size)
            storage.removeAttribute(.obHidden, range: mark)
            storage.addAttribute(.foregroundColor, value: look.muted, range: mark)
            storage.addAttribute(.font, value: face, range: mark)
            if kind == .bullet {
                storage.addAttribute(.obBullet, value: true, range: NSRange(location: at, length: 1))
            } else if markLength <= mark.length, ns.character(at: at + markLength - 1) == 0x29 {
                storage.addAttribute(.obDot, value: true, range: NSRange(location: at + markLength - 1, length: 1))
            }
            if mark.length > markLength {
                let space = (" " as NSString).size(withAttributes: [.font: face]).width
                storage.addAttribute(.kern, value: space, range: NSRange(location: at + markLength, length: 1))
            }
        }
    }
}

/// The text read as Markdown, as plain SwiftUI: for the DEBUG snapshots, which can't draw a text view.
struct MarkdownReadingView: View {
    var text: String
    var size: CGFloat
    @Environment(\.ob) private var ob

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(NotesMarkdown.parse(text).enumerated()), id: \.offset) { _, b in block(b) }
        }
        .foregroundStyle(ob.ink)
    }

    @ViewBuilder private func block(_ b: NotesMarkdown.Block) -> some View {
        switch b.kind {
        case .heading:
            let s = MarkdownLook.headingScale(b.level)
            Text(line(b.spans, size * s, bold: true)).padding(.top, size * 0.5).padding(.bottom, size * 0.4)
        case .bullet, .numbered:
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(b.kind == .bullet ? "•" : b.number + ".").font(.system(size: size)).foregroundStyle(ob.muted).frame(width: 16, alignment: .leading)
                Text(line(b.spans, size))
            }
            .padding(.leading, 4 + CGFloat(b.level) * 20).padding(.bottom, size * 0.3)
        case .quote:
            Text(line(b.spans, size)).foregroundStyle(ob.muted).padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(ob.divider).frame(width: 2) }.padding(.bottom, size * 0.75)
        case .code:
            Text(line(b.spans, size * 0.92, mono: true)).padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading).background(ob.subtle).padding(.bottom, size * 0.75)
        case .rule:
            Rectangle().fill(ob.divider).frame(height: 1).padding(.top, size * 0.3).padding(.bottom, size * 0.9)
        case .marker:
            Text(b.spans.map(\.text).joined()).font(.system(size: size * 0.9, weight: .bold, design: .monospaced)).foregroundStyle(ob.accent).padding(.bottom, size * 0.75)
        case .paragraph:
            Text(line(b.spans, size)).padding(.bottom, size * 0.75)
        }
    }

    private func line(_ spans: [NotesMarkdown.Span], _ size: CGFloat, bold: Bool = false, mono: Bool = false) -> AttributedString {
        var out = AttributedString()
        for s in spans {
            if s.isBreak { out += AttributedString("\n"); continue }
            var r = AttributedString(s.text)
            var font: Font = mono || s.code ? .system(size: size * (s.code && !mono ? 0.92 : 1), design: .monospaced) : .system(size: size, weight: bold || s.bold ? .bold : .regular)
            if s.italic { font = font.italic() }
            r.font = font
            if s.code && !mono { r.backgroundColor = ob.subtle }
            out += r
        }
        return out
    }
}
