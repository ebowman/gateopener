import Foundation
import os

/// Pure decode -> guard -> apply -> persist decision for a received
/// provisioning context. The watch's `WCSession` adapter is a thin shell
/// around this so the logic is unit-testable without WatchConnectivity.
/// Never logs credentials.
public struct WatchProvisioningApplier {
    private static let logger = Logger(subsystem: "ie.boboco.GateOpener", category: "watch-provisioning")

    private let settings: AppSettings
    private let credentialStore: any CredentialStoring

    public init(settings: AppSettings, credentialStore: any CredentialStoring) {
        self.settings = settings
        self.credentialStore = credentialStore
    }

    /// Returns the message iff it was newly applied (stores written and
    /// `watchProvisioningAppliedAt` advanced to its `issuedAt`). Returns nil
    /// for an empty/undecodable context, a stale or duplicate message, or an
    /// apply failure (all logged; no state change on decode/stale paths).
    @discardableResult
    public func handle(context: [String: Any]) -> WatchProvisioningMessage? {
        guard !context.isEmpty else {
            Self.logger.notice("empty provisioning context; nothing to apply")
            return nil
        }
        guard let message = WatchProvisioningMessage.fromContext(context) else {
            Self.logger.error("provisioning context failed to decode")
            return nil
        }
        do {
            let applied = try message.apply(
                to: settings,
                credentialStore: credentialStore,
                previouslyApplied: settings.watchProvisioningAppliedAt
            )
            guard applied else {
                Self.logger.notice("provisioning context stale or duplicate; ignored")
                return nil
            }
            settings.watchProvisioningAppliedAt = message.issuedAt
            switch message {
            case .provision: Self.logger.notice("applied provision")
            case .signedOut: Self.logger.notice("applied signed-out")
            }
            return message
        } catch {
            Self.logger.error("applying provisioning failed: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }
}

/// What the watch app does after a provisioning message is applied.
public enum WatchProvisioningReaction {
    /// True for every message kind. `apply(.provision)` deletes the STORED
    /// tokens (and `.signedOut` clears everything), but `TokenManager` keeps
    /// an in-memory cached access token; unless it is invalidated too, a
    /// re-provision with a different account would keep opening the gate
    /// with the old account's token until it expires.
    public static func shouldInvalidateCachedToken(for message: WatchProvisioningMessage) -> Bool {
        switch message {
        case .provision, .signedOut: return true
        }
    }
}
