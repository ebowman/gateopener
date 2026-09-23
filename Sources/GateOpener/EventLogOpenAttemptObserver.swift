import Foundation
import GateOpenerCore

/// Adapts `GateClient`'s per-attempt `OpenAttemptObserving` callback (bead
/// gateopener-41m.1) onto the macOS app's existing `EventLog` typed methods
/// (bead gateopener-4ub.10), so the menu-bar app's log shows the REAL
/// attempt count and HTTP status per retry -- e.g. "attempt 2 of 3 failed
/// with HTTP 500" -- instead of the state-driven "attempt 1 of 1" /
/// `.unknown` placeholder `GateOpenerApp.swift` used to record (see that
/// file's `controller.onStateChange` wiring, now reduced to success/failure
/// UI handling only -- this observer is the sole source of open-attempt log
/// lines).
///
/// One `record(_:)` call maps to exactly TWO `EventLog` calls, in order:
///   1. `logOpenAttempt(attempt:of:)` -- `GateClient` only calls
///      `record(_:)` once an attempt's outcome is already known (see
///      `OpenAttemptObserving`'s doc comment: it is notified "after that
///      attempt's outcome... is known"), so there is no earlier moment at
///      which this observer could log "attempt N of M" separately; logging
///      it here, immediately before the outcome line, preserves the
///      existing "attempt N of M" log line `GateOpenerApp.swift` used to
///      produce (previously always "1 of 1") without claiming a real-time
///      "attempt started" notification this seam cannot provide.
///   2. The outcome line:
///      - `.success(status:)` -> `logOpenSucceeded()` (the status code
///        itself is not separately logged; `EventLog.logOpenSucceeded()`
///        takes no parameters, matching its existing shape).
///      - `.httpFailure(status:)` -> `logOpenFailed(attempt:of:status:)`.
///      - `.transportFailure` -> `logOpenFailed(attempt:of:reason: .transport)`.
///      - `.tokenFailure` -> `logOpenFailed(attempt:of:reason: .unauthorized)`,
///        since every current call site of `OpenAttemptOutcome.tokenFailure`
///        (see `GateClient.open`) is a bearer-token resolution failure -- an
///        authorization problem, not a network-layer one.
///
/// `Sendable` (required by `OpenAttemptObserving`): holds only a reference
/// to `EventLog`, which is itself `@unchecked Sendable`/internally
/// lock-guarded, so this type has no mutable state of its own to protect.
struct EventLogOpenAttemptObserver: OpenAttemptObserving {
    private let eventLog: EventLog

    init(eventLog: EventLog) {
        self.eventLog = eventLog
    }

    func record(_ record: OpenAttemptRecord) {
        eventLog.logOpenAttempt(attempt: record.attempt, of: record.maxAttempts)
        switch record.outcome {
        case .success:
            eventLog.logOpenSucceeded()
        case .httpFailure(let status):
            eventLog.logOpenFailed(attempt: record.attempt, of: record.maxAttempts, status: status)
        case .transportFailure:
            eventLog.logOpenFailed(attempt: record.attempt, of: record.maxAttempts, reason: .transport)
        case .tokenFailure:
            eventLog.logOpenFailed(attempt: record.attempt, of: record.maxAttempts, reason: .unauthorized)
        }
    }
}
