# GateOpener

GateOpener is a macOS menu-bar app that opens a Comelit gate with a single click.

**Requirements:** macOS 14 or later

**License:** MIT — see [LICENSE](LICENSE).

**Status:** early development — not yet released.

## Build and install

Build a real, launchable `GateOpener.app`:

```bash
scripts/build-app.sh
```

This builds a release binary (`swift build -c release`), assembles
`GateOpener.app` in the repo root with the correct bundle layout
(`Contents/MacOS`, `Contents/Resources`, `Contents/Info.plist`), regenerates
the app icon from `Resources/AppIcon.svg`, and ad-hoc code-signs the bundle
(`codesign --force --deep --sign -`) so Keychain access and Launch-at-Login
(`SMAppService`) behave correctly on the machine that built it. The script
is idempotent — re-running it from a clean checkout always removes any
stale `GateOpener.app` first and produces the same result.

To install into `/Applications` (the normal path):

```bash
scripts/install.sh
```

This calls `scripts/build-app.sh` itself (no need to run it separately),
then:

1. Quits any currently running `GateOpener` instance and waits for it to
   exit, so a running bundle is never overwritten mid-flight.
2. Copies the new bundle into `/Applications` atomically — it stages the
   copy at a temp path inside `/Applications` and then `mv`s it into place,
   so a failure partway through never leaves a partial or half-replaced
   app; any previous install is preserved until the swap succeeds.
3. Verifies the signature survived the copy with
   `codesign --verify --deep --strict`, and fails loudly if it did not (a
   broken signature silently breaks Keychain access and Launch-at-Login).
4. Relaunches `GateOpener` from `/Applications`.

The script never calls `sudo`. `/Applications` is normally writable by an
admin user without elevation, so the plain copy is tried first; if it's not
writable, the script prints the exact `sudo` command to run yourself and
exits non-zero rather than escalating privileges on its own. It is
idempotent — safe to re-run any time you rebuild.

If you already have credentials stored in Keychain, they are keyed by
service string (`ie.boboco.GateOpener`), not by bundle path, so they survive
a reinstall. Because the bundle is ad-hoc signed and just moved to a new
path, macOS may prompt you for Keychain access again the first time the
reinstalled app runs — that prompt is expected, not a bug.

Launch-at-Login (the toggle in Settings) uses `SMAppService.mainApp`, which
only registers reliably when the app runs from a stable, expected location
such as `/Applications` — running it straight from the repo checkout may
cause registration to fail with a message asking you to move it to
`/Applications` first.

The app icon is generated reproducibly from `Resources/AppIcon.svg` by
`scripts/generate-icon.sh` (invoked automatically by `build-app.sh`); the
`.icns` itself is a build artifact and is not committed.

**Note:** the bundle above is ad-hoc signed, which is sufficient for local
use on the machine that built it. Distributing `GateOpener.app` to other
Macs requires a Developer ID signature and notarization — that is tracked
as separate follow-up work, not covered by this build script.
