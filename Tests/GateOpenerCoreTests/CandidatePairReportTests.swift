import Foundation
import Testing
@testable import GateOpenerCore

/// Tests for `CandidatePairReport` and `VideoDiagnosticsStage.candidatePair`/
/// `candidatePairSummary` (bead gateopener-6s8.6): the pure decode + line-
/// format logic behind macOS `DoorVideoSession`'s one-shot candidate-pair
/// diagnostics dump. `door-video.html`'s `window.getCandidatePairs()` cannot
/// be exercised headlessly (no `WKWebView` harness), so these tests are the
/// only automated coverage of the exact JSON shape and line wording.
struct CandidatePairReportTests {
    // MARK: - VideoDiagnosticsStage.candidatePair / candidatePairSummary

    @Test func candidatePairFormatsExactLine() {
        let line = VideoDiagnosticsStage.candidatePair(
            index: 1,
            state: "succeeded",
            nominated: true,
            localType: "prflx",
            localProtocol: "udp",
            localFamily: "v4",
            remoteType: "host",
            remoteProtocol: "udp",
            remoteFamily: "v4",
            requestsSent: 3,
            responsesReceived: 3
        )
        #expect(line == "candidate pair 1: state=succeeded nominated=true local=prflx/udp/v4 remote=host/udp/v4 req=3 resp=3")
    }

    @Test func candidatePairSummaryFormatsExactLine() {
        let line = VideoDiagnosticsStage.candidatePairSummary(
            count: 3,
            remoteTypes: ["host", "srflx", "relay"],
            iceConnectionState: "checking",
            connectionState: "connecting"
        )
        #expect(line == "candidate pairs: 3, remote types: [host, srflx, relay], ice=checking conn=connecting")
    }

    // MARK: - CandidatePairReport.parse

    @Test func parseDecodesFullShape() {
        let json = #"""
        {
          "iceConnectionState": "checking",
          "connectionState": "connecting",
          "remoteCandidateTypes": ["host", "srflx"],
          "pairs": [
            {
              "state": "succeeded",
              "nominated": true,
              "local": {"type": "prflx", "protocol": "udp", "family": "v4"},
              "remote": {"type": "host", "protocol": "udp", "family": "v4"},
              "requestsSent": 3,
              "responsesReceived": 3
            }
          ]
        }
        """#
        let report = CandidatePairReport.parse(json: json)
        #expect(report != nil)
        #expect(report?.pairs?.count == 1)
        #expect(report?.pairs?.first?.state == "succeeded")
        #expect(report?.remoteCandidateTypes == ["host", "srflx"])
    }

    @Test func parseMalformedJSONReturnsNil() {
        #expect(CandidatePairReport.parse(json: "{not valid json") == nil)
        #expect(CandidatePairReport.parse(json: "") == nil)
        #expect(CandidatePairReport.parse(json: #"{"pairs": "not an array"}"#) == nil)
    }

    // MARK: - diagLines: fixed JSON -> exact lines

    @Test func diagLinesProducesSummaryThenPairLines() {
        let json = #"""
        {
          "iceConnectionState": "connected",
          "connectionState": "connected",
          "remoteCandidateTypes": ["host", "srflx", "relay"],
          "pairs": [
            {
              "state": "succeeded",
              "nominated": true,
              "local": {"type": "prflx", "protocol": "udp", "family": "v4"},
              "remote": {"type": "host", "protocol": "udp", "family": "v4"},
              "requestsSent": 3,
              "responsesReceived": 3
            },
            {
              "state": "waiting",
              "nominated": false,
              "local": {"type": "host", "protocol": "udp", "family": "v6"},
              "remote": {"type": "relay", "protocol": "udp", "family": "v6"},
              "requestsSent": 0,
              "responsesReceived": 0
            }
          ]
        }
        """#
        guard let report = CandidatePairReport.parse(json: json) else {
            Issue.record("expected report to decode")
            return
        }
        let lines = report.diagLines()
        #expect(lines == [
            "candidate pairs: 2, remote types: [host, srflx, relay], ice=connected conn=connected",
            "candidate pair 1: state=succeeded nominated=true local=prflx/udp/v4 remote=host/udp/v4 req=3 resp=3",
            "candidate pair 2: state=waiting nominated=false local=host/udp/v6 remote=relay/udp/v6 req=0 resp=0",
        ])
    }

    // MARK: - error payload

    @Test func diagLinesForErrorPayloadIsSingleSummaryLine() {
        let report = CandidatePairReport.parse(json: #"{"error": "no pc"}"#)
        #expect(report != nil)
        #expect(report?.diagLines() == ["candidate pairs: unavailable (no pc)"])
    }

    // MARK: - cap at 12

    @Test func diagLinesCapsAt12Pairs() {
        var pairsJSON: [String] = []
        for i in 0..<20 {
            pairsJSON.append(#"""
            {
              "state": "succeeded",
              "nominated": false,
              "local": {"type": "host", "protocol": "udp", "family": "v4"},
              "remote": {"type": "host", "protocol": "udp", "family": "v4"},
              "requestsSent": \#(i),
              "responsesReceived": \#(i)
            }
            """#)
        }
        let json = #"{"iceConnectionState": "connected", "connectionState": "connected", "remoteCandidateTypes": [], "pairs": ["# +
            pairsJSON.joined(separator: ",") + "]}"

        guard let report = CandidatePairReport.parse(json: json) else {
            Issue.record("expected report to decode")
            return
        }
        #expect(report.pairs?.count == 20)
        let lines = report.diagLines()
        // 1 summary line + 12 pair lines (capped), never 20.
        #expect(lines.count == 13)
        #expect(lines.first?.hasPrefix("candidate pairs: 12,") == true)
        #expect(lines.last?.hasPrefix("candidate pair 12:") == true)
    }

    // MARK: - never leaks an address

    /// A report whose type/protocol/family fields ILLEGALLY carry a dotted-
    /// quad or colon-hex address (this should never happen from
    /// `door-video.html`'s own `addressFamily()`/candidate-type values, but
    /// this test proves `diagLines()` still would not leak it if it did —
    /// i.e. the formatter whitelists FIELDS, not values, so no downstream
    /// value can smuggle an address through).
    @Test func diagLinesNeverContainsAnAddressPatternEvenIfFieldsAreIllegallyPopulatedWithOne() {
        let json = #"""
        {
          "iceConnectionState": "connected",
          "connectionState": "connected",
          "remoteCandidateTypes": ["192.168.1.5"],
          "pairs": [
            {
              "state": "succeeded",
              "nominated": true,
              "local": {"type": "192.168.1.5", "protocol": "udp", "family": "192.168.1.5"},
              "remote": {"type": "fe80::1", "protocol": "udp", "family": "fe80::1"},
              "requestsSent": 1,
              "responsesReceived": 1
            }
          ]
        }
        """#
        guard let report = CandidatePairReport.parse(json: json) else {
            Issue.record("expected report to decode")
            return
        }
        let lines = report.diagLines()
        let combined = lines.joined(separator: "\n")

        // dotted-quad: one-to-three digits, dot, repeated 3x, one-to-three digits
        let dottedQuad = try! NSRegularExpression(pattern: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#)
        // colon-hex: at least two hex groups separated by a colon (v6-shaped)
        let colonHex = try! NSRegularExpression(pattern: #"\b[0-9a-fA-F]{1,4}:[0-9a-fA-F:]+\b"#)

        let range = NSRange(combined.startIndex..., in: combined)
        #expect(dottedQuad.firstMatch(in: combined, range: range) == nil)
        #expect(colonHex.firstMatch(in: combined, range: range) == nil)
    }

    /// MUTATION CHECK (per bd memory `gateopener-vacuous-assertion-failure-mode`):
    /// deliberately mutate the whitelist by adding an `address` field to a
    /// local reproduction of the Codable model and interpolating it into a
    /// line, then confirm the SAME regexes above would then fail — proving
    /// the "never leaks an address" test is not vacuously true (i.e. it
    /// would catch a real regression where a future field gets added to
    /// `CandidatePairReport`/`diagLines()` without going through the
    /// whitelist).
    @Test func mutationCheckAddingAnAddressFieldToDiagLinesWouldFailTheRegexTest() {
        struct MutatedCandidate: Codable {
            let type: String
            let `protocol`: String
            let family: String
            let address: String
        }
        let mutatedLocal = MutatedCandidate(type: "host", protocol: "udp", family: "v4", address: "192.168.1.5")
        // Simulates the broken variant: a hypothetical mutated `diagLines()`
        // that (incorrectly) interpolates `local.address` into the pair line
        // instead of sticking to the whitelisted type/protocol/family.
        let brokenLine = "candidate pair 1: state=succeeded nominated=true " +
            "local=\(mutatedLocal.type)/\(mutatedLocal.protocol)/\(mutatedLocal.family) addr=\(mutatedLocal.address) " +
            "remote=host/udp/v4 req=1 resp=1"

        let dottedQuad = try! NSRegularExpression(pattern: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#)
        let range = NSRange(brokenLine.startIndex..., in: brokenLine)
        // Proves the regex assertion is load-bearing: it DOES fire on the
        // broken variant, even though the real `diagLines()` (tested above)
        // never produces a line the regex matches.
        #expect(dottedQuad.firstMatch(in: brokenLine, range: range) != nil)
    }
}
