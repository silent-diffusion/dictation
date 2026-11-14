import Foundation

/// Recordings Oberton leaves in the temporary folder for a moment: the evened-out copy a History re-run reads
/// (oberton-rerun-<id>.wav, removed when the re-run ends) and, on the Mac, the copy of a note's recording put on the
/// clipboard as a file (oberton-copied/, replaced by the next copy). A crash or a quit leaves them behind, so they are
/// swept at launch: re-run copies always (no re-run is in flight then), the clipboard copy once it is a day old (a
/// newer one may still be on the clipboard, waiting to be pasted).
public enum TempFiles {
    public static func sweep(in dir: URL = FileManager.default.temporaryDirectory, now: Date = Date()) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix("oberton-rerun-"), name.hasSuffix(".wav") {
                try? fm.removeItem(at: item)
            } else if name == "oberton-copied" {
                let changed = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let changed, now.timeIntervalSince(changed) > 86400 { try? fm.removeItem(at: item) }
            }
        }
    }
}
