import Foundation
import Testing
@testable import GateOpenerCore

/// LIVE integration tests for `UpdateSwapScript.generate(...)`: run the
/// REAL generated script text through a REAL `/bin/sh`, including real
/// `hdiutil attach`/`hdiutil detach`/`cp -R`/`open` calls, against a
/// THROWAWAY install directory and a THROWAWAY DMG built with `hdiutil
/// create` — both entirely under `NSTemporaryDirectory()`. NEVER touches
/// `/Applications` or the real installed GateOpener.app.
///
/// These are slower (~seconds, not milliseconds — `scriptSwapsThrowaway
/// BundleEndToEndWithRealDMG` takes several seconds because it actually
/// creates and mounts a disk image) and touch real system state (mounts a
/// volume under `/Volumes`, launches a real process via `open`) more than
/// the rest of this test target does. They are kept anyway because they are
/// the only test coverage that proves the swap script's shell logic is
/// correct as ACTUAL shell script text executed by a real shell — the
/// `UpdateSwapScriptTests` suite only asserts on the generated string.
struct UpdateSwapScriptLiveIntegrationTests {
    @Test func scriptFailsLoudlyWhenDMGMissingAndNeverTouchesBundle() throws {
        let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swap-smoke-\(UUID().uuidString)")
        let installDir = scratchRoot.appendingPathComponent("install")
        let bundleDir = installDir.appendingPathComponent("GateOpener.app")
        try FileManager.default.createDirectory(at: bundleDir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("marker".utf8).write(to: bundleDir.appendingPathComponent("Contents/marker.txt"))

        let script = UpdateSwapScript.generate(
            dmgPath: scratchRoot.appendingPathComponent("nonexistent.dmg").path,
            parentPID: 999_999, // near-certainly not a running pid
            installDir: installDir.path,
            bundleName: "GateOpener.app"
        )

        let scriptURL = scratchRoot.appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("SCRIPT OUTPUT:\n\(output)")
        print("EXIT STATUS: \(process.terminationStatus)")

        #expect(process.terminationStatus != 0)
        #expect(FileManager.default.fileExists(atPath: bundleDir.appendingPathComponent("Contents/marker.txt").path))

        try? FileManager.default.removeItem(at: scratchRoot)
    }

    /// Full happy-path live run against a REAL (throwaway) DMG built with
    /// `hdiutil create`, proving attach -> python3 plist parse -> rm -rf old
    /// -> cp -R new -> detach -> open actually replaces a throwaway bundle
    /// end to end. Never touches the real installed app.
    @Test func scriptSwapsThrowawayBundleEndToEndWithRealDMG() throws {
        let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swap-smoke-happy-\(UUID().uuidString)")
        let installDir = scratchRoot.appendingPathComponent("install")
        let bundleDir = installDir.appendingPathComponent("GateOpener.app")
        try FileManager.default.createDirectory(at: bundleDir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("OLD VERSION".utf8).write(to: bundleDir.appendingPathComponent("Contents/marker.txt"))

        // Build a real throwaway DMG containing a fresh GateOpener.app whose
        // marker.txt differs from the old one, so the test can prove the
        // OLD bundle's contents are gone and the NEW bundle's contents are
        // in place after the swap -- not just that "some bundle" exists.
        let dmgSourceDir = scratchRoot.appendingPathComponent("dmgsrc")
        let newBundleDir = dmgSourceDir.appendingPathComponent("GateOpener.app")
        let newBundleMacOSDir = newBundleDir.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: newBundleMacOSDir, withIntermediateDirectories: true)
        try Data("NEW VERSION".utf8).write(to: newBundleDir.appendingPathComponent("Contents/marker.txt"))
        // Make this a genuinely launchable (if trivial) app bundle -- a
        // real executable (a copy of /usr/bin/true) plus an Info.plist
        // naming it -- so the script's FINAL step, `open "$OLD_BUNDLE"`,
        // can actually succeed too, rather than only proving the file-copy
        // portion of the swap.
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: newBundleMacOSDir.appendingPathComponent("GateOpener")
        )
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>GateOpener</string>
            <key>CFBundleIdentifier</key>
            <string>com.gateopener.smoketest</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """
        try Data(infoPlist.utf8).write(to: newBundleDir.appendingPathComponent("Contents/Info.plist"))

        let dmgPath = scratchRoot.appendingPathComponent("update.dmg").path
        let createDMG = Process()
        createDMG.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        createDMG.arguments = ["create", "-volname", "GateOpenerUpdateSmoke", "-srcfolder", dmgSourceDir.path, "-ov", "-format", "UDZO", dmgPath]
        createDMG.standardOutput = Pipe()
        createDMG.standardError = Pipe()
        try createDMG.run()
        createDMG.waitUntilExit()
        #expect(createDMG.terminationStatus == 0)

        let script = UpdateSwapScript.generate(
            dmgPath: dmgPath,
            parentPID: 999_999, // near-certainly not a running pid
            installDir: installDir.path,
            bundleName: "GateOpener.app"
        )

        let scriptURL = scratchRoot.appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("HAPPY-PATH SCRIPT OUTPUT:\n\(output)")
        print("HAPPY-PATH EXIT STATUS: \(process.terminationStatus)")

        #expect(process.terminationStatus == 0)
        #expect(output.contains("[gateopener-update] update complete"))

        let markerContents = try String(contentsOf: bundleDir.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
        #expect(markerContents.trimmingCharacters(in: .whitespacesAndNewlines) == "NEW VERSION")

        try? FileManager.default.removeItem(at: scratchRoot)
    }
}
