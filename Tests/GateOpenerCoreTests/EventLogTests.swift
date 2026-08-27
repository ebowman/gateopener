import Foundation
import Testing
@testable import GateOpenerCore

// MARK: - Basic behavior

@Test func snapshotStartsEmpty() {
    let log = EventLog()
    #expect(log.snapshot().isEmpty)
    #expect(log.formattedText().isEmpty)
}

@Test func logOpenAttemptRecordsExpectedMessage() {
    let log = EventLog()
    log.logOpenAttempt(attempt: 1, of: 3)
    let entries = log.snapshot()
    #expect(entries.count == 1)
    #expect(entries[0].message == "open attempted (attempt 1 of 3)")
    #expect(entries[0].level == .info)
}

@Test func logOpenFailedWithStatusRecordsExpectedMessage() {
    let log = EventLog()
    log.logOpenFailed(attempt: 2, of: 3, status: 503)
    let entries = log.snapshot()
    #expect(entries.count == 1)
    #expect(entries[0].message == "attempt 2 of 3 failed with HTTP 503")
    #expect(entries[0].level == .warning)
}

@Test func logOpenFailedWithReasonRecordsExpectedMessage() {
    let log = EventLog()
    log.logOpenFailed(attempt: 1, of: 3, reason: .timeout)
    let entries = log.snapshot()
    #expect(entries[0].message == "attempt 1 of 3 failed (timed out)")
}

@Test func logOpenSucceededRecordsExpectedMessage() {
    let log = EventLog()
    log.logOpenSucceeded()
    #expect(log.snapshot()[0].message == "open succeeded")
}

@Test func logTokenRefreshedRecordsLifetimeOnly() {
    let log = EventLog()
    log.logTokenRefreshed(expiresIn: 604800)
    #expect(log.snapshot()[0].message == "refreshed token (expires in 604800s)")
}

// MARK: - logTokenRefreshed must never trap on non-finite input
//
// `Int(Double)` traps at runtime on `.nan`/`.infinity`/out-of-range
// magnitudes. The intended call site (`tokenSet.expiresAt.timeIntervalSinceNow`)
// is a computed `TimeInterval` that can legitimately produce any of these,
// and a LOGGING path must never crash the app. These inputs must render
// as "unknown" rather than trap.
@Test func logTokenRefreshedDoesNotTrapOnNonFiniteInput() {
    let log = EventLog()
    log.logTokenRefreshed(expiresIn: .nan)
    log.logTokenRefreshed(expiresIn: .infinity)
    log.logTokenRefreshed(expiresIn: -.infinity)
    log.logTokenRefreshed(expiresIn: 1e300) // finite, but far outside Int's range

    let entries = log.snapshot()
    #expect(entries.count == 4)
    for entry in entries {
        #expect(entry.message == "refreshed token (expires in unknowns)")
    }
}

/// The boundary case a naive range guard gets wrong.
///
/// `Double(Int.max)` rounds UP to 9223372036854775808.0 (== `Int.max + 1`),
/// which is NOT representable as an `Int`. A `guard expiresIn <= Double(Int.max)`
/// therefore ADMITS it and the following `Int(expiresIn)` traps. This test
/// crashes the suite against that implementation and passes against
/// `Int(exactly:)`.
///
/// `Double(Int.min)` is exactly representable, so it is NOT "unknown" — it
/// converts cleanly. Asserting otherwise would be wrong.
@Test func logTokenRefreshedHandlesIntBoundaryValues() {
    let log = EventLog()

    log.logTokenRefreshed(expiresIn: Double(Int.max))   // must not trap
    log.logTokenRefreshed(expiresIn: Double(Int.min))   // exactly representable

    let entries = log.snapshot()
    #expect(entries.count == 2)
    #expect(entries[0].message == "refreshed token (expires in unknowns)")
    #expect(entries[1].message == "refreshed token (expires in \(Int.min)s)")
}

@Test func logLoginPerformedRecordsExpectedMessage() {
    let log = EventLog()
    log.logLoginPerformed()
    #expect(log.snapshot()[0].message == "login performed")
}

@Test func logDiscoveryPerformedRecordsExpectedMessage() {
    let log = EventLog()
    log.logDiscoveryPerformed(endpointCount: 4)
    #expect(log.snapshot()[0].message == "discovery performed (4 endpoint(s) found)")
}

@Test func clearEmptiesTheBuffer() {
    let log = EventLog()
    log.logOpenSucceeded()
    log.clear()
    #expect(log.snapshot().isEmpty)
}

@Test func formattedTextContainsOneLinePerEntry() {
    let log = EventLog()
    log.logOpenAttempt(attempt: 1, of: 1)
    log.logOpenSucceeded()
    let text = log.formattedText()
    let lines = text.split(separator: "\n")
    #expect(lines.count == 2)
    #expect(text.contains("open attempted"))
    #expect(text.contains("open succeeded"))
}

// MARK: - Ring buffer cap (edge case from the bead)

@Test func ringBufferNeverExceedsCapacityUnder1000Appends() {
    let log = EventLog()
    for i in 0..<1000 {
        log.logOpenAttempt(attempt: i, of: 1000)
        #expect(log.snapshot().count <= EventLog.capacity)
    }
    let finalSnapshot = log.snapshot()
    #expect(finalSnapshot.count == EventLog.capacity)
    // The buffer should hold the MOST RECENT entries: the last recorded
    // attempt index (999) must be present, and the oldest ones (e.g. 0)
    // must have been evicted.
    #expect(finalSnapshot.last?.message.contains("attempt 999") == true)
    #expect(finalSnapshot.allSatisfy { !$0.message.contains("attempt 0 ") })
}

@Test func ringBufferCapMixedEventKindsStillBounded() {
    let log = EventLog()
    for i in 0..<1000 {
        switch i % 4 {
        case 0: log.logOpenAttempt(attempt: i, of: 1000)
        case 1: log.logOpenFailed(attempt: i, of: 1000, status: 500)
        case 2: log.logTokenRefreshed(expiresIn: 3600)
        default: log.logDiscoveryPerformed(endpointCount: i % 5)
        }
    }
    #expect(log.snapshot().count == EventLog.capacity)
}

// MARK: - The no-secrets test (the most important test in this bead)

@Test func noSecretSubstringEverAppearsInLogOutput() {
    let log = EventLog()

    // Realistic-looking secrets, deliberately shaped like real values but
    // NOT real credentials (fake JWT payload, fake refresh token, fake
    // password).
    let accessToken = "eyJhbGciOiJIUzI1NiJ9.SECRETPAYLOAD.sig"
    let refreshToken = "rt_9f8e7d6c5b4a3210fedcba9876543210deadbeef"
    let password = "Sup3rSecretPassw0rd!2026"
    let username = "test.user@example.com"

    let tokenSet = TokenSet(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresIn: 604800,
        tokenType: "Bearer"
    )

    // Feed the secrets through EVERY logging path EventLog exposes. None of
    // these typed methods accept a token/password parameter at all, so
    // there is no call here that could even syntactically pass the secret
    // through — this loop documents and exercises exactly that fact.
    log.logOpenAttempt(attempt: 1, of: 3)
    log.logOpenFailed(attempt: 1, of: 3, status: 401)
    log.logOpenFailed(attempt: 2, of: 3, reason: .unauthorized)
    log.logOpenSucceeded()
    log.logTokenRefreshed(expiresIn: tokenSet.expiresAt.timeIntervalSinceNow)
    log.logLoginPerformed()
    log.logDiscoveryPerformed(endpointCount: 2)

    let text = log.formattedText()
    let allMessages = log.snapshot().map(\.message).joined(separator: "\n")

    let secrets = [accessToken, refreshToken, password, username, "SECRETPAYLOAD", "Bearer "]
    for secret in secrets {
        #expect(!text.contains(secret), "formattedText() leaked secret substring: \(secret)")
        #expect(!allMessages.contains(secret), "a LogEntry.message leaked secret substring: \(secret)")
    }

    // Also assert the TokenSet's own accessToken/refreshToken values (not
    // just the literals above) never appear, in case a future refactor
    // changes how the fixture is constructed.
    #expect(!text.contains(tokenSet.accessToken))
    if let rt = tokenSet.refreshToken {
        #expect(!text.contains(rt))
    }
}

// MARK: - The reason: channel is closed (gateopener-4ub.19)
//
// `logOpenFailed(attempt:of:reason:)` used to take a free-form `String`,
// making it the ONE channel through which a secret could reach the log
// (e.g. a caller passing an underlying error's description that happened
// to embed a token, or a URL with a credential in its query string). It
// now takes a closed `OpenFailureReason` enum instead.
//
// This test documents, and proves, that the channel is closed: every
// case of `OpenFailureReason` is exercised, a hostile secret-shaped value
// is asserted absent from every log rendering, AND — critically — there is
// no way to even ATTEMPT to route the token/refresh-token/password strings
// from the no-secrets test above through this method, because
// `OpenFailureReason` is not `ExpressibleByStringLiteral` and has no case
// that wraps an associated `String`. A hostile call such as
// `log.logOpenFailed(attempt: 1, of: 1, reason: accessToken)` or
// `reason: .unknown(accessToken)` does not compile — it is not merely
// "safe at runtime", it cannot be expressed at all. (This comment is the
// closest thing to a compile-failure assertion available in a runtime
// test; the enum's shape is what actually guarantees the property.)
@Test func openFailureReasonChannelCannotCarryAnySecret() {
    let log = EventLog()

    let accessToken = "eyJhbGciOiJIUzI1NiJ9.SECRETPAYLOAD.sig"
    let refreshToken = "rt_9f8e7d6c5b4a3210fedcba9876543210deadbeef"
    let password = "Sup3rSecretPassw0rd!2026"

    // Exercise every case of the closed enum — this is the entire
    // surface of the `reason:` parameter. There is no other value it can
    // hold.
    for (index, reason) in OpenFailureReason.allCases.enumerated() {
        log.logOpenFailed(attempt: index + 1, of: OpenFailureReason.allCases.count, reason: reason)
    }

    let text = log.formattedText()
    let allMessages = log.snapshot().map(\.message).joined(separator: "\n")

    for secret in [accessToken, refreshToken, password, "SECRETPAYLOAD", "Bearer "] {
        #expect(!text.contains(secret), "OpenFailureReason channel leaked secret substring: \(secret)")
        #expect(!allMessages.contains(secret), "OpenFailureReason channel leaked secret substring: \(secret)")
    }

    // Every rendered message must be built ONLY from the enum's own
    // known, non-secret `logText` values — never from arbitrary caller
    // input, because none can be supplied.
    for reason in OpenFailureReason.allCases {
        #expect(text.contains(reason.logText))
    }
}
