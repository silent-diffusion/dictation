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
    /// Apps folded in the list by app, by lower-cased name (for as long as the page is open).
    @State private var folded: Set<String> = []
    /// RUN AGAIN is running (for the whole page, as on Windows), and the line under the dictation.
    @State private var rerunning = false
    @State private var info = ""
    /// Counts HistoryPage.Rebuild: each one shows the selected dictation afresh (its player stopped, the line cleared).
    @State private var rebuilds = 0
    @FocusState private var listFocused: Bool

    /// A row of the list: an app's header (by app), or a dictation.
    enum Row: Identifiable {
        case header(name: String, key: String, count: Int, open: Bool)
        case entry(HistoryEntry)

        var id: String {
            switch self {
            case .header(_, let key, _, _): "app:" + key
            case .entry(let e): e.id.uuidString
            }
        }
        var entry: HistoryEntry? { if case .entry(let e) = self { e } else { nil } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "History", japanese: "履歴", readout: "Dictations // on this \(Device.noun)")
            HStack(alignment: .center, spacing: 0) {
                Caption(countLine, bottom: 0)
                Spacer(minLength: 0)
                Readout("Show").padding(.trailing, 8)
                ObMenu(options: [(false, "Newest first"), (true, "By app, newest first")], selection: $model.settings.historyByApp, width: 230)
                    .accessibilityLabel("Order")
            }
            .padding(.top, 14).padding(.bottom, 14)
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
        .padding(sizeClass == .compact ? EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16) : EdgeInsets(top: 28, leading: 32, bottom: 24, trailing: 32))
        .onAppear { keepSelection() }
        // HistoryPage.Rebuild(Current): a new or deleted dictation, a fold, or another order keeps the dictation shown
        // if it is still in the list, else shows the first one, and shows it afresh.
        .onChange(of: model.history.map(\.id)) { rebuild() }
        .onChange(of: model.settings.historyByApp) { rebuild() }
        .onChange(of: folded) { rebuild() }
        .onChange(of: selected?.id) { info = "" }
    }

    /// The dictation on the right: the one picked, while the list shows it; else the list's first (on a phone, only one
    /// picked).
    private var selected: HistoryEntry? {
        if sizeClass == .compact { return model.history.first { $0.id == nav.place.historyID } }
        let shown = rows.compactMap(\.entry)
        return shown.first { $0.id == nav.place.historyID } ?? shown.first
    }

    /// Hold on to the dictation shown, so a new one coming in doesn't replace it (Windows keeps the list's selection).
    private func keepSelection() {
        guard sizeClass != .compact, let id = selected?.id, id != nav.place.historyID else { return }
        nav.goHistory(id)
    }

    private func rebuild() {
        keepSelection()
        rebuilds += 1
        info = ""
    }

    private func detail(_ entry: HistoryEntry) -> some View {
        HistoryDetail(entry: entry, rerunning: rerunning, info: $info, runAgain: { runAgain(entry.id) },
                      swap: {
                          let message = model.swapHistoryEarlier(entry.id)
                          rebuild()
                          info = message
                      })
            .id("\(entry.id)/\(rebuilds)")
    }

    /// RUN AGAIN: its progress shows only while the same dictation is on screen; at the end the list goes back to it
    /// (if it is still shown) and says how it went.
    private func runAgain(_ id: UUID) {
        guard !rerunning else { return }
        rerunning = true
        Task {
            let message = await model.rerunHistory(id) { m in if selected?.id == id { info = m } }
            rerunning = false
            if sizeClass != .compact, rows.contains(where: { $0.entry?.id == id }) { nav.goHistory(id) }
            rebuild()
            info = message
        }
    }

    /// The line under the title (HistoryPage.UpdateCount).
    private var countLine: String {
        let s = model.settings, n = model.history.count
        return !s.keepHistory ? "History is off (Settings › History). Earlier dictations stay until you clear them."
            : s.historyLimit > 0 ? "\(n) of the last \(s.historyLimit) dictations, kept on this \(Device.noun) (they survive updates). Change how many under Settings › History."
            : s.historyDays > 0 ? "\(n) dictations from the last \(HistoryStore.daysLabel(s.historyDays)), kept on this \(Device.noun) (they survive updates). Change how long under Settings › History."
            : "\(n) dictations, all kept on this \(Device.noun) (they survive updates). Change this under Settings › History."
    }

    /// What the list shows (HistoryPage.Rebuild): the dictations newest first, or by app, each app's header a row of
    /// its own. Apps are told apart ignoring case and come in the order of their newest dictation.
    private var rows: [Row] {
        guard model.settings.historyByApp else { return model.history.map(Row.entry) }
        var order: [String] = []
        var byApp: [String: [HistoryEntry]] = [:]
        for e in model.history {
            let key = e.appLabel.lowercased()
            if byApp[key] == nil { order.append(key) }
            byApp[key, default: []].append(e)
        }
        var rows: [Row] = []
        for key in order {
            let entries = byApp[key] ?? []
            let open = !folded.contains(key)
            rows.append(.header(name: entries[0].appLabel, key: key, count: entries.count, open: open))
            if open { rows += entries.map(Row.entry) }
        }
        return rows
    }

    private var list: some View {
        let rows = rows
        return ScrollViewReader { proxy in
            PageScroll {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { r in
                        switch r {
                        case .header(let name, let key, let count, let open): header(name, key: key, count: count, open: open)
                        case .entry(let e): row(e)
                        }
                    }
                }
                .padding(6)
            }
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if model.history.isEmpty {
                    Caption("Nothing here yet. Your dictations appear here, with their recordings.").padding(16)
                }
            }
            .focusable(sizeClass != .compact && !model.history.isEmpty)
            .focused($listFocused)
            .accessibilityLabel("Dictations")
            .onKeyPress(keys: [.upArrow, .downArrow, .home, .end, .pageUp, .pageDown]) { press in
                guard let target = HistoryKeys.target(rows.map { $0.entry != nil }, from: rows.firstIndex { $0.entry?.id == selected?.id },
                                                      key: press.key) else { return .ignored }
                if let e = rows[target].entry, e.id != selected?.id {
                    nav.goHistory(e.id)
                    proxy.scrollTo(rows[target].id)
                }
                return .handled
            }
        }
    }

    /// An app's header (by app): its name, how many, + or − to fold it (HistoryPage's HistoryAppHeader).
    private func header(_ name: String, key: String, count: Int, open: Bool) -> some View {
        Button {
            if folded.contains(key) { folded.remove(key) } else { folded.insert(key) }
        } label: {
            HStack(spacing: 0) {
                Text(name).font(Ob.sans(12, .bold)).foregroundStyle(ob.ink).lineLimit(1)
                Readout("\(count)").padding(.leading, 10)
                Spacer(minLength: 0)
                Text(open ? "−" : "+").font(Ob.mono(12)).foregroundStyle(ob.muted)
            }
            .padding(EdgeInsets(top: 9, leading: 12, bottom: 7, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ob.subtle) // Windows' hover wash (Ob.Hover) is the same colour as Ob.Subtle
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .accessibilityLabel(name)
    }

    private func row(_ e: HistoryEntry) -> some View {
        HistoryRow(entry: e, selected: sizeClass != .compact && selected?.id == e.id) {
            nav.goHistory(e.id)
            if sizeClass != .compact { listFocused = true }
        }
    }
}

/// The arrow keys in History's list (a WPF ListBox): up and down a row, Home and End, a page at a time; landing on an
/// app's header goes on to the next dictation the way the arrow was going, or back the other way at the end
/// (HistoryPage.List_SelectionChanged).
enum HistoryKeys {
    static let page = 10

    /// The row to select, or nil when the key does nothing. `isEntry` says which rows are dictations; `from` is the
    /// selected row.
    static func target(_ isEntry: [Bool], from: Int?, key: KeyEquivalent) -> Int? {
        guard isEntry.contains(true) else { return nil }
        let last = isEntry.count - 1
        let at: Int
        switch key {
        case .upArrow: at = from.map { max(0, $0 - 1) } ?? 0
        case .downArrow: at = from.map { min(last, $0 + 1) } ?? 0
        case .pageUp: at = from.map { max(0, $0 - page) } ?? 0
        case .pageDown: at = from.map { min(last, $0 + page) } ?? 0
        case .home: at = 0
        case .end: at = last
        default: return nil
        }
        if isEntry[at] { return at }
        let step = (from ?? -1) > at ? -1 : 1
        var i = at
        while i >= 0, i <= last, !isEntry[i] { i += step }
        if i < 0 || i > last {
            i = at
            while i >= 0, i <= last, !isEntry[i] { i -= step }
        }
        return i >= 0 && i <= last ? i : from
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
            // RowItem's Padding 12,8 plus the template's Margin 2,5.
            VStack(alignment: .leading, spacing: 3) {
                // MonoLabel keeps the case it is given ("Mail", "40 s"): WPF doesn't change case.
                HStack(spacing: 0) {
                    Text(HistoryEntry.when(entry.date) + "  ·  " + entry.appLabel).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(HistoryEntry.duration(entry.seconds)).fixedSize()
                }
                .font(Ob.mono(10.5)).foregroundStyle(ob.muted)
                Text(entry.preview)
                    .font(Ob.sans(Ob.body)).foregroundStyle(ob.ink).lineLimit(2).truncationMode(.tail).multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected || hover ? ob.subtle : .clear)
            .overlay(alignment: .leading) { if selected { Rectangle().fill(ob.ink).frame(width: 3) } }
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { hover = $0 }
    }
}

/// One dictation in full: where it went, its recording, the three boxes, RUN AGAIN (HistoryPage.ShowDetailNow).
struct HistoryDetail: View {
    var entry: HistoryEntry
    var rerunning: Bool
    @Binding var info: String
    var runAgain: () -> Void
    var swap: () -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @StateObject private var player = HistoryPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(DateText.weekdayDayMonth(entry.date) + ", " + DateText.time(entry.date))
                        .font(Ob.mono(16, .bold)).foregroundStyle(ob.ink)
                    Caption(where_ + "\nProfile: \(entry.profileName) · \(HistoryEntry.duration(entry.seconds)) of speech", bottom: 0)
                        .padding(.top, 2)
                    if let at = entry.runAgainAt, entry.earlier != nil {
                        let showingEarlier = entry.showingEarlier ?? false
                        FlowRow(spacing: 0, lineSpacing: 0) {
                            Caption("Run again \(DateText.dayMonth(at)), \(DateText.time(at))"
                                    + (showingEarlier ? "; showing the result from before" : ""), bottom: 0)
                                .padding(.trailing, 10)
                            Button(showingEarlier ? "USE THE RERUN" : "PUT BACK THE EARLIER RESULT") { swap() }
                                .buttonStyle(.plain).font(Ob.mono(11)).foregroundStyle(ob.accent).handCursor()
                        }
                        .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
                if entry.hasAudio {
                    Button(rerunning ? "Running…" : "Run again") { runAgain() }
                        .buttonStyle(.quiet).disabled(rerunning)
                        .help("Transcribe the recording again with today's speech settings, then clean it up again with its profile. The current result is kept, so it can be put back.")
                        .padding(.trailing, 8)
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
                Caption("No recording kept for this dictation.", bottom: 0).padding(.top, 10)
            }
            ThreeBoxes(transcription: entry.transcription, aiEdit: shownEdit, inserted: entry.inserted, safetyNet: safetyNet,
                       transcriptionLit: player.lit.first ?? nil, insertedLit: player.lit.dropFirst().first ?? nil)
                .padding(.top, 16)
            // An empty note still takes its line, as Windows' empty TextBlock does.
            Caption(entry.warning ?? (safetyNet ? "The safety net kept some of your original words." : " "), bottom: 0).padding(.top, 6)
            #if os(macOS)
            Button("Insert transcription into the last app") {
                Task { info = await model.insertIntoLastApp(entry.transcription).sentence }
            }
            .buttonStyle(.quiet)
            .padding(.top, 14).padding(.bottom, 8)
            #endif
            if !info.isEmpty { Caption(info) }
        }
        .onAppear {
            player.load(entry.hasAudio ? entry.audioURL : nil)
            player.setWords(entry.spokenWords, texts: [entry.transcription, entry.inserted])
        }
        // Run again (or putting the earlier result back) changes the texts: the words are lined up with them again.
        .onChange(of: entry.transcription + "\u{0}" + entry.inserted) { player.setWords(entry.spokenWords, texts: [entry.transcription, entry.inserted]) }
        .onChange(of: rerunning) { if rerunning { player.stop() } }
        .onDisappear { player.stop() }
    }

    /// "Inserted into Mail" or "Not inserted (meant for Mail)". Lane J: Windows adds " · {window title}" here (direct
    /// build only, from AXReader.windowTitle once History keeps it).
    private var where_: String {
        entry.didInsert ? "Inserted into \(entry.appLabel)" : "Not inserted (meant for \(entry.appLabel))"
    }

    private var safetyNet: Bool { entry.isSafetyNet }
    private var shownEdit: String? { entry.aiOutput }

    /// The recording: play/pause, seek, "0:12 / 0:40", 2× (HistoryPage's Player card, Padding 10,8).
    private var recording: some View {
        HStack(spacing: 0) {
            // A PrimaryButton 34 wide: a 34×34 ink circle with the play or pause glyph.
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 12))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(CapsuleButtonStyle(kind: .primary, padding: 0))
            .accessibilityLabel("Play or pause")
            Slider(value: Binding(get: { player.fraction }, set: { player.seek(to: $0) }), in: 0...1)
                .tint(ob.ink)
                .padding(.leading, 12)
                .accessibilityLabel("Position")
            Text("\(HistoryPlayer.clock(player.position)) / \(HistoryPlayer.clock(player.duration))")
                .font(Ob.mono(12)).monospacedDigit().foregroundStyle(ob.ink).padding(.leading, 10)
            SpeedToggle(on: $player.double)
                .padding(.leading, 10)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
    }
}

/// The player's "2×": a WPF ToggleButton in the Windows 11 look (Padding 10,4, corner radius 4), its fill ink while on.
struct SpeedToggle: View {
    @Binding var on: Bool
    @Environment(\.ob) private var ob
    @State private var hover = false

    var body: some View {
        Button { on.toggle() } label: {
            Text("2×").font(Ob.sans(Ob.body))
                .foregroundStyle(on ? ob.onInk : ob.ink)
                .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(on ? ob.ink.opacity(hover ? 0.9 : 1) : Color.white.opacity(ob.dark ? (hover ? 0.08 : 0.06) : (hover ? 0.5 : 0.7)))
                }
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? .clear : (ob.dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Play at double speed")
        .accessibilityLabel("Double speed")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Plays a dictation's audio.wav. The player keeps the pitch at 2×, so speech stays understandable.
@MainActor
final class HistoryPlayer: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var double = false { didSet { player?.rate = double ? 2 : 1 } }
    /// The word being said, in each text given to `setWords` (nil where none is); empty while not playing.
    @Published private(set) var lit: [NSRange?] = []
    private var player: AVAudioPlayer?
    private var tick: AnyCancellable?
    private var wordTick: AnyCancellable?
    private var spans: [[TimedSpan]] = []

    /// The recording's words and the texts to light them in (lined up once here: a dictation is short).
    func setWords(_ words: [SpokenWord], texts: [String]) {
        spans = words.isEmpty ? [] : texts.map { WordTimes.align($0, words) }
        lit = []
    }

    private func updateLit() {
        guard playing, let p = player, !spans.isEmpty else { if !lit.isEmpty { lit = [] }; return }
        let now = spans.map { WordTimes.current($0, at: p.currentTime)?.range }
        if now != lit { lit = now }
    }

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
            wordTick = nil
            lit = []
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
        if !spans.isEmpty {
            wordTick = Timer.publish(every: PlaybackFollow.tick, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.updateLit() }
        }
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
        wordTick = nil
        lit = []
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
    /// "14:32", "Yesterday 14:32" or "3 Nov, 14:32" (HistoryEntry.When), day before month as on Windows.
    static func when(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return DateText.time(d) }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday " + DateText.time(d) }
        return DateText.dayMonthTime(d)
    }

    /// The list's text: what went in (or what was heard), on one line, at most 120 characters (HistoryEntry.Preview:
    /// .NET's ReplaceLineEndings, UTF-16 lengths, the cut trimmed at its end).
    var preview: String {
        var t = inserted.isEmpty ? transcription : inserted
        t = t.replacingOccurrences(of: "\r\n", with: " ")
        for c in ["\r", "\n", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] { t = t.replacingOccurrences(of: c, with: " ") }
        let utf16 = t as NSString
        if utf16.length <= 120 { return t }
        var cut = utf16.substring(to: 117)
        while let last = cut.unicodeScalars.last, last.properties.isWhitespace { cut.unicodeScalars.removeLast() }
        return cut + "…"
    }

    static func duration(_ s: Double) -> String {
        s < 60 ? "\(Int(s.rounded())) s" : String(format: "%d:%02d min", Int(s) / 60, Int(s) % 60)
    }
}

#if DEBUG && os(macOS)
/// History's three boxes mid-playback (the word being said lit), drawn to PNGs with the page snapshots.
@MainActor
enum HistoryPlaybackSnapshots {
    static func write(to dir: String, model: AppModel) {
        let said = "okay so um can you send the release notes to the team before friday"
        let inserted = "Can you send the release notes to the team before Friday?"
        let words = WordTimes.spread(said, start: 0, end: 4.2)
        let at = 2.6 // "notes"
        let lit = [said, inserted].map { WordTimes.current(WordTimes.align($0, words), at: at)?.range }
        for dark in [false, true] {
            var s = model.settings
            s.theme = dark ? .dark : .light
            let view = ThreeBoxes(transcription: said, aiEdit: inserted, inserted: inserted, transcriptionLit: lit[0], insertedLit: lit[1])
                .padding(20).frame(width: 900).background(Palette(dark: dark, accentChoice: s.accent).paper).obertonTheme(s)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "history-playback-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
#endif
