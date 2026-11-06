import Foundation

/// A dictation profile: the instructions the AI follows and the switches around it. The same fields and built-ins as
/// the Windows app's `Profile` (src/Dictation.Core/Settings/Models.cs), so the two stay recognisably one product.
public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: String = Profile.newID()
    public var name: String = "New Profile"
    public var description: String = ""
    public var prompt: String = ""
    /// The AI model, as a `ModelID` string ("apple:on-device", "ollama:qwen2.5:3b", "anthropic:…", "openai:…");
    /// nil = the default model in Settings.
    public var model: String?
    /// The speech recognition model for this profile: a Whisper model's id, `Profile.appleSpeech`, or nil for the one in
    /// Settings › Models. `AppSettings.dictating(with:)` resolves it.
    public var speechModel: String?
    /// Read aloud voice for this profile (a voice id, see `AppSettings.ttsVoice`); nil = Read aloud's own.
    public var voice: String?
    /// Off = Raw: the recognizer's words, no AI.
    public var autoProcess: Bool = true
    /// Raw only: words go into the app as they are heard. Off (the default): each new bit is pasted; on: typed key by
    /// key, which some apps garble.
    public var liveTyping: Bool = false
    public var showPreview: Bool = false
    public var preserveParagraphs: Bool = true
    public var removeFillers: Bool = true
    /// Give the AI the whole dictation in one piece so the instructions can reshape it (into an email, a list, …).
    /// Off: long dictation is edited a few sentences at a time, which keeps small models faithful.
    public var rewriteWhole: Bool = false
    /// Read the inserted text aloud once it is in place.
    public var readAloudAfterInsert: Bool = false
    /// Safety net: if the model's output differs in length from the input by more than this fraction, it is rejected
    /// and the raw transcript is used. 0.5 = ±50%.
    public var maxChangeRatio: Double = 0.5

    public init(id: String = Profile.newID(), name: String = "New Profile", description: String = "", prompt: String = "",
                model: String? = nil, autoProcess: Bool = true, showPreview: Bool = false, rewriteWhole: Bool = false,
                maxChangeRatio: Double = 0.5) {
        self.id = id
        self.name = name
        self.description = description
        self.prompt = prompt
        self.model = model
        self.autoProcess = autoProcess
        self.showPreview = showPreview
        self.rewriteWhole = rewriteWhole
        self.maxChangeRatio = maxChangeRatio
    }

    // Profiles saved by older versions are missing newer keys: decode what is there, default the rest.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func take<T: Decodable>(_ key: CodingKeys, _ into: inout T) { if let v = try? c.decode(T.self, forKey: key) { into = v } }
        take(.id, &id); take(.name, &name); take(.description, &description); take(.prompt, &prompt)
        take(.model, &model); take(.speechModel, &speechModel); take(.voice, &voice)
        take(.autoProcess, &autoProcess); take(.liveTyping, &liveTyping); take(.showPreview, &showPreview)
        take(.preserveParagraphs, &preserveParagraphs); take(.removeFillers, &removeFillers); take(.rewriteWhole, &rewriteWhole)
        take(.readAloudAfterInsert, &readAloudAfterInsert); take(.maxChangeRatio, &maxChangeRatio)
    }

    public var isRaw: Bool { !autoProcess }

    /// A new profile's id as Windows makes it (`Guid.NewGuid().ToString("N")`): 32 lower-case hex digits, no dashes.
    public static func newID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    /// The voice this profile reads with (Windows' `App.VoiceFor`): its own, or Read aloud's when it names none or a
    /// blank one.
    public func readVoice(fallback: String?) -> String? { Self.readVoice(voice, fallback: fallback) }

    public static func readVoice(_ voice: String?, fallback: String?) -> String? {
        guard let voice, !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return voice
    }

    /// `speechModel` for Apple's speech recognizer (in settings that is "", which here means "the one in Settings").
    public static let appleSpeech = "apple-speech"
}

public enum BuiltInProfiles {
    public static let rawID = "builtin-raw"
    /// Built-ins with a fixed id: one added in a later version shows up once for existing users too.
    public static let fixedIDs: Set<String> = [rawID]
    /// The profile a new install starts with (Windows 5.18).
    public static let defaultName = "Grammar & Clarity"

    public static let customPrompt =
        "You are a dictation editor. Clean up this speech transcript: remove filler words and false starts, " +
        "and fix punctuation and capitalization, while keeping the speaker's meaning and wording.\n" +
        "Do not summarize or add information.\nReturn only the processed text."

    /// Adds the fixed-id built-ins not offered before (`added` remembers which were), as Windows' ProfileService does at
    /// start: one the user deleted after it was offered stays deleted. True when anything changed.
    public static func addMissing(to profiles: inout [Profile], added: inout [String]) -> Bool {
        var changed = false
        for p in create() where fixedIDs.contains(p.id) && !added.contains(p.id) {
            if !profiles.contains(where: { $0.id == p.id }) { profiles.append(p) }
            added.append(p.id)
            changed = true
        }
        return changed
    }

    /// Windows' ProfileService at start. A new install (profiles.json missing, empty or unreadable: `fresh`) starts with
    /// Grammar & Clarity as the default and active profile (`freshPick` overrides that, e.g. Raw where no AI can run);
    /// built-ins added in later versions appear once; then the default is checked (missing: the first profile) and
    /// made active. True when the profiles or the settings changed in a way worth saving.
    @discardableResult
    public static func start(_ profiles: inout [Profile], settings: inout AppSettings, fresh: Bool, freshPick: String? = nil) -> Bool {
        if fresh {
            let pick = freshPick.flatMap { id in profiles.first { $0.id == id }?.id } ?? profiles.first { $0.name == defaultName }?.id
            settings.defaultProfileID = pick
            settings.activeProfileID = pick
        }
        let added = addMissing(to: &profiles, added: &settings.builtInProfilesAdded)
        settings.defaultProfileID = profiles.first { $0.id == settings.defaultProfileID }?.id ?? profiles.first?.id
        settings.activeProfileID = settings.defaultProfileID
        return fresh || added
    }

    /// A new profile, as Windows' ProfileService.Create makes it.
    public static func newProfile(name: String = "New Profile") -> Profile {
        Profile(name: name, description: "Custom editing profile.", prompt: customPrompt, maxChangeRatio: 0.5)
    }

    /// Word for word the Windows built-ins (5.18). None picks a model, so each uses the install's own default.
    public static func create() -> [Profile] {
        [
            Profile(
                name: "Light Cleanup",
                description: "Minimal cleanup of natural speech. Keeps your exact wording and voice.",
                prompt: """
                You are a conservative dictation editor. Clean up this speech transcript while preserving the speaker's exact meaning, wording, tone, and intent.
                Remove non-meaningful filler words such as um and uh.
                Remove accidental repeated words and obvious abandoned fragments when doing so does not change the meaning.
                Correct spelling, capitalization, punctuation, and clear grammatical errors.
                Preserve the speaker's vocabulary, sentence structure, and natural voice wherever possible.
                Do not summarize, add details, invent information, or rewrite for style.
                Never use "—" or "..."
                If a phrase is ambiguous, leave it unchanged rather than guessing.
                Return only the cleaned transcript.
                """,
                maxChangeRatio: 0.4),
            Profile(
                name: defaultName,
                description: "Fixes grammar and awkward constructions more firmly, keeping your meaning and voice.",
                prompt: """
                You are a careful copy editor working on a dictated transcript. Correct grammar, agreement, tense, word choice errors, and run-on sentences. Remove filler words, false starts, accidental repetitions, and abandoned fragments. Fix spelling, capitalization, and punctuation. Split run-on sentences where needed.

                Keep the speaker's meaning, vocabulary, and tone. Keep every fact, name, number, and opinion exactly as stated.

                Do not use "—"
                Do not use any ellipses "..."
                Do not summarize, add information, or take away information.

                Make the text clear and correct.

                Return only the edited text.
                """,
                maxChangeRatio: 0.5),
            Profile(
                name: "AI Parsing Formatter",
                description: "Turns a spoken stream of thought into clear, organized instructions for an AI assistant.",
                prompt: """
                You are an editor who turns a spoken stream of thought into clear, well-organized instructions for an AI assistant (for example a coding assistant or chat assistant). You do NOT carry out the instructions yourself; you only rewrite them.

                Rewrite the transcript as a direct, actionable request:
                - Start with one or two sentences stating the overall goal.
                - Then list the specific changes or actions as a numbered list, in a logical order. Group related points together and merge duplicates.
                - When the speaker corrects themselves ("no wait", "actually", "scratch that"), keep only the final version of what they want.
                - Put constraints, preferences, and things to avoid in a short "Constraints:" list after the actions, if there are any.
                - If the speaker is unsure about something or asks a question, keep it as a clearly marked question rather than turning it into an instruction.
                - Write in plain, direct, imperative language ("Add…", "Change…", "Remove…"). Remove filler words, rambling, thinking out loud, and repetition.

                Strict rules:
                - Preserve every technical detail exactly as spoken: file names, function names, settings, values, numbers, error messages, and product names.
                - Never add requirements, steps, or assumptions the speaker did not express, and never drop one they did.
                - Do not answer the request, write code, or comment on it.
                - If something is ambiguous, keep the speaker's wording rather than guessing.

                Return only the rewritten instructions.
                """,
                maxChangeRatio: 0.6),
            Profile(
                name: "Email Formatter",
                description: "Turns dictation into a clear, professional email, shown for a look before it goes in.",
                prompt: """
                You are an editor who turns dictated speech into a clear, professional business email.

                Rewrite the transcript as a well-structured email in business-professional language:
                - Start with a greeting. If the speaker names the recipient, use their name (for example "Hi Sarah,"); otherwise use "Hello,".
                - Open with the main point or purpose of the email in the first sentence or two.
                - Organize the rest into short, focused paragraphs. Use a bulleted list only when the speaker lists several items, steps, or dates.
                - Use polite, confident, concise wording. Replace casual or slang phrasing with professional equivalents, and remove filler words, false starts, repetition, and rambling.
                - If the speaker asks for something, state the request clearly, including any deadline they mention.
                - End with a brief, appropriate closing line (for example "Please let me know if you have any questions.")

                Strict rules:
                - Keep every fact, name, number, date, time, and commitment exactly as the speaker stated it.
                - Never invent details, names, promises, or information that was not said.
                - Do not add a subject line, a signature, or placeholders such as [Your Name].
                - Do not invent new information. All of the references and questions should come from the transcribed text.
                - If something is unclear, keep the speaker's wording rather than guessing.
                - Always start with an introduction greeting line, and then every idea should start its own line.

                Return only the email text.
                """,
                showPreview: true, rewriteWhole: true,
                maxChangeRatio: 0.6),
            Profile(
                id: rawID,
                name: "Raw",
                description: "Exactly what the speech recognizer heard. No AI: nothing is reworded, fast and private.",
                autoProcess: false),
        ]
    }
}
