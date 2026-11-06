import ObertonCore
import SwiftUI
#if os(macOS)
import ServiceManagement
#endif

// MARK: - A // Dictation

/// Windows GeneralPage.xaml. "Fit dictation into the surrounding text" needs to read the text around another app's
/// cursor, which only the direct build may (the App Store sandbox can't), so the App Store build leaves it out. The
/// iPhone can't type into other apps: no "Type as you speak" either.
struct GeneralSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(macOS)
            Caption("Everything runs on this computer. No audio or text is sent anywhere unless you allow cloud AI (Settings › Cloud AI), and there is no telemetry.")
            SwitchCard {
                ObSwitch("Start with Mac (minimized to the menu bar)", isOn: $model.settings.startAtLogin)
                ObSwitch("Keep running in the menu bar when the window is closed", isOn: $model.settings.minimizeToTray)
            }
            .padding(.top, 8)
            // macOS can hold the login item back until the user allows it; the switch alone would say it's on.
            if model.settings.startAtLogin, SMAppService.mainApp.status == .requiresApproval {
                Caption("macOS waits for your permission before it starts Oberton when you log in: turn Oberton on in System Settings › General › Login Items.", bottom: 0)
                    .padding(.top, 6)
            }

            SwitchCard {
                ObSwitch("Type as you speak",
                         detail: "Finished sentences appear in the app about every 5 seconds while you talk. When you press the hotkey again, the whole dictation is cleaned up in one final pass that replaces them. Off for profiles that preview before inserting.",
                         isOn: $model.settings.typeWhileSpeaking)
            }
            .padding(.top, 16)
            // macOS only lets Oberton type into other apps once it is allowed; until then the switch would do nothing.
            if model.settings.typeWhileSpeaking, !CGPreflightPostEventAccess() {
                Caption("Oberton isn't allowed to type into other apps yet, so the text goes in when you stop. To type as you speak, " + Distribution.allowAccessibility)
                    .padding(.top, 6)
            }

            if Distribution.isDirect {
                SwitchCard {
                    ObSwitch("Fit dictation into the surrounding text",
                             detail: "Reads a sentence or two around the cursor so text dropped mid-sentence isn't capitalized or given a period, and adds missing spaces. Works in apps that expose their text to macOS accessibility (Word, browsers, most text boxes). The text is never stored or sent anywhere.",
                             isOn: $model.settings.matchSurroundingText)
                }
                .padding(.top, 16)
                // Reading the text around the cursor needs Accessibility; until it is allowed the switch can't work.
                if model.settings.matchSurroundingText, !Distribution.axTrusted {
                    Caption("Oberton isn't allowed to read the text around the cursor yet. Allow it in System Settings › Privacy & Security › Accessibility.", bottom: 0)
                        .padding(.top, 6)
                }
            }

            FieldLabel("Text insertion method").padding(.top, 4)
            ObMenu(options: [(InsertionMode.auto, "Auto"), (.typing, "Typing"), (.clipboard, "Clipboard")],
                   selection: $model.settings.insertion, width: 220)
                .accessibilityLabel("Text insertion method") // AutomationProperties.Name
            Caption("Auto pastes the text (your clipboard is saved and restored afterwards), the most reliable method in every kind of app. Typing sends keystrokes instead and never touches the clipboard, but is slower. Typing is also used automatically if pasting fails. Per-app overrides: appOverrides (by bundle ID) in settings.json.", bottom: 0)
                .padding(.top, 6) // Margin 0,6,0,0: nothing below
            SwitchCard {
                ObSwitch("Put my clipboard back after inserting",
                         detail: "Oberton pastes the text at the cursor, then puts back what you had copied.", isOn: $model.settings.restoreClipboard)
            }
            .padding(.top, 12)
            #else
            Caption("Everything runs on this \(Device.noun). No audio or text is sent anywhere unless you allow cloud AI (Settings › Cloud AI), and there is no telemetry.")
            #endif

            FieldLabel("Maximum length of one dictation (seconds)")
            // UpdateSourceTrigger=LostFocus: any whole number that fits Windows' Int32 is taken when the box is left (a
            // dictation still gets at least 10 s); anything else gets the red validation border and the setting stays.
            CommitField(value: Binding(get: { String(Int(model.settings.maxRecordingSeconds)) },
                                       set: { if let n = Int32($0.trimmingCharacters(in: .whitespaces)) { model.settings.maxRecordingSeconds = Double(n) } }),
                        width: 120, isValid: { Int32($0.trimmingCharacters(in: .whitespaces)) != nil })
                .accessibilityLabel("Maximum length of one dictation in seconds")
        }
    }
}
