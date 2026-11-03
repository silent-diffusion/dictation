import Combine
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
    /// Nothing to type into had the cursor when the dictation started: the text waits for a click (Windows: Placing).
    var nowhereToPaste: Bool { get }
    /// Wait for the user to pick somewhere to type, up to `timeout`; true when there is a target now.
    func waitForPlace(timeout: Duration) async -> Bool
    /// Put the text on the clipboard (no restore).
    func copy(_ text: String)
}

extension PlatformServices {
    var nowhereToPaste: Bool { false }
    func waitForPlace(timeout: Duration) async -> Bool { false }
    func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// The dictation state machine, shared by the Mac and iPhone apps: Idle → Recording → Transcribing → Processing →
/// [Preview] → Inserting, as in the Windows `DictationController`.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle, starting, recording, transcribing, processing, preview, inserting
        /// Nothing to type into had the cursor: waiting for a click into another app, or COPY TO CLIPBOARD.
        case placing
        case done(String)
        case failed(String)

        var isBusy: Bool {
            switch self { case .idle, .done, .failed: false; default: true }
        }
    }

    @Published var settings: AppSettings {
        didSet {
            settingsFile.save(settings)
            // A new profile or language: get its models ready now, so the next dictation doesn't wait (as on Windows).
            if oldValue.activeProfileID != settings.activeProfileID || oldValue.language != settings.language { warmUp() }
        }
    }
    @Published var profiles: [Profile] { didSet { profilesFile.save(profiles) } }
    @Published private(set) var history: [HistoryEntry]
    /// A dictation pauses Extended Notes while it runs (both would hear the same voice).
    @Published private(set) var phase: Phase = .idle {
        didSet {
            notes.setDictating(phase.isBusy)
            // A new dictation state takes the pill from a notice, as on Windows.
            if phase != oldValue, phase.isBusy { overlayNotice = nil }
        }
    }
    @Published private(set) var liveText = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var startedAt: Date?
    /// The dictation waiting in the preview (profiles with "preview before inserting").
    @Published private(set) var pending: HistoryEntry?
    /// The text waiting for a place to go while `phase == .placing`.
    @Published private(set) var placingText: String?
    @Published var ollamaModels: [String] = []
    @Published private(set) var usage: UsageLog
    /// The Analytics word tally (words.json): counts only, never sentences.
    @Published private(set) var words: WordTally
    /// The last dictation that went in, for the overlay's receipt (shown when the pill is clicked).
    @Published var receipt: HistoryEntry?
    /// The cycle-profile hotkey was just pressed: the overlay shows which profile is on now, for 1.5 s.
    @Published private(set) var profileNotice = false
    /// The message the overlay shows now (Windows' `ShowMessage`): the silent microphone, the length limit, an AI
    /// problem, a hotkey that couldn't be registered. Set through `notice(_:kind:)`.
    @Published private(set) var overlayNotice: OverlayNotice?
    /// The speech model is still loading while recording goes on (it catches up on what was said).
    @Published private(set) var speechLoading = false
    /// Settings › Speech recognition's status line ("Speech: Ready · …"), and whether it is a good one.
    @Published private(set) var speechStatus = "Speech: starting…"
    @Published private(set) var speechOK = false
    /// The speech engine couldn't start at launch: shown once in the main window, as Windows' message box.
    @Published var startupProblem: String?

    let reader = ReadAloudPlayer()
    /// Extended Notes: the sessions on disk (notes/), and the one recording now.
    let notes: NotesRecorder
    weak var platform: PlatformServices?

    private let settingsFile = JSONFile<AppSettings>("settings.json")
    private let profilesFile = JSONFile<[Profile]>("profiles.json")
    /// History on disk: history/<entry>/entry.json and audio.wav (in a scratch folder for the debug snapshots).
    private let historyStore: HistoryStore
    /// The recording of the dictation running now, for History's audio.wav.
    private let historyAudio = HistoryAudioRecorder()
    private var historyPrune: Timer?
    private let usageFile = JSONFile<UsageLog>("usage.json")
    private let wordsFile = JSONFile<WordTally>("words.json")
    private let transcriber = LiveTranscriber()
    private var work: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var placeTask: Task<Void, Never>?
    private var placingEntry: HistoryEntry?
    private var overlayNoticeTask: Task<Void, Never>?
    private var limitTimer: Timer?
    /// When the recording stopped (the pill's "N S OF AUDIO").
    private(set) var stoppedAt: Date?
    /// Loads the speech model if needed, then hands the recognizer what was recorded so far.
    private var engineTask: Task<Void, Error>?
    private var warmTask: Task<Void, Never>?
    // For the turnaround: which models this dictation used, and whether they were loaded when it started.
    private var speechModelUsed = "", aiModelUsed = ""
    private var speechWarm = true
    private var aiWarm: Task<Bool, Never>?
    /// A previewed dictation's turnaround, taken when the preview showed (reading it isn't processing time).
    private var previewTurnaround: Double?
    /// The text waited for a click (nowhere to type): its turnaround isn't a fair one.
    private var placed = false
    private var notesChange: AnyCancellable?

    init() {
        let loadedSettings = settingsFile.load() ?? AppSettings()
        historyStore = Self.snapshotMode
            ? HistoryStore(dir: FileManager.default.temporaryDirectory.appending(path: "oberton-snapshot-history-\(UUID().uuidString)"))
            : HistoryStore(dir: HistoryStore.defaultDir, legacyFile: AppPaths.dataDir.appending(path: "history.json"))
        historyStore.prune(loadedSettings)
        let history = historyStore.entries
        settings = loadedSettings
        let notesStore = NotesStore(dir: Self.snapshotMode ? nil : NotesStore.defaultDir)
        // The dashboard notepad became Extended Notes' draft (notes/draft.txt): moved there once.
        let movesNotepad = !Self.snapshotMode && !loadedSettings.notepad.isEmpty
        if movesNotepad && notesStore.draft.isEmpty { notesStore.setDraft(loadedSettings.notepad) }
        notes = NotesRecorder(store: notesStore, settings: { loadedSettings })
        profiles = profilesFile.load() ?? BuiltInProfiles.create()
        self.history = history
        if let loaded = usageFile.load() {
            usage = loaded
        } else {
            // The first time: count what History already has, so the dashboard doesn't start from zero.
            let seeded = UsageLog(seed: history)
            usage = seeded
            if !Self.snapshotMode { usageFile.save(seeded) }
        }
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
        if settingsFile.load() == nil {
            // A new install starts on Grammar & Clarity (as on Windows since 5.18), or on Raw on a device without Apple
            // Intelligence rather than failing every dictation. Existing installs keep their own.
            settings.activeProfileID = AppleIntelligenceBackend.unavailableReason != nil && settings.defaultModel == .appleOnDevice
                ? BuiltInProfiles.rawID
                : profiles.first { $0.name == BuiltInProfiles.defaultName }?.id
        }
        if movesNotepad { settings.notepad = "" }
        notes.settingsSource = { [weak self] in self?.settings ?? loadedSettings }
        notesChange = notes.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        transcriber.onText = { [weak self] in self?.liveText = $0 }
        transcriber.onLevel = { [weak self] in self?.level = $0 }
        transcriber.onSilence = { [weak self] in
            guard self?.phase == .recording else { return }
            #if os(macOS)
            self?.notify("The microphone is silent. Check System Settings › Privacy & Security › Microphone or pick another mic.", level: .warning)
            #else
            self?.notify("The microphone is silent. Check Settings › Privacy & Security › Microphone or pick another mic.", level: .warning)
            #endif
        }
        transcriber.onAudio = { [historyAudio] in historyAudio.append($0) }
        // Kept by age: what has grown too old goes even when nothing new comes in.
        historyPrune = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneHistory() }
        }
        reader.onFinishedReading = { [weak self] words, seconds in
            guard let self else { return }
            self.usage.recordReading(words: words, seconds: seconds)
            self.usageFile.save(self.usage)
        }
        // Warm both models in the background so the first hotkey press is quick.
        if !Self.snapshotMode { Task { @MainActor [weak self] in self?.warmUp(atLaunch: true) } }
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
        case .placing: copyPlacingToClipboard()
        default: break // already working on it; Cancel stops it
        }
    }

    func start() {
        reader.stop()
        platform?.captureTarget()
        liveText = ""
        pending = nil
        receipt = nil
        historyAudio.begin()
        previewTurnaround = nil
        placed = false
        let profile = activeProfile
        // Were the models already loaded? A turnaround that includes loading one isn't a fair turnaround.
        speechModelUsed = speechModelName
        speechWarm = LiveTranscriber.modelRetained
        aiModelUsed = aiModelName(profile)
        let aiID = processor.model(for: profile), endpoint = settings.ollamaEndpoint
        aiWarm = profile.isRaw ? nil : Task { await Self.aiLoaded(aiID, endpoint: endpoint) }

        // Start listening right away. If the speech model isn't loaded (first use, or let go after a while), it loads
        // meanwhile and catches up on what was said.
        do { try transcriber.startRecording(microphone: settings.microphoneName, evenOut: settings.evenOutVolume) } catch { fail(error); return }
        startedAt = Date()
        phase = .recording
        speechLoading = !speechWarm
        let vocabulary = settings.vocabularyHint.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let locale = Locale(identifier: settings.language)
        let engine = Task { [transcriber] in try await transcriber.startRecognizer(locale: locale, vocabulary: vocabulary) }
        engineTask = engine
        Task { [weak self] in
            // The engine failed to start while the user was still speaking: say so now, not at the end.
            do { try await engine.value; self?.speechReady() } catch {
                if let self, self.engineTask == engine, self.phase == .recording { await self.transcriber.cancel(); self.fail(error) }
            }
            if self?.engineTask == engine { self?.speechLoading = false }
        }
        // The AI model too, so the cleanup at the end doesn't wait for it to load.
        warmUpAI(profile)
        limitTimer = Timer.scheduledTimer(withTimeInterval: max(10, settings.maxRecordingSeconds), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.notify("Maximum recording length reached; finishing up.", level: .info)
                self.stop()
            }
        }
    }

    func stop() {
        guard phase == .recording else { return }
        limitTimer?.invalidate()
        transcriber.stopRecording()
        stoppedAt = Date()
        let seconds = (stoppedAt ?? Date()).timeIntervalSince(startedAt ?? Date())
        phase = .transcribing
        level = 0
        let engine = engineTask
        work = Task {
            // If the model was still loading, it now catches up on the whole recording.
            do { try await engine?.value } catch {
                await transcriber.cancel()
                if !Task.isCancelled { fail(error) }
                return
            }
            let peak = transcriber.peak
            let raw = NotesFormat.collapseRepeats(OutputSanitizer.collapseDots(await transcriber.stop()))
            if Task.isCancelled { return }
            // No phantom text: silence, a click or a stock phrase the recognizer made up inserts nothing.
            if SpeechGuard.shouldDiscard(raw, recorded: seconds, peakLevel: peak) {
                phase = .idle
                notice("I didn't catch anything. Try again.")
                return
            }
            await finish(raw: raw, seconds: seconds, profile: activeProfile)
        }
    }

    func cancel() {
        if phase == .placing, let entry = placingEntry {
            endPlacing()
            record(entry) // discarded, but kept in History in case
        }
        limitTimer?.invalidate()
        work?.cancel()
        engineTask = nil
        speechLoading = false
        pending = nil
        Task { await transcriber.cancel() }
        level = 0
        phase = .idle
    }

    private func finish(raw: String, seconds: Double, profile: Profile) async {
        var result = ProcessResult(text: raw, modified: false)
        if !profile.isRaw {
            liveText = raw // the overlay shows what is being tidied
            phase = .processing
            result = await processor.process(raw, profile: profile)
            if Task.isCancelled { return }
        }
        // An AI edit only when the AI really changed the text: not when it failed, nor when the safety net kept it all.
        var entry = HistoryEntry(transcription: raw, aiEdit: result.modified ? result.text : nil, inserted: result.text,
                                 profileName: profile.name, model: profile.isRaw ? nil : processor.model(for: profile).description,
                                 appName: platform?.targetAppName, seconds: seconds, turnaroundSeconds: 0, warning: result.warning,
                                 safetyNet: result.safetyNet)
        entry.date = startedAt ?? entry.date
        if profile.showPreview {
            previewTurnaround = Date().timeIntervalSince(stoppedAt ?? Date()) // time spent reading the preview isn't processing time
            pending = entry
            phase = .preview
            return
        }
        await insert(entry, readBack: profile.readAloudAfterInsert ? profile.voice : nil, readBackRequested: profile.readAloudAfterInsert)
    }

    /// Insert the previewed text (`useOriginal`: the raw transcription instead).
    func confirmPreview(useOriginal: Bool = false) {
        guard var entry = pending else { return }
        if useOriginal {
            entry.inserted = entry.transcription
            entry.aiEdit = nil // the original words, not the AI's
        }
        pending = nil
        let profile = activeProfile
        work = Task { await insert(entry, readBack: profile.voice, readBackRequested: profile.readAloudAfterInsert) }
    }

    private func insert(_ entry: HistoryEntry, readBack voice: String?, readBackRequested: Bool) async {
        // Nothing had the cursor when the dictation started: ask where it should go instead of pasting into nowhere.
        if platform?.nowhereToPaste == true {
            waitForPlace(entry, readBack: voice, readBackRequested: readBackRequested)
            return
        }
        var entry = entry
        phase = .inserting
        do {
            let receipt = try await platform?.insert(entry.inserted) ?? "Done"
            // The turnaround runs from the stop press until the text is in place.
            entry.turnaroundSeconds = previewTurnaround ?? Date().timeIntervalSince(stoppedAt ?? Date())
            await recordTurnaround(entry)
            record(entry)
            self.receipt = entry
            phase = .done(entry.warning ?? receipt)
            if readBackRequested { reader.read(entry.inserted, voice: voice ?? settings.ttsVoice, speed: settings.ttsBaseSpeed) }
        } catch {
            entry.turnaroundSeconds = previewTurnaround ?? Date().timeIntervalSince(stoppedAt ?? Date())
            entry.wasInserted = false
            record(entry)
            fail(error)
            return
        }
        // The receipt stays 3 s, or 6 s when it has a warning to read (as on Windows).
        scheduleIdle(after: entry.warning == nil ? 3 : 6)
    }

    // MARK: Nowhere to type: wait for a click, or copy

    private func waitForPlace(_ entry: HistoryEntry, readBack voice: String?, readBackRequested: Bool) {
        // Waiting for the user isn't processing time.
        if previewTurnaround == nil { previewTurnaround = Date().timeIntervalSince(stoppedAt ?? Date()) }
        placed = true
        var entry = entry
        entry.turnaroundSeconds = previewTurnaround ?? 0
        placingEntry = entry
        placingText = entry.inserted
        phase = .placing
        placeTask?.cancel()
        placeTask = Task {
            // How long the text waits for a click before it is copied to the clipboard instead (as on Windows).
            let found = await platform?.waitForPlace(timeout: .seconds(120)) ?? false
            guard !Task.isCancelled, phase == .placing else { return }
            if found {
                endPlacing()
                await insert(entry, readBack: voice, readBackRequested: readBackRequested)
            } else {
                copyPlacingToClipboard(timedOut: true)
            }
        }
    }

    /// Placing: the overlay's Copy button or the hotkey (or the wait ran out): the text goes to the clipboard.
    func copyPlacingToClipboard(timedOut: Bool = false) {
        guard phase == .placing, let entry = placingEntry else { return }
        endPlacing()
        platform?.copy(entry.inserted)
        record(entry)
        receipt = nil
        phase = .idle
        notice(timedOut ? "No place to paste was chosen, so the text was copied to your clipboard."
                        : "Copied to your clipboard. Paste it wherever you like.")
    }

    private func endPlacing() {
        placeTask?.cancel()
        placeTask = nil
        placingEntry = nil
        placingText = nil
    }

    /// As on Windows: back to idle, and the error as the overlay's SOMETHING WENT WRONG notice.
    private func fail(_ error: Error) {
        level = 0
        phase = .idle
        notice(error.localizedDescription, kind: .error)
    }

    // MARK: Notices

    enum NoticeKind { case info, warning, error }

    struct OverlayNotice: Equatable {
        var text: String
        var kind: NoticeKind
        let id = UUID()
    }

    /// A message on the overlay (Windows' `ShowMessage`): OBERTON (info), HEADS UP (warning) or SOMETHING WENT WRONG
    /// (error), with `text` as the body. It stays for its length / 15 seconds, between 3 and 9. Info is skipped while
    /// a dictation is under way. Shown even with "Show overlay" off, as on Windows.
    func notice(_ text: String, kind: NoticeKind = .info) {
        if kind == .info, phase.isBusy { return }
        let notice = OverlayNotice(text: text, kind: kind)
        overlayNotice = notice
        overlayNoticeTask?.cancel()
        overlayNoticeTask = Task {
            try? await Task.sleep(for: .seconds(Self.noticeSeconds(text)))
            if !Task.isCancelled, overlayNotice?.id == notice.id { overlayNotice = nil }
        }
    }

    static func noticeSeconds(_ text: String) -> Double { min(9, max(3, Double(text.count) / 15)) }

    /// The dictation engine's name for `notice(_:kind:)`.
    func notify(_ text: String, level: NoticeKind) { notice(text, kind: level) }

    private func scheduleIdle(after seconds: Double = 2.5) {
        let current = phase
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled, phase == current { phase = .idle }
        }
    }

    /// The pointer is on the receipt: it stays until the pointer leaves, then goes after `seconds`.
    func holdReceipt(_ hold: Bool, release seconds: Double = 2) {
        guard case .done = phase else { return }
        if hold { idleTask?.cancel() } else { scheduleIdle(after: seconds) }
    }

    /// The receipt's ✕.
    func dismissReceipt() {
        guard case .done = phase else { return }
        idleTask?.cancel()
        phase = .idle
    }

    func cycleProfile() {
        guard let i = profiles.firstIndex(where: { $0.id == activeProfile.id }), !profiles.isEmpty else { return }
        activeProfile = profiles[(i + 1) % profiles.count]
        // Mid-dictation the pill's chip already shows the profile; otherwise the notice takes the receipt's place.
        guard !phase.isBusy else { return }
        idleTask?.cancel()
        phase = .idle
        profileNotice = true
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { profileNotice = false }
        }
    }

    // MARK: Warming up

    /// The speech model's name for the turnaround samples: Apple's recognizer and the language.
    var speechModelName: String { "apple-speech:" + settings.language }

    /// The AI model a profile uses, or "" without AI.
    func aiModelName(_ profile: Profile) -> String { profile.isRaw ? "" : processor.model(for: profile).description }

    /// The average of the last three turnarounds with the active profile's models, where neither had to load first.
    var recentTurnaround: Double? {
        usage.recentTurnaround(speechModel: speechModelName, aiModel: aiModelName(activeProfile)).seconds
    }

    /// Get the speech model and the active profile's AI model loaded (at launch, and when the profile or language
    /// changes), as Windows does. A speech model that can't start at launch is reported once (`startupProblem`).
    func warmUp(atLaunch: Bool = false) {
        guard !Self.snapshotMode else { return }
        let locale = Locale(identifier: settings.language)
        warmTask?.cancel()
        warmTask = Task {
            speechStatus = "Speech: loading the speech model (\(languageName))…"
            speechOK = false
            do {
                try await LiveTranscriber.warmUp(locale: locale)
                if Task.isCancelled { return }
                speechReady()
            } catch {
                if Task.isCancelled { return }
                speechStatus = "Speech: " + error.localizedDescription
                if atLaunch { startupProblem = error.localizedDescription }
            }
        }
        warmUpAI(activeProfile)
    }

    private var languageName: String { Locale.current.localizedString(forIdentifier: settings.language) ?? settings.language }

    private func speechReady() {
        speechStatus = "Speech: Ready · Apple Speech · \(languageName)"
        speechOK = true
        objectWillChange.send() // the dashboard's speech dial
    }

    /// Load a profile's AI model without generating anything: Apple Intelligence's prewarm, or an empty Ollama request.
    /// Cloud models have nothing to load.
    private func warmUpAI(_ profile: Profile) {
        guard !profile.isRaw else { return }
        let id = processor.model(for: profile)
        switch id.provider {
        case .apple:
            AppleIntelligenceBackend.warmUp()
        case .ollama:
            guard !id.isOllamaCloud, // runs on ollama.com: nothing to load here
                  let url = try? OllamaBackend.validated(settings.ollamaEndpoint) else { return }
            Task { await OllamaBackend.warmUp(endpoint: url, model: id.name) }
        case .anthropic, .openai:
            break
        }
    }

    /// Whether the AI model is in memory right now (Apple Intelligence and cloud models: nothing to load, or no way to tell).
    private static func aiLoaded(_ id: ModelID, endpoint: String) async -> Bool {
        guard id.provider == .ollama, !id.isOllamaCloud, let url = try? OllamaBackend.validated(endpoint) else { return true }
        return await OllamaBackend.isLoaded(endpoint: url, model: id.name)
    }

    // MARK: History

    var lastEntry: HistoryEntry? { history.first }

    /// The dashboard's turnaround: only a dictation that went straight in counts (not one that waited for a click),
    /// noting whether a model had to load first. Saved with the dictation's counts (`record`).
    private func recordTurnaround(_ entry: HistoryEntry) async {
        guard !placed, entry.turnaroundSeconds > 0 else { return }
        let aiWasWarm = await aiWarm?.value ?? true
        usage.recordTurnaround(TurnaroundSample(speechModel: speechModelUsed, aiModel: aiModelUsed, seconds: entry.turnaroundSeconds,
                                                modelLoaded: !speechWarm || !aiWasWarm))
    }

    private func record(_ entry: HistoryEntry) {
        // The daily counts are kept whether or not History is.
        usage.record(entry)
        usageFile.save(usage)
        if settings.keepWordTally {
            words.record(entry)
            wordsFile.save(words)
        }
        let pcm = historyAudio.finish()
        guard settings.keepHistory else { return }
        historyStore.add(entry, pcm: settings.saveHistoryAudio ? pcm : nil)
        pruneHistory()
    }

    func deleteHistory(_ ids: Set<HistoryEntry.ID>) {
        historyStore.delete(ids)
        history = historyStore.entries
    }

    /// Apply what Settings › History keeps now (also right after it is lowered, and every hour).
    func pruneHistory() {
        historyStore.prune(settings)
        history = historyStore.entries
    }

    /// How many dictations keeping the newest `limit` or the last `days` days would delete right away.
    func historyWouldDelete(limit: Int, days: Int) -> Int { historyStore.wouldDelete(limit: limit, days: days) }

    /// Bytes History takes on disk, texts and recordings.
    var historySizeBytes: Int64 { historyStore.sizeBytes }

    var historyFolder: URL { historyStore.dir ?? HistoryStore.defaultDir }

    /// History › Run again: transcribe the recording afresh and clean it up again; returns what to say (✓ or ⚠).
    func rerunHistory(_ id: HistoryEntry.ID, progress: @escaping @MainActor (String) -> Void) async -> String {
        guard let entry = history.first(where: { $0.id == id }) else { return "" }
        do {
            let (changed, message) = try await HistoryRerun.run(entry, profiles: profiles, active: activeProfile, settings: settings,
                                                                progress: progress)
            historyStore.save(changed)
            history = historyStore.entries
            return "✓ " + message
        } catch {
            return "⚠ " + ((error as? UserFacingError)?.message ?? "Running it again failed; the dictation was left as it was. (\(error.localizedDescription))")
        }
    }

    /// History's USE THE RERUN / PUT BACK THE EARLIER RESULT.
    func swapHistoryEarlier(_ id: HistoryEntry.ID) -> String {
        guard let entry = history.first(where: { $0.id == id }) else { return "" }
        let swapped = HistoryRerun.swapEarlier(entry)
        historyStore.save(swapped)
        history = historyStore.entries
        return swapped.showingEarlier == true ? "Put back the result from before it was run again." : "Back to the rerun's result."
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
        for t in [1.3, 0.9, 1.1] {
            log.recordTurnaround(TurnaroundSample(speechModel: speechModelName, aiModel: aiModelName(activeProfile), seconds: t, modelLoaded: false))
        }
        usage = log
        words = tally
        speechReady() // the Speech recognition page's status line
        seedSnapshotNotes()
        seedSnapshotHistory()
    }

    /// Snapshot mode only: a few dictations in the scratch history folder, one with a recording and a rerun.
    private func seedSnapshotHistory() {
        let now = Date()
        func entry(_ heard: String, _ edit: String?, app: String?, minutesAgo: Double, safetyNet: Bool = false, inserted: Bool = true) -> HistoryEntry {
            var e = HistoryEntry(transcription: heard, aiEdit: edit, inserted: safetyNet ? heard : edit ?? heard, profileName: edit == nil ? "Raw" : "Light Cleanup",
                                 model: nil, appName: app, seconds: 40, turnaroundSeconds: 1.1,
                                 warning: safetyNet ? "The AI's edit failed the safety net, so your original words were inserted unchanged." : nil,
                                 safetyNet: safetyNet, wasInserted: inserted)
            e.date = now.addingTimeInterval(-minutesAgo * 60)
            return e
        }
        let tone = Data((0..<(16000 * 40)).flatMap { i -> [UInt8] in
            let v = Int16(3000 * sin(Double(i) * 2 * .pi * 220 / 16000))
            return [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
        })
        historyStore.add(entry("i think uh we should move the standup to ten", nil, app: "Notes", minutesAgo: 300), pcm: nil)
        historyStore.add(entry("ping jessica about the design review tomorrow", "Ping Jessica about the design review tomorrow.", app: "Slack",
                               minutesAgo: 200, safetyNet: true), pcm: tone)
        historyStore.add(entry("can you go ahead and send the release notes to the team", "Can you go ahead and send the release notes to the team?",
                               app: "Safari", minutesAgo: 90, inserted: false), pcm: tone)
        var rerun = entry("um so the overton release goes out on friday", "So the Overton release goes out on Friday.", app: "Mail", minutesAgo: 12)
        rerun.earlier = HistoryVersion(transcription: rerun.transcription, aiEdit: rerun.aiEdit, inserted: rerun.inserted, safetyNet: false,
                                       warning: nil, profileName: rerun.profileName, wasInserted: true)
        rerun.transcription = "um so the oberton release goes out on friday"
        rerun.aiEdit = "The Oberton release goes out on Friday."
        rerun.inserted = rerun.aiEdit!
        rerun.wasInserted = false
        rerun.runAgainAt = now.addingTimeInterval(-60)
        historyStore.add(rerun, pcm: tone)
        history = historyStore.entries
    }

    /// Snapshot mode only: two finished Extended Notes sessions, in memory.
    private func seedSnapshotNotes() {
        let cal = Calendar.current, now = Date()
        let lecture = NoteSession()
        lecture.title = "Product sync // weekly"
        lecture.started = cal.date(byAdding: .hour, value: -3, to: now)!
        lecture.source = .both
        lecture.folder = FileManager.default.temporaryDirectory.appending(path: "20261102-1015")
        lecture.set(.transcript, "Agenda: beta dates, budget\n", source: nil)
        lecture.appendHeard("okay so um let's start with the beta the overton beta goes out to the first ten testers on friday", seconds: 4)
        lecture.appendHeard("and then we collect feedback for two weeks before the wider release", seconds: 11)
        lecture.addMarker(19)
        lecture.appendHeard("on the budget side the numbers are final we have 1550 for the design work", seconds: 22)
        let first = lecture.beginFormat()!
        lecture.endFormat(heard: first.heard, sent: first.sent,
                          ai: "Agenda: beta dates, budget\nLet's start with the beta. The Oberton beta goes out to the first ten testers on Friday, and then we collect feedback for two weeks before the wider release.\n⚑ 0:19\n\nOn the budget side, the numbers are final: we have 1550 for the design work.",
                          seconds: first.seconds, failed: false)
        lecture.set(.formatted, lecture.formatted.replacingOccurrences(of: "the numbers are final", with: "the numbers are now final"), source: nil)
        lecture.appendHeard("next week we look at the onboarding flow again", seconds: 31)
        lecture.digests = [NoteDigest(level: 0, first: 0, last: 0, start: 0, end: 30, text: "The beta goes to ten testers on Friday; two weeks of feedback follow. The design budget is final at 1550.")]
        lecture.summary = "Main idea: The Oberton beta ships to ten testers on Friday.\n\n- Two weeks of feedback before the wider release\n- The design budget is final at 1550\n- Onboarding is reviewed next week\n\nThe team agreed the dates and the budget; the onboarding flow comes up again next week."
        lecture.summaryByAi = lecture.summary
        lecture.seconds = 2843
        lecture.finished = true
        let call = NoteSession()
        call.title = "Lecture // Signals and systems"
        call.started = cal.date(byAdding: .day, value: -2, to: now)!
        call.source = .mic
        call.folder = FileManager.default.temporaryDirectory.appending(path: "20261031-0900")
        call.appendHeard("today we look at the fourier transform and why it matters for sampling", seconds: 3)
        call.seconds = 4920
        call.finished = true
        for s in [lecture, call] {
            notes.store.add(s)
            notes.store.usage.record(s, formatRequests: 14, summaryRequests: 5)
        }
    }
    #endif

    func clearHistory() {
        historyStore.clear()
        history = historyStore.entries
    }

    // MARK: Read aloud

    /// The read-aloud hotkey: read the selection; with nothing selected, offer the clipboard. Pressed again (while
    /// reading or asking), it stops.
    func readSelection() {
        if reader.isShowing { reader.stop(); return }
        Task {
            let voice = activeProfile.voice ?? settings.ttsVoice
            if let text = await platform?.selectedText(), OutputSanitizer.hasContent(text) {
                reader.read(text, voice: voice, speed: settings.ttsBaseSpeed)
            } else if let clipboard = platform?.clipboardText(), OutputSanitizer.hasContent(clipboard) {
                reader.askToReadClipboard(clipboard, voice: voice, speed: settings.ttsBaseSpeed)
            } else {
                readerNotice("Select some text, then press \(settings.speakHotkey) to hear it read aloud.")
            }
        }
    }

    /// An info notice for Read aloud, on the overlay (App.OnSpeakHotkey).
    private func readerNotice(_ text: String) {
        notice(text)
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

    // MARK: Unloading

    /// The speech model is in memory: used since it was last let go (the system keeps it a while after each use).
    var speechLoaded: Bool { LiveTranscriber.modelRetained }

    /// Unload models right now, on request (the dashboard's speech dial), as App.UnloadNowAsync does on Windows. Never
    /// while a dictation or a reading is using them. Returns what happened, for display.
    func unloadNow(speech: Bool, ai: Bool, voice: Bool) async -> String {
        var done: [String] = [], skipped: [String] = []
        if speech {
            if notes.needsModels { skipped.append("the speech model (Extended Notes is using it)") }
            else if phase.isBusy { skipped.append("the speech model (dictating)") }
            else if speechLoaded {
                await LiveTranscriber.unloadModel()
                done.append("speech model")
                speechStatus = "Speech: Unloaded · loads again when you dictate"
                speechOK = false
            }
        }
        if ai {
            // Apple Intelligence keeps no session between requests here; Ollama keeps its models loaded until told.
            if notes.needsModels { skipped.append("the AI model (Extended Notes is using it)") }
            else if phase.isBusy { skipped.append("the AI model (dictating)") }
            else if let url = try? OllamaBackend.validated(settings.ollamaEndpoint), await OllamaBackend.unloadAll(endpoint: url) > 0 {
                done.append("AI model")
            }
        }
        if voice {
            if reader.isSpeaking { skipped.append("the Read aloud voice (reading)") }
            else if reader.isLoaded { reader.unload(); done.append("Read aloud voice") }
        }
        var msg = !done.isEmpty ? "Unloaded: " + done.joined(separator: ", ") + ". They load again when needed."
            : skipped.isEmpty ? "Nothing was loaded." : ""
        if !skipped.isEmpty { msg = (msg + " Kept " + skipped.joined(separator: " and ") + ".").trimmingCharacters(in: .whitespaces) }
        objectWillChange.send() // the speech dial now reads "off"
        return msg
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
        case .placing: "No place to paste"
        case .done(let s): s
        case .failed(let s): s
        }
    }
}
