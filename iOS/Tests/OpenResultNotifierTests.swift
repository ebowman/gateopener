import Foundation
import Testing
import UserNotifications
import GateOpenerCore
@testable import GateOpener

private final class FakeCenter: NotificationCentering, @unchecked Sendable {
    var status: UNAuthorizationStatus = .authorized
    var requested: [UNAuthorizationOptions] = []
    var categories: Set<UNNotificationCategory> = []
    var added: [UNNotificationRequest] = []

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requested.append(options)
        return true
    }
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) { self.categories = categories }
    func add(_ request: UNNotificationRequest) async throws { added.append(request) }
}

private func makeSettings() -> (AppSettings, () -> Void) {
    let name = "OpenResultNotifierTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (AppSettings(defaults: defaults), { defaults.removePersistentDomain(forName: name) })
}

@Suite struct OpenResultNotifierTests {
    @Test func failureContent() async {
        let (settings, cleanup) = makeSettings(); defer { cleanup() }
        let center = FakeCenter()
        let notifier = OpenResultNotifier(settings: settings, center: center)
        let pressed = Date(timeIntervalSince1970: 1_700_000_000)

        await notifier.postFailure(gateName: "Main gate", message: "No network", pressedAt: pressed)

        #expect(center.added.count == 1)
        let content = center.added[0].content
        #expect(content.title == "Gate didn't open")
        #expect(content.body == "No network — tap Retry to try again")
        #expect(content.subtitle == "Main gate")
        #expect(content.categoryIdentifier == OpenResultNotifier.failureCategoryIdentifier)
        #expect(content.userInfo[OpenResultNotifier.pressedAtUserInfoKey] as? Double == 1_700_000_000)
        #expect(content.interruptionLevel == .active)
        #expect(content.sound != nil && content.sound != .default)
    }

    @Test func unconfirmedContent() async {
        let (settings, cleanup) = makeSettings(); defer { cleanup() }
        let center = FakeCenter()
        let notifier = OpenResultNotifier(settings: settings, center: center)
        let pressed = Date(timeIntervalSince1970: 1_700_000_000)

        await notifier.postUnconfirmed(gateName: "Main gate", pressedAt: pressed)

        #expect(center.added.count == 1)
        #expect(center.added[0].identifier == OpenResultNotifier.notificationIdentifier)
        let content = center.added[0].content
        #expect(content.title == "Couldn't confirm gate opened")
        #expect(content.body == "No response in time — tap Retry if the gate is still closed")
        #expect(content.subtitle == "Main gate")
        #expect(content.categoryIdentifier == OpenResultNotifier.failureCategoryIdentifier)
        #expect(content.userInfo[OpenResultNotifier.pressedAtUserInfoKey] as? Double == 1_700_000_000)
        #expect(content.interruptionLevel == .active)
        #expect(content.sound != nil && content.sound != .default)
    }

    @Test func failureWithoutGateNameHasNoSubtitle() async {
        let (settings, cleanup) = makeSettings(); defer { cleanup() }
        let center = FakeCenter()
        await OpenResultNotifier(settings: settings, center: center)
            .postFailure(gateName: nil, message: "x", pressedAt: Date())
        #expect(center.added[0].content.subtitle == "")
    }

    @Test func categoryHasSingleRetryActionWithEmptyOptions() {
        let (settings, cleanup) = makeSettings(); defer { cleanup() }
        let center = FakeCenter()
        OpenResultNotifier(settings: settings, center: center).registerCategories()

        #expect(center.categories.count == 2)
        let category = center.categories.first { $0.identifier == OpenResultNotifier.failureCategoryIdentifier }!
        #expect(category.identifier == "ie.boboco.GateOpener.openFailed")
        #expect(category.actions.count == 1)
        #expect(category.actions[0].identifier == "ie.boboco.GateOpener.retryOpen")
        #expect(category.actions[0].title == "Retry")
        #expect(category.actions[0].options.isEmpty)
    }

    @Test func resultsShareOneIdentifierSoTheyReplace() async {
        let (settings, cleanup) = makeSettings(); defer { cleanup() }
        let center = FakeCenter()
        let notifier = OpenResultNotifier(settings: settings, center: center)

        await notifier.postFailure(gateName: nil, message: "x", pressedAt: Date())
        await notifier.postSuccess(gateName: "Main gate")

        #expect(center.added.count == 2)
        #expect(center.added[0].identifier == OpenResultNotifier.notificationIdentifier)
        #expect(center.added[1].identifier == OpenResultNotifier.notificationIdentifier)
        let success = center.added[1].content
        #expect(success.title == "Open command accepted")
        #expect(success.sound == .default)
        #expect(success.categoryIdentifier == "")
        #expect(success.interruptionLevel == .active)
    }

    @Test func successIsGatedByTheSettingButFailureIsNot() async {
        let (settings, cleanup) = makeSettings(); defer { cleanup() }
        settings.notifyOnOpenSuccess = false
        let center = FakeCenter()
        let notifier = OpenResultNotifier(settings: settings, center: center)

        await notifier.postSuccess(gateName: nil)
        #expect(center.added.isEmpty)

        await notifier.postFailure(gateName: nil, message: "x", pressedAt: Date())
        #expect(center.added.count == 1)
    }

    @Test func postsAreNoOpsWhenUnauthorized() async {
        let (settings, cleanup) = makeSettings(); defer { cleanup() }
        let center = FakeCenter()
        center.status = .denied
        let notifier = OpenResultNotifier(settings: settings, center: center)

        await notifier.postFailure(gateName: nil, message: "x", pressedAt: Date())
        await notifier.postSuccess(gateName: nil)
        #expect(center.added.isEmpty)
    }

    @Test func authorizationRequestedOnlyWhenNotDetermined() async {
        let (settings, cleanup) = makeSettings(); defer { cleanup() }
        let center = FakeCenter()
        let notifier = OpenResultNotifier(settings: settings, center: center)

        center.status = .denied
        await notifier.requestAuthorizationIfNeeded()
        center.status = .authorized
        await notifier.requestAuthorizationIfNeeded()
        #expect(center.requested.isEmpty)

        center.status = .notDetermined
        await notifier.requestAuthorizationIfNeeded()
        #expect(center.requested == [[.alert, .sound]])
    }

    /// Dropping the per-reason body (or using one wording) fails one of the three.
    @Test func needsSetupBodiesPerReason() async {
        let expected: [(NeedsSetupReason, String)] = [
            (.credentialsUnreadable, "Unlock your iPhone and try again"),
            (.noGateSelected, "Open GateOpener to finish setup"),
            (.signedOut, "Open GateOpener and sign in"),
        ]
        for (reason, body) in expected {
            let (settings, cleanup) = makeSettings(); defer { cleanup() }
            let center = FakeCenter()
            let notifier = OpenResultNotifier(settings: settings, center: center)
            await notifier.postNeedsSetup(reason: reason)
            #expect(center.added.count == 1)
            #expect(center.added[0].identifier == OpenResultNotifier.notificationIdentifier)
            #expect(center.added[0].content.title == "GateOpener couldn't open the gate")
            #expect(center.added[0].content.body == body)
            #expect(center.added[0].content.categoryIdentifier == OpenResultNotifier.needsSetupCategoryIdentifier)
        }
    }

    /// Reusing the failure category would add Retry; this fails then.
    @Test func needsSetupCategoryHasNoRetryAction() {
        let category = OpenResultNotifier.makeNeedsSetupCategory()
        #expect(category.actions.isEmpty)
        #expect(!category.actions.contains { $0.identifier == OpenResultNotifier.retryActionIdentifier })
        // And the failure category still has Retry (guards the vacuous case).
        #expect(OpenResultNotifier.makeFailureCategory().actions.map(\.identifier) == [OpenResultNotifier.retryActionIdentifier])
    }

    /// Without registering the needs-setup category the system drops it.
    @Test func registerCategoriesIncludesNeedsSetupCategory() {
        let (settings, cleanup) = makeSettings(); defer { cleanup() }
        let center = FakeCenter()
        OpenResultNotifier(settings: settings, center: center).registerCategories()
        #expect(center.categories.map(\.identifier).sorted() == [
            OpenResultNotifier.failureCategoryIdentifier, OpenResultNotifier.needsSetupCategoryIdentifier,
        ].sorted())
    }

    @Test func needsSetupIsNoOpWhenUnauthorized() async {
        let (settings, cleanup) = makeSettings(); defer { cleanup() }
        let center = FakeCenter()
        center.status = .denied
        await OpenResultNotifier(settings: settings, center: center).postNeedsSetup(reason: .signedOut)
        #expect(center.added.isEmpty)
    }
}
