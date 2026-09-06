import Foundation
import Testing
@testable import GateOpener

/// Tests for `VideoDiagnostics` (bead gateopener-672.27): the release-build
/// diagnostics recorder `DoorVideoSession` appends to and persists so a
/// TestFlight (Release) build can still produce a shareable log after an
/// off-LAN video failure.
@MainActor
struct VideoDiagnosticsTests {
    // MARK: - append() caps at 16KB, keeping the most recent lines

    /// MUTATION CHECK: removing the `while textByteCount() > Self.maxBytes`
    /// eviction loop in `VideoDiagnostics.append(_:)`
    /// (`iOS/App/Video/VideoDiagnostics.swift`) makes `text.utf8.count`
    /// grow unbounded, failing the `<= VideoDiagnostics.maxBytes` assertion
    /// below.
    @Test func appendCapsAt16KBKeepingMostRecentLines() {
        let diagnostics = VideoDiagnostics()

        // Each line is ~40 bytes; 1000 lines is ~40KB, comfortably over the
        // 16KB cap, so eviction must have happened at least once.
        for i in 0..<1000 {
            diagnostics.append("line \(i): 0123456789012345678901234")
        }

        #expect(diagnostics.text.utf8.count <= VideoDiagnostics.maxBytes)

        // The MOST RECENT line must still be present (never evicted)...
        #expect(diagnostics.text.contains("line 999:"))
        // ...while an early line must have been evicted to make room.
        #expect(!diagnostics.text.contains("line 0: "))
    }

    /// A single pathologically long line (longer than the entire cap) must
    /// be truncated rather than looping forever trying to evict it (there
    /// is nothing else to evict once `lines.count == 1`).
    @Test func appendTruncatesASingleOversizedLine() {
        let diagnostics = VideoDiagnostics()
        let oversized = String(repeating: "x", count: VideoDiagnostics.maxBytes * 2)

        diagnostics.append(oversized)

        #expect(diagnostics.text.utf8.count <= VideoDiagnostics.maxBytes)
    }

    /// Appending many lines, each individually small, must never exceed the
    /// cap at any point along the way (not just at the end).
    @Test func appendNeverExceedsCapAtAnyPoint() {
        let diagnostics = VideoDiagnostics()
        for i in 0..<2000 {
            diagnostics.append("diagnostic line number \(i) with some padding text")
            #expect(diagnostics.text.utf8.count <= VideoDiagnostics.maxBytes)
        }
    }

    // MARK: - persist/loadLast round-trip

    @Test func persistThenLoadLastRoundTrips() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        let diagnostics = VideoDiagnostics()
        diagnostics.append("state: idle -> connecting")
        diagnostics.append("state: connecting -> streaming")
        diagnostics.append("terminal reason: stopped")

        diagnostics.persist(to: defaults)

        let loaded = VideoDiagnostics.loadLast(from: defaults)
        #expect(loaded == diagnostics.text)
        #expect(loaded?.contains("terminal reason: stopped") == true)
    }

    /// MUTATION CHECK: if `persist(to:)` wrote under the wrong key (or
    /// `loadLast(from:)` read a different key), this would fail because
    /// `loadLast` would return `nil` even though something WAS persisted.
    @Test func persistUsesTheDocumentedDefaultsKey() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        let diagnostics = VideoDiagnostics()
        diagnostics.append("only line")
        diagnostics.persist(to: defaults)

        #expect(defaults.string(forKey: VideoDiagnostics.defaultsKey) == "only line")
    }

    // MARK: - loadLast is nil when absent

    @Test func loadLastIsNilWhenNothingEverPersisted() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        #expect(VideoDiagnostics.loadLast(from: defaults) == nil)
    }
}
