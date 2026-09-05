import SwiftUI
import GateOpenerCore
#if DEBUG
import os
#endif

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
        #if DEBUG
        // Debug/test seam only (bead gateopener-672.9): `--mock-gate
        // [ok|fail]` injects a fake `GateOpening` and pre-seeds a fake
        // account so the main screen's `.opening`/`.succeeded`/`.failed`
        // states can be exercised on the simulator without touching the
        // real Comelit cloud. See `DebugLaunchOptions`.
        //
        // MUST run before `AppEnvironment.make(...)`: that call
        // synchronously constructs `GateController`, whose initial `state`
        // (`.idle` vs `.needsSetup`) is decided from `appSettings
        // .isConfigured` and `credentialStore.loadCredentials()` at
        // construction time — seeding afterwards would be too late to
        // affect the very first render. This uses the same
        // `SharedContainer` defaults suite / keychain access group
        // `AppEnvironment.make` itself resolves to, so the seed lands in
        // the exact store the freshly-constructed `AppEnvironment` reads
        // from. Both calls are no-ops when `--mock-gate` was not passed.
        DebugLaunchOptions.seedMockAccountIfNeeded(
            appSettings: AppSettings(defaults: SharedContainer.sharedDefaults() ?? .standard),
            credentialStore: KeychainCredentialStore(accessGroup: SharedContainer.keychainAccessGroup)
        )
        let environment = AppEnvironment.make(
            reachability: NWPathMonitorReachability(),
            gateClient: DebugLaunchOptions.makeGateClientIfNeeded(),
            tokenResolver: DebugLaunchOptions.makeTokenResolverIfNeeded()
        )
        #else
        let environment = AppEnvironment.make(reachability: NWPathMonitorReachability())
        #endif
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
            #if DEBUG
            // `--widget-preview` (bead gateopener-672.14 verification step
            // 7): shows `WidgetPreviewView` instead of the real
            // `RootView`, so a screenshot script can capture every widget
            // family/state without the (non-automatable) widget gallery.
            if DebugLaunchOptions.widgetPreviewOnLaunch {
                NavigationStack {
                    WidgetPreviewView()
                }
            } else {
                mainContent
            }
            #else
            mainContent
            #endif
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await environment.tokenManager.prewarm() }
            environment.publishSnapshot()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        RootView(environment: environment, observable: observable, appSettings: environment.appSettings)
            #if DEBUG
            // `--run-intent` (bead gateopener-672.13 verification):
            // drives `OpenGateIntent` directly, without any
            // AppIntents/Siri/Shortcuts/widget infrastructure, so a
            // screenshot script can confirm the SAME snapshot the
            // widget would read gets written by the intent path. This
            // constructs its OWN `AppEnvironment` (matching what a real
            // `OpenGateIntent` invocation from a separate extension
            // process would do) rather than reusing `environment`
            // above — see `OpenGateIntent.runFlow()`'s doc comment.
            .task {
                guard DebugLaunchOptions.runIntentOnLaunch else { return }
                // Reuses the app's OWN `environment` (built above,
                // possibly with a `--mock-gate`-injected fake
                // `GateOpening`/`TokenResolving`) rather than letting
                // `runFlow()` construct a fresh, unmocked one — see
                // `OpenGateIntent.runFlow(environment:)`'s doc comment.
                let outcome = await OpenGateIntent.runFlow(environment: environment)
                Logger(subsystem: "ie.boboco.GateOpener", category: "DebugLaunchOptions")
                    .notice("--run-intent finished: \(String(describing: outcome), privacy: .public)")
            }
            #endif
            // `gateopener://main` (bead gateopener-672.14 step 4): every
            // widget's non-button body uses `.widgetURL(URL(string:
            // "gateopener://main"))` (`iOS/Shared/GateWidgetViews.swift`)
            // to bring the app to the foreground/`MainView`. This handler
            // deliberately does NOTHING beyond that — no navigation state
            // is even needed, since `RootView` already renders `MainView`
            // by default — and, critically, it MUST NEVER call
            // `environment.controller.requestOpen()`/`openGate()` or any
            // wrapper around them: an accidental tap on the widget body
            // (as opposed to the explicit `Button(intent: OpenGateIntent())`
            // inside it) must not open a physical gate. Only the intent's
            // own button can open the gate.
            .onOpenURL { url in
                guard url.scheme == "gateopener" else { return }
                // Intentionally empty otherwise: opening the URL itself
                // already brought the app to the foreground/MainView.
            }
    }
}
