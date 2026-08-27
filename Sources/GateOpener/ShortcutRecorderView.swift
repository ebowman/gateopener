import AppKit
import SwiftUI
// This file needs both `SwiftUI.KeyboardShortcut` and
// `GateOpenerCore.KeyboardShortcut`, which collide as bare `KeyboardShortcut`
// under a plain `import GateOpenerCore` — and `GateOpenerCore` is ALSO the
// name of a public enum declared inside the module (see
// `GateOpenerCore.swift`), so `GateOpenerCore.KeyboardShortcut` resolves to
// that enum first rather than the module, making the usual qualification
// trick unusable here too. A declaration-scoped import of just the one type
// is the clean fix: it pulls in `KeyboardShortcut` under its own name
// without importing the rest of `GateOpenerCore`'s top-level names, so nothing
// in this file needs write `GateOpenerCore.` at all — the bare
// `KeyboardShortcut` below is unambiguously the core type because
// `SwiftUI.KeyboardShortcut` is never separately imported by name.
import struct GateOpenerCore.KeyboardShortcut
import enum GateOpenerCore.ShortcutPreference

// MARK: - Pure logic (bead gateopener-3vq.3)
//
// WHY THIS LIVES HERE, NOT IN GateOpenerCore: `GateOpenerCore` is
// Foundation-only (see `KeyboardShortcut.swift`'s HARD CONSTRAINT doc
// comment). The keystroke classification below takes `NSEvent.ModifierFlags`
// as input, which is an AppKit type, so it cannot move to `GateOpenerCore`
// without violating that constraint. There is currently no XCTest target
// covering `Sources/GateOpener/` (known gap, bead gateopener-4ub.22), so per
// the bead's instructions this logic is instead exercised by the
// `GATEOPENER_MOCK_SELFTEST=1` self-test in `GateOpenerApp.swift`, printed
// in the existing `SELFTEST …` style — see the assertions added there.
//
// Everything in this section is a pure function/enum: no AppKit view, no
// NSResponder, no I/O. `ShortcutRecorderView`/`RecorderNSView` below are
// thin AppKit/SwiftUI plumbing over this logic.

/// The three visually distinct states the recorder control can be in.
/// Mirrors `ShortcutPreference` but adds `.recording`, which has no
/// persisted-preference equivalent — it is purely transient UI state.
enum RecorderDisplayState: Equatable {
    /// Showing the current chord (or the "no shortcut" glyph if there is
    /// none) at rest.
    case idle
    /// Actively capturing keystrokes; visually distinct (highlighted
    /// border + prompt) so it is obvious input is being captured.
    case recording
}

/// The result of classifying one `keyDown`/`flagsChanged` event received
/// while recording.
enum RecorderKeystrokeClassification: Equatable {
    /// A modifier flag changed but no real key has been pressed yet (e.g.
    /// just holding Command). Recording must keep waiting — this must
    /// NEVER be captured as a chord on its own.
    case modifierOnly
    /// Escape was pressed: cancel recording and restore the previous
    /// value without changing anything.
    case cancel
    /// Delete/Backspace was pressed while recording: an explicit "clear to
    /// no shortcut" gesture, equivalent to pressing the ✕ button.
    case clear
    /// A complete key + modifier chord was captured. Carries the raw
    /// key code and the CORE's numeric modifier mask (already translated
    /// by `RecorderModifierMapping`, so nothing downstream of this enum
    /// needs to know about `NSEvent.ModifierFlags` at all).
    case chord(keyCode: UInt32, modifiers: UInt32)

    /// Classifies a `keyDown(with:)` event received while recording.
    /// `flagsChanged(with:)` events (bare modifier presses with no key)
    /// never reach this function — see `RecorderNSView.flagsChanged`,
    /// which is exactly where `.modifierOnly` would apply for a KEY-UP-less
    /// modifier tap; `keyDown` always carries a real key code, so this
    /// classifier's only job for `keyDown` is to distinguish
    /// escape/delete/backspace from an ordinary key that completes a chord.
    static func classify(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags) -> RecorderKeystrokeClassification {
        let coreModifiers = RecorderModifierMapping.coreModifiers(from: modifierFlags)

        // kVK_Escape = 53.
        if keyCode == 53 {
            return .cancel
        }
        // kVK_Delete (Backspace) = 51, kVK_ForwardDelete = 117. Either
        // clears to "no shortcut" per the bead's explicit requirement,
        // regardless of what modifiers happen to be held.
        if keyCode == 51 || keyCode == 117 {
            return .clear
        }

        return .chord(keyCode: keyCode, modifiers: coreModifiers)
    }
}

/// Translates AppKit's `NSEvent.ModifierFlags` into the raw numeric mask
/// `KeyboardShortcut` expects. Isolated in its own enum
/// (rather than inlined) so it is a single, obviously-correct mapping used
/// by both the classifier above and `RecorderNSView.flagsChanged`'s
/// modifier-only check.
enum RecorderModifierMapping {
    static func coreModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= KeyboardShortcut.cmdKey }
        if flags.contains(.shift) { result |= KeyboardShortcut.shiftKey }
        if flags.contains(.option) { result |= KeyboardShortcut.optionKey }
        if flags.contains(.control) { result |= KeyboardShortcut.controlKey }
        return result
    }
}

// MARK: - AppKit view

/// A focusable, click-to-activate control that looks like a text field but
/// is NOT a SwiftUI `TextField` — a `TextField` can only ever report
/// composed text, never an arbitrary modifier chord like ⌃⌥⌘G (Option
/// alone would compose an accented character; Command is invisible to text
/// input entirely). This is a plain `NSView` subclass wrapped by
/// `ShortcutRecorderView` (an `NSViewRepresentable`) instead, so it can
/// become first responder and override `performKeyEquivalent(with:)` /
/// `keyDown(with:)` / `flagsChanged(with:)` directly — the standard
/// approach used by every macOS shortcut-recorder control (System
/// Settings' own included).
///
/// - `performKeyEquivalent(with:)` is overridden and returns `true`
///   whenever this view is recording, which is what stops a captured
///   keystroke (e.g. ⌘Q) from leaking through to the app's main menu or
///   any other responder — returning `true` tells AppKit "handled, stop
///   dispatching this event" at the point key equivalents are resolved,
///   before `keyDown` would even be reached for menu-equivalent keys.
/// - `keyDown(with:)` is the actual capture path for the common case
///   (non-menu-equivalent keys reach here directly without ever visiting
///   `performKeyEquivalent`).
/// - `flagsChanged(with:)` is used ONLY to detect "still just holding
///   modifiers, no key pressed yet" — bare modifier taps must never be
///   captured as a chord.
final class RecorderNSView: NSView {
    var displayState: RecorderDisplayState = .idle {
        didSet { needsDisplay = true }
    }
    var currentChord: KeyboardShortcut?

    /// Called with a classification result whenever a relevant event
    /// arrives while recording. `ShortcutRecorderView.Coordinator` supplies
    /// this and owns all state transitions — this view is deliberately
    /// dumb about WHAT a classification means, only about detecting and
    /// reporting it.
    var onKeystroke: ((RecorderKeystrokeClassification) -> Void)?

    /// Called when the view loses first responder status (click elsewhere,
    /// window loses key, etc.) while recording, so the coordinator can
    /// cancel deterministically — this is what guarantees recording can
    /// never get stuck.
    var onResignWhileRecording: (() -> Void)?

    /// Called on a plain click while IDLE, so the coordinator can start
    /// recording (capturing the pre-recording preference for a clean
    /// Escape revert). Not called while already recording — clicking
    /// again mid-recording is a no-op, it does not restart the capture.
    var onActivateClick: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if displayState != .recording {
            onActivateClick?()
        }
        // Do NOT call super — this is a control, not a click-through
        // container; a click always means "activate me", never "pass this
        // through".
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        needsDisplay = true
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if displayState == .recording {
            onResignWhileRecording?()
        }
        needsDisplay = true
        return resigned
    }

    /// Intercepts key equivalents (including ones that would otherwise be
    /// claimed by the main menu, e.g. ⌘Q, ⌘W, ⌘,) while recording, so a
    /// captured chord can NEVER leak through to the rest of the app. Only
    /// active while recording — when idle, this view has no opinion on key
    /// equivalents and lets them flow through normally (critical so the
    /// password field elsewhere in Settings, and every other menu
    /// shortcut, is completely unaffected).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard displayState == .recording else { return false }
        handleKeyEvent(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard displayState == .recording else {
            super.keyDown(with: event)
            return
        }
        handleKeyEvent(event)
    }

    /// Bare modifier presses (no key) arrive here, never in `keyDown`.
    /// While recording, a modifier-only event must be explicitly ignored
    /// as "still waiting for a real key" rather than silently doing
    /// nothing indistinguishable from a bug — routed through the same
    /// classification enum via `.modifierOnly` so the coordinator can, if
    /// it wants, keep the "Type a shortcut…" prompt visibly unchanged.
    override func flagsChanged(with event: NSEvent) {
        guard displayState == .recording else {
            super.flagsChanged(with: event)
            return
        }
        onKeystroke?(.modifierOnly)
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let classification = RecorderKeystrokeClassification.classify(
            keyCode: UInt32(event.keyCode),
            modifierFlags: event.modifierFlags
        )
        onKeystroke?(classification)
    }

    // MARK: - Drawing

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let isRecording = displayState == .recording
        let bounds = self.bounds

        // Background: white at rest, a pale highlight while recording so
        // the RECORDING state is unmistakably visually distinct from IDLE.
        let backgroundColor: NSColor = isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.textBackgroundColor
        backgroundColor.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.fill()

        // Border: accent-colored and thicker while recording (the
        // "highlighted border" the bead calls for); a plain hairline at
        // rest.
        let borderColor: NSColor = isRecording ? .controlAccentColor : NSColor.separatorColor
        borderColor.setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        // Text content.
        let text: String
        let textColor: NSColor
        if isRecording {
            text = "Type a shortcut…"
            textColor = .controlAccentColor
        } else if let currentChord {
            text = currentChord.displayString
            textColor = .labelColor
        } else {
            // NONE state: an explicit, clearly-worded label — never an
            // empty field, which would look broken rather than
            // deliberately "off".
            text = "No shortcut"
            textColor = .secondaryLabelColor
        }

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let textRect = NSRect(
            x: 10,
            y: (bounds.height - textSize.height) / 2,
            width: bounds.width - 20,
            height: textSize.height
        )
        attributed.draw(in: textRect)
    }
}

// MARK: - SwiftUI wrapper

/// The recorder control's `View` binding, standing in for
/// `GlobalHotkeySectionView`'s previous read-only display.
///
/// State-machine ownership: ALL state transitions (idle -> recording,
/// recording -> idle with a captured/cleared/cancelled result, validation
/// rejection) are decided by `Coordinator`, which is the only place that
/// interprets a `RecorderKeystrokeClassification`. `RecorderNSView` only
/// detects and reports events; it has no opinion on what they mean beyond
/// classification.
struct ShortcutRecorderView: NSViewRepresentable {
    /// The currently-effective preference. Read by the view to render IDLE
    /// (custom chord), NONE (`.disabled`), or the default (`.unset`).
    @Binding var preference: ShortcutPreference
    /// A short, transient validation message (e.g. "Use at least two
    /// modifiers — this opens your gate"), shown by the CALLER
    /// (`GlobalHotkeySectionView`) below the recorder, not drawn inside
    /// this view itself — keeping this view focused purely on the
    /// field/recording affordance.
    @Binding var validationMessage: String?

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.currentChord = displayedChord
        view.onKeystroke = { classification in
            context.coordinator.handle(classification, view: view)
        }
        view.onResignWhileRecording = {
            context.coordinator.cancelRecording(view: view)
        }
        view.onActivateClick = { [weak view] in
            guard let view else { return }
            context.coordinator.startRecording(view: view)
        }
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        context.coordinator.parent = self
        // Do not stomp on an in-progress recording's display state if the
        // binding happens to re-publish while recording (e.g. an unrelated
        // observable change elsewhere in Settings).
        guard nsView.displayState != .recording else { return }
        nsView.currentChord = displayedChord
        nsView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private var displayedChord: KeyboardShortcut? {
        switch preference {
        case .unset: return KeyboardShortcut.defaultChord
        case .disabled: return nil
        case .custom(let chord): return chord
        }
    }

    @MainActor
    final class Coordinator {
        var parent: ShortcutRecorderView
        /// The preference to restore if recording is cancelled (Escape,
        /// or losing first responder). Captured at the moment recording
        /// starts so a cancel is always a clean revert, never a
        /// best-effort guess.
        private var preferenceBeforeRecording: ShortcutPreference?

        init(parent: ShortcutRecorderView) {
            self.parent = parent
        }

        func startRecording(view: RecorderNSView) {
            preferenceBeforeRecording = parent.preference
            parent.validationMessage = nil
            view.displayState = .recording
        }

        func cancelRecording(view: RecorderNSView) {
            guard view.displayState == .recording else { return }
            if let preferenceBeforeRecording {
                parent.preference = preferenceBeforeRecording
            }
            preferenceBeforeRecording = nil
            parent.validationMessage = nil
            view.displayState = .idle
            view.currentChord = parent.displayedChord
            view.needsDisplay = true
        }

        func handle(_ classification: RecorderKeystrokeClassification, view: RecorderNSView) {
            guard view.displayState == .recording else { return }

            switch classification {
            case .modifierOnly:
                // Keep waiting — do not change state, do not clear the
                // "Type a shortcut…" prompt.
                return

            case .cancel:
                cancelRecording(view: view)

            case .clear:
                preferenceBeforeRecording = nil
                parent.validationMessage = nil
                parent.preference = .disabled
                view.displayState = .idle
                view.currentChord = nil
                view.needsDisplay = true

            case .chord(let keyCode, let modifiers):
                let candidate = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
                if candidate.isValid {
                    preferenceBeforeRecording = nil
                    parent.validationMessage = nil
                    parent.preference = .custom(candidate)
                    view.displayState = .idle
                    view.currentChord = candidate
                    view.needsDisplay = true
                } else {
                    // Reject with visible feedback; STAY in recording so
                    // the user can immediately try again, per the bead's
                    // "recording either continues or reverts cleanly"
                    // requirement — continuing is the better UX here since
                    // the user is mid-gesture.
                    parent.validationMessage = "Use at least two modifiers — this opens your gate."
                }
            }
        }
    }
}
