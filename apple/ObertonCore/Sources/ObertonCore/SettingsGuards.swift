import Foundation

extension AppSettings {
    /// Privacy guard (Windows' SettingsService.EnforceLocalEndpoint): the Ollama address must be on this device,
    /// otherwise transcripts could leave it. Anything else goes back to the default. True when it was reset.
    @discardableResult
    public mutating func enforceLocalEndpoint() -> Bool {
        if (try? OllamaBackend.validated(ollamaEndpoint)) != nil { return false }
        ollamaEndpoint = AppSettings().ollamaEndpoint
        return true
    }
}
