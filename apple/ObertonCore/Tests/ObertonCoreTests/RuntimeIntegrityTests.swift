#if os(macOS)
import Foundation
import Security
import Testing
@testable import ObertonCore

/// The AI runtime's download is checked before it is unpacked or run (security audit 2026-11-07): the archive's
/// pinned SHA-256, then every program's Developer ID signature from Ollama's team.
@Suite struct RuntimeIntegrityTests {
    private func scratch() throws -> URL {
        // TMPDIR when it is set (keeps scratch off the small internal disk), else the system's.
        let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let dir = base.appending(path: "oberton-integrity-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func theReleaseIsPinned() {
        #expect(OllamaRuntime.sha256[OllamaRuntime.version] == "3137dbf28948ee844e0fb3e584d9b5de6879d73d9f0cb7eff3ad64930601d307")
        #expect(OllamaRuntime.teamID == "3MU9H2V9Y9")
    }

    @Test func aFileWithThePinnedHashPasses() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "a.tgz")
        try Data("abc".utf8).write(to: file)
        // SHA-256("abc"), FIPS 180-2's test vector.
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(try RuntimeIntegrity.sha256(of: file) == abc)
        try RuntimeIntegrity.checkSHA256(of: file, expected: abc.uppercased())
    }

    @Test func aFileWithAnotherHashIsRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "a.tgz")
        try Data("abd".utf8).write(to: file)
        #expect(throws: RuntimeIntegrity.Problem.self) {
            try RuntimeIntegrity.checkSHA256(of: file, expected: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        }
        // A version with no pinned hash is never installed.
        #expect(throws: RuntimeIntegrity.Problem.noPinnedHash) { try RuntimeIntegrity.checkSHA256(of: file, expected: nil) }
    }

    @Test func aProgramSignedBySomeoneElseIsRefused() throws {
        // Apple's own /usr/bin/true: validly signed, but not by Ollama's team.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: dir.appending(path: "ollama"))
        #expect(RuntimeIntegrity.checkSignature(of: dir.appending(path: "ollama"), team: OllamaRuntime.teamID) == errSecCSReqFailed)
        #expect(throws: RuntimeIntegrity.Problem.self) { try RuntimeIntegrity.checkSignatures(in: dir, team: OllamaRuntime.teamID) }
    }

    @Test func aProgramChangedAfterSigningIsRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        var bytes = try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
        // Flip a byte well inside the code (past the headers), so a code page no longer matches its signed hash.
        let at = bytes.count / 3
        bytes[at] ^= 0xFF
        let file = dir.appending(path: "ollama")
        try bytes.write(to: file)
        let status = RuntimeIntegrity.checkSignature(of: file, team: OllamaRuntime.teamID)
        #expect(status != errSecSuccess)
        #expect(throws: RuntimeIntegrity.Problem.self) { try RuntimeIntegrity.checkSignatures(in: dir, team: OllamaRuntime.teamID) }
    }

    @Test func anUnsignedProgramIsRefusedAndOtherFilesAreSkipped() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Licence texts and other non-code files are not checked.
        try Data("MIT".utf8).write(to: dir.appending(path: "LICENSE"))
        try RuntimeIntegrity.checkSignatures(in: dir, team: OllamaRuntime.teamID)
        // A Mach-O header with no signature at all.
        var macho = Data([0xCF, 0xFA, 0xED, 0xFE])
        macho.append(Data(count: 64))
        try macho.write(to: dir.appending(path: "libggml-x.so"))
        #expect(RuntimeIntegrity.isMachO(dir.appending(path: "libggml-x.so")))
        #expect(throws: RuntimeIntegrity.Problem.self) { try RuntimeIntegrity.checkSignatures(in: dir, team: OllamaRuntime.teamID) }
    }

    @Test func aLinkOutOfTheFolderIsRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "libggml.dylib"), withDestinationURL: URL(fileURLWithPath: "/usr/lib/libz.dylib"))
        #expect(throws: RuntimeIntegrity.Problem.linkOutside(file: "libggml.dylib")) {
            try RuntimeIntegrity.checkSignatures(in: dir, team: OllamaRuntime.teamID)
        }
        // A relative link climbing out is refused too; one between files inside is fine.
        try FileManager.default.removeItem(at: dir.appending(path: "libggml.dylib"))
        try FileManager.default.createSymbolicLink(atPath: dir.appending(path: "libggml.dylib").path, withDestinationPath: "../../etc/hosts")
        #expect(throws: RuntimeIntegrity.Problem.linkOutside(file: "libggml.dylib")) {
            try RuntimeIntegrity.checkSignatures(in: dir, team: OllamaRuntime.teamID)
        }
        try FileManager.default.removeItem(at: dir.appending(path: "libggml.dylib"))
        try FileManager.default.createSymbolicLink(atPath: dir.appending(path: "libggml.dylib").path, withDestinationPath: "LICENSE")
        try Data("MIT".utf8).write(to: dir.appending(path: "LICENSE"))
        try RuntimeIntegrity.checkSignatures(in: dir, team: OllamaRuntime.teamID)
    }

    /// The real release passes: `OBERTON_OLLAMA_TEST_DIR=<the unpacked ollama-darwin.tgz> swift test --filter RuntimeIntegrityTests`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OBERTON_OLLAMA_TEST_DIR"] != nil))
    func theRealReleasePasses() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OBERTON_OLLAMA_TEST_DIR"]!, isDirectory: true)
        let start = Date()
        #expect(RuntimeIntegrity.checkSignature(of: dir.appending(path: "ollama"), team: OllamaRuntime.teamID) == errSecSuccess)
        let one = Date().timeIntervalSince(start)
        try RuntimeIntegrity.checkSignatures(in: dir, team: OllamaRuntime.teamID)
        print("RuntimeIntegrity timing: ollama alone \(Int(one * 1000)) ms, the whole folder \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        if let tgz = ProcessInfo.processInfo.environment["OBERTON_OLLAMA_TEST_TGZ"] {
            try RuntimeIntegrity.checkSHA256(of: URL(fileURLWithPath: tgz), expected: OllamaRuntime.sha256[OllamaRuntime.version])
        }
    }
}
#endif
