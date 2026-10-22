import Foundation

/// Test seam for the pairing-code flows: production implementation talks to the
/// Mac link-server over HTTPS, tests inject a fake.
protocol PairingCodeRedeeming {
    /// LAN flow (design §5.3): Bonjour-discovered Mac, TOFU TLS + pin check.
    func redeemOnLAN(mac: DiscoveredMac, code: String, deviceName: String) async throws -> PairingCodeRedemption

    /// Public flow (design §5.4): relay `/v1/lookup` + strict-pinned Mac origin.
    func redeemViaRelay(config: RelayServerConfig, code: String, deviceName: String) async throws -> PairingCodeRedemption
}

/// Network implementation of the M2a pairing-code flows.
struct PairingCodeRedeemer: PairingCodeRedeeming {
    func redeemOnLAN(mac: DiscoveredMac, code: String, deviceName: String) async throws -> PairingCodeRedemption {
        let http: (status: Int, json: JSONValue, observedLeafPin: String?)
        do {
            http = try await HTTPSClient.json(
                serviceEndpoint: mac.endpoint,
                hostHeader: mac.serviceName,
                method: "POST",
                path: "/pair/code/redeem",
                body: Self.redeemBody(code: code, deviceName: deviceName),
                leafPin: nil,
                timeout: 20
            )
        } catch let error as PairingCodeError {
            throw error
        } catch {
            throw PairingCodeError(.network(NetworkErrorInterpreter.message(for: error)))
        }
        do {
            let response = try PairingCodeProtocol.decodeRedeemResponse(
                status: http.status,
                json: http.json,
                observedLeafPin: http.observedLeafPin
            )
            return try PairingCodeProtocol.makeLANRedemption(response: response, deviceName: deviceName)
        } catch let error as PairingCodeError {
            throw error
        } catch {
            throw PairingCodeError(.network(NetworkErrorInterpreter.message(for: error)))
        }
    }

    func redeemViaRelay(config: RelayServerConfig, code: String, deviceName: String) async throws -> PairingCodeRedemption {
        guard let relayOrigin = config.originURL, relayOrigin.host != nil else {
            throw PairingCodeError(.network(L10n.t("远程服务器地址无效")))
        }
        let lookupHTTP: (status: Int, json: JSONValue, observedLeafPin: String?)
        do {
            lookupHTTP = try await HTTPSClient.json(
                origin: relayOrigin,
                method: "POST",
                path: "/v1/lookup",
                body: .object(["code": .string(code)]),
                leafPin: config.pin,
                timeout: 20
            )
        } catch {
            throw PairingCodeError(Self.lookupTransportFailure(error))
        }
        do {
            let lookup = try PairingCodeProtocol.decodeLookupResponse(
                status: lookupHTTP.status,
                json: lookupHTTP.json
            )
            guard let macPin = lookup.pinHex, !macPin.isEmpty else {
                throw PairingCodeError(.malformed(L10n.t("/v1/lookup 未返回有效证书 pin")))
            }
            // Strict pin: never TOFU here, the relay lookup pin is the trust anchor.
            let redeemHTTP: (status: Int, json: JSONValue, observedLeafPin: String?)
            do {
                redeemHTTP = try await HTTPSClient.json(
                    origin: lookup.origin,
                    method: "POST",
                    path: "/pair/code/redeem",
                    body: Self.redeemBody(code: code, deviceName: deviceName),
                    leafPin: macPin,
                    timeout: 20
                )
            } catch {
                throw PairingCodeError(Self.macTransportFailure(error))
            }
            let response = try PairingCodeProtocol.decodeRedeemResponse(
                status: redeemHTTP.status,
                json: redeemHTTP.json,
                observedLeafPin: redeemHTTP.observedLeafPin
            )
            return try PairingCodeProtocol.makePublicRedemption(
                response: response,
                lookup: lookup,
                deviceName: deviceName
            )
        } catch let error as PairingCodeError {
            throw error
        } catch {
            throw PairingCodeError(.network(NetworkErrorInterpreter.message(for: error)))
        }
    }

    // MARK: - Transport failure mapping

    /// A custom TLS verify-block rejection surfaces as `NWError.tls`; for the
    /// relay lookup that almost always means the saved server config pin does not
    /// match the server (design §5.4 / Lead relay contract).
    static func isTLSPinFailure(_ error: Error) -> Bool {
        let message = NetworkErrorInterpreter.message(for: error)
        return message.contains("TLS 握手失败") || message.contains("TLS handshake")
    }

    static func lookupTransportFailure(_ error: Error) -> PairingCodeFailure {
        if isTLSPinFailure(error) {
            return .network(L10n.t("服务器配置与服务器不匹配，请重新扫码/粘贴"))
        }
        return .network(L10n.f("无法连接远程服务器：%@", NetworkErrorInterpreter.message(for: error)))
    }

    static func macTransportFailure(_ error: Error) -> PairingCodeFailure {
        if isTLSPinFailure(error) {
            return .network(L10n.t("无法用 relay 返回的证书指纹连接 Mac，已拒绝连接"))
        }
        return .network(L10n.f("无法连接 Mac：%@", NetworkErrorInterpreter.message(for: error)))
    }

    /// `POST /pair/code/redeem` body (design §5.2). The device P-256 public key
    /// is the same one `/pair/redeem` binds credentials to.
    static func redeemBody(code: String, deviceName: String) -> JSONValue {
        .object([
            "code": .string(code),
            "devicePubKey": .string(DeviceIdentity.shared.publicKeyBase64URL),
            "deviceName": .string(deviceName),
            "platform": .string("ios"),
        ])
    }
}
