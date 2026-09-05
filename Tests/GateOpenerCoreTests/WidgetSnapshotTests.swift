import Foundation
import Testing
@testable import GateOpenerCore

extension WidgetSnapshot.Phase: CaseIterable {
    public static let allCases: [WidgetSnapshot.Phase] = [
        .needsSetup, .idle, .queued, .opening, .succeeded, .failed,
    ]
}

/// Tests for `WidgetSnapshot` and `WidgetSnapshotStore`. Each test uses a
/// UNIQUE `UserDefaults(suiteName:)` (via a UUID) and removes the suite in
/// teardown, so tests never pollute the real app domain, the shared app
/// group domain, or each other, and so no stray plists accumulate in
/// `~/Library/Preferences` (see the vacuous-assertion / stray-plist memory).
struct WidgetSnapshotTests {
    /// Creates a throwaway UserDefaults suite and returns it along with a
    /// closure that removes it. Callers should `defer { cleanup() }`.
    private func makeSuite() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "ie.boboco.GateOpener.test.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create UserDefaults suite for testing")
        }
        let cleanup = {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, cleanup)
    }

    // MARK: - Round trip, every phase

    @Test("write/read round-trips every phase", arguments: WidgetSnapshot.Phase.allCases)
    func roundTripsEveryPhase(phase: WidgetSnapshot.Phase) {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let store = WidgetSnapshotStore(defaults: defaults)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let message = phase == .failed ? "network error" : nil
        let snapshot = WidgetSnapshot(gateName: "Front Gate", phase: phase, message: message, updatedAt: date)

        store.write(snapshot)
        let read = store.read()

        #expect(read == snapshot)
        #expect(read?.phase == phase)
        #expect(read?.message == message)
        #expect(read?.gateName == "Front Gate")
        #expect(read?.updatedAt == date)
    }

    // MARK: - from(state:) mapping, every GateState case

    @Test func fromStateMapsNeedsSetup() {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let snapshot = WidgetSnapshot.from(state: .needsSetup, gateName: "Front Gate", now: now)
        #expect(snapshot.phase == .needsSetup)
        #expect(snapshot.message == nil)
        #expect(snapshot.gateName == "Front Gate")
        #expect(snapshot.updatedAt == now)
    }

    @Test func fromStateMapsIdle() {
        let now = Date(timeIntervalSince1970: 1_700_000_101)
        let snapshot = WidgetSnapshot.from(state: .idle, gateName: "Front Gate", now: now)
        #expect(snapshot.phase == .idle)
        #expect(snapshot.message == nil)
        #expect(snapshot.updatedAt == now)
    }

    @Test func fromStateMapsQueued() {
        let now = Date(timeIntervalSince1970: 1_700_000_102)
        let snapshot = WidgetSnapshot.from(state: .queued, gateName: "Front Gate", now: now)
        #expect(snapshot.phase == .queued)
        #expect(snapshot.message == nil)
        #expect(snapshot.updatedAt == now)
    }

    @Test func fromStateMapsOpening() {
        let now = Date(timeIntervalSince1970: 1_700_000_103)
        let snapshot = WidgetSnapshot.from(state: .opening, gateName: "Front Gate", now: now)
        #expect(snapshot.phase == .opening)
        #expect(snapshot.message == nil)
        #expect(snapshot.updatedAt == now)
    }

    @Test func fromStateMapsSucceededWithNilMessage() {
        let now = Date(timeIntervalSince1970: 1_700_000_104)
        let succeededAt = Date(timeIntervalSince1970: 1_699_999_999)
        let snapshot = WidgetSnapshot.from(state: .succeeded(at: succeededAt), gateName: "Front Gate", now: now)
        #expect(snapshot.phase == .succeeded)
        #expect(snapshot.message == nil)
        // `updatedAt` must be `now` (when the snapshot was captured), not the
        // `succeeded(at:)` associated value.
        #expect(snapshot.updatedAt == now)
    }

    @Test func fromStateMapsFailedCarryingMessage() {
        let now = Date(timeIntervalSince1970: 1_700_000_105)
        let snapshot = WidgetSnapshot.from(state: .failed(message: "network error"), gateName: "Front Gate", now: now)
        #expect(snapshot.phase == .failed)
        #expect(snapshot.message == "network error")
        #expect(snapshot.updatedAt == now)
    }

    // MARK: - Corrupt / missing data

    @Test func readReturnsNilForCorruptData() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let store = WidgetSnapshotStore(defaults: defaults)
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF, 0x10, 0x20])
        defaults.set(garbage, forKey: WidgetSnapshotStore.defaultKey)

        #expect(store.read() == nil)
    }

    @Test func readReturnsNilForEmptySuite() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let store = WidgetSnapshotStore(defaults: defaults)

        #expect(store.read() == nil)
    }

    // MARK: - Wire format pin: ISO-8601 date

    @Test func persistedJSONEncodesUpdatedAtAsISO8601String() throws {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let store = WidgetSnapshotStore(defaults: defaults)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = WidgetSnapshot(gateName: "Front Gate", phase: .idle, message: nil, updatedAt: date)
        store.write(snapshot)

        let data = try #require(defaults.data(forKey: WidgetSnapshotStore.defaultKey))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let updatedAt = try #require(json["updatedAt"] as? String)

        // Pins the cross-process wire format: this MUST be a string
        // containing "T" (the ISO-8601 date/time separator), not a raw
        // timestamp number. If this ever regresses to `.deferredToDate` (a
        // Double) or `.secondsSince1970`, the widget's decoder (which also
        // expects `.iso8601`) would fail to decode it.
        #expect(updatedAt.contains("T"))
    }
}
