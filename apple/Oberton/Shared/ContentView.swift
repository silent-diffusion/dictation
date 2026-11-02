import ObertonCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable, Hashable {
    case dashboard, profiles, readAloud, history, settings
    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .profiles: "Speech to text"
        case .readAloud: "Read aloud"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .profiles: "waveform.and.mic"
        case .readAloud: "speaker.wave.2"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var page: Page? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                NavigationLink(value: p) { Label(p.title, systemImage: p.symbol) }
            }
            .navigationTitle("Oberton")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            #endif
        } detail: {
            NavigationStack {
                switch page ?? .dashboard {
                case .dashboard: DashboardView()
                case .profiles: ProfilesView()
                case .readAloud: ReadAloudView()
                case .history: HistoryView()
                case .settings: SettingsView()
                }
            }
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                signalPath
                dictateCard
                if let pending = model.pending { previewCard(pending) }
                PlayerView(player: model.reader) // shows itself only while reading
                todayCard
                if let last = model.lastEntry {
                    VStack(alignment: .leading, spacing: 8) {
                        PanelLabel(title: "Last dictation", japanese: "履歴")
                        ReceiptView(entry: last)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Dashboard")
    }

    /// MIC → SPEECH → AI → INSERT, each step lit while it works.
    private var signalPath: some View {
        let phase = model.phase
        let profile = model.activeProfile
        return VStack(alignment: .leading, spacing: 8) {
            PanelLabel(title: "Signal path", japanese: "計器")
            ViewThatFits {
                HStack(spacing: 6) { steps(phase: phase, profile: profile, arrows: true) }
                VStack(alignment: .leading, spacing: 6) { steps(phase: phase, profile: profile, arrows: false) }
            }
        }
    }

    @ViewBuilder
    private func steps(phase: AppModel.Phase, profile: Profile, arrows: Bool) -> some View {
        Step(name: "Mic", detail: "Microphone", lit: phase == .recording)
        if arrows { Image(systemName: "arrow.right").foregroundStyle(.tertiary) }
        Step(name: "Speech", detail: "Apple Speech (on-device)", lit: phase == .recording || phase == .transcribing)
        if arrows { Image(systemName: "arrow.right").foregroundStyle(.tertiary) }
        Step(name: "AI", detail: profile.isRaw ? "Off (Raw)" : model.processor.model(for: profile).displayName, lit: phase == .processing)
        if arrows { Image(systemName: "arrow.right").foregroundStyle(.tertiary) }
        Step(name: "Insert", detail: insertDetail, lit: phase == .inserting)
    }

    private var insertDetail: String {
        #if os(macOS)
        "At the cursor"
        #else
        "Clipboard"
        #endif
    }

    private var dictateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PanelLabel(title: "Dictate", japanese: "口述")
                Spacer()
                Picker("Profile", selection: Binding(get: { model.activeProfile.id }, set: { id in
                    if let p = model.profiles.first(where: { $0.id == id }) { model.activeProfile = p }
                })) {
                    ForEach(model.profiles) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack(spacing: 14) {
                Button {
                    model.toggleDictation()
                } label: {
                    Image(systemName: model.phase == .recording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(model.phase == .recording ? .red : .accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.phase == .recording ? "Stop dictating" : "Start dictating")
                .disabled(model.phase.isBusy && model.phase != .recording)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.phase.label).font(.headline)
                    if model.phase == .recording { LevelMeter(level: model.level) }
                    #if os(macOS)
                    Text("Or press \(model.settings.hotkey) in any app.").font(.caption).foregroundStyle(.secondary)
                    #endif
                }
                Spacer()
                if model.phase.isBusy { Button("Cancel", role: .cancel) { model.cancel() } }
            }
            if !model.liveText.isEmpty && model.phase.isBusy {
                Text(model.liveText).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    private func previewCard(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelLabel(title: "Preview")
            ReceiptView(entry: entry, focusInserted: true)
            HStack {
                Button("Insert") { model.confirmPreview() }.keyboardShortcut(.defaultAction)
                Button("Use original") { model.confirmPreview(useOriginal: true) }
                Button("Discard", role: .cancel) { model.cancel() }
            }
        }
    }

    private var todayCard: some View {
        let today = model.history.filter { Calendar.current.isDateInToday($0.date) }
        let words = today.reduce(0) { $0 + $1.words }
        let spoken = today.reduce(0) { $0 + $1.seconds }
        let saved = Double(words) / Double(max(model.settings.typingWPM, 1)) * 60 - spoken
        return HStack(spacing: 0) {
            Meter(title: "Words today", value: "\(words)")
            Meter(title: "Dictations", value: "\(today.count)")
            Meter(title: "Time saved", value: saved > 0 ? Duration.seconds(saved).formatted(.units(allowed: [.hours, .minutes], width: .narrow)) : "–")
        }
    }
}

private struct Step: View {
    var name: String
    var detail: String
    var lit: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(lit ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 8, height: 8)
                Text(name.uppercased()).font(.system(.caption, design: .monospaced).weight(.semibold))
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .frame(minWidth: 110, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(lit ? Color.accentColor : Color.secondary.opacity(0.3)))
        .animation(.easeInOut(duration: 0.2), value: lit)
    }
}

private struct Meter: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelLabel(title: title)
            Text(value).font(.system(.title, design: .monospaced).weight(.medium)).foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
