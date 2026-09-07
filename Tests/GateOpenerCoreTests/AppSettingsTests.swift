import Foundation
import Testing
@testable import GateOpenerCore

/// Tests for `AppSettings`. Each test uses a UNIQUE `UserDefaults(suiteName:)`
/// (via a UUID) and removes the suite in teardown, so tests never pollute the
/// real app domain or interfere with each other.
struct AppSettingsTests {
    /// Creates a throwaway UserDefaults suite and returns it along with a
    /// closure that removes it. Callers should `defer { cleanup() }`.
    private func makeSuite() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "ie.boboco.GateOpener.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create UserDefaults suite for testing")
        }
        let cleanup = {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, cleanup)
    }

    @Test func roundTripsAllProperties() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        settings.aptId = "apt-123"
        settings.selectedEndpointId = "endpoint-456"
        settings.selectedEndpointName = "Front Gate"
        settings.lastDiscoveryDate = date

        #expect(settings.aptId == "apt-123")
        #expect(settings.selectedEndpointId == "endpoint-456")
        #expect(settings.selectedEndpointName == "Front Gate")
        #expect(settings.lastDiscoveryDate == date)
    }

    @Test func isConfiguredFalseWhenSelectedEndpointIdIsNil() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        settings.aptId = "apt-123"
        settings.selectedEndpointId = nil

        #expect(!settings.isConfigured)
    }

    @Test func isConfiguredFalseWhenSelectedEndpointIdIsEmptyString() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        settings.selectedEndpointId = ""

        #expect(!settings.isConfigured)
    }

    @Test func isConfiguredTrueWhenSelectedEndpointIdSetEvenWithoutAptId() {
        // Encodes the resolved ambiguity: aptId is optional/vestigial and
        // discovery works without it, so isConfigured must not require it.
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        settings.aptId = nil
        settings.selectedEndpointId = "endpoint-456"

        #expect(settings.isConfigured)
    }

    @Test func resetClearsOwnedKeysButNotUnrelatedKeys() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        settings.aptId = "apt-123"
        settings.selectedEndpointId = "endpoint-456"
        settings.selectedEndpointName = "Front Gate"
        settings.lastDiscoveryDate = Date()

        let unrelatedKey = "ie.boboco.GateOpener.tests.unrelated"
        defaults.set("keep-me", forKey: unrelatedKey)

        settings.reset()

        #expect(settings.aptId == nil)
        #expect(settings.selectedEndpointId == nil)
        #expect(settings.selectedEndpointName == nil)
        #expect(settings.lastDiscoveryDate == nil)
        #expect(defaults.string(forKey: unrelatedKey) == "keep-me")
    }

    @Test func showOpenConfirmationOverlayDefaultsToTrueWhenUnset() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)

        #expect(settings.showOpenConfirmationOverlay)
    }

    @Test func showOpenConfirmationOverlaySetFalseReadsFalseOnSameInstance() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        settings.showOpenConfirmationOverlay = false

        #expect(!settings.showOpenConfirmationOverlay)
    }

    @Test func showOpenConfirmationOverlaySetFalsePersistsAcrossNewInstance() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settingsA = AppSettings(defaults: defaults)
        settingsA.showOpenConfirmationOverlay = false

        let settingsB = AppSettings(defaults: defaults)
        #expect(!settingsB.showOpenConfirmationOverlay)
    }

    @Test func showOpenConfirmationOverlaySetTruePersists() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        settings.showOpenConfirmationOverlay = false
        settings.showOpenConfirmationOverlay = true

        #expect(settings.showOpenConfirmationOverlay)

        let settingsB = AppSettings(defaults: defaults)
        #expect(settingsB.showOpenConfirmationOverlay)
    }

    @Test func autoShowDoorVideoOnOpenDefaultsToTrueWhenUnset() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)

        #expect(settings.autoShowDoorVideoOnOpen)
    }

    @Test func autoShowDoorVideoOnOpenSetFalseReadsFalseOnSameInstance() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        settings.autoShowDoorVideoOnOpen = false

        #expect(!settings.autoShowDoorVideoOnOpen)
    }

    @Test func autoShowDoorVideoOnOpenSetFalsePersistsAcrossNewInstance() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settingsA = AppSettings(defaults: defaults)
        settingsA.autoShowDoorVideoOnOpen = false

        let settingsB = AppSettings(defaults: defaults)
        #expect(!settingsB.autoShowDoorVideoOnOpen)
    }

    @Test func autoShowDoorVideoOnOpenSetTruePersists() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        settings.autoShowDoorVideoOnOpen = false
        settings.autoShowDoorVideoOnOpen = true

        #expect(settings.autoShowDoorVideoOnOpen)

        let settingsB = AppSettings(defaults: defaults)
        #expect(settingsB.autoShowDoorVideoOnOpen)
    }

    @Test func allowOpenWhileLockedDefaultsToTrueWhenUnset() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)

        #expect(settings.allowOpenWhileLocked)
    }

    @Test func allowOpenWhileLockedSetFalseReadsFalseOnSameInstance() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        settings.allowOpenWhileLocked = false

        #expect(!settings.allowOpenWhileLocked)
    }

    @Test func allowOpenWhileLockedSetFalsePersistsAcrossNewInstance() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settingsA = AppSettings(defaults: defaults)
        settingsA.allowOpenWhileLocked = false

        let settingsB = AppSettings(defaults: defaults)
        #expect(!settingsB.allowOpenWhileLocked)
    }

    @Test func allowOpenWhileLockedSetTruePersists() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        settings.allowOpenWhileLocked = false
        settings.allowOpenWhileLocked = true

        #expect(settings.allowOpenWhileLocked)

        let settingsB = AppSettings(defaults: defaults)
        #expect(settingsB.allowOpenWhileLocked)
    }

    @Test func resetRestoresAllowOpenWhileLockedDefault() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        settings.allowOpenWhileLocked = false

        // Mutation check: confirm the value is actually false BEFORE
        // reset(), so the post-reset assertion below is proven to
        // distinguish "reset restored the default" from "it was never
        // changed".
        #expect(!settings.allowOpenWhileLocked)

        settings.reset()

        #expect(settings.allowOpenWhileLocked)
    }

    @Test func twoInstancesOverSameSuiteSeeEachOthersWrites() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settingsA = AppSettings(defaults: defaults)
        let settingsB = AppSettings(defaults: defaults)

        settingsA.selectedEndpointId = "endpoint-789"
        settingsA.selectedEndpointName = "Back Gate"

        #expect(settingsB.selectedEndpointId == "endpoint-789")
        #expect(settingsB.selectedEndpointName == "Back Gate")

        settingsB.aptId = "apt-999"
        #expect(settingsA.aptId == "apt-999")
    }

    // MARK: - cachedGates (bead gateopener-672.10)

    @Test func cachedGatesRoundTrips() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        let gates = [
            Endpoint(endpointId: "id-1", friendlyName: "Front Gate", capabilities: ["PowerController"], displayCategories: ["LOCK_GENERIC"]),
            Endpoint(endpointId: "id-2", friendlyName: "Side Door", capabilities: ["PowerController"], displayCategories: ["LOCK_GENERIC"]),
        ]

        settings.cachedGates = gates

        #expect(settings.cachedGates == gates)

        // A second instance over the same suite must see the same value —
        // proves this is actually persisted to `defaults`, not just held
        // in an in-memory property (mutation check: an in-memory-only
        // implementation would fail this second assertion).
        let settingsB = AppSettings(defaults: defaults)
        #expect(settingsB.cachedGates == gates)
    }

    @Test func cachedGatesIsEmptyWhenAbsent() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)

        #expect(settings.cachedGates == [])
    }

    @Test func cachedGatesIsEmptyWhenStoredDataIsCorrupt() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        // Write garbage bytes directly under the same key `cachedGates`
        // uses, bypassing the property setter, to simulate a corrupt or
        // foreign-format stored value.
        defaults.set(Data([0xDE, 0xAD, 0xBE, 0xEF]), forKey: "ie.boboco.GateOpener.cachedGates")

        #expect(settings.cachedGates == [])
    }

    @Test func resetClearsCachedGates() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        let gates = [Endpoint(endpointId: "id-1", friendlyName: "Front Gate")]
        settings.cachedGates = gates

        // Mutation check: confirm the value is actually non-empty BEFORE
        // reset(), so the post-reset assertion below is proven to
        // distinguish "reset cleared it" from "it was already empty".
        #expect(!settings.cachedGates.isEmpty)

        settings.reset()

        #expect(settings.cachedGates == [])
    }
}
