import Foundation
import Testing
@testable import ObertonCore

/// Lane P's Windows rules: model ids, profile start-up, the AI edit's examples and the cloud catalog.
@Suite struct LanePParityTests {
    /// Windows writes a local model as its bare Ollama tag; a blank one means the default (ModelFor).
    @Test func storedModelIDs() {
        #expect(ModelID(stored: "qwen2.5:3b") == ModelID(provider: .ollama, name: "qwen2.5:3b"))
        #expect(ModelID(stored: "ollama:qwen2.5:3b") == ModelID(provider: .ollama, name: "qwen2.5:3b"))
        #expect(ModelID(stored: "OpenAI:gpt-4.1-mini") == ModelID(provider: .openai, name: "gpt-4.1-mini"))
        for blank in [nil, "", "   ", "ollama:", "ollama:  "] { #expect(ModelID(stored: blank) == nil) }
        var s = AppSettings()
        s.defaultModel = ModelID(provider: .anthropic, name: "claude-haiku-4-5-20251001")
        let processor = TextProcessor(settings: s)
        #expect(processor.model(for: Profile(model: "ollama:  ")) == s.defaultModel)
        #expect(processor.model(for: Profile(model: "llama3.2:3b")) == ModelID(provider: .ollama, name: "llama3.2:3b"))
        #expect(s.defaultModel.windowsForm == "anthropic:claude-haiku-4-5-20251001")
        #expect(ModelID(provider: .ollama, name: "qwen2.5:3b").windowsForm == "qwen2.5:3b")
        // A Windows-style settings value decodes too.
        let decoded = try? JSONDecoder().decode(AppSettings.self, from: Data(#"{"defaultModel": "qwen2.5:7b"}"#.utf8))
        #expect(decoded?.defaultModel == ModelID(provider: .ollama, name: "qwen2.5:7b"))
    }

    /// Guid.NewGuid().ToString("N"): 32 lower-case hex digits.
    @Test func newProfileIDsLookLikeWindows() {
        let id = BuiltInProfiles.newProfile().id
        #expect(id.count == 32 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    /// App.VoiceFor: a blank voice means Read aloud's.
    @Test func blankVoiceFallsBack() {
        var p = Profile()
        p.voice = "  "
        #expect(p.readVoice(fallback: "af_heart") == "af_heart")
        p.voice = "piper:en_US-lessac-medium"
        #expect(p.readVoice(fallback: "af_heart") == "piper:en_US-lessac-medium")
    }

    /// ProfileService: a new install (no profiles) starts on Grammar & Clarity as default and active; otherwise the
    /// default (or, when missing, the first profile) becomes active.
    @Test func startUpFollowsProfileService() {
        var s = AppSettings()
        s.builtInProfilesAdded = [BuiltInProfiles.rawID]
        var fresh = BuiltInProfiles.create()
        #expect(BuiltInProfiles.start(&fresh, settings: &s, fresh: true))
        let gc = fresh.first { $0.name == BuiltInProfiles.defaultName }!.id
        #expect(s.defaultProfileID == gc && s.activeProfileID == gc)

        var existing = fresh
        s.defaultProfileID = "gone"
        s.activeProfileID = existing[3].id
        BuiltInProfiles.start(&existing, settings: &s, fresh: false)
        #expect(s.defaultProfileID == existing[0].id && s.activeProfileID == existing[0].id) // not the old active one

        var raw = BuiltInProfiles.create()
        BuiltInProfiles.start(&raw, settings: &s, fresh: true, freshPick: BuiltInProfiles.rawID)
        #expect(s.defaultProfileID == BuiltInProfiles.rawID && s.activeProfileID == BuiltInProfiles.rawID)
    }

    /// The conservative-edit examples remove fillers: they go along only when the profile removes them, for local and
    /// cloud models alike (Windows' useExamples = RemoveFillers).
    @Test func examplesOnlyWithRemoveFillers() async {
        final class Seen: @unchecked Sendable { var counts: [Int] = [] }
        struct Spy: LanguageModelBackend {
            let seen: Seen
            func complete(system: String, examples: [(input: String, output: String)], user: String, maxTokens: Int) async throws -> String {
                seen.counts.append(examples.count)
                return "Hello there everyone."
            }
        }
        let seen = Seen()
        let processor = TextProcessor(settings: AppSettings())
        var p = Profile(prompt: "Edit.")
        _ = await processor.process("hello there everyone", profile: p, backend: Spy(seen: seen), cloud: true)
        p.removeFillers = false
        _ = await processor.process("hello there everyone", profile: p, backend: Spy(seen: seen), cloud: true)
        _ = await processor.process("hello there everyone", profile: p, backend: Spy(seen: seen))
        #expect(seen.counts == [3, 0, 0])
    }

    /// Windows shows its own words only for a UserFacingException; anything else is "Something went wrong. See the log."
    @Test func unexpectedErrorsAreNamedGenerically() async {
        struct Broken: LanguageModelBackend {
            func complete(system: String, examples: [(input: String, output: String)], user: String, maxTokens: Int) async throws -> String {
                throw NSError(domain: "NSCocoaErrorDomain", code: 3840)
            }
        }
        struct Refused: LanguageModelBackend {
            func complete(system: String, examples: [(input: String, output: String)], user: String, maxTokens: Int) async throws -> String {
                throw UserFacingError("Couldn't reach the local AI runtime.")
            }
        }
        let processor = TextProcessor(settings: AppSettings())
        let a = await processor.process("hello there", profile: Profile(prompt: "x"), backend: Broken())
        #expect(a.error == TextProcessor.somethingWentWrong && a.text == "hello there")
        let b = await processor.process("hello there", profile: Profile(prompt: "x"), backend: Refused())
        #expect(b.error == "Couldn't reach the local AI runtime." && b.warning == "Couldn't reach the local AI runtime. Inserting your original words.")
    }

    /// ThreeZeroTests: offline by default, no keys set, the configured OpenAI model in the catalog, every catalog id a
    /// cloud one. The Mac keeps keys in the Keychain, never in the settings: a new CloudSettings holds no key at all.
    @Test func cloudDefaultsAndCatalog() throws {
        #expect(CloudSettings().keepOffline)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CloudSettings())) as? [String: Any]
        #expect(Set(json?.keys.map { $0 } ?? []) == ["keepOffline", "openAIBaseURL", "openAIModel"])
        var c = CloudSettings()
        c.openAIModel = "my-model"
        let catalog = CloudCatalog.models(c)
        #expect(catalog.contains { $0.id.description == "openai:my-model" })
        #expect(catalog.allSatisfy { $0.id.isCloud })
    }

    /// Windows' OrderBy: the culture's order, where ':' comes before '.' and case doesn't put capitals first.
    @Test func installedModelsInCultureOrder() {
        let sorted = OllamaBackend.sortedLikeWindows(["qwen3.8:27b-q4_K_M", "qwen3:30b-a3b-instruct-2507-q4_K_M", "Llama3.2:3b", "gemma3:4b"])
        #expect(sorted == ["gemma3:4b", "Llama3.2:3b", "qwen3:30b-a3b-instruct-2507-q4_K_M", "qwen3.8:27b-q4_K_M"])
    }

    /// A deadline over the whole request: work that runs past it is cut off as a timeout.
    @Test func deadlineCutsOffSlowWork() async {
        do {
            _ = try await Deadline.run(seconds: 0.05) { try await Task.sleep(for: .seconds(5)); return 1 }
            Issue.record("expected a timeout")
        } catch let e as URLError {
            #expect(e.code == .timedOut)
        } catch {
            Issue.record("unexpected \(error)")
        }
        let quick = try? await Deadline.run(seconds: 5) { 7 }
        #expect(quick == 7)
    }

    // MARK: Round 3

    /// Regression #8 (LOOK-034/045, PROF-017): Windows' RowItem keeps the selected row's bar ink while the list has the
    /// focus; only a focused row that isn't selected gets the accent.
    @Test func selectedRowKeepsItsInkBar() {
        #expect(RowMark.of(selected: true, focused: false) == .ink)
        #expect(RowMark.of(selected: true, focused: true) == .ink)
        #expect(RowMark.of(selected: false, focused: true) == .accent)
        #expect(RowMark.of(selected: false, focused: false) == .none)
    }

    /// Regression #16, PROF-104/118: one download at a time on Settings › Models, and every button stays usable.
    @Test func oneDownloadAtATimeWithButtonsUsable() {
        #expect(!ModelDownloads.mayStart(busy: true) && ModelDownloads.mayStart(busy: false))
        #expect(ModelDownloads.buttonEnabled(busy: true) && ModelDownloads.buttonEnabled(busy: false))
    }

    /// Regression #17 (PROF-N013), PROF-033: Try it's preview is the app's, so its choice still reaches the run that
    /// asked after the page has gone; a new Try it ends the one before as discarded.
    @MainActor @Test func trialChoiceReachesTheRunThatAsked() async {
        let slot = ChoiceSlot<String, String>()
        var shown: [String?] = []
        let first = Task { await slot.ask("A") { shown.append($0) } }
        while !slot.isWaiting { await Task.yield() }
        #expect(slot.current == "A")
        // Profile B opens: nothing touches the slot. The choice made in the preview goes back to A's run.
        slot.end("A's edit")
        #expect(await first.value == "A's edit")
        let second = Task { await slot.ask("B") { shown.append($0) } }
        while !slot.isWaiting { await Task.yield() }
        let third = Task { await slot.ask("C") { shown.append($0) } }
        #expect(await second.value == nil) // replaced: discarded
        while slot.current != "C" { await Task.yield() }
        slot.end(nil)
        #expect(await third.value == nil)
        #expect(shown == ["A", nil, "B", nil, "C", nil])
    }

    /// PROF-073, PROF-074, SHELL-150: the direct download (a build with a runtime of its own) starts on Windows'
    /// qwen2.5:3b at Windows' private port; the App Store build on Apple Intelligence and Ollama's own port.
    @Test func defaultModelAndEndpointPerBuild() {
        let s = AppSettings()
        if AppSettings.ownsRuntime {
            #expect(s.defaultModel == ModelID(provider: .ollama, name: "qwen2.5:3b") && s.ollamaEndpoint == "http://127.0.0.1:11435")
        } else {
            #expect(s.defaultModel == .appleOnDevice && s.ollamaEndpoint == "http://127.0.0.1:11434")
        }
        // A reset goes to the build's default.
        var bad = s
        bad.ollamaEndpoint = "http://10.0.0.5:11434"
        #expect(bad.enforceLocalEndpoint() && bad.ollamaEndpoint == s.ollamaEndpoint)
    }

    /// PROF-074: .NET's Uri reads short and numeric IPv4 forms ("127.1" is 127.0.0.1), and IsLoopback takes them.
    @Test func loopbackInEveryIPv4Form() {
        for ok in ["http://127.1:11435", "http://127.0.1", "http://2130706433:11434", "http://0x7f.0.0.1", "http://[0:0:0:0:0:0:0:1]:1"] {
            #expect(OllamaBackend.isLoopback(URL(string: ok)!), "\(ok)")
        }
        for bad in ["http://128.0.0.1", "http://1270.0.0.1", "http://127.0.0.1.example.com", "http://[::2]:1", "http://localhostx"] {
            #expect(!OllamaBackend.isLoopback(URL(string: bad)!), "\(bad)")
        }
    }

    /// PROF-126: Windows' language box takes a code ("en", "de"; default "en"); Apple Speech gets a full locale for it.
    @Test func languageCodeGivesASpeechLocale() {
        #expect(AppSettings().language == "en")
        let british = Locale(identifier: "en_GB")
        #expect(AppSettings.speechLocale(for: "en", current: british).identifier == "en-GB")
        #expect(AppSettings.speechLocale(for: "de", current: british).identifier == "de-DE")
        #expect(AppSettings.speechLocale(for: "pt-BR", current: british).identifier == "pt-BR")
        #expect(AppSettings.speechLocale(for: "", current: british) == british)
        #expect(WhisperModels.language(for: "de", model: "large-v3-turbo") == "de")
    }

    /// PROF-075: GIVE UP AFTER takes what an int binding takes: whole numbers in Int32's range.
    @Test func timeoutBoxTakesInt32Only() {
        #expect(AppSettings.wholeNumber(" 45 ") == 45 && AppSettings.wholeNumber("-3") == -3 && AppSettings.wholeNumber("0") == 0)
        #expect(AppSettings.wholeNumber("2147483647") == Int32.max)
        for bad in ["2147483648", "45.5", "abc", ""] { #expect(AppSettings.wholeNumber(bad) == nil, "\(bad)") }
    }

    /// PROF-084: a cloud service that never takes the connection is given up after Windows' TCP connect limit as
    /// "couldn't connect", not as a timeout; one that connected runs on to its deadline.
    @Test func neverConnectedIsCouldntReach() async {
        do {
            _ = try await Deadline.run(seconds: 5, connectWithin: 0.05, connected: { false }) { try await Task.sleep(for: .seconds(5)); return 1 }
            Issue.record("expected a connection failure")
        } catch let e as URLError {
            #expect(e.code == .cannotConnectToHost)
        } catch {
            Issue.record("unexpected \(error)")
        }
        let connected = try? await Deadline.run(seconds: 5, connectWithin: 0.05, connected: { true }) { try await Task.sleep(for: .seconds(0.2)); return 3 }
        #expect(connected == 3)
        #expect(ConnectWatch.windowsConnectLimit == 21)
    }

    /// PROF-069: the runtime's output goes into Oberton's log line by line ("ollama: …").
    @Test func runtimeOutputSplitsIntoLines() {
        let split = LineSplitter()
        var lines: [String] = []
        split.add(Data("time=1 level=INFO msg=\"Listening\"\r\npart".utf8)) { lines.append($0) }
        split.add(Data("ial line\nlast".utf8)) { lines.append($0) }
        split.flush { lines.append($0) }
        #expect(lines == ["time=1 level=INFO msg=\"Listening\"", "partial line", "last"])
    }

    /// PROF-069: the runtime goes when Oberton goes, also when it doesn't quit cleanly (Windows' job object): the
    /// watchdog shell stops `serve` once the parent's process is gone.
    @Test func runtimeStopsWithItsParent() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "oberton-watchdog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appending(path: "ollama")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["1"]
        try parent.run()
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", OllamaRuntime.Host.watchdog, "oberton-ollama", fake.path, String(parent.processIdentifier)]
        try shell.run()
        for _ in 0..<80 where shell.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!shell.isRunning)
        if shell.isRunning { shell.terminate() }
    }
}

extension BrokenFileTests {
    /// NOTES-N020, PROF-N022: a runtime that can't be listed is logged as Windows' ListModelsAsync logs it.
    @Test func aFailedListingIsLogged() async {
        var lines: [String] = []
        CoreLog.sink = { level, message in lines.append(level + " " + message) }
        defer { CoreLog.sink = nil }
        let nobody = URL(string: "http://127.0.0.1:9")!
        #expect(await OllamaBackend.installedModels(endpoint: nobody).isEmpty)
        #expect(lines.contains { $0.hasPrefix("WARN Listing models failed: ") })
    }
}
