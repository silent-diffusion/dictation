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
    /// The app whose words are shown, or nil for every app; the page always opens on every app.
    @State private var app: String?

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
                panel(top: 18) { AppsCell(usage: usage, selected: $app) }
                row([1, 1, 1]) {
                    CorrectionsCell(tally: shown, on: on, scope: scope("Heard → written"), hint: hint)
                    TopWordsCell(tally: shown, on: on, scope: scope("Common words left out"), hint: hint)
                    PhrasesCell(tally: shown, before: before(now: now), on: on, period: period, scope: scope("3 to 4 words"), hint: hint)
                }
                row([1.4, 1]) {
                    WordsPerDayCell(usage: usage, period: period, now: now).frame(height: 230)
                    HeatmapCell(grid: heatGrid(usage: usage, shown: shown, on: on), on: on || app == nil, scope: scope("Weekday × hour"), hint: hint)
                        .frame(height: 230)
                }
                panel(top: 18) { ProfilesCell(tally: tally, on: on) }
            }
            .padding(compact ? EdgeInsets(top: 16, leading: 16, bottom: 24, trailing: 16) : EdgeInsets(top: 20, leading: 28, bottom: 24, trailing: 28))
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Analytics", japanese: "分析", size: compact ? 26 : 30) {
                if !compact { periods }
            }
            let summary = (period.map { "Last \($0) days" } ?? "Everything so far") + ": how you dictate, what gets corrected, and the words you reach for."
            let note = model.settings.keepWordTally ? "Word tally // on // counts only, never sentences" : "Word tally // off // turn it on under Settings › History"
            if compact {
                periods.padding(.top, 10)
                Text(summary).font(Ob.sans(12.5)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                Readout(note, size: 9.5).padding(.top, 4).padding(.bottom, 14)
            } else {
                HStack(spacing: 16) {
                    Text(summary).font(Ob.sans(12.5)).foregroundStyle(ob.muted).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Readout(note).lineLimit(1)
                }
                .padding(.top, 6).padding(.bottom, 14)
            }
        }
    }

    private var periods: some View {
        HStack(spacing: 4) {
            ForEach([(7, "7D"), (30, "30D"), (90, "90D"), (0, "All")], id: \.0) { days, label in
                let value: Int? = days == 0 ? nil : days
                Button(label) { period = value }
                    .buttonStyle(CapsuleButtonStyle(kind: value == period ? .primary : .quiet, size: 11, compact: true))
                    .frame(minWidth: 52)
                    .help(value.map { "The last \($0) days" } ?? "Everything so far")
                    .accessibilityAddTraits(value == period ? .isSelected : [])
            }
        }
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

        // How long the voice actually spoke (at the speed of each reading).
        let readSeconds = d.reduce(0) { $0 + $1.secondsRead }
        let wordsRead = d.reduce(0) { $0 + $1.wordsRead }, readings = d.reduce(0) { $0 + $1.readings }
        let timedWords = d.filter { $0.secondsRead > 0 }.reduce(0) { $0 + $1.wordsRead }
        let readSub = readSeconds >= 30 ? "real listening time · \(Int((Double(timedWords) / (readSeconds / 60)).rounded())) wpm"
            : readSeconds > 0 ? "real listening time" : "nothing read aloud yet"

        let wpm = Double(max(1, model.settings.typingWPM))
        let saved = max(0, Double(words) / wpm - (seconds + turn) / 60) // minutes
        let cells: [AnyView] = [
            AnyView(ReadoutCell(label: "Words dictated", value: words.formatted(), sub: "in \(dictations.formatted()) dictation\(dictations == 1 ? "" : "s")", accent: true)),
            AnyView(ReadoutCell(label: "Speaking pace", value: pace.map { "\(Int($0.rounded())) wpm" } ?? "—", sub: paceSub)),
            AnyView(ReadoutCell(label: "Time saved", value: words == 0 ? "—" : saved >= 60 ? String(format: "%.1f h", saved / 60) : "\(Int(saved.rounded())) min") {
                TypingSpeed(wpm: $model.settings.typingWPM)
            }),
            AnyView(ReadoutCell(label: "Turnaround", value: turnN > 0 ? String(format: "%.1f s", turn / Double(turnN)) : "—", sub: "stop → text in place")),
            AnyView(ReadoutCell(label: "AI edits kept", value: edits > 0 ? percent(Double(kept) / Double(edits)) : "—",
                                sub: edits > 0 ? "safety net rejected \(percent(Double(edits - kept) / Double(edits)))" : "no AI edits yet")),
            AnyView(ReadoutCell(label: "Read aloud", value: "\(wordsRead.formatted()) w",
                                sub: readings > 0 ? "in \(readings.formatted()) reading\(readings == 1 ? "" : "s")" : "words read aloud")),
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

    // MARK: Pieces

    /// A section's right-hand label: its own, or which app it is showing.
    private func scope(_ own: String) -> String { app.map { "In \($0)" } ?? own }

    /// An empty section's text: its own, or why the app picked has nothing yet.
    private func hint(_ own: String) -> String {
        app.map { "Nothing counted for \($0) in this period yet." } ?? own
    }

    /// The word tally of the period before this one (for "down 12% on the 30 days before"), of the app picked.
    private func before(now: Date) -> [TallyDay]? {
        guard let n = period else { return nil }
        let cal = Calendar.current
        let start = UsageLog.key(cal.date(byAdding: .day, value: 1 - 2 * n, to: now)!), end = UsageLog.key(cal.date(byAdding: .day, value: 1 - n, to: now)!)
        let days = model.words.days.filter { $0.day >= start && $0.day < end }
        return app.map { WordTally.forApp(days, $0) } ?? days
    }

    /// When you dictate: from the word tally (seeded from History, and per app); with the tally off, every app's
    /// hours from the daily counts.
    private func heatGrid(usage: [(key: String, day: UsageDay)], shown: [TallyDay], on: Bool) -> [[Int]] {
        on ? WordTally.weekHours(shown) : UsageLog.weekHours(usage)
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

    private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
        let cols = (0..<count).map { $0 < columns.count ? columns[$0] : .flex(1) }
        var fixed: CGFloat = 0, shares = 0.0
        for c in cols { switch c { case .fixed(let w): fixed += w; case .flex(let s): shares += s } }
        let rest = max(0, total - fixed)
        return cols.map { c in
            switch c { case .fixed(let w): w; case .flex(let s): shares > 0 ? (rest * s / shares).rounded(.down) : 0 }
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 800
        let w = widths(total, count: subviews.count)
        let h = zip(subviews, w).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: total, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        let w = widths(bounds.width, count: subviews.count)
        for (i, s) in subviews.enumerated() {
            // The last column takes what rounding left over.
            let width = i == subviews.count - 1 ? bounds.maxX - x : w[i]
            s.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
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
        Cell {
            VStack(alignment: .leading, spacing: 0) {
                Readout(label).lineLimit(1).truncationMode(.tail)
                Text(value).font(Ob.mono(24, .bold)).foregroundStyle(accent ? ob.accent : ob.ink)
                    .lineLimit(1).minimumScaleFactor(0.5).padding(.top, 6).padding(.bottom, 2)
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
    var body: some View { Text(text).font(Ob.sans(11)).foregroundStyle(ob.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
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
            HStack(spacing: 4) {
                Text("vs typing at").font(Ob.sans(11)).foregroundStyle(ob.muted)
                TextField("", text: $text)
                    .textFieldStyle(.plain).font(Ob.mono(11)).frame(width: 36)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(Rectangle().strokeBorder(ob.accent, lineWidth: 1))
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, f in if !f { commit() } }
                    .accessibilityLabel("Typing speed, words per minute")
                Text("wpm").font(Ob.sans(11)).foregroundStyle(ob.muted)
            }
            .onAppear { text = "\(wpm)"; focused = true }
        } else {
            Button { editing = true } label: {
                Text("vs typing at \(wpm) wpm ✎").font(Ob.sans(11)).foregroundStyle(ob.muted).underline().lineLimit(2)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
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

/// A section's head: its number and title in bold mono, a readout at the right (under it when the cell is narrow).
private struct Head: View {
    var title: String
    var right: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title.uppercased()).font(Ob.mono(13, .bold)).lineLimit(1)
                Spacer(minLength: 8)
                Readout(right, size: 10).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).font(Ob.mono(13, .bold)).lineLimit(1)
                Readout(right, size: 10).lineLimit(1)
            }
        }
        .padding(.bottom, 8)
    }
}

/// An empty section: why it is empty, and with the tally off, the way to turn it on.
private struct Empty: View {
    var on: Bool
    var text: String
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(on ? text : "The word tally is off, so nothing is counted here.").font(Ob.sans(12)).foregroundStyle(ob.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !on { Button("Turn it on") { nav.goSettings(.history) }.buttonStyle(.quietSmall) }
        }
        .padding(.top, 4)
    }
}

/// A row with a hairline over it.
private struct Ruled<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(.vertical, 5).overlay(alignment: .top) { Hairline() }
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
            ctx.fill(Path(CGRect(x: 0, y: 0, width: max(2, size.width * min(max(fraction, 0), 1)), height: size.height)),
                     with: .color(accent ? ob.accent : ob.ink))
        }
        .frame(height: 8)
    }
}

// MARK: 02 Output by app

private struct AppsCell: View {
    var usage: [(key: String, day: UsageDay)]
    @Binding var selected: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        var sums: [String: Int] = [:]
        for (_, d) in usage { for (a, n) in d.apps { sums[a, default: 0] += n } }
        let apps = sums.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(6)
        let total = max(1, usage.reduce(0) { $0 + $1.day.dictations })
        return Cell {
            VStack(alignment: .leading, spacing: 0) {
                Head(title: "02 // Output by app", right: sizeClass == .compact ? "Tap one: the words below follow it" : "Click an app: the words below follow it")
                if apps.isEmpty {
                    #if os(iOS)
                    Text("On iPhone the text goes to the clipboard, so Oberton can't tell which app it ends up in. On the Mac, each app you dictate into shows here.")
                        .font(Ob.sans(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    #else
                    Text("The apps you dictate into appear here.").font(Ob.sans(12)).foregroundStyle(.secondary)
                    #endif
                } else {
                    AppRow(text: "All apps", count: total, total: total, key: nil, selected: $selected)
                    ForEach(Array(apps), id: \.key) { app, n in
                        AppRow(text: app, count: n, total: total, key: app, selected: $selected)
                    }
                }
            }
        }
    }
}

/// One row of Output by app: the name, a bar of blocks, and the count. Clicking it shows that app's words below; ALL
/// APPS shows everything. The row shown is in the accent.
private struct AppRow: View {
    var text: String
    var count: Int
    var total: Int
    var key: String?
    @Binding var selected: String?
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var hover = false

    var body: some View {
        let on = key == selected
        let compact = sizeClass == .compact
        Button { selected = key } label: {
            WeightedRow(columns: compact ? [.flex(1.2), .flex(2), .fixed(44)] : [.flex(0.8), .flex(2.4), .fixed(52)]) {
                Text((on ? "▸ " : "") + text.uppercased()).font(Ob.mono(11, on ? .bold : .regular))
                    .foregroundStyle(on ? ob.accent : ob.ink).lineLimit(1).truncationMode(.tail).padding(.trailing, 10)
                BlockBar(fraction: Double(count) / Double(total), blocks: compact ? 20 : 30, color: on ? ob.accent : ob.ink)
                Text(count.formatted()).font(Ob.mono(11)).foregroundStyle(on ? ob.accent : ob.ink)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 26)
            .background(hover ? ob.accentWash : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(key.map { "Show the words dictated into \($0) (\(count.formatted()) dictations)" } ?? "Show the words of every app")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A bar of square-cornered blocks, filled up to a fraction, the rest outlined.
private struct BlockBar: View {
    var fraction: Double
    var blocks: Int
    var color: Color
    @Environment(\.ob) private var ob

    var body: some View {
        Canvas { ctx, size in
            let gap = 2.0, w = (size.width - gap * Double(blocks - 1)) / Double(blocks)
            let filled = max(1, Int((fraction * Double(blocks)).rounded()))
            for b in 0..<blocks {
                let r = CGRect(x: Double(b) * (w + gap), y: 0, width: w, height: size.height)
                if b < filled { ctx.fill(Path(r), with: .color(color)) } else { ctx.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(ob.divider), lineWidth: 1) }
            }
        }
        .frame(height: 10)
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
        let top = WordTally.top(tally, \.corrections, 8).compactMap { pair -> (String, String, Int)? in
            let parts = pair.key.components(separatedBy: WordTally.arrow)
            return parts.count == 2 ? (parts[0], parts[1], pair.count) : nil
        }
        Cell {
            VStack(alignment: .leading, spacing: 0) {
                Head(title: "03 // Most corrected", right: scope)
                Text("Words the AI fixes again and again. Add one to the speech vocabulary and the recognizer hears it right next time.")
                    .font(Ob.sans(11.5)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                if !on || top.isEmpty {
                    Empty(on: on, text: hint("Corrections show up here once the AI has fixed the same words a few times."))
                } else {
                    ForEach(top, id: \.0) { heard, written, n in
                        Ruled { CorrectionRow(heard: heard, written: written, count: n) }
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
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob

    var body: some View {
        // The button moves under the pair when the cell is too narrow for both.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { pair; Spacer(minLength: 0); times; button }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) { pair.lineLimit(1).truncationMode(.tail); Spacer(minLength: 0); times }
                button
            }
        }
    }

    private var pair: some View {
        var h = AttributedString(heard)
        h.strikethroughStyle = .single
        h.foregroundColor = ob.muted
        var w = AttributedString(written)
        w.foregroundColor = ob.accent
        w.font = Ob.mono(12.5, .bold)
        return Text(h + AttributedString("  →  ") + w).font(Ob.mono(12.5)).lineLimit(1)
            .help("Heard \"\(heard)\", the AI wrote \"\(written)\" (\(count.formatted()) time\(count == 1 ? "" : "s"))")
    }

    private var times: some View { Text("×\(count.formatted())").font(Ob.mono(11)).foregroundStyle(ob.muted) }

    private var button: some View {
        let added = model.inVocabulary(written)
        return Button(added ? "Added ✓" : "Add to vocabulary") { model.addToVocabulary(written) }
            .buttonStyle(.quietSmall)
            .disabled(added)
            .help(added ? "\"\(written)\" is in the speech vocabulary (Settings › Speech recognition)"
                  : "Add \"\(written)\" to the speech vocabulary, so the recognizer expects it")
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
        Cell {
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
        Cell {
            VStack(alignment: .leading, spacing: 0) {
                Head(title: "05 // Common phrases", right: scope)
                if !on || top.isEmpty {
                    Empty(on: on, text: hint("Phrases you say again and again appear here."))
                } else {
                    ForEach(top, id: \.phrase) { p in
                        Ruled {
                            HStack(spacing: 8) {
                                Text("“\(p.phrase)”").font(Ob.sans(13)).lineLimit(1).truncationMode(.tail).help(p.phrase)
                                Spacer(minLength: 0)
                                Text("×\(p.count.formatted())").font(Ob.mono(11)).foregroundStyle(ob.muted)
                            }
                        }
                    }
                }
                // Fillers removed, with the change on the period before.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("FILLERS REMOVED").font(Ob.mono(11, .bold))
                        Spacer()
                        Text(on ? total.formatted() : "—").font(Ob.mono(16, .bold))
                    }
                    if on { Text(detail(fillers, total)).font(Ob.sans(11)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true) }
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
        Cell {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("06 // WORDS PER \(unit.uppercased())").font(Ob.mono(13, .bold)).lineLimit(1)
                    Spacer(minLength: 8)
                    key(1, "Dictated")
                    key(0.3, "Read aloud")
                }
                .padding(.bottom, 8)
                if buckets.allSatisfy({ $0.dictated + $0.read == 0 }) {
                    Text("Dictate or read something aloud and your words appear here.").font(Ob.sans(12)).foregroundStyle(ob.muted)
                } else {
                    VStack(spacing: 0) {
                        Canvas { ctx, size in
                            let w = size.width / Double(buckets.count)
                            for (i, b) in buckets.enumerated() {
                                let last = i == buckets.count - 1
                                let inner = Swift.max(1, w - 2), barW = Swift.max(0.5, inner / 2 - 1)
                                let x = Double(i) * w + 1
                                for (k, v) in [b.dictated, b.read].enumerated() where v > 0 {
                                    let h = Swift.max(2, size.height * Double(v) / Double(max))
                                    let r = CGRect(x: x + Double(k) * (barW + 1) + 0.5, y: size.height - h, width: barW, height: h)
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

    private func key(_ opacity: Double, _ label: String) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(ob.ink.opacity(opacity)).frame(width: 9, height: 9)
            Readout(label, size: 10).lineLimit(1)
        }
        .padding(.leading, 8)
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
                let tick = i == 0 ? "NOW" : n == 7 ? String(d.formatted(.dateTime.weekday(.abbreviated)).prefix(2)).uppercased()
                    : cal.component(.day, from: d) % 5 == 0 ? "\(cal.component(.day, from: d))" : ""
                out.append(Bucket(tick: tick, from: k, to: k, tip: d.formatted(.dateTime.day().month())))
            }
        case 90:
            for i in stride(from: 12, through: 0, by: -1) {
                let to = day(7 * i), from = day(7 * i + 6)
                let tick = i == 0 ? "NOW" : i % 2 == 0 ? to.formatted(.dateTime.day().month(.abbreviated)).uppercased() : ""
                out.append(Bucket(tick: tick, from: UsageLog.key(from), to: UsageLog.key(to),
                                  tip: "\(from.formatted(.dateTime.day().month())) – \(to.formatted(.dateTime.day().month()))"))
            }
        default:
            let first = usage.first.flatMap { UsageLog.date($0.key) } ?? now
            var m = cal.date(from: cal.dateComponents([.year, .month], from: first))!
            let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            if let earliest = cal.date(byAdding: .month, value: -23, to: thisMonth), m < earliest { m = earliest }
            while m <= now {
                let end = cal.date(byAdding: .day, value: -1, to: cal.date(byAdding: .month, value: 1, to: m)!)!
                out.append(Bucket(tick: m.formatted(.dateTime.month(.abbreviated)).uppercased(), from: UsageLog.key(m), to: UsageLog.key(end),
                                  tip: m.formatted(.dateTime.month(.wide).year())))
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
        Cell {
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
                                    Group {
                                        if v > 0 { Rectangle().fill(ob.ink.opacity(0.15 + 0.85 * Double(v) / Double(max))) }
                                        else { Rectangle().strokeBorder(ob.divider, lineWidth: 1) }
                                    }
                                    .padding(1.5)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .help("\(Self.names[r]) \(String(format: "%02d:00–%02d:00", 2 * c, 2 * c + 2)) · \(v.formatted()) dictation\(v == 1 ? "" : "s")")
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
        Cell {
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
                            cell(p.turnaroundCount > 0 ? String(format: "%.1f s", p.turnaroundSeconds / Double(p.turnaroundCount)) : "—")
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

// MARK: - Formatting

private func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

/// A length of time the way a readout shows it: 45 s, 12 min, 1.4 h.
private func duration(_ seconds: Double) -> String {
    seconds < 60 ? "\(Int(seconds.rounded())) s" : seconds < 3600 ? "\(Int((seconds / 60).rounded())) min" : String(format: "%.1f h", seconds / 3600)
}
