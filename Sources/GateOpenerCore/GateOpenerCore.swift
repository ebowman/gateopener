import Foundation

/// Namespace for the GateOpener core library.
///
/// This target contains all authentication, API, and business logic for
/// GateOpener. It must remain free of AppKit/SwiftUI imports so that
/// `swift test` can run headlessly with no GUI dependency.
public enum GateOpenerCore {
    /// The current version of the GateOpenerCore library.
    public static let version = "0.1.0"
}
