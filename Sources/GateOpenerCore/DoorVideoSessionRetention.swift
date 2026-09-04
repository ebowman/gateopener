/// Payload-free mirror of the app-layer `DoorVideoSessionState`
/// (`Sources/GateOpener/DoorVideoSession.swift`), which carries associated
/// values (`ended(reason:)`, `failed(message:)`) that Core has no business
/// knowing about. This type exists purely so the retain-or-replace policy
/// below can live in, and be tested from, `GateOpenerCore` without pulling
/// the app target's types (or its WKWebView/AVFoundation dependencies) into
/// Core.
public enum DoorVideoSessionPhase: Sendable, Equatable {
    case idle
    case connecting
    case streaming
    case ended
    case failed
}

/// Whether a new door-video open request should retain an existing session
/// or tear it down and replace it with a fresh one.
public enum DoorVideoSessionRetention: Sendable, Equatable {
    case retain
    case replace

    /// Pure retain-or-replace policy for a repeat door-video open arriving
    /// while a session already exists (or doesn't). Introduced for epic
    /// gateopener-ufk: "second gate-open click must not restart an
    /// in-flight door-video load".
    ///
    /// - `nil` (no existing session) and `.idle` both `.replace`: there is
    ///   nothing in flight worth preserving, so starting fresh is correct
    ///   and has no downside.
    /// - `.connecting` and `.streaming` both `.retain`: a new open arriving
    ///   mid-connect or mid-stream must NOT discard the existing session,
    ///   because the door's WebRTC warm-up (signaling, ICE, DTLS, first
    ///   frame) takes multiple seconds — see the `../comelit` video notes
    ///   referenced from this project's `CLAUDE.md` — and tearing that down
    ///   just to restart it on every repeat click would mean a user who
    ///   double-clicks "View" never actually sees video, only an endless
    ///   series of restarted warm-ups.
    /// - `.ended` and `.failed` both `.replace`: these are terminal states
    ///   (the door's ~28-30s streaming window elapsed, or the session
    ///   errored out), so there is nothing in flight to protect, and a
    ///   second click here is the user's deliberate signal to retry —
    ///   replacing with a fresh session is exactly what should happen.
    public static func decision(forExistingPhase phase: DoorVideoSessionPhase?) -> DoorVideoSessionRetention {
        guard let phase else {
            return .replace
        }
        switch phase {
        case .idle:
            return .replace
        case .connecting:
            return .retain
        case .streaming:
            return .retain
        case .ended:
            return .replace
        case .failed:
            return .replace
        }
    }
}
