import Foundation
import WatchConnectivity

/// Sends the watch's open-history share text to the iPhone via
/// `WCSession.transferUserInfo` (bead gateopener-3d7.17). Dictionary keys:
/// "kind" = "watchHistory", "text" = share text, "sentAt" = Date. The share
/// text never contains credentials.
enum WatchHistorySender {
    /// Returns false when the session is unsupported or not yet activated.
    @discardableResult
    static func send(text: String) -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        guard session.activationState == .activated else { return false }
        session.transferUserInfo(["kind": "watchHistory", "text": text, "sentAt": Date()])
        return true
    }
}
