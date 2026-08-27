import AppKit
import SwiftUI
import GateOpenerCore

/// `@main` entry point. Deliberately an `NSApplicationDelegate`-driven
/// AppKit app (not a SwiftUI `App`/`MenuBarExtra` scene) because
/// `MenuBarExtra` cannot cleanly express left-click-fires / right-click-menu
/// — see `StatusItemController`'s doc comment.
@main
struct GateOpenerMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // `.accessory`: no Dock icon, no menu bar app-switcher entry, no
        // main-menu window — the app lives entirely in its status item.
        // Equivalent in effect to setting `LSUIElement` in Info.plist, done
        // in code so no Info.plist/bundle resources are required for a
        // plain SwiftPM executable target.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observable: GateControllerObservable!
    private var statusItemController: StatusItemController!
    private var notificationPresenter: NotificationPresenter!
    private var hasAutoOpenedSettings = false
    /// Set only under `GATEOPENER_MOCK=1`, so the self-test path can read
    /// call counts directly without `GateController` needing to expose its
    /// private `gateClient` dependency.
    private var mockGateOpeningForSelfTest: MockGateOpening?
    /// The app's shared `EventLog` (bead gateopener-4ub.10). Kept as a
    /// property (not just a local in `applicationDidFinishLaunching`) so
    /// `runSelfTestAndExit()` can assert real entries were recorded by a
    /// simulated open attempt.
    private var eventLog: EventLog!
    /// The app's global hotkey (bead gateopener-iif.2). Kept as a property
    /// so it can be unregistered on termination (`applicationWillTerminate`)
    /// and so `runSelfTestAndExit()` can invoke its handler directly. `nil`
    /// only before `applicationDidFinishLaunching` has run.
    private var globalHotkey: GlobalHotkey!
    /// The `AppSettings` instance backing this launch (mock or real),
    /// written by `makeGateController`. Read once at launch to apply the
    /// persisted `shortcutPreference` to `globalHotkey` (bead
    /// gateopener-3vq.2) and kept so the self-test can mutate/re-apply the
    /// preference directly.
    private var appSettings: AppSettings!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Must happen before any window is shown (the Settings window can
        // auto-open below on `.needsSetup`) so the Edit menu exists the
        // first time a text field becomes first responder. See
        // MainMenu.swift for the root-cause explanation (bead
        // gateopener-iif.1): without this, Cmd-V/C/X/A/Z are unbound in
        // every text field because AppKit never installs a main menu for
        // an `.accessory`/`LSUIElement` app on its own.
        MainMenu.install()

        var appSettingsForLaunch: AppSettings?
        let controller = Self.makeGateController(mockOut: &mockGateOpeningForSelfTest, appSettingsOut: &appSettingsForLaunch)
        self.appSettings = appSettingsForLaunch
        let observable = GateControllerObservable(controller: controller)
        self.observable = observable
        GateControllerObservable.appShared = observable

        let statusItemController = StatusItemController(observable: observable)
        self.statusItemController = statusItemController

        guard statusItemController.install() else {
            presentStatusItemUnavailableAlertAndExit()
            return
        }

        // `GateControllerObservable`'s own `onStateChange` subscription
        // (installed in its initializer) already keeps `observable.state`
        // current; chain a second hook onto the SAME `onStateChange`
        // property so the status item also repaints on every transition.
        // `GateControllerObservable` is created first, so its subscription
        // is already installed — wrap it rather than clobber it.
        let observableStateChange = controller.onStateChange
        let notificationPresenter = NotificationPresenter { [weak controller] in
            Task { await controller?.openGate() }
        }
        self.notificationPresenter = notificationPresenter

        // Global hotkey (bead gateopener-iif.2): mirrors
        // `StatusItemController.handleLeftClick()` exactly — if the app
        // still needs first-time setup, open Settings instead of firing a
        // doomed open; otherwise reuse the SAME `openGate()` call a
        // left-click makes (already idempotent against double-fires, so no
        // additional `.opening` guard is needed here beyond what
        // `openGate()` itself provides).
        let globalHotkey = GlobalHotkey { [weak controller] in
            guard let controller else { return }
            if case .needsSetup = controller.state {
                SettingsWindowController.showShared()
                return
            }
            Task {
                await controller.openGate()
            }
        }
        // Bead gateopener-3vq.2: apply the PERSISTED preference rather than
        // always registering the hardcoded default. `apply(_:)` itself
        // handles `.unset` (default chord), `.disabled` (no hotkey,
        // reported distinctly from a failure), and `.custom` (validated
        // before registering — an invalid persisted chord falls back to
        // the default rather than being registered as-is).
        globalHotkey.apply(appSettings.shortcutPreference)
        self.globalHotkey = globalHotkey
        observable.globalHotkey = globalHotkey

        // The app's single `EventLog` instance (bead gateopener-4ub.10).
        // Reachable by the Settings UI via `GateControllerObservable.eventLog`
        // (set once, immediately below) so `SettingsView`'s log section can
        // render real entries instead of the placeholder left by bead .9.
        let eventLog = EventLog()
        self.eventLog = eventLog
        observable.eventLog = eventLog

        // Records `.opening` -> `.succeeded`/`.failed` transitions. This is
        // the seam available from the app layer: `GateState` itself only
        // carries a short human-readable failure `message`, not a
        // per-attempt count or HTTP status code (those live inside
        // `GateClient.open`'s internal retry loop in `GateOpenerCore`,
        // which this bead does not restructure) — so every open here is
        // logged as a single attempt (1 of 1), and every failure is logged
        // via the closed `OpenFailureReason.unknown` case rather than a
        // real HTTP status, since no status is observable from here. See
        // the bead .10 report for the full list of event kinds this does
        // and does not cover.
        var lastLoggedStateWasOpening = false
        controller.onStateChange = { [weak self] state in
            observableStateChange?(state)
            self?.statusItemController.render(for: state)
            notificationPresenter.handle(state)

            switch state {
            case .opening:
                lastLoggedStateWasOpening = true
                eventLog.logOpenAttempt(attempt: 1, of: 1)
            case .succeeded:
                if lastLoggedStateWasOpening {
                    eventLog.logOpenSucceeded()
                }
                lastLoggedStateWasOpening = false
            case .failed:
                if lastLoggedStateWasOpening {
                    eventLog.logOpenFailed(attempt: 1, of: 1, reason: .unknown)
                }
                lastLoggedStateWasOpening = false
            case .needsSetup, .idle:
                lastLoggedStateWasOpening = false
            }
        }

        if case .needsSetup = controller.state, !hasAutoOpenedSettings {
            hasAutoOpenedSettings = true
            SettingsWindowController.showShared()
        }

        if ProcessInfo.processInfo.environment["GATEOPENER_MOCK_SELFTEST"] == "1" {
            runSelfTestAndExit()
        }
    }

    /// Verification path for the bead .8 done-criteria: proves, via the
    /// REAL production click-handling code path (`StatusItemController`'s
    /// `statusItemClicked(_:)`), that a left click calls `openGate()`
    /// exactly once and a right click calls it zero times — all against
    /// `MockGateOpening`, never the real gate. Prints a machine-checkable
    /// summary line and exits. Only runs when both `GATEOPENER_MOCK=1` and
    /// `GATEOPENER_MOCK_SELFTEST=1` are set.
    private func runSelfTestAndExit() {
        guard let mock = mockGateOpeningForSelfTest else {
            print("SELFTEST FAIL: not running against MockGateOpening")
            exit(1)
        }
        // The real `showMenu()` calls the BLOCKING/modal `NSMenu.popUp`,
        // which never returns in a headless process with no one to dismiss
        // it. Swap in a non-blocking recorder so the self-test can still
        // prove a right-click was routed to "show the menu" (and NOT to
        // `handleLeftClick()`) without hanging.
        var menuRequestedCount = 0
        statusItemController.onMenuRequestedForSelfTest = { menuRequestedCount += 1 }

        // Bead gateopener-iif.1: prove `MainMenu.install()` actually
        // produced a usable Edit menu, since AppKit does not install one
        // automatically for an `.accessory`/`LSUIElement` app. Checked
        // directly against `NSApp.mainMenu` (the real production object),
        // not a re-built copy.
        let mainMenu = NSApp.mainMenu
        let mainMenuPresent = mainMenu != nil
        let editMenu = mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu
        let editMenuPresent = editMenu != nil
        func editMenuHasItem(keyEquivalent: String, action: Selector) -> Bool {
            editMenu?.items.contains { $0.keyEquivalent == keyEquivalent && $0.action == action } ?? false
        }
        let hasPasteItem = editMenuHasItem(keyEquivalent: "v", action: #selector(NSText.paste(_:)))
        let hasCopyItem = editMenuHasItem(keyEquivalent: "c", action: #selector(NSText.copy(_:)))
        let hasSelectAllItem = editMenuHasItem(keyEquivalent: "a", action: #selector(NSText.selectAll(_:)))

        print("SELFTEST mainMenu present: \(mainMenuPresent)")
        print("SELFTEST edit menu present: \(editMenuPresent)")
        print("SELFTEST edit menu paste item: \(hasPasteItem)")
        print("SELFTEST edit menu copy item: \(hasCopyItem)")
        print("SELFTEST edit menu select all item: \(hasSelectAllItem)")

        Task { @MainActor in
            statusItemController.simulateClickForSelfTest(rightClick: true)
            try? await Task.sleep(for: .milliseconds(200))
            let afterRightClick = await mock.openCallCount

            statusItemController.simulateClickForSelfTest(rightClick: false)
            try? await Task.sleep(for: .milliseconds(700))
            let afterLeftClick = await mock.openCallCount

            // Prove EventLog actually records real events (bead
            // gateopener-4ub.10 defect 1): the left click above drove a
            // real `.opening` -> `.succeeded` transition through
            // `controller.onStateChange`, which must have appended a
            // "open attempted" entry and an "open succeeded" entry to the
            // app's shared EventLog.
            let logText = self.eventLog.formattedText()
            let logEntryCount = self.eventLog.snapshot().count
            let logRecordedAttempt = logText.contains("open attempted")
            let logRecordedSuccess = logText.contains("open succeeded")

            print("SELFTEST menu-shown count after right-click: \(menuRequestedCount)")
            print("SELFTEST openCallCount after right-click: \(afterRightClick)")
            print("SELFTEST openCallCount after left-click: \(afterLeftClick)")
            print("SELFTEST eventLog entry count: \(logEntryCount)")
            print("SELFTEST eventLog recorded open attempt: \(logRecordedAttempt)")
            print("SELFTEST eventLog recorded open success: \(logRecordedSuccess)")

            // Bead gateopener-iif.2: prove the global hotkey's HANDLER (the
            // exact closure `AppDelegate` wired into `GlobalHotkey.init`,
            // invoked directly — never a synthesized system-wide keystroke,
            // which could be delivered to whatever app is actually
            // frontmost) calls `openGate()` exactly once when state is not
            // `.needsSetup`.
            let hotkeyRegistered = self.globalHotkey.isRegistered
            let hotkeyRegistrationError = self.globalHotkey.lastRegistrationError
            let beforeHotkey = await mock.openCallCount
            self.globalHotkey.invokeHandlerForSelfTest()
            try? await Task.sleep(for: .milliseconds(700))
            let afterHotkey = await mock.openCallCount
            let hotkeyOpenCallCount = afterHotkey - beforeHotkey

            print("SELFTEST hotkey registered: \(hotkeyRegistered)")
            print("SELFTEST hotkey registration error: \(hotkeyRegistrationError ?? "none")")
            print("SELFTEST hotkey openCallCount: \(hotkeyOpenCallCount)")

            // Mirror the left-click `.needsSetup` behaviour: drive the
            // REAL controller to `.needsSetup` via the same public
            // `signOut()` API `SettingsView`'s "Sign Out" button calls, then
            // invoke the hotkey handler again and assert it produced ZERO
            // additional open calls (it must open Settings instead of
            // firing a doomed open — see `GlobalHotkey`'s wiring in
            // `applicationDidFinishLaunching`).
            self.observable.controller.signOut()
            try? await Task.sleep(for: .milliseconds(50))
            let stateIsNeedsSetup = self.observable.controller.state == .needsSetup
            let beforeHotkeyNeedsSetup = await mock.openCallCount
            self.globalHotkey.invokeHandlerForSelfTest()
            try? await Task.sleep(for: .milliseconds(200))
            let afterHotkeyNeedsSetup = await mock.openCallCount
            let hotkeyNeedsSetupOpenCallCount = afterHotkeyNeedsSetup - beforeHotkeyNeedsSetup

            print("SELFTEST controller state is .needsSetup after signOut: \(stateIsNeedsSetup)")
            print("SELFTEST hotkey openCallCount while .needsSetup: \(hotkeyNeedsSetupOpenCallCount)")

            // Bead gateopener-3vq.2: prove `GlobalHotkey.apply(_:)` against
            // the REAL production instance (`self.globalHotkey`, already
            // registered with the default chord above), not a fresh copy.

            // 1) .disabled -> unregistered, and reported as a deliberate
            // "no hotkey" state, NOT a registration failure (no error set).
            self.globalHotkey.apply(.disabled)
            let disabledIsRegistered = self.globalHotkey.isRegistered
            let disabledIsDisabled = self.globalHotkey.isDisabled
            let disabledHasNoError = self.globalHotkey.lastRegistrationError == nil
            print("SELFTEST apply(.disabled) isRegistered: \(disabledIsRegistered)")
            print("SELFTEST apply(.disabled) isDisabled: \(disabledIsDisabled)")
            print("SELFTEST apply(.disabled) has no error: \(disabledHasNoError)")

            // Applying .disabled AGAIN must be a harmless no-op, not an
            // error.
            self.globalHotkey.apply(.disabled)
            let disabledTwiceIsRegistered = self.globalHotkey.isRegistered
            let disabledTwiceHasNoError = self.globalHotkey.lastRegistrationError == nil
            print("SELFTEST apply(.disabled) twice still isRegistered false: \(disabledTwiceIsRegistered == false)")
            print("SELFTEST apply(.disabled) twice still has no error: \(disabledTwiceHasNoError)")

            // 2) A valid custom chord registers successfully.
            let validCustomChord = KeyboardShortcut(keyCode: 1, modifiers: KeyboardShortcut.cmdKey | KeyboardShortcut.controlKey | KeyboardShortcut.optionKey)
            self.globalHotkey.apply(.custom(validCustomChord))
            let validCustomIsRegistered = self.globalHotkey.isRegistered
            let validCustomChordMatches = self.globalHotkey.currentChord == validCustomChord
            print("SELFTEST apply(.custom(valid)) isRegistered: \(validCustomIsRegistered)")
            print("SELFTEST apply(.custom(valid)) registered the requested chord: \(validCustomChordMatches)")

            // 3) An INVALID custom chord (fewer than two modifiers) must
            // fall back to the DEFAULT chord — registered, not nothing —
            // never registered as-is. This is the safety gate: this chord
            // fires a real physical gate open, so a single-modifier/bare
            // chord must never reach live registration.
            let invalidCustomChord = KeyboardShortcut(keyCode: 5, modifiers: KeyboardShortcut.cmdKey)
            let invalidChordIsValid = invalidCustomChord.isValid
            self.globalHotkey.apply(.custom(invalidCustomChord))
            let invalidCustomIsRegistered = self.globalHotkey.isRegistered
            let invalidCustomFellBackToDefault = self.globalHotkey.currentChord == KeyboardShortcut.defaultChord
            print("SELFTEST invalid custom chord correctly rejected by isValid: \(invalidChordIsValid == false)")
            print("SELFTEST apply(.custom(invalid)) isRegistered: \(invalidCustomIsRegistered)")
            print("SELFTEST apply(.custom(invalid)) fell back to default chord: \(invalidCustomFellBackToDefault)")

            // 4) After a FAILED registration, the previously working chord
            // is still registered. A REAL Carbon registration failure
            // (another process already owning the exact combination) is
            // not reliably reproducible from a single-process self-test,
            // so `forceNextRegistrationFailureForSelfTest` makes the NEXT
            // `RegisterEventHotKey` call fail deterministically WITHOUT
            // touching Carbon — this exercises the real `apply(_:)` /
            // `registerWithFallback` fallback logic exactly as production
            // would run it on a genuine collision, only with a
            // deterministically-triggered failure instead of an
            // environment-dependent one.
            self.globalHotkey.apply(.custom(validCustomChord))
            let beforeFailureChord = self.globalHotkey.currentChord
            let beforeFailureIsRegistered = self.globalHotkey.isRegistered

            self.globalHotkey.forceNextRegistrationFailureForSelfTest = true
            let differentChord = KeyboardShortcut(keyCode: 3, modifiers: KeyboardShortcut.cmdKey | KeyboardShortcut.controlKey | KeyboardShortcut.optionKey)
            self.globalHotkey.apply(.custom(differentChord))

            let afterFailureChord = self.globalHotkey.currentChord
            let afterFailureIsRegistered = self.globalHotkey.isRegistered
            let afterFailureError = self.globalHotkey.lastRegistrationError
            print("SELFTEST before forced failure: chord=\(beforeFailureChord?.displayString ?? "nil") registered=\(beforeFailureIsRegistered)")
            print("SELFTEST after forced registration failure still registered: \(afterFailureIsRegistered)")
            print("SELFTEST after forced registration failure chord unchanged: \(afterFailureChord == beforeFailureChord)")
            print("SELFTEST after forced registration failure error reported: \(afterFailureError != nil)")

            // Bead gateopener-3vq.3: exercise the recorder's PURE logic
            // (`RecorderKeystrokeClassification.classify`,
            // `RecorderModifierMapping.coreModifiers`, and
            // `ShortcutRecorderView.Coordinator`'s idle/recording state
            // machine) directly — no NSApp event dispatch, no synthesized
            // keystrokes, per the bead's safety constraint. See
            // `ShortcutRecorderView.swift`'s file-level doc comment for why
            // this logic lives in the app layer rather than
            // `GateOpenerCore`, and is self-tested here rather than left
            // untested, given the known gap (bead gateopener-4ub.22) of no
            // XCTest target covering `Sources/GateOpener/`.

            // 1) Modifier mapping: Carbon-mirroring bits, bit-for-bit.
            let mappedCmdCtrlOpt = RecorderModifierMapping.coreModifiers(from: [.command, .control, .option])
            let expectedCmdCtrlOpt = KeyboardShortcut.cmdKey | KeyboardShortcut.controlKey | KeyboardShortcut.optionKey
            let mappedNone = RecorderModifierMapping.coreModifiers(from: [])
            print("SELFTEST recorder modifier mapping cmd+ctrl+opt: \(mappedCmdCtrlOpt == expectedCmdCtrlOpt)")
            print("SELFTEST recorder modifier mapping empty flags: \(mappedNone == 0)")

            // 2) Keystroke classification: escape -> cancel, delete/forward
            // delete -> clear, an ordinary key -> chord carrying the
            // translated modifier mask, regardless of what modifiers are
            // held for escape/delete (those must win over any chord
            // interpretation).
            let classifyEscape = RecorderKeystrokeClassification.classify(keyCode: 53, modifierFlags: [.command, .control])
            let classifyDelete = RecorderKeystrokeClassification.classify(keyCode: 51, modifierFlags: [])
            let classifyForwardDelete = RecorderKeystrokeClassification.classify(keyCode: 117, modifierFlags: [.shift])
            let classifyChord = RecorderKeystrokeClassification.classify(keyCode: 5, modifierFlags: [.command, .control, .option])
            print("SELFTEST recorder classify escape -> cancel: \(classifyEscape == .cancel)")
            print("SELFTEST recorder classify delete -> clear: \(classifyDelete == .clear)")
            print("SELFTEST recorder classify forward-delete -> clear: \(classifyForwardDelete == .clear)")
            print("SELFTEST recorder classify G+cmd+ctrl+opt -> chord: \(classifyChord == .chord(keyCode: 5, modifiers: expectedCmdCtrlOpt))")

            // 3) Coordinator state machine, driven through a throwaway
            // `ShortcutRecorderView`/`RecorderNSView` pair — the SAME types
            // production uses, just never attached to a window, so no
            // click/focus/keyboard event dispatch is involved (see the
            // bead's "could not verify headlessly" list below).
            var recorderPreference: ShortcutPreference = .custom(KeyboardShortcut.defaultChord)
            var recorderValidationMessage: String?
            let recorderPreferenceBinding = Binding(get: { recorderPreference }, set: { recorderPreference = $0 })
            let recorderValidationBinding = Binding(get: { recorderValidationMessage }, set: { recorderValidationMessage = $0 })
            let recorderView = ShortcutRecorderView(preference: recorderPreferenceBinding, validationMessage: recorderValidationBinding)
            let coordinator = recorderView.makeCoordinator()
            let nsView = RecorderNSView()
            nsView.onKeystroke = { [weak nsView] classification in
                guard let nsView else { return }
                coordinator.handle(classification, view: nsView)
            }

            // 3a) Idle -> recording on activation.
            coordinator.startRecording(view: nsView)
            let becameRecording = nsView.displayState == .recording
            print("SELFTEST recorder coordinator startRecording enters .recording: \(becameRecording)")

            // 3b) A modifier-only event while recording must NOT change
            // state or preference.
            coordinator.handle(.modifierOnly, view: nsView)
            let stillRecordingAfterModifierOnly = nsView.displayState == .recording
            let preferenceUnchangedAfterModifierOnly = recorderPreference == .custom(KeyboardShortcut.defaultChord)
            print("SELFTEST recorder coordinator modifierOnly keeps recording: \(stillRecordingAfterModifierOnly)")
            print("SELFTEST recorder coordinator modifierOnly leaves preference unchanged: \(preferenceUnchangedAfterModifierOnly)")

            // 3c) An invalid chord (fewer than two modifiers) is rejected
            // with a visible message, and recording CONTINUES rather than
            // silently accepting or silently dropping back to idle.
            coordinator.handle(.chord(keyCode: 5, modifiers: KeyboardShortcut.cmdKey), view: nsView)
            let stillRecordingAfterInvalidChord = nsView.displayState == .recording
            let validationMessageShown = recorderValidationMessage != nil
            let preferenceUnchangedAfterInvalidChord = recorderPreference == .custom(KeyboardShortcut.defaultChord)
            print("SELFTEST recorder coordinator invalid chord stays recording: \(stillRecordingAfterInvalidChord)")
            print("SELFTEST recorder coordinator invalid chord shows validation message: \(validationMessageShown)")
            print("SELFTEST recorder coordinator invalid chord leaves preference unchanged: \(preferenceUnchangedAfterInvalidChord)")

            // 3d) A valid chord is accepted: preference updates, recording
            // stops, validation message clears.
            let recordedChord = KeyboardShortcut(keyCode: 1, modifiers: KeyboardShortcut.cmdKey | KeyboardShortcut.shiftKey)
            coordinator.handle(.chord(keyCode: recordedChord.keyCode, modifiers: recordedChord.modifiers), view: nsView)
            let idleAfterValidChord = nsView.displayState == .idle
            let preferenceUpdatedToValidChord = recorderPreference == .custom(recordedChord)
            let validationClearedAfterValidChord = recorderValidationMessage == nil
            print("SELFTEST recorder coordinator valid chord returns to idle: \(idleAfterValidChord)")
            print("SELFTEST recorder coordinator valid chord updates preference: \(preferenceUpdatedToValidChord)")
            print("SELFTEST recorder coordinator valid chord clears validation message: \(validationClearedAfterValidChord)")

            // 3e) Escape while recording cancels and restores the PRIOR
            // value (captured at `startRecording`), not whatever is
            // current when Escape arrives. Note: by design, `parent.
            // preference` can never change while `displayState ==
            // .recording` through the normal keystroke-handling path —
            // `.clear` and a valid `.chord` are the only cases that mutate
            // it, and both immediately leave `.recording`. So to make the
            // restore-vs-"never touched it" distinction OBSERVABLE, this
            // scenario simulates an intervening external change to the
            // bound preference while still mid-recording (e.g. another
            // code path writing the binding) — exactly the case
            // `preferenceBeforeRecording` exists to guard against — and
            // then asserts cancel restores the value captured at
            // `startRecording`, NOT the intervening one. Deleting `parent.
            // preference = preferenceBeforeRecording` from
            // `cancelRecording` now leaves `recorderPreference` on the
            // intervening `.disabled` value, which fails this assertion.
            let preferenceBeforeEscapeScenario = recorderPreference
            coordinator.startRecording(view: nsView)
            coordinator.handle(.chord(keyCode: 2, modifiers: KeyboardShortcut.cmdKey), view: nsView) // invalid, stays recording; populates validationMessage
            recorderPreference = .disabled // simulate an intervening external change while still recording
            coordinator.handle(.cancel, view: nsView)
            let idleAfterCancel = nsView.displayState == .idle
            let preferenceRestoredAfterCancel = recorderPreference == preferenceBeforeEscapeScenario
            // cancelRecording must clear the validation message left over
            // from the rejected invalid chord above — deleting `parent.
            // validationMessage = nil` from `cancelRecording` leaves this
            // non-nil and fails this assertion.
            let validationMessageClearedAfterCancel = recorderValidationMessage == nil
            print("SELFTEST recorder coordinator escape cancels back to idle: \(idleAfterCancel)")
            print("SELFTEST recorder coordinator escape restores prior preference: \(preferenceRestoredAfterCancel)")
            print("SELFTEST recorder coordinator escape clears validation message: \(validationMessageClearedAfterCancel)")

            // 3f) Delete/Backspace while recording clears to `.disabled`.
            coordinator.startRecording(view: nsView)
            coordinator.handle(.clear, view: nsView)
            let idleAfterClear = nsView.displayState == .idle
            let preferenceDisabledAfterClear = recorderPreference == .disabled
            print("SELFTEST recorder coordinator clear returns to idle: \(idleAfterClear)")
            print("SELFTEST recorder coordinator clear sets preference to .disabled: \(preferenceDisabledAfterClear)")

            // 3g) Losing first responder while recording (e.g. window
            // loses focus) cancels deterministically — this is what
            // guarantees recording can never get stuck. Drive it through
            // the SAME `onResignWhileRecording` production wiring rather
            // than calling the coordinator method directly. Same defect as
            // 3e applies here: `parent.preference` cannot change while
            // still `.recording` through the normal path, so start from a
            // known preference, simulate an intervening external change
            // mid-recording, and assert the restore lands on the value
            // captured at `startRecording` rather than the intervening
            // one — the only way to make deleting the restore line in
            // `cancelRecording` observably FAIL here.
            nsView.onResignWhileRecording = { coordinator.cancelRecording(view: nsView) }
            recorderPreference = .custom(recordedChord)
            let preferenceBeforeResignScenario = recorderPreference
            coordinator.startRecording(view: nsView)
            coordinator.handle(.chord(keyCode: 2, modifiers: KeyboardShortcut.cmdKey), view: nsView) // invalid, stays recording
            recorderPreference = .disabled // simulate an intervening external change while still recording
            _ = nsView.resignFirstResponder()
            let idleAfterResign = nsView.displayState == .idle
            let preferenceRestoredAfterResign = recorderPreference == preferenceBeforeResignScenario
            print("SELFTEST recorder resignFirstResponder while recording cancels to idle: \(idleAfterResign)")
            print("SELFTEST recorder resignFirstResponder while recording restores prior preference: \(preferenceRestoredAfterResign)")

            let recorderPureLogicPassed = mappedCmdCtrlOpt == expectedCmdCtrlOpt && mappedNone == 0
                && classifyEscape == .cancel && classifyDelete == .clear && classifyForwardDelete == .clear
                && classifyChord == .chord(keyCode: 5, modifiers: expectedCmdCtrlOpt)
                && becameRecording
                && stillRecordingAfterModifierOnly && preferenceUnchangedAfterModifierOnly
                && stillRecordingAfterInvalidChord && validationMessageShown && preferenceUnchangedAfterInvalidChord
                && idleAfterValidChord && preferenceUpdatedToValidChord && validationClearedAfterValidChord
                && idleAfterCancel && preferenceRestoredAfterCancel && validationMessageClearedAfterCancel
                && idleAfterClear && preferenceDisabledAfterClear
                && idleAfterResign && preferenceRestoredAfterResign
            print("SELFTEST recorder pure logic all passed: \(recorderPureLogicPassed)")

            if menuRequestedCount == 1 && afterRightClick == 0 && afterLeftClick == 1
                && logRecordedAttempt && logRecordedSuccess
                && mainMenuPresent && editMenuPresent
                && hasPasteItem && hasCopyItem && hasSelectAllItem
                && hotkeyRegistered && hotkeyRegistrationError == nil
                && hotkeyOpenCallCount == 1
                && stateIsNeedsSetup && hotkeyNeedsSetupOpenCallCount == 0
                && disabledIsRegistered == false && disabledIsDisabled && disabledHasNoError
                && disabledTwiceIsRegistered == false && disabledTwiceHasNoError
                && validCustomIsRegistered && validCustomChordMatches
                && invalidChordIsValid == false && invalidCustomIsRegistered && invalidCustomFellBackToDefault
                && afterFailureIsRegistered && afterFailureChord == beforeFailureChord && afterFailureError != nil
                && recorderPureLogicPassed {
                print("SELFTEST PASS")
                exit(0)
            } else {
                print("SELFTEST FAIL")
                exit(1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the Settings window (the only window this app ever
        // shows) must never quit the app — it lives in the status item.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Bead gateopener-iif.2: unregister the global hotkey on quit so a
        // stale Carbon registration can never linger after the app exits
        // (which would otherwise make the combination unusable — or worse,
        // silently non-functional — until next reboot/registration owner
        // change).
        globalHotkey?.uninstall()
    }

    private func presentStatusItemUnavailableAlertAndExit() {
        let alert = NSAlert()
        alert.messageText = "GateOpener could not start"
        alert.informativeText = "macOS could not create a menu bar item for GateOpener (the menu bar may be full). Free up space in the menu bar and relaunch GateOpener."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Dependency graph construction

    /// Builds the real (or, under `GATEOPENER_MOCK=1`, mock) dependency
    /// graph and returns a fully-constructed `GateController`.
    ///
    /// - Parameter mockOut: written with the `MockGateOpening` instance iff
    ///   mock mode is active, so the self-test path can read its call
    ///   counts directly. Left `nil` in real (non-mock) mode.
    /// - Parameter appSettingsOut: written with the `AppSettings` instance
    ///   this call constructs (mock or real), so `applicationDidFinishLaunching`
    ///   can read `shortcutPreference` at launch (bead gateopener-3vq.2)
    ///   without `GateController` needing to expose its private
    ///   `appSettings` property.
    private static func makeGateController(mockOut: inout MockGateOpening?, appSettingsOut: inout AppSettings?) -> GateController {
        let isMock = ProcessInfo.processInfo.environment["GATEOPENER_MOCK"] == "1"

        if isMock {
            // Mock mode MUST NOT construct `AppSettings()` (i.e.
            // `UserDefaults.standard`) here. `.standard`'s resolved domain
            // depends on how the binary is launched:
            //   - No bundle identifier (plain SwiftPM executable, as under
            //     `swift run` / `.build/debug/GateOpener`): `.standard`
            //     falls back to the EXECUTABLE-NAME domain `GateOpener`.
            //   - Once packaged as a real .app with
            //     `CFBundleIdentifier = ie.boboco.GateOpener` (see bead
            //     .11), `.standard` resolves to the OPERATOR'S REAL
            //     `ie.boboco.GateOpener` domain.
            // Either way this branch is about to WRITE a fake mock
            // endpoint id/name into whatever `.standard` resolves to. If
            // that were the real domain, a mock/self-test run would
            // silently overwrite the operator's live gate selection and
            // the app would look configured while the gate never opens.
            // So mock mode always gets its own throwaway suite, wiped at
            // startup so runs don't accumulate stale state, and NEVER
            // falls back to `.standard` on failure — a silent fallback
            // here would reintroduce exactly the bug this guards against.
            let mockSuiteName = "ie.boboco.GateOpener.mock"
            guard let mockDefaults = UserDefaults(suiteName: mockSuiteName) else {
                fatalError("GateOpener mock mode could not create throwaway UserDefaults suite '\(mockSuiteName)'; refusing to fall back to .standard, which could pollute real settings.")
            }
            mockDefaults.removePersistentDomain(forName: mockSuiteName)
            let appSettings = AppSettings(defaults: mockDefaults)

            // See MockGateOpening.swift: records calls instead of hitting
            // the network, so left/right-click discrimination can be
            // verified without ever opening the real gate.
            appSettings.selectedEndpointId = MockGateOpening.mockEndpoint.endpointId
            appSettings.selectedEndpointName = MockGateOpening.mockEndpoint.friendlyName
            let mock = MockGateOpening()
            mockOut = mock
            appSettingsOut = appSettings
            return GateController(
                gateClient: mock,
                tokenManager: MockTokenResolving(),
                credentialStore: MockCredentialStore(),
                appSettings: appSettings
            )
        }

        let appSettings = AppSettings()
        appSettingsOut = appSettings
        let credentialStore = KeychainCredentialStore()
        let api = ComelitAPI()
        let tokenManager = TokenManager(api: api, credentialStore: credentialStore)
        let gateClient = GateClient(tokenManager: tokenManager)

        return GateController(
            gateClient: gateClient,
            tokenManager: tokenManager,
            credentialStore: credentialStore,
            appSettings: appSettings
        )
    }
}
