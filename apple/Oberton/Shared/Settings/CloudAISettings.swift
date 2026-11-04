import ObertonCore
import SwiftUI

/// Settings › Cloud AI (CloudPage.xaml): the offline switch, a key for Anthropic and one for OpenAI or a compatible
/// service, and that service's model and address.
struct CloudSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    /// The key boxes start empty and are cleared after saving: a saved key is never shown again (a PasswordBox).
    @State private var anthropic = ""
    @State private var openai = ""
    /// Re-read the Keychain after a change.
    @State private var keysChanged = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Oberton's own models run on this \(Device.noun). Optionally, a profile can use a cloud model instead (Anthropic's Claude, or OpenAI and compatible services) for stronger rewriting. Only the text of a dictation is sent, never the audio, and only for profiles you set to a cloud model.")
                .padding(.bottom, 8)
            SwitchCard {
                ObSwitch("Keep everything offline",
                         detail: "While this is on, nothing is ever sent to a cloud model, whatever a profile selects: such a profile inserts your words as spoken and says why.",
                         titleWeight: .semibold, isOn: $model.settings.cloud.keepOffline)
            }
            label("Anthropic (Claude)", top: 26)
            keyCard(text: $anthropic, provider: .anthropic, name: "Anthropic API key") { EmptyView() }
            label("OpenAI or a compatible service", top: 22)
            keyCard(text: $openai, provider: .openai, name: "OpenAI API key") {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Model").font(Ob.sans(Ob.body)).padding(.top, 12).padding(.bottom, 6)
                    // Saved when the box is left, as Windows' LostFocus binding: a half-typed id never goes live.
                    CommitField(value: $model.settings.cloud.openAIModel, width: 280).accessibilityLabel("OpenAI model")
                    Text("Service address").font(Ob.sans(Ob.body)).padding(.top, 12).padding(.bottom, 6)
                    CommitField(value: $model.settings.cloud.openAIBaseURL).accessibilityLabel("Service address")
                    Caption("https://api.openai.com/v1 for OpenAI. Services with the same API (OpenRouter, Groq and others) work too.", bottom: 0).padding(.top, 6)
                }
            }
            Caption("Keys are encrypted in the Keychain and stored only on this \(Device.noun). To use a cloud model, pick it on a profile's page or under Settings › Models; cloud models are marked CLOUD there.")
                .padding(.top, 18)
        }
    }

    private func label(_ text: String, top: CGFloat) -> some View {
        Text(text.uppercased()).font(Ob.mono(12, .bold)).padding(.top, top).padding(.bottom, 6)
    }

    private func keyCard<Extra: View>(text: Binding<String>, provider: ModelID.Provider, name: String, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("API key").font(Ob.sans(Ob.body)).padding(.bottom, 6)
            HStack(spacing: 8) {
                // Return does nothing here, as in Windows' PasswordBox (the page has no default button): SAVE KEY saves.
                ObField("", text: text, secure: true, padding: EdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 6)).accessibilityLabel(name)
                Button("Save key") { save(text, provider) }.buttonStyle(.primary)
                Button("Remove") {
                    KeyStore.set(provider, nil)
                    keysChanged += 1
                }
                .buttonStyle(.quiet)
            }
            Caption(hasKey(provider) ? "A key is saved (encrypted)." : "No key saved.", bottom: 0).padding(.top, 6)
            extra()
        }
        .padding(EdgeInsets(top: 14 + Ob.border, leading: 18 + Ob.border, bottom: 14 + Ob.border, trailing: 18 + Ob.border)) // Card Padding 18,14 inside its line
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: Ob.border))
    }

    /// CloudPage.SaveKey: an empty box does nothing (it never removes the saved key); after saving, the box is cleared.
    private func save(_ text: Binding<String>, _ provider: ModelID.Provider) {
        guard !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        KeyStore.set(provider, text.wrappedValue)
        text.wrappedValue = ""
        keysChanged += 1
        model.objectWillChange.send() // the Models page and profile menus read the key state
    }

    private func hasKey(_ provider: ModelID.Provider) -> Bool {
        _ = keysChanged
        return KeyStore.get(provider) != nil
    }
}

/// A text box that hands its text over when it is left (WPF's UpdateSourceTrigger=LostFocus): not on Return, which a
/// single-line WPF TextBox ignores. Leaving the page counts as leaving the box, as the click that leaves a Windows page
/// takes the focus with it. With `isValid`, text it refuses isn't handed over and the box gets WPF's red validation
/// border until fixed.
struct CommitField: View {
    @Binding var value: String
    var width: CGFloat?
    var isValid: ((String) -> Bool)? = nil
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool
    @Environment(\.ob) private var ob

    var body: some View {
        // A stock TextBox under the Fluent theme (its style sets 14 pt, over the window's 12): see ObField.
        Group {
            // The debug snapshots' image renderer can't draw an AppKit text field: the text stands in for it there.
            if PageScroll<EmptyView>.flat { Text(value).frame(maxWidth: .infinity, alignment: .leading) } else { TextField("", text: $text) }
        }
            .textFieldStyle(.plain)
            .font(Ob.sans(14))
            .focused($focused)
            .fluentBox(focused: focused, width: width)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(invalid ? Color.red : .clear, lineWidth: 1))
            .onAppear { text = value }
            .onChange(of: value) { if !focused { text = value; invalid = false } }
            .onChange(of: focused) { if !focused { commit() } }
            .onDisappear(perform: commit)
    }

    private func commit() {
        if let isValid, !isValid(text) { invalid = true; return }
        invalid = false
        if text != value { value = text }
    }
}
