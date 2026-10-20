import SwiftUI
import GateOpenerCore
import WatchKit

/// Watch main screen (bead gateopener-3d7.7): one big circular "Open Gate"
/// button with `GateState` feedback and haptics. No auto-open: only a
/// deliberate tap calls `requestOpen()`.
///
/// Also owns the two notification-authorization triggers moved from the old
/// placeholder root view (bead gateopener-3d7.8): first `.active` while
/// configured, and (in `GateOpenerWatchApp.onApplied`) on provisioning.
struct WatchMainView: View {
    let environment: AppEnvironment
    @State private var observable: GateControllerObservable
    @Environment(\.scenePhase) private var scenePhase
    @State private var requestedAuthorization = false

    init(environment: AppEnvironment) {
        self.environment = environment
        _observable = State(initialValue: GateControllerObservable(environment: environment))
    }

    var body: some View {
        WatchMainContent(state: observable.state) {
            WKInterfaceDevice.current().play(.click)
            observable.requestOpen()
        }
        .onChange(of: observable.state) { old, new in
            guard old != new else { return }
            switch new {
            case .succeeded: WKInterfaceDevice.current().play(.success)
            case .failed: WKInterfaceDevice.current().play(.failure)
            default: break
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // Foreground: same as GateOpenerIOSApp's `.startIfAppropriate`.
            Task { await environment.tokenManager.prewarm() }
            environment.publishSnapshot()
            guard !requestedAuthorization else { return }
            guard environment.controller.state != .needsSetup else { return }
            requestedAuthorization = true
            let notifier = OpenResultNotifier(settings: environment.appSettings)
            notifier.registerCategories()
            await notifier.requestAuthorizationIfNeeded()
        }
    }
}

/// Pure presentation of a `GateState` (previewable without an environment).
struct WatchMainContent: View {
    let state: GateState
    let onOpen: () -> Void

    private var isBusy: Bool { state == .opening || state == .queued }
    private var isSetup: Bool { state == .needsSetup }

    var body: some View {
        VStack(spacing: 6) {
            Button(action: onOpen) {
                buttonLabel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Circle().fill(fill))
            }
            .buttonStyle(.plain)
            .disabled(isBusy || isSetup)
            .accessibilityLabel(accessibilityText)

            if let caption {
                Text(caption.text)
                    .font(.footnote)
                    .foregroundStyle(caption.color)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var buttonLabel: some View {
        VStack(spacing: 4) {
            switch state {
            case .queued, .opening:
                ProgressView()
                Text("Opening…").font(.headline).minimumScaleFactor(0.5).lineLimit(1)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill").font(.title)
                Text("Accepted").font(.headline).minimumScaleFactor(0.5).lineLimit(1)
            case .failed:
                Image(systemName: GateSymbol.name).font(.title)
                Text("Retry").font(.headline).minimumScaleFactor(0.5).lineLimit(1)
            case .needsSetup, .idle:
                Image(systemName: GateSymbol.name).font(.title)
                Text("Open Gate").font(.headline).minimumScaleFactor(0.5).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(8)
    }

    private var fill: Color {
        switch state {
        case .succeeded: return .green
        case .failed: return .red
        case .needsSetup: return .gray
        default: return .blue
        }
    }

    private var caption: (text: String, color: Color)? {
        switch state {
        case .needsSetup: return ("Sign in on your iPhone to set up the gate", .secondary)
        case .failed(let message): return (message, .red)
        default: return nil
        }
    }

    private var accessibilityText: String {
        switch state {
        case .queued, .opening: return "Opening"
        case .succeeded: return "Open command accepted"
        case .failed(let message): return "Retry. \(message)"
        case .needsSetup: return "Open Gate, unavailable. Sign in on your iPhone."
        case .idle: return "Open Gate"
        }
    }
}

#Preview("Idle") { WatchMainContent(state: .idle) {} }
#Preview("Opening") { WatchMainContent(state: .opening) {} }
#Preview("Succeeded") { WatchMainContent(state: .succeeded(at: Date())) {} }
#Preview("Failed") { WatchMainContent(state: .failed(message: "No network")) {} }
#Preview("Needs setup") { WatchMainContent(state: .needsSetup) {} }
