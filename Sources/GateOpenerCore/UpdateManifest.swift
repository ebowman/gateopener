import Foundation

/// A tolerant-but-fail-closed semantic version comparator.
///
/// Accepts 1 to 4 dot-separated non-negative integer components
/// (`major[.minor[.patch[.build]]]`). Missing trailing components are
/// treated as `0`, so `"1.4"`, `"1.4.0"`, and `"1.4.0.0"` all compare equal.
///
/// Parsing is deliberately strict about anything else: empty strings,
/// whitespace, non-numeric components, negative numbers, and 5+ components
/// all fail to parse (`init?` returns `nil`). This is a security-relevant
/// property, not incidental behavior — see `UpdateManifest.isNewer(than:)`,
/// which treats an unparseable version on EITHER side as "no update
/// available" rather than guessing.
///
/// Leading zeros (e.g. `"1.04"`) are ACCEPTED and parsed as decimal integers
/// (`"04"` -> `4`), so `"1.04" == "1.4"`. Swift's `Int(String)` already
/// treats leading zeros as ordinary decimal digits, and there is no
/// ambiguity or security concern in doing the same here (unlike, say,
/// treating a leading zero as an octal prefix), so no special-casing is
/// applied.
public struct SemanticVersion: Equatable, Comparable, Sendable {
    /// Always exactly 4 components; missing trailing components are `0`.
    public let components: [Int]

    /// Parses `string` as a semantic version.
    ///
    /// Returns `nil` unless `string` is 1 to 4 dot-separated components,
    /// each of which is a non-negative base-10 integer with no surrounding
    /// or embedded whitespace. There is no upper bound check on `string`'s
    /// length beyond what naturally falls out of this parse: splitting on
    /// `.` and parsing each piece as an `Int` is O(n) and never recurses or
    /// backtracks, so pathologically long input fails fast rather than
    /// hanging.
    public init?(_ string: String) {
        guard !string.isEmpty else { return nil }

        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }

        var parsed: [Int] = []
        parsed.reserveCapacity(4)
        for part in parts {
            // Reject empty components ("1..0"), whitespace, signs, and
            // anything Int(_:) would otherwise accept that we don't want
            // (Int("+1") and Int("-1") both succeed, but a version
            // component must be a bare non-negative integer).
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            guard let value = Int(part), value >= 0 else { return nil }
            parsed.append(value)
        }
        while parsed.count < 4 {
            parsed.append(0)
        }
        self.components = parsed
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        for (l, r) in zip(lhs.components, rhs.components) where l != r {
            return l < r
        }
        return false
    }
}

/// The stable-named JSON manifest published alongside each release's DMG.
///
/// Fetching this manifest (networking) and verifying the DMG it describes
/// (streaming SHA-256, notarization check) are later beads. This type is
/// pure model + comparison logic only.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public let latestVersion: String
    public let notes: String
    public let dmgURL: String
    public let dmgSHA256: String

    public init(latestVersion: String, notes: String, dmgURL: String, dmgSHA256: String) {
        self.latestVersion = latestVersion
        self.notes = notes
        self.dmgURL = dmgURL
        self.dmgSHA256 = dmgSHA256
    }

    /// Whether `latestVersion` is strictly newer than `currentVersion`.
    ///
    /// FAILS CLOSED: if either `latestVersion` or `currentVersion` fails to
    /// parse as a `SemanticVersion`, this returns `false`. A malformed
    /// manifest (or a malformed/unexpected running-app version string) must
    /// never be treated as "newer" — never prompt to upgrade to a version
    /// you cannot meaningfully order against the one you have.
    ///
    /// The caller is expected to pass `Bundle.main.CFBundleShortVersionString`
    /// (or equivalent) as `currentVersion`; `GateOpenerCore` does not read
    /// `Bundle` itself.
    public func isNewer(than currentVersion: String) -> Bool {
        guard let latest = SemanticVersion(latestVersion),
              let current = SemanticVersion(currentVersion) else {
            return false
        }
        return latest > current
    }
}
