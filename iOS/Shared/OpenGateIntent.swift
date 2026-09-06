import AppIntents
import Foundation
import GateOpenerCore
import WidgetKit

/// The single `AppIntent` every one-tap surface (Home Screen/Lock Screen
/// widget button, Control Center, Action Button, Siri/Shortcuts) invokes to
/// open the gate, per bead gateopener-672.13.
///
/// `openAppWhenRun = false`: this must run entirely inside whatever
/// extension process invokes it (widget/Shortcuts/Siri) without ever
/// launching the full app — see `AppEnvironment`'s file-level doc comment,
/// which is written for exactly this "may run from the widget extension
/// process" case.
///
/// All the actual orchestration (deciding whether setup is needed, whether
/// to fail fast when offline, racing the open against a timeout, and
/// writing every `WidgetSnapshot` along the way) lives in `OpenGateFlow`
/// (`Sources/GateOpenerCore/OpenGateFlow.swift`), a plain Foundation type
/// covered by `swift test`. This type is intentionally a THIN wrapper: it
/// only resolves the `AppEnvironment` composition root and builds the
/// closures `OpenGateFlow.run` needs.
public struct OpenGateIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Gate"
    public static let description = IntentDescription(
        "Opens your gate without opening the GateOpener app."
    )
    public static let openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await Self.runFlow()
        return .result(dialog: IntentDialog(stringLiteral: outcome.dialog))
    }

    /// Extracted as a static, `@MainActor`-hopping helper (rather than
    /// inlined in `perform()`) so it can be exercised directly from
    /// `GateOpenerIOSApp`'s DEBUG `--run-intent` launch flag (bead .13 step
    /// 6's verification) without going through the full `AppIntents`
    /// invocation machinery, which is not drivable from a plain app launch.
    ///
    /// - Parameter environment: TEST/DEBUG SEAM ONLY. When `nil` (the
    ///   production default, and the only value ever used by `perform()`
    ///   above, matching a real widget/Siri/Shortcuts invocation), resolves
    ///   a fresh `AppEnvironment.make()` — a genuinely separate composition
    ///   root/process from the app, exactly like a real extension
    ///   invocation. Non-nil only ever comes from `GateOpenerIOSApp`'s
    ///   `--run-intent` DEBUG launch flag, so that flag can reuse the SAME
    ///   `AppEnvironment` (and therefore the same `--mock-gate`-injected
    ///   fake `GateOpening`/`TokenResolving`, if any) the app itself
    ///   already constructed — a fresh `AppEnvironment.make()` in that
    ///   harness would resolve a real, unmocked `GateController` and
    ///   attempt a real network login with the debug seam's dummy
    ///   credentials, exactly as `AppEnvironment.make(gateClient:
    ///   tokenResolver:)`'s own doc comment warns against.
    @MainActor
    static func runFlow(environment: AppEnvironment? = nil) async -> OpenGateFlow.Outcome {
        let environment = environment ?? AppEnvironment.make()

        // Reachability seam: `AppEnvironment.make()` defaults to a real
        // `NWPathMonitorReachability()` (see that type's initializer) when
        // no `reachability:` override is passed, exactly as here. Its
        // `isReachable` is optimistic (`true`) until the very first path
        // update arrives (documented on `NWPathMonitorReachability
        // ._isReachable`) — a fresh instance constructed inline in this
        // intent's process has essentially no time to receive that first
        // update before `OpenGateFlow.run` reads it. CHOICE MADE HERE:
        // accept that optimistic initial `true` rather than adding an
        // artificial wait for the first path update. Rationale: (1) a
        // genuinely offline device delivers its first `unsatisfied` update
        // "almost immediately" per that type's own doc comment, but
        // "almost immediately" is not a bounded guarantee worth blocking
        // this latency-sensitive, ~20s-budget intent on; (2) even if this
        // races and reads stale-optimistic `true` on a genuinely offline
        // device, the flow does not hang — `GateController.performOpen()`'s
        // own network call will simply fail (via `GateClient`'s existing
        // retry/timeout budget, ~15s worst case) and `OpenGateFlow` maps
        // that to `.failed(message:)`, which still produces a correct,
        // bounded, user-visible dialog. The `isReachable == false` fast
        // path exists to avoid the ~45s `requestOpen()` QUEUE TTL (which
        // this intent never uses in the first place, since it always calls
        // `openGate()` directly), not to avoid the retry budget itself.
        let reachability = NWPathMonitorReachability()

        let currentState = environment.controller.state
        let gateName = environment.appSettings.selectedEndpointName

        let outcome = await OpenGateFlow().run(
            currentState: currentState,
            gateName: gateName,
            isReachable: reachability.isReachable,
            open: {
                await environment.controller.openGate()
                return await environment.controller.state
            },
            snapshot: environment.snapshotStore,
            reloadTimelines: { WidgetCenter.shared.reloadAllTimelines() }
        )

        return outcome
    }
}
