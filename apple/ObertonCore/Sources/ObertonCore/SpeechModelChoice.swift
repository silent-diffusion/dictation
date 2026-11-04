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
