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

    // MARK: - (41m.2) open-attempt journal wiring

    /// Builds a throwaway temp-directory file URL (never the real App Group
    /// container) for one test, plus a cleanup closure that removes the
    /// enclosing directory afterwards.
    private func makeTempJournalURL(function: String = #function) -> (url: URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppEnvironmentTests-\(function)-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("open-attempts.jsonl")
        return (url, { try? FileManager.default.removeItem(at: directory) })
    }

    /// When `make()` is given an injectable journal URL AND builds a REAL
    /// (non-injected) `GateClient` -- i.e. `gateClient:` is left `nil`, the
    /// production path -- it must wire an `OpenAttemptJournal` at that URL
    /// and expose it as `environment.openAttemptJournal`, so the app AND the
    /// widget/App-Intent extension process can both read/write the same
    /// history (`OpenGateIntent.runFlow` calls this exact `make()`).
    ///
    /// MUTATION CHECK: removing the `OpenAttemptJournal(fileURL:)`
    /// construction (or failing to pass it as `GateClient`'s
    /// `attemptObserver:`) in `AppEnvironment.make()` makes
    /// `environment.openAttemptJournal` nil here, failing this test.
    @Test func makeWiresOpenAttemptJournalWhenURLProvidedAndGateClientIsReal() {
        let (defaults, cleanupDefaults) = makeInMemoryDefaults()
        defer { cleanupDefaults() }
        let (journalURL, cleanupJournal) = makeTempJournalURL()
        defer { cleanupJournal() }

        let environment = AppEnvironment.make(
            defaults: defaults,
            reachability: FakeReachabilityProviding(isReachable: true),
            timelineReloader: {},
            openAttemptJournalURL: journalURL
        )

        #expect(environment.openAttemptJournal != nil)
        #expect(environment.openAttemptJournal?.fileURL == journalURL)
    }

    /// The `--mock-gate` debug seam (a non-nil `gateClient:` override) must
    /// leave `openAttemptJournal` `nil` even when a journal URL is
    /// available: the fake `GateOpening` never calls an `attemptObserver`,
    /// so a journal built in that branch would sit unused, and exposing a
    /// non-nil `openAttemptJournal` there would misleadingly imply it is
    /// being written to.
    @Test func makeLeavesOpenAttemptJournalNilWhenGateClientIsInjected() {
        let (defaults, cleanupDefaults) = makeInMemoryDefaults()
        defer { cleanupDefaults() }
        let (journalURL, cleanupJournal) = makeTempJournalURL()
        defer { cleanupJournal() }

        let environment = AppEnvironment.make(
            defaults: defaults,
            reachability: FakeReachabilityProviding(isReachable: true),
            timelineReloader: {},
            gateClient: FakeGateOpening(),
            tokenResolver: FakeTokenResolving(),
            openAttemptJournalURL: journalURL
        )

        #expect(environment.openAttemptJournal == nil)
    }

    /// When no journal URL is injectable at all (the double-optional
    /// `nil` case meaning "no override provided" is itself not exercisable
    /// without touching the real App Group container, so this test instead
    /// proves the explicit-nil-override path: passing `.some(nil)` for
    /// `openAttemptJournalURL` must also leave `openAttemptJournal` nil,
    /// mirroring "container unavailable" without touching
    /// `SharedContainer.openAttemptJournalURL()`.
    @Test func makeLeavesOpenAttemptJournalNilWhenURLOverrideIsExplicitlyNil() {
        let (defaults, cleanupDefaults) = makeInMemoryDefaults()
        defer { cleanupDefaults() }

        let environment = AppEnvironment.make(
            defaults: defaults,
            reachability: FakeReachabilityProviding(isReachable: true),
            timelineReloader: {},
            openAttemptJournalURL: .some(nil)
        )

        #expect(environment.openAttemptJournal == nil)
    }

    // MARK: - (41m.23) journal capacity raised to 1000 in production wiring

    /// `make()`'s production journal wiring passes `capacity: 1000` (Core's
    /// own default, used when a caller constructs `OpenAttemptJournal`
    /// directly, stays 200) — since bead gateopener-41m.22 the journal's
    /// capacity counts PRESS lines too (~6-8 per press), so the original
    /// 200-line default would only retain roughly the last 25-30 presses.
    ///
    /// MUTATION CHECK: reverting `AppEnvironment.make()`'s
    /// `OpenAttemptJournal(fileURL:capacity:)` call back to the
    /// default-`capacity` initializer makes `environment.openAttemptJournal
    /// ?.capacity` read `200` instead of `1000`, failing this test.
    @Test func makeWiresOpenAttemptJournalWithCapacityOneThousand() {
        let (defaults, cleanupDefaults) = makeInMemoryDefaults()
        defer { cleanupDefaults() }
        let (journalURL, cleanupJournal) = makeTempJournalURL()
        defer { cleanupJournal() }

        let environment = AppEnvironment.make(
            defaults: defaults,
            reachability: FakeReachabilityProviding(isReachable: true),
            timelineReloader: {},
            openAttemptJournalURL: journalURL
        )

        #expect(environment.openAttemptJournal?.capacity == 1000)
    }
}
