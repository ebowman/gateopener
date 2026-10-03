import Foundation
import UIKit
import UserNotifications
import GateOpenerCore

/// Handles taps/actions on the open-result notification (bead gateopener-6qa.5).
///
/// - "Retry" action: opens the gate again ONLY if the original press was
///   less than `retryMaxAge` ago. Otherwise nothing is opened and the
///   notification is replaced by a "Retry expired" one with no action.
/// - Default tap: never opens; the app just launches normally.
///
/// iOS/App only (uses `UIApplication` via `BackgroundTaskHost`).
@MainActor
final class OpenResultNotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    /// SAFETY: a Retry older than this is refused, so a stale notification
    /// can never open the gate long after the original press.
    static let retryMaxAge: TimeInterval = 5 * 60
    /// Press source recorded in the journal for retries from the notification.
    static let retrySource = "notification-retry"

    /// Shared instance, so the app delegate can install it as the center's
    /// delegate at launch and `GateOpenerIOSApp` can configure it later.
    static let shared = OpenResultNotificationHandler()

    typealias RunFlow = @MainActor (_ source: String) async -> Void

    private var now: () -> Date
    private var runFlow: RunFlow?
    private var host: BackgroundTaskHost
    private var notifier: (any OpenResultNotifying)?

    /// Production: unconfigured until `configure(...)`.
    override convenience init() {
        self.init(now: { Date() }, runFlow: nil, host: UIApplicationBackgroundTaskHost(), notifier: nil)
    }

    init(now: @escaping () -> Date, runFlow: RunFlow?, host: BackgroundTaskHost, notifier: (any OpenResultNotifying)?) {
        self.now = now
        self.runFlow = runFlow
        self.host = host
        self.notifier = notifier
        super.init()
    }

    /// Wires the app's real environment. Called from `GateOpenerIOSApp.init`.
    func configure(environment: AppEnvironment) {
        notifier = OpenResultNotifier(settings: environment.appSettings)
        runFlow = { source in
            _ = await OpenGateIntent.runFlow(environment: environment, source: source)
        }
    }

    /// Testable core. Returns when all work (including the open flow) is done.
    func handle(actionIdentifier: String, userInfo: [AnyHashable: Any]) async {
        guard actionIdentifier == OpenResultNotifier.retryActionIdentifier else { return }

        let pressedAt = (userInfo[OpenResultNotifier.pressedAtUserInfoKey] as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        guard let pressedAt, now().timeIntervalSince(pressedAt) <= Self.retryMaxAge, let runFlow else {
            await notifier?.postRetryExpired()
            return
        }

        let box = TaskBox()
        box.id = host.beginBackgroundTask { [weak self, box] in
            // iOS requires endBackgroundTask to be called synchronously
            // inside the expiration handler (invoked on the main thread),
            // so no Task hop here.
            MainActor.assumeIsolated {
                guard let self, let id = box.id else { return }
                box.id = nil
                self.host.endBackgroundTask(id)
            }
        }
        await runFlow(Self.retrySource)
        if let id = box.id {
            box.id = nil
            host.endBackgroundTask(id)
        }
    }

    @MainActor private final class TaskBox: Sendable {
        nonisolated(unsafe) var id: UIBackgroundTaskIdentifier?
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        nonisolated(unsafe) let userInfo = response.notification.request.content.userInfo
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            await self.handle(actionIdentifier: action, userInfo: userInfo)
            done()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.foregroundPresentationOptions)
    }

    nonisolated static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner, .sound, .list]
}

/// Sets the notification delegate as early as possible on launch (the app
/// may be launched in the background purely to handle the Retry action).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = OpenResultNotificationHandler.shared
        }
        return true
    }
}
