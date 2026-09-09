import Foundation

/// Pure decoder + line-builder for the JSON produced by `door-video.html`'s
/// `window.getCandidatePairs()` (bead gateopener-6s8.6). `DoorVideoSession`
/// calls that JS function once per terminal event (the 20s no-video
/// deadline, or a post-answer-applied failure), then hands the raw JSON
/// string to `CandidatePairReport.parse(json:)` and records `diagLines()`
/// into its diagnostics — this type owns both the decoding and the
/// whitelisted rendering, so `DoorVideoSession` never touches raw JSON
/// fields directly and can never accidentally interpolate an
/// address/port-shaped value into a diagnostics line.
///
/// `diagLines()` is a WHITELIST: it only ever reads `state`, `nominated`,
/// `local.type`/`local.protocol`/`local.family`, `remote.type`/
/// `remote.protocol`/`remote.family`, `requestsSent`, `responsesReceived`,
/// `remoteCandidateTypes`, `iceConnectionState`, and `connectionState` — the
/// exact fields `VideoDiagnosticsStage.candidatePair`/`candidatePairSummary`
/// accept. It never copies an arbitrary JSON string (e.g. an `error`
/// message, or any field this type does not explicitly model) verbatim into
/// a line beyond the single documented `"candidate pairs: unavailable
/// (<error>)"` case, and even there `error` is a `String` field that this
/// bead's JS side (`door-video.html`) never populates with an address —
/// see that file's `getCandidatePairs` doc comment.
public struct CandidatePairReport: Codable, Equatable {
    /// Bound to 12 by `door-video.html`'s `getCandidatePairs` (`.slice(0, 12)`)
    /// before this type ever sees the JSON; `diagLines()` re-applies the
    /// same cap defensively so a future JS-side regression cannot balloon
    /// the persisted diagnostics.
    public static let maxPairs = 12

    public struct Candidate: Codable, Equatable {
        public let type: String
        public let `protocol`: String
        public let family: String

        public init(type: String, protocol: String, family: String) {
            self.type = type
            self.protocol = `protocol`
            self.family = family
        }
    }

    public struct Pair: Codable, Equatable {
        public let state: String
        public let nominated: Bool
        public let local: Candidate
        public let remote: Candidate
        public let requestsSent: Int
        public let responsesReceived: Int

        public init(
            state: String,
            nominated: Bool,
            local: Candidate,
            remote: Candidate,
            requestsSent: Int,
            responsesReceived: Int
        ) {
            self.state = state
            self.nominated = nominated
            self.local = local
            self.remote = remote
            self.requestsSent = requestsSent
            self.responsesReceived = responsesReceived
        }
    }

    public let iceConnectionState: String?
    public let connectionState: String?
    public let remoteCandidateTypes: [String]?
    public let pairs: [Pair]?
    /// Present only on the JS side's best-effort failure payload
    /// (`{"error": "..."}`); mutually exclusive with the above in practice,
    /// but this type does not enforce that — `diagLines()` simply checks
    /// `error` first.
    public let error: String?

    public init(
        iceConnectionState: String? = nil,
        connectionState: String? = nil,
        remoteCandidateTypes: [String]? = nil,
        pairs: [Pair]? = nil,
        error: String? = nil
    ) {
        self.iceConnectionState = iceConnectionState
        self.connectionState = connectionState
        self.remoteCandidateTypes = remoteCandidateTypes
        self.pairs = pairs
        self.error = error
    }

    /// Decodes `json` (as returned by `window.getCandidatePairs()`) into a
    /// `CandidatePairReport`. Returns `nil` on any decode failure (malformed
    /// JSON, wrong shape, non-UTF8 string) — callers should record a fixed
    /// "unavailable" line themselves in that case, mirroring how
    /// `DoorVideoSession` already treats other page-bridge failures.
    public static func parse(json: String) -> CandidatePairReport? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CandidatePairReport.self, from: data)
    }

    /// Renders this report into the diagnostics lines `DoorVideoSession`
    /// should record, via `VideoDiagnosticsStage`'s formatters exclusively —
    /// see this type's doc comment for the whitelist guarantee. Three
    /// shapes:
    ///  - `error` set: a single `"candidate pairs: unavailable (<error>)"`
    ///    line.
    ///  - otherwise: one `candidatePairSummary(...)` line, followed by one
    ///    `candidatePair(...)` line per pair (capped at
    ///    `CandidatePairReport.maxPairs`, 1-based `index`).
    ///
    /// Every `type`/`protocol`/`family` value (including each entry of
    /// `remoteCandidateTypes`) is passed through `Self.sanitized(_:)` first
    /// — belt-and-suspenders against a page-side bug that (illegally)
    /// populated one of those fields with an address instead of the short
    /// enum-like token `door-video.html`'s `getCandidatePairs` always
    /// produces: this whitelist is about which FIELDS are read, but it must
    /// still never let an address-shaped VALUE in one of those fields reach
    /// a persisted line.
    public func diagLines() -> [String] {
        if let error {
            return ["candidate pairs: unavailable (\(error))"]
        }

        let cappedPairs = Array((pairs ?? []).prefix(Self.maxPairs))
        var lines: [String] = [
            VideoDiagnosticsStage.candidatePairSummary(
                count: cappedPairs.count,
                remoteTypes: (remoteCandidateTypes ?? []).map(Self.sanitized),
                iceConnectionState: iceConnectionState ?? "unknown",
                connectionState: connectionState ?? "unknown"
            ),
        ]

        for (offset, pair) in cappedPairs.enumerated() {
            lines.append(
                VideoDiagnosticsStage.candidatePair(
                    index: offset + 1,
                    state: pair.state,
                    nominated: pair.nominated,
                    localType: Self.sanitized(pair.local.type),
                    localProtocol: Self.sanitized(pair.local.protocol),
                    localFamily: Self.sanitized(pair.local.family),
                    remoteType: Self.sanitized(pair.remote.type),
                    remoteProtocol: Self.sanitized(pair.remote.protocol),
                    remoteFamily: Self.sanitized(pair.remote.family),
                    requestsSent: pair.requestsSent,
                    responsesReceived: pair.responsesReceived
                )
            )
        }

        return lines
    }

    /// Regex for an IPv4 dotted-quad (1-3 digits, dot, x3, 1-3 digits).
    private static let dottedQuadPattern = try! NSRegularExpression(pattern: #"^\d{1,3}(\.\d{1,3}){3}$"#)
    /// Regex for a colon-hex (IPv6-shaped) token: at least two hex groups
    /// joined by colons.
    private static let colonHexPattern = try! NSRegularExpression(pattern: #"^[0-9a-fA-F]{0,4}(:[0-9a-fA-F]{0,4}){2,}$"#)

    /// Replaces `value` with the fixed token `"redacted"` if it looks
    /// address-shaped (an IPv4 dotted-quad or an IPv6 colon-hex form);
    /// otherwise returns `value` unchanged. This is a defensive check on
    /// top of the field-level whitelist above — `door-video.html` never
    /// legitimately produces an address-shaped `type`/`protocol`/`family`
    /// value, so this only ever fires on a bug or a hostile page.
    static func sanitized(_ value: String) -> String {
        let range = NSRange(value.startIndex..., in: value)
        if dottedQuadPattern.firstMatch(in: value, range: range) != nil {
            return "redacted"
        }
        if colonHexPattern.firstMatch(in: value, range: range) != nil {
            return "redacted"
        }
        return value
    }
}
