import Foundation
import Observation
import GateOpenerCore

/// App-layer bridge from `GateController` (plain, non-Observable, defined in
/// `GateOpenerCore`) to SwiftUI/AppKit observation.
///
/// `GateOpenerCore` deliberately cannot depend on Observation/SwiftUI (see
/// the file-level doc comment on `GateController`), so this type lives here
/// instead: it owns a `GateController`, subscribes to `onStateChange`, and
/// republishes the latest `GateState` as an `@Observable` property that
/// AppKit/SwiftUI code in this target can react to.
///
/// This class does NOT add any new state-mutation path: every mutation is
/// still routed through `GateController`'s own methods. It only forwards
/// notifications.
@MainActor
@Observable
final class GateControllerObservable {
    /// The controller this adapter wraps. Exposed so callers can invoke
    /// `openGate()`, `performFirstTimeSetup(...)`, etc. directly.
    let controller: GateController

    /// The latest state, kept in sync with `controller.state` via
    /// `onStateChange`. `@Observable` makes reads of this property from
    /// SwiftUI views trigger re-render on change.
    private(set) var state: GateState

    init(controller: GateController) {
        self.controller = controller
        self.state = controller.state
        controller.onStateChange = { [weak self] newState in
            self?.state = newState
        }
    }
}
