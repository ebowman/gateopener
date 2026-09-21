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

    /// Whether auto-starting video on app launch/foreground is currently
    /// enabled (`AppSettings.autoStartDoorVideoOnLaunch`, bead
    /// gateopener-41m.12). Read fresh on every `startForForeground()` call —
    /// same reasoning as `isEnabled` above. Deliberately a SEPARATE closure
    /// from `isEnabled`: launch/foreground auto-start and open-triggered
    /// auto-start are independent user preferences (see
    /// `AppSettings.autoStartDoorVideoOnLaunch`'s doc comment).
    ///
    /// Defaults to `{ true }` so every existing test-construction call site
    /// (`DoorVideoCoordinatorTests`, all of which pass only `makeSession:`/
    /// `isEnabled:`) keeps compiling unchanged. This default is safe for
    /// those tests specifically because none of them call
    /// `startForForeground()` — they only exercise `startForOpen()`/
    /// `viewDoor()`/`dismiss()`, so the default's value never affects a
    /// `sessionStartCount` assertion. A default of `{ false }` would be the
    /// "safer-looking" choice in isolation, but is NOT required for
    /// compilation or test correctness here, and would silently make any
    /// FUTURE test that forgets to pass `isAutoStartEnabled:` and then calls
    /// `startForForeground()` fail confusingly (zero sessions where one was
    /// expected) rather than matching the shipped default (auto-start ON).
    private let isAutoStartEnabled: () -> Bool

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

    /// Mirrors the current session's `cooldownUntil` (bead gateopener-41m.9)
    /// so `MainView` can tell the user the video panel is waiting out a
    /// door-busy cooldown before it issues the `rtc/offer` PUT. `nil` when
    /// no session exists, or the current session is not waiting out a
    /// cooldown. Cleared to `nil` on `dismiss()` and whenever the auto-clear
    /// timer nils `session` out — same lifecycle as `sessionState`.
    private(set) var cooldownUntil: Date?

    /// How the most recent session (if any) most recently finished, used by
    /// `MainView`'s permanent video slot (bead gateopener-41m.11) to choose
    /// between the plain "Tap to view door" placeholder and the
    /// "Retry"-with-message placeholder once `session` itself has been
    /// auto-cleared to `nil`. Unlike `sessionState`/`cooldownUntil`, this is
    /// NOT reset by `scheduleAutoClear` — it is the one piece of state that
    /// must survive the session being cleared, precisely so the placeholder
    /// can keep showing "why" after the session object itself is gone.
    ///
    /// Reset to `.none`:
    ///   - whenever a NEW session actually starts (`startOrRetain()`), so a
    ///     stale "failed"/"ended" reason from a previous session never
    ///     leaks into a fresh one's `.connecting` placeholder;
    ///   - whenever the USER explicitly closes the panel (the `dismiss()`
    ///     call from `MainView`'s close (X) button) — the user has
    ///     acknowledged whatever happened, so the placeholder should go back
    ///     to the neutral "Tap to view door" state.
    ///
    /// Deliberately NOT reset by the scenePhase-driven `dismiss()` call
    /// `GateOpenerIOSApp` makes when the app backgrounds — per this bead's
    /// STEPS, that path shares the same `dismiss()` method as the user's
    /// close button, and both resetting to `.none` is the documented,
    /// accepted behavior (backgrounding is treated the same as the user
    /// closing the panel).
    private(set) var lastTerminal: LastTerminal = .none

    /// See `lastTerminal`.
    enum LastTerminal: Equatable {
        case none
        case ended
        case failed(String)
    }

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

    /// Pure renew-or-stop policy for a PINNED session finishing (bead
    /// gateopener-41m.14). Stateless — this coordinator owns
    /// `consecutiveFailures` and the pin's elapsed-time bookkeeping
    /// (`pinnedSince`) and hands both to `decide(...)` on every `.ended`/
    /// `.failed` transition of the pinned session.
    private let pinPolicy: DoorVideoPinPolicy

    /// Injected clock, following the `autoClearDelay` precedent, so tests
    /// can simulate `pinnedElapsed` reaching `pinPolicy.maxPinnedDuration`
    /// without a real multi-minute wait.
    private let now: () -> Date

    /// Injected sleep used ONLY for a pinned session's failure backoff
    /// (`pinPolicy`'s `.renew(after:)` with `after > 0`) so tests can make
    /// that wait instant. Deliberately NOT used for the door-busy cooldown
    /// itself — `DoorVideoSession.start()` already waits that out
    /// internally (bead gateopener-41m.9), so an `after == 0` renewal here
    /// is always safe to start immediately without this coordinator adding
    /// any wait of its own.
    private let renewSleep: (Duration) async throws -> Void

    /// Emits one-line, timestamped coordinator/pin events (bead
    /// gateopener-41m.20) — "pin on", "pin off (user)", "pin renew #n
    /// (after ended|failed: <message>)", "pin backoff <s>s (failures=n)",
    /// "pin stop: <reason>", "cooldown wait <s>s", "dismiss (...)",
    /// "auto-start (foreground)" — so a pinned viewing period's renewal/
    /// backoff/stop history survives independently of any single session's
    /// diagnostics.
    ///
    /// Defaults to a NO-OP so every existing test-construction call site
    /// (`DoorVideoCoordinatorTests`, none of which pass `eventSink:`) stays
    /// hermetic and unchanged — it never writes to any `UserDefaults`
    /// unless a test opts in by passing its own sink. `GateOpenerIOSApp`
    /// wires the real sink (a `VideoDiagnostics.appendEvent(_:to:)` writer
    /// on the shared app-group defaults).
    private let eventSink: (String) -> Void

    /// True while the video is pinned (bead gateopener-41m.14): while
    /// pinned, a session that finishes (`.ended`/`.failed`) is replaced
    /// with a fresh one per `pinPolicy`, instead of the panel simply
    /// hiding. Never persisted — always `false` on a fresh coordinator.
    private(set) var isPinned = false

    /// When the CURRENT pin started (bead gateopener-41m.14), i.e. the most
    /// recent `setPinned(true)` call — NOT reset by individual session
    /// renewals, so `pinPolicy`'s `maxPinnedDuration` budget is measured
    /// against the whole pinned period. `nil` while unpinned.
    private(set) var pinnedSince: Date?

    /// Short, human-readable reason the pin most recently stopped itself
    /// (`DoorVideoPinPolicy.stopMessage(_:)`), or `nil` if the pin was never
    /// engaged, is still active, or was stopped by the user (`dismiss()`/
    /// `setPinned(false)`, neither of which sets this — only a policy-driven
    /// `.stop(reason)` does). Cleared by `setPinned(true)` and by any new
    /// user-initiated start (`viewDoor()`/`startForOpen()`/
    /// `startForForeground()` via `startOrRetain()`).
    private(set) var pinStopMessage: String?

    /// Number of consecutive `.failed` outcomes on the CURRENT pin, INCLUDING
    /// the one about to be decided — reset to `0` whenever a pinned session
    /// reaches `.streaming` (and therefore also on the `.ended` that
    /// naturally follows a streaming session), and whenever the pin itself
    /// (re)starts via `setPinned(true)`. `DoorVideoPinPolicy` itself is
    /// stateless; this is the bookkeeping it depends on.
    private var consecutiveFailures = 0

    /// Whether `.streaming` was reached during the CURRENT session, checked
    /// when that session finishes to decide whether to reset
    /// `consecutiveFailures`. Reset to `false` every time a new session
    /// starts.
    private var reachedStreamingThisSession = false

    /// The single pending pinned-renewal task (bead gateopener-41m.14's
    /// failure-backoff path, `pinPolicy`'s `.renew(after:)` with
    /// `after > 0`). At most one is ever outstanding: cancelled and
    /// replaced by `startOrRetain()`, `dismiss()`, and `setPinned(false)`,
    /// and by a fresh renewal superseding an earlier one.
    private var renewTask: Task<Void, Never>?

    /// Number of PINNED renewals started on the CURRENT pin (bead
    /// gateopener-41m.15 STEP 4) — incremented exactly where
    /// `handlePinnableTermination(_:for:whenNotRenewing:)` decides
    /// `.renew(after:)` and actually calls `startSession(resetPanelVisible:
    /// false)` (both the immediate `after == 0` path and the failure-backoff
    /// path once its sleep completes and it starts the replacement), NOT
    /// merely when a renewal is scheduled — a `renewTask` that is later
    /// cancelled (e.g. by `dismiss()`/`startOrRetain()` superseding it) must
    /// not count as a renewal that happened. Reset to `0` by `setPinned(_:)`
    /// (both directions) and by `dismiss()`, so a later pin starts counting
    /// fresh. `internal` (not `private`) so `DoorVideoCoordinatorTests` can
    /// assert it directly.
    private(set) var pinRenewalCount = 0

    /// `true` once the CURRENTLY mounted session is itself a pinned renewal
    /// (`pinRenewalCount > 0`) — bead gateopener-41m.15 STEP 4's signal for
    /// `MainView`/`DoorVideoSlotContent.content(...)` to show "Reconnecting…"
    /// instead of `DoorVideoView`'s own "Connecting…"/"Camera unavailable"
    /// text: the pin's very FIRST session has nothing to "reconnect" to yet,
    /// so it still shows the ordinary text.
    var isRenewing: Bool { pinRenewalCount > 0 }

    /// - Parameters:
    ///   - makeSession: Builds a fresh `DoorVideoSession` per replace. See
    ///     `makeSession`'s doc comment.
    ///   - isEnabled: Read fresh on every `startForOpen()`. See `isEnabled`'s
    ///     doc comment.
    ///   - isAutoStartEnabled: Read fresh on every `startForForeground()`.
    ///     See `isAutoStartEnabled`'s doc comment, including why its default
    ///     is `{ true }`.
    ///   - autoClearDelay: Defaults to 1 second (this bead's brief). Exposed
    ///     for tests so they need not wait a full second.
    ///   - pinPolicy: Defaults to `DoorVideoPinPolicy()`. See `pinPolicy`'s
    ///     doc comment.
    ///   - now: Defaults to `Date.init`. See `now`'s doc comment.
    ///   - renewSleep: Defaults to `Task.sleep(for:)`. See `renewSleep`'s doc
    ///     comment.
    ///   - eventSink: Defaults to a no-op. See `eventSink`'s doc comment.
    init(
        makeSession: @escaping @MainActor () -> DoorVideoSession,
        isEnabled: @escaping () -> Bool,
        isAutoStartEnabled: @escaping () -> Bool = { true },
        autoClearDelay: Duration = .seconds(1),
        pinPolicy: DoorVideoPinPolicy = DoorVideoPinPolicy(),
        now: @escaping () -> Date = Date.init,
        renewSleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        eventSink: @escaping (String) -> Void = { _ in }
    ) {
        self.makeSession = makeSession
        self.isEnabled = isEnabled
        self.isAutoStartEnabled = isAutoStartEnabled
        self.autoClearDelay = autoClearDelay
        self.pinPolicy = pinPolicy
        self.now = now
        self.renewSleep = renewSleep
        self.eventSink = eventSink
    }

    /// Time remaining in the current pin's total budget
    /// (`pinPolicy.maxPinnedDuration`), or `nil` while unpinned. See
    /// `DoorVideoPinPolicy.remaining(pinnedElapsed:)`.
    var pinRemaining: TimeInterval? {
        guard isPinned, let pinnedSince else { return nil }
        return pinPolicy.remaining(pinnedElapsed: now().timeIntervalSince(pinnedSince))
    }

    /// Pins (or unpins) the door video (bead gateopener-41m.14).
    ///
    /// `true`: marks the pin as started now, resets the failure count, and
    /// clears any previous `pinStopMessage`; if no session is currently
    /// connecting/streaming, starts one via `startOrRetain()` (which itself
    /// also clears `pinStopMessage`, harmlessly redundant with the clear
    /// here).
    ///
    /// `false`: clears all pin state and cancels any pending renew task,
    /// but deliberately does NOT touch the current session — it keeps
    /// playing to its natural end, per this bead's STEPS.
    func setPinned(_ on: Bool) {
        if on {
            isPinned = true
            pinnedSince = now()
            consecutiveFailures = 0
            pinStopMessage = nil
            pinRenewalCount = 0
            eventSink("pin on")

            let phase = session?.state.phase
            if phase != .connecting, phase != .streaming {
                startOrRetain()
            }
        } else {
            isPinned = false
            pinnedSince = nil
            pinRenewalCount = 0
            renewTask?.cancel()
            renewTask = nil
            eventSink("pin off (user)")
        }
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

    /// Starts (or retains) a session on app launch/foreground (bead
    /// gateopener-41m.12), called from `GateOpenerIOSApp` on cold launch and
    /// on every `scenePhase == .active` transition. No-ops entirely when
    /// `isAutoStartEnabled()` is false. Otherwise applies the same
    /// start-or-retain policy as `startForOpen()`/`viewDoor()` — in
    /// particular, calling this twice back-to-back (e.g. once from a cold
    /// launch's `.task` and once from the `scenePhase` handler firing for
    /// the same transition) starts at most one session, since the second
    /// call lands while the first is `.connecting` and is retained rather
    /// than replaced.
    func startForForeground() {
        guard isAutoStartEnabled() else { return }
        eventSink("auto-start (foreground)")
        startOrRetain()
    }

    /// Stops and discards the current session immediately (no animation
    /// delay) — used for the panel's explicit dismiss (X) button and for
    /// backgrounding (`scenePhase == .background`). Always unpins (bead
    /// gateopener-41m.14): both the user closing the panel and the app
    /// backgrounding are treated as ending any active pin, and the pin is
    /// never persisted across either.
    ///
    /// - Parameter reason: A short, human-readable tag identifying WHY this
    ///   was called (bead gateopener-41m.20's `eventSink` event, logged as
    ///   `"dismiss (<reason>)"`), e.g. `"user"` (the close button) or
    ///   `"background"` (the scenePhase handler). Defaults to `"user"` so
    ///   `MainView`'s existing close-button call site needs no change; the
    ///   `scenePhase` handler in `GateOpenerIOSApp` passes `"background"`
    ///   explicitly. Purely diagnostic — never changes this method's
    ///   behavior or any pin/renewal logic.
    func dismiss(reason: String = "user") {
        autoClearTask?.cancel()
        autoClearTask = nil
        renewTask?.cancel()
        renewTask = nil
        isPinned = false
        pinnedSince = nil
        pinRenewalCount = 0
        session?.stop()
        session = nil
        isPanelVisible = false
        sessionState = .idle
        cooldownUntil = nil
        lastTerminal = .none
        eventSink("dismiss (\(reason))")
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

        // A new user/foreground-initiated start supersedes any pending
        // pinned-renewal backoff: cancel it so at most one new session is
        // ever created for this seam (bead gateopener-41m.14's "startForOpen()
        // during a backoff wait -> exactly one new session").
        renewTask?.cancel()
        renewTask = nil
        pinStopMessage = nil

        startSession()
    }

    /// Builds and starts a genuinely fresh `DoorVideoSession` via
    /// `makeSession()` and wires it up as the current session. Shared by
    /// `startOrRetain()` and the pinned-renewal paths
    /// (`handleStateChange(_:for:)`'s `.renew` handling) so there is exactly
    /// ONE place that ever creates+starts a session — renewal must ALWAYS
    /// use a fresh instance via `makeSession()`, never `start()` on an ended
    /// instance (its script message handlers/navigation delegate are torn
    /// down by `stop()`/`endDueToLiveness`, so a reused instance is silently
    /// broken).
    /// - Parameter resetPanelVisible: `true` (the default, used by
    ///     `startOrRetain()`) resets `isPanelVisible` to `false` before the
    ///     new session's own `.connecting` transition sets it back to `true`
    ///     — the normal "nothing is showing yet" starting point. A PINNED
    ///     `.renew(after: 0)` renewal passes `false` instead: `isPanelVisible`
    ///     is already `true` from the session that just ended (it was
    ///     `.connecting`/`.streaming` a moment ago), and this bead's design
    ///     explicitly requires the panel to stay visible with no flash
    ///     across that renew seam.
    private func startSession(resetPanelVisible: Bool = true) {
        autoClearTask?.cancel()
        autoClearTask = nil

        let newSession = makeSession()
        sessionStartCount += 1
        reachedStreamingThisSession = false
        session = newSession
        if resetPanelVisible {
            isPanelVisible = false
        }
        cooldownUntil = nil
        lastTerminal = .none

        newSession.onStateChange = { [weak self] state in
            self?.handleStateChange(state, for: newSession)
        }
        newSession.onCooldownChange = { [weak self] cooldownUntil in
            self?.handleCooldownChange(cooldownUntil, for: newSession)
        }

        Task {
            await newSession.start()
        }
    }

    /// Publishes `cooldownUntil` on every change to the current session's
    /// own `cooldownUntil` (bead gateopener-41m.9). Guarded by identity
    /// (`for: newSession`), same as `handleStateChange`, so a stale callback
    /// from a session that has since been replaced/dismissed can never
    /// clobber the current one.
    private func handleCooldownChange(_ cooldownUntil: Date?, for changedSession: DoorVideoSession) {
        guard session === changedSession else { return }
        if let cooldownUntil, self.cooldownUntil == nil {
            let seconds = max(0, Int(cooldownUntil.timeIntervalSince(now()).rounded()))
            eventSink("cooldown wait \(seconds)s")
        }
        self.cooldownUntil = cooldownUntil
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
        case .connecting:
            isPanelVisible = true
        case .streaming:
            isPanelVisible = true
            reachedStreamingThisSession = true
        case .ended:
            if reachedStreamingThisSession {
                consecutiveFailures = 0
            }
            handlePinnableTermination(.ended, message: nil, for: changedSession) {
                // `.ended` fades out; the session is cleared the same way
                // as `.failed`, after the same short delay, so the panel's
                // disappear animation has time to run.
                self.isPanelVisible = false
                self.lastTerminal = .ended
                self.scheduleAutoClear(for: changedSession)
            }
        case .failed(let message):
            if reachedStreamingThisSession {
                consecutiveFailures = 0
            }
            consecutiveFailures += 1
            handlePinnableTermination(.failed, message: message, for: changedSession) {
                // `.failed` hides silently (no error alert) — `lastTerminal`
                // carries the REAL message forward so `MainView`'s
                // placeholder can show it (bead gateopener-41m.11) once
                // `session` itself is cleared below.
                self.isPanelVisible = false
                self.lastTerminal = .failed(message)
                self.scheduleAutoClear(for: changedSession)
            }
        }
    }

    /// Shared `.ended`/`.failed` handling for a PINNED session (bead
    /// gateopener-41m.14): asks `pinPolicy` what to do and either renews or
    /// stops the pin; when unpinned (`pinPolicy` immediately returns
    /// `.stop(.notPinned)`), falls through unchanged to `whenNotRenewing`
    /// (today's existing ended/failed handling), exactly as before this
    /// bead.
    ///
    /// - Parameters:
    ///   - outcome: how `changedSession` finished, already translated to
    ///     `DoorVideoPinPolicy.SessionOutcome`.
    ///   - message: the `.failed(message)` message when `outcome == .failed`,
    ///     `nil` for `.ended` — used ONLY to build the `eventSink` "pin renew"
    ///     event text (bead gateopener-41m.20); never affects any
    ///     pin/renewal decision.
    ///   - changedSession: the session that just finished; only consulted
    ///     for the `.renew` case's identity/mount bookkeeping.
    ///   - whenNotRenewing: the pre-existing ended/failed handling (hide the
    ///     panel, publish `lastTerminal`, schedule auto-clear) — run
    ///     whenever the policy says `.stop(_:)`, i.e. for an unpinned
    ///     session OR a pin that has just given up.
    private func handlePinnableTermination(
        _ outcome: DoorVideoPinPolicy.SessionOutcome,
        message: String?,
        for changedSession: DoorVideoSession,
        whenNotRenewing: () -> Void
    ) {
        guard isPinned, let pinStartedAt = pinnedSince else {
            whenNotRenewing()
            return
        }

        let decision = pinPolicy.decide(
            isPinned: true,
            outcome: outcome,
            pinnedElapsed: now().timeIntervalSince(pinStartedAt),
            consecutiveFailures: consecutiveFailures
        )

        // "ended"/"failed: <message>" fragment shared by both the immediate
        // and backoff "pin renew #n (after ...)" event lines below.
        let afterDescription: String = {
            switch outcome {
            case .ended:
                return "ended"
            case .failed:
                return "failed: \(message ?? "")"
            }
        }()

        switch decision {
        case .renew(let after):
            renewTask?.cancel()
            if after <= 0 {
                // Create + start the replacement SYNCHRONOUSLY inside this
                // handler so `session` is never `nil` between sessions and
                // `isPanelVisible` stays true throughout — this is what
                // stops `startForOpen()`/`viewDoor()` racing a second offer
                // during the gap (they see a `.connecting` session and
                // retain). Skip the hide/auto-clear path entirely:
                // `isPanelVisible` is left exactly as it was (`true`, since
                // the just-ended session was `.connecting`/`.streaming`
                // right before this), no `lastTerminal` change (stays
                // `.none`), no `scheduleAutoClear`.
                isPanelVisible = true
                pinRenewalCount += 1
                eventSink("pin renew #\(pinRenewalCount) (after \(afterDescription))")
                startSession(resetPanelVisible: false)
            } else {
                // Failure backoff: leave the just-failed `changedSession`
                // mounted as `session` and `isPanelVisible` as it already
                // was (true, from `.connecting`/`.streaming` before the
                // failure) so the UI does not flash the "failed" placeholder
                // during the wait — simpler than pre-creating the
                // replacement and delaying only its `start()`, since it
                // needs no extra "is this session started yet" bookkeeping
                // and the identity guard above already ignores any further
                // (there are none) callbacks from the terminal session.
                isPanelVisible = true
                eventSink("pin backoff \(Int(after))s (failures=\(consecutiveFailures))")
                renewTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.renewSleep(.seconds(after))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    guard self.session === changedSession else { return }
                    self.isPanelVisible = true
                    self.pinRenewalCount += 1
                    self.eventSink("pin renew #\(self.pinRenewalCount) (after \(afterDescription))")
                    self.startSession(resetPanelVisible: false)
                }
            }
        case .stop(let reason):
            isPinned = false
            pinnedSince = nil
            pinStopMessage = DoorVideoPinPolicy.stopMessage(reason)
            eventSink("pin stop: \(reason)")
            whenNotRenewing()
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
            self.cooldownUntil = nil
        }
    }
}
