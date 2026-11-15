#if os(macOS)
import AppKit
import SwiftUI
import Testing

/// The SwiftUI rule behind round 2's overflow regressions (History's title R2 and app headers R3, Analytics' heads R5,
/// the dashboard's speech meter R1): a flexible frame with only `maxWidth` never gets narrower than a fixed-size child,
/// so the row grows past its space instead of cutting the text; `minWidth: 0` lets it take the space offered and the
/// `clipped()` cut the rest, as a WPF DockPanel / layout slot does. The app's views use the second form.
@MainActor @Suite struct CutToFitLayoutTests {
    private func width(_ view: some View, in offered: CGFloat) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: offered, height: 1000)).width
    }

    private let long = "Wednesday 30 September 2026, 10:15 AM, a title much wider than the column"

    @Test func aFrameWithOnlyMaxWidthPushesTheButtonsOut() {
        let row = HStack(spacing: 0) {
            Text(long).lineLimit(1).fixedSize().frame(maxWidth: .infinity, alignment: .leading).clipped()
            Text("DELETE").fixedSize()
        }
        #expect(width(row, in: 200) > 200)
    }

    @Test func minWidthZeroCutsTheTitleBesideTheButtons() {
        let row = HStack(spacing: 0) {
            Text(long).lineLimit(1).fixedSize().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
            Text("DELETE").fixedSize()
        }
        #expect(width(row, in: 200) == 200)
    }

    @Test func aTooWideFooterIsCutInsideItsCell() {
        // The speech meter: the cell stays its quarter; only UNLOAD EVERYTHING is cut.
        let cell = VStack(spacing: 0) {
            Color.clear.frame(height: 20)
            Text(long).lineLimit(1).fixedSize().frame(minWidth: 0, maxWidth: .infinity).clipped().contentShape(Rectangle())
        }
        #expect(width(cell, in: 110) == 110)
    }
}
#endif
