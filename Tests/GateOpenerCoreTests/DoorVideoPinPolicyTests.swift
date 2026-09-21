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
        // Pinned, elapsed >= 300, AND this is the 4th consecutive failure
        // (the default maxConsecutiveFailures): per rule order, maxDuration
        // must win.
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 300, consecutiveFailures: 4)
                == .stop(.maxDuration)
        )
    }

    // MARK: - Rule 3: too many consecutive failures

    /// With the default `maxConsecutiveFailures == 4`, the 4th consecutive
    /// failure stops the pin.
    @Test func fourthConsecutiveFailureStopsWithTooManyFailures() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 4)
                == .stop(.tooManyFailures)
        )
    }

    @Test func thirdConsecutiveFailureRenewsInsteadOfStopping() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 3)
                == .renew(after: 10)
        )
    }

    @Test func failuresBeyondMaxAlsoStop() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 5)
                == .stop(.tooManyFailures)
        )
    }

    // MARK: - Rule 4: failed but under the failure limit renews with the escalating schedule

    /// Failures 1, 2, 3 map to the default schedule's 2, 5, 10 (last value
    /// reused beyond the array's length, exercised separately below).
    @Test func failureScheduleEscalatesAcrossConsecutiveFailures() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 1)
                == .renew(after: 2)
        )
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 2)
                == .renew(after: 5)
        )
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 3)
                == .renew(after: 10)
        )
    }

    /// Beyond the schedule's length, the LAST element is reused rather than
    /// going out of bounds.
    @Test func failureScheduleClampsToLastElementBeyondArrayLength() {
        let policy = DoorVideoPinPolicy(maxConsecutiveFailures: 100, failureBackoffs: [2, 5, 10])
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 4)
                == .renew(after: 10)
        )
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 50)
                == .renew(after: 10)
        )
    }

    /// An EMPTY schedule behaves as `[2]` -- every failure backs off 2s.
    @Test func emptyFailureScheduleBehavesAsSingleTwoSecondBackoff() {
        let policy = DoorVideoPinPolicy(maxConsecutiveFailures: 100, failureBackoffs: [])
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 1)
                == .renew(after: 2)
        )
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 5)
                == .renew(after: 2)
        )
    }

    @Test func customFailureScheduleUsesProvidedValues() {
        let policy = DoorVideoPinPolicy(maxConsecutiveFailures: 100, failureBackoffs: [1, 3, 7.5])
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 1)
                == .renew(after: 1)
        )
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 2)
                == .renew(after: 3)
        )
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 3)
                == .renew(after: 7.5)
        )
    }

    // MARK: - Compat init (single failureBackoff:)

    /// The compat initializer taking a single `failureBackoff:` behaves as
    /// `failureBackoffs: [value]` -- no escalation, every failure uses the
    /// same value.
    @Test func compatInitWithSingleFailureBackoffAppliesToEveryFailure() {
        let policy = DoorVideoPinPolicy(maxConsecutiveFailures: 100, failureBackoff: 7.5)
        #expect(policy.failureBackoffs == [7.5])
        #expect(policy.failureBackoff == 7.5)
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 1)
                == .renew(after: 7.5)
        )
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 4)
                == .renew(after: 7.5)
        )
    }

    // MARK: - Door-busy minimum backoff floor

    /// `failureWasDoorBusy: true` raises the schedule's 2s and 5s values up
    /// to the 10s floor, but leaves the schedule's own 10s unaffected (the
    /// floor only ever raises, never lowers).
    @Test func doorBusyFloorRaisesSmallScheduledValuesButLeavesTenUnaffected() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(
                isPinned: true, outcome: .failed, pinnedElapsed: 0,
                consecutiveFailures: 1, failureWasDoorBusy: true
            ) == .renew(after: 10)
        )
        #expect(
            policy.decide(
                isPinned: true, outcome: .failed, pinnedElapsed: 0,
                consecutiveFailures: 2, failureWasDoorBusy: true
            ) == .renew(after: 10)
        )
        #expect(
            policy.decide(
                isPinned: true, outcome: .failed, pinnedElapsed: 0,
                consecutiveFailures: 3, failureWasDoorBusy: true
            ) == .renew(after: 10)
        )
    }

    /// A door-busy failure still counts as a failure and does not change
    /// rule order: hitting the failure limit still stops the pin even when
    /// `failureWasDoorBusy` is `true`.
    @Test func doorBusyFailureStillStopsAtFailureLimit() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(
                isPinned: true, outcome: .failed, pinnedElapsed: 0,
                consecutiveFailures: 4, failureWasDoorBusy: true
            ) == .stop(.tooManyFailures)
        )
    }

    /// A custom `doorBusyMinimumBackoff` is honoured.
    @Test func customDoorBusyMinimumBackoffHonoured() {
        var policy = DoorVideoPinPolicy(failureBackoffs: [2])
        policy.doorBusyMinimumBackoff = 20
        #expect(
            policy.decide(
                isPinned: true, outcome: .failed, pinnedElapsed: 0,
                consecutiveFailures: 1, failureWasDoorBusy: true
            ) == .renew(after: 20)
        )
    }

    /// `failureWasDoorBusy: false` (the default) never applies the floor.
    @Test func failureWasDoorBusyDefaultsToFalse() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(isPinned: true, outcome: .failed, pinnedElapsed: 0, consecutiveFailures: 1)
                == .renew(after: 2)
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

    /// A stale `consecutiveFailures` count must NEVER stop an `.ended`
    /// outcome — only `.failed` can trigger `tooManyFailures` (rule 3 is
    /// explicitly gated on `outcome == .failed`). This matters because the
    /// coordinator resets `consecutiveFailures` to `0` on `.streaming`, but
    /// a caller bug that failed to reset it before an `.ended` outcome
    /// must not silently turn into a wrongful stop.
    ///
    /// MUTATION CHECK: removing the `outcome == .failed` guard from rule 3
    /// (`if outcome == .failed, consecutiveFailures >= failureLimit`),
    /// leaving only `consecutiveFailures >= failureLimit`, would make this
    /// call return `.stop(.tooManyFailures)` instead, failing the
    /// `#expect` below.
    @Test func endedWithStaleHighFailureCountStillRenewsImmediately() {
        let policy = DoorVideoPinPolicy()
        #expect(
            policy.decide(isPinned: true, outcome: .ended, pinnedElapsed: 0, consecutiveFailures: 99)
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

    @Test func stopMessageForTooManyFailuresWithNoLastFailureUsesGenericMessage() {
        #expect(DoorVideoPinPolicy.stopMessage(.tooManyFailures) == "Camera unavailable - unpinned")
    }

    @Test func stopMessageForTooManyFailuresWithNilLastFailureUsesGenericMessage() {
        #expect(
            DoorVideoPinPolicy.stopMessage(.tooManyFailures, lastFailure: nil)
                == "Camera unavailable - unpinned"
        )
    }

    @Test func stopMessageForTooManyFailuresWithEmptyLastFailureUsesGenericMessage() {
        #expect(
            DoorVideoPinPolicy.stopMessage(.tooManyFailures, lastFailure: "")
                == "Camera unavailable - unpinned"
        )
    }

    /// A short `lastFailure` is included verbatim, prefixed with "Unpinned - ".
    @Test func stopMessageForTooManyFailuresWithLastFailureIncludesReason() {
        #expect(
            DoorVideoPinPolicy.stopMessage(.tooManyFailures, lastFailure: "Could not reach door camera")
                == "Unpinned - Could not reach door camera"
        )
    }

    /// The formatted message must never exceed 40 characters, even for a
    /// `lastFailure` that would otherwise overflow it.
    @Test func stopMessageForTooManyFailuresTruncatesLongLastFailure() {
        let long = "This is a very long failure reason that will not fit"
        let message = DoorVideoPinPolicy.stopMessage(.tooManyFailures, lastFailure: long)
        #expect(message != nil)
        #expect((message ?? "").count <= 40)
        #expect((message ?? "").hasPrefix("Unpinned - "))
        #expect((message ?? "").hasSuffix("…"))
    }

    /// Every possible `lastFailure` length exercises the exact <= 40
    /// invariant, not merely the one long example above.
    @Test func stopMessageForTooManyFailuresStaysWithinFortyCharactersAcrossLengths() {
        for length in stride(from: 0, through: 60, by: 1) {
            let reason = String(repeating: "x", count: length)
            let message = DoorVideoPinPolicy.stopMessage(.tooManyFailures, lastFailure: reason)
            #expect((message ?? "").count <= 40)
        }
    }

    @Test func stopMessageForNotPinnedIsNil() {
        #expect(DoorVideoPinPolicy.stopMessage(.notPinned) == nil)
    }

    // MARK: - init defaults

    @Test func defaultInitValues() {
        let policy = DoorVideoPinPolicy()
        #expect(policy.maxPinnedDuration == 300)
        #expect(policy.maxConsecutiveFailures == 4)
        #expect(policy.failureBackoffs == [2, 5, 10])
        #expect(policy.failureBackoff == 2)
        #expect(policy.doorBusyMinimumBackoff == 10)
    }
}
