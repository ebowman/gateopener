import AppKit
import AVFoundation
import os
import GateOpenerCore

/// Shows a small, borderless HUD panel in the top-right corner of the
/// screen that PROVABLY never steals keyboard focus from whatever app the
/// user is currently typing into.
///
/// This exists instead of AVKit's built-in Picture-in-Picture because PiP is
/// designed for user-chosen, user-controlled media: it ships its own
/// playback chrome, a close button, and lets the user drag/resize/persist
/// its position across launches. All of that is wrong for a confirmation
/// HUD that appears for a few seconds and then goes away on its own — this
/// controller instead owns a plain `NSPanel` with exactly the behavior this
/// app needs and nothing more.
///
/// The panel is created LAZILY, on the first presentation — never in
/// `init` — so a run that never shows an overlay (e.g. a headless
/// self-test) never touches window-server machinery at all. This mirrors
/// `NotificationPresenter`'s lazy resolution of `UNUserNotificationCenter`.
///
/// THE load-bearing guarantee of this type: `show()` calls
/// `orderFrontRegardless()` and NEVER `makeKeyAndOrderFront(_:)` or
/// `NSApp.activate(...)`. The gate is typically triggered by a global
/// hotkey while the user is typing in some other app, and their keystrokes
/// must keep landing in that app, uninterrupted, the entire time the panel
/// is visible.
@MainActor
final class OverlayWindowController {
    private static let logger = Logger(subsystem: "com.gateopener", category: "overlay")

    /// Fixed panel size. 240x180 is a 4:3 aspect ratio deliberately matching
    /// the door camera's native 320x240 resolution, so a future live-feed
    /// overlay (see `setContent(_:)`) can reuse this exact frame without any
    /// geometry rework — do not change this to a square.
    static let panelSize = NSSize(width: 240, height: 180)

    private static let edgeInset: CGFloat = 16

    /// Whether the panel ignores mouse events (clicks pass through to
    /// whatever is underneath). Defaults to `true`, which is what THIS
    /// bead's confirmation overlay needs: it is pure decoration, and a
    /// click over its frame must always reach the app beneath it. Exposed
    /// as a constructor parameter (rather than hard-coded) because a future
    /// "View door" feature reuses this same panel for an interactive,
    /// user-dismissable live feed, and will need clicks to actually hit the
    /// panel. One parameter now avoids restructuring this type later.
    private let ignoresMouseEvents: Bool

    private var panel: OverlayPanel?

    /// Injected rather than constructed internally: `handle(_:)` must read
    /// `showOpenConfirmationOverlay` fresh on every call (see that method's
    /// doc comment for why), and taking the same `AppSettings` instance the
    /// rest of the app layer already holds (see call sites in
    /// `GateOpenerApp.swift`) keeps this type from silently reading a
    /// second, possibly-different `UserDefaults` suite than the one actually
    /// governing the running app.
    private let appSettings: AppSettings

    /// Factory for a fresh `DoorVideoSession` on the gate-OPEN path (bead
    /// gateopener-12h.6) — deliberately the SAME shape as
    /// `DoorVideoOverlayController.makeSession`, and for the same reason:
    /// building a real session requires the concrete `TokenManager`/
    /// `GateClient` instances that only exist in the app's real (non-mock)
    /// dependency graph (see `AppDelegate.makeGateController`). `nil` when
    /// the caller has no such dependency graph to offer (mock mode, or a
    /// caller — e.g. the confirmation-overlay unit-test-only construction
    /// path — that simply doesn't want this feature); `handleOpening()`
    /// treats a `nil` factory exactly like the `autoShowDoorVideoOnOpen`
    /// setting being off: canned-animation-only, today's exact behavior.
    private let makeDoorVideoSession: (() -> DoorVideoSession?)?

    /// - Parameters:
    ///   - ignoresMouseEvents: see the property doc above. Defaults to
    ///     `true` for the confirmation-overlay use case.
    ///   - appSettings: source of `showOpenConfirmationOverlay`/
    ///     `autoShowDoorVideoOnOpen`, read fresh on every `handle(_:)` call.
    ///     See the property doc above for why this is injected rather than
    ///     constructed internally.
    ///   - makeDoorVideoSession: see the property doc above. Defaults to
    ///     `nil` (no live-video-on-open feature at all), which is exactly
    ///     what every existing call site that does not pass this parameter
    ///     needs — this widens `init`'s surface without breaking any
    ///     existing caller.
    init(
        appSettings: AppSettings,
        ignoresMouseEvents: Bool = true,
        makeDoorVideoSession: (() -> DoorVideoSession?)? = nil
    ) {
        self.appSettings = appSettings
        self.ignoresMouseEvents = ignoresMouseEvents
        self.makeDoorVideoSession = makeDoorVideoSession
    }

    /// Replaces the panel's displayed content. Callers may call this before
    /// or after `show()`; if called before the panel exists yet, the view is
    /// held and installed the moment the panel is lazily created.
    ///
    /// THIS IS THE SWAPPABILITY SEAM: nothing about panel creation,
    /// positioning, focus behavior, or lifecycle depends on what `view` is.
    /// This bead installs a plain placeholder (see `makePlaceholderContent()`
    /// below); a future live-camera feature calls this same method with an
    /// `RTCMTLNSVideoView` (or similar) instead, touching no other part of
    /// this type.
    ///
    /// gateopener-12h.2: swapping content into an ALREADY-VISIBLE panel must
    /// start the incoming content and stop the outgoing content, exactly as
    /// `show()`/`hide()` would, even though neither of those is called here.
    /// Without this, content swapped in after the panel is already on screen
    /// (e.g. show a "connecting" placeholder, then swap in the live video
    /// once frames arrive) never receives `overlayWillShow()` and sits frozen
    /// — for video, a black tile that looks like a WebRTC failure rather than
    /// the lifecycle bug it actually is.
    ///
    /// - The OUTGOING view's `overlayDidHide()` fires first (only when the
    ///   panel is visible and content is actually being replaced, not
    ///   installed for the first time), so a swapped-out player pauses rather
    ///   than continuing to decode off-screen.
    /// - The INCOMING view's `overlayWillShow()` fires only when the panel
    ///   both exists and `isVisible`. When the panel is not visible yet, a
    ///   later `show()` call is what delivers that hook — firing it here too
    ///   would double-fire it.
    /// - Re-setting the SAME view is a no-op: neither hook fires. A same-view
    ///   re-set is not a transition, and firing `overlayWillShow()` alone
    ///   (unpaired with a `overlayDidHide()`) would restart a video from
    ///   frame zero. Callers that swap content on state changes can
    ///   legitimately re-set the view they already installed.
    /// - No reordering/re-positioning/re-presenting of the panel happens
    ///   here: this method only ever touches content-view lifecycle hooks,
    ///   never `orderFrontRegardless()`/`position(_:on:)`.
    func setContent(_ view: NSView) {
        let outgoing = currentContent()
        let isPanelVisible = panel?.isVisible ?? false

        pendingContent = view
        panel?.installContent(view)

        guard isPanelVisible else { return }

        // Re-setting the SAME view is a genuine no-op, not a transition.
        // Without this guard `overlayWillShow()` would fire unpaired (no
        // matching `overlayDidHide()`), which for a video view means
        // seek(.zero) + play() — silently restarting the stream from the
        // beginning. The live-camera code swaps content on state changes
        // and can legitimately re-set the view it already installed.
        guard outgoing !== view else { return }

        (outgoing as? OverlayShowHideResponding)?.overlayDidHide()
        (view as? OverlayShowHideResponding)?.overlayWillShow()
    }

    private var pendingContent: NSView?

    /// The content view currently on screen, if any.
    ///
    /// Prefers what the panel actually has installed, falling back to
    /// `pendingContent` for the case where `setContent(_:)` was called
    /// before the panel was lazily created. Both orders must resolve
    /// correctly: `show()` uses this to deliver `OverlayShowHideResponding`
    /// hooks, so returning nil here would silently mean video playback
    /// never starts.
    private func currentContent() -> NSView? {
        panel?.currentContentView ?? pendingContent
    }

    /// Shows the panel, creating it on first call. Safe to call repeatedly:
    /// at most one panel is ever created, so a second call reuses the
    /// existing one rather than stacking another on screen.
    ///
    /// It is NOT a no-op while already visible: each call re-runs
    /// `position(_:on:)` and `orderFrontRegardless()`. That is deliberate —
    /// it is what lets a show() after a hide() re-display correctly, and it
    /// re-anchors the panel if the active screen changed between calls.
    ///
    /// Silently degrades (logs a notice and returns) if there is no screen
    /// at all to position against — e.g. a headless CI/self-test process.
    ///
    /// PRIVATE by design: for THIS instance's `GateState`-driven confirmation
    /// overlay, `handle(_:)` is the sole driver of presentation (see the type
    /// doc comment and gateopener-9kk.6/9kk.9) and no caller should reach
    /// around it. gateopener-12h.5 needed exactly the out-of-band "show a new
    /// panel" entry point this comment used to say no feature would ever
    /// need: `showForVideo()` below exposes that, but ONLY for a caller that
    /// owns its own, separate `OverlayWindowController` instance dedicated to
    /// that purpose (see `DoorVideoOverlayController`, which never touches
    /// `handle(_:)` and is not driven by `GateState` at all) — the
    /// confirmation-overlay instance's own presentation still flows solely
    /// through `handle(_:)`. See `hide()`'s doc comment for the parallel
    /// asymmetric decision on that method.
    private func show() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Self.logger.notice("no screen available; skipping overlay presentation")
            return
        }

        let resolvedPanel = resolvePanel()
        position(resolvedPanel, on: screen)

        // orderFrontRegardless() — NEVER makeKeyAndOrderFront(_:), NEVER
        // NSApp.activate(...). Either of those would steal focus from
        // whatever app the user is currently typing into, which is exactly
        // what this entire type exists to prevent.
        resolvedPanel.orderFrontRegardless()

        (currentContent() as? OverlayShowHideResponding)?.overlayWillShow()
    }

    /// SAFE TO CALL EXTERNALLY — the video-overlay counterpart to `hide()`'s
    /// own external-safety note (gateopener-9kk.9). A thin public wrapper
    /// around `show()`, added for `DoorVideoOverlayController`
    /// (gateopener-12h.5): that type owns its OWN `OverlayWindowController`
    /// instance (constructed with `ignoresMouseEvents: false`, distinct from
    /// the `GateState`-driven confirmation-overlay instance `AppDelegate`
    /// owns) and drives its presentation directly from
    /// `DoorVideoSessionState`, not from `GateState`/`handle(_:)`. This does
    /// NOT weaken the confirmation overlay's own invariant: that instance is
    /// still only ever shown via `handle(_:)`, since nothing in this app
    /// calls `showForVideo()` on it. Named distinctly from a bare `show()`
    /// so it is never mistaken for a general-purpose public entry point on
    /// the confirmation-overlay instance.
    func showForVideo() {
        show()
    }

    /// Hides the panel. No-op if the panel was never created or is already
    /// hidden.
    ///
    /// SAFE TO CALL EXTERNALLY (gateopener-9kk.9), unlike `show()`: before
    /// ordering the panel out, this cancels any pending `.succeeded`/
    /// `.failed` hold-then-fade sequence and clears `isResolveFadePending`
    /// (see `cancelPendingResolve()`), and resets `alphaValue` back to 1 so
    /// a later internal `show()` never re-displays a panel stuck mid-fade or
    /// at alpha 0. Without this cleanup, an external `hide()` call made
    /// while a resolve-fade was pending would leave `isResolveFadePending`
    /// stuck `true`, causing `handleIdleOrNeedsSetup()`'s guard to silently
    /// ignore a subsequent `.idle`/`.needsSetup` and permanently strand the
    /// overlay's internal bookkeeping (see gateopener-9kk.9 for the original
    /// hazard writeup). This makes `hide()` a genuinely safe dismiss
    /// primitive — anticipating gateopener-12h's interactive "View door"
    /// panel, which will want a real user-initiated dismiss — while `show()`
    /// stays private; see its doc comment for why that split is not
    /// symmetric.
    func hide() {
        cancelPendingResolve()
        // gateopener-12h.6: an in-flight open-triggered video session must
        // never outlive the panel it is being shown in — an external
        // `hide()` call (or `handleOpenVideoSessionEnded()`'s own internal
        // one, see below) has to stop it, not just leave it running behind
        // an invisible panel. Mirrors `cancelPendingResolve()` immediately
        // above: both are cleanup steps that make this method a genuinely
        // safe, total dismiss primitive regardless of what was in flight.
        teardownOpenVideoSession()
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        (currentContent() as? OverlayShowHideResponding)?.overlayDidHide()
    }

    // MARK: - GateState-driven presentation (gateopener-9kk.5)

    /// How long `.succeeded` holds the overlay on screen (landing the
    /// confirmation) before the fade-out begins. `GateController` auto-resets
    /// to `.idle` `holdDuration + fadeDuration` seconds later at most
    /// (`autoResetDelay` is 3s), so this pair MUST sum to comfortably less
    /// than that or the overlay would still be visible/fading when `.idle`
    /// arrives from the auto-reset rather than from the fast-open path.
    private static let succeededHoldDuration: Duration = .milliseconds(1200)
    private static let fadeDuration: TimeInterval = 0.25

    /// Pending fade-then-hide work (scheduled from `.succeeded`/`.failed`),
    /// held so a later transition can cancel it before it runs — mirrors
    /// `StatusItemController.stillTryingTimer`'s
    /// invalidate-before-reschedule idiom, adapted to `Task` since the work
    /// here is a `Duration`-based hold rather than a single `Timer` fire.
    private var pendingResolveTask: Task<Void, Never>?

    /// `true` exactly while a `.succeeded`/`.failed` hold-then-fade sequence
    /// is scheduled or in progress (from the moment `handle(_:)` schedules it
    /// until the fade completes and the panel is ordered out). Read by the
    /// `.idle`/`.needsSetup` branch to implement reentrancy rule (b) below.
    private var isResolveFadePending = false

    // MARK: - Live video on open (gateopener-12h.6)

    /// The in-flight, open-triggered `DoorVideoSession`, if any. `nil`
    /// whenever no such session is running — including the entire time
    /// before `.opening` first starts one, and again once it ends/fails/is
    /// superseded. See `handleOpening()`/`teardownOpenVideoSession()`.
    ///
    /// THIS CHANGES THE OVERLAY'S LIFETIME FOR THE OPEN PATH, and that is
    /// deliberate — read this whole section before touching any of it.
    /// Historically (bead gateopener-9kk.5/.6) the confirmation overlay's
    /// entire lifetime was `.opening` -> show -> `.succeeded`/`.failed` ->
    /// hold (~1.2s or 0s) -> fade (~0.25s) -> hide, driven purely by
    /// `GateState`. An open completes in ~2s, but live video takes ~4-6s to
    /// its first frame (dominated by the cloud `rtc/offer` round trip, not
    /// reducible) and then runs for the door's full measured ~28-30s
    /// natural session length (gateopener-12h.4) — video arrives and keeps
    /// running long after `GateState` has already reached `.succeeded`/
    /// `.idle`. So: whenever a video session is in flight for the CURRENT
    /// open, `GateState`'s own `.succeeded`/`.failed`/`.idle`/`.needsSetup`
    /// transitions must NOT hide the panel (see the guards added to
    /// `handleResolved(holdDuration:)`/`handleIdleOrNeedsSetup()` below) —
    /// the video's own end signal (`DoorVideoFrameView`'s plateau/
    /// hard-timeout detector, delivered via `onSessionEnded` below) becomes
    /// the sole thing that hides the panel for that open. If video was
    /// never started for this open (setting off, no factory, or `start()`
    /// never reaches `.streaming`/fails outright), none of this applies and
    /// the panel behaves EXACTLY as it always has — video is additive, per
    /// the bead's explicit failure-must-degrade requirement.
    private var openVideoSession: DoorVideoSession?

    /// The frame view currently showing `openVideoSession`'s live feed, if
    /// streaming has actually started. Held so `teardownOpenVideoSession()`
    /// can clear its callbacks (preventing a stale `onSessionEnded`/future
    /// state delivery to a torn-down controller) and so a same-session
    /// re-`setContent` is never attempted from two different call sites.
    private var openVideoFrameView: DoorVideoFrameView?

    /// Downstream observer of `GateState`, shaped like
    /// `NotificationPresenter.handle(_:)`: never called from `openGate()`'s
    /// call chain, only assigned/chained onto `GateController.onStateChange`
    /// (wiring itself is bead gateopener-9kk.6, not this method).
    ///
    /// Gated on `AppSettings.showOpenConfirmationOverlay`, read FRESH on
    /// every call (not cached at init) so toggling the setting in Settings
    /// takes effect immediately without an app relaunch. When the setting is
    /// `false` AND no panel currently exists, this is a total no-op: no
    /// panel is ever created (the guard below returns before touching
    /// `panel`/`resolvePanel()` at all).
    ///
    /// EDGE CASE (bead gateopener-9kk.7): the setting can flip to `false`
    /// WHILE a panel is already on screen — e.g. `.opening` arrived when the
    /// setting was still `true` and showed the panel, the user then
    /// unchecks the Settings toggle, and only THEN does the next state
    /// (`.succeeded`/`.failed`/`.idle`) arrive with the setting now `false`.
    /// A blanket `guard appSettings.showOpenConfirmationOverlay else {
    /// return }` at the very top would return before ever reaching
    /// `handleResolved`/`handleIdleOrNeedsSetup`, permanently stranding the
    /// visible panel on screen — no future state transition would ever be
    /// allowed to hide it. DECISION: the currently-visible panel must be
    /// allowed to finish its natural course (hold, fade, hide) even after
    /// the setting flips off; only the decision to SHOW a NEW panel
    /// (`.opening` → `handleOpening()`) is gated on the live setting value.
    /// So the guard below only blocks `.opening`, and only when no panel
    /// exists yet; `.succeeded`/`.failed`/`.idle`/`.needsSetup` are always
    /// allowed to reach their handlers, which are themselves already no-ops
    /// once there is nothing left to hide (`guard panel != nil`).
    func handle(_ state: GateState) {
        let showOverlay = appSettings.showOpenConfirmationOverlay

        switch state {
        case .opening, .queued:
            // Only block bringing up a brand-new panel. If a panel already
            // exists (e.g. a fast re-open racing a toggle-off — see the
            // edge-case doc above), let it proceed exactly like the setting
            // was never touched; this mirrors reentrancy rule (a) elsewhere
            // in this type, which does not special-case a mid-flight
            // panel's origin.
            //
            // `.queued` (bead .4: `requestOpen()`'s offline queue) is
            // treated identically to `.opening` here — from the overlay's
            // perspective both mean "an open is in progress, show the busy
            // state", regardless of whether the underlying request has
            // physically started yet or is still waiting for connectivity.
            guard showOverlay || panel != nil else { return }
            handleOpening()
        case .succeeded:
            handleResolved(holdDuration: Self.succeededHoldDuration)
        case .failed:
            // No hold: a lingering overlay after a failure would visually
            // imply success. See the `handleResolved(holdDuration:)` doc
            // comment.
            handleResolved(holdDuration: .zero)
        case .idle, .needsSetup:
            handleIdleOrNeedsSetup()
        }
    }

    /// `.opening` → show and (re)start playback from zero.
    ///
    /// Reentrancy rule (a): a second open can commence while the overlay is
    /// still fading out from a previous one (e.g. `.opening` arrives again
    /// before a `.failed`/`.succeeded` fade has finished). Cancel that
    /// pending fade/hide FIRST, then reset `alphaValue` to 1 before calling
    /// `show()` — otherwise `show()` would order front a panel whose alpha
    /// is mid-fade (or already 0), producing a visible glitch or an
    /// invisible-but-technically-onscreen overlay.
    ///
    /// gateopener-f8w.2: EXPLICITLY installs a fresh canned-animation view
    /// via `setContent(_:)` BEFORE `show()`, on every single call — not just
    /// the first. This is the fix for the stale-frame-on-reopen bug (see the
    /// `gateopener-f8w-root-cause-...` bd memory): previously this method
    /// never called `setContent(_:)` at all, so `show()` simply re-fired
    /// `overlayWillShow()` on whatever content happened to still be
    /// installed — the PREVIOUS open's live `DoorVideoFrameView`, still
    /// holding its last decoded frame, on any reopen within the same
    /// process. Calling `setContent(_:)` here makes that structurally
    /// impossible: the panel's content is synchronously replaced with the
    /// canned animation before `show()` ever fires `overlayWillShow()`, so
    /// there is no path left where a previous session's frame can be
    /// re-displayed.
    ///
    /// MUST be a FRESH `GateOpenVideoView` instance every call, not the
    /// cached default content: `setContent(_:)` treats re-setting the SAME
    /// view instance as a no-op (bead gateopener-12h.2) specifically so a
    /// state-driven content swap that happens to reselect the current view
    /// does not spuriously restart it — but that same guard would mean a
    /// second `.opening` reusing the one shared default instance would
    /// SILENTLY NOT restart playback, showing only the first open's held
    /// final frame forever after. Building a new `GateOpenVideoView` (via
    /// `makeCannedAnimationContent()`) for every open sidesteps the no-op
    /// guard by construction — the incoming view is never `===` the
    /// outgoing one — so `overlayWillShow()` reliably fires and
    /// `GateOpenVideoView.overlayWillShow()` reliably seeks to `.zero` and
    /// calls `play()`. `show()` then delivers that same `overlayWillShow()`
    /// hook once more (harmless: it is the identical view `setContent(_:)`
    /// just installed, so `show()`'s own call is the only firing — see
    /// `setContent(_:)`'s doc comment on the panel-not-yet-visible case,
    /// which applies here since the panel may not be visible yet on a fresh
    /// `.opening`).
    ///
    /// Falls back to the plain HUD placeholder when the bundled clip is
    /// unavailable (unbundled process), exactly like the original default
    /// content — see `makeCannedAnimationContent()`.
    ///
    /// gateopener-ufk: when a previous open's video session is still
    /// `.connecting`/`.streaming`, this open is a RETAINED repeat, not a
    /// fresh one — see `DoorVideoSessionRetention` in `GateOpenerCore`. In
    /// that case the canned animation must NOT be re-installed: if the
    /// session is already `.streaming`, the frame view is the installed
    /// content and swapping back to the canned animation would yank the
    /// live video off screen for no reason; if it is still `.connecting`,
    /// the canned animation is already showing, so re-setting it would just
    /// restart its playback pointlessly. The retention decision is computed
    /// ONCE here (before `startOpenVideoSessionIfEnabled` can change
    /// `openVideoSession`'s state) and threaded through so the two call
    /// sites can never disagree. `cancelPendingResolve()`, the alpha reset,
    /// and `show()` still run unconditionally on every opening — they are
    /// idempotent and are what keep the panel visible for this open too.
    private func handleOpening() {
        cancelPendingResolve()
        panel?.alphaValue = 1
        let decision = DoorVideoSessionRetention.decision(forExistingPhase: openVideoSession?.state.phase)
        if decision == .replace {
            setContent(Self.makeCannedAnimationContent())
        }
        show()
        startOpenVideoSessionIfEnabled(decision: decision)
    }

    /// Starts a fresh live-video session for THIS open, in parallel with the
    /// canned animation `handleOpening()` just showed — see the
    /// `openVideoSession` doc comment above for why the two run
    /// side by side rather than one replacing the other.
    ///
    /// Reentrancy / retention (gateopener-ufk): `decision` is computed ONCE
    /// by the caller (`handleOpening()`) from `openVideoSession?.state
    /// .phase`, via `DoorVideoSessionRetention.decision(forExistingPhase:)`
    /// in `GateOpenerCore`, and passed in here rather than recomputed —
    /// recomputing after `handleOpening()` may already have changed the
    /// panel's content would risk the two call sites disagreeing.
    ///  - `.retain` (existing session is `.connecting` or `.streaming`):
    ///    this open is a repeat arriving mid-warm-up or mid-stream. Log at
    ///    notice level and RETURN immediately — no teardown, no new
    ///    session, no new `DoorVideoFrameView`, and `onStateChange`/
    ///    `onSessionEnded` are left pointing at the existing session, so the
    ///    in-flight warm-up (or live stream) is completely undisturbed.
    ///  - `.replace` (no existing session, or it is `.idle`/`.ended`/
    ///    `.failed`): existing behaviour — tear down whatever is there
    ///    (a no-op if nothing is) and start fresh. The "replacing it" log
    ///    line fires only when there actually was a previous session to
    ///    replace.
    ///
    /// No-ops (canned-animation-only, today's exact behavior) when either
    /// `autoShowDoorVideoOnOpen` is off or no `makeDoorVideoSession` factory
    /// was injected (mock mode / a caller that opted out) — see those
    /// properties' doc comments.
    private func startOpenVideoSessionIfEnabled(decision: DoorVideoSessionRetention) {
        if decision == .retain {
            let phaseDescription = openVideoSession.map { String(describing: $0.state.phase) } ?? "nil"
            Self.logger.notice("a new open arrived while this open's video session is \(phaseDescription, privacy: .public); retaining it")
            return
        }

        if openVideoSession != nil {
            Self.logger.notice("a new open arrived while a previous open's video session was still in flight; replacing it")
        }
        teardownOpenVideoSession()

        guard appSettings.autoShowDoorVideoOnOpen, let makeDoorVideoSession else { return }
        guard let session = makeDoorVideoSession() else { return }

        openVideoSession = session

        let frameView = DoorVideoFrameView(
            session: session,
            frame: NSRect(origin: .zero, size: Self.panelSize)
        )
        // Session-end detection (plateau/hard-timeout — see
        // `DoorVideoFrameView`'s own doc comment) is the SOLE trigger that
        // hides the panel for this open; GateState's own `.succeeded`/
        // `.failed`/`.idle` transitions are deliberately blocked from doing
        // so while `openVideoSession != nil` (see `handleResolved(
        // holdDuration:)`/`handleIdleOrNeedsSetup()` below).
        frameView.onSessionEnded = { [weak self] in
            self?.handleOpenVideoSessionEnded()
        }
        openVideoFrameView = frameView

        session.onStateChange = { [weak self] state in
            self?.handleOpenVideoState(state)
        }

        Task {
            await session.start()
        }
    }

    /// `DoorVideoSession.onStateChange` handler for the open-triggered
    /// session. Mirrors `DoorVideoOverlayController.handle(_:)`'s shape but
    /// is deliberately much narrower: `.idle`/`.connecting` do nothing (the
    /// canned animation is already covering that gap — see the
    /// `openVideoSession` doc comment above), `.streaming` swaps the panel's
    /// content to the live feed, and `.ended`/`.failed` tear the video down
    /// WITHOUT hiding the panel via the video path — `.failed` in
    /// particular must leave the canned animation's own already-scheduled
    /// (or already-elapsed) hold-then-fade in full control, exactly as if
    /// video had never been attempted (failure-must-degrade requirement).
    /// `.ended` DOES still need to hide the panel — that happens via
    /// `handleOpenVideoSessionEnded()` below, not from this switch directly,
    /// since `DoorVideoFrameView`'s plateau detector (not
    /// `DoorVideoSession.state` reaching `.ended`, which per
    /// `DoorVideoSession`'s own doc comment never fires on its own) is the
    /// primary end-of-session signal per the bead's explicit instruction.
    private func handleOpenVideoState(_ state: DoorVideoSessionState) {
        switch state {
        case .idle, .connecting:
            break
        case .streaming:
            guard let openVideoFrameView, openVideoSession != nil else { return }
            setContent(openVideoFrameView)
        case .ended:
            handleOpenVideoSessionEnded()
        case .failed:
            // Additive-only: swallow the failure and leave the canned
            // animation's own GateState-driven hold-then-fade as the only
            // thing controlling the panel from here — see this method's
            // doc comment.
            teardownOpenVideoSession()
        }
    }

    /// Invoked from `DoorVideoFrameView.onSessionEnded` (plateau/hard-
    /// timeout — the PRIMARY end-of-session signal per the bead) or from
    /// `DoorVideoSession` reaching `.ended` on its own. Tears down the video
    /// session and, since the video session ending is what the user's open
    /// is now waiting on (GateState itself resolved long ago), hides the
    /// panel directly here rather than waiting for another GateState
    /// transition that may never arrive.
    ///
    /// Idempotent: guards `openVideoSession != nil` itself, and `hide()`
    /// below also unconditionally calls `teardownOpenVideoSession()` (see
    /// that method's doc comment) — so a second call for the same session
    /// (e.g. both `DoorVideoFrameView`'s hard timeout AND a late
    /// `DoorVideoSession.ended` firing) is a harmless no-op either way.
    private func handleOpenVideoSessionEnded() {
        guard openVideoSession != nil else { return }
        panel?.alphaValue = 1
        hide()
    }

    /// Stops and releases the current open-triggered video session, if any.
    /// Safe to call when nothing is in flight (no-op). Clears both
    /// `onStateChange` and `onSessionEnded` on the outgoing session/view
    /// BEFORE releasing them, so a straggling async callback from a
    /// just-superseded or just-stopped session can never reach this
    /// controller again (e.g. reentering `handleOpenVideoSessionEnded()`
    /// for a session this method itself is in the middle of discarding).
    ///
    /// Does NOT touch the panel's visibility/content — callers decide that
    /// separately (`startOpenVideoSessionIfEnabled()` replaces content via
    /// a fresh session's own `.streaming` transition; `handleOpenVideoState
    /// (_:)`'s `.failed` branch deliberately leaves the canned animation's
    /// content in place; `handleOpenVideoSessionEnded()` hides the panel
    /// itself, after calling this).
    private func teardownOpenVideoSession() {
        guard let session = openVideoSession else { return }
        session.onStateChange = nil
        openVideoFrameView?.onSessionEnded = nil
        session.stop()
        openVideoSession = nil
        openVideoFrameView = nil
    }

    /// `.succeeded` and `.failed` share this shape structurally (hold for
    /// `holdDuration`, then fade), differing only in what `holdDuration` the
    /// caller passes: `.succeeded` holds ~1.2s to land the confirmation
    /// before fading (`Self.succeededHoldDuration`); `.failed` passes
    /// `.zero` so it fades immediately — a lingering overlay after a failure
    /// would visually imply success, and the actual failure messaging is
    /// `NotificationPresenter`'s job, not this type's.
    private func handleResolved(holdDuration: Duration) {
        // Any prior pending resolve (e.g. a stale `.failed` fade from a
        // previous attempt that never got cancelled) must not race this new
        // one; cancel-before-reschedule, same idiom as (a) above and as
        // `StatusItemController.scheduleStillTryingCheck()`.
        cancelPendingResolve()
        guard panel != nil else { return }

        // gateopener-12h.6: a video session in flight for THIS open owns
        // the panel's fate from here — see the `openVideoSession` doc
        // comment above. Scheduling the normal hold-then-fade here would
        // hide the panel out from under live video that has not even
        // started streaming yet (or has, and is nowhere near its ~28-30s
        // natural end). `isResolveFadePending` is deliberately left
        // `false` in this branch: that flag exists to stop `.idle`/
        // `.needsSetup` from truncating a hold-then-fade THIS method
        // scheduled, and no such sequence is scheduled here, so leaving it
        // `false` is correct, not an oversight — `handleIdleOrNeedsSetup()`
        // has its own, separate `openVideoSession != nil` guard for this
        // same case.
        guard openVideoSession == nil else { return }

        isResolveFadePending = true
        pendingResolveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: holdDuration)
            } catch {
                // Cancelled (superseded by a newer transition, e.g. a fast
                // re-open via handleOpening()'s cancelPendingResolve()) —
                // that newer transition already owns the panel's fate, so
                // this stale sequence must do nothing further.
                return
            }
            await self?.fadeOutThenHide()
        }
    }

    /// `.idle`/`.needsSetup` → hide immediately, UNLESS a `.succeeded`/
    /// `.failed` hold-then-fade is already pending.
    ///
    /// Reentrancy rule (b), implemented exactly as specified: a fast
    /// `.opening -> .succeeded -> .idle` sequence (GateController's
    /// auto-reset, or a quick subsequent state read) must not truncate the
    /// hold-then-fade that `.succeeded` just scheduled — so if
    /// `isResolveFadePending` is true, this is a no-op; the scheduled fade
    /// (from `handleResolved()`) is solely responsible for eventually
    /// hiding the panel. If NO fade is pending (e.g. `.idle` arrives with no
    /// preceding `.succeeded`/`.failed` at all, or after a previous fade has
    /// already completed), `.idle` is not ignored indefinitely: it forces an
    /// immediate hide so the overlay never outlives the state machine.
    private func handleIdleOrNeedsSetup() {
        guard !isResolveFadePending else { return }
        // gateopener-12h.6: same rationale as the guard in
        // `handleResolved(holdDuration:)` above — while a video session is
        // in flight for the current open, only that session's own end
        // signal (`handleOpenVideoSessionEnded()`) may hide the panel.
        // `GateState` typically reaches `.idle` (via `GateController`'s
        // auto-reset) well before the ~28-30s video session is anywhere
        // near over; hiding here would cut the live feed off almost as
        // soon as it started.
        guard openVideoSession == nil else { return }
        guard panel != nil else { return }
        panel?.alphaValue = 1
        hide()
    }

    /// Animates `alphaValue` to 0 over `fadeDuration`, then orders the panel
    /// out and resets `alphaValue` back to 1.
    ///
    /// The alpha reset back to 1 happens HERE, immediately after
    /// `orderOut(nil)` and before this method returns — i.e. it is in place
    /// before any subsequent `show()` can possibly run, since `show()` is
    /// only ever invoked from `handleOpening()` on the main actor, and this
    /// whole method runs on the main actor too. A panel left at alpha 0 and
    /// then ordered front by a later `show()` would be an invisible overlay;
    /// this is the fix for that failure mode.
    ///
    /// Guards against a second reentrancy-(a) case: `handleOpening()` can
    /// call `cancelPendingResolve()` (which marks `pendingResolveTask`
    /// cancelled) WHILE this method's animation await is already in flight —
    /// `Task` cancellation cannot interrupt the running
    /// `NSAnimationContext` block itself. Without the `Task.isCancelled`
    /// check below, this method would run `hide()` + reset alpha AFTER
    /// `handleOpening()` has already reset alpha and called `show()`,
    /// clobbering the fresh show with a hide. Checking `Task.isCancelled`
    /// immediately after the animation completes and bailing out (doing
    /// NEITHER `hide()` nor the alpha reset) leaves the panel exactly as the
    /// superseding `handleOpening()` call left it.
    private func fadeOutThenHide() async {
        guard let panel else {
            isResolveFadePending = false
            return
        }

        // Reduce Motion (bead gateopener-9kk.7): read FRESH here, not
        // cached at init, for the same reason `GateOpenVideoView
        // .overlayWillShow()` does — a user who flips the system setting
        // mid-run must see the new behavior on the very next resolve, no
        // relaunch required. When on, skip the animated alpha fade
        // entirely and go straight to a plain `orderOut` (via `hide()`
        // below): `NSAnimationContext`'s alpha animation IS the motion this
        // accessibility setting exists to suppress. The overlay itself
        // still appears (per `GateOpenVideoView`'s Reduce Motion path) and
        // still disappears at the same hold-duration-driven moment — only
        // the fade transition itself is skipped.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            await withCheckedContinuation { continuation in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.fadeDuration
                    panel.animator().alphaValue = 0
                } completionHandler: {
                    continuation.resume()
                }
            }

            guard !Task.isCancelled else {
                // Superseded mid-animation by a new .opening — see doc
                // comment above. The superseding call already owns
                // alpha/visibility.
                return
            }
        }

        hide()
        // These three now DUPLICATE what hide() itself does (it calls
        // cancelPendingResolve() and resets alpha, so external callers
        // can't strand this state — see hide()'s doc comment). Kept as
        // belt-and-braces: every write sets the identical value, so they
        // are idempotent, and keeping them makes this method correct on
        // its own terms rather than dependent on hide()'s internals.
        //
        // LOAD-BEARING ORDERING, do not "tidy" this: hide() cancels
        // pendingResolveTask — which is THIS task, still executing. That
        // is harmless only because the single `Task.isCancelled` check
        // above runs BEFORE this point and nothing after it reads
        // cancellation state. Adding another isCancelled check below
        // hide() would silently reintroduce the stranding bug, and no
        // test currently covers it (see gateopener-9kk.11).
        panel.alphaValue = 1
        isResolveFadePending = false
        pendingResolveTask = nil
    }

    private func cancelPendingResolve() {
        pendingResolveTask?.cancel()
        pendingResolveTask = nil
        isResolveFadePending = false
    }

    // MARK: - Private

    private func resolvePanel() -> OverlayPanel {
        if let panel { return panel }

        let created = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        // isFloatingPanel — keeps the panel above normal windows without
        // requiring it to be key or main. Without this a borderless panel
        // can still get buried behind ordinary document windows.
        created.isFloatingPanel = true

        // .statusBar level — sits above regular app windows (and roughly
        // level with menu-bar-adjacent UI). Without this the overlay could
        // appear behind the very app the user is looking at.
        created.level = .statusBar

        // Transparent, non-opaque, with a shadow — lets the placeholder's
        // rounded corners show real (non-rectangular) window edges. Without
        // isOpaque = false + backgroundColor = .clear, AppKit paints an
        // opaque rectangular backing behind the content, producing a
        // visible square around the rounded HUD. hasShadow = true keeps a
        // normal drop shadow despite the transparent background.
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = true

        // hidesOnDeactivate = false — without this, AppKit would hide the
        // panel the instant the app is no longer frontmost, which is
        // guaranteed to happen almost immediately since this panel never
        // takes focus in the first place.
        created.hidesOnDeactivate = false

        // collectionBehavior — .canJoinAllSpaces + .fullScreenAuxiliary so
        // the overlay can appear regardless of which Space or full-screen
        // app is active (the hotkey can fire from anywhere); .stationary so
        // the panel does not slide around during Space-switch animations.
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // ignoresMouseEvents — see the property doc above; defaults to
        // true so a click over the overlay's frame passes through to
        // whatever is underneath, since the confirmation overlay is pure
        // decoration.
        created.ignoresMouseEvents = ignoresMouseEvents

        let contentView = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        // LOAD-BEARING: the panel is borderless, non-opaque and clear-backed,
        // and its content (GateOpenVideoView) draws entirely through an
        // AVPlayerLayer. Without a layer-backed content view there is no
        // layer tree for that AVPlayerLayer to composite into, so the panel
        // appears on screen — isVisible true, alpha 1 — while rendering
        // nothing at all. That is exactly the "the panel shows but I never
        // see the video" bug (gateopener-9kk.12): every check confirmed the
        // panel and none confirmed the pixels.
        contentView.wantsLayer = true
        // Accessibility (bead gateopener-9kk.7): this panel is pure,
        // non-interactive decoration — it duplicates information already
        // available from the menu-bar icon and its tooltip, never accepts
        // clicks (see `ignoresMouseEvents` above), and can never become key/
        // main (see `OverlayPanel.canBecomeKey`/`canBecomeMain` below), so
        // it is already unreachable by keyboard. Marking the content view
        // `isAccessibilityElement(false)` additionally keeps VoiceOver from
        // announcing/focusing it at all, rather than presenting a
        // focusable-but-inert element that duplicates the menu-bar icon's
        // own accessible description.
        contentView.setAccessibilityElement(false)
        created.contentView = contentView

        let installedContent = pendingContent ?? Self.makeCannedAnimationContent()
        created.installContent(installedContent)

        panel = created
        return created
    }

    private func position(_ panel: NSPanel, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = Self.panelSize
        let origin = NSPoint(
            x: visible.maxX - size.width - Self.edgeInset,
            y: visible.maxY - size.height - Self.edgeInset
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// Builds a FRESH canned gate-open animation view (see
    /// `GateOpenVideoView`) — a brand-new `GateOpenVideoView`/`AVPlayer`
    /// instance every call, never a shared/cached one. Falls back to the
    /// plain HUD placeholder when the video asset cannot be located — see
    /// `GateOpenVideoView.makeIfAvailable()` for why that happens (chiefly:
    /// an unbundled process, where `Bundle.main` has no `Resources`
    /// directory at all) and why it must never crash.
    ///
    /// Used both as the panel's initial default content (`resolvePanel()`)
    /// and — critically — by `handleOpening()` on EVERY `.opening`, per-open,
    /// specifically so each open gets its own view instance rather than
    /// reusing a previous open's (see `handleOpening()`'s doc comment for why
    /// instance-freshness, not just view-type, is load-bearing here:
    /// `setContent(_:)`'s same-view no-op guard would otherwise silently
    /// suppress the restart-from-zero on any reopen).
    private static func makeCannedAnimationContent() -> NSView {
        GateOpenVideoView.makeIfAvailable(size: panelSize) ?? makePlaceholderContent()
    }

    /// Placeholder content: a rounded, semi-transparent dark HUD backing
    /// with no live data. Used both as this bead's degrade path (see
    /// `makeCannedAnimationContent()`) and available to any future feature via
    /// `setContent(_:)` — see that method's doc comment.
    private static func makePlaceholderContent() -> NSView {
        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        return effectView
    }
}

/// `NSPanel` subclass that unconditionally refuses key/main status.
///
/// A panel with `.nonactivatingPanel` in its style mask is documented to
/// avoid activating the app when ordered front, but empirically it can
/// still become key in some configurations (e.g. certain mouse-down
/// sequences over its content). Overriding `canBecomeKey`/`canBecomeMain`
/// to unconditionally return `false` removes that ambiguity entirely: this
/// window is now structurally incapable of taking focus, regardless of how
/// it is ordered front or clicked.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool {
        OverlayWindowController.logKeyMainQuery(kind: "canBecomeKey", result: false)
        return false
    }

    override var canBecomeMain: Bool {
        OverlayWindowController.logKeyMainQuery(kind: "canBecomeMain", result: false)
        return false
    }

    /// Removes any previously-installed content subview and installs
    /// `view`, resizing it to fill the panel's content view. Kept on the
    /// panel (rather than the controller) since it is purely a window-layout
    /// concern.
    func installContent(_ view: NSView) {
        guard let host = contentView else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        currentContentView = view
    }

    /// Tracks whatever view was most recently installed via
    /// `installContent(_:)`, so `OverlayWindowController.show()`/`hide()`
    /// can look it up (via `currentContent()`) to deliver
    /// `OverlayShowHideResponding` lifecycle hooks without keeping their own
    /// separate reference.
    private(set) var currentContentView: NSView?
}

/// Optional lifecycle hook for content installed via
/// `OverlayWindowController.setContent(_:)`. See that method's doc comment
/// for the swappability seam this protocol participates in.
///
/// Content that does not need to know about `show()`/`hide()` (e.g. a
/// static placeholder) simply does not conform; the controller only invokes
/// these methods when the currently-installed content does.
@MainActor
protocol OverlayShowHideResponding: AnyObject {
    /// Called from `OverlayWindowController.show()`, after the panel has
    /// been ordered front, every time `show()` runs (not just the first
    /// time the panel is created).
    func overlayWillShow()

    /// Called from `OverlayWindowController.hide()`, after the panel has
    /// been ordered out.
    func overlayDidHide()
}

extension OverlayWindowController {
    /// Logs every `canBecomeKey`/`canBecomeMain` query so runtime behavior
    /// (not just code inspection) can be confirmed: both must always log
    /// `false`. Internal logging hook only — not part of the public API.
    fileprivate static func logKeyMainQuery(kind: String, result: Bool) {
        logger.debug("\(kind, privacy: .public) queried, returning \(result, privacy: .public)")
    }
}
