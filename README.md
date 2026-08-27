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

To install:

```bash
rm -rf /Applications/GateOpener.app
cp -R GateOpener.app /Applications/
```

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
