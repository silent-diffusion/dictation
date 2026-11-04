import Foundation

/// Windows' App.PreviewOverlay, and where its pages call it: the overlay forgets where it was dragged and flashes
/// ● DICTATION APPEARS HERE at its position, and the Read aloud player forgets its own drag.
public enum PositionPreview {
    /// The overlay's and the player's position settings.
    public struct Positions: Equatable, Sendable {
        public var overlay: OverlayPosition
        public var reader: ReaderPosition
        public init(overlay: OverlayPosition, reader: ReaderPosition) { self.overlay = overlay; self.reader = reader }
    }

    /// A settings change from a position grid: the overlay moved (LayoutPage's overlay grid), or the player was given
    /// another spot of its own (either page's player grid). Turning "Same place as the dictation overlay" on or off is
    /// not a grid pick: the switch decides for itself (`samePlaceSwitchPreviews`).
    public static func previews(from old: Positions, to new: Positions) -> Bool {
        if old.overlay != new.overlay { return true }
        if case .at = old.reader, case .at = new.reader { return old.reader != new.reader }
        return false
    }

    /// The page a "Same place as the dictation overlay" switch is on.
    public enum Page: Sendable { case readAloud, layout }

    /// ReadAloudPage.SamePlace_Changed calls PreviewOverlay; LayoutPage.SamePlace_Changed doesn't.
    public static func samePlaceSwitchPreviews(on page: Page) -> Bool { page == .readAloud }
}
