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
            SwitchCard {
                ObSwitch("Keep everything offline",
                         detail: "While on, nothing is sent to a cloud model, whatever a profile picks. Apple Intelligence and Ollama run on this \(Device.noun) and stay allowed.",
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
                    Caption("https://api.openai.com/v1 for OpenAI, or another service's address (OpenRouter, Groq…).", size: 12).padding(.top, 6)
                }
            }
            Caption("Keys are kept in the Keychain on this \(Device.noun), never in Oberton's settings file.").padding(.top, 16)
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
            Caption(KeyStore.get(provider) != nil ? (saved == provider.rawValue ? "Saved." : "A key is set.") : "No key set.", size: 12).padding(.top, 6)
            extra()
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
    }
}
