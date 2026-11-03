import Foundation

/// How a finished session's recording is cut to be transcribed again (NotesRedo.cs).
public enum NotesRedo {
    /// About how long each part sent to the speech engine is: like the pieces of a live session.
    public static let partSeconds = 15.0

    /// The recording cut into parts of about `target` seconds, each cut in the pause nearest to that point (so no word
    /// is split), or at the point itself when there is no pause near it.
    public static func planParts(seconds: Double, pauses: [AudioPause], target: Double = partSeconds) -> [(start: Double, end: Double)] {
        var parts: [(start: Double, end: Double)] = []
        var start = 0.0
        while seconds - start > target + 8 {
            let want = start + target
            let cut = pauses.map { ($0.start + $0.end) / 2 }
                .filter { $0 > want - 6 && $0 < want + 8 }
                .min { abs($0 - want) < abs($1 - want) } ?? want
            parts.append((start, cut))
            start = cut
        }
        if seconds - start > 0.3 { parts.append((start, seconds)) }
        return parts
    }
}
