import Foundation

/// Pure line-format logic for macOS `DoorVideoSession`'s diagnostics
/// recording (bead gateopener-kgx.6): every stage line `DoorVideoSession`
/// appends to its `VideoDiagnostics` instance is built by one of these
/// static funcs, so the exact wording is unit-testable even though
/// `WKWebView` itself cannot be exercised headlessly (there is no headless
/// WebKit harness in this codebase — see the type doc comment on
/// `DoorVideoSession`).
///
/// Deliberately payload-free / side-effect-free: every func here takes
/// plain values and returns a `String`, with no knowledge of `VideoDiagnostics`,
/// `Logger`, or `UserDefaults`. `DoorVideoSession` is responsible for calling
/// `diagnostics.append(...)` and mirroring to `Self.logger.notice(...)`.
///
/// Wording is deliberately kept close to the iOS reference
/// (`iOS/App/Video/DoorVideoSession.swift`) where the two platforms record
/// the same event, so a merged/compared log from both platforms reads
/// consistently — see e.g. "rtc/offer attempt N/M ..." and "terminal
/// reason: ...".
public enum VideoDiagnosticsStage {
    /// "session start" line: app version/build (from `Bundle.main`) and the
    /// host OS version (from `ProcessInfo.operatingSystemVersionString`).
    /// Neither value can ever embed anything address- or credential-shaped,
    /// so this is safe to persist and paste verbatim.
    public static func sessionStart(appVersion: String, build: String, os: String) -> String {
        "session start: app \(appVersion) (\(build)), macOS \(os)"
    }

    /// One outcome of resolving an access token: success, or a short
    /// failure reason (never the token itself).
    public enum TokenOutcome {
        case ok
        case failed(String)
    }

    /// "token ok"/"token failed: <reason>" — never the token itself, only
    /// success or a short failure reason.
    public static func tokenResolved(outcome: TokenOutcome) -> String {
        switch outcome {
        case .ok:
            return "token ok"
        case .failed(let reason):
            return "token failed: \(reason)"
        }
    }

    /// "endpoint <suffix>" where `<suffix>` is ONLY the portion of the
    /// endpoint id from `"VIP#"` onward (e.g. an id of
    /// `"_DA_123_abc-00001_VIP#OD#SB100001.1"` yields `"VIP#OD#SB100001.1"`)
    /// — NEVER the full endpoint id, which embeds the Comelit apartment id
    /// ahead of the `VIP#` marker.
    ///
    /// If `id` contains no `"VIP#"` marker at all (unexpected, but must
    /// still never leak the full id), this falls back to the id's last 12
    /// characters, which is short enough to be useless for re-identifying
    /// the apartment on its own while still being a distinguishing
    /// fragment for diagnostics. An empty/very short id (under 12 chars,
    /// with no `"VIP#"`) falls back to the literal `"<unrecognised>"`
    /// rather than emitting the (short but still complete) id verbatim.
    public static func endpointResolved(id: String) -> String {
        "endpoint \(endpointSuffix(of: id))"
    }

    /// The pure suffix-extraction helper behind `endpointResolved(id:)`,
    /// exposed separately so tests can assert on the truncation logic in
    /// isolation from the surrounding line text.
    public static func endpointSuffix(of id: String) -> String {
        if let range = id.range(of: "VIP#") {
            return String(id[range.lowerBound...])
        }
        if id.count > 12 {
            return String(id.suffix(12))
        }
        return "<unrecognised>"
    }

    /// "stun resolved N addresses" — count only, never the addresses
    /// themselves.
    public static func stunResolved(count: Int) -> String {
        "stun resolved \(count) addresses"
    }

    /// "offer ready: N candidates" — the non-trickle offer SDP's ICE
    /// candidate count, never the SDP or the candidates themselves.
    public static func offerReady(candidateCount: Int) -> String {
        "offer ready: \(candidateCount) candidates"
    }

    /// One outcome of a single `rtc/offer` PUT attempt: either a successful
    /// HTTP 200, or a failure with a short description (an HTTP status or
    /// "network-error").
    public enum OfferOutcome {
        case success
        case failure(String)
    }

    /// "rtc/offer attempt N/M <status> latencyMs=X" — mirrors the iOS
    /// wording (`"rtc/offer attempt N/M status=... latencyMs=..."`) closely
    /// enough that the two platforms' logs read the same, while matching
    /// this bead's literal phrasing ("status/error and latency in ms").
    public static func offerAttempt(n: Int, of m: Int, outcome: OfferOutcome, latencyMs: Int) -> String {
        switch outcome {
        case .success:
            return "rtc/offer attempt \(n)/\(m) status=200 latencyMs=\(latencyMs)"
        case .failure(let description):
            return "rtc/offer attempt \(n)/\(m) status=\(description) latencyMs=\(latencyMs)"
        }
    }

    /// "answer applied" — the answer SDP has been handed to
    /// `RTCPeerConnection.setRemoteDescription` successfully.
    public static func answerApplied() -> String {
        "answer applied"
    }

    /// "video stats: <json>" — mirrors the existing `os.Logger` wording
    /// (`DoorVideoSession.watchForFirstFrame`'s `"video stats: \(jsonStr)"`)
    /// so the diagnostics record and the unified log agree. `json` is
    /// whatever `window.getVideoStats()` returned; the caller is
    /// responsible for only calling this when the JSON has CHANGED since
    /// the last poll.
    public static func videoStats(json: String) -> String {
        "video stats: \(json)"
    }

    /// The terminal outcome of a session, one of exactly four shapes per
    /// this bead's requirement:
    ///  - `.streaming(afterSeconds:)` -> "streaming after X.Xs"
    ///  - `.noVideo` -> "no video after 20s"
    ///  - `.failed(message:)` -> "failed: <message>"
    ///  - `.stopped` -> "stopped by caller"
    public enum TerminalReason {
        case streaming(afterSeconds: Double)
        case noVideo
        case failed(message: String)
        case stopped
    }

    /// "terminal: <reason>" formatting for `TerminalReason`. Prefixed with
    /// "terminal: " (distinct from the iOS wording's "terminal reason: ",
    /// which is bare, no colon-prefix duplication needed there) so a
    /// `grep terminal` finds it reliably in a merged log.
    public static func terminal(_ reason: TerminalReason) -> String {
        switch reason {
        case .streaming(let afterSeconds):
            return "terminal: streaming after \(String(format: "%.1f", afterSeconds))s"
        case .noVideo:
            return "terminal: no video after 20s"
        case .failed(let message):
            return "terminal: failed: \(message)"
        case .stopped:
            return "terminal: stopped by caller"
        }
    }
}
