import Testing
@testable import GateOpenerCore

/// Tests for `DoorVideoSessionRetention.decision(forExistingPhase:)`, the
/// pure retain-or-replace policy for a repeat door-video open request
/// introduced for epic gateopener-ufk.
struct DoorVideoSessionRetentionTests {
    @Test func noExistingSessionReplaces() {
        #expect(DoorVideoSessionRetention.decision(forExistingPhase: nil) == .replace)
    }

    @Test func idlePhaseReplaces() {
        #expect(DoorVideoSessionRetention.decision(forExistingPhase: .idle) == .replace)
    }

    @Test func connectingPhaseRetains() {
        #expect(DoorVideoSessionRetention.decision(forExistingPhase: .connecting) == .retain)
    }

    @Test func streamingPhaseRetains() {
        #expect(DoorVideoSessionRetention.decision(forExistingPhase: .streaming) == .retain)
    }

    @Test func endedPhaseReplaces() {
        #expect(DoorVideoSessionRetention.decision(forExistingPhase: .ended) == .replace)
    }

    @Test func failedPhaseReplaces() {
        #expect(DoorVideoSessionRetention.decision(forExistingPhase: .failed) == .replace)
    }

    @Test(arguments: [
        (DoorVideoSessionPhase.idle, DoorVideoSessionRetention.replace),
        (.connecting, .retain),
        (.streaming, .retain),
        (.ended, .replace),
        (.failed, .replace),
    ])
    func allPhasesMatchExpectedDecision(phase: DoorVideoSessionPhase, expected: DoorVideoSessionRetention) {
        #expect(DoorVideoSessionRetention.decision(forExistingPhase: phase) == expected)
    }
}
