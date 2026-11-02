import ObertonCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var byApp = false

    var body: some View {
        List {
            if model.history.isEmpty {
                ContentUnavailableView("No dictations yet", systemImage: "clock",
                                       description: Text("Your last \(model.settings.historyLimit) dictations are kept here, on this device."))
            } else if byApp {
                ForEach(groups, id: \.0) { app, entries in
                    Section(app) { ForEach(entries) { row($0) } }
                }
            } else {
                ForEach(model.history) { row($0) }
                    .onDelete { model.deleteHistory(Set($0.map { model.history[$0].id })) }
            }
        }
        .navigationTitle("History")
        .navigationDestination(for: HistoryEntry.self) { entry in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened) + " · " + entry.profileName + (entry.appName.map { " · " + $0 } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    ReceiptView(entry: entry)
                    Button("Read aloud") { model.reader.read(entry.inserted, voice: model.settings.ttsVoice, speed: model.settings.ttsBaseSpeed) }
                }
                .padding()
            }
            .navigationTitle("Dictation")
        }
        .toolbar {
            Picker("Group", selection: $byApp) {
                Text("Newest first").tag(false)
                Text("By app").tag(true)
            }
            .pickerStyle(.segmented)
            Button("Clear", role: .destructive) { model.clearHistory() }.disabled(model.history.isEmpty)
        }
    }

    private var groups: [(String, [HistoryEntry])] {
        Dictionary(grouping: model.history) { $0.appName ?? "Other" }
            .map { ($0.key, $0.value) }
            .sorted { $0.1[0].date > $1.1[0].date }
    }

    private func row(_ e: HistoryEntry) -> some View {
        NavigationLink(value: e) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.inserted).lineLimit(2)
                Text("\(e.date.formatted(.relative(presentation: .named))) · \(e.words) words · \(e.profileName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
