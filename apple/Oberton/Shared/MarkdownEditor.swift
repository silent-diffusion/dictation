import SwiftUI
import ObertonCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The first item of the right-click menu: "Jump to this moment in the recording · 0:12:34".
struct MarkdownJump {
    var title: String
    var enabled: Bool
    var action: () -> Void
}

/// A text of Extended Notes read as Markdown and edited a line at a time, in place (Windows' MarkdownPresenter and
/// NotesTextBinder): a click opens the line clicked as plain text (its Markdown syntax showing), and every other line
/// stays rendered. When the cursor leaves the line (another click, the arrow keys, Enter, Esc, or leaving the box) that
/// line is rendered again. Enter continues a list; Backspace at the start of a line joins it to the one above; typing
/// while reading goes on at the end. What arrives from elsewhere (new speech, the AI's formatting) goes into the text
/// without moving the cursor, keeping the reader at the end while new text arrives.
@MainActor
struct MarkdownEditor {
    var text: String
    var size: CGFloat
    var label: String
    var inset = CGSize(width: 14, height: 12)
    var onEdit: (String) -> Void
    /// Where the cursor is (UTF-16), for the Play button and the Summary's match.
    var onCaret: ((Int) -> Void)? = nil
    /// The Jump item for a place in the text, or nil for none.
    var jump: ((Int) -> MarkdownJump?)? = nil
    /// While the recording plays: the word being said is lit in the accent (nil: nothing is lit).
    var playback: PlaybackWords? = nil

    func makeCoordinator() -> MarkdownEditorController { MarkdownEditorController() }

    fileprivate func update(_ c: MarkdownEditorController, palette: Palette) {
        c.onEdit = onEdit
        c.onCaret = onCaret
        c.jump = jump
        c.setLook(MarkdownLook(size: size, palette: palette))
        c.setText(text)
        c.setPlayback(playback)
    }
}

/// Holds the text view and keeps it, the open line and the session's text in step.
@MainActor
final class MarkdownEditorController: NSObject {
    let storage = NSTextStorage()
    let layout: MarkdownLayoutManager
    let container = NSTextContainer(size: CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
    let styler: MarkdownStyler
    #if os(macOS)
    private(set) var textView: MarkdownTextView!
    #else
    private(set) var textView: MarkdownUITextView!
    #endif

    var onEdit: (String) -> Void = { _ in }
    var onCaret: ((Int) -> Void)?
    var jump: ((Int) -> MarkdownJump?)?

    /// The line being edited (its index), or nil while the whole text is read.
    private(set) var open: Int?
    /// Nothing open and no cursor: a click opens a line, typing goes on at the end.
    private(set) var closed = true
    /// A change made here (not the user's typing).
    private var applying = false
    private var clicking = false
    private var loaded = false
    /// The rendering follows a change made elsewhere at most every 300 ms (MarkdownPresenter's render timer).
    private var renderSoon: DispatchWorkItem?
    private var followEnd = false

    // The word being said while the recording plays.
    private var playback: PlaybackWords?
    private var playTick: Timer?
    private let spans = SpokenSpans()
    /// The range lit now (and, on iOS, the colour it had).
    private var lit: NSRange?
    #if os(iOS)
    private var litColor: Any?
    #endif
    var userScrolledAt = Date.distantPast

    override init() {
        let look = MarkdownLook(size: 14, palette: Palette(dark: false, accentChoice: .cobalt))
        layout = MarkdownLayoutManager(look: look)
        styler = MarkdownStyler(look: look)
        super.init()
        storage.addLayoutManager(layout)
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
    }

    func setLook(_ look: MarkdownLook) {
        guard look != styler.look else { return }
        styler.look = look
        layout.look = look
        restyle()
        refreshCaret()
    }

    // MARK: The binding

    /// The session's text, as it is now: put into the view without moving the cursor or the scroll position, and
    /// following the end if the reader was there.
    func setText(_ new: String) {
        let old = storage.string
        guard old != new || !loaded else { return }
        let first = !loaded
        loaded = true
        let atEnd = first || isAtEnd
        let selection = selectedRange
        applying = true
        if new.hasPrefix(old) {
            storage.append(NSAttributedString(string: (new as NSString).substring(from: (old as NSString).length), attributes: [.font: styler.look.sans(styler.look.size)]))
            selectedRange = selection
        } else {
            let (offset, removed, added) = NoteSession.change(old, new)
            let ns = new as NSString
            storage.replaceCharacters(in: NSRange(location: offset, length: removed), with: ns.substring(with: NSRange(location: offset, length: added)))
            let a = NoteSession.move(selection.location, offset, removed, added)
            let b = NoteSession.move(NSMaxRange(selection), offset, removed, added)
            selectedRange = NSRange(location: min(a, ns.length), length: max(0, min(b, ns.length) - min(a, ns.length)))
            undoManager?.removeAllActions()
        }
        applying = false
        if let o = open { open = min(o, MarkdownStyler.lines(storage.string as NSString).count - 1) }
        followEnd = followEnd || (atEnd && open == nil)
        if first { render(); return }
        guard renderSoon == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.renderSoon = nil; self?.render() }
        renderSoon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func render() {
        restyle()
        if followEnd && open == nil { scrollToEndSoon() }
        followEnd = false
    }

    /// The user typed: the session takes the text; the lines around are rendered again.
    func userEdited() {
        guard !applying else { return }
        onEdit(storage.string)
        restyle()
    }

    // MARK: The open line

    private var lines: [(content: NSRange, full: NSRange)] { MarkdownStyler.lines(storage.string as NSString) }

    private func lineIndex(_ offset: Int) -> Int { MarkdownStyler.lineIndex(lines, offset) }

    private func restyle() {
        #if os(iOS)
        lit = nil // the styler sets every colour again
        #endif
        styler.apply(storage, open: closed ? nil : open)
        if let o = open, !closed {
            let ls = lines
            if o < ls.count {
                let level = NotesMarkdown.parse((storage.string as NSString).substring(with: ls[o].content)).first.map { $0.kind == .heading ? $0.level : 0 } ?? 0
                typingAttributes = styler.look.openAttributes(headingLevel: level)
            }
        }
    }

    private func setOpen(_ line: Int?) {
        guard line != open else { return }
        open = line
        restyle()
        refreshCaret()
    }

    /// The cursor moved: its line opens (a selection across lines shows them all read).
    func selectionChanged() {
        guard !applying, !clicking else { return }
        let sel = selectedRange
        onCaret?(sel.location)
        guard !closed else { return }
        let line = lineIndex(sel.location)
        if sel.length == 0 || line == lineIndex(NSMaxRange(sel)) { setOpen(line) } else { setOpen(nil) }
    }

    func willClick() { clicking = true }

    /// After a click (or a drag that selected text): a plain click opens the line there.
    func didClick() {
        clicking = false
        closed = false
        selectionChanged()
        refreshCaret()
    }

    /// Esc: back to the whole text rendered; typing then goes on at the end.
    func escape() {
        closed = true
        setOpen(nil)
        refreshCaret()
    }

    func lostFocus() {
        closed = true
        setOpen(nil)
        refreshCaret()
    }

    /// Typing while nothing is open: it goes on at the end of the text.
    func beforeTyping() {
        guard closed else { return }
        closed = false
        selectedRange = NSRange(location: storage.length, length: 0)
        selectionChanged()
        refreshCaret()
    }

    /// Opens the line holding `offset` with the cursor there ("Edit here").
    func edit(at offset: Int) {
        closed = false
        focus()
        selectedRange = NSRange(location: min(max(0, offset), storage.length), length: 0)
        selectionChanged()
        refreshCaret()
    }

    /// Enter: a list goes on (the next bullet, the next number); Enter on an empty list item ends the list. Returns
    /// whether it was handled here.
    func newline() -> Bool {
        beforeTyping()
        let sel = selectedRange
        let ls = lines
        let i = lineIndex(sel.location)
        let content = ls[i].content
        let line = (storage.string as NSString).substring(with: content)
        switch NotesMarkdown.enter(line: line, caret: sel.location - content.location) {
        case .plain:
            return false
        case .endList:
            replace(content, with: "")
        case .continue(let prefix):
            replace(sel, with: "\n" + prefix)
        }
        return true
    }

    private func refreshCaret() {
        #if os(macOS)
        textView?.insertionPointColor = closed || open == nil ? .clear : styler.look.ink
        #else
        textView?.tintColor = styler.look.ink
        #endif
    }

    // MARK: The word being said

    func setPlayback(_ p: PlaybackWords?) {
        playback = p
        if p == nil {
            playTick?.invalidate(); playTick = nil
            showLit(nil)
        } else if playTick == nil {
            playTick = Timer.scheduledTimer(withTimeInterval: PlaybackFollow.tick, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.onPlayTick() }
            }
        }
    }

    #if DEBUG
    /// Snapshots: light the word at `seconds` now, as a playback tick would.
    func lightForSnapshot() { onPlayTick() }
    #endif

    private func onPlayTick() {
        guard let p = playback, let t = p.time() else { showLit(nil); return }
        let span = spans.current(text: storage.string, playback: p, at: t)
        showLit(span.map(\.range))
        if let span, closed || open == nil, Date().timeIntervalSince(userScrolledAt) >= PlaybackFollow.pause { follow(span.range) }
    }

    /// Light `range` in the accent (only the colour: nothing moves), and put the last one back.
    private func showLit(_ range: NSRange?) {
        let range = range.flatMap { NSMaxRange($0) <= storage.length ? $0 : nil }
        guard range != lit else { return }
        #if os(macOS)
        if let old = lit, NSMaxRange(old) <= storage.length { layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: old) }
        if let range { layout.addTemporaryAttribute(.foregroundColor, value: styler.look.accent, forCharacterRange: range) }
        #else
        storage.beginEditing()
        if let old = lit, NSMaxRange(old) <= storage.length {
            if let c = litColor { storage.addAttribute(.foregroundColor, value: c, range: old) } else { storage.removeAttribute(.foregroundColor, range: old) }
        }
        if let range {
            litColor = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
            storage.addAttribute(.foregroundColor, value: styler.look.accent, range: range)
        }
        storage.endEditing()
        #endif
        lit = range
    }

    /// Keep the lit word in view (the reader's rule).
    private func follow(_ range: NSRange) {
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        #if os(macOS)
        guard let tv = textView, let scroll = tv.enclosingScrollView else { return }
        rect.origin.y += tv.textContainerOrigin.y
        let visible = scroll.contentView.bounds
        guard let y = PlaybackFollow.offset(rect: rect, visible: visible, content: tv.frame.height) else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        #else
        guard let tv = textView else { return }
        rect.origin.y += tv.textContainerInset.top
        let visible = CGRect(origin: tv.contentOffset, size: tv.bounds.size)
        guard let y = PlaybackFollow.offset(rect: rect, visible: visible, content: tv.contentSize.height) else { return }
        tv.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        #endif
    }

    // MARK: The menu

    /// The right-click (long-press) menu's Jump item at `offset`; the cursor goes there unless that is inside the selection.
    func jumpItem(at offset: Int) -> MarkdownJump? {
        onCaret?(offset)
        return jump?(offset)
    }

    // MARK: Platform

    #if os(macOS)
    func makeView() -> NSScrollView {
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        tv.controller = self
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        container.widthTracksTextView = true
        tv.insertionPointColor = .clear
        textView = tv
        let scroll = MarkdownScrollView()
        scroll.onUserScroll = { [weak self] in self?.userScrolledAt = Date() }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = tv
        return scroll
    }

    private var selectedRange: NSRange {
        get { textView?.selectedRange() ?? NSRange(location: storage.length, length: 0) }
        set { textView?.setSelectedRange(newValue) }
    }
    private var typingAttributes: [NSAttributedString.Key: Any] {
        get { textView?.typingAttributes ?? [:] }
        set { textView?.typingAttributes = newValue }
    }
    private var undoManager: UndoManager? { textView?.undoManager }

    private var isAtEnd: Bool {
        guard let tv = textView, let scroll = tv.enclosingScrollView else { return true }
        return scroll.documentVisibleRect.maxY >= tv.bounds.height - 4
    }

    private func scrollToEndSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let tv = self?.textView else { return }
            tv.scrollToEndOfDocument(nil)
        }
    }

    private func focus() { textView?.window?.makeFirstResponder(textView) }

    private func replace(_ range: NSRange, with s: String) {
        guard let tv = textView, tv.shouldChangeText(in: range, replacementString: s) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: s, attributes: tv.typingAttributes))
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + (s as NSString).length, length: 0))
    }

    /// Right-click: Jump to this moment, then Cut / Copy / Paste on the open line, or Copy / Edit here on the text read.
    func menu(for event: NSEvent) -> NSMenu? {
        guard let tv = textView else { return nil }
        let at = tv.characterIndexForInsertion(at: tv.convert(event.locationInWindow, from: nil))
        let sel = tv.selectedRange()
        let editing = !closed && open != nil
        if editing && !(sel.length > 0 && at >= sel.location && at <= NSMaxRange(sel)) { tv.setSelectedRange(NSRange(location: at, length: 0)) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let j = jumpItem(at: at) {
            let item = MenuAction(title: j.title, action: j.action)
            item.isEnabled = j.enabled
            menu.addItem(item)
            menu.addItem(.separator())
        }
        if editing {
            // As WPF's ApplicationCommands: the shortcut shown, Paste only with text on the clipboard.
            let canPaste = NSPasteboard.general.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.string.rawValue])
            for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v")] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
                item.target = tv
                item.isEnabled = title == "Paste" ? canPaste : tv.selectedRange().length > 0
                menu.addItem(item)
            }
        } else {
            let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            copy.target = tv
            copy.isEnabled = sel.length > 0
            menu.addItem(copy)
            menu.addItem(MenuAction(title: "Edit here") { [weak self] in self?.edit(at: at) })
        }
        return menu
    }
    #else
    func makeView() -> MarkdownUITextView {
        let tv = MarkdownUITextView(frame: .zero, textContainer: container)
        tv.controller = self
        tv.delegate = self
        tv.backgroundColor = .clear
        tv.autocorrectionType = .no
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.alwaysBounceVertical = true
        container.widthTracksTextView = true
        textView = tv
        return tv
    }

    private var selectedRange: NSRange {
        get { textView?.selectedRange ?? NSRange(location: storage.length, length: 0) }
        set { textView?.selectedRange = newValue }
    }
    private var typingAttributes: [NSAttributedString.Key: Any] {
        get { textView?.typingAttributes ?? [:] }
        set { textView?.typingAttributes = newValue }
    }
    private var undoManager: UndoManager? { textView?.undoManager }

    private var isAtEnd: Bool {
        guard let tv = textView else { return true }
        return tv.contentOffset.y + tv.bounds.height >= tv.contentSize.height - 4
    }

    private func scrollToEndSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let tv = self?.textView else { return }
            let y = max(0, tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom)
            tv.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
    }

    private func focus() { _ = textView?.becomeFirstResponder() }

    private func replace(_ range: NSRange, with s: String) {
        guard let tv = textView, let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
              let end = tv.position(from: start, offset: range.length), let r = tv.textRange(from: start, to: end) else { return }
        tv.replace(r, withText: s)
    }
    #endif
}

#if os(macOS)
/// Reports the user's own scrolling (wheel, trackpad, scroll bar), not the playback's follow (ReaderFullText's).
final class MarkdownScrollView: NSScrollView {
    var onUserScroll: () -> Void = {}
    override func scrollWheel(with event: NSEvent) {
        onUserScroll()
        super.scrollWheel(with: event)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScroll), name: NSScrollView.willStartLiveScrollNotification, object: self)
    }
    @objc private func liveScroll() { onUserScroll() }
}

/// A menu item that runs a closure.
final class MenuAction: NSMenuItem {
    private let run: () -> Void
    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}

final class MarkdownTextView: NSTextView {
    weak var controller: MarkdownEditorController?

    override func mouseDown(with event: NSEvent) {
        controller?.willClick()
        super.mouseDown(with: event) // tracks the click or the drag until the button comes up
        controller?.didClick()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        controller?.beforeTyping()
        super.insertText(string, replacementRange: replacementRange)
    }

    override func insertNewline(_ sender: Any?) {
        if controller?.newline() != true { super.insertNewline(sender) }
    }

    override func cancelOperation(_ sender: Any?) { controller?.escape() }

    /// Tab moves to the next control rather than typing a tab (Windows' AcceptsTab="False").
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(nil) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(nil) }

    /// While nothing is open, the keys scroll; deleting does nothing.
    override func keyDown(with event: NSEvent) {
        if let c = controller, c.closed, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch event.keyCode {
            case 126: scrollLineUp(nil); return
            case 125: scrollLineDown(nil); return
            case 116: scrollPageUp(nil); return
            case 121: scrollPageDown(nil); return
            case 115: scrollToBeginningOfDocument(nil); return
            case 119: scrollToEndOfDocument(nil); return
            case 123, 124, 51, 117: return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { controller?.lostFocus() }
        return ok
    }

    override func menu(for event: NSEvent) -> NSMenu? { controller?.menu(for: event) ?? super.menu(for: event) }
}

extension MarkdownEditorController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { userEdited() }
    func textViewDidChangeSelection(_ notification: Notification) { selectionChanged() }
}

extension MarkdownEditor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = context.coordinator.makeView()
        context.coordinator.textView.textContainerInset = inset
        context.coordinator.textView.setAccessibilityLabel(label + ", formatted for reading; click a line to edit it")
        update(context.coordinator, palette: context.environment.ob)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { update(context.coordinator, palette: context.environment.ob) }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: MarkdownEditorController) { coordinator.setPlayback(nil) }
}
#else
final class MarkdownUITextView: UITextView {
    weak var controller: MarkdownEditorController?

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))]
    }

    @objc private func escape() {
        controller?.escape()
        _ = resignFirstResponder()
    }
}

extension MarkdownEditorController: UITextViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { userScrolledAt = Date() }
    func textViewDidBeginEditing(_ textView: UITextView) { didClick() }
    func textViewDidEndEditing(_ textView: UITextView) { lostFocus() }
    func textViewDidChange(_ textView: UITextView) { userEdited() }
    func textViewDidChangeSelection(_ textView: UITextView) { selectionChanged() }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\t" { return false } // Tab doesn't type a tab (Windows' AcceptsTab="False")
        return text == "\n" ? !newline() : true
    }

    /// The long-press menu: Jump to this moment first, then the usual items.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let j = jumpItem(at: range.location) else { return nil }
        let jump = UIAction(title: j.title, attributes: j.enabled ? [] : .disabled) { _ in j.action() }
        return UIMenu(children: [jump] + suggestedActions)
    }
}

extension MarkdownEditor: UIViewRepresentable {
    func makeUIView(context: Context) -> MarkdownUITextView {
        let tv = context.coordinator.makeView()
        tv.textContainerInset = UIEdgeInsets(top: inset.height, left: inset.width, bottom: inset.height, right: inset.width)
        tv.accessibilityLabel = label
        update(context.coordinator, palette: context.environment.ob)
        return tv
    }

    func updateUIView(_ tv: MarkdownUITextView, context: Context) { update(context.coordinator, palette: context.environment.ob) }

    static func dismantleUIView(_ tv: MarkdownUITextView, coordinator: MarkdownEditorController) { coordinator.setPlayback(nil) }
}
#endif

#if DEBUG && os(macOS)
/// The editor itself drawn to PNGs (the page snapshots can't draw a text view): read, and with a line open.
@MainActor
enum MarkdownEditorSnapshots {
    static let sample = """
    # Product sync
    Main idea: The **Oberton beta** ships to ten testers on *Friday*.

    ## Decisions
    - Two weeks of feedback before the wider release
    - The design budget is final at `1550`
      - nested: a point under a point
    1. Collect the feedback
    2. Review [the onboarding](https://example.com) next week
    > Ship it when it's ready, not before.
    ⚑ 0:19
    ---
    ```
    let x = 1 // code keeps its *stars*
    ```
    Todo: write the \\*release\\* notes
    """

    static func write(to dir: String, model: AppModel) {
        let cases: [(String, Int?)] = [("read", nil), ("open-heading", 0), ("open-item", 5)]
        for dark in [false, true] {
            for (name, line) in cases {
                save(sample, line: line, dark: dark, model: model, to: dir, name: "notes-markdown-\(name)-\(dark ? "dark" : "light")")
            }
            if let s = model.notes.store.sessions.first(where: { $0.id == "20261102-1015" }) {
                save(s.summary, line: nil, dark: dark, model: model, to: dir, name: "notes-markdown-summary-\(dark ? "dark" : "light")")
                save(s.formatted, line: nil, dark: dark, model: model, to: dir, name: "notes-markdown-formatted-\(dark ? "dark" : "light")")
            }
        }
        EditedTextSnapshots.write(to: dir, model: model)
        if let s = model.notes.store.sessions.first(where: { $0.id == "20261102-1015" }) {
            // Mid-playback: the words heard spread over the recording, the word at 40 % lit (the follow scrolls to it).
            let words = WordTimes.spread(s.heard, start: 0, end: s.seconds)
            let at = s.seconds * 0.4
            for dark in [false, true] {
                for (name, text, run) in [("transcript", s.transcript, 1), ("formatted", s.formatted, 1)] {
                    save(text, line: nil, dark: dark, model: model, to: dir, name: "notes-playback-\(name)-\(dark ? "dark" : "light")",
                         playback: PlaybackWords(words: words, minRun: run, time: { at }))
                }
            }
            HistoryPlaybackSnapshots.write(to: dir, model: model)
        }
    }

    private static func save(_ text: String, line: Int?, dark: Bool, model: AppModel, to dir: String, name: String, playback: PlaybackWords? = nil) {
        let c = MarkdownEditorController()
        let scroll = c.makeView()
        scroll.frame = CGRect(x: 0, y: 0, width: 640, height: 560)
        c.textView.frame = CGRect(x: 0, y: 0, width: 640, height: 560)
        c.textView.textContainerInset = CGSize(width: 14, height: 12)
        let palette = Palette(dark: dark, accentChoice: model.settings.accent)
        c.setLook(MarkdownLook(size: 14.5, palette: palette))
        c.setText(text)
        if let line {
            let ls = MarkdownStyler.lines(text as NSString)
            c.edit(at: NSMaxRange(ls[line].content))
        }
        c.layout.ensureLayout(for: c.container)
        if let playback {
            c.setPlayback(playback)
            c.lightForSnapshot()
        }
        defer { c.setPlayback(nil) }
        let host = NSView(frame: scroll.frame)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(palette.paper).cgColor
        host.addSubview(scroll)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if playback == nil { scroll.contentView.scroll(to: .zero) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: name + ".png"))
        }
    }
}
#endif
