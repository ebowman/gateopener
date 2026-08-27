import Testing
@testable import GateOpenerCore

@Test func versionIsNonEmpty() {
    #expect(!GateOpenerCore.version.isEmpty)
}
