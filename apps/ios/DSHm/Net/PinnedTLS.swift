import CryptoKit
import Foundation
import Network
import Security

/// Certificate pin helpers.
///
/// Pin format on the wire (QR payload / GET /health) is the Node
/// `X509Certificate.fingerprint256` form: 32 SHA-256 bytes as uppercase hex
/// separated by colons ("20:5A:8C:..."). We normalize to lowercase hex.
enum PinFormat {
    static func normalize(_ raw: String?) -> String? {
        guard var raw else { return nil }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = raw
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The link plugin also exposes pins as base64url-encoded 32-byte SHA-256
    /// digests (43 chars, no padding).
    static func hexFromBase64URL(_ raw: String?) -> String? {
        guard let raw, let data = Data(base64URL: raw), data.count == 32 else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// Pretty form for display only.
    static func display(_ normalized: String) -> String {
        stride(from: 0, to: normalized.count, by: 2).map { offset -> String in
            let start = normalized.index(normalized.startIndex, offsetBy: offset)
            let end = normalized.index(start, offsetBy: 2)
            return String(normalized[start..<end]).uppercased()
        }.joined(separator: ":")
    }
}

/// Thread-safe holder for the leaf pin observed during a TLS handshake.
final class PinCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var observed: String?

    var pin: String? {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    func record(_ pin: String) {
        lock.lock()
        observed = pin
        lock.unlock()
    }
}

/// Certificate-chain trust against the plugin's pinned **CA** certificate
/// (v0.1.1, C 方案).
///
/// The dsh-m plugin re-issues its leaf certificate over time (expiry, manual
/// rotation, and — before v0.1.1 — any LAN-IP/SAN drift). Pinning only the leaf
/// DER would un-pair every phone on each re-issue, so the app now pins the
/// long-lived CA: a presented leaf that chains to that CA is accepted, and the
/// exact leaf pin remains only as the fallback for pre-C pairings (and for the
/// pairing-time bootstrap where no CA is known yet).
enum CATrust {
    static func certificate(fromBase64 base64: String?) -> SecCertificate? {
        guard let base64,
              let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        return SecCertificateCreateWithData(nil, data as CFData)
    }

    /// Evaluates `chain` against `anchor` only (the pinned CA anchors the trust).
    /// Server-auth policy without a hostname: the link's identity is the pinned
    /// CA (the relay bridges terminate at the Mac leaf), so hostname matching is
    /// intentionally replaced by the pin/anchor trust decision.
    static func evaluate(chain: [SecCertificate], anchor: SecCertificate) -> Bool {
        guard !chain.isEmpty else { return false }
        let policy = SecPolicyCreateSSL(true, nil)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, policy, &trust) == errSecSuccess,
              let trust else {
            return false
        }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil)
    }
}

/// Builds NWParameters for a TLS connection whose certificate trust decision is
/// replaced by a pinned CA chain, with an exact SHA-256 leaf pin as fallback.
///
/// When both `leafPin` and `caCertBase64` are nil (pairing discovery via GET
/// /health) the handshake is accepted but the observed leaf pin is recorded, so
/// the caller can show it and pin subsequent connections.
enum PinnedTLS {
    static let defaultConnectTimeout: TimeInterval = 15

    static func parameters(
        leafPin: String?,
        caCertBase64: String? = nil,
        capture: PinCapture?,
        connectTimeout: TimeInterval = defaultConnectTimeout
    ) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let expected = PinFormat.normalize(leafPin)
        let anchor = CATrust.certificate(fromBase64: caCertBase64)
        let securityOptions = tls.securityProtocolOptions
        // Xcode 27 SDK: sec_protocol_verify_t = (metadata, trust_ref, complete).
        sec_protocol_options_set_verify_block(securityOptions, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                complete(false)
                return
            }
            let der = SecCertificateCopyData(leaf) as Data
            let actual = PinFormat.sha256Hex(der)
            capture?.record(actual)
            // v0.1.1 C: a chain issued by the pinned CA wins, so a re-issued leaf
            // (SAN change / expiry / new key) neither breaks TLS nor re-pairs.
            if let anchor, CATrust.evaluate(chain: chain, anchor: anchor) {
                complete(true)
                return
            }
            // Fallback: exact leaf pin (pre-C pairing credentials, pairing-time
            // bootstrap, or a plugin that does not expose a CA certificate yet).
            if let expected {
                complete(actual == expected)
            } else {
                complete(true)
            }
        }, DispatchQueue.global(qos: .userInitiated))
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(max(1, connectTimeout))
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowFastOpen = false
        return parameters
    }
}
