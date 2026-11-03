#if os(macOS) && DEBUG
import Foundation
import ObertonCore

/// Debug only: starts and stops dictations, Extended Notes sessions and the Microphone page's meter over and over, in
/// quick succession and overlapping, then quits. Run under Address or Thread Sanitizer to catch audio-engine lifetime
/// and threading bugs: `OBERTON_STRESS=<rounds> OBERTON_DATA_DIR=<scratch folder>` (the app writes its history and
/// notes there). Progress goes to the log.
@MainActor
enum StressTest {
    static func run(_ model: AppModel, rounds: Int) {
        Task { @MainActor in
            Log.info("Stress: \(rounds) rounds")
            for round in 1...rounds {
                Log.info("Stress: round \(round)")
                meter()
                await dictation(model, round: round)
                if round % 3 == 0 { await notes(model, round: round) }
            }
            Log.info("Stress: done")
            exit(0)
        }
    }

    private static func pause(_ seconds: ClosedRange<Double>) async {
        try? await Task.sleep(for: .seconds(Double.random(in: seconds)))
    }

    /// The Microphone page opens, closes, and opens again with another microphone.
    private static func meter() {
        for name in [nil] + Microphones.names.prefix(2).map(Optional.some) {
            let m = MicrophoneMeter()
            try? m.start(microphone: name)
        }
    }

    private static func waitIdle(_ model: AppModel) async {
        for _ in 0..<300 where model.phase.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
        if model.phase.isBusy { model.cancel() }
    }

    private static func dictation(_ model: AppModel, round: Int) async {
        model.start()
        await pause(0.05...1.5)
        switch round % 4 {
        case 0: // cancel, then start again at once
            model.cancel()
            model.start()
            await pause(0.05...0.5)
            model.cancel()
        case 1:
            model.stop()
            await pause(0...0.3)
            model.cancel() // while it transcribes
            model.start()
            await pause(0.2...0.8)
            model.stop()
        default:
            model.stop()
        }
        await waitIdle(model)
    }

    private static func notes(_ model: AppModel, round: Int) async {
        let source = NotesSource.allCases[(round / 3) % NotesSource.allCases.count]
        do { try await model.notes.start(source: source) } catch {
            Log.info("Stress: notes didn't start (\(error.localizedDescription))")
            return
        }
        await pause(0.5...2)
        await dictation(model, round: round + 1) // a dictation pauses the session
        meter()
        await model.notes.stop()
    }
}
#endif
