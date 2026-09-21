import SwiftUI
import GateOpenerCore
import UIKit

/// The app's real main screen (bead gateopener-672.9): the screen the app
/// launches straight into once configured (see `RootView`). It exists to
/// be tapped once while distracted — no confirmations, no waiting on
/// Comelit on the tap path.
///
/// Tapping the button calls `observable.requestOpen()`, which is
/// non-blocking (`GateController.requestOpen()` via
/// `BackgroundOpenRunner`) and returns immediately; every visual change
/// afterwards (button color/label, status line, haptics, idle-timer) is
/// driven purely by observing `observable.state`, never by awaiting
/// anything on the tap path itself.
struct MainView: View {
    var environment: AppEnvironment
    var observable: GateControllerObservable

    /// `GateController.appSettings` is `private` (see that file's field),
    /// so the display name is read directly from `AppSettings` rather than
    /// through `observable.controller`. Passed in by `RootView` from the
    /// same `AppEnvironment.appSettings` instance the controller itself
    /// reads from, so it always reflects the actually-selected gate.
    let appSettings: AppSettings

    /// Owns the live door-camera video panel (bead gateopener-672.12).
    /// Constructed once by `GateOpenerIOSApp` (not by this view) so its
    /// session survives `MainView` being recreated by SwiftUI, and so
    /// `GateOpenerIOSApp`'s `scenePhase == .background` handler can call
    /// `dismiss()` on the SAME instance this view observes.
    var doorVideoCoordinator: DoorVideoCoordinator

    @State private var settingsPresented = false

    /// Prepared on appear (`prepare()` primes the Taptic Engine so the
    /// first real haptic on this screen fires with minimal latency), used
    /// on every tap/state change thereafter.
    @State private var impactGenerator = UIImpactFeedbackGenerator(style: .heavy)
    @State private var lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    @State private var notificationGenerator = UINotificationFeedbackGenerator()

    #if DEBUG
    /// Debug-only, `--auto-open-after <seconds>` verification hook (bead
    /// gateopener-672.9's DONE criteria): lets a screenshot script capture
    /// `.opening`/`.succeeded`/`.failed` without UI automation. See
    /// `DebugLaunchOptions`.
    @State private var didScheduleDebugAutoOpen = false

    /// Debug-only, `--auto-pin-after <seconds>` verification hook (bead
    /// gateopener-41m.15 STEP 9): the pin button needs a real tap, which
    /// `simctl launch` cannot perform, so this schedules a single
    /// `doorVideoCoordinator.setPinned(true)` call instead. See
    /// `DebugLaunchOptions.autoPinAfterSeconds`.
    @State private var didScheduleDebugAutoPin = false
    #endif

    private var gateDisplayName: String {
        appSettings.selectedEndpointName ?? "your gate"
    }

    /// The primary (verb) line of the Open button's label, one per
    /// `GateState` case (bead gateopener-41m.10 STEP 2). A pure `static
    /// func`, independent of `self`, so it can be unit-tested directly
    /// without constructing a `MainView`.
    ///
    /// MUTATION CHECK: swapping any two branches' return values, or
    /// collapsing two cases onto the same string, would silently pass any
    /// test that doesn't cover both cases with distinct expectations — the
    /// tests in `OpenGateButtonLabelTests` cover every case with a distinct
    /// literal precisely to catch that.
    static func primaryLabel(for state: GateState) -> String {
        switch state {
        case .needsSetup, .idle:
            return "Open Gate"
        case .queued:
            return "Waiting for network…"
        case .opening:
            return "Opening…"
        case .succeeded:
            return "Opened"
        case .failed:
            return "Try Again"
        }
    }

    /// Pure combination of the two independent reasons the screen should
    /// stay awake (bead gateopener-41m.15 STEP 5): the pre-existing open-flow
    /// behavior (tap-to-open through queued/opening, restored once
    /// succeeded/failed/idle — computed by the caller and passed in as
    /// `openFlowNeedsAwake`) OR the video being pinned. A `static func`,
    /// independent of `self`, so it can be unit-tested directly.
    ///
    /// Applied from THREE places, all of which must agree on this single
    /// combined value rather than fighting each other by separately toggling
    /// `UIApplication.shared.isIdleTimerDisabled`: `handleTap()`,
    /// `handleStateChangeForHapticsAndIdleTimer(_:)`, and an
    /// `.onChange(of: doorVideoCoordinator.isPinned)` in `body`.
    ///
    /// MUTATION CHECK: changing `||` to `&&` would require BOTH conditions
    /// at once to keep the screen awake (e.g. a pinned session while idle
    /// would incorrectly let the screen sleep) — `MainViewKeepScreenAwakeTests`
    /// covers every combination with a distinct expectation.
    static func shouldKeepScreenAwake(isPinned: Bool, openFlowNeedsAwake: Bool) -> Bool {
        isPinned || openFlowNeedsAwake
    }

    private var statusText: String {
        switch observable.state {
        case .needsSetup:
            // Unreachable here: `RootView` swaps to `SignInView` before
            // this view is ever shown in that state. A placeholder status
            // text is still provided so `accessibilityValue` is never
            // empty if this is somehow reached transiently.
            return "Needs setup"
        case .idle:
            return "Ready"
        case .queued:
            return "Waiting for network…"
        case .opening:
            return "Opening…"
        case .succeeded(let at):
            return "Opened \(Self.timeFormatter.string(from: at))"
        case .failed(let message):
            return message
        }
    }

    private var accentColor: Color {
        switch observable.state {
        case .needsSetup, .idle:
            return .accentColor
        case .queued:
            return .orange
        case .opening:
            return .accentColor
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            Text(appSettings.selectedEndpointName ?? "GateOpener")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            // MARK: - Permanent video slot (bead gateopener-41m.11)
            //
            // Unlike the panel this replaces, the slot is ALWAYS present
            // (never conditionally inserted/removed from the layout) so the
            // screen always explains what's going on with the door camera,
            // rather than a panel that silently appears and vanishes. Its
            // CONTENT switches between the live web view, a connecting/
            // busy-retry overlay, and one of two placeholders — see
            // `videoSlot`. `layoutPriority(-1)` (lower than the status
            // text/Open button's default 0) is what lets it shrink first on
            // short screens per this bead's STEP 5 — the aspect-ratio frame
            // below caps its growth, but on a screen too short to fit both
            // at full size, SwiftUI takes space from the lowest-priority
            // view first, which must be this one, never the button.
            videoSlot
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .layoutPriority(-1)

            Spacer(minLength: 24)

            // MARK: - Bottom control cluster (bead gateopener-41m.10 STEP 3)
            //
            // The Open button is anchored to the bottom safe area (16pt
            // spacing) rather than centered/floating, so it sits in the
            // screen's most thumb-reachable zone regardless of how much
            // space the video slot above claims.
            VStack(spacing: 16) {
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true) // surfaced via the button's accessibilityValue instead

                openButton
                    .padding(.horizontal, 20)
            }
            .padding(.bottom, 24)
            .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeInOut(duration: 0.25), value: doorVideoCoordinator.isPanelVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    settingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $settingsPresented) {
            SettingsView(environment: environment, observable: observable, appSettings: appSettings)
        }
        .onAppear {
            impactGenerator.prepare()
            lightImpactGenerator.prepare()
            notificationGenerator.prepare()
            #if DEBUG
            scheduleDebugAutoOpenIfNeeded()
            scheduleDebugAutoPinIfNeeded()
            if DebugLaunchOptions.openSettingsOnLaunch {
                settingsPresented = true
            }
            #endif
        }
        .onDisappear {
            // Unconditionally `false`, regardless of `doorVideoCoordinator
            // .isPinned` — bead gateopener-41m.15 STEP 5's "must not be left
            // stuck true" guarantee. The view disappearing means there is no
            // screen left to keep awake for either reason.
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: observable.state) { _, newState in
            handleStateChangeForHapticsAndIdleTimer(newState)
        }
        .onChange(of: doorVideoCoordinator.isPinned) { _, isPinned in
            // Backgrounding calls `doorVideoCoordinator.dismiss()`
            // (`GateOpenerIOSApp`'s `scenePhase` handler), which unpins —
            // this fires from that same state change, applying
            // `shouldKeepScreenAwake(isPinned: false, ...)` and clearing the
            // flag rather than leaving it stuck `true` from the pin bead
            // gateopener-41m.15 STEP 5 requires.
            UIApplication.shared.isIdleTimerDisabled = Self.shouldKeepScreenAwake(
                isPinned: isPinned,
                openFlowNeedsAwake: Self.openFlowNeedsAwake(for: observable.state)
            )
        }
    }

    /// Whether the pre-existing open-flow behavior alone (independent of
    /// pinning) wants the screen kept awake for the given `GateState` — the
    /// `openFlowNeedsAwake` input to `shouldKeepScreenAwake(isPinned:
    /// openFlowNeedsAwake:)`. `true` only while actively tapped-through
    /// `.queued`/`.opening`; `false` for every terminal/idle state, matching
    /// `handleStateChangeForHapticsAndIdleTimer(_:)`'s pre-existing
    /// per-state resets.
    private static func openFlowNeedsAwake(for state: GateState) -> Bool {
        switch state {
        case .queued, .opening:
            return true
        case .needsSetup, .idle, .succeeded, .failed:
            return false
        }
    }

    /// The leading glyph shown in the button for the current state: a
    /// checkmark once succeeded, otherwise the shared gate glyph
    /// (`GateSymbol`, reused from the widget/App-Shortcuts icon per this
    /// bead's INPUT — it reads clearly at this ~34pt size in white on the
    /// filled accent background, so no separate SF Symbol is needed).
    private var openButtonIconName: String {
        if case .succeeded = observable.state {
            return "checkmark.circle.fill"
        }
        return GateSymbol.name
    }

    private var openButton: some View {
        Button(action: handleTap) {
            HStack(spacing: 14) {
                if case .opening = observable.state {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Image(systemName: openButtonIconName)
                        .font(.system(size: 34, weight: .semibold))
                        .frame(width: 40)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.primaryLabel(for: observable.state))
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(gateDisplayName)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .foregroundStyle(.white)
        }
        .buttonStyle(OpenGateButtonStyle(fillColor: accentColor))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .animation(.easeInOut(duration: 0.2), value: observable.state)
        .accessibilityLabel("Open \(gateDisplayName)")
        .accessibilityValue(statusText)
        .accessibilityHint("Double tap to open the gate")
        .accessibilityAddTraits(.isButton)
    }

    /// The permanent 4:3 video slot (bead gateopener-41m.11 STEP 2):
    /// black background, rounded corners, always present directly under the
    /// title. Its content switches on `DoorVideoSlotContent.content(...)`,
    /// a pure mapping unit-tested independently in
    /// `DoorVideoSlotContentTests` — this computed property only wires that
    /// mapping's result to actual views/actions.
    ///
    /// `maxHeight` (rather than a bare `aspectRatio`) is what lets this slot
    /// actually shrink on short screens: `aspectRatio(_:contentMode: .fit)`
    /// alone still asks for its ideal (full-width-derived) height first,
    /// and only `layoutPriority(-1)` on the caller plus this `maxHeight`
    /// cap keep it from pushing `openButton`/`statusText` off-screen or
    /// clipping them — see the `layoutPriority(-1)` comment where this is
    /// placed in `body`.
    ///
    /// HARD RULE (memory `gateopener-ios-video-autoplay-hidden-webview`,
    /// reaffirmed by bead gateopener-672.30 / commit 8797114): the
    /// `sessionVideo` branch below is the ONLY place the web view is ever
    /// placed in the hierarchy, it is placed there for the WHOLE window a
    /// session is visible (connecting, busy-retry cooldown, AND streaming —
    /// one stable structural branch, not a different one per sub-state), and
    /// it is never hidden behind `.opacity(0)` or removed from the hierarchy
    /// while some other branch is active. `DoorVideoView` itself keeps
    /// drawing its own "Connecting…"/"Camera unavailable" overlay on top
    /// (bead gateopener-672.30); `MainView` only ever layers ADDITIONAL
    /// chrome (the busy-retry countdown, the close button) on top of that
    /// same mounted view, never a competing standalone view. The
    /// `.tapToView`/`.failed` branches render an entirely different view
    /// tree (icon + text, or icon + text + button) instead.
    ///
    /// Only the busy-retry countdown text needs a per-second tick
    /// (`doorVideoCoordinator.cooldownUntil` itself only changes at the
    /// start/end of a cooldown), so the `TimelineView(.periodic(...))` wraps
    /// ONLY that overlay, not the whole slot — re-evaluating the
    /// WKWebView-hosting subtree every second would be an avoidable risk to
    /// the live video (reviewer finding on this bead's FIX PASS).
    @ViewBuilder
    private var videoSlot: some View {
        let content = DoorVideoSlotContent.content(
            hasVisibleSession: doorVideoCoordinator.isPanelVisible,
            sessionState: doorVideoCoordinator.sessionState,
            lastTerminal: doorVideoCoordinator.lastTerminal,
            cooldownUntil: doorVideoCoordinator.cooldownUntil,
            isPinned: doorVideoCoordinator.isPinned,
            isRenewal: doorVideoCoordinator.isRenewing,
            pinStopMessage: doorVideoCoordinator.pinStopMessage,
            now: Date()
        )

        Group {
            switch content {
            case .session(let overlay):
                if let session = doorVideoCoordinator.session {
                    sessionVideo(session: session, overlay: overlay)
                } else {
                    // Defensive only: `.session` is only produced when
                    // `hasVisibleSession` is true, which the coordinator
                    // only sets alongside a non-nil `session`. Falls back to
                    // the neutral placeholder rather than crashing if that
                    // invariant is ever violated.
                    placeholder(icon: "video.fill", message: "Tap to view door", retry: false)
                }
            case .tapToView(let message):
                // `message` is `pinStopMessage` when the pin most recently
                // auto-stopped itself (bead gateopener-41m.15 STEP 5), else
                // `nil` for the plain neutral placeholder — either way the
                // tap-to-view affordance/action (`viewDoor()`, UNPINNED) is
                // identical.
                placeholder(icon: "video.fill", message: message ?? "Tap to view door", retry: false)
            case .failed(let message):
                placeholder(icon: "exclamationmark.triangle", message: message, retry: true)
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 280)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: content)
    }

    /// The `.session` case: the real `DoorVideoView` — mounted at this SAME
    /// structural position across connecting, busy-retry cooldown, and
    /// streaming (see the HARD RULE above) — plus:
    ///  - the existing close (xmark) button, top-trailing, available
    ///    throughout the whole visible window (matches the pre-fix
    ///    `videoPanel(session:)`, which included the close button for
    ///    connecting too, not just streaming);
    ///  - the pin button, top-leading (bead gateopener-41m.15 STEP 1),
    ///    visible whenever a session exists (i.e. throughout this whole
    ///    method, same as the close button);
    ///  - when `overlay == .busyRetry`, an opaque countdown overlay drawn ON
    ///    TOP of `DoorVideoView`, fully covering its own "Connecting…" label
    ///    so the two never show at once. Only this countdown text lives
    ///    inside a `TimelineView(.periodic(from: .now, by: 1))`, since it is
    ///    the only piece that needs a per-second tick
    ///    (`doorVideoCoordinator.cooldownUntil` only changes at the start/
    ///    end of a cooldown);
    ///  - when `overlay == .reconnecting` (bead gateopener-41m.15 STEP 4), an
    ///    opaque "Reconnecting…" scrim, same style as the busy-retry overlay,
    ///    covering `DoorVideoView`'s own "Connecting…"/"Camera unavailable"
    ///    text so the operator is never told this is the pin's first session
    ///    when it is actually a renewal;
    ///  - while `doorVideoCoordinator.isPinned`, a bottom-trailing countdown
    ///    capsule (bead gateopener-41m.15 STEP 2) showing `pinRemaining` as
    ///    "m:ss", also inside a `TimelineView(.periodic(from: .now, by: 1))`
    ///    — the only other piece needing a per-second tick.
    ///
    /// Calling `dismiss()` (close button) stops the session (idempotent),
    /// clears it immediately (no animation delay — the button itself IS the
    /// explicit dismiss action), and resets `lastTerminal` to `.none` (a
    /// USER close, per `DoorVideoCoordinator.dismiss()`'s doc comment). This
    /// also always unpins (`dismiss()`'s own behavior), same as backgrounding.
    private func sessionVideo(session: DoorVideoSession, overlay: DoorVideoSlotContent.SessionOverlay) -> some View {
        // `DoorVideoSessionHost` (bead gateopener-41m.18) owns the
        // `.id(ObjectIdentifier(session))` identity that forces a remount on
        // a pinned renewal (a new `DoorVideoSession` instance swapped in
        // while this view stays on the same `.session` structural branch) —
        // see that type's doc comment for the full rationale. The overlays
        // below are applied OUTSIDE that identity so the pin/close/countdown
        // chrome does not flicker across a renewal.
        DoorVideoSessionHost(session: session, state: doorVideoCoordinator.sessionState)
            .overlay {
                switch overlay {
                case .busyRetry(let secondsRemaining):
                    TimelineView(.periodic(from: .now, by: 1)) { timelineContext in
                        let liveContent = DoorVideoSlotContent.content(
                            hasVisibleSession: doorVideoCoordinator.isPanelVisible,
                            sessionState: doorVideoCoordinator.sessionState,
                            lastTerminal: doorVideoCoordinator.lastTerminal,
                            cooldownUntil: doorVideoCoordinator.cooldownUntil,
                            isPinned: doorVideoCoordinator.isPinned,
                            isRenewal: doorVideoCoordinator.isRenewing,
                            pinStopMessage: doorVideoCoordinator.pinStopMessage,
                            now: timelineContext.date
                        )
                        if case .session(.busyRetry(let liveSecondsRemaining)) = liveContent {
                            busyRetryOverlay(secondsRemaining: liveSecondsRemaining)
                        } else if case .session(.reconnecting) = liveContent {
                            // The cooldown elapsed since the outer `content`
                            // was computed, and a pinned renewal is now
                            // underway: hand off to the reconnecting scrim
                            // rather than keep showing a stale countdown.
                            reconnectingOverlay()
                        } else {
                            // The cooldown elapsed since the outer `content`
                            // was computed; the outer view will re-render
                            // shortly with `overlay == .none` and drop this
                            // branch entirely. Shown once, briefly, rather
                            // than flashing a stale "0s"/negative countdown.
                            busyRetryOverlay(secondsRemaining: secondsRemaining)
                        }
                    }
                case .reconnecting:
                    reconnectingOverlay()
                case .none:
                    EmptyView()
                }
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    doorVideoCoordinator.dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, .black.opacity(0.4))
                }
                .padding(8)
                .accessibilityLabel("Close door camera")
            }
            .overlay(alignment: .topLeading) {
                pinButton
            }
            .overlay(alignment: .bottomTrailing) {
                if doorVideoCoordinator.isPinned {
                    pinCountdownCapsule
                }
            }
    }

    /// The pin toggle button (bead gateopener-41m.15 STEP 1): top-leading,
    /// SF Symbol "pin"/"pin.fill" (filled + accent-tinted when pinned), on a
    /// 44x44 material-circle hit target. Toggles
    /// `doorVideoCoordinator.setPinned(_:)` and fires a light haptic.
    private var pinButton: some View {
        Button {
            lightImpactGenerator.impactOccurred()
            doorVideoCoordinator.setPinned(!doorVideoCoordinator.isPinned)
        } label: {
            Image(systemName: doorVideoCoordinator.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(doorVideoCoordinator.isPinned ? Color.accentColor : Color.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(8)
        .accessibilityLabel(doorVideoCoordinator.isPinned ? "Unpin video" : "Pin video")
        .accessibilityValue("Keeps the camera on for up to 5 minutes")
    }

    /// The pinned countdown capsule (bead gateopener-41m.15 STEP 2):
    /// bottom-trailing, "m:ss" from `doorVideoCoordinator.pinRemaining`,
    /// monospaced digits, turning red at <= 30s remaining — mirrors the web
    /// app's countdown badge. Only this text needs a per-second tick
    /// (`pinRemaining` is derived from `Date()` at read time), so the
    /// `TimelineView` wraps ONLY this capsule, not `DoorVideoView`.
    private var pinCountdownCapsule: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = max(0, Int(doorVideoCoordinator.pinRemaining ?? 0))
            let minutes = remaining / 60
            let seconds = remaining % 60
            Text(String(format: "%d:%02d", minutes, seconds))
                .font(.footnote.monospacedDigit().weight(.semibold))
                .foregroundStyle(remaining <= 30 ? Color.red : Color.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
                .accessibilityLabel("Pin time remaining")
                .accessibilityValue("\(minutes) minutes \(seconds) seconds")
        }
    }

    /// The pinned-renewal "Reconnecting…" scrim (bead gateopener-41m.15 STEP
    /// 4): same opaque style as `busyRetryOverlay` (`Color.black.opacity
    /// (0.92)`) so it fully covers `DoorVideoView`'s own "Connecting…"/
    /// "Camera unavailable" text underneath — the two must never both be
    /// visible at once.
    private func reconnectingOverlay() -> some View {
        ZStack {
            Color.black.opacity(0.92)
            VStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                Text("Reconnecting…")
                    .font(.footnote)
                    .foregroundStyle(.white)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The busy-retry countdown overlay: an opaque dark background matching
    /// `DoorVideoView`'s own connecting-overlay style
    /// (`Color.black.opacity(0.92)`, bead gateopener-672.30), so it fully
    /// covers `DoorVideoView`'s own "Connecting…" text underneath — the two
    /// texts must never both be visible at once.
    private func busyRetryOverlay(secondsRemaining: Int) -> some View {
        ZStack {
            Color.black.opacity(0.92)
            VStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                Text("Door camera busy — retrying in \(secondsRemaining)s")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The `.tapToView`/`.failed` cases: an icon, a message, and (only for
    /// `.failed`) a "Retry" button — both call `doorVideoCoordinator
    /// .viewDoor()`, since retrying a failed session and starting a fresh
    /// one from the neutral placeholder are the same action.
    ///
    /// `.tapToView`'s whole slot area is itself tappable (the `Button`
    /// wraps the icon/text), matching this bead's STEP 2 ("whole slot is a
    /// Button calling viewDoor()"); `.failed` shows a plain icon/text with a
    /// separate, smaller "Retry" button instead, so a stray tap on the
    /// failure message itself is not misread as "retry".
    @ViewBuilder
    private func placeholder(icon: String, message: String, retry: Bool) -> some View {
        if retry {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.85))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") {
                    lightImpactGenerator.impactOccurred()
                    doorVideoCoordinator.viewDoor()
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.2), in: Capsule())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            Button {
                lightImpactGenerator.impactOccurred()
                doorVideoCoordinator.viewDoor()
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.85))
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(message)
            .accessibilityHint("Double tap to view the door camera")
        }
    }

    /// The tap handler: fires a heavy haptic, keeps the screen awake, and
    /// forwards to `observable.requestOpen()`. `requestOpen()` itself is
    /// non-blocking and returns immediately (see
    /// `GateControllerObservable.requestOpen()` /
    /// `BackgroundOpenRunner.requestOpen()`), so nothing here `await`s —
    /// the button's appearance changes purely as a side effect of `state`
    /// changing, observed via `onChange` above, not from anything done in
    /// this method. A repeat tap while `.queued`/`.opening` is a no-op
    /// beyond a light haptic acknowledgment, since `GateController
    /// .requestOpen()` already coalesces repeat calls in those states.
    ///
    /// `doorVideoCoordinator.startForOpen()` is called on this SAME
    /// synchronous path, immediately after `observable.requestOpen()` —
    /// bead gateopener-672.12's STEPS require video to start CONCURRENTLY
    /// with the open (same instant, separate `Task`), never awaited before
    /// or after it. Both calls are already non-blocking themselves
    /// (`requestOpen()` per the doc comment above; `startForOpen()` per
    /// `DoorVideoCoordinator.startForOpen()`'s doc comment, which only
    /// kicks off a detached `Task` for the actual `DoorVideoSession.start()`
    /// call), so this ordering is purely textual — neither call can delay
    /// the other. An open failing later does not touch
    /// `doorVideoCoordinator` at all (see the `onChange` handler below),
    /// so a streaming video is never torn down by a failed open.
    private func handleTap() {
        switch observable.state {
        case .queued, .opening:
            lightImpactGenerator.impactOccurred()
            return
        case .needsSetup, .idle, .succeeded, .failed:
            break
        }

        impactGenerator.impactOccurred()
        UIApplication.shared.isIdleTimerDisabled = Self.shouldKeepScreenAwake(
            isPinned: doorVideoCoordinator.isPinned,
            openFlowNeedsAwake: true
        )
        observable.requestOpen()
        doorVideoCoordinator.startForOpen()
    }

    /// Drives haptics and the idle-timer reset from `state` transitions,
    /// never from the tap itself — `UINotificationFeedbackGenerator`
    /// success/error haptics fire only once the controller actually
    /// reaches a terminal state, not optimistically on tap. The idle-timer
    /// flag itself is always the combined `shouldKeepScreenAwake(isPinned:
    /// openFlowNeedsAwake:)` value (bead gateopener-41m.15 STEP 5) — a
    /// terminal/idle open-flow state no longer unconditionally clears the
    /// flag if the video happens to be pinned at the same moment.
    private func handleStateChangeForHapticsAndIdleTimer(_ newState: GateState) {
        switch newState {
        case .succeeded:
            notificationGenerator.notificationOccurred(.success)
        case .failed:
            notificationGenerator.notificationOccurred(.error)
        case .needsSetup, .idle, .queued, .opening:
            break
        }
        UIApplication.shared.isIdleTimerDisabled = Self.shouldKeepScreenAwake(
            isPinned: doorVideoCoordinator.isPinned,
            openFlowNeedsAwake: Self.openFlowNeedsAwake(for: newState)
        )
    }

    #if DEBUG
    /// `--auto-open-after <seconds>`: calls `requestOpen()` once, after the
    /// given delay, from `onAppear`. DEBUG-only verification hook — see
    /// `DebugLaunchOptions`.
    private func scheduleDebugAutoOpenIfNeeded() {
        guard !didScheduleDebugAutoOpen,
              let delaySeconds = DebugLaunchOptions.autoOpenAfterSeconds else { return }
        didScheduleDebugAutoOpen = true
        Task {
            try? await Task.sleep(for: .seconds(delaySeconds))
            handleTap()
        }
    }

    /// `--auto-pin-after <seconds>`: calls `doorVideoCoordinator
    /// .setPinned(true)` once, after the given delay, from `onAppear`. The
    /// pin button itself needs a real tap, which `simctl launch` cannot
    /// perform — this DEBUG-only hook lets a screenshot script capture the
    /// pinned/reconnecting/countdown states instead (bead gateopener-41m.15
    /// STEP 9). See `DebugLaunchOptions.autoPinAfterSeconds`.
    private func scheduleDebugAutoPinIfNeeded() {
        guard !didScheduleDebugAutoPin,
              let delaySeconds = DebugLaunchOptions.autoPinAfterSeconds else { return }
        didScheduleDebugAutoPin = true
        Task {
            try? await Task.sleep(for: .seconds(delaySeconds))
            lightImpactGenerator.impactOccurred()
            doorVideoCoordinator.setPinned(true)
        }
    }
    #endif
}
