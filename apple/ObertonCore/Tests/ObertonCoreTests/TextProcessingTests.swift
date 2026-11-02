import Testing
@testable import ObertonCore

// Ported from tests/Dictation.Tests/TextProcessingTests.cs so both apps hold their text to the same rules.

@Suite struct SanitizerTests {
    @Test func stripsTranscriptTags() { #expect(OutputSanitizer.clean("<transcript>\nHello there.\n</transcript>\n", input: "hello there") == "Hello there.") }
    @Test func stripsPreamble() { #expect(OutputSanitizer.clean("Here is the cleaned transcript:\n\nMeet at three.", input: "meet at three") == "Meet at three.") }
    @Test func keepsPreambleTheUserSaid() { #expect(OutputSanitizer.clean("Here is the plan: ship it.", input: "Here is the plan: ship it").hasPrefix("Here is")) }
    @Test func stripsWrappingQuotes() { #expect(OutputSanitizer.clean("\"Hello.\"", input: "hello") == "Hello.") }
    @Test func keepsQuotesThatBelong() { #expect(OutputSanitizer.clean("\"Hello,\" she said.", input: "\"hello\" she said") == "\"Hello,\" she said.") }
    @Test func stripsThinkAndFences() { #expect(OutputSanitizer.clean("<think>hmm</think>```text\nDone.\n```", input: "done") == "Done.") }

    static let input = "i went to the store yesterday and bought some apples and oranges for the party"
    @Test func plausibleEdit() { #expect(OutputSanitizer.implausibility(input: Self.input, output: "I went to the store yesterday and bought apples and oranges for the party.", maxChange: 0.4) == nil) }
    @Test func emptyIsRejected() { #expect(OutputSanitizer.implausibility(input: Self.input, output: "  ", maxChange: 0.4) != nil) }
    @Test func summaryIsRejected() { #expect(OutputSanitizer.implausibility(input: Self.input, output: "Bought fruit.", maxChange: 0.4) != nil) }
    @Test func ramblingIsRejected() {
        let ramble = Array(repeating: "Sure! I would be happy to help with that.", count: 6).joined(separator: " ")
        #expect(OutputSanitizer.implausibility(input: Self.input, output: ramble, maxChange: 0.4) != nil)
    }
    @Test func tinyInputs() {
        #expect(OutputSanitizer.implausibility(input: "um yes", output: "Yes.", maxChange: 0.4) == nil)
        #expect(OutputSanitizer.implausibility(input: "um yes", output: Array(repeating: "word", count: 40).joined(separator: " "), maxChange: 0.4) != nil)
    }
    @Test(arguments: ["... ... ... ... ...", "", " . . . "]) func dotsOnlyIsNotContent(_ s: String) {
        #expect(!OutputSanitizer.hasContent(OutputSanitizer.collapseDots(s)))
    }
    @Test func collapsesDotRuns() { #expect(OutputSanitizer.collapseDots("Hello there. ... ... ... And more") == "Hello there. And more") }
    @Test func keepsOneEllipsis() { #expect(OutputSanitizer.collapseDots("Well...") == "Well...") }
}

@Suite struct ChunkerTests {
    @Test func shortTextIsOneChunk() { #expect(TextChunker.split("Short text.").count == 1) }
    @Test func longTextSplitsAtSentences() {
        let text = Array(repeating: "This is a sentence that goes on for a while.", count: 120).joined(separator: " ")
        let chunks = TextChunker.split(text, maxChars: 1000)
        #expect(chunks.count > 5)
        #expect(chunks.allSatisfy { $0.count <= 1000 && $0.hasSuffix(".") })
        #expect(chunks.joined(separator: " ") == text)
    }
    @Test func hardCutsWithoutSpaces() { #expect(TextChunker.split(String(repeating: "a", count: 5000), maxChars: 2000).count >= 3) }
    @Test func neverCutsAWord() {
        let text = Array(repeating: "word", count: 300).joined(separator: " ")
        let pieces = TextChunker.split(text, maxChars: 200)
        #expect(pieces.allSatisfy { $0.count <= 200 && !($0 + " ").contains("wor ") })
        #expect(pieces.joined(separator: " ") == text)
    }
    @Test func segmentsKeepParagraphs() {
        let text = "First paragraph here.\n\nSecond one."
        let segments = TextChunker.segment(text)
        #expect(segments.count == 2)
        #expect(!segments[0].startsParagraph && segments[1].startsParagraph)
        #expect(TextChunker.join(segments, segments.map(\.text)) == text)
    }
}

@Suite struct PromptTests {
    @Test func systemPromptCarriesTheSwitches() {
        var p = Profile(prompt: "Be careful.")
        p.removeFillers = false
        p.preserveParagraphs = false
        let s = PromptBuilder.systemPrompt(for: p)
        #expect(s.contains("Be careful.") && s.contains("Do not remove filler words") && s.contains("single paragraph") && s.contains("only the processed text"))
    }
    @Test func builtInsMatchWindows() {
        #expect(BuiltInProfiles.create().map(\.name) == ["Light Cleanup", "Grammar & Clarity", "Natural Phrasing", "Custom", "Raw"])
        #expect(BuiltInProfiles.create()[0].prompt.contains("conservative dictation editor"))
    }
    @Test func modelIDsRoundTrip() {
        #expect(ModelID("ollama:qwen2.5:3b") == ModelID(provider: .ollama, name: "qwen2.5:3b"))
        #expect(ModelID.appleOnDevice.description == "apple:on-device")
        #expect(ModelID("nonsense") == nil)
    }
}

@Suite struct DiffTests {
    @Test func marksRemovedAndAdded() {
        let d = WordDiff.compute("um so we meet tuesday", "So we meet on Tuesday.")
        #expect(d.filter { $0.kind == .removed }.map(\.word) == ["um"])
        #expect(d.filter { $0.kind == .added }.map(\.word) == ["on"])
        #expect(d.filter { $0.kind != .removed }.map(\.word).joined(separator: " ") == "So we meet on Tuesday.")
    }
}

struct FakeBackend: LanguageModelBackend {
    var reply: @Sendable (String) throws -> String
    func complete(system: String, examples: [(input: String, output: String)], user: String, maxTokens: Int) async throws -> String { try reply(user) }
}

@Suite struct ProcessorTests {
    let processor = TextProcessor(settings: AppSettings())
    let profile = BuiltInProfiles.create()[0]

    @Test func usesTheEdit() async {
        let r = await processor.process("um so we meet on tuesday at noon ok", profile: profile,
                                        backend: FakeBackend { _ in "So we meet on Tuesday at noon, OK." })
        #expect(r.text == "So we meet on Tuesday at noon, OK." && r.modified && !r.safetyNet)
    }
    @Test func safetyNetKeepsRawWords() async {
        let raw = "i went to the store yesterday and bought some apples and oranges for the party"
        let r = await processor.process(raw, profile: profile, backend: FakeBackend { _ in "Bought fruit." })
        #expect(r.text == raw && r.safetyNet)
    }
    @Test func failureKeepsRawWords() async {
        let r = await processor.process("hello there everyone", profile: profile,
                                        backend: FakeBackend { _ in throw UserFacingError("Apple Intelligence declined to edit this text.") })
        #expect(r.text == "hello there everyone" && r.warning?.contains("declined") == true)
    }
}
