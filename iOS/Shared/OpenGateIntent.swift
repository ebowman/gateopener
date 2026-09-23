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

    /// TEST SEAM ONLY, `DEBUG`-gated: overrides the URL `runFlow` opens its
    /// OWN direct `OpenAttemptJournal` at (see `runFlow`'s doc comment on
    /// why that journal is opened directly rather than only through
    /// `AppEnvironment`). `nil` in production (and reset to `nil` by every
    /// test after use), in which case `runFlow` resolves
    /// `SharedContainer.openAttemptJournalURL()` exactly as before. This
    /// exists purely so `iOS/Tests` never touches the real App Group
    /// container while still exercising the intent's own direct-journal
    /// press logging.
    #if DEBUG
    nonisolated(unsafe) static var journalURLOverride: URL??
    #endif

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
    /// PRESS JOURNALING (bead gateopener-41m.23): the very first things this
    /// method does -- before `AppEnvironment.make()`, which can itself take
    /// non-trivial time (Keychain access, `TokenManager`/`GateController`
    /// construction) -- are recording `pressStartedAt`/`pressId` and writing
    /// an `OpenPressPhase.started` press record directly to the shared
    /// journal, via a journal instance THIS method opens itself (NOT
    /// `environment.openAttemptJournal`, which does not exist yet at this
    /// point). This is so a press that dies before `AppEnvironment.make()`
    /// even finishes (e.g. the extension is killed by iOS under memory
    /// pressure, or hangs on a slow Keychain call) still leaves a `.started`
    /// line on disk -- the whole point of this bead. `environment
    /// .openAttemptJournal` (once it exists) is used for nothing here;
    /// writing directly avoids depending on `AppEnvironment` ever finishing
    /// construction. Both journal instances write to the same underlying
    /// file (`SharedContainer.openAttemptJournalURL()`), safely, thanks to
    /// `OpenAttemptJournal`'s cross-process `flock`-based locking.
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
        // FIRST statements: press identity + the direct journal write,
        // before AppEnvironment.make() -- see this method's doc comment.
        let pressStartedAt = Date()
        let pressId = UUID()
        let process = Bundle.main.bundleIdentifier ?? "?"
        let appVersion = AppVersion.current

        #if DEBUG
        let journalURL: URL? = journalURLOverride ?? SharedContainer.openAttemptJournalURL()
        #else
        let journalURL: URL? = SharedContainer.openAttemptJournalURL()
        #endif
        let journal: OpenAttemptJournal?
        if let journalURL {
            journal = OpenAttemptJournal(fileURL: journalURL, capacity: 1000)
        } else {
            journal = nil
        }

        func emit(_ phase: OpenPressPhase) {
            guard let journal else { return }
            let elapsedMilliseconds: Int
            switch phase {
            case .started:
                elapsedMilliseconds = 0
            default:
                elapsedMilliseconds = Int(max(0, Date().timeIntervalSince(pressStartedAt)) * 1000)
            }
            journal.record(
                OpenPressRecord(
                    pressId: pressId,
                    timestamp: Date(),
                    source: "intent",
                    process: process,
                    appVersion: appVersion,
                    phase: phase,
                    elapsedMilliseconds: elapsedMilliseconds
                )
            )
        }

        emit(.started)

        let environment = environment ?? AppEnvironment.make()

        emit(.environmentReady)

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
        // retry/timeout budget, ~18s worst case) and `OpenGateFlow` maps
        // that to `.failed(message:)`, which still produces a correct,
        // bounded, user-visible dialog. The `isReachable == false` fast
        // path exists to avoid the ~45s `requestOpen()` QUEUE TTL (which
        // this intent never uses in the first place, since it always calls
        // `openGate()` directly), not to avoid the retry budget itself.
        let reachability = NWPathMonitorReachability()

        let currentState = environment.controller.state
        let gateName = environment.appSettings.selectedEndpointName

        let journalWriter: (@Sendable (OpenPressRecord) -> Void)?
        if let journal {
            journalWriter = { (record: OpenPressRecord) in journal.record(record) }
        } else {
            journalWriter = nil
        }

        let outcome = await OpenGateFlow().run(
            currentState: currentState,
            gateName: gateName,
            isReachable: reachability.isReachable,
            open: {
                await environment.controller.openGate()
                return await environment.controller.state
            },
            snapshot: environment.snapshotStore,
            reloadTimelines: { WidgetCenter.shared.reloadAllTimelines() },
            journal: journalWriter,
            pressId: pressId,
            pressStartedAt: pressStartedAt,
            reachabilityDetail: reachability.pathDescription,
            pressSource: "intent",
            pressProcess: process,
            pressAppVersion: appVersion
        )

        return outcome
    }
}
