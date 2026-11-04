import AVFoundation
import Foundation

/// A voice Read aloud can use. `model` is the id of its `TtsModel`.
public struct VoiceOption: Hashable, Sendable {
    public let id: String
    public let name: String
    public let model: String
}

/// A text-to-speech model (engine) with its own voices.
public struct TtsModel: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
}

/// A downloadable Piper voice: one ONNX file (plus its JSON config) from rhasspy/piper-voices.
public struct PiperVoice: Hashable, Sendable {
    public let name: String
    public let label: String
    public let kind: String
    public let mb: Int

    public var id: String { VoiceCatalog.piperPrefix + name }

    /// "en_US-lessac-medium" → en/en_US/lessac/medium/en_US-lessac-medium.onnx on Hugging Face.
    public var url: URL {
        let parts = name.split(separator: "-").map(String.init) // locale, speaker, quality
        return URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/\(parts[0].prefix(2))/\(parts[0])/\(parts[1])/\(parts[2])/\(name).onnx")!
    }
}

/// The text-to-speech models Read aloud can use, and their voices (Windows' VoiceCatalog): Kokoro (natural, one
/// download), Piper (light and fast, one small download per voice) and the voices that come with the system (no
/// download). A voice id also says its model, as on Windows: "piper:<name>", a system voice's AVSpeechSynthesisVoice
/// identifier (where Windows writes "win:<name>"), and anything else is Kokoro's ("af_heart"; an id Kokoro doesn't know
/// reads with Heart).
public enum VoiceCatalog {
    public static let kokoro = "kokoro", piper = "piper", system = "system"
    public static let piperPrefix = "piper:"
    /// Windows' default voice, and the one Kokoro falls back to.
    public static let defaultVoice = "af_heart"

    /// For the texts ("runs on this Mac"), as the app's `Device`.
    #if os(macOS)
    public static let deviceNoun = "Mac", systemName = "macOS"
    #else
    public static let deviceNoun = "iPhone", systemName = "iOS"
    #endif

    public static var models: [TtsModel] {
        [
            TtsModel(id: kokoro, name: "Kokoro v1.0",
                     description: "The most natural voices. One download of about \(VoiceInstaller.kokoroDownloadMb) MB; runs on this \(deviceNoun)."),
            TtsModel(id: piper, name: "Piper",
                     description: "Light and fast, even on slower \(deviceNoun)s. Each voice is a separate download of 60 to 120 MB; runs on this \(deviceNoun)."),
            TtsModel(id: system, name: "\(deviceNoun) voices",
                     description: "The voices that come with \(systemName). Nothing to download; more robotic."),
        ]
    }

    /// A short list of Kokoro v1.0's best English voices.
    public static let kokoroVoices: [VoiceOption] = [
        VoiceOption(id: "af_heart", name: "Heart (American, female)", model: kokoro),
        VoiceOption(id: "af_bella", name: "Bella (American, female)", model: kokoro),
        VoiceOption(id: "af_nicole", name: "Nicole (American, female, soft)", model: kokoro),
        VoiceOption(id: "am_michael", name: "Michael (American, male)", model: kokoro),
        VoiceOption(id: "am_fenrir", name: "Fenrir (American, male)", model: kokoro),
        VoiceOption(id: "bf_emma", name: "Emma (British, female)", model: kokoro),
        VoiceOption(id: "bm_george", name: "George (British, male)", model: kokoro),
        VoiceOption(id: "bm_fable", name: "Fable (British, male)", model: kokoro),
    ]

    public static let piperVoices: [PiperVoice] = [
        PiperVoice(name: "en_US-lessac-medium", label: "Lessac", kind: "American, female", mb: 63),
        PiperVoice(name: "en_US-amy-medium", label: "Amy", kind: "American, female", mb: 63),
        PiperVoice(name: "en_US-ryan-high", label: "Ryan", kind: "American, male, high quality", mb: 121),
        PiperVoice(name: "en_US-joe-medium", label: "Joe", kind: "American, male", mb: 63),
        PiperVoice(name: "en_GB-jenny_dioco-medium", label: "Jenny", kind: "British, female", mb: 63),
        PiperVoice(name: "en_GB-alan-medium", label: "Alan", kind: "British, male", mb: 63),
    ]

    public static func isPiperVoice(_ id: String?) -> Bool { id?.hasPrefix(piperPrefix) == true }

    /// A Kokoro voice id: anything that isn't Piper's or the system's (Windows' ModelOf: no "win:"/"piper:" prefix).
    public static func isKokoroVoice(_ id: String?) -> Bool { !isPiperVoice(id) && !isSystemVoice(id) }

    /// A system voice: an AVSpeechSynthesisVoice identifier ("com.apple.voice.compact.en-US.Samantha"), or the id of a
    /// voice the system has (another vendor's).
    public static func isSystemVoice(_ id: String?) -> Bool {
        guard let id, !id.isEmpty, !isPiperVoice(id) else { return false }
        return id.hasPrefix(systemPrefix) || AVSpeechSynthesisVoice(identifier: id) != nil
    }

    /// How the system's voice identifiers start.
    static let systemPrefix = "com.apple."

    /// The model a voice belongs to.
    public static func modelOf(_ voiceID: String?) -> String {
        isPiperVoice(voiceID) ? piper : isKokoroVoice(voiceID) ? kokoro : system
    }

    public static func model(_ id: String) -> TtsModel { models.first { $0.id == id } ?? models[0] }

    /// Every voice of a model, downloaded or not.
    public static func voicesOf(_ model: String) -> [VoiceOption] {
        switch model {
        case piper: piperVoices.map { VoiceOption(id: $0.id, name: "\($0.label) (\($0.kind))", model: piper) }
        case system: systemVoices()
        default: kokoroVoices
        }
    }

    /// The voice can be used right now (its model or file is downloaded, or the system has it).
    public static func isInstalled(_ voiceID: String?) -> Bool {
        switch modelOf(voiceID) {
        case system: AVSpeechSynthesisVoice(identifier: voiceID ?? "") != nil
        case piper: VoiceInstaller.piperInstalled(String(voiceID!.dropFirst(piperPrefix.count)))
        default: VoiceInstaller.kokoroInstalled
        }
    }

    /// The voices that can be used right now.
    public static func available() -> [VoiceOption] {
        models.flatMap { voicesOf($0.id) }.filter { isInstalled($0.id) }
    }

    public static func findPiper(_ voiceID: String?) -> PiperVoice? { piperVoices.first { $0.id == voiceID } }

    /// A short display name: "Heart", "Lessac", "Samantha".
    public static func shortName(_ id: String?) -> String {
        let id = id?.isEmpty == false ? id! : defaultVoice
        if isSystemVoice(id) { return AVSpeechSynthesisVoice(identifier: id)?.name ?? id }
        guard let v = voicesOf(modelOf(id)).first(where: { $0.id == id }) else { return id }
        return String(v.name.split(separator: " (").first ?? Substring(v.name))
    }

    // MARK: System voices

    /// The system's voices, every one it has, as Windows lists every enabled voice, sorted by label:
    /// "Samantha (English (United States), female)".
    public static func systemVoices() -> [VoiceOption] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let labels = voices.map(systemLabel)
        // The Mac has some voices in more than one quality (Windows never lists two alike): only those say which.
        var counts: [String: Int] = [:]
        labels.forEach { counts[$0, default: 0] += 1 }
        return zip(voices, labels)
            .map { v, label in VoiceOption(id: v.identifier, name: counts[label, default: 0] > 1 ? label + qualitySuffix(v) : label, model: system) }
            .sorted { sortsBefore($0.name, $1.name) }
    }

    /// .NET's OrderBy on strings: the current culture's comparison.
    static func sortsBefore(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [], range: nil, locale: .current) == .orderedAscending
    }

    /// "Name (Language, gender)" as WindowsSpeech.InstalledVoices. A voice with no gender leaves it out: Windows would
    /// print its enum's name ("notset"), which no one would want to read.
    static func systemLabel(_ v: AVSpeechSynthesisVoice) -> String {
        let language = Locale.current.localizedString(forIdentifier: v.language) ?? v.language
        let gender = v.gender == .female ? ", female" : v.gender == .male ? ", male" : ""
        return "\(v.name) (\(language)\(gender))"
    }

    private static func qualitySuffix(_ v: AVSpeechSynthesisVoice) -> String {
        v.quality == .premium ? ", premium" : v.quality == .enhanced ? ", enhanced" : ""
    }
}
