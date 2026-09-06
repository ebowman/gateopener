import Foundation

/// A snapshot of `GateState` written by the app and read by the widget
/// extension, since a widget process cannot observe `GateController` directly
/// — it lives in a separate process from the app.
///
/// `GateOpenerCore` is Foundation-only, so this type (and its `Phase` mirror
/// of `GateState`) must not depend on WidgetKit/UIKit/AppKit/SwiftUI. Codable
/// conformance plus the ISO-8601 date strategy used by `WidgetSnapshotStore`
/// is the wire format both processes agree on — changing field names, the
/// `Phase` raw values, or the date encoding strategy is a breaking change to
/// that cross-process contract.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// Mirrors `GateState`'s cases, but WITHOUT associated values: a widget
    /// only needs to know which case it is in order to render, and
    /// `Codable`-synthesizing an enum with associated values whose payload
    /// types might change is more fragile as a wire format than a plain
    /// string enum plus a separate optional `message` field.
    public enum Phase: String, Codable, Sendable {
        case needsSetup
        case idle
        case queued
        case opening
        case succeeded
        case failed
    }

    /// The display name of the currently selected gate, if any is configured.
    public let gateName: String?

    /// Which `GateState` case this snapshot was captured from.
    public let phase: Phase

    /// The failure message, present only when `phase == .failed`. `nil` for
    /// every other phase.
    public let message: String?

    /// When this snapshot was captured (from `GateController`'s perspective,
    /// not necessarily when the widget reads it).
    public let updatedAt: Date

    public init(gateName: String?, phase: Phase, message: String?, updatedAt: Date) {
        self.gateName = gateName
        self.phase = phase
        self.message = message
        self.updatedAt = updatedAt
    }

    /// Maps a `GateController` `GateState` (plus the display name of the
    /// selected gate, and the current time) to the wire format the widget
    /// reads.
    ///
    /// Deliberately an EXHAUSTIVE switch with no `default:` case: if a future
    /// bead adds a new `GateState` case, this must fail to compile until the
    /// new case is mapped here explicitly, rather than silently falling
    /// through to a default and shipping an unmapped widget phase.
    public static func from(state: GateState, gateName: String?, now: Date) -> WidgetSnapshot {
        switch state {
        case .needsSetup:
            return WidgetSnapshot(gateName: gateName, phase: .needsSetup, message: nil, updatedAt: now)
        case .idle:
            return WidgetSnapshot(gateName: gateName, phase: .idle, message: nil, updatedAt: now)
        case .queued:
            return WidgetSnapshot(gateName: gateName, phase: .queued, message: nil, updatedAt: now)
        case .opening:
            return WidgetSnapshot(gateName: gateName, phase: .opening, message: nil, updatedAt: now)
        case .succeeded:
            return WidgetSnapshot(gateName: gateName, phase: .succeeded, message: nil, updatedAt: now)
        case .failed(let message):
            return WidgetSnapshot(gateName: gateName, phase: .failed, message: message, updatedAt: now)
        }
    }
}

/// Reads and writes a single `WidgetSnapshot` to a shared `UserDefaults`
/// suite, so the app and widget extension can hand off `GateState` across
/// processes.
///
/// `UserDefaults` is documented by Apple as thread-safe, so this class is
/// marked `@unchecked Sendable` (matching `AppSettings`'s rationale): all
/// mutable state is delegated to `UserDefaults` itself, and this store holds
/// no other mutable storage.
public final class WidgetSnapshotStore: @unchecked Sendable {
    /// The `UserDefaults` key this store reads/writes by default. Exposed as
    /// a public constant (rather than left as a private literal) because it
    /// is itself part of the cross-process contract: both the app and the
    /// widget extension must agree on it, typically by using the default
    /// rather than overriding `key`.
    public static let defaultKey = "widgetSnapshot"

    private let defaults: UserDefaults
    private let key: String

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// - Parameters:
    ///   - defaults: The shared `UserDefaults` suite to read/write. Callers
    ///     in the app/widget should pass `SharedContainer.sharedDefaults()`;
    ///     tests should inject a throwaway `UserDefaults(suiteName:)`
    ///     instance so they never pollute the real app-group domain.
    ///   - key: The `UserDefaults` key to store the snapshot under. Defaults
    ///     to `defaultKey`; only override in tests that need isolation
    ///     within a shared suite.
    public init(defaults: UserDefaults, key: String = WidgetSnapshotStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    /// Encodes and stores `snapshot` synchronously. If encoding fails (should
    /// never happen for this simple, all-`Codable`-native-type struct), the
    /// write is silently skipped rather than crashing.
    public func write(_ snapshot: WidgetSnapshot) {
        guard let data = try? Self.encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    /// Reads and decodes the stored snapshot.
    ///
    /// Returns `nil` if there is no value under `key`, or if the stored value
    /// is not valid `WidgetSnapshot` JSON — this NEVER throws, since a widget
    /// extension reading a stale or corrupt value (e.g. mid-write from
    /// another process, or written by a mismatched app version) must degrade
    /// to "no data" rather than crash.
    public func read() -> WidgetSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? Self.decoder.decode(WidgetSnapshot.self, from: data)
    }
}
