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
            if let load = model.whisperLoad { LoadClock(load: load).padding(.top, 4) }
            FieldLabel("Model")
            SpeechModelList().frame(maxWidth: 640)
            FieldLabel("Language")
            ObMenu(options: [("", "Auto-detect")] + ["en-US", "en-GB", "en-AU", "en-IN", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR", "ja-JP", "zh-CN", "ko-KR"]
                .map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }, selection: $model.settings.language, width: 260)
            Caption(languageNote, bottom: 0).padding(.top, 4).frame(maxWidth: 560, alignment: .leading)
            FieldLabel("Quiet speech")
            // A bare switch on the page, as Windows' (no card around it).
            ObSwitch("Even out the volume before transcribing",
                     detail: "Brings quiet stretches up to the level of the rest, and finds the words by how far they stand above the room's background noise, so a quiet microphone or turning away from it doesn't lose whole sentences. Silence still gives nothing. On by default; applies to dictation and Extended Notes.",
                     isOn: $model.settings.evenOutVolume)
                .frame(maxWidth: 560)
            FieldLabel("Vocabulary hint")
            // Taken when the box is left (Windows' LostFocus binding), not on every keystroke.
            CommitField(value: $model.settings.vocabularyHint).frame(maxWidth: 560).accessibilityLabel("Vocabulary hint")
            Caption("Optional names and jargon to bias recognition, e.g. Kubernetes, Dr. Nguyen, Acme Corp.", bottom: 0).padding(.top, 4)
            // Loads the speech model again now: a change already applies at once, but a model that failed to load can be
            // retried here (Windows' save-and-restart button).
            Button("Apply and restart speech engine") { model.warmUp() }
                .buttonStyle(.quiet).padding(.top, 16)
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
                     action: apple ? nil : ("Use this", { model.useSpeechModel("") }), primary: true, enabled: model.whisperDownload == nil)
            ForEach(WhisperModels.all) { row($0) }
        }
        // A failed download is a message box on Windows, with its own words or "The download failed. See the log…".
        .alert("Oberton", isPresented: Binding(get: { model.whisperDownloadError != nil }, set: { if !$0 { model.whisperDownloadError = nil } })) {
            Button("OK") {}
        } message: { Text(model.whisperDownloadError ?? "") }
        .dialogLook(.warning, shown: model.whisperDownloadError != nil)
    }

    private func row(_ m: WhisperModel) -> some View {
        let downloaded = WhisperModels.isDownloaded(m.id)
        let active = model.settings.speechModel == m.id
        let runs = WhisperModels.runsHere(m.id)
        let fetching = model.whisperDownload?.id == m.id
        var badges: [(String, Badge.Kind)] = []
        if active { badges.append(("Active", .active)) }
        if active && WhisperEngine.loadedModel == m.id { badges.append(("Loaded", .ok)) }
        if model.whisperLoad?.model == m.id { badges.append((model.whisperLoad!.firstTime ? "Preparing…" : "Loading…", .cloud)) }
        badges.append(downloaded ? ("Downloaded", .plain) : ("Not downloaded", .outline))
        if !runs && !downloaded { badges.append(("Too big for this \(Device.noun)", .outline)) }
        // One download at a time; meanwhile every other row's button is there but disabled (ModelsPage.Row).
        let action: (String, () -> Void)? =
            fetching ? ("Cancel", { model.cancelWhisperDownload() })
            : !downloaded ? (runs ? ("Download", { model.downloadWhisper(m.id) }) : nil)
            : active ? nil : ("Use this", { model.useSpeechModel(m.id) })
        return ModelRow(name: m.name, badges: badges, detail: "\(m.description) · \(m.size)", action: action,
                        progress: fetching ? .some(model.whisperDownload?.fraction) : nil,
                        primary: downloaded, enabled: fetching || model.whisperDownload == nil)
    }
}

/// How long a Whisper model has been loading, so a slow first preparation never looks like nothing is happening.
struct LoadClock: View {
    var load: WhisperEngine.Loading
    @Environment(\.ob) private var ob

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { t in
            let s = max(0, Int(t.date.timeIntervalSince(load.since)))
            Text(String(format: "%d:%02d so far", s / 60, s % 60) + (load.firstTime
                    ? ". CoreML is preparing the model for this \(Device.noun)'s chips; this happens once per model. Dictation records meanwhile and catches up."
                    : ". Dictation records meanwhile and catches up."))
                .font(Ob.sans(12.5)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}
