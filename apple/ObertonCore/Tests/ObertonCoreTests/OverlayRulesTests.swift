import Testing
@testable import ObertonCore

// Windows: App.PreviewOverlay and its callers (LayoutPage's grids, ReadAloudPage's grid and "Same place" switch;
// LayoutPage.SamePlace_Changed doesn't call it).
@Suite struct PositionPreviewTests {
    @Test func readAloudPagesSamePlaceSwitchFlashesTheOverlay() {
        // Round 2 regression (LOOK-070): the Read aloud page's switch must flash and reset both drags.
        #expect(PositionPreview.samePlaceSwitchPreviews(on: .readAloud))
    }

    @Test func layoutPagesSamePlaceSwitchDoesNot() {
        #expect(!PositionPreview.samePlaceSwitchPreviews(on: .layout))
    }
}
