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
}
