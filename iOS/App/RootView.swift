import SwiftUI
import GateOpenerCore

/// The app's root view: switches on `GateControllerObservable.state`.
///
/// `.needsSetup` → `SignInView` (bead gateopener-672.8). Anything else →
/// `MainView` (bead gateopener-672.9), the screen the app launches
/// straight into once configured.
struct RootView: View {
    var environment: AppEnvironment
    var observable: GateControllerObservable
    var appSettings: AppSettings
    var doorVideoCoordinator: DoorVideoCoordinator

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            switch observable.state {
            case .needsSetup:
                SignInView(observable: observable)
            default:
                MainView(
                    environment: environment,
                    observable: observable,
                    appSettings: appSettings,
                    doorVideoCoordinator: doorVideoCoordinator
                )
            }
        }
        // Bead gateopener-41m.12: once sign-in completes (`.needsSetup` ->
        // anything else) while the app is active, the user has just landed
        // on `MainView` for the first time this session — start door video
        // the same as any other foreground trigger would. Guarded to
        // `scenePhase == .active` so this can never fire for a transition
        // that happens to occur while backgrounded (there is no such path
        // today, but this keeps the same invariant as the app-level
        // triggers: never start video without an active scene).
        // Deliberately keyed on `observable.state == .needsSetup` (a Bool)
        // rather than the raw `GateState`, so this fires exactly once on
        // the needsSetup -> not-needsSetup edge and never again on
        // subsequent state changes within the non-needsSetup regime (e.g.
        // `.idle` -> `.opening` -> `.succeeded` while opening a gate).
        .onChange(of: observable.state == .needsSetup) { wasNeedsSetup, isNeedsSetup in
            guard wasNeedsSetup, !isNeedsSetup, scenePhase == .active else { return }
            doorVideoCoordinator.startForForeground()
        }
    }
}
