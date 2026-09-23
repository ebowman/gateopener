import Foundation

/// A short, non-secret "version (build)" string, e.g. `"0.1.9 (11)"`, used as
/// `OpenPressRecord.appVersion` -- see `OpenGateIntent`/`AppEnvironment
/// .make()`'s press-journal wiring (bead gateopener-41m.23).
///
/// Lives in `iOS/Shared` (compiled into both the app target and the widget
/// extension target -- see `iOS/Shared/README.md`) because both processes
/// need to stamp their own press records with a version string, and both
/// read it from their OWN `Bundle.main` (each process/target has its own
/// bundle and Info.plist, but both are generated from the same
/// `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` build settings in
/// `project.yml`, so the two strings match in practice).
public enum AppVersion {
    /// `"<CFBundleShortVersionString> (<CFBundleVersion>)"`, read from
    /// `Bundle.main.infoDictionary`. Falls back to `"?"` for either
    /// component that is missing (e.g. a plain SPM test bundle with no
    /// Info.plist at all) rather than crashing -- this is diagnostic
    /// metadata, never load-bearing for `OpenGateFlow`'s own control flow.
    public static var current: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let buildNumber = (info?["CFBundleVersion"] as? String) ?? "?"
        return "\(shortVersion) (\(buildNumber))"
    }
}
