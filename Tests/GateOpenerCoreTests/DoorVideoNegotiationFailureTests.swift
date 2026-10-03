import Foundation
import GateOpenerCore
import Testing

struct DoorVideoNegotiationFailureTests {
    @Test func timeoutCodeMapsToActionableMessage() {
        let error = NSError(
            domain: "WKErrorDomain",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "JavaScript exception: ice-gathering-timeout"]
        )
        #expect(DoorVideoNegotiationFailure.userMessage(for: error) == "Video network setup timed out")
    }

    @Test func closedCodeMapsToActionableMessage() {
        let error = NSError(
            domain: "WKErrorDomain",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "DoorVideoNegotiationError: ice-gathering-closed"]
        )
        #expect(DoorVideoNegotiationFailure.userMessage(for: error) == "Video session closed during network setup")
    }

    @Test func webKitClosedMessageWithoutJavaScriptCodeMapsToActionableMessage() {
        let error = NSError(
            domain: "WKErrorDomain",
            code: 5,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "JavaScript exception: DoorVideoNegotiationError: Video session closed before ICE gathering completed"
            ]
        )
        #expect(DoorVideoNegotiationFailure.userMessage(for: error) == "Video session closed during network setup")
    }

    @Test func unrelatedJavaScriptErrorKeepsSafeGenericMessage() {
        let error = NSError(
            domain: "WKErrorDomain",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "ReferenceError: internal details"]
        )
        #expect(DoorVideoNegotiationFailure.userMessage(for: error) == "Could not negotiate video session")
    }
}

extension DoorVideoNegotiationFailureTests {
    @Test func iceNoReflexiveMapsToStunBlockedMessage() {
        let error = NSError(domain: "WKErrorDomain", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "A JavaScript exception occurred",
            "WKJavaScriptExceptionMessage": "ICE gathering produced no srflx/relay candidate (ice-no-reflexive)",
        ])
        #expect(DoorVideoNegotiationFailure.userMessage(for: error) == "This network blocks door video (STUN/UDP)")
        #expect(OverlayFailureDecision.showsReason(for: DoorVideoNegotiationFailure.userMessage(for: error)) == true)
    }
}
