import SwiftUI
import ObertonCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Edited tab's text (NotesPage.BuildEdited): read only, every change in colour. The AI's in the accent (added) and
/// struck through in grey (removed), a ¶ where it made a paragraph; the user's in their own ink (amber): struck through
/// with a thick line, bold on a wash, or bold and underlined. 14.5 pt on 24-pt lines, 12 pt between paragraphs. Each run
/// knows the moment its first word was said, for the right-click "Jump to this moment". While the session records,
/// it is built again at most every 4 s; the scroll position stays.
@MainActor
struct EditedTextView {
    var session: NoteSession
    var revision: Int
    var live: Bool
    /// Whether the Edited tab shows. The view lives on while another tab shows, so it keeps its scroll position; it is
    /// built only while shown, and again at once when it shows (NotesPage builds it on the tab's switch).
    var shown = true
    /// The right-click item for the moment of a run (nil: no moment there).
    var jump: (Double?) -> MarkdownJump

    func makeCoordinator() -> EditedTextController { EditedTextController() }

    fileprivate func update(_ c: EditedTextController, palette: Palette) {
        c.jump = jump
        c.setShown(shown)
        if shown { c.show(session, revision: revision, live: live, palette: palette) }
    }
}

extension NSAttributedString.Key {
    /// When the run's first word was said (seconds into the recording).
    static let obSeconds = NSAttributedString.Key("ob.edited.seconds")
}

@MainActor
final class EditedTextController: NSObject {
    var jump: (Double?) -> MarkdownJump = { _ in MarkdownJump(title: "", enabled: false, action: {}) }
    private var built: (session: ObjectIdentifier, revision: Int, dark: Bool, accent: AccentChoice)?
    private var builtAt = Date.distantPast
    private var pending: DispatchWorkItem?
    #if os(macOS)
    private(set) var textView: EditedNSTextView!
    #else
    private(set) var textView: EditedUITextView!
    #endif

    static func userInk(_ ob: Palette) -> PlatformColor { PlatformColor(EditedText.userInk(ob)) }
    static func userWash(_ ob: Palette) -> PlatformColor { PlatformColor(EditedText.userWash(ob)) }

    private var isShown = true
    /// It has just shown again: built at once, however recently it was built.
    private var justShown = false

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        if shown { justShown = true } else { pending?.cancel(); pending = nil }
        #if os(macOS)
        if !shown, let tv = textView, tv.window?.firstResponder === tv { tv.window?.makeFirstResponder(nil) }
        textView?.enclosingScrollView?.isHidden = !shown
        #else
        textView?.isHidden = !shown
        #endif
    }

    func show(_ s: NoteSession, revision: Int, live: Bool, palette: Palette) {
        let key = (ObjectIdentifier(s), revision, palette.dark, palette.accentChoice)
        let now = justShown
        justShown = false
        if let b = built, b.session == key.0, b.revision == key.1, b.dark == key.2, b.accent == key.3 { return }
        let lookChanged = now || (built.map { $0.dark != palette.dark || $0.accent != palette.accentChoice || $0.session != key.0 } ?? true)
        // While the session records, at most every 4 s (an hour of notes stays quick to show).
        let wait = live && !lookChanged ? 4 - Date().timeIntervalSince(builtAt) : 0
        pending?.cancel()
        guard wait <= 0 else {
            let work = DispatchWorkItem { [weak self] in self?.build(s, revision: revision, palette: palette) }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            return
        }
        build(s, revision: revision, palette: palette)
    }

    private func build(_ s: NoteSession, revision: Int, palette: Palette) {
        built = (ObjectIdentifier(s), revision, palette.dark, palette.accentChoice)
        builtAt = Date()
        let text = Self.attributed(NotesEdits.build(s), palette: palette)
        #if os(macOS)
        guard let tv = textView, let storage = tv.textStorage else { return }
        let origin = tv.enclosingScrollView?.contentView.bounds.origin
        storage.setAttributedString(text)
        if let origin { tv.enclosingScrollView?.contentView.scroll(to: origin); tv.enclosingScrollView?.reflectScrolledClipView(tv.enclosingScrollView!.contentView) }
        #else
        guard let tv = textView else { return }
        let offset = tv.contentOffset
        tv.attributedText = text
        tv.setContentOffset(offset, animated: false)
        #endif
    }

    /// Neighbouring words with the same mark become one run; a paragraph mark ends the paragraph.
    static func attributed(_ pieces: [EditPiece], palette ob: Palette) -> NSAttributedString {
        let look = MarkdownLook(size: 14.5, palette: ob)
        let para = look.paragraph(lineHeight: 24, after: 12)
        let base: [NSAttributedString.Key: Any] = [.font: look.sans(14.5), .foregroundColor: look.ink, .paragraphStyle: para]
        let out = NSMutableAttributedString()
        // Nothing but plain paragraph breaks makes no paragraph either (NotesPage: `doc.Blocks.Count == 0`).
        if pieces.allSatisfy({ $0.mark == .paragraph }) {
            out.append(NSAttributedString(string: "Nothing yet: changes show here once the AI has formatted some text or you have edited it.",
                                          attributes: base.merging([.foregroundColor: look.muted]) { $1 }))
            return out
        }
        var mark: EditMark?
        var at = 0.0
        var run = ""
        var paragraphHasText = false
        func flush() {
            if let mark, !run.isEmpty {
                var a = styled(mark, look: look, ob: ob, base: base)
                a[.obSeconds] = at
                out.append(NSAttributedString(string: run, attributes: a))
                out.append(NSAttributedString(string: " ", attributes: base.merging([.obSeconds: at]) { $1 }))
                paragraphHasText = true
            }
            run = ""
        }
        for p in pieces {
            if p.mark == .paragraph || p.mark == .aiParagraph {
                flush()
                if p.mark == .aiParagraph {
                    out.append(NSAttributedString(string: "¶", attributes: base.merging([.foregroundColor: look.accent, .font: look.sans(14.5, bold: true),
                                                                                        .obSeconds: p.seconds]) { $1 }))
                    paragraphHasText = true
                }
                if paragraphHasText { out.append(NSAttributedString(string: "\n", attributes: base)); paragraphHasText = false }
                mark = nil
                continue
            }
            if mark != p.mark { flush(); mark = p.mark; at = p.seconds }
            if !run.isEmpty { run += " " }
            run += p.text
        }
        flush()
        // The last paragraph has no break after it.
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    static func styled(_ mark: EditMark, look: MarkdownLook, ob: Palette, base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var a = base
        let user = userInk(ob)
        switch mark {
        case .aiRemoved:
            a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            a[.foregroundColor] = look.muted
        case .aiAdded:
            a[.foregroundColor] = look.accent
        case .userRemoved:
            // Windows: a 2-px pen through the middle.
            a[.foregroundColor] = user
            a[.strikethroughStyle] = NSUnderlineStyle.thick.rawValue
            a[.strikethroughColor] = user
        case .userChanged:
            a[.foregroundColor] = user
            a[.font] = look.sans(14.5, bold: true)
            a[.backgroundColor] = userWash(ob)
        case .userNote:
            a[.foregroundColor] = user
            a[.font] = look.sans(14.5, bold: true)
            a[.underlineStyle] = NSUnderlineStyle.single.rawValue
        default:
            break
        }
        return a
    }

    /// The moment of the run at a character offset (or the one just before it).
    func seconds(at offset: Int, in text: NSAttributedString) -> Double? {
        guard text.length > 0 else { return nil }
        let i = max(0, min(offset, text.length - 1))
        if let s = text.attribute(.obSeconds, at: i, effectiveRange: nil) as? Double { return s }
        if i > 0, let s = text.attribute(.obSeconds, at: i - 1, effectiveRange: nil) as? Double { return s }
        return nil
    }

    #if os(macOS)
    func makeView() -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = EditedNSTextView(frame: scroll.contentView.bounds)
        tv.controller = self
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.textContainerInset = CGSize(width: 10, height: 8)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.setAccessibilityLabel("Edited: every change, in colour")
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        textView = tv
        return scroll
    }

    /// Right-click: "Jump to this moment in the recording · h:mm:ss", then Copy.
    func menu(for event: NSEvent) -> NSMenu? {
        guard let tv = textView, let storage = tv.textStorage else { return nil }
        let at = tv.window.map { tv.characterIndex(for: $0.convertPoint(toScreen: event.locationInWindow)) } ?? NSNotFound
        let j = jump(seconds(at: at == NSNotFound ? tv.selectedRange().location : at, in: storage))
        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = MenuAction(title: j.title, action: j.action)
        item.isEnabled = j.enabled
        menu.addItem(item)
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copy.target = tv
        copy.isEnabled = tv.selectedRange().length > 0
        menu.addItem(copy)
        return menu
    }
    #else
    func makeView() -> EditedUITextView {
        let tv = EditedUITextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        tv.textContainer.lineFragmentPadding = 0
        tv.delegate = self
        tv.accessibilityLabel = "Edited: every change, in colour"
        textView = tv
        return tv
    }
    #endif
}

#if os(macOS)
final class EditedNSTextView: NSTextView {
    weak var controller: EditedTextController?
    override func menu(for event: NSEvent) -> NSMenu? { controller?.menu(for: event) ?? super.menu(for: event) }
}

extension EditedTextView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = context.coordinator.makeView()
        update(context.coordinator, palette: context.environment.ob)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { update(context.coordinator, palette: context.environment.ob) }
}
#else
final class EditedUITextView: UITextView {}

extension EditedTextController: UITextViewDelegate {
    /// The long-press menu: Jump to this moment first, then the usual items.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let j = jump(seconds(at: range.location, in: textView.attributedText))
        let item = UIAction(title: j.title, attributes: j.enabled ? [] : .disabled) { _ in j.action() }
        return UIMenu(children: [item] + suggestedActions)
    }
}

extension EditedTextView: UIViewRepresentable {
    func makeUIView(context: Context) -> EditedUITextView {
        let tv = context.coordinator.makeView()
        update(context.coordinator, palette: context.environment.ob)
        return tv
    }

    func updateUIView(_ tv: EditedUITextView, context: Context) { update(context.coordinator, palette: context.environment.ob) }
}
#endif

#if DEBUG && os(macOS)
/// The Edited tab's own text view drawn to PNGs (the page snapshots can't draw a text view).
@MainActor
enum EditedTextSnapshots {
    static func write(to dir: String, model: AppModel) {
        guard let s = model.notes.store.sessions.first(where: { $0.id == "20261102-1015" }) else { return }
        for dark in [false, true] {
            let c = EditedTextController()
            let scroll = c.makeView()
            scroll.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
            let palette = Palette(dark: dark, accentChoice: model.settings.accent)
            c.show(s, revision: 0, live: false, palette: palette)
            c.textView.layoutManager?.ensureLayout(for: c.textView.textContainer!)
            let host = NSView(frame: scroll.frame)
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor(palette.paper).cgColor
            host.addSubview(scroll)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "notes-edited-view-\(dark ? "dark" : "light").png"))
        }
    }
}
#endif
