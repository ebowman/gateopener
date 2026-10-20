import Foundation
import Observation
import OSLog
import SwiftUI
import WatchConnectivity
import GateOpenerCore

// iOS app target ONLY: WatchConnectivity is unavailable in app extensions,
// and project.yml compiles `iOS/App` into the app target alone.

/// Activation state mirrored from `WCSessionActivationState`, kept as our own
/// type so tests never need a real `WCSession`.
enum WatchSessionActivation: Equatable, Sendable {
    case notActivated
    case inactive
    case activated
}

/// The slice of `WCSession` that `WatchSync` uses. Application context only;
/// there is deliberately no `sendMessage`.
@MainActor
protocol WatchSessionProviding: AnyObject {
    var isSupported: Bool { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var activationState: WatchSessionActivation { get }
    /// Called (on the main actor) when activation completes or the paired
    /// watch's state (paired / app installed) changes.
    var onStateChange: (@MainActor () -> Void)? { get set }
    /// Called (on the main actor) with a received `transferUserInfo` payload.
    var onUserInfo: (@MainActor ([String: Any]) -> Void)? { get set }
    func activate()
    func updateApplicationContext(_ context: [String: Any]) throws
}

/// `WCSession.default` adapter. `WCSession.default` is only touched when
/// `WCSession.isSupported()`.
@MainActor
final class WCSessionAdapter: NSObject, WatchSessionProviding, WCSessionDelegate {
    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    var onStateChange: (@MainActor () -> Void)?
    var onUserInfo: (@MainActor ([String: Any]) -> Void)?

    var isSupported: Bool { WCSession.isSupported() }
    var isPaired: Bool { session?.isPaired ?? false }
    var isWatchAppInstalled: Bool { session?.isWatchAppInstalled ?? false }
    var activationState: WatchSessionActivation {
        switch session?.activationState {
        case .activated: return .activated
        case .inactive: return .inactive
        default: return .notActivated
        }
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func updateApplicationContext(_ context: [String: Any]) throws {
        guard let session else { return }
        try session.updateApplicationContext(context)
    }

    // WCSessionDelegate callbacks arrive on a background queue.
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in self.onStateChange?() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in self.onStateChange?() }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Required on iOS to support watch switching: re-activate.
        session.activate()
        Task { @MainActor in self.onStateChange?() }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        nonisolated(unsafe) let box = userInfo
        Task { @MainActor in self.onUserInfo?(box) }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.onStateChange?() }
    }
}

/// Pushes the provisioning payload to the paired watch as application context
/// (latest-wins). Never logs credentials: only the reason and message kind.
@MainActor
@Observable
final class WatchSync {
    enum Status: Equatable {
        case unsupported
        case notPaired
        case watchAppNotInstalled
        case pending
        case sent(at: Date)
        case failed(message: String)
    }

    private(set) var status: Status = .pending

    @ObservationIgnored private let session: any WatchSessionProviding
    @ObservationIgnored private let appSettings: AppSettings
    /// Read lazily on every push: `AppEnvironment.updateKeychainAccessibility`
    /// swaps in a new store after launch.
    @ObservationIgnored private let credentialStoreProvider: () -> any CredentialStoring
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let watchHistoryStore: WatchHistoryStore?
    @ObservationIgnored private var pendingPush = false
    @ObservationIgnored private var pendingReason = ""
    @ObservationIgnored private let log = Logger(subsystem: "ie.boboco.GateOpener", category: "watch-sync")

    init(
        session: any WatchSessionProviding,
        appSettings: AppSettings,
        credentialStoreProvider: @escaping () -> any CredentialStoring,
        now: @escaping () -> Date = Date.init,
        watchHistoryStore: WatchHistoryStore? = SharedContainer.watchHistoryURL().map(WatchHistoryStore.init(url:))
    ) {
        self.session = session
        self.appSettings = appSettings
        self.credentialStoreProvider = credentialStoreProvider
        self.now = now
        self.watchHistoryStore = watchHistoryStore
        session.onStateChange = { [weak self] in self?.sessionStateDidChange() }
        session.onUserInfo = { [weak self] info in self?.onWatchHistoryReceived(info) }
    }

    /// A `transferUserInfo` payload arrived from the watch (bead
    /// gateopener-3d7.17). Anything but a well-formed `watchHistory` transfer
    /// is ignored. Logs only the size, never the text.
    func onWatchHistoryReceived(_ userInfo: [String: Any]) {
        guard let transfer = WatchHistoryStore.parse(userInfo: userInfo) else { return }
        guard let watchHistoryStore else {
            log.error("watch history dropped: no App Group container")
            return
        }
        let ok = watchHistoryStore.append(text: transfer.text, sentAt: transfer.sentAt)
        log.info("watch history received: \(transfer.text.count, privacy: .public) chars, stored=\(ok, privacy: .public)")
    }

    /// Fixed-store convenience (tests).
    convenience init(
        session: any WatchSessionProviding,
        appSettings: AppSettings,
        credentialStore: any CredentialStoring,
        now: @escaping () -> Date = Date.init,
        watchHistoryStore: WatchHistoryStore? = SharedContainer.watchHistoryURL().map(WatchHistoryStore.init(url:))
    ) {
        self.init(
            session: session, appSettings: appSettings, credentialStoreProvider: { credentialStore },
            now: now, watchHistoryStore: watchHistoryStore
        )
    }

    /// Activates the session once at launch.
    func start() {
        guard session.isSupported else {
            status = .unsupported
            return
        }
        session.activate()
    }

    /// Builds the current message and sends it if the session is ready;
    /// otherwise remembers to send on the next activation / watch-state change.
    func pushNow(reason: String) {
        guard session.isSupported else {
            status = .unsupported
            return
        }
        let message: WatchProvisioningMessage
        do {
            message = try WatchProvisioningMessage.build(
                settings: appSettings, credentialStore: credentialStoreProvider(), now: now()
            )
        } catch {
            // Never push (least of all .signedOut) because of a keychain error.
            log.error("watch push skipped (\(reason, privacy: .public)): build failed")
            status = .failed(message: "Could not read credentials")
            return
        }
        let kind: String = { if case .provision = message { return "provision" } else { return "signedOut" } }()

        guard session.activationState == .activated else {
            deferPush(reason: reason, kind: kind)
            return
        }
        guard session.isPaired else {
            status = .notPaired
            log.info("watch push not sent (\(reason, privacy: .public)): not paired")
            return
        }
        guard session.isWatchAppInstalled else {
            status = .watchAppNotInstalled
            log.info("watch push not sent (\(reason, privacy: .public)): watch app not installed")
            return
        }
        do {
            try session.updateApplicationContext(message.toContext())
            pendingPush = false
            status = .sent(at: now())
            log.info("watch push sent (\(reason, privacy: .public)): \(kind, privacy: .public)")
        } catch {
            status = .failed(message: error.localizedDescription)
            log.error("watch push failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// True once WCSession activation has completed. Read by the Settings row
    /// to tell "sending" from "waiting for the session".
    var isSessionActivated: Bool { session.activationState == .activated }

    /// Manual "Send to Watch": activates first if the session is not yet
    /// activated (the push is then deferred until activation completes).
    func sendFromSettings() {
        if session.isSupported, session.activationState != .activated {
            start()
        }
        pushNow(reason: "settings")
    }

    private func deferPush(reason: String, kind: String) {
        pendingPush = true
        pendingReason = reason
        status = .pending
        log.info("watch push deferred (\(reason, privacy: .public)): \(kind, privacy: .public), session not activated")
    }

    private func sessionStateDidChange() {
        guard session.isSupported else {
            status = .unsupported
            return
        }
        if session.activationState == .activated {
            // (a) activation completed; also covers watch-state changes.
            pushNow(reason: pendingPush ? "\(pendingReason)+activated" : "activated")
        } else {
            status = .pending
        }
    }
}

extension EnvironmentValues {
    @Entry var watchSync: WatchSync? = nil
}
