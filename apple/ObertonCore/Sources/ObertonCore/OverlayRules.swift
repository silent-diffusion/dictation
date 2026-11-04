import Foundation

/// Windows' App.PreviewOverlay, and where its pages call it: the overlay forgets where it was dragged and flashes
/// ● DICTATION APPEARS HERE at its position, and the Read aloud player forgets its own drag.
public enum PositionPreview {
    /// The page a "Same place as the dictation overlay" switch is on.
    public enum Page: Sendable { case readAloud, layout }

    /// ReadAloudPage.SamePlace_Changed calls PreviewOverlay; LayoutPage.SamePlace_Changed doesn't.
    public static func samePlaceSwitchPreviews(on page: Page) -> Bool { page == .readAloud }
}
