import ObertonCore
import SwiftUI

struct CloudSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @State private var anthropic = KeyStore.get(.anthropic) ?? ""
    @State private var openai = KeyStore.get(.openai) ?? ""
    @State private var saved: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Oberton's own models run on this \(Device.noun). Optionally, a profile can use a cloud model instead (Anthropic's Claude, or OpenAI and compatible services) for stronger rewriting. Only the text of a dictation is sent, never the audio, and only for profiles you set to a cloud model.")
                .padding(.bottom, 16)
            SwitchCard {
                ObSwitch("Keep everything offline",
                         detail: "While this is on, nothing is ever sent to a cloud model, whatever a profile selects: such a profile inserts your words as spoken and says why.",
                         isOn: $model.settings.cloud.keepOffline)
            }
            FieldLabel("Anthropic (Claude)")
            keyCard(text: $anthropic, provider: .anthropic) { EmptyView() }
            FieldLabel("OpenAI or a compatible service")
            keyCard(text: $openai, provider: .openai) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Model").font(Ob.sans(13)).padding(.top, 12).padding(.bottom, 4)
                    ObField("gpt-4.1-mini", text: $model.settings.cloud.openAIModel, mono: true, width: 280)
                    Text("Service address").font(Ob.sans(13)).padding(.top, 12).padding(.bottom, 4)
                    ObField("https://api.openai.com/v1", text: $model.settings.cloud.openAIBaseURL, mono: true)
                    Caption("https://api.openai.com/v1 for OpenAI. Services with the same API (OpenRouter, Groq and others) work too.", size: 12).padding(.top, 6)
                }
            }
            Caption("Keys are kept in the Keychain on this \(Device.noun), never in Oberton's settings file. To use a cloud model, pick it on a profile's page or under Settings › Models; cloud models are marked CLOUD there.").padding(.top, 16)
        }
    }

    private func keyCard<Extra: View>(text: Binding<String>, provider: ModelID.Provider, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("API key").font(Ob.sans(13)).padding(.bottom, 4)
            HStack(spacing: 8) {
                ObField("Paste your key", text: text, mono: true, secure: true)
                Button("Save key") { KeyStore.set(provider, text.wrappedValue); saved = provider.rawValue }.buttonStyle(.primary)
                Button("Remove") { KeyStore.set(provider, nil); text.wrappedValue = ""; saved = nil }.buttonStyle(.quiet)
            }
            Caption(KeyStore.get(provider) != nil ? (saved == provider.rawValue ? "Saved." : "A key is saved (in the Keychain).") : "No key saved.", size: 12).padding(.top, 6)
            extra()
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
    }
}
