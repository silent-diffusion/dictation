import ObertonCore
import SwiftUI

/// At a glance: on the Mac everything fits the window and nothing scrolls; rows share the height and meters scale to
/// their cells (DashboardPage.xaml). On iPhone the same cells stack and scroll.
struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var toast: String?
    @State private var toastShown = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if sizeClass == .compact { phone(now: context.date) } else { desk(now: context.date) }
        }
        // A short note (what Unload everything did), at the bottom.
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(Ob.mono(12)).foregroundStyle(ob.onInk).multilineTextAlignment(.center).frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Capsule().fill(ob.ink))
                    .opacity(toastShown ? 1 : 0)
                    .padding(.bottom, 34)
                    .allowsHitTesting(false)
            }
        }
    }

    private func showToast(_ message: String) {
        toast = message
        withAnimation(.easeOut(duration: 0.12)) { toastShown = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard toast == message else { return }
            withAnimation(.easeIn(duration: 0.3)) { toastShown = false }
        }
    }

    private func desk(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Dashboard", japanese: "計器", summary: summary, size: 30) { Readout(clock(now)) }
                .padding(.bottom, 14)
            // The panel: its top and left edges here, each cell draws its right and bottom edges.
            GeometryReader { geo in
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Cell { SignalPathCell() }.frame(width: max(geo.size.width * 1.75 / 2.75, geo.size.width - 360))
                        Cell(padding: EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12)) { NotesCell() }
                    }
                    .frame(height: geo.size.height * 1.3 / 2.45)
                    HStack(spacing: 0) {
                        meters.frame(width: geo.size.width * 4 / 6)
                        Cell(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) { HistoryCell() }
                    }
                }
            }
            .overlay(alignment: .top) { Hairline() }
            .overlay(alignment: .leading) { Hairline(vertical: true) }
            Readout(footer).lineLimit(1).padding(.top, 8)
        }
        .padding(EdgeInsets(top: 20, leading: 28, bottom: 14, trailing: 28))
    }

    private func phone(now: Date) -> some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "Dashboard", japanese: "計器", summary: summary, size: 26) { EmptyView() }
                    .padding(.bottom, 14)
                VStack(spacing: 0) {
                    Cell { SignalPathCell() }.frame(height: 330)
                    Cell(padding: EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12)) { NotesCell() }.frame(height: 200)
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow { meter(0); meter(1) }
                        GridRow { meter(2); meter(3) }
                    }
                    Cell(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) { HistoryCell() }.frame(height: 260)
                }
                .overlay(alignment: .top) { Hairline() }
                .overlay(alignment: .leading) { Hairline(vertical: true) }
                Readout(footer).padding(.top, 8)
            }
            .padding(16)
        }
    }

    private var meters: some View {
        HStack(spacing: 0) { ForEach(0..<4, id: \.self) { meter($0) } }
    }

    /// The four meters. The figures come from the daily counts, which survive History being trimmed, cleared or off.
    @ViewBuilder private func meter(_ i: Int) -> some View {
        let days = model.usage.perDay(30)
        let today = days.last ?? UsageDay()
        switch i {
        case 0:
            let best = days.map(\.words).max() ?? 0
            meterCell(to: .history) {
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
            let turn = model.recentTurnaround
            meterCell(settings: .models) {
                FanMeter(fraction: (turn ?? 0) / 10, value: turn.map { String(format: "%.1f s", $0) } ?? "—", label: "Turnaround")
            }
        default:
            // The speech model (DashboardPage's speech dial). The Mac has no unload timer: once used, the model stays
            // loaded until the system lets it go or it is unloaded here.
            meterCell(settings: .speech, footer: AnyView(unloadButton)) {
                if model.phase.isBusy {
                    RingMeter(fraction: 1, value: "busy", label: "Speech model", sub: "dictating now", accent: true)
                } else if !model.speechLoaded {
                    RingMeter(fraction: 0, value: "off", label: "Speech model", sub: "loads when you dictate")
                } else {
                    RingMeter(fraction: 1, value: "on", label: "Speech model", sub: "stays loaded",
                              valueAction: unloadSpeechNow, valueTip: "Click to unload the speech model now")
                }
            }
        }
    }

    /// UNLOAD EVERYTHING, at the bottom of the speech meter: the speech model, the AI model and the voice.
    private var unloadButton: some View {
        Button("Unload everything") {
            Task { showToast(await model.unloadNow(speech: true, ai: true, voice: true)) }
        }
        .buttonStyle(.quietSmall)
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
            .frame(minHeight: 150)
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

    private func clock(_ now: Date) -> String {
        now.formatted(.dateTime.weekday(.wide).day().month(.wide)) + " — " + now.formatted(date: .omitted, time: .shortened)
    }

    private var footer: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var parts = ["Oberton \(version)", "\(model.usage.totalWords.formatted()) words dictated in all",
                     model.settings.cloud.keepOffline ? "everything stays on this \(Device.noun)" : "cloud AI allowed"]
        #if os(macOS)
        parts.append("\(model.settings.cycleProfileHotkey) switches profile")
        #endif
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

/// MIC → SPEECH → AI → INSERT, with READ ALOUD branching off. Each step lights the moment it works.
struct SignalPathCell: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob

    var body: some View {
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
                Text(model.aiReady || model.activeProfile.isRaw ? "ON-DEVICE // READY" : "AI NOT READY")
                    .font(Ob.mono(12, .bold))
                    .foregroundStyle(model.aiReady || model.activeProfile.isRaw ? ob.muted : ob.accent)
                    .lineLimit(1)
            }
        }
    }

    private var nodes: [PathNode] {
        let phase = model.phase, p = model.activeProfile
        let micOn = phase == .starting || phase == .recording
        let speechOn = micOn || phase == .transcribing
        let aiOn = !p.isRaw && phase == .processing
        let insertOn = phase == .inserting
        let id = model.processor.model(for: p)
        let cloud = !id.isLocal
        let lastApp = model.lastEntry?.appName
        #if os(macOS)
        let insertTitle = "Paste" + (p.showPreview ? " // preview" : "")
        let insertRest = lastApp.map { "last → \($0)" } ?? "at the cursor"
        #else
        let insertTitle = "Copy" + (p.showPreview ? " // preview" : "")
        let insertRest = "to the clipboard"
        #endif
        return [
            PathNode(label: "MIC", title: "Default microphone", status: micOn ? "Recording" : "Ready", state: micOn ? .busy : .ok) {
                nav.goSettings(.microphone)
            },
            PathNode(label: "SPEECH", title: "Apple Speech",
                     status: "on-device // " + (phase == .transcribing ? "transcribing" : speechOn ? "listening" : "ready"),
                     state: speechOn ? .busy : .ok) { nav.goSettings(.speech) },
            p.isRaw
                ? PathNode(label: "AI", title: "No AI", status: p.name + " // raw words", state: .off) { nav.goProfile(p.id) }
                : PathNode(label: cloud ? "AI // CLOUD" : "AI", title: id.shortName,
                           status: p.name + " // " + (aiOn ? "editing" : cloud && model.settings.cloud.keepOffline ? "blocked offline" : model.aiReady ? "ready" : "not ready"),
                           state: aiOn ? .busy : model.aiReady ? .ok : .off) { nav.goProfile(p.id) },
            PathNode(label: "INSERT", title: insertTitle, status: insertOn ? "inserting" : insertRest, state: insertOn ? .busy : .ok) {
                nav.goSettings(.general)
            },
        ]
    }

    private var voice: PathNode {
        PathNode(label: "READ ALOUD", title: model.reader.voiceName.isEmpty ? voiceName : model.reader.voiceName,
                 status: model.reader.isSpeaking ? "reading" : "ready", state: model.reader.isSpeaking ? .busy : .ok) { nav.go(.readAloud) }
    }

    private var voiceName: String {
        ReadAloudPlayer.voices.first { $0.identifier == model.settings.ttsVoice }?.name ?? "System voice"
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

/// A step: its label, a dial (a ring of twelve faint ticks, the ring, the core), its title and status under it.
/// Hovering lights it in the accent; clicking opens its settings.
struct PathStep: View {
    var node: PathNode
    var first: Bool
    var width: Double
    var font: Double
    @Environment(\.ob) private var ob
    @State private var hover = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            Text(node.label).font(Ob.mono(15 * font, .bold)).foregroundStyle(hover ? ob.accent : ob.ink)
                .frame(height: 24 * font).padding(.top, 6 - 4 * (font - 1))
            dial.frame(width: 80, height: 80)
            VStack(spacing: 2) {
                Text(node.title.uppercased()).font(Ob.mono(13.5 * font)).foregroundStyle(hover ? ob.accent : ob.ink)
                Text(node.status.uppercased()).font(Ob.mono(12 * font)).foregroundStyle(node.state == .busy ? ob.accent : ob.muted)
            }
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: width - 8)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: 108 + 46 * font)
        .background(hover ? ob.accentWash : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
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
            let size: CGFloat = first ? 12 : 8
            switch node.state {
            case .off: Circle().strokeBorder(ob.muted, lineWidth: 1).frame(width: size, height: size)
            case .ok: Circle().fill(ob.ink).frame(width: size, height: size)
            case .busy:
                Circle().fill(ob.accent).frame(width: size, height: size).opacity(pulse ? 0.25 : 1)
                    .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { pulse = true } }
                    .onDisappear { pulse = false }
            }
        }
    }
}

/// READ ALOUD // VOICE // STATE in an ink capsule at the end of the dashed branch.
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
                if node.state == .busy { Circle().fill(ob.accent).frame(width: 6, height: 6) }
            }
            .frame(width: 11, height: 11)
            Text("\(node.label) // \(node.title) // \(node.status)".uppercased()).font(Ob.mono(12.5 * font)).lineLimit(1)
        }
        .foregroundStyle(hover ? ob.accent : ob.ink)
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(Capsule().fill(ob.paper))
        .overlay(Capsule().strokeBorder(hover ? ob.accent : ob.ink, lineWidth: 1))
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .onTapGesture { node.open() }
        .help("Read aloud: \(node.title) (\(node.status))" + (readsAloud ? ". This profile reads each dictation aloud." : ""))
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
                    NoteSessionView.toggleFullScreen(model)
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
        .alert("Extended notes", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    private var startButton: some View {
        Button {
            Task {
                do { try await notes.start(source: model.settings.notesSource) } catch { problem = error.localizedDescription }
                draft = notes.store.draft
            }
        } label: {
            HStack(spacing: 8) {
                Circle().strokeBorder(ob.record, lineWidth: 1.5).frame(width: 10, height: 10)
                Text("Extended notes session")
            }
        }
        .buttonStyle(.quietSmall)
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
            .disabled(notes.isFinishing)
            .help(notes.isFinishing ? "Finishing…" : "Stop the session")
            .accessibilityLabel("Stop the extended notes session")
            if renaming {
                TextField("", text: $title).textFieldStyle(.plain).font(Ob.mono(13, .bold)).focused($titleFocused)
                    .onSubmit { commit(s) }
                    .onChange(of: titleFocused) { if !titleFocused { commit(s) } }
                    .accessibilityLabel("Session name")
            } else {
                Text(s.title.uppercased()).font(Ob.mono(13, .bold)).lineLimit(1).padding(.vertical, 1)
                    .overlay(alignment: .bottom) { Hairline() }
                    .onTapGesture { title = s.title; renaming = true; titleFocused = true }
                    .help("Click to rename")
            }
        }
    }

    private func commit(_ s: NoteSession) {
        guard renaming else { return }
        if !title.trimmed.isEmpty && title.trimmed != s.title { s.title = title.trimmed; notes.store.save(s) }
        renaming = false
    }

    /// Always editable: the live transcript, or the draft between sessions; a hint while it's empty.
    private var text: Binding<String> {
        Binding(get: {
            if let s = notes.current { _ = notes.revision; return s.transcript }
            return draft
        }, set: { new in
            if let s = notes.current {
                s.set(.transcript, new, source: nil)
                model.objectWillChange.send()
            } else {
                draft = new
                notes.store.setDraft(new)
            }
        })
    }

    private var hint: String {
        if notes.isRecording {
            return notes.isPaused ? "Paused. You can still type your own notes here." : "Listening. The transcript appears here, and you can type your own notes in it anytime."
        }
        return (saved.map { "“\($0)” is saved in Extended Notes. " } ?? "") + "Type here anytime: what you type begins the next session, and its transcript follows."
    }

    @ViewBuilder private var box: some View {
        let value = text.wrappedValue
        if PageScroll<EmptyView>.flat {
            Text(value.isEmpty ? hint : value).font(Ob.mono(13)).foregroundStyle(value.isEmpty ? ob.muted : ob.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.horizontal, 5)
        } else {
            TextEditor(text: text)
                .font(Ob.mono(13))
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if value.isEmpty {
                        Text(hint).font(Ob.sans(12.5)).foregroundStyle(ob.muted).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Extended notes")
        }
    }
}

/// Two meters wide: how many dictations are kept, and the last one's AI edit (or text) as large as fits, with COPY and
/// INSERT TRANSCRIPTION INTO THE LAST APP.
struct HistoryCell: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @State private var hover = false
    @State private var done: String?

    var body: some View {
        let last = model.lastEntry
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("HISTORY").font(Ob.mono(13, .bold)).foregroundStyle(hover ? ob.accent : ob.ink)
                    Readout(last?.aiEdit != nil ? "Last AI edit" : "Last dictation", size: 10).padding(.top, 6)
                    if let last {
                        Text(meta(last)).font(Ob.mono(11)).foregroundStyle(ob.muted).lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(model.history.count.formatted()).font(Ob.mono(28, .bold)).foregroundStyle(hover ? ob.accent : ob.ink)
                    Readout(model.settings.historyLimit > 0 ? "of \(model.settings.historyLimit) kept" : "kept, no limit", size: 10)
                }
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { nav.goHistory(last?.id) }
            .help("Open History")

            PageScroll {
                Text(last.map { $0.aiEdit ?? $0.inserted } ?? "Nothing dictated yet. Your last dictation shows here.")
                    .font(Ob.mono(14))
                    .foregroundStyle(last == nil ? ob.muted : ob.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if let done { Text(done).font(Ob.mono(11)).foregroundStyle(ob.accent).lineLimit(1) }
            HStack(spacing: 8) {
                #if os(macOS)
                Button {
                    guard let last else { return }
                    Task {
                        done = await model.insertIntoLastApp(last.transcription)
                        try? await Task.sleep(for: .seconds(3))
                        done = nil
                    }
                } label: {
                    ViewThatFits {
                        Text("Insert transcription into the last app")
                        Text("Insert into last app")
                        Text("Insert")
                    }
                }
                .buttonStyle(.quietSmall)
                .disabled(last == nil)
                .help("Insert the last dictation's transcription (the words as heard) into the app it went to")
                #endif
                Spacer(minLength: 0)
                CopyButton(text: last.map { $0.aiEdit ?? $0.inserted } ?? "")
            }
        }
    }

    private func meta(_ e: HistoryEntry) -> String {
        var parts = [e.date.formatted(.relative(presentation: .named)).uppercased()]
        if let app = e.appName { parts.append(app.uppercased()) }
        parts.append("\(e.words) WORDS")
        return parts.joined(separator: " // ")
    }
}
