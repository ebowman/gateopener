import Foundation

/// Errors surfaced by `UpdateFetcher`.
///
/// None of these ever crash the app — every failure mode from "no network"
/// to "malformed JSON" to "manifest URL doesn't even parse" is represented
/// here so callers (the "Check for Updates…" UI) can show a clear, specific
/// message instead of the app dying or hanging.
public enum UpdateFetchError: Error, Equatable, Sendable {
    /// The manifest URL string itself failed to parse as a `URL`.
    case invalidManifestURL(String)

    /// The manifest request failed at the transport level (no network,
    /// DNS failure, timeout, etc). The associated string is
    /// `(error as NSError).localizedDescription` from the underlying
    /// `URLSession` error.
    case network(String)

    /// The manifest response was not HTTP or did not carry a 2xx status.
    case badResponse(status: Int)

    /// The manifest response body could not be decoded as `UpdateManifest`
    /// JSON. The associated string is a human-readable description of the
    /// decoding failure.
    case malformedManifest(String)

    /// The DMG download failed at the transport level.
    case downloadFailed(String)

    /// The DMG download response was not HTTP or did not carry a 2xx
    /// status.
    case downloadBadResponse(status: Int)
}

/// The outcome of checking for an update.
public enum UpdateCheckResult: Equatable, Sendable {
    /// The fetched manifest's version is not newer than the running app's
    /// version (per `UpdateManifest.isNewer(than:)`, which fails closed on
    /// any unparseable version).
    case upToDate(manifest: UpdateManifest)

    /// The fetched manifest describes a strictly newer version.
    case updateAvailable(manifest: UpdateManifest)
}

/// Fetches the update manifest and, when a newer version is available,
/// downloads the DMG it describes.
///
/// This type performs ONLY networking and JSON decoding — it never installs
/// or verifies anything. `UpdateInstaller.verify(dmgURL:manifest:)` (a
/// separate, already-existing security boundary — see that type's doc
/// comment) MUST be called on whatever this type downloads before the DMG
/// is used for anything destructive. This type does not call `verify` itself
/// so that boundary is never duplicated or drifted from here.
public enum UpdateFetcher {

    /// The base URL this app fetches its update manifest and DMGs from.
    ///
    /// *** THIS IS A PLACEHOLDER. THERE IS NO REMOTE REPOSITORY YET. ***
    ///
    /// `scripts/publish-release.sh` derives the real `OWNER/REPO` from
    /// `git remote get-url origin` at release time and publishes
    /// `appcast.json` to
    /// `https://github.com/OWNER/REPO/releases/latest/download/appcast.json`
    /// (see that script's header comment on why the manifest filename is
    /// stable across releases while the DMG filename is versioned). Once a
    /// real GitHub repository exists for this project, replace the
    /// `OWNER/REPO` placeholder below with the actual owner/repo pair — this
    /// is the ONLY place in the app that needs to change; nothing else
    /// hardcodes a repository identity.
    ///
    /// `UpdateInstaller.pinnedDMGHost` independently pins the DMG download
    /// host to `github.com` regardless of this constant, so a malicious
    /// manifest still cannot smuggle a DMG from anywhere else even if this
    /// value were ever wrong — see that type's doc comment.
    public static let manifestURLString = "https://github.com/OWNER/REPO/releases/latest/download/appcast.json"

    /// Fetches the manifest and compares it against `currentVersion`
    /// (expected to be `Bundle.main.CFBundleShortVersionString` or
    /// equivalent — this type never reads `Bundle` itself, mirroring
    /// `UpdateManifest.isNewer(than:)`'s own contract).
    ///
    /// - Parameters:
    ///   - currentVersion: the running app's version string.
    ///   - session: injected for testability (mirrors `ComelitAPI`'s own
    ///     `URLSession` injection pattern); defaults to `.shared`.
    /// - Returns: `.upToDate` or `.updateAvailable`, wrapping the fetched
    ///   manifest either way, so callers can still show its `notes`/
    ///   `latestVersion` even when there is nothing to install.
    /// - Throws: `UpdateFetchError` for every failure mode — malformed
    ///   manifest URL, no network, non-2xx response, or undecodable JSON.
    ///   Never crashes.
    public static func checkForUpdate(
        currentVersion: String,
        session: URLSession = .shared
    ) async throws -> UpdateCheckResult {
        let manifest = try await fetchManifest(session: session)
        if manifest.isNewer(than: currentVersion) {
            return .updateAvailable(manifest: manifest)
        }
        return .upToDate(manifest: manifest)
    }

    /// Fetches and decodes the manifest at `manifestURLString`.
    ///
    /// Separated from `checkForUpdate` so tests can exercise fetch/decode
    /// failures directly without needing a real `currentVersion` comparison
    /// to also succeed.
    public static func fetchManifest(session: URLSession = .shared) async throws -> UpdateManifest {
        guard let url = URL(string: manifestURLString) else {
            throw UpdateFetchError.invalidManifestURL(manifestURLString)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw UpdateFetchError.network((error as NSError).localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateFetchError.badResponse(status: -1)
        }
        guard (200...299).contains(http.statusCode) else {
            throw UpdateFetchError.badResponse(status: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            throw UpdateFetchError.malformedManifest(String(describing: error))
        }
    }

    /// Downloads `manifest.dmgURL` to a fresh, unique location under
    /// `NSTemporaryDirectory()` and returns its `file://` URL.
    ///
    /// This performs NO verification of the downloaded bytes — the caller
    /// MUST pass the returned URL to `UpdateInstaller.verify(dmgURL:
    /// manifest:)` before doing anything else with it. This function
    /// deliberately does not itself validate `manifest.dmgURL`'s scheme/
    /// host either; `UpdateInstaller.verify` already does that validation
    /// BEFORE any I/O in its own implementation (see
    /// `UpdateInstaller.validateManifestDMGURL`), and duplicating it here
    /// would risk the two checks drifting apart. This function will
    /// therefore itself throw `UpdateFetchError.invalidManifestURL` if
    /// `manifest.dmgURL` fails to even parse as a `URL` (necessary just to
    /// perform the download), but does not attempt to duplicate the
    /// scheme/host pinning that `verify` owns.
    ///
    /// - Returns: a `file://` URL to the downloaded (NOT YET VERIFIED) DMG.
    /// - Throws: `UpdateFetchError` on any transport or HTTP-status failure.
    public static func downloadDMG(
        manifest: UpdateManifest,
        session: URLSession = .shared
    ) async throws -> URL {
        guard let remoteURL = URL(string: manifest.dmgURL) else {
            throw UpdateFetchError.invalidManifestURL(manifest.dmgURL)
        }

        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GateOpenerUpdate-\(UUID().uuidString).dmg")

        let tempDownloadURL: URL
        let response: URLResponse
        do {
            (tempDownloadURL, response) = try await session.download(from: remoteURL)
        } catch {
            throw UpdateFetchError.downloadFailed((error as NSError).localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempDownloadURL)
            throw UpdateFetchError.downloadBadResponse(status: -1)
        }
        guard (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempDownloadURL)
            throw UpdateFetchError.downloadBadResponse(status: http.statusCode)
        }

        do {
            try FileManager.default.moveItem(at: tempDownloadURL, to: destination)
        } catch {
            throw UpdateFetchError.downloadFailed((error as NSError).localizedDescription)
        }

        return destination
    }
}
