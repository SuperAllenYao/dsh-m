import Foundation

/// App-side configuration of the user's self-hosted DSH-m relay server (M2a).
///
/// Wire form, printed once by `dshm-relay init` and scanned/pasted by the user:
/// `dshm-relay://<host>:<port>?pin=<b64url cert DER sha256>&v=1`
///
/// The pin is the SHA-256 of the relay leaf certificate **DER** (the same pin
/// format `HTTPSClient`/`PinnedTLS` consumes). It is not a secret, but it must be
/// validated before any lookup call: a wrong pin makes the TLS handshake fail
/// closed instead of trusting an impostor relay.
struct RelayServerConfig: Codable, Equatable {
    /// Normalized `https://<host>:<port>` control/lookup origin.
    var origin: String
    /// Lowercase hex SHA-256 of the relay leaf certificate DER.
    var pin: String
    /// Config schema version (`v` query item); M2a understands `1` only.
    var version: Int

    var originURL: URL? { URL(string: origin) }
    var host: String? { originURL?.host }
    var port: UInt16? { originURL.flatMap { UInt16($0.port ?? 443) } }
    var displayTarget: String {
        guard let host, let port else { return origin }
        return "\(host):\(port)"
    }
    var shortPin: String { String(pin.prefix(16)) + "…" }

    static let scheme = "dshm-relay"
    static let supportedVersion = 1

    static func looksLikeRelayConfig(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix(scheme + "://")
    }

    /// Parses a `dshm-relay://` string. Returns nil when the text is not a relay
    /// config at all (callers fall back to pairing-payload parsing); an invalid
    /// relay config returns a failure with a localized reason.
    static func parse(_ text: String) -> Result<RelayServerConfig, RelayConfigError>? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeRelayConfig(trimmed) else { return nil }
        guard var components = URLComponents(string: trimmed) else {
            return .failure(.malformed)
        }
        guard let rawHost = components.host,
              !rawHost.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(.missingHost)
        }
        let port: Int
        if let parsedPort = components.port {
            guard parsedPort > 0, parsedPort <= 65_535 else {
                return .failure(.invalidPort(String(parsedPort)))
            }
            port = parsedPort
        } else {
            port = 443
        }
        let queryItems = components.queryItems ?? []
        let pinText = queryItems.first(where: { $0.name == "pin" })?.value
        guard let pinText, !pinText.isEmpty else { return .failure(.missingPin) }
        let pin: String
        if let normalized = PinFormat.normalize(pinText) {
            pin = normalized
        } else if let fromBase64URL = PinFormat.hexFromBase64URL(pinText) {
            pin = fromBase64URL
        } else {
            return .failure(.invalidPin)
        }
        var version = supportedVersion
        if let versionText = queryItems.first(where: { $0.name == "v" })?.value, !versionText.isEmpty {
            guard let parsed = Int(versionText) else { return .failure(.unsupportedVersion(versionText)) }
            guard parsed == supportedVersion else { return .failure(.unsupportedVersion(versionText)) }
            version = parsed
        }
        components.scheme = "https"
        components.port = port
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let originURL = components.url else { return .failure(.malformed) }
        var origin = originURL.absoluteString
        while origin.hasSuffix("/") { origin.removeLast() }
        return .success(RelayServerConfig(origin: origin, pin: pin, version: version))
    }

    /// Builds a config from the optional top-level `relay` object the Mac plugin
    /// embeds in the signed pairing payload (`{origin,pin,v}`).
    static func parse(relayObject value: JSONValue?) -> RelayServerConfig? {
        guard let object = value?.objectValue else { return nil }
        guard let origin = object["origin"]?.stringValue,
              let pinText = object["pin"]?.stringValue,
              !origin.isEmpty, !pinText.isEmpty else { return nil }
        let pin: String
        if let normalized = PinFormat.normalize(pinText) {
            pin = normalized
        } else if let fromBase64URL = PinFormat.hexFromBase64URL(pinText) {
            pin = fromBase64URL
        } else {
            return nil
        }
        var normalizedOrigin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalizedOrigin.hasSuffix("/") { normalizedOrigin.removeLast() }
        guard let url = URL(string: normalizedOrigin),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        let version = object["v"]?.intValue.map(Int.init) ?? supportedVersion
        guard version == supportedVersion else { return nil }
        return RelayServerConfig(origin: normalizedOrigin, pin: pin, version: version)
    }

    /// Builds a config from a parsed unsigned `PairingRelay` payload field.
    static func from(payloadRelay relay: PairingRelay?) -> RelayServerConfig? {
        guard let relay else { return nil }
        var object: [String: JSONValue] = [:]
        if let origin = relay.origin { object["origin"] = .string(origin) }
        if let pin = relay.pin { object["pin"] = .string(pin) }
        if let version = relay.v { object["v"] = .int(Int64(version)) }
        return parse(relayObject: .object(object))
    }
}

enum RelayConfigError: Error, Equatable {
    case missingHost
    case invalidPort(String)
    case missingPin
    case invalidPin
    case unsupportedVersion(String)
    case malformed

    var message: String {
        switch self {
        case .missingHost:
            return L10n.t("服务器配置缺少地址（host）")
        case .invalidPort(let value):
            return L10n.f("服务器配置端口无效：%@", value)
        case .missingPin:
            return L10n.t("服务器配置缺少证书 pin")
        case .invalidPin:
            return L10n.t("服务器配置证书 pin 格式不正确")
        case .unsupportedVersion(let value):
            return L10n.f("服务器配置版本不支持：%@", value)
        case .malformed:
            return L10n.t("服务器配置格式不正确")
        }
    }
}

/// Non-secret persistence for the configured relay server (UserDefaults).
enum RelayConfigStore {
    static let key = "relayServerConfig"

    static func load(defaults: UserDefaults = .standard) -> RelayServerConfig? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RelayServerConfig.self, from: data)
    }

    @discardableResult
    static func save(_ config: RelayServerConfig?, defaults: UserDefaults = .standard) -> Bool {
        guard let config else {
            defaults.removeObject(forKey: key)
            return true
        }
        guard let data = try? JSONEncoder().encode(config) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    /// Saves the relay config advertised by a freshly paired Mac's signed payload
    /// (design §5.4: the tunnel origin's TLS pin is only available through this
    /// optional `relay` object). Returns the captured config, if any.
    @discardableResult
    static func capture(from payload: PairingPayload, defaults: UserDefaults = .standard) -> RelayServerConfig? {
        guard let config = RelayServerConfig.from(payloadRelay: payload.relay) else { return nil }
        save(config, defaults: defaults)
        return config
    }
}
