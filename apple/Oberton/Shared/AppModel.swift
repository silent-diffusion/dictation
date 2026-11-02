import Foundation
import ObertonCore
import SwiftUI

/// What each platform does differently: where the text goes and where read-aloud text comes from.
@MainActor
protocol PlatformServices: AnyObject {
    /// Remember where the user was when they pressed the hotkey, so the text goes back there.
    func captureTarget()
    /// Put the text where the user was. Returns a short receipt ("Inserted into Mail", "Copied").
    func insert(_ text: String) async throws -> String
    /// The name of the app the text is going into, if known.
    var targetAppName: String? { get }
    /// The text selected in the frontmost app, or nil.
    func selectedText() async -> String?
    func clipboardText() -> String?
    /// Ask once for the permissions dictation needs (microphone; on the Mac, Accessibility to paste).
    func requestPermissions() async
}

/// The dictation state machine, shared by the Mac and iPhone apps: Idle → Recording → Transcribing → Processing →
/// [Preview] → Inserting, as in the Windows `DictationController`.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle, starting, recording, transcribing, processing, preview, inserting
        case done(String)
        case failed(String)

        var isBusy: Bool {
            switch self { case .idle, .done, .failed: false; default: true }
        }
    }

    @Published var settings: AppSettings { didSet { settingsFile.save(settings) } }
    @Published var profiles: [Profile] { didSet { profilesFile.save(profiles) } }
    @Published private(set) var history: [HistoryEntry]
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveText = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var startedAt: Date?
    /// The dictation waiting in the preview (profiles with "preview before inserting").
    @Published private(set) var pending: HistoryEntry?
    @Published var ollamaModels: [String] = []

    let reader = ReadAloudPlayer()
    weak var platform: PlatformServices?

    private let settingsFile = JSONFile<AppSettings>("settings.json")
    private let profilesFile = JSONFile<[Profile]>("profiles.json")
    private let historyFile = JSONFile<[HistoryEntry]>("history.json")
    private let transcriber = LiveTranscriber()
    private var work: Task<Void, Never>?
    private var limitTimer: Timer?
    private var stoppedAt: Date?

    init() {
        settings = settingsFile.load() ?? AppSettings()
        profiles = profilesFile.load() ?? BuiltInProfiles.create()
        history = historyFile.load() ?? []
        if AppleIntelligenceBackend.unavailableReason != nil, settings.defaultModel == .appleOnDevice, settingsFile.load() == nil {
            // A device without Apple Intelligence starts on Raw rather than failing every dictation.
            settings.activeProfileID = BuiltInProfiles.rawID
        }
        transcriber.onText = { [weak self] in self?.liveText = $0 }
        transcriber.onLevel = { [weak self] in self?.level = $0 }
    }

    var activeProfile: Profile {
        get { profiles.first { $0.id == settings.activeProfileID } ?? profiles.first ?? BuiltInProfiles.create()[0] }
        set { settings.activeProfileID = newValue.id }
    }

    var processor: TextProcessor { TextProcessor(settings: settings) }

    // MARK: Dictation

    /// The hotkey: start, or stop and insert. With a preview showing, it inserts the preview.
    func toggleDictation() {
        switch phase {
        case .idle, .done, .failed: start()
        case .recording: stop()
        case .preview: confirmPreview()
        default: break // already working on it; Cancel stops it
        }
    }

    func start() {
        reader.stop()
        platform?.captureTarget()
        liveText = ""
        pending = nil
        phase = .starting
        startedAt = Date()
        work = Task {
            do {
                let vocabulary = settings.vocabularyHint.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                try await transcriber.start(locale: Locale(identifier: settings.language), vocabulary: vocabulary)
                guard phase == .starting else { await transcriber.cancel(); return }
                phase = .recording
                limitTimer = Timer.scheduledTimer(withTimeInterval: settings.maxRecordingSeconds, repeats: false) { [weak self] _ in
                    Task { @MainActor in if self?.phase == .recording { self?.stop() } }
                }
            } catch {
                fail(error)
            }
        }
    }

    func stop() {
        guard phase == .recording else { return }
        limitTimer?.invalidate()
        stoppedAt = Date()
        phase = .transcribing
        level = 0
        work = Task {
            let raw = await transcriber.stop()
            let seconds = (stoppedAt ?? Date()).timeIntervalSince(startedAt ?? Date())
            // No phantom text: very short or silent recordings insert nothing.
            guard seconds >= 0.4, OutputSanitizer.hasContent(raw) else { phase = .done("Nothing heard"); scheduleIdle(); return }
            await finish(raw: raw, seconds: seconds, profile: activeProfile)
        }
    }

    func cancel() {
        limitTimer?.invalidate()
        work?.cancel()
        pending = nil
        Task { await transcriber.cancel() }
        level = 0
        phase = .idle
    }

    private func finish(raw: String, seconds: Double, profile: Profile) async {
        var result = ProcessResult(text: raw, modified: false)
        if !profile.isRaw {
            phase = .processing
            result = await processor.process(raw, profile: profile)
            if Task.isCancelled { return }
        }
        let entry = HistoryEntry(transcription: raw, aiEdit: profile.isRaw ? nil : result.text, inserted: result.text,
                                 profileName: profile.name, model: profile.isRaw ? nil : processor.model(for: profile).description,
                                 appName: platform?.targetAppName, seconds: seconds,
                                 turnaroundSeconds: Date().timeIntervalSince(stoppedAt ?? Date()), warning: result.warning)
        if profile.showPreview {
            pending = entry
            phase = .preview
            return
        }
        await insert(entry, readBack: profile.readAloudAfterInsert ? profile.voice : nil, readBackRequested: profile.readAloudAfterInsert)
    }

    /// Insert the previewed text (`useOriginal`: the raw transcription instead).
    func confirmPreview(useOriginal: Bool = false) {
        guard var entry = pending else { return }
        if useOriginal { entry.inserted = entry.transcription }
        pending = nil
        let profile = activeProfile
        work = Task { await insert(entry, readBack: profile.voice, readBackRequested: profile.readAloudAfterInsert) }
    }

    private func insert(_ entry: HistoryEntry, readBack voice: String?, readBackRequested: Bool) async {
        phase = .inserting
        do {
            let receipt = try await platform?.insert(entry.inserted) ?? "Done"
            record(entry)
            phase = .done(entry.warning ?? receipt)
            if readBackRequested { reader.read(entry.inserted, voice: voice ?? settings.ttsVoice, speed: settings.ttsBaseSpeed) }
        } catch {
            record(entry)
            fail(error)
            return
        }
        scheduleIdle()
    }

    private func fail(_ error: Error) {
        level = 0
        phase = .failed(error.localizedDescription)
        scheduleIdle(after: 6)
    }

    private func scheduleIdle(after seconds: Double = 2.5) {
        let current = phase
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if phase == current { phase = .idle }
        }
    }

    func cycleProfile() {
        guard let i = profiles.firstIndex(where: { $0.id == activeProfile.id }), !profiles.isEmpty else { return }
        activeProfile = profiles[(i + 1) % profiles.count]
    }

    // MARK: History

    var lastEntry: HistoryEntry? { history.first }

    private func record(_ entry: HistoryEntry) {
        guard settings.keepHistory else { return }
        history.insert(entry, at: 0)
        if settings.historyLimit > 0, history.count > settings.historyLimit { history.removeLast(history.count - settings.historyLimit) }
        historyFile.save(history)
    }

    func deleteHistory(_ ids: Set<HistoryEntry.ID>) {
        history.removeAll { ids.contains($0.id) }
        historyFile.save(history)
    }

    func clearHistory() {
        history = []
        historyFile.save(history)
    }

    // MARK: Read aloud

    /// The read-aloud hotkey: the selection, or the clipboard when nothing is selected. Pressed while reading, it stops.
    func readSelection() {
        if reader.isSpeaking { reader.stop(); return }
        Task {
            let text = await platform?.selectedText() ?? platform?.clipboardText()
            guard let text, OutputSanitizer.hasContent(text) else { return }
            reader.read(text, voice: activeProfile.voice ?? settings.ttsVoice, speed: settings.ttsBaseSpeed)
        }
    }

    // MARK: Models

    /// Every model a profile can pick right now: Apple Intelligence, installed Ollama models, and cloud models.
    var availableModels: [ModelID] {
        var list = [ModelID.appleOnDevice]
        list += ollamaModels.map { ModelID(provider: .ollama, name: $0) }
        list += CloudCatalog.anthropic.map(\.id)
        list.append(ModelID(provider: .openai, name: settings.cloud.openAIModel))
        return list
    }

    func refreshOllama() async {
        guard let url = try? OllamaBackend.validated(settings.ollamaEndpoint) else { ollamaModels = []; return }
        ollamaModels = await OllamaBackend.installedModels(endpoint: url)
    }
}
