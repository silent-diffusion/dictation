import AVFoundation
import Foundation

/// What happens to a recording's microphone while it records: a phone call or another app takes the audio session
/// (iPhone and iPad), the input route changes (a headset plugged in or pulled out, AirPods connecting), or the engine's
/// configuration changes under it (macOS too: another default input). AVAudioEngine stops in all of these and says
/// nothing; this watches for them so the recorder can pause, keep what it has, and carry on through the new route.
/// Shared by dictation (`LiveTranscriber`) and, when its lane takes it up, Extended Notes' recorder.
public final class AudioInterruptions: @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        /// A call or another app took the audio session.
        case interruptionBegan
        /// It is over; `shouldResume`: the system says carrying on is welcome (it isn't when, say, the user started
        /// music in the meantime).
        case interruptionEnded(shouldResume: Bool)
        /// The input route changed (the reason as AVAudioSession gives it), or the engine's configuration did.
        case routeChanged
    }

    public enum Action: Equatable, Sendable {
        /// Hold on: the microphone is someone else's for now. The recording so far is kept.
        case pause
        /// Open the microphone again, through whatever route there is now.
        case restart
        /// Ended: the user's call: stop the recording here, keeping what was said.
        case finish
        case nothing
    }

    /// The decision, from the event and where the recording stands. `running`: the engine is still running (a route
    /// change it rode out needs nothing).
    public static func action(for event: Event, running: Bool, interrupted: Bool) -> Action {
        switch event {
        case .interruptionBegan: return interrupted ? .nothing : .pause
        case .interruptionEnded(let shouldResume): return shouldResume ? .restart : .finish
        case .routeChanged: return interrupted || running ? .nothing : .restart
        }
    }

    /// The pill's status line for an action (nil: none).
    public static func status(for action: Action) -> String? {
        switch action {
        case .pause: "Paused: a call or another app has the microphone. What you said is kept."
        case .restart: nil
        case .finish: "The microphone was taken by another app; finishing with what was said."
        case .nothing: nil
        }
    }

    private var observers: [NSObjectProtocol] = []

    /// Watch `engine` (its configuration changes) and, on iOS, the shared audio session. `handle` runs on the main queue.
    public init(engine: AVAudioEngine, handle: @escaping @MainActor (Event) -> Void) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            MainActor.assumeIsolated { handle(.routeChanged) }
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            let event: Event = type == .began ? .interruptionBegan : .interruptionEnded(shouldResume: options.contains(.shouldResume))
            MainActor.assumeIsolated { handle(event) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            guard let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange, .categoryChange:
                MainActor.assumeIsolated { handle(.routeChanged) }
            default: break
            }
        })
        #endif
    }

    /// Stop watching (also on deinit).
    public func cancel() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    deinit { cancel() }
}
