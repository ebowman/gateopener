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
    public let gateClient: GateClient
    public let controller: GateController
    public let snapshotStore: WidgetSnapshotStore

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
    public static func make(
        defaults: UserDefaults? = nil,
        reachability: (any ReachabilityProviding)? = nil,
        timelineReloader: @escaping @Sendable () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
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
        let gateClient = GateClient(tokenManager: tokenManager)
        let resolvedReachability = reachability ?? NWPathMonitorReachability()

        let controller = GateController(
            gateClient: gateClient,
            tokenManager: tokenManager,
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
            gateClient: gateClient,
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
        gateClient: GateClient,
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
    }

    /// Re-writes the current `controller.state` as a `WidgetSnapshot` and
    /// reloads widget timelines. Used both internally (on every state
    /// change) and on demand (e.g. the app calls this on foreground, since
    /// the snapshot's `updatedAt` staleness may matter to the widget even
    /// when the phase itself has not changed).
    public func publishSnapshot() {
        publishSnapshot(for: controller.state)
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
