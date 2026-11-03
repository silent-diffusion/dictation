import ObertonCore
import SwiftUI

// MARK: - A // Dictation

/// Windows GeneralPage.xaml. "Fit dictation into the surrounding text" needs to read the text around another app's
/// cursor, which only the direct build may (the App Store sandbox can't), so the App Store build leaves it out. The
/// iPhone can't type into other apps: no "Type as you speak" either.
struct GeneralSection: View {
    @EnvironmentObject var model: AppModel
    @State private var maxSeconds = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Everything runs on this \(Device.noun). No audio or text is sent anywhere unless you allow cloud AI (Settings › Cloud AI), and there is no telemetry.")
            #if os(macOS)
            SwitchCard {
                ObSwitch("Start when you log in (hidden in the menu bar)", isOn: $model.settings.startAtLogin)
                ObSwitch("Keep running in the menu bar when the window is closed", isOn: $model.settings.minimizeToTray)
            }
            .padding(.top, 8)

            SwitchCard {
                ObSwitch("Type as you speak",
                         detail: "Finished sentences appear in the app about every 5 seconds while you talk. When you press the hotkey again, the whole dictation is cleaned up in one final pass that replaces them. Off for profiles that preview before inserting.",
                         isOn: $model.settings.typeWhileSpeaking)
            }
            .padding(.top, 16)

            if Distribution.isDirect {
                SwitchCard {
                    ObSwitch("Fit dictation into the surrounding text",
                             detail: "Reads a sentence or two around the cursor so text dropped mid-sentence isn't capitalized or given a period, and adds missing spaces. Works in apps that expose their text to macOS accessibility (Word, browsers, most text boxes). The text is never stored or sent anywhere.",
                             isOn: $model.settings.matchSurroundingText)
                }
                .padding(.top, 16)
            }

            FieldLabel("Text insertion method").padding(.top, 4)
            ObMenu(options: [(InsertionMode.auto, "Auto"), (.typing, "Typing"), (.clipboard, "Clipboard")],
                   selection: $model.settings.insertion)
                .frame(width: 220)
            Caption("Auto pastes the text (your clipboard is saved and restored afterwards), the most reliable method in every kind of app. Typing sends keystrokes instead and never touches the clipboard, but is slower. Typing is also used automatically if pasting fails. Per-app overrides: appOverrides (by bundle ID) in settings.json.")
                .padding(.top, 6)
            SwitchCard {
                ObSwitch("Put my clipboard back after inserting",
                         detail: "Oberton pastes the text at the cursor, then puts back what you had copied.", isOn: $model.settings.restoreClipboard)
            }
            .padding(.top, 12)
            #endif

            FieldLabel("Maximum length of one dictation (seconds)")
            ObField("", text: Binding(get: { maxSeconds }, set: { text in
                maxSeconds = text
                if let n = Int(text.trimmingCharacters(in: .whitespaces)), n > 0 { model.settings.maxRecordingSeconds = Double(n) }
            }), width: 120)
            .onAppear { maxSeconds = String(Int(model.settings.maxRecordingSeconds)) }
        }
    }
}
