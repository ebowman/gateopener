import CryptoKit
import Foundation
import Testing
@testable import GateOpenerCore

/// Tests for `UpdateInstaller.verify(dmgURL:manifest:notarizationCheck:)` —
/// the whole security story for GateOpener's self-update feature.
///
/// The two gates (digest match, notarization) are independent: this suite
/// deliberately covers all four combinations so neither gate can silently
/// become optional. It also validates the manifest URL scheme/host pinning,
/// which runs before any I/O. Every assertion here is non-vacuous by
/// construction — see `gateopener-vacuous-assertion-failure-mode` — and each
/// was confirmed to fail when its corresponding source check is removed (see
/// the implementer's report for the specific mutations tried).
struct UpdateInstallerTests {

    // MARK: - Fixtures

    /// Writes `data` to a fresh temporary file and returns its `file://`
    /// URL. Caller is responsible for no cleanup — `NSTemporaryDirectory`
    /// entries are ephemeral and harmless to leave behind in test runs.
    private func writeTempFile(_ data: Data) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString).dmg")
        try data.write(to: url)
        return url
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func manifest(dmgURL: String = "https://github.com/OWNER/REPO/releases/download/v1.0.0/App.dmg", sha256: String) -> UpdateManifest {
        UpdateManifest(
            latestVersion: "1.0.0",
            notes: "https://github.com/OWNER/REPO/releases/tag/v1.0.0",
            dmgURL: dmgURL,
            dmgSHA256: sha256
        )
    }

    // MARK: - Digest correctness, including a >1 MiB file (chunk-boundary path)

    @Test func matchingDigestAndPassingNotarizationSucceeds() throws {
        let content = Data("small known content".utf8)
        let fileURL = try writeTempFile(content)
        let m = manifest(sha256: sha256Hex(content))

        // Must not throw.
        try UpdateInstaller.verify(dmgURL: fileURL, manifest: m) { _ in true }
    }

    @Test func matchingDigestOverMultipleChunksSucceeds() throws {
        // 1 MiB chunk size; use a file > 2.5 MiB so at least two full chunks
        // plus a partial final chunk are read, genuinely exercising the
        // streaming loop's boundary handling rather than a single read.
        var bytes = [UInt8]()
        bytes.reserveCapacity(2_684_354) // ~2.56 MiB, deliberately not a clean multiple of 1 MiB
        for i in 0..<2_684_354 {
            bytes.append(UInt8(truncatingIfNeeded: i))
        }
        let content = Data(bytes)
        #expect(content.count > (1 << 20) * 2) // sanity: genuinely multi-chunk

        let fileURL = try writeTempFile(content)
        let m = manifest(sha256: sha256Hex(content))

        try UpdateInstaller.verify(dmgURL: fileURL, manifest: m) { _ in true }
    }

    @Test func digestIsCaseInsensitiveMatch() throws {
        let content = Data("case insensitivity check".utf8)
        let fileURL = try writeTempFile(content)
        let m = manifest(sha256: sha256Hex(content).uppercased())

        try UpdateInstaller.verify(dmgURL: fileURL, manifest: m) { _ in true }
    }

    // MARK: - The two gates are independent; neither is sufficient alone

    @Test func digestMismatchThrowsEvenWhenNotarizationPasses() throws {
        let content = Data("real content".utf8)
        let fileURL = try writeTempFile(content)
        let wrongDigest = sha256Hex(Data("different content".utf8))
        let m = manifest(sha256: wrongDigest)

        #expect(throws: UpdateVerificationError.self) {
            try UpdateInstaller.verify(dmgURL: fileURL, manifest: m) { _ in true }
        }
    }

    @Test func notarizationFailureThrowsEvenWhenDigestMatches() throws {
        let content = Data("real content".utf8)
        let fileURL = try writeTempFile(content)
        let m = manifest(sha256: sha256Hex(content))

        #expect(throws: UpdateVerificationError.self) {
            try UpdateInstaller.verify(dmgURL: fileURL, manifest: m) { _ in false }
        }
    }

    @Test func bothDigestAndNotarizationFailingThrows() throws {
        let content = Data("real content".utf8)
        let fileURL = try writeTempFile(content)
        let m = manifest(sha256: sha256Hex(Data("wrong".utf8)))

        #expect(throws: UpdateVerificationError.self) {
            try UpdateInstaller.verify(dmgURL: fileURL, manifest: m) { _ in false }
        }
    }

    @Test func specificErrorIsDigestMismatchWhenOnlyDigestFails() throws {
        let content = Data("real content".utf8)
        let fileURL = try writeTempFile(content)
        let wrongDigest = sha256Hex(Data("different content".utf8))
        let m = manifest(sha256: wrongDigest)

        do {
            try UpdateInstaller.verify(dmgURL: fileURL, manifest: m) { _ in true }
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            guard case .digestMismatch = error else {
                Issue.record("expected .digestMismatch, got \(error)")
                return
            }
        }
    }

    @Test func specificErrorIsNotarizationFailedWhenOnlyNotarizationFails() throws {
        let content = Data("real content".utf8)
        let fileURL = try writeTempFile(content)
        let m = manifest(sha256: sha256Hex(content))

        do {
            try UpdateInstaller.verify(dmgURL: fileURL, manifest: m) { _ in false }
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .notarizationFailed)
        }
    }

    // MARK: - URL validation runs before any I/O

    @Test func nonHTTPSSchemeThrowsBeforeAnyIO() throws {
        let m = manifest(dmgURL: "http://github.com/OWNER/REPO/releases/download/v1.0.0/App.dmg", sha256: "irrelevant")

        var notarizationCheckWasCalled = false
        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m
            ) { _ in
                notarizationCheckWasCalled = true
                return true
            }
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            // Must be rejected specifically as insecure (wrong scheme), not
            // merely as "some error or other" (e.g. the unreadable-local-file
            // error, which would also be thrown here if URL validation were
            // skipped and the code fell through to I/O against a nonexistent
            // path — that would make this assertion pass for the wrong
            // reason). Pinning the exact case closes that gap.
            #expect(error == .insecureDMGURL(m.dmgURL))
        }
        // Confirms validation happens before I/O: a nonexistent local file
        // and a closure that would otherwise succeed are both never reached.
        #expect(!notarizationCheckWasCalled)
    }

    @Test func arbitrarySchemeThrows() throws {
        let m = manifest(dmgURL: "ftp://github.com/OWNER/REPO/releases/download/v1.0.0/App.dmg", sha256: "irrelevant")

        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m
            ) { _ in true }
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .insecureDMGURL(m.dmgURL))
        }
    }

    @Test func unparseableManifestURLThrows() throws {
        // A string with control characters / malformed percent-encoding
        // that Foundation's URL(string:) parser rejects outright.
        let badURLString = "not a valid url at all with spaces and no scheme"
        let m = manifest(dmgURL: badURLString, sha256: "irrelevant")

        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m
            ) { _ in true }
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .invalidDMGURL(badURLString))
        }
    }

    @Test func httpsButWrongHostThrows() throws {
        let m = manifest(dmgURL: "https://evil.example.com/App.dmg", sha256: "irrelevant")

        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m
            ) { _ in true }
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .insecureDMGURL(m.dmgURL))
        }
    }

    @Test func httpsAndPinnedHostPassesURLValidation() throws {
        // Confirms the host pin isn't accidentally rejecting the legitimate
        // host too: only the URL-validation step is under test here, so we
        // give it real matching content + a passing notarization stub and
        // expect success end-to-end.
        let content = Data("pinned host check".utf8)
        let fileURL = try writeTempFile(content)
        let m = manifest(
            dmgURL: "https://github.com/OWNER/REPO/releases/download/v1.0.0/App.dmg",
            sha256: sha256Hex(content)
        )

        try UpdateInstaller.verify(dmgURL: fileURL, manifest: m) { _ in true }
    }

    // MARK: - Real spctl closure (default parameter) does not crash on a bogus path

    @Test func defaultNotarizationCheckReturnsFalseForNonSignedFile() throws {
        let content = Data("not a real dmg".utf8)
        let fileURL = try writeTempFile(content)
        // Exercise the real (non-injected) spctl-backed default via the
        // public entry point, confirming it fails closed for a plain file
        // that is obviously not a signed, notarized disk image.
        let result = try UpdateInstaller.defaultNotarizationCheck(fileURL)
        #expect(result == false)
    }
}
