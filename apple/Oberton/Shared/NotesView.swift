import AVFoundation
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

    var body: some View {
        if let id = nav.place.noteSessionID, let s = model.notes.store.sessions.first(where: { $0.id == id }) {
            NoteSessionView(session: s).id(id)
        } else {
            NotesLanding()
        }
    }
}

// MARK: - Landing

struct NotesLanding: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @State private var search = ""
    @State private var starting = false
    @State private var problem: String?
    @State private var deleting: NoteSession?
    @State private var idleModel: ModelID?

    private var notes: NotesRecorder { model.notes }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Text("EXTENDED NOTES").font(Ob.mono(30, .bold))
                    Decor("記録", size: 26)
                }
                Rule().padding(.vertical, 6)
                Caption("Leave it on through a lecture or a meeting. It transcribes as it goes, tidies the text with the AI about every minute, keeps a running summary and the recording, and you can type your own notes straight into the text. Everything stays on this \(Device.noun).")
                NotesPipelineView(steps: NotesSteps.live(model, chosen: chosenSource, idleModel: idleModel),
                                  open: [{ nav.goSettings(.microphone) }, { nav.goSettings(.speech) }, { nav.goSettings(.models) }, { nav.goSettings(.models) }])
                    .padding(.top, 2)
                startCard.padding(.top, 14)
                usageStrip
                HStack {
                    FieldLabel("Sessions")
                    Spacer()
                    Readout("Search").padding(.trailing, 8)
                    TextField("", text: $search).textFieldStyle(.plain).font(Ob.sans(13)).padding(.horizontal, 8).padding(.vertical, 5)
                        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1)).frame(width: 240)
                        .accessibilityLabel("Search the sessions")
                }
                .padding(.top, 22).padding(.bottom, 8)
                list
            }
            .padding(EdgeInsets(top: 20, leading: 28, bottom: 16, trailing: 28))
        }
        .task { idleModel = await NotesRecorder.resolve(model.settings) }
        .alert("Extended notes", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
        .alert("Delete \"\(deleting?.title ?? "")\" with its recording? This can't be undone.",
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let d = deleting { notes.store.delete(d); model.objectWillChange.send() }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
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
                FlowRow(spacing: 6) {
                    Button {
                        if let live = notes.current { nav.goNotes(live.id); return }
                        starting = true
                        Task {
                            do {
                                try await notes.start(source: chosenSource)
                                if let s = notes.current { nav.goNotes(s.id) }
                            } catch { problem = error.localizedDescription }
                            starting = false
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Circle().strokeBorder(ob.record, lineWidth: 1.6).background(Circle().fill(notes.isRecording ? ob.record : .clear))
                                .frame(width: 11, height: 11)
                            Text(notes.current.map { "● Recording // \($0.title) // Open" } ?? "Extended notes session")
                        }
                    }
                    .buttonStyle(.quiet)
                    .disabled(starting)
                    .accessibilityLabel("Start an extended notes session")
                    .padding(.trailing, 12)
                    Readout("Listen to").padding(.trailing, 4)
                    #if os(macOS)
                    ForEach([(NotesSource.mic, "Mic"), (.computer, "Computer audio"), (.both, "Both")], id: \.0) { source, label in
                        Pill(label, on: model.settings.notesSource == source) { model.settings.notesSource = source }.disabled(notes.isRecording)
                    }
                    #else
                    Pill("Mic", on: true) {}
                    #endif
                    Readout("AI model").padding(.leading, 14).padding(.trailing, 4)
                    NotesModelMenu(width: 300)
                }
                Readout("Keeps the recording // about 115 MB an hour // dictating into an app pauses the session, then it resumes", size: 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
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
            .padding(.horizontal, 14).padding(.vertical, 9)
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
            .padding(.top, 10)
        }
    }

    private func usageRow(_ label: String, _ t: NotesUsageTotals) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Readout(label).frame(width: 170, alignment: .leading)
            FlowRow(spacing: 22) {
                readout(t.sessions.formatted(), t.sessions == 1 ? "session" : "sessions")
                readout(NotesUsage.hoursMinutes(t.seconds), "recorded")
                readout(t.wordsHeard.formatted(), "words heard")
                readout(t.wordsTyped.formatted(), "words typed")
                readout(t.aiRequests.formatted(), "AI requests")
                let by = [NotesSource.mic, .computer, .both].compactMap { s in t.sources[s.rawValue].map { "\(s.rawValue.uppercased()) \($0)" } }
                if !by.isEmpty { Text(by.joined(separator: " · ")).font(Ob.mono(10.5)).foregroundStyle(ob.muted) }
            }
        }
    }

    private func readout(_ value: String, _ label: String) -> some View {
        (Text(value).font(Ob.mono(13, .bold)).foregroundColor(ob.ink) + Text(" " + label.uppercased()).font(Ob.mono(10.5)).foregroundColor(ob.muted))
    }

    @ViewBuilder private var list: some View {
        let q = search.trimmed
        let sessions = notes.store.sessions.filter {
            q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.transcript.localizedCaseInsensitiveContains(q) || $0.summary.localizedCaseInsensitiveContains(q)
        }
        if sessions.isEmpty {
            Caption(q.isEmpty ? "No sessions yet. Start one above and it appears here." : "No session matches.").padding(.top, 6).padding(.leading, 2)
        } else {
            VStack(spacing: 0) { ForEach(sessions) { row($0) } }
        }
    }

    private func row(_ s: NoteSession) -> some View {
        NoteRow(session: s, live: s === notes.current) { deleting = s }
            .onTapGesture { nav.goNotes(s.id) }
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(Ob.mono(13, .bold)).lineLimit(1)
                Text(Self.gist(s)).font(Ob.sans(12)).foregroundStyle(ob.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(2.4)
            Text(Calendar.current.isDateInToday(s.started) ? "Today " + s.started.formatted(date: .omitted, time: .shortened)
                 : s.started.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                .font(Ob.mono(11.5)).lineLimit(1).frame(width: 150, alignment: .leading)
            Text(NoteSessionView.length(s.seconds)).font(Ob.mono(11.5)).frame(width: 80, alignment: .leading)
            Text(NoteSessionView.sourceLabel(s.source).uppercased()).font(Ob.mono(10.5)).foregroundStyle(ob.muted).lineLimit(1).frame(width: 120, alignment: .leading)
            if live {
                Text("● RECORDING").font(Ob.mono(10.5, .bold)).foregroundStyle(ob.record)
            } else {
                Button("Delete", action: delete).buttonStyle(.quietSmall).fixedSize()
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 10)
        .background(hover ? ob.subtle : .clear)
        .overlay(alignment: .bottom) { Hairline() }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    static func gist(_ s: NoteSession) -> String {
        let text = (!s.summary.trimmed.isEmpty ? s.summary : !s.formatted.trimmed.isEmpty ? s.formatted : s.transcript)
            .replacingOccurrences(of: "\n", with: " ").trimmed
        return text.isEmpty ? "Nothing transcribed yet." : text.count > 140 ? String(text.prefix(140)).trimmed + "…" : text
    }
}

// MARK: - A session

struct NoteSessionView: View {
    let session: NoteSession
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @StateObject private var player = NotesPlayer()
    @State private var tab = Self.snapshotTab
    /// The tab a session opens on (the debug snapshots set it).
    static var snapshotTab = Tab.transcript
    @State private var renaming = false
    @State private var title = ""
    /// Where the cursor is in the tab's text (UTF-16), for the Play button.
    @State private var caretOffset: Int?
    @State private var copied: String?
    @State private var problem: String?
    @State private var asking: NotesRedoStep?
    @State private var exporting: ExportFile?
    @State private var saveSoon: Task<Void, Never>?
    @FocusState private var titleFocused: Bool

    enum Tab: String, CaseIterable { case transcript = "Transcript", formatted = "Formatted", summary = "Summary", edited = "Edited" }

    private var notes: NotesRecorder { model.notes }
    private var live: Bool { session === notes.current }
    private var doc: NoteDoc { tab == .formatted ? .formatted : tab == .summary ? .summary : .transcript }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button("← Extended notes") { nav.goNotes(nil) }.buttonStyle(.quietSmall).padding(.bottom, 8)
            header
            Rule().padding(.vertical, 10)
            // A step redoes itself (and what follows it) from the recording, once the session has stopped.
            NotesPipelineView(steps: live ? NotesSteps.live(model, chosen: session.source, idleModel: nil) : NotesSteps.redo(model, session),
                              open: [.transcribe, .transcribe, .format, .summary].map { step in { ask(step) } })
                .padding(.bottom, 8)
            HStack {
                ForEach(Tab.allCases, id: \.self) { t in Pill(t.rawValue, on: tab == t) { tab = t; caretOffset = nil } }
                Spacer()
                Readout(hint, size: 10).lineLimit(1)
            }
            .padding(.bottom, 10)
            content
            if !live { playBar.padding(.top, 10) }
        }
        .padding(EdgeInsets(top: 20, leading: 28, bottom: 16, trailing: 28))
        .onAppear { if !live { player.prepare(session) } }
        .onDisappear { player.close(); flushSave() }
        .alert("Extended notes", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
        .alert(redoQuestion, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            Button(notes.redoing != nil ? "Stop" : "Redo") { if let step = asking { redo(step) }; asking = nil }
            Button("Cancel", role: .cancel) { asking = nil }
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }), document: exporting,
                      contentType: exporting?.type ?? .plainText, defaultFilename: exporting?.name) { result in
            if case .failure(let e) = result { problem = "Saving failed: " + e.localizedDescription }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            if live {
                Circle().strokeBorder(ob.record, lineWidth: 1.6)
                    .background(Circle().fill(!notes.isPaused && !notes.isFinishing ? ob.record : .clear))
                    .frame(width: 11, height: 11).padding(.trailing, 10)
            }
            if renaming {
                TextField("", text: $title).textFieldStyle(.plain).font(Ob.mono(22, .bold)).frame(minWidth: 360)
                    .focused($titleFocused)
                    .onSubmit(commitTitle)
                    .onExitCommand { title = session.title; commitTitle() }
                    .onChange(of: titleFocused) { if !titleFocused { commitTitle() } }
                    .accessibilityLabel("Session name")
            } else {
                Text(session.title.uppercased()).font(Ob.mono(24, .bold)).lineLimit(1)
                    .padding(.vertical, 1)
                    .overlay(alignment: .bottom) { Hairline() }
                    .onTapGesture { title = session.title; renaming = true; titleFocused = true }
                    .help("Click to rename")
            }
            Text(timer).font(Ob.mono(14, .bold)).foregroundStyle(live ? ob.ink : ob.muted).padding(.leading, 16).lineLimit(1)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if live {
                    Button("⚑ Mark") { notes.addMarker() }.buttonStyle(.quiet).disabled(notes.isFinishing)
                        .help("Drop a time marker into the transcript (hotkey in Settings › Hotkeys)")
                    Button(notes.userPaused ? "● Resume" : "Ⅱ Pause") { notes.userPaused ? notes.resume() : notes.pause() }
                        .buttonStyle(.quiet).disabled(notes.isFinishing)
                }
                #if os(macOS)
                Button(isFullScreen ? "⤡ Exit full screen" : "⤢ Full screen") { Self.toggleFullScreen(model) }.buttonStyle(.quiet)
                #endif
                exportMenu
                if live {
                    Button("■ Stop") { Task { await notes.stop() } }.buttonStyle(.primary).disabled(notes.isFinishing)
                }
            }
        }
    }

    private var timer: String {
        let seconds = live ? (notes.revision >= 0 ? session.seconds : 0) : session.seconds
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
    private var isFullScreen: Bool { NSApp.keyWindow?.styleMask.contains(.fullScreen) == true }

    /// The window fills the screen and the sidebar folds away (the dashboard's Full screen does the same).
    static func toggleFullScreen(_ model: AppModel) {
        guard let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        let entering = !w.styleMask.contains(.fullScreen)
        model.settings.sidebarCollapsed = entering
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
        if tab == .edited {
            VStack(alignment: .leading, spacing: 8) {
                PageScroll {
                    EditedText(session: session, revision: notes.revision).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
                }
                .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
                EditedLegend()
            }
        } else if PageScroll<EmptyView>.flat {
            // The snapshot renderer can't draw a text view: the text as it reads.
            MarkdownReadingView(text: text, size: 14.5).padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
                .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
        } else {
            // Read as Markdown; a click opens that line as plain text to edit (typing goes on at the end).
            MarkdownEditor(text: text, size: 14.5, label: tab.rawValue, onEdit: edit, onCaret: { caretOffset = $0 }, jump: jumpItem)
                .id(tab)
                .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
        }
    }

    /// The tab's text, as the session has it now.
    private var text: String {
        _ = notes.revision
        return session.get(doc)
    }

    /// Typing edits the session (anchors and formatting marks move with it) and saves a moment later.
    private func edit(_ new: String) {
        session.set(doc, new, source: nil)
        model.objectWillChange.send()
        // The recorder saves its own session; the user's edits of a finished one are saved here, after a pause.
        guard !live else { return }
        saveSoon?.cancel()
        saveSoon = Task { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { notes.store.save(session) } }
    }

    // MARK: Jump to this moment

    /// The right-click item: the moment the text there was said (the Summary leads to its section by its words).
    private func jumpItem(_ at: Int) -> MarkdownJump? {
        let seconds = doc == .summary ? session.summaryMoment(session.summary, caret: at) : session.secondsAt(doc, at)
        let title = live ? "Jump to this moment in the recording (once the session has stopped)"
            : seconds.map { "Jump to this moment in the recording  ·  \(Self.length($0))" } ?? "Jump to this moment in the recording"
        return MarkdownJump(title: title, enabled: seconds != nil && !live && hasRecording) {
            // Play (▶) then goes on from here rather than from the cursor's own moment.
            if let seconds { player.play(at: seconds, session, caretSeconds: session.secondsAt(doc, at)) }
        }
    }

    private func flushSave() {
        if saveSoon != nil { notes.store.save(session) }
        saveSoon?.cancel()
    }

    /// Where the cursor is in the tab's text, in UTF-16 units.
    private var caret: Int? { caretOffset.map { min($0, session.get(doc).utf16.count) } }

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
            Text(copied ?? "Export ▾")
        }
        .menuStyle(.button)
        .buttonStyle(.quiet)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var hasRecording: Bool { session.audioURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    private var safeName: String {
        session.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "_").trimmed
    }

    private func copy(_ part: NotesExport.Part, markdown: Bool) {
        let text = NotesExport.build(session, part: part, markdown: markdown)
        Clipboard.copy(text)
        flash("Copied \(NoteSession.words(text).formatted()) words ✓")
    }

    private func flash(_ what: String) {
        copied = what
        Task { try? await Task.sleep(for: .seconds(2)); if copied == what { copied = nil } }
    }

    private func save(_ part: NotesExport.Part, _ type: UTType, _ ext: String) {
        let name = part == .everything ? safeName : "\(safeName) - \(part.rawValue)"
        let data = ext == "docx" ? NotesExport.buildDocx(session, part: part) : Data(NotesExport.build(session, part: part, markdown: ext == "md").utf8)
        exporting = ExportFile(data: data, type: type, name: name + "." + ext)
    }

    /// As played: with its level brought up, once the recording has been prepared.
    private var recordingSource: URL? { player.prepared?.url ?? session.audioURL }

    private func saveRecording() {
        guard let url = recordingSource, let data = try? Data(contentsOf: url) else { return }
        exporting = ExportFile(data: data, type: .wav, name: safeName + ".wav")
    }

    #if os(macOS)
    /// The recording to the clipboard as a file named after the session, so it can be pasted into a folder or an email.
    private func copyRecording() {
        guard let url = recordingSource else { return }
        let dir = FileManager.default.temporaryDirectory.appending(path: "oberton-copied", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appending(path: safeName + ".wav")
        do { try FileManager.default.copyItem(at: url, to: copy) } catch { problem = "The recording couldn't be copied: " + error.localizedDescription; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([copy as NSURL])
        flash("Copied the recording ✓")
    }
    #endif

    // MARK: Redo

    private var redoQuestion: String {
        if notes.redoing != nil {
            return notes.redoSession === session ? "Stop redoing? What is done so far stays; a transcript is only replaced once it is whole."
                : "Another session is being redone; wait for it to finish."
        }
        let minutes = max(1, Int((session.seconds / 60).rounded(.up)))
        switch asking {
        case .transcribe: return "Transcribe this session again from its recording? The transcript, the formatted text and the summary are made again, so edits and notes typed into them are replaced (your markers are kept). For \(minutes) minutes of recording this takes a few minutes."
        case .format: return "Format the whole transcript again? The formatted text and the summary are made again, so edits typed into them are replaced. The transcript stays as it is."
        default: return "Write the summary again? Edits typed into the summary are replaced."
        }
    }

    /// A click on a step of the session's pipeline: confirm, then redo it (or stop the one running).
    private func ask(_ step: NotesRedoStep) {
        if live { problem = "A step can be redone once the session has stopped."; return }
        asking = step
    }

    private func redo(_ step: NotesRedoStep) {
        if notes.redoing != nil {
            if notes.redoSession === session { notes.cancelRedo() }
            return
        }
        if step == .transcribe && !hasRecording { problem = "This session has no recording to transcribe again."; return }
        Task {
            do { try await notes.redo(session, step) } catch is CancellationError {} catch { problem = error.localizedDescription }
        }
    }

    // MARK: Playback

    private var playBar: some View {
        HStack(spacing: 12) {
            Button {
                if player.playing { player.pause() } else { player.play(from: caret.map { session.secondsAt(doc, $0) }) }
            } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 13))
            }
            .buttonStyle(.primary)
            .disabled(player.preparing || !hasRecording)
            .help(player.prepared.map { $0.gainDb > 0.5 ? "Play from the cursor (level brought up \(Int($0.gainDb.rounded())) dB)" : "Play from the cursor" } ?? "Play from the cursor")
            .accessibilityLabel("Play the recording from the cursor")
            Text(player.preparing ? "PREPARING…" : "\(Self.length(player.position)) / \(Self.length(max(session.seconds, player.duration)))")
                .font(Ob.mono(11.5)).frame(minWidth: 130, alignment: .leading)
            Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(1, max(session.seconds, player.duration)))
                .tint(ob.ink)
                .accessibilityLabel("Position in the recording")
            Pill("Skip silences", on: player.skipSilences) { player.skipSilences.toggle() }.padding(.trailing, 10)
            ForEach([1.0, 1.5, 2.0], id: \.self) { r in
                Pill(r == 1 ? "1×" : r == 1.5 ? "1.5×" : "2×", on: player.rate == r) { player.setRate(r) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
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
    var type: UTType
    var name: String

    init(data: Data, type: UTType, name: String) { self.data = data; self.type = type; self.name = name }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data(); type = .data; name = "" }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
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
        if pieces.isEmpty {
            Text("Nothing yet: changes show here once the AI has formatted some text or you have edited it.").font(Ob.sans(14.5)).foregroundStyle(ob.muted)
        } else {
            Text(Self.attributed(pieces, ob: ob)).font(Ob.sans(14.5)).lineSpacing(6).textSelection(.enabled)
        }
    }

    static func userInk(_ ob: Palette) -> Color { ob.dark ? Color(hex: 0xFFB347) : Color(hex: 0x8A4B00) }
    static func userWash(_ ob: Palette) -> Color { ob.dark ? Color(hex: 0xFFB347, alpha: 0.16) : Color(hex: 0x8A4B00, alpha: 0.12) }

    static func styled(_ text: String, _ mark: EditMark, ob: Palette) -> AttributedString {
        var r = AttributedString(text)
        switch mark {
        case .aiRemoved: r.strikethroughStyle = .single; r.foregroundColor = ob.muted
        case .aiAdded: r.foregroundColor = ob.accent
        case .userRemoved: r.foregroundColor = userInk(ob); r.strikethroughStyle = Text.LineStyle(pattern: .solid, color: userInk(ob))
        case .userChanged: r.foregroundColor = userInk(ob); r.inlinePresentationIntent = .stronglyEmphasized; r.backgroundColor = userWash(ob)
        case .userNote: r.foregroundColor = userInk(ob); r.inlinePresentationIntent = .stronglyEmphasized; r.underlineStyle = .single
        default: r.foregroundColor = ob.ink
        }
        return r
    }

    /// Neighbouring words with the same mark become one run (an hour of notes stays quick to show).
    static func attributed(_ pieces: [EditPiece], ob: Palette) -> AttributedString {
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
                if !out.characters.isEmpty { out += AttributedString("\n\n") }
                mark = nil
                continue
            }
            if mark != p.mark { flush(); mark = p.mark }
            if !run.isEmpty { run += " " }
            run += p.text
        }
        flush()
        return out
    }
}

struct EditedLegend: View {
    @Environment(\.ob) private var ob

    var body: some View {
        FlowRow(spacing: 18) {
            ForEach([("Removed by AI", EditMark.aiRemoved), ("Added by AI", .aiAdded)], id: \.0) { item($0.0, $0.1) }
            Text("¶ PARAGRAPH BREAK BY AI").font(Ob.mono(10.5)).foregroundStyle(ob.muted)
            ForEach([("Removed by you", EditMark.userRemoved), ("Changed by you", .userChanged), ("Note typed by you", .userNote)], id: \.0) { item($0.0, $0.1) }
        }
    }

    private func item(_ label: String, _ mark: EditMark) -> some View {
        Text(EditedText.styled(label.uppercased(), mark, ob: ob)).font(Ob.mono(10.5))
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
    static func live(_ model: AppModel, chosen: NotesSource, idleModel: ModelID?) -> [PipeStep] {
        let n = model.notes
        let source = NoteSessionView.sourceLabel(n.current?.source ?? chosen)
        let speech = "Apple Speech"
        let listen: PipeStep, speechStep: PipeStep
        if let live = n.current {
            listen = n.isFinishing ? PipeStep(label: "LISTEN", title: source, status: "stopped", state: .ok)
                : n.isPaused ? PipeStep(label: "LISTEN", title: source, status: n.userPaused ? "paused" : "paused while you dictate", state: .ok)
                : PipeStep(label: "LISTEN", title: source, status: "recording", state: .busy)
            speechStep = n.isFinishing ? PipeStep(label: "SPEECH", title: speech, status: "the last piece…", state: .busy)
                : n.isPaused ? PipeStep(label: "SPEECH", title: speech, status: "waiting", state: .ok)
                : n.transcribing ? PipeStep(label: "SPEECH", title: speech, status: "transcribing", state: .busy)
                : PipeStep(label: "SPEECH", title: speech, status: "connecting…", state: .ok)
            let ai = (n.model ?? idleModel)?.shortName ?? "…"
            return [listen, speechStep,
                    n.isFormatting ? PipeStep(label: "FORMAT", title: ai, status: "formatting now", state: .busy)
                        : PipeStep(label: "FORMAT", title: ai, status: "\(live.unformattedWords().formatted()) words waiting", state: .ok),
                    n.isSummarizing ? PipeStep(label: "SUMMARY", title: ai, status: "summing up now", state: .busy)
                        : PipeStep(label: "SUMMARY", title: ai, status: "next section \(min(99, live.unsummarizedChars() * 100 / NotesSummary.sectionChars))% there", state: .ok)]
        }
        let ai = (n.model ?? idleModel)?.shortName ?? "…"
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
        let ai = n.model?.shortName ?? ModelID(model.settings.notesModel)?.shortName ?? (model.settings.notesModel == NotesModels.active ? model.settings.defaultModel.shortName : "Best on this \(Device.noun)")
        let again = "Click to transcribe this session again from its recording (then format and sum it up again)"
        func make(_ label: String, _ title: String, _ step: NotesRedoStep, _ idle: String, _ doing: String, _ hint: String) -> PipeStep {
            if redo == step { return PipeStep(label: label, title: title, status: doing + progress, state: .busy, hint: "Click to stop") }
            if let redo, step > redo { return PipeStep(label: label, title: title, status: "waiting", state: .ok) }
            if redo != nil { return PipeStep(label: label, title: title, status: "done", state: .ok) }
            return PipeStep(label: label, title: title, status: other ? "another session is being redone" : idle, state: .ok, hint: hint)
        }
        let recorded = s.audioURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return [make("LISTEN", NoteSessionView.sourceLabel(s.source), .transcribe, recorded ? "recorded · \(NoteSessionView.length(s.seconds))" : "no recording", "reading again", again),
                make("SPEECH", "Apple Speech", .transcribe, "click to transcribe again", "transcribing again", again),
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
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .top) {
            Text(step.label).font(Ob.mono(13, .bold))
            Circle().fill(ob.paper).overlay(Circle().strokeBorder(step.state == .busy ? ob.accent : ob.ink, lineWidth: 1))
                .frame(width: r * 2, height: r * 2).padding(.top, y - r)
            Group {
                switch step.state {
                case .off: Circle().strokeBorder(ob.muted, lineWidth: 1)
                case .ok: Circle().fill(ob.ink)
                case .busy: Circle().fill(ob.accent).opacity(pulse ? 0.25 : 1)
                        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true } }
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
        .help("\(step.label): \(step.title) · \(step.status)" + (step.hint.map { "\n" + $0 } ?? ""))
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

    init(_ title: String, on: Bool, action: @escaping () -> Void) { self.title = title; self.on = on; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title.uppercased()).font(Ob.mono(11, .semibold)).lineLimit(1)
                .foregroundStyle(on ? ob.onInk : ob.ink)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(on ? ob.ink : hover ? ob.subtle : .clear))
                .overlay(Capsule().strokeBorder(ob.ink, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hover = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { y += line + lineSpacing; x = 0; line = 0 }
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
            for (v, s, vx) in row { v.place(at: CGPoint(x: vx, y: y + (line - s.height) / 2), proposal: ProposedViewSize(s)) }
            row = []
        }
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { flush(); y += line + lineSpacing; x = bounds.minX; line = 0 }
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
    @State private var installed: [NotesModels.Installed] = []

    var body: some View {
        ObMenu(options: options, selection: $model.settings.notesModel, width: width)
            .help("Formats and sums up the session. Also under Settings › Models.")
            .accessibilityLabel("AI model for Extended Notes")
            .task {
                if let url = try? OllamaBackend.validated(model.settings.ollamaEndpoint) { installed = await OllamaBackend.installedDetails(endpoint: url) }
            }
    }

    private var options: [(String, String)] {
        let st = model.settings
        let gpu = NotesRecorder.gpuBytes, ram = LocalModel.systemRam
        let best = NotesModels.pickBest(installed, gpuBytes: gpu, ramBytes: ram)
        var list: [(String, String)] = [
            (NotesModels.best, best.map { "Best on this \(Device.noun) · \($0.name)" } ?? "Best on this \(Device.noun) · \(st.defaultModel.shortName) (no Ollama model)"),
            (NotesModels.active, "Same as the active model · \(st.defaultModel.shortName)"),
        ]
        if st.defaultModel != .appleOnDevice && AppleIntelligenceBackend.unavailableReason == nil {
            list.append((ModelID.appleOnDevice.description, ModelID.appleOnDevice.displayName))
        }
        list += installed.filter(NotesModels.isChatModel).sorted { ($0.billions, $1.name) > ($1.billions, $0.name) }.map { m in
            (ModelID(provider: .ollama, name: m.name).description,
             "\(m.name) · \(Self.billions(m.billions))B"
                + (m.runsFromMemory(gpuBytes: gpu, ramBytes: ram) ? " (\(Self.billions(m.activeBillions))B at work) · runs from memory"
                   : NotesModels.fits(m, gpuBytes: gpu, ramBytes: ram) ? "" : " · slow on this \(Device.noun)"))
        }
        if !st.cloud.keepOffline {
            // Ollama's cloud models run on ollama.com, so they are listed as cloud models.
            list += installed.filter { ModelID.isOllamaCloud($0.name) && !$0.name.lowercased().contains("embed") }.sorted { $0.name < $1.name }.map { m in
                (ModelID(provider: .ollama, name: m.name).description, "\(m.name) · cloud: the transcript goes to ollama.com")
            }
            for c in CloudCatalog.anthropic where KeyStore.get(.anthropic) != nil { list.append((c.id.description, "\(c.title) · cloud: the transcript goes to Anthropic")) }
            if KeyStore.get(.openai) != nil { list.append(("openai:\(st.cloud.openAIModel)", "\(st.cloud.openAIModel) · cloud: the transcript goes to OpenAI")) }
        }
        if !list.contains(where: { $0.0.lowercased() == st.notesModel.lowercased() }) { list.append((st.notesModel, st.notesModel + " · not available")) }
        return list
    }

    /// "7.6", "30" (Windows' {0:0.#}).
    static func billions(_ b: Double) -> String {
        let r = (b * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }
}

// MARK: - Playback

/// The recording, once the session has stopped: made ready (its level brought up, its pauses found) in the background,
/// then played from the cursor, at 1×, 1.5× or 2×, skipping silences if asked.
@MainActor
final class NotesPlayer: ObservableObject {
    @Published private(set) var prepared: PreparedAudio?
    @Published private(set) var preparing = false
    @Published private(set) var playing = false
    @Published private(set) var position = 0.0
    @Published private(set) var rate = 1.0
    @Published var skipSilences = false
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var lastCaret: Double?
    private var failed = false
    /// A moment to play from as soon as the recording is ready.
    private var pendingSeek: Double?

    var duration: Double { player?.duration ?? prepared?.seconds ?? 0 }

    func prepare(_ s: NoteSession) {
        guard prepared == nil, !preparing, !failed, let url = s.audioURL, FileManager.default.fileExists(atPath: url.path) else { return }
        preparing = true
        let id = s.id
        Task {
            let result = await Task.detached { try? NotesAudio.prepareCached(url, sessionID: id) }.value
            preparing = false
            guard let result, let p = try? AVAudioPlayer(contentsOf: result.url) else { failed = true; return }
            p.enableRate = true
            p.prepareToPlay()
            prepared = result
            player = p
            if let at = pendingSeek { pendingSeek = nil; play(at: at, s) }
        }
    }

    /// Play; from the moment the text at the cursor was said, if the cursor moved since the last play.
    func play(from caretSeconds: Double?) {
        guard let player else { return }
        if let caretSeconds, caretSeconds != lastCaret {
            lastCaret = caretSeconds
            player.currentTime = caretSeconds
        }
        player.rate = Float(rate)
        player.play()
        playing = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in Task { @MainActor in self?.onTick() } }
    }

    /// Jump to a moment and play from there (the right-click menu); the recording is made ready first if need be.
    func play(at seconds: Double, _ s: NoteSession, caretSeconds: Double? = nil) {
        lastCaret = caretSeconds ?? lastCaret
        guard let player else {
            pendingSeek = seconds
            prepare(s)
            return
        }
        player.currentTime = seconds
        position = seconds
        play(from: nil)
    }

    func pause() {
        player?.pause()
        playing = false
        timer?.invalidate()
    }

    func seek(_ seconds: Double) {
        player?.currentTime = seconds
        position = seconds
    }

    func setRate(_ r: Double) {
        rate = r
        if playing { player?.rate = Float(r) }
    }

    /// While "skip silences" is on: over a pause, jump to just before its end.
    private func onTick() {
        guard let player else { return }
        if !player.isPlaying { pause(); position = player.currentTime; return }
        if skipSilences, let gap = prepared?.silence(at: player.currentTime), gap.end - player.currentTime > NotesAudio.keepGap {
            player.currentTime = gap.end - NotesAudio.keepGap
        }
        position = player.currentTime
    }

    func close() {
        pause()
        player = nil
    }
}

#if os(iOS)
private extension View {
    func onExitCommand(perform: @escaping () -> Void) -> some View { self }
}
#endif
