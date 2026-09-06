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

            // MARK: - Video panel slot (bead gateopener-672.12)
            //
            // Reserved, clearly-marked empty region for the live
            // door-camera view. Deliberately empty in this bead — do not
            // implement video here. `.12` replaces this `Spacer()` (or
            // the whole VStack region) with the actual video panel.
            VStack {
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 80)

            Spacer(minLength: 24)

            openButton
                .padding(.horizontal, 20)

            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .accessibilityHidden(true) // surfaced via the button's accessibilityValue instead
        }
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
