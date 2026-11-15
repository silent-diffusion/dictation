import Foundation
import Testing
@testable import ObertonCore

// Ported from tests/Dictation.Tests/MarkdownTextTests.cs and ReadAloudTextTests.cs so both apps read text the same way.

@Suite struct MarkdownTextTests {
    @Test(arguments: [
        "Hello there. How are you?",
        "We came #1 in the league, 5*3 = 15, and my_file_name stays.",
        "Learn C# today.\nThe 3 - 2 = 1 rule.",
    ])
    func ordinaryTextComesThroughUnchanged(_ text: String) { #expect(MarkdownText.forReading(text) == text) }

    @Test(arguments: [
        ("Shopping:\n- milk\n- eggs", "Shopping:\nmilk\neggs"),
        ("I *really* mean it.", "I really mean it."),
        ("Two steps:\n1. **Install** it\n2. Run it", "Two steps:\n1. Install it\n2. Run it"),
        ("• first\n• second", "first\nsecond"),
        ("##Notes\nA *dangling bold", "Notes\nA dangling bold"),
        ("a | b | c", "a, b, c"),
    ])
    func lightMarkdownIsCleanedToo(_ text: String, _ expected: String) { #expect(MarkdownText.forReading(text) == expected) }

    @Test func headingsListsAndEmphasisBecomePlainLines() {
        let md = "## Getting started\n\n1. Install it\n- **Fast** and _simple_\n- [ ] Not done yet\n> A quote with `code`\n\n---\n\nDone ~~soon~~ now."
        #expect(MarkdownText.toPlain(md) == "Getting started\n\n1. Install it\nFast and simple\nNot done yet\nA quote with code\n\nDone soon now.")
    }

    @Test func linksAndImagesKeepTheirTextNotTheAddress() {
        #expect(MarkdownText.toPlain("Read [the guide](https://x.org/a?b=c \"Guide\") and look at ![the chart](img/c.png).")
                == "Read the guide and look at the chart.")
        #expect(MarkdownText.toPlain("See [the spec][1].\n\n[1]: https://example.com/spec") == "See the spec.")
    }

    @Test func codeFencesGoButTheCodeStays() { #expect(MarkdownText.toPlain("Run this:\n```bash\nnpm test\n```") == "Run this:\nnpm test") }

    @Test func tableRowsAreReadAsListsOfCells() {
        #expect(MarkdownText.toPlain("| Name | Age |\n|:-----|----:|\n| Ada | 36 |") == "Name, Age\nAda, 36")
    }

    @Test func headingKeepsATrailingHashThatIsPartOfAWord() { #expect(MarkdownText.toPlain("# Learn C#\n# Intro ##") == "Learn C#\nIntro") }

    @Test func escapesAndLineBreakTagsAreResolved() { #expect(MarkdownText.toPlain("2 \\* 3 is 6<br>next") == "2 * 3 is 6\nnext") }

    @Test func autolinksKeepTheAddress() { #expect(MarkdownText.toPlain("Mail <mailto:a@b.org> or see <https://x.org>.") == "Mail mailto:a@b.org or see https://x.org.") }

    @Test func plainMarkdownTextSplitsIntoReadablePieces() {
        let plain = MarkdownText.forReading("# Notes\n\n- **First** point.\n- Second point.")
        #expect(ReadAloudTextTests.pieces(plain) == ["Notes", "First point.", "Second point."])
    }
}

@Suite struct ReadAloudTextTests {
    static func pieces(_ text: String) -> [String] { ReadAloudText.split(text).map { (text as NSString).substring(with: $0) } }

    @Test func splitsIntoSentencesWithTheirPunctuation() {
        #expect(Self.pieces("Hello there. How are you? Fine!") == ["Hello there.", "How are you?", "Fine!"])
    }

    @Test func lineBreaksSplitListsAndHeadings() {
        #expect(Self.pieces("Shopping list\n- milk\n\n- eggs\n") == ["Shopping list", "- milk", "- eggs"])
    }

    @Test func quotesStayWithTheirSentence() {
        #expect(Self.pieces("She said \"stop.\" Then she left.") == ["She said \"stop.\"", "Then she left."])
    }

    @Test func piecesWithoutWordsAreSkipped() { #expect(Self.pieces("--- \n\n Real text. \n * * *") == ["Real text."]) }

    @Test func longSentencesBreakAtCommasAndNeverExceedTheLimit() {
        let clause = "this is one clause of a very long sentence that goes on"
        let text = Array(repeating: clause, count: 20).joined(separator: ", ") + "."
        let spans = ReadAloudText.split(text)
        #expect(spans.count > 3)
        #expect(spans.allSatisfy { $0.length <= ReadAloudText.maxPieceChars })
        #expect(spans.dropLast().allSatisfy { (text as NSString).substring(with: $0).hasSuffix(",") })
    }

    @Test func spansPointIntoTheOriginalTextInOrder() {
        let text = "  First line.\r\n\r\nSecond   line here.  "
        let spans = ReadAloudText.split(text)
        #expect(spans.count == 2)
        #expect(NSMaxRange(spans[0]) <= spans[1].location)
        #expect(ReadAloudText.speakable(text, spans[1]) == "Second line here.")
    }
}
