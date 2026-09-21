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
                    if let timeline = DebugLaunchOptions.mockVideoTimeline {
                        return DoorVideoSession.debugStub(
                            connectingDelay: timeline.connectingSeconds,
                            streamingDuration: timeline.streamingSeconds
                        )
                    }
                    return DoorVideoSession.debugStub()
                }
                #endif
                return DoorVideoSession(
                    tokenManager: environment.tokenManager,
                    gateClient: environment.gateClient,
                    appSettings: environment.appSettings
                )
            },
            isEnabled: { environment.appSettings.autoShowDoorVideoOnOpen },
            isAutoStartEnabled: { environment.appSettings.autoStartDoorVideoOnLaunch },
            eventSink: { line in
                VideoDiagnostics.appendEvent(line, to: SharedContainer.sharedDefaults() ?? .standard)
            }
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
            switch Self.videoAction(for: newPhase) {
            case .dismiss:
                // Backgrounding always dismisses any live door-video panel
                // (WebRTC would be suspended by the system anyway, and
                // `DoorVideoCoordinator.dismiss()` -> `DoorVideoSession
                // .stop()` is idempotent, so this is always safe to call
                // even if nothing is running) — bead gateopener-672.12 step
                // "Wire scenePhase".
                doorVideoCoordinator.dismiss(reason: "background")
                #if DEBUG
                // Backgrounding also stops an in-flight `--video-harness`
                // session, independent of `doorVideoCoordinator` (the
                // harness is not wired into it — see that property's doc
                // comment).
                videoHarnessSession?.stop()
                #endif
            case .none:
                // `.inactive` (bead gateopener-41m.17): a brief Notification
                // Center/Control Center pull-down, app-switcher peek, call
                // banner, Face ID, or system alert must NOT tear down a
                // live/connecting door-video session — the app is still
                // foreground and WebRTC keeps running underneath. Do
                // nothing to the video session OR any other per-phase work
                // below (token prewarm, snapshot publish, foreground
                // auto-start all wait for the next real `.active`).
                break
            case .startIfAppropriate:
                Task { await environment.tokenManager.prewarm() }
                environment.publishSnapshot()
                startDoorVideoForForegroundIfAppropriate()
            }
        }
    }

    /// Pure scenePhase -> video-lifecycle decision (bead gateopener-41m.17),
    /// extracted so it is unit-testable without a live `App`/`Scene`.
    ///
    /// - `.background` -> `.dismiss`: matches the pre-existing behavior —
    ///   the system may suspend/terminate the process at any point once
    ///   backgrounded, so any live session is torn down immediately (see the
    ///   `.dismiss` case's own comment at the call site for why this is
    ///   always safe).
    /// - `.inactive` -> `.none`: a brief, foreground-adjacent interruption
    ///   (Notification Center, Control Center, app-switcher peek, a call
    ///   banner, Face ID, or a system alert) that historically ALSO
    ///   dismissed the panel — costing the user a fresh `rtc/offer` inside
    ///   the door's ~15s busy window on every such blip once auto-start
    ///   (gateopener-41m.12) landed. No concrete reason tying the dismiss to
    ///   `.inactive` specifically (as opposed to `.background`) was found in
    ///   history or `bd memories` — see this bead's investigation — so the
    ///   video session and pin state are left untouched here.
    /// - `.active` -> `.startIfAppropriate`: unchanged — prewarm, publish
    ///   the widget snapshot, and (subject to
    ///   `startDoorVideoForForegroundIfAppropriate()`'s own guards)
    ///   start-or-retain door video.
    /// - `@unknown default` -> `.none`: a future scenePhase case is treated
    ///   conservatively as "do nothing to the video", matching `.inactive`
    ///   rather than risking a spurious dismiss on a phase this code does
    ///   not yet understand.
    static func videoAction(for phase: ScenePhase) -> ScenePhaseVideoAction {
        switch phase {
        case .background:
            return .dismiss
        case .inactive:
            return .none
        case .active:
            return .startIfAppropriate
        @unknown default:
            return .none
        }
    }

    /// See `videoAction(for:)`.
    enum ScenePhaseVideoAction: Equatable {
        case dismiss
        case none
        case startIfAppropriate
    }

    /// Shared guard for auto-starting door video on foreground/cold-launch
    /// (bead gateopener-41m.12): called from the `scenePhase == .active`
    /// branch above AND from `mainContent`'s cold-launch `.task` below.
    /// Calling this twice for the same foreground transition (which happens
    /// on a cold launch where `scenePhase` starts `.inactive` then flips to
    /// `.active`, firing BOTH the `.task` — guarded to check `scenePhase ==
    /// .active` at the moment it runs — and this `onChange` handler) is
    /// harmless: `DoorVideoCoordinator.startForForeground()` ->
    /// `startOrRetain()` retains an already-connecting/streaming session
    /// rather than starting a second one.
    ///
    /// Deliberately does NOT start video when:
    ///   - `observable.state == .needsSetup` — `SignInView` is showing, not
    ///     `MainView`, so there is nowhere for the video panel to appear and
    ///     starting a session here would waste a network round trip the user
    ///     can't even see.
    ///   - `DebugLaunchOptions.widgetPreviewOnLaunch` / `.videoHarnessOnLaunch`
    ///     — both debug harnesses replace or bypass the normal `MainView`
    ///     video slot; auto-starting here would double up with (or race)
    ///     whatever those harnesses already do.
    private func startDoorVideoForForegroundIfAppropriate() {
        #if DEBUG
        guard !DebugLaunchOptions.widgetPreviewOnLaunch, !DebugLaunchOptions.videoHarnessOnLaunch else { return }
        #endif
        guard observable.state != .needsSetup else { return }
        doorVideoCoordinator.startForForeground()
    }

    @ViewBuilder
    private var mainContent: some View {
        RootView(
            environment: environment,
            observable: observable,
            appSettings: environment.appSettings,
            doorVideoCoordinator: doorVideoCoordinator
        )
            // Cold-launch auto-start (bead gateopener-41m.12):
            // `.onChange(of: scenePhase)` above never fires for the
            // INITIAL scenePhase value, only on subsequent transitions — so
            // a cold launch that starts directly `.active` would otherwise
            // never call `startForForeground()` at all. Guarded to check
            // `scenePhase == .active` at the moment this task actually runs
            // (not merely "always run on first appearance"), because on a
            // cold launch scenePhase is often still `.inactive` here and
            // only flips to `.active` a moment later — in which case the
            // `onChange` handler fires instead and this guard correctly
            // no-ops, avoiding a double start (which would be harmless
            // anyway — see `startDoorVideoForForegroundIfAppropriate`'s doc
            // comment — but there is no reason to invite it). Also
            // guarantees a background launch (e.g. `BackgroundOpenRunner`
            // waking the process with no UI ever shown) never starts video:
            // scenePhase is never `.active` in that case.
            .task {
                guard scenePhase == .active else { return }
                startDoorVideoForForegroundIfAppropriate()
            }
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
