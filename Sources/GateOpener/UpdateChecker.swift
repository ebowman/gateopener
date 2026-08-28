import AppKit
import Foundation
import GateOpenerCore
import os

/// Drives the "Check for Updates…" menu item: fetch the manifest, compare
/// versions, verify a candidate DMG, and (only on explicit user
/// confirmation) hand off to `UpdateInstallerRunner` for the irreversible
/// swap.
///
/// Deliberately plain: an `NSAlert` per state (checking is implicit/none,
/// up-to-date, update-available-with-confirm, error) and nothing else. No
/// custom UTI, no `CFBundleDocumentTypes`, no `NSOpenPanel`, no "it's been N
/// days" nag — all dropped per the bead brief. This app's repository is
/// public, so there is no reason for anything more elaborate than
/// URLSession-GET-the-manifest-and-DMG.
///
/// This type activates the app (`NSApp.activate`) when showing its alerts,
/// same as `StatusItemController.menuShowAbout()` already does for the
/// About panel. That is safe: "Check for Updates…" is only ever reached via
/// a deliberate user click on the status-item menu, never triggered
/// automatically or from a background timer — so it never competes with or
/// disturbs `OverlayWindowController`'s `orderFrontRegardless`-only, never-
/// activates guarantee for the gate-open confirmation / door-video panels.
@MainActor
enum UpdateChecker {
    private static let logger = Logger(subsystem: "com.gateopener", category: "update-checker")

    /// Entry point for the "Check for Updates…" menu item.
    static func checkForUpdates() {
        Task {
            await run()
        }
    }

    private static func run() async {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

        let result: UpdateCheckResult
        do {
            result = try await UpdateFetcher.checkForUpdate(currentVersion: currentVersion)
        } catch {
            presentError(message: describeFetchError(error))
            return
        }

        switch result {
        case .upToDate:
            presentUpToDate()
        case .updateAvailable(let manifest):
            let shouldInstall = presentUpdateAvailable(manifest: manifest, currentVersion: currentVersion)
            guard shouldInstall else { return }
            await downloadVerifyAndInstall(manifest: manifest)
        }
    }

    /// Downloads the DMG, verifies it (the security boundary — see
    /// `UpdateInstaller.verify`), and only on success hands off to
    /// `UpdateInstallerRunner.launchSwap(dmgURL:)`.
    ///
    /// ORDER OF OPERATIONS IS THE SAFETY PROPERTY (see bead brief): download
    /// failures and verification failures both throw/return BEFORE anything
    /// destructive is attempted, and in both cases the app is left
    /// completely untouched. A failed verification also deletes the
    /// downloaded temp file, so a bad artifact never lingers on disk under
    /// the pretense of being a legitimate update.
    private static func downloadVerifyAndInstall(manifest: UpdateManifest) async {
        let dmgURL: URL
        do {
            dmgURL = try await UpdateFetcher.downloadDMG(manifest: manifest)
        } catch {
            presentError(message: "Could not download the update: \(describeFetchError(error))")
            return
        }

        do {
            try UpdateInstaller.verify(dmgURL: dmgURL, manifest: manifest)
        } catch {
            // Verification failed: delete the temp download and leave the
            // app completely untouched. Nothing destructive may run on an
            // unverified artifact.
            try? FileManager.default.removeItem(at: dmgURL)
            logger.error("update verification failed: \(String(describing: error), privacy: .public)")
            presentError(message: "The downloaded update could not be verified and was discarded. GateOpener has not been changed.")
            return
        }

        do {
            try UpdateInstallerRunner.launchSwap(dmgURL: dmgURL)
            // launchSwap calls NSApp.terminate(nil) on success; execution
            // does not meaningfully continue past this point.
        } catch {
            logger.error("update swap launch failed: \(String(describing: error), privacy: .public)")
            presentError(message: "Could not start the update installer. GateOpener has not been changed.")
        }
    }

    // MARK: - Alerts

    private static func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "GateOpener \(currentVersionString()) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Shows the "a newer version is available" confirmation alert.
    /// Returns `true` if the user chose to install, `false` if they
    /// cancelled.
    private static func presentUpdateAvailable(manifest: UpdateManifest, currentVersion: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "GateOpener \(manifest.latestVersion) is available"
        var info = "You have \(currentVersion)."
        if !manifest.notes.isEmpty {
            info += "\n\n\(manifest.notes)"
        }
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }

    private static func presentError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't Check for Updates"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func currentVersionString() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private static func describeFetchError(_ error: Error) -> String {
        guard let fetchError = error as? UpdateFetchError else {
            return error.localizedDescription
        }
        switch fetchError {
        case .invalidManifestURL:
            return "The update manifest URL is invalid."
        case .network(let message):
            return "Network error: \(message)"
        case .badResponse(let status):
            return "Update server returned an unexpected response (status \(status))."
        case .malformedManifest:
            return "The update manifest could not be read."
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .downloadBadResponse(let status):
            return "Update server returned an unexpected response while downloading (status \(status))."
        }
    }
}
