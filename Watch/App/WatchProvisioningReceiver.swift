import Foundation
import GateOpenerCore
import WatchConnectivity
import os

/// Seam over `WCSession` so the adapter is swappable; the decode/guard/apply
/// logic itself lives in core's `WatchProvisioningApplier` (unit-tested).
protocol ProvisioningSessionProviding: AnyObject {
    var isSupported: Bool { get }
    var receivedApplicationContext: [String: Any] { get }
    func setDelegate(_ delegate: WCSessionDelegate)
    func activate()
}

final class WCSessionProvider: ProvisioningSessionProviding {
    var isSupported: Bool { WCSession.isSupported() }
    var receivedApplicationContext: [String: Any] { WCSession.default.receivedApplicationContext }
    func setDelegate(_ delegate: WCSessionDelegate) { WCSession.default.delegate = delegate }
    func activate() { WCSession.default.activate() }
}

/// Thin WatchConnectivity adapter: receives the iPhone's application context
/// and funnels it into `WatchProvisioningApplier`. WCSession callbacks arrive
/// on a background queue, so each hops to the main actor.
@MainActor
final class WatchProvisioningReceiver: NSObject, WCSessionDelegate {
    private nonisolated static let logger = Logger(subsystem: "ie.boboco.GateOpener", category: "watch-provisioning")

    private let applier: WatchProvisioningApplier
    private let session: any ProvisioningSessionProviding
    private let onApplied: @MainActor (WatchProvisioningMessage) -> Void
    private var started = false

    init(
        settings: AppSettings,
        credentialStore: any CredentialStoring,
        session: any ProvisioningSessionProviding = WCSessionProvider(),
        onApplied: @escaping @MainActor (WatchProvisioningMessage) -> Void
    ) {
        self.applier = WatchProvisioningApplier(settings: settings, credentialStore: credentialStore)
        self.session = session
        self.onApplied = onApplied
        super.init()
    }

    /// Idempotent: activates the session once.
    func start() {
        guard !started else { return }
        started = true
        guard session.isSupported else {
            Self.logger.notice("WCSession not supported")
            return
        }
        session.setDelegate(self)
        session.activate()
    }

    func handle(context: [String: Any]) {
        if let message = applier.handle(context: context) {
            onApplied(message)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            Self.logger.error("WCSession activation failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard activationState == .activated else { return }
        Self.logger.notice("WCSession activated")
        let context = session.receivedApplicationContext
        nonisolated(unsafe) let box = context
        Task { @MainActor in self.handle(context: box) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        nonisolated(unsafe) let box = applicationContext
        Task { @MainActor in self.handle(context: box) }
    }
}
