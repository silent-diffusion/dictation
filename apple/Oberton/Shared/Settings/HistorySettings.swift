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
            Caption("Recent dictations are kept on this \(Device.noun) with everything about them: the recording, the transcription, the AI's output and what was inserted where. They are stored in Oberton's data folder, which app updates never touch.", size: 12.5)
            SwitchCard {
                ObSwitch("Keep a history of dictations", isOn: $model.settings.keepHistory)
                ObSwitch("Keep the recordings", detail: "So you can play a dictation back. About 2 MB per minute of speech.",
                         isOn: $model.settings.saveHistoryAudio)
            }
            .padding(.top, 8)
            FieldLabel("How long to keep")
            VStack(spacing: 0) {
                row("Text", detail: "The dictation itself: what was heard, the AI's edit, and where it went.") {
                    KeepMenu(audio: false, selection: Binding(get: { Keep(count: model.settings.historyLimit, days: model.settings.historyDays) },
                                                              set: chooseText))
                }
                Hairline()
                row("Recordings", detail: "The audio, for playing a dictation back. Never kept longer than its text.") {
                    KeepMenu(audio: true, selection: Binding(get: { Keep(count: model.settings.audioLimit, days: model.settings.audioDays) },
                                                             set: { model.settings.audioLimit = $0.count; model.settings.audioDays = $0.days; changed() }))
                        .disabled(!model.settings.saveHistoryAudio)
                }
            }
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
            Caption("Keep a number of the newest, or everything from a recent stretch of time. Older ones are deleted as new ones come in, every hour, and right away when you choose less. A recording deleted this way leaves its dictation's text in History.", size: 12.5)
                .padding(.top, 6)
            FieldLabel("Stored in")
            Text(model.historyFolder.path(percentEncoded: false)).font(Ob.mono(12)).textSelection(.enabled)
            Caption("\(model.history.count) dictations, \(String(format: "%.1f", Double(size) / 1_048_576).replacingOccurrences(of: ".0", with: "")) MB.", size: 12.5)
                .padding(.top, 4)
            HStack(spacing: 8) {
                #if os(macOS)
                Button("Open folder") {
                    try? FileManager.default.createDirectory(at: model.historyFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.historyFolder)
                }
                .buttonStyle(.quiet)
                #endif
                Button("Delete all history…") { confirmClear = true }.buttonStyle(.quiet).disabled(model.history.isEmpty)
            }
            .padding(.top, 8)
            FieldLabel("Analytics word tally")
            SwitchCard {
                ObSwitch("Count the words I dictate, for Analytics",
                         detail: "After each dictation: the words and phrases that went in, the words the AI corrected and the fillers it took out, the hour, and how much the profile changed. Counts only, never sentences, kept in words.json next to History.",
                         isOn: $model.settings.keepWordTally)
            }
            Button("Reset word tally…") { confirmResetTally = true }.buttonStyle(.quiet).padding(.top, 8)
                .disabled(model.words.days.isEmpty)
            FieldLabel("Dashboard counts")
            // Windows also counts the web site in a browser; the Mac can't read it in the sandbox, so that part is left out.
            Caption("The dashboard keeps its own daily tallies in usage.json next to History: per day, how many dictations and words, seconds spoken, the turnaround, AI edits kept, texts read aloud, and dictations per app (the app's name only). Never any text, audio or window titles. They stay when you delete History or turn it off.", size: 12.5)
            Button("Reset dashboard counts…") { confirmReset = true }.buttonStyle(.quiet).padding(.top, 8)
        }
        .onAppear { size = model.historySizeBytes }
        .onChange(of: model.history) { size = model.historySizeBytes }
        .onChange(of: model.settings.saveHistoryAudio) { changed() }
        .confirmationDialog(shorter.map { "This deletes \($0.gone) older dictation\($0.gone == 1 ? "" : "s") from History right away, with \($0.gone == 1 ? "its recording" : "their recordings"). Go ahead?" } ?? "",
                            isPresented: Binding(get: { shorter != nil }, set: { if !$0 { shorter = nil } }), titleVisibility: .visible) {
            Button("Delete them", role: .destructive) {
                if let keep = shorter?.keep { setText(keep) }
                shorter = nil
            }
        }
        .confirmationDialog("Delete every dictation in History, with its recording? This can't be undone.", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all history", role: .destructive) { model.clearHistory() }
        }
        .confirmationDialog("Reset the dashboard's daily counts (words per day, streaks, apps)? History itself is not touched.",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset counts", role: .destructive) { model.resetUsage() }
        }
        .confirmationDialog("Reset the Analytics word tally (words, phrases, corrections, fillers, hours, profiles)? History and the dashboard counts are not touched.",
                            isPresented: $confirmResetTally, titleVisibility: .visible) {
            Button("Reset word tally", role: .destructive) { model.resetWordTally() }
        }
    }

    private func row<C: View>(_ title: String, detail: String, @ViewBuilder control: () -> C) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Ob.sans(13.5))
                Caption(detail, size: 12)
            }
            Spacer(minLength: 16)
            control()
        }
        .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
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
/// (HistorySettingsPage.FillKeep). Drawn like `ObMenu`.
private struct KeepMenu: View {
    var audio: Bool
    @Binding var selection: HistorySettingsSection.Keep
    @Environment(\.ob) private var ob
    @Environment(\.isEnabled) private var enabled

    private typealias Keep = HistorySettingsSection.Keep

    private var counts: [Int] { Array(Set([10, 25, 50, 100, 200, 500] + (selection.count > 0 ? [selection.count] : []))).sorted() }
    private var ages: [Int] { Array(Set([1, 3, 7, 14, 30, 90, 365] + (selection.days > 0 ? [selection.days] : []))).sorted() }
    private var first: String { audio ? "As long as the text" : "Everything (never delete)" }

    private func label(_ k: Keep) -> String {
        k.count > 0 ? "The newest \(k.count) dictations" : k.days > 0 ? "The last \(HistoryStore.daysLabel(k.days))" : first
    }

    var body: some View {
        Menu {
            item(Keep())
            SwiftUI.Section("The newest") { ForEach(counts, id: \.self) { item(Keep(count: $0)) } }
            SwiftUI.Section("From the last") { ForEach(ages, id: \.self) { item(Keep(days: $0)) } }
        } label: {
            HStack {
                Text(label(selection)).font(Ob.sans(13.5)).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(ob.muted)
            }
            .foregroundStyle(ob.ink)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(width: 240)
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func item(_ k: Keep) -> some View {
        Button { selection = k } label: {
            if k == selection { Label(label(k), systemImage: "checkmark") } else { Text(label(k)) }
        }
    }
}
