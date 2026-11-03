import Foundation
import ObertonCore
import os

/// A small log: the system log (Console, subsystem "Oberton") and a file in the data folder's logs/, as Windows'
/// dictation.log, under the same name. Metadata only (timings, sizes, states, errors), never what was said. The file
/// rolls over at 2 MB, keeping one older copy (dictation.log.1).
enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Oberton", category: "app")
    private static let lock = NSLock()

    static var dir: URL {
        let dir = AppPaths.dataDir.appending(path: "logs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var file: URL { dir.appending(path: "dictation.log") }

    static func info(_ message: String) { write("INFO", message); logger.info("\(message, privacy: .public)") }
    static func warn(_ message: String) { write("WARN", message); logger.warning("\(message, privacy: .public)") }
    static func error(_ message: String) { write("ERROR", message); logger.error("\(message, privacy: .public)") }
    /// "message: the error", as Windows' Log.Error(m, e).
    static func error(_ message: String, _ error: Error) { self.error("\(message): \(error)") }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func write(_ level: String, _ message: String) {
        // Paths in messages would carry the account name.
        let home = NSHomeDirectory()
        var message = message
        if home.count > 3 {
            message = message.replacingOccurrences(of: home.hasSuffix("/") ? String(home.dropLast()) : home, with: "~", options: .caseInsensitive)
        }
        let line = "\(stamp.string(from: .now)) \(level.padding(toLength: 5, withPad: " ", startingAt: 0)) \(message)\n"
        lock.withLock {
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
