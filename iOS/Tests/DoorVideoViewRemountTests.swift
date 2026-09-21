import Foundation
import Testing
import SwiftUI
import UIKit
import QuartzCore
import GateOpenerCore
@testable import GateOpener

/// Tests for bead gateopener-41m.18: after a pinned renewal swaps
/// `DoorVideoCoordinator.session` to a fresh `DoorVideoSession` instance
/// while `MainView` stays on the same structural `.session` branch, the
/// video slot must host the NEW session's `WKWebView`, not silently keep
/// hosting the OLD (dead, blanked) one.
///
/// These are HOSTED tests: `DoorVideoView` is placed inside a real
/// `UIHostingController` attached to a real `UIWindow`, mirroring how
/// `MainView.sessionVideo(session:overlay:)` actually mounts it — this is
/// the only way to observe whether the hosted `WKWebView` is actually
/// attached to a window, which is what distinguishes "remounted" from
/// "still showing the stale instance".
///
/// `RemountHarness` below stands in for `MainView`'s `sessionVideo`: it
/// renders the production `DoorVideoSessionHost` type directly (the same
/// type `MainView.swift` mounts), applying no `.id` of its own, so these
/// tests exercise the real fix rather than a reimplementation of it.
@MainActor
struct DoorVideoViewRemountTests {
    /// A tiny stand-in for `MainView.sessionVideo(session:overlay:)`: an
    /// `@Observable` box holding the current session (swappable, like
    /// `DoorVideoCoordinator.session`) and a mirrored `state` (like
    /// `DoorVideoCoordinator.sessionState`, wired via `onStateChange` exactly
    /// as `DoorVideoCoordinator.startSession` wires it — `DoorVideoSession`
    /// itself is not `@Observable`, see gateopener-672.29), plus a view that
    /// reads both and hosts `DoorVideoView`, keyed the same way
    /// `MainView.swift` keys it.
    @MainActor
    @Observable
    final class SessionBox {
        var session: DoorVideoSession
        var state: DoorVideoSession.State

        init(session: DoorVideoSession) {
            self.session = session
            self.state = session.state
            wire(session)
        }

        /// Swaps in a new session and mirrors ITS state, same as
        /// `DoorVideoCoordinator.startSession` swapping `self.session` and
        /// re-wiring `onStateChange` on the fresh instance.
        func replace(with newSession: DoorVideoSession) {
            session = newSession
            state = newSession.state
            wire(newSession)
        }

        private func wire(_ session: DoorVideoSession) {
            session.onStateChange = { [weak self] newState in
                self?.state = newState
            }
        }
    }

    private struct RemountHarness: View {
        var box: SessionBox

        var body: some View {
            // Renders the production `DoorVideoSessionHost` (bead
            // gateopener-41m.18) directly — no `.id` of its own here, since
            // `DoorVideoSessionHost` itself owns the identity keyed on the
            // session instance.
            DoorVideoSessionHost(session: box.session, state: box.state)
        }
    }

    /// Hosts `harness` in a real, key `UIWindow` and forces a layout pass so
    /// SwiftUI actually materializes the `UIViewRepresentable`'s hosted
    /// `WKWebView` into the hierarchy (rather than leaving it lazily
    /// unbuilt). Attaching to a real `UIWindowScene` (from the test host
    /// app's own `connectedScenes`) is load-bearing: without a scene,
    /// SwiftUI's `_UIHostingView` update pipeline for a later `.id` change
    /// never actually attaches the new identity's hosted view to the window
    /// even after many run-loop turns — the old and new
    /// `PlatformViewRepresentableAdaptor` hosts were observed coexisting
    /// indefinitely, with the new one never gaining a `superview` under
    /// `controller.view`. A bare, sceneless `UIWindow(frame:)` was tried as a
    /// fallback and does NOT work for this reason, so if the test host has no
    /// connected `UIWindowScene`, this records a failed expectation and
    /// returns `nil` rather than silently proceeding on a path that cannot
    /// succeed (should not happen for a hosted UI test target).
    private func host(_ box: SessionBox) -> (window: UIWindow, controller: UIHostingController<RemountHarness>)? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("no UIWindowScene in test host")
            return nil
        }
        let controller = UIHostingController(rootView: RemountHarness(box: box))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (window, controller)
    }

    /// Lets SwiftUI's next body evaluation (after a mutation to an
    /// `@Observable` box) actually happen and the hosting controller's view
    /// tree update, then forces layout again. SwiftUI schedules its
    /// state-driven view update on the main run loop (a `CATransaction`
    /// -adjacent mechanism), not via plain `Task` scheduling, so
    /// `Task.yield()`/`Task.sleep` ALONE are not reliable here — this
    /// actually pumps `RunLoop.main` synchronously (via the `nonisolated`
    /// `spinRunLoop` helper below, since `run(until:)` itself is unavailable
    /// from an async context directly) between checks, which is what lets
    /// the pending SwiftUI update actually run before `layoutIfNeeded()` is
    /// asked to lay out the new tree. Bounded at ~2s total, well above what
    /// this is observed to need in practice (a handful of run loop turns),
    /// so a genuine regression still fails promptly rather than hanging.
    private func settle(_ controller: UIHostingController<RemountHarness>) async {
        for _ in 0..<100 {
            await Task.yield()
            Self.spinRunLoop(for: 0.02)
            CATransaction.flush()
            controller.view.window?.layoutIfNeeded()
            controller.view.layoutIfNeeded()
        }
    }

    /// `nonisolated` so calling `RunLoop.main.run(until:)` — a synchronous,
    /// main-thread-blocking call, fine to make from the main thread, but
    /// disallowed as a *direct* statement inside an `async` function body —
    /// is legal; this always actually runs on the main thread since these
    /// tests only ever call it from `@MainActor` async test methods.
    nonisolated private static func spinRunLoop(for duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    /// Polls `condition` until it returns `true` or `timeout` elapses,
    /// mirroring the inline poll loop in `DoorVideoCoordinatorPinTests`.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Renewal (new session instance) -> remount

    /// MUTATION CHECK: removing `.id(ObjectIdentifier(session))` from
    /// `DoorVideoSessionHost` (rendered directly here by `RemountHarness`,
    /// the same production type `MainView.sessionVideo(session:overlay:)`
    /// mounts) makes SwiftUI reuse the existing `UIViewRepresentable`/hosted
    /// `WKWebView` across the session swap below, since `DoorVideoView`
    /// stays on the same structural branch and `makeUIView` is never called
    /// again — this test then fails because `sessionA.webView.window` is
    /// still non-nil and/or `sessionB.webView.window` is nil.
    @Test func pinnedRenewalRemountsNewSessionWebView() async throws {
        let sessionA = DoorVideoSession.debugStub(connectingDelay: 100, streamingDuration: 100)
        let sessionB = DoorVideoSession.debugStub(connectingDelay: 100, streamingDuration: 100)
        let box = SessionBox(session: sessionA)
        guard let (window, controller) = host(box) else { return }
        defer { window.isHidden = true }

        await settle(controller)
        #expect(sessionA.webView.window != nil, "session A's web view must be attached to the window on first mount")

        // Simulate a pinned renewal: `DoorVideoCoordinator.startSession`
        // swaps `session` to a brand-new instance while the coordinator
        // (and thus `MainView`) stays on the same `.session` branch.
        box.replace(with: sessionB)
        await settle(controller)

        #expect(sessionB.webView.window != nil, "session B's web view must be attached to the window after the renewal")
        #expect(sessionB.webView.isDescendant(of: controller.view), "session B's web view must be hosted under the same view tree")
        #expect(sessionA.webView.window == nil, "session A's web view must be detached once B is mounted")
    }

    // MARK: - Same-session state change -> NO remount (gateopener-672.30 guard)

    /// Regression guard for gateopener-672.30: a state change WITHOUT a
    /// session swap (the ordinary `.connecting` -> `.streaming` path) must
    /// NOT remount the web view — it must stay mounted and visible
    /// throughout negotiation. Asserts the exact same `WKWebView` instance
    /// stays attached to the same window/superview across the state change,
    /// i.e. `.id` is keyed on the session only, never on `state`.
    ///
    /// MUTATION CHECK: keying `DoorVideoSessionHost`'s `.id` on
    /// `(ObjectIdentifier(session), state)` instead of
    /// `ObjectIdentifier(session)` alone would remount on every state change
    /// and make this test fail (a NEW `DoorVideoView`/representable instance
    /// is still backed by the same `WKWebView` object, but re-attaching it
    /// tears down and rebuilds the hosting `UIView`, which this test catches
    /// via superview identity below).
    @Test func sameSessionStateChangeDoesNotRemount() async throws {
        // Short `connectingDelay`/long `streamingDuration` so the SAME
        // session naturally transitions `.connecting` -> `.streaming` on its
        // own canned timeline (bead's runDebugStubTimeline) without ever
        // swapping the session instance — the ordinary, non-renewal path.
        let session = DoorVideoSession.debugStub(connectingDelay: 0.05, streamingDuration: 100)
        let box = SessionBox(session: session)
        guard let (window, controller) = host(box) else { return }
        defer { window.isHidden = true }

        await settle(controller)
        #expect(session.webView.window != nil)
        let superviewBefore = session.webView.superview

        // `start()` awaits the WHOLE canned timeline (through
        // `streamingDuration`, here 100s), same as
        // `DoorVideoCoordinator.startSession`'s `Task { await
        // newSession.start() }` — launch it detached and poll `box.state`
        // instead of awaiting it directly.
        Task { await session.start() }
        await waitUntil { box.state == .streaming }
        await settle(controller)

        #expect(box.state == .streaming, "the stub session must have reached .streaming for this test to be meaningful")
        #expect(session.webView.window != nil, "the web view must remain attached across a same-session state change")
        #expect(session.webView.superview === superviewBefore, "the web view's superview identity must be unchanged (no remount) across a same-session state change")
    }
}
