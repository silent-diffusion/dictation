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
    @Published private(set) var usage: UsageLog
    /// The Analytics word tally (words.json): counts only, never sentences.
    @Published private(set) var words: WordTally
    /// The last dictation that went in, for the overlay's receipt (shown when the pill is clicked).
    @Published var receipt: HistoryEntry?

    let reader = ReadAloudPlayer()
    weak var platform: PlatformServices?

    private let settingsFile = JSONFile<AppSettings>("settings.json")
    private let profilesFile = JSONFile<[Profile]>("profiles.json")
    private let historyFile = JSONFile<[HistoryEntry]>("history.json")
    private let usageFile = JSONFile<UsageLog>("usage.json")
    private let wordsFile = JSONFile<WordTally>("words.json")
    private let transcriber = LiveTranscriber()
    private var work: Task<Void, Never>?
    private var limitTimer: Timer?
    private var stoppedAt: Date?

    init() {
        let loadedSettings = settingsFile.load() ?? AppSettings(), history = historyFile.load() ?? []
        settings = loadedSettings
        profiles = profilesFile.load() ?? BuiltInProfiles.create()
        self.history = history
        usage = usageFile.load() ?? UsageLog()
        if let loaded = wordsFile.load() {
            words = loaded
        } else if loadedSettings.keepWordTally {
            // The first time: seed the tally from what History already has, so Analytics doesn't start empty.
            let seeded = WordTally(seed: history)
            words = seeded
            if !Self.snapshotMode { wordsFile.save(seeded) }
        } else {
            words = WordTally()
        }
        if AppleIntelligenceBackend.unavailableReason != nil, settings.defaultModel == .appleOnDevice, settingsFile.load() == nil {
            // A device without Apple Intelligence starts on Raw rather than failing every dictation.
            settings.activeProfileID = BuiltInProfiles.rawID
        }
        transcriber.onText = { [weak self] in self?.liveText = $0 }
        transcriber.onLevel = { [weak self] in self?.level = $0 }
        reader.onFinishedReading = { [weak self] words, seconds in
            guard let self else { return }
            self.usage.recordReading(words: words, seconds: seconds)
            self.usageFile.save(self.usage)
        }
    }

    /// Whether the active profile's AI can run right now (for the status dots).
    var aiReady: Bool {
        let id = processor.model(for: activeProfile)
        switch id.provider {
        case .apple: return AppleIntelligenceBackend.unavailableReason == nil
        case .ollama: return ollamaModels.contains(id.name)
        case .anthropic, .openai: return !settings.cloud.keepOffline && KeyStore.get(id.provider) != nil
        }
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
            self.receipt = entry
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
        // The daily counts are kept whether or not History is.
        usage.recordDictation(words: entry.words, seconds: entry.seconds, turnaround: entry.turnaroundSeconds,
                              usedAI: entry.aiEdit != nil, keptAI: entry.aiEdit != nil && entry.warning == nil, app: entry.appName)
        usageFile.save(usage)
        if settings.keepWordTally {
            words.record(entry)
            wordsFile.save(words)
        }
        guard settings.keepHistory else { return }
        history.insert(entry, at: 0)
        if settings.historyLimit > 0, history.count > settings.historyLimit { history.removeLast(history.count - settings.historyLimit) }
        historyFile.save(history)
    }

    func deleteHistory(_ ids: Set<HistoryEntry.ID>) {
        history.removeAll { ids.contains($0.id) }
        historyFile.save(history)
    }

    /// Put a text into the app the last dictation went to (History's "Insert transcription into the last app").
    func insertIntoLastApp(_ text: String) async -> String {
        do { return try await platform?.insert(text) ?? "" } catch { return error.localizedDescription }
    }

    func resetUsage() {
        usage = UsageLog()
        usageFile.save(usage)
    }

    /// Forget the word tally (Settings › History).
    func resetWordTally() {
        words = WordTally()
        wordsFile.save(words)
    }

    /// Whether a word is in the speech vocabulary hint (Settings › Speech recognition).
    func inVocabulary(_ word: String) -> Bool { Vocabulary.contains(settings.vocabularyHint, word) }

    /// Add a word to the speech vocabulary hint, so the recognizer expects it from the next dictation on (Analytics'
    /// "Add to vocabulary").
    func addToVocabulary(_ word: String) {
        settings.vocabularyHint = Vocabulary.adding(word, to: settings.vocabularyHint)
    }

    /// The debug snapshots run outside the sandbox: they must never write to the real data folder.
    static var snapshotMode: Bool { ProcessInfo.processInfo.environment["OBERTON_SNAPSHOT"] != nil }

    #if DEBUG
    /// Snapshot mode only: made-up counts so the Analytics charts aren't empty. Kept in memory, never saved.
    func seedSnapshotData() {
        guard Self.snapshotMode else { return }
        let cal = Calendar.current, now = Date()
        var log = UsageLog(), tally = WordTally()
        let apps = ["Mail", "Slack", "Notes", "Safari", "Xcode"]
        let profiles = ["Light Cleanup", "Formal", "Raw", "Bullet notes"]
        let samples: [(String, String)] = [
            ("um so the overton release goes out on friday", "The Oberton release goes out on Friday."),
            ("can you go ahead and send the release notes to the team", "Can you go ahead and send the release notes to the team?"),
            ("i think uh we should move the standup to ten", "I think we should move the standup to ten."),
            ("make sure that the cooper netties cluster is up", "Make sure that the Kubernetes cluster is up."),
            ("let's go ahead and merge the pull request you know after review", "Let's go ahead and merge the pull request after review."),
            ("the quarterly report is basically done", "The quarterly report is done."),
            ("ping jessica about the design review tomorrow", "Ping Jessica about the design review tomorrow."),
            ("make sure that the swift ui preview builds", "Make sure that the SwiftUI preview builds."),
        ]
        var rng = SystemRandomNumberGenerator()
        for back in 0..<120 {
            let day = cal.date(byAdding: .day, value: -back, to: now)!
            let weekend = UsageLog.weekdayRow(day) >= 5
            let n = back == 0 ? 6 : Int.random(in: weekend ? 0...3 : 2...11, using: &rng)
            for k in 0..<n {
                let hour = [8, 9, 9, 10, 11, 13, 14, 14, 15, 16, 17, 21][Int.random(in: 0..<12, using: &rng)]
                let time = cal.date(bySettingHour: hour, minute: k % 60, second: 0, of: day)!
                let (heard, edit) = samples.randomElement(using: &rng)!
                let profile = profiles[Int.random(in: 0..<(k % 3 == 0 ? 4 : 2), using: &rng)]
                let raw = profile == "Raw"
                let rejected = !raw && Int.random(in: 0..<12, using: &rng) == 0
                var e = HistoryEntry(transcription: heard, aiEdit: raw ? nil : rejected ? heard : edit, inserted: raw || rejected ? heard : edit,
                                     profileName: profile, model: nil, appName: apps[min(Int.random(in: 0..<7, using: &rng), 4)],
                                     seconds: Double.random(in: 3...9, using: &rng), turnaroundSeconds: Double.random(in: 0.6...2.2, using: &rng),
                                     warning: rejected ? "Safety net" : nil)
                e.date = time
                log.recordDictation(words: e.words * 6, seconds: e.seconds * 5, turnaround: e.turnaroundSeconds, usedAI: !raw, keptAI: !raw && !rejected,
                                    app: e.appName, on: time)
                tally.record(e, now: now)
            }
            if Int.random(in: 0..<3, using: &rng) > 0 {
                log.recordReading(words: Int.random(in: 80...900, using: &rng), seconds: Double.random(in: 30...300, using: &rng), on: day)
            }
        }
        usage = log
        words = tally
    }
    #endif

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

extension AppModel.Phase {
    var label: String {
        switch self {
        case .idle: "Ready"
        case .starting: "Starting…"
        case .recording: "Listening"
        case .transcribing: "Transcribing…"
        case .processing: "Tidying up…"
        case .preview: "Preview"
        case .inserting: "Inserting…"
        case .done(let s): s
        case .failed(let s): s
        }
    }
}
