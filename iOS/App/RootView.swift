import SwiftUI
import GateOpenerCore

/// The app's root view: switches on `GateControllerObservable.state`.
///
/// `.needsSetup` → `SignInView` (bead gateopener-672.8). Anything else →
/// `MainViewStub`, a placeholder proving the wiring compiles and runs end
/// to end; the real main screen is bead gateopener-672.9.
struct RootView: View {
    var observable: GateControllerObservable

    var body: some View {
        NavigationStack {
            switch observable.state {
            case .needsSetup:
                SignInView(observable: observable)
            default:
                MainViewStub(observable: observable)
            }
        }
    }
}

/// Temporary placeholder main screen: shows the current `GateState` as
/// text plus a debug "Request open" button. Replaced by the real main
/// screen in bead gateopener-672.9.
private struct MainViewStub: View {
    var observable: GateControllerObservable

    var body: some View {
        VStack(spacing: 16) {
            Text("GateOpener")
                .font(.title)
            Text("State: \(String(describing: observable.state))")
            Button("Request open") {
                observable.requestOpen()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
