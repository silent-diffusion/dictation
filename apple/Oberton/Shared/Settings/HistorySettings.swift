import ObertonCore
import SwiftUI

struct HistorySettingsSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @State private var confirmClear = false
    @State private var confirmReset = false
    @State private var confirmResetTally = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SwitchCard {
                ObSwitch("Keep a history of dictations", detail: "What was heard, the AI's edit, and where it went. On this \(Device.noun) only.",
                         isOn: $model.settings.keepHistory)
            }
            FieldLabel("How long to keep")
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Text").font(Ob.sans(13.5))
                    Caption("The dictation itself: what was heard, the AI's edit, and where it went.", size: 12)
                }
                Spacer()
                ObMenu(options: [(0, "Everything (never delete)")] + [10, 25, 50, 100, 200, 500].map { ($0, "The newest \($0)") },
                       selection: $model.settings.historyLimit, width: 240)
            }
            .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
            FieldLabel("Stored in")
            Text(AppPaths.dataDir.path(percentEncoded: false)).font(Ob.mono(12)).textSelection(.enabled)
            HStack(spacing: 8) {
                #if os(macOS)
                Button("Open folder") { NSWorkspace.shared.open(AppPaths.dataDir) }.buttonStyle(.quiet)
                #endif
                Button("Delete all history…") { confirmClear = true }.buttonStyle(.quiet).disabled(model.history.isEmpty)
            }
            .padding(.top, 10)
            FieldLabel("Dashboard counts")
            Caption("The meters on the dashboard come from daily counts (numbers only, never text), so they survive History being cleared.", size: 12.5)
            Button("Reset dashboard counts…") { confirmReset = true }.buttonStyle(.quiet).padding(.top, 10)
            FieldLabel("Word tally")
            SwitchCard {
                ObSwitch("Keep a word tally for Analytics",
                         detail: "Counts of the words and phrases you dictate, the words the AI corrects and the fillers it removes, saved in words.json. Counts only, never sentences.",
                         isOn: $model.settings.keepWordTally)
            }
            Button("Reset word tally…") { confirmResetTally = true }.buttonStyle(.quiet).padding(.top, 10)
                .disabled(model.words.days.isEmpty)
        }
        .confirmationDialog("Delete every dictation in History?", isPresented: $confirmClear) {
            Button("Delete all history", role: .destructive) { model.clearHistory() }
        }
        .confirmationDialog("Reset the dashboard counts?", isPresented: $confirmReset) {
            Button("Reset counts", role: .destructive) { model.resetUsage() }
        }
        .confirmationDialog("Forget every word, phrase and correction counted for Analytics?", isPresented: $confirmResetTally) {
            Button("Reset word tally", role: .destructive) { model.resetWordTally() }
        }
    }
}
