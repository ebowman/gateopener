import Testing
@testable import GateOpenerCore

/// Tests for `DoorVideoPinPolicy`, the pure renew-or-stop policy for a
/// pinned door video session, bounded per user ruling in `../comelit` bead
/// `comelit-ecw.11` ("do NOT hammer the door forever").
struct DoorVideoPinPolicyTests {
    // MARK: - Rule 1: not pinned

    @Test func notPinnedStopsRegardlessOfOtherParameters() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(isPinned: false, outcome: .ended, pinnedElapsed: 0, consecutiveFailures: 0)
                == .stop(.notPinned)
        )
        #expect(
            policy.decide(isPinned: false, outcome: .failed, pinnedElapsed: 9999, consecutiveFailures: 99)
                == .stop(.notPinned)
        )
    }

    // MARK: - Rule 2: max duration

    @Test func pinnedElapsedAtMaxDurationStops() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(isPinned: true, outcome: .ended, pinnedElapsed: 300, consecutiveFailures: 0)
                == .stop(.maxDuration)
        )
    }

    @Test func pinnedElapsedPastMaxDurationStops() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(isPinned: true, outcome: .ended, pinnedElapsed: 301, consecutiveFailures: 0)
                == .stop(.maxDuration)
        )
    }

    @Test func pinnedElapsedJustUnderMaxDurationDoesNotStopOnDurationAlone() {
        let policy = DoorVideoPinPolicy()
        // 299.9 < 300 -> falls through to the ended/renew rule.
        #expect(
            policy.decide(isPinned: true, outcome: .ended, pinnedElapsed: 299.9, consecutiveFailures: 0)
                == .renew(after: 0)
        )
    }

    // MARK: - Rule order: maxDuration takes priority over tooManyFailures

    @Test func maxDurationTakesPriorityOverTooManyFailuresWhenBothApply() {
        let policy = DoorVideoPinPolicy()
        // Pinned, elapsed >= 300, AND this is the 3rd consecutive failure:
        // per rule order, maxDuration must win.
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 300, consecutiveFailures: 3)
                == .stop(.maxDuration)
        )
    }

    // MARK: - Rule 3: too many consecutive failures

    @Test func thirdConsecutiveFailureStopsWithTooManyFailures() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 3)
                == .stop(.tooManyFailures)
        )
    }

    @Test func secondConsecutiveFailureRenewsInsteadOfStopping() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 2)
                == .renew(after: 2)
        )
    }

    @Test func failuresBeyondMaxAlsoStop() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 4)
                == .stop(.tooManyFailures)
        )
    }

    // MARK: - Rule 4: failed but under the failure limit renews with backoff

    @Test func firstFailureRenewsWithFailureBackoff() {
        let policy = DoorVideoPinPolicy(failureBackoff: 2)
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 1)
                == .renew(after: 2)
        )
    }

    @Test func failureBackoffUsesCustomValue() {
        let policy = DoorVideoPinPolicy(failureBackoff: 7.5)
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 1)
                == .renew(after: 7.5)
        )
    }

    // MARK: - Rule 5: ended renews immediately

    @Test func endedRenewsImmediately() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(isPinned: true, outcome: .ended, pinnedElapsed: 0, consecutiveFailures: 0)
                == .renew(after: 0)
        )
    }

    // MARK: - Defensive: negative pinnedElapsed treated as 0

    @Test func negativePinnedElapsedTreatedAsZeroInDecide() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(isPinned: true, outcome: .ended, pinnedElapsed: -50, consecutiveFailures: 0)
                == .renew(after: 0)
        )
    }

    @Test func negativePinnedElapsedDoesNotFalselyTriggerMaxDuration() {
        let policy = DoorVideoPinPolicy(maxPinnedDuration: 10)
        #expect(
            policy.decide(isPinned: true, outcome: .ended, pinnedElapsed: -1, consecutiveFailures: 0)
                == .renew(after: 0)
        )
    }

    // MARK: - Defensive: maxConsecutiveFailures <= 0 behaves as 1

    @Test func zeroMaxConsecutiveFailuresStopsOnFirstFailure() {
        let policy = DoorVideoPinPolicy(maxConsecutiveFailures: 0)
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 1)
                == .stop(.tooManyFailures)
        )
    }

    @Test func negativeMaxConsecutiveFailuresStopsOnFirstFailure() {
        let policy = DoorVideoPinPolicy(maxConsecutiveFailures: -5)
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 1)
                == .stop(.tooManyFailures)
        )
    }

    // MARK: - Defensive: non-positive maxPinnedDuration means cap immediately reached

    @Test func zeroMaxPinnedDurationStopsImmediately() {
        let policy = DoorVideoPinPolicy(maxPinnedDuration: 0)
        #expect(
            policy.decide(isPinned: true, outcome: .ended, pinnedElapsed: 0, consecutiveFailures: 0)
                == .stop(.maxDuration)
        )
    }

    @Test func negativeMaxPinnedDurationStopsImmediately() {
        let policy = DoorVideoPinPolicy(maxPinnedDuration: -10)
        #expect(
            policy.decide(isPinned: true, outcome: .ended, pinnedElapsed: 0, consecutiveFailures: 0)
                == .stop(.maxDuration)
        )
    }

    // MARK: - Custom values

    @Test func customMaxPinnedDurationHonoured() {
        let policy = DoorVideoPinPolicy(maxPinnedDuration: 60)
        #expect(
            policy.decide(isPinned: true, outcome: .ended, pinnedElapsed: 59.9, consecutiveFailures: 0)
                == .renew(after: 0)
        )
        #expect(
            policy.decide(isPinned: true, outcome: .ended, pinnedElapsed: 60, consecutiveFailures: 0)
                == .stop(.maxDuration)
        )
    }

    @Test func customMaxConsecutiveFailuresHonoured() {
        let policy = DoorVideoPinPolicy(maxConsecutiveFailures: 1)
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 1)
                == .stop(.tooManyFailures)
        )
    }

    // MARK: - remaining()

    @Test func remainingComputesBudgetLeft() {
        let policy = DoorVideoPinPolicy(maxPinnedDuration: 300)
        #expect(policy.remaining(pinnedElapsed: 100) == 200)
    }

    @Test func remainingClampsAtZeroWhenElapsedExceedsMax() {
        let policy = DoorVideoPinPolicy(maxPinnedDuration: 300)
        #expect(policy.remaining(pinnedElapsed: 500) == 0)
    }

    @Test func remainingClampsAtZeroWhenElapsedEqualsMax() {
        let policy = DoorVideoPinPolicy(maxPinnedDuration: 300)
        #expect(policy.remaining(pinnedElapsed: 300) == 0)
    }

    @Test func remainingTreatsNegativeElapsedAsZero() {
        let policy = DoorVideoPinPolicy(maxPinnedDuration: 300)
        #expect(policy.remaining(pinnedElapsed: -50) == 300)
    }

    @Test func remainingClampsAtZeroForNonPositiveMaxPinnedDuration() {
        let policy = DoorVideoPinPolicy(maxPinnedDuration: 0)
        #expect(policy.remaining(pinnedElapsed: 0) == 0)
    }

    // MARK: - stopMessage

    @Test func stopMessageForMaxDuration() {
        #expect(DoorVideoPinPolicy.stopMessage(.maxDuration) == "Stream ended - tap to resume")
    }

    @Test func stopMessageForTooManyFailures() {
        #expect(DoorVideoPinPolicy.stopMessage(.tooManyFailures) == "Camera unavailable - unpinned")
    }

    @Test func stopMessageForNotPinnedIsNil() {
        #expect(DoorVideoPinPolicy.stopMessage(.notPinned) == nil)
    }

    // MARK: - init defaults

    @Test func defaultInitValues() {
        let policy = DoorVideoPinPolicy()
        #expect(policy.maxPinnedDuration == 300)
        #expect(policy.maxConsecutiveFailures == 3)
        #expect(policy.failureBackoff == 2)
    }
}
