import Network
import XCTest
@testable import DSHm

/// M2a pairing-code input state machine, error mapping and the LAN/relay flow
/// model (design §5.3/§5.4/§5.6).
@MainActor
final class M2PairingCodeTests: XCTestCase {

    // MARK: - Fixtures

    private func makeMac(_ id: String, hostName: String? = nil) -> DiscoveredMac {
        let name = hostName ?? "Mac " + id
        return DiscoveredMac(
            hostId: id,
            hostName: name,
            serviceName: id + "-service",
            txt: ["hostId": id, "hostName": name, "proto": "dsh-m/1", "pair": "code"],
            endpoint: .service(name: id, type: "_dshm._tcp", domain: "local.", interface: nil),
            relayOrigin: nil
        )
    }

    private func makeRedemption(
        origin: String = "https://192.168.1.10:3466",
        pin: String = String(repeating: "ab", count: 32),
        relay: RelayServerConfig? = nil
    ) -> PairingCodeRedemption {
        PairingCodeRedemption(
            credentials: PairingCredentials(
                origin: origin,
                leafPin: pin,
                deviceId: "dev-1",
                credential: "cred-1234567890",
                deviceName: "iPhone",
                pairedAt: 1,
                keyId: "key-1",
                originCandidates: [origin]
            ),
            payload: nil,
            relay: relay
        )
    }

    private func testDefaults() -> UserDefaults {
        let suite = "com.dshm.tests.m2code." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    // MARK: - PairingCodeInput

    func testInputSanitizesToEightDigits() {
        var input = PairingCodeInput()
        XCTAssertEqual(input.digits, "")
        let completed = input.update("12ab34-567890xyz")
        XCTAssertTrue(completed, "8 digits reached on this update")
        XCTAssertEqual(input.digits, "12345678")
        XCTAssertTrue(input.isComplete)
        XCTAssertEqual(input.grouped, "1234 5678")
    }

    func testInputCompletionEdgeOnlyOnce() {
        var input = PairingCodeInput()
        XCTAssertFalse(input.update("1234567"))
        XCTAssertFalse(input.isComplete)
        XCTAssertTrue(input.update("12345678"), "8th digit reports completion")
        XCTAssertFalse(input.update("12345678"), "already complete: no second auto-submit edge")
        XCTAssertFalse(input.update("123456789"), "extra digits are dropped")
        XCTAssertEqual(input.digits, "12345678")
    }

    func testInputDeletionAndClear() {
        var input = PairingCodeInput()
        input.update("12345678")
        XCTAssertTrue(input.isComplete)
        XCTAssertFalse(input.update("1234567"), "deletion is not a completion edge")
        XCTAssertFalse(input.isComplete)
        input.clear()
        XCTAssertTrue(input.isEmpty)
        XCTAssertEqual(input.grouped, "")
    }

    func testInputIgnoresNonASCIIDigits() {
        var input = PairingCodeInput()
        input.update("１２３٤٥67")
        XCTAssertEqual(input.digits, "67", "only ASCII 0-9 are accepted")
    }

    // MARK: - Error mapping

    private func json(_ text: String) -> JSONValue {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            fatalError("bad fixture JSON")
        }
        return value
    }

    func testRedeemFailureMapping() {
        XCTAssertEqual(
            PairingCodeErrorMapper.redeemFailure(status: 401, json: json(#"{"ok":false,"error":"code/invalid","remaining":3}"#)),
            .invalid(remaining: 3)
        )
        XCTAssertEqual(
            PairingCodeErrorMapper.redeemFailure(status: 410, json: json(#"{"ok":false,"error":"code/expired"}"#)),
            .expired
        )
        XCTAssertEqual(
            PairingCodeErrorMapper.redeemFailure(status: 423, json: json(#"{"ok":false,"error":"code/locked"}"#)),
            .locked
        )
        XCTAssertEqual(
            PairingCodeErrorMapper.redeemFailure(status: 429, json: json(#"{"ok":false,"error":"code/rate-limited"}"#)),
            .rateLimited
        )
        XCTAssertEqual(
            PairingCodeErrorMapper.redeemFailure(status: 503, json: json(#"{"ok":false,"error":"host/inactive"}"#)),
            .hostInactive
        )
        XCTAssertEqual(
            PairingCodeErrorMapper.redeemFailure(status: 503, json: json(#"{"ok":false,"error":"contract/pending"}"#)),
            .contractPending
        )
        XCTAssertEqual(
            PairingCodeErrorMapper.redeemFailure(status: 500, json: json(#"{"ok":false,"message":"boom"}"#)),
            .malformed("HTTP 500 · boom")
        )
    }

    func testLookupFailureMapping() {
        XCTAssertEqual(
            PairingCodeErrorMapper.lookupFailure(status: 404, json: json(#"{"ok":false,"error":"code/not-found"}"#)),
            .notFound
        )
        XCTAssertEqual(
            PairingCodeErrorMapper.lookupFailure(status: 410, json: json(#"{"ok":false,"error":"code/expired"}"#)),
            .expired
        )
        XCTAssertEqual(
            PairingCodeErrorMapper.lookupFailure(status: 429, json: json(#"{"ok":false,"error":"rate-limited"}"#)),
            .rateLimited
        )
        XCTAssertEqual(
            PairingCodeErrorMapper.lookupFailure(status: 429, json: json(#"{"ok":false}"#)),
            .rateLimited,
            "status fallback when the error field is missing"
        )
        XCTAssertEqual(PairingCodeFailure.invalid(remaining: 2).keepsCode, true)
        XCTAssertEqual(PairingCodeFailure.locked.keepsCode, false)
        XCTAssertEqual(PairingCodeFailure.expired.keepsCode, false)
        XCTAssertFalse(PairingCodeFailure.invalid(remaining: 2).message.isEmpty)
    }

    func testNotFoundAndExpiredHaveDistinctCopy() {
        // Relay contract (Lead / task-1): 404 and 410 must be distinguishable.
        XCTAssertNotEqual(PairingCodeFailure.notFound.message, PairingCodeFailure.expired.message)
        XCTAssertTrue(PairingCodeFailure.notFound.message.contains("未连接服务器"))
        XCTAssertTrue(PairingCodeFailure.expired.message.contains("过期"))
    }

    func testRelayTransportFailureMapping() {
        // A custom TLS verify block rejection (~pin mismatch) must tell the user to
        // re-scan the server config instead of a generic network error.
        let tlsFailure = LinkError.transport(
            "连接 203.0.113.10:443 等待中：TLS 握手失败（OSStatus -9802）：请确认桌面端在线"
        )
        XCTAssertTrue(PairingCodeRedeemer.isTLSPinFailure(tlsFailure))
        let lookupFailure = PairingCodeRedeemer.lookupTransportFailure(tlsFailure)
        XCTAssertTrue(lookupFailure.message.contains("服务器配置与服务器不匹配"))
        let macFailure = PairingCodeRedeemer.macTransportFailure(tlsFailure)
        XCTAssertTrue(macFailure.message.contains("已拒绝连接"))

        let timeoutFailure = LinkError.transport("连接 203.0.113.10:443 失败：连接 Mac 超时（code: 60）")
        XCTAssertFalse(PairingCodeRedeemer.isTLSPinFailure(timeoutFailure))
        XCTAssertTrue(PairingCodeRedeemer.lookupTransportFailure(timeoutFailure).message.contains("无法连接远程服务器"))
    }

    // MARK: - Discovery parsing

    func testDiscoveredMacTXT() {
        let mac = DiscoveredMac.parse(
            serviceName: "Mac-abcdef12",
            txt: [
                "hostId": "abcdef1234567890",
                "hostName": "Studio Mac",
                "proto": "dsh-m/1",
                "pair": "code",
                "relay": "https://203.0.113.10:30001",
            ],
            endpoint: .service(name: "Mac-abcdef12", type: "_dshm._tcp", domain: "local.", interface: nil)
        )
        let unwrapped = try? XCTUnwrap(mac)
        XCTAssertEqual(unwrapped?.hostId, "abcdef1234567890")
        XCTAssertEqual(unwrapped?.displayName, "Studio Mac")
        XCTAssertEqual(unwrapped?.supportsPairingCode, true)
        XCTAssertEqual(unwrapped?.protocolVersion, "dsh-m/1")
        XCTAssertEqual(unwrapped?.relayOrigin, "https://203.0.113.10:30001")
    }

    func testDiscoveredMacRequiresHostIdAndFallsBackToServiceName() {
        XCTAssertNil(DiscoveredMac.parse(
            serviceName: "No-TXT",
            txt: [:],
            endpoint: .service(name: "No-TXT", type: "_dshm._tcp", domain: "local.", interface: nil)
        ))
        let mac = DiscoveredMac.parse(
            serviceName: "Mac-23456789",
            txt: ["hostId": "23456789abcd"],
            endpoint: .service(name: "Mac-23456789", type: "_dshm._tcp", domain: "local.", interface: nil)
        )
        XCTAssertEqual(mac?.displayName, "Mac-23456789")
    }

    func testDiscoveryDeduplicatesAndSorts() {
        let a = makeMac("aaaa1111", hostName: "Zeta")
        let b = makeMac("bbbb2222", hostName: "Alpha")
        let duplicate = makeMac("aaaa1111", hostName: "Zeta")
        let result = BonjourDiscovery.deduplicate([a, b, duplicate])
        XCTAssertEqual(result.map(\.hostId), ["bbbb2222", "aaaa1111"])
    }

    // MARK: - Flow model (LAN)

    func testLANSingleMacAutoSelectedAndCodeAutoSubmits() async throws {
        let discovery = FakeDiscovery()
        let redeemer = FakeRedeemer()
        let redemption = makeRedemption()
        redeemer.redemption = redemption
        let defaults = testDefaults()
        let model = PairingCodeFlowModel(redeemer: redeemer, discovery: discovery, defaults: defaults)

        model.start()
        XCTAssertEqual(discovery.startCount, 1)
        let mac = makeMac("aaaa1111")
        discovery.publish([mac])
        XCTAssertEqual(model.discoveryState, .found(1))
        XCTAssertEqual(model.selectedMacId, mac.id, "single Mac is auto-selected")
        XCTAssertEqual(model.route, .lan(mac))

        var paired: PairingCodeRedemption?
        model.onRedemption = { paired = $0 }
        model.updateCode("12345678")
        await waitUntil { redeemer.lanCalls.count == 1 }
        XCTAssertEqual(redeemer.lanCalls.first, "12345678")
        XCTAssertEqual(redeemer.lastLANMac?.hostId, mac.id)
        XCTAssertEqual(paired?.credentials.deviceId, "dev-1")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(redeemer.relayCalls.count, 0)

        // Re-setting the same complete text must not submit twice.
        model.updateCode("12345678")
        await Task.yield()
        XCTAssertEqual(redeemer.lanCalls.count, 1, "auto-submit fires exactly once per completion edge")
        model.stop()
    }

    func testMultipleMacsRequireExplicitSelection() async throws {
        let discovery = FakeDiscovery()
        let redeemer = FakeRedeemer()
        redeemer.redemption = makeRedemption()
        let model = PairingCodeFlowModel(redeemer: redeemer, discovery: discovery, defaults: testDefaults())
        model.start()
        let m1 = makeMac("aaaa1111")
        let m2 = makeMac("bbbb2222")
        discovery.publish([m1, m2])
        XCTAssertEqual(model.discoveryState, .found(2))
        XCTAssertNil(model.selectedMacId, "multiple Macs must not auto-select")
        XCTAssertEqual(model.route, .none)

        model.updateCode("12345678")
        await Task.yield()
        XCTAssertEqual(model.failure, .selectionRequired, "must ask the user, never try codes one by one")
        XCTAssertEqual(redeemer.lanCalls.count, 0)
        XCTAssertEqual(model.code.isComplete, true, "code stays so the user can submit after choosing")

        model.selectMac(m2.id)
        await waitUntil { redeemer.lanCalls.count == 1 }
        XCTAssertEqual(redeemer.lastLANMac?.hostId, m2.id)
        XCTAssertEqual(model.selectedMacId, m2.id)
        XCTAssertEqual(model.phase, .idle)
        model.stop()
    }

    func testInvalidCodeKeepsDigitsAndShowsRemainingAttempts() async throws {
        let discovery = FakeDiscovery()
        let redeemer = FakeRedeemer()
        redeemer.lanError = PairingCodeError(.invalid(remaining: 2))
        let model = PairingCodeFlowModel(redeemer: redeemer, discovery: discovery, defaults: testDefaults())
        model.start()
        discovery.publish([makeMac("aaaa1111")])
        model.updateCode("12345678")
        await waitUntil { model.failure != nil }
        XCTAssertEqual(model.failure, .invalid(remaining: 2))
        XCTAssertEqual(model.attemptsLeft, 2)
        XCTAssertEqual(model.code.digits, "12345678", "invalid code keeps the digits for a quick retry")
        XCTAssertEqual(model.canSubmit, true)
        model.stop()
    }

    func testLockedCodeClearsInput() async throws {
        let discovery = FakeDiscovery()
        let redeemer = FakeRedeemer()
        redeemer.lanError = PairingCodeError(.locked)
        let model = PairingCodeFlowModel(redeemer: redeemer, discovery: discovery, defaults: testDefaults())
        model.start()
        discovery.publish([makeMac("aaaa1111")])
        model.updateCode("12345678")
        await waitUntil { model.failure != nil }
        XCTAssertEqual(model.failure, .locked)
        XCTAssertTrue(model.code.isEmpty, "a locked code is unusable: clear the field")
        model.stop()
    }

    // MARK: - Flow model (relay)

    func testNoMacWithRelayConfigUsesPublicLookupAndCapturesRelay() async throws {
        let discovery = FakeDiscovery()
        let redeemer = FakeRedeemer()
        let defaults = testDefaults()
        let relay = RelayServerConfig(
            origin: "https://203.0.113.10:443",
            pin: String(repeating: "cd", count: 32),
            version: 1
        )
        RelayConfigStore.save(relay, defaults: defaults)
        let advertised = RelayServerConfig(
            origin: "https://203.0.113.10:30001",
            pin: String(repeating: "ef", count: 32),
            version: 1
        )
        redeemer.redemption = makeRedemption(origin: "https://203.0.113.10:30001", relay: advertised)
        let model = PairingCodeFlowModel(redeemer: redeemer, discovery: discovery, defaults: defaults)
        model.start()
        XCTAssertEqual(model.relayConfig, relay, "stored relay config is loaded")
        discovery.publish([])
        XCTAssertEqual(model.route, .relay(relay), "no LAN Mac -> relay fallback")

        model.updateCode("87654321")
        await waitUntil { redeemer.relayCalls.count == 1 }
        XCTAssertEqual(redeemer.relayCalls.first, "87654321")
        XCTAssertEqual(redeemer.lanCalls.count, 0)
        XCTAssertEqual(RelayConfigStore.load(defaults: defaults), advertised,
                       "relay advertised by the signed payload is persisted")
        model.stop()
    }

    func testExplicitRelayPreferenceOverridesVisibleLANMac() async throws {
        let discovery = FakeDiscovery()
        let redeemer = FakeRedeemer()
        let defaults = testDefaults()
        let relay = RelayServerConfig(
            origin: "https://203.0.113.10:443",
            pin: String(repeating: "cd", count: 32),
            version: 1
        )
        RelayConfigStore.save(relay, defaults: defaults)
        redeemer.redemption = makeRedemption()
        let model = PairingCodeFlowModel(redeemer: redeemer, discovery: discovery, defaults: defaults)
        model.start()
        discovery.publish([makeMac("aaaa1111")])
        model.useRelay()
        XCTAssertEqual(model.route, .relay(relay))
        model.updateCode("12345678")
        await waitUntil { redeemer.relayCalls.count == 1 }
        XCTAssertEqual(redeemer.lanCalls.count, 0)
        model.stop()
    }

    func testNoTargetFailureWhenNoMacAndNoRelay() async throws {
        let discovery = FakeDiscovery()
        let redeemer = FakeRedeemer()
        let model = PairingCodeFlowModel(redeemer: redeemer, discovery: discovery, defaults: testDefaults())
        model.start()
        discovery.publish([])
        XCTAssertEqual(model.route, .none)
        model.updateCode("12345678")
        await Task.yield()
        XCTAssertEqual(model.failure, .noTarget)
        XCTAssertEqual(redeemer.lanCalls.count, 0)
        XCTAssertEqual(redeemer.relayCalls.count, 0)
        model.stop()
    }

    func testPrefillDoesNotAutoSubmit() async throws {
        let discovery = FakeDiscovery()
        let redeemer = FakeRedeemer()
        redeemer.redemption = makeRedemption()
        let model = PairingCodeFlowModel(redeemer: redeemer, discovery: discovery, defaults: testDefaults())
        model.start()
        discovery.publish([makeMac("aaaa1111")])
        model.prefillCode("11112222")
        await Task.yield()
        XCTAssertEqual(model.code.digits, "11112222")
        XCTAssertEqual(redeemer.lanCalls.count, 0, "prefill must not submit; the user/E2E still types")
        model.stop()
    }
}

// MARK: - Fakes

@MainActor
private final class FakeDiscovery: PairingDiscovering {
    var macs: [DiscoveredMac] = []
    var onChange: (([DiscoveredMac]) -> Void)?
    var startCount = 0
    var stopCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }

    func publish(_ macs: [DiscoveredMac]) {
        self.macs = macs
        onChange?(macs)
    }
}

private final class FakeRedeemer: PairingCodeRedeeming {
    var lanCalls: [String] = []
    var relayCalls: [String] = []
    var lastLANMac: DiscoveredMac?
    var lastRelayConfig: RelayServerConfig?
    var lanError: Error?
    var relayError: Error?
    var redemption = PairingCodeRedemption(
        credentials: PairingCredentials(
            origin: "https://192.168.1.10:3466",
            leafPin: String(repeating: "ab", count: 32),
            deviceId: "dev-1",
            credential: "cred",
            deviceName: "iPhone",
            pairedAt: 1,
            keyId: nil,
            originCandidates: nil
        ),
        payload: nil,
        relay: nil
    )

    func redeemOnLAN(mac: DiscoveredMac, code: String, deviceName: String) async throws -> PairingCodeRedemption {
        lanCalls.append(code)
        lastLANMac = mac
        if let lanError { throw lanError }
        return redemption
    }

    func redeemViaRelay(config: RelayServerConfig, code: String, deviceName: String) async throws -> PairingCodeRedemption {
        relayCalls.append(code)
        lastRelayConfig = config
        if let relayError { throw relayError }
        return redemption
    }
}
