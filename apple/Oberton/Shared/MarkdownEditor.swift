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
    /// Whether its tab is showing. A view hidden keeps its scroll position and cursor for when it shows again; its open
    /// line is rendered again and it gives up the keyboard (MarkdownPresenter.Shown).
    var shown = true
    var onEdit: (String) -> Void
    /// Whether the box has the keyboard (the dashboard's text box draws its accent line then).
    var onFocus: ((Bool) -> Void)? = nil
    /// Where the cursor is (UTF-16), for the Play button and the Summary's match.
    var onCaret: ((Int) -> Void)? = nil
    /// The Jump item for a place in the text, or nil for none.
    var jump: ((Int) -> MarkdownJump?)? = nil
    /// While the recording plays: the word being said is lit in the accent (nil: nothing is lit).
    var playback: PlaybackWords? = nil
    /// Only a click on a control marked `takesFocusOnClick()` renders the open line again (macOS; see `watchClicks`).
    var focusClicksOnly = false

    func makeCoordinator() -> MarkdownEditorController { MarkdownEditorController() }

    fileprivate func update(_ c: MarkdownEditorController, palette: Palette) {
        c.onEdit = onEdit
        c.onFocus = onFocus
        c.onCaret = onCaret
        c.jump = jump
        #if os(macOS)
        c.focusClicksOnly = focusClicksOnly
        #endif
        c.setLook(MarkdownLook(size: size, palette: palette))
        c.setText(text)
        c.setShown(shown)
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
    var onFocus: ((Bool) -> Void)?
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
        #if os(macOS)
        // A selection in ink at WPF's 0.4 selection opacity, whatever the system highlight colour (Windows' accent is ink).
        textView?.selectedTextAttributes = [.backgroundColor: look.ink.withAlphaComponent(0.4)]
        #endif
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
            storage.append(NSAttributedString(string: (new as NSString).substring(from: (old as NSString).length), attributes: styler.look.pendingAttributes))
            selectedRange = selection
        } else {
            let (offset, removed, added) = NoteSession.change(old, new)
            let ns = new as NSString
            // Not shown until the next render, as an appended piece (Windows keeps the old rendering until its tick):
            // the new text never takes the look of what it replaced, nor shows its raw Markdown meanwhile.
            storage.replaceCharacters(in: NSRange(location: offset, length: removed),
                                      with: NSAttributedString(string: ns.substring(with: NSRange(location: offset, length: added)), attributes: styler.look.pendingAttributes))
            let a = NoteSession.move(selection.location, offset, removed, added)
            let b = NoteSession.move(NSMaxRange(selection), offset, removed, added)
            selectedRange = NSRange(location: min(a, ns.length), length: max(0, min(b, ns.length) - min(a, ns.length)))
            // The user's own edits can still be undone when the change came after all of them (the AI's formatting
            // replacing the tail, as Windows' open line keeps its undo); one before them would shift what they undo.
            if offset < editReach { undoManager?.removeAllActions(); editReach = 0 }
            // The open line's own undo (the Mac) goes when the change reached into that line: Windows sets the line
            // box's text afresh then, which empties its undo.
            if let o = open, o < MarkdownStyler.lines(old as NSString).count {
                let full = MarkdownStyler.lines(old as NSString)[o].full
                if offset <= NSMaxRange(full) && offset + removed >= full.location { forgetLineUndo() }
            }
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

    /// How far into the text the user's edits (what ⌘Z would undo) reach: a change from elsewhere after it keeps them.
    private var editReach = 0

    /// The user typed: the session takes the text; the lines around are rendered again.
    func userEdited() {
        guard !applying else { return }
        editReach = max(editReach, NSMaxRange(selectedRange) + 1)
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
        forgetLineUndo() // a new line box on Windows, with an undo of its own
        open = line
        restyle()
        refreshCaret()
    }

    /// The cursor moved: its line opens (a selection across lines shows them all read). The Play button starts from
    /// the open line's cursor (MarkdownPresenter sets the box's caret only when a line opens, is edited, or its cursor
    /// moves); a selection made over the text read leaves it where it was.
    func selectionChanged() {
        guard !applying, !clicking, !closed else { return }
        let sel = selectedRange
        let line = lineIndex(sel.location)
        if sel.length == 0 || line == lineIndex(NSMaxRange(sel)) {
            setOpen(line)
            onCaret?(sel.location)
        } else {
            setOpen(nil)
        }
    }

    func willClick() { clicking = true }

    /// A mouse-down while a line is open (MarkdownPresenter's PreviewMouseLeftButtonDown): on another line, that line
    /// opens at once with the cursor at the place clicked, and the click goes no further (no drag can start there). True
    /// when it was handled so.
    func mouseDownElsewhere(at offset: Int) -> Bool {
        guard !closed, let o = open else { return false }
        let ls = lines
        guard o < ls.count else { return false }
        let c = ls[o].content
        if offset >= c.location && offset <= NSMaxRange(c) { return false }
        selectedRange = NSRange(location: min(max(0, offset), storage.length), length: 0)
        selectionChanged()
        refreshCaret()
        return true
    }

    /// The open line is a one-line box on Windows: a drag that began in it, or ⌘A, selects within it.
    func selectAllInOpenLine() -> Bool {
        guard !closed, let o = open else { return false }
        let ls = lines
        guard o < ls.count else { return false }
        selectedRange = ls[o].content
        return true
    }

    var lineOpen: Bool { !closed && open != nil }

    /// After a click: a plain click opens the line there. A drag over the text read selects it to copy: it stays
    /// rendered (MarkdownPresenter's mouse-up returns while the viewer has a selection), and typing still goes on at the end.
    func didClick() {
        clicking = false
        let editing = !closed && open != nil
        if !editing && selectedRange.length > 0 {
            closed = true
            setOpen(nil)
            refreshCaret()
            return
        }
        closed = false
        selectionChanged()
        refreshCaret()
    }

    /// Esc: back to the whole text rendered, nothing left selected (the view is drawn afresh); typing then goes on at the end.
    func escape() {
        closed = true
        let sel = selectedRange
        if sel.length > 0 { applying = true; selectedRange = NSRange(location: sel.location, length: 0); applying = false }
        setOpen(nil)
        refreshCaret()
    }

    /// Up and Down on the open line's first or last row (MarkdownPresenter.OnKey): the line above or below opens with the
    /// cursor at the same character; at the first or last line of the text nothing moves. Returns whether it was
    /// handled here (elsewhere in a wrapped line the cursor moves row by row as usual).
    func moveLine(_ step: Int) -> Bool {
        guard !closed, let o = open else { return false }
        // With a selection too: Windows goes by the box's CaretIndex, the selection's start.
        let sel = NSRange(location: selectedRange.location, length: 0)
        let ls = lines
        guard o < ls.count else { return false }
        let content = ls[o].content
        func row(_ offset: Int) -> CGFloat {
            let g = layout.glyphIndexForCharacter(at: min(offset, max(0, storage.length - 1)))
            return layout.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY
        }
        if storage.length > 0, content.length > 0 {
            let edge = step < 0 ? content.location : max(content.location, NSMaxRange(content) - 1)
            if row(sel.location) != row(edge) && !(step > 0 && sel.location == NSMaxRange(content) && row(sel.location - 1) == row(edge)) { return false }
        }
        let target = o + step
        guard target >= 0, target < ls.count else { return true }
        let col = sel.location - content.location
        selectedRange = NSRange(location: ls[target].content.location + min(col, ls[target].content.length), length: 0)
        return true
    }

    /// A selection made from the keyboard stays inside the open line (it is a one-line box on Windows).
    func keepInOpenLine() {
        guard !closed, let o = open else { return }
        let ls = lines
        guard o < ls.count else { return }
        let c = ls[o].content, sel = selectedRange
        let a = min(max(sel.location, c.location), NSMaxRange(c)), b = min(max(NSMaxRange(sel), c.location), NSMaxRange(c))
        if a != sel.location || b != NSMaxRange(sel) { selectedRange = NSRange(location: a, length: b - a) }
    }

    /// ⌘↑ / ⌘↓ on the open line: its start or end (Ctrl+Home/End in Windows' one-line box), not the whole text's.
    func toLineEdge(end: Bool) -> Bool {
        guard !closed, let o = open else { return false }
        let ls = lines
        guard o < ls.count else { return false }
        selectedRange = NSRange(location: end ? NSMaxRange(ls[o].content) : ls[o].content.location, length: 0)
        return true
    }

    /// Told after the current update, so a view may keep it in its state.
    func focusChanged(_ focused: Bool) {
        guard let onFocus else { return }
        DispatchQueue.main.async { onFocus(focused) }
    }

    func lostFocus() {
        closed = true
        setOpen(nil)
        refreshCaret()
    }

    private var isShown = true

    /// Its tab shows or hides.
    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        // Windows' ShowView acts only while a line is open: a selection made over the text read stays for the tab's return.
        let wasOpen = !closed && open != nil
        #if os(macOS)
        guard let tv = textView, let scroll = tv.enclosingScrollView else { return }
        if !shown, tv.window?.firstResponder === tv { tv.window?.makeFirstResponder(nil) }
        scroll.isHidden = !shown
        #else
        guard let tv = textView else { return }
        if !shown, tv.isFirstResponder { _ = tv.resignFirstResponder() }
        tv.isHidden = !shown
        #endif
        if !shown && wasOpen { escape() }
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

    /// Return (MarkdownPresenter.OnKey / Split). On the open line: it splits at the cursor and the cursor goes to the
    /// new line; a list goes on (the next bullet, the next number); Return on an empty list item ends the list. The
    /// line break is the text's own ("\r\n" in a text that has one). With ⌥ or ⌃ (or ⌘) nothing happens: Windows splits
    /// only on Enter without modifiers (Shift aside), and the line box doesn't take a Return of its own. While nothing
    /// is open, Return goes to the read view as typing does: the last line opens with the cursor at its end, and no line
    /// is added (Windows' read-only viewer also appends a bare "\r" to the text there, a WPF quirk left out: READ-125).
    func returnKey(modified: Bool) {
        if closed { beforeTyping(); return }
        if modified { return }
        let sel = selectedRange
        let ns = storage.string as NSString
        let newline = ns.range(of: "\r\n").location != NSNotFound ? "\r\n" : "\n"
        let ls = lines
        let i = lineIndex(sel.location)
        let content = ls[i].content
        switch NotesMarkdown.enter(line: ns.substring(with: content), caret: sel.location - content.location) {
        case .plain:
            replace(sel, with: newline)
        case .endList:
            replace(content, with: "")
        case .continue(let prefix):
            replace(sel, with: newline + prefix)
        }
    }

    /// The view's name for VoiceOver ("Transcript, formatted for reading; click a line to edit it"), and while a line is
    /// open "Transcript, the line being edited" (the open line's own name on Windows).
    var label = ""

    private var announcedEditing = false

    private func refreshCaret() {
        let editing = !closed && open != nil
        let name = label + (editing ? ", the line being edited" : ", formatted for reading; click a line to edit it")
        #if os(macOS)
        textView?.insertionPointColor = editing ? styler.look.ink : .clear
        textView?.setAccessibilityLabel(name)
        #else
        textView?.tintColor = styler.look.ink
        textView?.accessibilityLabel = name
        #endif
        // Windows' open line is an element of its own that takes the focus, so Narrator says its name as a line opens
        // and the viewer's as it closes; here the one text view is renamed, and VoiceOver is told the new name.
        guard editing != announcedEditing else { return }
        announcedEditing = editing
        #if os(macOS)
        guard let tv = textView, tv.window?.firstResponder === tv || editing else { return }
        NSAccessibility.post(element: tv, notification: .announcementRequested,
                             userInfo: [.announcement: name, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        #else
        guard textView?.isFirstResponder == true || editing else { return }
        UIAccessibility.post(notification: .announcement, argument: name)
        #endif
    }

    // MARK: The open line's undo

    /// ⌘Z / ⇧⌘Z undo and redo what was typed in the open line since it opened, as Windows' line box (a TextBox of its
    /// own, made each time a line opens) does: a step is the line as it was. Changes from elsewhere don't touch it.
    private var lineUndo: [(text: String, caret: Int)] = []
    private var lineRedo: [(text: String, caret: Int)] = []
    /// Where the last edit ended and whether it typed: typing on from there is the same step (a TextBox merges it).
    private var lastEdit: (end: Int, typing: Bool)?

    private func forgetLineUndo() {
        lineUndo = []
        lineRedo = []
        lastEdit = nil
    }

    var canUndoLine: Bool { lineOpen && !lineUndo.isEmpty }
    var canRedoLine: Bool { lineOpen && !lineRedo.isEmpty }

    /// The user is about to change `range` in the open line: the line as it is now becomes an undo step.
    func willEdit(_ range: NSRange, _ replacement: String) {
        guard !applying, !closed, let o = open else { return }
        let ls = lines
        guard o < ls.count else { return }
        let typing = range.length == 0 && !replacement.isEmpty
        let end = range.location + (replacement as NSString).length
        defer { lastEdit = (end, typing) }
        lineRedo = []
        if let last = lastEdit, last.typing, typing, last.end == range.location { return }
        let c = ls[o].content
        lineUndo.append(((storage.string as NSString).substring(with: c), selectedRange.location - c.location))
    }

    /// Undo (or redo) a step of the open line. False when there is none (the key does nothing then).
    @discardableResult
    func undoLine(redo: Bool) -> Bool {
        guard !closed, let o = open, let step = redo ? lineRedo.popLast() : lineUndo.popLast() else { return false }
        let ls = lines
        guard o < ls.count else { return false }
        let c = ls[o].content
        let now = ((storage.string as NSString).substring(with: c), selectedRange.location - c.location)
        if redo { lineUndo.append(now) } else { lineRedo.append(now) }
        applying = true
        storage.replaceCharacters(in: c, with: NSAttributedString(string: step.text, attributes: typingAttributes))
        selectedRange = NSRange(location: c.location + min(max(0, step.caret), (step.text as NSString).length), length: 0)
        applying = false
        lastEdit = nil
        onEdit(storage.string)
        restyle()
        onCaret?(selectedRange.location)
        return true
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

    /// The right-click (long-press) menu's Jump item at `offset`.
    func jumpItem(at offset: Int) -> MarkdownJump? { jump?(offset) }

    // MARK: Platform

    #if os(macOS)
    func makeView() -> NSScrollView {
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        tv.controller = self
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = false // the open line keeps its own (`undoLine`)
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

    /// A click on a control that takes the keyboard (▶, a pill, ⚑ MARK, the slider, EXPORT ▾, the title) takes it from
    /// the text, as a focusable WPF control does on mouse-down: the open line is rendered again (MarkdownPresenter's
    /// LostKeyboardFocus) and typing no longer goes into the text. A click on what can't take the focus (blank page,
    /// a label, the timer, the hint, the pipeline, the title bar) leaves the line open, as on Windows; so does the
    /// view's own scroll bar.
    private var clickWatch: Any?
    /// Only clicks on controls marked `takesFocusOnClick()` take the keyboard (Extended Notes); otherwise any click
    /// outside the text does (the dashboard's notes box, whose controls aren't marked).
    var focusClicksOnly = false

    func watchClicks() {
        guard clickWatch == nil else { return }
        clickWatch = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let tv = self.textView, let window = tv.window, event.window === window,
                      window.firstResponder === tv, let scroll = tv.enclosingScrollView else { return }
                if scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) { return }
                guard !self.focusClicksOnly || FocusTaking.at(event.locationInWindow, in: window) else { return }
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    func stopWatchingClicks() {
        if let clickWatch { NSEvent.removeMonitor(clickWatch) }
        clickWatch = nil
    }

    private func replace(_ range: NSRange, with s: String) {
        guard let tv = textView, tv.shouldChangeText(in: range, replacementString: s) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: s, attributes: tv.typingAttributes))
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + (s as NSString).length, length: 0))
    }

    /// Right-click: Jump to this moment, then Cut / Copy / Paste on the open line, or Copy / Edit here on the text read.
    /// On the open line (a text box of its own on Windows) the cursor moves there unless the click was inside the
    /// selection, and Play follows the cursor. Elsewhere the open line stays as it is and the text read gets its own
    /// menu; Play then starts from the place right-clicked (NotesPage.AttachJumpView sets the box's caret there).
    func menu(for event: NSEvent) -> NSMenu? {
        guard let tv = textView else { return nil }
        let at = tv.characterIndexForInsertion(at: tv.convert(event.locationInWindow, from: nil))
        let sel = tv.selectedRange()
        let ls = lines
        let editing: Bool
        if !closed, let o = open, o < ls.count, at >= ls[o].content.location, at <= NSMaxRange(ls[o].content) { editing = true } else { editing = false }
        let place: Int
        if editing {
            if !(sel.length > 0 && at >= sel.location && at <= NSMaxRange(sel)) { tv.setSelectedRange(NSRange(location: at, length: 0)) }
            place = tv.selectedRange().location
        } else {
            onCaret?(at)
            place = at
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let j = jumpItem(at: place) {
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
            // Copy copies the text read's selection (none while a line is open: the open line holds the cursor).
            let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            copy.target = tv
            copy.isEnabled = closed && sel.length > 0
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
/// The controls that take the keyboard when clicked, as a focusable WPF control does (Button, ToggleButton, Slider,
/// ComboBox…): each is marked with `takesFocusOnClick()`, an empty AppKit view behind it. A click lands on one of them
/// (enabled, shown) or not: labels, blank page and the title bar are not (FocusTaking).
final class FocusTakerView: NSView {
    @MainActor static let all = NSHashTable<FocusTakerView>.weakObjects()
    var enabled = true
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated { _ = window.map { _ in Self.all.add(self) } }
    }
}

private struct FocusTakerMarker: NSViewRepresentable {
    var enabled: Bool
    func makeNSView(context: Context) -> FocusTakerView { FocusTakerView() }
    func updateNSView(_ v: FocusTakerView, context: Context) { v.enabled = enabled }
}

private struct TakesFocusOnClick: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    // (Not in the debug page snapshots: their image renderer can't draw an AppKit view.)
    func body(content: Content) -> some View {
        if PageScroll<EmptyView>.flat && !FocusTaking.checking { content } else { content.background(FocusTakerMarker(enabled: enabled)) }
    }
}

extension View {
    /// Marks a control that takes the keyboard when clicked: a click on it renders an open Markdown line again.
    func takesFocusOnClick() -> some View { modifier(TakesFocusOnClick()) }
}

@MainActor
enum FocusTaking {
    /// The DEBUG self-check draws the markers even in snapshot mode.
    static var checking = false

    /// Whether `point` (in the window) is on a marked control that is enabled and showing.
    static func at(_ point: NSPoint, in window: NSWindow) -> Bool {
        FocusTakerView.all.allObjects.contains { v in
            v.window === window && v.enabled && !v.isHiddenOrHasHiddenAncestor && v.bounds.contains(v.convert(point, from: nil))
        }
    }
}

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
        let at = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if controller?.mouseDownElsewhere(at: at) == true { return }
        let inOpenLine = controller?.lineOpen == true
        controller?.willClick()
        super.mouseDown(with: event) // tracks the click or the drag until the button comes up
        // A drag that began in the open line stays in it (Windows' line box can't select past its own text).
        if inOpenLine { controller?.keepInOpenLine() }
        controller?.didClick()
    }

    override func selectAll(_ sender: Any?) {
        if controller?.selectAllInOpenLine() != true { super.selectAll(sender) }
    }

    @objc func undo(_ sender: Any?) { controller?.undoLine(redo: false) }
    @objc func redo(_ sender: Any?) { controller?.undoLine(redo: true) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return controller?.canUndoLine == true }
        if item.action == #selector(redo(_:)) { return controller?.canRedoLine == true }
        return super.validateUserInterfaceItem(item)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        controller?.beforeTyping()
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Return splits the open line; ⌥Return (`insertNewlineIgnoringFieldEditor:`), ⌃Return (`insertLineBreak:`) and
    /// ⌘Return do nothing there (`returnKey`).
    override func insertNewline(_ sender: Any?) {
        let mods = NSApp.currentEvent.map { $0.type == .keyDown ? $0.modifierFlags.intersection([.command, .control, .option]) : [] } ?? []
        controller?.returnKey(modified: !mods.isEmpty)
    }
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { controller?.returnKey(modified: true) }
    override func insertLineBreak(_ sender: Any?) { controller?.returnKey(modified: true) }
    override func insertParagraphSeparator(_ sender: Any?) { controller?.returnKey(modified: true) }

    /// While nothing is open the text is read only, as Windows' viewer: ⌘V and ⌘X do nothing (⌘C copies).
    override func paste(_ sender: Any?) { if controller?.closed != true { super.paste(sender) } }
    override func pasteAsPlainText(_ sender: Any?) { if controller?.closed != true { super.pasteAsPlainText(sender) } }
    override func cut(_ sender: Any?) { if controller?.closed != true { super.cut(sender) } }

    override func cancelOperation(_ sender: Any?) { controller?.escape() }

    /// Tab moves to the next control rather than typing a tab (Windows' AcceptsTab="False"); with no other control to
    /// go to (buttons take the keyboard only with Keyboard navigation on), the keyboard leaves the text all the same,
    /// so the open line renders again as on Windows.
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(nil)
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }
    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(nil)
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override func moveUp(_ sender: Any?) { if controller?.moveLine(-1) != true { super.moveUp(sender) } }
    override func moveDown(_ sender: Any?) { if controller?.moveLine(1) != true { super.moveDown(sender) } }
    override func moveToBeginningOfDocument(_ sender: Any?) { if controller?.toLineEdge(end: false) != true { super.moveToBeginningOfDocument(sender) } }
    override func moveToEndOfDocument(_ sender: Any?) { if controller?.toLineEdge(end: true) != true { super.moveToEndOfDocument(sender) } }
    override func moveUpAndModifySelection(_ sender: Any?) { super.moveUpAndModifySelection(sender); controller?.keepInOpenLine() }
    override func moveDownAndModifySelection(_ sender: Any?) { super.moveDownAndModifySelection(sender); controller?.keepInOpenLine() }
    override func moveLeftAndModifySelection(_ sender: Any?) { super.moveLeftAndModifySelection(sender); controller?.keepInOpenLine() }
    override func moveRightAndModifySelection(_ sender: Any?) { super.moveRightAndModifySelection(sender); controller?.keepInOpenLine() }
    override func moveWordLeftAndModifySelection(_ sender: Any?) { super.moveWordLeftAndModifySelection(sender); controller?.keepInOpenLine() }
    override func moveWordRightAndModifySelection(_ sender: Any?) { super.moveWordRightAndModifySelection(sender); controller?.keepInOpenLine() }
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { super.moveToBeginningOfDocumentAndModifySelection(sender); controller?.keepInOpenLine() }
    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { super.moveToEndOfDocumentAndModifySelection(sender); controller?.keepInOpenLine() }

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

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { controller?.focusChanged(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { controller?.lostFocus(); controller?.focusChanged(false) }
        return ok
    }

    override func menu(for event: NSEvent) -> NSMenu? { controller?.menu(for: event) ?? super.menu(for: event) }
}

extension MarkdownEditorController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        willEdit(range, replacementString ?? "")
        return true
    }
    func textDidChange(_ notification: Notification) { userEdited() }
    func textViewDidChangeSelection(_ notification: Notification) { selectionChanged() }
}

extension MarkdownEditor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = context.coordinator.makeView()
        context.coordinator.watchClicks()
        context.coordinator.textView.textContainerInset = inset
        context.coordinator.label = label
        context.coordinator.textView.setAccessibilityLabel(label + ", formatted for reading; click a line to edit it")
        update(context.coordinator, palette: context.environment.ob)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { update(context.coordinator, palette: context.environment.ob) }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: MarkdownEditorController) {
        coordinator.setPlayback(nil)
        coordinator.stopWatchingClicks()
    }
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
    func textViewDidBeginEditing(_ textView: UITextView) { didClick(); focusChanged(true) }
    func textViewDidEndEditing(_ textView: UITextView) { lostFocus(); focusChanged(false) }
    func textViewDidChange(_ textView: UITextView) { userEdited() }
    func textViewDidChangeSelection(_ textView: UITextView) { selectionChanged() }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\t" { return false } // Tab doesn't type a tab (Windows' AcceptsTab="False")
        if text == "\n" { returnKey(modified: false); return false }
        return true
    }

    /// The long-press menu: Jump to this moment first, then the usual items.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        onCaret?(range.location)
        guard let j = jumpItem(at: range.location) else { return nil }
        let jump = UIAction(title: j.title, attributes: j.enabled ? [] : .disabled) { _ in j.action() }
        return UIMenu(children: [jump] + suggestedActions)
    }
}

extension MarkdownEditor: UIViewRepresentable {
    func makeUIView(context: Context) -> MarkdownUITextView {
        let tv = context.coordinator.makeView()
        tv.textContainerInset = UIEdgeInsets(top: inset.height, left: inset.width, bottom: inset.height, right: inset.width)
        context.coordinator.label = label
        tv.accessibilityLabel = label + ", formatted for reading; click a line to edit it"
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
        FocusTakingCheck.write(to: dir)
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

/// The click rule of `FocusTaking`, checked on a window that is never shown: which places close an open line. Written
/// to notes-focus-check.txt beside the snapshots ("yes" where Windows' focus would move).
@MainActor
enum FocusTakingCheck {
    static func write(to dir: String) {
        FocusTaking.checking = true
        defer { FocusTaking.checking = false }
        let cell = CGSize(width: 150, height: 50)
        let view = VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button("Quiet") {}.buttonStyle(.quiet).takesFocusOnClick().frame(width: cell.width, height: cell.height)
                Text("A label").frame(width: cell.width, height: cell.height)
                Pill("Pill", on: false) {}.takesFocusOnClick().frame(width: cell.width, height: cell.height)
                Color.clear.frame(width: cell.width, height: cell.height)
            }
            HStack(spacing: 0) {
                FluentSlider(value: .constant(0.5), range: 0...1).takesFocusOnClick().frame(width: cell.width, height: cell.height)
                Button("Off") {}.buttonStyle(.quiet).takesFocusOnClick().disabled(true).frame(width: cell.width, height: cell.height)
                Menu("Export") { Button("Copy") {} }.menuStyle(.button).takesFocusOnClick().frame(width: cell.width, height: cell.height)
                Text("0:01:02").contentShape(Rectangle()).onTapGesture {}.frame(width: cell.width, height: cell.height)
            }
        }
        .environment(\.ob, Palette(dark: false, accentChoice: .cobalt))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 600, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 100)
        host.layoutSubtreeIfNeeded()
        let names = [["quiet button", "label", "pill", "blank"], ["slider", "disabled button", "menu", "tappable timer"]]
        var out = ""
        for (row, y) in [(0, 75.0), (1, 25.0)] {
            for col in 0..<4 {
                let p = NSPoint(x: 75 + Double(col) * 150, y: y)
                out += "\(names[row][col]): \(FocusTaking.at(p, in: window) ? "yes" : "no")\n"
            }
        }
        out += "title bar: \(FocusTaking.at(NSPoint(x: 300, y: window.frame.height - 5), in: window) ? "yes" : "no")\n"
        try? out.write(to: URL(fileURLWithPath: dir).appending(path: "notes-focus-check.txt"), atomically: true, encoding: .utf8)
        window.contentView = nil
    }
}
#endif
