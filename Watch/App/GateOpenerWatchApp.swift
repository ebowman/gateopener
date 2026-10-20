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
        ) { [weak controller = environment.controller, tokenManager = environment.tokenManager] message in
            Task { @MainActor in
                if case .signedOut = message {
                    // Drop the in-memory access token (actor method, hence
                    // the await) so a signed-out watch can't keep opening
                    // with a cached one; done before re-evaluating state.
                    await tokenManager.invalidate()
                }
                controller?.refreshStateFromStores()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        _receiver = State(initialValue: receiver)
    }

    var body: some Scene {
        WindowGroup {
            Text("GateOpener")
                // Started from `.task` (once the scene exists) rather than
                // `init`, so WCSession activation never races App setup.
                // `start()` is idempotent.
                .task { receiver.start() }
        }
    }
}
