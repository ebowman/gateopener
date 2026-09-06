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
    ///   - isReachable: The current reachability reading. If `false`, this
    ///     method fails fast with `"No network"` rather than queuing or
    ///     waiting — an extension process cannot sit around for the ~45s
    ///     `GateController.requestOpen()` queue TTL.
    ///   - open: Performs the actual open attempt (wraps
    ///     `GateController.openGate()`) and returns the controller's
    ///     resulting terminal-ish state. Not called at all for the
    ///     `.needsSetup` or unreachable paths.
    ///   - snapshot: Where every `WidgetSnapshot` this method writes is
    ///     persisted.
    ///   - reloadTimelines: Invoked after every snapshot write.
    ///   - timeout: How long to wait for `open()` before giving up and
    ///     returning `.timedOut`. Defaults to 25s — comfortably above the
    ///     ~15s worst-case `GateClient` retry budget (see the
    ///     `comelit-cloud-latency-and-timeout-budget` memory: do NOT shrink
    ///     the underlying per-request timeout to "fix" this; 25s here is
    ///     purely an extension-lifetime safety net) and comfortably below
    ///     the ~30s a widget/App-Intent extension process is typically
    ///     killed at.
    ///   - now: Injectable clock for the snapshot's `updatedAt`, defaulting
    ///     to `Date.init`.
    public func run(
        currentState: GateState,
        gateName: String?,
        isReachable: Bool,
        open: @escaping @Sendable () async -> GateState,
        snapshot: WidgetSnapshotStore,
        reloadTimelines: @Sendable () -> Void,
        timeout: Duration = .seconds(25),
        now: @Sendable () -> Date = Date.init
    ) async -> Outcome {
        if currentState == .needsSetup {
            write(.needsSetup, gateName: gateName, snapshot: snapshot, reloadTimelines: reloadTimelines, now: now)
            return .needsSetup
        }

        guard isReachable else {
            let message = "No network"
            write(.failed(message: message), gateName: gateName, snapshot: snapshot, reloadTimelines: reloadTimelines, now: now)
            return .failed(message: message)
        }

        write(.opening, gateName: gateName, snapshot: snapshot, reloadTimelines: reloadTimelines, now: now)

        let resultState = await raceAgainstTimeout(timeout: timeout, open: open)

        let outcome: Outcome
        let terminalState: GateState
        switch resultState {
        case .succeeded:
            outcome = .opened
            terminalState = .succeeded(at: now())
        case .failed(let message):
            outcome = .failed(message: message)
            terminalState = .failed(message: message)
        case .timedOut:
            let message = "Timed out"
            outcome = .timedOut
            terminalState = .failed(message: message)
        case .other:
            // `open()` returned some other, non-terminal `GateState` (e.g.
            // still `.opening`/`.idle`/`.queued`/`.needsSetup`) — this
            // should not happen given `GateController.openGate()` always
            // awaits its own completion, but is handled explicitly rather
            // than silently treated as success, per the bead's mapping.
            let message = "Unknown result"
            outcome = .failed(message: message)
            terminalState = .failed(message: message)
        }

        write(terminalState, gateName: gateName, snapshot: snapshot, reloadTimelines: reloadTimelines, now: now)
        return outcome
    }

    /// The three outcomes `raceAgainstTimeout` can produce, collapsing
    /// `GateState` down to only what `run(...)`'s mapping above cares about.
    private enum RaceResult {
        case succeeded
        case failed(message: String)
        case timedOut
        case other
    }

    /// Races `open()` against `timeout` using a `TaskGroup`: whichever
    /// finishes first wins, and the other is cancelled. `open()` itself is
    /// NOT structured to observe cancellation (it wraps `GateController
    /// .openGate()`, which does not check `Task.isCancelled`), so on a
    /// timeout the losing `open()` task is cancelled but may continue
    /// running in the background — acceptable here since `GateController`
    /// is idempotent against a second concurrent `openGate()` call (it
    /// awaits the existing in-flight task rather than starting a new one),
    /// and this method has already told the caller the attempt timed out.
    private func raceAgainstTimeout(
        timeout: Duration,
        open: @escaping @Sendable () async -> GateState
    ) async -> RaceResult {
        await withTaskGroup(of: RaceResult.self) { group in
            group.addTask {
                let state = await open()
                switch state {
                case .succeeded:
                    return .succeeded
                case .failed(let message):
                    return .failed(message: message)
                case .needsSetup, .idle, .opening, .queued:
                    return .other
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    // Cancelled because the `open()` task already won the
                    // race — return a value that will simply be discarded
                    // below, since `group.next()` returns the first
                    // COMPLETED result and this task, having been
                    // cancelled, only reaches here after that has already
                    // happened.
                    return .other
                }
                return .timedOut
            }

            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
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
