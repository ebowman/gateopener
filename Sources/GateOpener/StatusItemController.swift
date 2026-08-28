import AppKit
import GateOpenerCore

/// Owns the `NSStatusItem`, drives its icon/tooltip from `GateState`, and
/// discriminates left-click (fire the gate immediately) from right-click /
/// Control-click (show a menu) — the core UX decision for this app.
///
/// SwiftUI's `MenuBarExtra` cannot cleanly express "left click performs an
/// action, right click shows a menu" (it always shows either a menu or runs
/// an action, not both depending on click kind), so this is built directly
/// on `NSStatusItem`/`NSMenu`.
@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private let observable: GateControllerObservable

    /// Drives the "View door" menu item (gateopener-12h.5): owns its own
    /// `DoorVideoSession`/`OverlayWindowController` pair, entirely separate
    /// from `observable`/`GateState` and from the gate-open confirmation
    /// overlay. `nil` when the app has no way to construct a
    /// `DoorVideoSession` (e.g. `GATEOPENER_MOCK=1`, where no concrete
    /// `TokenManager`/`GateClient` exist) — in that case "View door" is
    /// simply not added to the menu at all (see `showMenu()`), rather than
    /// being present and silently failing.
    private let doorVideoOverlayController: DoorVideoOverlayController?

    /// Wall-clock time `.opening` was first observed by THIS controller
    /// (not carried by `GateState` itself — see the bead brief). Used to
    /// escalate the tooltip to "Still trying…" once `.opening` has
    /// persisted beyond `stillTryingThreshold`, so a long (worst-case ~15s)
    /// failure path never looks wedged.
    private var openingStartedAt: Date?
    private var stillTryingTimer: Timer?
    private let stillTryingThreshold: TimeInterval = 5

    /// True once `.opening` has lasted past `stillTryingThreshold` for the
    /// CURRENT `.opening` episode; reset on every state change.
    private var isEscalatedToStillTrying = false

    /// - Parameters:
    ///   - observable: as before.
    ///   - doorVideoOverlayController: injected rather than constructed
    ///     internally, since building it requires `appSettings` and a
    ///     `DoorVideoSession` factory that only `AppDelegate`'s dependency
    ///     graph has (mirrors how `DoorVideoOverlayController` itself takes
    ///     an injected `makeSession` factory, for the same reason). `nil`
    ///     under mock mode — see the property's doc comment.
    init(observable: GateControllerObservable, doorVideoOverlayController: DoorVideoOverlayController? = nil) {
        self.observable = observable
        self.doorVideoOverlayController = doorVideoOverlayController
        super.init()
    }

    /// Creates the status item. Returns `false` (and creates nothing) if
    /// the system could not hand out a status item (e.g. menu bar full) —
    /// callers must treat this as a graceful-degradation signal, not crash.
    @discardableResult
    func install() -> Bool {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return false
        }

        button.image = GateIcon.image(for: observable.state)
        button.toolTip = GateIcon.tooltip(for: observable.state)
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem = item
        render(for: observable.state)
        return true
    }

    // MARK: - Verification (GATEOPENER_MOCK=1 self-test only)

    /// Set only during the `GATEOPENER_MOCK_SELFTEST=1` verification path.
    /// When non-nil, `showMenu()`'s actual (blocking/modal) `NSMenu.popUp`
    /// call is skipped in favor of invoking this closure — so the self-test
    /// can prove a right-click was correctly ROUTED to "show the menu"
    /// (and, critically, did NOT call `handleLeftClick()`/`openGate()`)
    /// without an interactive menu blocking the run loop forever in a
    /// headless process. Never set outside the self-test path.
    var onMenuRequestedForSelfTest: (() -> Void)?

    /// Synthesizes a real `NSEvent` of the given type and invokes the SAME
    /// production selector (`statusItemClicked(_:)`) that AppKit calls for
    /// a genuine click, with the event passed exactly as AppKit would
    /// deliver it via `NSApp.currentEvent`. This exercises the exact
    /// production left/right-click discrimination path end-to-end, without
    /// requiring an actual mouse.
    ///
    /// Used ONLY by the `GATEOPENER_MOCK_SELFTEST=1` verification path in
    /// `GateOpenerMain`; never called during normal operation.
    func simulateClickForSelfTest(rightClick: Bool) {
        guard let button = statusItem?.button, let window = button.window else { return }
        let locationInWindow = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let eventType: NSEvent.EventType = rightClick ? .rightMouseUp : .leftMouseUp
        guard let event = NSEvent.mouseEvent(
            with: eventType,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else { return }

        statusItemClicked(button, overrideEvent: event)
    }

    // MARK: - Click discrimination

    @objc private func statusItemClicked(_ sender: Any?) {
        statusItemClicked(sender, overrideEvent: nil)
    }

    private func statusItemClicked(_ sender: Any?, overrideEvent: NSEvent?) {
        let event = overrideEvent ?? NSApp.currentEvent

        let isRightClick: Bool
        switch event?.type {
        case .rightMouseUp:
            isRightClick = true
        case .leftMouseUp:
            isRightClick = event?.modifierFlags.contains(.control) ?? false
        default:
            isRightClick = false
        }

        if isRightClick {
            if let onMenuRequestedForSelfTest {
                onMenuRequestedForSelfTest()
                return
            }
            showMenu()
            return
        }

        handleLeftClick()
    }

    private func handleLeftClick() {
        if case .needsSetup = observable.state {
            SettingsWindowController.showShared()
            return
        }

        // Do not spawn a parallel Task while already opening — the
        // controller's openGate() is internally idempotent against this,
        // but there is no reason to pile up Tasks that would just await
        // the same in-flight work.
        if case .opening = observable.state {
            return
        }

        let controller = observable.controller
        Task {
            await controller.openGate()
        }
    }

    /// Builds the real status-item menu, with every item's `target`/`action`
    /// wired exactly as production uses it.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // "View door" sits ABOVE "Open Gate" — seeing who is there logically
        // precedes deciding to open (gateopener-12h.5). Only added when a
        // `doorVideoOverlayController` was actually injected; under
        // `GATEOPENER_MOCK=1` (no concrete TokenManager/GateClient to build
        // a DoorVideoSession from) it is simply absent from the menu rather
        // than present and silently failing every time.
        if doorVideoOverlayController != nil {
            let viewDoorItem = NSMenuItem(title: "View Door", action: #selector(menuViewDoor), keyEquivalent: "")
            viewDoorItem.target = self
            menu.addItem(viewDoorItem)
        }

        let openItem = NSMenuItem(title: "Open Gate", action: #selector(menuOpenGate), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "About GateOpener", action: #selector(menuShowAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let checkForUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(menuCheckForUpdates), keyEquivalent: "")
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func showMenu() {
        let menu = buildMenu()

        // Popped up directly via NSMenu (rather than assigning
        // `statusItem.menu`, which would make NSStatusItem show the menu
        // unconditionally on EVERY click, including left clicks — breaking
        // the left-click-fires-immediately requirement).
        guard let button = statusItem?.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    @objc private func menuOpenGate() {
        handleLeftClick()
    }

    /// Handler for the "View Door" menu item. Does NOT call `openGate()` or
    /// touch `observable`/`GateState` in any way — this path only ever
    /// starts a `DoorVideoSession` (an `rtc/offer` PUT), never a gate-power
    /// call. Runs synchronously inside `NSMenu`'s modal tracking loop, same
    /// as every other menu action here (`menuOpenGate`, `menuOpenSettings`,
    /// etc.) — verified by observation for this bead (see the bead's
    /// done-criteria) rather than merely argued, per the gateopener-9kk.12
    /// lesson referenced in the bead brief.
    @objc private func menuViewDoor() {
        doorVideoOverlayController?.start()
    }

    @objc private func menuOpenSettings() {
        SettingsWindowController.showShared()
    }

    @objc private func menuShowAbout() {
        let alert = NSAlert()
        alert.messageText = "GateOpener"
        alert.informativeText = "One-click Comelit gate opener."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func menuCheckForUpdates() {
        UpdateChecker.checkForUpdates()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Rendering

    /// Call whenever `observable.state` changes to keep the icon/tooltip in
    /// sync, and to manage the "Still trying…" escalation timer.
    func render(for state: GateState) {
        statusItem?.button?.image = GateIcon.image(for: state)

        if case .opening = state {
            if openingStartedAt == nil {
                openingStartedAt = Date()
                isEscalatedToStillTrying = false
                scheduleStillTryingCheck()
            }
        } else {
            openingStartedAt = nil
            isEscalatedToStillTrying = false
            stillTryingTimer?.invalidate()
            stillTryingTimer = nil
        }

        statusItem?.button?.toolTip = GateIcon.tooltip(for: state, stillTryingAfterEscalation: isEscalatedToStillTrying)
    }

    private func scheduleStillTryingCheck() {
        stillTryingTimer?.invalidate()
        let timer = Timer(timeInterval: stillTryingThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.escalateToStillTrying()
            }
        }
        stillTryingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func escalateToStillTrying() {
        guard openingStartedAt != nil else { return }
        isEscalatedToStillTrying = true
        statusItem?.button?.toolTip = GateIcon.tooltip(for: observable.state, stillTryingAfterEscalation: true)
    }
}
