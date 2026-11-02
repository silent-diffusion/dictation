import Foundation
import Security

/// Where the dictation overlay sits. Row by row, left to right, as on Windows.
public enum OverlayPosition: String, Codable, CaseIterable, Sendable {
    case topLeft, topCenter, topRight, middleLeft, center, middleRight, bottomLeft, bottomCenter, bottomRight
}

public struct CloudSettings: Codable, Sendable, Equatable {
    /// The master switch: while on, nothing is sent to a cloud model, whatever a profile selects.
    public var keepOffline = true
    /// OpenAI or any OpenAI-compatible service (OpenRouter, Groq, …).
    public var openAIBaseURL = "https://api.openai.com/v1"
    public var openAIModel = "gpt-4.1-mini"
    // The API keys themselves live in the Keychain (`KeyStore`), never in settings.json.
}

public struct AppSettings: Codable, Sendable, Equatable {
    public static let defaultHotkey = "Ctrl+D", defaultCycleProfileHotkey = "Ctrl+Alt+D", defaultSpeakHotkey = "Ctrl+Space"

    public var hotkey = defaultHotkey
    public var cycleProfileHotkey = defaultCycleProfileHotkey
    public var speakHotkey = defaultSpeakHotkey
    /// The AI model used by profiles that don't pick their own. Apple Intelligence where it is available: nothing to
    /// install, nothing leaves the device.
    public var defaultModel = ModelID.appleOnDevice
    /// A local Ollama server, optional (Ollama's own default port; the Windows app's private 11435 is its bundled copy).
    public var ollamaEndpoint = "http://127.0.0.1:11434"
    public var aiTimeoutSeconds = 60.0
    /// Speech recognition language (BCP 47, e.g. "en-US").
    public var language = "en-US"
    /// Names and jargon to bias recognition, e.g. "Kubernetes, Dr. Nguyen".
    public var vocabularyHint = ""
    public var activeProfileID: String?
    public var showOverlay = true
    public var overlayPosition = OverlayPosition.bottomCenter
    public var overlayOpacity = 0.88
    /// Read aloud: an AVSpeechSynthesisVoice identifier (nil = the system's default voice) and base speed (0.5–2).
    public var ttsVoice: String?
    public var ttsBaseSpeed = 1.0
    /// After a dictation is inserted, put the user's own clipboard back.
    public var restoreClipboard = true
    public var keepHistory = true
    public var historyLimit = 50
    public var maxRecordingSeconds = 600.0
    public var typingWPM = 40
    public var cloud = CloudSettings()

    public init() {}

    // Settings files from older versions are missing newer keys: decode what is there, default the rest.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func take<T: Decodable>(_ key: CodingKeys, _ into: inout T) { if let v = try? c.decode(T.self, forKey: key) { into = v } }
        take(.hotkey, &hotkey); take(.cycleProfileHotkey, &cycleProfileHotkey); take(.speakHotkey, &speakHotkey)
        take(.defaultModel, &defaultModel); take(.ollamaEndpoint, &ollamaEndpoint); take(.aiTimeoutSeconds, &aiTimeoutSeconds)
        take(.language, &language); take(.vocabularyHint, &vocabularyHint); take(.activeProfileID, &activeProfileID)
        take(.showOverlay, &showOverlay); take(.overlayPosition, &overlayPosition); take(.overlayOpacity, &overlayOpacity)
        take(.ttsVoice, &ttsVoice); take(.ttsBaseSpeed, &ttsBaseSpeed); take(.restoreClipboard, &restoreClipboard)
        take(.keepHistory, &keepHistory); take(.historyLimit, &historyLimit); take(.maxRecordingSeconds, &maxRecordingSeconds)
        take(.typingWPM, &typingWPM); take(.cloud, &cloud)
    }
}

/// The app's data folder: Application Support/Oberton (inside the sandbox container on the App Store build).
public enum AppPaths {
    public static var dataDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appending(path: "Oberton", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Reads and writes one Codable value as pretty JSON in the data folder.
public struct JSONFile<T: Codable> {
    public let url: URL
    public init(_ name: String) { url = AppPaths.dataDir.appending(path: name) }

    public func load() -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func save(_ value: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(value) { try? data.write(to: url, options: .atomic) }
    }
}

/// Cloud API keys, in the Keychain (the Windows app encrypts them with DPAPI for the same reason).
public enum KeyStore {
    static let service = "Oberton.CloudKey"

    public static func get(_ provider: ModelID.Provider) -> String? {
        var item: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: provider.rawValue, kSecReturnData as String: true]
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    public static func set(_ provider: ModelID.Provider, _ key: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: provider.rawValue]
        SecItemDelete(q as CFDictionary)
        guard let key, !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(key.trimmingCharacters(in: .whitespaces).utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
