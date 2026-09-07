import Foundation
import GateOpenerCore
import UIKit

/// Abstraction over `UIApplication`'s background-task API, so tests can
/// fake begin/end without a real `UIApplication` (which is unavailable off
/// the main app process and awkward to drive from a unit test).
///
/// `iOS/App` only (this file `import UIKit`), never `iOS/Shared` — see
/// `AppEnvironment`'s doc comment on why `UIApplication` must never be
/// touched from code that also runs in the widget extension process.
@MainActor
protocol BackgroundTaskHost {
    /// Begins a background task, matching
    /// `UIApplication.beginBackgroundTask(expirationHandler:)`'s shape:
    /// returns an opaque identifier and invokes `expirationHandler` if the
    /// system needs to end the task before `endBackgroundTask(_:)` is
    /// called.
    func beginBackgroundTask(expirationHandler: @escaping @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    /// Ends a previously-begun background task.
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

/// Default `BackgroundTaskHost` backed by the real `UIApplication.shared`.
@MainActor
struct UIApplicationBackgroundTaskHost: BackgroundTaskHost {
    func beginBackgroundTask(expirationHandler: @escaping @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(expirationHandler: expirationHandler)
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

/// Wraps `GateController.requestOpen()` so that dispatching an open (from
/// the main screen's button, in the app process) keeps running inside a
/// `UIApplication` background task for as long as the controller reports
/// `.queued`/`.opening` — so backgrounding the app (e.g. switching to
/// Messages to confirm someone is at the door) does not get the in-flight
/// open command suspended/killed by the OS before it completes.
///
/// The background task is begun the moment `state` enters `.queued` or
/// `.opening`, and ended the moment it reaches any terminal-for-this-
/// purpose state: `.idle`, `.succeeded`, `.failed`, or `.needsSetup`.
/// Ending is idempotent/guarded against double-ending, since
/// `UIApplication.endBackgroundTask(_:)` called twice with the same
/// identifier is a programmer error Apple's docs call out explicitly.
@MainActor
final class BackgroundOpenRunner {
    private let controller: GateController
    private let host: BackgroundTaskHost

    /// The currently-active background task identifier, if any. `nil`
    /// whenever no background task is in flight — this doubles as the
    /// double-end guard: `endCurrentTaskIfNeeded()` no-ops when this is
    /// already `nil`.
    private var currentTaskId: UIBackgroundTaskIdentifier?

    init(controller: GateController, host: BackgroundTaskHost = UIApplicationBackgroundTaskHost()) {
        self.controller = controller
        self.host = host
    }

    /// Forwards to `controller.requestOpen()`, updating the background
    /// task around the resulting state transition. Safe to call
    /// repeatedly — `GateController.requestOpen()` already coalesces
    /// repeat calls while queued/opening.
    func requestOpen() {
        updateBackgroundTask(for: controller.state)
        controller.requestOpen()
        updateBackgroundTask(for: controller.state)
    }

    /// Called whenever `state` changes, to begin/end the background task
    /// as needed. Intended to be wired from the owner of this runner (see
    /// `GateOpenerIOSApp`) as an additional observer alongside
    /// `GateControllerObservable`'s own subscription.
    func stateDidChange(_ state: GateState) {
        updateBackgroundTask(for: state)
    }

    private func updateBackgroundTask(for state: GateState) {
        switch state {
        case .queued, .opening:
            beginBackgroundTaskIfNeeded()
        case .idle, .succeeded, .failed, .needsSetup:
            endCurrentTaskIfNeeded()
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard currentTaskId == nil else { return }
        currentTaskId = host.beginBackgroundTask { [weak self] in
            // Expiration handler: the system is about to force-kill the
            // app if this background task is not ended now. End it
            // immediately; the open itself may still fail asynchronously,
            // but there is nothing further this runner can do to extend
            // its lifetime. The handler itself must be `@Sendable` (it may
            // be invoked off the main actor), so hop back to the main
            // actor before touching this main-actor-isolated instance.
            Task { @MainActor in
                self?.endCurrentTaskIfNeeded()
            }
        }
    }

    private func endCurrentTaskIfNeeded() {
        guard let taskId = currentTaskId else { return }
        currentTaskId = nil
        host.endBackgroundTask(taskId)
    }
}
