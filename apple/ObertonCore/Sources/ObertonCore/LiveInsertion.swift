import Foundation

/// What the focused control shows right before the caret, compared with what live dictation typed (Windows
/// `InsertionContext.LiveText`).
public enum LiveText: Sendable, Equatable {
    /// Exactly the typed text: it can be selected and replaced.
    case matches
    /// The app doesn't show its text through Accessibility (terminals, many Electron apps, every app from the App
    /// Store build), is too slow to, or shows the same words with different spacing or line breaks: nothing says the
    /// user changed it.
    case unreadable
    /// Different words: the user (or the app) changed it, so it must not be touched.
    case differs
}

/// Where "type as you speak" types: the window the dictation started in, as the platform reaches it (Windows'
/// `TextInserter` plus `InsertionContext`'s UI Automation checks). Errors the user should see are `UserFacingError`s.
@MainActor
public protocol LiveTarget: AnyObject {
    /// The dictation's window is in front now (this never brings it there).
    var isInFront: Bool { get }
    /// Nothing to type into had the cursor when the dictation started (a button, a list, the desktop).
    func nowhere() async -> Bool
    /// The text goes in as a normal insertion does (the window brought back, paste or typing per the settings), but
    /// the clipboard is not put back: `LiveInsertion` holds it for the whole dictation.
    func insert(_ text: String) async throws
    /// Paste a short piece straight in (clipboard not put back). Never steals focus: throws when not in front.
    func paste(_ text: String) async throws
    /// Type a short piece key by key. Never steals focus: throws when not in front.
    func type(_ text: String) async throws
    /// Erase the last `text` typed, one Backspace per character. Never steals focus: throws when not in front.
    func erase(_ text: String) async throws
    /// Bring the dictation's window back to the front; false when it couldn't.
    func focus() async -> Bool
    /// Delete the current selection (Backspace).
    func deleteSelection() async throws
    /// Read-only: is `expected` the text right before the caret?
    func checkBeforeCaret(_ expected: String, timeout: Duration) async -> LiveText
    /// Select `expected` if it is exactly the text right before the caret; false (nothing selected) otherwise.
    func selectBeforeCaret(_ expected: String, timeout: Duration) async -> Bool
    /// If the text before the caret is `first` then `second`, select `first`.
    func selectDoubled(_ first: String, _ second: String, timeout: Duration) async -> Bool
    /// Take a copy of the user's clipboard (before the first live paste).
    func holdClipboard()
    /// Put the copy back.
    func restoreClipboard()
    /// Drop the copy: what is on the clipboard now stays.
    func forgetClipboard()
    /// Put text on the clipboard (an ordinary copy, for the user to paste).
    func copy(_ text: String)
    /// The live text may be erased blind, with Backspace, when it can't be read (Windows always may). The App Store
    /// build, which can never read it, says no once the user has clicked somewhere since the typing began: the caret
    /// may not be after the typed text any more.
    var mayEraseUnread: Bool { get }
}

public extension LiveTarget {
    var mayEraseUnread: Bool { true }
}

/// "Type as you speak" for one dictation (Windows `Session/LiveInsertion.cs`). While recording, each finished piece from
/// the recognizer (whole sentences, every ~5 s) is cleaned up and typed into the target right away. When the user stops,
/// the whole recording, cleaned in one pass, replaces everything typed live; that replacement only happens after
/// confirming (through Accessibility) that the text before the caret is exactly what was typed. With a profile that
/// rewrites the whole dictation (an email, say), pieces are typed as spoken, since the instructions only make sense for
/// the whole, and the rewrite replaces them at the end. A profile without AI goes further: the recognizer's running guess
/// is typed as it is heard (about every second, the same words the overlay shows), pasted (or typed, if the profile says
/// so), and corrected in place with Backspace when the guess changes.
@MainActor
public final class LiveInsertion {
    /// How long a slow app may take to show its text through Accessibility (plus 1 ms a character, up to 2.5 s).
    public static let readTimeout: Duration = .milliseconds(700)
    /// Breathing room between live insertions, so the app has read one paste before the next one starts.
    public var minGap: Duration = .milliseconds(700)
    /// Settle time after the last live paste, Backspace or keystroke: the app handles them a moment after they are
    /// sent, and reading the document before then finds it out of date.
    public var settle: Duration = .milliseconds(450)
    /// The user's clipboard comes back this long after the last paste.
    public var releaseDelay: Duration = .milliseconds(800)

    private let target: LiveTarget
    private let profile: Profile
    private let context: Task<InsertionContext?, Never>
    /// The AI's edit of one piece; the piece itself (trimmed) when the AI fails.
    private let cleanPiece: (String) async -> String
    private let holdsClipboard: Bool

    private var typedPieces = ""
    /// Cleaned pieces not typed: the target lost focus, or typing failed.
    private var held: [String] = []
    private var queue: Task<Void, Never>?
    private var queued: [Task<Void, Never>] = []
    /// Typed from the running guess, after the pieces; revised as the guess changes.
    private var partialTyped = ""
    /// The newest guess, not typed yet (older ones are skipped).
    private var pendingPartial: String?
    private var partialQueued = false
    private var clipboardTaken = false
    private var lastInsert: ContinuousClock.Instant?
    private var stopped = false

    /// `holdsClipboard`: take the user's clipboard before the first live paste and put it back once at the end
    /// (Settings › General's "Put my clipboard back").
    public init(target: LiveTarget, profile: Profile, context: Task<InsertionContext?, Never>, holdsClipboard: Bool = true,
                clean: @escaping (String) async -> String) {
        self.target = target
        self.profile = profile
        self.context = context
        self.holdsClipboard = holdsClipboard
        self.cleanPiece = clean
    }

    /// Exactly what has been typed so far, in order.
    public var typed: String { typedPieces + partialTyped }
    public var hasTyped: Bool { !typed.isEmpty }

    /// No AI: the words go in as they are heard, not only once a piece is finished.
    private var streams: Bool { !profile.autoProcess }

    /// The recognizer's running guess at the speech since the last finished piece. Typed right away for a profile
    /// without AI; ignored otherwise (the AI needs finished sentences).
    public func setPartial(_ partial: String) {
        guard streams, !stopped else { return }
        pendingPartial = partial
        if partialQueued { return } // the queued update will pick up this newer guess
        partialQueued = true
        enqueue { await self.applyPartial() }
    }

    private func applyPartial() async {
        partialQueued = false
        let partial = pendingPartial
        pendingPartial = nil
        guard let partial, !stopped, !SpeechGuard.isStockPhrase(partial) else { return }
        // Never pull focus back mid-dictation; the finished piece or the final pass catches up.
        guard held.isEmpty, target.isInFront else { return }
        if await target.nowhere() { return }
        do { try await replacePartial(fit(partial)) } catch is CancellationError {
        } catch let e as UserFacingError {
            CoreLog.warn("Live typing of the running guess failed: " + e.message)
        } catch {
            CoreLog.error("Live guess failed: \(error)")
        }
    }

    /// Queue a finished piece; pieces are cleaned and typed strictly in order.
    public func add(_ piece: String) { enqueue { await self.addPiece(piece) } }

    /// Wait until every queued piece is typed (or held).
    public func drain() async { await queue?.value }

    /// Stop typing pieces (the dictation was cancelled or failed), and give the clipboard back.
    public func stop() {
        stopped = true
        for task in queued { task.cancel() }
        Task { await releaseClipboard() }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        queue = task
        queued.removeAll { $0.isCancelled }
        queued.append(task)
        if queued.count > 32 { queued.removeFirst(queued.count - 32) }
    }

    private func addPiece(_ piece: String) async {
        guard !stopped, !SpeechGuard.isStockPhrase(piece) else { return }
        let cleaned = await clean(piece)
        guard !stopped, !Task.isCancelled else { return }
        // Never pull focus back mid-dictation; whatever can't be typed now is handled when the user stops.
        var away = !held.isEmpty || !target.isInFront
        if !away { away = await target.nowhere() }
        if away { held.append(cleaned); return }
        let text = ContextFit.apply(cleaned, context: await contextAfterTyped())
        do {
            if !partialTyped.isEmpty {
                // The piece's words are mostly typed already, as they were heard: correct them into the final piece.
                try await replacePartial(text)
                partialTyped = ""
            } else {
                try await insertLive(text)
            }
            typedPieces += text
        } catch is CancellationError {
        } catch let e as UserFacingError {
            CoreLog.warn("Live insertion failed: " + e.message)
            held.append(cleaned)
        } catch {
            CoreLog.error("Live piece failed: \(error)")
        }
    }

    private func clean(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !profile.autoProcess || profile.rewriteWhole || trimmed.isEmpty { return trimmed }
        return await cleanPiece(raw)
    }

    /// Insert during a live dictation: the clipboard stays ours until `releaseClipboard`.
    private func insertLive(_ text: String) async throws {
        try await beforeInsert()
        try await target.insert(text)
        lastInsert = .now
    }

    private func beforeInsert() async throws {
        if !clipboardTaken, holdsClipboard {
            clipboardTaken = true
            target.holdClipboard()
        }
        if let lastInsert {
            let wait = minGap - (ContinuousClock.now - lastInsert)
            if wait > .zero { try await Task.sleep(for: wait) }
        }
    }

    /// The dictation is over: once the last paste has had time to land, give the user their clipboard back.
    public func releaseClipboard() async {
        guard clipboardTaken else { return }
        clipboardTaken = false
        await drain()
        try? await Task.sleep(for: releaseDelay)
        target.restoreClipboard()
    }

    /// Keep whatever is on the clipboard now (the dictation was left there so it isn't lost).
    public func forgetClipboard() {
        if clipboardTaken { target.forgetClipboard() }
        clipboardTaken = false
    }

    /// Spacing and capitals for text that follows what has been typed for good so far.
    private func fit(_ text: String) async -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "" : ContextFit.apply(t, context: await contextAfterTyped())
    }

    /// Make the typed guess read `want`: keep the part that already matches (whole characters), erase the rest with
    /// Backspace, type the difference.
    private func replacePartial(_ want: String) async throws {
        let have = Array(partialTyped), wanted = Array(want)
        var keep = 0
        while keep < have.count, keep < wanted.count, have[keep] == wanted[keep] { keep += 1 }
        if keep < have.count {
            try await target.erase(String(have[keep...]))
            partialTyped = String(have[..<keep])
            lastInsert = .now
        }
        if keep < wanted.count {
            let more = String(wanted[keep...])
            if profile.liveTyping {
                try await target.type(more)
            } else {
                try await beforeInsert()
                try await target.paste(more)
            }
            lastInsert = .now
            partialTyped = want
        }
    }

    /// The original context, with the finished pieces live dictation already typed appended to the text before the
    /// caret (not the running guess, which the next text replaces).
    private func contextAfterTyped() async -> InsertionContext? {
        let ctx = await context.value
        if typedPieces.isEmpty { return ctx }
        return InsertionContext(before: (ctx?.before ?? "") + typedPieces, after: ctx?.after ?? "")
    }

    /// The user stopped. Replace the live text with `finalText` (the whole recording, cleaned in one pass). If the live
    /// text can't be confirmed in place, keep it and type only what is missing: pieces that were held back and `tail`,
    /// the speech after the last piece. Returns the text now in the document for this dictation, and a note for the
    /// receipt when the final pass couldn't run.
    public func finish(_ finalText: String, tail: String) async throws -> (inserted: String, note: String?) {
        await drain()
        guard await target.focus() else {
            throw UserFacingError("Couldn't switch back to the app you were typing in. Click into it and try again.")
        }
        try Task.checkCancellation()
        let rewrite = profile.rewriteWhole && profile.autoProcess
        if Self.isPlausibleReplacement(finalText, typed: typed, rewrite: rewrite) {
            let replacement = ContextFit.fit(finalText, context: await context.value, spacingOnly: rewrite)
            let typed = self.typed
            let timeout = Self.timeout(for: typed.utf16.count)
            let check = await checkTyped(timeout)
            if check == .matches, await target.selectBeforeCaret(typed, timeout: timeout) {
                try await insertLive(replacement) // replaces the selection
                CoreLog.info("Live dictation: final pass replaced \(typed.count) typed chars with \(replacement.count)")
                await removeDouble(typed, replacement)
                return (replacement, nil)
            }
            // Apps that don't show their text to Accessibility (terminals, many Electron apps), or won't take a
            // selection: nothing says the live text was changed, and it is still right before the caret in the same
            // window, so take it out the way live typing corrects itself, with Backspace, and paste the final text. Not
            // when the app shows different words there: then the user has edited it.
            if check != .differs, target.isInFront, target.mayEraseUnread {
                do {
                    try await target.erase(typed.replacingOccurrences(of: "\r\n", with: "\n"))
                    lastInsert = .now
                    try await insertLive(replacement)
                    CoreLog.info("Live dictation: final pass erased \(typed.count) typed chars and pasted \(replacement.count) (\(check))")
                    return (replacement, nil)
                } catch let e as UserFacingError {
                    CoreLog.warn("Couldn't erase the live text: " + e.message)
                    throw e
                }
            }
        }

        var rest = held
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { rest.append(await clean(tail)) }
        var missing = ContextFit.apply(rest.filter { !$0.isEmpty }.joined(separator: " "), context: await contextAfterTyped())
        if !partialTyped.isEmpty {
            // The last words went in as they were heard: correct them into the rest rather than typing them twice.
            do { try await replacePartial(missing) } catch let e as UserFacingError {
                CoreLog.warn("Couldn't correct the last words typed live: " + e.message)
            }
            missing = ""
        } else if !missing.isEmpty {
            try await insertLive(missing)
        }
        CoreLog.info("Live dictation: couldn't confirm the typed text, so the final pass was skipped")
        if rewrite, !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The words as spoken are in the document; hand over the rewrite so it isn't lost. (Windows then puts the
            // user's old clipboard back over it 800 ms later; here the rewrite stays.)
            target.copy(finalText)
            forgetClipboard()
            return (typed + missing,
                    "This app didn't let Oberton replace the text it typed while you spoke, so your words were kept as "
                        + "spoken. The rewritten version is on your clipboard.")
        }
        return (typed + missing,
                "This app didn't let Oberton confirm the text it typed while you spoke, so that text was kept as typed "
                    + "and only the rest was added.")
    }

    /// Wait until the app shows the text typed live (reading only, nothing visible); a few tries, since a busy app can
    /// take a while to show its last paste. The last answer if it never matches.
    private func checkTyped(_ timeout: Duration) async -> LiveText {
        var check = LiveText.unreadable
        for _ in 0..<4 {
            await settleDown()
            check = await target.checkBeforeCaret(typed, timeout: timeout)
            if check != .differs { return check } // matches, or nothing more to learn by waiting
            lastInsert = .now // wait a full settle before the next try
        }
        return check
    }

    private func settleDown() async {
        guard let lastInsert else { return }
        let wait = settle - (ContinuousClock.now - lastInsert)
        if wait > .zero { try? await Task.sleep(for: wait) }
    }

    /// Long text takes a slow app (Electron ones especially) a while to report through Accessibility.
    nonisolated static func timeout(for length: Int) -> Duration { readTimeout + .milliseconds(min(2500, length)) }

    /// Select the text typed live, once the app has caught up with the last edit.
    private func selectTyped() async -> Bool {
        let timeout = Self.timeout(for: typed.utf16.count)
        guard await checkTyped(timeout) == .matches else { return false }
        return await target.selectBeforeCaret(typed, timeout: timeout)
    }

    /// A last check that the final pass replaced the live text instead of landing after it: if the document reads the
    /// live text and then the replacement, take the live text out.
    private func removeDouble(_ typed: String, _ replacement: String) async {
        do {
            try await Task.sleep(for: settle)
            let timeout = Self.readTimeout + .milliseconds(min(2500, typed.utf16.count + replacement.utf16.count))
            guard await target.selectDoubled(typed, replacement, timeout: timeout) else { return }
            try await target.deleteSelection()
            CoreLog.info("Live dictation: the final pass landed after the live text instead of replacing it; removed the live text")
        } catch is CancellationError {
        } catch {
            CoreLog.warn("Couldn't check for doubled live text: \(error.localizedDescription)")
        }
    }

    /// The final pass must cover at least most of what was already typed: an empty or much shorter result (a failed
    /// final decode, a model that summarized) would delete the user's words. A rewrite may legitimately be much
    /// shorter; the AI step already checked it.
    public nonisolated static func isPlausibleReplacement(_ finalText: String, typed: String, rewrite: Bool = false) -> Bool {
        func words(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }
        let n = words(finalText)
        return n > 0 && Double(n) >= Double(words(typed)) * (rewrite ? 0.1 : 0.6)
    }

    /// Cancelled: remove what was typed live, if it can be confirmed in place.
    public func removeTyped() async {
        stop()
        await drain()
        guard hasTyped, await target.focus() else { return }
        if await selectTyped() {
            try? await target.deleteSelection()
        } else {
            CoreLog.info("Live dictation cancelled; the typed text couldn't be confirmed, so it was left in place")
        }
    }
}
