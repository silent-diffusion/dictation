import AVFoundation
import Combine
import Foundation
import Metal
import ObertonCore
import Speech
#if os(iOS)
import UIKit
#endif

/// Runs an Extended Notes session (NotesRecorder.cs): listens (the microphone, the Mac's own audio, or both), writes the
/// recording, sends it to Apple's speech recognizer on an analyzer of its own (or to the Whisper model in Settings), appends each finished piece to the
/// transcript, formats the new text with the AI about every minute, sums it up every 5 to 10 minutes (`NotesSummary`),
/// and saves as it goes. Only one session records at a time. A dictation pauses it (`setDictating`).
@MainActor
final class NotesRecorder: ObservableObject {
    /// Format once this many new words have come in, or after `formatEvery` with at least a few.
    static let formatWords = 110
    static let formatEvery: TimeInterval = 90
    /// Audio that arrives while the recognizer isn't running (still starting, or restarting) waits, up to three minutes.
    nonisolated static let maxBacklog = WavWriter.sampleRate * 180

    let store: NotesStore
    /// The app's settings as they are now (set by AppModel once it exists).
    var settingsSource: () -> AppSettings
    private func settings() -> AppSettings { settingsSource() }

    /// The session recording now; nil when none is.
    @Published private(set) var current: NoteSession?
    /// Paused by the user (Pause), not by a dictation.
    @Published private(set) var userPaused = false
    @Published private(set) var dictating = false
    /// Stop was pressed: the last piece is being transcribed and formatted.
    @Published private(set) var isFinishing = false
    /// The recognizer is listening; false while it starts or restarts.
    @Published private(set) var transcribing = false
    @Published private(set) var isFormatting = false
    @Published private(set) var isSummarizing = false
    /// The AI model this session formats and sums up with, once worked out.
    @Published private(set) var model: ModelID?
    /// The AI model a session would use now, for the pipeline while none records (`keepIdleModel`).
    @Published private(set) var idleModel: ModelID?
    private var idleResolved = Date.distantPast
    /// The step being redone (nil when none is), for which session, and how far it got.
    @Published private(set) var redoing: NotesRedoStep?
    @Published private(set) var redoSession: NoteSession?
    @Published private(set) var redoProgress = ""
    /// Bumped on every tick and change, so views showing the live session redraw.
    @Published private(set) var revision = 0

    var isRecording: Bool { current != nil }
    /// Seconds recorded in the session now, as the audio comes in (the page's timer reads it; `session.seconds` follows
    /// on the 2 s tick).
    var seconds: Double { feed.seconds }
    /// Recording, or redoing a step: the speech recognizer and the AI model are in use, so nothing may unload them.
    var needsModels: Bool { current != nil || redoing != nil }
    /// Not recording right now: paused by the user, or while a dictation runs.
    var isPaused: Bool { userPaused || dictating }

    private let feed = NotesFeed()
    private let engine = AVAudioEngine()
    private var micConverter: AVAudioConverter?
    #if os(macOS)
    private var computerAudio: SystemAudioCapture?
    /// Computer audio alone: a 100-ms clock takes it from the mixer by wall time, silence where none came.
    private var computerClock: DispatchSourceTimer?
    #endif
    private var tick: Timer?
    private var speechTask: Task<Void, Never>?
    private var connecting = false
    /// Where in the recording the Whisper stream's time 0 is.
    private var whisperStart = 0.0
    private var nextConnect = Date.distantPast
    private var connectDelay: TimeInterval = 5
    private var formatRequests = 0, summaryRequests = 0
    private var modelFor = "", modelResolved = Date.distantPast
    private var lastFormat = Date(), lastSave = Date(), lastSection = Date()
    private var dirty = false
    private var redoTask: Task<Void, Error>?

    init(store: NotesStore, settings: @escaping () -> AppSettings) {
        self.store = store
        settingsSource = settings
        #if os(iOS)
        // iOS ends a backgrounded app without notice: what is typed and recorded so far is written as it goes there.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        #endif
    }

    /// While a page showing the pipeline is open: the model a session would use, worked out again every half minute
    /// (a model may have been installed or removed meanwhile), checked on the page's 400 ms tick. The landing page and a
    /// live session's pipeline skip it while a session records; a finished session's pipeline skips it while a step is
    /// redone (NotesPage.PipelineSteps / RedoSteps).
    func keepIdleModel(skip: @escaping @MainActor () -> Bool) async {
        while !Task.isCancelled {
            if !skip(), Date().timeIntervalSince(idleResolved) > 30 {
                idleResolved = Date()
                idleModel = await Self.resolve(settings())
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    /// Extended Notes was opened afresh (Windows builds a new page each time, whose `_idleModel` starts empty): the idle
    /// model is forgotten, so FORMAT / SUMMARY read "…" until it has been worked out again, at once.
    func forgetIdleModel() {
        idleModel = nil
        idleResolved = .distantPast
    }

    // MARK: Start

    func start(source requested: NotesSource) async throws {
        if isRecording { return }
        if redoing != nil {
            throw UserFacingError("A session is being redone. Wait for it to finish, or stop it from its pipeline, then start a new one.")
        }
        #if os(iOS)
        let source = NotesSource.mic // an iPhone app can't hear other apps' audio
        #else
        let source = requested
        #endif
        let s = try store.create(source: source)
        userPaused = false; isFormatting = false; isSummarizing = false
        formatRequests = 0; summaryRequests = 0
        model = nil
        connectDelay = 5
        lastFormat = Date(); lastSave = Date(); lastSection = Date()
        do {
            try feed.begin(wav: s.audioURL!)
            try startAudio(source)
        } catch {
            stopAudio()
            feed.end()
            store.delete(s)
            throw error
        }
        // What was typed in the dashboard's notes box beforehand begins the transcript, as the user's own notes.
        let draft = store.takeDraft().trimmed
        if !draft.isEmpty {
            s.set(.transcript, draft + "\n", source: self)
            store.save(s)
        }
        current = s
        Log.info("Extended notes: started \(s.id) (\(source.rawValue))")
        feed.setPaused(isPaused) // a dictation running now pauses the session from its first moment
        tick = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.onTick() } }
        await connectSpeech()
    }

    private func startAudio(_ source: NotesSource) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
        try session.setActive(true)
        LiveTranscriber.audioSessionHeld = true
        #endif
        let feed = self.feed
        #if os(macOS)
        if source == .computer || source == .both {
            let capture = SystemAudioCapture()
            try capture.start { feed.mixer.addComputer($0) }
            computerAudio = capture
            if source == .computer {
                // Computer audio alone is paced by the clock, not by the device (NotesRecorder.StartAudio): the
                // recording and its timer go on, as silence, if the output device stops or goes away.
                let clock = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Oberton.NotesComputerClock"))
                let started = DispatchTime.now().uptimeNanoseconds
                var emitted = 0
                clock.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
                clock.setEventHandler {
                    let due = Int(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 * Double(WavWriter.sampleRate)) - emitted
                    guard due > 0 else { return }
                    emitted += due
                    feed.take(feed.mixer.takeComputer(due))
                }
                clock.resume()
                computerClock = clock
            }
        }
        #endif
        guard source == .mic || source == .both else { return }
        // The microphone chosen in Settings › Microphone, as dictation uses (the system default when none is).
        Microphones.use(settings().microphoneName, on: engine)
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(WavWriter.sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: micFormat, to: target) else {
            throw UserFacingError(Self.noMicrophone)
        }
        micConverter = converter
        let both = source == .both
        var tapConverter = converter // the tap's own (its thread only), made again if the microphone's format changes
        try Microphones.tap(input, bufferSize: 4096) { buffer, _ in
            if tapConverter.inputFormat != buffer.format, let c = AVAudioConverter(from: buffer.format, to: target) { tapConverter = c }
            let samples = NotesFeed.convert(buffer, with: tapConverter, to: target)
            feed.take(both ? feed.mixer.mix(withMic: samples) : samples)
        }
        engine.prepare()
        do { try engine.start() } catch {
            Log.warn("Extended notes: the microphone didn't start: " + error.localizedDescription)
            throw UserFacingError(Self.micWontOpen)
        }
    }

    /// MicCapture's messages (as dictation's, in the Mac's words).
    #if os(macOS)
    static let noMicrophone = "No microphone was found. Plug one in or enable it in System Settings › Sound."
    static let micWontOpen = "Could not open the microphone. Check that it is connected and that macOS allows Oberton to use it (System Settings › Privacy & Security › Microphone)."
    #else
    static let noMicrophone = "No microphone was found. Plug one in, or check Settings › Privacy & Security › Microphone."
    static let micWontOpen = "Could not open the microphone. Check that Oberton may use it (Settings › Privacy & Security › Microphone)."
    #endif

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        micConverter = nil
        #if os(macOS)
        computerClock?.cancel()
        computerClock = nil
        computerAudio?.stop()
        computerAudio = nil
        #else
        LiveTranscriber.audioSessionHeld = false
        #endif
    }

    // MARK: Speech

    /// Start the recognizer for this session; on failure, try again later (5 s, 10 s, 20 s, up to a minute apart).
    private func connectSpeech() async {
        guard !connecting, current != nil else { return }
        connecting = true
        defer { connecting = false }
        do {
            let st = settings()
            if let whisper = Self.whisperModel(st) {
                try await connectWhisper(whisper, st)
                return
            }
            let locale = try await LiveTranscriber.prepare(locale: st.speechLocale)
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let vocabulary = st.vocabularyHint.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocabulary
                try await analyzer.setContext(context)
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw UserFacingError("The speech recognizer has no audio format to take.")
            }
            let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
            let waiting = feed.backlogPieces
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
            LiveTranscriber.markInUse()
            guard current != nil else { input.finish(); await analyzer.cancelAndFinishNow(); return }
            // What was said meanwhile goes first; the live audio follows on. Times count from the session's start.
            let startSeconds = feed.connect(input: input, format: format, evenOut: st.evenOutVolume)
            speechTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results where result.isFinal {
                        let text = String(result.text.characters)
                        let at = startSeconds + max(0, result.range.start.seconds.isFinite ? result.range.start.seconds : 0)
                        let words = WordTimes.words(result.text, offset: startSeconds)
                        await MainActor.run { self?.onPiece(text, at: at, words: words) }
                    }
                } catch {}
                await MainActor.run { self?.onSpeechEnded() }
            }
            feed.analyzer = analyzer
            connectDelay = 5
            transcribing = true
            Log.info("Extended notes: listening" + (waiting > 0 ? " (\(waiting) waiting pieces of audio sent first)" : ""))
        } catch {
            Log.warn("Extended notes: couldn't connect to the speech engine (\(error.localizedDescription)); next try in \(Int(connectDelay)) s")
            nextConnect = Date().addingTimeInterval(connectDelay)
            connectDelay = min(60, connectDelay * 2)
        }
    }

    /// The Whisper model in Settings: finished sentences come in every few seconds (`WhisperLiveStream`).
    private func connectWhisper(_ id: String, _ st: AppSettings) async throws {
        try await WhisperEngine.shared.load(id)
        guard current != nil else { return }
        var made: WhisperLiveStream?
        let stream = WhisperLiveStream(model: id, language: st.whisperLanguage, vocabulary: st.vocabularyHint, even: st.evenOutVolume) { [weak self] text, at in
            let words = made?.takeWords() ?? []
            Task { @MainActor in
                let start = self?.whisperStart ?? 0
                self?.onPiece(text, at: start + at, words: words.map { $0.shifted(by: start) })
            }
        }
        made = stream
        let waiting = feed.backlogPieces
        whisperStart = feed.connect(whisper: stream)
        stream.start()
        connectDelay = 5
        transcribing = true
        Log.info("Extended notes: listening" + (waiting > 0 ? " (\(waiting) waiting pieces of audio sent first)" : ""))
    }

    /// The Whisper model Extended Notes transcribes with, or nil for Apple's recognizer: the one the speech engine has
    /// loaded now, else the active profile's (`settingsSource` resolves it with `dictating(with:)`), as Windows'
    /// `Speech.LoadedModel ?? SpeechModels.For(...)`. A profile on Apple's recognizer keeps it.
    static func whisperModel(_ st: AppSettings) -> String? {
        guard let wanted = st.whisperModel else { return nil }
        return WhisperEngine.loadedModel ?? wanted
    }

    private func onSpeechEnded() {
        transcribing = false
        speechTask = nil
        if current != nil && !isFinishing { feed.disconnect() } // audio waits in the backlog until it starts again
    }

    /// A finished piece of speech, with its words timed in the recording.
    private func onPiece(_ text: String, at seconds: Double, words: [SpokenWord] = []) {
        guard let s = current else { return }
        s.appendHeard(text, seconds: seconds, source: self)
        s.appendWords(words)
        dirty = true
        revision += 1
    }

    private func onTick() {
        guard let s = current, !isFinishing else { return }
        s.seconds = feed.seconds
        if !transcribing && !connecting && Date() >= nextConnect { Task { await connectSpeech() } }
        if !dictating {
            // Not while a dictation runs: its AI edit would wait behind a long formatting or summary request.
            maybeFormat(s)
            maybeSummarize(s)
        }
        if dirty && Date().timeIntervalSince(lastSave) > 10 || Date().timeIntervalSince(lastSave) > 30 { save(s) }
        revision += 1
    }

    private func save(_ s: NoteSession) {
        feed.flush()
        store.save(s)
        dirty = false
        lastSave = Date()
    }

    // MARK: Formatting and summing up

    private func maybeFormat(_ s: NoteSession) {
        guard !isFormatting else { return }
        let words = s.unformattedWords()
        // The part is taken and "formatting" set now, before the tick goes on to the summary (Windows' FormatAsync runs
        // up to its first await at once), so the summary waits its turn rather than going out alongside.
        if words >= Self.formatWords || words >= 15 && Date().timeIntervalSince(lastFormat) >= Self.formatEvery, let take = claimFormat(s) {
            Task { await format(s, take) }
        }
    }

    /// Takes the next part to format and marks formatting as running; nil when one runs already or nothing is new.
    private func claimFormat(_ s: NoteSession, maxWords: Int? = nil) -> (heard: String, sent: String, seconds: Double)? {
        guard !isFormatting, let take = maxWords.map({ s.beginFormatPart(maxWords: $0) }) ?? s.beginFormat() else { return nil }
        isFormatting = true
        return take
    }

    private func format(_ s: NoteSession, maxWords: Int? = nil) async {
        guard let take = claimFormat(s, maxWords: maxWords) else { return }
        await format(s, take)
    }

    private func format(_ s: NoteSession, _ take: (heard: String, sent: String, seconds: Double)) async {
        // The recognizer's loops go before anything else: the AI would copy them.
        let input = NotesFormat.collapseRepeats(take.sent)
        var ai = input, failed = true
        if Self.onlyMarkers(take.sent) {
            ai = take.sent; failed = false // nothing but markers since the last step: nothing for the AI to tidy
        } else {
            formatRequests += 1
            do {
                let reply = try await ask(NotesFormat.instructions(input), NotesFormat.wrap(input), NotesFormat.maxTokens(input))
                if let accepted = NotesFormat.accept(sent: input, reply: reply) { ai = accepted; failed = false }
                else { Log.info("Extended notes: the AI's formatting added to, dropped or changed the text; keeping it as heard") }
            } catch {
                Log.warn("Extended notes: formatting failed, keeping the text as heard: " + error.localizedDescription)
            }
        }
        s.endFormat(heard: take.heard, sent: take.sent, ai: ai, seconds: take.seconds, failed: failed, source: self)
        lastFormat = Date()
        isFormatting = false
        dirty = true
        revision += 1
    }

    /// Every line is a marker's (or blank).
    static func onlyMarkers(_ text: String) -> Bool {
        text.components(separatedBy: "\n").allSatisfy { $0.trimmed.isEmpty || $0.trimmed.hasPrefix(NoteSession.markerFlag) }
    }

    private func maybeSummarize(_ s: NoteSession) {
        guard !isSummarizing, !isFormatting else { return }
        let fresh = s.unsummarizedChars()
        if fresh >= NotesSummary.sectionChars || fresh >= NotesSummary.sectionMinChars && Date().timeIntervalSince(lastSection) >= NotesSummary.sectionEvery {
            isSummarizing = true // now, so a formatting due on the next tick waits for it (as Windows' SummarizeAsync)
            Task { await summarizeClaimed(s, final: false) }
        }
    }

    /// Sum up what is new (at Stop: everything left), merge, and rewrite the summary.
    private func summarize(_ s: NoteSession, final: Bool) async {
        guard !isSummarizing else { return }
        isSummarizing = true
        await summarizeClaimed(s, final: final)
    }

    /// `summarize`, once "summarizing" is set.
    private func summarizeClaimed(_ s: NoteSession, final: Bool) async {
        defer { isSummarizing = false; revision += 1 }
        do {
            // 1. The new formatted text, a section at a time.
            var sections = 0, added = 0
            while sections < (final ? 50 : 1), let section = s.beginSection(maxChars: NotesSummary.inputBudget) {
                sections += 1
                summaryRequests += 1
                let reply = try await ask(NotesSummary.digestPrompt(NotesSummary.digestWords(section.text)), section.text, NotesSummary.digestTokens)
                guard NotesSummary.isUsable(input: section.text, output: reply) else {
                    s.endSection(nil, start: section.start, end: section.end)
                    Log.info("Extended notes: a section's summary was unusable; trying again next time")
                    break
                }
                s.endSection(reply, start: section.start, end: section.end)
                lastSection = Date(); added += 1
                dirty = true
            }
            if added == 0 { return }
            // 2. Four summaries of one level become one, shorter; and so on up.
            var merges = 0
            while merges < 20, let group = NotesSummary.mergeGroup(s.frontier()) {
                merges += 1
                summaryRequests += 1
                let input = NotesSummary.mergeInput(group)
                let reply = try await ask(NotesSummary.mergePrompt(NotesSummary.mergeWords(group)), input, NotesSummary.mergeTokens)
                guard NotesSummary.isUsable(input: input, output: reply) else { Log.info("Extended notes: merging summaries gave nothing usable; keeping them apart"); break }
                s.merge(group, text: reply)
                dirty = true
            }
            // 3. The Summary tab: the main idea, key points, at most three paragraphs; the listener's edits kept.
            let frontier = s.frontier()
            if frontier.isEmpty { return }
            let basedOn = s.summary
            let listener = basedOn.trimmed != s.summaryByAi.trimmed ? basedOn : nil
            let text = NotesSummary.finalInput(frontier, listener: listener)
            summaryRequests += 1
            if let summary = NotesSummary.shape(try await ask(NotesSummary.finalPrompt, text, NotesSummary.finalTokens)),
               Double(NoteSession.words(summary)) <= Double(NoteSession.words(text)) * 1.5 + 60 {
                if !s.endSummary(summary, basedOn: basedOn, source: self) { Log.info("Extended notes: the summary was edited meanwhile; keeping the edit") }
            } else {
                Log.info("Extended notes: the summary was unusable; keeping the last one")
            }
            dirty = true
        } catch {
            Log.warn("Extended notes: summarizing failed: " + error.localizedDescription)
        }
    }

    private func ask(_ instructions: String, _ text: String, _ maxTokens: Int) async throws -> String {
        let id = await resolveModel()
        let backend = try await TextProcessor(settings: settings()).backend(for: id, ask: true)
        let started = Date()
        let reply = try await backend.complete(system: instructions, examples: [], user: text, maxTokens: maxTokens)
        // TextProcessing.AskAsync logs a local model's answer ("llm <model>: asked 1200->1180 chars in 3456 ms", UTF-16
        // lengths, the reply as it came); a cloud model's goes straight to its provider, unlogged.
        if id.provider == .ollama {
            Log.info("llm \(id.name): asked \(text.utf16.count)->\(reply.utf16.count) chars in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        }
        // Cleaned as every AI reply is (TextProcessing's AskAsync → OutputSanitizer.Clean): think tags, transcript tags,
        // code fences, a "Here is…:" opener and wrapping quotes go before the reply is used.
        return OutputSanitizer.clean(reply, input: text)
    }

    /// The AI model for formatting and summaries (`NotesModels`): worked out again when the setting changes, and every
    /// ten minutes, since a model may have been installed or removed meanwhile.
    func resolveModel() async -> ModelID {
        let st = settings()
        if let model, st.notesModel == modelFor, Date().timeIntervalSince(modelResolved) < 600 { return model }
        let (resolved, why) = await Self.resolveWhy(st)
        if resolved != model { Log.info("Extended notes: AI model \(resolved.notesName) (\(why))") }
        model = resolved
        modelFor = st.notesModel
        modelResolved = Date()
        return resolved
    }

    static func resolve(_ st: AppSettings) async -> ModelID { await resolveWhy(st).model }

    /// The model and why (NotesModels.ResolveAsync); a chosen model that is gone is said in the log.
    static func resolveWhy(_ st: AppSettings) async -> (model: ModelID, why: String) {
        let setting0 = st.notesModel.trimmed
        // The active model, or a cloud model chosen by name, needs no list (ResolveAsync returns before listing).
        let noList = setting0.lowercased() == NotesModels.active || (ModelID(setting0).map { $0.provider != .ollama } ?? false)
        let installed = noList ? [] : await listModels(st)
        let r = NotesModels.resolve(st.notesModel, activeModel: st.defaultModel, installed: installed, gpuBytes: gpuBytes, ramBytes: LocalModel.systemRam)
        let setting = st.notesModel.trimmed
        let named = !setting.isEmpty && setting.lowercased() != NotesModels.active && (ModelID(setting).map { $0.provider == .ollama } ?? true)
        if named && !r.why.hasPrefix("chosen") {
            Log.warn("Extended notes: the chosen AI model \(setting) isn't installed; using the best one instead")
        }
        return r
    }

    /// The installed Ollama models with their details, as Windows' ListModelDetailsAsync: Oberton's own runtime is started
    /// first when nothing answers (Direct; EnsureRunningAsync), and a failure is logged ("Listing models failed: …") and
    /// reads as no model installed.
    static func listModels(_ st: AppSettings) async -> [NotesModels.Installed] {
        let url: URL
        do {
            url = try OllamaBackend.validated(st.ollamaEndpoint)
            try await OllamaRuntime.ensureRunning(settings: st)
        } catch {
            if !(error is CancellationError) { Log.warn("Listing models failed: " + ((error as? UserFacingError)?.message ?? error.localizedDescription)) }
            return []
        }
        return await OllamaBackend.installedDetails(endpoint: url) // logs a listing that fails itself
    }

    /// keep_alive 0 for one model (Windows' PostAsJsonAsync + EnsureSuccessStatusCode): nil once Ollama took it, else
    /// why not, as the exception's message says it.
    static func unloadFailure(endpoint: URL, model: String) async -> String? {
        var req = URLRequest(url: endpoint.appending(path: "api/generate"), timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0] as [String: Any])
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return HTTPStatusError(response)?.localizedDescription
        } catch {
            return error.localizedDescription
        }
    }

    /// The memory the GPU may use (Metal's recommended working set): what an Ollama model has to fit in.
    static var gpuBytes: Int64? { MTLCreateSystemDefaultDevice().map { Int64($0.recommendedMaxWorkingSetSize) } }

    // MARK: Pause, markers, dictation, stop

    func pause() {
        guard isRecording, !userPaused else { return }
        userPaused = true
        feed.setPaused(isPaused)
        Log.info("Extended notes: paused")
    }

    func resume() {
        guard isRecording, userPaused else { return }
        userPaused = false
        feed.setPaused(isPaused)
        Log.info("Extended notes: resumed")
    }

    /// The listener marked this moment (the hotkey, or the Mark button): a "⚑ m:ss" line goes into the transcript,
    /// paused or not, and the session is saved. Nothing once Stop was pressed.
    func addMarker() {
        guard let s = current, !isFinishing else { return }
        let at = feed.seconds
        s.addMarker(at, source: self)
        Log.info("Extended notes: marker at " + NoteSession.markerLabel(at))
        save(s)
        revision += 1
    }

    /// A dictation started or ended: the session pauses while it runs (both would hear the same voice).
    func setDictating(_ on: Bool) {
        guard dictating != on else { return }
        dictating = on
        feed.setPaused(isPaused)
    }

    /// Stop: the last piece is transcribed and formatted, the summary brought up to date, and the session saved.
    func stop() async {
        guard let s = current, !isFinishing else { return }
        isFinishing = true
        feed.setPaused(true)
        stopAudio()
        tick?.invalidate()
        let left = feed.backlogSeconds
        if left > 0 { Log.warn("Extended notes: \(Int(left)) s of audio never reached the speech engine (not connected); the recording has it") }
        // The last piece: at most a minute (as Windows' StopAsync), so a recognizer that never finishes can't keep the
        // session on FINISHING… for good.
        if let analyzer = feed.analyzer {
            feed.finishInput()
            let task = speechTask
            let done: Void? = await Self.within(Self.lastPieceWait) {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                await task?.value
            }
            if done == nil {
                Log.warn("Extended notes: the speech engine didn't finish the last piece in time")
                task?.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } else if let stream = feed.whisper {
            feed.finishInput()
            switch await Self.within(Self.lastPieceWait, { await stream.finish() }) {
            case .some(.some(let last)): onPiece(last.text, at: whisperStart + last.at, words: stream.takeWords().map { $0.shifted(by: whisperStart) })
            case .some(.none): break
            case .none:
                Log.warn("Extended notes: the speech engine didn't finish the last piece in time")
                stream.cancel()
            }
        }
        feed.end()
        s.seconds = feed.seconds
        while isFormatting || isSummarizing { try? await Task.sleep(for: .milliseconds(200)) }
        if s.unformattedWords() > 0 { await format(s) }
        await summarize(s, final: true)
        s.finished = true
        store.save(s)
        store.usage.record(s, formatRequests: formatRequests, summaryRequests: summaryRequests)
        current = nil
        isFinishing = false
        userPaused = false
        transcribing = false
        Log.info("Extended notes: stopped \(s.id) after \(NoteSessionView.length(s.seconds))")
        store.sessionsChanged?()
        await releaseModel()
    }

    /// How long Stop waits for the speech engine's last piece (NotesRecorder.cs: `StopAsync(60 s)`).
    static var lastPieceWait: Double = 60

    /// `work`'s result, or nil if it takes longer than `seconds` (it is then left to finish on its own).
    static func within<T>(_ seconds: Double, _ work: @escaping () async -> T) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            Task { let r = await work(); if once.claim() { c.resume(returning: r) } }
            Task { try? await Task.sleep(for: .seconds(seconds)); if once.claim() { c.resume(returning: nil) } }
        }
    }

    /// The session or redo is done: a model held in the Mac's memory rather than the GPU's (a big MoE such as Qwen3
    /// 30B-A3B, a 27B) is let go at once, rather than holding ~20 GB until Ollama times it out (`ReleaseIfLargeAsync`).
    /// Not while another session or redo has started meanwhile.
    private func releaseModel() async {
        let st = settings()
        guard let model, model.provider == .ollama, !needsModels,
              let url = try? OllamaBackend.validated(st.ollamaEndpoint) else { return }
        guard await OllamaBackend.size(endpoint: url, model: model.name).large,
              await OllamaBackend.isLoaded(endpoint: url, model: model.name) else { return }
        // keep_alive 0, then wait for the runner to stop (up to 10 s), so the log says whether the memory came back
        // (TextProcessing.ReleaseIfLargeAsync).
        // A refusal is logged with its reason ("Unloading <m> failed: Response status code does not indicate success:
        // 404 (Not Found).", or the connection's error). Windows' outer "letting the AI model go failed" catch is never
        // reached (ReleaseIfLargeAsync catches everything but a cancellation, and it is given no token): nothing here.
        if let why = await Self.unloadFailure(endpoint: url, model: model.name) {
            Log.warn("Unloading \(model.name) failed: \(why)")
            return
        }
        for _ in 0..<40 where await OllamaBackend.isLoaded(endpoint: url, model: model.name) { try? await Task.sleep(for: .milliseconds(250)) }
        if await OllamaBackend.isLoaded(endpoint: url, model: model.name) {
            Log.warn("LLM \(model.name): asked to unload, but it is still loaded after 10 s")
        } else {
            Log.info("LLM \(model.name): done, unloaded from memory")
        }
    }

    /// Oberton is quitting: keep everything up to now (and the dashboard draft; no last formatting pass), right away.
    func shutdown() {
        store.flushDraft()
        guard let s = current else { return }
        stopAudio()
        tick?.invalidate()
        feed.whisper?.cancel()
        feed.finishInput()
        feed.end()
        s.seconds = feed.seconds
        s.finished = true
        store.saveNow(s)
        store.usage.record(s, formatRequests: formatRequests, summaryRequests: summaryRequests)
        current = nil
    }

    #if os(iOS)
    /// iOS: the app went to the background (it may be ended there without notice): what is typed and recorded so far
    /// is written now. A session goes on recording in the background (UIBackgroundModes: audio).
    func saveNow() {
        store.flushDraft()
        guard let s = current else { return }
        feed.flush()
        s.seconds = feed.seconds
        store.saveNow(s)
    }
    #endif

    // MARK: Redoing a finished session's steps

    func cancelRedo() { redoTask?.cancel() }

    /// Redo a step of a finished session, and every step after it: transcribe the recording again (then format and sum
    /// up again), format the whole transcript again (then sum up again), or sum up again. Not while a session records.
    func redo(_ s: NoteSession, _ step: NotesRedoStep) async throws {
        if isRecording { throw UserFacingError("A step can be redone once the session recording now has stopped.") }
        if redoing != nil { throw UserFacingError("Another step is being redone; wait for it to finish.") }
        redoSession = s
        model = nil
        Log.info("Extended notes: redoing \(step.name) for \(s.id)")
        let task = Task { @MainActor in
            if step == .transcribe {
                redoing = .transcribe
                try await retranscribe(s)
            }
            if step <= .format {
                redoing = .format
                redoProgress = ""
                s.resetFormatting(source: self)
                store.save(s)
                var parts = 0
                while !s.transcript.u16Tail(s.formattedThrough).trimmed.isEmpty {
                    try Task.checkCancellation()
                    redoProgress = "\(s.formattedThrough * 100 / max(1, s.transcript.utf16.count))%"
                    let before = s.formattedThrough
                    // Stopping lets the request on its way finish (Windows' FormatAsync takes no token): the part is
                    // kept as formatted, then the redo stops.
                    await Task { @MainActor in await self.format(s, maxWords: Self.formatWords) }.value
                    if s.formattedThrough <= before { break }
                    parts += 1
                    if parts % 5 == 0 { store.save(s) }
                }
            }
            try Task.checkCancellation()
            redoing = .summary
            redoProgress = ""
            s.resetSummary(source: self)
            // Once begun, the summary is written to the end, as Windows' SummarizeAsync (no token).
            await Task { @MainActor in await self.summarize(s, final: true) }.value
            Log.info("Extended notes: redid \(step.name) for \(s.id)")
        }
        redoTask = task
        defer {
            redoing = nil
            redoSession = nil
            redoProgress = ""
            redoTask = nil
            store.save(s)
            revision += 1
            Task { await releaseModel() }
        }
        try await task.value
    }

    /// The recording, transcribed again from its file. The transcript is replaced only once the whole recording is
    /// done, so a cancelled redo changes nothing.
    private func retranscribe(_ s: NoteSession) async throws {
        guard let url = s.audioURL, FileManager.default.fileExists(atPath: url.path) else {
            throw UserFacingError("This session has no recording to transcribe again.")
        }
        redoProgress = "reading the recording"
        let st = settings()
        if let whisper = Self.whisperModel(st) {
            // NotesRecorder.RetranscribeAsync: "reading the recording" until the engine is in, then before each part how
            // far the parts done so far got ("{i*100/n}%": 0% while the first runs, never 100%).
            try await WhisperEngine.shared.load(whisper)
            try Task.checkCancellation()
            redoProgress = "0%"
            let done = PartCount()
            let heard = try await WhisperAudio.redoTimed(url, model: whisper, language: st.whisperLanguage, vocabulary: st.vocabularyHint,
                                                         even: st.evenOutVolume) { fraction in
                // Told after part i of n with (i + 1) / n: what Windows shows as the next part starts.
                done.add()
                guard fraction < 1 else { return }
                await MainActor.run { self.redoProgress = "\(Int(fraction * 100 + 1e-9))%" }
            }
            try Task.checkCancellation()
            s.replaceTranscript(heard.pieces, source: self)
            s.words = heard.words
            store.save(s)
            Log.info("Extended notes: transcribed \(s.id) again in \(done.count) parts")
            return
        }
        let locale = try await LiveTranscriber.prepare(locale: st.speechLocale)
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let file = try AVAudioFile(forReading: url)
        let total = max(1, Double(file.length) / file.processingFormat.sampleRate)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        LiveTranscriber.markInUse()
        let collect = Task { () -> (pieces: [(seconds: Double, text: String)], words: [SpokenWord]) in
            var pieces: [(seconds: Double, text: String)] = []
            var words: [SpokenWord] = []
            for try await r in transcriber.results where r.isFinal {
                let at = r.range.start.seconds.isFinite ? r.range.start.seconds : 0
                pieces.append((at, String(r.text.characters)))
                words += WordTimes.words(r.text)
                let progress = "\(Int(min(99, at / total * 100)))%"
                await MainActor.run { self.redoProgress = progress }
            }
            return (pieces, words)
        }
        do {
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            let heard = try await withTaskCancellationHandler {
                try await collect.value
            } onCancel: {
                collect.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
            try Task.checkCancellation()
            s.replaceTranscript(heard.pieces.filter { !$0.text.trimmed.isEmpty }, source: self)
            s.words = heard.words
            store.save(s)
            Log.info("Extended notes: transcribed \(s.id) again")
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}

/// The parts a redo has transcribed so far (one progress report each).
final class PartCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

/// An HTTP answer other than 2xx, worded as .NET's EnsureSuccessStatusCode ("Response status code does not indicate
/// success: 404 (Not Found).").
struct HTTPStatusError: LocalizedError {
    var code: Int
    init?(_ response: URLResponse) {
        guard let code = (response as? HTTPURLResponse)?.statusCode, code / 100 != 2 else { return nil }
        self.code = code
    }
    var errorDescription: String? {
        let reason = HTTPURLResponse.localizedString(forStatusCode: code).capitalized
        return "Response status code does not indicate success: \(code) (\(reason))."
    }
}

/// Lets exactly one of several racing callers through.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// What to redo; every step after it is redone too, since it is made from it.
enum NotesRedoStep: Int, Comparable {
    case transcribe, format, summary
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    /// As Windows' NotesRedo.Step writes itself in the log: "Transcribe", "Format", "Summary".
    var name: String { switch self { case .transcribe: "Transcribe"; case .format: "Format"; case .summary: "Summary" } }
}

extension String {
    /// The text from a UTF-16 offset on.
    func u16Tail(_ from: Int) -> String {
        let n = utf16.count, a = Swift.max(0, Swift.min(from, n))
        return String(utf16[utf16.index(utf16.startIndex, offsetBy: a)...]) ?? ""
    }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The audio path off the main thread: 16 kHz mono samples from the capture threads go into the recording and to the
/// recognizer, or wait in the backlog while it isn't running. Paused, they are dropped (the recording's length counts
/// only what was recorded).
final class NotesFeed: @unchecked Sendable {
    let mixer = NotesMixer()
    private let lock = NSLock()
    private var wav: WavWriter?
    private var paused = true
    private var samples = 0
    private var backlog: [Float] = []
    /// The size of each piece waiting, oldest first: a full backlog drops whole pieces from the front, as Windows'
    /// queue of chunks does, so the count is of the pieces still there.
    private var backlogSizes: [Int] = []
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var _analyzer: SpeechAnalyzer?
    private var _whisper: WhisperLiveStream?
    /// "Even out the volume" for Apple's recognizer (Whisper levels its own input): what it hears, not the recording.
    private var leveller: VolumeLeveller?
    private let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(WavWriter.sampleRate), channels: 1, interleaved: false)!

    var analyzer: SpeechAnalyzer? {
        get { lock.withLock { _analyzer } }
        set { lock.withLock { _analyzer = newValue } }
    }

    /// The Whisper stream the audio goes to instead of an analyzer, while one runs.
    var whisper: WhisperLiveStream? { lock.withLock { _whisper } }

    /// Seconds recorded (pauses not counted).
    var seconds: Double { lock.withLock { Double(samples) / Double(WavWriter.sampleRate) } }

    /// Seconds of audio waiting for the recognizer to start.
    var backlogSeconds: Double { lock.withLock { Double(backlog.count) / Double(WavWriter.sampleRate) } }
    /// How many pieces of audio (capture buffers) are waiting, for the log (Windows counts its queued chunks).
    var backlogPieces: Int { lock.withLock { backlogSizes.count } }

    func begin(wav url: URL) throws {
        let w = try WavWriter(url: url)
        lock.withLock { wav = w; samples = 0; backlog = []; backlogSizes = []; paused = true }
    }

    func setPaused(_ on: Bool) { lock.withLock { paused = on } }

    func take(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        lock.withLock {
            guard !paused, let wav else { return }
            wav.write(chunk)
            samples += chunk.count
            if let _whisper { _whisper.append(chunk) } else if let input { send(chunk, to: input) } else {
                backlog += chunk
                backlogSizes.append(chunk.count)
                var drop = 0
                while backlog.count - drop > NotesRecorder.maxBacklog, !backlogSizes.isEmpty { drop += backlogSizes.removeFirst() }
                if drop > 0 { backlog.removeFirst(drop) }
            }
        }
    }

    /// The recognizer is running: the backlog goes first. Returns where in the recording its time 0 is.
    func connect(input: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat, evenOut: Bool) -> Double {
        lock.withLock {
            leveller = evenOut ? VolumeLeveller(sampleRate: Double(WavWriter.sampleRate)) : nil
            analyzerFormat = format
            converter = format == source ? nil : AVAudioConverter(from: source, to: format)
            self.input = input
            let start = Double(samples - backlog.count) / Double(WavWriter.sampleRate)
            if !backlog.isEmpty { send(backlog, to: input) }
            backlog = []
            backlogSizes = []
            return start
        }
    }

    /// Whisper is running: the backlog goes first. Returns where in the recording its time 0 is.
    func connect(whisper: WhisperLiveStream) -> Double {
        lock.withLock {
            _whisper = whisper
            let start = Double(samples - backlog.count) / Double(WavWriter.sampleRate)
            if !backlog.isEmpty { whisper.append(backlog) }
            backlog = []
            backlogSizes = []
            return start
        }
    }

    func disconnect() { lock.withLock { input?.finish(); input = nil; _analyzer = nil; _whisper = nil; leveller = nil } }
    /// No more audio for the recognizer (Whisper's stream stays known, for `stop` to finish it).
    func finishInput() { lock.withLock { input?.finish(); input = nil } }

    func flush() { lock.withLock { wav }?.flush() }

    func end() {
        let w = lock.withLock { () -> WavWriter? in let w = wav; wav = nil; _analyzer = nil; _whisper = nil; leveller = nil; backlog = []; backlogSizes = []; return w }
        w?.close()
    }

    /// Called with the lock held.
    private func send(_ chunk: [Float], to input: AsyncStream<AnalyzerInput>.Continuation) {
        var chunk = chunk
        leveller?.process(&chunk)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(chunk.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
        guard let converter, let format = analyzerFormat else { input.yield(AnalyzerInput(buffer: buffer)); return }
        let capacity = AVAudioFrameCount(Double(chunk.count) * format.sampleRate / source.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var used = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if used { status.pointee = .noDataNow; return nil }
            used = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    /// A microphone buffer as 16 kHz mono samples.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> [Float] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var used = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if used { status.pointee = .noDataNow; return nil }
            used = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }
}
