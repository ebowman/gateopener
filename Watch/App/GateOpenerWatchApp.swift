import SwiftUI
import GateOpenerCore
import os

/// Watch app entry point. Constructs the composition root
/// (`AppEnvironment`, `iOS/Shared`) exactly once, mirroring
/// `GateOpenerIOSApp` minus the iOS-only glue (BackgroundOpenRunner,
/// DoorVideoCoordinator, DebugLaunchOptions). The real UI arrives in later
/// beads of the gateopener-3d7 epic (bead gateopener-3d7.3).
@main
struct GateOpenerWatchApp: App {
    @State private var environment: AppEnvironment

    init() {
        let environment = AppEnvironment.make()
        Logger(subsystem: "ie.boboco.GateOpener", category: "watch")
            .notice("watch launch: SharedContainer.sharedDefaults() non-nil = \(SharedContainer.sharedDefaults() != nil, privacy: .public)")
        _environment = State(initialValue: environment)
    }

    var body: some Scene {
        WindowGroup {
            Text("GateOpener")
        }
    }
}
