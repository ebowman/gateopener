import Foundation
import UserNotifications
import os
import GateOpenerCore

/// Posts a user notification when the gate genuinely fails to open, so the
/// operator finds out even if they are not looking at the menu bar.
///
/// Deliberately narrow: this type only reacts to `.failed`. It never posts
/// on `.succeeded` (success is conveyed by the icon alone — see the bead
/// brief) and never posts on `.opening`/`.idle`/`.needsSetup`.
///
/// Notification authorization is requested LAZILY, on the first `.failed`
/// state this presenter observes — not at app launch, so a user who never
/// experiences a failure is never interrupted with a permission prompt. If
/// the user denies authorization, this type degrades silently: it never
/// throws, never blocks the open path (it is purely a downstream observer
/// of state changes, never in the call chain of `openGate()` itself), and
/// never re-prompts in a loop — `UNUserNotificationCenter` itself will not
/// re-show the system prompt once a user has answered it, and this type
/// does not attempt to work around that.
///
/// `UNUserNotificationCenter` itself is resolved LAZILY too, and ONLY after
/// confirming `Bundle.main.bundleIdentifier != nil`. `UNUserNotificationCenter
/// .current()` raises an uncatchable `NSException` (NOT a Swift `Error` —
/// `try`/`catch` cannot intercept it) when the running process has no
/// bundle identifier, which is exactly the case for a plain SwiftPM
/// executable (`swift run` / `.build/debug/GateOpener`, and this app's own
/// self-test). Resolving `.current()` eagerly at `init` — which runs during
/// `applicationDidFinishLaunching`, before any failure has occurred — used
/// to crash every unbundled launch outright. The guard here treats "no
/// bundle identifier" exactly like "user denied authorization": a silent,
/// permanent degrade to icon-only feedback, never attempted again.
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    /// Identifier for the "Retry" notification action, and the category
    /// that action is registered under.
    static let retryActionIdentifier = "com.gateopener.retry"
    static let failureCategoryIdentifier = "com.gateopener.gateFailure"

    /// Privacy-preserving logger for anything this type sends to the
    /// system log. No secret is ever passed to any log call here (there is
    /// nothing secret in this type's data at all: state, a short
    /// human-readable failure message, and boolean authorization results).
    private static let logger = Logger(subsystem: "com.gateopener", category: "notifications")

    /// Supplies the notification center to use once it is actually needed.
    /// Defaults to `UNUserNotificationCenter.current()`; injectable for
    /// tests that want to substitute a fake (headless test environments
    /// generally cannot obtain real authorization at all — see the
    /// type-level doc comment). This closure is never invoked unless
    /// `Bundle.main.bundleIdentifier != nil` — see `resolveCenterIfPossible()`.
    private let centerProvider: () -> UNUserNotificationCenter
    private let retryHandler: () -> Void

    /// Lazily-resolved notification center. `nil` until the first time it
    /// is needed (category registration or a `.failed` state), and stays
    /// `nil` forever on an unbundled process — see `resolveCenterIfPossible()`.
    private var center: UNUserNotificationCenter?

    /// Set once `resolveCenterIfPossible()` has run, so repeated `.failed`
    /// states on an unbundled process don't repeatedly re-check
    /// `Bundle.main.bundleIdentifier` (cheap, but this keeps the intent
    /// explicit: the no-bundle degrade is permanent for this process).
    private var hasAttemptedCenterResolution = false

    /// Tracks whether authorization has already been requested this
    /// process lifetime, so a second/third failure never re-prompts even
    /// if the first request is somehow still resolving or was denied.
    private var hasRequestedAuthorization = false

    /// - Parameters:
    ///   - center: closure producing the notification center to use,
    ///     invoked at most once, lazily, and only when
    ///     `Bundle.main.bundleIdentifier != nil`. Defaults to
    ///     `UNUserNotificationCenter.current()`.
    ///   - retryHandler: invoked on the main actor when the user activates
    ///     the notification's "Retry" action.
    init(
        center: @escaping () -> UNUserNotificationCenter = { .current() },
        retryHandler: @escaping () -> Void
    ) {
        self.centerProvider = center
        self.retryHandler = retryHandler
        super.init()
        // Deliberately NOT calling registerCategory() here: that would
        // touch UNUserNotificationCenter at init time again, reintroducing
        // the crash this type exists to avoid. Category registration (and
        // delegate assignment, for the "Retry" action) is deferred to the
        // first successful lazy resolution instead.
    }

    /// Resolves `center` on first use, guarding on
    /// `Bundle.main.bundleIdentifier != nil` BEFORE touching
    /// `UNUserNotificationCenter` at all. On a process with no bundle
    /// identifier, `UNUserNotificationCenter.current()` raises an
    /// uncatchable `NSException` — this guard exists to PREVENT that call
    /// from ever happening, not to recover from it (recovery is not
    /// possible; `try`/`catch` cannot catch an `NSException`).
    ///
    /// Returns `nil` (permanently, for this process) when there is no
    /// bundle identifier, which callers treat identically to "user denied
    /// authorization": silent degrade to icon-only feedback.
    private func resolveCenterIfPossible() -> UNUserNotificationCenter? {
        if let center { return center }
        guard !hasAttemptedCenterResolution else { return nil }
        hasAttemptedCenterResolution = true

        guard Bundle.main.bundleIdentifier != nil else {
            Self.logger.notice("no bundle identifier for this process; degrading to icon-only feedback")
            return nil
        }

        let resolved = centerProvider()
        center = resolved
        registerCategory(on: resolved)
        // Register self as the delegate so `handleRetryAction()` (invoked
        // from `userNotificationCenter(_:didReceive:withCompletionHandler:)`
        // below) can actually fire when the user activates the "Retry"
        // action. Deferred to here (not `init`) for the same reason
        // category registration is: this is only reached once
        // `Bundle.main.bundleIdentifier != nil` has already been
        // confirmed, so it never touches `UNUserNotificationCenter` on an
        // unbundled process.
        resolved.delegate = self
        return resolved
    }

    /// Intended to be assigned (or chained) onto
    /// `GateController.onStateChange`. Only `.failed` states result in a
    /// notification; every other state is a silent no-op.
    func handle(_ state: GateState) {
        guard case .failed(let message) = state else { return }
        Self.logger.notice("gate open failed; presenting notification")
        Task { [weak self] in
            await self?.presentFailureNotification(message: message)
        }
    }

    // MARK: - Private

    private func registerCategory(on center: UNUserNotificationCenter) {
        let retryAction = UNNotificationAction(
            identifier: Self.retryActionIdentifier,
            title: "Retry",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.failureCategoryIdentifier,
            actions: [retryAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    private func presentFailureNotification(message: String) async {
        guard let center = resolveCenterIfPossible() else {
            // No bundle identifier: degrade silently to icon-only
            // feedback, exactly as if authorization had been denied.
            Self.logger.notice("no notification center available; degrading to icon-only feedback")
            return
        }

        let authorized = await ensureAuthorized(using: center)
        guard authorized else {
            // Denied (or request failed): degrade silently to icon-only
            // feedback. Never throw, never retry the prompt.
            Self.logger.notice("notification authorization not granted; degrading to icon-only feedback")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Gate did not open"
        content.body = message
        content.categoryIdentifier = Self.failureCategoryIdentifier

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
        } catch {
            // Never let a notification-delivery failure propagate anywhere
            // that could disrupt the open path; this is best-effort UX.
            Self.logger.error("failed to add notification request")
        }
    }

    /// Resolves whether this process is authorized to post notifications,
    /// requesting authorization lazily (once) if the current status is
    /// `.notDetermined`. Never throws: an error from the authorization
    /// request itself is treated the same as "denied".
    private func ensureAuthorized(using center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            guard !hasRequestedAuthorization else { return false }
            hasRequestedAuthorization = true
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Self.logger.error("notification authorization request failed")
                return false
            }
        @unknown default:
            return false
        }
    }

    /// Invoked by `userNotificationCenter(_:didReceive:withCompletionHandler:)`
    /// below when the user activates the "Retry" action on a failure
    /// notification.
    func handleRetryAction() {
        retryHandler()
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Routes the "Retry" notification action to `handleRetryAction()`.
    /// Any other action identifier (including the default "open the app"
    /// tap) is a no-op here — this delegate exists solely to make Retry
    /// reachable, not to change any other notification behavior.
    ///
    /// `UNUserNotificationCenterDelegate` methods are not actor-isolated by
    /// the framework, so this explicitly hops back onto the main actor
    /// (where `NotificationPresenter` itself lives) before touching
    /// `handleRetryAction()`/`retryHandler`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        Task { @MainActor in
            if actionIdentifier == Self.retryActionIdentifier {
                self.handleRetryAction()
            }
        }
        completionHandler()
    }

    /// Ensures a failure notification is still shown even while the app is
    /// frontmost (e.g. the Settings window has focus) — without this, the
    /// system default is to suppress the alert/sound when the posting app
    /// is active, which would defeat the point of notifying the operator.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
