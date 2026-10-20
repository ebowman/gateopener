import Foundation

/// Keeps the latest few open-history text transfers sent from the watch
/// (bead gateopener-3d7.17). One small JSON file; at most `capacity` entries.
/// The text is the watch's share text, which never contains credentials.
public struct WatchHistoryStore: Sendable {
    public struct Transfer: Codable, Equatable, Sendable {
        public let text: String
        public let sentAt: Date
        public init(text: String, sentAt: Date) {
            self.text = text
            self.sentAt = sentAt
        }
    }

    /// `userInfo["kind"]` value identifying a watch-history transfer.
    public static let kind = "watchHistory"
    public static let capacity = 5

    public let url: URL

    public init(url: URL) { self.url = url }

    /// Newest first.
    public func transfers() -> [Transfer] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Transfer].self, from: data)) ?? []
    }

    /// Prepends the transfer and drops everything beyond `capacity`.
    @discardableResult
    public func append(text: String, sentAt: Date) -> Bool {
        var all = transfers()
        all.insert(Transfer(text: text, sentAt: sentAt), at: 0)
        if all.count > Self.capacity { all = Array(all.prefix(Self.capacity)) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(all) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Parses a WCSession userInfo dictionary; `nil` unless it is a
    /// well-formed watch-history transfer.
    public static func parse(userInfo: [String: Any]) -> Transfer? {
        guard userInfo["kind"] as? String == kind, let text = userInfo["text"] as? String else { return nil }
        return Transfer(text: text, sentAt: userInfo["sentAt"] as? Date ?? Date())
    }

    /// Share-text block appended to the iPhone history share text.
    public static func shareBlock(for transfers: [Transfer]) -> String? {
        guard !transfers.isEmpty else { return nil }
        return "--- From watch ---\n" + transfers.map(\.text).joined(separator: "\n\n")
    }
}
