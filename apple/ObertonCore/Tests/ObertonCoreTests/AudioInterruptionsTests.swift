import Testing
@testable import ObertonCore

/// What a recording does when a call, another app or a route change takes its microphone.
@Suite struct AudioInterruptionsTests {
    typealias A = AudioInterruptions

    @Test func aCallPausesOnce() {
        #expect(A.action(for: .interruptionBegan, running: true, interrupted: false) == .pause)
        #expect(A.action(for: .interruptionBegan, running: false, interrupted: true) == .nothing)
    }

    @Test func theCallEnding() {
        // Welcome back: the microphone opens again and the recording carries on.
        #expect(A.action(for: .interruptionEnded(shouldResume: true), running: false, interrupted: true) == .restart)
        // Not welcome (the user started something else): finish with what was said.
        #expect(A.action(for: .interruptionEnded(shouldResume: false), running: false, interrupted: true) == .finish)
    }

    @Test func aNewRoute() {
        // The engine stopped (headset pulled out, AirPods connected): open the microphone there is now.
        #expect(A.action(for: .routeChanged, running: false, interrupted: false) == .restart)
        // It rode it out: nothing to do.
        #expect(A.action(for: .routeChanged, running: true, interrupted: false) == .nothing)
        // During a call the route changes too; the call's end restarts it.
        #expect(A.action(for: .routeChanged, running: false, interrupted: true) == .nothing)
    }

    @Test func thePillSaysWhatHappened() {
        #expect(A.status(for: .pause)?.contains("What you said is kept") == true)
        #expect(A.status(for: .finish) != nil)
        #expect(A.status(for: .restart) == nil)
        #expect(A.status(for: .nothing) == nil)
    }
}
