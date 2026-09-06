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
    @State private var doorVideoCoordinator: DoorVideoCoordinator
    private let backgroundOpenRunner: BackgroundOpenRunner

    #if DEBUG
    /// `--video-harness` (bead gateopener-672.11 verification): held
    /// strongly here (rather than a local inside a `.task`) so the session
    /// survives the closure that starts it. `nil` unless `--video-harness`
    /// was passed. See `DebugLaunchOptions.videoHarnessOnLaunch`.
    @State private var videoHarnessSession: DoorVideoSession?
    #endif

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

        // `DoorVideoCoordinator`'s factory closure captures `environment`
        // (constructed above), so its `tokenManager`/`gateClient`/
        // `appSettings` always match what `GateController`/`observable`
        // themselves use — including a `--mock-gate`-injected fake
        // `GateOpening`/`TokenResolving`, where relevant.
        //
        // `--mock-video` (bead gateopener-672.12 verification) substitutes
        // `DoorVideoSession.debugStub()` for a real session: `--mock-gate
        // ok`'s seeded `cachedGates` has no camera endpoint, so a real
        // session would fail immediately with "No camera" and the video
        // panel could never be screenshotted from the simulator.
        let doorVideoCoordinator = DoorVideoCoordinator(
            makeSession: {
                #if DEBUG
                if DebugLaunchOptions.mockVideoOnLaunch {
                    return DoorVideoSession.debugStub()
                }
                #endif
                return DoorVideoSession(
                    tokenManager: environment.tokenManager,
                    gateClient: environment.gateClient,
                    appSettings: environment.appSettings
                )
            },
            isEnabled: { environment.appSettings.autoShowDoorVideoOnOpen }
        )

        _environment = State(initialValue: environment)
        _observable = State(initialValue: observable)
        _doorVideoCoordinator = State(initialValue: doorVideoCoordinator)
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
            guard newPhase == .active else {
                // Backgrounding always dismisses any live door-video panel
                // (WebRTC would be suspended by the system anyway, and
                // `DoorVideoCoordinator.dismiss()` -> `DoorVideoSession
                // .stop()` is idempotent, so this is always safe to call
                // even if nothing is running) — bead gateopener-672.12 step
                // "Wire scenePhase".
                doorVideoCoordinator.dismiss()
                #if DEBUG
                // Backgrounding also stops an in-flight `--video-harness`
                // session, independent of `doorVideoCoordinator` (the
                // harness is not wired into it — see that property's doc
                // comment).
                videoHarnessSession?.stop()
                #endif
                return
            }
            Task { await environment.tokenManager.prewarm() }
            environment.publishSnapshot()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        RootView(
            environment: environment,
            observable: observable,
            appSettings: environment.appSettings,
            doorVideoCoordinator: doorVideoCoordinator
        )
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
            #if DEBUG
            // `--video-harness` (bead gateopener-672.11 verification):
            // creates a `DoorVideoSession` and logs every state
            // transition via os.Logger. Not wired into any visible UI —
            // bead gateopener-672.12 does that; this exists purely so a
            // verification script can grep the log for the session's
            // state machine running end to end.
            .task {
                guard DebugLaunchOptions.videoHarnessOnLaunch, videoHarnessSession == nil else { return }
                let logger = Logger(subsystem: "ie.boboco.GateOpener", category: "video")
                let session = DoorVideoSession(
                    tokenManager: environment.tokenManager,
                    gateClient: environment.gateClient,
                    appSettings: environment.appSettings
                )
                session.onStateChange = { newState in
                    logger.notice("--video-harness state: \(String(describing: newState), privacy: .public)")
                }
                videoHarnessSession = session
                logger.notice("--video-harness: starting session")
                await session.start()
            }
            #endif
    }
}
