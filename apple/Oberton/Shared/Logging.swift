import Foundation
import ObertonCore
import os

/// The app's log: the system log (Console, subsystem "Oberton", category "app") and the same file ObertonCore writes,
/// the data folder's logs/dictation.log, as Windows' (`CoreLog`: the format, the 2 MB roll-over, "~" for the home
/// folder). Metadata only (timings, sizes, states, errors), never what was said.
enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Oberton", category: "app")

    static var dir: URL { CoreLog.dir }
    static var file: URL { CoreLog.file }

    static func info(_ message: String) { CoreLog.append("INFO", message); logger.info("\(message, privacy: .public)") }
    static func warn(_ message: String) { CoreLog.append("WARN", message); logger.warning("\(message, privacy: .public)") }
    static func error(_ message: String) { CoreLog.append("ERROR", message); logger.error("\(message, privacy: .public)") }
    /// "message: the error", as Windows' Log.Error(m, e).
    static func error(_ message: String, _ error: Error) { self.error("\(message): \(error)") }
}
