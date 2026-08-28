/// Namespace for the GateOpener core library.
///
/// This target contains all authentication, API, and business logic for
/// GateOpener. It must remain free of AppKit/SwiftUI imports so that
/// `swift test` can run headlessly with no GUI dependency.
///
/// There is no `GateOpenerCore.version` constant here — the single
/// authoritative version lives in the repo-root `VERSION` file, which
/// `scripts/build-app.sh` reads and writes into the built bundle's
/// `Info.plist` (`CFBundleShortVersionString`). At runtime the app reads
/// its own version back from `Bundle.main.CFBundleShortVersionString`
/// (see `UpdateManifest.isNewer(than:)`), never from a compiled-in
/// constant, so there is exactly one place a version can go stale.
public enum GateOpenerCore {}
