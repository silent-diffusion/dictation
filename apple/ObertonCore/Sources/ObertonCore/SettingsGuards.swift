import Foundation

extension AppSettings {
    /// Privacy guard (Windows' SettingsService.EnforceLocalEndpoint): the Ollama address must be on this device,
    /// otherwise transcripts could leave it. Anything else goes back to the default. True when it was reset.
    @discardableResult
    public mutating func enforceLocalEndpoint() -> Bool {
        if (try? OllamaBackend.validated(ollamaEndpoint)) != nil { return false }
        CoreLog.warn("LLM endpoint '\(ollamaEndpoint)' is not local; resetting to default.")
        ollamaEndpoint = AppSettings().ollamaEndpoint
        return true
    }
}

extension AppSettings {
    /// What a WPF int binding takes from a text box (Settings › Models' GIVE UP AFTER): a whole number in Int32's range,
    /// spaces around it allowed; anything else is refused and the setting stays.
    public static func wholeNumber(_ text: String) -> Int32? { Int32(text.trimmingCharacters(in: .whitespaces)) }
}
