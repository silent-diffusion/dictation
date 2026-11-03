import AVFoundation
import ObertonCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The first-run setup (Windows SetupWindow.xaml): the mark and "OBERTON 倍音", what Oberton is, then the steps
/// dictation needs here instead of Windows' downloads: the microphone, Accessibility (Mac: to paste at the cursor;
/// asked here with an explanation, no longer on every launch), the speech model for the language, and whether Apple
/// Intelligence is ready. Shown once; QUIT leaves it for the next start, as on Windows.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    /// Called by START USING OBERTON.
    var finish: () -> Void

    static let doneKey = "setupDone"
    static var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: doneKey) }
        set { UserDefaults.standard.set(newValue, forKey: doneKey) }
    }

    enum Phase: Equatable { case plan, running, done }
    @State private var phase = Phase.plan
    @State private var step = 0
    @State private var stepTitle = ""
    @State private var fraction: Double?
    @State private var detail = ""
    @State private var error: String?
    @State private var mic = OnboardingView.micState
    #if os(macOS)
    @State private var accessibility = CGPreflightPostEventAccess()
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

    private var steps: [String] {
        #if os(macOS)
        ["Microphone", "Accessibility", "Speech model", "Apple Intelligence"]
        #else
        ["Microphone", "Speech model", "Apple Intelligence"]
        #endif
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
            Text("Talk into any app. Speech is recognized on this \(Device.noun) and Apple Intelligence tidies it up here too: no accounts, no cloud, no telemetry. First, a few things \(Device.noun == "Mac" ? "macOS" : "iOS") asks you to allow.")
                .font(Ob.sans(15)).foregroundStyle(ob.muted).lineSpacing(7).fixedSize(horizontal: false, vertical: true).padding(.top, 8)

            VStack(spacing: 0) {
                row(done: mic == .granted, warn: mic == .denied, name: "Microphone",
                    what: mic == .granted ? "Allowed" : mic == .denied ? "Not allowed: turn it on in \(settingsApp) › Privacy & Security › Microphone"
                        : "Oberton listens only while you dictate") {
                    if mic == .denied { openPrivacy("Privacy_Microphone") }
                }
                #if os(macOS)
                Hairline()
                row(done: accessibility, warn: false, name: "Accessibility",
                    what: accessibility ? "Allowed" : "To put the text where your cursor is, Oberton presses ⌘V for you in the app you were using. macOS lets an app do that only once you allow it under Privacy & Security › Accessibility. Oberton doesn't read other apps.") {
                    if !accessibility { openPrivacy("Privacy_Accessibility") }
                }
                #endif
                Hairline()
                row(done: speechReady, warn: false, name: "Speech model",
                    what: "Apple Speech · \(languageName) · downloaded once, then works offline") {}
                Hairline()
                row(done: AppleIntelligenceBackend.unavailableReason == nil, warn: false, name: "Apple Intelligence",
                    what: AppleIntelligenceBackend.unavailableReason.map { $0 + " Until then, profiles that use it insert what you said as is." }
                        ?? "Ready: tidies up your dictation on this \(Device.noun)") {}
                if phase != .plan {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(stepTitle).font(Ob.sans(13, .semibold))
                        ProgressBar(fraction: phase == .done ? 1 : fraction).frame(height: 6).padding(.top, 8)
                        if !detail.isEmpty {
                            Text(detail).font(Ob.sans(12)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                        }
                    }
                    .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Hairline() }
                }
            }
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
            .padding(.top, 24)

            if let error {
                Text(error).font(Ob.sans(13)).foregroundStyle(ob.record).fixedSize(horizontal: false, vertical: true).padding(.top, 16)
            }

            HStack(spacing: 16) {
                Text("The speech model is a one-time download from Apple, a few hundred MB, kept by the system.")
                    .font(Ob.sans(12)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    if phase != .done {
                        #if os(macOS)
                        Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.quiet).disabled(phase == .running)
                        #endif
                    }
                    Button(phase == .done ? "Start using Oberton" : error != nil ? "Continue setup" : "Set up") {
                        if phase == .done { Self.isDone = true; finish() } else { Task { await run() } }
                    }
                    .buttonStyle(.primary)
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
        .frame(width: 640)
        .onReceive(accessibilityPoll) { _ in
            accessibility = CGPreflightPostEventAccess()
            mic = Self.micState
        }
        #endif
    }

    /// One plan row: a check once it's done, an "i" note while not (Windows' hardware row), the name and what it is.
    private func row(done: Bool, warn: Bool, name: String, what: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                StepMark(done: done, color: done ? ob.ink : warn ? ob.record : ob.muted).frame(width: 18, height: 18).padding(.top, 1)
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
    }

    // MARK: Running

    @State private var speechReady = false

    private var languageName: String { Locale.current.localizedString(forIdentifier: model.settings.language) ?? model.settings.language }

    private func begin(_ n: Int, _ title: String, _ text: String = "") {
        step = n
        stepTitle = "Step \(n) of \(steps.count): \(title)"
        fraction = nil
        detail = text
    }

    private func run() async {
        phase = .running
        error = nil
        var n = 0
        n += 1
        begin(n, "Microphone", "Allow the microphone when asked.")
        await Self.requestMic()
        mic = Self.micState
        #if os(macOS)
        n += 1
        begin(n, "Accessibility", accessibility ? "" : "Turn on Oberton under Privacy & Security › Accessibility. You can do this later, too: until then the text is copied, ready to paste.")
        if !accessibility { CGRequestPostEventAccess() }
        #endif
        n += 1
        begin(n, "Speech model", "Checking \(languageName)…")
        do {
            let downloaded = try await LiveTranscriber.download(locale: Locale(identifier: model.settings.language)) { f in
                fraction = f
                if let f, f < 1 { detail = "Downloading the \(languageName) speech model  (\(Int(f * 100))%)" }
            }
            speechReady = true
            detail = downloaded ? "Downloaded." : "Already on this \(Device.noun)."
        } catch {
            self.error = error.localizedDescription
            phase = .plan
            return
        }
        n += 1
        begin(n, "Apple Intelligence", AppleIntelligenceBackend.unavailableReason ?? "Ready.")
        AppleIntelligenceBackend.warmUp()
        Log.info("Setup finished (microphone \(mic), speech model ready)")
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

    // MARK: Permissions

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
private struct ProgressBar: View {
    var fraction: Double?
    @Environment(\.ob) private var ob
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(ob.subtle)
                if let fraction {
                    Rectangle().fill(ob.ink).frame(width: g.size.width * min(1, max(0, fraction)))
                } else {
                    TimelineView(.animation) { t in
                        let x = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Rectangle().fill(ob.ink).frame(width: g.size.width * 0.25).offset(x: g.size.width * (x * 1.25 - 0.25))
                    }
                    .clipped()
                }
            }
        }
    }
}
