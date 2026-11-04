import ObertonCore
import SwiftUI

/// READ ALOUD 読上 (ReadAloudPage.xaml): the voice's status with DOWNLOAD VOICE and TRY IT, then MODEL (Kokoro v1.0,
/// Piper, the Mac's own voices) and its VOICE, the base speed, and the player's opacity and place. The iPhone has no
/// hotkey, so it gets a box to paste text into and the player inline instead.
struct ReadAloudView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { ReadAloudPage(reader: model.reader) }
}

private struct ReadAloudPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject private var reader: ReadAloudPlayer
    /// The model whose voices the VOICE list shows (follows the voice until another model is picked).
    @State private var shownModel: String?
    /// A download started here, for which voice (the page shows only its own, and cancels it when left, as Windows
    /// does), and its failure.
    @State private var downloading = false
    @State private var download: UUID?
    @State private var failure: String?
    /// A voice was picked while the download runs: as ReadAloudPage.ShowStatus, TRY IT is back (for any voice, the one
    /// downloading too) and the status shows the picked voice until the download's next report.
    @State private var tryBack = false
    @State private var pickedSinceReport = false
    #if os(iOS)
    @State private var text = ""
    #endif

    static let sample = "Hello! This is how Oberton sounds when it reads to you. Select any text and press the shortcut to hear it."

    init(reader: ReadAloudPlayer) { self.reader = reader }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 0) {
                // PageHeader's 14 below the rule, then the intro.
                PageTitle(title: "Read aloud", japanese: "読上", readout: "Voice // on this \(Device.noun)").padding(.bottom, 14)
                Caption(intro)
                status.padding(.top, 8)

                FieldLabel("Model").padding(.top, 4)
                ObMenu(options: VoiceCatalog.models.map { ($0.id, $0.name) }, selection: modelBinding, width: 380)
                    .accessibilityLabel("Text-to-speech model")
                Caption(modelNote, bottom: 0).padding(.top, 6)

                FieldLabel("Voice").padding(.top, -2)
                // Under a model with no voices the box is empty and blank (no SelectedItem), not "—".
                ObMenu(options: voiceItems, selection: voiceBinding, width: 380, maxListHeight: 420, noSelection: "").accessibilityLabel("Voice")
                Caption("Used unless a profile picks its own model and voice (see its page under Speech to text).", bottom: 0).padding(.top, 6)

                FieldLabel("Base speed")
                // The readout is a XAML Binding's StringFormat {0:0.00}×: en-US, "1.75×" in every region. The keys move
                // by the Slider's SmallChange (0.1), snapped to the 0.05 ticks.
                ObSlider(value: snapped($model.settings.ttsBaseSpeed, ReadAloudSliders.speedTick), range: ReadAloudSliders.speedRange,
                         step: nil, format: ReadAloudSliders.speedReadout, width: sizeClass == .compact ? 200 : 300, name: "Base speed",
                         smallChange: ReadAloudSliders.smallChange)
                Caption("Every reading starts at this speed. The − and + buttons in the reader, and the menu that opens when you click the speed there, change it too, and the next reading starts where you left it.",
                        bottom: 0).padding(.top, 6)

                #if os(macOS)
                FieldLabel("Player opacity")
                // StringFormat {0:P0}: "90%" in every region; the keys move by 0.1, snapped to the 0.02 ticks.
                ObSlider(value: snapped($model.settings.readerOpacity, ReadAloudSliders.opacityTick), range: ReadAloudSliders.opacityRange,
                         step: nil, format: ReadAloudSliders.opacityReadout, name: "Player opacity", smallChange: ReadAloudSliders.smallChange)
                Caption("How much of the player's dark background shows; the text stays solid. The dictation pill has its own setting under Settings › Layout.",
                        bottom: 0).padding(.top, 6)

                FieldLabel("Player position")
                ObSwitch("Same place as the dictation overlay", isOn: ReaderPositionPicker.samePlaceBinding(model, previews: true)).fixedSize()
                HStack(spacing: 14) {
                    // A Border in Ob.Border (ink) on Ob.Window, radius 8.
                    ReaderPositionPicker(fill: ob.paper, radius: 8)
                    Text(ReaderPositionPicker.placeName(model.settings)).font(Ob.sans(12.5)).foregroundStyle(ob.muted)
                        .opacity(model.settings.readerPosition == .withOverlay ? 0.45 : 1)
                }
                .padding(.top, 6)
                Caption("Put the player somewhere other than the dictation pill if you like. You can also drag it while it reads.",
                        bottom: 0).padding(.top, 6)

                FieldLabel("How to use it")
                Caption("Select text, then press \(model.settings.speakHotkey). With nothing selected, Oberton offers to read your clipboard. Press the shortcut again (or ✕) to stop. Change the shortcut under Hotkeys.")
                #else
                FieldLabel("Read something")
                TextEditor(text: $text)
                    .font(Ob.sans(14)).scrollContentBackground(.hidden).padding(8)
                    .frame(minHeight: 110)
                    .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
                HStack {
                    Button("Read this") { model.reader.read(text, voice: model.settings.ttsVoice) }
                        .buttonStyle(.primary).disabled(text.isEmpty)
                    Button("Read the clipboard") {
                        if let s = model.platform?.clipboardText() { text = s; model.reader.read(s, voice: model.settings.ttsVoice) }
                    }
                    .buttonStyle(.quiet)
                }
                .padding(.top, 10)
                ReaderCard(player: model.reader, opacity: 1).padding(.top, 16)
                #endif
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(sizeClass == .compact ? EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16) : EdgeInsets(top: 32, leading: 40, bottom: 40, trailing: 40))
        }
        .onDisappear { if downloading, let download { reader.cancelInstall(download) } }
        .onChange(of: model.settings.ttsVoice) { if downloading { tryBack = true; pickedSinceReport = true } }
        .onChange(of: download.flatMap { reader.progress(of: $0) }) { pickedSinceReport = false }
    }

    private var intro: String {
        #if os(macOS)
        "Select text in any app and press \(model.settings.speakHotkey) to hear it. The voices run on this Mac; nothing you read is sent anywhere."
        #else
        "Paste or type text below to hear it. The voices run on this \(Device.noun); nothing you read is sent anywhere."
        #endif
    }

    // MARK: Status

    private var voice: String { model.settings.ttsVoice ?? VoiceCatalog.defaultVoice }

    /// "Heart is ready" / "… isn't downloaded yet" / "… isn't installed" / "Kokoro isn't downloaded yet", or how the
    /// download goes; DOWNLOAD VOICE and TRY IT (ReadAloudPage.ShowStatus).
    private var status: some View {
        // Only this page's own download; until its first report the status stays, over an empty bar. A voice picked
        // meanwhile shows its own status until the next report.
        let progress = downloading ? download.flatMap { reader.progress(of: $0) } ?? VoiceProgress.waiting : nil
        let reported = !pickedSinceReport && (progress.map { !$0.title.isEmpty } ?? false)
        return HStack(spacing: 0) {
            // A DockPanel: the text column takes the room left of the buttons, 16 from them. The title stays on one
            // line and is cut off (no TextWrapping on Windows).
            VStack(alignment: .leading, spacing: 0) {
                Text(reported ? progress!.title : statusTitle).font(Ob.sans(Ob.body, .semibold))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
                Text(failure ?? (reported ? progress!.detail : statusDetail)).font(Ob.sans(12)).foregroundStyle(ob.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                if let progress {
                    ProgressBar(fraction: progress.fraction).frame(height: 4).padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 16)
            HStack(spacing: 8) {
                if !installed && !VoiceCatalog.isSystemVoice(voice) {
                    Button("Download voice") { startDownload() }.buttonStyle(.quiet).disabled(downloading)
                }
                // Picking a voice during the download gives TRY IT back (ReadAloudPage.ShowStatus).
                Button("Try it") { reader.read(Self.sample, voice: voice) }
                    .buttonStyle(.primary).disabled(downloading && !tryBack)
            }
        }
        // DockPanel Margin 18,14 inside the Card's 1 px border (SYS-001).
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
        .padding(Ob.border)
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: Ob.border))
    }

    private var installed: Bool { VoiceCatalog.isInstalled(voice) }

    private var statusTitle: String {
        let name = VoiceCatalog.shortName(voice)
        if installed { return "\(name) is ready" }
        if VoiceCatalog.findPiper(voice) != nil { return "\(name) isn't downloaded yet" }
        if VoiceCatalog.isSystemVoice(voice) { return "\(name) isn't installed" }
        return "Kokoro isn't downloaded yet"
    }

    private var statusDetail: String {
        if installed { return "\(VoiceCatalog.model(VoiceCatalog.modelOf(voice)).name) · ready to read." }
        if let piper = VoiceCatalog.findPiper(voice) { return "A one-time download of about \(piper.mb) MB, also offered the first time you use it." }
        if VoiceCatalog.isSystemVoice(voice) { return "That \(Device.noun) voice isn't on this \(Device.noun) any more. Pick another one." }
        return "A one-time download of about \(VoiceInstaller.kokoroDownloadMb) MB, also offered the first time you use Read aloud."
    }

    private func startDownload() {
        failure = nil
        downloading = true
        tryBack = false
        pickedSinceReport = false
        download = reader.installVoice(voice) { result in
            downloading = false
            download = nil
            tryBack = false
            pickedSinceReport = false
            switch result {
            case .success, .failure(is CancellationError): break
            case .failure(let error as UserFacingError): failure = error.message
            case .failure(let error):
                Log.error("Read aloud install failed", error)
                failure = "The download failed. See the log, and try again."
            }
        }
    }

    // MARK: Model and voice

    private var currentModel: String { shownModel ?? VoiceCatalog.modelOf(voice) }

    private var modelBinding: Binding<String> {
        Binding(get: { currentModel }, set: { new in
            guard new != currentModel else { return }
            shownModel = new
            failure = nil
            // A different model: its first voice (ReadAloudPage.FillVoices).
            if let first = VoiceCatalog.voicesOf(new).first { model.settings.ttsVoice = first.id }
        })
    }

    private var modelNote: String {
        var note = VoiceCatalog.model(currentModel).description
        if currentModel == VoiceCatalog.system, VoiceCatalog.voicesOf(VoiceCatalog.system).isEmpty {
            #if os(macOS)
            note += " No \(Device.noun) voices are installed; add some under System Settings › Accessibility › Spoken Content."
            #else
            note += " No \(Device.noun) voices are installed; add some under Settings › Accessibility › Spoken Content."
            #endif
        }
        return note
    }

    /// The model's voices; ones that still need downloading say so ("Lessac (American, female) · download 63 MB").
    private var voiceItems: [(String, String)] {
        let items = VoiceCatalog.voicesOf(currentModel).map { v in
            (v.id, v.name + (VoiceCatalog.isInstalled(v.id) ? "" : VoiceCatalog.findPiper(v.id).map { " · download \($0.mb) MB" } ?? " · download"))
        }
        // The saved voice is listed even when it isn't (any more), but only under its own model: under a model with no
        // voices the list stays empty, as on Windows.
        return items.contains { $0.0 == voice } || VoiceCatalog.modelOf(voice) != currentModel ? items : items + [(voice, VoiceCatalog.shortName(voice))]
    }

    private var voiceBinding: Binding<String> {
        Binding(get: { voice }, set: { model.settings.ttsVoice = $0; failure = nil })
    }

    /// A slider that moves in steps without drawing tick marks (Windows' sliders have none).
    private func snapped(_ value: Binding<Double>, _ step: Double) -> Binding<Double> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ReadAloudSliders.snap($0, tick: step) })
    }
}
