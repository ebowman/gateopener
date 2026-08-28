import Foundation
import Testing
@testable import GateOpenerCore

/// The single authoritative version lives in the repo-root `VERSION` file
/// (see `Sources/GateOpenerCore/GateOpenerCore.swift`), not in a compiled
/// constant. This test guards that the file exists, is non-empty, and
/// parses as a `SemanticVersion` — the same fail-closed parser
/// `scripts/build-app.sh` and the updater agree on.
@Test func versionFileExistsAndParsesAsSemanticVersion() throws {
    // #file for this test is .../Tests/GateOpenerCoreTests/GateOpenerCoreTests.swift;
    // the repo root is three directories up.
    let thisFile = URL(fileURLWithPath: #filePath)
    let repoRoot = thisFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let versionFile = repoRoot.appendingPathComponent("VERSION")

    let contents = try String(contentsOf: versionFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    #expect(!contents.isEmpty)
    #expect(SemanticVersion(contents) != nil)
}
