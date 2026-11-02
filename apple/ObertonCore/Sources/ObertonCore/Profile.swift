import Foundation

/// A dictation profile: the instructions the AI follows and the switches around it. The same fields and built-ins as
/// the Windows app's `Profile` (src/Dictation.Core/Settings/Models.cs), so the two stay recognisably one product.
public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: String = UUID().uuidString
    public var name: String = "New Profile"
    public var description: String = ""
    public var prompt: String = ""
    /// The AI model, as a `ModelID` string ("apple:on-device", "ollama:qwen2.5:3b", "anthropic:…", "openai:…");
    /// nil = the default model in Settings.
    public var model: String?
    /// Read aloud voice for this profile (an AVSpeechSynthesisVoice identifier); nil = Read aloud's own.
    public var voice: String?
    /// Off = Raw: the recognizer's words, no AI.
    public var autoProcess: Bool = true
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

    public init(id: String = UUID().uuidString, name: String = "New Profile", description: String = "", prompt: String = "",
                model: String? = nil, autoProcess: Bool = true, maxChangeRatio: Double = 0.5) {
        self.id = id
        self.name = name
        self.description = description
        self.prompt = prompt
        self.model = model
        self.autoProcess = autoProcess
        self.maxChangeRatio = maxChangeRatio
    }

    public var isRaw: Bool { !autoProcess }
}

public enum BuiltInProfiles {
    public static let rawID = "builtin-raw"

    public static let customPrompt =
        "You are a dictation editor. Clean up this speech transcript: remove filler words and false starts, " +
        "and fix punctuation and capitalization, while keeping the speaker's meaning and wording.\n" +
        "Do not summarize or add information.\nReturn only the processed text."

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
                Preserve deliberate repetition, emphasis, and meaningful self-corrections.
                Do not summarize, add details, invent information, or rewrite for style.
                If a phrase is ambiguous, leave it unchanged rather than guessing.
                Return only the cleaned transcript.
                """,
                maxChangeRatio: 0.4),
            Profile(
                name: "Grammar & Clarity",
                description: "Fixes grammar and awkward constructions more firmly, keeping your meaning and voice.",
                prompt: """
                You are a careful copy editor working on a dictated transcript. Correct grammar, agreement, tense, word choice errors, and awkward or run-on sentence construction so the text is clear and correct.
                Remove filler words, false starts, accidental repetitions, and abandoned fragments.
                Fix spelling, capitalization, and punctuation. Split run-on sentences where needed.
                Keep the speaker's meaning, vocabulary, and tone. Keep every fact, name, number, and opinion exactly as stated.
                Do not summarize, add information, or change what is being said. You may lightly reorder words within a sentence only when needed for clarity.
                If something is ambiguous, leave it as spoken rather than guessing.
                Return only the edited text.
                """,
                maxChangeRatio: 0.5),
            Profile(
                name: "Natural Phrasing",
                description: "Makes spoken language read like written language while keeping the meaning and tone.",
                prompt: """
                You are editing a dictated transcript so that it reads naturally as written text, as if the speaker had typed it carefully.
                Remove filler words, false starts, repetitions, and verbal tics. Convert spoken constructions into natural written phrasing, and tidy sentence flow and punctuation.
                Preserve the speaker's meaning, intent, tone, and level of formality. Keep all facts, names, numbers, and opinions exactly as stated.
                Never summarize, never add information that was not said, and never drop meaningful content.
                If something is ambiguous, keep it as spoken rather than guessing.
                Return only the rewritten text.
                """,
                maxChangeRatio: 0.6),
            Profile(
                name: "Custom",
                description: "Write your own instructions.",
                prompt: customPrompt,
                maxChangeRatio: 0.6),
            Profile(
                id: rawID,
                name: "Raw",
                description: "Exactly what the speech recognizer heard. No AI: nothing is reworded, fast and private.",
                autoProcess: false),
        ]
    }
}
