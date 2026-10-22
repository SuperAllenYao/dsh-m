import XCTest
@testable import DSHm

/// M2a remote-relay server config parsing/persistence and pairing-payload
/// `relay`/candidate handling (design §5.4).
final class M2RelayConfigTests: XCTestCase {

    private let pinHex = String(repeating: "ab", count: 32)
    private var pinBase64URL: String { Data(repeating: 0xAB, count: 32).base64URLEncodedString }
    private var fingerprint: String {
        stride(from: 0, to: 64, by: 2).map { offset -> String in
            let start = pinHex.index(pinHex.startIndex, offsetBy: offset)
            let end = pinHex.index(start, offsetBy: 2)
            return String(pinHex[start..<end]).uppercased()
        }.joined(separator: ":")
    }

    private func payload(_ json: String) -> PairingPayload {
        guard let payload = PairingPayload.parse(json) else {
            fatalError("bad payload fixture")
        }
        return payload
    }

    private func defaults() -> UserDefaults {
        let suite = "com.dshm.tests.m2relay." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - dshm-relay:// parsing

    func testParseRelayConfigWithBase64URLPin() {
        let text = "dshm-relay://203.0.113.10:443?pin=\(pinBase64URL)&v=1"
        guard case .success(let config) = RelayServerConfig.parse(text) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(config.origin, "https://203.0.113.10:443")
        XCTAssertEqual(config.pin, pinHex, "base64url pin is normalized to lowercase hex")
        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.host, "203.0.113.10")
        XCTAssertEqual(config.port, 443)
        XCTAssertEqual(config.displayTarget, "203.0.113.10:443")
    }

    func testParseRelayConfigWithFingerprintHexPin() {
        let text = "dshm-relay://relay.example.com:8443?pin=\(fingerprint)&v=1"
        guard case .success(let config) = RelayServerConfig.parse(text) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(config.pin, pinHex)
        XCTAssertEqual(config.origin, "https://relay.example.com:8443")
        XCTAssertEqual(config.port, 8443)
    }

    func testParseRelayConfigDefaultsPort443AndRequiresVersion1() {
        guard case .success(let config) = RelayServerConfig.parse("dshm-relay://203.0.113.10?pin=\(pinBase64URL)") else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(config.port, 443)
        guard case .failure(let error) = RelayServerConfig.parse(
            "dshm-relay://203.0.113.10:443?pin=\(pinBase64URL)&v=2"
        ) else {
            return XCTFail("expected version failure")
        }
        XCTAssertEqual(error, .unsupportedVersion("2"))
    }

    func testParseRelayConfigFailures() {
        guard case .failure(let missingPin) = RelayServerConfig.parse("dshm-relay://203.0.113.10:443?v=1") else {
            return XCTFail("expected missing pin")
        }
        XCTAssertEqual(missingPin, .missingPin)

        guard case .failure(let invalidPin) = RelayServerConfig.parse(
            "dshm-relay://203.0.113.10:443?pin=not-a-pin&v=1"
        ) else {
            return XCTFail("expected invalid pin")
        }
        XCTAssertEqual(invalidPin, .invalidPin)

        guard case .failure(let invalidPort) = RelayServerConfig.parse(
            "dshm-relay://203.0.113.10:0?pin=\(pinBase64URL)"
        ) else {
            return XCTFail("expected invalid port")
        }
        XCTAssertEqual(invalidPort, .invalidPort("0"))

        guard case .failure(let missingHost) = RelayServerConfig.parse("dshm-relay://?pin=\(pinBase64URL)") else {
            return XCTFail("expected missing host")
        }
        XCTAssertEqual(missingHost, .missingHost)
        XCTAssertFalse(missingHost.message.isEmpty)
    }

    func testNonRelayTextIsNotParsedAsRelayConfig() {
        XCTAssertNil(RelayServerConfig.parse("https://203.0.113.10:443?pin=\(pinBase64URL)"))
        XCTAssertNil(RelayServerConfig.parse("{\"v\":1}"))
        XCTAssertFalse(RelayServerConfig.looksLikeRelayConfig("https://example.com"))
        XCTAssertTrue(RelayServerConfig.looksLikeRelayConfig("  dshm-relay://host:443?pin=x"))
    }

    // MARK: - payload `relay` object (design §5.4)

    func testPayloadRelayObjectParses() {
        let value = TestJSON.value("""
        {"origin":"https://203.0.113.10:30001/","pin":"\(pinBase64URL)","v":1}
        """)
        let config = RelayServerConfig.parse(relayObject: value)
        XCTAssertEqual(config?.origin, "https://203.0.113.10:30001")
        XCTAssertEqual(config?.pin, pinHex)
        XCTAssertEqual(config?.version, 1)
        XCTAssertNil(RelayServerConfig.parse(relayObject: TestJSON.value(#"{"origin":"https://x"}"#)))
        XCTAssertNil(RelayServerConfig.parse(relayObject: TestJSON.value(
            #"{"origin":"https://x:443","pin":"\#(pinBase64URL)","v":2}"#
        )), "unsupported schema version is ignored")
    }

    func testPayloadWithRelayDecodesAndAddsCandidateOrigin() {
        let parsed = payload("""
        {"v":1,"origins":["https://127.0.0.1:3466","https://192.168.1.10:3466"],
         "endpoints":[{"url":"https://192.168.1.10:3466","kind":"lan","pri":10}],
         "relay":{"origin":"https://203.0.113.10:30001","pin":"\(pinBase64URL)","v":1},
         "pair":{"token":"t","exp":1893456000}}
        """)
        XCTAssertEqual(parsed.relay?.origin, "https://203.0.113.10:30001")
        let candidates = PairingOriginSelector.candidates(payload: parsed, allowLoopback: false)
        XCTAssertEqual(candidates.map(\.host), ["192.168.1.10", "203.0.113.10"],
                       "relay bridge origin joins the reconnect candidates")
        let legacy = payload(#"{"v":1,"origins":["https://192.168.1.10:3466"]}"#)
        XCTAssertNil(legacy.relay, "payloads without a relay block keep working")
    }

    func testCaptureFromPayloadSavesRelayConfig() {
        let defaults = defaults()
        let parsed = payload("""
        {"v":1,"origins":["https://192.168.1.10:3466"],
         "relay":{"origin":"https://203.0.113.10:30001","pin":"\(pinBase64URL)","v":1}}
        """)
        let captured = RelayConfigStore.capture(from: parsed, defaults: defaults)
        XCTAssertEqual(captured?.origin, "https://203.0.113.10:30001")
        XCTAssertEqual(RelayConfigStore.load(defaults: defaults), captured)
        XCTAssertNil(RelayConfigStore.capture(from: payload(#"{"v":1}"#), defaults: defaults))
        XCTAssertNotNil(RelayConfigStore.load(defaults: defaults), "no-op capture keeps the stored config")
    }

    // MARK: - reconnect candidate ordering (design §4.7)

    func testReconnectCandidatesTryCurrentThenAllStoredInOrder() {
        let candidates = PairingOriginSelector.reconnectCandidates(
            current: "https://192.168.1.10:3466",
            stored: [
                "https://192.168.1.10:3466/",
                "https://203.0.113.10:30001",
                "http://203.0.113.10:30001",
                "  ",
            ],
            allowLoopback: false
        )
        XCTAssertEqual(candidates.map(\.host), ["192.168.1.10", "203.0.113.10"])
    }

    func testReconnectCandidatesPreferRelayWhenCurrentIsRelay() {
        let candidates = PairingOriginSelector.reconnectCandidates(
            current: "https://203.0.113.10:30001",
            stored: ["https://192.168.1.10:3466", "https://203.0.113.10:30001"],
            allowLoopback: false
        )
        XCTAssertEqual(candidates.map(\.host), ["203.0.113.10", "192.168.1.10"],
                       "the working relay origin heads the next round")
        XCTAssertTrue(PairingOriginSelector.reconnectCandidates(current: nil, stored: nil, allowLoopback: false).isEmpty)
    }

    // MARK: - Store

    func testRelayConfigStoreRoundTrip() {
        let defaults = defaults()
        XCTAssertNil(RelayConfigStore.load(defaults: defaults))
        let config = RelayServerConfig(origin: "https://203.0.113.10:443", pin: pinHex, version: 1)
        XCTAssertTrue(RelayConfigStore.save(config, defaults: defaults))
        XCTAssertEqual(RelayConfigStore.load(defaults: defaults), config)
        XCTAssertTrue(RelayConfigStore.save(nil, defaults: defaults))
        XCTAssertNil(RelayConfigStore.load(defaults: defaults))
    }
}
