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
/// download). A voice id also says its model: a Kokoro id ("af_heart"), "piper:<name>", or a system voice's
/// AVSpeechSynthesisVoice identifier.
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

    /// A Kokoro voice id: a language letter, f/m, "_", a name ("af_heart", "bm_george").
    public static func isKokoroVoice(_ id: String?) -> Bool {
        guard let id, !id.isEmpty else { return true } // no voice = the default, Heart
        return id.range(of: #"^[a-z][fm]_[a-z]+$"#, options: .regularExpression) != nil
    }

    public static func isSystemVoice(_ id: String?) -> Bool { !isPiperVoice(id) && !isKokoroVoice(id) }

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

    /// The system's voices in the user's language (Windows lists all its installed voices; the Mac has dozens per
    /// language, so only those that can read the user's language are offered), sorted by label as Windows sorts its
    /// voices: "Samantha (English (United States), female)". A name the Mac has in several qualities says which.
    public static func systemVoices() -> [VoiceOption] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { VoiceOption(id: $0.identifier, name: systemLabel($0), model: system) }
            .sorted { $0.name.compare($1.name, options: [.caseInsensitive, .numeric]) == .orderedAscending }
    }

    static func systemLabel(_ v: AVSpeechSynthesisVoice) -> String {
        let language = Locale.current.localizedString(forIdentifier: v.language) ?? v.language
        let gender = v.gender == .female ? ", female" : v.gender == .male ? ", male" : ""
        let quality = v.quality == .premium ? ", premium" : v.quality == .enhanced ? ", enhanced" : ""
        return "\(v.name) (\(language)\(gender)\(quality))"
    }
}
