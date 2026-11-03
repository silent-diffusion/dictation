import Combine
import Foundation
import ObertonCore
import SwiftUI

/// What each platform does differently: where the text goes and where read-aloud text comes from.
@MainActor
protocol PlatformServices: AnyObject {
    /// Remember where the user was when they pressed the hotkey, so the text goes back there.
    func captureTarget()
    /// `captureTarget`, and with `readContext` the text around the cursor too ("Fit dictation into the surrounding
    /// text"; only where Accessibility may read it, the Mac's direct build).
    func captureTarget(readContext: Bool)
    /// The text around the cursor, read when the dictation started; nil when unknown.
    func insertionContext() async -> InsertionContext?
    /// "Type as you speak": the place this dictation types into while the user speaks; nil where that isn't possible
    /// (the iPhone) or when there was nowhere to type.
    func liveTarget() -> LiveTarget?
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
    var nowhereToPaste: Bool { get async }
    /// Wait for the user to pick somewhere to type, up to `timeout`; true when there is a target now.
    func waitForPlace(timeout: Duration) async -> Bool
    /// Put the text on the clipboard (no restore).
    func copy(_ text: String)
}

extension PlatformServices {
    func captureTarget(readContext: Bool) { captureTarget() }
    func insertionContext() async -> InsertionContext? { nil }
    func liveTarget() -> LiveTarget? { nil }
    var nowhereToPaste: Bool { false }
    /// The text left on the clipboard as a last resort, when it couldn't go in: an ordinary copy, so clipboard managers
    /// keep it too.
    func leaveOnClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
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
            // A new language or speech model: get it ready now, so the next dictation doesn't wait (as on Windows).
            if oldValue.language != settings.language || oldValue.speechModel != settings.speechModel {
                warmUp()
            } else if oldValue.activeProfileID != settings.activeProfileID {
                // Another profile (App.xaml.cs ActiveChanged): warm its AI model, and swap to its speech model only if
                // one is loaded and nothing is dictating (an unloaded engine stays unloaded).
                warmUpAI(activeProfile)
                swapSpeechModel()
            } else if oldValue.defaultModel != settings.defaultModel {
                warmUpAI(activeProfile) // Settings › Models' USE THIS
            }
        }
    }
    @Published var profiles: [Profile] {
        didSet {
            profilesFile.save(profiles)
            // The active profile's own speech model was changed on its page: load it now if a speech model is in
            // memory and nothing is dictating, as a profile switch does (an unloaded engine stays unloaded).
            let id = settings.activeProfileID
            if settings.speechModel(for: oldValue.first { $0.id == id }) != settings.speechModel(for: activeProfile) {
                swapSpeechModel()
                if !phase.isBusy, speechModelLoaded { speechReady() } // the status line names the profile's model
            }
        }
    }
    @Published private(set) var history: [HistoryEntry]
    /// A dictation pauses Extended Notes while it runs (both would hear the same voice).
    @Published private(set) var phase: Phase = .idle {
        didSet {
            notes.setDictating(phase.isBusy)
            // A new dictation state takes the pill from a notice, as on Windows: from any notice when the overlay shows
            // that state, and from one held by the state before it (`overlayPinned`).
            if phase != oldValue, (overlayPinned && phase.isBusy) || overlayNotice?.pinned == true { overlayNotice = nil }
            if phase != oldValue { lastActivity = .now }
            if phase == .recording { meter.start() } else { meter.stop() }
        }
    }
    /// When a dictation last changed state (Windows' `LastActivity`): the model unloading timer counts from here.
    @Published private(set) var lastActivity = Date()
    /// Settings › Model unloading: unloads idle models (`ModelUnloading.swift`).
    let unloader = ModelUnloader()
    @Published private(set) var liveText = ""
    @Published private(set) var level: Float = 0
    /// The overlay's level meter, running while recording (its own object, so its 20 redraws a second don't redraw
    /// everything that watches the model).
    let meter = LevelMeter()
    @Published private(set) var startedAt: Date?
    /// The dictation waiting in the preview (profiles with "preview before inserting").
    @Published private(set) var pending: HistoryEntry?
    /// The text waiting for a place to go while `phase == .placing`.
    @Published private(set) var placingText: String?
    /// The text around the cursor for the current dictation (read when it started), once known: shown either side of
    /// the AI edit, so the edit can be judged in place (Windows' `DictationController.Context`).
    @Published private(set) var insertionContext: InsertionContext?
    /// Text was typed while speaking, so the cleanup now is the final pass over it (the overlay's FINAL PASS).
    @Published private(set) var finalPass = false
    /// "Type as you speak" for the dictation running now, when it is on (Windows' `_live`).
    private var live: LiveInsertion?
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
    /// The Whisper model downloading now (Settings › Speech recognition and Models), how far it got (nil while
    /// unknown), and the last download's problem.
    @Published private(set) var whisperDownload: (id: String, fraction: Double?)?
    @Published var whisperDownloadError: String?
    /// A Whisper model loading or being prepared now (`WhisperEngine.loadingModel`), for the status line and badges.
    @Published private(set) var whisperLoad: WhisperEngine.Loading?
    private var whisperDownloadTask: Task<Void, Never>?
    /// The Whisper model a new install picked for this device (Windows' RuntimeInstaller.ChooseModels), while it
    /// downloads: until it is in, dictation uses Apple Speech, then it switches over by itself. Kept across launches.
    /// In the data folder (speech-setup.json), next to the settings it belongs with.
    @Published private(set) var pendingSpeechModel: String? = AppModel.speechSetupFile.load()?.model {
        didSet {
            if let model = pendingSpeechModel { Self.speechSetupFile.save(SpeechSetup(model: model)) }
            else { try? FileManager.default.removeItem(at: Self.speechSetupFile.url) }
        }
    }
    private struct SpeechSetup: Codable { var model: String }
    private static let speechSetupFile = JSONFile<SpeechSetup>("speech-setup.json")
    /// The AI status line (Windows' LlmService status: "Starting AI runtime…", "Loading qwen3:8b…", "Ready · …", "AI
    /// model 'x' not installed"), set by the warm-up; `aiStatusOK` is false while loading or when it failed.
    @Published private(set) var aiStatus = "AI: starting…"
    @Published private(set) var aiStatusOK = false
    /// The AI model being loaded by the warm-up right now ("loading, then editing" on the dashboard).
    @Published private(set) var aiLoading: String?
    /// The Ollama models in memory now (`/api/ps`), refreshed every 3 s while someone watches (`watchLoadedAI`).
    @Published private(set) var loadedAIModels: Set<String> = []
    private var loadedAIWatchers = 0
    private var loadedAITimer: Timer?
    private var aiWarmTask: Task<Void, Never>?
    /// The speech engine couldn't start at launch: shown once in the main window, as Windows' message box.
    @Published var startupProblem: String?
    /// A Settings section to open in the main window (⌘,, the menu bar's "Check for updates…"); the window clears it.
    @Published var requestedSettings: SettingsSection?

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
            // The speech model for this device, as Windows' setup picks it: downloaded during setup
            // (`startDefaultSpeechDownload`); Apple Speech until it is in.
            if !Self.snapshotMode { pendingSpeechModel = Self.recommendedSpeechModel(language: settings.language) }
        }
        if movesNotepad { settings.notepad = "" }
        startProfiles()
        // Extended Notes transcribes with the active profile's speech model, as Windows' NotesRecorder (SpeechModels.For).
        notes.settingsSource = { [weak self] in self.map { $0.settings.dictating(with: $0.activeProfile) } ?? loadedSettings }
        notesChange = notes.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        WhisperEngine.onChange = { [weak self] in Task { @MainActor in self?.whisperChanged() } }
        transcriber.onText = { [weak self] in self?.liveText = $0 }
        transcriber.onLevel = { [weak self] level in
            guard let self else { return }
            self.level = level
            if phase == .recording { meter.hear(level) }
        }
        transcriber.onSilence = { [weak self] in
            guard self?.phase == .recording else { return }
            #if os(macOS)
            self?.notify("The microphone is silent. Check System Settings › Privacy & Security › Microphone or pick another mic.", level: .warning)
            #else
            self?.notify("The microphone is silent. Check Settings › Privacy & Security › Microphone or pick another mic.", level: .warning)
            #endif
        }
        transcriber.onAudio = { [historyAudio] in historyAudio.append($0) }
        // Type as you speak: finished pieces are typed in order; the running guess too, for a profile without AI.
        transcriber.onPiece = { [weak self] piece in
            guard let self, self.phase == .recording || self.phase == .transcribing else { return }
            self.live?.add(piece)
        }
        transcriber.onGuess = { [weak self] guess in
            guard let self, self.phase == .recording else { return }
            self.live?.setPartial(guess)
        }
        // Kept by age: what has grown too old goes even when nothing new comes in.
        historyPrune = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneHistory() }
        }
        reader.onFinishedReading = { [weak self] words, seconds in
            guard let self else { return }
            self.usage.recordReading(words: words, seconds: seconds)
            self.usageFile.save(self.usage)
        }
        if !Self.snapshotMode { unloader.start(self) }
        // Warm both models in the background so the first hotkey press is quick.
        if !Self.snapshotMode { Task { @MainActor [weak self] in self?.warmUp(atLaunch: true) } }
        // A first-run speech model download that didn't finish (Oberton quit meanwhile) carries on once setup is done.
        if !Self.snapshotMode, OnboardingView.isDone, pendingSpeechModel != nil {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5)) // after launch's own work
                self?.startDefaultSpeechDownload()
            }
        }
    }

    /// At start, as Windows' ProfileService and SettingsService: built-ins added in later versions show up once, the
    /// default profile (on an update, the profile that was active) is the one active, and the Ollama address must be
    /// local. (Property observers don't run in init, so this saves itself.)
    private func startProfiles() {
        let added = BuiltInProfiles.addMissing(to: &profiles, added: &settings.builtInProfilesAdded)
        if added && !Self.snapshotMode { profilesFile.save(profiles) }
        func find(_ id: String?) -> String? { profiles.first { $0.id == id }?.id }
        settings.defaultProfileID = find(settings.defaultProfileID) ?? find(settings.activeProfileID) ?? profiles.first?.id
        settings.activeProfileID = settings.defaultProfileID
        settings.enforceLocalEndpoint()
        if !Self.snapshotMode { settingsFile.save(settings) }
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

    /// Starting a dictation leaves Read aloud reading, as on Windows (DictationController.StartAsync never touches it).
    func start() {
        platform?.captureTarget(readContext: settings.matchSurroundingText)
        insertionContext = nil
        finalPass = false
        liveText = ""
        pending = nil
        receipt = nil
        historyAudio.begin()
        previewTurnaround = nil
        placed = false
        let profile = activeProfile
        // Were the models already loaded? A turnaround that includes loading one isn't a fair turnaround.
        speechModelUsed = speechModelName
        speechWarm = speechModelLoaded
        aiModelUsed = aiModelName(profile)
        let aiID = processor.model(for: profile), endpoint = settings.ollamaEndpoint
        aiWarm = profile.isRaw ? nil : Task { await Self.aiLoaded(aiID, endpoint: endpoint) }
        // Type as you speak needs the text to go straight in, so it is off for profiles that preview before inserting,
        // and when there is nowhere to type (the text then waits for a click at the end).
        live?.stop()
        live = nil
        if settings.typeWhileSpeaking, !profile.showPreview, let target = platform?.liveTarget() {
            let platform = platform, processor = processor
            live = LiveInsertion(target: target, profile: profile, context: Task { await platform?.insertionContext() },
                                 holdsClipboard: settings.restoreClipboard) { piece in
                // An AI failure gives back the words as spoken (TextProcessor), so they are typed raw.
                await processor.process(piece, profile: profile).text
            }
        }
        let isLive = live != nil

        // Start listening right away. If the speech model isn't loaded (first use, or let go after a while), it loads
        // meanwhile and catches up on what was said.
        do { try transcriber.startRecording(microphone: settings.microphoneName, evenOut: settings.evenOutVolume) } catch { fail(error); return }
        startedAt = Date()
        phase = .recording
        speechLoading = !speechWarm
        let vocabulary = settings.vocabulary, hint = settings.vocabularyHint, locale = settings.speechLocale
        let speech = speechSettings(for: profile)
        let whisper = speech.whisperModel, language = speech.whisperLanguage
        let engine = Task { [transcriber] in
            if let whisper {
                try await transcriber.startWhisper(model: whisper, language: language, prompt: hint, live: isLive)
            } else {
                try await transcriber.startRecognizer(locale: locale, vocabulary: vocabulary, live: isLive)
            }
        }
        engineTask = engine
        Task { [weak self] in
            // The engine failed to start while the user was still speaking: say so now, not at the end.
            do { try await engine.value; self?.speechReady() } catch {
                if let self, self.engineTask == engine, self.phase == .recording { self.transcriber.cancel(); self.fail(error) }
            }
            if self?.engineTask == engine { self?.speechLoading = false }
        }
        // The AI model too, so the cleanup at the end doesn't wait for it to load.
        warmUpAI(profile, forDictation: true)
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
            // Cancelled meanwhile: `cancel()` already let the recording go, and a new one may be running.
            do { try await engine?.value } catch {
                if Task.isCancelled { return }
                transcriber.cancel()
                fail(error)
                return
            }
            if Task.isCancelled { return }
            let peak = transcriber.peak
            let raw = NotesFormat.collapseRepeats(OutputSanitizer.collapseDots(await transcriber.stop()))
            if Task.isCancelled { return }
            insertionContext = await platform?.insertionContext()
            await live?.drain() // let pieces already on their way finish typing
            if Task.isCancelled { return }
            // No phantom text: silence, a click or a stock phrase the recognizer made up inserts nothing (unless text
            // was already typed while speaking).
            if live?.hasTyped != true, SpeechGuard.shouldDiscard(raw, recorded: seconds, peakLevel: peak) {
                live?.stop()
                live = nil
                phase = .idle
                notice("I didn't catch anything. Try again.")
                return
            }
            await finish(raw: raw, seconds: seconds, profile: activeProfile)
        }
    }

    func cancel() {
        if phase == .placing, var entry = placingEntry {
            endPlacing()
            entry.wasInserted = false
            record(entry) // discarded, but kept in History in case
        }
        limitTimer?.invalidate()
        work?.cancel()
        engineTask = nil
        speechLoading = false
        pending = nil
        transcriber.cancel() // now, before the next dictation can start
        if let typed = live {
            // Take back what was typed while speaking (only if it can be confirmed in place).
            live = nil
            if phase != .inserting { Task { await typed.removeTyped() } } else { typed.stop() }
        }
        level = 0
        phase = .idle
    }

    private func finish(raw: String, seconds: Double, profile: Profile) async {
        var result = ProcessResult(text: raw, modified: false)
        aiNotice = nil
        if !profile.isRaw {
            liveText = raw // the overlay shows what is being tidied
            finalPass = live?.hasTyped == true // with live typing, this is the final pass over the whole recording
            phase = .processing
            result = await processor.process(raw, profile: profile)
            if Task.isCancelled { return }
            // A safety-net rejection is reported on the receipt; any other AI problem is a HEADS UP notice of its own,
            // and the original words go in (DictationController.StopAsync).
            if let warning = result.warning, !result.safetyNet {
                Log.warn("AI step failed: " + warning)
                aiNotice = Self.aiFailureNotice(warning)
                result.warning = nil
            }
        }
        // An AI edit only when the AI really changed the text: not when it failed, nor when the safety net kept it all.
        var entry = HistoryEntry(transcription: raw, aiEdit: result.modified ? result.text : nil, inserted: result.text,
                                 profileName: profile.name, model: profile.isRaw ? nil : processor.model(for: profile).description,
                                 appName: platform?.targetAppName, seconds: seconds, turnaroundSeconds: 0, warning: result.warning,
                                 safetyNet: result.safetyNet)
        entry.date = startedAt ?? entry.date
        if profile.showPreview, live?.hasTyped != true { // the profile may have been switched mid-dictation
            previewTurnaround = Date().timeIntervalSince(stoppedAt ?? Date()) // time spent reading the preview isn't processing time
            pending = entry
            phase = .preview
            showAINotice()
            return
        }
        await insert(entry, readBack: profile.readAloudAfterInsert ? profile.voice : nil, readBackRequested: profile.readAloudAfterInsert)
    }

    /// The AI step's problem, said when the text goes in (or the preview shows), so it isn't covered at once by the next
    /// state.
    private var aiNotice: String?

    private func showAINotice() {
        guard let text = aiNotice else { return }
        aiNotice = nil
        // Over the preview it goes after its time and gives the preview back (Windows would leave it covering it).
        notice(text, kind: .warning, hold: false)
    }

    /// A failed AI step, as Windows says it while the words go in: "{problem} Inserting your original words."
    /// (TextProcessor words it so now; older wording is converted, and the sentence is never added twice.)
    static func aiFailureNotice(_ warning: String) -> String {
        let windows = " Inserting your original words."
        if warning.hasSuffix(windows) { return warning }
        let suffix = " Your original words were inserted."
        let problem = warning.hasSuffix(suffix) ? String(warning.dropLast(suffix.count)) : warning
        return problem + windows
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
        if live?.hasTyped != true, await platform?.nowhereToPaste == true {
            waitForPlace(entry, readBack: voice, readBackRequested: readBackRequested)
            return
        }
        var entry = entry
        phase = .inserting
        let typed = live
        live = nil
        // The user's clipboard, back once the last live paste landed (nothing to do if it was never taken, or left).
        defer { if let typed { Task { await typed.releaseClipboard() } } }
        do {
            let receipt: String
            if let typed, typed.hasTyped {
                // Replace what was typed while speaking with the final pass over the whole recording.
                let (final, note) = try await typed.finish(entry.inserted, tail: transcriber.finalTail)
                entry.inserted = final.trimmingCharacters(in: .whitespacesAndNewlines)
                if let note { entry.warning = note }
                receipt = "Inserted into \(platform?.targetAppName ?? "the app")"
            } else {
                // Fit the text where it goes (capitals, a period, spaces); a rewrite was laid out on purpose, so only
                // its spacing is fixed.
                let profile = activeProfile
                let rewrite = profile.rewriteWhole && profile.autoProcess && entry.inserted != entry.transcription
                let text = ContextFit.fit(entry.inserted, context: await platform?.insertionContext(), spacingOnly: rewrite)
                entry.inserted = text.trimmingCharacters(in: .whitespacesAndNewlines)
                receipt = try await platform?.insert(text) ?? "Done"
            }
            // The turnaround runs from the stop press until the text is in place.
            entry.turnaroundSeconds = previewTurnaround ?? Date().timeIntervalSince(stoppedAt ?? Date())
            await recordTurnaround(entry)
            record(entry)
            // A profile can read what went in aloud. The player then takes the receipt's place, unless the receipt has
            // a warning to show; decided once, here (App.xaml.cs Inserted).
            let text = entry.inserted.trimmingCharacters(in: .whitespacesAndNewlines)
            let readIt = readBackRequested && !text.isEmpty
            self.receipt = !readIt || entry.safetyNet == true || entry.warning != nil ? entry : nil
            phase = .done(entry.warning ?? receipt)
            showAINotice()
            if readIt { reader.read(text, voice: voice ?? settings.ttsVoice, speed: settings.ttsBaseSpeed) }
        } catch {
            // The text is on the clipboard now (the platform put it there): a HEADS UP, not a failure; History keeps
            // it as not inserted, and there is no receipt.
            var message = (error as? UserFacingError)?.message ?? error.localizedDescription
            if let typed {
                typed.forgetClipboard()
                if typed.hasTyped, !(error is CancellationError) {
                    // The final pass couldn't run: last resort so the dictation isn't lost, it goes on the clipboard.
                    platform?.leaveOnClipboard(entry.inserted)
                    message += " The text was copied to your clipboard."
                }
            }
            entry.turnaroundSeconds = previewTurnaround ?? Date().timeIntervalSince(stoppedAt ?? Date())
            entry.wasInserted = false
            record(entry)
            aiNotice = nil
            level = 0
            phase = .idle
            Log.warn("Insert failed: " + message)
            notice(message, kind: .warning)
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
        live?.stop()
        live = nil
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
        guard phase == .placing, var entry = placingEntry else { return }
        endPlacing()
        platform?.copy(entry.inserted.trimmingCharacters(in: .whitespacesAndNewlines))
        entry.wasInserted = false // copied, not inserted (DictationController.CopyPlacingToClipboard)
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

    /// As on Windows: back to idle, and the error as the overlay's SOMETHING WENT WRONG notice. A problem the user can
    /// act on says so; anything else points to the log (DictationController.Fail).
    private func fail(_ error: Error) {
        live?.stop() // whatever was typed live stays
        live = nil
        level = 0
        phase = .idle
        aiNotice = nil
        if let error = error as? UserFacingError {
            Log.warn("Dictation failed: " + error.message)
            notice(error.message, kind: .error)
        } else {
            Log.error("Dictation failed: \(error)")
            notice("Something went wrong during dictation. See \(Self.logPath).", kind: .error)
        }
    }

    /// Where the log is, as the notice says it (Windows: data\logs\dictation.log).
    static var logPath: String {
        let path = Log.file.path
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Notices

    enum NoticeKind { case info, warning, error }

    struct OverlayNotice: Equatable {
        var text: String
        var kind: NoticeKind
        /// Held by the dictation state it came in (a silent microphone while recording): it stays, with no timer,
        /// until the state changes (OverlayWindow's hide timer is ignored while pinned).
        var pinned = false
        let id = UUID()
    }

    /// The overlay is showing a dictation state now (Windows' `_pinnedByState`): every state with "Show overlay" on;
    /// with it off, only the preview and NO PLACE TO PASTE, which show either way.
    var overlayPinned: Bool {
        settings.showOverlay ? phase.isBusy : phase == .preview || phase == .placing
    }

    /// A message on the overlay (Windows' `ShowMessage`): OBERTON (info), HEADS UP (warning) or SOMETHING WENT WRONG
    /// (error), with `text` as the body. It stays for its length / 15 seconds, between 3 and 9. Info is skipped while
    /// the overlay shows a dictation (so with "Show overlay" off it shows); a warning or error then takes the pill and
    /// stays until the next state (`hold: false` gives it its time instead). Shown even with "Show overlay" off.
    func notice(_ text: String, kind: NoticeKind = .info, hold: Bool = true) {
        if kind == .info, overlayPinned { return }
        let pinned = hold && overlayPinned
        let notice = OverlayNotice(text: text, kind: kind, pinned: pinned)
        overlayNotice = notice
        overlayNoticeTask?.cancel()
        guard !pinned else { return }
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
        // While the overlay shows a dictation, its chip already shows the profile; otherwise the notice takes the
        // receipt's place (with "Show overlay" off it shows mid-dictation too, as on Windows).
        guard !overlayPinned else { return }
        if !phase.isBusy {
            idleTask?.cancel()
            phase = .idle
        }
        profileNotice = true
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { profileNotice = false }
        }
    }

    // MARK: Warming up

    /// The speech settings a profile dictates with (Windows' SpeechModels.For): its own speech model, or Settings'.
    func speechSettings(for profile: Profile) -> AppSettings { settings.dictating(with: profile) }

    /// The active profile's speech settings.
    var activeSpeech: AppSettings { speechSettings(for: activeProfile) }

    /// The speech model's name for the turnaround samples: Apple's recognizer and the language, or the Whisper model.
    var speechModelName: String { activeSpeech.whisperModel.map { "whisper:" + $0 } ?? "apple-speech:" + settings.language }

    /// The speech model for display: "Apple Speech" or the Whisper model's name.
    var speechEngineName: String { activeSpeech.whisperModel.map(WhisperModels.name(of:)) ?? "Apple Speech" }

    /// The speech model in a few characters, as Windows' dashboard shows it: "Apple Speech" or the Whisper id ("base.en").
    var speechShortName: String { activeSpeech.whisperModel ?? "Apple Speech" }

    /// The AI model a profile uses, or "" without AI.
    func aiModelName(_ profile: Profile) -> String { profile.isRaw ? "" : processor.model(for: profile).description }

    /// The average of the last three turnarounds with the active profile's models, where neither had to load first.
    var recentTurnaround: Double? {
        usage.recentTurnaround(speechModel: speechModelName, aiModel: aiModelName(activeProfile)).seconds
    }

    /// Get the speech model and the active profile's AI model loaded (at launch, and when the language or the speech
    /// model changes), as Windows does. A speech model that can't start at launch is reported once (`startupProblem`).
    func warmUp(atLaunch: Bool = false) {
        guard !Self.snapshotMode else { return }
        let speech = activeSpeech
        let locale = speech.speechLocale, whisper = speech.whisperModel
        warmTask?.cancel()
        warmTask = Task {
            speechStatus = whisper.map(loadingStatus) ?? "Speech: loading the speech model (\(languageName))…"
            speechOK = false
            do {
                if let whisper {
                    try await WhisperEngine.shared.load(whisper)
                } else {
                    // Back on Apple Speech: a Whisper model left in memory isn't needed any more (unless Extended
                    // Notes is still transcribing with it; it loads it again by itself).
                    if WhisperEngine.loadedModel != nil, !notes.needsModels { await WhisperEngine.shared.unload() }
                    try await LiveTranscriber.warmUp(locale: locale)
                }
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

    /// The active profile changed to one with another speech model: load it now, while idle, so the next dictation
    /// doesn't wait. Only when a speech model is in memory already (App.SwapSpeechModelAsync).
    private func swapSpeechModel() {
        guard speechLoaded, !phase.isBusy, !speechModelLoaded else { return }
        warmTask?.cancel()
        let speech = activeSpeech
        warmTask = Task {
            do {
                if let whisper = speech.whisperModel { try await WhisperEngine.shared.load(whisper) }
                else { try await LiveTranscriber.warmUp(locale: speech.speechLocale) }
                if !Task.isCancelled { speechReady() }
            } catch {
                Log.warn("Loading the profile's speech model failed: " + error.localizedDescription)
            }
        }
    }

    /// "Speech: preparing Whisper large-v3 turbo for this Mac…" (first time) or "Speech: loading …".
    private func loadingStatus(_ id: String) -> String {
        WhisperModels.isPrepared(id)
            ? "Speech: loading \(WhisperModels.name(of: id))…"
            : "Speech: preparing \(WhisperModels.name(of: id)) for this \(Device.noun) (first time only; a large model takes a few minutes)…"
    }

    /// A Whisper load started or ended: the status line and badges follow it.
    private func whisperChanged() {
        whisperLoad = WhisperEngine.loadingModel
        if let load = whisperLoad, load.model == activeSpeech.whisperModel, !phase.isBusy {
            speechStatus = loadingStatus(load.model)
            speechOK = false
        }
        objectWillChange.send()
    }

    private var languageName: String {
        if let whisper = activeSpeech.whisperModel {
            if WhisperModels.model(whisper)?.englishOnly == true { return "English" }
            if settings.language.isEmpty { return "auto-detect" }
        }
        return Locale.current.localizedString(forIdentifier: settings.speechLocale.identifier) ?? settings.language
    }

    private func speechReady() {
        speechStatus = "Speech: Ready · \(speechEngineName) · \(languageName)"
        speechOK = true
        objectWillChange.send() // the dashboard's speech dial
    }

    /// Load a profile's AI model without generating anything, saying how it goes in `aiStatus` as Windows' WarmUpAsync
    /// does (`AIStatus.warmUp`): "Starting AI runtime…" (Oberton's own Ollama is started if nothing answers, in the
    /// direct build), "AI model 'x' not installed", "Loading x…", "Ready · x · GPU". Cloud models have nothing to load.
    /// A profile without AI warms nothing at dictation time (`forDictation`), but its status still names the default
    /// model, as on Windows.
    private func warmUpAI(_ profile: Profile, forDictation: Bool = false) {
        guard !Self.snapshotMode, !(forDictation && profile.isRaw) else { return }
        let id = processor.model(for: profile)
        let settings = settings
        aiWarmTask?.cancel()
        aiWarmTask = Task { [weak self] in
            await AIStatus.warmUp(id, settings: settings) { line, ok in
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.aiStatus = "AI: " + line
                    self.aiStatusOK = ok
                    // "Loading x…" until the next line: the dashboard's "loading, then editing".
                    self.aiLoading = line.hasPrefix("Loading ") ? id.name : nil
                }
            }
            guard let self, !Task.isCancelled, id.provider == .ollama, !id.isOllamaCloud else { return }
            await self.refreshOllama()
            await self.refreshLoadedAI()
        }
    }

    /// The dashboard is showing (Windows' 3 s refresh of `LoadedModelsAsync`): keep `loadedAIModels` current while at
    /// least one view watches. Call with true when it appears and false when it goes.
    func watchLoadedAI(_ on: Bool) {
        loadedAIWatchers = max(0, loadedAIWatchers + (on ? 1 : -1))
        if loadedAIWatchers > 0, loadedAITimer == nil {
            Task { await refreshLoadedAI() }
            loadedAITimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refreshLoadedAI() }
            }
        } else if loadedAIWatchers == 0 {
            loadedAITimer?.invalidate()
            loadedAITimer = nil
        }
    }

    func refreshLoadedAI() async {
        guard let url = try? OllamaBackend.validated(settings.ollamaEndpoint) else { loadedAIModels = []; return }
        let loaded = Set(await OllamaBackend.loadedModels(endpoint: url))
        if loaded != loadedAIModels { loadedAIModels = loaded }
    }

    /// The dashboard's AI node status for a profile, after "{profile} // " (DashboardPage.Build): "editing" or "loading,
    /// then editing" while it tidies, "blocked offline" / "ready" for a cloud model, "loaded" / "not loaded" for a local
    /// one (`loadedAIModels`, kept current by `watchLoadedAI`). Apple Intelligence: "ready" or "not ready". Nil without AI.
    func aiNodeStatus(_ profile: Profile) -> String? {
        guard !profile.isRaw else { return nil }
        let id = processor.model(for: profile)
        let cloud = !id.isLocal || id.isOllamaCloud
        let loaded = id.provider == .apple ? AppleIntelligenceBackend.unavailableReason == nil : aiInMemory(id)
        if phase == .processing { return cloud || loaded ? "editing" : "loading, then editing" }
        if cloud { return settings.cloud.keepOffline ? "blocked offline" : "ready" }
        if id.provider == .apple { return loaded ? "ready" : "not ready" }
        return loaded ? "loaded" : "not loaded"
    }

    /// An Ollama model is in memory now (as `/api/ps` last said).
    func aiInMemory(_ id: ModelID) -> Bool {
        loadedAIModels.contains { $0.lowercased().hasPrefix(id.name.lowercased()) }
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
        // As Windows saves it: the final text trimmed, seconds to a tenth, the turnaround to a hundredth.
        var entry = entry
        entry.inserted = entry.inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.seconds = (entry.seconds * 10).rounded() / 10
        entry.turnaroundSeconds = (entry.turnaroundSeconds * 100).rounded() / 100
        // The daily counts are kept whether or not History is.
        usage.record(entry)
        usageFile.save(usage)
        if settings.keepWordTally {
            words.record(entry)
            wordsFile.save(words)
        }
        let pcm = historyAudio.finish()
        guard settings.keepHistory else { return }
        historyStore.add(entry, pcm: settings.saveHistoryAudio ? pcm : nil, words: transcriber.lastWords) // words: playback highlighting
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
            // With the speech model of the profile it was dictated with (HistoryRerun.cs: SpeechModels.For).
            let profile = profiles.first { $0.name.caseInsensitiveCompare(entry.profileName) == .orderedSame } ?? activeProfile
            let (changed, message) = try await HistoryRerun.run(entry, profiles: profiles, active: activeProfile,
                                                                settings: speechSettings(for: profile),
                                                                canSwapSpeechModel: !notes.needsModels, progress: progress)
            historyStore.save(changed)
            history = historyStore.entries
            return "✓ " + message
        } catch let error as UserFacingError {
            return "⚠ " + error.message
        } catch {
            Log.error("History: running a dictation again failed", error)
            return "⚠ Running it again failed; the dictation was left as it was. See the log for details."
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

    /// What History's and the dashboard's insert says: "Inserted into Mail" (or "Copied…"), or the problem.
    struct InsertNote: Equatable {
        var ok: Bool
        var text: String
        /// History: "✓ Inserted into Mail." or "⚠ {problem}" (HistoryPage).
        var sentence: String { ok ? "✓ \(text)." : "⚠ \(text)" }
        /// The dashboard: "✓ INSERTED INTO MAIL" or "⚠ {problem}" (DashboardPage.History).
        var banner: String { ok ? "✓ " + text.uppercased() : "⚠ \(text)" }
    }

    /// Put a text into the app the last dictation went to (History's "Insert transcription into the last app").
    func insertIntoLastApp(_ text: String) async -> InsertNote {
        do { return InsertNote(ok: true, text: try await platform?.insert(text) ?? "Done") } catch {
            return InsertNote(ok: false, text: (error as? UserFacingError)?.message ?? error.localizedDescription)
        }
    }

    func resetUsage() {
        usage.clearDays() // the turnaround samples stay, as on Windows
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
        whisperDownload = ("small.en", 0.42) // the speech model lists show a download under way
        whisperLoad = WhisperEngine.Loading(model: "base.en", since: Date().addingTimeInterval(-42), firstTime: true)
        speechStatus = loadingStatus("base.en")
        speechOK = false
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
            // Any selection is read, any clipboard text offered (a punctuation-only one then says there's nothing to read).
            if let text = await platform?.selectedText(), !text.isEmpty {
                reader.read(text, voice: voice, speed: settings.ttsBaseSpeed)
            } else if let clipboard = platform?.clipboardText()?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !clipboard.isEmpty {
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

    /// A speech model is in memory: Apple's, used since it was last let go (the system keeps it a while after each
    /// use), or a Whisper model.
    var speechLoaded: Bool { LiveTranscriber.modelRetained || WhisperEngine.loadedModel != nil }

    /// The speech model in Settings is the one in memory (a dictation started now doesn't wait for it to load).
    var speechModelLoaded: Bool {
        activeSpeech.whisperModel.map { WhisperEngine.loadedModel == $0 } ?? LiveTranscriber.modelRetained
    }

    /// Unload models right now, on request (the dashboard's speech dial), as App.UnloadNowAsync does on Windows. Never
    /// while a dictation or a reading is using them. Returns what happened, for display.
    func unloadNow(speech: Bool, ai: Bool, voice: Bool) async -> String {
        var done: [String] = [], skipped: [String] = []
        if speech {
            if notes.needsModels { skipped.append("the speech model (Extended Notes is using it)") }
            else if phase.isBusy { skipped.append("the speech model (dictating)") }
            else if speechLoaded {
                await LiveTranscriber.unloadModel()
                await WhisperEngine.shared.unload()
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
            // The player on screen counts as reading, also its DONE card (Windows' ReaderWindow.IsBusy = visible).
            if reader.isShowing { skipped.append("the Read aloud voice (reading)") }
            else if reader.isLoaded { reader.unload(); done.append("Read aloud voice") }
        }
        var msg = !done.isEmpty ? "Unloaded: " + done.joined(separator: ", ") + ". They load again when needed."
            : skipped.isEmpty ? "Nothing was loaded." : ""
        if !skipped.isEmpty { msg = (msg + " Kept " + skipped.joined(separator: " and ") + ".").trimmingCharacters(in: .whitespaces) }
        objectWillChange.send() // the speech dial now reads "off"
        return msg
    }

    // MARK: Speech models

    /// Make a speech model the one dictation and Extended Notes use ("" = Apple Speech); it loads now (`warmUp`).
    func useSpeechModel(_ id: String) {
        guard id.isEmpty || WhisperModels.isDownloaded(id) else { return }
        pendingSpeechModel = nil // the user's own choice wins over the first-run one
        settings.speechModel = id
    }

    // MARK: First-run speech model (Windows' RuntimeInstaller: the Whisper model for the hardware, downloaded in setup)

    /// The speech model a new install starts with, as Windows picks by hardware (large-v3 turbo with an NVIDIA GPU,
    /// small.en without): large-v3 turbo on Apple silicon with 16 GB of memory or more, small.en otherwise and on
    /// iPhone and iPad. Those English-only models don't fit a device set to another language: there, without room for
    /// turbo, it stays on Apple Speech (""), which follows the system language.
    nonisolated static func recommendedSpeechModel(language: String = "", memory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                                       appleSilicon: Bool = isAppleSilicon, phone: Bool = isPhone) -> String {
        if !phone, appleSilicon, memory >= 16 << 30 { return "large-v3-turbo" }
        let code = language.isEmpty ? (Locale.current.language.languageCode?.identifier ?? "en") : String(language.prefix(2))
        return code == "en" ? "small.en" : ""
    }

    nonisolated static var isPhone: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    nonisolated static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// Setup's speech model step (and a launch after an unfinished one): download the first-run model, then switch
    /// dictation over to it. Nothing to do when there is none, it is in already, or a download runs.
    func startDefaultSpeechDownload() {
        guard let id = pendingSpeechModel, !id.isEmpty else { pendingSpeechModel = nil; return }
        if WhisperModels.isDownloaded(id) { finishDefaultSpeechModel(id); return }
        downloadWhisper(id)
    }

    /// The first-run model is in: dictation uses it from now on (it loads now, `warmUp`).
    private func finishDefaultSpeechModel(_ id: String) {
        guard pendingSpeechModel == id else { return }
        pendingSpeechModel = nil
        Log.info("Speech model \(id) downloaded at first run: using it from now on")
        settings.speechModel = id
    }

    /// Download a Whisper model (one at a time, as on Windows), showing its progress in the model lists.
    func downloadWhisper(_ id: String) {
        guard whisperDownload == nil else { return }
        whisperDownloadError = nil
        whisperDownload = (id, nil)
        whisperDownloadTask = Task {
            do {
                try await WhisperModels.download(id) { fraction in
                    Task { @MainActor [weak self] in
                        if self?.whisperDownload?.id == id { self?.whisperDownload = (id, fraction) }
                    }
                }
                Log.info("Downloaded the speech model \(id)")
                if pendingSpeechModel == id {
                    finishDefaultSpeechModel(id) // loads (and prepares) it now
                } else {
                    // Prepared for this device now, so choosing it doesn't sit through that.
                    Task.detached { await WhisperEngine.prepare(id) }
                }
            } catch is CancellationError {
            } catch {
                Log.info("Speech model download failed: \(error.localizedDescription)")
                whisperDownloadError = error.localizedDescription
            }
            whisperDownload = nil
            whisperDownloadTask = nil
        }
    }

    func cancelWhisperDownload() { whisperDownloadTask?.cancel() }

    /// The installed Ollama models, after making sure the runtime answers (Windows' EnsureRunningAsync starts its own).
    func refreshOllama() async {
        guard let url = try? OllamaBackend.validated(settings.ollamaEndpoint) else { ollamaModels = []; return }
        try? await OllamaRuntime.ensureRunning(settings: settings)
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

/// The overlay's level meter: 22 columns of √level, oldest first, as OverlayWindow draws them. It moves on a steady
/// 20 Hz tick while recording rather than on audio events, so it never freezes: each tick takes the loudest level heard
/// since the last one; when nothing new came for a moment (or the microphone sends nothing), the level falls away
/// towards a flat, calm baseline and keeps scrolling.
@MainActor
final class LevelMeter: ObservableObject {
    static let count = 22
    @Published private(set) var columns = [Double](repeating: 0, count: LevelMeter.count)
    private var pending: Double?
    private var held = 0.0
    private var heardAt = Date.distantPast
    private var timer: Timer?

    /// A level from the microphone (0…1, Windows' scale).
    func hear(_ level: Float) {
        let v = Double(min(max(level, 0), 1)).squareRoot() // perceptual: quiet speech still moves the dots
        pending = max(pending ?? 0, v)
    }

    func start() {
        guard timer == nil else { return }
        columns = [Double](repeating: 0, count: Self.count)
        pending = nil
        held = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common) // also while a menu is open
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pending = nil
    }

    func tick(now: Date = .now) {
        if let pending {
            held = pending
            heardAt = now
            self.pending = nil
        } else if now.timeIntervalSince(heardAt) > 0.15 {
            held = held * 0.6 < 0.02 ? 0 : held * 0.6 // nothing heard: settle towards flat
        }
        columns.removeFirst()
        columns.append(held)
    }
}
