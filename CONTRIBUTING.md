# Contributing to GateOpener

Thanks for your interest in GateOpener. This is a small, focused project —
please keep contributions similarly small and focused.

## Getting started

No Apple Developer account or paid certificate is required to build, run,
and test the app from source:

```bash
swift build
swift test
scripts/build-app.sh   # produces a real, launchable GateOpener.app
```

See the [README](README.md#build-from-source) for details on the build
script and what an ad-hoc-signed local build can and can't do.

To exercise the app's logic without ever touching a real Comelit account or
a real gate, run with the mock environment variables set:

```bash
GATEOPENER_MOCK=1 GATEOPENER_MOCK_SELFTEST=1 swift run GateOpener
```

This runs the full self-test — status-item click routing, hotkey
registration, the event log, and shortcut persistence — against mocked
Comelit calls, and exits with `SELFTEST PASS`. It is the same gate CI
runs, and it never contacts the real service or opens a real gate.

(consult the code for the current self-test invocation if this drifts —
`GATEOPENER_MOCK` and `GATEOPENER_MOCK_SELFTEST` are the load-bearing
variables).

## Before opening a pull request

- Run `swift build` and `swift test` locally; both must pass.
- Keep changes scoped to one concern per PR — this makes review tractable.
- If you're touching anything that talks to the Comelit API
  (`Sources/GateOpenerCore/ComelitAPI.swift`, `GateClient.swift`,
  `TokenManager.swift`), read [docs/PROTOCOL.md](docs/PROTOCOL.md) first.
  Several behaviors there (the Generic Actuator filtering, the retry rules,
  the never-send-`value:false` rule) were discovered the hard way against
  real hardware and are safety- or account-security-critical — please don't
  "simplify" them without understanding why they're there.
- Never commit real credentials, tokens, account identifiers (including a
  real `aptId`), or any other account-specific data. Test fixtures should
  use obviously fake values.
- Match the existing code style: doc comments on public types and any
  non-obvious behavior, `swift-testing` (`@Test`/`#expect`) rather than
  XCTest for new tests.

## Reporting issues

Please open a GitHub issue. Include macOS version, GateOpener version (from
Settings), and steps to reproduce. Do not include real credentials, tokens,
or account-identifying details in a public issue.

## What this project is not looking for

- New third-party dependencies — `Package.swift` currently has none, and
  that's deliberate.
- Features that require credentials or access this project's maintainer
  cannot verify against the real Comelit cloud (video-path changes
  especially — see `docs/PROTOCOL.md`'s note on the WebRTC layer).
