# GateOpener

GateOpener is a macOS menu-bar app for one-click opening of a Comelit gate,
with live door-camera video shown right at the moment you open it.

Click the menu-bar icon and the gate opens — no app window, no waiting for a
page to load. If a door camera is available, GateOpener shows a brief live
video overlay so you can see the gate actually swing open, instead of just
trusting that it did.

> **Screenshot:** _add a screenshot of the menu-bar icon and the confirmation
> overlay here (e.g. `docs/screenshot.png`)._

**Requirements:** macOS 14 (Sonoma) or later.

**License:** MIT — see [LICENSE](LICENSE).

**Disclaimer:** GateOpener is an unofficial, third-party client. It is not
affiliated with, endorsed by, or supported by Comelit Group S.p.A. It talks
to the same public cloud API that Comelit's own mobile app uses. See
[DISCLAIMER.md](DISCLAIMER.md) and use at your own risk.

## Features

- One click (or a global keyboard shortcut) opens the gate — no window to
  open first.
- A brief confirmation overlay shows live door-camera video when you open
  the gate, so you can see it actually happen (honors macOS's Reduce Motion
  setting, and can be turned off in Settings).
- Lives entirely in the menu bar: no Dock icon, no always-open window.
- Optional Launch at Login.
- Self-updates in place, verifying every update against a SHA-256 digest
  *and* Apple notarization before installing it (see [Security](#security)).

## Install

The simplest path is the prebuilt app:

1. Download the latest `GateOpener-<version>.dmg` from this repository's
   [Releases](../../releases) page.
2. Open the DMG and drag `GateOpener.app` into `/Applications`.
3. Launch it from `/Applications` (not from the mounted DMG) — the first
   launch will ask for your Comelit account credentials, which are then
   stored in the macOS Keychain, and prompt for Keychain access, which is
   expected.

Released DMGs are signed with a Developer ID certificate and notarized by
Apple, so Gatekeeper should let them run without extra steps.

## Build from source

Build a real, launchable `GateOpener.app` yourself:

```bash
scripts/build-app.sh
```

This runs `swift build -c release`, assembles `GateOpener.app` in the repo
root with the correct bundle layout (`Contents/MacOS`, `Contents/Resources`,
`Contents/Info.plist`), regenerates the app icon from
`Resources/AppIcon.svg`, and code-signs the bundle. The script is
idempotent — re-running it from a clean checkout always removes any stale
`GateOpener.app` first and produces the same result.

**Signing note for contributors:** `scripts/build-app.sh` resolves a
Developer ID signing identity if one is available in your keychain
(`scripts/lib/resolve-codesign-identity.sh`), and falls back to an ad-hoc
signature (`codesign --force --deep --sign -`) if not. An ad-hoc-signed
build is fully usable for local development and testing on the machine that
built it — Keychain access and Launch-at-Login both work correctly with it.
**You do not need an Apple Developer account to build and run GateOpener
from source.** A Developer ID certificate is only required to produce a DMG
that other people's Macs will run without a Gatekeeper warning (see
Release flow, below).

To install into `/Applications`:

```bash
scripts/install.sh
```

This builds first, then quits any running instance, copies the new bundle
into `/Applications` atomically (staged copy + `mv`, so a failure never
leaves a half-replaced app), verifies the signature survived the copy, and
relaunches it. It never calls `sudo`; if `/Applications` isn't writable
without elevation it prints the exact command to run yourself instead of
escalating on its own.

Running the test suite:

```bash
swift test
```

### iOS (simulator)

- `make ios-build` is the fast compile gate for the iOS app: it builds for
  a generic Simulator destination with `CODE_SIGNING_ALLOWED=NO`. This is
  unsigned, so the Keychain is unusable — any code path that touches
  `KeychainCredentialStore` fails immediately with
  `KeychainError.saveFailed(status: -34018)` (`errSecMissingEntitlement`).
  Use it only to confirm the app compiles.
- `make ios-sim-build` / `make ios-sim-run` build and run the iOS app
  signed for a concrete Simulator device (`SIM_DEVICE`, default "iPhone 17
  Pro"), so the app's entitlements (`application-groups`,
  `keychain-access-groups`) are embedded and the Keychain works. Use
  `SIM_ARGS` to pass launch arguments, e.g. `make ios-sim-run
  SIM_ARGS="--signin-debug-attempt user@example.com pass"`.

### iOS app (TestFlight)

Prerequisites:

- `xcodegen` (`brew install xcodegen`).
- An App Store Connect API key at
  `~/.appstoreconnect/private_keys/AuthKey_<API_KEY_ID>.p8`.
- A `.env` file at the repo root (copy `.env.example` and fill in
  `API_KEY_ID` / `API_ISSUER_ID` — both come from the same App Store
  Connect API key). `.env` is gitignored; never commit it.

Day-to-day iOS development uses `make ios-build` (fast unsigned compile
check) or `make ios-sim-run` (signed run on a Simulator). To verify signing
and archiving without uploading anything, run:

```bash
./testflight.sh ios --archive-only
```

This archives the app with automatic signing via the API key
(`-allowProvisioningUpdates`) and restores `project.yml` afterwards, leaving
the tree clean. To archive, export, upload to TestFlight, and commit the
resulting build-number bump, run:

```bash
./testflight.sh ios
```

Note: the App Store Connect app record for bundle id `ie.boboco.GateOpener`
must already exist before the first upload can succeed — creating it is an
operator step (see bead 672.20).

The export (`ExportOptions.plist`) uses **manual** signing with the local
"Apple Distribution" certificate and two App Store provisioning profiles,
"GateOpener AppStore ios" and "GateOpener AppStore widget", which must be
installed in `~/Library/MobileDevice/Provisioning Profiles`. Both were
created through the App Store Connect API and can be re-downloaded from the
developer portal if missing. Automatic/cloud signing is not used because
the API key configured above lacks cloud-signing permission.

## Release flow (maintainers)

Producing and publishing a distributable release is a four-stage pipeline:

```bash
scripts/build-app.sh        # build + sign GateOpener.app
scripts/make-dmg.sh         # package it into a signed DMG
scripts/notarize-dmg.sh     # submit to Apple, wait, staple the ticket
make release                # generate the update manifest and publish
```

`make release` (`scripts/publish-release.sh`) tags the current commit,
generates the stable-named `appcast.json` update manifest describing the
just-built DMG (its `dmgSHA256` is computed from that exact DMG file, so it
can never describe a different binary), and publishes both the DMG and the
manifest as GitHub Release assets via `gh release create`. It refuses to run
unless every precondition holds — no git remote named `origin`, a dirty
working tree, an already-existing `v<version>` tag, or a DMG that isn't
notarized all fail fast with a specific, actionable message naming which
check failed. It is **not** part of `make`'s default target, so a bare
`make` or `make all` never publishes anything; only running `make release`
deliberately does.

This requires, on the machine doing the release:

- A **Developer ID Application** certificate in the signing keychain (an
  ad-hoc signature cannot be notarized).
- Notarization credentials, resolved by `scripts/notarize-dmg.sh` in this
  order: a `notarytool` keychain profile (`xcrun notarytool
  store-credentials`, default profile name `GateOpenerNotary`), or the
  `NOTARY_KEY` / `NOTARY_KEY_ID` / `NOTARY_ISSUER` environment variables
  pointing at an App Store Connect API key. Neither the key file, key ID,
  nor issuer ID are ever printed, logged, or committed by this script.
- `gh` authenticated (`gh auth login`) against this repository, plus a git
  remote named `origin` pointing at it, to publish the release and upload
  the DMG and manifest assets. `make release` derives the GitHub owner and
  repo from `origin`'s URL (SSH or HTTPS) rather than a hardcoded value, so
  a fork or rename works without editing anything.

Contributors without any of the above can still build, run, and test the app
completely — none of this is required to work on the code.

## Security

- **Credentials never live in this repository.** Your Comelit username and
  password, and the OAuth tokens obtained from them, are stored only in the
  macOS Keychain (`kSecClassGenericPassword`, scoped to this app), never on
  disk in plain text and never committed anywhere.
- **Network scope**: GateOpener talks only to Comelit's own cloud API
  (`api.comelitgroup.com`) to authenticate, discover devices, open the gate,
  and stream door-camera video, plus GitHub's release infrastructure to
  check for and download app updates. It contacts no other service.
- **Self-update verification**: before installing any downloaded update,
  GateOpener requires BOTH of the following to hold — either one alone is
  not trusted:
  1. The downloaded DMG's streaming SHA-256 digest matches the digest
     published in the release's update manifest.
  2. `spctl -a -t open --context context:primary-signature` exits
     successfully against the DMG, meaning it is genuinely Developer-ID
     signed *and* notarized by Apple — not just a file with a matching
     hash.

  See `Sources/GateOpenerCore/UpdateInstaller.swift` for the implementation.
- See [docs/PROTOCOL.md](docs/PROTOCOL.md) for how GateOpener talks to
  Comelit's API, for anyone auditing or extending that code.

If you believe you've found a security issue, please open an issue in this
repository describing it (without posting any real credentials, tokens, or
account-identifying details).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
