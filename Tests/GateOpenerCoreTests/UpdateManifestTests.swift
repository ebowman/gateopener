import Foundation
import Testing
@testable import GateOpenerCore

/// Tests for `SemanticVersion` and `UpdateManifest`.
///
/// `SemanticVersion` is pure, sharp-edged parsing/comparison logic with a
/// security-relevant fail-closed contract (see its doc comment), so this
/// suite is deliberately exhaustive about malformed input: every case below
/// is a rule that, if inverted or removed, must make the corresponding
/// assertion fail. See `gateopener-vacuous-assertion-failure-mode`.
struct UpdateManifestTests {

    // MARK: - SemanticVersion parsing

    @Test func parsesThreeComponents() {
        #expect(SemanticVersion("1.4.0") != nil)
    }

    @Test func parsesOneComponent() {
        #expect(SemanticVersion("5") != nil)
    }

    @Test func parsesFourComponents() {
        #expect(SemanticVersion("1.2.3.4") != nil)
    }

    @Test func rejectsFiveComponents() {
        #expect(SemanticVersion("1.2.3.4.5") == nil)
    }

    @Test func rejectsEmptyString() {
        #expect(SemanticVersion("") == nil)
    }

    @Test func rejectsWhitespaceOnly() {
        #expect(SemanticVersion("   ") == nil)
    }

    @Test func rejectsNonNumericComponent() {
        #expect(SemanticVersion("1.x.0") == nil)
    }

    @Test func rejectsNegativeComponent() {
        #expect(SemanticVersion("1.-2.0") == nil)
    }

    @Test func rejectsEmbeddedWhitespace() {
        #expect(SemanticVersion("1. 2.0") == nil)
    }

    @Test func rejectsEmptyComponent() {
        #expect(SemanticVersion("1..0") == nil)
    }

    @Test func rejectsTrailingDot() {
        #expect(SemanticVersion("1.2.") == nil)
    }

    @Test func rejectsSignedComponent() {
        #expect(SemanticVersion("1.+2.0") == nil)
    }

    @Test func absurdlyLongInputFailsFastWithoutCrashOrHang() {
        let garbage = String(repeating: "9", count: 1_000_000)
        // A single 1,000,000-digit component: too large to be a real
        // version, but must not hang or crash — Int(_:) simply overflows to
        // nil, which SemanticVersion must treat as unparseable.
        #expect(SemanticVersion(garbage) == nil)

        let manyComponents = String(repeating: "1.", count: 1_000_000) + "1"
        // Far more than 4 components: must be rejected by the count check,
        // and rejected FAST (the count check runs before per-component
        // parsing), not hang attempting to parse a million components.
        #expect(SemanticVersion(manyComponents) == nil)
    }

    // MARK: - Missing trailing components default to zero

    @Test func missingTrailingComponentsDefaultToZero() {
        #expect(SemanticVersion("1.4") == SemanticVersion("1.4.0"))
        #expect(SemanticVersion("1.4") == SemanticVersion("1.4.0.0"))
        #expect(SemanticVersion("1") == SemanticVersion("1.0.0.0"))
    }

    @Test func missingTrailingComponentsDefaultToZeroNotToSomethingElse() {
        // Guards against a broken implementation that pads with a sentinel
        // other than 0 (e.g. treats a shorter version as always-smaller
        // regardless of numeric value, or always-equal to everything).
        #expect(SemanticVersion("1.4") != SemanticVersion("1.4.1"))
        #expect((SemanticVersion("1.4")! < SemanticVersion("1.4.1")!))
        #expect(!(SemanticVersion("1.4")! < SemanticVersion("1.3.9")!))
    }

    // MARK: - Leading zeros (documented decision: parsed as decimal, so "1.04" == "1.4")

    @Test func leadingZerosParseAsDecimalInteger() {
        #expect(SemanticVersion("1.04") == SemanticVersion("1.4"))
        #expect(SemanticVersion("01.2.3") == SemanticVersion("1.2.3"))
    }

    @Test func leadingZerosDoNotMakeDistinctValuesEqual() {
        // Confirms the comparator is actually comparing numeric value (not,
        // say, comparing the zero-padded strings, or treating any leading
        // zero as "invalid" and silently degrading to some other equality).
        #expect(SemanticVersion("1.04") != SemanticVersion("1.5"))
        #expect((SemanticVersion("1.04")! < SemanticVersion("1.5")!))
    }

    // MARK: - Ordering

    @Test func strictlyNewerComparesGreater() {
        #expect(SemanticVersion("1.5.0")! > SemanticVersion("1.4.0")!)
        #expect(!(SemanticVersion("1.4.0")! > SemanticVersion("1.5.0")!))
    }

    @Test func strictlyOlderComparesLess() {
        #expect(SemanticVersion("1.4.0")! < SemanticVersion("1.5.0")!)
        #expect(!(SemanticVersion("1.5.0")! < SemanticVersion("1.4.0")!))
    }

    @Test func equalVersionsCompareEqualNotLessNotGreater() {
        let a = SemanticVersion("2.3.1")!
        let b = SemanticVersion("2.3.1")!
        #expect(a == b)
        #expect(!(a < b))
        #expect(!(a > b))
    }

    @Test func fourComponentVersionsCompareCorrectly() {
        #expect(SemanticVersion("1.2.3.5")! > SemanticVersion("1.2.3.4")!)
        #expect(SemanticVersion("1.2.3.4")! < SemanticVersion("1.2.4.0")!)
        #expect(SemanticVersion("1.2.3.4") == SemanticVersion("1.2.3.4"))
    }

    // MARK: - UpdateManifest.isNewer(than:)

    private func manifest(_ version: String) -> UpdateManifest {
        UpdateManifest(
            latestVersion: version,
            notes: "https://example.com/notes",
            dmgURL: "https://example.com/App.dmg",
            dmgSHA256: "deadbeef"
        )
    }

    @Test func isNewerTrueWhenManifestVersionIsStrictlyNewer() {
        #expect(manifest("1.10.0").isNewer(than: "1.9.0"))
    }

    @Test func isNewerFalseWhenVersionsAreEqual() {
        #expect(!manifest("1.9.0").isNewer(than: "1.9.0"))
    }

    @Test func isNewerFalseWhenManifestVersionIsEqualViaTrailingZeroPadding() {
        #expect(!manifest("1.4").isNewer(than: "1.4.0"))
        #expect(!manifest("1.4.0").isNewer(than: "1.4"))
    }

    @Test func isNewerFalseWhenManifestVersionIsOlder() {
        #expect(!manifest("1.8.0").isNewer(than: "1.9.0"))
    }

    @Test func isNewerFalseWhenManifestVersionIsUnparseable() {
        // FAIL CLOSED: garbage manifest version must never look "newer".
        #expect(!manifest("").isNewer(than: "1.0.0"))
        #expect(!manifest("not-a-version").isNewer(than: "1.0.0"))
        #expect(!manifest("1.2.3.4.5").isNewer(than: "1.0.0"))
    }

    @Test func isNewerFalseWhenCurrentVersionIsUnparseable() {
        // FAIL CLOSED: even a legitimately newer-looking manifest version
        // must not trigger an update if we can't parse our OWN version.
        #expect(!manifest("99.0.0").isNewer(than: ""))
        #expect(!manifest("99.0.0").isNewer(than: "not-a-version"))
        #expect(!manifest("99.0.0").isNewer(than: "1.2.3.4.5"))
    }

    @Test func isNewerFalseWhenBothVersionsAreUnparseable() {
        #expect(!manifest("garbage").isNewer(than: "also-garbage"))
    }

    // MARK: - UpdateManifest JSON decoding

    @Test func decodesValidManifestJSON() throws {
        let json = """
        {
            "latestVersion": "1.10.0",
            "notes": "https://github.com/OWNER/REPO/releases/tag/v1.10.0",
            "dmgURL": "https://github.com/OWNER/REPO/releases/download/v1.10.0/App-1.10.0.dmg",
            "dmgSHA256": "abc123"
        }
        """
        let decoded = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(decoded.latestVersion == "1.10.0")
        #expect(decoded.notes == "https://github.com/OWNER/REPO/releases/tag/v1.10.0")
        #expect(decoded.dmgURL == "https://github.com/OWNER/REPO/releases/download/v1.10.0/App-1.10.0.dmg")
        #expect(decoded.dmgSHA256 == "abc123")
    }

    @Test func decodingFailsWhenRequiredFieldIsMissing() {
        let json = """
        {
            "notes": "https://example.com/notes",
            "dmgURL": "https://example.com/App.dmg",
            "dmgSHA256": "abc123"
        }
        """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        }
    }

    /// Decision: extra/unknown JSON fields are TOLERATED (ignored), not
    /// treated as a decode failure. `Codable`'s synthesized `init(from:)`
    /// already only looks up the keys it knows about via `CodingKeys`, so
    /// this falls out for free — but we assert it explicitly so a future
    /// switch to a strict/unknown-key-rejecting decode strategy is caught.
    @Test func decodingToleratesUnknownExtraFields() throws {
        let json = """
        {
            "latestVersion": "1.10.0",
            "notes": "https://example.com/notes",
            "dmgURL": "https://example.com/App.dmg",
            "dmgSHA256": "abc123",
            "someFutureField": "unexpected",
            "minimumOSVersion": "14.0"
        }
        """
        let decoded = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(decoded.latestVersion == "1.10.0")
        #expect(decoded.dmgSHA256 == "abc123")
    }
}
