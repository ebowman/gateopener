import Foundation
import Testing
@testable import GateOpenerCore

// MARK: - OpenAttemptRecord Codable round-trip

/// `OpenAttemptRecord` is stored/transmitted as JSON (see the bead's parent
/// epic: a future bead persists these to an App Group journal), so every
/// `OpenAttemptOutcome` case must survive an encode/decode round-trip
/// exactly.
@Test(arguments: [
    OpenAttemptOutcome.success(status: 202),
    .httpFailure(status: 500),
    .transportFailure(urlErrorCode: URLError.networkConnectionLost.rawValue),
    .tokenFailure(description: "invalid credentials"),
])
func openAttemptRecordRoundTripsThroughCodable(outcome: OpenAttemptOutcome) throws {
    let original = OpenAttemptRecord(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        attempt: 2,
        maxAttempts: 3,
        outcome: outcome,
        elapsedMilliseconds: 2900,
        willRetry: true
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(OpenAttemptRecord.self, from: data)

    #expect(decoded == original)
}
