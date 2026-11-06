import Testing
@testable import ObertonCore

// Windows: DictationController's LastActivity stamps (StartAsync, InsertPendingAsync's finally, Fail, Cancel, the
// discard, CopyPlacingToClipboard), OverlayWindow.SetLevel, DictationController.Stitch.
@Suite struct DictationRulesTests {
    @Test func activityIsStampedAtTheStartAndTheEndOnly() {
        #expect(DictationActivity.stamps(wasBusy: false, isBusy: true)) // idle → recording
        #expect(DictationActivity.stamps(wasBusy: true, isBusy: false)) // inserting → done, anything → idle
        #expect(!DictationActivity.stamps(wasBusy: true, isBusy: true)) // recording → transcribing → processing → preview…
        #expect(!DictationActivity.stamps(wasBusy: false, isBusy: false)) // done → idle: the receipt clearing
    }

    @Test func everyLevelIsOneColumnAndNothingMovesWithoutLevels() {
        var meter = LevelColumns()
        for _ in 0..<6 { meter.hear(0.25) }
        var moved = 0
        for _ in 0..<30 where meter.tick() { moved += 1 }
        // Six levels: six columns of √0.25, none dropped and no decay afterwards (Windows holds the meter still).
        #expect(Array(meter.columns.suffix(6)) == [Double](repeating: 0.5, count: 6))
        #expect(Array(meter.columns.prefix(16)) == [Double](repeating: 0, count: 16))
        #expect(moved <= 6)
        let held = meter.columns
        for _ in 0..<10 { meter.tick() }
        #expect(meter.columns == held)
    }

    @Test func aBurstOfLevelsIsDrawnWhole() {
        var meter = LevelColumns()
        for i in 0..<12 { meter.hear(Float(i) / 100) }
        while meter.tick() {}
        #expect(Array(meter.columns.suffix(12)) == (0..<12).map { (Double(Float($0) / 100)).squareRoot() })
    }

    @Test func livePiecesAreStitchedWithTheirOwnDots() {
        // The final text is the pieces and the tail (dots collapsed for the comparison only): the pieces are kept as
        // they came, a "… … …" run inside a piece included.
        let pieces = ["So the plan is … … … fine.", "We ship on Friday."], tail = "Then feedback"
        let raw = OutputSanitizer.collapseDots((pieces + [tail]).joined(separator: " "))
        #expect(LiveStitch.stitch(raw: raw, pieces: pieces, tail: tail) == FragmentStitcher.join(pieces + [tail]))
        #expect(LiveStitch.stitch(raw: raw, pieces: pieces, tail: tail).contains("… … …"))
    }

    @Test func aWholeDecodeHasNoSeams() {
        // Live mode fell back to decoding the whole recording: the words differ, so only the final text is tidied.
        let raw = "so the plan is fine we ship on friday then feedback"
        #expect(LiveStitch.stitch(raw: raw, pieces: ["So the plan is fine."], tail: "x") == FragmentStitcher.join([raw]))
        #expect(LiveStitch.stitch(raw: raw, pieces: [], tail: "") == FragmentStitcher.join([raw]))
    }
}
