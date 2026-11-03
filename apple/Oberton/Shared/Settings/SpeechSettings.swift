import ObertonCore
import SwiftUI

struct SpeechSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Speech is transcribed on this \(Device.noun): by Apple's speech recognizer, which downloads each language once through the system, or by a Whisper model you download here. A change applies at once.")
            Text(model.speechStatus).font(Ob.sans(13.5, .semibold)).foregroundStyle(model.speechOK ? ob.ink : ob.accent)
                .padding(.top, 8)
            FieldLabel("Model")
            SpeechModelList().frame(maxWidth: 640)
            FieldLabel("Language")
            ObMenu(options: [("", "Auto-detect")] + ["en-US", "en-GB", "en-AU", "en-IN", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR", "ja-JP", "zh-CN", "ko-KR"]
                .map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }, selection: $model.settings.language, width: 260)
            Caption(languageNote, size: 12.5).padding(.top, 6).frame(maxWidth: 560, alignment: .leading)
            FieldLabel("Quiet speech")
            SwitchCard {
                // Windows also applies this to Extended Notes; on the Mac, Extended Notes records through its own path.
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

    /// Windows: "Leave empty to auto-detect (slightly slower, less reliable for short phrases)."
    private var languageNote: String {
        if let id = model.settings.whisperModel, WhisperModels.model(id)?.englishOnly == true {
            return "\(WhisperModels.name(of: id)) hears only English, so this applies to Apple Speech and the multilingual Whisper models."
        }
        return "Auto-detect works with the multilingual Whisper models (slightly slower, less reliable for short phrases); Apple Speech then uses this \(Device.noun)'s language."
    }
}

/// The speech models as rows, on Settings › Speech recognition and Models (ModelsPage.xaml.cs's SpeechList): Apple
/// Speech, then Windows' Whisper models with ACTIVE / LOADED / DOWNLOADED, Download (progress, Cancel) and Use this.
struct SpeechModelList: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let apple = model.settings.whisperModel == nil
            ModelRow(name: "Apple Speech",
                     badges: (apple ? [("Active", .active)] : []) + (apple && LiveTranscriber.modelRetained ? [("Loaded", .ok)] : []) + [("Installed", .plain)],
                     detail: "Apple's on-device speech recognizer. Downloads its language once, through the system.",
                     action: apple ? nil : ("Use this", { model.useSpeechModel("") }))
            ForEach(WhisperModels.all) { row($0) }
            if let error = model.whisperDownloadError {
                Text(error).font(Ob.sans(12.5)).foregroundStyle(ob.accent).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ m: WhisperModel) -> some View {
        let downloaded = WhisperModels.isDownloaded(m.id)
        let active = model.settings.speechModel == m.id
        let runs = WhisperModels.runsHere(m.id)
        let fetching = model.whisperDownload?.id == m.id
        var badges: [(String, Badge.Kind)] = []
        if active { badges.append(("Active", .active)) }
        if active && WhisperEngine.loadedModel == m.id { badges.append(("Loaded", .ok)) }
        badges.append(downloaded ? ("Downloaded", .plain) : ("Not downloaded", .outline))
        if !runs && !downloaded { badges.append(("Too big for this \(Device.noun)", .outline)) }
        let action: (String, () -> Void)? =
            fetching ? ("Cancel", { model.cancelWhisperDownload() })
            : !downloaded ? (runs && model.whisperDownload == nil ? ("Download", { model.downloadWhisper(m.id) }) : nil)
            : active ? nil : ("Use this", { model.useSpeechModel(m.id) })
        return ModelRow(name: m.name, badges: badges, detail: "\(m.description) · \(m.size)", action: action,
                        progress: fetching ? .some(model.whisperDownload?.fraction) : nil)
    }
}
