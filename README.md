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

## Release flow (maintainers)

Producing a distributable release is a four-stage pipeline:

```bash
scripts/build-app.sh        # build + sign GateOpener.app
scripts/make-dmg.sh         # package it into a signed DMG
scripts/notarize-dmg.sh     # submit to Apple, wait, staple the ticket
```

followed by publishing a GitHub release (tag, DMG asset, and an update
manifest for the self-updater).

This requires, on the machine doing the release:

- A **Developer ID Application** certificate in the signing keychain (an
  ad-hoc signature cannot be notarized).
- Notarization credentials, resolved by `scripts/notarize-dmg.sh` in this
  order: a `notarytool` keychain profile (`xcrun notarytool
  store-credentials`, default profile name `GateOpenerNotary`), or the
  `NOTARY_KEY` / `NOTARY_KEY_ID` / `NOTARY_ISSUER` environment variables
  pointing at an App Store Connect API key. Neither the key file, key ID,
  nor issuer ID are ever printed, logged, or committed by this script.
- `gh` authenticated (`gh auth login`) against this repository, to publish
  the release and upload the DMG asset.

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
