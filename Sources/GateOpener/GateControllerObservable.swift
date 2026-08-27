import Foundation
import Observation
import GateOpenerCore

/// App-layer bridge from `GateController` (plain, non-Observable, defined in
/// `GateOpenerCore`) to SwiftUI/AppKit observation.
///
/// `GateOpenerCore` deliberately cannot depend on Observation/SwiftUI (see
/// the file-level doc comment on `GateController`), so this type lives here
/// instead: it owns a `GateController`, subscribes to `onStateChange`, and
/// republishes the latest `GateState` as an `@Observable` property that
/// AppKit/SwiftUI code in this target can react to.
///
/// This class does NOT add any new state-mutation path: every mutation is
/// still routed through `GateController`'s own methods. It only forwards
/// notifications.
@MainActor
@Observable
final class GateControllerObservable {
    /// The app's single `GateControllerObservable` instance, set once by
    /// `AppDelegate` immediately after construction
    /// (`Sources/GateOpener/GateOpenerApp.swift`).
    ///
    /// Exists so `SettingsWindowController` (bead gateopener-4ub.9) can
    /// reach the shared observable without changing `showShared()`'s
    /// existing zero-argument signature — that signature has two call
    /// sites in `StatusItemController.swift`, a file bead .9 does not own
    /// and must not edit. `nil` only in the (untested-in-practice) window
    /// before `AppDelegate.applicationDidFinishLaunching` runs.
    static var appShared: GateControllerObservable?

    /// The controller this adapter wraps. Exposed so callers can invoke
    /// `openGate()`, `performFirstTimeSetup(...)`, etc. directly.
    let controller: GateController

    /// The latest state, kept in sync with `controller.state` via
    /// `onStateChange`. `@Observable` makes reads of this property from
    /// SwiftUI views trigger re-render on change.
    private(set) var state: GateState

    /// The app's shared `EventLog` (bead gateopener-4ub.10), set once by
    /// `AppDelegate` immediately after constructing this observable. `nil`
    /// only in the same brief pre-launch window `appShared` itself can be
    /// `nil` in. Exposed here (rather than only via `appShared`) so
    /// `SettingsView`'s log section can read it directly off the
    /// `@Bindable var observable` it already holds.
    var eventLog: EventLog?

    /// The app's global hotkey (bead gateopener-iif.2), set once by
    /// `AppDelegate` immediately after installing it — same lifecycle
    /// caveat as `eventLog` above. Exposed so `SettingsView` can display
    /// the current shortcut and surface a registration-failure message
    /// without a separate access path.
    var globalHotkey: GlobalHotkey?

    init(controller: GateController) {
        self.controller = controller
        self.state = controller.state
        controller.onStateChange = { [weak self] newState in
            self?.state = newState
        }
    }

    // MARK: - Shortcut preference (bead gateopener-3vq.4)

    /// THE single path by which anything in the app (views, buttons, the
    /// recorder) may change the shortcut preference. Persists via
    /// `controller.setShortcutPreference(_:)` (the `GateOpenerCore`-side
    /// single write path — see that method's doc comment) AND applies the
    /// SAME value live to `globalHotkey`, so persistence and live effect can
    /// never drift apart. A view writing `AppSettings`/`GateController`
    /// directly and separately calling `globalHotkey.apply(_:)` itself would
    /// risk exactly the split-write bug `gateopener-4ub.7`'s notes warn
    /// about (a write that fires no change notification and silently
    /// desyncs bound UI) — this method exists so there is only ever ONE
    /// call site that does both, and every caller (recorder, ✕ button,
    /// "Reset to Default") goes through it.
    ///
    /// This is an `@Observable` class, so simply performing the writes below
    /// (which mutate `globalHotkey`'s stored properties, themselves tracked
    /// by `@Observable` via this object holding the reference) is enough to
    /// republish to any SwiftUI view reading `observable.globalHotkey`'s
    /// properties through this object.
    func setShortcutPreference(_ preference: ShortcutPreference) {
        controller.setShortcutPreference(preference)
        globalHotkey?.apply(preference)
    }
}
