import Foundation
import Testing
@testable import ObertonCore

/// `Microphones.settle`'s wait for a microphone switching formats: up to 20 × 50 ms, as before, but suspending instead
/// of `Thread.sleep`ing, so the main thread (the hotkey, the pill) keeps going meanwhile.
@Suite struct MicrophoneSettleTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Test func readyAtOnceDoesNotWait() async {
        let started = Date()
        var checks = 0
        let ok = await Microphones.waitUntil { checks += 1; return true }
        #expect(ok)
        #expect(checks == 1)
        #expect(Date().timeIntervalSince(started) < 0.04)
    }

    @Test func waitsUntilReady() async {
        let started = Date()
        let ok = await Microphones.waitUntil { Date().timeIntervalSince(started) > 0.2 }
        #expect(ok)
        let took = Date().timeIntervalSince(started)
        #expect(took > 0.19 && took < 0.6, "took \(took)")
    }

    /// Never ready: gives up after about a second (20 checks, 19 waits of 50 ms), and says so.
    @Test func givesUpAfterASecond() async {
        let started = Date()
        var checks = 0
        let ok = await Microphones.waitUntil { checks += 1; return false }
        #expect(!ok)
        #expect(checks == 21) // the 20 tries, then the last word
        let took = Date().timeIntervalSince(started)
        #expect(took > 0.9 && took < 2.0, "took \(took)")
    }

    /// On the main actor, other main-actor work runs while it waits (the old loop blocked the thread for the second).
    @MainActor @Test func mainActorKeepsRunning() async {
        let ticks = Flag()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                ticks.bump()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let started = Date()
        _ = await Microphones.waitUntil { Date().timeIntervalSince(started) > 0.4 }
        ticker.cancel()
        #expect(ticks.count >= 8, "main-actor ticks while waiting: \(ticks.count)")
    }
}
