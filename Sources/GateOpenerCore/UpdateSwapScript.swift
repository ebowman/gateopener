import Foundation

/// Generates the detached `/bin/sh` script that performs GateOpener's
/// self-replacing update swap, and the shell-quoting helper that makes doing
/// so safe.
///
/// THIS IS THE MOST DANGEROUS CODE IN THE PROJECT. The generated script ends
/// with `rm -rf "$INSTALL_DIR/$BUNDLE_NAME"` against a path built from
/// filesystem/bundle strings that this app does not fully control (a
/// build-directory path, a Finder-renamed `.app`, etc.). An unquoted space,
/// quote character, or shell metacharacter in any interpolated value can
/// corrupt that `rm -rf` into deleting the wrong thing, or worse. Every
/// value that flows into the generated script MUST go through `shQuote(_:)`
/// first — there is no other line of defense once the script is launched:
/// by the time it runs, the app that could have caught a mistake has already
/// called `NSApp.terminate(nil)`.
///
/// A running `.app` cannot overwrite its own bundle out from under itself,
/// so the swap has to happen from a process that outlives it: this type only
/// produces the *text* of that script. Writing it to disk, making it
/// executable, launching it detached, and calling `NSApp.terminate(nil)`
/// afterward are all done by `UpdateInstallerRunner` (in the `GateOpener`
/// target, where `AppKit`/`NSApp` are available) — kept here, in
/// `GateOpenerCore`, only because this logic is pure string generation with
/// no AppKit dependency, and pure string generation is exactly what can be
/// unit-tested exhaustively without ever touching a filesystem or process.
public enum UpdateSwapScript {

    /// Shell-quotes `value` for safe interpolation into a POSIX `/bin/sh`
    /// script as a single word, using the standard single-quote technique:
    /// wrap in `'...'`, and for every literal single quote in `value`, close
    /// the quoting, emit an escaped quote (`\'`), and reopen quoting.
    ///
    /// Single-quoting is used (not double-quoting) because inside single
    /// quotes, POSIX shells treat EVERY character literally — no variable
    /// expansion (`$(...)`, `$VAR`), no backslash escapes, no command
    /// substitution, nothing. The only character that cannot appear inside a
    /// single-quoted string at all is the single quote itself, which is why
    /// it needs the close-escape-reopen dance below. This makes the result
    /// safe against spaces, double quotes, backslashes, newlines, `$(...)`,
    /// semicolons, and leading dashes (a leading `-` inside `'...'` is just
    /// a literal character to the shell, not an option flag, once the
    /// quoted word is used as a plain argument rather than passed through
    /// something like `getopt`).
    ///
    /// Example: `shQuote("it's")` -> `'it'\''s'`
    ///   - `'it'`      -- literal "it"
    ///   - `\'`        -- an escaped literal single quote
    ///   - `'s'`       -- literal "s"
    ///   Concatenated by the shell (with no separators between adjacent
    ///   quoted/escaped segments) into the single word `it's`.
    public static func shQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'" + escaped + "'"
    }

    /// Builds the full text of the detached swap script.
    ///
    /// - Parameters:
    ///   - dmgPath: absolute filesystem path to the already-downloaded AND
    ///     VERIFIED DMG (see `UpdateInstaller.verify` — this script must
    ///     never run against an unverified artifact).
    ///   - parentPID: the running app's own `getpid()`, so the script can
    ///     wait for this specific process to exit before touching anything.
    ///   - installDir: the directory CONTAINING the installed bundle (i.e.
    ///     `Bundle.main.bundleURL.deletingLastPathComponent().path`) — NOT
    ///     hardcoded to `/Applications`, so this works from a build
    ///     directory too.
    ///   - bundleName: the bundle's own last path component (e.g.
    ///     `"GateOpener.app"`), taken from `Bundle.main.bundleURL`.
    ///
    /// Every one of these four values is interpolated through `shQuote(_:)`
    /// exactly once. The script:
    ///   1. Spins on `kill -0 "$PID"` (once per 0.5s) until the parent
    ///      process has actually exited, so the running `.app` bundle is
    ///      never touched while still in use.
    ///   2. `hdiutil attach -nobrowse -noverify -plist` the DMG, capturing
    ///      its plist output to a temp file.
    ///   3. Parses the mount point out of that plist with `python3` (never
    ///      by grepping `/Volumes` — see the type doc comment on why that
    ///      was rejected as fragile). If `python3` is unavailable, or parsing
    ///      fails to produce a mount point, the script logs and exits
    ///      NONZERO *before* doing anything destructive — it never falls
    ///      back to guessing a path.
    ///   4. `rm -rf` the OLD installed bundle
    ///      (`"$INSTALL_DIR/$BUNDLE_NAME"`) — the single irreversible step
    ///      in this entire pipeline.
    ///   5. `cp -R` the new bundle from the mounted DMG into `installDir` in
    ///      its place — same path, same signing identity, so TCC/login-item/
    ///      keychain-ACL grants survive (do not change this to a "fresh
    ///      install" elsewhere; see the bead brief).
    ///   6. `hdiutil detach` the mounted volume.
    ///   7. `open` the freshly-installed bundle.
    ///
    /// Every step from `hdiutil attach` onward is written with `set -e`
    /// semantics made explicit (`|| exit 1` after the load-bearing steps)
    /// so a failure partway through stops rather than silently continuing
    /// into the next (potentially destructive) step. All output is expected
    /// to be redirected to `/tmp/gateopener-update.log` by the CALLER
    /// (`UpdateInstallerRunner`, via `nohup ... >>/tmp/gateopener-update.log
    /// 2>&1 &`), not by this script itself — this script just writes to
    /// stdout/stderr as normal.
    public static func generate(
        dmgPath: String,
        parentPID: Int32,
        installDir: String,
        bundleName: String
    ) -> String {
        let qDMG = shQuote(dmgPath)
        let qPID = shQuote(String(parentPID))
        let qInstallDir = shQuote(installDir)
        let qBundleName = shQuote(bundleName)

        return """
        #!/bin/sh
        set -e

        DMG_PATH=\(qDMG)
        PID=\(qPID)
        INSTALL_DIR=\(qInstallDir)
        BUNDLE_NAME=\(qBundleName)

        # Refuse to run at all with a target that could make the rm -rf below
        # catastrophic. With an empty BUNDLE_NAME, "$MOUNT_POINT/$BUNDLE_NAME"
        # is the mount root — a real directory, so the -d check further down
        # PASSES — and "$INSTALL_DIR/$BUNDLE_NAME" collapses to "/". That is
        # `rm -rf /` with no recovery but this log. Bundle.main.bundleURL
        # never yields empty components today, so this is defence in depth on
        # the single most dangerous line in the project: cheap, and the one
        # bug class where "not currently reachable" is not good enough.
        if [ -z "$INSTALL_DIR" ] || [ -z "$BUNDLE_NAME" ]; then
            echo "[gateopener-update] refusing to run: empty install dir or bundle name"
            exit 1
        fi
        if [ "$INSTALL_DIR" = "/" ]; then
            echo "[gateopener-update] refusing to run: install dir is /"
            exit 1
        fi
        case "$BUNDLE_NAME" in
            */*|.|..)
                echo "[gateopener-update] refusing to run: unsafe bundle name $BUNDLE_NAME"
                exit 1
                ;;
        esac

        echo "[gateopener-update] waiting for parent pid $PID to exit"
        while kill -0 "$PID" 2>/dev/null; do
            sleep 0.5
        done
        echo "[gateopener-update] parent exited, proceeding"

        PLIST_PATH="$(mktemp -t gateopener-update-plist)"
        echo "[gateopener-update] attaching $DMG_PATH"
        if ! hdiutil attach -nobrowse -noverify -plist "$DMG_PATH" > "$PLIST_PATH"; then
            echo "[gateopener-update] hdiutil attach failed"
            exit 1
        fi

        if ! command -v python3 >/dev/null 2>&1; then
            echo "[gateopener-update] python3 not found; cannot safely parse hdiutil plist, aborting"
            exit 1
        fi

        MOUNT_POINT="$(python3 -c '
        import plistlib
        import sys

        with open(sys.argv[1], "rb") as f:
            data = plistlib.load(f)

        for entity in data.get("system-entities", []):
            mount_point = entity.get("mount-point")
            if mount_point:
                print(mount_point)
                break
        ' "$PLIST_PATH")"

        if [ -z "$MOUNT_POINT" ]; then
            echo "[gateopener-update] could not determine mount point from hdiutil plist, aborting"
            exit 1
        fi
        echo "[gateopener-update] mounted at $MOUNT_POINT"

        NEW_BUNDLE="$MOUNT_POINT/$BUNDLE_NAME"
        if [ ! -d "$NEW_BUNDLE" ]; then
            echo "[gateopener-update] $NEW_BUNDLE not found on mounted volume, aborting"
            hdiutil detach "$MOUNT_POINT" -quiet || true
            exit 1
        fi

        OLD_BUNDLE="$INSTALL_DIR/$BUNDLE_NAME"
        echo "[gateopener-update] removing $OLD_BUNDLE"
        rm -rf "$OLD_BUNDLE"

        echo "[gateopener-update] copying $NEW_BUNDLE to $INSTALL_DIR"
        cp -R "$NEW_BUNDLE" "$INSTALL_DIR/"

        echo "[gateopener-update] detaching $MOUNT_POINT"
        hdiutil detach "$MOUNT_POINT" -quiet || true

        echo "[gateopener-update] relaunching $OLD_BUNDLE"
        open "$OLD_BUNDLE"

        echo "[gateopener-update] update complete"
        """
    }
}
