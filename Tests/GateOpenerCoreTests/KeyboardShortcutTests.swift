import Foundation
import Testing
@testable import GateOpenerCore

/// Tests for `KeyboardShortcut` and `ShortcutPreference`, including their
/// persistence through `AppSettings`. Follows `AppSettingsTests`' convention
/// of a UUID-unique throwaway `UserDefaults(suiteName:)` per test, removed
/// in teardown, so the real `ie.boboco.GateOpener` domain is never touched.
struct KeyboardShortcutTests {
    private func makeSuite() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "ie.boboco.GateOpener.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create UserDefaults suite for testing")
        }
        let cleanup = {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, cleanup)
    }

    // MARK: - Default chord

    @Test func defaultChordIsCmdControlOptionG() {
        #expect(KeyboardShortcut.defaultChord.keyCode == 5)
        let expectedModifiers = KeyboardShortcut.cmdKey | KeyboardShortcut.controlKey | KeyboardShortcut.optionKey
        #expect(KeyboardShortcut.defaultChord.modifiers == expectedModifiers)
    }

    @Test func defaultChordDisplayStringIsControlOptionCommandG() {
        #expect(KeyboardShortcut.defaultChord.displayString == "⌃⌥⌘G")
    }

    // MARK: - Validation: at least two modifiers

    @Test func chordWithOneModifierFailsValidation() {
        let chord = KeyboardShortcut(keyCode: 5, modifiers: KeyboardShortcut.cmdKey)
        #expect(!chord.isValid)
    }

    @Test func chordWithNoModifiersFailsValidation() {
        let chord = KeyboardShortcut(keyCode: 5, modifiers: 0)
        #expect(!chord.isValid)
    }

    @Test func chordWithTwoModifiersPassesValidation() {
        let chord = KeyboardShortcut(keyCode: 5, modifiers: KeyboardShortcut.cmdKey | KeyboardShortcut.controlKey)
        #expect(chord.isValid)
    }

    @Test func defaultChordIsValid() {
        #expect(KeyboardShortcut.defaultChord.isValid)
    }

    // MARK: - Display string: key name mapping

    @Test func displayStringCoversLettersAndDigits() {
        let letterChord = KeyboardShortcut(keyCode: 0, modifiers: KeyboardShortcut.cmdKey | KeyboardShortcut.shiftKey)
        #expect(letterChord.displayString == "⇧⌘A")

        let digitChord = KeyboardShortcut(keyCode: 18, modifiers: KeyboardShortcut.controlKey | KeyboardShortcut.optionKey)
        #expect(digitChord.displayString == "⌃⌥1")
    }

    @Test func displayStringForUnmappedKeyCodeIsHonestNotEmpty() {
        let chord = KeyboardShortcut(keyCode: 999, modifiers: KeyboardShortcut.cmdKey | KeyboardShortcut.controlKey)
        let display = chord.displayString
        #expect(!display.isEmpty)
        #expect(display.contains("999"))
        #expect(display == "⌃⌘Key 999")
    }

    // MARK: - ShortcutPreference round-trip through AppSettings

    @Test func roundTripsUnsetPreference() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        settings.shortcutPreference = .unset

        #expect(settings.shortcutPreference == .unset)
    }

    @Test func roundTripsDisabledPreference() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        settings.shortcutPreference = .disabled

        #expect(settings.shortcutPreference == .disabled)
    }

    @Test func roundTripsCustomPreference() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        let chord = KeyboardShortcut(keyCode: 8, modifiers: KeyboardShortcut.cmdKey | KeyboardShortcut.shiftKey)
        settings.shortcutPreference = .custom(chord)

        #expect(settings.shortcutPreference == .custom(chord))
    }

    /// The heart of the bead: `.disabled` and `.unset` must not collapse
    /// into each other through persistence. If they did, clearing a custom
    /// shortcut would silently revert to the default chord instead of
    /// disabling the hotkey entirely.
    @Test func disabledAndUnsetAreNotConfusedAfterRoundTrip() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)

        settings.shortcutPreference = .disabled
        let readBackDisabled = settings.shortcutPreference
        #expect(readBackDisabled == .disabled)
        #expect(readBackDisabled != .unset)

        settings.shortcutPreference = .unset
        let readBackUnset = settings.shortcutPreference
        #expect(readBackUnset == .unset)
        #expect(readBackUnset != .disabled)
    }

    @Test func defaultAppSettingsValueIsUnsetWhenNeverSet() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.shortcutPreference == .unset)
    }

    // MARK: - Corrupt / unrecognized persisted payload

    @Test func corruptPersistedPayloadDecodesToUnsetWithoutTrapping() {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)

        // Not valid JSON at all.
        defaults.set(Data([0xFF, 0x00, 0xDE, 0xAD, 0xBE, 0xEF]), forKey: "ie.boboco.GateOpener.shortcutPreference")
        #expect(settings.shortcutPreference == .unset)
    }

    @Test func unrecognizedCaseTagDecodesToUnsetWithoutTrapping() throws {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)

        // Valid JSON, but a case tag this version of the app does not
        // recognize — simulates a payload from a future app version.
        let json = #"{"case":"futureCaseFromNewerVersion"}"#
        defaults.set(Data(json.utf8), forKey: "ie.boboco.GateOpener.shortcutPreference")
        #expect(settings.shortcutPreference == .unset)
    }

    @Test func customTagWithMissingShortcutPayloadDecodesToUnsetWithoutTrapping() throws {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)

        // "custom" tag but no "shortcut" payload — malformed/truncated data.
        let json = #"{"case":"custom"}"#
        defaults.set(Data(json.utf8), forKey: "ie.boboco.GateOpener.shortcutPreference")
        #expect(settings.shortcutPreference == .unset)
    }

    // MARK: - Codable round-trip (encoder/decoder directly, not via AppSettings)

    @Test func shortcutPreferenceEncodesAndDecodesDirectly() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for preference in [ShortcutPreference.unset, .disabled, .custom(KeyboardShortcut.defaultChord)] {
            let data = try encoder.encode(preference)
            let decoded = try decoder.decode(ShortcutPreference.self, from: data)
            #expect(decoded == preference)
        }
    }
}

// MARK: - Reset-to-Default semantics

/// "Reset to Default" must restore `.unset`, NOT `.custom(defaultChord)`.
///
/// `.unset` means "follow the default chord, whatever it becomes";
/// `.custom(defaultChord)` means "I deliberately chose this chord". If the two
/// collapse, a future change of the default silently fails to reach anyone who
/// pressed Reset. Asserting only that the value round-trips would NOT catch
/// that — `.custom(defaultChord)` round-trips perfectly well — so this asserts
/// the DISTINCTION.
@Test func resetPreferenceIsUnsetAndNotCustomDefault() {
    #expect(shortcutResetPreference == .unset)
    #expect(shortcutResetPreference != .custom(KeyboardShortcut.defaultChord))
}

/// The two must also stay distinguishable across a persistence round-trip,
/// since that is where a collapse would actually bite.
@Test func resetPreferenceStaysDistinctFromCustomDefaultAcrossPersistence() {
    let suiteName = "ie.boboco.GateOpener.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = AppSettings(defaults: defaults)

    settings.shortcutPreference = shortcutResetPreference
    #expect(settings.shortcutPreference == .unset)
    #expect(settings.shortcutPreference != .custom(KeyboardShortcut.defaultChord))

    settings.shortcutPreference = .custom(KeyboardShortcut.defaultChord)
    #expect(settings.shortcutPreference == .custom(KeyboardShortcut.defaultChord))
    #expect(settings.shortcutPreference != .unset)
}
