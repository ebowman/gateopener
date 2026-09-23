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
    /// The latest `NWPath` delivered to `pathUpdateHandler`, if any --
    /// `nil` before the very first delivery, mirroring `_isReachable`'s own
    /// optimistic-default doc comment. Retained (not just its derived
    /// `Bool`) so `pathDescription` can report interface types/
    /// isExpensive/isConstrained too, for the press journal's
    /// `.reachability(detail:)` phase.
    private var _latestPath: NWPath?
    private var onChangeHandler: (@Sendable (Bool) -> Void)?

    public init() {
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let reachable = path.status == .satisfied
            self.lock.lock()
            self._isReachable = reachable
            self._latestPath = path
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

    /// A free-form, non-secret, human-readable summary of the latest
    /// `NWPath` this monitor has delivered -- e.g. `"satisfied wifi
    /// expensive=false constrained=false"` -- included verbatim in the
    /// press journal's `.reachability(detail:)` phase (see
    /// `OpenPressPhase.reachability`). Never a token/credential/URL.
    ///
    /// Returns `"unknown (monitor just started)"` before the very first
    /// `pathUpdateHandler` delivery, mirroring `isReachable`'s own
    /// optimistic-default doc comment: a fresh instance constructed inline
    /// in `OpenGateIntent.runFlow` has essentially no time to receive that
    /// first update before this is read.
    ///
    /// THREAD-SAFE: reads `_latestPath` under the same `NSLock` that
    /// protects `_isReachable`, so this may be called from any thread, same
    /// as `isReachable`.
    public var pathDescription: String {
        lock.lock()
        let path = _latestPath
        lock.unlock()

        guard let path else {
            return "unknown (monitor just started)"
        }

        let statusDescription: String
        switch path.status {
        case .satisfied:
            statusDescription = "satisfied"
        case .unsatisfied:
            statusDescription = "unsatisfied"
        case .requiresConnection:
            statusDescription = "requiresConnection"
        @unknown default:
            statusDescription = "unknown"
        }

        // `NWInterface.InterfaceType` is not `CaseIterable`, so the checked
        // types are enumerated explicitly here, in a fixed, documented
        // order (matching the STEPS brief: "interface types in order").
        let allInterfaceTypes: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .loopback, .other]
        let interfaceTypes: [String] = allInterfaceTypes.compactMap { type in
            path.usesInterfaceType(type) ? Self.name(for: type) : nil
        }
        let interfacesDescription = interfaceTypes.isEmpty ? "none" : interfaceTypes.joined(separator: ",")

        return "\(statusDescription) \(interfacesDescription) expensive=\(path.isExpensive) constrained=\(path.isConstrained)"
    }

    private static func name(for interfaceType: NWInterface.InterfaceType) -> String {
        switch interfaceType {
        case .wifi:
            return "wifi"
        case .cellular:
            return "cellular"
        case .wiredEthernet:
            return "wiredEthernet"
        case .loopback:
            return "loopback"
        case .other:
            return "other"
        @unknown default:
            return "unknown"
        }
    }
}
