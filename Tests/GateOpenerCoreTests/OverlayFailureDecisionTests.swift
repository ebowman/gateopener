import Foundation
import Testing
@testable import GateOpenerCore

/// Tests for `OverlayFailureDecision`, introduced for bead gateopener-6s8.3
/// to fix the stranded-overlay bug on the gate-open path (see that type's
/// doc comment).
struct OverlayFailureDecisionTests {

    // MARK: - decide(gateResolvedHold:)

    @Test func decideNilHoldAwaitsGateResolution() {
        #expect(OverlayFailureDecision.decide(gateResolvedHold: nil) == .awaitGateResolution)
    }

    @Test func decideNonNilHoldSchedulesFadeWithThatHold() {
        let hold: Duration = .milliseconds(1200)
        #expect(OverlayFailureDecision.decide(gateResolvedHold: hold) == .scheduleFade(hold: hold))
    }

    @Test func decideZeroHoldStillSchedulesFade() {
        // .zero is a legitimate deferred hold (the `.failed` GateState case
        // passes .zero to handleResolved), and must be distinguished from
        // "no hold was deferred at all" (nil) -- not conflated with
        // .awaitGateResolution.
        #expect(OverlayFailureDecision.decide(gateResolvedHold: .zero) == .scheduleFade(hold: .zero))
    }

    /// MUTATION CHECK (per bd memory `gateopener-vacuous-assertion-failure-
    /// mode`): swap the two `decide` cases and confirm the existing
    /// assertions above would then fail, demonstrating they are not vacuous.
    /// This does NOT mutate the production type -- it simulates the swapped
    /// outcome inline and shows the real assertions would catch it.
    @Test func mutationCheckSwappedCasesWouldFailExistingAssertions() {
        let hold: Duration = .milliseconds(1200)

        // Simulated "broken" decide with the two cases swapped.
        func brokenDecide(gateResolvedHold: Duration?) -> OverlayFailureDecision {
            guard let gateResolvedHold else {
                return .scheduleFade(hold: .zero) // swapped: should be .awaitGateResolution
            }
            return .awaitGateResolution // swapped: should be .scheduleFade(hold:)
        }

        // The real decide's own assertions, re-checked against the broken
        // variant to confirm they would fail.
        #expect(brokenDecide(gateResolvedHold: nil) != .awaitGateResolution)
        #expect(brokenDecide(gateResolvedHold: hold) != .scheduleFade(hold: hold))

        // Confirm the REAL implementation still passes (not swapped).
        #expect(OverlayFailureDecision.decide(gateResolvedHold: nil) == .awaitGateResolution)
        #expect(OverlayFailureDecision.decide(gateResolvedHold: hold) == .scheduleFade(hold: hold))
    }

    // MARK: - showsReason(for:)

    @Test func showsReasonTrueForDoorBusyMessage() {
        let message = DoorVideoBusyPolicy.failureMessage(for: .doorBusy)
        #expect(OverlayFailureDecision.showsReason(for: message) == true)
    }

    @Test func showsReasonTrueForTimedOutMessage() {
        let message = DoorVideoBusyPolicy.failureMessage(for: .timedOut)
        #expect(OverlayFailureDecision.showsReason(for: message) == true)
    }

    @Test func showsReasonFalseForNetworkMessage() {
        let message = DoorVideoBusyPolicy.failureMessage(for: .network)
        #expect(OverlayFailureDecision.showsReason(for: message) == false)
    }

    @Test func showsReasonFalseForUnauthorizedMessage() {
        let message = DoorVideoBusyPolicy.failureMessage(for: .unauthorized)
        #expect(OverlayFailureDecision.showsReason(for: message) == false)
    }

    @Test func showsReasonFalseForArbitraryMessage() {
        #expect(OverlayFailureDecision.showsReason(for: "some unrelated string") == false)
    }

    @Test func showsReasonFalseForEmptyMessage() {
        #expect(OverlayFailureDecision.showsReason(for: "") == false)
    }
}
