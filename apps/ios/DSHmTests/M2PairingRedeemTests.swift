import CryptoKit
import XCTest
@testable import DSHm

/// M2a trust decisions for `/pair/code/redeem` + `/v1/lookup`: pin consistency,
/// signed-payload verification and credential/candidate construction
/// (design §5.2–§5.4).
final class M2PairingRedeemTests: XCTestCase {

    // MARK: - Fixtures

    private let pinHex = String(repeating: "1a", count: 32)
    private let otherPinHex = String(repeating: "2b", count: 32)

    private func base64URLPin(_ hex: String) -> String {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return Data(bytes).base64URLEncodedString
    }

    private func fingerprint(_ hex: String) -> String {
        stride(from: 0, to: 64, by: 2).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return String(hex[start..<end]).uppercased()
        }.joined(separator: ":")
    }

    private struct SignedFixture {
        var payload: PairingPayload
        var payloadText: String
        var pinHex: String
    }

    /// Builds a signed `dsh-m.pair` payload with TLS pins and an optional relay
    /// block, then parses it exactly like the app does at runtime.
    private func makeSignedPayload(
        origins: [String],
        pinHex: String,
        relayOrigin: String? = nil,
        relayPinBase64URL: String? = nil,
        signed: Bool = true
    ) -> SignedFixture {
        let hostKey = Curve25519.Signing.PrivateKey()
        let hostPublic = hostKey.publicKey.rawRepresentation.base64URLEncodedString
        var unsigned: [String: JSONValue] = [
            "v": .int(1),
            "kind": .string("dsh-m.pair"),
            "host": .object([
                "id": .string("host-abcdef12"),
                "name": .string("Mac 测试"),
                "key": .string(hostPublic),
            ]),
            "mode": .string("lan"),
            "origins": .array(origins.map { .string($0) }),
            "endpoints": .array(origins.map {
                .object(["url": .string($0), "kind": .string("lan"), "pri": .int(10)])
            }),
            "tls": .object([
                "kind": .string("self-signed-ca"),
                "leafPin": .string(base64URLPin(pinHex)),
                "caPin": .string(base64URLPin(pinHex)),
                "leafFingerprint256": .string(fingerprint(pinHex)),
                "caFingerprint256": .string(fingerprint(pinHex)),
            ]),
            "pair": .object([
                "token": .string("tok-1"),
                "exp": .int(1_893_456_000),
                "proto": .string("dsh-m/1"),
            ]),
        ]
        if let relayOrigin, let relayPinBase64URL {
            unsigned["relay"] = .object([
                "origin": .string(relayOrigin),
                "pin": .string(relayPinBase64URL),
                "v": .int(1),
            ])
        }
        let canonical = try! CanonicalJSON.encode(.object(unsigned))
        if signed {
            let signature = try! hostKey.signature(for: Data(canonical.utf8))
            var signedObject = unsigned
            signedObject["sig"] = .string(signature.base64URLEncodedString)
            let text = try! CanonicalJSON.encode(.object(signedObject))
            let parsed = try! XCTUnwrap(PairingPayload.parse(text))
            return SignedFixture(payload: parsed, payloadText: text, pinHex: pinHex)
        }
        let text = canonical
        let parsed = try! XCTUnwrap(PairingPayload.parse(text))
        return SignedFixture(payload: parsed, payloadText: text, pinHex: pinHex)
    }

    private func redeemJSON(
        payloadText: String?,
        leafFingerprint256: String,
        leafPinBase64URL: String? = nil,
        devId: String = "dev-1",
        proto: String = "dsh-m/1"
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "ok": .bool(true),
            "deviceId": .string(devId),
            "deviceName": .string("iPhone"),
            "keyId": .string("key-1"),
            "credential": .string("credential-1234567890"),
            "proto": .string(proto),
            "server": .object([
                "hostId": .string("host-abcdef12"),
                "hostName": .string("Mac 测试"),
            ]),
            "tls": .object([
                "leafFingerprint256": .string(leafFingerprint256),
                "leafPin": .string(leafPinBase64URL ?? ""),
            ]),
        ]
        if let payloadText {
            object["payloadText"] = .string(payloadText)
        }
        return .object(object)
    }

    private func lookupJSON(
        origin: String = "https://203.0.113.10:30001",
        leafFingerprint256: String?,
        leafPinBase64URL: String? = nil,
        exp: Int64 = 1_893_456_000
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "ok": .bool(true),
            "hostId": .string("host-abcdef12"),
            "hostName": .string("Mac 测试"),
            "origin": .string(origin),
            "exp": .int(exp),
        ]
        if let leafFingerprint256 { object["leafFingerprint256"] = .string(leafFingerprint256) }
        if let leafPinBase64URL { object["leafPin"] = .string(leafPinBase64URL) }
        return .object(object)
    }

    // MARK: - Pin consistency (LAN TOFU)

    func testLANPinConsistencyAcceptsMatchingPins() {
        let check = PairingPinConsistency.validateLAN(
            observedPin: pinHex,
            responsePin: fingerprint(pinHex),
            payloadPin: base64URLPin(pinHex)
        )
        XCTAssertEqual(check, .ok(pin: pinHex))
    }

    func testLANPinConsistencyRequiresHandshakePin() {
        let check = PairingPinConsistency.validateLAN(
            observedPin: nil,
            responsePin: fingerprint(pinHex),
            payloadPin: nil
        )
        XCTAssertEqual(check, .failed(.missingHandshakePin))
    }

    func testLANPinConsistencyRejectsServerMismatch() {
        let check = PairingPinConsistency.validateLAN(
            observedPin: pinHex,
            responsePin: fingerprint(otherPinHex),
            payloadPin: nil
        )
        XCTAssertEqual(check, .failed(.responseMismatch(expected: pinHex, actual: otherPinHex)))
    }

    func testLANPinConsistencyRejectsPayloadMismatch() {
        let check = PairingPinConsistency.validateLAN(
            observedPin: pinHex,
            responsePin: fingerprint(pinHex),
            payloadPin: base64URLPin(otherPinHex)
        )
        XCTAssertEqual(check, .failed(.payloadMismatch(expected: pinHex, actual: otherPinHex)))
    }

    // MARK: - Pin consistency (public relay anchor)

    func testPublicPinConsistencyAcceptsLookupAnchor() {
        let check = PairingPinConsistency.validatePublic(
            lookupPin: base64URLPin(pinHex),
            observedPin: fingerprint(pinHex),
            responsePin: fingerprint(pinHex),
            payloadPin: fingerprint(pinHex)
        )
        XCTAssertEqual(check, .ok(pin: pinHex))
    }

    func testPublicPinConsistencyRejectsEachMismatch() {
        XCTAssertEqual(
            PairingPinConsistency.validatePublic(
                lookupPin: pinHex,
                observedPin: pinHex,
                responsePin: fingerprint(otherPinHex),
                payloadPin: nil
            ),
            .failed(.responseMismatch(expected: pinHex, actual: otherPinHex))
        )
        XCTAssertEqual(
            PairingPinConsistency.validatePublic(
                lookupPin: pinHex,
                observedPin: fingerprint(otherPinHex),
                responsePin: fingerprint(pinHex),
                payloadPin: nil
            ),
            .failed(.handshakeMismatch(expected: pinHex, actual: otherPinHex))
        )
        XCTAssertEqual(
            PairingPinConsistency.validatePublic(
                lookupPin: pinHex,
                observedPin: nil,
                responsePin: fingerprint(pinHex),
                payloadPin: fingerprint(otherPinHex)
            ),
            .failed(.payloadMismatch(expected: pinHex, actual: otherPinHex))
        )
        if case .failed(let failure) = PairingPinConsistency.validateLAN(
            observedPin: nil, responsePin: fingerprint(pinHex), payloadPin: nil
        ) {
            XCTAssertFalse(failure.detail.isEmpty)
        }
    }

    // MARK: - Response parsing

    func testRedeemResponseParsesTLSAndSignedPayload() throws {
        let fixture = makeSignedPayload(origins: ["https://192.168.1.10:3466"], pinHex: pinHex)
        let json = redeemJSON(payloadText: fixture.payloadText, leafFingerprint256: fingerprint(pinHex))
        let response = try PairingCodeProtocol.decodeRedeemResponse(
            status: 200,
            json: json,
            observedLeafPin: pinHex
        )
        XCTAssertEqual(response.deviceId, "dev-1")
        XCTAssertEqual(response.credential, "credential-1234567890")
        XCTAssertEqual(response.proto, "dsh-m/1")
        XCTAssertEqual(response.hostId, "host-abcdef12")
        XCTAssertEqual(response.tlsLeafPinHex, pinHex)
        XCTAssertEqual(response.observedLeafPin, pinHex)
        XCTAssertEqual(response.payload?.host?.name, "Mac 测试")
        XCTAssertTrue(PairingCodePayloadVerifier.verify(payload: response.payload))
    }

    func testRedeemResponseRejectsErrorStatusAndProto() {
        XCTAssertThrowsError(try PairingCodeProtocol.decodeRedeemResponse(
            status: 401,
            json: TestJSON.value(#"{"ok":false,"error":"code/invalid","remaining":4}"#),
            observedLeafPin: nil
        )) { error in
            XCTAssertEqual(error as? PairingCodeError, PairingCodeError(.invalid(remaining: 4)))
        }
        let fixture = makeSignedPayload(origins: ["https://192.168.1.10:3466"], pinHex: pinHex)
        XCTAssertThrowsError(try PairingCodeProtocol.decodeRedeemResponse(
            status: 200,
            json: redeemJSON(
                payloadText: fixture.payloadText,
                leafFingerprint256: fingerprint(pinHex),
                proto: "dsh-m/0"
            ),
            observedLeafPin: pinHex
        ))
    }

    func testLookupResponseParsing() throws {
        let withFingerprint = try PairingCodeProtocol.decodeLookupResponse(
            status: 200,
            json: lookupJSON(leafFingerprint256: fingerprint(pinHex))
        )
        XCTAssertEqual(withFingerprint.origin.absoluteString, "https://203.0.113.10:30001")
        XCTAssertEqual(withFingerprint.hostName, "Mac 测试")
        XCTAssertEqual(withFingerprint.pinHex, pinHex)

        let withLeafPin = try PairingCodeProtocol.decodeLookupResponse(
            status: 200,
            json: lookupJSON(leafFingerprint256: nil, leafPinBase64URL: base64URLPin(pinHex))
        )
        XCTAssertEqual(withLeafPin.pinHex, pinHex)

        XCTAssertThrowsError(try PairingCodeProtocol.decodeLookupResponse(
            status: 200,
            json: lookupJSON(leafFingerprint256: nil)
        ))
        XCTAssertThrowsError(try PairingCodeProtocol.decodeLookupResponse(
            status: 200,
            json: lookupJSON(origin: "http://203.0.113.10:30001", leafFingerprint256: fingerprint(pinHex))
        ))
        XCTAssertThrowsError(try PairingCodeProtocol.decodeLookupResponse(
            status: 404,
            json: TestJSON.value(#"{"ok":false,"error":"code/not-found"}"#)
        )) { error in
            XCTAssertEqual((error as? PairingCodeError)?.failure, .notFound)
        }
    }

    // MARK: - LAN redemption

    func testLANRedemptionBuildsCredentialsFromPayload() throws {
        let relayPin = String(repeating: "3c", count: 32)
        let fixture = makeSignedPayload(
            origins: ["https://192.168.1.10:3466"],
            pinHex: pinHex,
            relayOrigin: "https://203.0.113.10:30001",
            relayPinBase64URL: base64URLPin(relayPin)
        )
        let response = try PairingCodeProtocol.decodeRedeemResponse(
            status: 200,
            json: redeemJSON(payloadText: fixture.payloadText, leafFingerprint256: fingerprint(pinHex)),
            observedLeafPin: pinHex
        )
        let redemption = try PairingCodeProtocol.makeLANRedemption(response: response, deviceName: "iPhone")
        XCTAssertEqual(redemption.credentials.origin, "https://192.168.1.10:3466")
        XCTAssertEqual(redemption.credentials.leafPin, pinHex)
        XCTAssertEqual(redemption.credentials.deviceId, "dev-1")
        XCTAssertEqual(redemption.credentials.originCandidates?.first, "https://192.168.1.10:3466")
        XCTAssertTrue(redemption.credentials.originCandidates?.contains("https://203.0.113.10:30001") == true,
                      "relay bridge origin is stored as a reconnect candidate")
        XCTAssertEqual(redemption.relay?.origin, "https://203.0.113.10:30001")
        XCTAssertEqual(redemption.relay?.pin, relayPin)
    }

    func testLANRedemptionRejectsPinMismatch() throws {
        let fixture = makeSignedPayload(origins: ["https://192.168.1.10:3466"], pinHex: pinHex)
        let json = redeemJSON(payloadText: fixture.payloadText, leafFingerprint256: fingerprint(pinHex))
        let response = try PairingCodeProtocol.decodeRedeemResponse(
            status: 200,
            json: json,
            observedLeafPin: otherPinHex
        )
        XCTAssertThrowsError(try PairingCodeProtocol.makeLANRedemption(response: response, deviceName: "iPhone")) { error in
            guard let failure = (error as? PairingCodeError)?.failure,
                  case .pinMismatch = failure else {
                return XCTFail("expected pinMismatch, got \(error)")
            }
        }
    }

    func testLANRedemptionRejectsUnsignedPayload() throws {
        let fixture = makeSignedPayload(origins: ["https://192.168.1.10:3466"], pinHex: pinHex, signed: false)
        let json = redeemJSON(payloadText: fixture.payloadText, leafFingerprint256: fingerprint(pinHex))
        let response = try PairingCodeProtocol.decodeRedeemResponse(
            status: 200,
            json: json,
            observedLeafPin: pinHex
        )
        XCTAssertThrowsError(try PairingCodeProtocol.makeLANRedemption(response: response, deviceName: "iPhone")) { error in
            XCTAssertEqual((error as? PairingCodeError)?.failure, .signatureInvalid)
        }
    }

    // MARK: - Public redemption

    func testPublicRedemptionPrefersRelayMacOriginAndKeepsLANFallback() throws {
        let fixture = makeSignedPayload(
            origins: ["https://192.168.1.10:3466"],
            pinHex: pinHex,
            relayOrigin: "https://203.0.113.10:30001",
            relayPinBase64URL: base64URLPin(pinHex)
        )
        let lookup = try PairingCodeProtocol.decodeLookupResponse(
            status: 200,
            json: lookupJSON(leafFingerprint256: fingerprint(pinHex))
        )
        let response = try PairingCodeProtocol.decodeRedeemResponse(
            status: 200,
            json: redeemJSON(payloadText: fixture.payloadText, leafFingerprint256: fingerprint(pinHex)),
            observedLeafPin: pinHex
        )
        let redemption = try PairingCodeProtocol.makePublicRedemption(
            response: response,
            lookup: lookup,
            deviceName: "iPhone"
        )
        XCTAssertEqual(redemption.credentials.origin, "https://203.0.113.10:30001",
                       "public pairing prefers the relay-reachable Mac origin")
        XCTAssertEqual(redemption.credentials.originCandidates?.first, "https://203.0.113.10:30001")
        XCTAssertTrue(redemption.credentials.originCandidates?.contains("https://192.168.1.10:3466") == true,
                      "LAN origin stays as a fallback candidate")
        XCTAssertEqual(redemption.credentials.leafPin, pinHex)
        XCTAssertEqual(redemption.relay?.origin, "https://203.0.113.10:30001")
    }

    func testPublicRedemptionRejectsLookupResponseMismatch() throws {
        let fixture = makeSignedPayload(
            origins: ["https://192.168.1.10:3466"],
            pinHex: pinHex,
            relayOrigin: "https://203.0.113.10:30001",
            relayPinBase64URL: base64URLPin(pinHex)
        )
        let lookup = try PairingCodeProtocol.decodeLookupResponse(
            status: 200,
            json: lookupJSON(leafFingerprint256: fingerprint(pinHex))
        )
        let response = try PairingCodeProtocol.decodeRedeemResponse(
            status: 200,
            json: redeemJSON(payloadText: fixture.payloadText, leafFingerprint256: fingerprint(otherPinHex)),
            observedLeafPin: otherPinHex
        )
        XCTAssertThrowsError(try PairingCodeProtocol.makePublicRedemption(
            response: response,
            lookup: lookup,
            deviceName: "iPhone"
        )) { error in
            XCTAssertEqual((error as? PairingCodeError)?.failure.isPinMismatch, true)
        }
    }

    func testPublicRedemptionRequiresSignedPayload() throws {
        let lookup = try PairingCodeProtocol.decodeLookupResponse(
            status: 200,
            json: lookupJSON(leafFingerprint256: fingerprint(pinHex))
        )
        let response = try PairingCodeProtocol.decodeRedeemResponse(
            status: 200,
            json: redeemJSON(payloadText: nil, leafFingerprint256: fingerprint(pinHex)),
            observedLeafPin: pinHex
        )
        XCTAssertThrowsError(try PairingCodeProtocol.makePublicRedemption(
            response: response,
            lookup: lookup,
            deviceName: "iPhone"
        ))
    }

    func testOriginNormalizationDropsTrailingSlash() {
        XCTAssertEqual(
            PairingCodeProtocol.normalizedOrigin(URL(string: "https://192.168.1.10:3466/")!),
            "https://192.168.1.10:3466"
        )
    }
}

private extension PairingCodeFailure {
    var isPinMismatch: Bool {
        if case .pinMismatch = self { return true }
        return false
    }
}
