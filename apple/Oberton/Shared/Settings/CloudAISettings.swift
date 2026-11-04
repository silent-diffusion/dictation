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
                ObField("", text: text, mono: true, secure: true).accessibilityLabel(name)
                    .onSubmit { save(text, provider) }
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
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
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

/// A text box that hands its text over when it is left or Return is pressed (WPF's UpdateSourceTrigger=LostFocus).
/// With `isValid`, text it refuses isn't handed over and the box gets WPF's red validation border until fixed.
struct CommitField: View {
    @Binding var value: String
    var width: CGFloat?
    var isValid: ((String) -> Bool)? = nil
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool
    @Environment(\.ob) private var ob

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(Ob.sans(Ob.body)) // a stock WPF TextBox: the window's 12
            .focused($focused)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .overlay(Rectangle().strokeBorder(invalid ? Color.red : focused ? ob.ink : ob.divider, lineWidth: 1))
            .onAppear { text = value }
            .onChange(of: value) { if !focused { text = value; invalid = false } }
            .onChange(of: focused) { if !focused { commit() } }
            .onSubmit(commit)
            .onDisappear(perform: commit)
    }

    private func commit() {
        if let isValid, !isValid(text) { invalid = true; return }
        invalid = false
        if text != value { value = text }
    }
}
