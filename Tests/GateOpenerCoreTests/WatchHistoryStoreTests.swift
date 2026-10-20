import Foundation
import Testing
@testable import GateOpenerCore

struct WatchHistoryStoreTests {
    private func makeStore() -> WatchHistoryStore {
        WatchHistoryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-history-\(UUID().uuidString).json"))
    }

    // Fails if append stops persisting (transfers() would be empty).
    @Test func appendPersistsAndReadsBack() {
        let store = makeStore()
        #expect(store.transfers().isEmpty)
        store.append(text: "hello", sentAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(store.transfers().map(\.text) == ["hello"])
    }

    // Fails if the cap of 5 is removed (7 would remain) or the oldest is kept
    // instead of the newest; also fails if order is oldest-first.
    @Test func keepsOnlyLatestFiveNewestFirst() {
        let store = makeStore()
        for i in 1...7 {
            store.append(text: "t\(i)", sentAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
        }
        #expect(store.transfers().map(\.text) == ["t7", "t6", "t5", "t4", "t3"])
    }

    // Fails if parse stops checking `kind` (a foreign payload would be stored).
    @Test func parseRejectsOtherKindsAndMissingText() {
        #expect(WatchHistoryStore.parse(userInfo: ["kind": "other", "text": "x"]) == nil)
        #expect(WatchHistoryStore.parse(userInfo: ["kind": "watchHistory"]) == nil)
        #expect(WatchHistoryStore.parse(userInfo: ["kind": "watchHistory", "text": "x"])?.text == "x")
    }

    // Fails if the header literal changes or the block is omitted when transfers exist.
    @Test func shareTextAppendsFromWatchBlockOnlyWhenPresent() {
        let t = WatchHistoryStore.Transfer(text: "WATCHTEXT", sentAt: Date())
        let with = OpenHistoryText.shareText(for: [], prefix: "P", watchTransfers: [t])
        #expect(with.contains("--- From watch ---\nWATCHTEXT"))
        #expect(!OpenHistoryText.shareText(for: [], prefix: "P").contains("From watch"))
    }
}
