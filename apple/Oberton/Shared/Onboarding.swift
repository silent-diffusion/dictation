import AVFoundation
import ObertonCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The first-run setup (Windows SetupWindow.xaml): the mark and "OBERTON 倍音", what Oberton is, then the steps
/// dictation needs here instead of Windows' runtimes: the microphone, Accessibility (Mac: to paste at the cursor;
/// asked here with an explanation, no longer on every launch), the speech model (the chosen Whisper model downloaded,
/// as on Windows, or Apple Speech's for the language), and whether Apple Intelligence is ready. Shown until it
/// finishes; QUIT (or closing it) leaves it for the next start, CANCEL stops a run, CONTINUE SETUP picks it up again.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    /// Called by START USING OBERTON.
    var finish: () -> Void

    /// Where earlier versions kept "the setup is done": the app's preferences, now moved into the data folder.
    static let doneKey = "setupDone"
    /// A setup was started and not finished (Windows finds the runtimes it left): it opens on CONTINUE SETUP.
    static let startedKey = "setupStarted"

    /// The setup's mark in the data folder (Windows' runtime.json): once it is there the setup is done, and when the data
    /// folder is deleted the setup runs again, as on Windows (RuntimeInstaller.IsInstalled).
    static var marker: URL { AppPaths.dataDir.appending(path: "setup.json") }

    static var isDone: Bool {
        get {
            if FileManager.default.fileExists(atPath: marker.path) { return true }
            guard UserDefaults.standard.bool(forKey: doneKey) else { return false }
            // Done before the mark existed: written once (not into a test run's own data folder).
            if !AppPaths.isOverridden {
                isDone = true
                UserDefaults.standard.removeObject(forKey: doneKey)
            }
            return true
        }
        set {
            if newValue {
                let stamp = ["completed": ISO8601DateFormatter().string(from: .now), "version": Distribution.version]
                if let data = try? JSONSerialization.data(withJSONObject: stamp, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: marker, options: .atomic)
                }
                UserDefaults.standard.removeObject(forKey: startedKey)
            } else {
                try? FileManager.default.removeItem(at: marker)
            }
        }
    }

    enum Phase: Equatable { case plan, running, done }
    @State private var phase = Phase.plan
    @State private var step = 0
    @State private var stepTitle = ""
    @State private var fraction: Double?
    @State private var detail = ""
    @State private var error: String?
    /// A run stopped (cancelled or failed): the progress panel stays.
    @State private var stopped = false
    /// A run was started before, here or at an earlier start: the button says CONTINUE SETUP (also while it runs).
    @State private var resume = UserDefaults.standard.bool(forKey: OnboardingView.startedKey)
    @State private var runTask: Task<Void, Never>?
    @State private var mic = OnboardingView.micState
    #if os(macOS)
    @State private var accessibility = Distribution.accessibilityAllowed
    private let accessibilityPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    #endif

    init(finish: @escaping () -> Void) { self.finish = finish }

    #if DEBUG
    /// The snapshots: the setup as it looks while downloading, and when done.
    init(snapshot: Phase, step: Int, title: String, fraction: Double?, detail: String) {
        finish = {}
        _phase = State(initialValue: snapshot)
        _step = State(initialValue: step)
        _stepTitle = State(initialValue: title)
        _fraction = State(initialValue: fraction)
        _detail = State(initialValue: detail)
        _speechReady = State(initialValue: snapshot == .done)
    }
    #endif

    /// The Whisper model this setup downloads: the one a new install picked for this device (AppModel), or one chosen
    /// in Settings that isn't downloaded yet; nil when Apple Speech is all there is to get.
    private var whisperToGet: String? {
        if let id = model.pendingSpeechModel, !id.isEmpty { return id }
        if let id = model.settings.whisperModel, !WhisperModels.isDownloaded(id) { return id }
        return nil
    }

    private var steps: [String] {
        var all = ["Microphone"]
        #if os(macOS)
        all.append("Accessibility")
        #endif
        all.append("Speech model")
        if whisperToGet != nil { all.append("Whisper") }
        #if os(macOS)
        // The direct download gets Windows' local AI in setup (LocalAISetup): the runtime, then its model.
        if aiInSetup { all += LocalAISetup.setupSteps(runtimeInstalled: OllamaRuntime.isInstalled); return all }
        #endif
        all.append("Apple Intelligence")
        return all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 5).fill(ob.ink).frame(width: 36, height: 36)
                    .overlay(Circle().fill(ob.paper).frame(width: 11, height: 11))
                Text("OBERTON").font(Ob.mono(16, .bold)).padding(.leading, 12)
                Decor("倍音", size: 14).padding(.leading, 10)
            }
            Text("DICTATION THAT NEVER LEAVES YOUR \(Device.noun.uppercased())").font(Ob.mono(26, .bold))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 22)
            Rule().padding(.top, 10)
            Text("One download and you can talk into any app. After this, Oberton works offline: no accounts, no cloud, no telemetry.")
                .font(Ob.sans(15)).foregroundStyle(ob.muted).lineSpacing(Ob.lineSpacing(15, lineHeight: 22))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)

            VStack(spacing: 0) {
                row(done: mic == .granted, warn: mic == .denied, name: "Microphone",
                    what: mic == .granted ? "Allowed" : mic == .denied ? "Not allowed: turn it on in \(settingsApp) › Privacy & Security › Microphone"
                        : "Oberton listens only while you dictate") {
                    if mic == .denied { openPrivacy("Privacy_Microphone") }
                }
                #if os(macOS)
                Hairline()
                row(done: accessibility, warn: false, name: "Accessibility", what: accessibility ? "Allowed" : Self.accessibilityWhy) {
                    if !accessibility { openPrivacy("Privacy_Accessibility") }
                }
                #endif
                Hairline()
                row(done: speechReady, warn: false, name: "Speech model",
                    what: whisperToGet ?? model.settings.whisperModel ?? "Apple Speech · \(languageName) · downloaded once, then works offline") {}
                Hairline()
                #if os(macOS)
                if aiInSetup || aiFromSetup {
                    // Windows' plan row "Cleanup model · qwen2.5:3b via Ollama".
                    row(done: aiFromSetup, warn: false, name: "Cleanup model", what: LocalCatalog.defaultModel + " via Ollama") {}
                } else { appleRow }
                #else
                appleRow
                #endif
                if phase != .plan || stopped {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(stepTitle).font(Ob.sans(13, .semibold))
                        ProgressBar(fraction: phase == .done ? 1 : stopped ? fraction ?? 0 : fraction).frame(height: 6).padding(.top, 8)
                        // Always there, one empty line when there is nothing to say (Windows' DetailText).
                        Text(detail.isEmpty ? " " : detail).font(Ob.sans(12)).foregroundStyle(ob.muted)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    }
                    .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Hairline() }
                }
            }
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
            .padding(.top, 24)

            #if os(macOS)
            // Read aloud's Ctrl+Space is also macOS's input-source shortcut when that is on: said here, with another key.
            SystemShortcutClash(top: 16)
            #endif

            if let error {
                // Ob.Error: the accent (red only ever means recording).
                Text(error).font(Ob.sans(Ob.body)).foregroundStyle(ob.accent).fixedSize(horizontal: false, vertical: true).padding(.top, 16)
            }

            HStack(spacing: 16) {
                Text(planText)
                    .font(Ob.sans(12)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    // QUIT, which turns into CANCEL while the setup runs; hidden once it is done.
                    if phase == .running {
                        Button("Cancel") { runTask?.cancel() }.buttonStyle(CapsuleButtonStyle(kind: .quiet, height: 40))
                    } else if phase != .done {
                        #if os(macOS)
                        Button("Quit") {
                            // DialogResult false: Oberton exits without starting (App.xaml.cs).
                            Log.info("Setup not completed; exiting")
                            model.cancelWhisperDownload()
                            NSApp.terminate(nil)
                        }
                        .buttonStyle(CapsuleButtonStyle(kind: .quiet, height: 40))
                        #endif
                    }
                    Button(phase == .done ? "Start using Oberton" : resume ? "Continue setup" : "Set up") {
                        if phase == .done { finish() } else { runTask = Task { await run() } }
                    }
                    .buttonStyle(CapsuleButtonStyle(kind: .primary, height: 40))
                    .keyboardShortcut(.defaultAction)
                    .disabled(phase == .running)
                }
            }
            .padding(.top, 24)
        }
        .padding(EdgeInsets(top: 40, leading: 44, bottom: 32, trailing: 44))
        .foregroundStyle(ob.ink)
        .background(ob.paper)
        #if os(macOS)
        // Windows' Width="640" is the whole window, its 7 px frames included.
        .frame(width: 626)
        .onReceive(accessibilityPoll) { _ in
            accessibility = Distribution.accessibilityAllowed
            mic = Self.micState
        }
        #endif
    }

    private var appleRow: some View {
        row(done: AppleIntelligenceBackend.unavailableReason == nil, warn: false, name: "Apple Intelligence",
            what: AppleIntelligenceBackend.unavailableReason.map { $0 + " Until then, profiles that use it insert what you said as is." }
                ?? "Ready: tidies up your dictation on this \(Device.noun)") {}
    }

    #if os(macOS)
    /// This setup downloads the local AI (a new install of the direct download), and whether it has done so.
    private var aiInSetup: Bool { LocalAISetup.shared.setupGetsAI }
    @State private var aiFromSetup = false
    #endif

    /// One plan row: a check once it's done, an "i" note while not (Windows' hardware row), the name and what it is.
    private func row(done: Bool, warn: Bool, name: String, what: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                // Not OK is muted, as Windows' setup draws it: red only ever means recording.
                StepMark(done: done, color: done ? ob.ink : ob.muted).frame(width: 18, height: 18).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Ob.sans(14))
                    Text(what).font(Ob.mono(12)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 11, leading: 18, bottom: 11, trailing: 18))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyTabStop(radius: 0, action: action)
    }

    // MARK: Running

    @State private var speechReady = false

    private var languageName: String { Locale.current.localizedString(forIdentifier: model.settings.speechLocale.identifier) ?? model.settings.language }

    private func begin(_ n: Int, _ title: String, _ text: String = "") {
        step = n
        stepTitle = "Step \(n) of \(steps.count): \(title)"
        fraction = nil
        detail = text
    }

    /// "About 1.6 GB in total, saved to ~/Library/…" (Windows' plan line), or Apple's own download.
    private var planText: String {
        if let id = whisperToGet, let m = WhisperModels.model(id) {
            // The whole path, as Windows prints it (in the App Store build, inside Oberton's container).
            return "About \(m.size) in total, saved to \(AppPaths.dataDir.path)."
        }
        return "The speech model is a one-time download from Apple, a few hundred MB, kept by the system."
    }

    /// A problem worded for the user (Windows' UserFacingException).
    private struct Problem: Error { var message: String }

    private func run() async {
        phase = .running
        error = nil
        stopped = false
        UserDefaults.standard.set(true, forKey: Self.startedKey)
        do {
            try await runSteps()
        } catch is CancellationError {
            fail("Setup was cancelled. Click Continue setup to pick up where it left off.")
        } catch let problem as Problem {
            fail(problem.message)
        } catch let problem as UserFacingError {
            fail(problem.message)
        } catch {
            Log.error("Setup failed", error)
            fail("Setup failed unexpectedly: \(error.localizedDescription)\nDetails are in \(Log.dir.path)")
        }
        runTask = nil
    }

    private func fail(_ message: String) {
        error = message
        stopped = true
        resume = true
        phase = .plan
    }

    private func runSteps() async throws {
        Log.info("Runtime setup starting (speech model \(whisperToGet ?? model.settings.whisperModel ?? "Apple Speech"), AI model \(model.settings.defaultModel.shortName))")
        var n = 0
        n += 1
        begin(n, "Microphone", "Allow the microphone when asked.")
        await Self.requestMic()
        mic = Self.micState
        try Task.checkCancellation()
        #if os(macOS)
        n += 1
        begin(n, "Accessibility", accessibility ? "" : "Turn on Oberton under Privacy & Security › Accessibility. You can do this later, too: until then the text is copied, ready to paste.")
        if !accessibility { Distribution.requestAccessibility() }
        try Task.checkCancellation()
        #endif
        n += 1
        // Apple Speech for the language first: dictation works with it until the Whisper model is in.
        let whisper = whisperToGet
        do {
            begin(n, "Speech model", "Checking \(languageName)…")
            do {
                let downloaded = try await LiveTranscriber.download(locale: model.settings.speechLocale) { f in
                    fraction = f
                    if let f, f < 1 { detail = "Downloading the \(languageName) speech model" + Self.percent(f) }
                }
                speechReady = whisper == nil
                detail = downloaded ? "Downloaded." : "Already on this \(Device.noun)."
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as URLError {
                Log.warn("Setup: speech model download failed: \(e.localizedDescription)")
                throw Problem(message: "A download failed. Check your internet connection and click Retry.")
            }
        }
        if let whisper, WhisperModels.model(whisper) != nil {
            try Task.checkCancellation()
            n += 1
            try await downloadWhisper(whisper, step: n)
        }
        try Task.checkCancellation()
        #if os(macOS)
        if aiInSetup {
            final class Step { var n: Int; init(_ n: Int) { self.n = n } }
            let step = Step(n)
            try await LocalAISetup.shared.runInSetup(model, begin: { next, title, text in
                if next { step.n += 1 }
                begin(step.n, title, text)
            }, progress: { f in
                fraction = f
                if let f { detail = f < 1 ? Self.percent(f) : "" } // Windows: the detail, then "  (42%)"
            })
            aiFromSetup = true
            n = step.n
        } else {
            n += 1
            begin(n, "Apple Intelligence", AppleIntelligenceBackend.unavailableReason ?? "Ready.")
            AppleIntelligenceBackend.warmUp()
        }
        #else
        n += 1
        begin(n, "Apple Intelligence", AppleIntelligenceBackend.unavailableReason ?? "Ready.")
        AppleIntelligenceBackend.warmUp()
        #endif
        Log.info("Runtime setup complete")
        // Done from here on, also if the window is closed now (Windows has written runtime.json by this point).
        Self.isDone = true
        phase = .done
        stepTitle = "All set!"
        fraction = 1
        #if os(macOS)
        detail = "Press \(model.settings.hotkey) in any app to start dictating, and press it again to stop."
        #else
        detail = "Tap Dictate on the dashboard to start, and tap it again to stop. The text is copied, ready to paste."
        #endif
        model.warmUp()
    }

    /// Windows' step 4: "Downloading the speech model (large-v3-turbo)", through the app's own download (the one the
    /// model lists show), with "  (42%)" after the detail.
    private func downloadWhisper(_ id: String, step: Int) async throws {
        let size = "About \(Self.whisperMB(id).formatted(.number.grouping(.automatic))) MB"
        begin(step, "Downloading the speech model (\(id))", size)
        if !WhisperModels.isDownloaded(id) {
            if model.whisperDownload?.id != id {
                if model.pendingSpeechModel == id { model.startDefaultSpeechDownload() } else { model.downloadWhisper(id) }
            }
            while model.whisperDownload?.id == id {
                if Task.isCancelled {
                    model.cancelWhisperDownload()
                    throw CancellationError()
                }
                fraction = model.whisperDownload?.fraction
                detail = size + (fraction.map { $0 < 1 ? Self.percent($0) : "" } ?? "")
                try? await Task.sleep(for: .milliseconds(200))
            }
            try Task.checkCancellation()
            guard WhisperModels.isDownloaded(id) else {
                // RunToolAsync's message, then what went wrong (Windows adds the tool's last lines).
                let why = model.whisperDownloadError.map { "\n\n" + $0 } ?? ""
                throw Problem(message: "Downloading the speech model failed. Check your internet connection and click Retry." + why)
            }
        }
        // Already there: AppModel switches dictation over to it.
        if model.pendingSpeechModel == id { model.startDefaultSpeechDownload() }
        speechReady = true
        fraction = 1
        detail = ""
    }

    /// "  (42%)", rounded as Windows' {g:P0}.
    private static func percent(_ f: Double) -> String { "  (\(f.formatted(.percent.precision(.fractionLength(0)))))" }

    /// Windows' WhisperModelMb: the rough download of a speech model, in MB, for "About 1,550 MB".
    static func whisperMB(_ id: String) -> Int {
        switch id {
        case "large-v3-turbo": 1550
        case "large-v3": 3000
        case "distil-large-v3": 1500
        case "medium.en", "medium": 1500
        case "small.en", "small": 470
        case "base.en", "base": 145
        case "tiny.en", "tiny": 75
        default: 1000
        }
    }

    // MARK: Permissions

    #if os(macOS)
    /// What Accessibility is for, in this build. The direct build reads other apps' text (Windows does it through UI
    /// Automation, which needs no permission; its General page words it the same way); the App Store build can't.
    static var accessibilityWhy: String {
        Distribution.isDirect
            ? "To put the text where your cursor is, Oberton presses ⌘V for you in the app you were using. It also reads a sentence or two around the cursor so the text fits in, the text you select for Read aloud, and the window's title for History. macOS allows this only once you turn Oberton on under Privacy & Security › Accessibility. The text around the cursor is never stored or sent anywhere."
            : "To put the text where your cursor is, Oberton presses ⌘V for you in the app you were using, and ⌘C to copy the text you select for Read aloud. macOS lets an app do that only once you allow it under Privacy & Security › Accessibility. Apart from that, Oberton doesn't read other apps."
    }
    #endif

    enum MicState: String { case unknown, granted, denied }

    static var micState: MicState {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .unknown
        }
        #else
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .unknown
        }
        #endif
    }

    static func requestMic() async {
        #if os(macOS)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        #else
        if AVAudioApplication.shared.recordPermission == .undetermined { _ = await AVAudioApplication.requestRecordPermission() }
        #endif
    }

    private var settingsApp: String { Device.noun == "Mac" ? "System Settings" : "Settings" }

    private func openPrivacy(_ pane: String) {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }
}

/// The check (done) or the "i"-style note (not yet), drawn as on Windows' setup window.
private struct StepMark: View {
    var done: Bool
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 18
            var p = Path()
            if done {
                p.move(to: CGPoint(x: 2.5 * s, y: 9.5 * s)); p.addLine(to: CGPoint(x: 6.5 * s, y: 13.5 * s)); p.addLine(to: CGPoint(x: 15 * s, y: 4.5 * s))
            } else {
                p.move(to: CGPoint(x: 9 * s, y: 3 * s)); p.addLine(to: CGPoint(x: 9 * s, y: 10.5 * s))
                p.move(to: CGPoint(x: 9 * s, y: 14 * s)); p.addLine(to: CGPoint(x: 9 * s, y: 14.1 * s))
            }
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }
}

/// A flat bar: ink fill on a hairline track; nil = still waiting (a short slice that slides).
/// A thin bar: the fraction done, or a sliding piece while it is unknown (setup, model downloads).
struct ProgressBar: View {
    var fraction: Double?
    @Environment(\.ob) private var ob
    var body: some View {
        GeometryReader { g in
            // Rounded track and indicator, as the Fluent ProgressBar (its accent is the ink here).
            ZStack(alignment: .leading) {
                Capsule().fill(ob.subtle)
                if let fraction {
                    Capsule().fill(ob.ink).frame(width: g.size.width * min(1, max(0, fraction)))
                } else {
                    TimelineView(.animation) { t in
                        let x = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Capsule().fill(ob.ink).frame(width: g.size.width * 0.25).offset(x: g.size.width * (x * 1.25 - 0.25))
                    }
                    .clipShape(Capsule())
                }
            }
        }
    }
}
