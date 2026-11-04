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

    /// ThreeZeroTests: offline by default, the configured OpenAI model in the catalog, every catalog id a cloud one.
    @Test func cloudDefaultsAndCatalog() {
        #expect(CloudSettings().keepOffline)
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
}
