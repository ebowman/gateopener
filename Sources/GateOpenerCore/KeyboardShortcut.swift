import Foundation

// HARD CONSTRAINT: GateOpenerCore imports Foundation ONLY — no Carbon,
// AppKit, or SwiftUI. This keeps the core headlessly testable (see
// AppSettings.swift's doc comment for the same rule). For that reason the
// modifier bit constants below are RAW NUMBERS that mirror Carbon's
// `cmdKey`/`shiftKey`/`optionKey`/`controlKey` values exactly, so the app
// layer (which DOES import Carbon) can pass its constants straight through
// to `KeyboardShortcut` without any translation table, and this file can
// still be unit-tested without linking Carbon at all.

/// A keyboard chord: a virtual key code plus a modifier bitmask, both stored
/// as raw numbers so this type has zero dependency on Carbon/AppKit.
///
/// `keyCode` matches the Carbon `kVK_*` virtual key code space (e.g. `5` is
/// `kVK_ANSI_G`). `modifiers` is a bitwise-OR of the `KeyboardShortcut`
/// modifier constants below, which mirror Carbon's `cmdKey`/`shiftKey`/
/// `optionKey`/`controlKey` bit values.
public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // MARK: - Modifier bit constants

    /// Mirrors Carbon's `cmdKey` (0x0100). Kept as a raw number so this file
    /// never imports Carbon; the app layer's Carbon constant has the same
    /// numeric value and can be passed straight through.
    public static let cmdKey: UInt32 = 0x0100

    /// Mirrors Carbon's `shiftKey` (0x0200).
    public static let shiftKey: UInt32 = 0x0200

    /// Mirrors Carbon's `optionKey` (0x0800).
    public static let optionKey: UInt32 = 0x0800

    /// Mirrors Carbon's `controlKey` (0x1000).
    public static let controlKey: UInt32 = 0x1000

    /// All four modifier constants, paired with their conventional macOS
    /// display order and glyph. Order is Control, Option, Shift, Command —
    /// this matches how macOS itself renders shortcuts (e.g. System
    /// Settings > Keyboard > Keyboard Shortcuts), which is ⌃⌥⇧⌘ rather than
    /// the ⌘-first order some apps use informally.
    private static let orderedModifierGlyphs: [(mask: UInt32, glyph: String)] = [
        (controlKey, "⌃"),
        (optionKey, "⌥"),
        (shiftKey, "⇧"),
        (cmdKey, "⌘"),
    ]

    // MARK: - Default chord

    /// Cmd-Ctrl-Option-G — key code 5 (`kVK_ANSI_G`), matching
    /// `GlobalHotkey`'s hardcoded default. Named here so the app layer and
    /// tests share one source of truth instead of re-deriving it.
    public static let defaultChord = KeyboardShortcut(
        keyCode: 5,
        modifiers: cmdKey | controlKey | optionKey
    )

    // MARK: - Validation

    /// A chord must have AT LEAST TWO modifiers to be valid. This is a real
    /// gate against accidentally-triggerable single-modifier (or bare-key)
    /// shortcuts firing a physical gate — enforced here at the model level,
    /// not only in whatever UI records the chord.
    public var isValid: Bool {
        modifierCount >= 2
    }

    private var modifierCount: Int {
        Self.orderedModifierGlyphs.reduce(0) { count, entry in
            modifiers & entry.mask != 0 ? count + 1 : count
        }
    }

    // MARK: - Display

    /// Renders the chord in conventional macOS order and glyphs, e.g.
    /// `⌃⌥⌘G` for the default chord. Unmapped key codes render as
    /// `Key <code>` rather than an empty string, so a chord never displays
    /// as glyphs with no key.
    public var displayString: String {
        let modifierGlyphs = Self.orderedModifierGlyphs
            .filter { modifiers & $0.mask != 0 }
            .map(\.glyph)
            .joined()
        return modifierGlyphs + Self.keyName(for: keyCode)
    }

    /// Maps a virtual key code to a display name. Covers letters and
    /// digits (matching Carbon's `kVK_ANSI_*` layout); anything unmapped
    /// falls back to `"Key <code>"` rather than an empty string.
    private static func keyName(for keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    /// Virtual key codes for letters A-Z and digits 0-9, matching Carbon's
    /// `kVK_ANSI_*` constants. Duplicated here as raw numbers (rather than
    /// imported from Carbon) to preserve the Foundation-only constraint.
    private static let keyNames: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9",
    ]
}

/// The stored shortcut preference: distinguishes "not configured yet" (use
/// the default), "explicitly disabled" (no hotkey at all), and "a specific
/// custom chord". `.disabled` and `.unset` MUST remain distinguishable
/// through a persistence round-trip — collapsing them would mean clearing
/// the shortcut silently reverts to the default, which is exactly the
/// behavior the operator ruled out.
public enum ShortcutPreference: Codable, Equatable, Sendable {
    case unset
    case disabled
    case custom(KeyboardShortcut)

    // MARK: - Codable

    /// Encoded as `{"case": "unset" | "disabled" | "custom", "shortcut": ...}`
    /// so the case tag and payload are both explicit on disk — this is what
    /// lets `.unset` and `.disabled` survive a round-trip as distinct values
    /// (a naive `Optional<KeyboardShortcut>` encoding cannot represent
    /// "explicitly disabled" at all) and lets decoding recognize an
    /// unrecognized/corrupt tag and fall back safely instead of trapping.
    private enum CodingKeys: String, CodingKey {
        case caseTag = "case"
        case shortcut
    }

    private enum CaseTag: String, Codable {
        case unset
        case disabled
        case custom
    }

    public init(from decoder: Decoder) throws {
        // Any failure below (missing keys, wrong types, unrecognized tag)
        // falls back to `.unset` rather than throwing/trapping, per the
        // bead's edge case: a persisted payload from an older or newer
        // version of this app must never crash decoding.
        guard
            let container = try? decoder.container(keyedBy: CodingKeys.self),
            let tag = try? container.decode(CaseTag.self, forKey: .caseTag)
        else {
            self = .unset
            return
        }

        switch tag {
        case .unset:
            self = .unset
        case .disabled:
            self = .disabled
        case .custom:
            if let shortcut = try? container.decode(KeyboardShortcut.self, forKey: .shortcut) {
                self = .custom(shortcut)
            } else {
                self = .unset
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unset:
            try container.encode(CaseTag.unset, forKey: .caseTag)
        case .disabled:
            try container.encode(CaseTag.disabled, forKey: .caseTag)
        case .custom(let shortcut):
            try container.encode(CaseTag.custom, forKey: .caseTag)
            try container.encode(shortcut, forKey: .shortcut)
        }
    }
}
