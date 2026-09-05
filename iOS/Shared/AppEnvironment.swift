import Foundation
import GateOpenerCore
import WidgetKit
import os

/// The composition root shared by BOTH the iOS app and the widget
/// extension: it wires `GateOpenerCore`'s plain Foundation types
/// (`ComelitAPI`, `TokenManager`, `GateClient`, `GateController`,
/// `KeychainCredentialStore`) together with the iOS-only reachability
/// adapter (`NWPathMonitorReachability`, this directory) and the app-group
/// `UserDefaults`/`WidgetSnapshotStore` that let the widget see the app's
/// latest `GateState` without observing `GateController` directly (it lives
/// in a separate process).
///
/// This file lives in `iOS/Shared` (compiled into both the app target and
/// the widget extension target — see `iOS/Shared/README.md`), so it must
/// NOT import UIKit at the top level: `AppEnvironment.make()` may run from
/// the widget extension process (e.g. from `OpenGateIntent`) while the
/// device is locked, and must never touch `UIApplication` or prompt for
/// anything. `WidgetKit` is imported here only for the default
/// `timelineReloader`, which is itself just a static call into the
/// `WidgetCenter` singleton — no UI is created or shown.
///
/// `@MainActor` because it owns `GateController`, which is itself
/// `@MainActor` (see that type's doc comment): all state mutation is
/// expected to happen on the main actor.
@MainActor
public final class AppEnvironment {
    /// The shared `os.Logger` subsystem/category used to loudly report
    /// configuration problems (currently just the app-group entitlement
    /// fallback below) that would otherwise fail silently.
    private static let logger = Logger(subsystem: "ie.boboco.GateOpener", category: "AppEnvironment")

    public let defaults: UserDefaults
    public let appSettings: AppSettings
    public let credentialStore: KeychainCredentialStore
    public let api: ComelitAPI
    public let tokenManager: TokenManager
    public let gateClient: any GateOpening
    public let controller: GateController
    public let snapshotStore: WidgetSnapshotStore

    /// Reloads widget timelines. Stored (rather than only closed over by the
    /// `controller.onStateChange` handler installed in `make()`) so
    /// `publishSnapshot()` can also call it directly on a foreground
    /// re-publish (`GateOpenerIOSApp`'s `scenePhase == .active` handler),
    /// which writes a snapshot WITHOUT going through `controller
    /// .onStateChange` (the phase has not changed, only `updatedAt`) — see
    /// this bead's NOTES follow-up from 672.7's review: previously this was
    /// only a constructor parameter that was never stored, so that
    /// foreground re-publish silently never refreshed the widget.
    private let timelineReloader: @Sendable () -> Void

    /// Additional state observers chained onto `controller.onStateChange`,
    /// beyond the snapshot-publishing subscription installed by `make()`
    /// itself. See `addStateObserver(_:)`.
    private var additionalObservers: [(GateState) -> Void] = []

    /// - Parameters:
    ///   - defaults: Injection seam for tests. When `nil` (the production
    ///     default), resolves via `SharedContainer.sharedDefaults()`,
    ///     falling back to `.standard` (and logging loudly via `os.Logger`,
    ///     since a `nil` shared suite means the App Group entitlement is
    ///     missing or misconfigured on the running process) if that
    ///     returns `nil`.
    ///   - reachability: Injection seam for tests. When `nil`, defaults to
    ///     a real `NWPathMonitorReachability()`.
    ///   - timelineReloader: Injection seam for tests, so they never touch
    ///     the real `WidgetCenter`. Defaults to
    ///     `WidgetCenter.shared.reloadAllTimelines()`.
    ///   - gateClient: TEST/DEBUG SEAM ONLY. When `nil` (the production
    ///     default, and the only value ever used in a Release build),
    ///     resolves to a real `GateClient` wired to the `TokenManager`
    ///     constructed here. Non-nil only ever comes from
    ///     `DebugLaunchOptions` (`iOS/App`, `#if DEBUG`-gated) parsing a
    ///     `--mock-gate` launch argument, so that a fake `GateOpening` can
    ///     be exercised end to end (including `.opening`/`.succeeded`/
    ///     `.failed` UI states) on the simulator without ever touching the
    ///     real Comelit cloud or a physical gate. This parameter carries no
    ///     runtime `#if DEBUG` guard of its own — the guard lives at the
    ///     one call site that ever passes a non-nil value.
    ///   - tokenResolver: TEST/DEBUG SEAM ONLY, paired with `gateClient`.
    ///     `GateController.performOpen()` calls `tokenManager.accessToken()`
    ///     BEFORE `gateClient.open(endpointId:)`, so injecting only a fake
    ///     `GateOpening` is not suficient to exercise `--mock-gate` without
    ///     the real `TokenManager` attempting a real network login with the
    ///     debug seam's dummy credentials (and failing/succeeding
    ///     unpredictably depending on real network conditions). When `nil`
    ///     (the production default), the real `TokenManager` constructed
    ///     here is used, unchanged. This does NOT affect
    ///     `AppEnvironment.tokenManager` (still always the real
    ///     `TokenManager`, used for `prewarm()` and anything else that
    ///     needs the concrete type) — it only substitutes what
    ///     `GateController` itself calls for token resolution.
    public static func make(
        defaults: UserDefaults? = nil,
        reachability: (any ReachabilityProviding)? = nil,
        timelineReloader: @escaping @Sendable () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
        gateClient: (any GateOpening)? = nil,
        tokenResolver: (any TokenResolving)? = nil
    ) -> AppEnvironment {
        let resolvedDefaults: UserDefaults
        if let defaults {
            resolvedDefaults = defaults
        } else if let shared = SharedContainer.sharedDefaults() {
            resolvedDefaults = shared
        } else {
            logger.error("App Group entitlement missing or misconfigured: SharedContainer.sharedDefaults() returned nil; falling back to UserDefaults.standard. The app and widget extension will NOT share settings/credentials/snapshots until this is fixed.")
            resolvedDefaults = .standard
        }

        let appSettings = AppSettings(defaults: resolvedDefaults)

        // The lock-screen "Allow opening while locked" setting (default on)
        // selects `.afterFirstUnlockThisDeviceOnly` vs
        // `.whenUnlockedThisDeviceOnly`; that wiring is a later bead
        // (gateopener-672.16). For now this always uses
        // `.afterFirstUnlockThisDeviceOnly`, matching the store's own
        // default.
        let credentialStore = KeychainCredentialStore(
            accessGroup: SharedContainer.keychainAccessGroup,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )

        let api = ComelitAPI()
        let tokenManager = TokenManager(api: api, credentialStore: credentialStore)
        let resolvedGateClient: any GateOpening = gateClient ?? GateClient(tokenManager: tokenManager)
        let resolvedReachability = reachability ?? NWPathMonitorReachability()

        let resolvedTokenResolver: any TokenResolving = tokenResolver ?? tokenManager

        let controller = GateController(
            gateClient: resolvedGateClient,
            tokenManager: resolvedTokenResolver,
            credentialStore: credentialStore,
            appSettings: appSettings,
            reachability: resolvedReachability
        )

        let snapshotStore = WidgetSnapshotStore(defaults: resolvedDefaults)

        let environment = AppEnvironment(
            defaults: resolvedDefaults,
            appSettings: appSettings,
            credentialStore: credentialStore,
            api: api,
            tokenManager: tokenManager,
            gateClient: resolvedGateClient,
            controller: controller,
            snapshotStore: snapshotStore,
            timelineReloader: timelineReloader
        )

        // Publish once at construction so a fresh install shows
        // `needsSetup` in the widget immediately, before any state change
        // ever fires.
        environment.publishSnapshot()

        // The ONE subscriber `GateController.onStateChange` is given:
        // writes the snapshot on every change, reloads widget timelines,
        // then fans out to any observers registered via
        // `addStateObserver(_:)` (e.g. `GateControllerObservable`) so both
        // consumers can coexist without one overwriting the other's
        // handler.
        controller.onStateChange = { [weak environment] newState in
            guard let environment else { return }
            environment.publishSnapshot(for: newState)
            timelineReloader()
            for observer in environment.additionalObservers {
                observer(newState)
            }
        }

        return environment
    }

    private init(
        defaults: UserDefaults,
        appSettings: AppSettings,
        credentialStore: KeychainCredentialStore,
        api: ComelitAPI,
        tokenManager: TokenManager,
        gateClient: any GateOpening,
        controller: GateController,
        snapshotStore: WidgetSnapshotStore,
        timelineReloader: @escaping @Sendable () -> Void
    ) {
        self.defaults = defaults
        self.appSettings = appSettings
        self.credentialStore = credentialStore
        self.api = api
        self.tokenManager = tokenManager
        self.gateClient = gateClient
        self.controller = controller
        self.snapshotStore = snapshotStore
        self.timelineReloader = timelineReloader
    }

    /// Re-writes the current `controller.state` as a `WidgetSnapshot` and
    /// reloads widget timelines. Used both internally (on every state
    /// change) and on demand (e.g. the app calls this on foreground, since
    /// the snapshot's `updatedAt` staleness may matter to the widget even
    /// when the phase itself has not changed).
    public func publishSnapshot() {
        publishSnapshot(for: controller.state)
        timelineReloader()
    }

    private func publishSnapshot(for state: GateState) {
        let snapshot = WidgetSnapshot.from(
            state: state,
            gateName: appSettings.selectedEndpointName,
            now: Date()
        )
        snapshotStore.write(snapshot)
    }

    /// Registers an additional observer of `controller.state` changes,
    /// invoked (on the main actor) after the snapshot has been published
    /// and timelines reloaded for that same change.
    ///
    /// This exists so `GateControllerObservable` (app target only) can
    /// mirror state into an `@Observable` property WITHOUT overwriting the
    /// snapshot-publishing handler `make()` installs directly on
    /// `controller.onStateChange` — `GateController` only retains a single
    /// `onStateChange` closure, so a second subscriber must multicast
    /// through here rather than assigning `onStateChange` a second time.
    public func addStateObserver(_ observer: @escaping (GateState) -> Void) {
        additionalObservers.append(observer)
    }
}
