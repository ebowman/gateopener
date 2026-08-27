import AppKit
import Carbon.HIToolbox
import GateOpenerCore

/// Registers a system-wide keyboard shortcut ("global hotkey") that opens
/// the gate the same way a left-click on the status item does — see the
/// bead gateopener-iif.2 brief.
///
/// WHY THIS EXISTS: the status item can be pushed off-screen by macOS when
/// the menu bar is full (measured live at x = -10329 on a 1352-point
/// screen — see the bead), making the one-click affordance unreachable. A
/// global hotkey works regardless of menu bar space. This ADDS to
/// click-to-open; it does not replace it.
///
/// ## API choice: Carbon `RegisterEventHotKey`, not `NSEvent.addGlobalMonitorForEvents`
///
/// `NSEvent.addGlobalMonitorForEvents(matching:handler:)` can observe
/// keystrokes system-wide, but ONLY after the user has granted the app
/// Accessibility permission (System Settings > Privacy & Security >
/// Accessibility) — first launch would otherwise show a permission prompt
/// (or, worse, silently fail to fire with no prompt at all if the
/// entitlement request is misconfigured) before the hotkey does anything.
/// That is a materially worse first-run experience for a one-purpose menu
/// bar utility.
///
/// The Carbon Event Manager's `RegisterEventHotKey`/`UnregisterEventHotKey`
/// APIs (declared in `Carbon.HIToolbox`) register a truly system-wide
/// hotkey WITHOUT requiring any special permission or entitlement — the
/// same mechanism macOS itself and countless utilities (e.g. window
/// managers, launcher apps) have used for this exact purpose for decades.
/// Carbon is deprecated as an application framework but this specific
/// low-level Event Manager corner is still fully supported and has no
/// modern non-Accessibility-gated replacement; it remains the standard
/// answer for "global hotkey with no permission prompt" on macOS as of
/// this writing. Hence: Carbon `RegisterEventHotKey` is used here.
///
/// ## Chord source (bead gateopener-3vq.2)
///
/// The chord registered is no longer hardcoded: it is derived from the
/// app's persisted `ShortcutPreference` (`GateOpenerCore.AppSettings`) via
/// `apply(_:)`. `GateOpenerCore.KeyboardShortcut` stores a Carbon-free raw
/// `keyCode`/`modifiers` pair; THIS file (the app layer, which imports
/// Carbon) is the only place that pair is ever turned into Carbon's
/// `UInt32` key code / modifier mask arguments to `RegisterEventHotKey`.
/// The core stays Carbon-free — see `KeyboardShortcut.swift`'s doc comment
/// for why the modifier bit constants there are raw numbers rather than
/// imported Carbon constants.
///
/// `KeyboardShortcut.defaultChord` (Cmd-Ctrl-Option-G) is registered
/// whenever the preference is `.unset` or a persisted `.custom` chord
/// fails `isValid` (see `apply(_:)`'s doc comment for why that check lives
/// here rather than trusting the model).
///
/// ## Registration failure
///
/// If another app has already claimed a given combination,
/// `RegisterEventHotKey` returns a non-`noErr` status. This is treated as a
/// soft failure: `lastRegistrationError` is set (read by Settings — see
/// `SettingsView`'s "Keyboard Shortcut" section) and the call returns
/// without crashing or throwing. `apply(_:)` additionally guarantees a
/// failed re-registration never leaves the app with NO working hotkey — see
/// its doc comment.
@MainActor
final class GlobalHotkey {
    private static let signature: OSType = {
        // Any 4-char OSType uniquely identifying this app's hotkey to the
        // Carbon Event Manager; arbitrary but stable.
        let bytes: [UInt8] = Array("GTOP".utf8)
        return (OSType(bytes[0]) << 24) | (OSType(bytes[1]) << 16) | (OSType(bytes[2]) << 8) | OSType(bytes[3])
    }()
    private static let hotKeyID = EventHotKeyID(signature: signature, id: 1)

    /// The handler invoked when the hotkey fires. Set once at construction;
    /// exists as a stored closure (rather than calling straight into
    /// `GateControllerObservable`/`SettingsWindowController` from the C
    /// callback) so the self-test can invoke EXACTLY the same handler the
    /// real Carbon callback would invoke, without going through Carbon's
    /// event dispatch at all (see `handleHotkeyForSelfTest()` below and the
    /// bead's "programmatically invoke the handler" done-criterion).
    private let onHotkeyFired: () -> Void

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    /// The chord currently registered with the Carbon Event Manager, if
    /// any. `nil` whenever nothing is registered — either because
    /// `.disabled` was applied (see `isDisabled`) or because the most
    /// recent registration attempt failed and there was no prior working
    /// chord to fall back to.
    private var registeredChord: KeyboardShortcut?

    /// Non-nil iff the most recent registration ATTEMPT failed (e.g.
    /// another app already owns the combination). `nil` means either no
    /// attempt has been made yet, the most recent attempt succeeded, or
    /// the hotkey is deliberately `.disabled` — see `isDisabled` for that
    /// last case. A chosen "no shortcut" setting must never populate this
    /// property: only an unexpected failure to register should. Read by
    /// `SettingsView` to surface a "Shortcut unavailable" message rather
    /// than failing silently.
    private(set) var lastRegistrationError: String?

    /// True iff the hotkey is currently registered with the system and
    /// expected to fire. Read by `SettingsView`.
    private(set) var isRegistered = false

    /// True iff the CURRENT state is the operator's deliberate choice of
    /// "no hotkey" (`ShortcutPreference.disabled`), as opposed to
    /// `isRegistered == false` meaning "we tried to register something and
    /// failed". `SettingsView` (bead .3) uses this to render "No shortcut"
    /// rather than "Shortcut unavailable" when the operator chose to turn
    /// the hotkey off — the two must never look the same.
    private(set) var isDisabled = false

    /// The chord CURRENTLY registered, if any — i.e. exactly the chord
    /// `isRegistered == true` refers to. `nil` whenever nothing is
    /// registered (`.disabled`, or a failed registration with no working
    /// fallback). Read by `SettingsView` so every user-visible rendering of
    /// the shortcut goes through `KeyboardShortcut.displayString` — the
    /// SAME formatting used in `lastRegistrationError` — rather than a
    /// separately-maintained string.
    var currentChord: KeyboardShortcut? { registeredChord }

    /// - Parameter onHotkeyFired: called on the main actor whenever the
    ///   hotkey fires. Callers pass a closure that mirrors the left-click
    ///   behaviour exactly (see `AppDelegate`'s wiring in
    ///   `GateOpenerApp.swift`): open Settings if `.needsSetup`, otherwise
    ///   `Task { await controller.openGate() }`. This type does not itself
    ///   know about `GateController`/`GateState` — it stays a thin,
    ///   reusable Carbon wrapper — so it takes a plain closure rather than
    ///   importing GateOpenerCore's controller types.
    init(onHotkeyFired: @escaping () -> Void) {
        self.onHotkeyFired = onHotkeyFired
    }

    /// Applies a `ShortcutPreference` to the live Carbon registration:
    ///
    /// - `.unset` -> register `KeyboardShortcut.defaultChord`.
    /// - `.custom(chord)` where `chord.isValid` -> register that chord.
    /// - `.custom(chord)` where `!chord.isValid` -> register the DEFAULT
    ///   chord instead, never the invalid one. **This check is required
    ///   here, at the point of registration**: `KeyboardShortcut.isValid`
    ///   is defined in `GateOpenerCore` but nothing upstream enforces it
    ///   before a chord reaches this call (a hand-edited or corrupted
    ///   persisted preference could carry an invalid chord straight from
    ///   `AppSettings`). This chord fires a REAL PHYSICAL GATE OPEN; a
    ///   single-modifier or bare-key shortcut could trigger on an ordinary
    ///   keystroke, so the two-modifier minimum is enforced as a safety
    ///   gate here, not trusted from the model.
    /// - `.disabled` -> unregister and register nothing. `isRegistered`
    ///   becomes `false` and `isDisabled` becomes `true`; critically,
    ///   `lastRegistrationError` is left `nil` (or cleared, if a stale
    ///   error was set before), because a deliberately-chosen "no hotkey"
    ///   state is NOT a malfunction and must never be presented as one.
    ///
    /// ## Failure preserves the previous working registration
    ///
    /// If registering the requested chord (default, valid custom, or the
    /// invalid-custom fallback) fails — most commonly because another app
    /// already owns that exact combination — the PREVIOUSLY registered
    /// chord (if any) is restored rather than left unregistered. The
    /// operator must never end up with no hotkey merely because they tried
    /// a chord that turned out to be taken; they keep whatever was
    /// working, and `lastRegistrationError` reports the failure so the UI
    /// can surface it.
    ///
    /// ## Idempotence / no stale registrations
    ///
    /// Applying `.disabled` twice is a harmless no-op (uninstalling an
    /// already-uninstalled hotkey is safe). Applying the same chord that
    /// is already registered re-registers it (unregister-then-register)
    /// rather than skipping the call, so there is never a window where a
    /// chord CHANGE would leave the app briefly unregistered followed by a
    /// registration failure with nothing restorable — the "previous
    /// working chord" bookkeeping below is updated only after a
    /// successful registration, so a no-op reapplication cannot corrupt it.
    func apply(_ preference: ShortcutPreference) {
        switch preference {
        case .disabled:
            // Deliberate "no hotkey": unregister (safe even if already
            // unregistered) and report NOTHING as an error. Do not touch
            // `registeredChord`'s role as "last known working chord" — if
            // the operator re-enables afterwards via `.unset`/`.custom`,
            // that is a fresh registration attempt on its own merits, not
            // a restore, so clearing it here has no observable effect
            // either way.
            uninstallHotKeyOnly()
            isDisabled = true
            lastRegistrationError = nil
            registeredChord = nil

        case .unset:
            isDisabled = false
            registerWithFallback(requested: KeyboardShortcut.defaultChord)

        case .custom(let chord):
            isDisabled = false
            let toRegister = chord.isValid ? chord : KeyboardShortcut.defaultChord
            registerWithFallback(requested: toRegister)
        }
    }

    /// Attempts to register `requested`. On success, updates
    /// `registeredChord`/`isRegistered`/`lastRegistrationError` and returns.
    /// On failure, restores the previously-registered chord (if any) so
    /// the operator never ends up with no working hotkey, and sets
    /// `lastRegistrationError` to describe the failure using the
    /// SAME `KeyboardShortcut.displayString` the rest of the app uses —
    /// never a separately-formatted string.
    private func registerWithFallback(requested: KeyboardShortcut) {
        let previous = registeredChord

        if registerHotKey(requested) {
            registeredChord = requested
            isRegistered = true
            lastRegistrationError = nil
            return
        }

        // Registration of the requested chord failed. Report it, then try
        // to restore whatever was working before so the operator is never
        // left with nothing.
        let failureMessage = "Shortcut unavailable — another app is using \(requested.displayString)."

        if let previous, registerHotKey(previous) {
            registeredChord = previous
            isRegistered = true
        } else {
            registeredChord = nil
            isRegistered = false
        }
        lastRegistrationError = failureMessage
    }

    /// Ensures the Carbon event handler is installed, unregisters any
    /// currently-held `hotKeyRef`, and attempts to register `chord`.
    /// Returns whether registration succeeded. Does NOT touch
    /// `lastRegistrationError`/`isRegistered`/`registeredChord` — callers
    /// (`registerWithFallback`) own that bookkeeping so both the
    /// requested-chord attempt and the fallback-to-previous attempt can
    /// share this one low-level routine.
    @discardableResult
    private func registerHotKey(_ chord: KeyboardShortcut) -> Bool {
        if forceNextRegistrationFailureForSelfTest {
            forceNextRegistrationFailureForSelfTest = false
            return false
        }

        if !installEventHandlerIfNeeded() {
            return false
        }

        if let existing = hotKeyRef {
            UnregisterEventHotKey(existing)
            hotKeyRef = nil
        }

        var newRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            chord.keyCode,
            Self.carbonModifiers(from: chord.modifiers),
            Self.hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newRef
        )

        guard registerStatus == noErr else {
            hotKeyRef = nil
            return false
        }

        hotKeyRef = newRef
        return true
    }

    /// Translates the core's Carbon-mirroring raw modifier bitmask
    /// (`KeyboardShortcut.cmdKey`/`shiftKey`/`optionKey`/`controlKey`) into
    /// Carbon's actual `cmdKey`/`shiftKey`/`optionKey`/`controlKey`
    /// constants. `GateOpenerCore` defines its constants as raw numbers
    /// with the SAME values specifically so this translation is a
    /// mechanical bit-for-bit OR rather than a lookup table — but it is
    /// still done explicitly, in this file, so `GateOpenerCore` never
    /// imports Carbon (see the file's HARD CONSTRAINT note).
    private static func carbonModifiers(from coreModifiers: UInt32) -> UInt32 {
        var result: UInt32 = 0
        if coreModifiers & KeyboardShortcut.cmdKey != 0 { result |= UInt32(cmdKey) }
        if coreModifiers & KeyboardShortcut.shiftKey != 0 { result |= UInt32(shiftKey) }
        if coreModifiers & KeyboardShortcut.optionKey != 0 { result |= UInt32(optionKey) }
        if coreModifiers & KeyboardShortcut.controlKey != 0 { result |= UInt32(controlKey) }
        return result
    }

    /// Installs the Carbon event handler exactly once (idempotent — safe
    /// to call on every `registerHotKey`). Returns `false` and sets
    /// `lastRegistrationError` if installation itself fails (distinct
    /// from a specific chord being unavailable).
    private func installEventHandlerIfNeeded() -> Bool {
        guard eventHandlerRef == nil else { return true }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
                var receivedID = EventHotKeyID()
                let getStatus = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard getStatus == noErr, receivedID.signature == GlobalHotkey.signature, receivedID.id == GlobalHotkey.hotKeyID.id else {
                    return OSStatus(eventNotHandledErr)
                }
                let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    hotkey.onHotkeyFired()
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )

        guard status == noErr else {
            lastRegistrationError = "Shortcut unavailable — could not install hotkey handler."
            isRegistered = false
            return false
        }
        return true
    }

    /// Unregisters the hotkey WITHOUT removing the Carbon event handler
    /// (the handler is cheap to leave installed and re-registering later
    /// does not need to reinstall it) and without touching
    /// `lastRegistrationError`. Used by `apply(.disabled)` and by
    /// `uninstall()`.
    private func uninstallHotKeyOnly() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        isRegistered = false
    }

    /// Unregisters the hotkey and removes the Carbon event handler. Call on
    /// app termination so no stale registration can linger after quit.
    func uninstall() {
        uninstallHotKeyOnly()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        registeredChord = nil
        isDisabled = false
    }

    // MARK: - Verification (GATEOPENER_MOCK_SELFTEST=1 only)

    /// Invokes the SAME handler closure passed to `init(onHotkeyFired:)` —
    /// i.e. the real production closure `AppDelegate` wires up — directly,
    /// bypassing Carbon's event dispatch entirely. This is deliberate per
    /// the bead's done-criterion: the self-test must NOT synthesize a
    /// system-wide keystroke (which could be delivered to whatever app is
    /// actually frontmost at the time), but it must still exercise the
    /// real handler logic, not a re-implementation of it.
    func invokeHandlerForSelfTest() {
        onHotkeyFired()
    }

    /// When `true`, the NEXT single call to `registerHotKey(_:)` (from
    /// either the primary or fallback attempt inside `registerWithFallback`)
    /// reports failure without touching Carbon at all, and the flag then
    /// resets itself to `false`. Exists ONLY so the self-test can
    /// deterministically exercise `apply(_:)`'s "a failed registration
    /// preserves the previously working chord" contract — a REAL Carbon
    /// registration failure (another process owning the exact combination)
    /// is not reliably reproducible from a single-process self-test.
    /// Never set outside `GATEOPENER_MOCK_SELFTEST=1` — see
    /// `GateOpenerApp.swift`'s self-test, the only caller.
    var forceNextRegistrationFailureForSelfTest = false
}
