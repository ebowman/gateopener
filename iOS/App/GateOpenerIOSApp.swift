import SwiftUI
import GateOpenerCore

/// Minimal, launchable entry point for the iOS app target.
///
/// This is a placeholder that proves `GateOpenerCore` links into the iOS
/// app target end to end: it constructs `AppSettings` backed by the shared
/// App Group `UserDefaults` suite (falling back to `.standard` if the App
/// Group entitlement is unavailable, e.g. in a simulator build without a
/// team-signed provisioning profile) and reads `isConfigured` from it. Real
/// UI is built by later beads (composition root, sign-in, main screen).
@main
struct GateOpenerIOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private struct ContentView: View {
    private let settings = AppSettings(defaults: SharedContainer.sharedDefaults() ?? .standard)

    var body: some View {
        Text("GateOpener — configured: \(settings.isConfigured)")
            .padding()
    }
}
