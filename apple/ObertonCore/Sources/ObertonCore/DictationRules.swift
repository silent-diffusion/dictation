import Foundation

/// Windows' `LastActivity` (DictationController): stamped when a dictation starts and when it ends (inserted, copied,
/// discarded, cancelled, failed), not as it moves between its own busy states. The model unloading timer and the
/// dashboard's "Unload in mm:ss" count from it.
public enum DictationActivity {
    /// Whether a change from `wasBusy` to `isBusy` stamps the time.
    public static func stamps(wasBusy: Bool, isBusy: Bool) -> Bool { wasBusy != isBusy }
}

/// The overlay's level meter as OverlayWindow.SetLevel draws it: 22 columns of √level, oldest first. Every level the
/// microphone reports becomes one column, none is dropped and none is made up: with no levels coming the meter holds
/// still. (The Mac's microphone hands over its levels a few at a time; the overlay draws them one per 50 ms tick, all
/// of them, so a burst doesn't jump.)
public struct LevelColumns: Equatable, Sendable {
    public static let count = 22
    public private(set) var columns = [Double](repeating: 0, count: LevelColumns.count)
    /// Levels heard, not drawn yet.
    public private(set) var queue: [Double] = []

    public init() {}

    /// A level from the microphone (0…1, Windows' scale).
    public mutating func hear(_ level: Float) {
        queue.append(Double(min(max(level, 0), 1)).squareRoot()) // perceptual: quiet speech still moves the dots
    }

    /// One tick of the overlay's 50 ms clock: the next level heard becomes a column, two if more than a few are
    /// waiting (so the meter never falls behind the voice); nothing waiting, nothing moves. Returns whether it moved.
    @discardableResult
    public mutating func tick() -> Bool {
        guard !queue.isEmpty else { return false }
        let n = queue.count > 4 ? 2 : 1
        for _ in 0..<n {
            columns.removeFirst()
            columns.append(queue.removeFirst())
        }
        return true
    }
}

/// DictationController.Stitch: the transcript with the seams between live pieces fixed. The recognizer's final text
/// is the pieces handed out while speaking plus the speech after the last one (the tail); when it is (the words match,
/// runs of dots aside), the pieces are stitched as they were, their own dots left alone. Otherwise (live mode failed
/// and the whole recording was decoded at once) there are no seams and the final text is only tidied.
public enum LiveStitch {
    /// `raw`: the final text with runs of dots collapsed (`OutputSanitizer.collapseDots`).
    public static func stitch(raw: String, pieces: [String], tail: String) -> String {
        if pieces.isEmpty { return FragmentStitcher.join([raw]) }
        let all = pieces + [tail]
        func words(_ s: String) -> [Substring] { s.split(whereSeparator: \.isWhitespace) }
        let same = words(OutputSanitizer.collapseDots(all.joined(separator: " "))) == words(raw)
        return FragmentStitcher.join(same ? all : [raw])
    }
}
