import AppKit
import Foundation
import GateOpenerCore
import os

/// Errors from `UpdateInstallerRunner.launchSwap(dmgURL:)`.
///
/// Every case here is thrown BEFORE anything irreversible happens — the
/// installed bundle is only ever touched by the detached script AFTER this
/// function has already returned successfully and `NSApp.terminate(nil)`
/// has been called. See `UpdateInstallerRunner`'s doc comment for the full
/// ordering guarantee.
public enum UpdateSwapError: Error, Sendable {
    /// Writing the generated script to `NSTemporaryDirectory()` failed.
    case scriptWriteFailed(String)

    /// Marking the script executable (mode 0755) failed.
    case scriptPermissionsFailed(String)

    /// Launching the detached `/bin/sh -c` process failed.
    case launchFailed(String)
}

/// Performs the self-replacing update swap: writes a detached `/bin/sh`
/// script, launches it, and terminates this app so the script can safely
/// replace the running bundle.
///
/// ## Order of operations is the safety property
///
/// `UpdateInstallerRunner.launchSwap(dmgURL:)` is called ONLY after
/// `UpdateInstaller.verify(dmgURL:manifest:)` has already succeeded (see
/// `UpdateChecker`, the caller) — that is this whole feature's security
/// boundary, and it is not re-checked or re-validated here. Within THIS
/// function, everything that can fail (writing the script, chmod'ing it,
/// launching it) is attempted BEFORE `NSApp.terminate(nil)` is called, and
/// every failure throws rather than proceeding. The running app is
/// UNTOUCHED if this function throws for any reason. Once
/// `NSApp.terminate(nil)` runs, control has left this process for good —
/// there is no later point at which a failure here could still be reported
/// to the user, which is exactly why every prior step fails loudly and
/// nothing is skipped or reordered "as an optimisation". Once the detached
/// script's own `rm -rf` runs, the only recovery is
/// `/tmp/gateopener-update.log` (the script's own stdout/stderr, redirected
/// there by the `nohup` launch below) — this function's entire job is to
/// make sure that irreversible step is only ever reached with a verified
/// DMG and a successfully-launched script.
@MainActor
public enum UpdateInstallerRunner {
    private static let logger = Logger(subsystem: "com.gateopener", category: "update-installer")

    static let updateLogPath = "/tmp/gateopener-update.log"

    /// Writes the swap script, launches it detached, and terminates this
    /// app.
    ///
    /// - Parameter dmgURL: a `file://` URL to a DMG that has ALREADY passed
    ///   `UpdateInstaller.verify(dmgURL:manifest:)`. This function does not
    ///   re-verify it — callers must not call this with an unverified DMG.
    /// - Throws: `UpdateSwapError` if the script could not be written, made
    ///   executable, or launched. The app is left completely untouched in
    ///   every throwing case — `NSApp.terminate(nil)` is only reached after
    ///   the launch itself has succeeded.
    public static func launchSwap(dmgURL: URL) throws {
        let bundleURL = Bundle.main.bundleURL
        let installDir = bundleURL.deletingLastPathComponent().path
        let bundleName = bundleURL.lastPathComponent

        let scriptText = UpdateSwapScript.generate(
            dmgPath: dmgURL.path,
            parentPID: ProcessInfo.processInfo.processIdentifier,
            installDir: installDir,
            bundleName: bundleName
        )

        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gateopener-update-\(UUID().uuidString).sh")

        do {
            try scriptText.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            throw UpdateSwapError.scriptWriteFailed(error.localizedDescription)
        }

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            throw UpdateSwapError.scriptPermissionsFailed(error.localizedDescription)
        }

        // Launched DETACHED: `nohup ... >>/tmp/gateopener-update.log 2>&1 &`
        // via `/bin/sh -c`, so the script keeps running after this process
        // exits (a plain child process would be killed along with its
        // parent on quit/terminate). All of the script's own output is
        // captured to updateLogPath — the ONLY recovery path once the
        // script's `rm -rf` has run.
        let quotedScriptPath = UpdateSwapScript.shQuote(scriptURL.path)
        let quotedLogPath = UpdateSwapScript.shQuote(updateLogPath)
        let shellCommand = "nohup /bin/sh \(quotedScriptPath) >>\(quotedLogPath) 2>&1 &"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellCommand]

        do {
            try process.run()
        } catch {
            throw UpdateSwapError.launchFailed(error.localizedDescription)
        }

        logger.notice("update swap script launched (pid target \(ProcessInfo.processInfo.processIdentifier)); terminating app")
        NSApp.terminate(nil)
    }
}
