import Foundation
import Testing
@testable import GateOpenerCore

/// Tests for `UpdateSwapScript.shQuote(_:)` and
/// `UpdateSwapScript.generate(dmgPath:parentPID:installDir:bundleName:)`.
///
/// `shQuote` is the single most dangerous line in this codebase (see the
/// type's doc comment): an unquoted space or shell metacharacter in a path
/// interpolated into the generated `rm -rf` can corrupt it. Every case
/// below is proven non-vacuous by ACTUALLY HANDING THE QUOTED STRING TO A
/// REAL POSIX SHELL and checking the shell reconstructs the exact original
/// value — this is a mutation-style check: if `shQuote` were broken (e.g.
/// stopped escaping embedded quotes, or used double-quotes and thus allowed
/// `$(...)` expansion), these assertions would fail because the shell would
/// echo back something other than the original input. See
/// `gateopener-vacuous-assertion-failure-mode`.
struct UpdateSwapScriptTests {

    // MARK: - shQuote: round-trip through a real shell

    /// Runs `/bin/sh -c "printf '%s' <quoted>"` and returns what the shell
    /// actually produced. This is the ground truth for "is this quoting
    /// safe" — not a hand-rolled parser that could share the same blind
    /// spots as the code under test.
    private func shellRoundTrip(_ quoted: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' \(quoted)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // discard

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    @Test func roundTripsPlainPath() throws {
        let input = "/Applications/GateOpener.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithSpaces() throws {
        let input = "/Users/eric bowman/Applications/Gate Opener.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithSingleQuote() throws {
        let input = "/Users/eric's mac/GateOpener.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithDoubleQuote() throws {
        let input = "/Users/eric \"the boss\" bowman/GateOpener.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithBackslash() throws {
        let input = "/Users/eric\\bowman/GateOpener.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithNewline() throws {
        let input = "/Users/eric\nbowman/GateOpener.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithCommandSubstitution() throws {
        // The classic injection payload: if this were double-quoted (or
        // unquoted), $(...) would be executed by the shell. Single-quoting
        // must render it inert.
        let input = "/tmp/$(rm -rf ~)/GateOpener.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithSemicolon() throws {
        let input = "/tmp/foo; rm -rf /; echo pwned/GateOpener.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithLeadingDash() throws {
        // A leading "-" could otherwise be misread as an option flag by
        // whatever command consumes the quoted word.
        let input = "-rf/GateOpener.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithMultipleAdjacentSingleQuotes() throws {
        let input = "it''s ''weird''"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsEmptyString() throws {
        let input = ""
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithDollarSign() throws {
        let input = "/tmp/$HOME/GateOpener.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithBacktick() throws {
        let input = "/tmp/`whoami`/GateOpener.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    // MARK: - shQuote structural properties (independent of the shell)

    @Test func alwaysWrapsInSingleQuotes() {
        let quoted = UpdateSwapScript.shQuote("anything")
        #expect(quoted.hasPrefix("'"))
        #expect(quoted.hasSuffix("'"))
    }

    @Test func embeddedSingleQuoteIsEscapedNotLeftBare() {
        // Non-vacuous by construction: if shQuote naively wrapped the
        // input in quotes WITHOUT escaping embedded quotes, this exact
        // "close-escape-reopen" substring would be absent (there'd just be
        // a bare "'" instead), so this assertion fails under that mutation.
        let quoted = UpdateSwapScript.shQuote("it's")
        #expect(quoted.contains("'\\''"))
        #expect(quoted == "'it'\\''s'")
    }

    // MARK: - Script generation: exact text for known inputs

    @Test func generatedScriptContainsShellShebangAndSetE() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 4242,
            installDir: "/Applications",
            bundleName: "GateOpener.app"
        )
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("set -e"))
    }

    @Test func generatedScriptEmbedsQuotedValuesExactlyOnce() {
        let dmgPath = "/tmp/GateOpener Update.dmg"
        let pid: Int32 = 99887
        let installDir = "/Applications"
        let bundleName = "GateOpener.app"

        let script = UpdateSwapScript.generate(
            dmgPath: dmgPath,
            parentPID: pid,
            installDir: installDir,
            bundleName: bundleName
        )

        let expectedDMGAssignment = "DMG_PATH=\(UpdateSwapScript.shQuote(dmgPath))"
        let expectedPIDAssignment = "PID=\(UpdateSwapScript.shQuote(String(pid)))"
        let expectedInstallDirAssignment = "INSTALL_DIR=\(UpdateSwapScript.shQuote(installDir))"
        let expectedBundleNameAssignment = "BUNDLE_NAME=\(UpdateSwapScript.shQuote(bundleName))"

        #expect(script.contains(expectedDMGAssignment))
        #expect(script.contains(expectedPIDAssignment))
        #expect(script.contains(expectedInstallDirAssignment))
        #expect(script.contains(expectedBundleNameAssignment))

        // Each assignment line appears EXACTLY once — proves the value is
        // not accidentally duplicated (e.g. once quoted, once raw), which
        // would be a real injection surface if the raw form were also
        // present and later referenced instead of the quoted variable.
        #expect(script.components(separatedBy: expectedDMGAssignment).count == 2)
        #expect(script.components(separatedBy: expectedPIDAssignment).count == 2)
        #expect(script.components(separatedBy: expectedInstallDirAssignment).count == 2)
        #expect(script.components(separatedBy: expectedBundleNameAssignment).count == 2)
    }

    @Test func generatedScriptNeverContainsRawUnquotedDangerousPath() {
        // The raw (unquoted) dangerous value must NEVER appear anywhere in
        // the script text on its own — only inside the shQuote(...) wrapped
        // assignment. This directly guards against a regression where some
        // OTHER interpolation site forgets to call shQuote.
        let dangerousPath = "/tmp/evil; rm -rf ~"
        let script = UpdateSwapScript.generate(
            dmgPath: dangerousPath,
            parentPID: 1,
            installDir: "/Applications",
            bundleName: "GateOpener.app"
        )

        // The only occurrence of the raw substring must be inside the
        // shQuote(...)'d assignment line.
        let quoted = UpdateSwapScript.shQuote(dangerousPath)
        let scriptWithoutQuotedOccurrence = script.replacingOccurrences(of: quoted, with: "")
        #expect(!scriptWithoutQuotedOccurrence.contains(dangerousPath))
    }

    @Test func generatedScriptWaitsForParentPIDBeforeAnyDestructiveStep() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "GateOpener.app"
        )

        guard let killRange = script.range(of: "kill -0"),
              let rmRange = script.range(of: "rm -rf \"$OLD_BUNDLE\"") else {
            Issue.record("expected both 'kill -0' wait loop and 'rm -rf \"$OLD_BUNDLE\"' to be present")
            return
        }
        // Non-vacuous: this fails if the destructive rm -rf were ever moved
        // (or newly introduced) ahead of the parent-exit wait loop.
        #expect(killRange.lowerBound < rmRange.lowerBound)
    }

    @Test func generatedScriptRemovesOldBundleBeforeCopyingNewOne() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "GateOpener.app"
        )

        guard let rmRange = script.range(of: "rm -rf \"$OLD_BUNDLE\""),
              let cpRange = script.range(of: "cp -R \"$NEW_BUNDLE\"") else {
            Issue.record("expected both rm -rf and cp -R steps to be present")
            return
        }
        #expect(rmRange.lowerBound < cpRange.lowerBound)
    }

    @Test func generatedScriptUsesPython3ToParsePlistNotGrepVolumes() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "GateOpener.app"
        )
        #expect(script.contains("python3"))
        #expect(script.contains("plistlib"))
        #expect(!script.contains("grep") || !script.lowercased().contains("/volumes"))
    }

    @Test func generatedScriptFailsLoudlyWhenPython3Missing() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "GateOpener.app"
        )
        #expect(script.contains("command -v python3"))
        // Must exit nonzero rather than silently continuing when python3
        // is absent.
        guard let checkRange = script.range(of: "command -v python3") else {
            Issue.record("expected python3 availability check")
            return
        }
        let afterCheck = script[checkRange.upperBound...]
        #expect(afterCheck.contains("exit 1"))
    }

    /// The reviewer of gateopener-c33.7 reached `rm -rf "/"` by running the
    /// generated script with an empty install dir and bundle name: with an
    /// empty BUNDLE_NAME, "$MOUNT_POINT/$BUNDLE_NAME" is the mount ROOT — a
    /// real directory, so the existing -d check passes — and
    /// "$INSTALL_DIR/$BUNDLE_NAME" collapses to "/".
    ///
    /// Not reachable via Bundle.main.bundleURL today, but this is the one
    /// bug class where "not currently reachable" is not good enough, so the
    /// script refuses outright. These assertions exist so a future edit
    /// cannot quietly drop the guard.
    @Test func generatedScriptRefusesEmptyOrRootTargetsBeforeRemoving() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/x.dmg",
            parentPID: 999_999,
            installDir: "/Applications",
            bundleName: "GateOpener.app"
        )

        // The guards must exist...
        #expect(script.contains(#"[ -z "$INSTALL_DIR" ]"#))
        #expect(script.contains(#"[ -z "$BUNDLE_NAME" ]"#))
        #expect(script.contains(#"[ "$INSTALL_DIR" = "/" ]"#))

        // ...and must come BEFORE the destructive line, or they are useless.
        let guardIndex = script.range(of: #"[ -z "$INSTALL_DIR" ]"#)
        let removeIndex = script.range(of: #"rm -rf "$OLD_BUNDLE""#)
        #expect(guardIndex != nil)
        #expect(removeIndex != nil)
        if let g = guardIndex, let r = removeIndex {
            #expect(g.lowerBound < r.lowerBound)
        }
    }

    @Test func generatedScriptOpensRelaunchedAppAtEnd() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "GateOpener.app"
        )
        guard let cpRange = script.range(of: "cp -R \"$NEW_BUNDLE\""),
              let openRange = script.range(of: "open \"$OLD_BUNDLE\"") else {
            Issue.record("expected both cp -R and open steps to be present")
            return
        }
        #expect(cpRange.lowerBound < openRange.lowerBound)
    }
}
