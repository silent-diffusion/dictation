import Foundation
import Testing
@testable import ObertonCore

/// Extended Notes' files: recordings stay out of backups, the notes text stays in, and the iOS protection class is the
/// one that lets a session record with the screen locked (NotesFiles).
@Suite struct NotesFilesTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "oberton-notes-files-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Read afresh (a URL keeps the values it read before).
    private func excluded(_ url: URL) -> Bool {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }

    @Test func theClassAllowsRecordingWhileLocked() {
        #expect(NotesFiles.protection == .completeUntilFirstUserAuthentication)
        #expect(NotesFiles.writeOptions.contains(.atomic))
        #if os(iOS)
        #expect(NotesFiles.writeOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
        #expect(NotesFiles.attributes?[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
        #endif
    }

    @Test func aRecordingIsKeptOutOfBackups() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "audio.wav")
        let writer = try WavWriter(url: url)
        writer.write([0, 0.5, -0.5])
        writer.close()
        #expect(excluded(url))
        #if os(iOS)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attrs[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
        #endif
    }

    @Test func theNotesTextStaysInBackups() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesStore(dir: dir)
        let s = try store.create(source: .mic)
        store.saveNow(s)
        let json = try #require(s.folder).appending(path: "session.json")
        #expect(FileManager.default.fileExists(atPath: json.path))
        #expect(!excluded(json))
        #expect(!excluded(try #require(s.folder)))
    }

    @Test func anOlderRecordingLeavesTheBackupsWhenTheStoreLoads() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = NotesStore(dir: dir)
        let s = try first.create(source: .mic)
        first.saveNow(s)
        // A recording written before NotesFiles: an ordinary file, in the backups.
        let audio = try #require(s.audioURL)
        try WavWriter.header(dataBytes: 0).write(to: audio)
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        var u = audio
        try u.setResourceValues(values)
        #expect(!excluded(audio))
        _ = NotesStore(dir: dir)
        #expect(excluded(audio))
    }
}
