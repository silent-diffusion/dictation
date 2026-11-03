import AVFoundation
import ObertonCore
import SwiftUI

struct MicrophoneSection: View {
    @EnvironmentObject var model: AppModel
    @State private var devices: [String] = []
    @State private var meterLevel: Float = 0
    @State private var meter: MicrophoneMeter?
    @State private var problem: String?

    /// The picker's first entry: no choice, the system's input (Windows' "(System default microphone)").
    private static let systemDefault = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Windows' words, except that History may keep a dictation's recording here too (Settings › History).
            Caption("Audio is held in memory only while you dictate and is discarded afterwards, unless History keeps the recording. Recordings are never uploaded.")
            FieldLabel("Microphone")
            ObMenu(options: [(Self.systemDefault, "(System default microphone)")] + devices.map { ($0, $0) }, selection: choice, width: 400)
            FieldLabel("Input level")
            // While a dictation records, its own level shows; otherwise the page's meter (as Windows' AudioPage).
            ProgressBar(fraction: Double(model.phase == .recording ? model.level : meterLevel)).frame(width: 400, height: 10)
                .accessibilityLabel("Input level")
            Caption(problem ?? "Speak to see the meter move. If it stays flat, choose another microphone or check \(privacyPlace).", size: 12.5)
                .padding(.top, 8)
        }
        .onAppear {
            devices = Microphones.names
            startMeter()
        }
        .onDisappear(perform: stopMeter)
        .onChange(of: model.phase.isBusy) { _, busy in if busy { stopMeter() } else { startMeter() } }
    }

    /// The chosen microphone; one that is no longer connected shows as the system default.
    private var choice: Binding<String> {
        Binding(get: { model.settings.microphoneName.flatMap { devices.contains($0) ? $0 : nil } ?? Self.systemDefault },
                set: { name in
                    model.settings.microphoneName = name == Self.systemDefault ? nil : name
                    startMeter()
                })
    }

    private var privacyPlace: String {
        #if os(macOS)
        "System Settings → Privacy & Security → Microphone"
        #else
        "Settings → Privacy & Security → Microphone"
        #endif
    }

    private func startMeter() {
        stopMeter()
        guard !model.phase.isBusy, !model.notes.needsModels else { return } // don't fight a dictation or Extended Notes
        let m = MicrophoneMeter()
        m.onLevel = { meterLevel = $0 }
        do {
            try m.start(microphone: model.settings.microphoneName)
            meter = m
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func stopMeter() {
        meter?.stop()
        meter = nil
        meterLevel = 0
    }
}
