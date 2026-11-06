import Foundation

/// Windows' App.PreviewOverlay, and where its pages call it: the overlay forgets where it was dragged and flashes
/// ● DICTATION APPEARS HERE at its position, and the Read aloud player forgets its own drag.
public enum PositionPreview {
    /// The page a "Same place as the dictation overlay" switch is on.
    public enum Page: Sendable { case readAloud, layout }

    /// ReadAloudPage.SamePlace_Changed calls PreviewOverlay; LayoutPage.SamePlace_Changed doesn't.
    public static func samePlaceSwitchPreviews(on page: Page) -> Bool { page == .readAloud }
}

/// The words so far as the pill shows them while dictating (OverlayWindow.Tail): the newest `max` characters, starting
/// at a word when one starts within 40 characters, with "…" in front when cut. The pill holds three lines and keeps the
/// last ones in view, so the newest words always show, however long the dictation gets.
public enum LiveTail {
    public static let characters = 180

    public static func tail(_ text: String, _ max: Int = characters) -> String {
        guard text.count > max else { return text }
        let tail = text.suffix(max)
        if let sp = tail.firstIndex(of: " "), (1..<40).contains(tail.distance(from: tail.startIndex, to: sp)) {
            return "…" + tail[tail.index(after: sp)...]
        }
        return "…" + tail
    }
}
