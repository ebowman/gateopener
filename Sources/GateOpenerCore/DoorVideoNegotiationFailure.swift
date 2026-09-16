import Foundation

/// Maps stable error codes emitted by `Resources/door-video.html` to short,
/// actionable UI text shared by the macOS and iOS video callers.
public enum DoorVideoNegotiationFailure {
    public static func userMessage(for error: Error) -> String {
        let nsError = error as NSError
        let details = ([nsError.localizedDescription, String(describing: error)]
            + nsError.userInfo.values.map(String.init(describing:)))
            .joined(separator: " ")
            .lowercased()

        if details.contains("ice-gathering-timeout") ||
            details.contains("ice gathering did not complete within 15 seconds") {
            return "Video network setup timed out"
        }
        if details.contains("ice-gathering-closed") ||
            details.contains("video session closed before ice gathering completed") {
            return "Video session closed during network setup"
        }
        return "Could not negotiate video session"
    }
}
