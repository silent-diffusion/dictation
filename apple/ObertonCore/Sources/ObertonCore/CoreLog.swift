import Foundation
import os

/// Problems found inside ObertonCore, for the app's log: the system log (subsystem "Oberton", category "core") and the
/// data folder's logs/oberton.log, in the app's `Log` format. Metadata only, never what was said.
public enum CoreLog {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Oberton", category: "core")
    private static let lock = NSLock()
    /// Tests catch the lines here instead of writing them to the data folder.
    nonisolated(unsafe) static var sink: ((String, String) -> Void)?

    public static func warn(_ message: String) { write("WARN", message); logger.warning("\(message, privacy: .public)") }
    public static func error(_ message: String) { write("ERROR", message); logger.error("\(message, privacy: .public)") }

    private static func write(_ level: String, _ message: String) {
        if let sink { sink(level, message); return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let home = NSHomeDirectory()
        let message = home.count > 3 ? message.replacingOccurrences(of: home, with: "~") : message
        let line = "\(f.string(from: .now)) \(level.padding(toLength: 5, withPad: " ", startingAt: 0)) \(message)\n"
        let dir = AppPaths.dataDir.appending(path: "logs", directoryHint: .isDirectory)
        lock.withLock {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: "oberton.log")
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
