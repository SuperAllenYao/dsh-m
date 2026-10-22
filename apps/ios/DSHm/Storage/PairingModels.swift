import Foundation
import Security
import UIKit

/// Persisted pairing state (Keychain). Never contains the process launch token —
/// only the device credential minted by the link plugin's /pair/redeem.
struct PairingCredentials: Codable, Equatable {
    var origin: String
    var leafPin: String
    /// v0.1.1 C: pinned CA certificate (base64 DER) learned at pair time or via
    /// the one-shot `/health` migration. Nil = pre-C pairing that still trusts the
    /// exact leaf pin; keeping it optional makes old persisted credentials decode.
    var caCertBase64: String?
    var deviceId: String
    var credential: String
    var deviceName: String
    var pairedAt: Int64
    var keyId: String?
    /// All reachable origins from the pairing payload (non-loopback first), used
    /// for reconnect fallback when the current origin is unreachable.
    var originCandidates: [String]?
    /// P1: plugin single-WSS capability captured at pairing
    /// (`/health.features.muxRpc` or a `proto` list containing "dsh-m/2").
    /// Nil = old plugin / pre-P1 pairing (legacy path only).
    var supportsMuxRPC: Bool?
    /// P1: in-band auth tickets (seeded by pair/redeem, rotated by `welcome`).
    /// Opaque strings; never logged and never put in URLs.
    var connectTickets: [String]?
    /// P1: resume cursor for `hello{resume}` — epoch + last applied server sid.
    var p1Epoch: String?
    var p1Sid: Int?
    /// Mac 的稳定 hostId（配对载荷 `host.id` / 配对码兑换响应的 hostId）。
    /// 运行期 mDNS 自愈用它确认「广播的是同一台 Mac」；旧凭据为 nil。
    var hostId: String? = nil

    var originURL: URL? { URL(string: origin) }
}

// MARK: - QR payload schema (dsh-m-link M1, signed JCS payload)

struct PairingEndpoint: Codable, Equatable {
    var url: String?
    var kind: String?
    var pri: Int?
    var trust: String?
    var pin: String?
}

struct PairingHost: Codable, Equatable {
    var id: String?
    var name: String?
    var key: String?
}

struct PairingTLS: Codable, Equatable {
    var kind: String?
    var caPin: String?
    var leafPin: String?
    var caFingerprint256: String?
    var leafFingerprint256: String?
    var leafNotAfter: String?
    /// v0.1.1 C: the plugin's public CA certificate (base64 DER). The phone
    /// anchors TLS trust on this long-lived certificate, so a re-issued leaf
    /// (SAN change / expiry / manual rotation) never forces a re-pair. Optional:
    /// pre-C plugins omit it and the app falls back to the leaf pin.
    var caCert: String?
}

struct PairingToken: Codable, Equatable {
    var id: String?
    var token: String?
    var exp: Int64?
    var proto: String?
    var caps: JSONValue?
}

/// Optional top-level relay block (M2a design §5.4): written by the Mac plugin
/// once its tunnel is ready, so a LAN-paired phone learns the relay TLS pin
/// (which is not part of the per-endpoint pins).
struct PairingRelay: Codable, Equatable {
    var origin: String?
    var pin: String?
    var v: Int?
}

/// Signed QR payload:
/// { v, kind:"dsh-m.pair", host{id,name,key}, mode, origins[], endpoints[],
///   tls{kind,caPin,leafPin,caFingerprint256,leafFingerprint256,leafNotAfter},
///   pair{id,token,exp,proto,caps}, sig }
/// The legacy M0 flat shape ({origins,caPin,leafPin,pairToken,exp}) is still
/// accepted for backward-compatible manual pairing.
struct PairingPayload: Codable, Equatable {
    var v: Int?
    var kind: String?
    var host: PairingHost?
    var mode: String?
    var origins: [String]?
    var endpoints: [PairingEndpoint]?
    var tls: PairingTLS?
    var pair: PairingToken?
    /// M2a: relay server metadata for public pairing/reconnect fallback.
    var relay: PairingRelay?
    var sig: String?

    // Legacy M0 flat fields
    var origin: String?
    var caPin: String?
    var leafPin: String?
    var pairToken: String?
    var exp: Int64?
    var deviceNameHint: String?

    /// Original payload text (used for Ed25519 signature verification; not coded).
    var rawText: String?

    enum CodingKeys: String, CodingKey {
        case v, kind, host, mode, origins, endpoints, tls, pair, relay, sig
        case origin, caPin, leafPin, pairToken, exp, deviceNameHint
    }

    var bestOrigin: String? {
        if let url = endpoints?.compactMap({ $0.url }).first(where: { !$0.isEmpty }) { return url }
        if let origin = origins?.first(where: { !$0.isEmpty }) { return origin }
        return origin
    }

    var token: String? { pair?.token ?? pairToken }

    var proto: String? { pair?.proto }

    var hostName: String? { host?.name }

    /// pair.exp is epoch seconds (M1); legacy exp is epoch milliseconds (M0).
    var expiresAtMillis: Int64? {
        if let seconds = pair?.exp { return seconds * 1000 }
        return exp
    }

    var isExpired: Bool {
        guard let expiresAtMillis else { return false }
        return Int64(Date().timeIntervalSince1970 * 1000) > expiresAtMillis
    }

    /// TLS leaf pin (normalized lowercase hex) from either the fingerprint256 or
    /// the base64url SHA-256 forms.
    var tlsLeafPinHex: String? {
        if let pin = PinFormat.normalize(tls?.leafFingerprint256) { return pin }
        if let pin = PinFormat.hexFromBase64URL(tls?.leafPin) { return pin }
        if let pin = PinFormat.normalize(leafPin) { return pin }
        if let pin = PinFormat.hexFromBase64URL(leafPin) { return pin }
        if let pin = PinFormat.normalize(tls?.caFingerprint256) { return pin }
        if let pin = PinFormat.hexFromBase64URL(tls?.caPin) { return pin }
        return PinFormat.normalize(caPin)
    }

    var tlsCAPinHex: String? {
        if let pin = PinFormat.normalize(tls?.caFingerprint256) { return pin }
        if let pin = PinFormat.hexFromBase64URL(tls?.caPin) { return pin }
        return PinFormat.normalize(caPin)
    }

    /// v0.1.1 C: public CA certificate (base64 DER) carried by the signed payload.
    /// Base64 decoding lives in `PinnedTLS`/`CATrust`; here we only surface the
    /// wire string (signed material, trusted once the payload signature verifies).
    var tlsCACertBase64: String? {
        guard let caCert = tls?.caCert, !caCert.isEmpty else { return nil }
        return caCert
    }

    var isSigned: Bool { sig != nil && host?.key != nil }

    /// Verifies the host Ed25519 signature over the JCS payload (M1 trust anchor).
    func verifyHostSignature() -> Bool {
        guard let rawText else { return false }
        return HostSignature.verify(payloadText: rawText)
    }

    static func parse(_ text: String) -> PairingPayload? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        guard var payload = try? JSONDecoder().decode(PairingPayload.self, from: data) else { return nil }
        payload.rawText = trimmed
        return payload
    }

    /// Manual code path: origin + one-time pair token (+ optional pin).
    static func manual(origin: String, pairToken: String, pin: String?, deviceNameHint: String? = nil) -> PairingPayload {
        var payload = PairingPayload()
        payload.v = 1
        payload.origins = [origin]
        payload.origin = origin
        payload.pairToken = pairToken
        payload.leafPin = pin
        payload.deviceNameHint = deviceNameHint
        return payload
    }
}

/// Keychain-backed storage for device credentials.
final class CredentialStore {
    private let service = "com.dshm.app.pairing"
    private let account = "device-credentials"

    func save(_ credentials: PairingCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        #if targetEnvironment(simulator)
        // Unsigned simulator builds (CODE_SIGNING_ALLOWED=NO) may not get Keychain
        // entitlements; keep a simulator-only fallback so relaunch/reconnect E2E
        // works. Device builds use Keychain only.
        try? data.write(to: Self.fallbackURL, options: [.atomic])
        NSLog("[DSHm] keychain save status=%d (simulator fallback file used)", status)
        #else
        guard status == errSecSuccess else {
            throw LinkError.transport("Keychain 写入失败 (OSStatus \(status))")
        }
        #endif
    }

    func load() -> PairingCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let credentials = try? JSONDecoder().decode(PairingCredentials.self, from: data) {
            return credentials
        }
        #if targetEnvironment(simulator)
        if let data = try? Data(contentsOf: Self.fallbackURL),
           let credentials = try? JSONDecoder().decode(PairingCredentials.self, from: data) {
            return credentials
        }
        #endif
        return nil
    }

    private static var fallbackURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("pairing-credentials.json")
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        #if targetEnvironment(simulator)
        try? FileManager.default.removeItem(at: Self.fallbackURL)
        #endif
    }
}

/// Lightweight non-secret preferences.
enum AppSettings {
    private static let defaults = UserDefaults.standard

    static var lastOrigin: String {
        get { defaults.string(forKey: "lastOrigin") ?? "https://127.0.0.1:3488" }
        set { defaults.set(newValue, forKey: "lastOrigin") }
    }

    static var deviceName: String {
        get { defaults.string(forKey: "deviceName") ?? UIDevice.current.name }
        set { defaults.set(newValue, forKey: "deviceName") }
    }

    static var showSystemMessages: Bool {
        get { defaults.bool(forKey: "showSystemMessages") }
        set { defaults.set(newValue, forKey: "showSystemMessages") }
    }

    /// P1 (single-WSS transport) rollout switch. Default **off** = legacy dual-TLS.
    /// `DSHM_PROTO_V2` env override for E2E/bench: "1"/"true" force on, "0" force
    /// off (explicit rollback without a rebuild).
    static var remoteProtocolV2: Bool {
        if let raw = ProcessInfo.processInfo.environment["DSHM_PROTO_V2"]?.lowercased() {
            return raw == "1" || raw == "true" || raw == "on"
        }
        return defaults.bool(forKey: "remoteProtocolV2")
    }

    static func setRemoteProtocolV2(_ enabled: Bool) {
        defaults.set(enabled, forKey: "remoteProtocolV2")
    }
}
