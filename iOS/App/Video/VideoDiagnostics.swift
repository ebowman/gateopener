import Foundation

/// Collects a plain-text diagnostics log for exactly ONE `DoorVideoSession`
/// attempt, so an operator hitting the "does not work off the LAN" failure
/// (bead gateopener-672.27) can capture and share a log naming candidate
/// types, the selected candidate pair, and the failure stage -- from a
/// RELEASE (TestFlight) build, where there is no attached debug console.
///
/// Deliberately independent of `os.Logger`: `Logger` output is not easily
/// exfiltrated from a Release build by an end user, whereas this type's
/// `text` is designed to be persisted to the shared app-group `UserDefaults`
/// and displayed/shared directly from Settings.
///
/// `append(_:)` caps total stored text at `maxBytes` (16KB) by dropping the
/// OLDEST lines first, so the most recent (most diagnostically relevant --
/// typically the failure/terminal lines) content is always retained.
@MainActor
public final class VideoDiagnostics {
    /// The `UserDefaults` key both `persist(to:)` and `loadLast(from:)` use.
    public static let defaultsKey = "videoDiagnostics"

    /// Total cap on `text`'s UTF-8 byte size. 16KB comfortably holds a full
    /// ~30-35s session's worth of state transitions, candidate summaries,
    /// and selected-pair polls (each line is well under 200 bytes) while
    /// staying small enough to store in `UserDefaults` and paste into a bug
    /// report without truncation concerns downstream.
    public static let maxBytes = 16 * 1024

    private var lines: [String] = []

    public init() {}

    /// Appends one line (a newline is added automatically). If the
    /// resulting `text` would exceed `maxBytes`, the OLDEST lines are
    /// dropped (one at a time) until it fits again -- never the newest,
    /// since the newest lines (state transitions, the terminal reason) are
    /// exactly what a diagnostic report needs most.
    public func append(_ line: String) {
        lines.append(line)
        while textByteCount() > Self.maxBytes, lines.count > 1 {
            lines.removeFirst()
        }
        // Edge case: a single line alone already exceeds maxBytes (e.g. a
        // pathologically long SDP dump was appended by mistake). Truncate
        // it rather than looping forever with lines.count == 1.
        if lines.count == 1, textByteCount() > Self.maxBytes {
            lines[0] = String(lines[0].prefix(Self.maxBytes))
        }
    }

    /// The full accumulated log, one line per `append(_:)` call, joined by
    /// newlines.
    public var text: String {
        lines.joined(separator: "\n")
    }

    private func textByteCount() -> Int {
        text.utf8.count
    }

    /// Persists `text` to `defaults` under `defaultsKey`. Called on every
    /// terminal state and on `stop()`, per this bead's requirement that a
    /// RELEASE build still leaves a shareable log after any given attempt
    /// (successful or not) -- there is deliberately no "only persist on
    /// failure" branch, since a same-network success and an off-network
    /// failure both need to be comparable from the same Settings row.
    public func persist(to defaults: UserDefaults) {
        defaults.set(text, forKey: Self.defaultsKey)
    }

    /// Loads the last persisted session's log text, or `nil` if none has
    /// ever been persisted (fresh install, or `UserDefaults(suiteName:)`
    /// returned `nil` for the caller's suite).
    public static func loadLast(from defaults: UserDefaults) -> String? {
        defaults.string(forKey: defaultsKey)
    }
}
