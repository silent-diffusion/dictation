import AVFoundation
import ObertonCore
import SwiftUI

struct MicrophoneSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Audio is held in memory only while you dictate, and recognized on this \(Device.noun). Nothing is recorded to disk.")
            FieldLabel("Microphone")
            Text(defaultMic).font(Ob.sans(13.5))
            Caption("Oberton uses the input chosen in \(Device.noun == "Mac" ? "System Settings › Sound › Input" : "Control Center").", size: 12.5).padding(.top, 6)
            FieldLabel("Input level")
            LevelBar(level: model.phase == .recording ? model.level : 0).frame(width: 400, height: 10)
            Caption("Moves while you dictate.", size: 12.5).padding(.top, 6)
        }
    }

    private var defaultMic: String {
        #if os(macOS)
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default microphone"
        #else
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "iPhone microphone"
        #endif
    }
}

/// A level as a block bar.
struct LevelBar: View {
    var level: Float
    @Environment(\.ob) private var ob

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<40, id: \.self) { i in
                    Rectangle().fill(Float(i) / 40 < level ? ob.ink : ob.subtle)
                }
            }
            .frame(width: geo.size.width)
        }
    }
}
