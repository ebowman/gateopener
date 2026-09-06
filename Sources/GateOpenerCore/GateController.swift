import Foundation

// MARK: - Observability approach
//
// `GateOpenerCore` must never import SwiftUI/AppKit/Observation (load-bearing
// constraint from bead .1, reaffirmed in the bead .6 review notes: `AppSettings`
// is deliberately a plain, non-observable class for exactly this reason).
// `GateController` lives in this same target, so it inherits that constraint.
//
// The pattern used here: `GateController` is a plain `@MainActor final class`
// exposing its state via a normal stored property (`state`) plus a
// change-notification hook, `onStateChange: ((GateState) -> Void)?`, invoked
// on every state transition. This keeps `GateOpenerCore` dependency-free
// while giving the app layer (bead .8) everything it needs: it can wrap this
// controller in an `@Observable` (or `ObservableObject`) type that forwards
// `onStateChange` into its own published state, without `GateOpenerCore`
// itself ever importing Observation/Combine/SwiftUI.
//
// `AppSettings` itself is never written to directly by anything outside this
// file (see the bead .6 review's routing rule): every mutation the UI can
// trigger (selecting a gate, first-time setup, sign-out) goes through a
// `GateController` method, so `onStateChange` (and any future re-published
// convenience properties the app layer adds) always fires. A direct write to
// `AppSettings` would fire no notification, silently breaking UI binding.

// MARK: - GateState

/// The full state of the gate-opening flow, as far as the UI needs to know.
///
/// Every case carries what the icon/tooltip needs to render:
///  - `.needsSetup`: no usable credentials or no selected gate yet — show a
///    "set up" affordance, not an error.
///  - `.idle`: ready, nothing in flight.
///  - `.opening`: a command is in flight; the icon should show a busy state.
///  - `.queued`: a `requestOpen()` call (bead .4) arrived while offline and
///    is being held until connectivity returns (or its TTL elapses). The UI
///    should treat this identically to `.opening` (same busy icon/overlay/
///    status text) — the caller has already gotten "your tap registered"
///    feedback; whether the request is physically in flight yet or merely
///    waiting for a network path is an internal distinction the UI does not
///    need to show separately.
///  - `.succeeded(at:)`: the open command succeeded at this time — the icon
///    can show a checkmark, and this timestamp lets the UI decide how long
///    to keep it (independent of the internal auto-reset timer).
///  - `.failed(message:)`: the open command failed; `message` is a SHORT,
///    human-readable string safe to show directly in a tooltip/notification
///    (never a raw error dump).
public enum GateState: Equatable, Sendable {
    case needsSetup
    case idle
    case opening
    case queued
    case succeeded(at: Date)
    case failed(message: String)
}

// MARK: - Seams (protocols) so tests need no network

/// Abstraction over the two `GateClient` operations `GateController` needs,
/// so tests can inject a mock with no network access.
///
/// `GateClient` already has matching method signatures, so it conforms via a
/// plain (no-op-body) extension below — no changes to `GateClient.swift` are
/// needed. This mirrors the `TokenIssuing` / `extension ComelitAPI:
/// TokenIssuing {}` pattern established in `TokenManager.swift`.
public protocol GateOpening: Sendable {
    func discover(aptId: String?) async throws -> [Endpoint]
    func open(endpointId: String) async throws
}

extension GateClient: GateOpening {}

/// Abstraction over the one `TokenManager` operation `GateController` needs
/// directly (token resolution errors, in particular `.notConfigured`, are
/// mapped to `.needsSetup` rather than `.failed`).
///
/// `TokenManager` already has a matching method signature, so it conforms via
/// a plain (no-op-body) extension below.
public protocol TokenResolving: Sendable {
    func accessToken() async throws -> String
}

extension TokenManager: TokenResolving {}

// MARK: - Injectable clock for the auto-reset delay

/// Injectable sleep function, matching the shape already used by
/// `RetryPolicy.sleep` in `GateClient.swift`. Tests inject a no-op so the
/// ~3s auto-reset-to-`.idle` never actually sleeps.
public typealias GateControllerSleep = @Sendable (Duration) async throws -> Void

// MARK: - GateController

/// The single facade the UI drives. All orchestration, error mapping, and
/// state lives here so it is testable without a GUI.
///
/// `@MainActor` because the UI (menu-bar icon) reads `state` and is expected
/// to react to `onStateChange` on the main thread; all mutation of `state`
/// happens here, so there is a single, main-actor-isolated writer.
@MainActor
public final class GateController {
    /// The current state. The UI should treat this as read-only and observe
    /// `onStateChange` (or an app-layer wrapper thereof) for updates rather
    /// than polling.
    public private(set) var state: GateState {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Invoked on the main actor whenever `state` changes. The app layer
    /// (bead .8) is expected to subscribe here and forward into its own
    /// `@Observable`/`ObservableObject` state, since `GateOpenerCore` itself
    /// cannot depend on Observation/Combine/SwiftUI.
    public var onStateChange: ((GateState) -> Void)?

    private let gateClient: any GateOpening
    private let tokenManager: any TokenResolving
    private let credentialStore: any CredentialStoring
    private let appSettings: AppSettings

    /// How long after `.succeeded`/`.failed` to auto-return to `.idle`.
    /// Defaults to 3 seconds per the bead brief; injectable for tests.
    private let autoResetDelay: Duration

    /// Injectable sleep function backing the auto-reset delay. Defaults to
    /// real `Task.sleep`; tests inject a no-op so the suite never actually
    /// waits ~3 seconds.
    private let sleep: GateControllerSleep

    /// Tracks the in-flight `openGate()` task, if any, so a second call
    /// arriving while one is already running can identify and simply return
    /// rather than starting a second underlying `open` call. Combined with
    /// the `.opening` state check below, this makes `openGate()` idempotent
    /// against a nervous double-click even under real concurrency (two
    /// `Task`s calling `openGate()` "simultaneously"), not just sequential
    /// re-entrancy.
    private var openTask: Task<Void, Never>?

    /// Tracks the currently-scheduled auto-reset task so a later transition
    /// does not race a stale reset back to `.idle` (e.g. a fast fail
    /// following closely after a scheduled success-reset).
    private var resetTask: Task<Void, Never>?

    /// Reachability seam for `requestOpen()` (bead .4). Defaults to
    /// `AlwaysReachable()` so every existing call site (and existing Mac app
    /// behavior/tests) is unaffected.
    private let reachability: any ReachabilityProviding

    /// How long a `requestOpen()` call may sit `.queued` (offline) before it
    /// is abandoned with `.failed(message: "No network")`. Defaults to 45
    /// seconds per the bead brief; injectable for tests.
    private let queueTTL: Duration

    /// Identifies the currently-queued `requestOpen()` request, if any.
    /// Compared by reference identity (a fresh `NSObject`-free token) so a
    /// stale TTL task from a PREVIOUS queued request — one that has already
    /// been cleared, e.g. because reachability flipped true and the request
    /// fired — can recognize it is stale and no-op rather than clobbering a
    /// newer queued request or double-firing.
    private var queuedRequestToken: UUID?

    /// Tracks the scheduled TTL task for the currently-queued request, so it
    /// can be cancelled the moment the request fires (reachability flip) or
    /// is dropped (`signOut()`).
    private var queueTTLTask: Task<Void, Never>?

    public init(
        gateClient: any GateOpening,
        tokenManager: any TokenResolving,
        credentialStore: any CredentialStoring,
        appSettings: AppSettings,
        autoResetDelay: Duration = .seconds(3),
        sleep: @escaping GateControllerSleep = { try await Task.sleep(for: $0) },
        reachability: any ReachabilityProviding = AlwaysReachable(),
        queueTTL: Duration = .seconds(45)
    ) {
        self.gateClient = gateClient
        self.tokenManager = tokenManager
        self.credentialStore = credentialStore
        self.appSettings = appSettings
        self.autoResetDelay = autoResetDelay
        self.sleep = sleep
        self.reachability = reachability
        self.queueTTL = queueTTL

        // Initial state: `.needsSetup` when there are no stored credentials
        // or no selected gate; otherwise `.idle`. `AppSettings.isConfigured`
        // already captures "has a selected gate"; credential presence is
        // checked separately since AppSettings deliberately holds no
        // secrets.
        let hasCredentials = (try? credentialStore.loadCredentials()) != nil
        if hasCredentials, appSettings.isConfigured {
            self.state = .idle
        } else {
            self.state = .needsSetup
        }

        // Registered once, here, for the controller's lifetime (per the
        // bead's "registered once" requirement). The handler hops to the
        // main actor before touching any state (reachability callbacks may
        // arrive on any thread — see `ReachabilityProviding`'s THREADING
        // note) and ignores callbacks when nothing is queued.
        self.reachability.setOnChange { [weak self] isReachable in
            guard isReachable else { return }
            Task { @MainActor [weak self] in
                self?.handleReachabilityBecameTrue()
            }
        }
    }

    // MARK: - openGate (THE method the menu-bar click calls)

    /// Open the currently-selected gate.
    ///
    /// Idempotent against double-clicks: if a call is already in flight
    /// (state is `.opening`), this returns immediately without starting a
    /// second underlying `open` call — a nervous double-click must never
    /// send two open commands to a physical gate.
    ///
    /// A throwing/failing attempt never leaves `state` stuck in `.opening`:
    /// the terminal state (`.succeeded`/`.failed`) is set from a `defer`-like
    /// guarantee around the actual work.
    public func openGate() async {
        // Idempotency: if a call is already in flight, await ITS completion
        // rather than starting a new one. This is deterministic under real
        // concurrency (two Tasks calling openGate() "at the same time"), not
        // just a state-flag check that could race between two callers both
        // observing `.idle` before either has set `.opening`, because
        // `GateController` is `@MainActor` — there is no actual concurrent
        // execution between the check and the assignment below.
        if let existing = openTask {
            await existing.value
            return
        }

        if state == .opening {
            // Defensive: should be unreachable given the openTask gate
            // above (the only way state becomes `.opening` is via
            // `performOpen()`, which is only ever started with `openTask`
            // set), but keeps the invariant explicit and cheap to check.
            return
        }

        let task = Task { [weak self] () -> Void in
            await self?.performOpen()
        }
        openTask = task
        await task.value
        openTask = nil
    }

    // MARK: - requestOpen (non-blocking entry point, bead .4)

    /// Non-blocking entry point for the widget/background-task use case:
    /// unlike `openGate()`, this never suspends the caller. It always
    /// returns synchronously.
    ///
    /// Semantics:
    ///  - If a request is already `.opening` or `.queued`, this is a no-op
    ///    (coalescing: a burst of taps must never result in more than one
    ///    physical open).
    ///  - If `reachability.isReachable`, starts `openGate()` in a detached
    ///    `Task` (fire-and-forget) and returns immediately — behaviorally
    ///    identical to today's "tap -> `Task { await controller.openGate()
    ///    }`" call sites, just moved inside the controller.
    ///  - Otherwise, transitions to `.queued`, remembers this request via a
    ///    fresh token, and starts a bounded TTL timer (`queueTTL`, default
    ///    45s, via the injected `sleep` seam so tests never wait). If
    ///    reachability flips true before the TTL elapses, the request fires
    ///    (`openGate()`) on the FIRST such flip — a later flip back to
    ///    `false` must not cancel an already-fired request, and this method
    ///    only ever needs to react to a flip TO true. If the TTL elapses
    ///    first, the request is abandoned: `transition(to: .failed(message:
    ///    "No network"))`, which reuses the existing auto-reset-to-`.idle`
    ///    path. A subsequent flip to true after the TTL has already fired
    ///    (or expired) must NOT fire a stale request — enforced by
    ///    comparing `queuedRequestToken` by identity everywhere it is
    ///    consulted.
    public func requestOpen() {
        if state == .opening || state == .queued {
            return
        }

        if reachability.isReachable {
            Task { [weak self] in
                await self?.openGate()
            }
            return
        }

        let token = UUID()
        queuedRequestToken = token
        state = .queued

        queueTTLTask = Task { [weak self, queueTTL, sleep] in
            do {
                try await sleep(queueTTL)
            } catch {
                return
            }
            self?.handleQueueTTLElapsed(for: token)
        }
    }

    /// Invoked (on the main actor) when the queue TTL timer fires for
    /// `token`. A no-op if `token` is no longer the current queued request
    /// (it already fired via a reachability flip, or was dropped by
    /// `signOut()`), so a stale timer can never clobber newer state.
    private func handleQueueTTLElapsed(for token: UUID) {
        guard queuedRequestToken == token else { return }
        queuedRequestToken = nil
        queueTTLTask = nil
        transition(to: .failed(message: "No network"))
    }

    /// Invoked (on the main actor) whenever the injected `reachability`
    /// reports a flip to `true`. A no-op if nothing is currently queued
    /// (either there was never a queued request, or it already fired/
    /// expired) — this is what makes a stale/late `true` callback after TTL
    /// expiry harmless, and what makes an extra `true` callback with
    /// nothing queued harmless too.
    private func handleReachabilityBecameTrue() {
        guard queuedRequestToken != nil else { return }
        queuedRequestToken = nil
        queueTTLTask?.cancel()
        queueTTLTask = nil
        Task { [weak self] in
            await self?.openGate()
        }
    }

    private func performOpen() async {
        state = .opening

        do {
            let endpointId = try requireSelectedEndpointId()
            let _ = try await tokenManager.accessToken()
            try await gateClient.open(endpointId: endpointId)
            transition(to: .succeeded(at: Date()))
        } catch {
            handleOpenFailure(error)
        }
    }

    /// Maps any thrown error from the open attempt to a terminal state.
    /// `.notConfigured` routes to `.needsSetup` (not `.failed`) per the
    /// bead brief; everything else gets a SHORT human message.
    private func handleOpenFailure(_ error: Error) {
        if isNotConfigured(error) {
            cancelPendingReset()
            state = .needsSetup
            return
        }
        transition(to: .failed(message: Self.shortMessage(for: error)))
    }

    private func requireSelectedEndpointId() throws -> String {
        guard let endpointId = appSettings.selectedEndpointId, !endpointId.isEmpty else {
            throw TokenManagerError.notConfigured
        }
        return endpointId
    }

    // MARK: - Error -> short human message mapping

    private func isNotConfigured(_ error: Error) -> Bool {
        if let tokenError = error as? TokenManagerError, tokenError == .notConfigured {
            return true
        }
        return false
    }

    /// Maps an error to a SHORT, human-readable message suitable for a
    /// menu-bar tooltip/notification. Never surfaces a raw `Error`
    /// description (and, structurally, never a token/password/credential:
    /// none of the cases below ever interpolate the underlying error's
    /// associated values into the returned string).
    static func shortMessage(for error: Error) -> String {
        if let comelitError = error as? ComelitError {
            switch comelitError {
            case .invalidCredentials:
                return "Wrong username or password"
            case .network, .server, .missingRefreshToken:
                return "Could not reach the gate"
            case .decoding:
                return "Could not reach the gate"
            }
        }
        if let gateClientError = error as? GateClientError {
            switch gateClientError {
            case .noEndpointsFound, .noGateFound:
                return "No gate found"
            }
        }
        // `errSecInteractionNotAllowed` (-25308): the keychain item's
        // accessibility class requires the device to have been unlocked
        // (see `KeychainAccessibility`), but the current process cannot
        // prompt for/perform that interaction right now — this is the
        // status a locked-device App Intent / widget invocation surfaces
        // when it tries to read credentials/tokens before first unlock.
        // Mapped to an explicit, actionable message rather than falling
        // through to the generic one below.
        if let keychainError = error as? KeychainError {
            switch keychainError {
            case .loadFailed(let status), .saveFailed(let status), .deleteFailed(let status):
                if status == errSecInteractionNotAllowed {
                    return "Unlock iPhone to open the gate"
                }
            case .decodeFailed:
                break
            }
        }
        // Unknown error type: a generic short message, never the raw
        // description (which could contain a URL, status body fragment, or
        // other implementation detail unsuitable for end-user display).
        return "Could not open the gate"
    }

    // MARK: - Terminal-state transition + auto-reset

    /// Set a terminal state (`.succeeded`/`.failed`) and schedule the
    /// best-effort auto-return to `.idle` after `autoResetDelay`.
    ///
    /// "Best-effort" per the bead's edge case: clock skew or system sleep
    /// between now and the scheduled reset must never wedge the state. This
    /// is satisfied structurally — the reset task only ever writes `.idle`
    /// if `state` is STILL the same terminal state it scheduled from (a
    /// concurrent `openGate()` call, or another transition, may have already
    /// moved state elsewhere, in which case the stale reset is a no-op
    /// rather than clobbering newer state). If `sleep` throws (e.g. task
    /// cancellation), the reset simply does not happen — it never leaves
    /// `state` stuck, since the terminal state itself (not `.opening`) is
    /// already a valid resting state.
    private func transition(to newState: GateState) {
        cancelPendingReset()
        state = newState

        resetTask = Task { [weak self, autoResetDelay, sleep] in
            guard let self else { return }
            do {
                try await sleep(autoResetDelay)
            } catch {
                return
            }
            self.resetToIdleIfStillShowing(newState)
        }
    }

    private func resetToIdleIfStillShowing(_ expected: GateState) {
        guard state == expected else { return }
        state = .idle
    }

    private func cancelPendingReset() {
        resetTask?.cancel()
        resetTask = nil
    }

    // MARK: - First-time setup

    /// Saves credentials, logs in, discovers gates (no `aptId` — live-verified
    /// unnecessary, see `AppSettings.aptId`'s doc comment), and auto-selects
    /// the top candidate gate (`GateClient.candidateGates` ranks
    /// `LOCK_GENERIC` first).
    ///
    /// On success, persists `selectedEndpointId` + `selectedEndpointName` +
    /// `lastDiscoveryDate` to `AppSettings`, and opportunistically populates
    /// `AppSettings.aptId` via `GateClient.parseAptId(fromEndpointId:)` when
    /// derivable (nothing gates on this succeeding).
    ///
    /// On `.invalidCredentials`, the error propagates distinctly (so the UI
    /// can say the password is wrong) and NOTHING is persisted — not the
    /// credentials that were about to be saved for real use, and not any
    /// selection. Note: credentials ARE saved to the credential store before
    /// the login attempt (a login call needs them to already be resolvable
    /// via the normal `TokenManager` path in general use), but on failure
    /// this method deletes what it just saved so no half-written state
    /// survives a failed setup.
    ///
    /// If discovery yields no candidate gate, throws
    /// `GateClientError.noGateFound` and persists no selection (any
    /// credentials saved this call are also rolled back, matching the
    /// `.invalidCredentials` case, since setup as a whole did not succeed).
    public func performFirstTimeSetup(username: String, password: String) async throws {
        try credentialStore.saveCredentials(username: username, password: password)

        do {
            _ = try await tokenManager.accessToken()
        } catch {
            try? credentialStore.deleteCredentials()
            try? credentialStore.deleteTokens()
            throw error
        }

        let endpoints: [Endpoint]
        do {
            endpoints = try await gateClient.discover(aptId: nil)
        } catch {
            try? credentialStore.deleteCredentials()
            try? credentialStore.deleteTokens()
            throw error
        }

        let candidates = GateClient.candidateGates(from: endpoints)
        guard let selected = candidates.first else {
            try? credentialStore.deleteCredentials()
            try? credentialStore.deleteTokens()
            throw GateClientError.noGateFound
        }

        appSettings.selectedEndpointId = selected.endpointId
        appSettings.selectedEndpointName = selected.friendlyName
        appSettings.lastDiscoveryDate = Date()
        appSettings.cachedGates = candidates
        if let aptId = GateClient.parseAptId(fromEndpointId: selected.endpointId) {
            appSettings.aptId = aptId
        }

        state = .idle
    }

    // MARK: - Gate list refresh (for the Settings gate picker, bead .9)

    /// Re-runs discovery and returns the filtered candidate list. Does NOT
    /// mutate the SELECTION in `AppSettings` (selection happens via
    /// `selectGate(_:)`) and must not clear an existing valid selection if
    /// discovery fails — this method simply propagates the failure and
    /// leaves `AppSettings` untouched in that case. On success, the
    /// filtered candidate list is persisted to `appSettings.cachedGates`
    /// (bead gateopener-672.10) so the Settings gate picker has something
    /// to show without a fresh network round trip on every appearance.
    public func refreshGates() async throws -> [Endpoint] {
        let endpoints = try await gateClient.discover(aptId: appSettings.aptId)
        appSettings.lastDiscoveryDate = Date()
        let candidates = GateClient.candidateGates(from: endpoints)
        appSettings.cachedGates = candidates
        return candidates
    }

    // MARK: - Gate selection

    /// Persists the chosen gate. Routed through the controller (rather than
    /// letting the UI write `AppSettings` directly) so `onStateChange`-based
    /// observers always see a consistent picture — see the file-level doc
    /// comment on the observability approach.
    public func selectGate(_ endpoint: Endpoint) {
        appSettings.selectedEndpointId = endpoint.endpointId
        appSettings.selectedEndpointName = endpoint.friendlyName
        if state == .needsSetup {
            state = .idle
        }
    }

    // MARK: - Shortcut preference

    /// The persisted global-hotkey preference (bead gateopener-3vq.4).
    /// Read-only mirror of `appSettings.shortcutPreference`, exposed so the
    /// app layer (`GateControllerObservable`) can read the durable value —
    /// e.g. at launch — without `AppSettings` itself needing to be exposed
    /// for direct writes. This getter carries no side effect: it does not
    /// touch the live Carbon registration.
    public var shortcutPreference: ShortcutPreference {
        appSettings.shortcutPreference
    }

    /// Persists a new shortcut preference. This is the ONLY path by which
    /// the UI may change `AppSettings.shortcutPreference` — mirrors
    /// `selectGate(_:)` above: routed through the controller rather than
    /// letting a view write `AppSettings` directly, so the value can never
    /// be changed without going through one auditable place. Does NOT
    /// itself touch the live Carbon registration (that is a Carbon/AppKit
    /// concern living in the app layer's `GlobalHotkey`, which
    /// `GateOpenerCore` must never import — see this file's HARD
    /// CONSTRAINT). The app layer (`GateControllerObservable`) is
    /// responsible for calling this AND applying the same value to
    /// `GlobalHotkey` so persistence and live effect never drift apart.
    public func setShortcutPreference(_ preference: ShortcutPreference) {
        appSettings.shortcutPreference = preference
    }

    // MARK: - Sign out

    /// Clears keychain credentials AND tokens, clears `AppSettings`, and
    /// returns to `.needsSetup`.
    public func signOut() {
        cancelPendingReset()
        openTask?.cancel()
        openTask = nil
        queueTTLTask?.cancel()
        queueTTLTask = nil
        queuedRequestToken = nil
        try? credentialStore.deleteCredentials()
        try? credentialStore.deleteTokens()
        appSettings.reset()
        state = .needsSetup
    }
}
