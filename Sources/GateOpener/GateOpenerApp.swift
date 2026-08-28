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
    /// Confirmation-overlay HUD (bead gateopener-9kk.6), driven solely via
    /// `OverlayWindowController.handle(_:)` chained onto `controller.
    /// onStateChange` below — never `show()`/`hide()` directly from here.
    /// Retained as a stored property (mirrors `notificationPresenter`
    /// immediately above): without a strong reference the panel would be
    /// deallocated and never appear.
    private var overlayWindowController: OverlayWindowController!
    /// "View door" (bead gateopener-12h.5): a SEPARATE overlay/session
    /// controller from `overlayWindowController` above — see
    /// `DoorVideoOverlayController`'s doc comment for why the two must never
    /// share a panel. Retained as a stored property for the same reason as
    /// `overlayWindowController`: without a strong reference here it would
    /// be deallocated and "View door" would silently do nothing. `nil` under
    /// `GATEOPENER_MOCK=1` (see the property's assignment below).
    private var doorVideoOverlayController: DoorVideoOverlayController!
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
        // THROWAWAY hardware-verification path for gateopener-12h.3 — NOT
        // part of the normal app flow, gated behind an env var a real user
        // will never set. Exercises DoorVideoSession against the real
        // Comelit API/door camera and prints getStats() results, then
        // exits. Candidate for removal once gateopener-12h.4/.5 add a real
        // UI entry point that exercises the same code path.
        if ProcessInfo.processInfo.environment["GATEOPENER_VERIFY_DOOR_VIDEO"] == "1" {
            Task { await Self.runDoorVideoVerificationAndExit() }
            return
        }

        // EXPERIMENT for gateopener-12h.8, option (c): identical in spirit
        // to GATEOPENER_VERIFY_DOOR_VIDEO above (THROWAWAY, env-var gated,
        // never part of normal app flow), but hosts `contentView` in a
        // panel configured EXACTLY like OverlayWindowController's
        // (non-activating, never key) and asks whether captureFrameJpeg()
        // can pull real pixels out of the hidden canvas anyway. See that
        // method's doc comment for the full experiment writeup.
        if ProcessInfo.processInfo.environment["GATEOPENER_VERIFY_PANEL_CAPTURE"] == "1" {
            Task { await Self.runPanelCaptureExperimentAndExit() }
            return
        }

        // Must happen before any window is shown (the Settings window can
        // auto-open below on `.needsSetup`) so the Edit menu exists the
        // first time a text field becomes first responder. See
        // MainMenu.swift for the root-cause explanation (bead
        // gateopener-iif.1): without this, Cmd-V/C/X/A/Z are unbound in
        // every text field because AppKit never installs a main menu for
        // an `.accessory`/`LSUIElement` app on its own.
        MainMenu.install()

        var appSettingsForLaunch: AppSettings?
        var doorVideoDependenciesForLaunch: (tokenManager: TokenManager, gateClient: GateClient)?
        let controller = Self.makeGateController(
            mockOut: &mockGateOpeningForSelfTest,
            appSettingsOut: &appSettingsForLaunch,
            doorVideoDependenciesOut: &doorVideoDependenciesForLaunch
        )
        self.appSettings = appSettingsForLaunch
        let observable = GateControllerObservable(controller: controller)
        self.observable = observable
        GateControllerObservable.appShared = observable

        // "View door" (bead gateopener-12h.5): only constructed when the
        // real (non-mock) dependency graph produced concrete
        // TokenManager/GateClient instances — DoorVideoSession requires
        // those concrete types (not the `any GateOpening`/`any
        // TokenResolving` existentials GateController itself stores), and
        // GATEOPENER_MOCK=1 never constructs them (see makeGateController's
        // mock branch). `makeSession` returns a FRESH DoorVideoSession every
        // call — DoorVideoOverlayController never reuses one across "View
        // door" selections (see that type's doc comment).
        let doorVideoOverlayController: DoorVideoOverlayController?
        if let doorVideoDependenciesForLaunch, let appSettingsForLaunch {
            doorVideoOverlayController = DoorVideoOverlayController(appSettings: appSettingsForLaunch) {
                DoorVideoSession(
                    tokenManager: doorVideoDependenciesForLaunch.tokenManager,
                    gateClient: doorVideoDependenciesForLaunch.gateClient
                )
            }
        } else {
            doorVideoOverlayController = nil
        }
        self.doorVideoOverlayController = doorVideoOverlayController

        let statusItemController = StatusItemController(observable: observable, doorVideoOverlayController: doorVideoOverlayController)
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

        // Confirmation-overlay HUD (bead gateopener-9kk.6). MUST be
        // constructed with the app's SHARED `appSettings` instance (the same
        // one just captured above from `makeGateController`), not a fresh
        // `AppSettings()` — a second instance could read a different
        // `UserDefaults` suite than the one the Settings window writes to
        // (this genuinely differs under `GATEOPENER_MOCK=1`, which uses a
        // throwaway suite), which would make the Settings toggle appear
        // broken. `ignoresMouseEvents` is left at its default (`true`).
        //
        // `makeDoorVideoSession` (bead gateopener-12h.6): the SAME
        // factory shape/dependency-availability check as
        // `doorVideoOverlayController` immediately above — only offered
        // when the real (non-mock) dependency graph produced concrete
        // `TokenManager`/`GateClient` instances, `nil` otherwise (mock
        // mode). Deliberately a SEPARATE closure/session from "View door"'s
        // `doorVideoOverlayController`, even though both build a
        // `DoorVideoSession` the same way: the two features run
        // independently (a "View door" session and an open-triggered
        // session must never share or interfere with one another), so
        // each gets its own fresh `DoorVideoSession` per call, never a
        // shared instance.
        let overlayWindowController: OverlayWindowController
        if let doorVideoDependenciesForLaunch {
            overlayWindowController = OverlayWindowController(appSettings: appSettings) {
                DoorVideoSession(
                    tokenManager: doorVideoDependenciesForLaunch.tokenManager,
                    gateClient: doorVideoDependenciesForLaunch.gateClient
                )
            }
        } else {
            overlayWindowController = OverlayWindowController(appSettings: appSettings)
        }
        self.overlayWindowController = overlayWindowController

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
            overlayWindowController.handle(state)

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

        // THROWAWAY hardware-verification path for gateopener-12h.5's
        // done-criteria — NOT part of normal app flow, gated behind an env
        // var a real user will never set. Unlike
        // GATEOPENER_VERIFY_DOOR_VIDEO/GATEOPENER_VERIFY_PANEL_CAPTURE
        // above, this one runs AFTER the full real (non-mock) launch
        // sequence completes, so it exercises the REAL StatusItemController/
        // DoorVideoOverlayController the menu bar icon actually uses — the
        // whole point is to observe the real "View Door" menu-item action
        // dispatch end to end (gateopener-9kk.12 lesson: observe, don't
        // argue that a menu path works), not a reimplementation of it.
        if ProcessInfo.processInfo.environment["GATEOPENER_VERIFY_VIEW_DOOR_MENU"] == "1" {
            Task { await self.runViewDoorMenuVerificationAndExit() }
        }

        // THROWAWAY hardware-verification path for gateopener-12h.6's
        // done-criteria — see runOpenVideoVerificationAndExit()'s doc
        // comment. Select the trigger under test with
        // GATEOPENER_VERIFY_OPEN_VIDEO_TRIGGER=leftclick|menu|hotkey.
        if ProcessInfo.processInfo.environment["GATEOPENER_VERIFY_OPEN_VIDEO"] == "1" {
            Task { await self.runOpenVideoVerificationAndExit() }
        }
    }

    /// THROWAWAY hardware-verification path for gateopener-12h.5's
    /// done-criteria: proves, by observation, that (1) the real "View Door"
    /// menu item exists and its action reaches `DoorVideoOverlayController.
    /// start()` (via `StatusItemController.invokeViewDoorForVerification()`,
    /// which builds and dispatches the REAL `NSMenu`'s real target/action —
    /// see that method's doc comment), (2) a connecting state is visible
    /// before the first frame, (3) the panel disappears at session end via
    /// the plateau detector, and (4) no gate-open call is ever made along
    /// this path. Prints a machine-checkable summary and the overlay panel's
    /// screen rect (mirroring `runDoorVideoVerificationAndExit()`'s own
    /// `screencapture -R`-ready rect line) so a screenshot can be taken and
    /// LOOKED AT while the panel is showing live frames — printing "got a
    /// frame" is not evidence, only a decoded, inspected image is.
    private func runViewDoorMenuVerificationAndExit() async {
        guard mockGateOpeningForSelfTest == nil else {
            // GATEOPENER_MOCK=1 never constructs a doorVideoOverlayController
            // (see makeGateController's mock branch) — this path is only
            // meaningful against the real, non-mock dependency graph.
            print("VERIFYMENU FAIL: running under GATEOPENER_MOCK=1; \"View Door\" would not even be in the menu. Run without GATEOPENER_MOCK.")
            exit(1)
        }

        // (1) Prove the menu item exists and reaches DoorVideoOverlayController
        // via the REAL NSMenuItem target/action dispatch, not a direct call.
        let invoked = statusItemController.invokeViewDoorForVerification()
        print("VERIFYMENU \"View Door\" menu item found and invoked: \(invoked)")
        guard invoked else {
            print("VERIFYMENU FAIL: \"View Door\" item missing from the real menu")
            exit(1)
        }

        // (2) A connecting state must be visible immediately — the overlay
        // panel this bead added is a SEPARATE OverlayWindowController from
        // the confirmation-overlay one, so print ITS screen rect (not
        // reachable via `overlayWindowController`) for a human/agent to
        // screenshot and LOOK AT while frames are arriving.
        try? await Task.sleep(for: .milliseconds(300))
        if let screenFrame = NSScreen.main?.frame {
            let visible = NSScreen.main!.visibleFrame
            let size = OverlayWindowController.panelSize
            let x = visible.maxX - size.width - 16
            let y = visible.maxY - size.height - 16
            let flippedY = screenFrame.height - y - size.height
            print("VERIFYMENU overlay panel rect for screencapture: \(Int(x)),\(Int(flippedY)),\(Int(size.width)),\(Int(size.height))")
        } else {
            print("VERIFYMENU overlay panel rect for screencapture: <no screen>")
        }

        // Give the human/agent time to screenshot the connecting state,
        // then real frames, then observe the panel disappear at session
        // end. Extendable via GATEOPENER_VERIFY_VIEW_DOOR_MENU_DWELL_MS
        // (default 45s: comfortably past the measured ~28-30s session
        // length plus this view's plateau detector).
        let dwellMs = ProcessInfo.processInfo.environment["GATEOPENER_VERIFY_VIEW_DOOR_MENU_DWELL_MS"]
            .flatMap { UInt64($0) } ?? 45_000
        print("VERIFYMENU dwelling \(dwellMs)ms for observation (screenshot the panel now)...")
        try? await Task.sleep(nanoseconds: dwellMs * 1_000_000)

        print("VERIFYMENU done dwelling; exiting")
        exit(0)
    }

    /// THROWAWAY hardware-verification path for gateopener-12h.6's
    /// done-criteria: proves, by observation, that opening the gate via ONE
    /// of the three real production triggers — selected by
    /// `GATEOPENER_VERIFY_OPEN_VIDEO_TRIGGER` ("leftclick" | "menu" |
    /// "hotkey") — (1) shows the confirmation overlay immediately with the
    /// canned animation, (2) swaps to live video once the first frame
    /// arrives, and (3) the overlay disappears at the video session's
    /// natural end (the plateau detector), all driven purely through
    /// `GateState`/`OverlayWindowController.handle(_:)` with NO per-trigger
    /// branching in that type — this harness only choreographs WHICH real
    /// production entry point fires the SAME `openGate()` call, exactly as
    /// `runViewDoorMenuVerificationAndExit()` above does for "View Door".
    /// Prints a machine-checkable summary and the confirmation-overlay
    /// panel's screen rect for a human/agent to screenshot and LOOK AT
    /// while live frames are showing (gateopener-9kk.12 lesson: observe,
    /// never argue).
    private func runOpenVideoVerificationAndExit() async {
        guard mockGateOpeningForSelfTest == nil else {
            print("VERIFYOPEN FAIL: running under GATEOPENER_MOCK=1; no real DoorVideoSession dependency graph exists. Run without GATEOPENER_MOCK.")
            exit(1)
        }

        let trigger = ProcessInfo.processInfo.environment["GATEOPENER_VERIFY_OPEN_VIDEO_TRIGGER"] ?? "leftclick"
        print("VERIFYOPEN trigger: \(trigger)")

        switch trigger {
        case "leftclick":
            // Real production left-click path: a synthesized real NSEvent
            // through statusItemClicked(_:), same as the self-test uses.
            statusItemController.simulateClickForSelfTest(rightClick: false)
        case "menu":
            // Real production "Open Gate" NSMenuItem target/action dispatch
            // — see StatusItemController.invokeOpenGateForVerification()'s
            // doc comment for why this matters (gateopener-9kk.12).
            let invoked = statusItemController.invokeOpenGateForVerification()
            print("VERIFYOPEN \"Open Gate\" menu item found and invoked: \(invoked)")
            guard invoked else {
                print("VERIFYOPEN FAIL: \"Open Gate\" item missing from the real menu")
                exit(1)
            }
        case "hotkey":
            // Real production global-hotkey closure (registered via
            // globalHotkey.apply(...) in applicationDidFinishLaunching),
            // invoked directly rather than via a synthesized system-wide
            // keystroke — see GlobalHotkey.invokeHandlerForSelfTest()'s doc
            // comment; this is the same call the self-test uses.
            globalHotkey.invokeHandlerForSelfTest()
        case "rapid":
            // gateopener-12h.6 done-criteria: "rapid repeated opens do not
            // stack sessions or panels". Fires the real left-click path
            // twice, a couple seconds apart (comfortably before the first
            // open's video reaches .streaming, ~4-6s in) — the second open
            // must replace the first open's session/panel, never stack a
            // second one alongside it. OverlayWindowController.
            // startOpenVideoSessionIfEnabled() logs a notice when this
            // replace path is taken; grep the unified log for it to
            // confirm.
            statusItemController.simulateClickForSelfTest(rightClick: false)
            try? await Task.sleep(for: .seconds(2))
            print("VERIFYOPEN firing second rapid open now")
            statusItemController.simulateClickForSelfTest(rightClick: false)
        default:
            print("VERIFYOPEN FAIL: unknown trigger '\(trigger)'; expected leftclick|menu|hotkey|rapid")
            exit(1)
        }

        // The confirmation overlay must appear essentially immediately
        // (canned animation, covering the gap before live video arrives).
        try? await Task.sleep(for: .milliseconds(300))
        if let screenFrame = NSScreen.main?.frame {
            let visible = NSScreen.main!.visibleFrame
            let size = OverlayWindowController.panelSize
            let x = visible.maxX - size.width - 16
            let y = visible.maxY - size.height - 16
            let flippedY = screenFrame.height - y - size.height
            print("VERIFYOPEN overlay panel rect for screencapture: \(Int(x)),\(Int(flippedY)),\(Int(size.width)),\(Int(size.height))")
        } else {
            print("VERIFYOPEN overlay panel rect for screencapture: <no screen>")
        }

        // Give the human/agent time to screenshot the canned animation,
        // then live frames once they arrive (~4-6s in), then observe the
        // panel disappear at session end (~28-30s of streaming later).
        // Extendable via GATEOPENER_VERIFY_OPEN_VIDEO_DWELL_MS (default
        // 45s, mirroring GATEOPENER_VERIFY_VIEW_DOOR_MENU_DWELL_MS's own
        // rationale).
        let dwellMs = ProcessInfo.processInfo.environment["GATEOPENER_VERIFY_OPEN_VIDEO_DWELL_MS"]
            .flatMap { UInt64($0) } ?? 45_000
        print("VERIFYOPEN dwelling \(dwellMs)ms for observation (screenshot the panel now)...")
        try? await Task.sleep(nanoseconds: dwellMs * 1_000_000)

        print("VERIFYOPEN done dwelling; exiting")
        exit(0)
    }

    /// THROWAWAY hardware-verification path for gateopener-12h.3's
    /// done-criteria: establishes ONE real `DoorVideoSession` against the
    /// real Comelit API and door camera, waits for `.streaming`, fetches
    /// `getVideoStats()` from the page, prints the result, then calls
    /// `stop()` and exits. Never calls `GateClient.open` — only
    /// `rtc/offer`, which starts a video session and opens nothing.
    ///
    /// Uses the SAME construction path as `makeGateController`'s real
    /// (non-mock) branch, so this is the production auth/discovery code,
    /// not a reimplementation.
    ///
    /// gateopener-12h.8 ROOT CAUSE (verified empirically by isolating each
    /// variable independently — see bd memory
    /// `gateopener-12h-8-root-cause-wkwebview-refuses-to` for the full
    /// record): `WKWebView` does not paint ANY content — not even the
    /// page's own background color, let alone decoded video — unless it is
    /// hosted in a window that is or becomes KEY.
    ///  - Hosting in a window that is never added/ordered front at all: no
    ///    paint (the original bug — `contentView`'s own doc comment used
    ///    to, wrongly, call this "fine").
    ///  - Hosting in `OverlayWindowController`'s exact panel recipe
    ///    (`styleMask: [.borderless, .nonactivatingPanel]`,
    ///    `isFloatingPanel`, `.statusBar` level, `orderFrontRegardless()`):
    ///    still no paint, because `.nonactivatingPanel` makes the panel
    ///    structurally UNABLE to ever become key — confirmed even after
    ///    adding `NSApp.activate(ignoringOtherApps:)` and even calling
    ///    `makeKeyAndOrderFront(_:)` on it directly (a no-op on a
    ///    non-activating panel).
    ///  - Removing ONLY `.nonactivatingPanel` (same borderless/floating/
    ///    statusBar panel, same frame, same everything else) and calling
    ///    `makeKeyAndOrderFront(_:)` instead of `orderFrontRegardless()`:
    ///    paints real decoded video immediately.
    /// `.accessory` activation policy and `NSApp.activate(...)` were tested
    /// and ruled out independently — neither one, alone or combined, made
    /// a `.nonactivatingPanel` paint. Key-window status is what mattered.
    ///
    /// CONSTRAINT THIS PUTS ON gateopener-12h.5: `OverlayWindowController`'s
    /// panel is deliberately, permanently non-activating/non-key (see that
    /// type's doc comment — the confirmation HUD must never steal keyboard
    /// focus). `DoorVideoSession.contentView` cannot simply be dropped into
    /// that SAME panel via `setContent(_:)` and expect to paint. 12h.5 will
    /// need either a separate, key-capable window/panel for live video
    /// (accepting that it may steal focus, unlike the HUD), or a way to
    /// grant JUST the video panel key status without disturbing the rest of
    /// the app's focus model (e.g. a distinct panel that CAN become key,
    /// still `isFloatingPanel`/`.statusBar` for stacking, shown only for
    /// the deliberate "View door" action rather than a passive HUD) — this
    /// needs a real design decision, not a copy-paste of the HUD panel.
    ///
    /// This harness therefore hosts `contentView` in an ordinary titled,
    /// closable `NSWindow` (which naturally becomes key via
    /// `makeKeyAndOrderFront(_:)`) — the simplest faithful proof that the
    /// paint problem is fixed, not a preview of 12h.5's eventual chrome.
    private static func runDoorVideoVerificationAndExit() async {
        let credentialStore = KeychainCredentialStore()
        let api = ComelitAPI()
        let tokenManager = TokenManager(api: api, credentialStore: credentialStore)
        let gateClient = GateClient(tokenManager: tokenManager)

        let t0 = Date()
        let session = DoorVideoSession(tokenManager: tokenManager, gateClient: gateClient)
        session.onStateChange = { state in
            let elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
            print("VERIFY [\(elapsedMs)ms] state=\(state)")
        }

        // Host `contentView` in a real, titled, CLOSABLE window and make it
        // key BEFORE start() so the WKWebView actually composites for the
        // whole session (not just once streaming begins) — see the
        // gateopener-12h.8 root-cause note above: `makeKeyAndOrderFront(_:)`
        // is load-bearing here, NOT merely `orderFrontRegardless()`.
        // `.closable` + a real title bar means the human running this
        // verification can dismiss the window with the standard close
        // button rather than having to kill the process.
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        hostWindow.title = "Door Camera (verification)"
        hostWindow.contentView?.wantsLayer = true
        if let hostContentView = hostWindow.contentView {
            session.contentView.frame = hostContentView.bounds
            session.contentView.autoresizingMask = [.width, .height]
            hostContentView.addSubview(session.contentView)
        }
        // Positioned top-trailing on the main screen, matching where
        // `OverlayWindowController` anchors its own panel (16pt from the
        // top-right of `visibleFrame`) -- purely so a human watching this
        // verification run sees the window somewhere sane, NOT because
        // this harness's window is a preview of 12h.5's production
        // chrome (it explicitly is not; see the doc comment above).
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = hostWindow.frame.size
            let origin = NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16)
            hostWindow.setFrameOrigin(origin)
        }
        // NSApp.activate(ignoringOtherApps:) + makeKeyAndOrderFront(_:) --
        // BOTH needed. This deliberately steals keyboard focus, which is
        // fine for a human explicitly running this verification path but
        // would be WRONG for a passive HUD (see the root-cause note above
        // on why this constrains 12h.5's design).
        NSApp.activate(ignoringOtherApps: true)
        hostWindow.makeKeyAndOrderFront(nil)

        await session.start()

        // Poll up to 20s for .streaming (mirrors the spike harness's
        // deadline), then fetch stats regardless of outcome so a failure
        // still prints diagnosable state.
        let deadline = Date().addingTimeInterval(20)
        while session.state != .streaming, Date() < deadline {
            if case .failed = session.state { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        let firstFrameElapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
        print("VERIFY time-to-first-frame-or-give-up = \(firstFrameElapsedMs)ms, final state = \(session.state)")

        // Always dump getVideoStats() and getState() to stdout regardless
        // of final state, for diagnosability -- unified logging (os.Logger)
        // truncates long messages, stdout does not.
        if let raw = try? await session.contentView.callAsyncJavaScript(
            "return await window.getVideoStats();",
            contentWorld: .page
        ), let jsonStr = raw as? String {
            print("VERIFY stats: \(jsonStr)")
        } else {
            print("VERIFY stats: <could not fetch>")
        }
        if let raw = try? await session.contentView.callAsyncJavaScript(
            "return window.getState ? JSON.stringify(window.getState()) : null;",
            contentWorld: .page
        ), let jsonStr = raw as? String {
            print("VERIFY full state: \(jsonStr)")
        }

        // Capture success BEFORE stop() -- stop() unconditionally
        // transitions .streaming to .ended("stopped"), so checking
        // session.state after stop() would always report failure even on
        // a successful run.
        let reachedStreaming = session.state == .streaming

        // gateopener-12h.8: print the on-screen frame of `hostWindow` so a
        // caller can `screencapture -x -R <rect>` it and LOOK at the actual
        // pixels -- this is the whole point of the bead, and printing the
        // rect here means no guessing/hardcoding screen coordinates.
        if let screenFrame = hostWindow.screen?.frame {
            let windowFrame = hostWindow.frame
            // Flip AppKit's bottom-left-origin frame to the top-left-origin
            // rect `screencapture -R` expects.
            let flippedY = screenFrame.height - windowFrame.origin.y - windowFrame.height
            print("VERIFY window rect for screencapture: \(Int(windowFrame.origin.x)),\(Int(flippedY)),\(Int(windowFrame.width)),\(Int(windowFrame.height))")
        } else {
            print("VERIFY window rect for screencapture: <no screen>")
        }
        // Give the window server a moment to composite the latest decoded
        // frame before anything captures the screen. Extendable via
        // GATEOPENER_VERIFY_DOOR_VIDEO_DWELL_MS (default 500ms) purely to
        // give a human/screencapture more time to grab a frame while
        // manually confirming gateopener-12h.8's done-criteria; production
        // behavior (and the default when unset) is unchanged.
        let dwellMs = ProcessInfo.processInfo.environment["GATEOPENER_VERIFY_DOOR_VIDEO_DWELL_MS"]
            .flatMap { UInt64($0) } ?? 500
        try? await Task.sleep(nanoseconds: dwellMs * 1_000_000)

        session.stop()
        // Give stop()'s fire-and-forget closeSession() a moment to run
        // before the process exits.
        try? await Task.sleep(nanoseconds: 500_000_000)
        // Explicitly close the host window rather than relying on process
        // exit to remove it -- proves the window is genuinely closable
        // (gateopener-12h.8 follow-up: the human running this must be able
        // to dismiss the video window without killing the process) and
        // matches how an embedder would tear this down on a real "close"
        // action rather than app termination.
        hostWindow.close()
        exit(reachedStreaming ? 0 : 1)
    }

    /// EXPERIMENT for gateopener-12h.8, option (c) — answers ONE question:
    /// does `captureFrameJpeg()` (a hidden-`<canvas>` frame grab, ported
    /// from `../comelit/comelit/webrtc_page.html` into `door-video.html`)
    /// produce real pixels when `DoorVideoSession.contentView` is hosted in
    /// a panel that is structurally incapable of ever becoming key — i.e.
    /// the EXACT panel recipe `OverlayWindowController` uses. See bd memory
    /// `gateopener-12h-8-root-cause-wkwebview-refuses-to` (corrected
    /// version) for why this question matters: a WKWebView must become key
    /// ONCE to start compositing, and `.nonactivatingPanel` makes that
    /// structurally impossible, so the confirmation-overlay panel can never
    /// host a plain `<video>` element. This experiment tests whether canvas
    /// capture sidesteps that requirement entirely, since the reference
    /// Python app never displays its `<video>` on screen either — it only
    /// ever reads frames out via canvas.
    ///
    /// Deliberately NEVER calls `makeKeyAndOrderFront(_:)` or
    /// `NSApp.activate(...)` anywhere in this method — the whole point is
    /// to prove (or disprove) capture WITHOUT ever granting key status.
    /// Uses `orderFrontRegardless()` only, exactly like
    /// `OverlayWindowController.show()`.
    ///
    /// THROWAWAY: gated behind an env var a real user will never set, not
    /// part of normal app flow, candidate for removal once this bead's
    /// production decision is made (see the bead's write-up for the
    /// eventual disposition).
    private static func runPanelCaptureExperimentAndExit() async {
        let credentialStore = KeychainCredentialStore()
        let api = ComelitAPI()
        let tokenManager = TokenManager(api: api, credentialStore: credentialStore)
        let gateClient = GateClient(tokenManager: tokenManager)

        let t0 = Date()
        let session = DoorVideoSession(tokenManager: tokenManager, gateClient: gateClient)
        session.onStateChange = { state in
            let elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
            print("PANELCAP [\(elapsedMs)ms] state=\(state)")
        }

        // Panel configuration copied EXACTLY from
        // OverlayWindowController.resolvePanel()/show() -- styleMask,
        // isFloatingPanel, level, backgroundColor, isOpaque, hasShadow,
        // hidesOnDeactivate, collectionBehavior, and the show mechanism
        // (orderFrontRegardless() only) all match. Deliberately duplicated
        // here rather than reusing OverlayWindowController/OverlayPanel
        // directly, since those types are private to this file's target
        // and this experiment must not touch production wiring.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hostContentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        hostContentView.wantsLayer = true
        panel.contentView = hostContentView

        session.contentView.frame = hostContentView.bounds
        session.contentView.autoresizingMask = [.width, .height]
        hostContentView.addSubview(session.contentView)

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            let origin = NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16)
            panel.setFrameOrigin(origin)
        }

        // orderFrontRegardless() ONLY -- see the doc comment above. NEVER
        // makeKeyAndOrderFront(_:), NEVER NSApp.activate(...).
        panel.orderFrontRegardless()

        await session.start()

        let deadline = Date().addingTimeInterval(20)
        while session.state != .streaming, Date() < deadline {
            if case .failed = session.state { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        let elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
        print("PANELCAP time-to-streaming-or-give-up = \(elapsedMs)ms, final state = \(session.state)")

        guard session.state == .streaming else {
            print("PANELCAP FAIL: never reached .streaming")
            session.stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
            exit(1)
        }

        // Give the panel a moment before capturing -- mirrors
        // GATEOPENER_VERIFY_DOOR_VIDEO_DWELL_MS's rationale, though here
        // nothing on-screen is being screenshotted; this only gives the
        // decoder a little longer to accumulate frames before the first
        // capture attempt.
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Log videoWidth/videoHeight/framesDecoded BEFORE attempting
        // capture, so a null/failed capture can be distinguished as "no
        // frames arriving" vs "frames arriving but canvas is blank".
        if let raw = try? await session.contentView.callAsyncJavaScript(
            "return await window.getVideoStats();",
            contentWorld: .page
        ), let jsonStr = raw as? String {
            print("PANELCAP stats: \(jsonStr)")
        }
        if let raw = try? await session.contentView.callAsyncJavaScript(
            "return window.getState ? JSON.stringify(window.getState()) : null;",
            contentWorld: .page
        ), let jsonStr = raw as? String {
            print("PANELCAP full state: \(jsonStr)")
        }

        // The capture itself: window.captureFrameJpeg() via
        // callAsyncJavaScript (NEVER evaluateJavaScript -- see
        // DoorVideoSession's GOTCHA doc comment; it is a synchronous
        // function but callAsyncJavaScript is used uniformly here to match
        // this file's established pattern for all page calls).
        var dataURL: String?
        do {
            let raw = try await session.contentView.callAsyncJavaScript(
                "return window.captureFrameJpeg ? window.captureFrameJpeg(0.85) : null;",
                contentWorld: .page
            )
            dataURL = raw as? String
        } catch {
            print("PANELCAP captureFrameJpeg() threw: \(error)")
        }

        if dataURL == nil {
            print("PANELCAP RESULT: captureFrameJpeg() returned null -- video.videoWidth/videoHeight are 0, canvas capture is ALSO gated on the same signal that never populates in this WKWebView context. Option (c) FAILS.")
            session.stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
            exit(1)
        }

        // Decode the base64 JPEG data URL and write it to a PNG file so a
        // human/agent can LOOK at the actual pixels. Never report success
        // without having looked at decoded pixels -- printing "got a data
        // URL" is not evidence; only the decoded image is.
        let outputPath = ProcessInfo.processInfo.environment["GATEOPENER_VERIFY_PANEL_CAPTURE_OUTPUT"]
            ?? "/tmp/gateopener-panelcap-frame.png"
        guard let dataURL,
              let commaIndex = dataURL.firstIndex(of: ","),
              let jpegData = Data(base64Encoded: String(dataURL[dataURL.index(after: commaIndex)...])),
              let image = NSBitmapImageRep(data: jpegData),
              let pngData = image.representation(using: .png, properties: [:]) else {
            print("PANELCAP RESULT: captureFrameJpeg() returned a non-empty string but it could not be decoded as a JPEG (data URL malformed or NSBitmapImageRep failed). Treating as FAIL.")
            session.stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
            exit(1)
        }

        do {
            try pngData.write(to: URL(fileURLWithPath: outputPath))
            print("PANELCAP RESULT: captureFrameJpeg() decoded successfully, \(image.pixelsWide)x\(image.pixelsHigh) pixels, written to \(outputPath). LOOK AT THIS FILE to confirm it shows the real door camera scene before declaring option (c) a success.")
        } catch {
            print("PANELCAP RESULT: decoded image but failed to write PNG to \(outputPath): \(error)")
            session.stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
            exit(1)
        }

        session.stop()
        try? await Task.sleep(nanoseconds: 500_000_000)
        panel.orderOut(nil)
        exit(0)
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

            // Bead gateopener-3vq.4: prove persistence survives a simulated
            // fresh launch. Uses its own throwaway `UserDefaults(suiteName:)`
            // (UUID-unique, never `.standard`/the real
            // `ie.boboco.GateOpener` domain — see the bead's test-hygiene
            // requirement) and constructs BRAND NEW `AppSettings`/
            // `GateController`/`GlobalHotkey` instances per scenario to
            // simulate "app relaunches" rather than reusing `self.
            // globalHotkey` (which already carries state from the
            // assertions above) — this is what makes these assertions
            // actually exercise the launch-time read-persisted-then-apply
            // path (`AppDelegate.applicationDidFinishLaunching`'s `globalHotkey.
            // apply(appSettings.shortcutPreference)` call) rather than
            // re-testing `apply(_:)` in isolation, which the block above
            // already covers.
            let persistenceSuiteName = "ie.boboco.GateOpener.selftest.\(UUID().uuidString)"
            guard let persistenceDefaults = UserDefaults(suiteName: persistenceSuiteName) else {
                print("SELFTEST FAIL: could not create throwaway UserDefaults suite for persistence self-test")
                exit(1)
            }
            defer { persistenceDefaults.removePersistentDomain(forName: persistenceSuiteName) }

            /// Simulates one full "app relaunch": a fresh `AppSettings` over
            /// the SAME throwaway suite (so previously-written keys are
            /// still there, exactly like a real relaunch reading the same
            /// UserDefaults domain) and a fresh `GlobalHotkey` with
            /// `apply(_:)` invoked on the freshly-read persisted preference
            /// — the exact sequence `AppDelegate` performs at launch.
            @MainActor
            func simulateFreshLaunch() -> (settings: AppSettings, hotkey: GlobalHotkey) {
                let settings = AppSettings(defaults: persistenceDefaults)
                let hotkey = GlobalHotkey { }
                hotkey.apply(settings.shortcutPreference)
                return (settings, hotkey)
            }

            // 1) A saved .custom chord is registered on a fresh start.
            let savedCustomChord = KeyboardShortcut(keyCode: 4, modifiers: KeyboardShortcut.cmdKey | KeyboardShortcut.shiftKey | KeyboardShortcut.controlKey)
            AppSettings(defaults: persistenceDefaults).shortcutPreference = .custom(savedCustomChord)
            let freshCustom = simulateFreshLaunch()
            let freshCustomIsRegistered = freshCustom.hotkey.isRegistered
            let freshCustomChordMatches = freshCustom.hotkey.currentChord == savedCustomChord
            let freshCustomHasNoError = freshCustom.hotkey.lastRegistrationError == nil
            let freshCustomIsNotDisabled = freshCustom.hotkey.isDisabled == false
            print("SELFTEST fresh start with saved .custom chord isRegistered: \(freshCustomIsRegistered)")
            print("SELFTEST fresh start with saved .custom chord matches saved chord: \(freshCustomChordMatches)")
            print("SELFTEST fresh start with saved .custom chord has no error: \(freshCustomHasNoError)")

            // 2) A saved .disabled results in NO registration AND no error
            // message — and is presented as DELIBERATE (isDisabled == true),
            // never as a failure.
            AppSettings(defaults: persistenceDefaults).shortcutPreference = .disabled
            let freshDisabled = simulateFreshLaunch()
            let freshDisabledIsRegistered = freshDisabled.hotkey.isRegistered
            let freshDisabledIsDisabled = freshDisabled.hotkey.isDisabled
            let freshDisabledHasNoError = freshDisabled.hotkey.lastRegistrationError == nil
            let freshDisabledHasNoChord = freshDisabled.hotkey.currentChord == nil
            print("SELFTEST fresh start with saved .disabled isRegistered false: \(freshDisabledIsRegistered == false)")
            print("SELFTEST fresh start with saved .disabled isDisabled true: \(freshDisabledIsDisabled)")
            print("SELFTEST fresh start with saved .disabled has no error: \(freshDisabledHasNoError)")
            print("SELFTEST fresh start with saved .disabled has no chord: \(freshDisabledHasNoChord)")

            // 3) .unset registers the default.
            AppSettings(defaults: persistenceDefaults).shortcutPreference = .unset
            let freshUnset = simulateFreshLaunch()
            let freshUnsetIsRegistered = freshUnset.hotkey.isRegistered
            let freshUnsetChordIsDefault = freshUnset.hotkey.currentChord == KeyboardShortcut.defaultChord
            let freshUnsetIsNotDisabled = freshUnset.hotkey.isDisabled == false
            print("SELFTEST fresh start with saved .unset isRegistered: \(freshUnsetIsRegistered)")
            print("SELFTEST fresh start with saved .unset registered the default chord: \(freshUnsetChordIsDefault)")

            // 4) The round-trip through AppSettings preserves each of the
            // three states distinctly (re-reading, not just re-applying —
            // proves the PERSISTED VALUE itself, not just its live effect,
            // survived).
            let rereadSettings = AppSettings(defaults: persistenceDefaults)
            let roundTripUnsetPreserved = rereadSettings.shortcutPreference == .unset
            AppSettings(defaults: persistenceDefaults).shortcutPreference = .disabled
            let roundTripDisabledPreserved = AppSettings(defaults: persistenceDefaults).shortcutPreference == .disabled
            AppSettings(defaults: persistenceDefaults).shortcutPreference = .custom(savedCustomChord)
            let roundTripCustomPreserved = AppSettings(defaults: persistenceDefaults).shortcutPreference == .custom(savedCustomChord)
            print("SELFTEST round trip preserves .unset: \(roundTripUnsetPreserved)")
            print("SELFTEST round trip preserves .disabled: \(roundTripDisabledPreserved)")
            print("SELFTEST round trip preserves .custom: \(roundTripCustomPreserved)")

            // 5) GateController.setShortcutPreference(_:) is the single
            // write path used by the app layer (GateControllerObservable) —
            // prove it actually reaches AppSettings.shortcutPreference, and
            // that GateController.shortcutPreference reads back the same
            // value, using a throwaway controller built exactly like
            // `AppDelegate`'s mock-mode wiring.
            let controllerSettings = AppSettings(defaults: persistenceDefaults)
            let routingController = GateController(
                gateClient: MockGateOpening(),
                tokenManager: MockTokenResolving(),
                credentialStore: MockCredentialStore(),
                appSettings: controllerSettings
            )
            routingController.setShortcutPreference(.custom(savedCustomChord))
            let controllerRoutingPersisted = controllerSettings.shortcutPreference == .custom(savedCustomChord)
            let controllerRoutingReadBack = routingController.shortcutPreference == .custom(savedCustomChord)
            print("SELFTEST GateController.setShortcutPreference persists to AppSettings: \(controllerRoutingPersisted)")
            print("SELFTEST GateController.shortcutPreference reads back the same value: \(controllerRoutingReadBack)")

            // 6) "Reset to Default" (SettingsView.swift) must save .unset,
            // NOT .custom(KeyboardShortcut.defaultChord) — the two are NOT
            // interchangeable: .unset means "follow the default, whatever it
            // becomes"; .custom(default) means "I deliberately chose this
            // chord". Route .unset through the SAME single write path
            // (GateController.setShortcutPreference) that SettingsView uses,
            // and assert BOTH that it round-trips as .unset AND that it is
            // NOT EQUAL to .custom(defaultChord) — the second half is what
            // makes this non-vacuous, since .custom(defaultChord) would also
            // round-trip fine and silently pass a plain equality check.
            routingController.setShortcutPreference(.unset)
            let resetRoutingReadBack = routingController.shortcutPreference == .unset
            let resetRoutingPersisted = controllerSettings.shortcutPreference == .unset
            let resetRoutingIsNotCustomDefault = routingController.shortcutPreference != .custom(KeyboardShortcut.defaultChord)
            print("SELFTEST GateController.setShortcutPreference(.unset) reads back as .unset: \(resetRoutingReadBack)")
            print("SELFTEST GateController.setShortcutPreference(.unset) persists as .unset: \(resetRoutingPersisted)")
            print("SELFTEST GateController.setShortcutPreference(.unset) is NOT .custom(defaultChord): \(resetRoutingIsNotCustomDefault)")

            let persistenceRoundTripPassed = freshCustomIsRegistered && freshCustomChordMatches && freshCustomHasNoError && freshCustomIsNotDisabled
                && freshDisabledIsRegistered == false && freshDisabledIsDisabled && freshDisabledHasNoError && freshDisabledHasNoChord
                && freshUnsetIsRegistered && freshUnsetChordIsDefault && freshUnsetIsNotDisabled
                && roundTripUnsetPreserved && roundTripDisabledPreserved && roundTripCustomPreserved
                && controllerRoutingPersisted && controllerRoutingReadBack
                && resetRoutingReadBack && resetRoutingPersisted && resetRoutingIsNotCustomDefault
            print("SELFTEST shortcut persistence round trip all passed: \(persistenceRoundTripPassed)")

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
                && persistenceRoundTripPassed
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
    /// - Parameter doorVideoDependenciesOut: written with the concrete
    ///   `TokenManager`/`GateClient` pair in real (non-mock) mode only —
    ///   `DoorVideoSession.init` requires those CONCRETE types, not the
    ///   `any GateOpening`/`any TokenResolving` existentials
    ///   `GateController` stores privately, so this is the only seam that
    ///   can hand them to `applicationDidFinishLaunching` for constructing a
    ///   `DoorVideoOverlayController` (bead gateopener-12h.5). Left `nil`
    ///   under `GATEOPENER_MOCK=1`, where no concrete instances of either
    ///   type are ever constructed — this is exactly the signal
    ///   `applicationDidFinishLaunching` uses to skip building a
    ///   `DoorVideoOverlayController`/"View door" menu item at all under
    ///   mock mode, rather than presenting a menu item that would always
    ///   fail.
    private static func makeGateController(
        mockOut: inout MockGateOpening?,
        appSettingsOut: inout AppSettings?,
        doorVideoDependenciesOut: inout (tokenManager: TokenManager, gateClient: GateClient)?
    ) -> GateController {
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
        doorVideoDependenciesOut = (tokenManager: tokenManager, gateClient: gateClient)

        return GateController(
            gateClient: gateClient,
            tokenManager: tokenManager,
            credentialStore: credentialStore,
            appSettings: appSettings
        )
    }
}
