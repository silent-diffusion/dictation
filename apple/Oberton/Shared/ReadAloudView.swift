import AVFoundation
import ObertonCore
import SwiftUI

struct ReadAloudView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                PlayerView(player: model.reader)
                TextEditor(text: $text).frame(minHeight: 120)
                HStack {
                    Button("Read this") { model.reader.read(text, voice: model.settings.ttsVoice, speed: model.settings.ttsBaseSpeed) }
                        .disabled(text.isEmpty)
                    Button("Read the clipboard") {
                        if let s = model.platform?.clipboardText() { text = s; model.reader.read(s, voice: model.settings.ttsVoice, speed: model.settings.ttsBaseSpeed) }
                    }
                }
                #if os(macOS)
                Text("Or select text in any app and press \(model.settings.speakHotkey).").font(.caption).foregroundStyle(.secondary)
                #endif
            }
            Section("Voice") {
                Picker("Voice", selection: $model.settings.ttsVoice) {
                    Text("System default").tag(String?.none)
                    ForEach(ReadAloudPlayer.voices, id: \.identifier) { v in
                        Text(v.name + (v.quality == .premium ? " · Premium" : v.quality == .enhanced ? " · Enhanced" : "")).tag(Optional(v.identifier))
                    }
                }
                LabeledContent("Speed") {
                    Slider(value: $model.settings.ttsBaseSpeed, in: 0.5...2, step: 0.05)
                    Text(String(format: "%.2g×", model.settings.ttsBaseSpeed)).monospacedDigit().frame(width: 44)
                }
                Text("More natural voices: System Settings › Accessibility › Spoken Content › System voice › Manage Voices (Enhanced and Premium).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Read aloud")
    }
}

/// Play/pause, back to the sentence start, speed, and the text with the current word highlighted (click a word to jump).
struct PlayerView: View {
    @ObservedObject var player: ReadAloudPlayer

    var body: some View {
        if player.isSpeaking {
            VStack(alignment: .leading, spacing: 10) {
                PanelLabel(title: "Reading aloud", japanese: "読上")
                ScrollView { Text(highlighted).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 140)
                HStack(spacing: 16) {
                    Button { player.togglePause() } label: { Image(systemName: player.isPaused ? "play.fill" : "pause.fill") }
                        .accessibilityLabel(player.isPaused ? "Play" : "Pause")
                    Button { player.setSpeed(player.speed - 0.25) } label: { Image(systemName: "minus") }.accessibilityLabel("Slower")
                    Menu(String(format: "%.2g×", player.speed)) {
                        ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4], id: \.self) { s in
                            Button(String(format: "%.2g×", s)) { player.setSpeed(s) }
                        }
                    }
                    .fixedSize()
                    Button { player.setSpeed(player.speed + 0.25) } label: { Image(systemName: "plus") }.accessibilityLabel("Faster")
                    Spacer()
                    Button { player.stop() } label: { Image(systemName: "stop.fill") }.accessibilityLabel("Stop")
                }
                .buttonStyle(.borderless)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        }
    }

    private var highlighted: AttributedString {
        var s = AttributedString(player.text)
        if let r = player.spokenRange, let range = Range(r, in: s) {
            s[range].foregroundColor = .accentColor
            s[range].backgroundColor = .accentColor.opacity(0.15)
        }
        return s
    }
}
