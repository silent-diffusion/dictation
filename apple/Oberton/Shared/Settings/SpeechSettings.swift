import ObertonCore
import SwiftUI

struct SpeechSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Speech is transcribed on this \(Device.noun): by Apple's speech recognizer, which downloads each language once through the system, or by a Whisper model you download under Settings › Models. A change applies at once.")
            Text(model.speechStatus).font(Ob.sans(13.5, .semibold)).foregroundStyle(model.speechOK ? ob.ink : ob.accent)
                .padding(.top, 8)
            if let load = model.whisperLoad { LoadClock(load: load).padding(.top, 4) }
            // Windows' MODEL combo (260 wide) with the models by id, and whether the one chosen is on this device. The
            // Mac runs only the CoreML builds made for these models, so there is no free text to type.
            FieldLabel("Model")
            ObMenu(options: [("", "Apple Speech")] + WhisperModels.all.map { ($0.id, $0.id) },
                   selection: Binding(get: { model.settings.speechModel }, set: { model.useSpeechModel($0) }), width: 260)
                .accessibilityLabel("Speech model")
            Caption(modelNote, bottom: 0).padding(.top, 4).frame(maxWidth: 560, alignment: .leading)
            FieldLabel("Language")
            // Windows' 120-wide box with a language code, taken when it is left.
            CommitField(value: $model.settings.language, width: 120).accessibilityLabel("Language")
            Caption("Two-letter code such as en, de, es. Leave empty to auto-detect (slightly slower, less reliable for short phrases).", bottom: 0)
                .padding(.top, 4)
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
            // Windows' save-and-restart: the speech model loads again from scratch, even one that works.
            Button("Apply and restart speech engine") { model.warmUp(restart: true) }
                .buttonStyle(.quiet).padding(.top, 16)
        }
    }

    /// SpeechPage.UpdateNote: whether the chosen model is on this device (the Mac downloads it under Settings › Models,
    /// where Windows names its setup script).
    private var modelNote: String {
        guard let id = model.settings.whisperModel, !WhisperModels.isDownloaded(id) else { return "Installed locally." }
        return "Not downloaded yet. Download it once under Settings › Models (needs internet; after that it works offline)."
    }
}

/// The speech models as rows on Settings › Models (ModelsPage.xaml.cs's SpeechList): Apple Speech, then Windows'
/// Whisper models with ACTIVE / LOADED / DOWNLOADED, Download (progress, Cancel) and Use this. As on Windows every
/// button stays usable while a download runs; a second Download does nothing until it is done (`busy`).
struct SpeechModelList: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    /// Another download runs on the page (a local AI model, a voice): Download does nothing (Windows' `if (Busy) return;`).
    /// Asked at the click.
    var busy: () -> Bool = { false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let apple = model.settings.whisperModel == nil
            ModelRow(name: "Apple Speech",
                     badges: (apple ? [("Active", .active)] : []) + (apple && LiveTranscriber.modelRetained ? [("Loaded", .ok)] : []) + [("Installed", .plain)],
                     detail: "Apple's on-device speech recognizer. Downloads its language once, through the system.",
                     action: apple ? nil : ("Use this", { model.useSpeechModel("") }), primary: true)
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
        badges.append(downloaded ? ("Downloaded", .plain) : ("Not downloaded", .outline))
        // A model this device can't run (an iPhone without the memory for a large one) can't be downloaded here: it
        // says so in its line instead of offering a download that would never work.
        let detail = "\(m.description) · \(m.size)" + (runs || downloaded ? "" : " · too big for this \(Device.noun)")
        let action: (String, () -> Void)? =
            fetching ? ("Cancel", { model.cancelWhisperDownload() })
            : !downloaded ? (runs ? ("Download", { if ModelDownloads.mayStart(busy: busy()) { model.downloadWhisper(m.id) } }) : nil)
            : active ? nil : ("Use this", { model.useSpeechModel(m.id) })
        return ModelRow(name: m.name, badges: badges, detail: detail, action: action,
                        progress: fetching ? .some(model.whisperDownload?.fraction) : nil, primary: downloaded)
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
