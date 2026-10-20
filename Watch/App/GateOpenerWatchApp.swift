import SwiftUI
import GateOpenerCore
import os
import WidgetKit

/// Watch app entry point. Constructs the composition root
/// (`AppEnvironment`, `iOS/Shared`) exactly once, mirroring
/// `GateOpenerIOSApp` minus the iOS-only glue (BackgroundOpenRunner,
/// DoorVideoCoordinator, DebugLaunchOptions). The real UI arrives in later
/// beads of the gateopener-3d7 epic (bead gateopener-3d7.3).
@main
struct GateOpenerWatchApp: App {
    @State private var environment: AppEnvironment
    @State private var receiver: WatchProvisioningReceiver

    init() {
        let environment = AppEnvironment.make()
        Logger(subsystem: "ie.boboco.GateOpener", category: "watch")
            .notice("watch launch: SharedContainer.sharedDefaults() non-nil = \(SharedContainer.sharedDefaults() != nil, privacy: .public)")
        _environment = State(initialValue: environment)
        let receiver = WatchProvisioningReceiver(
            settings: environment.appSettings,
            credentialStore: environment.credentialStore
        ) { [weak controller = environment.controller, tokenManager = environment.tokenManager, appSettings = environment.appSettings] message in
            Task { @MainActor in
                if WatchProvisioningReaction.shouldInvalidateCachedToken(for: message) {
                    // Drop the in-memory access token (actor method, hence
                    // the await): apply(.provision) deletes stored tokens but
                    // the cache would keep opening as the old account, and a
                    // signed-out watch must not keep a cached one either.
                    await tokenManager.invalidate()
                }
                controller?.refreshStateFromStores()
                WidgetCenter.shared.reloadAllTimelines()
                if case .provision = message {
                    // The watch just became configured: ask for notification
                    // permission now (no-op unless `.notDetermined`) so
                    // Siri/Action Button failures can post (bead 3d7.8).
                    let notifier = OpenResultNotifier(settings: appSettings)
                    notifier.registerCategories()
                    await notifier.requestAuthorizationIfNeeded()
                }
            }
        }
        _receiver = State(initialValue: receiver)
    }

    var body: some Scene {
        WindowGroup {
            WatchMainView(environment: environment)
                // Started from `.task` (once the scene exists) rather than
                // `init`, so WCSession activation never races App setup.
                // `start()` is idempotent.
                .task { receiver.start() }
                // `gateopener://main` from a complication tap: nothing to do
                // beyond showing the main view (bead gateopener-3d7.9).
                .onOpenURL { _ in }
        }
    }
}
