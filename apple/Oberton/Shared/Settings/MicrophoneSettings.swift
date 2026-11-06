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
            FluentMeter(fraction: Double(model.phase == .recording ? model.level : meterLevel)).frame(width: 400, height: 10)
                .accessibilityLabel("Input level")
            Caption(problem ?? "Speak to see the meter move. If it stays flat, choose another microphone or check \(privacyPlace).", bottom: 0)
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
        // Don't fight an active dictation (Windows checks only that). On iPhone and iPad also not Extended Notes: there the
        // app has one audio session, and a second recorder would reset the one Notes records with.
        guard !model.phase.isBusy else { return }
        #if os(iOS)
        guard !model.notes.needsModels else { return }
        #endif
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

/// WPF's Fluent ProgressBar at Height 10 (AudioPage's level): inside a 1-pt margin, a square track in
/// ControlStrongStroke (#72000000 / dark #8BFFFFFF), and over it the indicator, a ControlStroke-tinted strip
/// (#0F000000 / #12FFFFFF) holding a rounded bar (radius 6, so fully round at 8 tall) in the system accent.
struct FluentMeter: View {
    var fraction: Double
    @Environment(\.ob) private var ob

    var body: some View {
        GeometryReader { g in
            let inner = CGSize(width: max(0, g.size.width - 2), height: max(0, g.size.height - 2))
            let w = inner.width * min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Rectangle().fill(ob.dark ? Color.white.opacity(0.545) : Color.black.opacity(0.447))
                ZStack {
                    Rectangle().fill(ob.dark ? Color.white.opacity(0.07) : Color.black.opacity(0.059))
                    RoundedRectangle(cornerRadius: min(6, inner.height / 2, w / 2)).fill(SystemAccent.fill(dark: ob.dark))
                }
                .frame(width: w)
            }
            .frame(width: inner.width, height: inner.height)
            .offset(x: 1, y: 1)
        }
    }
}
