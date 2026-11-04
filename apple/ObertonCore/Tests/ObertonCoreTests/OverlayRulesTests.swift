import Testing
@testable import ObertonCore

// Windows: App.PreviewOverlay and its callers (LayoutPage's grids, ReadAloudPage's grid and "Same place" switch;
// LayoutPage.SamePlace_Changed doesn't call it).
@Suite struct PositionPreviewTests {
    typealias P = PositionPreview.Positions

    @Test func readAloudPagesSamePlaceSwitchFlashesTheOverlay() {
        // Round 2 regression (LOOK-070): the Read aloud page's switch must flash and reset both drags.
        #expect(PositionPreview.samePlaceSwitchPreviews(on: .readAloud))
    }

    @Test func layoutPagesSamePlaceSwitchDoesNot() {
        #expect(!PositionPreview.samePlaceSwitchPreviews(on: .layout))
    }

    @Test func turningSamePlaceOnOrOffIsNotAGridPick() {
        let with = P(overlay: .bottomCenter, reader: .withOverlay), own = P(overlay: .bottomCenter, reader: .at(.bottomCenter))
        #expect(!PositionPreview.previews(from: with, to: own))
        #expect(!PositionPreview.previews(from: own, to: with))
    }

    @Test func gridPicksFlash() {
        #expect(PositionPreview.previews(from: P(overlay: .bottomCenter, reader: .withOverlay), to: P(overlay: .topLeft, reader: .withOverlay)))
        #expect(PositionPreview.previews(from: P(overlay: .bottomCenter, reader: .at(.topLeft)), to: P(overlay: .bottomCenter, reader: .at(.topRight))))
        #expect(!PositionPreview.previews(from: P(overlay: .bottomCenter, reader: .at(.topLeft)), to: P(overlay: .bottomCenter, reader: .at(.topLeft))))
    }
}
