import Testing
@testable import ObertonCore

/// SYS-016: the stitcher and the word diff use .NET's character rules, as Windows' FragmentStitcher and WordDiff do.
@Suite struct DotNetCharRulesTests {
    @Test func aSuperscriptOrFractionDoesNotLeaveASentenceOpen() {
        // char.IsLetterOrDigit: "²" and "½" are other numbers (No), not decimal digits, so the piece after them isn't
        // taken as the same sentence carrying on; a plain digit is.
        #expect(FragmentStitcher.join(["the area is 5 m²", "And it fits"]).contains("m² And"))
        #expect(FragmentStitcher.join(["add ½", "And stir"]).contains("½ And"))
        #expect(FragmentStitcher.join(["the area is 5 m2", "And it fits"]).contains("m2 and"))
    }

    @Test func diffWordsAreComparedWithToLowerInvariant() {
        // İ stays İ (ToLowerInvariant), where Swift's lowercased() makes it "i̇".
        #expect(WordDiff.normalize("İstanbul,") == "İstanbul")
        #expect(WordDiff.normalize("\"So,\"") == "so")
        #expect(WordDiff.normalize("...") == "...")
    }
}
