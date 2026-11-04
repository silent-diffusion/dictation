import Foundation
import Testing
@testable import ObertonCore

/// settings.json as Windows' JsonStore and SettingsService read and write it (SHELL-147/151, SHELL-N002/N004,
/// SHELL-149, PROF-087, SYS-018/019).
@Suite(.serialized) struct SettingsStoreTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "oberton-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func commentsAndTrailingCommasAreRead() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "settings.json")
        try Data(#"""
            {
              // hand-edited
              "insertion": "typing",
              "hotkey": "F9",
            }
            """#.utf8).write(to: url)
        let s = try #require(JSONFile<AppSettings>(url: url).load())
        #expect(s.insertion == .typing)
        #expect(s.hotkey == "F9")
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("bad").path))
    }

    @Test func aMissingCloudKeyKeepsTheOthers() throws {
        let data = Data(#"{"cloud": {"keepOffline": false, "openAIModel": "gpt-5"}}"#.utf8)
        let s = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(s.cloud.keepOffline == false)
        #expect(s.cloud.openAIModel == "gpt-5")
        #expect(s.cloud.openAIBaseURL == "https://api.openai.com/v1")
    }

    @Test func overridesIgnoreCase() throws {
        let data = Data(#"{"appOverrides": {"com.apple.TextEdit": "Typing", "com.apple.Notes": "CLIPBOARD", "x": "nope"}}"#.utf8)
        let s = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(s.appOverrides.count == 2)
        #expect(s.insertionOverride(for: "com.apple.TextEdit") == .typing)
        #expect(s.insertionOverride(for: "com.apple.textedit") == .typing)
        #expect(s.insertionOverride(for: "COM.APPLE.NOTES") == .clipboard)
        #expect(s.insertionOverride(for: "com.apple.Safari") == nil)
    }

    @Test func anUnchangedFileIsNotWrittenAgain() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = JSONFile<AppSettings>(url: dir.appending(path: "settings.json"))
        var s = AppSettings()
        file.save(s)
        let old = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.url.path)
        file.save(s)
        let same = try FileManager.default.attributesOfItem(atPath: file.url.path)[.modificationDate] as? Date
        #expect(same == old)
        s.hotkey = "F9"
        file.save(s)
        let changed = try FileManager.default.attributesOfItem(atPath: file.url.path)[.modificationDate] as? Date
        #expect(changed != old)
        #expect(file.load()?.hotkey == "F9")
    }

    @Test func aFailedSaveIsLogged() throws {
        var logged: [String] = []
        CoreLog.sink = { level, message in logged.append(level + " " + message) }
        defer { CoreLog.sink = nil }
        // A folder can't be written over with a file.
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocked = dir.appending(path: "settings.json")
        try FileManager.default.createDirectory(at: blocked.appending(path: "inside"), withIntermediateDirectories: true)
        JSONFile<AppSettings>(url: blocked).save(AppSettings())
        #expect(logged.contains { $0.hasPrefix("ERROR Saving settings failed: ") })
        let usage = dir.appending(path: "usage.json")
        try FileManager.default.createDirectory(at: usage.appending(path: "inside"), withIntermediateDirectories: true)
        JSONFile<[String]>(url: usage).save(["a"])
        #expect(logged.contains { $0.hasPrefix("WARN Saving usage counts failed: ") })
    }

    @Test func aNonLocalEndpointIsLoggedAndReset() {
        var logged: [String] = []
        CoreLog.sink = { level, message in logged.append(level + " " + message) }
        defer { CoreLog.sink = nil }
        var s = AppSettings()
        s.ollamaEndpoint = "http://example.com:11434"
        let reset = s.enforceLocalEndpoint()
        #expect(reset)
        #expect(s.ollamaEndpoint == AppSettings().ollamaEndpoint)
        #expect(logged == ["WARN LLM endpoint 'http://example.com:11434' is not local; resetting to default."])
    }
}
