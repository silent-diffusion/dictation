import AVFoundation
import Combine
import ObertonCore
import SwiftUI

/// HISTORY 履歴: the list at the left (newest first, or by app), the chosen dictation at the right (HistoryPage.xaml).
struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var folded: Set<String> = []
    /// RUN AGAIN is running (for the whole page, as on Windows), and the line under the dictation.
    @State private var rerunning = false
    @State private var info = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "History", japanese: "履歴", readout: "Dictations // on this \(Device.noun)")
            HStack(alignment: .center) {
                Caption(countLine, size: 12.5)
                Spacer()
                Readout("Show")
                ObMenu(options: [(false, "Newest first"), (true, "By app, newest first")], selection: $model.settings.historyByApp, width: 230)
            }
            .padding(.top, 12).padding(.bottom, 14)
            if sizeClass == .compact {
                if let entry = selected, nav.place.historyID != nil { PageScroll { detail(entry) } } else { list }
            } else {
                HStack(alignment: .top, spacing: 20) {
                    list.frame(width: 320)
                    PageScroll {
                        if let entry = selected { detail(entry) }
                    }
                }
            }
        }
        .onChange(of: selected?.id) { info = "" }
        .padding(sizeClass == .compact ? EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16) : EdgeInsets(top: 28, leading: 32, bottom: 24, trailing: 32))
    }

    private var selected: HistoryEntry? {
        model.history.first { $0.id == nav.place.historyID } ?? (sizeClass == .compact ? nil : model.history.first)
    }

    private func detail(_ entry: HistoryEntry) -> some View {
        HistoryDetail(entry: entry, rerunning: $rerunning, info: $info).id(entry.id)
    }

    /// The line under the title (HistoryPage.UpdateCount).
    private var countLine: String {
        let s = model.settings, n = model.history.count
        return !s.keepHistory ? "History is off (Settings › History). Earlier dictations stay until you clear them."
            : s.historyLimit > 0 ? "\(n) of the last \(s.historyLimit) dictations, kept on this \(Device.noun) (they survive updates). Change how many under Settings › History."
            : s.historyDays > 0 ? "\(n) dictations from the last \(HistoryStore.daysLabel(s.historyDays)), kept on this \(Device.noun) (they survive updates). Change how long under Settings › History."
            : "\(n) dictations, all kept on this \(Device.noun) (they survive updates). Change this under Settings › History."
    }

    private var list: some View {
        PageScroll {
            LazyVStack(spacing: 0) {
                if model.history.isEmpty {
                    Caption("Nothing here yet. Your dictations appear here, with their recordings.", size: 12.5)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                } else if model.settings.historyByApp {
                    ForEach(groups, id: \.0) { app, entries in
                        Button {
                            if folded.contains(app) { folded.remove(app) } else { folded.insert(app) }
                        } label: {
                            HStack(spacing: 10) {
                                Text(app).font(Ob.sans(12, .bold))
                                Readout("\(entries.count)")
                                Spacer()
                                Text(folded.contains(app) ? "+" : "−").font(Ob.mono(12)).foregroundStyle(ob.muted)
                            }
                            .padding(EdgeInsets(top: 9, leading: 12, bottom: 7, trailing: 12))
                            .background(ob.subtle)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if !folded.contains(app) { ForEach(entries) { row($0) } }
                    }
                } else {
                    ForEach(model.history) { row($0) }
                }
            }
            .padding(6)
        }
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
    }

    private var groups: [(String, [HistoryEntry])] {
        Dictionary(grouping: model.history) { $0.appLabel }.map { ($0.key, $0.value) }.sorted { $0.1[0].date > $1.1[0].date }
    }

    private func row(_ e: HistoryEntry) -> some View {
        HistoryRow(entry: e, selected: sizeClass != .compact && selected?.id == e.id) { nav.goHistory(e.id) }
    }
}

struct HistoryRow: View {
    var entry: HistoryEntry
    var selected: Bool
    var action: () -> Void
    @Environment(\.ob) private var ob
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Readout(HistoryEntry.when(entry.date) + "  ·  " + entry.appLabel)
                    Spacer()
                    Readout(HistoryEntry.duration(entry.seconds))
                }
                Text(entry.preview)
                    .font(Ob.sans(13.5)).lineLimit(2).multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected || hover ? ob.subtle : .clear)
            .overlay(alignment: .leading) { if selected { Rectangle().fill(ob.ink).frame(width: 3) } }
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// One dictation in full: where it went, its recording, the three boxes, RUN AGAIN (HistoryPage.ShowDetailNow).
struct HistoryDetail: View {
    var entry: HistoryEntry
    @Binding var rerunning: Bool
    @Binding var info: String
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @StateObject private var player = HistoryPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.date.formatted(.dateTime.weekday(.wide).day().month(.wide)) + ", " + entry.date.formatted(date: .omitted, time: .shortened))
                        .font(Ob.mono(16, .bold))
                    // The window title Windows adds after the app needs Accessibility, which the sandbox doesn't allow.
                    Caption((entry.didInsert ? "Inserted into \(entry.appLabel)" : "Not inserted (meant for \(entry.appLabel))")
                            + "\nProfile: \(entry.profileName) · \(HistoryEntry.duration(entry.seconds)) of speech", size: 12.5)
                    if let at = entry.runAgainAt, entry.earlier != nil {
                        let showingEarlier = entry.showingEarlier ?? false
                        HStack(spacing: 10) {
                            Caption("Run again \(at.formatted(.dateTime.day().month(.abbreviated))), \(at.formatted(date: .omitted, time: .shortened))"
                                    + (showingEarlier ? "; showing the result from before" : ""), size: 12.5)
                            Button(showingEarlier ? "USE THE RERUN" : "PUT BACK THE EARLIER RESULT") { info = model.swapHistoryEarlier(entry.id) }
                                .buttonStyle(.plain).font(Ob.mono(11)).foregroundStyle(ob.accent)
                        }
                        .padding(.top, 4)
                    }
                }
                Spacer()
                Button("Read aloud") { model.reader.read(entry.inserted, voice: model.settings.ttsVoice, speed: model.settings.ttsBaseSpeed) }
                    .buttonStyle(.quiet)
                if entry.hasAudio {
                    Button(rerunning ? "Running…" : "Run again") { runAgain() }
                        .buttonStyle(.quiet).disabled(rerunning)
                        .help("Transcribe the recording again with today's speech settings, then clean it up again with its profile. The current result is kept, so it can be put back.")
                }
                Button("Delete") {
                    player.stop()
                    model.deleteHistory([entry.id])
                }
                .buttonStyle(.quiet)
            }
            if player.loaded {
                recording.padding(.top, 12)
            } else {
                Caption("No recording kept for this dictation.", size: 12.5).padding(.top, 10)
            }
            ThreeBoxes(transcription: entry.transcription, aiEdit: shownEdit ?? (safetyNet ? entry.transcription : nil), inserted: entry.inserted,
                       safetyNet: safetyNet && shownEdit == nil)
                .padding(.top, 16)
            if let note = entry.warning ?? (safetyNet ? "The safety net kept some of your original words." : nil) {
                Caption(note, size: 12.5).padding(.top, 6)
            }
            #if os(macOS)
            Button("Insert transcription into the last app") {
                Task { info = await model.insertIntoLastApp(entry.transcription).sentence }
            }
            .buttonStyle(.quiet)
            .padding(.top, 14)
            #endif
            if !info.isEmpty { Caption(info, size: 12.5).padding(.top, 8) }
        }
        .onAppear { player.load(entry.hasAudio ? entry.audioURL : nil) }
        .onDisappear { player.stop() }
    }

    /// The stored safety-net flag; entries from before it was kept fall back to what their text shows.
    private var safetyNet: Bool {
        entry.safetyNet ?? (entry.aiEdit != nil && entry.aiEdit == entry.transcription && entry.warning != nil)
    }

    /// The AI's own output; nil when no AI edit was used, or when the AI step gave back the words unchanged with a warning
    /// (a failure: nothing of the AI's went in).
    private var shownEdit: String? {
        entry.aiEdit == entry.transcription && entry.warning != nil ? nil : entry.aiEdit
    }

    /// The recording: play/pause, seek, "0:12 / 0:40", 2× (HistoryPage's Player card).
    private var recording: some View {
        HStack(spacing: 0) {
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ob.onInk)
                    .frame(width: 34, height: 28)
                    .background(Capsule().fill(ob.ink))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play or pause")
            Slider(value: Binding(get: { player.fraction }, set: { player.seek(to: $0) }), in: 0...1)
                .tint(ob.ink)
                .padding(.leading, 12)
                .accessibilityLabel("Position")
            Text("\(HistoryPlayer.clock(player.position)) / \(HistoryPlayer.clock(player.duration))")
                .font(Ob.mono(12)).monospacedDigit().padding(.leading, 10)
            Button("2×") { player.double.toggle() }
                .buttonStyle(CapsuleButtonStyle(kind: player.double ? .primary : .quiet, size: 11, compact: true))
                .help("Play at double speed")
                .padding(.leading, 10)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
    }

    private func runAgain() {
        rerunning = true
        let id = entry.id
        player.stop()
        Task {
            let message = await model.rerunHistory(id) { info = $0 }
            rerunning = false
            info = message
        }
    }
}

/// Plays a dictation's audio.wav. The player keeps the pitch at 2×, so speech stays understandable.
@MainActor
final class HistoryPlayer: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var double = false { didSet { player?.rate = double ? 2 : 1 } }
    private var player: AVAudioPlayer?
    private var tick: AnyCancellable?

    var loaded: Bool { player != nil }
    var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }

    func load(_ url: URL?) {
        stop()
        // Read into memory, so the entry's own file is never held open.
        guard let url, let data = try? Data(contentsOf: url), let p = try? AVAudioPlayer(data: data) else { player = nil; return }
        p.enableRate = true
        p.prepareToPlay()
        player = p
        duration = p.duration
        position = 0
    }

    func toggle() {
        guard let p = player else { return }
        if playing {
            p.pause()
            playing = false
            tick = nil
            return
        }
        #if os(iOS)
        if !LiveTranscriber.audioSessionHeld {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        #endif
        p.rate = double ? 2 : 1
        p.play()
        playing = true
        tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.update() }
    }

    func seek(to fraction: Double) {
        guard let p = player else { return }
        p.currentTime = fraction * p.duration
        position = p.currentTime
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        playing = false
        tick = nil
        position = 0
    }

    private func update() {
        guard let p = player else { return }
        if !p.isPlaying { stop(); return } // came to the end
        position = p.currentTime
    }

    /// "0:12".
    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return "\(t / 60):" + String(format: "%02d", t % 60)
    }
}

extension HistoryEntry {
    /// "14:32", "Yesterday 14:32" or "9 Oct, 14:32" (Dictation.Core/Session/History.cs).
    static func when(_ d: Date) -> String {
        let time = d.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(d) { return time }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday " + time }
        return d.formatted(.dateTime.day().month(.abbreviated)) + ", " + time
    }

    /// The list's text: what went in (or what was heard), on one line, at most 120 characters.
    var preview: String {
        let t = (inserted.isEmpty ? transcription : inserted).replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        return t.count <= 120 ? t : String(t.prefix(117)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func duration(_ s: Double) -> String {
        s < 60 ? "\(Int(s.rounded())) s" : String(format: "%d:%02d min", Int(s) / 60, Int(s) % 60)
    }
}
