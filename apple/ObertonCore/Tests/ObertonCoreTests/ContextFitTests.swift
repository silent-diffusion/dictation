import Testing
@testable import ObertonCore

// Ported from the Windows ContextFitTests.

@Suite struct ContextFitTests {
    private func fit(_ text: String, _ before: String, _ after: String) -> String {
        ContextFit.apply(text, context: InsertionContext(before: before, after: after))
    }

    @Test func withoutContextTheTextIsUnchanged() {
        #expect(ContextFit.apply("Hello there.", context: nil) == "Hello there.")
    }

    @Test func shortPhraseMidSentenceIsLowercasedWithoutAPeriod() {
        #expect(fit("Quickly.", "We need to finish this ", "before Friday.") == "quickly ")
    }

    @Test func wordAtTheEndOfAnUnfinishedSentenceGetsNoPeriod() {
        #expect(fit("Groceries.", "Remember to buy the ", "") == "groceries")
    }

    @Test func newSentenceAfterAFullStopKeepsCapitalAndPeriod() {
        #expect(fit("this is new.", "The first sentence ends here. ", "") == "This is new.")
    }

    @Test func emptyDocumentStartsASentence() {
        #expect(fit("hello world.", "", "") == "Hello world.")
    }

    @Test func spacesAreAddedWhereWordsWouldTouch() {
        #expect(fit("Brown.", "The quick", "fox jumps.") == " brown ")
    }

    @Test func periodIsKeptWhenTheNextSentenceFollows() {
        #expect(fit("And that was it.", "We waited ", "Then we left.") == "and that was it. ")
    }

    @Test func namesAcronymsAndIKeepTheirCapitals() {
        #expect(fit("I think so.", "Well, ", "").hasPrefix("I think"))
        #expect(fit("NASA launched it.", "Yesterday ", "").hasPrefix("NASA"))
        #expect(fit("Sarah agreed.", "We asked Sarah and ", "").hasPrefix("Sarah"))
    }

    @Test func aWordCapitalizedOnlyAtASentenceStartIsLowercased() {
        #expect(fit("Maybe later.", "Maybe. We could go ", "") == "maybe later")
    }

    @Test(arguments: ["\u{200B}", "\u{FFFC}", "\u{FEFF}", "\u{00A0}", " \n "])
    func aBlankFieldStartsASentenceWithoutALeadingSpace(blank: String) {
        let c = InsertionContext.trim(before: blank, after: blank)
        #expect(ContextFit.apply("hello world.", context: c) == "Hello world.")
    }

    @Test func invisibleCharactersDontHideAFullStop() {
        #expect(ContextFit.apply("this is new.", context: InsertionContext.trim(before: "Done.\u{200B}", after: "")) == " This is new.")
    }

    @Test func trimKeepsTwoSentencesBeforeAndOneAfter() {
        let c = InsertionContext.trim(before: "One. Two. Three. Four ", after: "five. Six. Seven.")
        #expect(c.before == "Three. Four ")
        #expect(c.after == "five.")
    }

    @Test func spacingOnlyKeepsCapitalsAndPunctuation() {
        #expect(ContextFit.fit("Dear Sam.", context: InsertionContext(before: "Hi", after: "x"), spacingOnly: true) == " Dear Sam. ")
    }

    @Test func sameTextIgnoresEditorSubstitutions() {
        #expect(InsertionContext.sameText("It\u{2019}s \u{201C}ok\u{201D}\r\nyes\u{00A0}no", "It's \"ok\"\nyes no"))
        #expect(!InsertionContext.sameText("a", "b"))
    }

    // Windows InsertionContext.IsEmptyField: placeholders and invisible characters count as an empty field.
    @Test func blankOrInvisibleTextIsAnEmptyField() {
        #expect(InsertionContext.isEmptyField(shown: " \u{200B}\u{FEFF}\n", value: nil, labels: []))
    }

    @Test func aPlaceholderTheValueDoesntHaveIsAnEmptyField() {
        #expect(InsertionContext.isEmptyField(shown: "Type a message", value: "", labels: []))
        #expect(!InsertionContext.isEmptyField(shown: "See you then. Bye", value: "", labels: [])) // a sentence: real text
        #expect(!InsertionContext.isEmptyField(shown: "Type a message", value: "Type a message", labels: []))
    }

    @Test func textEqualToTheControlsLabelIsAPlaceholder() {
        #expect(InsertionContext.isEmptyField(shown: "Search", value: nil, labels: [nil, "search"]))
        #expect(!InsertionContext.isEmptyField(shown: "Search the docs", value: nil, labels: ["Search"]))
    }
}
