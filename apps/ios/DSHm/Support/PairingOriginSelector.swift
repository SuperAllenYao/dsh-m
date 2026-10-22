import Foundation

/// Picks reachable pairing origins from a QR payload.
///
/// A Mac-generated QR lists loopback first (valid on the Mac, and on the iOS
/// simulator which shares the host network namespace). On a physical iPhone
/// 127.0.0.1/localhost points at the phone itself, so loopback origins must be
/// filtered there and the remaining LAN/tunnel origins tried in order.
enum PairingOriginSelector {
    static var isPhysicalDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host else { return false }
        let value = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return value == "localhost"
            || value == "::1"
            || value == "0.0.0.0"
            || value.hasPrefix("127.")
    }

 /// Unique https origins from endpoints[]/origins[]/legacy origin, non-loopback
 /// first; loopback candidates are only kept when `allowLoopback` (simulator).
    static func candidates(payload: PairingPayload, allowLoopback: Bool = !isPhysicalDevice) -> [URL] {
        var raw: [String] = []
 // origins[] is the plugin's preferred fallback list; endpoints[] adds
 // per-endpoint URLs (may be the same origins with kind/pri metadata).
        raw.append(contentsOf: payload.origins ?? [])
        raw.append(contentsOf: payload.endpoints?.compactMap { $0.url } ?? [])
        if let origin = payload.origin { raw.append(origin) }
 // M2a: the tunnel (relay bridge) origin may only be advertised through the
 // top-level `relay` object, so keep it in the reconnect candidate list.
        if let relayOrigin = payload.relay?.origin { raw.append(relayOrigin) }
        return candidates(from: raw, allowLoopback: allowLoopback)
    }

 /// Reconnect order for persisted credentials: the origin currently in use
 /// first, then every stored candidate (signed payload origins incl. the relay
 /// bridge origin). Used by every reconnect round (design §4.7).
    static func reconnectCandidates(
        current: String?,
        stored: [String]?,
        allowLoopback: Bool = !isPhysicalDevice
    ) -> [URL] {
        var raw: [String] = []
        if let current { raw.append(current) }
        raw.append(contentsOf: stored ?? [])
        return candidates(from: raw, allowLoopback: allowLoopback)
    }

 /// Origin string as persisted in credentials (no trailing slash).
    static func normalizedOriginString(_ url: URL) -> String {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    static func candidates(from strings: [String], allowLoopback: Bool) -> [URL] {
        var seen = Set<String>()
        var nonLoopback: [URL] = []
        var loopback: [URL] = []
        for string in strings {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let url = URL(string: trimmed),
                  url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty else { continue }
            var key = url.absoluteString.lowercased()
            while key.hasSuffix("/") { key.removeLast() }
            guard seen.insert(key).inserted else { continue }
            if isLoopbackHost(host) {
                if allowLoopback { loopback.append(url) }
            } else {
                nonLoopback.append(url)
            }
        }
        return nonLoopback + loopback
    }

 // MARK: - P0 (remote perf): path-aware dial order

 /// Hosts that only make sense on the local network: RFC1918 IPv4, link-local,
 /// `.local` mDNS names and IPv6 ULA/link-local prefixes.
    static func isLANHost(_ host: String?) -> Bool {
        guard let raw = host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased(),
              !raw.isEmpty else { return false }
        if raw == "localhost" || raw.hasSuffix(".local") { return true }
        let octets = raw.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
            let a = octets[0], b = octets[1]
            if a == 10 { return true }
            if a == 192 && b == 168 { return true }
            if a == 172 && (16...31).contains(b) { return true }
            if a == 169 && b == 254 { return true }
            return false
        }
        if raw.hasPrefix("fe80:") || raw.hasPrefix("fc") || raw.hasPrefix("fd") { return true }
        return false
    }

 /// P0: dial order for one reconnect round. On cellular/expensive paths the
 /// relay origin is dialed first and LAN origins are dropped entirely when at
 /// least one non-LAN candidate exists (each LAN probe can cost a 15s timeout).
    static func dialCandidates(_ candidates: [URL], prefersRelay: Bool) -> [URL] {
        guard prefersRelay else { return candidates }
        let relay = candidates.filter { !isLANHost($0.host) }
        return relay.isEmpty ? candidates : relay
    }
}
