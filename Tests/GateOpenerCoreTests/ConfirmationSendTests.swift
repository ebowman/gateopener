import Foundation
import Testing
@testable import GateOpenerCore

// gateopener-pi0.5: the post-accept "confirmation" send. Reuses
// `RequestScript` / `makeSequencedSession` / `RecordingAttemptObserver` /
// `SleepRecorder` from GateClientTests.swift.

private func makeSeededTokenManager(expiresIn: TimeInterval = 3600) -> (TokenManager, MockTokenIssuing) {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    try? store.saveCredentials(username: "alice", password: "s3cret")
    issuing.loginResult = .success(
        TokenSet(accessToken: "tok", refreshToken: "rt", expiresIn: expiresIn, tokenType: "bearer")
    )
    issuing.refreshResult = issuing.loginResult
    return (TokenManager(api: issuing, credentialStore: store), issuing)
}

private func makeClient(
    statuses: [Int],
    policy: RetryPolicy,
    expiresIn: TimeInterval = 3600
) -> (GateClient, RequestScript, RecordingAttemptObserver, MockTokenIssuing) {
    let script = RequestScript(statuses: statuses)
    return makeClient(script: script, policy: policy, expiresIn: expiresIn)
}

private func makeClient(
    script: RequestScript,
    policy: RetryPolicy,
    expiresIn: TimeInterval = 3600
) -> (GateClient, RequestScript, RecordingAttemptObserver, MockTokenIssuing) {
    let session = makeSequencedSession(script: script)
    let (tokenManager, issuing) = makeSeededTokenManager(expiresIn: expiresIn)
    let observer = RecordingAttemptObserver()
    let client = GateClient(
        session: session,
        tokenManager: tokenManager,
        retryPolicy: policy,
        attemptObserver: observer
    )
    return (client, script, observer, issuing)
}

private final class EnteredFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}

/// Awaits the client's background confirmation task (if any) to completion.
private func settle(_ client: GateClient) async {
    await client.pendingConfirmationTaskForTesting()?.value
}

/// Polling flag usable from `@Sendable` sleep closures (ignores cancellation
/// while waiting, like a stuck request would).
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var _open = false
    private var _entered = 0
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return _open }
    var entered: Int { lock.lock(); defer { lock.unlock() }; return _entered }
    func release() { lock.lock(); _open = true; lock.unlock() }
    func markEntered() { lock.lock(); _entered += 1; lock.unlock() }
    func waitUntilOpen() async {
        while !isOpen { try? await Task.sleep(for: .milliseconds(1)) }
    }
    func waitUntilEntered() async {
        while entered == 0 { try? await Task.sleep(for: .milliseconds(1)) }
    }
}

private let gateId = "VIP#OD#SB100001.1"

// MARK: - RetryPolicy fields

/// Breaks if the defaults (1 send, 400ms, 3s) change.
@Test func retryPolicyDefaultsIncludeOneConfirmationSendAt400msWith3sTimeout() {
    let p = RetryPolicy.default
    #expect(p.confirmationSends == 1)
    #expect(p.confirmationDelay == .milliseconds(400))
    #expect(p.confirmationTimeout == .seconds(3))
    // Worst case 18s + 3.4s stays under OpenGateFlow's 27s deadline.
    let worst = p.requestTimeouts.reduce(Duration.zero, +) + p.maxTotalDelay
        + p.confirmationDelay + p.confirmationTimeout
    #expect(worst == .milliseconds(21_400))
    #expect(worst < .seconds(27))
}

/// Breaks if a negative count is no longer clamped to 0 or the custom values are dropped.
@Test func retryPolicyConfirmationFieldsAreStoredAndNegativeCountClampsToZero() {
    let p = RetryPolicy(confirmationSends: -2, confirmationDelay: .milliseconds(7), confirmationTimeout: .seconds(1))
    #expect(p.confirmationSends == 0)
    #expect(p.confirmationDelay == .milliseconds(7))
    #expect(p.confirmationTimeout == .seconds(1))
}

// MARK: - (a)-(e) scenarios

/// (a) Breaks if no confirmation PUT is sent or it is not tagged .confirmation.
@Test func confirmation_202Then202_returnsNormallyWithPrimaryAndConfirmationRecords() async throws {
    let (client, script, observer, _) = makeClient(statuses: [202, 202], policy: .noDelay(confirmationSends: 1))
    try await client.open(endpointId: gateId)
    await settle(client)
    #expect(script.requestCount == 2)
    let records = observer.records
    #expect(records.map(\.kind) == [.primary, .confirmation])
    #expect(records.map(\.outcome) == [.success(status: 202), .success(status: 202)])
    #expect(records.map(\.willRetry) == [false, false])
}

/// (b) Breaks if a failing confirmation throws, is retried, or is not journaled.
@Test func confirmation_202Then500_returnsNormallyAndJournalsHttpFailureOnly() async throws {
    let (client, script, observer, _) = makeClient(statuses: [202, 500], policy: .noDelay(confirmationSends: 1))
    try await client.open(endpointId: gateId)
    await settle(client)
    #expect(script.requestCount == 2)
    let records = observer.records
    #expect(records.count == 2)
    #expect(records[0].kind == .primary)
    #expect(records[1].kind == .confirmation)
    #expect(records[1].outcome == .httpFailure(status: 500))
}

/// (c) Breaks if the confirmation is skipped after a retried primary.
@Test func confirmation_500Then202Then202_recordsRetryPrimarySuccessAndConfirmation() async throws {
    let (client, script, observer, _) = makeClient(statuses: [500, 202, 202], policy: .noDelay(confirmationSends: 1))
    try await client.open(endpointId: gateId)
    await settle(client)
    #expect(script.requestCount == 3)
    let records = observer.records
    #expect(records.map(\.kind) == [.primary, .primary, .confirmation])
    #expect(records.map(\.outcome) == [.httpFailure(status: 500), .success(status: 202), .success(status: 202)])
    #expect(records.map(\.attempt) == [1, 2, 2])
}

/// (d) Breaks if `confirmationSends = 0` sends anything beyond the single primary PUT.
@Test func confirmation_zeroSends_reproducesOldSingleRequestSequence() async throws {
    let (client, script, observer, _) = makeClient(statuses: [202, 202], policy: .noDelay(confirmationSends: 0))
    try await client.open(endpointId: gateId)
    await settle(client)
    #expect(script.requestCount == 1)
    #expect(observer.records.map(\.kind) == [.primary])
}

/// (d2) Same with a retry in front: 500, 202 -> exactly two requests.
@Test func confirmation_zeroSends_withRetryStillExactlyPrimaryRequests() async throws {
    let (client, script, observer, _) = makeClient(statuses: [500, 202, 202], policy: .noDelay(confirmationSends: 0))
    try await client.open(endpointId: gateId)
    await settle(client)
    #expect(script.requestCount == 2)
    #expect(observer.records.map(\.kind) == [.primary, .primary])
}

/// (e) The primary was accepted, so the caller's cancellation must NOT
/// suppress the confirmation: it still goes out from its own unstructured
/// task. Breaks if the confirmation inherits caller cancellation (e.g. is
/// awaited inline or run as a child task) or is dropped on cancel.
@Test func callerCancelledAfterAcceptedPrimary_confirmationStillSentInBackground() async throws {
    let latch = Latch()
    let policy = RetryPolicy(
        confirmationSends: 1,
        confirmationDelay: .milliseconds(400),
        sleep: { _ in
            latch.markEntered()
            await latch.waitUntilOpen()
        }
    )
    let (client, script, observer, _) = makeClient(statuses: [202, 202], policy: policy)
    let caller = Task {
        try await client.open(endpointId: gateId)
        try await Task.sleep(for: .seconds(30)) // cancellable work after open
    }
    await latch.waitUntilEntered()
    caller.cancel()
    #expect(script.requestCount == 1)
    latch.release()
    await settle(client)
    #expect(script.requestCount == 2)
    #expect(observer.records.map(\.kind) == [.primary, .confirmation])
    _ = try? await caller.value
}

/// `open` returns at the first 202 -- before the confirmation delay elapses
/// or the second PUT exists. Breaks if `open` awaits the confirmation inline.
@Test func openReturnsBeforeConfirmationIsSent() async throws {
    let latch = Latch()
    let policy = RetryPolicy(
        confirmationSends: 1,
        sleep: { _ in
            latch.markEntered()
            await latch.waitUntilOpen()
        }
    )
    let (client, script, observer, _) = makeClient(statuses: [202, 202], policy: policy)
    try await client.open(endpointId: gateId) // would hang here if awaited inline
    #expect(script.requestCount == 1)
    #expect(observer.records.map(\.kind) == [.primary])
    latch.release()
    await settle(client)
    #expect(script.requestCount == 2)
}

// MARK: - waitForPendingConfirmation

/// Breaks if it waits (or sleeps) when nothing is pending.
@Test func waitForPendingConfirmation_returnsImmediatelyWhenNothingPending() async throws {
    let recorder = SleepRecorder()
    let policy = RetryPolicy(confirmationSends: 1, sleep: { recorder.record($0) })
    let (client, _, _, _) = makeClient(statuses: [202], policy: policy)
    await client.waitForPendingConfirmation(upTo: .seconds(3))
    #expect(recorder.durations.isEmpty)
}

/// Confirmation finishes first; the bound sleep would block for 30s. Breaks
/// if the wait does not return when the confirmation completes.
@Test func waitForPendingConfirmation_returnsWhenConfirmationCompletesBeforeBound() async throws {
    let policy = RetryPolicy(
        confirmationSends: 1,
        confirmationDelay: .milliseconds(11),
        sleep: { d in
            if d == .seconds(7) { try await Task.sleep(for: .seconds(30)) }
        }
    )
    let (client, script, observer, _) = makeClient(statuses: [202, 202], policy: policy)
    try await client.open(endpointId: gateId)
    await client.waitForPendingConfirmation(upTo: .seconds(7))
    #expect(script.requestCount == 2)
    #expect(observer.records.map(\.kind) == [.primary, .confirmation])
}

/// The bound fires (through the sleep seam) while the confirmation is still
/// stuck; the wait returns WITHOUT cancelling it and the record still
/// arrives afterwards. Breaks if the wait blocks past the bound or cancels.
@Test func waitForPendingConfirmation_returnsAtBoundWhileConfirmationKeepsRunning() async throws {
    let latch = Latch()
    let policy = RetryPolicy(
        confirmationSends: 1,
        confirmationDelay: .milliseconds(11),
        sleep: { d in
            if d == .milliseconds(11) { await latch.waitUntilOpen() }
            // any other duration (the 7s bound) returns immediately
        }
    )
    let (client, script, observer, _) = makeClient(statuses: [202, 202], policy: policy)
    try await client.open(endpointId: gateId)
    await client.waitForPendingConfirmation(upTo: .seconds(7))
    #expect(script.requestCount == 1)
    latch.release()
    await settle(client)
    #expect(script.requestCount == 2)
    #expect(observer.records.map(\.kind) == [.primary, .confirmation])
}

// MARK: - Edge cases

/// Breaks if the confirmation does not go through the policy's own `sleep` seam with `confirmationDelay`.
@Test func confirmation_delayGoesThroughInjectedSleepSeamWithConfirmationDelay() async throws {
    let recorder = SleepRecorder()
    let policy = RetryPolicy(
        confirmationSends: 1,
        confirmationDelay: .milliseconds(123),
        sleep: { recorder.record($0) }
    )
    let (client, _, _, _) = makeClient(statuses: [202, 202], policy: policy)
    try await client.open(endpointId: gateId)
    await settle(client)
    #expect(recorder.durations == [.milliseconds(123)])
}

/// Breaks if a confirmation is sent although the primary never got 202/200.
@Test func confirmation_neverSentWhenPrimaryFailsAllAttempts() async throws {
    let (client, script, observer, _) = makeClient(statuses: [500, 500, 500, 202], policy: .noDelay(confirmationSends: 1))
    await #expect(throws: Error.self) { try await client.open(endpointId: gateId) }
    #expect(script.requestCount == 3)
    #expect(observer.records.map(\.kind) == [.primary, .primary, .primary])
}

/// Breaks if a 401 on the confirmation triggers a retry/invalidate/throw instead of journal-only.
@Test func confirmation_401IsJournaledNotRetriedAndDoesNotThrow() async throws {
    let (client, script, observer, issuing) = makeClient(statuses: [202, 401, 202], policy: .noDelay(confirmationSends: 1))
    try await client.open(endpointId: gateId)
    await settle(client)
    #expect(script.requestCount == 2)
    #expect(observer.records.last?.kind == .confirmation)
    #expect(observer.records.last?.outcome == .httpFailure(status: 401))
    #expect(issuing.loginCallCount == 1)
}

/// Breaks if the confirmation resolves a token again. expiresIn 0 makes every
/// `accessToken()` call log in again (proved by the 500-then-202 control).
@Test func confirmation_reusesPrimaryTokenWithoutSecondResolution() async throws {
    let (control, _, _, controlIssuing) = makeClient(
        statuses: [500, 202], policy: .noDelay(confirmationSends: 0), expiresIn: 0
    )
    try await control.open(endpointId: gateId)
    await settle(control)
    #expect(controlIssuing.loginCallCount + controlIssuing.refreshCallCount == 2) // harness detects re-resolution

    let (client, script, _, issuing) = makeClient(
        statuses: [202, 202], policy: .noDelay(confirmationSends: 1), expiresIn: 0
    )
    try await client.open(endpointId: gateId)
    await settle(client)
    #expect(issuing.loginCallCount + issuing.refreshCallCount == 1)
    #expect(script.authorizationHeaders == ["Bearer tok", "Bearer tok"])
}

/// Breaks if the confirmation ignores `confirmationTimeout` (or uses the escalating schedule).
@Test func confirmation_usesConfirmationTimeoutNotAttemptSchedule() async throws {
    let policy = RetryPolicy(
        requestTimeouts: [.seconds(3), .seconds(5), .seconds(8)],
        confirmationSends: 1,
        confirmationTimeout: .milliseconds(1500),
        sleep: { _ in }
    )
    let (client, script, _, _) = makeClient(statuses: [202, 202], policy: policy)
    try await client.open(endpointId: gateId)
    await settle(client)
    #expect(script.timeoutIntervals == [3.0, 1.5])
}

/// Breaks if a transport error/timeout on the confirmation throws or goes unjournaled.
@Test func confirmation_transportErrorIsJournaledAndDoesNotThrow() async throws {
    let script = RequestScript(responses: [ScriptedResponse(status: 202), .transportError(.timedOut)])
    let (client, _, observer, _) = makeClient(script: script, policy: .noDelay(confirmationSends: 1))
    try await client.open(endpointId: gateId)
    await settle(client)
    #expect(script.requestCount == 2)
    #expect(observer.records.last?.kind == .confirmation)
    #expect(observer.records.last?.outcome == .transportFailure(urlErrorCode: URLError.timedOut.rawValue))
}

/// Breaks if the second request is not a PUT to .../power.
@Test func confirmation_isPutToSamePowerPath() async throws {
    let (client, script, _, _) = makeClient(statuses: [202, 202], policy: .noDelay(confirmationSends: 1))
    try await client.open(endpointId: gateId)
    await settle(client)
    #expect(script.requestCount == 2)
    #expect(script.methods == ["PUT", "PUT"])
    #expect(script.paths.count == 2)
    #expect(script.paths[1].hasSuffix("/power"))
    #expect(script.paths[1] == script.paths[0])
}

// MARK: - Record codec

/// Breaks if `kind` loses its `.primary` default when absent (legacy JSONL).
@Test func openAttemptRecordWithoutKindFieldDecodesAsPrimary() throws {
    let line = #"{"timestamp":0,"attempt":1,"maxAttempts":3,"outcome":{"success":{"status":202}},"elapsedMilliseconds":120,"willRetry":false}"#
    let record = try JSONDecoder().decode(OpenAttemptRecord.self, from: Data(line.utf8))
    #expect(record.kind == .primary)
    #expect(record.attempt == 1)
}

/// Breaks if `kind` is not encoded/decoded (including through the journal's own top-level "kind").
@Test func openAttemptRecordConfirmationKindRoundTripsThroughJournalEntry() throws {
    let record = OpenAttemptRecord(
        timestamp: Date(timeIntervalSince1970: 1), attempt: 1, maxAttempts: 3,
        outcome: .httpFailure(status: 500), elapsedMilliseconds: 5, willRetry: false, kind: .confirmation
    )
    let data = try JSONEncoder().encode(OpenJournalEntry.attempt(record))
    let decoded = try JSONDecoder().decode(OpenJournalEntry.self, from: data)
    #expect(decoded == .attempt(record))
    #expect(String(decoding: data, as: UTF8.self).contains(#""sendKind":"confirmation""#))
}
