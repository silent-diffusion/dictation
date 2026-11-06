import SwiftUI
import ObertonCore

/// What a text needs to light the word being said while its recording plays: the words heard with their times, and
/// the playback's moment (nil while it isn't playing).
struct PlaybackWords {
    var words: [SpokenWord]
    /// Matches in runs shorter than this don't count (the Summary: 3; see `WordTimes.align`).
    var minRun = 1
    var time: () -> Double?
}

/// Keeping the lit word in view, as the read-aloud panel does (ReaderFullText): a third of the way down, and only when
/// it nears an edge; never for 5 s after the user scrolls.
enum PlaybackFollow {
    static let pause: TimeInterval = 5
    /// How often the lit word is looked up while playing.
    static let tick: TimeInterval = 0.08

    /// The scroll offset that brings `rect` into view, or nil when it is well inside it already.
    static func offset(rect: CGRect, visible: CGRect, content: CGFloat) -> CGFloat? {
        let y = rect.minY - visible.minY
        if y >= 8, y + rect.height <= visible.height - 28 { return nil }
        return max(0, min(rect.minY - visible.height / 3, content - visible.height))
    }
}

/// Lines a text up with the words heard, again only when the text or the words changed (and at most once a second
/// while it keeps changing), and gives the span being said at a moment.
@MainActor
final class SpokenSpans {
    private var spans: [TimedSpan] = []
    private var alignedText = "", alignedCount = -1, alignedRun = 0
    private var alignedAt = Date.distantPast

    func current(text: String, playback: PlaybackWords, at seconds: Double) -> TimedSpan? {
        if text != alignedText || playback.words.count != alignedCount || playback.minRun != alignedRun,
           Date().timeIntervalSince(alignedAt) >= 1 || alignedCount < 0 {
            spans = WordTimes.align(text, playback.words, minRun: playback.minRun)
            alignedText = text; alignedCount = playback.words.count; alignedRun = playback.minRun
            alignedAt = Date()
        }
        return WordTimes.current(spans, at: seconds)
    }
}
