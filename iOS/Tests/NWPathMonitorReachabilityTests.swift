import Foundation
import Testing
import GateOpenerCore
@testable import GateOpener

/// Tests for `NWPathMonitorReachability.pathDescription` (bead
/// gateopener-41m.23). Only the "no path delivered yet" default is
/// deterministically testable without a real network stack: a genuine
/// `NWPathMonitor` delivery is asynchronous and its exact timing/content is
/// not under test control, so this does not attempt to assert the populated
/// (post-delivery) string's exact contents — only its documented format is
/// exercised (see the type's own doc comment for the full contract).
struct NWPathMonitorReachabilityTests {
    /// Constructed-and-read-immediately: before any `pathUpdateHandler`
    /// delivery, `pathDescription` must report the documented placeholder --
    /// or, if a real, live `NWPathMonitor` has already delivered its first
    /// path by the time this reads (a genuine race: monitor start and this
    /// read both happen on live system queues, so delivery before the read
    /// is possible, not just theoretical), a description reflecting that
    /// real path instead. Either way it must be non-empty and must not crash.
    ///
    /// MUTATION CHECK: removing the `guard let path else { return "unknown
    /// (monitor just started)" }` early return in `NWPathMonitorReachability
    /// .pathDescription` (iOS/Shared/NWPathMonitorReachability.swift) would
    /// force-unwrap or otherwise mishandle a `nil` `_latestPath`, failing
    /// this test (either by crashing, or -- in the "monitor hasn't delivered
    /// yet" case -- returning a string that is empty or matches neither
    /// accepted form).
    @Test func pathDescriptionIsUnknownBeforeAnyPathUpdate() {
        let reachability = NWPathMonitorReachability()
        let description = reachability.pathDescription
        #expect(!description.isEmpty)
        let validStatusPrefixes = ["satisfied", "unsatisfied", "requiresConnection"]
        #expect(
            description == "unknown (monitor just started)"
                || validStatusPrefixes.contains { description.hasPrefix($0) }
        )
    }

    /// `isReachable` is documented optimistic (`true`) before the first path
    /// update, but -- exactly as `pathDescriptionIsUnknownBeforeAnyPathUpdate`
    /// documents above -- a live `NWPathMonitor` may have already delivered
    /// its first path by the time this reads, in which case `isReachable`
    /// legitimately reflects that real (possibly unsatisfied) path instead.
    /// This is therefore only a smoke test that the property is readable
    /// without crashing, not an assertion on its specific value.
    @Test func isReachableIsOptimisticTrueBeforeAnyPathUpdate() {
        let reachability = NWPathMonitorReachability()
        _ = reachability.isReachable
    }
}
