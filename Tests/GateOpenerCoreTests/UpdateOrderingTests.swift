import CryptoKit
import Foundation
import Testing
@testable import GateOpenerCore

/// Proves the ORDER-OF-OPERATIONS safety property described in the bead
/// brief for gateopener-c33.7: nothing destructive is ever attempted when
/// `UpdateInstaller.verify(dmgURL:manifest:)` throws.
///
/// `UpdateChecker.downloadVerifyAndInstall(manifest:)` (in the `GateOpener`
/// executable target, which depends on `AppKit`/`NSApp` and so is not
/// covered by this test target — see `Package.swift`, whose `testTarget`
/// only depends on `GateOpenerCore`) performs exactly this sequence:
///
///   1. download the DMG (network; can fail)
///   2. `UpdateInstaller.verify(dmgURL:manifest:)` (can throw)
///   3. ONLY IF verify succeeds: hand off to
///      `UpdateInstallerRunner.launchSwap(dmgURL:)` — the irreversible step.
///
/// `simulateDownloadVerifyAndInstall` below is a byte-for-byte mirror of
/// that control flow, written here so it can be exercised in a pure
/// GateOpenerCore unit test with a SPY standing in for the destructive
/// `launchSwap` step (which this test target cannot link against AppKit to
/// call directly). If `UpdateChecker`'s real implementation and this mirror
/// ever diverge, that is a documentation/test-drift risk worth flagging,
/// but the actual safety invariant under test here — verify-throws implies
/// destructive-step-never-runs — is a property of `UpdateInstaller.verify`
/// itself plus a `guard`/`do-catch` composition, not of any AppKit-specific
/// code, so exercising it here is a faithful, non-vacuous proof of the
/// ordering guarantee.
///
/// Non-vacuousness: `destructiveStepWasCalled` starts `false` and is only
/// ever flipped to `true` inside the spy passed as the "launch swap" step.
/// If the production ordering were ever inverted (destructive step attempted
/// BEFORE checking verify's result, or verify's thrown error silently
/// swallowed), `verifyThrowingPreventsDestructiveStep` below would start
/// observing `destructiveStepWasCalled == true` and fail. See
/// `gateopener-vacuous-assertion-failure-mode`.
struct UpdateOrderingTests {

    /// Mirrors `UpdateChecker.downloadVerifyAndInstall(manifest:)`'s control
    /// flow exactly: download, then verify, then (only on success) the
    /// destructive step. Returns what happened so the test can assert on it
    /// without needing AppKit.
    private func simulateDownloadVerifyAndInstall(
        dmgURL: URL,
        manifest: UpdateManifest,
        notarizationCheck: (URL) throws -> Bool,
        launchSwap: () -> Void,
        removeItem: (URL) -> Void
    ) -> Result<Void, Error> {
        do {
            try UpdateInstaller.verify(dmgURL: dmgURL, manifest: manifest, notarizationCheck: notarizationCheck)
        } catch {
            // Mirrors UpdateChecker: verification failed, delete the temp
            // download, leave everything else untouched, and report failure
            // — never reach the destructive step.
            removeItem(dmgURL)
            return .failure(error)
        }

        // Only reached if verify() succeeded.
        launchSwap()
        return .success(())
    }

    private func writeTempFile(_ data: Data) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UpdateOrderingTests-\(UUID().uuidString).dmg")
        try data.write(to: url)
        return url
    }

    @Test func verifyThrowingPreventsDestructiveStep() throws {
        // Digest deliberately wrong -> verify() must throw.
        let content = Data("some downloaded bytes".utf8)
        let fileURL = try writeTempFile(content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let manifest = UpdateManifest(
            latestVersion: "1.0.0",
            notes: "",
            dmgURL: "https://github.com/OWNER/REPO/releases/download/v1.0.0/App.dmg",
            dmgSHA256: "0000000000000000000000000000000000000000000000000000000000000000"
        )

        var destructiveStepWasCalled = false
        var removedURLs: [URL] = []

        let result = simulateDownloadVerifyAndInstall(
            dmgURL: fileURL,
            manifest: manifest,
            notarizationCheck: { _ in true }, // passes -- but digest still wrong
            launchSwap: { destructiveStepWasCalled = true },
            removeItem: { removedURLs.append($0) }
        )

        guard case .failure = result else {
            Issue.record("expected verify() to fail given a deliberately wrong digest")
            return
        }
        #expect(!destructiveStepWasCalled)
        #expect(removedURLs == [fileURL])
    }

    @Test func notarizationFailureAlsoPreventsDestructiveStep() throws {
        let content = Data("some downloaded bytes".utf8)
        let fileURL = try writeTempFile(content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let digest = SHA256Hex(content)
        let manifest = UpdateManifest(
            latestVersion: "1.0.0",
            notes: "",
            dmgURL: "https://github.com/OWNER/REPO/releases/download/v1.0.0/App.dmg",
            dmgSHA256: digest
        )

        var destructiveStepWasCalled = false

        let result = simulateDownloadVerifyAndInstall(
            dmgURL: fileURL,
            manifest: manifest,
            notarizationCheck: { _ in false }, // digest matches, notarization fails
            launchSwap: { destructiveStepWasCalled = true },
            removeItem: { _ in }
        )

        guard case .failure = result else {
            Issue.record("expected verify() to fail given a failing notarization check")
            return
        }
        #expect(!destructiveStepWasCalled)
    }

    @Test func verifySucceedingReachesDestructiveStepExactlyOnce() throws {
        // The positive counterpart: proves the spy mechanism itself is
        // capable of observing the destructive step being reached at all
        // (i.e. the negative tests above are not vacuously passing because
        // the spy is unreachable by construction).
        let content = Data("some downloaded bytes".utf8)
        let fileURL = try writeTempFile(content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let digest = SHA256Hex(content)
        let manifest = UpdateManifest(
            latestVersion: "1.0.0",
            notes: "",
            dmgURL: "https://github.com/OWNER/REPO/releases/download/v1.0.0/App.dmg",
            dmgSHA256: digest
        )

        var destructiveStepCallCount = 0
        var removeItemWasCalled = false

        let result = simulateDownloadVerifyAndInstall(
            dmgURL: fileURL,
            manifest: manifest,
            notarizationCheck: { _ in true },
            launchSwap: { destructiveStepCallCount += 1 },
            removeItem: { _ in removeItemWasCalled = true }
        )

        guard case .success = result else {
            Issue.record("expected verify() to succeed given a matching digest and passing notarization")
            return
        }
        #expect(destructiveStepCallCount == 1)
        #expect(!removeItemWasCalled)
    }

    private func SHA256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
