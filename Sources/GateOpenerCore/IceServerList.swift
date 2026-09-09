import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - IceServerList

/// Builds the `stun:` ICE server URL list injected into `door-video.html`
/// as `window.__ICE_SERVERS__`, shared verbatim by both the iOS and macOS
/// `DoorVideoSession` types (bead gateopener-6s8.5). Byte-for-byte the
/// logic that previously lived as private helpers on iOS's
/// `DoorVideoSession` (`resolveStunAddresses`/`iceServerURLs`, bead
/// gateopener-672.28), plus the official Comelit app's Google STUN
/// fallback servers (memory
/// `comelit-video-breakthrough-wireguard-full-traffic-capture-th`).
public enum IceServerList {

    // MARK: - STUN pre-resolution

    /// Resolves `host` to its addresses via `getaddrinfo`, so the page can
    /// be handed real `stun:<ip>:3478`/`stun:[<ip6>]:3478` URLs alongside
    /// the hostname form. Resolves with `ai_family = AF_UNSPEC` and
    /// `ai_flags = AI_DEFAULT` (`AI_V4MAPPED_CFG | AI_ADDRCONFIG` on
    /// Apple platforms): on an IPv6-only/NAT64 cellular network, this makes
    /// the resolver SYNTHESIZE an IPv6 address for this IPv4-only host,
    /// giving ICE gathering a route to an actual STUN response where a bare
    /// IPv4 literal would silently fail (root cause of bead
    /// gateopener-672.28: video works over STUN-only on IPv4 Wi-Fi/hotel
    /// networks but fails on cellular).
    /// Returns `[]` (never throws) on any resolution failure — the caller
    /// still injects the hostname-form entry regardless (see `urls`).
    public nonisolated static func resolveStunAddresses(host: String) -> [(family: Int32, address: String)] {
        var hints = addrinfo(
            ai_flags: AI_DEFAULT, ai_family: AF_UNSPEC, ai_socktype: SOCK_DGRAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        var addresses: [(family: Int32, address: String)] = []
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else { return addresses }
        defer { freeaddrinfo(first) }
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let p = ptr {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(p.pointee.ai_addr, p.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let family = p.pointee.ai_family
                if !address.isEmpty, !addresses.contains(where: { $0.family == family && $0.address == address }) {
                    addresses.append((family: family, address: address))
                }
            }
            ptr = p.pointee.ai_next
        }
        return addresses
    }

    /// Google STUN fallback servers, appended AFTER every Comelit entry in
    /// `urls(host:port:resolved:)`. The official Comelit app also uses
    /// `stun1`/`stun2.l.google.com` (memory
    /// `comelit-video-breakthrough-wireguard-full-traffic-capture-th`).
    ///
    /// RISK: adding more STUN servers can lengthen how long ICE gathering
    /// takes to reach `iceGatheringState === 'complete'` when one of them
    /// is unreachable — `door-video.html` waits up to 8s for gathering to
    /// finish. Not measured by this change; flagged for the human's
    /// hardware check.
    public static let extraStunURLs = [
        "stun:stun1.l.google.com:19302",
        "stun:stun2.l.google.com:19302",
    ]

    /// Pure formatting/ordering helper (unit-tested directly in
    /// `IceServerURLTests`): builds the final `stun:` URL list injected as
    /// `window.__ICE_SERVERS__`. Order is significant only insofar as the
    /// hostname form is tried first (WebKit resolves it itself, including
    /// NAT64 synthesis — the HTTP-500-on-hostname problem documented in bd
    /// memory `gateopener-yjn-spike-*` was Chromium-specific and was never
    /// observed in WKWebView), then IPv6/synthesized literals (bracketed
    /// per RFC 3986), then IPv4 literals, then `extraStunURLs` — never
    /// empty, since the hostname entry is unconditional.
    public nonisolated static func urls(host: String, port: Int, resolved: [(family: Int32, address: String)]) -> [String] {
        var urls: [String] = ["stun:\(host):\(port)"]

        for entry in resolved where entry.family == AF_INET6 {
            let url = "stun:[\(entry.address)]:\(port)"
            if !urls.contains(url) { urls.append(url) }
        }
        for entry in resolved where entry.family == AF_INET {
            let url = "stun:\(entry.address):\(port)"
            if !urls.contains(url) { urls.append(url) }
        }

        for url in extraStunURLs where !urls.contains(url) {
            urls.append(url)
        }

        return urls
    }
}
