import ObertonCore
import SwiftUI

// MARK: - D // App

struct AdvancedSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel("Locations")
            Text(AppPaths.dataDir.path(percentEncoded: false)).font(Ob.mono(12)).textSelection(.enabled)
            Caption("settings.json, profiles.json, history.json and usage.json.", size: 12.5).padding(.top, 6)
            #if os(macOS)
            Button("Open data folder") { NSWorkspace.shared.open(AppPaths.dataDir) }.buttonStyle(.quiet).padding(.top, 10)
            #endif
            FieldLabel("Privacy")
            Caption("Speech is recognized on this \(Device.noun), and Apple Intelligence edits it here too. Nothing is sent anywhere unless a profile picks a cloud model and “Keep everything offline” is off. History and the daily counts stay in the folder above; the counts are numbers only, never text.")
        }
    }
}
