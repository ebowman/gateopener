import Foundation
import Observation
import GateOpenerCore

/// iOS app-target `@Observable` bridge from `GateController`'s plain,
/// non-Observable `state`/`onStateChange` to SwiftUI observation.
///
/// This is a deliberately separate, minimal file from
/// `Sources/GateOpener/GateControllerObservable.swift` (the macOS menu-bar
/// app's version) rather than a shared/reused one — see the DECISION note
/// on bead gateopener-672.7: the macOS version references `GlobalHotkey`,
/// which imports AppKit + Carbon.HIToolbox and is macOS-only, so it cannot
/// be compiled into the iOS target. This file has no hotkey/event-log/
/// shortcut-preference surface at all, only state mirroring plus a
/// `requestOpen()` forwarder.
///
/// Mirrors state via `AppEnvironment.addStateObserver(_:)` rather than
/// assigning `controller.onStateChange` directly, so it composes with the
/// snapshot-publishing subscriber `AppEnvironment.make()` already installs
/// on that same closure property — `GateController` retains only one
/// `onStateChange` closure, so a second direct assignment here would
/// silently replace (not add to) the snapshot publisher.
@MainActor
@Observable
final class GateControllerObservable {
    /// The controller this adapter wraps. Exposed so callers can invoke
    /// `openGate()`, etc. directly if needed.
    let controller: GateController

    /// The latest state, kept in sync with `controller.state` via
    /// `AppEnvironment.addStateObserver(_:)`. `@Observable` makes reads of
    /// this property from SwiftUI views trigger re-render on change.
    private(set) var state: GateState

    /// The runner `requestOpen()` forwards to, so an open dispatched from
    /// SwiftUI runs inside a `UIApplication` background task (see
    /// `BackgroundOpenRunner`) rather than risking suspension mid-flight.
    private let backgroundOpenRunner: BackgroundOpenRunner

    /// The journal this class writes in-app press records to (bead
    /// gateopener-41m.23). `nil` exactly when `environment.openAttemptJournal`
    /// is `nil` (no App Group container, or the `--mock-gate` debug seam) —
    /// in which case `requestOpen()`/state observation below simply write
    /// nothing, matching `OpenGateFlow`'s own "journal: nil -> no-op" policy.
    private let journal: OpenAttemptJournal?

    /// Free-form, non-secret reachability detail string, read lazily at the
    /// moment a `.queued` transition needs it (never at journal-write time
    /// for other phases) — see `reachabilityDetail`'s doc comment on
    /// `NWPathMonitorReachability.pathDescription` for the format.
    private let reachabilityDetail: () -> String

    /// The process bundle id and app version stamped on every press record
    /// this class writes, resolved once at construction (both are static
    /// for the process's lifetime).
    private let process: String
    private let appVersion: String

    /// State for the SINGLE in-flight in-app press this class currently
    /// tracks (see `requestOpen()`/`STEP 8` of the bead brief: "a single
    /// in-flight press at a time in the observable"). `nil` when no in-app
    /// press is currently open; `requestOpen()` refuses to start a second
    /// one on top of an existing in-flight press (matching `GateController
    /// .requestOpen()`'s own `.opening`/`.queued` coalescing — a second tap
    /// while one is already in flight must not fork a second untracked
    /// press).
    private var inFlightPress: (pressId: UUID, startedAt: Date, wasQueued: Bool)?

    /// - Parameters:
    ///   - environment: Supplies `controller`, `openAttemptJournal`, and the
    ///     multicast `addStateObserver(_:)` seam used both by this class (to
    ///     mirror `state`) and, separately, by `backgroundOpenRunner`
    ///     (registered by the caller — see `GateOpenerIOSApp` — so
    ///     background-task begin/end tracks every state transition, not
    ///     just the one immediately following a `requestOpen()` call).
    ///   - backgroundOpenRunner: The runner `requestOpen()` forwards to.
    ///   - reachabilityDetail: Supplies `NWPathMonitorReachability
    ///     .pathDescription` (or an equivalent) for the `.reachability`
    ///     phase written when a request is queued. Defaults to `{ "" }`
    ///     (empty detail) so existing call sites/tests that do not care
    ///     about this string need no changes; `GateOpenerIOSApp` passes the
    ///     real reachability instance's `pathDescription`.
    init(
        environment: AppEnvironment,
        backgroundOpenRunner: BackgroundOpenRunner,
        reachabilityDetail: @escaping () -> String = { "" }
    ) {
        self.controller = environment.controller
        self.state = environment.controller.state
        self.backgroundOpenRunner = backgroundOpenRunner
        self.journal = environment.openAttemptJournal
        self.reachabilityDetail = reachabilityDetail
        self.process = Bundle.main.bundleIdentifier ?? "?"
        self.appVersion = AppVersion.current
        environment.addStateObserver { [weak self] newState in
            self?.handleStateChange(newState)
        }
    }

    /// TEST SEAM ONLY: builds this class directly from a `GateController`
    /// (registering the state observer via `controller.onStateChange`
    /// itself, rather than `AppEnvironment.addStateObserver(_:)`) instead of
    /// an `AppEnvironment`.
    ///
    /// This exists because `AppEnvironment.make()` has NO `credentialStore:`
    /// injection parameter (see `OpenGateIntentTests`'s "IMPORTANT GAP" doc
    /// comment for the same limitation elsewhere) — it always constructs a
    /// real `KeychainCredentialStore`, so there is no way to make an
    /// `AppEnvironment`-backed `GateController` start `.idle` (rather than
    /// `.needsSetup`) without touching the real Keychain access group, which
    /// this test bundle must never do. A directly-constructed
    /// `GateController` (exactly as `BackgroundOpenRunnerTests
    /// .makeIdleController` already does, with an `InMemoryCredentialStore`)
    /// has no such restriction. `controller.onStateChange` is assigned
    /// directly here (not `addStateObserver`, an `AppEnvironment`-only API)
    /// — acceptable ONLY because this initializer is never used alongside a
    /// real `AppEnvironment`'s own snapshot-publishing subscriber.
    init(
        testController controller: GateController,
        backgroundOpenRunner: BackgroundOpenRunner,
        journal: OpenAttemptJournal?,
        reachabilityDetail: @escaping () -> String = { "" }
    ) {
        self.controller = controller
        self.state = controller.state
        self.backgroundOpenRunner = backgroundOpenRunner
        self.journal = journal
        self.reachabilityDetail = reachabilityDetail
        self.process = Bundle.main.bundleIdentifier ?? "?"
        self.appVersion = AppVersion.current
        controller.onStateChange = { [weak self] newState in
            self?.handleStateChange(newState)
        }
    }

    /// Forwards to `BackgroundOpenRunner.requestOpen()`, which wraps
    /// `controller.requestOpen()` in a `UIApplication` background task so
    /// leaving the app mid-open does not get the open command killed.
    ///
    /// PRESS JOURNALING (bead gateopener-41m.23): writes `.started` (source
    /// "app") for a new in-app press before forwarding to
    /// `backgroundOpenRunner`, UNLESS a press is already in flight (matching
    /// `GateController.requestOpen()`'s own `.opening`/`.queued` coalescing
    /// -- a repeat tap while one is already in flight is a no-op there, and
    /// must not start a second, untracked press here either).
    ///
    /// ATTEMPT CORRELATION GAP (per this bead's brief, deliberately not
    /// fixed here): `GateController.requestOpen()` calls `openGate()` ->
    /// `performOpen()` internally, NOT from this observable, so there is no
    /// call site here that could wrap the underlying `GateClient.open()` in
    /// `OpenPressContext.$pressId.withValue(...)` without changing
    /// `GateOpenerCore`. As a result, `OpenAttemptRecord`s produced by an
    /// in-app open do NOT carry this press's `pressId` -- only the press
    /// lines themselves (`.started`/`.reachability`/`.finished`) are
    /// written, and they still are valuable on their own (they show when an
    /// in-app tap happened and how it concluded, even without per-attempt
    /// correlation).
    func requestOpen() {
        if inFlightPress == nil {
            let pressId = UUID()
            let startedAt = Date()
            inFlightPress = (pressId, startedAt, false)
            emit(.started, pressId: pressId, startedAt: startedAt, source: "app")
        }
        backgroundOpenRunner.requestOpen()
    }

    /// Mirrors `state` (unchanged from before this bead) and, additionally,
    /// journals the in-app press's phases for AS LONG AS `inFlightPress` is
    /// set (i.e. only while a press started via THIS class's `requestOpen()`
    /// is outstanding) -- a state change with no in-flight press (e.g. the
    /// very first snapshot-publish at construction, or a state change caused
    /// by something other than this class, such as `OpenGateIntent` running
    /// concurrently in the widget extension) writes nothing here.
    private func handleStateChange(_ newState: GateState) {
        state = newState

        guard let press = inFlightPress else { return }

        switch newState {
        case .queued:
            // First time we observe `.queued` for this press: emit the
            // reachability phase and remember we've done so (so a second
            // `.queued` -- which should not normally happen for the SAME
            // press, but is handled defensively -- does not double-emit).
            guard !press.wasQueued else { return }
            inFlightPress = (press.pressId, press.startedAt, true)
            emit(
                .reachability(isReachable: false, detail: reachabilityDetail()),
                pressId: press.pressId,
                startedAt: press.startedAt,
                source: "app"
            )
        case .succeeded:
            inFlightPress = nil
            emit(
                .finished(outcome: "Gate opened"),
                pressId: press.pressId,
                startedAt: press.startedAt,
                source: "app"
            )
        case .failed(let message):
            inFlightPress = nil
            emit(
                .finished(outcome: message),
                pressId: press.pressId,
                startedAt: press.startedAt,
                source: "app"
            )
        case .idle:
            // As of this writing, `GateController`'s only route out of
            // `.queued` is `.queued` -> `.failed(message: "No network")`
            // (TTL elapsed, see `handleQueueTTLElapsed`) -> (after the
            // controller's own auto-reset delay) `.idle` -- the `.failed`
            // case above already closes out the press and clears
            // `inFlightPress`, so THAT path never reaches this branch at
            // all. This branch exists defensively, per the bead brief, for
            // any current/future path that could abandon a queued press
            // directly back to `.idle` WITHOUT an intervening `.failed`
            // (e.g. if `signOut()` is ever changed to reset to `.idle`
            // instead of `.needsSetup` while a request is queued) --
            // without it, such a press would otherwise never receive a
            // `.finished` phase at all.
            if press.wasQueued {
                inFlightPress = nil
                emit(
                    .finished(outcome: "Queue expired"),
                    pressId: press.pressId,
                    startedAt: press.startedAt,
                    source: "app"
                )
            }
        case .needsSetup, .opening:
            break
        }
    }

    private func emit(_ phase: OpenPressPhase, pressId: UUID, startedAt: Date, source: String) {
        guard let journal else { return }
        let elapsedMilliseconds: Int
        switch phase {
        case .started:
            elapsedMilliseconds = 0
        default:
            elapsedMilliseconds = Int(max(0, Date().timeIntervalSince(startedAt)) * 1000)
        }
        journal.record(
            OpenPressRecord(
                pressId: pressId,
                timestamp: Date(),
                source: source,
                process: process,
                appVersion: appVersion,
                phase: phase,
                elapsedMilliseconds: elapsedMilliseconds
            )
        )
    }
}
