import Foundation

/// Exact `Duration` -> `TimeInterval` conversion.
///
/// `Duration.components` splits a duration into whole `seconds` and
/// `attoseconds` (10^-18 s). Converting with only `TimeInterval(seconds)`
/// silently truncates any fractional part: `.milliseconds(2500)` becomes
/// `2.0` instead of `2.5`, and `.milliseconds(500)` becomes `0.0` -- which,
/// when fed to `URLRequest.timeoutInterval`, is treated as "no override" and
/// silently falls back to the system default (60s). This helper folds the
/// `attoseconds` term back in so fractional-second durations survive the
/// conversion exactly.
extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
