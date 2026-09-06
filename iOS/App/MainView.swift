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
    #endif

    private var gateDisplayName: String {
        appSettings.selectedEndpointName ?? "your gate"
    }

    private var buttonLabel: String {
        switch observable.state {
        case .failed:
            return "Try again"
        case .needsSetup, .idle, .queued, .opening, .succeeded:
            return appSettings.selectedEndpointName ?? "Open Gate"
        }
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

            // MARK: - Video panel (bead gateopener-672.12)
            //
            // Shown only while `doorVideoCoordinator.isPanelVisible` (a
            // session is connecting or streaming); animates in/out so the
            // panel never just pops in/out of the layout. When hidden this
            // renders as a zero-height `EmptyView`, so the button/status
            // line below simply occupy the space instead of leaving a gap
            // — there is no separate "reserved slot" once real video
            // exists.
            if doorVideoCoordinator.isPanelVisible, let session = doorVideoCoordinator.session {
                videoPanel(session: session)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            Spacer(minLength: 24)

            openButton
                .padding(.horizontal, 20)

            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .accessibilityHidden(true) // surfaced via the button's accessibilityValue instead

            viewDoorButton
                .padding(.top, 4)
                .padding(.bottom, 24)
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
            if DebugLaunchOptions.openSettingsOnLaunch {
                settingsPresented = true
            }
            #endif
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: observable.state) { _, newState in
            handleStateChangeForHapticsAndIdleTimer(newState)
        }
    }

    private var openButton: some View {
        Button(action: handleTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(accentColor)

                if case .opening = observable.state {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .controlSize(.extraLarge)
                        .scaleEffect(1.6)
                }

                HStack(spacing: 10) {
                    if case .succeeded = observable.state {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text(buttonLabel)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(.white)
                .opacity(isOpening ? 0.0 : 1.0)
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 140)
        .animation(.easeInOut(duration: 0.2), value: observable.state)
        .accessibilityLabel("Open \(gateDisplayName)")
        .accessibilityValue(statusText)
        .accessibilityAddTraits(.isButton)
    }

    private var isOpening: Bool {
        if case .opening = observable.state { return true }
        return false
    }

    /// The live door-camera panel: `DoorVideoView` plus a small circular X
    /// (dismiss) button overlaid in the top-trailing corner, so the
    /// operator can close it early without waiting for the door's own
    /// ~28-30s session window to elapse. Calling `dismiss()` stops the
    /// session (idempotent) and clears it immediately (no animation delay
    /// — the button itself IS the explicit dismiss action).
    private func videoPanel(session: DoorVideoSession) -> some View {
        DoorVideoView(session: session, state: doorVideoCoordinator.sessionState)
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
    }

    /// Secondary, plain "View door" affordance below the status line: starts
    /// a video session WITHOUT opening the gate. Per this bead's STEPS,
    /// pressing it while a session is already live (connecting/streaming)
    /// is a no-op — `DoorVideoCoordinator.viewDoor()` itself enforces the
    /// retain-vs-replace policy, so this button never needs to check
    /// `isPanelVisible` itself before calling it.
    private var viewDoorButton: some View {
        Button("View door") {
            lightImpactGenerator.impactOccurred()
            doorVideoCoordinator.viewDoor()
        }
        .buttonStyle(.plain)
        .font(.subheadline)
        .foregroundStyle(Color.accentColor)
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
        UIApplication.shared.isIdleTimerDisabled = true
        observable.requestOpen()
        doorVideoCoordinator.startForOpen()
    }

    /// Drives haptics and the idle-timer reset from `state` transitions,
    /// never from the tap itself — `UINotificationFeedbackGenerator`
    /// success/error haptics fire only once the controller actually
    /// reaches a terminal state, not optimistically on tap.
    private func handleStateChangeForHapticsAndIdleTimer(_ newState: GateState) {
        switch newState {
        case .succeeded:
            notificationGenerator.notificationOccurred(.success)
            UIApplication.shared.isIdleTimerDisabled = false
        case .failed:
            notificationGenerator.notificationOccurred(.error)
            UIApplication.shared.isIdleTimerDisabled = false
        case .needsSetup, .idle:
            UIApplication.shared.isIdleTimerDisabled = false
        case .queued, .opening:
            // Already set true on tap; keep it true through queued/opening.
            UIApplication.shared.isIdleTimerDisabled = true
        }
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
    #endif
}
