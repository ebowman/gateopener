import AppIntents
import GateOpenerCore

/// Exposes `OpenGateIntent` to Siri/Shortcuts so "Open the gate" phrases
/// work without the user ever needing to build a Shortcut manually, per
/// bead gateopener-672.13 step 4.
///
/// `iOS/App`-only (not `iOS/Shared`): `AppShortcutsProvider` conformance is
/// only meaningful for the app target that owns the `INTENTS`/App Shortcuts
/// donation surface — the widget extension does not need its own copy,
/// since both targets link the SAME `OpenGateIntent` type from
/// `iOS/Shared`.
struct GateOpenerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenGateIntent(),
            phrases: [
                "Open the gate with \(.applicationName)",
                "Open my gate in \(.applicationName)",
            ],
            shortTitle: "Open Gate",
            // `systemImageName:` requires a compile-time string literal (the
            // App Shortcuts macro extracts it statically), so it cannot take
            // `GateSymbol.name` directly — keep this literal in sync with
            // `iOS/Shared/GateSymbol.swift` by hand.
            systemImageName: "door.left.hand.open"
        )
    }
}
