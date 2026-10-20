#if canImport(SwiftUI)
import SwiftUI
#endif

/// The single SF Symbol used everywhere the app represents "open the gate":
/// the Home Screen widget, the Lock Screen widget, the Control Center /
/// Lock Screen control, and the App Shortcuts phrase icon.
///
/// `door.left.hand.open` (SF Symbols 4, iOS 16+) reads as an actual gate/door
/// being opened, which is a closer match for this app's action than a
/// padlock — `lock.fill` describes a *security* action, but tapping the
/// widget doesn't lock or unlock anything conceptually, it swings a gate
/// open. The deployment target here is iOS 18.0 (see `project.yml`), well
/// past this symbol's iOS 16 introduction, so it is always available.
public enum GateSymbol {
    public static let name = "door.left.hand.open"

#if canImport(SwiftUI)
    /// Explicit tint for `GateControl`, equal to the AccentColor asset's
    /// universal (light) sRGB value (0.169, 0.227, 0.333). The asset also has
    /// a dark variant (0.353, 0.439, 0.600) which is deliberately not used
    /// here. `.accentColor` cannot be resolved when the watch renders the
    /// iPhone-imported control, so the control uses this constant instead.
    public static let controlTint = Color(.sRGB, red: 0.169, green: 0.227, blue: 0.333, opacity: 1)
#endif
}
