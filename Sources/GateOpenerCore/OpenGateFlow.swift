import Foundation

/// Orchestrates a single "open the gate" attempt on behalf of `OpenGateIntent`
/// (`iOS/Shared/OpenGateIntent.swift`), extracted into `GateOpenerCore` (a
/// plain, Foundation-only type) so `swift test` can exercise the ENTIRE
/// intent flow — including the timeout race — without any dependency on
/// `AppIntents`/`WidgetKit`, neither of which this target may import.
///
/// This mirrors bead .13's step 2 in the app-facing intent: `OpenGateIntent
/// .perform()` is a thin wrapper that resolves an `AppEnvironment` and calls
/// `run(...)` here, so the only untested code left in the intent itself is
/// the few lines that build the closures this type is handed.
///
/// `Sendable` because `run(...)` is `async` and may be called from a
/// non-main-actor context (an `AppIntent.perform()` is not itself
/// main-actor-isolated); the closures it is handed (`open`, `reloadTimelines`,
/// `now`) are all `@Sendable` for the same reason. `snapshot`
/// (`WidgetSnapshotStore`) is itself `Sendable` (backed only by
/// `UserDefaults`, documented thread-safe).
public struct OpenGateFlow: Sendable {
    /// The result of running the flow, mapped 1:1 to the dialog string
    /// `OpenGateIntent` returns to Siri/Shortcuts/widget UI.
    public enum Outcome: Equatable, Sendable {
        /// `currentState == .needsSetup`: no usable credentials/selected gate.
        /// Zero `open()` calls were made.
        case needsSetup
        /// The underlying `open()` call completed with `GateState.succeeded`.
        case opened
        /// The underlying `open()` call completed with `GateState.failed`,
        /// or with some other non-terminal state (treated as "unknown
        /// result" — see `run(...)`'s doc comment), OR `isReachable` was
        /// `false` (short-circuited before ever calling `open()`).
        case failed(message: String)
        /// `open()` did not complete before `timeout` elapsed.
        case timedOut

        /// The user-facing dialog string for this outcome, returned verbatim
        /// by `OpenGateIntent.perform()` as its `IntentDialog`.
        public var dialog: String {
            switch self {
            case .needsSetup:
                return "Sign in to GateOpener first"
            case .opened:
                return "Gate opened"
            case .failed(let message):
                return message
            case .timedOut:
                return "Timed out"
            }
        }
    }

    public init() {}

    /// Runs one open attempt end to end, writing a `WidgetSnapshot` at every
    /// step so the widget/Lock Screen surfaces reflect what is happening in
    /// (near) real time, even though this may be running in a separate
    /// extension process from the app.
    ///
    /// Every path through this method writes exactly one TERMINAL snapshot
    /// (`needsSetup`, `succeeded`, or `failed`) and calls `reloadTimelines()`
    /// at least once — the `needsSetup` and unreachable short-circuits call
    /// it exactly once (no `.opening` snapshot is ever written for those,
    /// since no attempt is actually made); the full-attempt path calls it
    /// twice: once after publishing `.opening`, and once more after the
    /// terminal snapshot is written.
    ///
    /// NOTE on interaction with `AppEnvironment.make()`: that composition
    /// root installs its OWN `controller.onStateChange` subscriber, which
    /// ALSO writes a snapshot + reloads timelines on every `GateState`
    /// transition — so by the time `open()` (which drives `GateController
    /// .openGate()`) returns here, the controller has typically ALREADY
    /// published the terminal snapshot once via that subscriber. This
    /// method's own terminal write below is therefore usually a redundant,
    /// idempotent re-write of the same phase/message — harmless (the same
    /// bytes, done twice) and deliberately kept so `OpenGateFlow` remains
    /// correct and self-contained even if it is ever driven by something
    /// that does NOT go through `AppEnvironment.make()`'s subscriber.
    ///
    /// - Parameters:
    ///   - currentState: `GateController.state` as observed at the start of
    ///     this call.
    ///   - gateName: `AppSettings.selectedEndpointName`, threaded through to
    ///     every `WidgetSnapshot` written.
    ///   - isReachable: The reachability reading at the start of the press;
    ///     seeds the loop's first check. If `false`, the loop calls
    ///     `waitForReachability` (bounded by the deadline) instead of
    ///     failing fast; if that returns `false`, the outcome is
    ///     `.failed("No network")` with no `open()` call made.
    ///   - open: Performs the actual open attempt (wraps
    ///     `GateController.openGate()`) and returns the controller's
    ///     resulting terminal-ish state. Not called at all for the
    ///     `.needsSetup` or unreachable paths.
    ///   - snapshot: Where every `WidgetSnapshot` this method writes is
    ///     persisted.
    ///   - reloadTimelines: Invoked after every snapshot write.
    ///   - deadline: Hard limit, measured from `pressStartedAt` via `now`,
    ///     after which nothing is opened. Defaults to 27s, inside iOS's ~30s
    ///     background-intent budget. Individual attempts are raced against
    ///     the time remaining, so they never extend past it. The underlying
    ///     `GateClient` per-request timeouts (3s/5s/8s) are NOT changed (see
    ///     the `comelit-cloud-latency-and-timeout-budget` memory).
    ///   - minimumAttemptWindow: No attempt is started with less than this
    ///     remaining before the deadline (3.5s: a fresh attempt cannot
    ///     realistically finish sooner). Default 3.5s.
    ///   - retryDelay: Pause between attempts (never past the deadline).
    ///   - sleep: Injectable sleep for `retryDelay`; defaults to `Task.sleep`.
    ///   - isReachableNow: Re-checked between attempts. Defaults to
    ///     returning the original `isReachable` value.
    ///   - waitForReachability: Called with the remaining time when the
    ///     device is not reachable; returns `true` if connectivity returned
    ///     in time. Default `{ _ in false }` ("no way to wait").
    ///   - now: Injectable clock for the snapshot's `updatedAt`, defaulting
    ///     to `Date.init`.
    ///   - journal: Optional sink for `OpenPressRecord` phase checkpoints
    ///     (see `OpenPressPhase`), called synchronously once per phase this
    ///     method emits. `nil` by default, in which case `run` behaves
    ///     exactly as if journaling did not exist -- this bead (Core only)
    ///     wires phase emission itself; the actual `OpenAttemptJournal`-
    ///     backed closure and source/process/appVersion metadata are wired
    ///     by callers (iOS, bead gateopener-41m.23), not by this type.
    ///   - pressId: Correlates every phase emitted by this call, and (via
    ///     `OpenPressContext.$pressId.withValue`, bound only around the
    ///     `open()` invocation) every `OpenAttemptRecord` produced inside
    ///     `open()`. Defaults to a fresh `UUID()` per call.
    ///   - pressStartedAt: When this press began, for computing each
    ///     emitted phase's `elapsedMilliseconds`. Defaults to `Date()` (now)
    ///     -- callers that already know the press's true start time (e.g.
    ///     the intent's own entry point) should pass it explicitly so
    ///     elapsed times reflect the whole press, not just this call.
    ///   - reachabilityDetail: Free-form, non-secret string describing the
    ///     `isReachable` reading (e.g. the underlying `NWPath` status name),
    ///     included verbatim in the emitted `.reachability` phase. Defaults
    ///     to `""`.
    ///   - pressSource: `OpenPressRecord.source` for every phase this call
    ///     emits, e.g. "intent"/"app"/"queued". Defaults to `"intent"` (this
    ///     flow's original, and still primary, caller).
    ///   - pressProcess: `OpenPressRecord.process` for every phase this call
    ///     emits, e.g. `Bundle.main.bundleIdentifier ?? "?"` (this Core
    ///     target never reads `Bundle.main` itself). Defaults to `"?"`.
    ///   - pressAppVersion: `OpenPressRecord.appVersion` for every phase
    ///     this call emits, e.g. `"0.1.9 (11)"`. Defaults to `""`.
    public func run(
        currentState: GateState,
        gateName: String?,
        isReachable: Bool,
        open: @escaping @Sendable () async -> GateState,
        snapshot: WidgetSnapshotStore,
        reloadTimelines: @Sendable () -> Void,
        deadline: Duration = .seconds(27),
        minimumAttemptWindow: Duration = .seconds(3.5),
        retryDelay: Duration = .seconds(1),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        isReachableNow: (@Sendable () -> Bool)? = nil,
        waitForReachability: @escaping @Sendable (Duration) async -> Bool = { _ in false },
        now: @escaping @Sendable () -> Date = Date.init,
        journal: (@Sendable (OpenPressRecord) -> Void)? = nil,
        pressId: UUID = UUID(),
        pressStartedAt: Date = Date(),
        reachabilityDetail: String = "",
        pressSource: String = "intent",
        pressProcess: String = "?",
        pressAppVersion: String = ""
    ) async -> Outcome {
        func emit(_ phase: OpenPressPhase) {
            guard let journal else { return }
            let elapsedMilliseconds: Int
            switch phase {
            case .started:
                elapsedMilliseconds = 0
            default:
                let elapsedSeconds = now().timeIntervalSince(pressStartedAt)
                elapsedMilliseconds = Int(max(0, elapsedSeconds) * 1000)
            }
            journal(
                OpenPressRecord(
                    pressId: pressId,
                    timestamp: now(),
                    source: pressSource,
                    process: pressProcess,
                    appVersion: pressAppVersion,
                    phase: phase,
                    elapsedMilliseconds: elapsedMilliseconds
                )
            )
        }

        emit(.reachability(isReachable: isReachable, detail: reachabilityDetail))

        if currentState == .needsSetup {
            write(.needsSetup, gateName: gateName, snapshot: snapshot, reloadTimelines: reloadTimelines, now: now)
            emit(.finished(outcome: Outcome.needsSetup.dialog))
            return .needsSetup
        }

        write(.opening, gateName: gateName, snapshot: snapshot, reloadTimelines: reloadTimelines, now: now)

        let deadlineDate = pressStartedAt.addingTimeInterval(deadline.timeInterval)
        func remaining() -> Duration {
            let seconds = deadlineDate.timeIntervalSince(now())
            return .seconds(max(0, seconds))
        }

        var reachableNow = isReachable
        var attemptNumber = 0
        // `nil` until some attempt completed with a (retryable) failure.
        var lastFailure: String?
        var finalOutcome: Outcome?
        var terminalOverride: GateState?

        loop: while true {
            // (b) Not reachable: wait (bounded by the deadline) for connectivity.
            if !reachableNow {
                emit(.waitingForNetwork)
                let cameBack = await waitForReachability(remaining())
                if !cameBack {
                    finalOutcome = .failed(message: "No network")
                    break loop
                }
                reachableNow = true
            }

            // (c) Staleness rule: never start an attempt with too little time left.
            if remaining() < minimumAttemptWindow {
                if let lastFailure {
                    finalOutcome = .failed(message: lastFailure)
                } else {
                    finalOutcome = .timedOut
                }
                break loop
            }

            // (d) One attempt, never allowed to run past the deadline. The
            // next attempt is only started after this one has returned, so
            // `open()` is never invoked concurrently with itself.
            attemptNumber += 1
            if attemptNumber == 1 { emit(.openStarted) }
            emit(.attempt(number: attemptNumber))
            let result = await OpenPressContext.$pressId.withValue(pressId) {
                await OpenPressContext.$pressStartedAt.withValue(pressStartedAt) {
                    await OpenPressContext.$pressSource.withValue(pressSource) {
                        await raceAgainstTimeout(timeout: remaining(), open: open)
                    }
                }
            }

            switch result {
            case .succeeded:
                finalOutcome = .opened
                break loop
            case .needsSetup:
                finalOutcome = .needsSetup
                terminalOverride = .needsSetup
                break loop
            case .timedOut:
                finalOutcome = .timedOut
                break loop
            case .failed(let message):
                if !Self.isRetryable(message: message) {
                    finalOutcome = .failed(message: message)
                    break loop
                }
                lastFailure = message
            case .other:
                // `open()` returned some other, non-terminal `GateState`
                // (e.g. still `.opening`/`.idle`/`.queued`) -- should not
                // happen given `GateController.openGate()` always awaits
                // its own completion; treated as a retryable failure.
                lastFailure = "Unknown result"
            }

            // (f) Delay before the next attempt, never past the deadline.
            let left = remaining()
            if left <= .zero {
                finalOutcome = .failed(message: lastFailure ?? "Unknown result")
                break loop
            }
            do {
                try await sleep(min(retryDelay, left))
            } catch {
                finalOutcome = .failed(message: lastFailure ?? "Unknown result")
                break loop
            }
            if let isReachableNow {
                reachableNow = isReachableNow()
            } else {
                reachableNow = isReachable
            }
        }

        let outcome = finalOutcome ?? .timedOut
        let terminalState: GateState
        if let terminalOverride {
            terminalState = terminalOverride
        } else {
            switch outcome {
            case .opened:
                terminalState = .succeeded(at: now())
            case .failed(let message):
                terminalState = .failed(message: message)
            case .timedOut:
                terminalState = .failed(message: "Timed out")
            case .needsSetup:
                terminalState = .needsSetup
            }
        }

        write(terminalState, gateName: gateName, snapshot: snapshot, reloadTimelines: reloadTimelines, now: now)
        if outcome == .timedOut {
            emit(.timedOut)
        } else {
            emit(.finished(outcome: outcome.dialog))
        }
        return outcome
    }

    /// Whether a failure message produced by `GateController.performOpen()`
    /// (via `GateErrorMessage.short(for:)`) is worth retrying. The message
    /// string is the only signal available through `GateState.failed`.
    ///
    /// NON-retryable (retrying cannot help within the press):
    ///  - "Wrong username or password" (`ComelitError.invalidCredentials`):
    ///    the stored credentials are rejected.
    ///  - "No gate found" (`GateClientError.noEndpointsFound`/`.noGateFound`):
    ///    the account has no usable gate.
    ///  - "Unlock iPhone to open the gate" (keychain `errSecInteractionNotAllowed`):
    ///    the phone is locked before first unlock; credentials unreadable
    ///    until the user unlocks.
    /// Everything else (network, timeout, 5xx, 429, generic) is retryable.
    public static func isRetryable(message: String) -> Bool {
        !nonRetryableMessages.contains(message)
    }

    static let nonRetryableMessages: Set<String> = [
        "Wrong username or password",
        "No gate found",
        "Unlock iPhone to open the gate",
    ]

    /// The three outcomes `raceAgainstTimeout` can produce, collapsing
    /// `GateState` down to only what `run(...)`'s mapping above cares about.
    private enum RaceResult {
        case succeeded
        case needsSetup
        case failed(message: String)
        case timedOut
        case other
    }

    /// Races `open()` against `timeout`: whichever finishes first wins and
    /// the caller resumes IMMEDIATELY with that result.
    ///
    /// Implemented with two unstructured `Task`s and a checked continuation
    /// resumed exactly once (lock-guarded), NOT a `TaskGroup` -- a group
    /// awaits all children before returning, and production `open()` (which
    /// wraps `GateController.openGate()` awaiting an unstructured `Task`)
    /// ignores cancellation, so a group would not return until the real
    /// open finished. Here, on timeout the losing `open()` task is
    /// cancelled best-effort but may keep running in the background;
    /// `run(...)` NEVER waits for it. (Task-locals set by the caller are
    /// inherited by the unstructured tasks.) Because the loop ends after a
    /// `.timedOut`, no second `open()` is started while a prior one may
    /// still be in flight.
    private func raceAgainstTimeout(
        timeout: Duration,
        open: @escaping @Sendable () async -> GateState
    ) async -> RaceResult {
        let gate = RaceGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<RaceResult, Never>) in
            let openTask = Task {
                let state = await open()
                let result: RaceResult
                switch state {
                case .succeeded: result = .succeeded
                case .failed(let message): result = .failed(message: message)
                case .needsSetup: result = .needsSetup
                case .idle, .opening, .queued: result = .other
                }
                if gate.claim() { continuation.resume(returning: result) }
            }
            let timerTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return  // cancelled: open() already won
                }
                if gate.claim() {
                    continuation.resume(returning: .timedOut)
                    openTask.cancel()
                }
            }
            gate.onWin { timerTask.cancel() }
        }
    }

    /// One-shot flag: `claim()` returns true for exactly the first caller.
    private final class RaceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        private var winHandler: (@Sendable () -> Void)?

        func claim() -> Bool {
            lock.lock()
            if claimed { lock.unlock(); return false }
            claimed = true
            let handler = winHandler
            lock.unlock()
            handler?()
            return true
        }

        /// Runs `handler` when the race is (or already was) won.
        func onWin(_ handler: @escaping @Sendable () -> Void) {
            lock.lock()
            if claimed { lock.unlock(); handler(); return }
            winHandler = handler
            lock.unlock()
        }
    }

    private func write(
        _ state: GateState,
        gateName: String?,
        snapshot: WidgetSnapshotStore,
        reloadTimelines: @Sendable () -> Void,
        now: @Sendable () -> Date
    ) {
        snapshot.write(WidgetSnapshot.from(state: state, gateName: gateName, now: now()))
        reloadTimelines()
    }
}
