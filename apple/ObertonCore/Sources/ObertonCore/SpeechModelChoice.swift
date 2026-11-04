import Foundation

/// The speech model a new install starts with, as Windows' RuntimeInstaller.ChooseModels picks by hardware
/// (large-v3 turbo with an NVIDIA GPU, small.en without): large-v3 turbo on Apple silicon with 16 GB of memory or more,
/// small.en otherwise and on iPhone and iPad. Those English-only models don't fit a device set to another language:
/// there, without room for turbo, it stays on Apple Speech (""), which follows the system language. Picked once, for a
/// new install only; existing settings keep the user's own model.
public enum SpeechModelChoice {
    public static func recommended(language: String = "", memory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                                   appleSilicon: Bool = isAppleSilicon, phone: Bool = isPhone,
                                   systemLanguage: String? = Locale.current.language.languageCode?.identifier) -> String {
        if !phone, appleSilicon, memory >= 16 << 30 { return "large-v3-turbo" }
        let code = language.isEmpty ? (systemLanguage ?? "en") : String(language.prefix(2))
        return code == "en" ? "small.en" : ""
    }

    public static var isPhone: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
}

/// A new install's speech model while it downloads (Windows' RuntimeInstaller.ChooseModels at setup, ModelsChosen):
/// picked once, when there was no settings.json at launch, and kept in speech-setup.json until it is downloaded and in
/// use, so the launch's own settings save (or quitting before the download ends) can't lose it.
public struct FirstRunSpeech: Sendable {
    struct Setup: Codable { var model: String }
    private let file: JSONFile<Setup>

    public init(file url: URL = AppPaths.dataDir.appending(path: "speech-setup.json")) { file = JSONFile(url: url) }

    /// The model still to set up at launch: a new install's pick (`pick`, written down at once), else the one an earlier
    /// launch picked and didn't finish.
    public func atLaunch(newInstall: Bool, pick: () -> String) -> String? {
        guard newInstall else { return pending }
        let model = pick()
        pending = model
        return model
    }

    /// The model waiting to be set up; nil when none (setting nil forgets it).
    public var pending: String? {
        get { file.load()?.model }
        nonmutating set {
            if let newValue { _ = file.save(Setup(model: newValue)) } else { try? FileManager.default.removeItem(at: file.url) }
        }
    }
}
