import ObertonCore
import SwiftUI

/// HISTORY 履歴: the list at the left (newest first, or by app), the chosen dictation at the right (HistoryPage.xaml).
struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var byApp = false
    @State private var folded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "History", japanese: "履歴", readout: "Dictations // on this \(Device.noun)")
            HStack(alignment: .center) {
                Caption(countLine, size: 12.5)
                Spacer()
                Readout("Show")
                ObMenu(options: [(false, "Newest first"), (true, "By app, newest first")], selection: $byApp, width: 230)
            }
            .padding(.top, 12).padding(.bottom, 14)
            if sizeClass == .compact {
                if let entry = selected, nav.place.historyID != nil { PageScroll { HistoryDetail(entry: entry) } } else { list }
            } else {
                HStack(alignment: .top, spacing: 20) {
                    list.frame(width: 320)
                    PageScroll {
                        if let entry = selected { HistoryDetail(entry: entry) }
                    }
                }
            }
        }
        .padding(sizeClass == .compact ? EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16) : EdgeInsets(top: 28, leading: 32, bottom: 24, trailing: 32))
    }

    private var selected: HistoryEntry? {
        model.history.first { $0.id == nav.place.historyID } ?? (sizeClass == .compact ? nil : model.history.first)
    }

    private var countLine: String {
        model.history.isEmpty ? "Nothing here yet. Your dictations appear here."
            : "\(model.history.count) of the last \(model.settings.historyLimit) dictations, kept on this \(Device.noun). Change how many under Settings › History."
    }

    private var list: some View {
        PageScroll {
            LazyVStack(spacing: 0) {
                if byApp {
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
        Dictionary(grouping: model.history) { $0.appName ?? "Other" }.map { ($0.key, $0.value) }.sorted { $0.1[0].date > $1.1[0].date }
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
                    Readout(([HistoryEntry.when(entry.date)] + (entry.appName.map { [$0] } ?? [])).joined(separator: "  ·  "))
                    Spacer()
                    Readout(HistoryEntry.duration(entry.seconds))
                }
                Text(entry.inserted.count > 120 ? String(entry.inserted.prefix(120)) + "…" : entry.inserted)
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

struct HistoryDetail: View {
    var entry: HistoryEntry
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.date.formatted(.dateTime.weekday(.wide).day().month(.wide)) + ", " + entry.date.formatted(date: .omitted, time: .shortened))
                        .font(Ob.mono(16, .bold))
                    Caption(entry.appName.map { "Inserted into \($0)" } ?? "Inserted", size: 12.5)
                    Caption("Profile: \(entry.profileName) · \(HistoryEntry.duration(entry.seconds)) of speech", size: 12.5)
                }
                Spacer()
                Button("Read aloud") { model.reader.read(entry.inserted, voice: model.settings.ttsVoice, speed: model.settings.ttsBaseSpeed) }
                    .buttonStyle(.quiet)
                Button("Delete") { model.deleteHistory([entry.id]) }.buttonStyle(.quiet)
            }
            ThreeBoxes(transcription: entry.transcription, aiEdit: entry.aiEdit, inserted: entry.inserted,
                       safetyNet: entry.aiEdit != nil && entry.aiEdit == entry.transcription && entry.warning != nil)
                .padding(.top, 16)
            if let warning = entry.warning { Caption(warning, size: 12.5).padding(.top, 10) }
            #if os(macOS)
            HStack(spacing: 12) {
                Button("Insert transcription into the last app") {
                    Task { note = await model.insertIntoLastApp(entry.transcription) }
                }
                .buttonStyle(.quiet)
                if let note { Caption(note, size: 12) }
            }
            .padding(.top, 14)
            #endif
        }
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

    static func duration(_ s: Double) -> String {
        s < 60 ? "\(Int(s.rounded())) s" : String(format: "%d:%02d min", Int(s) / 60, Int(s) % 60)
    }
}
