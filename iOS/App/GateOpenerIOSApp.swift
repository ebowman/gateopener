import SwiftUI
import GateOpenerCore

/// The iOS app's `@main` entry point.
///
/// Constructs the composition root (`AppEnvironment`, `iOS/Shared`) exactly
/// once, plus the app-only glue (`GateControllerObservable`,
/// `BackgroundOpenRunner`) that must not live in `iOS/Shared` because it
/// imports `UIKit`/`Observation`-for-SwiftUI. On every foreground
/// (`scenePhase == .active`) it prewarms the token manager and re-publishes
/// the widget snapshot, per bead gateopener-672.7 step 5.
///
/// `RootView` (`iOS/App/RootView.swift`) switches between `SignInView`
/// (bead gateopener-672.8) and a main-screen stub — the real main/settings
/// screens are later beads (gateopener-672.9, .10).
@main
struct GateOpenerIOSApp: App {
    @State private var environment: AppEnvironment
    @State private var observable: GateControllerObservable
    private let backgroundOpenRunner: BackgroundOpenRunner

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let environment = AppEnvironment.make(reachability: NWPathMonitorReachability())
        let runner = BackgroundOpenRunner(controller: environment.controller)
        // Registered alongside `GateControllerObservable`'s own observer
        // (both via `addStateObserver`, never by assigning
        // `controller.onStateChange` directly) so background-task
        // begin/end tracks every subsequent state transition, not only the
        // one immediately following a `requestOpen()` call.
        environment.addStateObserver { [runner] newState in
            runner.stateDidChange(newState)
        }
        let observable = GateControllerObservable(environment: environment, backgroundOpenRunner: runner)

        _environment = State(initialValue: environment)
        _observable = State(initialValue: observable)
        self.backgroundOpenRunner = runner
    }

    var body: some Scene {
        WindowGroup {
            RootView(observable: observable)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await environment.tokenManager.prewarm() }
            environment.publishSnapshot()
        }
    }
}
