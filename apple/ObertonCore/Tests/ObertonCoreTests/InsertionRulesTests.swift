import Foundation
import Testing
@testable import ObertonCore

// The Mac inserter's rules against Windows' TextInserter, PasteSpot and SelectionReader (lane I), and the stitcher's
// .NET word boundary.

@Suite struct InsertionRulesTests {
    /// Windows TurnaroundTests.No_window_is_nowhere_to_type: `PasteSpot.IsNowhere(IntPtr.Zero)`.
    @Test func noWindowIsNowhereToType() { #expect(InsertionRules.isNowhere(.none, accessibility: true)) }

    @Test(arguments: ["com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver"])
    func theShellIsNowhere(_ id: String) {
        #expect(InsertionRules.isNowhere(.other(bundleID: id), accessibility: true))
        #expect(InsertionRules.isNowhere(.other(bundleID: id), accessibility: false))
    }

    @Test func ordinaryAppsAreSomewhere() {
        #expect(!InsertionRules.isNowhere(.other(bundleID: "com.apple.TextEdit"), accessibility: false))
        #expect(!InsertionRules.isNowhere(.other(bundleID: nil), accessibility: false))
    }

    /// Without Accessibility the Finder's desktop can't be told from its windows; with it, the focused control decides.
    @Test func theFinderIsNowhereOnlyWithoutAccessibility() {
        #expect(InsertionRules.isNowhere(.other(bundleID: "com.apple.finder"), accessibility: false))
        #expect(!InsertionRules.isNowhere(.other(bundleID: "com.apple.finder"), accessibility: true))
    }

    @Test func obertonIsSomewhereOnlyInItsOwnTextField() {
        #expect(InsertionRules.isNowhere(.oberton(textFieldFocused: false), accessibility: true))
        #expect(!InsertionRules.isNowhere(.oberton(textFieldFocused: true), accessibility: false))
    }

    /// Windows `text.Contains('\n')`.
    @Test func onlyALineFeedMakesTextMultiLine() {
        #expect(InsertionRules.isMultiLine("a\nb"))
        #expect(InsertionRules.isMultiLine("a\r\nb")) // one Character in Swift, still a '\n' to Windows
        for single in ["a\rb", "a\u{2028}b", "a\u{2029}b", "a\u{0085}b", "a\u{000B}b", "a\u{000C}b", "plain"] {
            #expect(!InsertionRules.isMultiLine(single))
        }
    }

    @Test func pasteWaitCountsUTF16Units() {
        #expect(InsertionRules.pasteWait("") == .milliseconds(450))
        #expect(InsertionRules.pasteWait(String(repeating: "😀", count: 20)) == .milliseconds(452)) // 40 units
        #expect(InsertionRules.pasteWait(String(repeating: "a", count: 100_000)) == .milliseconds(1300))
    }

    /// Windows: batches of 4 UTF-16 units, 5 when the 4th is the first half of a pair.
    @Test func typingBatchesFollowWindowsUnits() {
        func shape(_ text: String) -> [Int] { InsertionRules.typingBatches(text).map { $0.reduce(0) { $0 + $1.count } } }
        #expect(shape("abcdefghij") == [4, 4, 2])
        #expect(shape("abc😀def") == [5, 3]) // the pair at units 4–5 is taken whole
        #expect(shape("ab😀cdef") == [4, 4])
        #expect(shape("") == [])
        // One keystroke per code point; a pair is one keystroke.
        #expect(InsertionRules.typingBatches("abc😀").first?.count == 4)
        #expect(InsertionRules.typingBatches("e\u{301}").first?.count == 2)
        #expect(InsertionRules.typingBatches("abc😀def").flatMap { $0 }.map { String(decoding: $0, as: UTF16.self) }.joined() == "abc😀def")
    }

    /// QWERTY: the ANSI key. Dvorak: the key that types v. "Dvorak – QWERTY ⌘": the QWERTY key again (⌘ uses it).
    @Test func pasteKeyFollowsTheLayout() {
        let qwerty: [UInt16: String] = [0x08: "c", 0x09: "v", 0x2F: "."]
        let dvorak: [UInt16: String] = [0x08: "j", 0x09: "k", 0x2F: "v", 0x22: "c"]
        #expect(InsertionRules.keyCode(for: "v", preferred: 0x09) { qwerty[$0] } == 0x09)
        #expect(InsertionRules.keyCode(for: "v", preferred: 0x09) { dvorak[$0] } == 0x2F)
        #expect(InsertionRules.keyCode(for: "c", preferred: 0x08) { dvorak[$0] } == 0x22)
        #expect(InsertionRules.keyCode(for: "v", preferred: 0x09) { _ in "ж" } == nil)
        #expect(InsertionRules.keyCode(for: "v", preferred: 0x09) { $0 == 0x09 ? "V" : nil } == 0x09)
    }

    @Test func selectionsAreCappedInUTF16Units() {
        #expect(InsertionRules.capped("abcdef", max: 4) == "abcd")
        #expect(InsertionRules.capped("abc😀", max: 4) == "abc") // never half a pair
        #expect(InsertionRules.capped("short", max: 100) == "short")
    }
}

@Suite struct FragmentStitcherBoundaryTests {
    /// .NET's `\b` falls between "3" and ".", so the repeated "3" goes; the spacing tidy then joins "3.5".
    @Test func aNumberRepeatedAcrossTheCutIsDropped() {
        #expect(FragmentStitcher.join(["version 3", "3.5 percent"]) == "Version 3.5 percent")
        #expect(FragmentStitcher.dropRepeatedWord(before: "version 3", piece: "3.5 percent") == ".5 percent")
    }
    @Test func aDottedWordRepeatedAcrossTheCutIsDropped() {
        #expect(FragmentStitcher.dropRepeatedWord(before: "go to example", piece: "example.com now") == ".com now")
    }
}
