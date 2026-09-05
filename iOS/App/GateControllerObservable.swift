import Foundation
import Observation
import GateOpenerCore

/// iOS app-target `@Observable` bridge from `GateController`'s plain,
/// non-Observable `state`/`onStateChange` to SwiftUI observation.
///
/// This is a deliberately separate, minimal file from
/// `Sources/GateOpener/GateControllerObservable.swift` (the macOS menu-bar
/// app's version) rather than a shared/reused one — see the DECISION note
/// on bead gateopener-672.7: the macOS version references `GlobalHotkey`,
/// which imports AppKit + Carbon.HIToolbox and is macOS-only, so it cannot
/// be compiled into the iOS target. This file has no hotkey/event-log/
/// shortcut-preference surface at all, only state mirroring plus a
/// `requestOpen()` forwarder.
///
/// Mirrors state via `AppEnvironment.addStateObserver(_:)` rather than
/// assigning `controller.onStateChange` directly, so it composes with the
/// snapshot-publishing subscriber `AppEnvironment.make()` already installs
/// on that same closure property — `GateController` retains only one
/// `onStateChange` closure, so a second direct assignment here would
/// silently replace (not add to) the snapshot publisher.
@MainActor
@Observable
final class GateControllerObservable {
    /// The controller this adapter wraps. Exposed so callers can invoke
    /// `openGate()`, etc. directly if needed.
    let controller: GateController

    /// The latest state, kept in sync with `controller.state` via
    /// `AppEnvironment.addStateObserver(_:)`. `@Observable` makes reads of
    /// this property from SwiftUI views trigger re-render on change.
    private(set) var state: GateState

    /// The runner `requestOpen()` forwards to, so an open dispatched from
    /// SwiftUI runs inside a `UIApplication` background task (see
    /// `BackgroundOpenRunner`) rather than risking suspension mid-flight.
    private let backgroundOpenRunner: BackgroundOpenRunner

    /// - Parameters:
    ///   - environment: Supplies `controller` and the multicast
    ///     `addStateObserver(_:)` seam used both by this class (to mirror
    ///     `state`) and, separately, by `backgroundOpenRunner` (registered
    ///     by the caller — see `GateOpenerIOSApp` — so background-task
    ///     begin/end tracks every state transition, not just the one
    ///     immediately following a `requestOpen()` call).
    ///   - backgroundOpenRunner: The runner `requestOpen()` forwards to.
    init(environment: AppEnvironment, backgroundOpenRunner: BackgroundOpenRunner) {
        self.controller = environment.controller
        self.state = environment.controller.state
        self.backgroundOpenRunner = backgroundOpenRunner
        environment.addStateObserver { [weak self] newState in
            self?.state = newState
        }
    }

    /// Forwards to `BackgroundOpenRunner.requestOpen()`, which wraps
    /// `controller.requestOpen()` in a `UIApplication` background task so
    /// leaving the app mid-open does not get the open command killed.
    func requestOpen() {
        backgroundOpenRunner.requestOpen()
    }
}
