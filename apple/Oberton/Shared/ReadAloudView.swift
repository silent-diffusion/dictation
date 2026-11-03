import AVFoundation
import ObertonCore
import SwiftUI

/// READ ALOUD 読上 (ReadAloudPage.xaml).
struct ReadAloudView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var text = ""

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "Read aloud", japanese: "読上", readout: "Voice // on this \(Device.noun)",
                          summary: intro)
                // Status: the voice, and a way to hear it.
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(voiceName) is ready").font(Ob.sans(13.5, .semibold))
                        Text("A voice of this \(Device.noun)'s own; nothing to download.").font(Ob.sans(12)).foregroundStyle(ob.muted)
                    }
                    Spacer()
                    Button("Try it") {
                        model.reader.read("Select any text and press the shortcut to hear it read aloud.", voice: model.settings.ttsVoice,
                                          speed: model.settings.ttsBaseSpeed)
                    }
                    .buttonStyle(.primary)
                }
                .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
                .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
                .padding(.top, 16)

                FieldLabel("Voice")
                ObMenu(options: [(String?.none, "System voice")] + ReadAloudPlayer.voices.map { (Optional($0.identifier), label($0)) },
                       selection: $model.settings.ttsVoice, width: 380)
                Caption("Used unless a profile picks its own voice. More natural voices: System Settings › Accessibility › Spoken Content › System voice › Manage Voices (the Enhanced and Premium ones).",
                        size: 12.5).padding(.top, 8)

                FieldLabel("Base speed")
                ObSlider(value: $model.settings.ttsBaseSpeed, range: 0.25...4, step: 0.05, format: { String(format: "%.2f×", $0) },
                         width: sizeClass == .compact ? 200 : 300)
                Caption("The speed each reading starts at. The player's − and + change it for that reading.", size: 12.5).padding(.top, 8)

                #if os(macOS)
                FieldLabel("Player opacity")
                ObSlider(value: $model.settings.readerOpacity, range: 0.3...1, step: 0.02, format: { "\(Int(($0 * 100).rounded()))%" })
                Caption("How much of the player's dark background shows; the text stays solid. The dictation pill has its own setting under Settings › Layout.",
                        size: 12.5).padding(.top, 6)

                FieldLabel("Player position")
                ObSwitch("Same place as the dictation overlay", isOn: ReaderPositionPicker.samePlaceBinding(model)).fixedSize()
                HStack(spacing: 14) {
                    ReaderPositionPicker()
                    Text(ReaderPositionPicker.placeName(model.settings)).font(Ob.sans(12.5)).foregroundStyle(ob.muted)
                }
                .padding(.top, 6)
                Caption("Put the player somewhere other than the dictation pill if you like. You can also drag it while it reads.",
                        size: 12.5).padding(.top, 6)

                FieldLabel("How to use it")
                Caption("Select text, then press \(model.settings.speakHotkey). With nothing selected, Oberton offers to read your clipboard. Press the shortcut again (or ✕) to stop. Change the shortcut under Hotkeys.")
                #endif

                FieldLabel("Read something")
                TextEditor(text: $text)
                    .font(Ob.sans(14)).scrollContentBackground(.hidden).padding(8)
                    .frame(minHeight: 110)
                    .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
                HStack {
                    Button("Read this") { model.reader.read(text, voice: model.settings.ttsVoice, speed: model.settings.ttsBaseSpeed) }
                        .buttonStyle(.primary).disabled(text.isEmpty)
                    Button("Read the clipboard") {
                        if let s = model.platform?.clipboardText() { text = s; model.reader.read(s, voice: model.settings.ttsVoice, speed: model.settings.ttsBaseSpeed) }
                    }
                    .buttonStyle(.quiet)
                }
                .padding(.top, 10)
                #if os(iOS)
                ReaderCard(player: model.reader, opacity: 1).padding(.top, 16)
                #endif
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(sizeClass == .compact ? EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16) : EdgeInsets(top: 32, leading: 40, bottom: 40, trailing: 40))
        }
    }

    private var intro: String {
        #if os(macOS)
        "Select text in any app and press \(model.settings.speakHotkey) to hear it. The voices run on this Mac."
        #else
        "Paste or type text below to hear it. The voices run on this iPhone."
        #endif
    }

    private var voiceName: String {
        ReadAloudPlayer.voices.first { $0.identifier == model.settings.ttsVoice }?.name ?? "The system voice"
    }

    private func label(_ v: AVSpeechSynthesisVoice) -> String {
        v.name + (v.quality == .premium ? " · Premium" : v.quality == .enhanced ? " · Enhanced" : "")
    }
}
