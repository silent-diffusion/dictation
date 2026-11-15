import Testing
@testable import ObertonCore

// Ported from tests/Dictation.Tests/WordDiffTests.cs: the word diff History's AI EDIT box and the word tally read.

@Suite struct WordDiffParityTests {
    private func kept(_ d: [DiffToken]) -> String { d.filter { $0.kind != .removed }.map(\.word).joined(separator: " ") }
    private func removed(_ d: [DiffToken]) -> [String] { d.filter { $0.kind == .removed }.map(\.word) }

    @Test func keptWordsReadBackAsTheEditedText() {
        let raw = "um so yesterday I I went to the the store and and bought uh three apples no wait four apples"
        let edited = "Yesterday I went to the store and bought four apples."
        let d = WordDiff.compute(raw, edited)
        #expect(kept(d) == edited)
        #expect(removed(d).contains("um"))
        #expect(removed(d).contains("uh"))
        #expect(d.contains { $0.kind != .same })
    }

    @Test func caseAndPunctuationChangesAreNotEdits() {
        let d = WordDiff.compute("so i think we should meet", "So I think we should meet.")
        #expect(d.allSatisfy { $0.kind == .same })
    }

    @Test func replacedWordsShowAsRemovedThenAdded() {
        let d = WordDiff.compute("fifty dollars", "sixty dollars")
        #expect(d.map(\.kind) == [.removed, .added, .same])
        #expect(d[0].word == "fifty")
        #expect(d[1].word == "sixty")
    }

    @Test func emptyInputsAreHandled() {
        #expect(WordDiff.compute("", "").isEmpty)
        #expect(WordDiff.compute("", "hello there").allSatisfy { $0.kind == .added })
        #expect(WordDiff.compute("hello there", "").allSatisfy { $0.kind == .removed })
    }
}
