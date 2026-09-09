import Foundation
import Testing
@testable import GateOpenerCore

/// Tests for `DoorVideoBusyPolicy` (cooldown + offer-outcome classification)
/// and `DoorVideoSessionRegistry`, introduced for epic gateopener-6s8 per
/// memory `comelit-rtc-offer-500-means-door-busy`.
struct DoorVideoBusyPolicyTests {

    // MARK: - waitBeforeOffer

    @Test func nilLastSessionEndedWaitsZero() {
        let wait = DoorVideoBusyPolicy.waitBeforeOffer(lastSessionEnded: nil, now: Date())
        #expect(wait == .zero)
    }

    @Test func endedTwentySecondsAgoWaitsZero() {
        let now = Date()
        let lastEnded = now.addingTimeInterval(-20)
        let wait = DoorVideoBusyPolicy.waitBeforeOffer(lastSessionEnded: lastEnded, now: now)
        #expect(wait == .zero)
    }

    @Test func endedFiveSecondsAgoWaitsTenSeconds() {
        let now = Date()
        let lastEnded = now.addingTimeInterval(-5)
        let wait = DoorVideoBusyPolicy.waitBeforeOffer(lastSessionEnded: lastEnded, now: now)
        let expected: Duration = .seconds(10)
        let delta = wait - expected
        // Assert within 1ms either direction.
        #expect(delta > .milliseconds(-1) && delta < .milliseconds(1))
    }

    @Test func endedExactlyFifteenSecondsAgoWaitsZero() {
        let now = Date()
        let lastEnded = now.addingTimeInterval(-15)
        let wait = DoorVideoBusyPolicy.waitBeforeOffer(lastSessionEnded: lastEnded, now: now)
        #expect(wait == .zero)
    }

    // MARK: - classify

    @Test func classifyHttp200IsAccepted() {
        #expect(DoorVideoBusyPolicy.classify(httpStatus: 200, transportError: nil) == .accepted)
    }

    @Test func classifyHttp500IsDoorBusy() {
        #expect(DoorVideoBusyPolicy.classify(httpStatus: 500, transportError: nil) == .doorBusy)
    }

    @Test func classifyHttp401IsUnauthorized() {
        #expect(DoorVideoBusyPolicy.classify(httpStatus: 401, transportError: nil) == .unauthorized)
    }

    @Test func classifyHttp403IsUnauthorized() {
        #expect(DoorVideoBusyPolicy.classify(httpStatus: 403, transportError: nil) == .unauthorized)
    }

    @Test func classifyOtherFourHundredIsServerError() {
        #expect(DoorVideoBusyPolicy.classify(httpStatus: 404, transportError: nil) == .serverError(404))
    }

    @Test func classifyOtherFiveHundredIsServerError() {
        #expect(DoorVideoBusyPolicy.classify(httpStatus: 503, transportError: nil) == .serverError(503))
    }

    @Test func classifyNilStatusTimedOutTransportIsTimedOut() {
        #expect(DoorVideoBusyPolicy.classify(httpStatus: nil, transportError: .timedOut) == .timedOut)
    }

    @Test func classifyNilStatusOtherTransportIsNetwork() {
        #expect(DoorVideoBusyPolicy.classify(httpStatus: nil, transportError: .other) == .network)
    }

    @Test func classifyNilStatusNilTransportIsNetwork() {
        #expect(DoorVideoBusyPolicy.classify(httpStatus: nil, transportError: nil) == .network)
    }

    @Test func classifyStatusTakesPrecedenceOverTransportError() {
        // A non-nil status must win even if a transportError is also set.
        #expect(DoorVideoBusyPolicy.classify(httpStatus: 200, transportError: .timedOut) == .accepted)
        #expect(DoorVideoBusyPolicy.classify(httpStatus: 500, transportError: .other) == .doorBusy)
    }

    // MARK: - shouldRetry

    @Test func shouldRetryTrueOnlyForNetwork() {
        #expect(DoorVideoBusyPolicy.shouldRetry(.network) == true)
    }

    @Test func shouldRetryFalseForTimedOut() {
        #expect(DoorVideoBusyPolicy.shouldRetry(.timedOut) == false)
    }

    @Test func shouldRetryFalseForDoorBusy() {
        #expect(DoorVideoBusyPolicy.shouldRetry(.doorBusy) == false)
    }

    @Test func shouldRetryFalseForAccepted() {
        #expect(DoorVideoBusyPolicy.shouldRetry(.accepted) == false)
    }

    @Test func shouldRetryFalseForUnauthorized() {
        #expect(DoorVideoBusyPolicy.shouldRetry(.unauthorized) == false)
    }

    @Test func shouldRetryFalseForServerError() {
        #expect(DoorVideoBusyPolicy.shouldRetry(.serverError(503)) == false)
    }

    // MARK: - DoorVideoSessionRegistry

    @Test @MainActor func registryWaitBeforeOfferReflectsRecordedSessionEnd() {
        let registry = DoorVideoSessionRegistry()
        let start = Date()
        registry.recordSessionEnded(at: start)
        let wait = registry.waitBeforeOffer(now: start.addingTimeInterval(5))
        let expected: Duration = .seconds(10)
        let delta = wait - expected
        #expect(delta > .milliseconds(-1) && delta < .milliseconds(1))
    }

    @Test @MainActor func registryWaitBeforeOfferZeroWhenNoSessionRecorded() {
        let registry = DoorVideoSessionRegistry()
        #expect(registry.waitBeforeOffer(now: Date()) == .zero)
    }

    @Test @MainActor func registryRecordSessionAcceptedDoesNotAffectWait() {
        let registry = DoorVideoSessionRegistry()
        let now = Date()
        registry.recordSessionAccepted(at: now)
        // No session END recorded, so wait must be zero even though an
        // accept was recorded moments ago.
        #expect(registry.waitBeforeOffer(now: now) == .zero)
    }
}
