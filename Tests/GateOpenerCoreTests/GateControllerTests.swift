import Foundation
import Testing
@testable import GateOpenerCore

// MARK: - Test doubles

/// In-memory, thread-safe mock of `GateOpening` for use in `GateController`
/// tests. No network access.
///
/// `openGate` calls can optionally be gated on a continuation so a test can
/// deterministically prove "two concurrent calls -> exactly one underlying
/// open call" without relying on timing. Per the bead .4 lesson: a gate that
/// holds a SINGLE continuation slot orphans a second waiter that arrives
/// before the first is resumed, turning a regression into a HANG rather than
/// a clean test failure. This mock holds continuations in an ARRAY and
/// resumes ALL of them when released, so any number of concurrent callers
/// are safely woken.
final class MockGateOpening: GateOpening, @unchecked Sendable {
    private let lock = NSLock()

    var discoverResult: Result<[Endpoint], Error> = .success([])
    var openResult: Result<Void, Error> = .success(())

    private(set) var openCallCount = 0
    private(set) var discoverCallCount = 0

    /// When true, `open(endpointId:)` suspends on a continuation until
    /// `releaseOpen()` is called, letting a test observe "call has started"
    /// before letting it finish.
    var gateOpenCalls = false
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

    private func recordDiscoverCall() -> Result<[Endpoint], Error> {
        lock.lock()
        defer { lock.unlock() }
        discoverCallCount += 1
        return discoverResult
    }

    func discover(aptId: String?) async throws -> [Endpoint] {
        try recordDiscoverCall().get()
    }

    private func recordOpenCallAndCheckGating() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        openCallCount += 1
        return gateOpenCalls
    }

    private func enqueueContinuation(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        pendingContinuations.append(continuation)
    }

    private func currentOpenResult() -> Result<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        return openResult
    }

    func open(endpointId: String) async throws {
        let shouldGate = recordOpenCallAndCheckGating()

        if shouldGate {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                enqueueContinuation(continuation)
            }
        }

        try currentOpenResult().get()
    }

    /// Resumes every continuation currently waiting in `open`, letting all
    /// gated calls proceed. Safe to call even if no calls are waiting yet
    /// (they simply won't be released) or if called multiple times (only
    /// newly-queued continuations are affected the next time).
    func releaseOpen() {
        lock.lock()
        let toResume = pendingContinuations
        pendingContinuations.removeAll()
        lock.unlock()
        for continuation in toResume {
            continuation.resume()
        }
    }

    /// Number of calls to `open` currently suspended waiting for
    /// `releaseOpen()`. Used to deterministically wait until both concurrent
    /// callers have actually entered `open` before releasing them.
    func waitingCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingContinuations.count
    }
}

/// In-memory, thread-safe mock of `TokenResolving` for use in
/// `GateController` tests.
final class MockTokenResolving: TokenResolving, @unchecked Sendable {
    private let lock = NSLock()
    var result: Result<String, Error> = .success("the-access-token")
    private(set) var callCount = 0

    private func recordCall() -> Result<String, Error> {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        return result
    }

    func accessToken() async throws -> String {
        try recordCall().get()
    }
}

/// A no-op sleep recorder: records requested durations without ever
/// actually sleeping, so tests never wait ~3 real seconds for the
/// auto-reset-to-`.idle` behavior.
final class RecordingSleep: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requestedDurations: [Duration] = []

    private func record(_ duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        requestedDurations.append(duration)
    }

    var fn: GateControllerSleep {
        { [weak self] duration in
            self?.record(duration)
        }
    }
}

/// A controllable sleep for TTL tests: every call to the returned
/// `GateControllerSleep` suspends until the test explicitly calls
/// `advance()`. This is essential for test (b)/(c) below: an
/// immediate-return sleep (like `RecordingSleep`) would let the TTL "elapse"
/// before the test ever gets a chance to flip reachability, making it
/// impossible to distinguish "fired because of the flip" from "fired
/// because the TTL raced ahead and won" -- i.e. it would make the test
/// vacuous (see the gateopener-vacuous-assertion-failure-mode memory).
///
/// Holds pending continuations in an array (not a single slot) for the same
/// reason `MockGateOpening` does: a second overlapping `sleep` call must
/// never orphan a waiter.
final class GatedSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedDurations: [Duration] = []

    var fn: GateControllerSleep {
        { [weak self] duration in
            guard let self else { return }
            self.record(duration)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.enqueue(continuation)
            }
        }
    }

    private func record(_ duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        requestedDurations.append(duration)
    }

    private func enqueue(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        pendingContinuations.append(continuation)
    }

    /// Resumes every `sleep` call currently suspended, letting the TTL
    /// "elapse" for all of them. Safe to call when nothing is waiting yet.
    func advance() {
        lock.lock()
        let toResume = pendingContinuations
        pendingContinuations.removeAll()
        lock.unlock()
        for continuation in toResume {
            continuation.resume()
        }
    }

    /// Number of `sleep` calls currently suspended, waiting for `advance()`.
    /// Used to deterministically wait until the TTL timer has actually
    /// started before flipping reachability or calling `advance()`.
    func waitingCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingContinuations.count
    }
}

/// A settable, test-controlled `ReachabilityProviding` conformer.
/// `flip(_:)` both updates `isReachable` and synchronously invokes the
/// currently-installed handler (if any), mirroring what a real reachability
/// framework's callback would do -- letting tests exercise
/// `GateController`'s "fire on the first true" / "ignore a later true after
/// TTL expiry" logic deterministically.
final class FakeReachability: ReachabilityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _isReachable: Bool
    private var handler: (@Sendable (Bool) -> Void)?
    private var _isReachableReadCount = 0

    init(isReachable: Bool = true) {
        self._isReachable = isReachable
    }

    var isReachable: Bool {
        lock.lock()
        defer { lock.unlock() }
        _isReachableReadCount += 1
        return _isReachable
    }

    /// Number of times `isReachable` has been READ (not merely set). Used
    /// to distinguish `requestOpen()`'s OWN coalescing guard (which must
    /// short-circuit on `.opening`/`.queued` BEFORE ever consulting
    /// `reachability.isReachable` again) from `openGate()`'s pre-existing,
    /// unrelated idempotency mechanism -- without this signal, a test that
    /// only asserts the final open-call-count would pass even if
    /// `requestOpen()`'s own guard were deleted, because a second spawned
    /// `Task { await openGate() }` would still be swallowed by `openGate()`'s
    /// own `openTask` check. See the gateopener-vacuous-assertion-failure-mode
    /// memory: "the only reliable check is mutation testing".
    func isReachableReadCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return _isReachableReadCount
    }

    func setOnChange(_ handler: (@Sendable (Bool) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    /// Sets `isReachable` to `newValue` and invokes the installed handler
    /// with that value, exactly as a real framework's callback would.
    func flip(_ newValue: Bool) {
        lock.lock()
        _isReachable = newValue
        let currentHandler = handler
        lock.unlock()
        currentHandler?(newValue)
    }
}

// MARK: - Test helpers

private let sampleEndpointLockGeneric = Endpoint(
    endpointId: "_DA_apt-1_dev-1-00001_VIP#OD#SB100001.1",
    friendlyName: "Entrance lock",
    capabilities: ["PowerController"],
    displayCategories: ["LOCK_GENERIC"]
)

private let sampleEndpointOther = Endpoint(
    endpointId: "_DA_apt-1_dev-2-00001_VIP#OD#SB100002.1",
    friendlyName: "Other Actuator",
    capabilities: ["PowerController"],
    displayCategories: ["SOME_OTHER_CATEGORY"]
)

@MainActor
private func makeController(
    credentialStore: MockCredentialStore = MockCredentialStore(),
    gateOpening: MockGateOpening = MockGateOpening(),
    tokenResolving: MockTokenResolving = MockTokenResolving(),
    defaultsSuiteName: String = UUID().uuidString,
    preconfigured: Bool = true,
    sleep: RecordingSleep = RecordingSleep(),
    sleepFn: GateControllerSleep? = nil,
    reachability: any ReachabilityProviding = AlwaysReachable(),
    queueTTL: Duration = .seconds(45)
) -> (GateController, MockGateOpening, MockTokenResolving, MockCredentialStore, AppSettings) {
    let defaults = UserDefaults(suiteName: defaultsSuiteName)!
    let settings = AppSettings(defaults: defaults)

    if preconfigured {
        try? credentialStore.saveCredentials(username: "alice", password: "s3cret")
        settings.selectedEndpointId = sampleEndpointLockGeneric.endpointId
        settings.selectedEndpointName = sampleEndpointLockGeneric.friendlyName
    }

    let controller = GateController(
        gateClient: gateOpening,
        tokenManager: tokenResolving,
        credentialStore: credentialStore,
        appSettings: settings,
        autoResetDelay: .seconds(3),
        sleep: sleepFn ?? sleep.fn,
        reachability: reachability,
        queueTTL: queueTTL
    )
    return (controller, gateOpening, tokenResolving, credentialStore, settings)
}

// MARK: - 1. Successful open

@Test @MainActor func openGateSuccessTransitionsIdleOpeningSucceeded() async throws {
    let (controller, gateOpening, _, _, _) = makeController()

    #expect(controller.state == .idle)

    var observedStates: [GateState] = []
    controller.onStateChange = { observedStates.append($0) }

    await controller.openGate()

    #expect(gateOpening.openCallCount == 1)
    #expect(observedStates.first == .opening)
    guard case .succeeded = controller.state else {
        Issue.record("expected .succeeded, got \(controller.state)")
        return
    }
}

// MARK: - 2. Failing open ends in .failed with a short message

@Test @MainActor func openGateFailureEndsInFailedWithShortMessage() async throws {
    let (controller, gateOpening, _, _, _) = makeController()
    gateOpening.openResult = .failure(ComelitError.server(status: 500, body: "a very long body that should never appear in the UI message at all, ever"))

    await controller.openGate()

    guard case .failed(let message) = controller.state else {
        Issue.record("expected .failed, got \(controller.state)")
        return
    }
    #expect(message == "Could not reach the gate")
    #expect(!message.contains("500"))
    #expect(!message.contains("very long body"))
    #expect(message.count < 60)
}

// MARK: - 3. Two concurrent openGate() calls -> exactly one underlying open call

@Test @MainActor func concurrentOpenGateCallsResultInExactlyOneUnderlyingOpenCall() async throws {
    let (controller, gateOpening, _, _, _) = makeController()
    gateOpening.gateOpenCalls = true

    async let first: Void = controller.openGate()
    async let second: Void = controller.openGate()

    // Deterministically wait until at least one call has actually entered
    // `open` and is suspended on the gate, without a fixed sleep. Since
    // `GateController` is @MainActor and `openGate()`'s idempotency check
    // happens synchronously before any suspension, the second call will
    // already have taken the "await existing.value" path by the time this
    // loop observes the first waiter -- but we still poll defensively
    // rather than assume scheduling order.
    while gateOpening.waitingCount() < 1 {
        await Task.yield()
    }

    gateOpening.releaseOpen()

    _ = await (first, second)

    #expect(gateOpening.openCallCount == 1)
    // The terminal state itself is not the point of this test (and is
    // racy against the no-op injected sleep immediately auto-resetting
    // `.succeeded` back to `.idle`) -- the decisive assertion is the call
    // count above. Still assert the state landed somewhere sane (never
    // `.opening`/`.failed`, which would indicate the open genuinely failed
    // or got stuck).
    #expect(controller.state == .idle || {
        if case .succeeded = controller.state { return true }
        return false
    }())
}

// MARK: - 3b. A second, SEQUENTIAL openGate() (after the first has resolved)
// issues its own underlying open call

@Test @MainActor func sequentialOpenGateCallsEachIssueAnUnderlyingOpen() async throws {
    // No `Task.sleep`/wall-clock wait is needed here, and none is inserted,
    // for two independent reasons:
    //  1. `RecordingSleep` (the `sleep` fixture, see `makeController`) is
    //     injected as `GateControllerSleep` and never actually suspends --
    //     it just records the requested `Duration` -- so the auto-reset
    //     Task scheduled by `transition(to:)` after the first `openGate()`
    //     completes instantly rather than after a real 3s delay.
    //  2. `openGate()` clears `openTask` synchronously (`openTask = nil`)
    //     immediately after `await task.value` returns, BEFORE `openGate()`
    //     itself returns to its caller. So the moment `await
    //     controller.openGate()` resolves below, there is no in-flight
    //     `openTask` for a second call to join -- it is free to issue a
    //     fresh underlying `open`, regardless of whether `state` has
    //     already auto-reset to `.idle` or is still sitting at
    //     `.succeeded`. Calling `openGate()` again immediately, with no
    //     wait, is therefore deterministic rather than racy.
    let (controller, gateOpening, _, _, _) = makeController()

    await controller.openGate()

    #expect(gateOpening.openCallCount == 1)
    guard case .succeeded = controller.state else {
        Issue.record("expected .succeeded after first openGate(), got \(controller.state)")
        return
    }

    await controller.openGate()

    #expect(gateOpening.openCallCount == 2)
    guard case .succeeded = controller.state else {
        Issue.record("expected .succeeded after second openGate(), got \(controller.state)")
        return
    }
}

// MARK: - 4. .notConfigured routes to .needsSetup, not .failed

@Test @MainActor func notConfiguredRoutesToNeedsSetupNotFailed() async throws {
    let (controller, _, tokenResolving, _, _) = makeController()
    tokenResolving.result = .failure(TokenManagerError.notConfigured)

    await controller.openGate()

    #expect(controller.state == .needsSetup)
}

// MARK: - 5. signOut() returns to .needsSetup and clears the store

@Test @MainActor func signOutReturnsToNeedsSetupAndClearsStore() async throws {
    let (controller, _, _, credentialStore, settings) = makeController()

    controller.signOut()

    #expect(controller.state == .needsSetup)
    #expect(credentialStore.deleteCredentialsCallCount == 1)
    #expect(credentialStore.deleteTokensCallCount == 1)
    #expect(credentialStore.isEmpty)
    #expect(settings.selectedEndpointId == nil)
    #expect(settings.isConfigured == false)
}

// MARK: - 5b. setCredentialStore() routes signOut()'s deletes to the new store

/// Covers bead gateopener-672.25: after `AppEnvironment
/// .updateKeychainAccessibility(allowWhileLocked:)` swaps in a freshly
/// -accessibility-configured store, `GateController.signOut()` must delete
/// from the NEW store, not the one the controller was originally
/// constructed with.
@Test @MainActor func setCredentialStoreRoutesSignOutDeletesToTheNewStore() async throws {
    let oldStore = MockCredentialStore()
    let (controller, _, _, _, settings) = makeController(credentialStore: oldStore)
    let newStore = MockCredentialStore()
    try newStore.saveCredentials(username: "alice", password: "s3cret")
    try newStore.saveTokens(TokenSet(accessToken: "tok", refreshToken: "r", expiresIn: 3600, tokenType: "bearer"))

    controller.setCredentialStore(newStore)
    controller.signOut()

    #expect(controller.state == .needsSetup)
    #expect(newStore.deleteCredentialsCallCount == 1)
    #expect(newStore.deleteTokensCallCount == 1)
    #expect(newStore.isEmpty)
    #expect(oldStore.deleteCredentialsCallCount == 0)
    #expect(oldStore.deleteTokensCallCount == 0)
    #expect(settings.selectedEndpointId == nil)
}

// MARK: - 6. Auto-reset to .idle uses the injected delay, not a real sleep

@Test @MainActor func autoResetUsesInjectedDelayNotRealSleep() async throws {
    let recordingSleep = RecordingSleep()
    let (controller, _, _, _, _) = makeController(sleep: recordingSleep)

    await controller.openGate()

    // The open itself completed without any real delay. The auto-reset task
    // is fire-and-forget from openGate()'s perspective, so give it a brief
    // moment to run (still no REAL 3s sleep, since `sleep.fn` is a no-op).
    for _ in 0..<20 {
        if !recordingSleep.requestedDurations.isEmpty { break }
        await Task.yield()
    }

    // NOTE: deliberately NO wall-clock assertion here (see bead .18).
    // requestedDurations is the assertion that carries the meaning: the 3s
    // delay was REQUESTED FROM THE INJECTED SLEEP rather than really slept.
    // A real Task.sleep would leave requestedDurations empty and fail below.
    #expect(recordingSleep.requestedDurations == [.seconds(3)])
}

@Test @MainActor func autoResetActuallyReturnsToIdleWithInjectedNoDelaySleep() async throws {
    let recordingSleep = RecordingSleep()
    let (controller, _, _, _, _) = makeController(sleep: recordingSleep)

    await controller.openGate()

    // Poll (no fixed sleep) until the fire-and-forget reset task has run.
    for _ in 0..<200 {
        if controller.state == .idle { break }
        await Task.yield()
    }

    // NOTE: deliberately NO wall-clock assertion here (see bead .18).
    // Reaching .idle at all is the proof that the injected no-op sleep was
    // used rather than a real 3s sleep; asserting elapsed-time thresholds
    // made this test fail spuriously under concurrent CPU load.
    #expect(controller.state == .idle)
}

// MARK: - 7. A throwing open never leaves state in .opening

@Test @MainActor func throwingOpenNeverLeavesStateInOpening() async throws {
    let (controller, gateOpening, _, _, _) = makeController()
    gateOpening.openResult = .failure(ComelitError.network("connection reset"))

    await controller.openGate()

    #expect(controller.state != .opening)
    guard case .failed = controller.state else {
        Issue.record("expected .failed, got \(controller.state)")
        return
    }
}

// MARK: - 8. performFirstTimeSetup

@Test @MainActor func performFirstTimeSetupHappyPathPersistsEndpointIdAndName() async throws {
    let (controller, gateOpening, _, credentialStore, settings) = makeController(preconfigured: false)
    gateOpening.discoverResult = .success([sampleEndpointOther, sampleEndpointLockGeneric])

    try await controller.performFirstTimeSetup(username: "alice", password: "s3cret")

    #expect(settings.selectedEndpointId == sampleEndpointLockGeneric.endpointId)
    #expect(settings.selectedEndpointName == sampleEndpointLockGeneric.friendlyName)
    #expect(settings.lastDiscoveryDate != nil)
    #expect(credentialStore.saveCredentialsCallCount == 1)
    #expect(controller.state == .idle)
}

@Test @MainActor func performFirstTimeSetupInvalidCredentialsPropagatesAndPersistsNothing() async throws {
    let (controller, _, tokenResolving, credentialStore, settings) = makeController(preconfigured: false)
    tokenResolving.result = .failure(ComelitError.invalidCredentials)

    await #expect(throws: ComelitError.invalidCredentials) {
        try await controller.performFirstTimeSetup(username: "alice", password: "wrong")
    }

    #expect(settings.selectedEndpointId == nil)
    #expect(settings.selectedEndpointName == nil)
    #expect(credentialStore.isEmpty)
}

// MARK: - 9. performFirstTimeSetup with no candidate gate

@Test @MainActor func performFirstTimeSetupNoCandidateGateThrowsNoGateFoundAndPersistsNothing() async throws {
    let (controller, gateOpening, _, credentialStore, settings) = makeController(preconfigured: false)
    let camera = Endpoint(
        endpointId: "id-camera",
        friendlyName: "Camera",
        capabilities: ["RTCSessionController"],
        displayCategories: ["CAMERA"]
    )
    gateOpening.discoverResult = .success([camera])

    await #expect(throws: GateClientError.noGateFound) {
        try await controller.performFirstTimeSetup(username: "alice", password: "s3cret")
    }

    #expect(settings.selectedEndpointId == nil)
    #expect(credentialStore.isEmpty)
}

// MARK: - 10. refreshGates failure does not clear an existing selection

@Test @MainActor func refreshGatesFailureDoesNotClearExistingSelection() async throws {
    let (controller, gateOpening, _, _, settings) = makeController()
    let originalEndpointId = settings.selectedEndpointId
    gateOpening.discoverResult = .failure(ComelitError.network("boom"))

    await #expect(throws: ComelitError.self) {
        _ = try await controller.refreshGates()
    }

    #expect(settings.selectedEndpointId == originalEndpointId)
    #expect(settings.selectedEndpointId != nil)
}

@Test @MainActor func refreshGatesSuccessReturnsCandidates() async throws {
    let (controller, gateOpening, _, _, _) = makeController()
    gateOpening.discoverResult = .success([sampleEndpointOther, sampleEndpointLockGeneric])

    let candidates = try await controller.refreshGates()

    #expect(candidates.map(\.endpointId) == [sampleEndpointLockGeneric.endpointId, sampleEndpointOther.endpointId])
}

@Test @MainActor func refreshGatesPersistsCachedGates() async throws {
    let (controller, gateOpening, _, _, settings) = makeController()
    // Mutation check: confirm the cache starts empty so the post-call
    // assertion below is proven to distinguish "refreshGates wrote it"
    // from "it was already populated by some other path".
    #expect(settings.cachedGates.isEmpty)
    gateOpening.discoverResult = .success([sampleEndpointOther, sampleEndpointLockGeneric])

    let candidates = try await controller.refreshGates()

    #expect(!candidates.isEmpty)
    #expect(settings.cachedGates == candidates)
    #expect(settings.cachedGates.map(\.endpointId) == [sampleEndpointLockGeneric.endpointId, sampleEndpointOther.endpointId])
}

// MARK: - Additional: initial state derivation

@Test @MainActor func initialStateIsNeedsSetupWithNoCredentials() throws {
    let (controller, _, _, _, _) = makeController(
        credentialStore: MockCredentialStore(),
        preconfigured: false
    )
    #expect(controller.state == .needsSetup)
}

@Test @MainActor func initialStateIsNeedsSetupWithCredentialsButNoSelectedEndpoint() throws {
    let store = MockCredentialStore()
    try store.saveCredentials(username: "alice", password: "s3cret")
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let settings = AppSettings(defaults: defaults)

    let controller = GateController(
        gateClient: MockGateOpening(),
        tokenManager: MockTokenResolving(),
        credentialStore: store,
        appSettings: settings
    )

    #expect(controller.state == .needsSetup)
}

@Test @MainActor func initialStateIsIdleWithCredentialsAndSelectedEndpoint() throws {
    let (controller, _, _, _, _) = makeController()
    #expect(controller.state == .idle)
}

// MARK: - Additional: selectGate routes through the controller

@Test @MainActor func selectGatePersistsThroughController() throws {
    let (controller, _, _, _, settings) = makeController(preconfigured: false)

    controller.selectGate(sampleEndpointLockGeneric)

    #expect(settings.selectedEndpointId == sampleEndpointLockGeneric.endpointId)
    #expect(settings.selectedEndpointName == sampleEndpointLockGeneric.friendlyName)
    #expect(controller.state == .idle)
}

// MARK: - Additional: shortMessage(for:) forwards to GateErrorMessage.short(for:)
//
// The full branch-by-branch coverage of the mapping itself now lives in
// `GateErrorMessageTests.swift` (`GateErrorMessage.short`/`.signIn`); this
// single smoke test just proves `GateController.shortMessage(for:)` still
// forwards correctly now that it is a one-line wrapper.

@Test @MainActor func shortMessageForwardsToGateErrorMessageShort() throws {
    #expect(GateController.shortMessage(for: ComelitError.invalidCredentials) == GateErrorMessage.short(for: ComelitError.invalidCredentials))
}

// MARK: - requestOpen() (bead .4: non-blocking entry point, offline queue, TTL, coalescing)

/// Polls (no fixed sleep) until `controller.state` matches `predicate`, or a
/// bounded number of yields elapses. Since `requestOpen()` returns
/// synchronously and the actual open (and TTL-elapse handling) runs in a
/// detached `Task`, tests need a deterministic way to await the eventual
/// terminal state without a wall-clock sleep -- mirrors the existing
/// polling pattern used by `autoResetActuallyReturnsToIdleWithInjectedNoDelaySleep`
/// above.
@MainActor
private func waitUntil(_ predicate: () -> Bool, maxYields: Int = 500) async {
    for _ in 0..<maxYields {
        if predicate() { return }
        await Task.yield()
    }
}

// MARK: - (a) reachable -> requestOpen leads to .opening then .succeeded, exactly ONE open call

@Test @MainActor func requestOpenWhenReachableOpensImmediatelyAndSucceeds() async throws {
    let (controller, gateOpening, _, _, _) = makeController(reachability: FakeReachability(isReachable: true))

    var observedStates: [GateState] = []
    controller.onStateChange = { observedStates.append($0) }

    controller.requestOpen()

    await waitUntil {
        if case .succeeded = controller.state { return true }
        return false
    }

    #expect(gateOpening.openCallCount == 1)
    #expect(observedStates.contains(.opening))
    guard case .succeeded = controller.state else {
        Issue.record("expected .succeeded, got \(controller.state)")
        return
    }
}

// MARK: - (b) unreachable -> .queued, ZERO open calls; flip(true) -> exactly one open call, terminal .succeeded

@Test @MainActor func requestOpenWhenUnreachableQueuesThenFiresOnReachabilityFlip() async throws {
    let reachability = FakeReachability(isReachable: false)
    let gatedSleep = GatedSleep()
    let (controller, gateOpening, _, _, _) = makeController(
        sleepFn: gatedSleep.fn,
        reachability: reachability
    )

    controller.requestOpen()

    #expect(controller.state == .queued)
    #expect(gateOpening.openCallCount == 0)

    // Wait until the TTL timer has actually started (entered `sleep`)
    // before flipping reachability, so this proves the flip -- not a race
    // won by an immediate-return sleep -- is what fires the request. This
    // is exactly the vacuousness trap called out in the bead brief: an
    // immediate-return sleep would let the TTL "elapse" before the flip
    // ever runs, and this assertion would then pass whether or not the
    // reachability-flip branch exists at all.
    while gatedSleep.waitingCount() < 1 {
        await Task.yield()
    }

    reachability.flip(true)

    await waitUntil {
        if case .succeeded = controller.state { return true }
        return false
    }

    #expect(gateOpening.openCallCount == 1)
    guard case .succeeded = controller.state else {
        Issue.record("expected .succeeded after reachability flip, got \(controller.state)")
        return
    }
}

// MARK: - (c) unreachable, TTL elapses -> .failed("No network"), zero open calls; then flip(true) -> still zero open calls

@Test @MainActor func requestOpenTTLElapsesFailsAndIgnoresLateReachabilityFlip() async throws {
    let reachability = FakeReachability(isReachable: false)
    let gatedSleep = GatedSleep()
    let (controller, gateOpening, _, _, _) = makeController(
        sleepFn: gatedSleep.fn,
        reachability: reachability
    )

    controller.requestOpen()

    #expect(controller.state == .queued)

    while gatedSleep.waitingCount() < 1 {
        await Task.yield()
    }

    // Advance the (fake) clock: the TTL elapses before any flip.
    gatedSleep.advance()

    await waitUntil {
        if case .failed = controller.state { return true }
        return false
    }

    guard case .failed(let message) = controller.state else {
        Issue.record("expected .failed, got \(controller.state)")
        return
    }
    #expect(message == "No network")
    #expect(gateOpening.openCallCount == 0)

    // A LATE flip to true, after the TTL has already fired, must not
    // resurrect the stale request.
    reachability.flip(true)
    await Task.yield()
    await Task.yield()

    #expect(gateOpening.openCallCount == 0)
}

// MARK: - (d) three requestOpen() calls while queued -> one open call after flip

@Test @MainActor func threeRequestOpenCallsWhileQueuedCoalesceToOneOpenAfterFlip() async throws {
    let reachability = FakeReachability(isReachable: false)
    let gatedSleep = GatedSleep()
    let (controller, gateOpening, _, _, _) = makeController(
        sleepFn: gatedSleep.fn,
        reachability: reachability
    )

    controller.requestOpen()
    controller.requestOpen()
    controller.requestOpen()

    #expect(controller.state == .queued)
    #expect(gateOpening.openCallCount == 0)

    while gatedSleep.waitingCount() < 1 {
        await Task.yield()
    }

    reachability.flip(true)

    await waitUntil {
        if case .succeeded = controller.state { return true }
        return false
    }

    #expect(gateOpening.openCallCount == 1)
}

// MARK: - (e) signOut while queued -> flip(true) -> zero open calls

@Test @MainActor func signOutWhileQueuedDropsRequestAndIgnoresLaterFlip() async throws {
    let reachability = FakeReachability(isReachable: false)
    let gatedSleep = GatedSleep()
    let (controller, gateOpening, _, credentialStore, _) = makeController(
        sleepFn: gatedSleep.fn,
        reachability: reachability
    )

    controller.requestOpen()

    #expect(controller.state == .queued)

    while gatedSleep.waitingCount() < 1 {
        await Task.yield()
    }

    controller.signOut()

    #expect(controller.state == .needsSetup)
    #expect(credentialStore.isEmpty)

    reachability.flip(true)
    await Task.yield()
    await Task.yield()

    #expect(gateOpening.openCallCount == 0)
    // State must still reflect signOut(), not a resurrected queued request.
    #expect(controller.state == .needsSetup)
}

// MARK: - (f) requestOpen while .opening is a no-op (one open call total)

@Test @MainActor func requestOpenWhileOpeningIsANoOp() async throws {
    let reachability = FakeReachability(isReachable: true)
    let (controller, gateOpening, _, _, _) = makeController(reachability: reachability)
    gateOpening.gateOpenCalls = true

    controller.requestOpen()

    while gateOpening.waitingCount() < 1 {
        await Task.yield()
    }
    #expect(controller.state == .opening)

    let readCountBeforeSecondCall = reachability.isReachableReadCount()

    // A second requestOpen() call while the first is genuinely in flight
    // must be a no-op: no second underlying open call, AND it must
    // short-circuit on the `.opening` check BEFORE ever consulting
    // `reachability.isReachable` again (see `isReachableReadCount()`'s doc
    // comment for why this second assertion is the one that actually
    // distinguishes `requestOpen()`'s own guard from `openGate()`'s
    // unrelated, pre-existing idempotency).
    controller.requestOpen()

    #expect(reachability.isReachableReadCount() == readCountBeforeSecondCall)

    gateOpening.releaseOpen()

    await waitUntil {
        if case .succeeded = controller.state { return true }
        return false
    }

    #expect(gateOpening.openCallCount == 1)
}
