import Foundation
import Testing
@testable import ObertonCore

@Suite struct TempFilesTests {
    @Test func sweepsLeftoverRecordingsOnly() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "oberton-tempfiles-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let rerun = dir.appending(path: "oberton-rerun-ABC.wav")
        let other = dir.appending(path: "something-else.wav")
        let notes = dir.appending(path: "oberton-notes")
        let copied = dir.appending(path: "oberton-copied")
        try Data([1]).write(to: rerun)
        try Data([1]).write(to: other)
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)
        try fm.createDirectory(at: copied, withIntermediateDirectories: true)
        try Data([1]).write(to: copied.appending(path: "Lecture.wav"))

        // A fresh clipboard copy stays (it may still be pasted); the re-run copy goes.
        TempFiles.sweep(in: dir)
        #expect(!fm.fileExists(atPath: rerun.path))
        #expect(fm.fileExists(atPath: other.path))
        #expect(fm.fileExists(atPath: notes.path))
        #expect(fm.fileExists(atPath: copied.path))

        // A day later the clipboard copy goes too.
        TempFiles.sweep(in: dir, now: Date().addingTimeInterval(2 * 86400))
        #expect(!fm.fileExists(atPath: copied.path))
        #expect(fm.fileExists(atPath: other.path))
        #expect(fm.fileExists(atPath: notes.path))
    }
}
