import AVFoundation
import ObertonCore
import SwiftUI

/// At a glance: on the Mac everything fits the window and nothing scrolls; rows share the height and meters scale to
/// their cells (DashboardPage.xaml). On iPhone the same cells stack and scroll. Like Windows' 3-second timer, the page is
/// drawn again every 3 s (the clock, the unload countdown, the dials) and at once when the dictation moves on.
struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var toast: String?
    @State private var toastShown = false
    @State private var toastShows = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3)) { context in
            if sizeClass == .compact { phone(now: context.date) } else { desk(now: context.date) }
        }
        // A short note (what Unload everything did, or why inserting failed): 34 above the panel's bottom edge, which
        // is 14 above the page's.
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(Ob.mono(12)).foregroundStyle(ob.onInk)
                    .frame(width: min(TextFit.width(toast, font: Ob.monoFont(12)), 480), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 17).fill(ob.ink))
                    .opacity(toastShown ? 1 : 0)
                    .padding(.bottom, 48)
                    .allowsHitTesting(false)
            }
        }
        // Which AI models are in memory, asked every 3 s while the dashboard shows (Windows' LoadedModelsAsync).
        .onAppear { model.watchLoadedAI(true) }
        .onDisappear { model.watchLoadedAI(false) }
    }

    /// Fades in over 120 ms, stays 2.5 s and fades out over 300 ms; a new note starts the 2.5 s again.
    private func showToast(_ message: String) {
        toast = message
        toastShows += 1
        let show = toastShows
        withAnimation(.linear(duration: 0.12)) { toastShown = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard show == toastShows else { return }
            withAnimation(.linear(duration: 0.3)) { toastShown = false }
        }
    }

    private func desk(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(now: now, phone: false)
            // The panel: its top and left edges here, each cell draws its right and bottom edges. Star rows and columns
            // with Windows' minimums: the notes column at least 250 wide, History 240, the rows 150 and 120 tall.
            GeometryReader { geo in
                let rows = Self.split(geo.size.height, 1.3, 1.15, min: 150, 120)
                let top = Self.split(geo.size.width, 1.75, 1, min: 0, 250)
                let bottom = Self.split(geo.size.width, 4, 2, min: 0, 240)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Cell { SignalPathCell(now: now) }.frame(width: top.0)
                        Cell(padding: EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12)) { NotesCell() }.frame(width: top.1)
                    }
                    .frame(height: rows.0)
                    HStack(spacing: 0) {
                        meters.frame(width: bottom.0)
                        Cell(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) {
                            HistoryCell(last: model.lastEntry, now: now, toast: showToast)
                        }
                        .frame(width: bottom.1)
                    }
                    .frame(height: rows.1)
                }
            }
            .overlay(alignment: .top) { Hairline() }
            .overlay(alignment: .leading) { Hairline(vertical: true) }
            Readout(footer).lineLimit(1).truncationMode(.tail).padding(.top, 8)
        }
        .padding(EdgeInsets(top: 20, leading: 28, bottom: 14, trailing: 28))
    }

    /// Two star sizes (WPF's `1.3*` and `1.15*`) sharing `total`, each kept at least its minimum, as a Grid does.
    static func split(_ total: CGFloat, _ a: CGFloat, _ b: CGFloat, min minA: CGFloat, _ minB: CGFloat) -> (CGFloat, CGFloat) {
        var first = total * a / (a + b)
        if total - first < minB { first = total - minB }
        first = max(first, minA)
        return (first, max(total - first, minB))
    }

    private func phone(now: Date) -> some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 0) {
                header(now: now, phone: true)
                VStack(spacing: 0) {
                    Cell { SignalPathCell(now: now) }.frame(height: 330)
                    Cell(padding: EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12)) { NotesCell() }.frame(height: 200)
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow { meter(0).frame(minHeight: 150); meter(1).frame(minHeight: 150) }
                        GridRow { meter(2).frame(minHeight: 150); meter(3).frame(minHeight: 150) }
                    }
                    Cell(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) {
                        HistoryCell(last: model.lastEntry, now: now, toast: showToast)
                    }
                    .frame(height: 260)
                }
                .overlay(alignment: .top) { Hairline() }
                .overlay(alignment: .leading) { Hairline(vertical: true) }
                Readout(footer).padding(.top, 8)
            }
            .padding(16)
        }
    }

    /// "DASHBOARD 計器" with the clock at the right, an ink rule, and the summary on one line (DashboardPage.xaml's own
    /// header: the decor 12 from the title and 1 above its bottom, the clock 4 above the rule, the summary 12.5 and 6
    /// under the rule). On iPhone the title is smaller, there is no clock, and the summary wraps.
    private func header(now: Date, phone: Bool) -> some View {
        let size: CGFloat = phone ? 26 : 30
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                Text("DASHBOARD").font(Ob.mono(size, .bold)).lineLimit(1).truncationMode(.tail)
                Decor("計器", size: size - 4, color: ob.divider, weight: .bold).fixedSize().padding(.leading, 12).padding(.bottom, 1)
                Spacer(minLength: 16)
                if !phone { Readout(clock(now)).fixedSize().padding(.bottom, 4).layoutPriority(1) }
            }
            Rule().padding(.top, 6)
            Text(summary).font(Ob.sans(12.5)).foregroundStyle(ob.muted)
                .lineLimit(phone ? nil : 1).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: phone)
                .padding(.top, 6)
        }
        .padding(.bottom, 14)
    }

    private var meters: some View {
        HStack(spacing: 0) { ForEach(0..<4, id: \.self) { meter($0) } }
    }

    /// The four meters. The figures come from the daily counts, which survive History being trimmed, cleared or off;
    /// "best day" is the best of the last 14 days (UsageStore.PerDay).
    @ViewBuilder private func meter(_ i: Int) -> some View {
        let days = model.usage.perDay(14)
        let today = days.last ?? UsageDay()
        switch i {
        case 0:
            let best = days.map(\.words).max() ?? 0
            // The same figures over time: Analytics (DashboardPage.DialPage).
            meterCell(to: .analytics) {
                RingMeter(fraction: best > 0 ? Double(today.words) / Double(best) : 0, value: today.words.formatted(), label: "Dictated today",
                          sub: best > 0 ? "words · best day \(best.formatted())" : "no dictation yet", accent: true)
            }
        case 1:
            let best = days.map(\.wordsRead).max() ?? 0
            meterCell(to: .readAloud) {
                RingMeter(fraction: best > 0 ? Double(today.wordsRead) / Double(best) : 0, value: today.wordsRead.formatted(),
                          label: "Read aloud today", sub: best > 0 ? "words · best day \(best.formatted())" : "nothing read yet")
            }
        case 2:
            // The last three dictations with the current speech and AI models, leaving out any that had to load a model.
            // The models by their ids, as Windows writes them ("large-v3-turbo + qwen2.5:3b").
            let p = model.activeProfile
            let ai = model.aiModelName(p)
            let (turn, count) = model.usage.recentTurnaround(speechModel: model.speechModelName, aiModel: ai)
            meterCell(to: .analytics) {
                FanMeter(fraction: min(max((turn ?? 0) / 10, 0), 1),
                         value: turn.map { $0.formatted(.number.precision(.fractionLength(1)).grouping(.never)) + " s" } ?? "—",
                         label: "Turnaround",
                         sub: count == 0 ? "no runs yet with these models loaded"
                             : "last \(count) · " + model.speechShortName + (ai.isEmpty ? ", no AI" : " + " + SignalPathCell.aiTitle(model.processor.model(for: p)))
                                 + ", models already loaded")
            }
        default:
            // The speech model (DashboardPage's speech dial): busy, off, on (kept or let go right after use), or the
            // minutes left until it unloads.
            let minutes = model.settings.unloadAfterMinutes
            meterCell(settings: .unloading, footer: AnyView(unloadButton)) {
                if model.phase.isBusy {
                    RingMeter(fraction: 1, value: "busy", label: "Speech model", sub: "dictating now", accent: true)
                } else if !model.speechLoaded {
                    RingMeter(fraction: 0, value: "off", label: "Speech model", sub: "loads when you dictate")
                } else if minutes > 0, let left = model.unloadCountdown {
                    RingMeter(fraction: left / Double(minutes * 60), value: left >= 60 ? "\(Int((left / 60).rounded(.up))) min" : "<1 min",
                              label: "Speech model", sub: "until it unloads", accent: true,
                              valueAction: unloadSpeechNow, valueTip: "Click to unload the speech model now")
                } else {
                    RingMeter(fraction: 1, value: "on", label: "Speech model", sub: minutes < 0 ? "unloads right after use" : "stays loaded",
                              valueAction: unloadSpeechNow, valueTip: "Click to unload the speech model now")
                }
            }
        }
    }

    /// UNLOAD EVERYTHING, at the bottom of the speech meter: the speech model, the AI model and the voice. A QuietButton
    /// with FontSize 10 and Padding 12,4, never cut short.
    private var unloadButton: some View {
        Button("Unload everything") {
            Task {
                showToast(await model.unloadNow(speech: true, ai: true, voice: true))
                await model.refreshLoadedAI()
            }
        }
        .buttonStyle(CapsuleButtonStyle(kind: .quiet, size: 10, padding: 12))
        .fixedSize()
        .disabled(model.phase.isBusy)
        .help("Free the memory of the speech model, the AI model and the Read aloud voice now (they load again when needed)")
        .padding(.top, 4).padding(.bottom, 2)
    }

    /// The speech dial's number: free the speech model's memory right away.
    private func unloadSpeechNow() {
        Task { _ = await model.unloadNow(speech: true, ai: false, voice: false) }
    }

    private func meterCell<C: View>(to section: Section? = nil, settings: SettingsSection? = nil, footer: AnyView? = nil,
                                    @ViewBuilder _ content: () -> C) -> some View {
        Cell(link: true, padding: EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)) {
            VStack(spacing: 0) {
                content()
                if let footer { footer }
            }
        }
        .handCursor()
        .onTapGesture {
            if let settings { nav.goSettings(settings) } else if let section { nav.go(section) }
        }
    }

    private var summary: String {
        let p = model.activeProfile.name
        if model.phase.isBusy { return "Dictating with \(p) right now." }
        #if os(macOS)
        return "Press \(model.settings.hotkey) to dictate with \(p). Select text and press \(model.settings.speakHotkey) to hear it."
        #else
        return "Tap Dictate to dictate with \(p). The text is copied, ready to paste."
        #endif
    }

    /// "TUESDAY 3 NOVEMBER — 15:41": Windows' `dddd d MMMM — t`, day first whatever the region's order.
    private func clock(_ now: Date) -> String {
        DateText.weekdayDayMonth(now) + " — " + DateText.time(now)
    }

    private var footer: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var parts = ["Oberton \(version)", "\(model.usage.totalWords.formatted()) words dictated in all",
                     model.settings.cloud.keepOffline ? "everything stays on this \(Device.noun)" : "cloud AI allowed"]
        #if os(macOS)
        parts.append("\(model.settings.cycleProfileHotkey) switches profile")
        #endif
        let m = model.settings.unloadAfterMinutes
        let unload = m < 0 ? "right after each use" : m == 0 ? "never" : m >= 60 ? "\((Double(m) / 60).formatted(.number.precision(.fractionLength(0...1)))) h" : "\(m) min"
        parts.append("models unload " + (m < 0 ? unload : "after \(unload) unused"))
        return parts.joined(separator: "  //  ")
    }
}

// MARK: - Signal path

/// One step of the signal path, as the dashboard draws it.
struct PathNode {
    var label: String
    var title: String
    var status: String
    var state: DotState
    var open: () -> Void
}

/// MIC → SPEECH → AI → INSERT, with READ ALOUD branching off. Each step lights the moment it works, and stays lit at
/// least 1.5 s so even a quick one is seen (DashboardPage.MinLit).
struct SignalPathCell: View {
    var now: Date
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    /// When each step began to work (DashboardPage._litSince), and a redraw 1.6 s after each change (_holdTimer).
    @State private var litSince: [String: Date] = [:]
    @State private var held = 0
    @State private var hold: Task<Void, Never>?

    var body: some View {
        let _ = held
        VStack(spacing: 4) {
            HStack {
                Readout("Signal path", size: 12)
                Spacer()
                #if os(macOS)
                KeyChips(hotkey: model.settings.hotkey)
                Readout("→ Start", size: 12).padding(.leading, 6)
                #else
                Button(model.phase == .recording ? "■ Stop" : "● Dictate") { model.toggleDictation() }
                    .buttonStyle(.primary)
                    .disabled(model.phase.isBusy && model.phase != .recording)
                #endif
            }
            GeometryReader { geo in
                SignalPathDrawing(nodes: nodes, voice: voice, readsAloud: model.activeProfile.readAloudAfterInsert, size: geo.size)
            }
            HStack {
                #if os(macOS)
                Readout("Click a node to open its settings", size: 12).lineLimit(1)
                #else
                Readout("Tap a node", size: 12).lineLimit(1)
                #endif
                Spacer()
                // When the models unload ("UNLOAD IN 12:34" in the accent), redrawn with the page every 3 s.
                let note = unloadNote
                Text(note.uppercased())
                    .font(Ob.mono(12, .bold))
                    .foregroundStyle(note.hasPrefix("Unload in") ? ob.accent : ob.muted)
                    .lineLimit(1)
            }
        }
        .onChange(of: model.phase, initial: true) { old, phase in
            let at = Date(), was = Self.working(old), busy = Self.working(phase)
            for step in busy where !was.contains(step) || litSince[step] == nil { litSince[step] = at }
            for (step, since) in litSince where !busy.contains(step) && at.timeIntervalSince(since) >= Self.minLit { litSince[step] = nil }
            hold?.cancel()
            hold = Task {
                try? await Task.sleep(for: .seconds(1.6))
                if !Task.isCancelled { held += 1 }
            }
        }
    }

    private static let minLit: TimeInterval = 1.5

    /// The steps at work in a phase.
    private static func working(_ phase: AppModel.Phase) -> Set<String> {
        switch phase {
        case .starting, .recording: ["mic", "speech"]
        case .transcribing: ["speech"]
        case .processing: ["ai"]
        case .inserting, .placing: ["insert"]
        default: []
        }
    }

    /// Whether a step shows as at work: while it is, and until 1.5 s after it began.
    private func lit(_ step: String) -> Bool {
        if Self.working(model.phase).contains(step) { return true }
        if let since = litSince[step], Date().timeIntervalSince(since) < Self.minLit { return true }
        return false
    }

    /// The AI model as Windows names it on the dashboard: its id ("qwen2.5:3b", "claude-sonnet-4-5"); Apple
    /// Intelligence, which has no id, by name.
    static func aiTitle(_ id: ModelID) -> String { id.provider == .apple ? id.shortName : id.name }

    /// Whether the next dictation with this profile types while you speak (Windows: the General switch on and the
    /// profile without a preview).
    // Lane I: replace with `model.typesWhileSpeaking(p)`. Until live typing exists on the Mac nothing types while you
    // speak, so the node must not claim "// live".
    private func typesWhileSpeaking(_ p: Profile) -> Bool { false }

    private var nodes: [PathNode] {
        let p = model.activeProfile
        let micOn = lit("mic"), speechOn = lit("speech")
        // The AI lights from the moment the speech model hands it the words (loading the model counts) until its edit is done.
        let aiOn = !p.isRaw && lit("ai")
        let insertOn = lit("insert")
        let id = model.processor.model(for: p)
        let cloud = !id.isLocal || id.isOllamaCloud
        let offline = model.settings.cloud.keepOffline
        let aiLoaded = id.provider == .apple ? AppleIntelligenceBackend.unavailableReason == nil : model.aiInMemory(id)
        let aiStatus = aiOn ? (cloud || aiLoaded ? "editing" : "loading, then editing")
            : cloud ? (offline ? "blocked offline" : "ready")
            : id.provider == .apple ? (aiLoaded ? "ready" : "not ready") : aiLoaded ? "loaded" : "not loaded"
        let aiDot: DotState = aiOn ? .busy : cloud ? (offline ? .off : .ok) : aiLoaded ? .ok : .off
        // The last dictation's app; "Unknown app" when it didn't note one (HistoryEntry.AppName).
        let lastApp = model.lastEntry?.appLabel
        #if os(macOS)
        let s = model.settings
        let insertTitle = (s.insertion == .typing ? "Type" : s.insertion == .clipboard ? "Paste" : "Paste or type")
            + (typesWhileSpeaking(p) ? " // live" : p.showPreview ? " // preview" : "")
        let insertRest = lastApp.map { "last → \($0)" } ?? "at the cursor"
        #else
        let insertTitle = "Copy" + (p.showPreview ? " // preview" : "")
        let insertRest = "to the clipboard"
        #endif
        return [
            PathNode(label: "MIC", title: model.settings.microphoneName ?? "Default microphone", status: micOn ? "Recording" : "Ready", state: micOn ? .busy : .ok) {
                nav.goSettings(.microphone)
            },
            PathNode(label: "SPEECH", title: model.speechShortName,
                     status: "on-device // " + (model.phase == .transcribing ? "transcribing" : speechOn ? "listening" : model.speechModelLoaded ? "loaded" : "not loaded"),
                     state: speechOn ? .busy : model.speechModelLoaded ? .ok : .off) { nav.goSettings(.models) },
            p.isRaw
                ? PathNode(label: "AI", title: "No AI", status: p.name + " // raw words", state: .off) { nav.goProfile(p.id) }
                : PathNode(label: cloud ? "AI // CLOUD" : "AI", title: Self.aiTitle(id), status: p.name + " // " + aiStatus, state: aiDot) {
                    nav.goProfile(p.id)
                },
            PathNode(label: "INSERT", title: insertTitle, status: insertOn ? "inserting" : insertRest, state: insertOn ? .busy : .ok) {
                nav.goSettings(.general)
            },
        ]
    }

    /// The profile's voice (App.VoiceFor): its short name ("Samantha"), or "Not installed" when that voice isn't on this
    /// Mac. System voices start at once, so they are always "ready", as Windows' own voices are.
    // Lane C: Kokoro/Piper voices add Windows' "loaded" (the voice server running), "idle" and "downloads on first use".
    private var voice: PathNode {
        let id = model.activeProfile.voice ?? model.settings.ttsVoice ?? ""
        let name = id.isEmpty ? "System voice" : AVSpeechSynthesisVoice(identifier: id)?.name
        return PathNode(label: "READ ALOUD", title: name.map { String($0.components(separatedBy: " (")[0]) } ?? "Not installed",
                        status: "ready", state: .ok) { nav.go(.readAloud) }
    }

    /// "Unload in 12:34" counts down from the last dictation while anything is in memory, the speech model or an AI
    /// model; "Nothing loaded" only when neither is (DashboardPage.Build).
    private var unloadNote: String {
        let minutes = model.settings.unloadAfterMinutes
        if minutes < 0 { return "Models unload right after use" }
        if minutes == 0 { return "Models stay loaded" }
        if !model.speechLoaded && model.loadedAIModels.isEmpty { return "Nothing loaded" }
        let left = Int(max(0, Double(minutes * 60) - now.timeIntervalSince(model.lastActivity)))
        return String(format: "Unload in %02d:%02d", left / 60, left % 60)
    }
}

/// The signal path drawn at a design size and scaled to the cell: one row when there is room, otherwise two levels
/// (MIC → SPEECH over INSERT ← AI), as DashboardPage.SignalPath does.
struct SignalPathDrawing: View {
    var nodes: [PathNode]
    var voice: PathNode
    var readsAloud: Bool
    var size: CGSize
    @Environment(\.ob) private var ob

    // The Windows layout's constants.
    private let pathHeight = 210.0, pathY = 92.0, nodeR = 22.0, branchY = 188.0, stepW = 230.0
    private let twoW = 760.0, twoH = 350.0, twoY1 = 70.0, twoY2 = 220.0, twoCol0 = 190.0, twoCol1 = 545.0, twoColW = 340.0, twoFont = 1.2, twoTurnX = 735.0

    var body: some View {
        let width = min(max(pathHeight * size.width / max(size.height, 1), 4 * stepW), 2400)
        let oneRow = min(size.width / width, size.height / pathHeight)
        let two = min(size.width / twoW, size.height / twoH) * twoFont
        if oneRow < 1 && two > oneRow {
            DesignSize(width: twoW, height: twoH) { twoLevels }
        } else {
            DesignSize(width: width, height: pathHeight) { row(width: width) }
        }
    }

    private func row(width: Double) -> some View {
        let x = { (i: Int) in stepW / 2 + Double(i) * (width - stepW / 2 - 150) / Double(nodes.count - 1) }
        let last = x(nodes.count - 1), pillRight = x(nodes.count - 2) + 80
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                wire(ctx, [CGPoint(x: x(0), y: pathY), CGPoint(x: last, y: pathY)])
                for i in 0..<(nodes.count - 1) { arrow(ctx, (x(i) + x(i + 1)) / 2, pathY, 1, 0) }
                branch(ctx, [CGPoint(x: last + nodeR, y: pathY), CGPoint(x: last + 90, y: pathY), CGPoint(x: last + 90, y: branchY),
                             CGPoint(x: pillRight, y: branchY)])
            }
            ForEach(Array(nodes.enumerated()), id: \.offset) { i, n in
                PathStep(node: n, first: i == 0, width: stepW, font: 1).position(x: x(i), y: pathY - 70 + (108 + 46) / 2)
            }
            VoicePill(node: voice, readsAloud: readsAloud, font: 1)
                .fixedSize()
                .frame(width: pillRight, height: 30, alignment: .trailing)
                .position(x: pillRight / 2, y: branchY)
        }
    }

    private var twoLevels: some View {
        let pillY = twoY2 + 108
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                wire(ctx, [CGPoint(x: twoCol0 + nodeR, y: twoY1), CGPoint(x: twoCol1 - nodeR, y: twoY1)])
                arrow(ctx, (twoCol0 + twoCol1) / 2, twoY1, 1, 0)
                wire(ctx, [CGPoint(x: twoCol1 + nodeR, y: twoY1), CGPoint(x: twoTurnX, y: twoY1), CGPoint(x: twoTurnX, y: twoY2),
                           CGPoint(x: twoCol1 + nodeR, y: twoY2)])
                arrow(ctx, twoTurnX, (twoY1 + twoY2) / 2, 0, 1)
                wire(ctx, [CGPoint(x: twoCol1 - nodeR, y: twoY2), CGPoint(x: twoCol0 + nodeR, y: twoY2)])
                arrow(ctx, (twoCol0 + twoCol1) / 2, twoY2, -1, 0)
                branch(ctx, [CGPoint(x: twoCol0 - nodeR, y: twoY2), CGPoint(x: 20, y: twoY2), CGPoint(x: 20, y: pillY), CGPoint(x: 40, y: pillY)])
            }
            let spots = [(twoCol0, twoY1), (twoCol1, twoY1), (twoCol1, twoY2), (twoCol0, twoY2)]
            ForEach(Array(nodes.prefix(4).enumerated()), id: \.offset) { i, n in
                PathStep(node: n, first: i == 0, width: twoColW, font: twoFont)
                    .position(x: spots[i].0, y: spots[i].1 - 70 + (108 + 46 * twoFont) / 2)
            }
            VoicePill(node: voice, readsAloud: readsAloud, font: twoFont)
                .fixedSize()
                .frame(width: 600, height: 36, alignment: .leading)
                .position(x: 40 + 300, y: pillY)
        }
    }

    private func wire(_ ctx: GraphicsContext, _ points: [CGPoint]) {
        var p = Path()
        p.addLines(points)
        ctx.stroke(p, with: .color(ob.ink), lineWidth: 1)
    }

    private func arrow(_ ctx: GraphicsContext, _ x: Double, _ y: Double, _ dx: Double, _ dy: Double) {
        var p = Path()
        p.addLines([CGPoint(x: x - 3 * dx - 4 * dy, y: y - 3 * dy - 4 * dx), CGPoint(x: x + 3 * dx, y: y + 3 * dy),
                    CGPoint(x: x - 3 * dx + 4 * dy, y: y - 3 * dy + 4 * dx)])
        ctx.stroke(p, with: .color(ob.ink), lineWidth: 1)
    }

    private func branch(_ ctx: GraphicsContext, _ points: [CGPoint]) {
        var p = Path()
        p.addLines(points)
        ctx.stroke(p, with: .color(readsAloud ? ob.ink : ob.muted), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }
}

/// A step: its label, a dial (a ring of twelve faint ticks, the ring, the core), its title and status under it, each at
/// Windows' fixed place in the column whatever the text size (the label at the top, the dial 30 down, so its centre is
/// on the wire, the texts 108 down). Hovering lights it in the accent; clicking opens its settings.
struct PathStep: View {
    var node: PathNode
    var first: Bool
    var width: Double
    var font: Double
    @Environment(\.ob) private var ob
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .top) {
            Text(node.label).font(Ob.mono(15 * font, .bold)).foregroundStyle(hover ? ob.accent : ob.ink).lineLimit(1)
                .padding(.top, 6 - 4 * (font - 1))
            dial.frame(width: 80, height: 80).padding(.top, 30)
            VStack(spacing: 2) {
                Text(node.title.uppercased()).font(Ob.mono(13.5 * font)).foregroundStyle(hover ? ob.accent : ob.ink)
                Text(node.status.uppercased()).font(Ob.mono(12 * font)).foregroundStyle(node.state == .busy ? ob.accent : ob.muted)
            }
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: width - 8)
            .padding(.top, 108)
        }
        .frame(width: width, height: 108 + 46 * font, alignment: .top)
        .background(hover ? ob.accentWash : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .handCursor()
        .onTapGesture { node.open() }
        .help("\(node.title): \(node.status)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(node.label): \(node.title), \(node.status)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { node.open() }
    }

    private var dial: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { k in
                let a = Double(k) / 12 * 2 * .pi
                Circle().fill(ob.ink).opacity(0.5).frame(width: 2, height: 2).offset(x: cos(a) * 30, y: sin(a) * 30)
            }
            Circle().fill(ob.paper).frame(width: 44, height: 44)
            Circle().strokeBorder(node.state == .busy || hover ? ob.accent : ob.ink, lineWidth: node.state == .busy ? 2 : 1).frame(width: 44, height: 44)
            NodeCore(state: node.state, size: first ? 12 : 8)
        }
    }
}

/// A node's core: hollow when off, filled ink when ready, the accent and breathing (1 ↔ 0.25 every 0.6 s, linear, as
/// Windows' DoubleAnimation) while at work.
struct NodeCore: View {
    var state: DotState
    var size: CGFloat
    @Environment(\.ob) private var ob
    @State private var pulse = false

    var body: some View {
        switch state {
        case .off: Circle().strokeBorder(ob.muted, lineWidth: 1).frame(width: size, height: size)
        case .ok: Circle().fill(ob.ink).frame(width: size, height: size)
        case .busy:
            Circle().fill(ob.accent).frame(width: size, height: size).opacity(pulse ? 0.25 : 1)
                .onAppear { withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true } }
                .onDisappear { pulse = false }
        }
    }
}

/// READ ALOUD // VOICE // STATE in a rounded box at the end of the dashed branch, with a small node (a ring and its
/// core) in front. Under the pointer its border and text take the accent.
struct VoicePill: View {
    var node: PathNode
    var readsAloud: Bool
    var font: Double
    @Environment(\.ob) private var ob
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().strokeBorder(node.state == .busy ? ob.accent : ob.ink, lineWidth: 1)
                NodeCore(state: node.state, size: 6)
            }
            .frame(width: 11, height: 11)
            Text("\(node.label) // \(node.title) // \(node.status)".uppercased()).font(Ob.mono(12.5 * font)).lineLimit(1)
                .foregroundStyle(hover ? ob.accent : ob.ink)
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 11 * font).fill(ob.paper))
        .overlay(RoundedRectangle(cornerRadius: 11 * font).strokeBorder(hover ? ob.accent : ob.ink, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 11 * font))
        .onHover { hover = $0 }
        .handCursor()
        .onTapGesture { node.open() }
        .help("Read aloud: \(node.title) (\(node.status))" + (readsAloud ? " — this profile reads each dictation aloud" : ""))
    }
}

// MARK: - Notes and History cells

/// The dashboard's Extended Notes cell (DashboardPage.Notes.cs): only a title and a text box. Before a session the
/// title's spot is an "Extended notes session" button with a hollow red ring (it starts one); while recording, the ring
/// is solid red (click it to stop) and the session's name is there (click to rename). The box can always be typed in:
/// while a session records it is the live transcript; between sessions it is a notepad (notes/draft.txt) that the next
/// session begins with. Full screen opens the live session, or Extended Notes when nothing records.
struct NotesCell: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @State private var draft = ""
    @State private var renaming = false
    @State private var title = ""
    @State private var problem: String?
    @State private var saved: String?
    @State private var starting = false
    @FocusState private var titleFocused: Bool

    private var notes: NotesRecorder { model.notes }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let s = notes.current { live(s) } else { startButton }
                Spacer(minLength: 0)
                Button("⤢ Full screen") {
                    nav.goNotes(notes.current?.id)
                    #if os(macOS)
                    // Always into full screen (MainWindow.ShowNotes(fullScreen: true)), never out of it.
                    let window = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible }
                    if window?.styleMask.contains(.fullScreen) != true { NoteSessionView.toggleFullScreen(model) }
                    #endif
                }
                .buttonStyle(.quietSmall)
            }
            box
        }
        .onAppear { draft = notes.store.draft }
        .onChange(of: notes.isRecording) { was, now in
            if was && !now, let last = notes.store.sessions.first { saved = last.title }
            draft = notes.store.draft
        }
        .alert("Oberton", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    /// A QuietButton with FontSize 11 and Padding 10,4,12,4; off while the session starts, so it can't start twice.
    private var startButton: some View {
        Button {
            starting = true
            Task {
                do { try await notes.start(source: model.settings.notesSource) } catch let error as UserFacingError {
                    problem = error.message
                } catch {
                    Log.error("Starting extended notes failed", error)
                    problem = "Extended notes couldn't start. See the log for details."
                }
                starting = false
                draft = notes.store.draft
            }
        } label: {
            HStack(spacing: 8) {
                Circle().strokeBorder(ob.record, lineWidth: 1.5).frame(width: 10, height: 10)
                Text("Extended notes session")
            }
            .padding(.trailing, 2)
        }
        .buttonStyle(CapsuleButtonStyle(kind: .quiet, size: 11, padding: 10))
        .disabled(starting)
        .help("Start an extended notes session")
        .accessibilityLabel("Start an extended notes session")
    }

    private func live(_ s: NoteSession) -> some View {
        HStack(spacing: 6) {
            Button { Task { await notes.stop() } } label: {
                Circle().strokeBorder(ob.record, lineWidth: 1.5).background(Circle().fill(!notes.isPaused && !notes.isFinishing ? ob.record : .clear))
                    .frame(width: 10, height: 10).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .disabled(notes.isFinishing)
            .help(notes.isFinishing ? "Finishing…" : "Stop the session")
            .accessibilityLabel("Stop the extended notes session")
            if renaming {
                // A standard text box (Windows' Fluent TextBox), all of the name selected.
                TextField("", text: $title).textFieldStyle(.plain).font(Ob.mono(13, .bold)).focused($titleFocused)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .modifier(FluentField(focused: titleFocused))
                    .onSubmit { commit(s) }
                    .onKeyPress(.escape) { title = s.title; commit(s); return .handled } // Esc puts the name back
                    .onChange(of: titleFocused) { if !titleFocused { commit(s) } }
                    .accessibilityLabel("Session name")
            } else {
                Text(s.title.uppercased()).font(Ob.mono(13, .bold)).lineLimit(1).padding(.vertical, 1)
                    .overlay(alignment: .bottom) { Hairline() }
                    .contentShape(Rectangle())
                    .iBeamCursor()
                    .onTapGesture { startRenaming(s) }
                    .help("Click to rename")
            }
        }
    }

    private func startRenaming(_ s: NoteSession) {
        title = s.title
        renaming = true
        titleFocused = true
        #if os(macOS)
        DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        #endif
    }

    private func commit(_ s: NoteSession) {
        guard renaming else { return }
        if !title.trimmed.isEmpty && title.trimmed != s.title { s.title = title.trimmed; notes.store.save(s) }
        renaming = false
    }

    /// Always editable: the live transcript, or the draft between sessions; a hint while it's empty.
    private var text: String {
        if let s = notes.current { _ = notes.revision; return s.transcript }
        return draft
    }

    private func edit(_ new: String) {
        if let s = notes.current {
            s.set(.transcript, new, source: nil)
            model.objectWillChange.send()
        } else {
            draft = new
            notes.store.setDraft(new)
        }
    }

    private var hint: String {
        if notes.isRecording {
            return notes.isPaused ? "Paused. You can still type your own notes here." : "Listening. The transcript appears here, and you can type your own notes in it anytime."
        }
        return (saved.map { "“\($0)” is saved in Extended Notes. " } ?? "") + "Type here anytime: what you type begins the next session, and its transcript follows."
    }

    /// Read as Markdown; a click opens that line as plain text to edit (typing goes on at the end). In a standard text
    /// box, as Windows' TextBox is.
    @ViewBuilder private var box: some View {
        let value = text
        Group {
            if PageScroll<EmptyView>.flat {
                MarkdownReadingView(text: value, size: 13).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)).clipped()
            } else {
                // The session's transcript and the draft are different texts: a fresh view for each.
                MarkdownEditor(text: value, size: 13, label: "Extended notes", inset: CGSize(width: 8, height: 6), onEdit: edit)
                    .id(notes.current?.id ?? "draft")
            }
        }
        .modifier(FluentField(focused: false))
        .overlay(alignment: .topLeading) {
            if value.isEmpty {
                Text(hint).font(Ob.sans(12.5)).foregroundStyle(ob.muted).padding(EdgeInsets(top: 9, leading: 12, bottom: 0, trailing: 12)).allowsHitTesting(false)
            }
        }
    }
}

/// The look of a standard Windows 11 text box (WPF's Fluent theme, which the Windows app's text boxes keep): a faint
/// fill, a hairline edge with 4-point corners, a darker line along the bottom, the accent there while typing.
struct FluentField: ViewModifier {
    var focused: Bool
    @Environment(\.ob) private var ob

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: 4)
            ZStack(alignment: .bottom) {
                if ob.dark {
                    shape.fill(focused ? Color(hex: 0x1E1E1E, alpha: 0.7) : Color.white.opacity(0.06))
                } else {
                    shape.fill(Color.white.opacity(focused ? 1 : 0.7))
                }
                shape.strokeBorder(ob.dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06), lineWidth: 1)
                Rectangle().fill(focused ? ob.accent : ob.dark ? Color.white.opacity(0.55) : Color.black.opacity(0.45))
                    .frame(height: focused ? 2 : 1)
            }
            .clipShape(shape)
        }
    }
}

private extension View {
    /// The I-beam over something that turns into text to edit when clicked (Windows' Cursor="IBeam").
    func iBeamCursor() -> some View {
        #if os(macOS)
        pointerStyle(.horizontalText)
        #else
        self
        #endif
    }
}

/// Two meters wide: how many dictations are kept, and the last one's AI edit (or text) as large as fits, with COPY and
/// INSERT TRANSCRIPTION INTO THE LAST APP (DashboardPage.History.cs).
struct HistoryCell: View {
    var last: HistoryEntry?
    var now: Date
    /// The page's toast, for an insert that failed.
    var toast: (String) -> Void
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @State private var hover = false
    @State private var done: String?
    @State private var doneShown = false
    @State private var dones = 0

    static let insertLabel = "Insert transcription into the last app"

    var body: some View {
        let text = last.map(Self.shown) ?? "Nothing dictated yet. Your last dictation shows here."
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 6)
            FittedText(text: text, color: last == nil ? ob.muted : ob.ink, resetKey: last?.id)

            // Where the text went, for 5 s, fading in and out (DashboardPage.History.ShowHistoryDone).
            VStack(alignment: .leading, spacing: 0) {
                if let done {
                    Text(done).font(Ob.mono(11)).foregroundStyle(ob.accent).lineLimit(1).truncationMode(.tail).help(done)
                        .opacity(doneShown ? 1 : 0)
                        .padding(.bottom, 6)
                }
                HStack(spacing: 8) {
                    #if os(macOS)
                    Button { insert() } label: {
                        ViewThatFits {
                            Text(Self.insertLabel)
                            Text("Insert into last app")
                            Text("Insert")
                        }
                    }
                    .buttonStyle(CapsuleButtonStyle(kind: .quiet, size: 10, padding: 12))
                    .disabled(last?.transcription.isEmpty != false)
                    .help("Insert the last dictation's transcription (the words as heard) into the app it went to; this window stays in front")
                    .accessibilityLabel(Self.insertLabel)
                    #endif
                    Spacer(minLength: 0)
                    HistoryCopyButton(text: last.map(Self.shown) ?? "")
                }
            }
            .padding(.top, 8)
        }
    }

    /// HISTORY (opens the page as it was) and how many are kept, both in the accent under the pointer.
    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("HISTORY").font(Ob.mono(13, .bold)).foregroundStyle(hover ? ob.accent : ob.ink)
                Readout(last == nil || last?.aiEdit?.isEmpty == false ? "Last AI edit" : "Last dictation // No AI edit", size: 10).padding(.top, 6)
                if let last {
                    Text(meta(last)).font(Ob.mono(11)).foregroundStyle(ob.muted).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(model.history.count.formatted()).font(Ob.mono(28, .bold)).foregroundStyle(hover ? ob.accent : ob.ink)
                Readout(kept, size: 10)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .handCursor()
        .onTapGesture { nav.go(.history) }
        .help("Open History")
    }

    #if os(macOS)
    /// The words as heard, into the app the dictation went to; "✓ INSERTED INTO MAIL" here, or the problem in the
    /// page's toast.
    private func insert() {
        guard let last, !last.transcription.isEmpty else { return }
        Task {
            let note = await model.insertIntoLastApp(last.transcription)
            guard note.ok else { toast(note.text); return }
            dones += 1
            let shown = dones
            done = note.banner
            withAnimation(.linear(duration: 0.15)) { doneShown = true }
            try? await Task.sleep(for: .seconds(5))
            guard shown == dones else { return }
            withAnimation(.linear(duration: 0.4)) { doneShown = false }
            try? await Task.sleep(for: .seconds(0.4))
            if shown == dones { done = nil }
        }
    }
    #endif

    /// "OF 50 KEPT", "KEPT · LAST MONTH" or "KEPT, NO LIMIT".
    private var kept: String {
        let s = model.settings
        return s.historyLimit > 0 ? "of \(s.historyLimit.formatted()) kept"
            : s.historyDays > 0 ? "kept · last \(HistoryStore.daysLabel(s.historyDays))" : "kept, no limit"
    }

    /// What the cell shows of a dictation: the AI's edit; without one, what went in (or what was heard).
    static func shown(_ e: HistoryEntry) -> String {
        if let ai = e.aiEdit, !ai.isEmpty { return ai }
        return e.inserted.isEmpty ? e.transcription : e.inserted
    }

    /// "Mail · 14:32 · 12 words" (HistoryEntry.AppName, When and Words).
    // Lane J (wave 3, DASH-099): web sites are counted in Usage.swift and shown in Analytics and History; Windows'
    // dashboard names only the app here and in the INSERT node, so nothing on this page changes when sites land.
    private func meta(_ e: HistoryEntry) -> String {
        "\(e.appLabel) · \(Self.when(e.date, now: now)) · \(e.words.formatted()) word" + (e.words == 1 ? "" : "s")
    }

    /// HistoryEntry.When: "14:32" today, "Yesterday 14:32", else "3 Nov, 14:32" (day first).
    static func when(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return DateText.time(d) }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: yesterday) { return "Yesterday " + DateText.time(d) }
        return DateText.dayMonthTime(d)
    }
}

/// COPY (a QuietButton with FontSize 10 and Padding 12,4): greyed out with nothing to copy, otherwise flashes COPIED ✓
/// or BUSY, TRY AGAIN for 1.5 s (DashboardPage.CopyShown).
struct HistoryCopyButton: View {
    var text: String
    @State private var flash: String?

    var body: some View {
        Button(flash ?? "Copy") {
            let label = text.isEmpty ? "Nothing yet" : Clipboard.copy(text) ? "Copied ✓" : "Busy, try again"
            flash = label
            Task { try? await Task.sleep(for: .seconds(1.5)); if flash == label { flash = nil } }
        }
        .buttonStyle(CapsuleButtonStyle(kind: .quiet, size: 10, padding: 12))
        .fixedSize()
        .disabled(text.isEmpty)
        .help("Copy the text shown")
    }
}

/// The History cell's text, in the meters' mono face, as large as fits the space: the largest size from 11 to 30 points
/// (in half points, lines 1.4 × the size apart) at which all of it shows. When even 11 doesn't fit, it scrolls, and it
/// goes back to the top when the last dictation changes (DashboardPage.FitHistoryText). Not selectable, as on Windows.
struct FittedText: View {
    var text: String
    var color: Color
    var resetKey: UUID?

    static let smallest: CGFloat = 11, largest: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let size = Self.fit(text, in: geo.size)
            let shown = Text(text).font(Ob.mono(size)).lineSpacing(Self.spacing(size)).foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
            if PageScroll<EmptyView>.flat {
                shown.fixedSize(horizontal: false, vertical: true).frame(width: geo.size.width, height: geo.size.height, alignment: .top).clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { shown.id("top") }
                        .onChange(of: resetKey) { proxy.scrollTo("top", anchor: .top) }
                }
            }
        }
    }

    static func spacing(_ size: CGFloat) -> CGFloat { Ob.lineSpacing(size, lineHeight: size * 1.4) }

    /// The size the text is drawn at in a space this big.
    static func fit(_ text: String, in space: CGSize) -> CGFloat {
        let (w, h) = (space.width, space.height)
        guard w >= 20, h >= 10 else { return smallest }
        func fits(_ size: CGFloat) -> Bool {
            TextFit.height(text, font: Ob.monoFont(size), lineSpacing: spacing(size), width: w - 2) <= h
        }
        var lo = smallest, hi = largest
        if !fits(lo) { return lo }
        if fits(hi) { return hi }
        while hi - lo > 0.5 {
            let mid = (lo + hi) / 2
            if fits(mid) { lo = mid } else { hi = mid }
        }
        return (lo * 2).rounded(.down) / 2
    }
}

/// Measuring text the way it will be drawn, to choose a size or a width before laying it out.
enum TextFit {
    static func height(_ text: String, font: PlatformFont, lineSpacing: CGFloat, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let s = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font, .paragraphStyle: paragraph])
        return s.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading],
                              context: nil).height.rounded(.up)
    }

    static func width(_ text: String, font: PlatformFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width.rounded(.up) + 1
    }
}

#if DEBUG && os(macOS)
/// Snapshot mode: the History cell with no dictation, a short one, a longer one and one too long to fit (it scrolls at
/// 11 pt), at the size the cell has in a 1200 × 780 window, to compare the fitted text with Windows'.
@MainActor
enum DashboardSnapshots {
    static func write(to dir: String, model: AppModel) {
        let words = "So the plan for Friday is that we ship the beta to the first ten testers, collect their feedback over the weekend, and then decide on Monday whether the release goes out on the twelfth or slips a week. "
        let texts: [(String, String?)] = [
            ("empty", nil), ("short", "Ship it on Friday."), ("medium", words), ("long", String(repeating: words, count: 6)),
        ]
        for dark in [false, true] {
            var s = model.settings
            s.theme = dark ? .dark : .light
            for (name, text) in texts {
                let entry = text.map {
                    HistoryEntry(transcription: $0, aiEdit: nil, inserted: $0, profileName: "Light Cleanup", model: nil, appName: name == "medium" ? nil : "Mail",
                                 seconds: 9, turnaroundSeconds: 1.1, warning: nil)
                }
                let cell = Cell(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) { HistoryCell(last: entry, now: .now, toast: { _ in }) }
                    .frame(width: 309, height: 280)
                    .environmentObject(model).environmentObject(Navigator()).obertonTheme(s)
                    .background(Palette(dark: dark, accentChoice: s.accent).paper)
                let r = ImageRenderer(content: cell)
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appending(path: "dashboard-history-\(name)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
#endif
