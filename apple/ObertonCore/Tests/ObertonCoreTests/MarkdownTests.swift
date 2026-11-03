import Foundation
import Testing
@testable import ObertonCore

// Ported from tests/Dictation.Tests/NotesMarkdownTests.cs and MarkdownDocTests.cs, so both apps read Markdown the same way.

@Suite struct NotesMarkdownTests {
    static func show(_ b: NotesMarkdown.Block) -> String {
        "\(b.kind):" + b.spans.map { s in
            s.isBreak ? "|" : s.code ? "`\(s.text)`" : s.bold && s.italic ? "***\(s.text)***" : s.bold ? "**\(s.text)**" : s.italic ? "_\(s.text)_" : s.text
        }.joined()
    }

    @Test func blocksAreFound() {
        let md = "# Title\n\nFirst line\nsecond line\n\n- one\n  - nested\n2. two\n> quoted\n---\n⚑ 12:34\n```\ncode *here*\n```"
        let blocks = NotesMarkdown.parse(md)
        #expect(blocks.map(Self.show) == ["heading:Title", "paragraph:First line|second line", "bullet:one", "bullet:nested", "numbered:two",
                                          "quote:quoted", "rule:", "marker:⚑ 12:34", "code:`code *here*`"])
        #expect(blocks[0].level == 1)
        #expect(blocks[3].level == 1)
        #expect(blocks[4].number == "2")
    }

    @Test func inlineMarkupAndLabels() {
        let b = NotesMarkdown.parse("Main idea: the **launch** moves to *May*, see `plan` and [the doc](http://x)")
        #expect(b.count == 1)
        #expect(Self.show(b[0]) == "paragraph:**Main idea:** the **launch** moves to _May_, see `plan` and the doc")
        #expect(NotesMarkdown.parse("snake_case_name and 2 * 3 * 4").map(Self.show) == ["paragraph:snake_case_name and 2 * 3 * 4"])
        #expect(NotesMarkdown.parse("**not closed").map(Self.show) == ["paragraph:**not closed"])
        #expect(NotesMarkdown.parse(#"\*literal\*"#).map(Self.show) == ["paragraph:*literal*"])
    }

    @Test func spansKnowWhereTheyCameFrom() {
        let md = "Hello **bold** world\n- item ⚑ émoji 👋 *x*"
        let ns = md as NSString
        for span in NotesMarkdown.parse(md).flatMap(\.spans) where !span.isBreak && !span.text.isEmpty {
            #expect(span.text == ns.substring(with: NSRange(location: span.offset, length: span.text.utf16.count)))
        }
    }

    @Test func summaryLayoutReadsWell() {
        let blocks = NotesMarkdown.parse("Main idea: Plans.\n\n- First point\n- Second point\n\nA paragraph.")
        #expect(blocks.map(Self.show) == ["paragraph:**Main idea:** Plans.", "bullet:First point", "bullet:Second point", "paragraph:A paragraph."])
    }

    @Test func aLinkIsNotALabel() {
        #expect(NotesMarkdown.parse("Https: no label").map(Self.show) == ["paragraph:Https: no label"])
        #expect(NotesMarkdown.parse("Todo: call Anna").map(Self.show) == ["paragraph:**Todo:** call Anna"])
    }
}

@Suite struct MarkdownDocTests {
    @Test(arguments: [
        "Hello there. How are you?",
        "We came #1 in the league, 5*3 = 15, and my_file_name stays.",
        "Shopping:\n- milk\n- eggs",
        "I *really* mean it.",
        "Two steps:\n1. **Install** it\n2. Run it",
        "## Getting started\n\n1. Install it\n- **Fast** and _simple_\n- [ ] Not done yet\n> A quote with `code`\n\n---\n\nDone ~~soon~~ now.",
        "Read [the guide](https://x.org/a?b=c \"Guide\") and look at ![the chart](img/c.png).",
    ])
    func readsTheSamePlainTextAsBefore(_ md: String) { #expect(MarkdownDoc.parse(md).plain == MarkdownText.toPlain(md)) }

    @Test func linesKnowWhatTheyAre() {
        let doc = MarkdownDoc.parse("# Title\nSome text.\n- one\n  - nested\n1. first\n> quoted\n```\nvar x = 1;\n```")
        let ns = doc.plain as NSString
        #expect(doc.lines.map { ns.substring(with: NSRange(location: $0.start, length: $0.length)) }
                == ["Title", "Some text.", "one", "nested", "1. first", "quoted", "var x = 1;"])
        #expect(doc.lines.map(\.kind) == [.heading, .paragraph, .bullet, .bullet, .numbered, .quote, .code])
        #expect(doc.lines[0].level == 1)
        #expect(doc.lines[2].level == 0)
        #expect(doc.lines[3].level == 1)
    }

    @Test func inlineStylesPointAtThePlainText() {
        let doc = MarkdownDoc.parse("Use **bold**, *italic*, `code` and [a link](https://x.org).")
        #expect(doc.plain == "Use bold, italic, code and a link.")
        func at(_ word: String) -> MarkdownDoc.Style { doc.styleAt((doc.plain as NSString).range(of: word).location) }
        #expect(at("bold") == .bold)
        #expect(at("italic") == .italic)
        #expect(at("code") == .code)
        #expect(at("a link") == .link)
        #expect(at("Use") == [])
    }

    @Test func nestedEmphasisAndSetextHeadings() {
        let doc = MarkdownDoc.parse("Title\n=====\n**very *important* note**")
        #expect(doc.plain == "Title\nvery important note")
        #expect(doc.lines[0].kind == .heading)
        let ns = doc.plain as NSString
        #expect(doc.styleAt(ns.range(of: "important").location) == [.bold, .italic])
        #expect(doc.styleAt(ns.range(of: "very").location) == .bold)
    }

    @Test func everySentenceFallsInsideOneLine() {
        let doc = MarkdownDoc.parse("# Notes\nFirst point. Second point.\n- item one\n- item two\n\nEnd.")
        for s in ReadAloudText.split(doc.plain) {
            let line = doc.lineAt(s.location)
            #expect(line != nil)
            if let line { #expect(s.location + s.length <= line.start + line.length) }
        }
    }
}

@Suite struct NotesModelsBestPickTests {
    let gb: Int64 = 1_073_741_824

    @Test func aMixtureOfExpertsRunsFromMemory() {
        let moe = LocalModel(name: "qwen3:30b-a3b", billions: 30.5, bytes: 18 * gb, family: "qwen3moe")
        let dense = LocalModel(name: "qwen3:14b", billions: 14.8, bytes: 9 * gb, family: "qwen3")
        #expect(moe.activeBillions == 3)
        #expect(moe.runsFromMemory(gpuBytes: 12 * gb, ramBytes: 32 * gb))
        #expect(!moe.runsFromMemory(gpuBytes: 12 * gb, ramBytes: 16 * gb)) // no room left for the rest
        #expect(NotesModels.pickBest([dense, moe], gpuBytes: 12 * gb, ramBytes: 32 * gb)?.name == "qwen3:30b-a3b")
        #expect(NotesModels.pickBest([dense, moe], gpuBytes: 12 * gb, ramBytes: 16 * gb)?.name == "qwen3:14b")
    }

    @Test func withoutAGpuOnlySmallModelsFit() {
        let small = LocalModel(name: "llama3.2:3b", billions: 3.2, bytes: 2 * gb, family: "llama")
        let big = LocalModel(name: "qwen3:14b", billions: 14.8, bytes: 9 * gb, family: "qwen3")
        #expect(NotesModels.pickBest([small, big], gpuBytes: nil)?.name == "llama3.2:3b")
    }

    @Test func ollamaCloudModelsAreNeverBest() {
        let cloud = LocalModel(name: "qwen3-coder:480b-cloud", billions: 480, bytes: 400, family: "qwen3")
        let cloud2 = LocalModel(name: "deepseek-v3.1:671b-cloud:latest", billions: 671, bytes: 400, family: "deepseek2")
        let local = LocalModel(name: "llama3.2:3b", billions: 3.2, bytes: 2 * gb, family: "llama")
        #expect(NotesModels.pickBest([cloud, cloud2, local], gpuBytes: 12 * gb)?.name == "llama3.2:3b")
        #expect(NotesModels.pickBest([cloud, cloud2], gpuBytes: 12 * gb) == nil)
    }
}
