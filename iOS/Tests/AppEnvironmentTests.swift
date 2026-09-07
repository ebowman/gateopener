import Foundation
import Testing
import GateOpenerCore
@testable import GateOpener

/// Tests for `AppEnvironment` (bead gateopener-672.18): the construction-time
/// snapshot publish, and the pure `keychainAccessibility(allowWhileLocked:)`
/// mapping. Every test uses an in-memory `UserDefaults` suite — never the
/// real shared app-group suite or the real Keychain access group.
@MainActor
struct AppEnvironmentTests {
    // MARK: - (d) make() publishes a needsSetup snapshot at construction

    /// A fresh `AppEnvironment.make()` (no stored credentials, no selected
    /// gate) starts `.needsSetup`, and `make()` publishes exactly that
    /// state as a `WidgetSnapshot` at construction — BEFORE any state
    /// change ever fires — so the widget shows something sane immediately
    /// after a fresh install.
    ///
    /// MUTATION CHECK: removing the `environment.publishSnapshot()` call in
    /// `AppEnvironment.make()` (iOS/Shared/AppEnvironment.swift, just after
    /// the `AppEnvironment(...)` initializer call) makes
    /// `WidgetSnapshotStore(defaults:).read()` return `nil` instead of a
    /// `.needsSetup` snapshot — this test then fails on the `#expect(read
    /// != nil)` and phase assertions below.
    @Test func makeWritesNeedsSetupSnapshotAtConstruction() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        _ = AppEnvironment.make(
            defaults: defaults,
            reachability: FakeReachabilityProviding(isReachable: true),
            timelineReloader: {},
            gateClient: FakeGateOpening(),
            tokenResolver: FakeTokenResolving()
        )

        let store = WidgetSnapshotStore(defaults: defaults)
        let snapshot = store.read()
        #expect(snapshot != nil)
        #expect(snapshot?.phase == .needsSetup)
    }

    // MARK: - (d) keychainAccessibility(allowWhileLocked:) mapping

    /// MUTATION CHECK: swapping the ternary branches in
    /// `AppEnvironment.keychainAccessibility(allowWhileLocked:)`
    /// (iOS/Shared/AppEnvironment.swift) — i.e. returning
    /// `.whenUnlockedThisDeviceOnly` for `true` and
    /// `.afterFirstUnlockThisDeviceOnly` for `false` — flips both
    /// assertions below to failing.
    @Test func keychainAccessibilityMapsAllowWhileLockedTrueToAfterFirstUnlock() {
        #expect(AppEnvironment.keychainAccessibility(allowWhileLocked: true) == .afterFirstUnlockThisDeviceOnly)
    }

    @Test func keychainAccessibilityMapsAllowWhileLockedFalseToWhenUnlocked() {
        #expect(AppEnvironment.keychainAccessibility(allowWhileLocked: false) == .whenUnlockedThisDeviceOnly)
    }
}
