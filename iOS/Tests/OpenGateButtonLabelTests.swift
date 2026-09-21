import Foundation
import Testing
import GateOpenerCore
@testable import GateOpener

/// Tests for bead gateopener-41m.10: `MainView.primaryLabel(for:)`, the pure
/// static func extracted from the Open button's label so its per-state text
/// is testable without constructing a `MainView`/SwiftUI hierarchy.
struct OpenGateButtonLabelTests {
    /// `.needsSetup` and `.idle` both read as "Open Gate" — the verb-first
    /// call to action this bead's GOAL asks for, replacing the old
    /// noun-only gate name.
    ///
    /// MUTATION CHECK: swapping this for the gate name (the pre-bead
    /// behaviour) would fail this exact-string `#expect`.
    @Test func idleLabelIsOpenGate() {
        #expect(MainView.primaryLabel(for: .idle) == "Open Gate")
    }

    @Test func needsSetupLabelIsOpenGate() {
        #expect(MainView.primaryLabel(for: .needsSetup) == "Open Gate")
    }

    /// `.queued` reads as "Waiting for network…" per STEP 2.
    ///
    /// MUTATION CHECK: collapsing `.queued` onto the same string as `.idle`
    /// would fail this test while leaving `idleLabelIsOpenGate` passing.
    @Test func queuedLabelIsWaitingForNetwork() {
        #expect(MainView.primaryLabel(for: .queued) == "Waiting for network…")
    }

    /// `.opening` reads as "Opening…" — the label must stay visible (not
    /// blank) while a spinner also shows, per STEP 2's explicit requirement.
    @Test func openingLabelIsOpening() {
        #expect(MainView.primaryLabel(for: .opening) == "Opening…")
    }

    /// `.succeeded` reads as "Opened" regardless of the associated
    /// timestamp — the date is surfaced via `statusText`, not this label.
    ///
    /// MUTATION CHECK: if `primaryLabel` accidentally formatted the
    /// associated `Date` into the string, this exact-match `#expect` would
    /// fail (the label would contain a time, not just "Opened").
    @Test func succeededLabelIsOpened() {
        #expect(MainView.primaryLabel(for: .succeeded(at: Date())) == "Opened")
    }

    /// `.failed` reads as "Try Again" regardless of the associated error
    /// message — the message itself is surfaced via `statusText`.
    ///
    /// MUTATION CHECK: if `primaryLabel` returned the associated `message`
    /// instead of the fixed "Try Again" string, this would fail.
    @Test func failedLabelIsTryAgain() {
        #expect(MainView.primaryLabel(for: .failed(message: "Network error")) == "Try Again")
    }

    /// Every `GateState` case maps to a distinct label except the two that
    /// are intentionally identical (`.needsSetup`/`.idle`) — guards against
    /// two DIFFERENT states silently collapsing onto the same text.
    @Test func distinctStatesMostlyProduceDistinctLabels() {
        let idle = MainView.primaryLabel(for: .idle)
        let queued = MainView.primaryLabel(for: .queued)
        let opening = MainView.primaryLabel(for: .opening)
        let succeeded = MainView.primaryLabel(for: .succeeded(at: Date()))
        let failed = MainView.primaryLabel(for: .failed(message: "x"))

        let labels = [idle, queued, opening, succeeded, failed]
        #expect(Set(labels).count == labels.count)
    }
}
