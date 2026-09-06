import Foundation
import GateOpenerCore
import Observation

/// Owns the ONE `DoorVideoSession` slot `MainView` shows (bead
/// gateopener-672.12): starts a session alongside a gate open (when
/// enabled) or on an explicit "View door" tap, retains an in-flight session
/// across repeat requests, and auto-clears it a beat after it ends so the
/// panel can animate out before the view disappears.
///
/// This is a plain `@Observable` class (not tied to `GateControllerObservable`
/// or `GateController` directly) so `MainView` can observe `isPanelVisible`/
/// `session` independently of gate-open state — an open failing must NOT
/// tear down a session that is still streaming (see this bead's EDGE CASES).
@MainActor
@Observable
final class DoorVideoCoordinator {
    /// Builds a fresh `DoorVideoSession` on demand. Injected (rather than
    /// this type constructing `DoorVideoSession` itself) so tests (bead
    /// gateopener-672.18) can supply a fake factory and assert `start()` is
    /// called exactly once across two `startForOpen()`/`viewDoor()` calls
    /// made while a session is warming up — see `sessionStartCount` below.
    private let makeSession: @MainActor () -> DoorVideoSession

    /// Whether auto-showing video on a gate open is currently enabled
    /// (`AppSettings.autoShowDoorVideoOnOpen`). Read fresh on every
    /// `startForOpen()` call (a closure, not a captured `Bool`) so a
    /// Settings change taking effect mid-session is honored immediately.
    /// `viewDoor()` deliberately ignores this — it is an explicit user
    /// action independent of the auto-show preference.
    private let isEnabled: () -> Bool

    /// The current session, or `nil` when nothing has ever started, or the
    /// most recent session has fully cleared (see `scheduleAutoClear`).
    private(set) var session: DoorVideoSession?

    /// True while `session` is `.connecting` or `.streaming` — the signal
    /// `MainView` uses to show/animate the video panel. `false` for `nil`,
    /// `.idle`, `.ended`, and `.failed` sessions (a `.failed` session is
    /// cleared silently per this bead's EDGE CASES; a brief window between
    /// the terminal state and `scheduleAutoClear` firing is intentional so
    /// the panel can animate out rather than disappearing instantly).
    private(set) var isPanelVisible: Bool = false

    /// Mirrors the current session's `state` so `MainView` (which observes
    /// this coordinator, not the plain, non-`@Observable` `DoorVideoSession`
    /// itself) re-renders on every connecting -> streaming -> ended/failed
    /// transition. Fixes bead gateopener-672.29: passing `session.state`
    /// directly to `DoorVideoView` never triggered a SwiftUI re-render
    /// because `DoorVideoSession` is not `@Observable`, leaving the panel
    /// stuck showing "Connecting…" even once frames were actually
    /// streaming. Reset to `.idle` on `dismiss()` and whenever the
    /// auto-clear timer nils `session` out.
    private(set) var sessionState: DoorVideoSession.State = .idle

    /// Number of times `makeSession()` has actually been invoked (i.e. a
    /// NEW session was created, as opposed to an existing one being
    /// retained). `internal` (not `private`) so a unit test (bead
    /// gateopener-672.18) can assert exactly one `start()` across two taps
    /// made during warm-up/streaming — the retention rule this bead
    /// requires.
    private(set) var sessionStartCount = 0

    /// Delay after `.ended`/`.failed` before `session` is cleared to `nil`,
    /// long enough for `MainView`'s `withAnimation` disappear transition to
    /// visibly run before the panel is actually removed from the view
    /// hierarchy.
    private let autoClearDelay: Duration

    /// Cancelled/replaced on every new session so at most one auto-clear
    /// timer is ever pending.
    private var autoClearTask: Task<Void, Never>?

    /// - Parameters:
    ///   - makeSession: Builds a fresh `DoorVideoSession` per replace. See
    ///     `makeSession`'s doc comment.
    ///   - isEnabled: Read fresh on every `startForOpen()`. See `isEnabled`'s
    ///     doc comment.
    ///   - autoClearDelay: Defaults to 1 second (this bead's brief). Exposed
    ///     for tests so they need not wait a full second.
    init(
        makeSession: @escaping @MainActor () -> DoorVideoSession,
        isEnabled: @escaping () -> Bool,
        autoClearDelay: Duration = .seconds(1)
    ) {
        self.makeSession = makeSession
        self.isEnabled = isEnabled
        self.autoClearDelay = autoClearDelay
    }

    /// Called on the SAME synchronous path as a gate-open request
    /// (`MainView.handleTap()`), immediately after `observable.requestOpen()`
    /// — never awaited before or after the open. No-ops entirely when
    /// `isEnabled()` is false. Otherwise applies the same start-or-retain
    /// policy as `viewDoor()`.
    func startForOpen() {
        guard isEnabled() else { return }
        startOrRetain()
    }

    /// Starts (or retains) a session in response to an explicit "View door"
    /// tap, ignoring `isEnabled()` — this is a deliberate user action, not
    /// the auto-show-on-open behavior. A tap while a session is already
    /// live (connecting/streaming) is a no-op beyond retaining it.
    func viewDoor() {
        startOrRetain()
    }

    /// Stops and discards the current session immediately (no animation
    /// delay) — used for the panel's explicit dismiss (X) button and for
    /// backgrounding (`scenePhase == .background`).
    func dismiss() {
        autoClearTask?.cancel()
        autoClearTask = nil
        session?.stop()
        session = nil
        isPanelVisible = false
        sessionState = .idle
    }

    /// Shared retain-or-replace policy for `startForOpen()`/`viewDoor()`:
    /// `GateOpenerCore.DoorVideoSessionRetention.decision(forExistingPhase:)`
    /// applied against the current session's phase, mirroring the pattern
    /// `OverlayWindowController` (macOS) and `DoorVideoSession.start()`
    /// itself already use. `.retain` (connecting/streaming) does nothing at
    /// all — no new session, no new `start()` call, `onStateChange` still
    /// points at the existing session. `.replace` builds a fresh session via
    /// `makeSession()` and starts it.
    private func startOrRetain() {
        let decision = DoorVideoSessionRetention.decision(forExistingPhase: session?.state.phase)
        guard decision == .replace else { return }

        autoClearTask?.cancel()
        autoClearTask = nil

        let newSession = makeSession()
        sessionStartCount += 1
        session = newSession
        isPanelVisible = false

        newSession.onStateChange = { [weak self] state in
            self?.handleStateChange(state, for: newSession)
        }

        Task {
            await newSession.start()
        }
    }

    /// Publishes `isPanelVisible` on every state transition and schedules
    /// the auto-clear timer once a session reaches a terminal state.
    /// Guarded by identity (`for: newSession`) so a stale callback from a
    /// session that has since been replaced/dismissed can never clobber the
    /// current one.
    private func handleStateChange(_ state: DoorVideoSession.State, for changedSession: DoorVideoSession) {
        guard session === changedSession else { return }

        sessionState = state

        switch state {
        case .idle:
            isPanelVisible = false
        case .connecting, .streaming:
            isPanelVisible = true
        case .ended, .failed:
            // `.failed` hides silently (no error alert) and `.ended` fades
            // out — both routes clear the session the same way, after the
            // same short delay, so the panel's disappear animation has time
            // to run either way.
            isPanelVisible = false
            scheduleAutoClear(for: changedSession)
        }
    }

    /// Clears `session` to `nil` ~`autoClearDelay` after a terminal state,
    /// so `MainView`'s disappear transition can animate before the panel is
    /// actually removed. Guarded by identity so a session that got replaced
    /// before the delay elapses is never incorrectly nilled out.
    private func scheduleAutoClear(for changedSession: DoorVideoSession) {
        autoClearTask?.cancel()
        autoClearTask = Task { [weak self] in
            try? await Task.sleep(for: self?.autoClearDelay ?? .seconds(1))
            guard !Task.isCancelled else { return }
            guard let self, self.session === changedSession else { return }
            self.session = nil
            self.sessionState = .idle
        }
    }
}
