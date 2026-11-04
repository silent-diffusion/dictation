import ObertonCore
import SwiftUI

/// Analytics: how dictation goes over a period (7, 30 or 90 days, or everything), as AnalyticsPage.xaml(.cs) draws it.
/// Readouts and charts come from the daily counts (usage.json); words, phrases, corrections, fillers and profiles from
/// the word tally (words.json), which keeps counts only. Drawn like the dashboard: cells sharing hairline edges, ink
/// with one accent. On iPhone the cells stack.
struct AnalyticsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var period: Int? = 30
    /// The app whose words are shown (its key in the word tally), or nil for every app; the page always opens on every
    /// app.
    @State private var app: String?
    /// The app's name as the row showed it, for "IN MAIL" and the empty text.
    @State private var appLabel = ""

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        let now = Date()
        let usage = model.usage.inPeriod(period, until: now)
        let from = period.map { Calendar.current.date(byAdding: .day, value: 1 - $0, to: now)! }
        let tally = model.words.days(from: from)
        let shown = app.map { WordTally.forApp(tally, $0) } ?? tally
        let on = model.settings.keepWordTally

        PageScroll {
            VStack(alignment: .leading, spacing: 0) {
                header
                readouts(usage, now: now)
                panel(top: 18) { AppsCell(usage: usage, selected: $app, label: $appLabel) }
                row([1, 1, 1]) {
                    CorrectionsCell(tally: shown, on: on, scope: scope("Heard → written"), hint: hint)
                    TopWordsCell(tally: shown, on: on, scope: scope("Common words left out"), hint: hint)
                    PhrasesCell(tally: shown, before: before(now: now), on: on, period: period, scope: scope("3 to 4 words"), hint: hint)
                }
                row([1.4, 1]) {
                    WordsPerDayCell(usage: usage, period: period, now: now).frame(height: 230)
                    HeatmapCell(grid: WordTally.weekHours(shown), on: on, scope: scope("Weekday × hour"), hint: hint)
                        .frame(height: 230)
                }
                panel(top: 18) { ProfilesCell(tally: tally, on: on) }
                notes(from: from, now: now)
            }
            .padding(compact ? EdgeInsets(top: 16, leading: 16, bottom: 24, trailing: 16) : EdgeInsets(top: 20, leading: 28, bottom: 24, trailing: 28))
        }
    }

    // MARK: Header

    /// "ANALYTICS 分析" at 30 with the periods at the right, an ink rule, then the summary and the tally note
    /// (AnalyticsPage.xaml).
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title at the top of the row, the decor and the periods at its bottom (HeaderRow, as Decor.cs).
            HeaderRow(decorGap: 12, decorBottom: 1, trailingGap: 16, trailingBottom: 2) {
                Text("ANALYTICS").font(Ob.mono(compact ? 26 : 30, .bold)).noWrap()
                    .layoutValue(key: HeaderRow.RoleKey.self, value: .title)
                Decor("分析", size: compact ? 22 : 26, color: ob.divider, weight: .bold).noWrap()
                    .layoutValue(key: HeaderRow.RoleKey.self, value: .decor)
                if !compact { periods.fixedSize().layoutValue(key: HeaderRow.RoleKey.self, value: .trailing) }
            }
            Rule().padding(.top, 6).padding(.bottom, 6)
            let summary = (period.map { "Last \($0) days" } ?? "Everything so far") + ": how you dictate, what gets corrected, and the words you reach for."
            let note = model.settings.keepWordTally ? "Word tally // on // counts only, never sentences" : "Word tally // off // turn it on under Settings › History"
            if compact {
                periods.padding(.top, 4)
                Text(summary).font(Ob.sans(12.5)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                Readout(note, size: 9.5).padding(.top, 4).padding(.bottom, 14)
            } else {
                HStack(spacing: 0) {
                    Text(summary).font(Ob.sans(12.5)).foregroundStyle(ob.muted).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 16)
                    Readout(note).lineLimit(1).fixedSize()
                }
                .padding(.bottom, 14)
            }
        }
    }

    /// 7D 30D 90D ALL: full capsules at least 52 wide, the period shown filled (BuildPeriods).
    private var periods: some View {
        HStack(spacing: 4) {
            ForEach([(7, "7D"), (30, "30D"), (90, "90D"), (0, "All")], id: \.0) { days, label in
                let value: Int? = days == 0 ? nil : days
                let tip = value.map { "The last \($0) days" } ?? "Everything so far"
                Button { period = value } label: { Text(label).frame(minWidth: 52 - 32) }
                    .buttonStyle(CapsuleButtonStyle(kind: value == period ? .primary : .quiet))
                    .help(tip)
                    .accessibilityLabel(tip)
                    .accessibilityAddTraits(value == period ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Period")
    }

    // MARK: 01 Readouts

    private func readouts(_ usage: [(key: String, day: UsageDay)], now: Date) -> some View {
        let d = usage.map(\.day)
        let words = d.reduce(0) { $0 + $1.words }, dictations = d.reduce(0) { $0 + $1.dictations }
        let seconds = d.reduce(0) { $0 + $1.secondsSpoken }
        let turnN = d.reduce(0) { $0 + $1.turnaroundCount }, turn = d.reduce(0) { $0 + $1.turnaroundSeconds }
        let edits = d.reduce(0) { $0 + $1.aiEdits }, kept = d.reduce(0) { $0 + $1.aiKept }
        let pace: Double? = seconds >= 30 ? Double(words) / (seconds / 60) : nil

        var paceSub = "words per minute while talking"
        if let pace, let n = period {
            let before = model.usage.inPeriod(n, until: Calendar.current.date(byAdding: .day, value: -n, to: now)!).map(\.day)
            let bs = before.reduce(0) { $0 + $1.secondsSpoken }
            if bs >= 30 {
                let delta = pace - Double(before.reduce(0) { $0 + $1.words }) / (bs / 60)
                paceSub = "\(delta >= 0 ? "+" : "−")\(Int(abs(delta).rounded())) vs the \(n) days before"
            }
        }

        // How long the voice actually spoke (at the speed of each reading); Windows counts it from 5.10.0 on.
        let readSeconds = d.reduce(0) { $0 + $1.secondsRead }
        let wordsRead = d.reduce(0) { $0 + $1.wordsRead }, readings = d.reduce(0) { $0 + $1.readings }
        let timedWords = d.filter { $0.secondsRead > 0 }.reduce(0) { $0 + $1.wordsRead }
        let readSub = readSeconds >= 30 ? "real listening time · \(Int((Double(timedWords) / (readSeconds / 60)).rounded())) wpm"
            : readSeconds > 0 ? "real listening time" : "counted from 5.10.0 on"

        let wpm = Double(max(1, model.settings.typingWPM))
        let saved = max(0, Double(words) / wpm - (seconds + turn) / 60) // minutes
        let cells: [AnyView] = [
            AnyView(ReadoutCell(label: "Words dictated", value: words.formatted(), sub: "in \(dictations.formatted()) dictation\(dictations == 1 ? "" : "s")", accent: true)),
            AnyView(ReadoutCell(label: "Speaking pace", value: pace.map { "\(Int($0.rounded())) wpm" } ?? "—", sub: paceSub)),
            AnyView(ReadoutCell(label: "Time saved", value: words == 0 ? "—" : saved >= 60 ? NetNumber.fixed(saved / 60, digits: 1) + " h" : NetNumber.fixed(saved, digits: 0) + " min") {
                TypingSpeed(wpm: $model.settings.typingWPM)
            }),
            AnyView(ReadoutCell(label: "Turnaround", value: turnN > 0 ? NetNumber.fixed(turn / Double(turnN), digits: 1) + " s" : "—", sub: "stop → text in place")),
            AnyView(ReadoutCell(label: "AI edits kept", value: edits > 0 ? percent(Double(kept) / Double(edits)) : "—",
                                sub: edits > 0 ? "safety net rejected \(percent(Double(edits - kept) / Double(edits)))" : "no AI edits yet")),
            AnyView(ReadoutCell(label: "Read aloud", value: "\(wordsRead.formatted()) w",
                                sub: "in \(readings.formatted()) reading\(readings == 1 ? "" : "s")")),
            AnyView(ReadoutCell(label: "Time read aloud", value: readSeconds > 0 ? duration(readSeconds) : "—", sub: readSub)),
        ]
        return panel(top: 0) {
            if compact {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(0..<4, id: \.self) { r in
                        GridRow {
                            if 2 * r + 1 < cells.count { cells[2 * r]; cells[2 * r + 1] } else { cells[2 * r].gridCellColumns(2) }
                        }
                    }
                }
            } else {
                WeightedRow(columns: Array(repeating: .flex(1), count: cells.count)) { ForEach(0..<cells.count, id: \.self) { cells[$0] } }
            }
        }
    }

    // MARK: 09 to 11 Extended Notes

    @ViewBuilder private func notes(from: Date?, now: Date) -> some View {
        let store = model.notes.store
        let f = NotesFigures.compute(store.sessions, from: from.map { Calendar.current.startOfDay(for: $0) })
        let ai = store.usage.totals(now: now, days: period ?? 0)
        let longest = f.longest.first
        HStack(alignment: .lastTextBaseline) {
            Text("09 // EXTENDED NOTES").font(Ob.mono(13, .bold)).lineLimit(1)
            Spacer(minLength: 8)
            if !compact { Readout("Lectures and meetings // kept apart from dictation").lineLimit(1) }
        }
        .padding(.top, 26)
        let cells: [AnyView] = [
            AnyView(ReadoutCell(label: "Sessions", value: f.sessions.formatted(),
                                sub: f.sessions > 0 ? "\(duration(f.seconds / Double(f.sessions))) each on average" : "none in this period", accent: true)),
            AnyView(ReadoutCell(label: "Time recorded", value: f.seconds > 0 ? duration(f.seconds) : "—",
                                sub: longest.map { "longest \(duration($0.seconds))" } ?? "lectures, meetings, calls")),
            AnyView(ReadoutCell(label: "Words captured", value: f.wordsHeard.formatted(),
                                sub: f.wordsPerMinute.map { "\(Int($0.rounded())) a minute of recording" } ?? "heard by the speech model")),
            AnyView(ReadoutCell(label: "Your own notes", value: "\(f.wordsTyped.formatted()) w", sub: "typed in during sessions")),
            AnyView(ReadoutCell(label: "Markers", value: f.markers.formatted(),
                                sub: f.markers > 0 && f.seconds > 0 ? "one every \(duration(f.seconds / Double(f.markers)))" : "⚑ moments you marked")),
            AnyView(ReadoutCell(label: "Formatting kept", value: f.steps > 0 ? percent(Double(f.stepsKept) / Double(f.steps)) : "—",
                                sub: "\(ai.aiRequests.formatted()) AI step\(ai.aiRequests == 1 ? "" : "s"), formatting and summing up")),
        ]
        panel(top: 8) {
            if compact {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(0..<3, id: \.self) { r in GridRow { cells[2 * r]; cells[2 * r + 1] } }
                }
            } else {
                WeightedRow(columns: Array(repeating: .flex(1), count: cells.count)) { ForEach(0..<cells.count, id: \.self) { cells[$0] } }
            }
        }
        row([1.4, 1]) {
            LongestSessionsCell(figures: f)
            NotesSourcesCell(figures: f)
        }
    }

    // MARK: Pieces

    /// A section's right-hand label: its own, or which app it is showing.
    private func scope(_ own: String) -> String { app == nil ? own : "In " + appLabel }

    /// An empty section's text: its own, or why the app picked has nothing yet.
    private func hint(_ own: String) -> String {
        app == nil ? own
            : "Nothing counted for \(appLabel) in this period yet. Words are counted per app from 5.10.0 on, and from the dictations History still had then."
    }

    /// The word tally of the period before this one (for "down 12% on the 30 days before"), of the app picked.
    private func before(now: Date) -> [TallyDay]? {
        guard let n = period else { return nil }
        let cal = Calendar.current
        let start = UsageLog.key(cal.date(byAdding: .day, value: 1 - 2 * n, to: now)!), end = UsageLog.key(cal.date(byAdding: .day, value: 1 - n, to: now)!)
        let days = model.words.days.filter { $0.day >= start && $0.day < end }
        return app.map { WordTally.forApp(days, $0) } ?? days
    }

    /// The panel's top and left edges; each cell draws its right and bottom ones.
    private func panel<C: View>(top: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .overlay(alignment: .top) { Hairline() }
            .overlay(alignment: .leading) { Hairline(vertical: true) }
            .padding(.top, top)
    }

    /// A row of cells sharing hairline edges, with the given column widths; on iPhone they stack.
    @ViewBuilder private func row<C: View>(_ weights: [Double], @ViewBuilder _ content: () -> C) -> some View {
        if compact {
            panel(top: 18) { VStack(spacing: 0) { content() } }
        } else {
            panel(top: 18) { WeightedRow(columns: weights.map { .flex($0) }) { content() } }
        }
    }
}

// MARK: - Layout

/// Lays children side by side in columns of fixed widths and shares of the rest (WPF's star widths); every child gets
/// the row's height, the tallest child's, and sits vertically centered.
struct WeightedRow: Layout {
    enum Column { case fixed(CGFloat), flex(Double) }
    var columns: [Column]

    /// Each column's exact width (stars share what the fixed columns leave).
    private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
        let cols = (0..<count).map { $0 < columns.count ? columns[$0] : .flex(1) }
        var fixed: CGFloat = 0, shares = 0.0
        for c in cols { switch c { case .fixed(let w): fixed += w; case .flex(let s): shares += s } }
        let rest = max(0, total - fixed)
        return cols.map { c in
            switch c { case .fixed(let w): w; case .flex(let s): shares > 0 ? rest * s / shares : 0 }
        }
    }

    /// Where each column starts and ends, rounded to whole points as WPF's layout rounding does: equal stars come out
    /// within a point of each other, the rounding spread over the row rather than all given to the last column.
    private func edges(_ bounds: CGRect, count: Int) -> [(x: CGFloat, width: CGFloat)] {
        var at = bounds.minX, out: [(x: CGFloat, width: CGFloat)] = []
        for (i, w) in widths(bounds.width, count: count).enumerated() {
            let start = at.rounded(), end = i == count - 1 ? bounds.maxX : (at + w).rounded()
            out.append((start, max(0, end - start)))
            at += w
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 800
        let w = widths(total, count: subviews.count)
        let h = zip(subviews, w).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: total, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (s, e) in zip(subviews, edges(bounds, count: subviews.count)) {
            s.place(at: CGPoint(x: e.x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: e.width, height: bounds.height))
        }
    }
}

// MARK: - Cells

/// A readout cell: its label, a large mono value (the first one in the accent), and a line under it.
private struct ReadoutCell<Sub: View>: View {
    var label: String
    var value: String
    var accent = false
    @ViewBuilder var sub: Sub
    @Environment(\.ob) private var ob

    var body: some View {
        PanelCell {
            VStack(alignment: .leading, spacing: 0) {
                Readout(label).lineLimit(1).truncationMode(.tail)
                Text(value).font(Ob.mono(24, .bold)).foregroundStyle(accent ? ob.accent : ob.ink)
                    .lineLimit(1).truncationMode(.tail).padding(.top, 6).padding(.bottom, 2)
                sub
            }
        }
    }
}

extension ReadoutCell where Sub == SubLine {
    init(label: String, value: String, sub: String, accent: Bool = false) {
        self.init(label: label, value: value, accent: accent) { SubLine(text: sub) }
    }
}

private struct SubLine: View {
    var text: String
    @Environment(\.ob) private var ob
    var body: some View { Text(text).font(Ob.sans(11)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true) }
}

/// "vs typing at 35 wpm ✎" under TIME SAVED: a click turns the number into a box to type another speed.
private struct TypingSpeed: View {
    @Binding var wpm: Int
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.ob) private var ob

    var body: some View {
        if editing {
            // A TextBox 52 × 24, FontSize 11, Padding 4,1, right after "vs typing at " and before " wpm".
            HStack(spacing: 0) {
                Text("vs typing at ").font(Ob.sans(11)).foregroundStyle(ob.muted)
                TextField("", text: $text)
                    .textFieldStyle(.plain).font(Ob.sans(11))
                    .padding(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                    .frame(width: 52, height: 24)
                    .modifier(FluentField(focused: focused))
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, f in if !f { commit() } }
                    .accessibilityLabel("Typing speed, words per minute")
                Text(" wpm").font(Ob.sans(11)).foregroundStyle(ob.muted)
            }
            .onAppear { text = "\(max(1, wpm))"; focused = true }
        } else {
            Button { editing = true } label: {
                Text("vs typing at \(max(1, wpm)) wpm ✎").font(Ob.sans(11)).foregroundStyle(ob.muted).underline().lineLimit(2)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .keyTabStop { editing = true }
            .handCursor()
            .help("Click to change the typing speed time saved is measured against")
        }
    }

    private func commit() {
        guard editing else { return }
        if let n = Int(text.trimmingCharacters(in: .whitespaces)), (5...300).contains(n) { wpm = n }
        editing = false
    }
}

#if os(iOS)
private extension View {
    func onExitCommand(perform: @escaping () -> Void) -> some View { self }
}
#endif

/// A section's head (AnalyticsPage.Head): its number and title in mono 11 bold, a readout at the right, 8 below.
private struct Head<Key: View>: View {
    var title: String
    var right: String
    @ViewBuilder var key: Key

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // No "…": a title the right-hand label leaves no room for is cut off, as Windows' TextBlock.
            Text(title.uppercased()).font(Ob.mono(11, .bold)).lineLimit(1).fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading).clipped()
            key
            if !right.isEmpty { Readout(right).lineLimit(1).fixedSize().padding(.leading, 12) }
        }
        .padding(.bottom, 8)
    }
}

extension Head where Key == EmptyView {
    init(title: String, right: String) { self.init(title: title, right: right) { EmptyView() } }
}

/// An Analytics cell: Windows' Cell has Padding 16,12,16,14.
private struct PanelCell<Content: View>: View {
    var link = false
    @ViewBuilder var content: Content
    var body: some View { Cell(link: link, padding: EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16)) { content } }
}

/// An empty section: why it is empty, or that the word tally is off (muted 12).
private struct Empty: View {
    var on: Bool
    var text: String
    @Environment(\.ob) private var ob

    var body: some View {
        Text(on ? text : "The word tally is off. Turn it on under Settings › History to see this.").font(Ob.sans(12)).foregroundStyle(ob.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row with a hairline over it.
private struct Ruled<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(.vertical, 6).overlay(alignment: .top) { Hairline() }
    }
}

/// A horizontal bar filled to a fraction: ink (or the accent) on a faint track.
private struct Meter: View {
    var fraction: Double
    var accent = false
    @Environment(\.ob) private var ob
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(ob.subtle))
            // At least 2 % of the track (Windows' star width Max(0.02, fraction)).
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width * max(0.02, min(fraction, 1)), height: size.height)),
                     with: .color(accent ? ob.accent : ob.ink))
        }
        .frame(height: 8)
    }
}

// MARK: 02 Output by app

private struct AppsCell: View {
    var usage: [(key: String, day: UsageDay)]
    @Binding var selected: String?
    @Binding var label: String
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// The top six apps by dictations, then by name; names told apart ignoring case, under the spelling met first.
    static func top(_ usage: [(key: String, day: UsageDay)]) -> [(app: String, count: Int)] {
        var sums: [(app: String, count: Int)] = []
        for (_, d) in usage {
            for (a, n) in d.apps.sorted(by: { $0.key < $1.key }) {
                if let i = sums.firstIndex(where: { $0.app.caseInsensitiveCompare(a) == .orderedSame }) { sums[i].count += n } else { sums.append((a, n)) }
            }
        }
        return Array(sums.sorted { $0.count != $1.count ? $0.count > $1.count : $0.app.compare($1.app, locale: .current) == .orderedAscending }.prefix(6))
    }

    var body: some View {
        let apps = Self.top(usage)
        let total = max(1, usage.reduce(0) { $0 + $1.day.dictations })
        // Sites need the window title, which only the direct build reads: the App Store build doesn't offer them.
        return PanelCell {
            VStack(alignment: .leading, spacing: 0) {
                Head(title: "02 // Output by app", right: sizeClass == .compact ? "Tap one: the words below follow it"
                     : Distribution.isDirect ? "Click an app or site: the words below follow it" : "Click an app: the words below follow it")
                if apps.isEmpty {
                    #if os(iOS)
                    Text("On iPhone the text goes to the clipboard, so Oberton can't tell which app it ends up in. On the Mac, each app you dictate into shows here.")
                        .font(Ob.sans(12)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true)
                    #else
                    Text("The apps you dictate into appear here.").font(Ob.sans(12)).foregroundStyle(ob.muted)
                    #endif
                } else {
                    AppRow(text: "All apps", tip: "Every app", count: total, total: total, key: nil, selected: selected) { selected = nil; label = "" }
                    ForEach(apps, id: \.app) { app, n in
                        let key = WordTally.appKey(app)
                        AppRow(text: app, tip: app, count: n, total: total, key: key, selected: selected) { selected = key; label = app }
                        // A browser: its sites under it (the top four, the rest together), each with its own bar.
                        let sites = UsageLog.sitesOf(usage.map(\.day), app)
                        if !sites.isEmpty {
                            let rest = sites.dropFirst(4).reduce(0) { $0 + $1.count } + max(0, n - sites.reduce(0) { $0 + $1.count })
                            ForEach(sites.prefix(4), id: \.site) { site, m in
                                let siteKey = WordTally.appKey(app, site), tip = "\(site) in \(app)"
                                AppRow(text: "↳ " + site, tip: tip, count: m, total: total, key: siteKey, selected: selected, site: true) {
                                    selected = siteKey; label = tip
                                }
                            }
                            if rest > 0 {
                                AppRow(text: "↳ Other", tip: sites.count > 4 ? "Other sites in \(app)" : "\(app), from before sites were counted",
                                       count: rest, total: total, key: nil, selected: selected, site: true, pick: nil)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One row of Output by app: the name, a bar of blocks, and the count. A site row is indented, smaller and muted.
/// Clicking a row shows that app's (or site's) words below; ALL APPS shows everything; a row without `pick` (a browser's
/// other sites) can't be clicked. The row shown is in the accent (AnalyticsPage.AppRow).
private struct AppRow: View {
    var text: String
    var tip: String
    var count: Int
    var total: Int
    var key: String?
    var selected: String?
    var site = false
    var pick: (() -> Void)?
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var hover = false

    var body: some View {
        // ALL APPS (no key) is the one shown while no app is picked; keys compared ignoring case.
        let on = pick != nil && (key == nil ? selected == nil : selected.map { key!.caseInsensitiveCompare($0) == .orderedSame } == true)
        let compact = sizeClass == .compact
        let color = on ? ob.accent : site ? ob.muted : ob.ink
        let row = WeightedRow(columns: compact ? [.flex(1.2), .flex(2), .fixed(44)] : [.flex(0.8), .flex(2.4), .fixed(52)]) {
            // The name's tooltip covers its whole column (a stretched TextBlock), inside its margins.
            Text((on ? "▸ " : "") + text.uppercased()).font(Ob.mono(site ? 10 : 11, on ? .bold : .regular))
                .foregroundStyle(color).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).help(tip)
                .padding(.leading, site ? 12 : 0).padding(.trailing, 10)
            BlockBar(fraction: Double(count) / Double(total), blocks: compact ? 20 : 30, color: color, height: site ? 7 : 10,
                     tip: "\(tip): \(count.formatted()) dictation\(count == 1 ? "" : "s")")
            Text(count.formatted()).font(Ob.mono(site ? 10 : 11)).foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: site ? 22 : 26)
        if let pick {
            Button(action: pick) {
                row
                    .background(hover ? ob.accentWash : .clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyTabStop(radius: 0, action: pick)
            .handCursor()
            .onHover { hover = $0 }
            .help(key == nil ? "Show the words of every app" : "Show the words dictated into \(tip)")
            .accessibilityAddTraits(on ? .isSelected : [])
        } else {
            row
        }
    }
}

/// A bar of square-cornered blocks, filled up to a fraction, the rest outlined: Windows' one-row UniformGrid, each block
/// a cell's width less its 2 px right margin (so the bar ends 2 px short of its column). Its tooltip shows over the
/// filled blocks only; the empty ones are bare outlines on Windows, and the gaps show the row's own tooltip.
private struct BlockBar: View {
    var fraction: Double
    var blocks: Int
    var color: Color
    var height = 10.0
    var tip: String?
    @Environment(\.ob) private var ob

    /// Math.Round: halves to the even block count.
    private var filled: Int { max(1, Int((fraction * Double(blocks)).rounded(.toNearestOrEven))) }

    private func block(_ b: Int, _ size: CGSize) -> CGRect {
        let cell = size.width / Double(blocks)
        return CGRect(x: Double(b) * cell, y: 0, width: max(0, cell - 2), height: size.height)
    }

    var body: some View {
        Canvas { ctx, size in
            for b in 0..<blocks {
                let r = block(b, size)
                if b < filled { ctx.fill(Path(r), with: .color(color)) } else { ctx.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(ob.divider), lineWidth: 1) }
            }
        }
        .frame(height: height)
        .overlay {
            if let tip {
                GeometryReader { g in
                    ForEach(0..<min(filled, blocks), id: \.self) { b in
                        let r = block(b, g.size)
                        Color.clear.contentShape(Rectangle()).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY).help(tip)
                    }
                }
            }
        }
    }
}

// MARK: 03 Most corrected, 04 most used words, 05 phrases and fillers

private struct CorrectionsCell: View {
    var tally: [TallyDay]
    var on: Bool
    var scope: String
    var hint: (String) -> String
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob

    var body: some View {
        // Keyed by the whole "heard → written" pair: one heard word can have been written two ways.
        let top = WordTally.top(tally, \.corrections, 8).compactMap { pair -> (key: String, heard: String, written: String, count: Int)? in
            let parts = pair.key.components(separatedBy: WordTally.arrow)
            return parts.count == 2 ? (pair.key, parts[0], parts[1], pair.count) : nil
        }
        PanelCell {
            VStack(alignment: .leading, spacing: 0) {
                Head(title: "03 // Most corrected", right: scope)
                Text("Words the AI fixes again and again. Add one to the speech vocabulary and the recognizer hears it right next time.")
                    .font(Ob.sans(11.5)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                if !on || top.isEmpty {
                    Empty(on: on, text: hint("Corrections show up here once the AI has fixed the same words a few times."))
                } else {
                    let stamp = top.map { "\($0.key)\u{0}\($0.count)" }.joined(separator: "\u{1}")
                    ForEach(top, id: \.key) { row in
                        Ruled { CorrectionRow(heard: row.heard, written: row.written, count: row.count, stamp: stamp) }
                    }
                }
            }
        }
    }
}

private struct CorrectionRow: View {
    var heard: String
    var written: String
    var count: Int
    /// Changes when the section is drawn again (new counts): each row then looks at the vocabulary afresh.
    var stamp: String
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    /// "ADDED ✓" as this row last looked (Windows' ShowState: when the row is drawn and when its own button is
    /// clicked), so adding a word turns only the row clicked, not another with the same written word.
    @State private var added: Bool?

    var body: some View {
        // One line: the pair cut with "…" when the cell is narrow, then ×N and the button (a DockPanel).
        HStack(spacing: 0) {
            pair.layoutPriority(-1)
            Spacer(minLength: 0)
            times.fixedSize().padding(.leading, 8)
            button.fixedSize().padding(.leading, 8)
        }
    }

    private var pair: some View {
        var h = AttributedString(heard)
        h.strikethroughStyle = .single
        h.foregroundColor = ob.muted
        var w = AttributedString(written)
        w.foregroundColor = ob.accent
        w.font = Ob.mono(12.5, .bold)
        return Text(h + AttributedString("  →  ") + w).font(Ob.mono(12.5)).lineLimit(1).truncationMode(.tail)
            .help("Heard \"\(heard)\", the AI wrote \"\(written)\" (\(count.formatted()) time\(count == 1 ? "" : "s"))")
    }

    private var times: some View { Text("×\(count.formatted())").font(Ob.mono(11)).foregroundStyle(ob.muted) }

    private var button: some View {
        let added = self.added ?? model.inVocabulary(written)
        let tip = added ? "\"\(written)\" is in the speech vocabulary (Settings › Speech recognition)"
            : "Add \"\(written)\" to the speech vocabulary, so the recognizer expects it"
        return Button(added ? "Added ✓" : "Add to vocabulary") {
            model.addToVocabulary(written)
            self.added = model.inVocabulary(written)
        }
        .buttonStyle(.quietSmall)
        .disabled(added)
        .help(tip)
        .accessibilityLabel(tip)
        .onAppear { self.added = model.inVocabulary(written) }
        .onChange(of: stamp) { self.added = model.inVocabulary(written) }
    }
}

private struct TopWordsCell: View {
    var tally: [TallyDay]
    var on: Bool
    var scope: String
    var hint: (String) -> String
    @Environment(\.ob) private var ob

    var body: some View {
        let top = WordTally.top(tally, \.words, 10)
        let max = Double(top.first?.count ?? 1)
        PanelCell {
            VStack(alignment: .leading, spacing: 0) {
                Head(title: "04 // Most used words", right: scope)
                if !on || top.isEmpty {
                    Empty(on: on, text: hint("Your most used words appear here after a few dictations."))
                } else {
                    ForEach(Array(top.enumerated()), id: \.offset) { i, w in
                        WeightedRow(columns: [.fixed(24), .flex(1), .flex(1.6), .fixed(48)]) {
                            Text(String(format: "%02d", i + 1)).font(Ob.mono(10)).foregroundStyle(ob.muted)
                            Text(w.key).font(Ob.mono(12.5)).lineLimit(1).truncationMode(.tail).padding(.trailing, 8).help(w.key)
                            Meter(fraction: Double(w.count) / max, accent: i == 0)
                            Text(w.count.formatted()).font(Ob.mono(11)).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .frame(height: 24)
                    }
                }
            }
        }
    }
}

private struct PhrasesCell: View {
    var tally: [TallyDay]
    var before: [TallyDay]?
    var on: Bool
    var period: Int?
    var scope: String
    var hint: (String) -> String
    @Environment(\.ob) private var ob

    var body: some View {
        let top = WordTally.topPhrases(tally, 8)
        let fillers = WordTally.top(tally, \.fillers, 6)
        let total = fillers.reduce(0) { $0 + $1.count }
        PanelCell {
            VStack(alignment: .leading, spacing: 0) {
                Head(title: "05 // Common phrases", right: scope)
                if !on || top.isEmpty {
                    Empty(on: on, text: hint("Phrases you say again and again appear here."))
                } else {
                    ForEach(top, id: \.phrase) { p in
                        Ruled {
                            // A DockPanel: ×N docked at the right, the phrase filling the rest right up to it.
                            HStack(spacing: 0) {
                                Text("“\(p.phrase)”").font(Ob.sans(13)).lineLimit(1).truncationMode(.tail).help(p.phrase)
                                Spacer(minLength: 0)
                                Text("×\(p.count.formatted())").font(Ob.mono(11)).foregroundStyle(ob.muted)
                            }
                        }
                    }
                }
                // Fillers removed, with the change on the period before.
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("FILLERS REMOVED").font(Ob.mono(11, .bold))
                        Spacer()
                        Text(on ? total.formatted() : "—").font(Ob.mono(16, .bold))
                    }
                    // An empty line with the tally off, as Windows' empty TextBlock.
                    Text(on ? detail(fillers, total) : " ").font(Ob.sans(11)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                .overlay(alignment: .top) { Hairline() }
                .padding(.top, 10)
            }
        }
    }

    private func detail(_ fillers: [(key: String, count: Int)], _ total: Int) -> String {
        guard total > 0 else { return "None taken out yet." }
        var s = fillers.map { "\($0.key) \($0.count.formatted())" }.joined(separator: " · ")
        if let before, let n = period {
            let prev = before.reduce(0) { $0 + $1.fillers.values.reduce(0, +) }
            if prev > 0 {
                s += ". \(total <= prev ? "Down" : "Up") \(percent(Double(abs(total - prev)) / Double(prev))) on the \(n) days before."
            }
        }
        return s
    }
}

// MARK: 06 Words per day, 07 when you dictate

private struct WordsPerDayCell: View {
    var usage: [(key: String, day: UsageDay)]
    var period: Int?
    var now: Date
    @Environment(\.ob) private var ob

    struct Bucket { var tick: String; var from: String; var to: String; var tip: String; var dictated = 0; var read = 0 }

    var body: some View {
        let buckets = makeBuckets()
        let max = Swift.max(1, buckets.map { Swift.max($0.dictated, $0.read) }.max() ?? 1)
        let unit = period == 7 || period == 30 ? "day" : period == 90 ? "week" : "month"
        PanelCell {
            VStack(alignment: .leading, spacing: 0) {
                Head(title: "06 // Words per \(unit)", right: "") {
                    key(1, "Dictated")
                    key(0.3, "Read aloud")
                }
                if buckets.allSatisfy({ $0.dictated + $0.read == 0 }) {
                    Text("Dictate or read something aloud and your words appear here.").font(Ob.sans(12)).foregroundStyle(ob.muted)
                } else {
                    VStack(spacing: 0) {
                        Canvas { ctx, size in
                            // Each bucket: a pair with 1 either side, each bar in half of it with 1 either side (Bar).
                            let w = size.width / Double(buckets.count)
                            for (i, b) in buckets.enumerated() {
                                let last = i == buckets.count - 1
                                let half = Swift.max(0, w - 2) / 2, barW = Swift.max(0.5, half - 2)
                                for (k, v) in [b.dictated, b.read].enumerated() where v > 0 {
                                    let h = Swift.max(2, size.height * Double(v) / Double(max))
                                    let r = CGRect(x: Double(i) * w + 1 + Double(k) * half + 1, y: size.height - h, width: barW, height: h)
                                    ctx.fill(Path(r), with: .color(k == 0 ? (last ? ob.accent : ob.ink) : ob.ink.opacity(0.3)))
                                }
                            }
                        }
                        .overlay {
                            HStack(spacing: 0) {
                                ForEach(Array(buckets.enumerated()), id: \.offset) { _, b in
                                    Color.clear.contentShape(Rectangle())
                                        .help("\(b.tip)\n\(b.dictated.formatted()) words dictated\n\(b.read.formatted()) words read aloud")
                                }
                            }
                        }
                        Hairline()
                        HStack(spacing: 0) {
                            ForEach(Array(buckets.enumerated()), id: \.offset) { i, b in
                                let last = i == buckets.count - 1
                                Text(b.tick).font(Ob.mono(9, last ? .bold : .regular)).foregroundStyle(last ? ob.accent : ob.muted)
                                    .lineLimit(1).fixedSize().frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Words per \(unit): \(buckets.reduce(0) { $0 + $1.dictated }.formatted()) dictated, \(buckets.reduce(0) { $0 + $1.read }.formatted()) read aloud")
                }
            }
        }
    }

    /// A key swatch, 9 × 9 with Margin 12,0,5,0, and its MonoLabel.
    private func key(_ opacity: Double, _ label: String) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(ob.ink.opacity(opacity)).frame(width: 9, height: 9).padding(.trailing, 5)
            Readout(label).lineLimit(1).fixedSize()
        }
        .padding(.leading, 12)
    }

    /// Days for a week or a month, weeks for 90 days, months for everything.
    private func makeBuckets() -> [Bucket] {
        let cal = Calendar.current
        let day = { (back: Int) in cal.date(byAdding: .day, value: -back, to: now)! }
        var out: [Bucket] = []
        switch period {
        case 7, 30:
            let n = period!
            for i in stride(from: n - 1, through: 0, by: -1) {
                let d = day(i), k = UsageLog.key(d)
                let tick = i == 0 ? "NOW" : n == 7 ? String(DateText.format(d, "EEE").prefix(2)).uppercased()
                    : cal.component(.day, from: d) % 5 == 0 ? "\(cal.component(.day, from: d))" : ""
                out.append(Bucket(tick: tick, from: k, to: k, tip: DateText.dayMonth(d)))
            }
        case 90:
            for i in stride(from: 12, through: 0, by: -1) {
                let to = day(7 * i), from = day(7 * i + 6)
                let tick = i == 0 ? "NOW" : i % 2 == 0 ? DateText.dayMonth(to).uppercased() : ""
                out.append(Bucket(tick: tick, from: UsageLog.key(from), to: UsageLog.key(to),
                                  tip: "\(DateText.dayMonth(from)) – \(DateText.dayMonth(to))"))
            }
        default:
            let first = usage.first.flatMap { UsageLog.date($0.key) } ?? now
            var m = cal.date(from: cal.dateComponents([.year, .month], from: first))!
            let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            if let earliest = cal.date(byAdding: .month, value: -23, to: thisMonth), m < earliest { m = earliest }
            while m <= now {
                let end = cal.date(byAdding: .day, value: -1, to: cal.date(byAdding: .month, value: 1, to: m)!)!
                out.append(Bucket(tick: DateText.month(m).uppercased(), from: UsageLog.key(m), to: UsageLog.key(end),
                                  tip: "\(DateText.dayMonth(m)) – \(DateText.dayMonth(end))"))
                m = cal.date(byAdding: .month, value: 1, to: m)!
            }
            if !out.isEmpty { out[out.count - 1].tick = "NOW" }
        }
        for i in out.indices {
            for (k, d) in usage where k >= out[i].from && k <= out[i].to {
                out[i].dictated += d.words
                out[i].read += d.wordsRead
            }
        }
        return out
    }
}

private struct HeatmapCell: View {
    var grid: [[Int]]
    var on: Bool
    var scope: String
    var hint: (String) -> String
    @Environment(\.ob) private var ob

    private static let names = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]

    var body: some View {
        // Two-hour blocks: twelve columns read better than twenty-four.
        let blocks = grid.map { row in (0..<12).map { row[2 * $0] + row[2 * $0 + 1] } }
        let max = Swift.max(1, blocks.flatMap { $0 }.max() ?? 1)
        let total = blocks.flatMap { $0 }.reduce(0, +)
        PanelCell {
            VStack(alignment: .leading, spacing: 0) {
                Head(title: "07 // When you dictate", right: scope)
                if !on || total == 0 {
                    Empty(on: on, text: hint("Once you have dictated for a while, your busiest hours show here."))
                } else {
                    VStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { r in
                            HStack(spacing: 0) {
                                Text(Self.names[r]).font(Ob.mono(10)).foregroundStyle(ob.muted).frame(width: 36, alignment: .leading)
                                ForEach(0..<12, id: \.self) { c in
                                    let v = blocks[r][c]
                                    let tip = "\(Self.names[r]) \(String(format: "%02d:00–%02d:00", 2 * c, 2 * c + 2)) · \(v.formatted()) dictation\(v == 1 ? "" : "s")"
                                    // Only a filled block takes the pointer (an empty one is a bare outline on Windows,
                                    // so its tooltip practically never shows).
                                    Group {
                                        if v > 0 { Rectangle().fill(ob.ink.opacity(0.15 + 0.85 * Double(v) / Double(max))).help(tip) }
                                        else { Rectangle().strokeBorder(ob.divider, lineWidth: 1).allowsHitTesting(false) }
                                    }
                                    .frame(minHeight: 14)
                                    .padding(1.5)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        }
                        HStack(spacing: 0) {
                            Color.clear.frame(width: 36, height: 1)
                            ForEach(0..<12, id: \.self) { c in
                                Text(c % 2 == 0 ? "\(2 * c)" : "").font(Ob.mono(9.5)).foregroundStyle(ob.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 2)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("When you dictate, by weekday and hour")
                }
            }
        }
    }
}

// MARK: 08 Profiles

private struct ProfilesCell: View {
    var tally: [TallyDay]
    var on: Bool
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let rows = WordTally.byProfile(tally).prefix(8)
        let compact = sizeClass == .compact
        let columns: [WeightedRow.Column] = [.flex(2), .flex(1), .flex(1), .flex(1), .flex(1)]
        PanelCell {
            VStack(alignment: .leading, spacing: 0) {
                Head(title: "08 // How each profile edits", right: "Every app")
                if !on || rows.isEmpty {
                    Empty(on: on, text: "Each profile's edits are summed up here after you dictate with it.")
                } else {
                    WeightedRow(columns: columns) {
                        ForEach(Array((compact ? ["Profile", "Used", "Changed", "Kept", "Turn"] : ["Profile", "Used", "Words changed", "Kept", "Turnaround"]).enumerated()),
                                id: \.offset) { i, h in
                            Readout(h, size: 10).lineLimit(1).frame(maxWidth: .infinity, alignment: i == 0 ? .leading : .trailing)
                        }
                    }
                    .padding(.vertical, 5)
                    ForEach(Array(rows), id: \.profile) { name, p in
                        WeightedRow(columns: columns) {
                            Text(name).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                            cell(p.dictations.formatted())
                            cell(p.aiEdited == 0 || p.wordsHeard == 0 ? "—" : percent(min(1, Double(p.wordsChanged) / Double(p.wordsHeard))))
                            cell(p.aiEdited == 0 ? "—" : percent(Double(p.aiKept) / Double(p.aiEdited)))
                            cell(p.turnaroundCount > 0 ? NetNumber.fixed(p.turnaroundSeconds / Double(p.turnaroundCount), digits: 1) + " s" : "—")
                        }
                        .font(Ob.mono(12))
                        .padding(.vertical, 5)
                        .overlay(alignment: .top) { Hairline() }
                    }
                }
            }
        }
    }

    private func cell(_ s: String) -> some View { Text(s).lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing) }
}

// MARK: 10, 11 Extended Notes

private struct LongestSessionsCell: View {
    var figures: NotesFigures
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob

    var body: some View {
        PanelCell {
            VStack(alignment: .leading, spacing: 0) {
                Head(title: "10 // Longest sessions", right: "Click one to open it")
                if figures.longest.isEmpty {
                    Text("Your longest Extended Notes sessions appear here.").font(Ob.sans(12)).foregroundStyle(ob.muted)
                } else {
                    ForEach(figures.longest) { n in LongestRow(session: n) { nav.goNotes(n.id) } }
                }
            }
        }
    }
}

private struct LongestRow: View {
    var session: NoteSession
    var open: () -> Void
    @Environment(\.ob) private var ob
    @State private var hover = false

    var body: some View {
        Ruled {
            HStack(spacing: 0) {
                Text(DateText.dayMonth(session.started).uppercased()).font(Ob.mono(10)).foregroundStyle(ob.muted)
                    .frame(width: 56, alignment: .leading)
                Text(session.title).font(Ob.sans(13)).foregroundStyle(hover ? ob.accent : ob.ink).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(NoteSession.words(session.transcript).formatted()) w").font(Ob.mono(11)).foregroundStyle(ob.muted).fixedSize().padding(.leading, 10)
                Text(duration(session.seconds)).font(Ob.mono(12, .bold)).frame(width: 60, alignment: .trailing).padding(.leading, 10)
            }
            .contentShape(Rectangle())
            .handCursor()
            .onHover { hover = $0 }
            .onTapGesture(perform: open)
            .help("Open \"\(session.title)\"")
        }
    }
}

private struct NotesSourcesCell: View {
    var figures: NotesFigures
    @Environment(\.ob) private var ob

    var body: some View {
        PanelCell {
            VStack(alignment: .leading, spacing: 0) {
                Head(title: "11 // What it listened to", right: "By time recorded")
                if figures.sessions == 0 {
                    Text("The microphone, the computer's audio, or both: how your sessions split shows here.").font(Ob.sans(12)).foregroundStyle(ob.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let most = max(1, figures.sources.values.map(\.seconds).max() ?? 1)
                    ForEach([(NotesSource.mic, "Microphone"), (.computer, "Computer audio"), (.both, "Both")], id: \.0) { source, label in
                        let v = figures.sources[source]
                        WeightedRow(columns: [.flex(1), .flex(1.4), .fixed(96)]) {
                            Text(label.uppercased()).font(Ob.mono(11)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Meter(fraction: (v?.seconds ?? 0) / most)
                            Text(v.map { "\(NetNumber.n0($0.sessions)) · \(duration($0.seconds))" } ?? "—").font(Ob.mono(11)).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .frame(height: 28)
                    }
                }
            }
        }
    }
}

// MARK: - Formatting

/// .NET's "P0" in the user's region ("6%", "6 %").
private func percent(_ x: Double) -> String { NetNumber.percent(x) }

/// A length of time the way a readout shows it: 45 s, 12 min, 1.4 h ("0" and "0.0" custom formats, the region's decimal
/// separator).
private func duration(_ seconds: Double) -> String {
    seconds < 60 ? NetNumber.fixed(seconds, digits: 0) + " s" : seconds < 3600 ? NetNumber.fixed(seconds / 60, digits: 0) + " min"
        : NetNumber.fixed(seconds / 3600, digits: 1) + " h"
}
