import ObertonCore
import SwiftUI

struct SpeechSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Apple's speech recognizer, on this \(Device.noun). The first time you dictate in a language, the system downloads it once.")
            Text(model.speechStatus).font(Ob.sans(13.5, .semibold)).foregroundStyle(model.speechOK ? ob.ink : ob.accent)
                .padding(.top, 8)
            FieldLabel("Engine")
            Text("Apple Speech (SpeechAnalyzer)").font(Ob.sans(13.5))
            FieldLabel("Language")
            ObMenu(options: ["en-US", "en-GB", "en-AU", "en-IN", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR", "ja-JP", "zh-CN", "ko-KR"]
                .map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }, selection: $model.settings.language, width: 260)
            FieldLabel("Quiet speech")
            SwitchCard {
                // Windows also applies this to Extended Notes; on the Mac, Extended Notes records through its own analyzer.
                ObSwitch("Even out the volume before transcribing",
                         detail: "Brings quiet stretches up to the level of the rest, so a quiet microphone or turning away from it doesn't lose whole sentences. Silence still gives nothing. On by default; applies to dictation.",
                         isOn: $model.settings.evenOutVolume)
            }
            .frame(maxWidth: 560)
            FieldLabel("Vocabulary hint")
            ObField("Kubernetes, Dr. Nguyen, Oberton", text: $model.settings.vocabularyHint).frame(maxWidth: 560)
            Caption("Names and words the recognizer should expect, separated by commas.", size: 12.5).padding(.top, 6)
        }
    }
}
