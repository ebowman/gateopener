import SwiftUI
import GateOpenerCore

/// The app's root view: switches on `GateControllerObservable.state`.
///
/// `.needsSetup` → `SignInView` (bead gateopener-672.8). Anything else →
/// `MainView` (bead gateopener-672.9), the screen the app launches
/// straight into once configured.
struct RootView: View {
    var environment: AppEnvironment
    var observable: GateControllerObservable
    var appSettings: AppSettings

    var body: some View {
        NavigationStack {
            switch observable.state {
            case .needsSetup:
                SignInView(observable: observable)
            default:
                MainView(environment: environment, observable: observable, appSettings: appSettings)
            }
        }
    }
}
