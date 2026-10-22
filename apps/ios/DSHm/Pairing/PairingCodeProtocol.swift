import Foundation

/// Normalizes certificate pins from any wire representation the Mac plugin /
/// relay use: `fingerprint256` (uppercase colon hex, certificate DER) or the
/// SPKI/DER `pin` field (base64url SHA-256, 43 chars).
enum PairingPinFormat {
    static func pin(from raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let hex = PinFormat.normalize(raw) { return hex }
        return PinFormat.hexFromBase64URL(raw)
    }

    static func short(_ pin: String) -> String {
        String(pin.prefix(16)) + "…"
    }
}

/// Decoded 200 envelope of `POST /pair/code/redeem` (Mac link-server, design §5.2).
struct PairingCodeRedeemResponse: Equatable {
    var deviceId: String
    var deviceName: String?
    var keyId: String?
    var credential: String
    var proto: String?
    /// Full signed pairing payload (same shape as the QR payload) when present.
    var payload: PairingPayload?
    /// JCS payload text the plugin signed (Ed25519 trust anchor).
    var payloadText: String?
    /// Certificate DER SHA-256 reported in `tls.leafFingerprint256`/`tls.leafPin`.
    var tlsLeafPinHex: String?
    /// CA fingerprint from the response `tls` object (SPKI or DER form).
    var tlsCAPinHex: String?
    /// v0.1.1 C: public CA certificate (base64 DER) from the response `tls`
    /// object. The signed payload is preferred; this is the fallback for hosts
    /// that only expose it in the redeem response.
    var tlsCACertBase64: String?
    var hostId: String?
    var hostName: String?
    /// Leaf DER SHA-256 observed during the handshake (TOFU capture / strict check).
    var observedLeafPin: String?

    static func parse(json: JSONValue, observedLeafPin: String?) -> PairingCodeRedeemResponse? {
        guard let deviceId = json["deviceId"]?.stringValue, !deviceId.isEmpty,
              let credential = json["credential"]?.stringValue, !credential.isEmpty else {
            return nil
        }
        var payload = json["payloadText"]?.stringValue.flatMap(PairingPayload.parse)
        if payload == nil, let payloadObject = json["payload"],
           let data = try? payloadObject.encodedData() {
            payload = PairingPayload.parse(String(data: data, encoding: .utf8) ?? "")
        }
        let tls = json["tls"]
        let response = PairingCodeRedeemResponse(
            deviceId: deviceId,
            deviceName: json["deviceName"]?.stringValue,
            keyId: json["keyId"]?.stringValue,
            credential: credential,
            proto: json["proto"]?.stringValue,
            payload: payload,
            payloadText: json["payloadText"]?.stringValue,
            tlsLeafPinHex: PairingPinFormat.pin(from: tls?["leafFingerprint256"]?.stringValue)
                ?? PairingPinFormat.pin(from: tls?["leafPin"]?.stringValue),
            tlsCAPinHex: PairingPinFormat.pin(from: tls?["caFingerprint256"]?.stringValue)
                ?? PairingPinFormat.pin(from: tls?["caPin"]?.stringValue),
            tlsCACertBase64: tls?["caCert"]?.stringValue,
            hostId: json["server"]?["hostId"]?.stringValue,
            hostName: json["server"]?["hostName"]?.stringValue,
            observedLeafPin: observedLeafPin
        )
        return response
    }
}

/// Decoded 200 envelope of relay `POST /v1/lookup` (design §5.4).
struct RelayLookupResponse: Equatable {
    var hostId: String?
    var hostName: String?
    var origin: URL
    var leafPinEncoded: String?
    var leafFingerprint256: String?
    var exp: Int64?

    /// Normalized certificate pin (lowercase hex) used for the strict Mac TLS
    /// connection and for the consistency check against the redeem response.
    var pinHex: String? {
        PairingPinFormat.pin(from: leafFingerprint256) ?? PairingPinFormat.pin(from: leafPinEncoded)
    }

    static func parse(json: JSONValue) -> RelayLookupResponse? {
        guard let originText = json["origin"]?.stringValue,
              let origin = URL(string: originText),
              origin.scheme?.lowercased() == "https",
              let host = origin.host, !host.isEmpty else {
            return nil
        }
        let response = RelayLookupResponse(
            hostId: json["hostId"]?.stringValue,
            hostName: json["hostName"]?.stringValue,
            origin: origin,
            leafPinEncoded: json["leafPin"]?.stringValue,
            leafFingerprint256: json["leafFingerprint256"]?.stringValue,
            exp: json["exp"]?.intValue
        )
        guard response.pinHex != nil else { return nil }
        return response
    }
}

/// Outcomes of the pin consistency checks (design §5.3 step 4 / §5.4 step 3).
enum PairingPinCheckResult: Equatable {
    case ok(pin: String)
    case failed(PairingPinCheckFailure)
}

enum PairingPinCheckFailure: Equatable {
    case missingHandshakePin
    case missingServerPin
    case responseMismatch(expected: String, actual: String)
    case handshakeMismatch(expected: String, actual: String)
    case payloadMismatch(expected: String, actual: String)

    var detail: String {
        switch self {
        case .missingHandshakePin:
            return L10n.t("未捕获到桌面端证书指纹")
        case .missingServerPin:
            return L10n.t("配对响应缺少证书指纹")
        case .responseMismatch(let expected, let actual):
            return L10n.f("服务器响应指纹不一致（期望 %@，实际 %@）",
                          PairingPinFormat.short(expected), PairingPinFormat.short(actual))
        case .handshakeMismatch(let expected, let actual):
            return L10n.f("TLS 握手指纹不一致（期望 %@，实际 %@）",
                          PairingPinFormat.short(expected), PairingPinFormat.short(actual))
        case .payloadMismatch(let expected, let actual):
            return L10n.f("配对载荷指纹不一致（期望 %@，实际 %@）",
                          PairingPinFormat.short(expected), PairingPinFormat.short(actual))
        }
    }
}

/// First-trust anchor for pairing codes. The code is a weak secret, so the pin
/// comparison is what actually prevents a transparent MITM from relaying the
/// redeem call to the real Mac under a different certificate.
enum PairingPinConsistency {
    /// LAN: TLS is TOFU (`leafPin: nil`). The handshake-observed DER fingerprint
    /// must match the pin the Mac reports, and the signed payload's pin must
    /// agree as well.
    static func validateLAN(observedPin: String?, responsePin: String?, payloadPin: String?) -> PairingPinCheckResult {
        guard let observed = PairingPinFormat.pin(from: observedPin) else {
            return .failed(.missingHandshakePin)
        }
        guard let server = PairingPinFormat.pin(from: responsePin) else {
            return .failed(.missingServerPin)
        }
        guard observed == server else {
            return .failed(.responseMismatch(expected: observed, actual: server))
        }
        if let payload = PairingPinFormat.pin(from: payloadPin), payload != server {
            return .failed(.payloadMismatch(expected: server, actual: payload))
        }
        // Design §5.3 step 4: the signed payload pins are authoritative for the
        // saved credentials; TOFU observed == pinned here, so both are equal.
        return .ok(pin: PairingPinFormat.pin(from: payloadPin) ?? observed)
    }

    /// Public: the relay lookup pin is the trust anchor. The strict TLS connection
    /// to the Mac origin, the redeem response and the signed payload must all
    /// carry that same pin.
    static func validatePublic(lookupPin: String?, observedPin: String?, responsePin: String?, payloadPin: String?) -> PairingPinCheckResult {
        guard let lookup = PairingPinFormat.pin(from: lookupPin) else {
            return .failed(.missingServerPin)
        }
        guard let server = PairingPinFormat.pin(from: responsePin) else {
            return .failed(.missingServerPin)
        }
        guard server == lookup else {
            return .failed(.responseMismatch(expected: lookup, actual: server))
        }
        if let observed = PairingPinFormat.pin(from: observedPin), observed != lookup {
            return .failed(.handshakeMismatch(expected: lookup, actual: observed))
        }
        if let payload = PairingPinFormat.pin(from: payloadPin), payload != lookup {
            return .failed(.payloadMismatch(expected: lookup, actual: payload))
        }
        return .ok(pin: lookup)
    }
}

/// Successful code redemption: credentials to persist plus payload metadata the
/// app can act on (relay config advertised by the Mac).
struct PairingCodeRedemption: Equatable {
    var credentials: PairingCredentials
    var payload: PairingPayload?
    var relay: RelayServerConfig?
}

/// Pure protocol layer between the HTTP transport and the app: envelope decoding,
/// trusted-pin decisions, payload signature verification and credential building.
enum PairingCodeProtocol {
    static let proto = "dsh-m/1"

    // MARK: - Envelopes

    static func decodeRedeemResponse(
        status: Int,
        json: JSONValue,
        observedLeafPin: String?
    ) throws -> PairingCodeRedeemResponse {
        guard status == 200, json["ok"]?.boolValue == true else {
            throw PairingCodeError(PairingCodeErrorMapper.redeemFailure(status: status, json: json))
        }
        guard let response = PairingCodeRedeemResponse.parse(json: json, observedLeafPin: observedLeafPin) else {
            throw PairingCodeError(.malformed(L10n.t("/pair/code/redeem 响应缺少 deviceId/credential")))
        }
        if let proto = response.proto, proto != Self.proto {
            throw PairingCodeError(.malformed(L10n.f("桌面端插件协议版本不匹配（%@）", proto)))
        }
        return response
    }

    static func decodeLookupResponse(status: Int, json: JSONValue) throws -> RelayLookupResponse {
        guard status == 200, json["ok"]?.boolValue == true else {
            throw PairingCodeError(PairingCodeErrorMapper.lookupFailure(status: status, json: json))
        }
        guard let response = RelayLookupResponse.parse(json: json) else {
            throw PairingCodeError(.malformed(L10n.t("/v1/lookup 响应缺少 origin/pin")))
        }
        return response
    }

    // MARK: - Credentials

    /// LAN pairing: origin/candidates come from the signed payload (the Bonjour
    /// SRV/A records are consumed by the transport connection, not persisted).
    static func makeLANRedemption(
        response: PairingCodeRedeemResponse,
        deviceName: String
    ) throws -> PairingCodeRedemption {
        guard let payload = response.payload else {
            throw PairingCodeError(.malformed(L10n.t("配对响应缺少签名载荷")))
        }
        guard PairingCodePayloadVerifier.verify(payload: payload) else {
            throw PairingCodeError(.signatureInvalid)
        }
        let pinCheck = PairingPinConsistency.validateLAN(
            observedPin: response.observedLeafPin,
            responsePin: response.tlsLeafPinHex,
            payloadPin: payload.tlsLeafPinHex
        )
        let pin: String
        switch pinCheck {
        case .ok(let accepted): pin = accepted
        case .failed(let failure): throw PairingCodeError(.pinMismatch(failure.detail))
        }
        let candidates = PairingOriginSelector.candidates(payload: payload)
        guard let origin = candidates.first else {
            throw PairingCodeError(.malformed(L10n.t("配对载荷没有可用的 Mac 地址")))
        }
        return PairingCodeRedemption(
            credentials: credentials(
                origin: origin,
                candidates: candidates,
                pin: pin,
                response: response,
                deviceName: deviceName,
                caCertBase64: payload.tlsCACertBase64 ?? response.tlsCACertBase64
            ),
            payload: payload,
            relay: RelayServerConfig.from(payloadRelay: payload.relay)
        )
    }

    /// Public pairing: the relay lookup pin is authoritative and the Mac origin
    /// is preferred for reconnects; all payload candidates (LAN + relay) follow.
    static func makePublicRedemption(
        response: PairingCodeRedeemResponse,
        lookup: RelayLookupResponse,
        deviceName: String
    ) throws -> PairingCodeRedemption {
        guard let payload = response.payload else {
            throw PairingCodeError(.malformed(L10n.t("配对响应缺少签名载荷")))
        }
        guard PairingCodePayloadVerifier.verify(payload: payload) else {
            throw PairingCodeError(.signatureInvalid)
        }
        let pinCheck = PairingPinConsistency.validatePublic(
            lookupPin: lookup.pinHex,
            observedPin: response.observedLeafPin,
            responsePin: response.tlsLeafPinHex,
            payloadPin: payload.tlsLeafPinHex
        )
        let pin: String
        switch pinCheck {
        case .ok(let accepted): pin = accepted
        case .failed(let failure): throw PairingCodeError(.pinMismatch(failure.detail))
        }
        let candidates = publicCandidates(payload: payload, macOrigin: lookup.origin)
        guard let preferred = candidates.first else {
            throw PairingCodeError(.malformed(L10n.t("配对结果没有可用的 Mac 地址")))
        }
        return PairingCodeRedemption(
            credentials: credentials(
                origin: preferred,
                candidates: candidates,
                pin: pin,
                response: response,
                deviceName: deviceName,
                caCertBase64: payload.tlsCACertBase64 ?? response.tlsCACertBase64
            ),
            payload: payload,
            relay: RelayServerConfig.from(payloadRelay: payload.relay)
        )
    }

    /// Candidates for a public pairing: the relay-provided Mac origin first, then
    /// every origin from the signed payload (LAN + relay).
    static func publicCandidates(payload: PairingPayload, macOrigin: URL) -> [URL] {
        var strings = [macOrigin.absoluteString]
        strings.append(contentsOf: PairingOriginSelector.candidates(payload: payload).map(\.absoluteString))
        return PairingOriginSelector.candidates(
            from: strings,
            allowLoopback: !PairingOriginSelector.isPhysicalDevice
        )
    }

    static func credentials(
        origin: URL,
        candidates: [URL],
        pin: String,
        response: PairingCodeRedeemResponse,
        deviceName: String,
        caCertBase64: String? = nil
    ) -> PairingCredentials {
        var ordered: [String] = []
        var seen = Set<String>()
        for url in [origin] + candidates {
            let normalized = normalizedOrigin(url)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }
        return PairingCredentials(
            origin: normalizedOrigin(origin),
            leafPin: pin,
            caCertBase64: caCertBase64,
            deviceId: response.deviceId,
            credential: response.credential,
            deviceName: deviceName,
            pairedAt: Int64(Date().timeIntervalSince1970 * 1000),
            keyId: response.keyId,
            originCandidates: ordered
        )
    }

    static func normalizedOrigin(_ url: URL) -> String {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// Verifies the Ed25519 signature over the redeem response's pairing payload.
enum PairingCodePayloadVerifier {
    static func verify(payload: PairingPayload?) -> Bool {
        guard let payload, payload.isSigned, payload.host?.key != nil else { return false }
        return payload.verifyHostSignature()
    }
}
