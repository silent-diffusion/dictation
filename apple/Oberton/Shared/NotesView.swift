import AVFoundation
import Combine
import ObertonCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Extended Notes (NotesPage.xaml): the landing page (start a session, the sessions so far) and a session (Transcript,
/// Formatted, Summary and Edited, the recording at the bottom, Export). Every text is a plain text box; the Edited tab
/// colours the AI's changes and the user's apart.
struct NotesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    /// The search and the tab chosen live as long as the page (Windows' NotesPage keeps its SearchBox and tab pills):
    /// back from a session the list is still filtered, and the next session opens on the same tab.
    @State private var search = ""
    @State private var tab = NoteSessionView.snapshotTab
    @StateObject private var page = NotesPageState()

    /// Each visit to the page (Windows builds a new NotesPage each time): a start begun on an earlier visit doesn't open
    /// its session on this one (NOTES-N022).
    @MainActor static var visit = 0

    var body: some View {
        let open = nav.place.noteSessionID.flatMap { id in model.notes.store.sessions.first { $0.id == id } }
        // The landing stays while a session shows, only hidden (Windows collapses it), so its list keeps its scroll.
        ZStack(alignment: .topLeading) {
            NotesLanding(search: $search, hidden: open != nil)
                .opacity(open == nil ? 1 : 0)
                .allowsHitTesting(open == nil)
                .accessibilityHidden(open != nil)
            if let s = open {
                NoteSessionView(session: s, tab: $tab, page: page).id(s.id)
            }
        }
        .onAppear {
            Self.visit += 1
            model.notes.forgetIdleModel()
        }
    }
}

/// What Windows' NotesPage keeps for as long as it is open, whichever session it shows: the playback speed and Skip
/// silences (ClosePlayer leaves them), and the Export button's "COPIED …" flash with its two-second timer.
@MainActor
final class NotesPageState: ObservableObject {
    @Published var rate = 1.0
    @Published var skipSilences = false
    @Published var copied: String?
    var copiedTurn = 0

    /// The Export button says what was copied, for two seconds after the last copy.
    func flash(_ what: String) {
        copied = what
        copiedTurn += 1
        let turn = copiedTurn
        Task { try? await Task.sleep(for: .seconds(2)); if copiedTurn == turn { copied = nil } }
    }
}

// MARK: - Landing

struct NotesLanding: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @Binding var search: String
    /// A session shows over it: its pipeline's model isn't worked out meanwhile (the page shows the session's).
    var hidden = false
    @State private var starting = false
    @State private var problem: String?
    @State private var deleting: NoteSession?

    private var notes: NotesRecorder { model.notes }

    var body: some View {
        landing
        .task(id: hidden) { guard !hidden else { return }; let n = notes; await n.keepIdleModel { n.isRecording } }
        .alert(NotesDialog.title, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
        .alert(NotesDialog.title, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Yes") { if let d = deleting { notes.store.delete(d); model.objectWillChange.send() }; deleting = nil }
            Button("No", role: .cancel) { deleting = nil }
        } message: { Text("Delete \"\(deleting?.title ?? "")\" with its recording? This can't be undone.") }
        .dialogLook(.warning, shown: deleting != nil)
    }

    /// Windows docks everything above the list at the top and scrolls only the list, so the start button, the model
    /// and the search box stay on screen however long the list grows. (The snapshots and the iPhone scroll it all.)
    @ViewBuilder private var landing: some View {
        let margins = EdgeInsets(top: 20, leading: 28, bottom: 16, trailing: 28)
        #if os(macOS)
        if !PageScroll<EmptyView>.flat {
            VStack(alignment: .leading, spacing: 0) {
                top.padding(EdgeInsets(top: margins.top, leading: margins.leading, bottom: 0, trailing: margins.trailing))
                // The ScrollViewer sits inside the page's margins: its scroll bar 28 in from the edge, the list cut 16 above
                // the bottom.
                ScrollView { list }
                    .padding(EdgeInsets(top: 0, leading: margins.leading, bottom: margins.bottom, trailing: margins.trailing))
            }
        } else {
            PageScroll { VStack(alignment: .leading, spacing: 0) { top; list }.padding(margins) }
        }
        #else
        PageScroll { VStack(alignment: .leading, spacing: 0) { top; list }.padding(margins) }
        #endif
    }

    private var top: some View {
            VStack(alignment: .leading, spacing: 0) {
                // The title at the top of the row, the decor at its bottom (a horizontal StackPanel, HeaderRow).
                HeaderRow(decorGap: 12, decorBottom: 1, trailingGap: 0, trailingBottom: 0) {
                    Text("EXTENDED NOTES").font(Ob.mono(30, .bold)).noWrap()
                        .layoutValue(key: HeaderRow.RoleKey.self, value: .title)
                    Decor("記録", size: 26, color: ob.divider, weight: .bold).noWrap()
                        .layoutValue(key: HeaderRow.RoleKey.self, value: .decor)
                }
                Rule().padding(.vertical, 6)
                Caption("Leave it on through a lecture or a meeting. It transcribes as it goes, tidies the text with the AI about every minute, keeps a running summary and the recording, and you can type your own notes straight into the text. Everything stays on this \(Device.noun).")
                // LISTEN opens the microphone's page; the speech and AI steps open Models, as on Windows.
                NotesPipelineView(steps: NotesSteps.live(model, chosen: chosenSource),
                                  open: [{ nav.goSettings(.microphone) }, { nav.goSettings(.models) }, { nav.goSettings(.models) }, { nav.goSettings(.models) }])
                    .padding(.top, 2)
                startCard.padding(.top, 14)
                usageStrip
                HStack {
                    Text("SESSIONS").font(Ob.mono(12, .bold))
                    Spacer()
                    Readout("Search").padding(.trailing, 8)
                    // A plain TextBox: the Fluent text box, Width 240.
                    ObField("", text: $search, width: 240)
                        .accessibilityLabel("Search the sessions")
                }
                .padding(.top, 22).padding(.bottom, 8)
            }
    }

    private var chosenSource: NotesSource {
        #if os(macOS)
        model.settings.notesSource
        #else
        .mic
        #endif
    }

    private var startCard: some View {
        Box(padding: 0) {
            VStack(alignment: .leading, spacing: 6) {
                FlowRow(spacing: 0) {
                    Button {
                        if let live = notes.current { nav.goNotes(live.id); return }
                        starting = true
                        let visit = NotesView.visit
                        Task {
                            do {
                                try await notes.start(source: chosenSource)
                                // Opened only on the very page it was started from (Windows opens it on its own page: moving
                                // to History meanwhile leaves you there, and a new visit to Notes stays on the landing).
                                if let s = notes.current, nav.place.section == .notes, NotesView.visit == visit { nav.goNotes(s.id) }
                            } catch let e as UserFacingError {
                                NotesDialog.warn(e.localizedDescription) { problem = $0 }
                            } catch {
                                Log.error("Starting extended notes failed: \(error)")
                                NotesDialog.warn("Extended notes couldn't start. See the log for details.") { problem = $0 }
                            }
                            starting = false
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Circle().strokeBorder(ob.record, lineWidth: 1.6).background(Circle().fill(notes.isRecording ? ob.record : .clear))
                                .frame(width: 11, height: 11)
                            // ToUpperInvariant ("ß" stays), not the capsule's own upper-casing ("SS").
                            Text(notes.current.map { "● RECORDING // " + NoteSessionView.invariantUpper($0.title) + " // OPEN" } ?? "EXTENDED NOTES SESSION")
                                .textCase(nil)
                        }
                    }
                    .buttonStyle(.quiet)
                    .disabled(starting)
                    .accessibilityLabel("Start an extended notes session")
                    .padding(.trailing, 18)
                    Readout("Listen to").padding(.trailing, 10)
                    #if os(macOS)
                    ForEach([(NotesSource.mic, "Mic"), (.computer, "Computer audio"), (.both, "Both")], id: \.0) { source, label in
                        Pill(label, on: model.settings.notesSource == source) { model.settings.notesSource = source }.disabled(notes.isRecording)
                            .padding(.trailing, 4)
                    }
                    #else
                    Pill("Mic", on: true) {}.padding(.trailing, 4)
                    #endif
                    Readout("AI model").padding(.leading, 14).padding(.trailing, 10)
                    NotesModelMenu(width: 300)
                }
                // The controls' bottom margin 6 and the note's top margin 6: 12 between them.
                Readout("Keeps the recording // about 115 MB an hour // dictating into an app pauses the session, then it resumes", size: 10)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            // Padding 18,14 inside the card's 1-px border.
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)) // Padding 18,14; Box adds the line
        }
    }

    /// The counts in notes/usage.json over the last 30 days and all time. Hidden until a session has been counted.
    @ViewBuilder private var usageStrip: some View {
        let all = notes.store.usage.totals(days: 0)
        if all.sessions > 0 {
            VStack(alignment: .leading, spacing: 8) {
                usageRow("Usage // last 30 days", notes.store.usage.totals(days: 30))
                Hairline()
                usageRow("All time", all)
            }
            // Padding 14,9 inside the 1-px border.
            .padding(.horizontal, 15).padding(.vertical, 10)
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
            .padding(.top, 10)
        }
    }

    private func usageRow(_ label: String, _ t: NotesUsageTotals) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Readout(label).frame(width: 170, alignment: .leading)
            FlowRow(spacing: 22, lineSpacing: 0, marginWraps: true) {
                readout(t.sessions.formatted(), t.sessions == 1 ? "session" : "sessions")
                readout(NotesUsage.hoursMinutes(t.seconds), "recorded")
                readout(t.wordsHeard.formatted(), "words heard")
                readout(t.wordsTyped.formatted(), "words typed")
                readout(t.aiRequests.formatted(), "AI requests")
                // By source, in the order of the pills above, only the ones used: "MIC 3 · COMPUTER 1 · BOTH 2".
                // Always there, even empty (one line high, no width), with its 22 after it, as Windows' TextBlock.
                let by = [NotesSource.mic, .computer, .both].compactMap { s in t.sources[s.rawValue].flatMap { $0 > 0 ? (s, $0) : nil } }
                if by.isEmpty {
                    Text(verbatim: "\u{200B}").font(Ob.mono(10.5))
                } else {
                    Text(by.enumerated().reduce(into: AttributedString()) { text, item in
                        var label = AttributedString((item.offset > 0 ? " · " : "") + item.element.0.rawValue.uppercased() + " ")
                        label.font = Ob.mono(10.5); label.foregroundColor = ob.muted
                        var number = AttributedString(item.element.1.formatted())
                        number.font = Ob.mono(13, .bold); number.foregroundColor = ob.ink
                        text += label + number
                    })
                }
            }
        }
    }

    private func readout(_ value: String, _ label: String) -> some View {
        Text("\(Text(value).font(Ob.mono(13, .bold)).foregroundColor(ob.ink))\(Text(" " + label.uppercased()).font(Ob.mono(10.5)).foregroundColor(ob.muted))")
    }

    @ViewBuilder private var list: some View {
        let q = search.trimmed
        let sessions = notes.store.sessions.filter { q.isEmpty || [$0.title, $0.transcript, $0.summary].contains { NoteSessionView.containsIgnoringCase($0, q) } }
        if sessions.isEmpty {
            // Margin 2,6,0,0 replaces the Caption style's bottom 12 (NotesPage.xaml.cs:168).
            Caption(q.isEmpty ? "No sessions yet. Start one above and it appears here." : "No session matches.", bottom: 0).padding(.top, 6).padding(.leading, 2)
        } else {
            VStack(spacing: 0) { ForEach(sessions) { row($0) } }
        }
    }

    private func row(_ s: NoteSession) -> some View {
        NoteRow(session: s, live: s === notes.current) { deleting = s }
            .onTapGesture { nav.goNotes(s.id) }
            .handCursor()
    }
}

/// A session in the list: its name and gist, when, how long, what it listened to, and Delete (or ● RECORDING).
struct NoteRow: View {
    var session: NoteSession
    var live: Bool
    var delete: () -> Void
    @Environment(\.ob) private var ob
    @State private var hover = false

    var body: some View {
        let s = session
        // Columns as Windows' star widths 2.4 / 1 / 0.7 / 0.9, then Delete (or ● RECORDING) at its own size.
        StarColumns(weights: [2.4, 1, 0.7, 0.9]) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(Ob.mono(13, .bold)).lineLimit(1)
                Text(Self.gist(s)).font(Ob.sans(12)).foregroundStyle(ob.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 12)
            Text(Self.when(s.started)).font(Ob.mono(11.5)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(NoteSessionView.length(s.seconds)).font(Ob.mono(11.5)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(NoteSessionView.sourceLabel(s.source).uppercased()).font(Ob.mono(10.5)).foregroundStyle(ob.muted).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if live {
                Text("● RECORDING").font(Ob.mono(10.5, .bold)).foregroundStyle(ob.record)
            } else {
                Button("Delete", action: delete).buttonStyle(.quietSmall).fixedSize().handCursor()
            }
        }
        // Padding 6,10 above the row's 1-px bottom line.
        .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 11)
        .background(hover ? ob.subtle : .clear)
        .overlay(alignment: .bottom) { Hairline() }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    /// The summary, else the formatted text, else the transcript, on one line: 140 UTF-16 units and "…" (NotesPage.Gist).
    static func gist(_ s: NoteSession) -> String {
        let source = !s.summary.trimmed.isEmpty ? s.summary : !s.formatted.trimmed.isEmpty ? s.formatted : s.transcript
        // .NET's ReplaceLineEndings: CR LF, CR, LF, NEL, LS, PS and FF each become a space.
        let text = source.replacingOccurrences(of: "\r\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: "\r\n\u{85}\u{2028}\u{2029}\u{0C}")).joined(separator: " ").trimmed
        guard text.utf16.count > 140 else { return text.isEmpty ? "Nothing transcribed yet." : text }
        let cut = String(decoding: Array(text.utf16.prefix(140)), as: UTF16.self)
        return String(cut.reversed().drop(while: \.isWhitespace).reversed()) + "…"
    }

    /// "Today 14:32", else "2 Nov, 14:32": the day before the month, the time as the system writes it (`d MMM, t`).
    static func when(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today " + time }
        return dayMonth.string(from: date) + ", " + time
    }

    static let dayMonth: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM"; return f }()
}

// MARK: - A session

struct NoteSessionView: View {
    let session: NoteSession
    /// The tab showing; it stays chosen for the next session opened (NotesView keeps it).
    @Binding var tab: Tab
    @ObservedObject var page: NotesPageState
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @StateObject private var player = NotesPlayer()
    /// The tab the page first opens on (the debug snapshots set it).
    static var snapshotTab = Tab.transcript
    @State private var renaming = false
    @State private var title = ""
    /// Where the cursor is in each tab's text (UTF-16), for the Play button: each tab keeps its own, as each of
    /// Windows' text boxes does.
    @State private var carets: [Tab: Int] = [:]
    @State private var problem: String?
    @State private var asking: NotesRedoStep?
    /// The question asked was "Stop redoing?" (kept as asked, as Windows' modal MessageBox keeps its text).
    @State private var askingStop = false
    /// The kind of file being saved, for the log if saving it fails.
    @State private var exportingExt = ""
    @State private var exporting: ExportFile?
    @State private var saveSoon: Task<Void, Never>?
    @State private var playKeyFocused = false
    @FocusState private var titleFocused: Bool
    @State private var titleKeyFocused = false
    /// One of the three texts has the keyboard: the box draws Fluent's ink line along its bottom.
    @State private var textFocused: [Tab: Bool] = [:]
    #if os(macOS)
    @State private var fullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true
    #endif

    enum Tab: String, CaseIterable { case transcript = "Transcript", formatted = "Formatted", summary = "Summary", edited = "Edited" }

    private var notes: NotesRecorder { model.notes }
    private var live: Bool { session === notes.current }
    private var doc: NoteDoc { tab == .formatted ? .formatted : tab == .summary ? .summary : .transcript }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button("← Extended notes") { nav.goNotes(nil) }.buttonStyle(CapsuleButtonStyle(kind: .quiet, size: 10.5, compact: true)).handCursor()
                .focusTaker().padding(.bottom, 8)
            header
            Rule().padding(.vertical, 10)
            // A step redoes itself (and what follows it) from the recording, once the session has stopped.
            NotesPipelineView(steps: live ? NotesSteps.live(model, chosen: session.source) : NotesSteps.redo(model, session),
                              open: [.transcribe, .transcribe, .format, .summary].map { step in { ask(step) } })
                .padding(.bottom, 8)
            // The hint is docked right first: it stays whole, and the pills give way when the row is too narrow.
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Tab.allCases, id: \.self) { t in Pill(t.rawValue, on: tab == t) { tab = t }.focusTaker().padding(.trailing, 4) }
                }
                .fixedSize()
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                Readout(hint, size: 10).lineLimit(1).fixedSize()
            }
            .padding(.bottom, 10)
            content
            if !live { playBar.padding(.top, 10) }
        }
        .padding(EdgeInsets(top: 20, leading: 28, bottom: 16, trailing: 28))
        .onAppear {
            player.setRate(page.rate)
            player.skipSilences = page.skipSilences
            if !live { player.prepare(session) }
        }
        // Stopped while on the page: the recording is made ready at once, so ▶ works (Windows' Refresh does this).
        .onChange(of: live) { if !live { player.prepare(session) } }
        .onDisappear { player.close(); flushSave() }
        // A live session's pipeline skips it while recording; a finished one's while a step is redone.
        .task { let n = notes, s = session; await n.keepIdleModel { s === n.current ? n.isRecording : n.redoing != nil } }
        .alert(NotesDialog.title, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
        .alert(NotesDialog.title, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            Button("Yes") {
                if askingStop { if notes.redoSession === session { notes.cancelRedo() } } else if let step = asking { redo(step) }
                asking = nil
            }
            Button("No", role: .cancel) { asking = nil }
        } message: { Text(redoQuestion) }
        .dialogLook(.question, shown: asking != nil)
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullScreen = false }
        #endif
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }), document: exporting,
                      contentType: exporting?.type ?? .plainText, defaultFilename: exporting?.name) { result in
            if case .failure(let e) = result {
                if exportingExt == "docx" { Log.warn("Extended notes: Word export failed: \(type(of: e))") }
                NotesDialog.warn("Saving failed: " + e.localizedDescription) { problem = $0 }
            }
        }
    }

    // MARK: Header

    /// Windows' DockPanel: the buttons docked right keep their size; the dot, the name and the timer (a horizontal
    /// StackPanel, measured at any width) get what is left and are cut off there, so a long name runs to the buttons
    /// with no "…" and pushes the timer out of sight.
    private var header: some View {
        HStack(spacing: 0) {
            headerLeft
                .fixedSize()
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
            headerButtons
                .padding(.leading, 6) // each button's left margin 6
                .fixedSize()
        }
    }

    private var headerLeft: some View {
        HStack(spacing: 0) {
            if live {
                Circle().strokeBorder(ob.record, lineWidth: 1.6)
                    .background(Circle().fill(!notes.isPaused && !notes.isFinishing ? ob.record : .clear))
                    .frame(width: 11, height: 11).padding(.trailing, 10)
            }
            if renaming {
                // A Fluent TextBox (4-pt corners, the control fill, the ink line while typing), MinWidth 360.
                TextField("", text: $title).textFieldStyle(.plain).font(Ob.mono(22, .bold))
                    .focused($titleFocused)
                    .fluentBox(focused: titleFocused)
                    .frame(minWidth: 360)
                    .fixedSize()
                    .onSubmit(commitTitle)
                    .onExitCommand { title = session.title; commitTitle() }
                    .onChange(of: titleFocused) { if !titleFocused { commitTitle() } }
                    .accessibilityLabel("Session name")
            } else {
                Button {
                    title = session.title
                    renaming = true
                    // Focused once the box exists (it then has its text selected, as TitleBox.Focus(); SelectAll()).
                    DispatchQueue.main.async { titleFocused = true }
                } label: {
                    // Padding 0,1 above the 1-px underline; upper-cased as ToUpperInvariant ("ß" stays).
                    Text(Self.invariantUpper(session.title)).font(Ob.mono(24, .bold)).lineLimit(1).fixedSize()
                        .padding(.top, 1).padding(.bottom, 2)
                        .overlay(alignment: .bottom) { Hairline() }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .tabStop(focused: $titleKeyFocused) {
                    title = session.title
                    renaming = true
                    DispatchQueue.main.async { titleFocused = true }
                }
                // WPF's own focus mark on a Button with its own template: a dotted rectangle 2 inside its edge.
                .overlay {
                    if titleKeyFocused {
                        Rectangle().strokeBorder(ob.ink, style: StrokeStyle(lineWidth: 1, dash: [1, 2])).padding(2).allowsHitTesting(false)
                    }
                }
                .focusTaker()
                .help("Click to rename")
                .accessibilityLabel("Session name; click to rename")
                .textCursor()
            }
            // The live timer reads the recorder's samples as they come in (Windows' 400 ms tick).
            TimelineView(.periodic(from: .now, by: 0.4)) { _ in
                Text(timer).font(Ob.mono(14, .bold)).foregroundStyle(live ? ob.ink : ob.muted).padding(.leading, 16).lineLimit(1).fixedSize()
            }
        }
    }

    private var headerButtons: some View {
            HStack(spacing: 6) {
                if live {
                    Button("⚑ Mark") { notes.addMarker() }.buttonStyle(.quiet).focusTaker().disabled(notes.isFinishing)
                        .help("Drop a time marker into the transcript (hotkey in Settings › Hotkeys)")
                        .accessibilityLabel("Drop a time marker into the transcript")
                    Button(notes.userPaused ? "● Resume" : "Ⅱ Pause") { notes.userPaused ? notes.resume() : notes.pause() }
                        .buttonStyle(.quiet).focusTaker().disabled(notes.isFinishing)
                }
                #if os(macOS)
                Button(fullScreen ? "⤡ Exit full screen" : "⤢ Full screen") { Self.toggleFullScreen(model) }.buttonStyle(.quiet).focusTaker()
                #endif
                exportMenu.focusTaker()
                if live {
                    Button("■ Stop") { Task { await notes.stop() } }.buttonStyle(.primary).focusTaker().disabled(notes.isFinishing)
                }
            }
    }

    private var timer: String {
        let seconds = live ? notes.seconds : session.seconds
        let state = !live ? "" : notes.isFinishing ? "  // FINISHING…" : notes.userPaused ? "  // PAUSED"
            : notes.isPaused ? "  // PAUSED WHILE YOU DICTATE" : !notes.transcribing ? "  // CONNECTING…" : ""
        return Self.length(seconds) + state
    }

    private func commitTitle() {
        guard renaming else { return }
        let t = title.trimmed
        if !t.isEmpty && t != session.title {
            session.title = t
            notes.store.save(session)
        }
        renaming = false
    }

    #if os(macOS)
    /// The sidebar's state before Full screen folded it, given back on the way out (MainWindow.SetFullScreen).
    private static var sidebarBefore: Bool?
    private static var foldWatch: AnyCancellable?

    /// Windows folds the sidebar for full screen without saving it (`SetSidebar(false, save: false)`): while in full
    /// screen, settings.json keeps the sidebar as it was before, whatever else is saved meanwhile, so even a crash or a
    /// forced quit there leaves it as the user had it.
    private static func keepSavedFold(_ model: AppModel) {
        func rewrite(_ settings: AppSettings) {
            guard let before = sidebarBefore, settings.sidebarCollapsed != before, !AppModel.snapshotMode else { return }
            var saved = settings
            saved.sidebarCollapsed = before
            _ = JSONFile<AppSettings>("settings.json").save(saved)
        }
        // After AppModel's own save of each change (it saves in didSet; the publisher fires before it).
        foldWatch = model.$settings.sink { s in DispatchQueue.main.async { MainActor.assumeIsolated { rewrite(s) } } }
        DispatchQueue.main.async { MainActor.assumeIsolated { rewrite(model.settings) } }
    }
    private static var exitWatch: NSObjectProtocol?
    private static var quitWatch: NSObjectProtocol?

    /// The window fills the screen and the sidebar folds away (the dashboard's Full screen does the same); leaving full
    /// screen, however it is left, puts the sidebar back as it was.
    static func toggleFullScreen(_ model: AppModel) {
        guard let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        if !w.styleMask.contains(.fullScreen) {
            sidebarBefore = model.settings.sidebarCollapsed
            model.settings.sidebarCollapsed = true
            keepSavedFold(model)
            if exitWatch == nil {
                exitWatch = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak model] _ in
                    MainActor.assumeIsolated {
                        foldWatch = nil
                        if let before = sidebarBefore { model?.settings.sidebarCollapsed = before }
                        sidebarBefore = nil
                    }
                }
            }
            // Windows folds the sidebar without saving it: quitting in full screen leaves the saved state as it was
            // before, so the next start opens with the sidebar as the user had it.
            if quitWatch == nil {
                quitWatch = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak model] _ in
                    MainActor.assumeIsolated {
                        foldWatch = nil
                        if let before = sidebarBefore { model?.settings.sidebarCollapsed = before }
                        sidebarBefore = nil
                    }
                }
            }
        }
        w.toggleFullScreen(nil)
    }
    #endif

    // MARK: Tabs

    private var hint: String {
        switch tab {
        case .edited: "Every change, in colour // read only"
        case .formatted: "Tidied by the AI about every minute // your edits stay"
        case .summary: "Main idea, key points, three paragraphs at most // every 5–10 minutes // edit freely"
        case .transcript: "Word for word, as it is heard // type anywhere to add your notes"
        }
    }

    @ViewBuilder private var content: some View {
        if PageScroll<EmptyView>.flat {
            if tab == .edited {
                VStack(alignment: .leading, spacing: 8) {
                    // The snapshot renderer can't draw a text view: the same text in SwiftUI.
                    EditedText(session: session, revision: notes.revision).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 11).padding(.vertical, 9).clipped()
                        .modifier(FluentField(focused: false))
                    EditedLegend()
                }
            } else {
                // The snapshot renderer can't draw a text view: the text as it reads.
                MarkdownReadingView(text: text, size: 14.5).padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
                    .modifier(FluentField(focused: false))
            }
        } else {
            // Read as Markdown; a click opens that line as plain text to edit (typing goes on at the end). One view per
            // text, and the Edited view, all kept while another tab shows, so each keeps its own scroll position and
            // cursor (only the tab showing takes clicks and the keyboard; a tab hidden renders its open line again, as
            // MarkdownPresenter.Shown does).
            ZStack(alignment: .topLeading) {
                ZStack {
                    ForEach([Tab.transcript, .formatted, .summary], id: \.self) { t in
                        let doc = Self.doc(t)
                        // Padding 14,12 inside the box's 1-px border.
                        MarkdownEditor(text: text(doc), size: 14.5, label: t.rawValue, inset: CGSize(width: 15, height: 13), shown: tab == t,
                                       onEdit: { edit($0, doc) }, onFocus: { textFocused[t] = $0 }, onCaret: { carets[t] = $0 },
                                       jump: { jumpItem($0, doc) }, playback: tab == t ? playback : nil, focusClicksOnly: true)
                    }
                }
                // Windows' NotesBox is the Fluent TextBox: 4-pt corners, the control fill, a hairline edge, and its
                // bottom line turning into the 2-pt ink line while typing.
                .modifier(FluentField(focused: textFocused[tab] == true))
                .opacity(tab == .edited ? 0 : 1)
                VStack(alignment: .leading, spacing: 8) {
                    EditedTextView(session: session, revision: notes.revision, live: live, shown: tab == .edited) { seconds in jumpItem(seconds: seconds) }
                        .modifier(FluentField(focused: false)) // a RichTextBox: the same Fluent box
                    EditedLegend()
                }
                .opacity(tab == .edited ? 1 : 0)
                .allowsHitTesting(tab == .edited)
                .accessibilityHidden(tab != .edited)
            }
        }
    }

    static func doc(_ t: Tab) -> NoteDoc { t == .formatted ? .formatted : t == .summary ? .summary : .transcript }

    /// While the recording plays, the word being said is lit: in the transcript and the formatted text, and in the
    /// summary where a phrase of it was said. Sessions from before word times were kept play unlit.
    private var playback: PlaybackWords? {
        guard !live, let words = session.words, !words.isEmpty else { return nil }
        let player = player
        return PlaybackWords(words: words, minRun: tab == .summary ? 3 : 1, time: { player.currentTime })
    }

    /// The tab's text, as the session has it now.
    private var text: String { text(doc) }

    private func text(_ doc: NoteDoc) -> String {
        _ = notes.revision
        return session.get(doc)
    }

    /// Typing edits the session (anchors and formatting marks move with it) and saves a moment later.
    private func edit(_ new: String, _ doc: NoteDoc) {
        session.set(doc, new, source: nil)
        model.objectWillChange.send()
        // The recorder saves its own session; the user's edits of a finished one are saved here, after a pause.
        guard !live else { return }
        saveSoon?.cancel()
        saveSoon = Task { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { notes.store.save(session) } }
    }

    // MARK: Jump to this moment

    /// The right-click item: the moment the text there was said (the Summary leads to its section by its words).
    private func jumpItem(_ at: Int, _ doc: NoteDoc) -> MarkdownJump? {
        jumpItem(seconds: doc == .summary ? session.summaryMoment(session.summary, caret: at) : session.secondsAt(doc, at))
    }

    /// The Jump item for a moment (the Edited tab's runs, or a place in a text). Play (▶) then goes on from there,
    /// until the cursor moves again (NotesPage.PlayFrom notes the cursor as it is).
    private func jumpItem(seconds: Double?) -> MarkdownJump {
        let title = live ? "Jump to this moment in the recording (once the session has stopped)"
            : seconds.map { "Jump to this moment in the recording  ·  \(Self.length($0))" } ?? "Jump to this moment in the recording"
        return MarkdownJump(title: title, enabled: seconds != nil && !live && hasRecording) {
            if let seconds { player.play(at: seconds, session, caret: caret) }
        }
    }

    private func flushSave() {
        if saveSoon != nil { notes.store.save(session) }
        saveSoon?.cancel()
    }

    /// Where the cursor is in the tab's text, in UTF-16 units; none on the Summary and Edited tabs (Windows' ActiveBox).
    private var caret: Int? {
        guard tab == .transcript || tab == .formatted else { return nil }
        return carets[tab].map { min($0, session.get(doc).utf16.count) }
    }

    // MARK: Export

    private var exportMenu: some View {
        Menu {
            ForEach(NotesExport.Part.allCases, id: \.self) { part in
                Menu(part.rawValue) {
                    Button("Copy to clipboard") { copy(part, markdown: false) }
                    if part == .everything { Button("Copy to clipboard as Markdown") { copy(part, markdown: true) } }
                    Divider()
                    Button("Save as text (.txt)…") { save(part, .plainText, "txt") }
                    Button("Save as Markdown (.md)…") { save(part, UTType(filenameExtension: "md") ?? .plainText, "md") }
                    Button("Save as Word (.docx)…") { save(part, UTType(filenameExtension: "docx") ?? .data, "docx") }
                }
            }
            Divider()
            Menu("Recording") {
                #if os(macOS)
                Button("Copy the file to the clipboard") { copyRecording() }
                #endif
                Button("Save as WAV (.wav)…") { saveRecording() }
            }
            .disabled(!hasRecording)
        } label: {
            // ToUpperInvariant, as the Content Windows sets ("EXPORT ▾", "COPIED 1,234 WORDS ✓").
            Text(Self.invariantUpper(page.copied ?? "Export ▾"))
        }
        .menuStyle(.button)
        // A Menu takes only a plain ButtonStyle (the capsules are a PrimitiveButtonStyle on the Mac): the same quiet pill.
        .buttonStyle(QuietMenuFace())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var hasRecording: Bool { session.audioURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// The title with Windows' invalid file-name characters (`"<>|:*?\\/` and control characters) as "_".
    private var safeName: String {
        var bad = CharacterSet(charactersIn: "\"<>|:*?\\/")
        bad.formUnion(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(31)))
        return session.title.components(separatedBy: bad).joined(separator: "_").trimmed
    }

    private func copy(_ part: NotesExport.Part, markdown: Bool) {
        let text = NotesExport.build(session, part: part, markdown: markdown)
        Clipboard.copy(text)
        page.flash("Copied \(NoteSession.words(text).formatted()) words ✓")
    }

    private func save(_ part: NotesExport.Part, _ type: UTType, _ ext: String) {
        let name = part == .everything ? safeName : "\(safeName) - \(part.rawValue)"
        let s = session
        let build = { ext == "docx" ? NotesExport.buildDocx(s, part: part) : Data(NotesExport.build(s, part: part, markdown: ext == "md").utf8) }
        #if os(macOS)
        // Built once the Save panel is closed (Windows builds after ShowDialog returns), so what was heard meanwhile is in it.
        savePanel(name: name + "." + ext, type: type, ext: ext) { url in try build().write(to: url, options: .atomic) }
        #else
        exportingExt = ext
        exporting = ExportFile(data: build(), type: type, name: name + "." + ext)
        #endif
    }

    #if os(macOS)
    /// The Save panel on the main window; `write` runs on the main thread once a place is chosen.
    private func savePanel(name: String, type contentType: UTType, ext: String, write: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try write(url) } catch {
                if ext == "docx" { Log.warn("Extended notes: Word export failed: \(type(of: error))") }
                NotesDialog.warn("Saving failed: " + error.localizedDescription) { problem = $0 }
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
    #endif

    /// As played: with its level brought up, once the recording has been prepared (and its copy is still there).
    private var recordingSource: URL? {
        if let url = player.prepared?.url, FileManager.default.fileExists(atPath: url.path) { return url }
        return session.audioURL
    }

    private func saveRecording() {
        guard hasRecording, let url = recordingSource else { return }
        #if os(macOS)
        savePanel(name: safeName + ".wav", type: .wav, ext: "wav") { to in
            if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
            try FileManager.default.copyItem(at: url, to: to)
        }
        #else
        exportingExt = "wav"
        exporting = ExportFile(file: url, type: .wav, name: safeName + ".wav")
        #endif
    }

    #if os(macOS)
    /// The recording to the clipboard as a file named after the session, so it can be pasted into a folder or an email.
    private func copyRecording() {
        guard let url = recordingSource else { return }
        let dir = FileManager.default.temporaryDirectory.appending(path: "oberton-copied", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appending(path: safeName + ".wav")
        do { try FileManager.default.copyItem(at: url, to: copy) } catch {
            Log.warn("Extended notes: copying the recording failed: \(type(of: error))")
            NotesDialog.warn("The recording couldn't be copied: " + error.localizedDescription) { problem = $0 }
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([copy as NSURL])
        page.flash("Copied the recording ✓")
    }
    #endif

    // MARK: Redo

    private var redoQuestion: String {
        if askingStop { return "Stop redoing? What is done so far stays; a transcript is only replaced once it is whole." }
        let minutes = max(1, Int((session.seconds / 60).rounded(.up)))
        switch asking {
        case .transcribe: return "Transcribe this session again from its recording? The transcript, the formatted text and the summary are made again, so edits and notes typed into them are replaced (your markers are kept). For \(minutes) minutes of recording this takes a few minutes."
        case .format: return "Format the whole transcript again? The formatted text and the summary are made again, so edits typed into them are replaced. The transcript stays as it is."
        default: return "Write the summary again? Edits typed into the summary are replaced."
        }
    }

    /// A click on a step of the session's pipeline: confirm, then redo it (or stop the one running). While another
    /// session is being redone, nothing.
    private func ask(_ step: NotesRedoStep) {
        if live { NotesDialog.inform("A step can be redone once the session has stopped.") { problem = $0 }; return }
        if notes.redoing != nil {
            if notes.redoSession === session { askingStop = true; asking = step }
            return
        }
        if step == .transcribe && !hasRecording { NotesDialog.inform("This session has no recording to transcribe again.") { problem = $0 }; return }
        askingStop = false
        asking = step
    }

    private func redo(_ step: NotesRedoStep) {
        if notes.redoing != nil {
            if notes.redoSession === session { notes.cancelRedo() }
            return
        }
        Task {
            do { try await notes.redo(session, step) } catch is CancellationError {
                Log.info("Extended notes: redo stopped")
            } catch let e as UserFacingError {
                NotesDialog.warn(e.localizedDescription) { problem = $0 }
            } catch {
                Log.error("Extended notes: redoing a step failed: \(error)")
                NotesDialog.warn("Redoing that step failed. See the log for details.") { problem = $0 }
            }
        }
    }

    // MARK: Playback

    /// The Summary and Edited tabs have no cursor moment: Play goes on from where it is.
    private func playOrPause() {
        if player.playing { player.pause() } else { let doc = doc; player.play(caret: caret, at: { session.secondsAt(doc, $0) }, session) }
    }

    private var playBar: some View {
        HStack(spacing: 12) {
            Button {
                playOrPause()
            } label: {
                PlayFace(playing: player.playing, keyFocused: playKeyFocused)
            }
            .buttonStyle(PlayButtonStyle())
            // A WPF Button: a Tab stop, Space or Return presses it, its accent border while it has the keyboard.
            .focusEffectDisabled()
            .tabStop(focused: $playKeyFocused) { playOrPause() }
            .handCursor(!(player.preparing || !hasRecording))
            .focusTaker()
            .disabled(player.preparing || !hasRecording)
            .help(player.prepared.map { $0.gainDb > 0.5 ? "Play from the cursor (level brought up \(Int($0.gainDb.rounded())) dB)" : "Play from the cursor" } ?? "Play from the cursor")
            .accessibilityLabel("Play the recording from the cursor; right-click the text to jump to a moment")
            Text(player.preparing ? "PREPARING…" : "\(Self.length(player.position)) / \(Self.length(max(session.seconds, player.duration)))")
                .font(Ob.mono(11.5)).frame(minWidth: 130, alignment: .leading)
            // The Fluent slider (SmallChange 0.1 s on the arrow keys).
            FluentSlider(value: Binding(get: { player.position }, set: { player.seek($0) }), range: 0...max(1, max(session.seconds, player.duration)), step: 0.1)
                .focusTaker()
                .accessibilityLabel("Position in the recording")
            HStack(spacing: 0) {
                Pill("Skip silences", on: player.skipSilences) { player.skipSilences.toggle(); page.skipSilences = player.skipSilences }
                    .focusTaker().padding(.trailing, 14)
                    .help("Jump over the pauses")
                    .accessibilityLabel("Skip silences")
                ForEach([1.0, 1.5, 2.0], id: \.self) { r in
                    // Each pill keeps the style's right margin 4, the last one too.
                    Pill(r == 1 ? "1×" : r == 1.5 ? "1.5×" : "2×", on: player.rate == r) { player.setRate(r); page.rate = r }.focusTaker().padding(.trailing, 4)
                }
            }
        }
        // Padding 12,8 inside the 1-px border.
        .padding(.horizontal, 13).padding(.vertical, 9)
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
    }

    /// .NET's ToUpperInvariant: each character's own capital where it has a single one ("ß" stays "ß"), never the
    /// language's rules.
    static func invariantUpper(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            let up = c.properties.uppercaseMapping.unicodeScalars
            if up.count == 1, let u = up.first { out.append(u) } else { out.append(c) }
        }
        return String(out)
    }

    /// .NET's `Contains(q, StringComparison.OrdinalIgnoreCase)`: each UTF-16 unit upper-cased on its own (simple
    /// mapping, invariant), then compared unit by unit.
    static func containsIgnoringCase(_ text: String, _ q: String) -> Bool {
        let needle = ordinalUpper(q)
        if needle.isEmpty { return true }
        let hay = ordinalUpper(text)
        guard hay.count >= needle.count else { return false }
        let first = needle[0]
        var i = 0
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == first {
                var k = 1
                while k < needle.count && hay[i + k] == needle[k] { k += 1 }
                if k == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    static func ordinalUpper(_ s: String) -> [UInt16] {
        s.utf16.map { u in
            if u < 0x80 { return u >= 0x61 && u <= 0x7A ? u - 0x20 : u }
            guard let scalar = Unicode.Scalar(u) else { return u } // a surrogate half stays as it is
            let up = scalar.properties.uppercaseMapping.unicodeScalars
            if up.count == 1, let v = up.first, v.value <= 0xFFFF { return UInt16(v.value) }
            return u
        }
    }

    static func length(_ seconds: Double) -> String {
        let t = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }

    static func sourceLabel(_ s: NotesSource) -> String {
        switch s {
        case .mic: "Mic"
        case .computer: "Computer audio"
        case .both: "Mic + computer"
        }
    }
}

/// A file for the Save panel.
struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    /// A file copied as it is when saved (the recording: not read into memory first).
    var file: URL?
    var type: UTType
    var name: String

    init(data: Data, type: UTType, name: String) { self.data = data; self.type = type; self.name = name }
    init(file: URL, type: UTType, name: String) { data = Data(); self.file = file; self.type = type; self.name = name }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data(); type = .data; name = "" }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if let file { return try FileWrapper(url: file, options: []) }
        return FileWrapper(regularFileWithContents: data)
    }
}

/// Windows' MessageBox title (AppInfo.Name) on every message of this page.
@MainActor
enum NotesDialog {
    static let title = "Oberton"

    /// MessageBoxImage.Warning. Windows' MessageBox shows whatever page is open (a start or a redo may fail after the
    /// page was left), so on the Mac it goes up on the main window as an alert of its own, with the caution badge.
    /// `fallback` shows it in the page instead (iPhone and iPad).
    static func warn(_ message: String, fallback: (String) -> Void) { show(message, warning: true, fallback: fallback) }

    /// MessageBoxImage.Information: a message with the information glyph.
    static func inform(_ message: String, fallback: (String) -> Void) { show(message, warning: false, fallback: fallback) }

    private static func show(_ message: String, warning: Bool, fallback: (String) -> Void) {
        #if os(macOS)
        guard !PageScroll<EmptyView>.flat else { fallback(message); return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        // MessageBoxImage.Warning / Information: the warning triangle or the "i", as the page's other dialogs show them.
        alert.alertStyle = warning ? .warning : .informational
        let kind: DialogKind = warning ? .warning : .information
        if let glyph = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
                .applying(NSImage.SymbolConfiguration(hierarchicalColor: warning ? .systemYellow : .systemBlue))) {
            alert.icon = glyph
        }
        alert.addButton(withTitle: "OK")
        NSSound.beep() // the Exclamation / Asterisk sound Windows plays with the box
        if let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
        #else
        fallback(message)
        #endif
    }
}

/// The Play button: a 36×36 ink circle with the play or pause glyph (PrimaryButton, Width 36, Height 36; Segoe Fluent
/// Icons' outline Play/Pause).
private struct PlayFace: View {
    var playing: Bool
    var keyFocused = false
    @Environment(\.ob) private var ob
    @Environment(\.isEnabled) private var enabled
    @Environment(\.playPressed) private var pressed
    @Environment(\.isFocused) private var focused
    @State private var hover = false

    var body: some View {
        Image(systemName: playing ? "pause" : "play").font(.system(size: 13)).foregroundStyle(ob.onInk)
            .frame(width: 36, height: 36)
            .background(Circle().fill(ob.ink))
            .overlay(Circle().strokeBorder(ob.accent, lineWidth: focused || keyFocused ? 1 : 0))
            .contentShape(Circle())
            // PrimaryButton's triggers: hover 0.82, pressed 0.66, disabled 0.4, accent border on keyboard focus.
            .opacity(!enabled ? 0.4 : pressed ? 0.66 : hover ? 0.82 : 1)
            .onHover { hover = enabled && $0 }
    }
}

/// EXPORT ▾'s face: App.xaml's QuietButton (an ink outline at CornerRadius 17, at least 34 tall, Padding 16 inside the
/// line, the hover wash, 0.7 while pressed, the hand) for a Menu, which on the Mac takes only a plain ButtonStyle.
private struct QuietMenuFace: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(label: configuration.label, pressed: configuration.isPressed) }

    private struct Face<Label: View>: View {
        var label: Label
        var pressed: Bool
        @Environment(\.ob) private var ob
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 17)
            label
                .font(Ob.mono(12))
                .lineLimit(1)
                .foregroundStyle(ob.ink)
                .padding(.horizontal, 16 + Ob.border)
                .frame(minHeight: 34)
                .background(shape.fill(hover ? ob.subtle : .clear))
                .overlay(shape.strokeBorder(ob.ink, lineWidth: 1))
                .contentShape(shape)
                .opacity(!enabled ? 0.4 : pressed ? 0.7 : 1)
                .onHover { hover = enabled && $0 }
                .handCursor(enabled)
        }
    }
}

/// The Play button's own style: no system dimming; the face draws the pressed state.
private struct PlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.playPressed, configuration.isPressed)
    }
}

private extension EnvironmentValues {
    @Entry var playPressed = false
}

fileprivate extension View {
    /// A control that takes the keyboard when clicked (a focusable WPF control): a click on it renders an open line of
    /// the text again; a click anywhere else on the page leaves it open (NOTES-159).
    func focusTaker() -> some View {
        #if os(macOS)
        takesFocusOnClick()
        #else
        self
        #endif
    }

    /// The pointing hand over something clickable (WPF's Cursor="Hand").
    func handCursor() -> some View {
        #if os(macOS)
        pointerStyle(.link)
        #else
        self
        #endif
    }

    /// The text cursor over the session's name (WPF's Cursor="IBeam").
    func textCursor() -> some View {
        #if os(macOS)
        pointerStyle(.horizontalText)
        #else
        self
        #endif
    }
}

// MARK: - The Edited tab

/// Every change, in colour: the AI's in the accent (added) and struck through in grey (removed), a ¶ where it made a
/// paragraph; the user's in their own ink (amber), struck through, bold on a wash, or bold and underlined.
struct EditedText: View {
    var session: NoteSession
    var revision: Int
    @Environment(\.ob) private var ob

    var body: some View {
        let pieces = NotesEdits.build(session)
        if pieces.allSatisfy({ $0.mark == .paragraph }) {
            Text("Nothing yet: changes show here once the AI has formatted some text or you have edited it.").font(Ob.sans(14.5)).foregroundStyle(ob.muted)
        } else {
            // Paragraphs 12 apart, lines about 24 pt (the app shows `EditedTextView`; this is the snapshots' stand-in).
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(Self.paragraphs(pieces, ob: ob).enumerated()), id: \.offset) { _, p in
                    Text(p).font(Ob.sans(14.5)).lineSpacing(7)
                }
            }
        }
    }

    static func userInk(_ ob: Palette) -> Color { ob.dark ? Color(hex: 0xFFB347) : Color(hex: 0x8A4B00) }
    static func userWash(_ ob: Palette) -> Color { ob.dark ? Color(hex: 0xFFB347, alpha: 0.16) : Color(hex: 0x8A4B00, alpha: 0.12) }

    static func styled(_ text: String, _ mark: EditMark, ob: Palette) -> AttributedString {
        var r = AttributedString(text)
        switch mark {
        case .aiRemoved: r.strikethroughStyle = .single; r.foregroundColor = ob.muted
        case .aiAdded: r.foregroundColor = ob.accent
        case .userRemoved: r.foregroundColor = userInk(ob); r.strikethroughStyle = Text.LineStyle(pattern: .solid, color: userInk(ob)) // thick in `EditedTextView`
        case .userChanged: r.foregroundColor = userInk(ob); r.inlinePresentationIntent = .stronglyEmphasized; r.backgroundColor = userWash(ob)
        case .userNote: r.foregroundColor = userInk(ob); r.inlinePresentationIntent = .stronglyEmphasized; r.underlineStyle = .single
        default: r.foregroundColor = ob.ink
        }
        return r
    }

    /// The paragraphs; neighbouring words with the same mark become one run (an hour of notes stays quick to show).
    static func paragraphs(_ pieces: [EditPiece], ob: Palette) -> [AttributedString] {
        var all: [AttributedString] = []
        var out = AttributedString()
        var mark: EditMark?
        var run = ""
        func flush() {
            if let mark, !run.isEmpty { out += styled(run, mark, ob: ob); out += AttributedString(" ") }
            run = ""
        }
        for p in pieces {
            if p.mark == .paragraph || p.mark == .aiParagraph {
                flush()
                if p.mark == .aiParagraph {
                    var pil = AttributedString("¶")
                    pil.foregroundColor = ob.accent
                    pil.inlinePresentationIntent = .stronglyEmphasized
                    out += pil
                }
                if !out.characters.isEmpty { all.append(out); out = AttributedString() }
                mark = nil
                continue
            }
            if mark != p.mark { flush(); mark = p.mark }
            if !run.isEmpty { run += " " }
            run += p.text
        }
        flush()
        if !out.characters.isEmpty { all.append(out) }
        return all
    }
}

struct EditedLegend: View {
    @Environment(\.ob) private var ob

    /// A WrapPanel of items with Margin 0,0,18,4: an item wraps when it and its 18 after it don't fit, and the last
    /// row keeps its 4 below.
    var body: some View {
        FlowRow(spacing: 18, lineSpacing: 4, top: true, marginWraps: true) {
            ForEach([("Removed by AI", EditMark.aiRemoved), ("Added by AI", .aiAdded)], id: \.0) { item($0.0, $0.1) }
            Text("¶ PARAGRAPH BREAK BY AI").font(Ob.mono(10.5)).foregroundStyle(ob.muted)
            ForEach([("Removed by you", EditMark.userRemoved), ("Changed by you", .userChanged), ("Note typed by you", .userNote)], id: \.0) { item($0.0, $0.1) }
        }
        .padding(.bottom, 4)
    }

    private static func unstruck(_ a: AttributedString) -> AttributedString { var a = a; a.strikethroughStyle = nil; return a }

    @ViewBuilder private func item(_ label: String, _ mark: EditMark) -> some View {
        if mark == .userRemoved {
            // Windows' Pen(user, 2) in FontRecommended units: 2 × Cascadia Mono's strikeout size (100/2048 em), about
            // 1 px at 10.5, at its strikeout position (636/2048 em, about 3.26 pt above the baseline; the middle of the
            // line is about 3.64).
            Text(Self.unstruck(EditedText.styled(label.uppercased(), mark, ob: ob))).font(Ob.mono(10.5))
                .overlay { Rectangle().fill(EditedText.userInk(ob)).frame(height: 10.5 * 200 / 2048).offset(y: 0.38) }
        } else {
            Text(EditedText.styled(label.uppercased(), mark, ob: ob)).font(Ob.mono(10.5))
        }
    }
}

// MARK: - The pipeline at the top

/// One step of the pipeline: its label, its model or source, what it is doing, and its state.
struct PipeStep {
    var label: String
    var title: String
    var status: String
    var state: DotState
    var hint: String?
}

/// What each step is doing (NotesPage.PipelineSteps / RedoSteps).
@MainActor
enum NotesSteps {
    /// The speech model as Windows names it (`Speech.LoadedModel ?? SpeechModels.For(...)`): the Whisper model's id,
    /// or Apple Speech.
    static func speechName(_ model: AppModel) -> String { NotesRecorder.whisperModel(model.activeSpeech) ?? "Apple Speech" }

    /// The AI model the session uses, or the one a session would use now (worked out every half minute).
    static func aiName(_ n: NotesRecorder) -> String { (n.model ?? n.idleModel)?.notesName ?? "…" }

    static func live(_ model: AppModel, chosen: NotesSource) -> [PipeStep] {
        let n = model.notes
        let source = NoteSessionView.sourceLabel(n.current?.source ?? chosen)
        let speech = speechName(model)
        let listen: PipeStep, speechStep: PipeStep
        if let live = n.current {
            listen = n.isFinishing ? PipeStep(label: "LISTEN", title: source, status: "stopped", state: .ok)
                : n.isPaused ? PipeStep(label: "LISTEN", title: source, status: n.userPaused ? "paused" : "paused while you dictate", state: .ok)
                : PipeStep(label: "LISTEN", title: source, status: "recording", state: .busy)
            speechStep = n.isFinishing ? PipeStep(label: "SPEECH", title: speech, status: "the last piece…", state: .busy)
                : n.isPaused ? PipeStep(label: "SPEECH", title: speech, status: "waiting", state: .ok)
                : n.transcribing ? PipeStep(label: "SPEECH", title: speech, status: "transcribing", state: .busy)
                : PipeStep(label: "SPEECH", title: speech, status: "connecting…", state: .ok)
            let ai = aiName(n)
            return [listen, speechStep,
                    n.isFormatting ? PipeStep(label: "FORMAT", title: ai, status: "formatting now", state: .busy)
                        : PipeStep(label: "FORMAT", title: ai, status: "\(live.unformattedWords().formatted()) words waiting", state: .ok),
                    n.isSummarizing ? PipeStep(label: "SUMMARY", title: ai, status: "summing up now", state: .busy)
                        : PipeStep(label: "SUMMARY", title: ai, status: "next section \(min(99, live.unsummarizedChars() * 100 / NotesSummary.sectionChars))% there", state: .ok)]
        }
        let ai = aiName(n)
        return [PipeStep(label: "LISTEN", title: source, status: "ready", state: .ok),
                PipeStep(label: "SPEECH", title: speech, status: model.speechLoaded ? "loaded" : "loads when a session starts", state: model.speechLoaded ? .ok : .off),
                n.isFormatting ? PipeStep(label: "FORMAT", title: ai, status: "formatting now", state: .busy) : PipeStep(label: "FORMAT", title: ai, status: "about every minute", state: .ok),
                n.isSummarizing ? PipeStep(label: "SUMMARY", title: ai, status: "summing up now", state: .busy) : PipeStep(label: "SUMMARY", title: ai, status: "every 5–10 minutes", state: .ok)]
    }

    /// A finished session's pipeline: each step redoes itself when clicked; while one is redone, it is lit with how far
    /// it got, and the steps after it wait for it.
    static func redo(_ model: AppModel, _ s: NoteSession) -> [PipeStep] {
        let n = model.notes
        let redo = n.redoSession === s ? n.redoing : nil
        let other = n.redoing != nil && redo == nil
        let progress = n.redoProgress.isEmpty ? "" : " · " + n.redoProgress
        let ai = aiName(n)
        let again = "Click to transcribe this session again from its recording (then format and sum it up again)"
        func make(_ label: String, _ title: String, _ step: NotesRedoStep, _ idle: String, _ doing: String, _ hint: String) -> PipeStep {
            if redo == step { return PipeStep(label: label, title: title, status: doing + progress, state: .busy, hint: "Click to stop") }
            if let redo, step > redo { return PipeStep(label: label, title: title, status: "waiting", state: .ok) }
            if redo != nil { return PipeStep(label: label, title: title, status: "done", state: .ok) }
            return PipeStep(label: label, title: title, status: other ? "another session is being redone" : idle, state: .ok, hint: hint)
        }
        let recorded = s.audioURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return [make("LISTEN", NoteSessionView.sourceLabel(s.source), .transcribe, recorded ? "recorded · \(NoteSessionView.length(s.seconds))" : "no recording", "reading again", again),
                make("SPEECH", speechName(model), .transcribe, "click to transcribe again", "transcribing again", again),
                make("FORMAT", ai, .format, "click to format again", "formatting again", "Click to format the whole transcript again (then sum it up again)"),
                make("SUMMARY", ai, .summary, "click to sum up again", "summing up again", "Click to write the summary again")]
    }
}

/// The top of Extended Notes: its own signal path, drawn like the dashboard's (NotesPipeline.cs). What it listens to →
/// the speech model → the AI formatting → the AI summing up. A step lights in the accent, its core pulsing, while it
/// is at work; hollow while it is off.
struct NotesPipelineView: View {
    var steps: [PipeStep]
    var open: [(() -> Void)?]
    @Environment(\.ob) private var ob
    private let w = 1000.0, h = 118.0, y = 46.0, r = 15.0, col = 250.0

    var body: some View {
        CappedAspect(ratio: w / h, maxHeight: 150) {
            GeometryReader { geo in
                let scale = min(geo.size.width / w, geo.size.height / h)
                drawing.frame(width: w, height: h).scaleEffect(scale, anchor: .topLeading).frame(width: w * scale, height: h * scale, alignment: .topLeading)
            }
        }
    }

    private func x(_ i: Int) -> Double { col / 2 + Double(i) * col }

    private var drawing: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                var line = Path()
                line.move(to: CGPoint(x: x(0), y: y)); line.addLine(to: CGPoint(x: x(3), y: y))
                ctx.stroke(line, with: .color(ob.ink), lineWidth: 1)
                for i in 0..<3 {
                    let mid = (x(i) + x(i + 1)) / 2
                    var a = Path()
                    a.addLines([CGPoint(x: mid - 3, y: y - 4), CGPoint(x: mid + 3, y: y), CGPoint(x: mid - 3, y: y + 4)])
                    ctx.stroke(a, with: .color(ob.ink), lineWidth: 1)
                }
            }
            .frame(width: w, height: h)
            ForEach(Array(steps.prefix(4).enumerated()), id: \.offset) { i, s in
                PipeColumn(step: s, open: i < open.count ? open[i] : nil, width: col, height: h, y: y, r: r).offset(x: x(i) - col / 2)
            }
        }
    }
}

private struct PipeColumn: View {
    var step: PipeStep
    var open: (() -> Void)?
    var width, height, y, r: Double
    @Environment(\.ob) private var ob
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .top) {
            Text(step.label).font(Ob.mono(13, .bold))
            Circle().fill(ob.paper).overlay(Circle().strokeBorder(step.state == .busy ? ob.accent : ob.ink, lineWidth: 1))
                .frame(width: r * 2, height: r * 2).padding(.top, y - r)
            Group {
                switch step.state {
                case .off: Circle().strokeBorder(ob.muted, lineWidth: 1)
                case .ok: Circle().fill(ob.ink)
                case .busy: PulsingCore()
                }
            }
            .frame(width: 9, height: 9).padding(.top, y - 4.5)
            VStack(spacing: 2) {
                Text(step.title.uppercased()).font(Ob.mono(12.5))
                Text(step.status.uppercased()).font(Ob.mono(11.5)).foregroundStyle(step.state == .busy ? ob.accent : ob.muted)
            }
            .lineLimit(1).truncationMode(.tail).frame(maxWidth: width - 12).padding(.top, y + r + 7)
        }
        .foregroundStyle(ob.ink)
        .frame(width: width, height: height, alignment: .top)
        .background(open != nil && hover ? ob.accentWash : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { open?() }
        .modifier(HandIf(on: open != nil))
        .help("\(step.label): \(step.title) · \(step.status)" + (step.hint.map { "\n" + $0 } ?? ""))
    }
}

/// A busy step's core: the accent, its opacity going 1 → 0.25 over 0.8 s and back, linearly, for as long as the step is
/// busy; a step that becomes busy again starts afresh at 1 (a new view each time).
private struct PulsingCore: View {
    @Environment(\.ob) private var ob
    @State private var dim = false

    var body: some View {
        Circle().fill(ob.accent).opacity(dim ? 0.25 : 1)
            .onAppear { withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: true)) { dim = true } }
    }
}

private struct HandIf: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on { content.handCursor() } else { content }
    }
}

// MARK: - Pieces

/// A capsule choice (source, tab, speed) or switch (skip silences): ink outline, filled with ink when chosen.
struct Pill: View {
    var title: String
    var on: Bool
    var action: () -> Void
    @Environment(\.ob) private var ob
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    @FocusState private var focused: Bool
    @State private var keyFocused = false

    init(_ title: String, on: Bool, action: @escaping () -> Void) { self.title = title; self.on = on; self.action = action }

    /// As Windows' Pill template: no look of its own when disabled (only no hover or click), an accent outline on
    /// keyboard focus, the hand over it.
    var body: some View {
        Button(action: action) {
            Text(title.uppercased()).font(Ob.mono(11, .semibold)).lineLimit(1)
                .foregroundStyle(on ? ob.onInk : ob.ink)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(on ? ob.ink : hover ? ob.subtle : .clear))
                .overlay(Capsule().strokeBorder((focused || keyFocused) && !on ? ob.accent : ob.ink, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(PlainFaceStyle())
        .focused($focused)
        .tabStop(focused: $keyFocused, action: action)
        .focusEffectDisabled()
        // A disabled ToggleButton has no IsMouseOver, and WPF shows the arrow over it.
        .onHover { hover = enabled && $0 }
        .onChange(of: enabled) { if !enabled { hover = false } }
        .handCursor(enabled)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A button style that draws the label as it is: no dimming while pressed or disabled (Windows' Pill template has no
/// IsPressed or IsEnabled trigger).
struct PlainFaceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// A grid row of star-sized columns (Windows' `*` widths) and a last column at its own size.
struct StarColumns: Layout {
    var weights: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let sizes = widths(width, subviews)
        let height = zip(subviews, sizes).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (v, w) in zip(subviews, widths(bounds.width, subviews)) {
            let h = v.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            v.place(at: CGPoint(x: x, y: bounds.midY - h / 2), proposal: ProposedViewSize(width: w, height: h))
            x += w
        }
    }

    private func widths(_ total: CGFloat, _ subviews: Subviews) -> [CGFloat] {
        let auto = subviews.enumerated().filter { $0.offset >= weights.count }.map { $0.element.sizeThatFits(.unspecified).width }
        let room = max(0, total - auto.reduce(0, +))
        let sum = weights.reduce(0, +)
        return weights.prefix(subviews.count).map { room * $0 / sum } + auto
    }
}

/// Takes the full width and the height that keeps the drawing's proportions, up to `maxHeight` (a Viewbox with MaxHeight).
struct CappedAspect: Layout {
    var ratio: CGFloat
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1000
        return CGSize(width: width, height: min(maxHeight, width / ratio))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for v in subviews { v.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

/// Lays its children out in rows, wrapping to the next when one is full (WPF's WrapPanel).
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    /// Items at the top of their line (WPF's WrapPanel), not centred in it.
    var top = false
    /// The spacing is each item's own right margin (WPF Margin): an item goes to the next line when it and its margin
    /// don't fit.
    var marginWraps = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width + (marginWraps ? spacing : 0) > width { y += line + lineSpacing; x = 0; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        var row: [(LayoutSubview, CGSize, CGFloat)] = []
        func flush() {
            for (v, s, vx) in row { v.place(at: CGPoint(x: vx, y: top ? y : y + (line - s.height) / 2), proposal: ProposedViewSize(s)) }
            row = []
        }
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width + (marginWraps ? spacing : 0) > bounds.maxX { flush(); y += line + lineSpacing; x = bounds.minX; line = 0 }
            row.append((v, s, x))
            x += s.width + spacing
            line = max(line, s.height)
        }
        flush()
    }
}

/// The AI model drop-down for Extended Notes, on the start card and on Settings › Models (one setting): the best model
/// on this Mac (the default), the active model, each installed Ollama model, and cloud models that have a key while
/// "Keep everything offline" is off (NotesModelChoices.cs).
struct NotesModelMenu: View {
    var width: CGFloat?
    @EnvironmentObject var model: AppModel
    /// The list once filled: blank each time the box first shows, until Ollama answers (Windows builds the page anew on
    /// every visit, and its box is empty until FillAsync).
    @State private var installed: [NotesModels.Installed]? = PageScroll<EmptyView>.flat ? [] : nil

    var body: some View {
        // Before the list arrives the box shows nothing (one blank choice: the setting as it is).
        let options = installed.map { self.options($0) } ?? [(model.settings.notesModel, "")]
        ObMenu(options: options, selection: Binding(get: {
            // The choice as stored, matched without regard to case (and an older "ollama:<name>" as that model).
            let v = model.settings.notesModel
            return options.first { $0.0.caseInsensitiveCompare(v) == .orderedSame }?.0
                ?? options.first { $0.0.caseInsensitiveCompare(Self.bare(v)) == .orderedSame }?.0 ?? v
        }, set: { v in
            guard v != model.settings.notesModel else { return }
            model.settings.notesModel = v
            Log.info("Extended notes: AI model set to " + (v.isEmpty ? "the best on this \(Device.noun)" : v))
        }), width: width)
            .help("Formats and sums up the session. Also under Settings › Models.")
            .accessibilityLabel("AI model for Extended Notes")
            .task {
                // ListModelDetailsAsync: Oberton's own runtime is started first if nothing answers (Direct).
                installed = await NotesRecorder.listModels(model.settings)
            }
    }

    /// An Ollama model is stored by its own name, as Windows stores it ("qwen3:8b"); older settings have "ollama:qwen3:8b".
    static func bare(_ v: String) -> String {
        if let id = ModelID(v), id.provider == .ollama { return id.name }
        return v
    }

    private func options(_ installed: [NotesModels.Installed]) -> [(String, String)] {
        let st = model.settings
        let gpu = NotesRecorder.gpuBytes, ram = LocalModel.systemRam
        let best = NotesModels.pickBest(installed, gpuBytes: gpu, ramBytes: ram)
        var list: [(String, String)] = [
            (NotesModels.best, best.map { "Best on this \(Device.noun) · \($0.name)" } ?? "Best on this \(Device.noun) · no local model installed yet"),
            (NotesModels.active, "Same as the active model · \(st.defaultModel.notesName)"),
        ]
        if st.defaultModel != .appleOnDevice && AppleIntelligenceBackend.unavailableReason == nil {
            list.append((ModelID.appleOnDevice.description, ModelID.appleOnDevice.displayName))
        }
        // Largest first, then by name as the user's language sorts it (Windows' culture comparer).
        list += installed.filter(NotesModels.isChatModel).sorted {
            $0.billions != $1.billions ? $0.billions > $1.billions : $0.name.compare($1.name, locale: NotesExport.userLocale) == .orderedAscending
        }.map { m in
            (m.name,
             "\(m.name) · \(Self.billions(m.billions))B"
                + (m.runsFromMemory(gpuBytes: gpu, ramBytes: ram) ? " (\(Self.billions(m.activeBillions))B at work) · runs from memory"
                   : NotesModels.fits(m, gpuBytes: gpu, ramBytes: ram) ? "" : " · slow on this \(Device.noun)"))
        }
        if !st.cloud.keepOffline {
            // Ollama's cloud models run on ollama.com, so they are listed as cloud models.
            list += installed.filter { ModelID.isOllamaCloud($0.name) }.sorted { $0.name.compare($1.name, locale: NotesExport.userLocale) == .orderedAscending }.map { m in
                (m.name, "\(m.name) · cloud: the transcript goes to ollama.com")
            }
            for c in CloudCatalog.anthropic where KeyStore.get(.anthropic) != nil { list.append((c.id.description, "\(c.title) · cloud: the transcript goes to Anthropic")) }
            if KeyStore.get(.openai) != nil { list.append(("openai:\(st.cloud.openAIModel)", "\(st.cloud.openAIModel) · cloud: the transcript goes to OpenAI-compatible")) }
        }
        let current = st.notesModel
        if !list.contains(where: { $0.0.caseInsensitiveCompare(current) == .orderedSame || $0.0.caseInsensitiveCompare(Self.bare(current)) == .orderedSame }) {
            list.append((current, Self.bare(current) + " · not available"))
        }
        return list
    }

    /// "7.6", "30" (Windows' {0:0.#}, a tie rounded away from zero, in the user's own decimal mark).
    static func billions(_ b: Double) -> String {
        ((b * 10).rounded(.toNearestOrAwayFromZero) / 10).formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }
}

extension ModelID {
    /// The model as Windows writes it on this page: an Ollama model by its name, a cloud model by its id
    /// ("anthropic:claude-haiku-4-5-20251001"), Apple's on-device model by its name.
    var notesName: String {
        switch provider {
        case .ollama: name
        case .apple: "Apple Intelligence"
        case .anthropic, .openai: description
        }
    }
}

// MARK: - Playback

/// The recording, once the session has stopped: made ready (its level brought up, its pauses found) in the background,
/// then played from the cursor, at 1×, 1.5× or 2×, skipping silences if asked (NotesPage's player). Silent until Play;
/// Play or a jump before it is ready makes it ready and plays then. At the end it stays paused at the end.
@MainActor
final class NotesPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var prepared: PreparedAudio?
    @Published private(set) var preparing = false
    @Published private(set) var playing = false
    @Published private(set) var position = 0.0
    @Published private(set) var rate = 1.0
    @Published var skipSilences = false
    private var player: AVAudioPlayer?
    /// The readout and the slider (400 ms, as Windows' page tick) and Skip silences (120 ms).
    private var tick: Timer?
    private var skipTick: Timer?
    /// The cursor (UTF-16, in the tab's text) Play last started from: Play seeks only once it has moved
    /// (NotesPage's `_lastPlayCaret`, an index, so a click elsewhere in the same piece seeks again).
    private var lastCaret: Int?
    private var failed = false
    /// A moment to start from once the recording is ready (a seek or jump before then).
    private var pendingSeek: Double?
    /// Play once the recording is ready.
    private var autoPlay = false

    var duration: Double { player?.duration ?? prepared?.seconds ?? 0 }
    /// Where the playback is, while it plays (nil when paused or stopped): the word being said is lit from it.
    var currentTime: Double? { playing ? player?.currentTime : nil }

    func prepare(_ s: NoteSession) {
        guard prepared == nil, !preparing, !failed, let url = s.audioURL, FileManager.default.fileExists(atPath: url.path) else { return }
        preparing = true
        let id = s.id
        Task {
            let result: PreparedAudio?
            do { result = try await Task.detached { try NotesAudio.prepareCached(url, sessionID: id) }.value } catch {
                Log.warn("Extended notes: couldn't prepare the recording: \(error.localizedDescription)")
                result = nil
            }
            preparing = false
            guard let result, let p = try? AVAudioPlayer(contentsOf: result.url) else { failed = true; autoPlay = false; return }
            p.enableRate = true
            p.delegate = self
            p.prepareToPlay()
            prepared = result
            player = p
            if let at = pendingSeek { p.currentTime = min(at, p.duration); position = p.currentTime }
            pendingSeek = nil
            if autoPlay { autoPlay = false; start() }
        }
    }

    /// Play; from the moment the text at the cursor was said, if the cursor moved since the last play. Not ready yet:
    /// made ready, then played.
    func play(caret: Int?, at seconds: (Int) -> Double, _ s: NoteSession) {
        guard let player else { autoPlay = true; prepare(s); return }
        if let caret, caret != lastCaret {
            lastCaret = caret
            player.currentTime = seconds(caret)
        }
        start()
    }

    /// Jump to a moment and play from there (the right-click menu); the recording is made ready first if need be.
    func play(at seconds: Double, _ s: NoteSession, caret: Int?) {
        lastCaret = caret
        guard let player else {
            pendingSeek = seconds
            position = seconds
            autoPlay = true
            prepare(s)
            return
        }
        player.currentTime = seconds
        position = seconds
        start()
    }

    private func start() {
        guard let player else { return }
        player.rate = Float(rate)
        player.play()
        playing = true
        position = player.currentTime
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in Task { @MainActor in self?.onTick() } }
        skipTick?.invalidate()
        skipTick = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in Task { @MainActor in self?.onSkipTick() } }
    }

    func pause() {
        player?.pause()
        playing = false
        tick?.invalidate()
        skipTick?.invalidate()
        if let player { position = player.currentTime }
    }

    /// The slider: before the recording is ready, kept for when it is.
    func seek(_ seconds: Double) {
        if let player { player.currentTime = seconds } else { pendingSeek = seconds }
        position = seconds
    }

    func setRate(_ r: Double) {
        rate = r
        if playing { player?.rate = Float(r) }
    }

    private func onTick() {
        guard let player else { return }
        position = player.currentTime
    }

    /// While "skip silences" is on: over a pause, jump to just before its end.
    private func onSkipTick() {
        guard skipSilences, playing, let player, let gap = prepared?.silence(at: player.currentTime),
              gap.end - player.currentTime > NotesAudio.keepGap else { return }
        player.currentTime = gap.end - NotesAudio.keepGap
    }

    /// The end: paused there, the readout at the end (AVAudioPlayer would go back to 0).
    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard p === self.player else { return }
            self.pause()
            p.currentTime = p.duration
            self.position = p.duration
        }
    }

    func close() {
        pause()
        player = nil
        prepared = nil
        pendingSeek = nil
        autoPlay = false
        failed = false
    }
}

#if os(iOS)
private extension View {
    func onExitCommand(perform: @escaping () -> Void) -> some View { self }
}
#endif
