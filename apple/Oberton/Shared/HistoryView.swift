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
    /// RUN AGAIN is running (for the whole page, as on Windows).
    @State private var rerunning = false
    /// The line under the dictation (Info), and which dictation it was said for: showing another one clears it.
    @State private var info = HistoryInfo()
    /// Counts HistoryPage.Rebuild: each one shows the selected dictation afresh (its player stopped, the line cleared).
    @State private var rebuilds = 0
    /// The player's 2×: Windows' toggle stays set for as long as the page is open, from one dictation to the next.
    @State private var double = false
    /// The row with the keyboard focus, when it isn't the selected one: ⌘↑/⌘↓ (Windows' Ctrl+arrow) move it without
    /// selecting, Space selects it. A WPF RowItem marks it with a 3 px accent bar.
    @State private var cursor: String?
    /// A row to bring into view (ListBox.ScrollIntoView), bumped on every rebuild and key.
    @State private var scrollRequest = ScrollRequest()
    /// Where the rows sit in the list's viewport, for PageUp/PageDown (kept outside SwiftUI's state: scrolling doesn't
    /// redraw the page).
    @State private var geometry = ListGeometry()
    /// When the page was opened, for Windows' "History page: built in N ms" (logged when slow).
    @State private var opened = ContinuousClock.now
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

    struct HistoryInfo: Equatable {
        var id: UUID?
        var text = ""
    }

    struct ScrollRequest: Equatable {
        var ids: [String] = []
        var tick = 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "History", japanese: "履歴", readout: "Dictations // on this \(Device.noun)")
            // A DockPanel row: the count caption at the top of the row, SHOW and the combo centred in it.
            HStack(alignment: .center, spacing: 0) {
                Caption(countLine, bottom: 0).frame(maxHeight: .infinity, alignment: .top)
                Spacer(minLength: 0)
                Readout("Show").padding(.trailing, 8)
                ObMenu(options: [(false, "Newest first"), (true, "By app, newest first")], selection: $model.settings.historyByApp, width: 230)
                    .accessibilityLabel("Order")
            }
            .fixedSize(horizontal: false, vertical: true)
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
        .onAppear {
            keepSelection()
            scrollToSelection()
            let ms = Self.milliseconds(since: opened)
            if ms >= 100 { Log.info("History page: built in \(ms) ms (\(model.history.count) dictations)") }
        }
        // HistoryPage.Rebuild(Current): a new or deleted dictation, a fold, or another order keeps the dictation shown
        // if it is still in the list, else shows the first one, and shows it afresh.
        .onChange(of: model.history.map(\.id)) { rebuild() }
        .onChange(of: model.settings.historyByApp) { rebuild() }
        .onChange(of: folded) { rebuild() }
        .onChange(of: selected?.id) { if info.id != selected?.id { info = HistoryInfo() } }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
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
        info = HistoryInfo()
        cursor = nil // the list's rows are new; the focus goes back to the selection
        scrollToSelection()
    }

    /// `List.ScrollIntoView(select)`: the least scrolling that shows the selected dictation.
    private func scrollToSelection() {
        guard sizeClass != .compact, let id = selected?.id else { return }
        scroll([id.uuidString])
    }

    private func scroll(_ ids: [String]) {
        scrollRequest = ScrollRequest(ids: ids, tick: scrollRequest.tick + 1)
    }

    private func detail(_ entry: HistoryEntry) -> some View {
        HistoryDetail(entry: entry, rerunning: rerunning,
                      info: Binding(get: { info.id == entry.id ? info.text : "" }, set: { info = HistoryInfo(id: entry.id, text: $0) }),
                      double: $double, runAgain: { runAgain(entry.id) },
                      swap: {
                          let message = model.swapHistoryEarlier(entry.id)
                          rebuild()
                          info = HistoryInfo(id: entry.id, text: message)
                      })
            .id("\(entry.id)/\(rebuilds)")
    }

    /// RUN AGAIN: its progress shows only while the same dictation is on screen. At the end the list goes back to it if
    /// it still shows it, else to its first dictation (Rebuild(c)), and the line under that one says how it went.
    private func runAgain(_ id: UUID) {
        guard !rerunning else { return }
        rerunning = true
        Task {
            let message = await model.rerunHistory(id) { m in if selected?.id == id { info = HistoryInfo(id: id, text: m) } }
            rerunning = false
            var target = id
            if sizeClass != .compact {
                let shown = rows.compactMap(\.entry)
                target = shown.contains { $0.id == id } ? id : shown.first?.id ?? id
                if target != nav.place.historyID, shown.contains(where: { $0.id == target }) { nav.goHistory(target) }
            }
            rebuild()
            info = HistoryInfo(id: target, text: message)
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
        // The card's Padding 6 sits outside the list: its rows and scroll bar stay 6 inside the hairline.
        return ScrollViewReader { proxy in
            PageScroll {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { r in
                        Group {
                            switch r {
                            case .header(let name, let key, let count, let open): header(name, key: key, count: count, open: open)
                            case .entry(let e): row(e)
                            }
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ListGeometry.space)) } action: { geometry.update(r.id, $0) }
                        .onDisappear { geometry.update(r.id, nil) }
                    }
                }
            }
            .coordinateSpace(.named(ListGeometry.space))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { geometry.viewport = $0 }
            .padding(6)
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if model.history.isEmpty {
                    Caption("Nothing here yet. Your dictations appear here, with their recordings.").padding(16)
                }
            }
            .focusable(sizeClass != .compact && !model.history.isEmpty)
            .focused($listFocused)
            .focusEffectDisabled()
            .accessibilityLabel("Dictations")
            .onKeyPress(keys: [.upArrow, .downArrow, .home, .end, .pageUp, .pageDown, .space]) { press in key(press, rows) }
            .onChange(of: scrollRequest) {
                let ids = scrollRequest.ids
                DispatchQueue.main.async { for id in ids { proxy.scrollTo(id) } }
            }
        }
    }

    /// The list's keys, as a WPF ListBox has them: the arrows, Home/End and PageUp/PageDown select (a page is what the
    /// list shows); ⌘ (Windows' Ctrl) with them moves only the keyboard focus, and Space selects the focused row. A
    /// selection landing on an app's header goes on to the next dictation (HistoryPage.List_SelectionChanged). Each
    /// step brings the row it lands on into view, then the dictation selected.
    private func key(_ press: KeyPress, _ rows: [Row]) -> KeyPress.Result {
        let isEntry = rows.map { $0.entry != nil }
        guard isEntry.contains(true) else { return .ignored }
        let shown = rows.firstIndex { $0.entry?.id == selected?.id }
        let focus = cursor.flatMap { c in rows.firstIndex { $0.id == c } } ?? shown
        let at: Int
        if press.key == .space {
            guard let focus else { return .ignored }
            at = focus
        } else {
            let page = press.key == .pageUp || press.key == .pageDown
                ? geometry.pageTarget(rows.map(\.id), from: focus ?? 0, down: press.key == .pageDown) : nil
            guard let to = HistoryKeys.step(rows.count, from: focus, key: press.key, page: page) else { return .ignored }
            at = to
        }
        if press.key != .space, press.modifiers.contains(.command) || press.modifiers.contains(.control) {
            cursor = rows[at].id
            scroll([rows[at].id])
            return .handled
        }
        guard let target = HistoryKeys.settle(isEntry, at: at, shown: shown) else { return .handled }
        cursor = nil
        if let e = rows[target].entry, e.id != selected?.id { nav.goHistory(e.id) }
        scroll([rows[at].id, rows[target].id])
        return .handled
    }

    /// An app's header (by app): its name, how many, + or − to fold it (HistoryPage's HistoryAppHeader). A name too
    /// long for the row is cut off hard and takes the count with it, as Windows' StackPanel does.
    private func header(_ name: String, key: String, count: Int, open: Bool) -> some View {
        Button {
            if folded.contains(key) { folded.remove(key) } else { folded.insert(key) }
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(name).font(Ob.sans(12, .bold)).foregroundStyle(ob.ink).fixedSize()
                    Readout("\(count)").fixedSize().padding(.leading, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                Text(open ? "−" : "+").font(Ob.mono(12)).foregroundStyle(ob.muted)
            }
            .padding(EdgeInsets(top: 9, leading: 12, bottom: 7, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // The row's focus mark shows through the header's wash (Ob.Hover is the same colour as Ob.Subtle).
                ZStack(alignment: .leading) {
                    if listFocused && cursor == "app:" + key { Rectangle().fill(ob.accent).frame(width: 3) }
                    Rectangle().fill(ob.subtle)
                }
            }
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(BareButtonStyle())
        .handCursor()
        .accessibilityLabel(name)
    }

    private func row(_ e: HistoryEntry) -> some View {
        let isSelected = sizeClass != .compact && selected?.id == e.id
        return HistoryRow(entry: e, selected: isSelected, focused: listFocused && cursor == e.id.uuidString && !isSelected) {
            nav.goHistory(e.id)
            cursor = nil
            if sizeClass != .compact { listFocused = true }
        }
    }
}

/// A button with no look of its own and no pressed state (WPF's bare `<ContentPresenter/>` template).
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// Where History's rows sit in the list's viewport (for paging), updated as it scrolls. A plain reference, so scrolling
/// doesn't redraw the page.
final class ListGeometry {
    static let space = "historyList"
    /// The rows laid out now (a lazy list lays out only those near the view), in the viewport's coordinates.
    var frames: [String: CGRect] = [:]
    /// Every row's height seen so far, for rows not laid out now.
    var heights: [String: CGFloat] = [:]
    var viewport: CGFloat = 0

    func update(_ id: String, _ frame: CGRect?) {
        frames[id] = frame
        if let frame, frame.height > 0 { heights[id] = frame.height }
    }

    /// PageDown in a WPF ListBox: the last row wholly in view, or, when the focus is on it (or past it) already, the last
    /// row wholly in view one viewport further on; PageUp the same upwards. A row never seen counts as the average
    /// height of those that were. nil when nothing is known yet.
    func pageTarget(_ ids: [String], from: Int, down: Bool) -> Int? {
        guard viewport > 0, ids.indices.contains(from),
              let anchor = ids.indices.filter({ frames[ids[$0]] != nil }).min(by: { abs($0 - from) < abs($1 - from) }) else { return nil }
        let seen = heights.values
        let average = seen.isEmpty ? 60 : seen.reduce(0, +) / CGFloat(seen.count)
        let height = ids.map { heights[$0] ?? average }
        // Each row's top, counted from the laid-out row nearest the focus.
        var top = [CGFloat](repeating: 0, count: ids.count)
        top[anchor] = frames[ids[anchor]]!.minY
        if anchor + 1 < ids.count { for i in (anchor + 1)..<ids.count { top[i] = top[i - 1] + height[i - 1] } }
        if anchor > 0 { for i in stride(from: anchor - 1, through: 0, by: -1) { top[i] = top[i + 1] - height[i] } }
        func bottom(_ i: Int) -> CGFloat { top[i] + height[i] }
        if down {
            if let last = ids.indices.last(where: { top[$0] >= -0.5 && bottom($0) <= viewport + 0.5 }), last > from { return last }
            let limit = max(bottom(from), viewport) + viewport // the view one page further down
            return ids.indices.last { $0 > from && bottom($0) <= limit + 0.5 } ?? min(ids.count - 1, from + 1)
        } else {
            if let first = ids.indices.first(where: { top[$0] >= -0.5 && bottom($0) <= viewport + 0.5 }), first < from { return first }
            let limit = min(top[from], 0) - viewport
            return ids.indices.first { $0 < from && top[$0] >= limit - 0.5 } ?? max(0, from - 1)
        }
    }
}

/// The keys of History's list (a WPF ListBox).
enum HistoryKeys {
    /// The row a key moves to from `from` (the focused row): up and down one, Home and End, a page (`page`, worked out
    /// from what the list shows). nil when the key does nothing.
    static func step(_ count: Int, from: Int?, key: KeyEquivalent, page: Int?) -> Int? {
        guard count > 0 else { return nil }
        let last = count - 1
        switch key {
        case .upArrow: return from.map { max(0, $0 - 1) } ?? 0
        case .downArrow: return from.map { min(last, $0 + 1) } ?? 0
        case .pageUp: return page ?? from.map { max(0, $0 - 10) } ?? 0
        case .pageDown: return page ?? from.map { min(last, $0 + 10) } ?? 0
        case .home: return 0
        case .end: return last
        default: return nil
        }
    }

    /// The dictation to select when the selection lands on row `at`: itself, or, on an app's header, the next dictation
    /// the way the move was going (from `shown`, the dictation shown), or back the other way at the end
    /// (HistoryPage.List_SelectionChanged). nil when there is none.
    static func settle(_ isEntry: [Bool], at: Int, shown: Int?) -> Int? {
        guard isEntry.indices.contains(at) else { return shown }
        if isEntry[at] { return at }
        let last = isEntry.count - 1
        let step = (shown ?? -1) > at ? -1 : 1
        var i = at
        while i >= 0, i <= last, !isEntry[i] { i += step }
        if i < 0 || i > last {
            i = at
            while i >= 0, i <= last, !isEntry[i] { i -= step }
        }
        return i >= 0 && i <= last ? i : shown
    }
}

struct HistoryRow: View {
    var entry: HistoryEntry
    var selected: Bool
    /// The keyboard focus is on this row but it isn't selected: RowItem's accent mark.
    var focused = false
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
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(ob.ink).frame(width: 3) } else if focused { Rectangle().fill(ob.accent).frame(width: 3) }
            }
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(BareButtonStyle())
        .handCursor()
        .onHover { hover = $0 }
    }
}

/// WPF's WrapPanel: items side by side, each measured against the whole width (a long caption wraps inside it), the
/// next one on a new line when it doesn't fit; each centred in its line.
private struct WrapLine: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width, subviews)
        return CGSize(width: proposal.width ?? lines.map(\.width).max() ?? 0, height: lines.reduce(0) { $0 + $1.height })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for (i, size) in line.items {
                subviews[i].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width
            }
            y += line.height
        }
    }

    private func arrange(width: CGFloat?, _ subviews: Subviews) -> [(items: [(Int, CGSize)], width: CGFloat, height: CGFloat)] {
        var lines: [(items: [(Int, CGSize)], width: CGFloat, height: CGFloat)] = []
        var current: [(Int, CGSize)] = [], x: CGFloat = 0, h: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if !current.isEmpty, let width, x + s.width > width {
                lines.append((current, x, h))
                current = []; x = 0; h = 0
            }
            current.append((i, s)); x += s.width; h = max(h, s.height)
        }
        if !current.isEmpty { lines.append((current, x, h)) }
        return lines
    }
}

/// One dictation in full: where it went, its recording, the three boxes, RUN AGAIN (HistoryPage.ShowDetailNow).
struct HistoryDetail: View {
    var entry: HistoryEntry
    var rerunning: Bool
    @Binding var info: String
    @Binding var double: Bool
    var runAgain: () -> Void
    var swap: () -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @StateObject private var player = HistoryPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    // No wrapping and no "…": a title too long for the space beside the buttons is cut off.
                    Text(DateText.weekdayDayMonth(entry.date) + ", " + DateText.time(entry.date))
                        .font(Ob.mono(16, .bold)).foregroundStyle(ob.ink)
                        .lineLimit(1).fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading).clipped()
                    Caption(where_ + "\nProfile: \(entry.profileName) · \(HistoryEntry.duration(entry.seconds)) of speech", bottom: 0)
                        .padding(.top, 2)
                    if let at = entry.runAgainAt, entry.earlier != nil {
                        let showingEarlier = entry.showingEarlier ?? false
                        WrapLine {
                            Caption("Run again \(DateText.dayMonth(at)), \(DateText.time(at))"
                                    + (showingEarlier ? "; showing the result from before" : ""), bottom: 0)
                                .padding(.trailing, 10)
                            Button(showingEarlier ? "USE THE RERUN" : "PUT BACK THE EARLIER RESULT") { swap() }
                                .buttonStyle(BareButtonStyle()).font(Ob.mono(11)).foregroundStyle(ob.accent).handCursor()
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Docked at the right: they keep their size whatever the title needs.
                if entry.hasAudio {
                    Button(rerunning ? "Running…" : "Run again") { runAgain() }
                        .buttonStyle(.quiet).disabled(rerunning)
                        .help("Transcribe the recording again with today's speech settings, then clean it up again with its profile. The current result is kept, so it can be put back.")
                        .fixedSize()
                        .padding(.trailing, 8)
                }
                Button("Delete") {
                    player.stop()
                    model.deleteHistory([entry.id])
                }
                .buttonStyle(.quiet)
                .fixedSize()
            }
            if player.state == .none {
                Caption("No recording kept for this dictation.", bottom: 0).padding(.top, 10)
            } else {
                recording.padding(.top, 12)
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
            let clock = ContinuousClock.now
            player.double = double
            player.load(entry.hasAudio ? entry.audioURL : nil, seconds: entry.seconds)
            player.setWords(entry.spokenWords, texts: [entry.transcription, entry.inserted])
            let ms = HistoryView.milliseconds(since: clock)
            if ms >= 100 { Log.info("History page: showing a dictation took \(ms) ms") }
        }
        // Run again (or putting the earlier result back) changes the texts: the words are lined up with them again.
        .onChange(of: entry.transcription + "\u{0}" + entry.inserted) { player.setWords(entry.spokenWords, texts: [entry.transcription, entry.inserted]) }
        .onDisappear { player.stop() }
    }

    /// "Inserted into Mail · Inbox – Mail" or "Not inserted (meant for Mail)": the window title when one was kept (the
    /// direct build).
    private var where_: String {
        let s = entry.didInsert ? "Inserted into \(entry.appLabel)" : "Not inserted (meant for \(entry.appLabel))"
        guard let title = entry.windowTitle, !title.isEmpty else { return s }
        return s + " · " + title
    }

    private var safetyNet: Bool { entry.isSafetyNet }
    private var shownEdit: String? { entry.aiOutput }

    /// The recording: play/pause, seek, "0:12 / 0:40", 2× (HistoryPage's Player card, Padding 10,8).
    private var recording: some View {
        HStack(spacing: 0) {
            // A PrimaryButton 34 wide: a 34×34 ink circle with Segoe Fluent's Play or Pause, line glyphs.
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause" : "play").font(.system(size: 12))
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
            SpeedToggle(on: Binding(get: { double }, set: { double = $0; player.double = $0 }))
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
        .keyTabStop { on.toggle() }
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

    /// No recording (or one that couldn't be opened); one that plays; or one that opened but won't play (Windows'
    /// MediaPlayer fails on it silently: the card stays, showing the dictation's length, and does nothing).
    enum State { case none, ready, broken }
    @Published private(set) var state = State.none

    var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }

    /// `seconds`: the dictation's length, shown when the file won't play.
    func load(_ url: URL?, seconds: Double = 0) {
        stop()
        player = nil
        state = .none
        guard let url else { return }
        // Read into memory, so the entry's own file is never held open.
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            Log.warn("Couldn't open a recording: " + error.localizedDescription)
            return
        }
        guard let p = try? AVAudioPlayer(data: data) else {
            state = .broken
            duration = seconds
            position = 0
            return
        }
        p.enableRate = true
        p.prepareToPlay()
        player = p
        state = .ready
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
