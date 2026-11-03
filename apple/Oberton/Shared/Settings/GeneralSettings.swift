import ObertonCore
import SwiftUI

// MARK: - A // Dictation

struct GeneralSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Everything runs on this \(Device.noun). No audio or text is sent anywhere unless you allow cloud AI (Settings › Cloud AI), and there is no telemetry.")
                .padding(.bottom, 16)
            #if os(macOS)
            SwitchCard {
                ObSwitch("Put my clipboard back after inserting",
                         detail: "Oberton pastes the text at the cursor, then puts back what you had copied.", isOn: $model.settings.restoreClipboard)
            }
            #endif
            FieldLabel("Maximum length of one dictation (minutes)")
            HStack(spacing: 10) {
                Button("−") { model.settings.maxRecordingSeconds = max(60, model.settings.maxRecordingSeconds - 60) }.buttonStyle(.quiet)
                Text("\(Int(model.settings.maxRecordingSeconds / 60))").font(Ob.mono(14, .bold)).frame(width: 40)
                Button("+") { model.settings.maxRecordingSeconds = min(3600, model.settings.maxRecordingSeconds + 60) }.buttonStyle(.quiet)
            }
        }
    }
}
