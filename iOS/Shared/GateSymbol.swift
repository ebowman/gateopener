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
}
