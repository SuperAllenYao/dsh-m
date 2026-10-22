import Network
import XCTest
@testable import DSHm

final class PairingOriginFallbackTests: XCTestCase {

    private func payload(_ json: String) -> PairingPayload {
        guard let payload = PairingPayload.parse(json) else {
            fatalError("bad fixture")
        }
        return payload
    }

    func testPhysicalDeviceFiltersLoopbackAndKeepsLan() {
        let fixture = payload("""
        {"v":1,"origins":["https://127.0.0.1:3466","https://192.168.1.10:3466","http://localhost:3466"],
         "endpoints":[{"url":"https://127.0.0.1:3466"},{"url":"https://10.0.0.7:3466"}]}
        """)
        let candidates = PairingOriginSelector.candidates(payload: fixture, allowLoopback: false)
        XCTAssertEqual(candidates.map(\.host), ["192.168.1.10", "10.0.0.7"], "loopback must be filtered on device")
        XCTAssertFalse(candidates.contains { PairingOriginSelector.isLoopbackHost($0.host) })
    }

    func testSimulatorKeepsLoopbackLast() {
        let fixture = payload("""
        {"v":1,"origins":["https://127.0.0.1:3499","https://192.168.1.10:3499"]}
        """)
        let candidates = PairingOriginSelector.candidates(payload: fixture, allowLoopback: true)
        XCTAssertEqual(candidates.map(\.host), ["192.168.1.10", "127.0.0.1"], "non-loopback first, loopback fallback last")
    }

    func testLoopbackOnlyOnDeviceYieldsNoCandidates() {
        let fixture = payload("""
        {"v":1,"origins":["https://127.0.0.1:3466"],"endpoints":[{"url":"https://localhost:3466"}]}
        """)
        XCTAssertTrue(PairingOriginSelector.candidates(payload: fixture, allowLoopback: false).isEmpty)
        // …and the simulator keeps them for local development.
        XCTAssertEqual(PairingOriginSelector.candidates(payload: fixture, allowLoopback: true).count, 2)
    }

    func testCandidateDeduplicationAndSchemeFiltering() {
        let candidates = PairingOriginSelector.candidates(
            from: ["https://192.168.1.10:3466", "https://192.168.1.10:3466/", "http://192.168.1.11:3466", "  "],
            allowLoopback: false
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.host, "192.168.1.10")
    }

    func testConnectionRefusedIsReadableAndKeepsCode() {
        let message = NetworkErrorInterpreter.message(posixCode: 61, detail: "Connection refused")
        XCTAssertTrue(message.contains("无法连接 Mac"))
        XCTAssertTrue(message.contains("拒绝"))
        XCTAssertTrue(message.contains("61"), "raw code must be kept for diagnostics")
    }

    func testTimeoutMessage() {
        let message = NetworkErrorInterpreter.message(posixCode: 60, detail: "Operation timed out")
        XCTAssertTrue(message.contains("超时"))
        XCTAssertTrue(message.contains("60"))
    }

    func testNWErrorPosixMapping() {
        let message = NetworkErrorInterpreter.message(for: NWError.posix(.ECONNREFUSED))
        XCTAssertTrue(message.contains("code: 61"))
    }

    func testCredentialsOriginCandidatesDecodeBackwardsCompatible() throws {
        let legacy = """
        {"origin":"https://192.168.1.10:3466","leafPin":"aa","deviceId":"d","credential":"c","deviceName":"iPhone","pairedAt":1}
        """
        let credentials = try JSONDecoder().decode(PairingCredentials.self, from: Data(legacy.utf8))
        XCTAssertNil(credentials.originCandidates, "old Keychain records decode without candidates")

        let modern = """
        {"origin":"https://192.168.1.10:3466","leafPin":"aa","deviceId":"d","credential":"c","deviceName":"iPhone","pairedAt":1,
         "originCandidates":["https://192.168.1.10:3466","https://10.0.0.7:3466"]}
        """
        let upgraded = try JSONDecoder().decode(PairingCredentials.self, from: Data(modern.utf8))
        XCTAssertEqual(upgraded.originCandidates?.count, 2)
    }

    // MARK: - M2b P1-②: learned candidates from /health (manual pairing)

    private func healthJSON(_ json: String) -> JSONValue {
        guard let value = try? JSONValue.jsonObject(from: Data(json.utf8)) else {
            fatalError("bad health fixture")
        }
        return value
    }

    private func manualCandidates(_ origin: String) -> [URL] {
        let payload = PairingPayload.manual(origin: origin, pairToken: "pair-token", pin: nil)
        return PairingOriginSelector.candidates(payload: payload, allowLoopback: false)
    }

    private func mergedCandidates(
        current: URL,
        base: [URL],
        relay: String? = nil,
        health: JSONValue
    ) -> [String] {
        LinkService.mergeOriginCandidates(
            currentOrigin: current,
            payloadCandidates: base,
            relayOrigin: relay,
            healthDeviceEndpoints: LinkService.healthDeviceEndpoints(from: health)
        )
    }

    func testManualPairingLearnsLanAndRelayCandidates() {
        let origin = URL(string: "https://192.168.1.10:3466")!
        let merged = mergedCandidates(
            current: origin,
            base: manualCandidates("https://192.168.1.10:3466"),
            health: healthJSON("""
            {"ok":true,"ready":true,
             "deviceEndpoints":["https://192.168.1.10:3466","https://203.0.113.10:30001"]}
            """)
        )
        XCTAssertEqual(
            merged,
            ["https://192.168.1.10:3466", "https://203.0.113.10:30001"],
            "manual pairing must learn LAN + relay bridge origins from /health"
        )
    }

    func testLearnedCandidatesFilterLoopbackEndpoints() {
        let origin = URL(string: "https://192.168.1.10:3466")!
        let merged = mergedCandidates(
            current: origin,
            base: manualCandidates("https://192.168.1.10:3466"),
            relay: "https://127.0.0.1:3466",
            health: healthJSON("""
            {"deviceEndpoints":["https://127.0.0.1:3466","https://localhost:3466",
                                "https://[::1]:3466","http://192.168.1.11:3466",
                                "https://203.0.113.10:30001"]}
            """)
        )
        XCTAssertEqual(merged, ["https://192.168.1.10:3466", "https://203.0.113.10:30001"])
        XCTAssertFalse(merged.contains { url in
            URL(string: url).map { PairingOriginSelector.isLoopbackHost($0.host) } ?? false
        }, "loopback learned endpoints must never be persisted")
    }

    func testLearnedCandidatesDeduplicateAndNormalizeTrailingSlash() {
        let merged = mergedCandidates(
            current: URL(string: "https://192.168.1.10:3466")!,
            base: manualCandidates("https://192.168.1.10:3466/"),
            relay: "https://203.0.113.10:30001/",
            health: healthJSON("""
            {"deviceEndpoints":["https://192.168.1.10:3466","https://203.0.113.10:30001",
                                "https://203.0.113.10:30001/"]}
            """)
        )
        XCTAssertEqual(
            merged,
            ["https://192.168.1.10:3466", "https://203.0.113.10:30001"],
            "the current origin and the relay origin must appear once, without a trailing slash"
        )
    }

    func testPayloadCodePathCandidateOrderIsPreserved() {
        let fixture = payload("""
        {"v":1,"origins":["https://127.0.0.1:3466","https://192.168.1.10:3466"],
         "endpoints":[{"url":"https://192.168.1.10:3466"},{"url":"https://203.0.113.10:30001"}],
         "relay":{"origin":"https://203.0.113.10:30001"}}
        """)
        let base = PairingOriginSelector.candidates(payload: fixture, allowLoopback: false)
        XCTAssertEqual(base.map(\.absoluteString), ["https://192.168.1.10:3466", "https://203.0.113.10:30001"])
        let merged = mergedCandidates(
            current: base[0],
            base: base,
            relay: fixture.relay?.origin,
            health: healthJSON("""
            {"deviceEndpoints":["https://192.168.1.10:3466","https://203.0.113.10:30001"]}
            """)
        )
        XCTAssertEqual(
            merged,
            base.map(\.absoluteString),
            "payload/code pairing keeps its exact candidate order and gains no duplicates"
        )
    }

    func testCurrentOriginIsFirstAndRestKeepsRelativeOrder() {
        let lan = URL(string: "https://192.168.1.10:3466")!
        let relay = URL(string: "https://203.0.113.10:30001")!
        let merged = mergedCandidates(current: relay, base: [lan, relay], health: healthJSON("{\"ok\":true}"))
        XCTAssertEqual(
            merged,
            ["https://203.0.113.10:30001", "https://192.168.1.10:3466"],
            "the origin that just paired heads every reconnect round"
        )
    }

    func testMissingHealthDeviceEndpointsFallsBackToSingleManualOrigin() {
        let origin = URL(string: "https://192.168.1.10:3466")!
        let merged = mergedCandidates(
            current: origin,
            base: manualCandidates("https://192.168.1.10:3466"),
            health: healthJSON("{\"ok\":true,\"ready\":true}")
        )
        XCTAssertEqual(
            merged,
            ["https://192.168.1.10:3466"],
            "hosts without deviceEndpoints keep exactly the manual single origin"
        )
    }

    func testHealthDeviceEndpointsParserHandlesMissingAndNonStringEntries() {
        XCTAssertEqual(LinkService.healthDeviceEndpoints(from: healthJSON("{\"ok\":true}")), [])
        XCTAssertEqual(
            LinkService.healthDeviceEndpoints(from: healthJSON("""
            {"deviceEndpoints":["https://192.168.1.10:3466",{"url":"https://10.0.0.7:3466"}]}
            """)),
            ["https://192.168.1.10:3466"],
            "non-string endpoint entries are ignored"
        )
    }
}
