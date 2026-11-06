import Foundation
import os

/// The log (Windows' Log): the system log (subsystem "Oberton", category "core") and the data folder's
/// logs/dictation.log, one file for ObertonCore and the app alike (the app's `Log` writes through `append`). Lines read
/// "yyyy-MM-dd HH:mm:ss.fff LEVEL message"; the file rolls over at 2 MB, keeping one older copy (dictation.log.1); the
/// home folder is written "~". Metadata only, never what was said.
public enum CoreLog {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Oberton", category: "core")
    private static let lock = NSLock()
    /// Tests catch the lines here instead of writing them to the data folder.
    nonisolated(unsafe) static var sink: ((String, String) -> Void)?

    public static func info(_ message: String) { append("INFO", message); logger.info("\(message, privacy: .public)") }
    public static func warn(_ message: String) { append("WARN", message); logger.warning("\(message, privacy: .public)") }
    public static func error(_ message: String) { append("ERROR", message); logger.error("\(message, privacy: .public)") }

    /// logs/ in the data folder.
    public static var dir: URL {
        let dir = AppPaths.dataDir.appending(path: "logs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var file: URL { dir.appending(path: "dictation.log") }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// One line in the file (the system log is the caller's).
    public static func append(_ level: String, _ message: String) {
        if let sink { sink(level, message); return }
        // Paths in messages would carry the account name.
        let home = NSHomeDirectory()
        var message = message
        if home.count > 3 {
            message = message.replacingOccurrences(of: home.hasSuffix("/") ? String(home.dropLast()) : home, with: "~", options: .caseInsensitive)
        }
        lock.withLock {
            let line = "\(stamp.string(from: .now)) \(level.padding(toLength: 5, withPad: " ", startingAt: 0)) \(message)\n"
            let url = file
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url) // logging must never stop the app
            }
        }
    }
}
