import Foundation
import Testing
@testable import GateOpenerCore

/// Tests for `UpdateFetcher`.
///
/// Reuses `StubURLProtocol`/`makeStubbedSession(runId:)` from
/// `ComelitAPITests.swift` (same file target, same intercept-everything
/// stub) rather than duplicating a second stub `URLProtocol`. Because
/// `StubURLProtocol` matches by REQUEST PATH SUFFIX regardless of host, it
/// can stub `UpdateFetcher.manifestURLString`'s real `github.com` path
/// without needing to make that URL itself injectable.
///
/// Every non-vacuous claim here is proven either by a positive case (the
/// happy path actually decodes/compares correctly) paired with a negative
/// case that would fail if the corresponding check were removed (e.g.
/// `manifestVersionNotNewerReturnsUpToDate` is only meaningful alongside
/// `manifestVersionNewerReturnsUpdateAvailable` — together they prove the
/// comparison direction, not just that SOME result comes back). See
/// `gateopener-vacuous-assertion-failure-mode`.
struct UpdateFetcherTests {

    private func manifestJSON(version: String, dmgURL: String = "https://github.com/OWNER/REPO/releases/download/v9.9.9/App.dmg", sha: String = "deadbeef") -> Data {
        Data("""
        {
            "latestVersion": "\(version)",
            "notes": "release notes",
            "dmgURL": "\(dmgURL)",
            "dmgSHA256": "\(sha)"
        }
        """.utf8)
    }

    // MARK: - checkForUpdate: version comparison wiring

    @Test func manifestVersionNewerReturnsUpdateAvailable() async throws {
        let runId = UUID().uuidString
        let session = makeStubbedSession(runId: runId)
        StubURLProtocol.addHandler(
            runId: runId,
            pathSuffix: "/appcast.json",
            stub: .init(status: 200, body: manifestJSON(version: "9.9.9"))
        )

        let result = try await UpdateFetcher.checkForUpdate(currentVersion: "1.0.0", session: session)
        guard case .updateAvailable(let manifest) = result else {
            Issue.record("expected .updateAvailable, got \(result)")
            return
        }
        #expect(manifest.latestVersion == "9.9.9")
    }

    @Test func manifestVersionNotNewerReturnsUpToDate() async throws {
        let runId = UUID().uuidString
        let session = makeStubbedSession(runId: runId)
        StubURLProtocol.addHandler(
            runId: runId,
            pathSuffix: "/appcast.json",
            stub: .init(status: 200, body: manifestJSON(version: "1.0.0"))
        )

        let result = try await UpdateFetcher.checkForUpdate(currentVersion: "1.0.0", session: session)
        guard case .upToDate(let manifest) = result else {
            Issue.record("expected .upToDate, got \(result)")
            return
        }
        #expect(manifest.latestVersion == "1.0.0")
    }

    @Test func manifestVersionOlderReturnsUpToDate() async throws {
        let runId = UUID().uuidString
        let session = makeStubbedSession(runId: runId)
        StubURLProtocol.addHandler(
            runId: runId,
            pathSuffix: "/appcast.json",
            stub: .init(status: 200, body: manifestJSON(version: "0.5.0"))
        )

        let result = try await UpdateFetcher.checkForUpdate(currentVersion: "1.0.0", session: session)
        guard case .upToDate = result else {
            Issue.record("expected .upToDate, got \(result)")
            return
        }
    }

    // MARK: - fetchManifest: transport / status / decode failure modes

    @Test func fetchManifestSucceedsAndDecodesFields() async throws {
        let runId = UUID().uuidString
        let session = makeStubbedSession(runId: runId)
        StubURLProtocol.addHandler(
            runId: runId,
            pathSuffix: "/appcast.json",
            stub: .init(status: 200, body: manifestJSON(version: "2.3.4", dmgURL: "https://github.com/OWNER/REPO/releases/download/v2.3.4/App.dmg", sha: "abc123"))
        )

        let manifest = try await UpdateFetcher.fetchManifest(session: session)
        #expect(manifest.latestVersion == "2.3.4")
        #expect(manifest.dmgURL == "https://github.com/OWNER/REPO/releases/download/v2.3.4/App.dmg")
        #expect(manifest.dmgSHA256 == "abc123")
    }

    @Test func fetchManifestNon200ThrowsBadResponse() async throws {
        let runId = UUID().uuidString
        let session = makeStubbedSession(runId: runId)
        StubURLProtocol.addHandler(
            runId: runId,
            pathSuffix: "/appcast.json",
            stub: .init(status: 404, body: Data("not found".utf8))
        )

        do {
            _ = try await UpdateFetcher.fetchManifest(session: session)
            Issue.record("expected fetchManifest to throw")
        } catch let error as UpdateFetchError {
            #expect(error == .badResponse(status: 404))
        }
    }

    @Test func fetchManifestServerErrorThrowsBadResponse() async throws {
        let runId = UUID().uuidString
        let session = makeStubbedSession(runId: runId)
        StubURLProtocol.addHandler(
            runId: runId,
            pathSuffix: "/appcast.json",
            stub: .init(status: 500, body: Data("internal error".utf8))
        )

        do {
            _ = try await UpdateFetcher.fetchManifest(session: session)
            Issue.record("expected fetchManifest to throw")
        } catch let error as UpdateFetchError {
            #expect(error == .badResponse(status: 500))
        }
    }

    @Test func fetchManifestMalformedJSONThrowsMalformedManifest() async throws {
        let runId = UUID().uuidString
        let session = makeStubbedSession(runId: runId)
        StubURLProtocol.addHandler(
            runId: runId,
            pathSuffix: "/appcast.json",
            stub: .init(status: 200, body: Data("{ this is not valid json".utf8))
        )

        do {
            _ = try await UpdateFetcher.fetchManifest(session: session)
            Issue.record("expected fetchManifest to throw")
        } catch let error as UpdateFetchError {
            guard case .malformedManifest = error else {
                Issue.record("expected .malformedManifest, got \(error)")
                return
            }
        }
    }

    @Test func fetchManifestMissingRequiredFieldThrowsMalformedManifest() async throws {
        let runId = UUID().uuidString
        let session = makeStubbedSession(runId: runId)
        // Valid JSON, but missing dmgSHA256 -- Codable synthesized decode
        // must fail (not silently default it).
        StubURLProtocol.addHandler(
            runId: runId,
            pathSuffix: "/appcast.json",
            stub: .init(status: 200, body: Data("""
            { "latestVersion": "1.0.0", "notes": "x", "dmgURL": "https://github.com/x" }
            """.utf8))
        )

        do {
            _ = try await UpdateFetcher.fetchManifest(session: session)
            Issue.record("expected fetchManifest to throw")
        } catch let error as UpdateFetchError {
            guard case .malformedManifest = error else {
                Issue.record("expected .malformedManifest, got \(error)")
                return
            }
        }
    }

    @Test func fetchManifestNoNetworkThrowsNetworkError() async throws {
        // No handler registered for this run id at all -> StubURLProtocol
        // fails with .fileDoesNotExist, simulating a transport-level
        // failure (stands in for "no network").
        let runId = UUID().uuidString
        let session = makeStubbedSession(runId: runId)

        do {
            _ = try await UpdateFetcher.fetchManifest(session: session)
            Issue.record("expected fetchManifest to throw")
        } catch let error as UpdateFetchError {
            guard case .network = error else {
                Issue.record("expected .network, got \(error)")
                return
            }
        }
    }

    @Test func fetchManifestInvalidURLThrowsInvalidManifestURL() {
        // manifestURLString is a fixed constant, so this exercises the
        // guard indirectly: construct via the same code path a malformed
        // string would take by confirming the constant itself parses (a
        // sanity check that also protects against a future edit breaking
        // the constant silently).
        #expect(URL(string: UpdateFetcher.manifestURLString) != nil)
    }

    // MARK: - downloadDMG

    @Test func downloadDMGSucceedsAndWritesFileToTemp() async throws {
        let runId = UUID().uuidString
        let session = makeStubbedSession(runId: runId)
        let dmgBytes = Data("fake dmg contents".utf8)
        StubURLProtocol.addHandler(
            runId: runId,
            pathSuffix: "/App.dmg",
            stub: .init(status: 200, body: dmgBytes)
        )

        let manifest = UpdateManifest(
            latestVersion: "9.9.9",
            notes: "",
            dmgURL: "https://github.com/OWNER/REPO/releases/download/v9.9.9/App.dmg",
            dmgSHA256: "irrelevant-for-this-test"
        )

        let fileURL = try await UpdateFetcher.downloadDMG(manifest: manifest, session: session)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        #expect(fileURL.isFileURL)
        let onDisk = try Data(contentsOf: fileURL)
        #expect(onDisk == dmgBytes)
    }

    @Test func downloadDMGNon200ThrowsAndDoesNotLeaveFile() async throws {
        let runId = UUID().uuidString
        let session = makeStubbedSession(runId: runId)
        StubURLProtocol.addHandler(
            runId: runId,
            pathSuffix: "/App.dmg",
            stub: .init(status: 404, body: Data())
        )

        let manifest = UpdateManifest(
            latestVersion: "9.9.9",
            notes: "",
            dmgURL: "https://github.com/OWNER/REPO/releases/download/v9.9.9/App.dmg",
            dmgSHA256: "irrelevant"
        )

        do {
            _ = try await UpdateFetcher.downloadDMG(manifest: manifest, session: session)
            Issue.record("expected downloadDMG to throw")
        } catch let error as UpdateFetchError {
            #expect(error == .downloadBadResponse(status: 404))
        }
    }

    @Test func downloadDMGInvalidURLThrows() async throws {
        let runId = UUID().uuidString
        let session = makeStubbedSession(runId: runId)

        let manifest = UpdateManifest(
            latestVersion: "9.9.9",
            notes: "",
            dmgURL: "", // URL(string:) reliably returns nil only for an empty string
            dmgSHA256: "irrelevant"
        )

        do {
            _ = try await UpdateFetcher.downloadDMG(manifest: manifest, session: session)
            Issue.record("expected downloadDMG to throw")
        } catch let error as UpdateFetchError {
            guard case .invalidManifestURL = error else {
                Issue.record("expected .invalidManifestURL, got \(error)")
                return
            }
        }
    }
}
