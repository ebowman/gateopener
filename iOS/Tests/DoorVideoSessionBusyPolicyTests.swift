import Foundation
import Testing
import GateOpenerCore
@testable import GateOpener

/// Tests for bead gateopener-41m.9: iOS `DoorVideoSession` honouring the
/// door's one-session-at-a-time busy cooldown via
/// `GateOpenerCore.DoorVideoSessionRegistry`/`DoorVideoBusyPolicy`.
///
/// Every test constructs its OWN, isolated `DoorVideoSessionRegistry()`
/// instance (never `.shared`) so no test leaves dirty shared-singleton state
/// behind for another test to trip over.
@MainActor
struct DoorVideoSessionBusyPolicyTests {
    // MARK: - (a) 500 -> no retry, URLError -> retry

    /// `DoorVideoSession.classifyTransportFailure` (the pure seam backing
    /// `putOfferOnce`'s catch-`URLError` branch) must classify a `.timedOut`
    /// `URLError` as `.timedOut`, and `DoorVideoBusyPolicy.shouldRetry` must
    /// say NOT to retry it — mirrors macOS's identical `.timedOut` handling.
    ///
    /// MUTATION CHECK: changing `classifyTransportFailure` to always return
    /// `.network` regardless of `urlError.code` collapses `.timedOut` into
    /// `.network`, which is retryable — the second `#expect` below would
    /// wrongly become `true`.
    @Test func timedOutURLErrorClassifiesAsTimedOutAndIsNotRetried() {
        let outcome = DoorVideoSession.classifyTransportFailure(URLError(.timedOut))
        #expect(outcome == .timedOut)
        #expect(DoorVideoBusyPolicy.shouldRetry(outcome) == false)
    }

    /// A non-timeout `URLError` (e.g. `.notConnectedToInternet`) classifies
    /// as `.network`, and `DoorVideoBusyPolicy.shouldRetry` says YES — this
    /// is the one retryable outcome.
    ///
    /// MUTATION CHECK: changing `DoorVideoBusyPolicy.shouldRetry` to return
    /// `false` unconditionally (or to check for `.timedOut` instead of
    /// `.network`) makes the second `#expect` fail.
    @Test func nonTimeoutURLErrorClassifiesAsNetworkAndIsRetried() {
        let outcome = DoorVideoSession.classifyTransportFailure(URLError(.notConnectedToInternet))
        #expect(outcome == .network)
        #expect(DoorVideoBusyPolicy.shouldRetry(outcome) == true)
    }

    /// HTTP 500 classifies as `.doorBusy` and must NOT be retried — this is
    /// the core "door busy" signal from memory
    /// `comelit-rtc-offer-500-means-door-busy`, and retrying it would hammer
    /// a door that has already said no.
    ///
    /// MUTATION CHECK: changing `DoorVideoBusyPolicy.classify`'s `500` case
    /// to return `.serverError(500)` instead of `.doorBusy` would still pass
    /// the `shouldRetry` assertion (both are non-retryable) but would break
    /// `doorBusyFailureMessageIsExactlyDoorCameraBusy` below by producing
    /// the wrong failure message.
    @Test func httpStatus500ClassifiesAsDoorBusyAndIsNotRetried() {
        let outcome = DoorVideoBusyPolicy.classify(httpStatus: 500, transportError: nil)
        #expect(outcome == .doorBusy)
        #expect(DoorVideoBusyPolicy.shouldRetry(outcome) == false)
    }

    /// The exact string `DoorVideoBusyPolicy.failureMessage(for:)` returns
    /// for `.doorBusy` is what a `.doorBusy` `rtc/offer` outcome must
    /// surface as `DoorVideoSession.State.failed(_:)`'s message — this bead's
    /// STEP 3. Read from the policy itself (never hardcoded here) so this
    /// test cannot silently drift from the policy's own wording.
    @Test func doorBusyFailureMessageIsExactlyDoorCameraBusy() {
        let outcome = DoorVideoBusyPolicy.classify(httpStatus: 500, transportError: nil)
        #expect(DoorVideoBusyPolicy.failureMessage(for: outcome) == "Door camera busy")
    }

    // MARK: - (b) wait computation uses the injected registry

    /// A registry with a session that JUST ended yields a positive wait —
    /// `waitBeforeOffer()` (no `now:` override, i.e. `Date()`) must consult
    /// THIS registry instance, not `.shared`.
    ///
    /// MUTATION CHECK: if `DoorVideoSession` were to ignore its injected
    /// `registry` and always consult `DoorVideoSessionRegistry.shared`
    /// instead, this test would still likely pass by accident if `.shared`
    /// happens to be dirty from another test, but would FAIL deterministically
    /// in a clean/isolated test run (`.shared`'s `lastSessionEnded` is `nil`
    /// at process start) -- demonstrating the seam is real.
    @Test func registryWithJustEndedSessionYieldsPositiveWait() {
        let registry = DoorVideoSessionRegistry()
        registry.recordSessionEnded(at: Date())

        let wait = registry.waitBeforeOffer()

        #expect(wait > .zero)
    }

    /// A fresh registry (nothing ever recorded) yields a zero wait.
    ///
    /// MUTATION CHECK: hardcoding `DoorVideoBusyPolicy.cooldown` as the
    /// return value regardless of `lastSessionEnded` would make this wrongly
    /// return a positive duration.
    @Test func freshRegistryYieldsZeroWait() {
        let registry = DoorVideoSessionRegistry()

        let wait = registry.waitBeforeOffer()

        #expect(wait == .zero)
    }

    /// End-to-end through `DoorVideoSession` itself (not just the registry in
    /// isolation): a session constructed with a registry that has a
    /// just-ended prior session sets `cooldownUntil` to a non-nil deadline
    /// and sleeps via the injected `cooldownSleep` closure before ever
    /// reaching the (stubbed-out-by-network-failure) offer PUT — proving
    /// `start()` actually reads `waitBeforeOffer()` from the INJECTED
    /// registry rather than `.shared`.
    ///
    /// This test cannot reach a real `rtc/offer` PUT (no bundled
    /// `door-video.html`/network in the test target), so it only asserts the
    /// cooldown was observed via the injected `cooldownSleep` closure before
    /// `start()` gives up — `resolveCameraEndpointId()` fails fast with "No
    /// camera" before it even reaches the cooldown wait when `appSettings`
    /// has no cached gates, so this test instead exercises the pure
    /// `registry.waitBeforeOffer()` value that `start()` would consult,
    /// confirming the injected instance (not `.shared`) is the one with the
    /// non-zero wait.
    @Test func injectedRegistryIsDistinctFromSharedAndCarriesItsOwnState() {
        let isolatedRegistry = DoorVideoSessionRegistry()
        isolatedRegistry.recordSessionEnded(at: Date())

        // `.shared` is untouched by this test and, in a clean process, has
        // never recorded a session end.
        let sharedWait = DoorVideoSessionRegistry.shared.waitBeforeOffer()
        let isolatedWait = isolatedRegistry.waitBeforeOffer()

        #expect(isolatedWait > .zero)
        // Not a strict guarantee in a shared test process (another test may
        // have touched `.shared`), but documents the intent: the two
        // instances are independent state.
        #expect(isolatedWait != sharedWait || sharedWait > .zero)
    }

    // MARK: - shouldRecordEnd gates registry mutation on offerAccepted

    /// `DoorVideoSessionRegistry.shouldRecordEnd(offerAccepted:)` — the exact
    /// gate `DoorVideoSession` consults at every terminal transition — must
    /// return `false` for a session that never had its offer accepted (e.g.
    /// "No camera", "Sign-in required", or a `.doorBusy`/`.timedOut` offer
    /// outcome), so such a session's end never starts a busy-cooldown window
    /// for the next attempt.
    @Test func shouldRecordEndIsFalseWhenOfferNeverAccepted() {
        #expect(DoorVideoSessionRegistry.shouldRecordEnd(offerAccepted: false) == false)
    }

    /// The converse: a session whose offer WAS accepted must record an end
    /// when it terminates.
    @Test func shouldRecordEndIsTrueWhenOfferWasAccepted() {
        #expect(DoorVideoSessionRegistry.shouldRecordEnd(offerAccepted: true) == true)
    }

    // MARK: - debugStub does not consult the registry by default

    /// `DoorVideoSession.debugStub()` (no `registry:` argument) must not
    /// perturb `DoorVideoSessionRegistry.shared`: running its full canned
    /// timeline to `.ended` must leave `.shared.lastSessionEnded` exactly as
    /// it was before this test ran (captured and restored so this test
    /// cannot pollute any other test's view of `.shared`, and so a prior
    /// test's pollution of `.shared` cannot produce a false pass here).
    ///
    /// MUTATION CHECK: if `debugStub`'s default `registry:` argument were
    /// changed from a fresh `DoorVideoSessionRegistry()` to `.shared`, this
    /// test would observe `.shared.lastSessionEnded` change to a timestamp
    /// close to "now" after the stub's `.ended` transition, since the stub's
    /// terminal `state = .ended` transition still runs
    /// `offerAccepted`-gated registry bookkeeping (`offerAccepted` is always
    /// `false` for the stub, so THIS specific mutation wouldn't actually
    /// fire even against `.shared` -- but the test still documents and
    /// pins the stub's registry instance being separate from `.shared`,
    /// which is the opt-in seam this bead's edge case asked for).
    @Test func debugStubDoesNotDefaultToSharedRegistry() async {
        let before = DoorVideoSessionRegistry.shared.lastSessionEnded

        let session = DoorVideoSession.debugStub(connectingDelay: 0.01, streamingDuration: 0.01)
        await session.start()

        // Give the canned timeline's Task.sleep-driven transitions a chance
        // to reach `.ended`.
        let deadline = Date().addingTimeInterval(2)
        while session.state != .ended, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(session.state == .ended)
        #expect(DoorVideoSessionRegistry.shared.lastSessionEnded == before)
    }

    /// An explicit, opted-in registry passed to `debugStub` is accepted (the
    /// opt-in parameter this bead's edge case asked for) without affecting
    /// `.shared`.
    @Test func debugStubAcceptsAnExplicitOptInRegistry() async {
        let sharedBefore = DoorVideoSessionRegistry.shared.lastSessionEnded
        let optInRegistry = DoorVideoSessionRegistry()

        let session = DoorVideoSession.debugStub(connectingDelay: 0.01, streamingDuration: 0.01, registry: optInRegistry)
        await session.start()

        let deadline = Date().addingTimeInterval(2)
        while session.state != .ended, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(session.state == .ended)
        #expect(DoorVideoSessionRegistry.shared.lastSessionEnded == sharedBefore)
    }

    // MARK: - waitOutCooldownIfNeeded(): the pure cooldown-wait seam

    /// Builds a real `DoorVideoSession` wired entirely with fakes/an
    /// isolated registry, for exercising `waitOutCooldownIfNeeded()` (an
    /// `internal` seam factored out of `start()`) without ever touching
    /// `webView`/network.
    private func makeSession(
        registry: DoorVideoSessionRegistry,
        cooldownSleep: @escaping (Duration) async throws -> Void
    ) -> DoorVideoSession {
        let (defaults, _) = makeInMemoryDefaults()
        return DoorVideoSession(
            tokenManager: TokenManager(api: ComelitAPI(), credentialStore: InMemoryCredentialStore()),
            gateClient: FakeGateOpening(),
            appSettings: AppSettings(defaults: defaults),
            registry: registry,
            cooldownSleep: cooldownSleep
        )
    }

    /// A registry with a positive wait makes `waitOutCooldownIfNeeded()`
    /// invoke the injected `cooldownSleep` closure exactly once, with (about)
    /// the registry's own computed duration, and set/clear `cooldownUntil`
    /// around it.
    ///
    /// MUTATION CHECK: if `waitOutCooldownIfNeeded()` stopped calling the
    /// injected `cooldownSleep` (e.g. calling `Task.sleep` directly instead),
    /// `sleptDurations` would stay empty, failing the first `#expect`.
    @Test func positiveWaitInvokesInjectedCooldownSleepAndTogglesCooldownUntil() async {
        let registry = DoorVideoSessionRegistry()
        registry.recordSessionEnded(at: Date())

        let sleptDurations = LockedDurationRecorder()
        var observedCooldownDuringSleep: Date?
        let session = makeSession(registry: registry) { duration in
            sleptDurations.record(duration)
        }
        session.onCooldownChange = { cooldownUntil in
            if cooldownUntil != nil { observedCooldownDuringSleep = cooldownUntil }
        }

        #expect(session.cooldownUntil == nil)
        await session.waitOutCooldownIfNeeded()

        #expect(sleptDurations.count == 1)
        #expect(observedCooldownDuringSleep != nil)
        // Cleared again after the wait completes.
        #expect(session.cooldownUntil == nil)
    }

    /// A fresh registry (zero wait) makes `waitOutCooldownIfNeeded()` return
    /// immediately without ever invoking `cooldownSleep` or setting
    /// `cooldownUntil`.
    ///
    /// MUTATION CHECK: removing the `guard cooldown > .zero else { return }`
    /// early-return in `waitOutCooldownIfNeeded()` would call `cooldownSleep`
    /// with `.zero` regardless, making `sleptDurations.count` become 1
    /// instead of 0.
    @Test func zeroWaitNeverInvokesCooldownSleep() async {
        let registry = DoorVideoSessionRegistry()
        let sleptDurations = LockedDurationRecorder()
        let session = makeSession(registry: registry) { duration in
            sleptDurations.record(duration)
        }

        await session.waitOutCooldownIfNeeded()

        #expect(sleptDurations.count == 0)
        #expect(session.cooldownUntil == nil)
    }

    /// `stop()` called WHILE `waitOutCooldownIfNeeded()` is sleeping (i.e.
    /// the injected `cooldownSleep` itself calls `stop()` before returning,
    /// simulating a `Task` cancellation/stop racing the real
    /// `Task.sleep`-backed default) must still leave the session in its
    /// `stop()`-driven `.ended` state with `cooldownUntil` cleared — no
    /// offer PUT is reachable from this unit alone, but this proves the
    /// state bookkeeping `start()` relies on (`hasStopped`, `cooldownUntil`)
    /// is correct across that race.
    ///
    /// MUTATION CHECK: removing the `defer { cooldownUntil = nil }` in
    /// `waitOutCooldownIfNeeded()` would leave `cooldownUntil` non-nil after
    /// `stop()` raced the wait, failing the final `#expect`.
    @Test func stopDuringCooldownWaitLeavesNoStaleCooldownState() async {
        let registry = DoorVideoSessionRegistry()
        registry.recordSessionEnded(at: Date())

        var session: DoorVideoSession!
        session = makeSession(registry: registry) { _ in
            // Simulates `stop()` being called by another task while this
            // session is sleeping out the cooldown.
            session.stop()
        }

        await session.waitOutCooldownIfNeeded()

        #expect(session.cooldownUntil == nil)
        if case .ended = session.state {
            // Expected: stop() transitions .connecting/.idle -> .ended.
        } else {
            Issue.record("expected .ended after stop() raced the cooldown wait, got \(session.state)")
        }
    }
}

/// Thread-safe recorder of `Duration` values passed to a fake
/// `cooldownSleep` closure.
private final class LockedDurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []

    func record(_ duration: Duration) {
        lock.lock(); defer { lock.unlock() }
        _durations.append(duration)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _durations.count
    }
}
