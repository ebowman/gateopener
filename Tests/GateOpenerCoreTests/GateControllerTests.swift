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
    sleep: RecordingSleep = RecordingSleep()
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
        sleep: sleep.fn
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

// MARK: - Additional: unknown error type never surfaces a raw description

private struct WeirdError: Error {}

@Test @MainActor func unknownErrorTypeMapsToGenericShortMessage() throws {
    let message = GateController.shortMessage(for: WeirdError())
    #expect(message == "Could not open the gate")
}

@Test @MainActor func noGateFoundMapsToShortMessage() throws {
    let message = GateController.shortMessage(for: GateClientError.noGateFound)
    #expect(message == "No gate found")
}

@Test @MainActor func invalidCredentialsMapsToShortMessage() throws {
    let message = GateController.shortMessage(for: ComelitError.invalidCredentials)
    #expect(message == "Wrong username or password")
}
