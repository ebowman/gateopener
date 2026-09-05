import Foundation

// MARK: - ReachabilityProviding

/// Abstraction over "is the network reachable right now", so
/// `GateController.requestOpen()` (bead .4) never has to talk to a concrete
/// reachability framework directly and tests can inject a fake with no real
/// network dependency.
///
/// This is a plain protocol (not an `AsyncStream`) so a caller can both poll
/// the current value (`isReachable`) AND be told about changes
/// (`setOnChange(_:)`), matching the two things `requestOpen()` needs: an
/// immediate check when a request comes in, and a one-shot notification if
/// it has to wait.
///
/// CONTRACT: `setOnChange(_:)` is a SETTER METHOD, not a mutable stored
/// property, specifically so a concrete conformer can be a `final class`
/// that is also `Sendable` under Swift 6 strict concurrency without needing
/// a mutable stored closure property to be independently `Sendable`-checked
/// at every call site — the conformer is free to guard the handler storage
/// internally (e.g. behind a lock or by being main-actor-isolated) rather
/// than exposing it as a directly externally-settable stored property.
///
/// THREADING: the handler passed to `setOnChange(_:)` may be invoked from
/// ANY thread/queue the underlying reachability mechanism happens to use
/// (e.g. `NWPathMonitor`'s dispatch queue) — implementations and callers
/// must never assume main-thread delivery. `GateController` hops to the
/// main actor itself before touching any state in response to a callback;
/// conformers and other callers must do the same.
///
/// Only one handler is retained at a time: a second call to
/// `setOnChange(_:)` replaces the previous handler (it does not add a
/// second listener). Passing `nil` removes the current handler.
public protocol ReachabilityProviding: AnyObject, Sendable {
    /// Whether the network is currently believed to be reachable. Reading
    /// this must be safe from any thread.
    var isReachable: Bool { get }

    /// Installs (or removes, when `handler` is `nil`) the single callback
    /// invoked whenever reachability changes. May be called from any
    /// thread; the handler itself may later be invoked from any thread —
    /// see the type-level THREADING note above.
    func setOnChange(_ handler: (@Sendable (Bool) -> Void)?)
}

// MARK: - AlwaysReachable

/// The default `ReachabilityProviding` conformer: always reports reachable,
/// and never invokes a change handler (there is nothing for it to report).
///
/// Used as `GateController`'s default `reachability` parameter so existing
/// call sites (and existing Mac app behavior/tests) are unaffected by the
/// addition of the offline-queue feature — `requestOpen()` on an
/// `AlwaysReachable`-backed controller behaves exactly like calling
/// `openGate()` in a `Task`, immediately, every time.
public final class AlwaysReachable: ReachabilityProviding, @unchecked Sendable {
    public init() {}

    public var isReachable: Bool { true }

    /// Intentionally a no-op: this conformer's reachability never changes,
    /// so there is nothing to notify a handler about. The handler is not
    /// even retained.
    public func setOnChange(_ handler: (@Sendable (Bool) -> Void)?) {}
}
