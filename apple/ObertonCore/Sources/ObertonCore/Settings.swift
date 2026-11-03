import Foundation
import Security

/// Where the dictation overlay sits. Row by row, left to right, as on Windows.
public enum OverlayPosition: String, Codable, CaseIterable, Sendable {
    case topLeft, topCenter, topRight, middleLeft, center, middleRight, bottomLeft, bottomCenter, bottomRight
}

/// Where the Read aloud player sits: with the dictation overlay, or a place of its own (Windows' `ReaderPosition`,
/// where null = with the overlay). Saved as "withOverlay" or the position's name.
public enum ReaderPosition: Codable, Hashable, Sendable {
    case withOverlay
    case at(OverlayPosition)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "withOverlay" { self = .withOverlay; return }
        guard let p = OverlayPosition(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown reader position \(raw)"))
        }
        self = .at(p)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .withOverlay: try c.encode("withOverlay")
        case .at(let p): try c.encode(p.rawValue)
        }
    }
}

/// How a dictation goes into the app: Auto types short text and pastes long text (or text with line breaks), Typing
/// always types, Clipboard always pastes.
public enum InsertionMode: String, Codable, CaseIterable, Sendable { case auto, typing, clipboard }

/// System follows the device's light/dark setting; Light and Dark override it.
public enum AppTheme: String, Codable, CaseIterable, Sendable { case system, light, dark }

/// The accent laid over the paper, as on Windows: color is a signal (what is live or matters most), never decoration.
public enum AccentChoice: String, Codable, CaseIterable, Sendable {
    case cobalt, teal, signalGreen, violet, amber

    public var title: String {
        switch self {
        case .cobalt: "Cobalt"
        case .teal: "Teal"
        case .signalGreen: "Signal green"
        case .violet: "Violet"
        case .amber: "Amber"
        }
    }

    /// The version for light paper and for dark paper, as RGB hex (Services/ThemeManager.cs).
    public var hex: (light: UInt32, dark: UInt32) {
        switch self {
        case .cobalt: (0x2340FF, 0x7F8DFF)
        case .teal: (0x00747C, 0x3CD2D9)
        case .signalGreen: (0x00875A, 0x3BE0A2)
        case .violet: (0x6A2CF5, 0xB39BFF)
        case .amber: (0x9A6500, 0xFFC233)
        }
    }
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
    public static let defaultHotkey = "Ctrl+D", defaultCycleProfileHotkey = "Ctrl+Alt+D", defaultSpeakHotkey = "Ctrl+Space",
        defaultNotesMarkerHotkey = ""

    public var hotkey = defaultHotkey
    public var cycleProfileHotkey = defaultCycleProfileHotkey
    public var speakHotkey = defaultSpeakHotkey
    /// Drop a time marker into the Extended Notes transcript while a session records (paused or not); none by default,
    /// as on Windows (the session header's ⚑ Mark button does the same).
    public var notesMarkerHotkey = defaultNotesMarkerHotkey
    /// What Extended Notes listens to: the microphone, the computer's audio, or both (remembered). The iPhone can only
    /// hear its microphone.
    public var notesSource = NotesSource.both
    /// The AI model for Extended Notes' formatting and summaries: "" = the best on this Mac (the default), "active" =
    /// the active model, otherwise a model ID. See `NotesModels`.
    public var notesModel = ""
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
    /// The profile marked DEFAULT (the profile ⋯ menu); nil = none marked.
    public var defaultProfileID: String?
    /// IDs of built-in profiles already offered, so one added in an update appears once and stays deleted if the user
    /// deletes it.
    public var builtInProfilesAdded: [String] = []
    /// The microphone to record from, by name; nil = the system's default input.
    public var microphoneName: String?
    /// Level the volume before transcribing, so quiet stretches next to loud ones aren't dropped.
    public var evenOutVolume = true
    /// Open Oberton when the user logs in (Windows' StartWithWindows, on by default there too).
    public var startAtLogin = true
    /// Closing the window keeps Oberton running in the menu bar (Windows: minimize to the tray).
    public var minimizeToTray = true
    /// Unload a model after this many minutes without use, to free memory. 0 = keep loaded; `unloadImmediately` = as
    /// soon as each dictation or reading is done. It loads again by itself the next time it is needed.
    public var unloadAfterMinutes = 30
    public static let unloadImmediately = -1
    public var showOverlay = true
    /// Bottom left at 90% (the Windows defaults since 5.18).
    public var overlayPosition = OverlayPosition.bottomLeft
    public var overlayOpacity = 0.9
    /// The Read aloud player's own place (top right by default, as on Windows) and background opacity (0.3–1; its text
    /// stays fully opaque).
    public var readerPosition = ReaderPosition.at(.topRight)
    public var readerOpacity = 0.9
    /// The player shows the whole text (scrolling along) instead of the current sentence only.
    public var readerExpanded = false
    /// Read aloud: an AVSpeechSynthesisVoice identifier (nil = the system's default voice) and base speed (0.5–2).
    public var ttsVoice: String?
    public var ttsBaseSpeed = 1.75
    /// After a dictation is inserted, put the user's own clipboard back.
    public var restoreClipboard = true
    public var insertion = InsertionMode.auto
    /// Per-app insertion override, keyed by the app's bundle identifier (Windows: by process name, e.g. "notepad").
    public var appOverrides: [String: InsertionMode] = [:]
    /// In Auto mode, text longer than this (or containing line breaks) is pasted instead of typed.
    public var typingMaxChars = 400
    /// Read a sentence or two around the cursor to fix capitalization, trailing periods and spacing when inserting
    /// into the middle of existing text.
    public var matchSurroundingText = true
    /// Type finished sentences into the app while still speaking, then replace them with one final cleaned-up pass
    /// when dictation stops.
    public var typeWhileSpeaking = false
    public var keepHistory = true
    /// How many recent dictations History keeps; 0 = all of them (the default since Windows 5.18).
    public var historyLimit = 0
    /// Or how long History keeps them, in days (0 = no limit by age).
    public var historyDays = 0
    /// Keep each dictation's recording so it can be played back.
    public var saveHistoryAudio = true
    /// How many of the newest dictations keep their recording, or for how many days (0 and 0 = as long as the text).
    /// A recording never outlives its text. By default recordings are kept for a week.
    public var audioLimit = 0
    public var audioDays = 7
    /// History lists dictations by app (newest first within each) rather than in one list.
    public var historyByApp = true
    /// Keep the Analytics word tally (words.json): counts of words, phrases, corrections and fillers, never sentences.
    public var keepWordTally = true
    public var maxRecordingSeconds = 600.0
    public var typingWPM = 35
    public var cloud = CloudSettings()
    public var theme = AppTheme.system
    public var accent = AccentChoice.violet
    /// Show the small decorative Japanese words beside labels (倍音, 設定…). Off hides every one of them.
    public var showJapanese = true
    /// The main window's sidebar is folded away, so the page fills the window (open by default, as on Windows since 5.18).
    public var sidebarCollapsed = false
    /// Settings menu groups folded away, by name ("A // Dictation", "B // Models & AI", …).
    public var collapsedSettingsGroups: [String] = []
    /// The size of everything in the main window, 1 = as designed (Cmd+plus, Cmd+minus, Cmd+0).
    public var uiScale = 1.0
    /// The dashboard notepad from before Extended Notes; its text moves to Extended Notes' draft (notes/draft.txt) once.
    public var notepad = ""

    public init() {}

    // Settings files from older versions are missing newer keys: decode what is there, default the rest.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func take<T: Decodable>(_ key: CodingKeys, _ into: inout T) { if let v = try? c.decode(T.self, forKey: key) { into = v } }
        take(.hotkey, &hotkey); take(.cycleProfileHotkey, &cycleProfileHotkey); take(.speakHotkey, &speakHotkey)
        take(.notesMarkerHotkey, &notesMarkerHotkey); take(.notesSource, &notesSource); take(.notesModel, &notesModel)
        take(.defaultModel, &defaultModel); take(.ollamaEndpoint, &ollamaEndpoint); take(.aiTimeoutSeconds, &aiTimeoutSeconds)
        take(.language, &language); take(.vocabularyHint, &vocabularyHint); take(.activeProfileID, &activeProfileID)
        take(.showOverlay, &showOverlay); take(.overlayPosition, &overlayPosition); take(.overlayOpacity, &overlayOpacity)
        take(.ttsVoice, &ttsVoice); take(.ttsBaseSpeed, &ttsBaseSpeed); take(.restoreClipboard, &restoreClipboard)
        take(.keepHistory, &keepHistory); take(.historyLimit, &historyLimit); take(.historyByApp, &historyByApp); take(.keepWordTally, &keepWordTally); take(.maxRecordingSeconds, &maxRecordingSeconds)
        take(.typingWPM, &typingWPM); take(.cloud, &cloud)
        take(.theme, &theme); take(.accent, &accent); take(.showJapanese, &showJapanese)
        take(.sidebarCollapsed, &sidebarCollapsed); take(.uiScale, &uiScale); take(.notepad, &notepad)
        take(.defaultProfileID, &defaultProfileID); take(.builtInProfilesAdded, &builtInProfilesAdded)
        take(.microphoneName, &microphoneName); take(.evenOutVolume, &evenOutVolume)
        take(.startAtLogin, &startAtLogin); take(.minimizeToTray, &minimizeToTray); take(.unloadAfterMinutes, &unloadAfterMinutes)
        take(.readerPosition, &readerPosition); take(.readerOpacity, &readerOpacity); take(.readerExpanded, &readerExpanded)
        take(.insertion, &insertion); take(.typingMaxChars, &typingMaxChars)
        take(.matchSurroundingText, &matchSurroundingText); take(.typeWhileSpeaking, &typeWhileSpeaking)
        take(.historyDays, &historyDays); take(.saveHistoryAudio, &saveHistoryAudio); take(.audioLimit, &audioLimit); take(.audioDays, &audioDays)
        take(.collapsedSettingsGroups, &collapsedSettingsGroups)
        // One unknown mode drops only that app's override, not the others.
        if let raw = try? c.decode([String: String].self, forKey: .appOverrides) {
            appOverrides = raw.compactMapValues(InsertionMode.init(rawValue:))
        }
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
