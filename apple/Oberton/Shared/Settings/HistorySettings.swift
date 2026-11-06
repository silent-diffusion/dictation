import ObertonCore
import SwiftUI

/// A.4 History (HistorySettingsPage.xaml): keep it or not, with recordings or not; how long; where; the word tally and
/// the dashboard counts.
struct HistorySettingsSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @State private var confirmClear = false
    @State private var confirmReset = false
    @State private var confirmResetTally = false
    /// A shorter keep for the text waiting for "Go ahead?", and how many dictations it deletes.
    @State private var shorter: (keep: Keep, gone: Int)?
    @State private var size: Int64 = 0

    /// The newest so many, or a stretch of days; 0 and 0 = everything (text) or as long as the text (recordings).
    struct Keep: Hashable {
        var count = 0
        var days = 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Recent dictations are kept on this \(Device.noun) with everything about them: the recording, the transcription, the AI's output and what was inserted where. They are stored in Oberton's data folder, which app updates never touch.")
            // The card's StackPanel Margin 18,0 inside its 1 px line: the first switch flush, the second with 4 above and
            // below.
            VStack(spacing: 0) {
                ObSwitch("Keep a history of dictations", isOn: $model.settings.keepHistory)
                Hairline()
                ObSwitch("Keep the recordings", detail: "So you can play a dictation back. About 2 MB per minute of speech.",
                         isOn: $model.settings.saveHistoryAudio)
                    .padding(.vertical, 4)
            }
            .padding(.horizontal, 18 + Ob.border).padding(.vertical, Ob.border)
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: Ob.border))
            .padding(.top, 8)
            label("How long to keep", top: 22)
            // One grid (Margin 18,12): the two rows with a hairline straight between them.
            VStack(spacing: 0) {
                row("Text", detail: "The dictation itself: what was heard, the AI's edit, and where it went.") {
                    // While "Go ahead?" is up the box already shows the new choice; No puts the old one back (RevertKeep).
                    KeepMenu(audio: false, selection: Binding(get: { Keep(count: model.settings.historyLimit, days: model.settings.historyDays) },
                                                              set: chooseText),
                             pending: shorter?.keep, name: "How long to keep the text of dictations")
                }
                Hairline()
                row("Recordings", detail: "The audio, for playing a dictation back. Never kept longer than its text.") {
                    KeepMenu(audio: true, selection: Binding(get: { Keep(count: model.settings.audioLimit, days: model.settings.audioDays) },
                                                             set: { model.settings.audioLimit = $0.count; model.settings.audioDays = $0.days; changed() }),
                             name: "How long to keep the recordings of dictations")
                        .disabled(!model.settings.saveHistoryAudio)
                }
            }
            // Margin 18,12 inside the card's 1 px line.
            .padding(EdgeInsets(top: 13, leading: 19, bottom: 13, trailing: 19))
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
            Caption("Keep a number of the newest, or everything from a recent stretch of time. Older ones are deleted as new ones come in, every hour, and right away when you choose less. A recording deleted this way leaves its dictation's text in History.", bottom: 0)
                .padding(.top, 6)
            label("Stored in", top: 18)
            Text(Self.folderText(model.historyFolder)).font(Ob.mono(12)).fixedSize(horizontal: false, vertical: true)
            Caption("\(model.history.count) dictations, \(Self.megabytes(size)) MB.", bottom: 0)
                .padding(.top, 4)
            HStack(spacing: 8) {
                #if os(macOS)
                Button("Open folder") {
                    do {
                        try FileManager.default.createDirectory(at: model.historyFolder, withIntermediateDirectories: true)
                        if !NSWorkspace.shared.open(model.historyFolder) { throw CocoaError(.fileReadUnknown) }
                    } catch {
                        Log.warn("Opening the history folder failed: " + error.localizedDescription)
                    }
                }
                .buttonStyle(.quiet)
                #endif
                Button("Delete all history…") { confirmClear = true }.buttonStyle(.quiet)
            }
            .padding(.top, 8)
            label("Analytics word tally", top: 24)
            SwitchCard {
                ObSwitch("Count the words I dictate, for Analytics",
                         detail: "After each dictation: the words and phrases that went in, the words the AI corrected and the fillers it took out, the hour, and how much the profile changed. Counts only, never sentences, kept in words.json next to History.",
                         isOn: $model.settings.keepWordTally)
            }
            Button("Reset word tally…") { confirmResetTally = true }.buttonStyle(.quiet).padding(.top, 8)
            label("Dashboard counts", top: 24)
            // Sites need the window title, which only the direct build reads.
            Caption("The dashboard keeps its own daily tallies in usage.json next to History: per day, how many dictations and words, seconds spoken, the turnaround, AI edits kept, texts read aloud, and dictations per app (the app's name only\(Distribution.isDirect ? "; in a browser, also the site's name, such as Gmail" : "")). Never any text, audio or window titles. They stay when you delete History or turn it off.")
            Button("Reset dashboard counts…") { confirmReset = true }.buttonStyle(.quiet).padding(.top, 8)
        }
        .onAppear { size = model.historySizeBytes }
        .onChange(of: model.history) { size = model.historySizeBytes }
        .onChange(of: model.settings.saveHistoryAudio) { changed() }
        // Windows' MessageBoxes: titled Oberton, Yes and No.
        .alert("Oberton", isPresented: Binding(get: { shorter != nil }, set: { if !$0 { shorter = nil } })) {
            Button("Yes") {
                if let keep = shorter?.keep { setText(keep) }
                shorter = nil
            }
            Button("No", role: .cancel) { shorter = nil }
        } message: {
            Text(shorter.map { "This deletes \($0.gone) older dictation\($0.gone == 1 ? "" : "s") from History right away, with \($0.gone == 1 ? "its recording" : "their recordings"). Go ahead?" } ?? "")
        }
        .dialogLook(.question, shown: shorter != nil)
        .alert("Oberton", isPresented: $confirmClear) {
            Button("Yes") { model.clearHistory(); size = model.historySizeBytes }
            Button("No", role: .cancel) {}
        } message: { Text("Delete every dictation in History, with its recording? This can't be undone.") }
        .dialogLook(.warning, shown: confirmClear)
        .alert("Oberton", isPresented: $confirmResetTally) {
            Button("Yes") { model.resetWordTally() }
            Button("No", role: .cancel) {}
        } message: { Text("Reset the Analytics word tally (words, phrases, corrections, fillers, hours, profiles)? History and the dashboard counts are not touched.") }
        .dialogLook(.question, shown: confirmResetTally)
        .alert("Oberton", isPresented: $confirmReset) {
            Button("Yes") { model.resetUsage() }
            Button("No", role: .cancel) {}
        } message: { Text("Reset the dashboard's daily counts (words per day, streaks, apps)? History itself is not touched.") }
        .dialogLook(.question, shown: confirmReset)
    }

    /// "{mb:0.#}": one decimal at most, none when it is .0, in the region's decimal separator.
    static func megabytes(_ bytes: Int64) -> String { NetNumber.fixed(Double(bytes) / 1_048_576, digits: 1, optional: true) }

    /// The folder as Windows shows it (Path.Combine): no separator at its end.
    static func folderText(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// A FieldLabel with the top margin the Windows page gives it.
    private func label(_ text: String, top: CGFloat) -> some View {
        Text(text.uppercased()).font(Ob.mono(12, .bold)).foregroundStyle(ob.ink).padding(.top, top).padding(.bottom, 6)
    }

    private func row<C: View>(_ title: String, detail: String, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Ob.sans(Ob.body)).foregroundStyle(ob.ink)
                Text(detail).font(Ob.sans(12)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 16)
            control()
        }
    }

    /// Text kept for less time than now deletes dictations right away: say how many first (ConfirmShorter).
    private func chooseText(_ keep: Keep) {
        let gone = keep.count > 0 || keep.days > 0 ? model.historyWouldDelete(limit: keep.count, days: keep.days) : 0
        if gone > 0 { shorter = (keep, gone) } else { setText(keep) }
    }

    private func setText(_ keep: Keep) {
        model.settings.historyLimit = keep.count
        model.settings.historyDays = keep.days
        changed()
    }

    /// A lower keep applies right away.
    private func changed() {
        model.pruneHistory()
        size = model.historySizeBytes
    }
}

/// A keep box: everything (text) or as long as the text (recordings), then THE NEWEST and FROM THE LAST under headings
/// (HistorySettingsPage.FillKeep), a stock Fluent ComboBox as `ObMenu` draws it: 240 wide, Windows' list below the box,
/// the headings greyed items in Cascadia Mono 10 with 4 above that can't be chosen. As Windows' list, built once per
/// page: a value outside the usual ones that was saved when the page opened stays in the list after another is chosen.
/// On the Mac it is a Tab stop; ↑/↓ step a closed box to the next choice (each step is a choice, as a ComboBox's
/// SelectionChanged), skipping the headings; Alt+↓ / F4 / Space / Return open it; in the open list ↑/↓ move, Return
/// takes, Esc closes. No hand cursor: the page leaves WPF's ComboBox its arrow.
private struct KeepMenu: View {
    var audio: Bool
    @Binding var selection: HistorySettingsSection.Keep
    /// A choice waiting for "Go ahead?": shown in the box meanwhile, as Windows' combo has already taken it.
    var pending: HistorySettingsSection.Keep?
    var name: String
    @Environment(\.ob) private var ob
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused
    @State private var keyFocused = false
    @State private var hover = false
    @State private var open = false
    @State private var highlighted: Int?
    /// What was saved when the page opened (FillKeep's `count` and `days`).
    @State private var opened: HistorySettingsSection.Keep?

    private typealias Keep = HistorySettingsSection.Keep

    /// One line of the list: a choice, or a heading.
    private enum Entry: Hashable {
        case keep(Keep)
        case heading(String)
        var keep: Keep? { if case .keep(let k) = self { k } else { nil } }
    }

    private var start: Keep { opened ?? selection }
    private var counts: [Int] { Array(Set([10, 25, 50, 100, 200, 500] + (start.count > 0 ? [start.count] : []))).sorted() }
    private var ages: [Int] { Array(Set([1, 3, 7, 14, 30, 90, 365] + (start.days > 0 ? [start.days] : []))).sorted() }
    private var first: String { audio ? "As long as the text" : "Everything (never delete)" }

    private var entries: [Entry] {
        [.keep(Keep()), .heading("THE NEWEST")] + counts.map { .keep(Keep(count: $0)) }
            + [.heading("FROM THE LAST")] + ages.map { .keep(Keep(days: $0)) }
    }

    /// The item the box shows: the one that matches (a hand-edited file keeping both by number and by age matches
    /// none, so the first, as Windows' `?? box.Items[0]`).
    private var shown: Keep {
        let k = pending ?? selection
        return k.count > 0 && k.days > 0 ? Keep() : k
    }

    private func label(_ k: Keep) -> String {
        k.count > 0 ? "The newest \(k.count) dictations" : k.days > 0 ? "The last \(HistoryStore.daysLabel(k.days))" : first
    }

    /// Picking the item already shown changes nothing (no SelectionChanged).
    private func choose(_ k: Keep) { if k != shown { selection = k } }

    var body: some View {
        #if os(macOS)
        Button { toggle() } label: { face }
            .buttonStyle(.plain)
            .focused($focused)
            .tabStop(focused: $keyFocused) { activate() }
            .onKeyPress(keys: [.upArrow, .downArrow, .escape, .return, .space, KeyEquivalent(Character(UnicodeScalar(NSF4FunctionKey)!))]) { press in
                key(press)
            }
            .background { if !PageScroll<EmptyView>.flat { DropDownPanel(isPresented: $open, maxHeight: nil) { list } } }
            .onHover { hover = $0 }
            .fixedSize()
            // A ComboBox reads its name and the item shown.
            .accessibilityLabel(name)
            .accessibilityValue(label(shown))
            .onAppear { if opened == nil { opened = selection } }
            .onChange(of: enabled) { _, on in if !on { open = false } }
        #else
        Menu {
            item(Keep())
            SwiftUI.Section("THE NEWEST") { ForEach(counts, id: \.self) { item(Keep(count: $0)) } }
            SwiftUI.Section("FROM THE LAST") { ForEach(ages, id: \.self) { item(Keep(days: $0)) } }
        } label: { face }
            .focused($focused)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(name)
            .accessibilityValue(label(shown))
            .onAppear { if opened == nil { opened = selection } }
        #endif
    }

    #if os(iOS)
    private func item(_ k: Keep) -> some View {
        Button { choose(k) } label: {
            if k == shown { Label(label(k), systemImage: "checkmark") } else { Text(label(k)) }
        }
    }
    #endif

    /// ObMenu's face at the page's Width 240: 14 pt, Padding 12,5,0,7 inside the 1 px edge, the chevron 10 from the
    /// right, at least 32 tall.
    private var face: some View {
        HStack(spacing: 0) {
            Text(label(shown)).font(Ob.sans(14)).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .regular)).foregroundStyle(ob.ink.opacity(enabled ? 0.62 : 0.36))
                .padding(.trailing, 10)
        }
        // Disabled (Recordings with the recordings switch off): Fluent's TextFillColorDisabled.
        .foregroundStyle(ob.ink.opacity(enabled ? 1 : 0.36))
        .padding(EdgeInsets(top: 5 + Ob.border, leading: 12 + Ob.border, bottom: 7 + Ob.border, trailing: Ob.border))
        // Width 240, wider when the choice needs it.
        .frame(minWidth: 240)
        .frame(minHeight: 32)
        .background { FluentComboFace(hover: hover || open, focused: focused || keyFocused) }
        .contentShape(Rectangle())
    }

    #if os(macOS)
    /// The choices' places in `entries` (the headings can't be chosen, by click or by key).
    private var choices: [Int] { entries.indices.filter { entries[$0].keep != nil } }
    private var index: Int? { entries.firstIndex(of: .keep(shown)) }

    private func toggle() {
        highlighted = index
        open.toggle()
    }

    private func activate() {
        if open, let h = highlighted, let k = entries[safe: h]?.keep { choose(k) }
        if open { open = false } else { toggle() }
    }

    /// The next choice from `from` in `step`'s direction, past headings; nil at the end.
    private func next(from: Int?, _ step: Int) -> Int? {
        guard let from else { return choices.first }
        return step > 0 ? choices.first { $0 > from } : choices.last { $0 < from }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        let f4 = press.key == KeyEquivalent(Character(UnicodeScalar(NSF4FunctionKey)!))
        if open {
            switch press.key {
            case .upArrow: highlighted = next(from: highlighted ?? index, -1) ?? highlighted ?? index
            case .downArrow: highlighted = next(from: highlighted ?? index, 1) ?? highlighted ?? index
            case .return, .space:
                if let h = highlighted, let k = entries[safe: h]?.keep { choose(k) }
                open = false
            case .escape: open = false
            default: if f4 { open = false } else { return .ignored }
            }
            return .handled
        }
        if press.key == .downArrow && press.modifiers.contains(.option) || f4 || press.key == .space || press.key == .return {
            toggle()
            return .handled
        }
        switch press.key {
        case .upArrow: if let i = next(from: index, -1), let k = entries[i].keep { choose(k) }
        case .downArrow: if let i = next(from: index, 1), let k = entries[i].keep { choose(k) }
        default: return .ignored
        }
        return .handled
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { i, entry in
                        switch entry {
                        case .keep(let k):
                            DropDownRow(text: label(k), chosen: k == shown, highlighted: highlighted == i) {
                                choose(k)
                                open = false
                            }
                            .id(i)
                        case .heading(let text):
                            // A disabled ComboBoxItem: FontSize 10, Cascadia Mono, Margin 0,4,0,0 (in place of the
                            // item's own 5,2), in Fluent's disabled text colour; not hit by the pointer.
                            Text(text).font(Ob.mono(10)).foregroundStyle(ob.ink.opacity(0.36)).fixedSize(horizontal: false, vertical: true)
                                .padding(EdgeInsets(top: 5, leading: 11, bottom: 7, trailing: 11))
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                .padding(.top, 4)
                                .allowsHitTesting(false)
                                .accessibilityAddTraits(.isHeader)
                                .id(i)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear { if let i = index { proxy.scrollTo(i, anchor: .center) } }
            .onChange(of: highlighted) { _, h in if let h { proxy.scrollTo(h) } }
        }
        .environment(\.ob, ob)
    }
    #endif
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
