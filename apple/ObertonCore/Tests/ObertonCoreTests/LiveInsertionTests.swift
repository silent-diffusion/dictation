import Foundation
import Testing
@testable import ObertonCore

// Ported from the Windows LiveInsertionTests and RewriteWholeTests, plus the whole "type as you speak" flow against a
// pretend document (Windows tests only the pure parts).

@Suite struct LiveInsertionPlausibilityTests {
    @Test func finalPassMayTidyTheTypedText() {
        #expect(LiveInsertion.isPlausibleReplacement("So I think we should meet on Tuesday.",
                                                     typed: "So I think, um, we should meet on on Tuesday."))
    }

    @Test(arguments: ["", "Meeting Tuesday."])
    func finalPassNeverReplacesWithMuchLess(_ finalText: String) {
        #expect(!LiveInsertion.isPlausibleReplacement(finalText, typed: "So I think we should meet on Tuesday because Sarah is free that afternoon."))
    }

    static let rambling = "okay so I need to tell Mark that the report is going to be late because the numbers from finance "
        + "came in on Thursday instead of Monday and um I think we can have it to him by next Wednesday "
        + "and also ask if he wants the summary slides too or just the spreadsheet"
    static let email = "Hi Mark,\n\nThe report will be a few days late: finance sent the numbers on Thursday instead of Monday. "
        + "I expect to have it to you by next Wednesday.\n\nWould you like summary slides as well, or just the spreadsheet?\n\nThanks"

    @Test func liveTextMayBeReplacedByAMuchShorterRewrite() {
        #expect(!LiveInsertion.isPlausibleReplacement(Self.email, typed: Self.rambling + " " + Self.rambling))
        #expect(LiveInsertion.isPlausibleReplacement(Self.email, typed: Self.rambling + " " + Self.rambling, rewrite: true))
        #expect(!LiveInsertion.isPlausibleReplacement("", typed: Self.rambling, rewrite: true))
    }

    @Test(arguments: [("Hello there.\r\nNext line", "Hello there.\nNext line"), ("It’s “fine”", "It's \"fine\""), ("a b", "a b")])
    func editorSubstitutionsStillCountAsTheSameText(_ pair: (String, String)) {
        #expect(InsertionContext.sameText(pair.0, pair.1))
    }

    @Test func differentTextIsNotTheSame() {
        #expect(!InsertionContext.sameText("Hello there", "Hello their"))
    }
}

/// A text field in another app: its text, caret and selection, whether it is in front, and whether Accessibility can
/// read it.
@MainActor
class FakeDocument: LiveTarget {
    var text: String
    /// The caret / selection, in UTF-16 units (as Accessibility reports them).
    var selection: NSRange
    var inFront = true
    var readable = true
    var clicked = false
    var clipboard = "user's clipboard"
    private var savedClipboard: String?
    var log: [String] = []

    init(_ text: String = "") {
        self.text = text
        selection = NSRange(location: (text as NSString).length, length: 0)
    }

    var isInFront: Bool { inFront }
    func nowhere() async -> Bool { false }
    var mayEraseUnread: Bool { !clicked }

    private func replaceSelection(_ s: String) {
        text = (text as NSString).replacingCharacters(in: selection, with: s)
        selection = NSRange(location: selection.location + (s as NSString).length, length: 0)
    }

    private func requireFront() throws {
        if !inFront { throw UserFacingError("The app you were dictating into isn't in front any more.") }
    }

    func insert(_ s: String) async throws { inFront = true; log.append("insert " + s); clipboard = s; replaceSelection(s) }
    func paste(_ s: String) async throws { try requireFront(); log.append("paste " + s); clipboard = s; replaceSelection(s) }
    func type(_ s: String) async throws { try requireFront(); log.append("type " + s); replaceSelection(s) }

    func erase(_ s: String) async throws {
        try requireFront()
        log.append("erase \(s.count)")
        let before = (text as NSString).substring(to: selection.location)
        let kept = String(before.dropLast(s.count))
        text = kept + (text as NSString).substring(from: selection.location)
        selection = NSRange(location: (kept as NSString).length, length: 0)
    }

    func focus() async -> Bool { inFront = true; return true }

    func deleteSelection() async throws {
        log.append("delete")
        if selection.length > 0 { replaceSelection("") } else { try await erase("x") }
    }

    private var caret: Int { NSMaxRange(selection) }

    private func beforeCaret(_ n: Int) -> String {
        let ns = text as NSString
        return ns.substring(with: NSRange(location: max(0, caret - n), length: min(n, caret)))
    }

    func checkBeforeCaret(_ expected: String, timeout: Duration) async -> LiveText {
        guard readable else { return .unreadable }
        return InsertionContext.sameText(beforeCaret(expected.utf16.count), expected) ? .matches : .differs
    }

    func selectBeforeCaret(_ expected: String, timeout: Duration) async -> Bool {
        guard readable, InsertionContext.sameText(beforeCaret(expected.utf16.count), expected) else { return false }
        selection = NSRange(location: caret - expected.utf16.count, length: expected.utf16.count)
        return true
    }

    func selectDoubled(_ first: String, _ second: String, timeout: Duration) async -> Bool {
        let both = first + second
        guard readable, InsertionContext.sameText(beforeCaret(both.utf16.count), both) else { return false }
        selection = NSRange(location: caret - both.utf16.count, length: first.utf16.count)
        return true
    }

    func holdClipboard() { log.append("hold clipboard"); savedClipboard = clipboard }
    func restoreClipboard() { log.append("restore clipboard"); if let savedClipboard { clipboard = savedClipboard } }
    func forgetClipboard() { savedClipboard = nil }
    func copy(_ s: String) { clipboard = s }
}

@MainActor
@Suite struct LiveInsertionFlowTests {
    static let raw = Profile(name: "Raw", prompt: "", autoProcess: false)
    static let cleanup = Profile(name: "Cleanup", prompt: "Tidy.")
    static let email = Profile(name: "Email", prompt: "An email.", rewriteWhole: true)

    private func live(_ doc: FakeDocument, _ profile: Profile, context: InsertionContext? = nil,
                      clean: @escaping (String) async -> String = { $0.trimmingCharacters(in: .whitespaces).uppercased() }) -> LiveInsertion {
        let l = LiveInsertion(target: doc, profile: profile, context: Task { context }, clean: clean)
        l.minGap = .zero
        l.settle = .zero
        l.releaseDelay = .zero
        return l
    }

    @Test func aRawProfileStreamsTheRunningGuessAndCorrectsItWithBackspace() async {
        let doc = FakeDocument()
        let l = live(doc, Self.raw)
        l.setPartial("hello")
        await l.drain()
        #expect(doc.text == "hello")
        l.setPartial("hello world")
        await l.drain()
        l.setPartial("hello word")
        await l.drain()
        #expect(doc.text == "hello word")
        #expect(doc.log.contains("erase 2")) // only the changed end ("ld") was taken back
        // The finished piece replaces the guess it settled.
        l.add("Hello world.")
        await l.drain()
        #expect(doc.text == "Hello world.")
        #expect(l.typed == "Hello world.")
    }

    @Test func liveTypingTypesKeyByKeyInsteadOfPasting() async {
        var profile = Self.raw
        profile.liveTyping = true
        let doc = FakeDocument()
        let l = live(doc, profile)
        l.setPartial("one two")
        await l.drain()
        #expect(doc.log == ["type one two"])
        #expect(doc.clipboard == "user's clipboard")
    }

    @Test func aProfileWithAIIgnoresTheGuessAndTypesCleanedPieces() async throws {
        let doc = FakeDocument("Notes. ")
        let l = live(doc, Self.cleanup, context: InsertionContext(before: "Notes. ", after: ""))
        l.setPartial("first bit")
        l.add("first sentence.")
        l.add("second one.")
        await l.drain()
        #expect(doc.text == "Notes. FIRST SENTENCE. SECOND ONE.")
        // The final pass replaces exactly what was typed.
        let (inserted, note) = try await l.finish("First sentence. Second one.", tail: "")
        #expect(note == nil)
        #expect(inserted == "First sentence. Second one.")
        #expect(doc.text == "Notes. First sentence. Second one.")
        await l.releaseClipboard()
        #expect(doc.clipboard == "user's clipboard")
        #expect(doc.log.filter { $0 == "hold clipboard" }.count == 1)
    }

    @Test func aRewriteProfileTypesThePiecesAsSpokenThenReplacesThemWithTheRewrite() async throws {
        let doc = FakeDocument()
        var asked = 0
        let l = live(doc, Self.email) { piece in asked += 1; return piece }
        l.add("tell mark the report is late.")
        await l.drain()
        #expect(asked == 0) // the AI only sees the whole dictation
        #expect(doc.text == "tell mark the report is late.") // no context: as spoken
        let (_, note) = try await l.finish("Hi Mark,\n\nThe report is late.", tail: "")
        #expect(note == nil)
        #expect(doc.text == "Hi Mark,\n\nThe report is late.")
    }

    @Test func anUnreadableAppHasTheLiveTextErasedAndThenPastedOver() async throws {
        let doc = FakeDocument()
        doc.readable = false
        let l = live(doc, Self.cleanup)
        l.add("so um we meet tuesday.")
        await l.drain()
        let (_, note) = try await l.finish("So we meet Tuesday.", tail: "")
        #expect(note == nil)
        #expect(doc.text == "So we meet Tuesday.")
    }

    @Test func withoutAccessibilityAClickSinceTheTypingKeepsTheLiveText() async throws {
        let doc = FakeDocument()
        doc.readable = false
        let l = live(doc, Self.cleanup)
        l.add("so we meet tuesday.")
        await l.drain()
        doc.clicked = true
        let (inserted, note) = try await l.finish("So we meet Tuesday at noon.", tail: "at noon.")
        #expect(note?.hasPrefix("This app didn't let Oberton confirm") == true)
        #expect(doc.text == "SO WE MEET TUESDAY. AT NOON.")
        #expect(inserted == doc.text)
    }

    @Test func textTheUserChangedIsNeverReplaced() async throws {
        let doc = FakeDocument()
        let l = live(doc, Self.cleanup)
        l.add("hello there.")
        await l.drain()
        doc.text += " (edited)"
        doc.selection = NSRange(location: (doc.text as NSString).length, length: 0)
        let (_, note) = try await l.finish("Hello there, everyone.", tail: "everyone")
        #expect(note != nil)
        #expect(doc.text.hasPrefix("HELLO THERE. (edited)"))
    }

    @Test func aMuchShorterFinalPassKeepsTheLiveText() async throws {
        let doc = FakeDocument()
        let l = live(doc, Self.cleanup)
        l.add("so I think we should meet on tuesday because sarah is free that afternoon.")
        await l.drain()
        let before = doc.text
        let (_, note) = try await l.finish("Meeting Tuesday.", tail: "")
        #expect(note != nil)
        #expect(doc.text == before)
    }

    @Test func aRewriteThatCantReplaceGoesToTheClipboardAndStaysThere() async throws {
        let doc = FakeDocument()
        doc.readable = false
        doc.clicked = true
        let l = live(doc, Self.email)
        l.add("tell mark it's late.")
        await l.drain()
        let (_, note) = try await l.finish("Hi Mark, it's late.", tail: "")
        #expect(note?.contains("The rewritten version is on your clipboard.") == true)
        await l.releaseClipboard()
        #expect(doc.clipboard == "Hi Mark, it's late.")
    }

    @Test func piecesWaitWhileTheAppIsNotInFrontAndGoInAtTheEnd() async throws {
        let doc = FakeDocument()
        let l = live(doc, Self.cleanup)
        l.add("one.")
        await l.drain()
        doc.inFront = false
        l.add("two.")
        l.add("three.")
        await l.drain()
        #expect(doc.text == "ONE.")
        // A final pass that can't be used (much shorter): the held pieces and the tail are added.
        let (_, note) = try await l.finish("", tail: "four")
        #expect(note != nil)
        #expect(doc.text == "ONE. TWO. THREE. FOUR")
    }

    @Test func stockPhrasesAreNeverTyped() async {
        let doc = FakeDocument()
        let l = live(doc, Self.raw)
        l.setPartial("Thank you.")
        l.add("Thank you.")
        await l.drain()
        #expect(doc.text.isEmpty)
    }

    @Test func cancellingRemovesTheTypedTextOnlyWhenItCanBeConfirmed() async {
        let doc = FakeDocument("Keep this. ")
        let l = live(doc, Self.cleanup)
        l.add("drop this.")
        await l.drain()
        await l.removeTyped()
        #expect(doc.text == "Keep this. ")

        let unread = FakeDocument("Keep this. ")
        unread.readable = false
        let l2 = live(unread, Self.cleanup)
        l2.add("stays.")
        await l2.drain()
        await l2.removeTyped()
        #expect(unread.text == "Keep this. STAYS.")
    }

    @Test func theFinalPassLandingAfterTheLiveTextIsTidiedUp() async throws {
        // An app that takes the selection but pastes after it: the doubled live text is found and removed.
        final class Stubborn: FakeDocument {
            override func insert(_ s: String) async throws {
                selection = NSRange(location: NSMaxRange(selection), length: 0)
                try await super.insert(s)
            }
        }
        let doc = Stubborn()
        let l = live(doc, Self.cleanup)
        l.add("hello there.")
        await l.drain()
        _ = try await l.finish("Hello there.", tail: "")
        #expect(doc.text == "Hello there.")
    }
}
