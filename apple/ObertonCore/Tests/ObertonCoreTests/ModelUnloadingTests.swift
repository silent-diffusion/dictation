import Testing
@testable import ObertonCore

/// Settings › Model unloading as Ollama's keep_alive (Windows Models.cs OllamaKeepAlive, TextProcessing KeepAliveAsync).
struct ModelUnloadingTests {
    private func settings(_ minutes: Int) -> AppSettings {
        var s = AppSettings()
        s.unloadAfterMinutes = minutes
        return s
    }

    @Test func keepAliveFollowsTheSetting() {
        #expect(AppSettings().unloadAfterMinutes == 30)
        #expect(settings(30).ollamaKeepAlive == "30m")
        #expect(settings(1).ollamaKeepAlive == "1m")
        #expect(settings(0).ollamaKeepAlive == "-1m") // never: keep loaded
        #expect(settings(AppSettings.unloadImmediately).ollamaKeepAlive == "1m") // the app unloads it a few seconds after use
    }

    @Test func aLargeModelIsKeptFiveMinutesAtMost() {
        #expect(settings(30).ollamaKeepAlive(large: true) == "5m")
        #expect(settings(0).ollamaKeepAlive(large: true) == "5m")
        #expect(settings(3).ollamaKeepAlive(large: true) == "3m")
        #expect(settings(AppSettings.unloadImmediately).ollamaKeepAlive(large: true) == "1m")
        #expect(settings(30).ollamaKeepAlive(large: false) == "30m")
    }
}
