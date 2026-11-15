import CoreText
import Foundation
import Testing
@testable import ObertonCore

/// The overlay pill never cuts a profile or model name of normal length (the user's no-clip request).
struct PillRowFitTests {
    /// A name's width in the chip: 11 pt monospaced (Cascadia Mono and SF Mono are both 0.6 em a character).
    private func chipText(_ name: String) -> CGFloat {
        let font = CTFontCreateUIFontForLanguage(.userFixedPitch, 11, nil)!
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: [.init(kCTFontAttributeName as String): font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// ● 0:07 [meter] 録音 [name] ✕ CANCEL: indicator 28, clock, decor word 31 (drops out), chip (text, 11 + 11 inside, 8 after,
    /// ends in "…" last), CANCEL 92 (✕ alone: 36).
    private func recordingRow(_ name: String) -> (columns: [PillRowFit.Column], chip: CGFloat) {
        let chip = min(chipText(name), PillRowFit.chipCap) + 30
        return ([PillRowFit.Column(width: 28), PillRowFit.Column(width: 31), PillRowFit.Column(width: 31, shrink: 1),
                 PillRowFit.Column(width: chip, shrink: 2), PillRowFit.Column(width: 92, shrink: 1, least: 36)], chip)
    }

    private let names = ["Light Cleanup", "Formal email to the leadership", "Übersetzung ins Deutsche, förmlich",
                         "Weekly status update for the whole team"]

    @Test func normalNamesFitTheChipCap() {
        for name in names { #expect(chipText(name) <= PillRowFit.chipCap, "\(name)") }
        let huge = "Formal email to the leadership team, with British spelling and no contractions"
        #expect(chipText(huge) > PillRowFit.chipCap) // only a truly huge name ends in "…"
    }

    @Test func macPillWidensSoTheWholeNameShows() {
        let limit: CGFloat = 1512 - 48 - 28 // a 14" MacBook's screen less the margins and the card's edge
        for name in names {
            let (cols, chip) = recordingRow(name)
            let width = PillRowFit.width(cols, star: 64 + 24, proposed: 440, limit: limit)
            let (widths, star) = PillRowFit.widths(cols, in: width)
            #expect(widths[3] == chip, "\(name) is cut")
            #expect(widths[4] == 92 && widths[2] == 31, "\(name): CANCEL or the decor dropped on a Mac")
            #expect(star >= 64 + 24 - 1, "\(name): the meter has no room")
        }
        // A short name keeps Windows' 440.
        let (cols, _) = recordingRow("Light Cleanup")
        #expect(PillRowFit.width(cols, star: 64 + 24, proposed: 440, limit: limit) == 440)
    }

    @Test func iPhoneDropsWordsBeforeCuttingTheName() {
        let limit: CGFloat = (390 - 24) / 0.92 - 28
        let (cols, chip) = recordingRow("Formal email to the leadership")
        let width = PillRowFit.width(cols, star: 64 + 24, proposed: 440, limit: limit)
        #expect(abs(width - limit) < 0.01)
        let (widths, _) = PillRowFit.widths(cols, in: width)
        #expect(widths[3] == chip) // the 30-character name stays whole
        #expect(widths[4] == 36) // CANCEL became ✕, which was enough: the decor word stays
        #expect(widths[2] == 31)
    }

    @Test func tooNarrowShrinksTheWidestNameDownToForty() {
        let cols = [PillRowFit.Column(width: 28), PillRowFit.Column(width: 300, shrink: 2), PillRowFit.Column(width: 100, shrink: 2)]
        let (widths, star) = PillRowFit.widths(cols, in: 200)
        #expect(widths == [28, 72, 100])
        #expect(star == 0)
        let (tight, _) = PillRowFit.widths(cols, in: 50)
        #expect(tight == [28, 40, 40])
    }
}
