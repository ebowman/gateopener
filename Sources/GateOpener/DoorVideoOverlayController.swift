import AppKit
import GateOpenerCore
import os

/// Drives the "View door" feature end to end: owns exactly one
/// `DoorVideoSession` at a time, presents it in its OWN `OverlayWindowController`
/// panel (deliberately separate from the gate-open confirmation overlay —
/// see below), and tears everything down when the session ends, fails, or
/// the user dismisses it.
///
/// ## Why a SEPARATE `OverlayWindowController` from the confirmation overlay
///
/// The confirmation overlay (`AppDelegate.overlayWindowController`) is
/// driven purely by `GateState` via `handle(_:)` and MUST keep
/// `ignoresMouseEvents == true` — it is pure decoration a click must pass
/// through. The View-door panel needs the opposite: `ignoresMouseEvents ==
/// false` so a click dismisses it (per the bead's requirement and the
/// `overlay-focus-beats-closeability` ruling: closeability is a nice-to-have
/// that must never cost the focus guarantee, but a plain
/// `ignoresMouseEvents = false` panel that still never becomes key satisfies
/// both — see `OverlayWindowController`'s own doc comment on that
/// parameter). Reusing the SAME panel instance for both features would mean
/// either the confirmation overlay starts accepting clicks it must not, or
/// the video panel stays click-through and cannot be dismissed — so this
/// type owns its own `OverlayWindowController`, constructed once with
/// `ignoresMouseEvents: false`.
///
/// ## Lifecycle this type does NOT do
///
/// No renegotiation, no reconnect, no stale-frame watchdog beyond what
/// `DoorVideoFrameView` already implements — see that type and
/// `DoorVideoSession`'s own doc comments. `start()` is called AT MOST ONCE
/// per `DoorVideoSession` instance; a fresh "View door" selection always
/// gets a fresh `DoorVideoSession` (this controller never reuses one).
@MainActor
final class DoorVideoOverlayController {
    private static let logger = Logger(subsystem: "com.gateopener", category: "door-video-overlay")

    private let overlay: OverlayWindowController
    private let makeSession: () -> DoorVideoSession?

    /// Current session, if a "View door" flow is in flight. `nil` when
    /// idle. Guards against a second "View door" selection stacking a
    /// second session on top of an existing one — see `start()`.
    private var currentSession: DoorVideoSession?
    private var currentFrameView: DoorVideoFrameView?

    /// - Parameters:
    ///   - appSettings: forwarded to the dedicated `OverlayWindowController`
    ///     this type constructs. `handle(_:)` (the `GateState`-driven path)
    ///     is intentionally never called on that controller — this type
    ///     drives it directly via `presentConnecting()`/`presentFrameView()`
    ///     /`dismiss()` instead, so the confirmation overlay's
    ///     `showOpenConfirmationOverlay` setting has no bearing on this
    ///     feature.
    ///   - makeSession: factory for a fresh `DoorVideoSession`, injected
    ///     rather than constructed internally because building one requires
    ///     the concrete `TokenManager`/`GateClient` instances that only
    ///     exist in the app's real (non-mock) dependency graph — see
    ///     `AppDelegate.makeGateController`. Returns `nil` when video is
    ///     unavailable (mock mode, or any other reason the caller decides
    ///     not to offer it), in which case `start()` reports a failure
    ///     message and never presents a panel.
    init(appSettings: AppSettings, makeSession: @escaping () -> DoorVideoSession?) {
        self.overlay = OverlayWindowController(appSettings: appSettings, ignoresMouseEvents: false)
        self.makeSession = makeSession
    }

    /// Entry point for the "View door" menu item.
    ///
    /// gateopener-ufk.3: retain-or-replace policy for a repeat "View door"
    /// selection, mirroring `OverlayWindowController.handleOpening()`'s
    /// handling of the same rule for the gate-open path. The decision is
    /// computed once from `currentSession?.state.phase` via
    /// `DoorVideoSessionRetention.decision(forExistingPhase:)`:
    ///  - `.retain` (existing session is `.connecting` or `.streaming`):
    ///    this selection arrived mid-warm-up or mid-stream. Log at notice
    ///    level and RETURN immediately — no teardown, no new session, and
    ///    the overlay is left exactly as-is (no `hide()`/`show()`/
    ///    `setContent`), so the in-flight warm-up (or live stream) is
    ///    completely undisturbed.
    ///  - `.replace` (no existing session, or it is `.idle`/`.ended`/
    ///    `.failed`): existing behaviour — tear down whatever is there (a
    ///    no-op if nothing is) and start fresh. The "replacing it" log line
    ///    fires only when there actually was a previous session to replace.
    func start() {
        let decision = DoorVideoSessionRetention.decision(forExistingPhase: currentSession?.state.phase)
        if decision == .retain {
            let phaseDescription = currentSession.map { String(describing: $0.state.phase) } ?? "nil"
            Self.logger.notice("View door selected while a session is \(phaseDescription, privacy: .public); retaining it")
            return
        }

        if currentSession != nil {
            Self.logger.notice("View door selected while a session was already in flight; replacing it")
            teardown()
        }

        guard let session = makeSession() else {
            presentFailure(message: "Door camera unavailable")
            return
        }

        currentSession = session

        let frameView = DoorVideoFrameView(
            session: session,
            frame: NSRect(origin: .zero, size: OverlayWindowController.panelSize)
        )
        frameView.onSessionEnded = { [weak self] in
            self?.handleSessionEnded()
        }
        frameView.onClickToDismiss = { [weak self] in
            self?.dismiss()
        }
        currentFrameView = frameView

        session.onStateChange = { [weak self] state in
            self?.handle(state)
        }

        presentConnecting()

        Task {
            await session.start()
        }
    }

    /// Externally-safe dismiss (mirrors `OverlayWindowController.hide()`,
    /// which is documented safe to call at any time as of gateopener-9kk.9):
    /// tears down the in-flight session (if any) and hides the panel. Wired
    /// as the click-to-dismiss target for every view this controller
    /// presents (`DoorVideoConnectingView`/`DoorVideoFrameView`'s
    /// `onClickToDismiss`), and available to any future dismiss affordance
    /// (e.g. a menu toggle) as the single, safe entry point.
    func dismiss() {
        teardown()
    }

    // MARK: - DoorVideoSessionState handling

    private func handle(_ state: DoorVideoSessionState) {
        switch state {
        case .idle, .connecting:
            // .connecting is already reflected by presentConnecting() at
            // start(); nothing further to do here.
            break
        case .streaming:
            presentFrameView()
        case .ended(let reason):
            Self.logger.notice("door video session ended: \(reason, privacy: .public)")
            handleSessionEnded()
        case .failed(let message):
            Self.logger.notice("door video session failed: \(message, privacy: .public)")
            presentFailure(message: message)
        }
    }

    /// Called either from `DoorVideoSession`'s own `.ended` state or from
    /// `DoorVideoFrameView`'s plateau/hard-timeout detector — whichever
    /// fires first. Idempotent: `teardown()` is safe to call more than once
    /// (mirrors `DoorVideoSession.stop()`'s own idempotency), and
    /// `currentSession == nil` after the first call makes any second call
    /// here a no-op via `teardown()`'s own guard.
    private func handleSessionEnded() {
        teardown()
    }

    // MARK: - Presentation

    private func presentConnecting() {
        let connecting = DoorVideoConnectingView(size: OverlayWindowController.panelSize)
        connecting.onClickToDismiss = { [weak self] in
            self?.dismiss()
        }
        overlay.setContent(connecting)
        overlay.showForVideo()
    }

    private func presentFrameView() {
        guard let currentFrameView else { return }
        overlay.setContent(currentFrameView)
        overlay.showForVideo()
    }

    /// Shows a brief human-readable failure message, then disappears —
    /// never strands the panel (bead requirement). The message is shown via
    /// the SAME connecting-style placeholder view rather than a distinct
    /// view class, just with different text.
    private func presentFailure(message: String) {
        let failureView = DoorVideoConnectingView(size: OverlayWindowController.panelSize, text: message)
        failureView.onClickToDismiss = { [weak self] in
            self?.dismiss()
        }
        overlay.setContent(failureView)
        overlay.showForVideo()

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.teardown()
        }
    }

    private func teardown() {
        currentSession?.stop()
        currentSession = nil
        currentFrameView = nil
        overlay.hide()
    }
}
