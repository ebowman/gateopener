import Foundation
import Testing
@testable import GateOpener

/// Tests for `DoorVideoSession.iceServerURLs(host:port:resolved:)` (bead
/// gateopener-672.28): the pure formatting/ordering function that builds
/// the `stun:` URL list injected into `window.__ICE_SERVERS__`.
///
/// Root cause under test: on an IPv6-only/NAT64 cellular network, a bare
/// IPv4 STUN literal gives WKWebView's ICE gathering no usable route, while
/// an IPv6 (possibly NAT64-synthesized) literal or the hostname form
/// (WebKit resolves it itself, including NAT64 synthesis) does. This suite
/// locks down that IPv6 entries are included, bracketed, and ordered before
/// IPv4 entries, with the hostname form always first and never dropped.
struct IceServerURLTests {
    private let host = "stun.cloud.comelitgroup.com"
    private let port = 3478

    // MARK: - Hostname first

    /// MUTATION CHECK: removing the unconditional `"stun:\(host):\(port)"`
    /// seed entry in `iceServerURLs` (iOS/App/Video/DoorVideoSession.swift)
    /// makes this fail — the first element would instead be an IP literal
    /// (or the array would be empty when `resolved` is empty).
    @Test func hostnameFormIsAlwaysFirst() {
        let resolved: [(family: Int32, address: String)] = [
            (family: AF_INET, address: "1.2.3.4"),
            (family: AF_INET6, address: "2001:db8::1"),
        ]
        let urls = DoorVideoSession.iceServerURLs(host: host, port: port, resolved: resolved)
        #expect(urls.first == "stun:\(host):\(port)")
    }

    // MARK: - IPv6 bracketed, IPv4 unbracketed and last

    /// MUTATION CHECK: swapping the IPv6/IPv4 loop order in `iceServerURLs`
    /// (iterating `AF_INET` before `AF_INET6`) makes `urls[1]` the IPv4
    /// entry and `urls[2]` the IPv6 entry, failing these exact-index
    /// assertions.
    ///
    /// MUTATION CHECK: dropping the `[` `]` brackets around the IPv6
    /// address (formatting it as `"stun:\(addr):\(port)"` instead of
    /// `"stun:[\(addr)]:\(port)"`) makes the bracket-format assertion fail.
    @Test func ipv6IsBracketedAndOrderedBeforeUnbracketedIPv4() {
        let resolved: [(family: Int32, address: String)] = [
            (family: AF_INET, address: "1.2.3.4"),
            (family: AF_INET6, address: "2001:db8::1"),
        ]
        let urls = DoorVideoSession.iceServerURLs(host: host, port: port, resolved: resolved)

        #expect(urls.count == 3)
        #expect(urls[1] == "stun:[2001:db8::1]:\(port)")
        #expect(urls[2] == "stun:1.2.3.4:\(port)")

        // Explicit bracket-format checks, independent of index.
        #expect(urls.contains("stun:[2001:db8::1]:\(port)"))
        #expect(!urls.contains("stun:2001:db8::1:\(port)"))
    }

    /// Resolver order within a family is preserved (not sorted): two IPv6
    /// addresses and two IPv4 addresses keep their relative order from
    /// `resolved`.
    ///
    /// MUTATION CHECK: sorting or reversing entries within a family (e.g.
    /// alphabetically) instead of preserving resolver order flips the
    /// expected index-2/3 and index-4/5 pairs below.
    @Test func resolverOrderIsPreservedWithinEachFamily() {
        let resolved: [(family: Int32, address: String)] = [
            (family: AF_INET, address: "10.0.0.1"),
            (family: AF_INET6, address: "2001:db8::1"),
            (family: AF_INET, address: "10.0.0.2"),
            (family: AF_INET6, address: "2001:db8::2"),
        ]
        let urls = DoorVideoSession.iceServerURLs(host: host, port: port, resolved: resolved)

        #expect(urls == [
            "stun:\(host):\(port)",
            "stun:[2001:db8::1]:\(port)",
            "stun:[2001:db8::2]:\(port)",
            "stun:10.0.0.1:\(port)",
            "stun:10.0.0.2:\(port)",
        ])
    }

    // MARK: - Dedupe

    /// MUTATION CHECK: removing the `if !urls.contains(url)` dedupe guards
    /// in `iceServerURLs` makes this fail — `urls.count` would be 5 instead
    /// of 3, with the repeated IPv4/IPv6 addresses each appearing twice.
    @Test func repeatedAddressesAreDeduped() {
        let resolved: [(family: Int32, address: String)] = [
            (family: AF_INET, address: "1.2.3.4"),
            (family: AF_INET, address: "1.2.3.4"),
            (family: AF_INET6, address: "2001:db8::1"),
            (family: AF_INET6, address: "2001:db8::1"),
        ]
        let urls = DoorVideoSession.iceServerURLs(host: host, port: port, resolved: resolved)

        #expect(urls.count == 3)
        #expect(urls == [
            "stun:\(host):\(port)",
            "stun:[2001:db8::1]:\(port)",
            "stun:1.2.3.4:\(port)",
        ])
    }

    // MARK: - Empty resolved list

    /// MUTATION CHECK: any code path that returns `[]` instead of the
    /// unconditional hostname entry when `resolved` is empty (e.g. an
    /// early `guard !resolved.isEmpty else { return [] }`) makes this
    /// fail.
    @Test func emptyResolvedListYieldsJustTheHostnameEntry() {
        let urls = DoorVideoSession.iceServerURLs(host: host, port: port, resolved: [])
        #expect(urls == ["stun:\(host):\(port)"])
    }
}
