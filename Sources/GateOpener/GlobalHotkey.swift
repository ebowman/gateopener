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
/// ## Default shortcut
///
/// Cmd-Ctrl-Option-G. Verified (2026-08-27, on the machine this was built
/// on) against `com.apple.symbolichotkeys`'s `AppleSymbolicHotKeys`
/// dictionary — exported via `defaults export` and inspected programmatically
/// — that:
///   - no entry uses key code 5 (the `G` key) at all, under any modifier
///     combination, and
///   - no entry's modifier mask includes Command+Control+Option together
///     (regardless of key).
/// This is a triple-modifier chord; it cannot be produced by ordinary
/// typing (see `install()`'s doc comment on accidental-firing risk), and
/// does not collide with any macOS default shortcut on this system.
///
/// ## Registration failure
///
/// If another app has already claimed this exact combination,
/// `RegisterEventHotKey` returns a non-`noErr` status. `install()` treats
/// that as a soft failure: it records `lastRegistrationError` (read by
/// Settings — see `SettingsView`'s "Keyboard Shortcut" section) and
/// returns without crashing or throwing. The status item and Settings
/// continue to work normally; only the hotkey itself is inert.
@MainActor
final class GlobalHotkey {
    /// The chord this app registers by default: Cmd-Ctrl-Option-G.
    /// Exposed so Settings can display it without duplicating the literal.
    static let displayString = "⌘⌃⌥G"

    private static let signature: OSType = {
        // Any 4-char OSType uniquely identifying this app's hotkey to the
        // Carbon Event Manager; arbitrary but stable.
        let bytes: [UInt8] = Array("GTOP".utf8)
        return (OSType(bytes[0]) << 24) | (OSType(bytes[1]) << 16) | (OSType(bytes[2]) << 8) | OSType(bytes[3])
    }()
    private static let hotKeyID = EventHotKeyID(signature: signature, id: 1)

    /// `kVK_ANSI_G` = 5, `cmdKey | controlKey | optionKey` — the
    /// Cmd-Ctrl-Option-G chord described above.
    private static let keyCode: UInt32 = UInt32(kVK_ANSI_G)
    private static let modifiers: UInt32 = UInt32(cmdKey | controlKey | optionKey)

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

    /// Non-nil iff the most recent `install()` call failed to register the
    /// hotkey (e.g. another app already owns the combination). `nil` means
    /// either registration has not been attempted yet or it succeeded.
    /// Read by `SettingsView` to surface a "Shortcut unavailable" message
    /// rather than failing silently.
    private(set) var lastRegistrationError: String?

    /// True iff the hotkey is currently registered with the system and
    /// expected to fire. Read by `SettingsView`.
    private(set) var isRegistered = false

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

    /// Registers the global hotkey. Safe to call even if registration
    /// fails: on failure, `lastRegistrationError` is set and this method
    /// returns without throwing or crashing — the caller (AppDelegate)
    /// does not need a do/catch.
    ///
    /// ## Accidental-firing risk
    ///
    /// Cmd-Ctrl-Option-G requires three simultaneous modifier keys plus a
    /// letter. No ordinary typing, and no single-or-double-modifier system
    /// shortcut, can produce this combination by accident. Considered and
    /// rejected as implausible: a user resting fingers on modifier keys
    /// while typing "g" would need to be holding Cmd, Control, AND Option
    /// simultaneously while pressing G — not a pattern that occurs in
    /// normal typing, shortcuts, or games. This is the standard rationale
    /// for using a triple-modifier chord for a destructive/physical-effect
    /// action.
    func install() {
        // Install the Carbon event handler exactly once; re-registering the
        // hotkey itself (e.g. if `install()` were called twice) is handled
        // by unregistering any existing `hotKeyRef` first.
        if eventHandlerRef == nil {
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
                return
            }
        }

        if let existing = hotKeyRef {
            UnregisterEventHotKey(existing)
            hotKeyRef = nil
        }

        var newRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            Self.keyCode,
            Self.modifiers,
            Self.hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newRef
        )

        if registerStatus == noErr {
            hotKeyRef = newRef
            isRegistered = true
            lastRegistrationError = nil
        } else {
            hotKeyRef = nil
            isRegistered = false
            // `RegisterEventHotKey` fails (most commonly with
            // `eventHotKeyExistsErr`) when another app already owns this
            // exact key+modifier combination. Surfaced in Settings rather
            // than thrown/crashed — see the type's doc comment.
            lastRegistrationError = "Shortcut unavailable — another app is using \(Self.displayString)."
        }
    }

    /// Unregisters the hotkey and removes the Carbon event handler. Call on
    /// app termination so no stale registration can linger after quit.
    func uninstall() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        isRegistered = false
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
}
