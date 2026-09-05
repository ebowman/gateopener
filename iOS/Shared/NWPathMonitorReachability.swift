import Foundation
import GateOpenerCore
import Network

/// `ReachabilityProviding` conformer backed by `Network.NWPathMonitor`.
///
/// Lives in `iOS/Shared` (compiled into both the app and the widget
/// extension — see `iOS/Shared/README.md`) rather than `iOS/App`, since
/// `Network` is available in both processes and `AppEnvironment.make()`
/// (also `iOS/Shared`) needs a default instance to hand `GateController`.
///
/// THREADING: `NWPathMonitor` delivers `pathUpdateHandler` calls on the
/// `DispatchQueue` passed to `start(queue:)` — a background utility queue
/// here, never the main queue. `isReachable` is read from arbitrary threads
/// (see `ReachabilityProviding`'s THREADING note), so the underlying
/// `Bool` is protected by `NSLock`. The `onChange` handler this class
/// forwards path updates to is itself invoked from that same utility
/// queue, unchanged — `GateController` is responsible for hopping to the
/// main actor before touching its own state, exactly as documented on
/// `ReachabilityProviding`.
public final class NWPathMonitorReachability: ReachabilityProviding, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "ie.boboco.GateOpener.reachability", qos: .utility)

    private let lock = NSLock()
    /// Optimistic default: before the very first `pathUpdateHandler`
    /// delivery, this reports reachable so a cold-start `requestOpen()`
    /// never gets queued purely because `NWPathMonitor` has not yet
    /// delivered its first path — a real offline device will receive an
    /// `unsatisfied` update almost immediately and flip this to `false`.
    private var _isReachable = true
    private var onChangeHandler: (@Sendable (Bool) -> Void)?

    public init() {
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let reachable = path.status == .satisfied
            self.lock.lock()
            self._isReachable = reachable
            let handler = self.onChangeHandler
            self.lock.unlock()
            handler?(reachable)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    public var isReachable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isReachable
    }

    public func setOnChange(_ handler: (@Sendable (Bool) -> Void)?) {
        lock.lock()
        onChangeHandler = handler
        lock.unlock()
    }
}
