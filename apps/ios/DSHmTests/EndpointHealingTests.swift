import Network
import XCTest
@testable import DSHm

/// 跨网络连接自愈（2026-10-23 用户要求：任何网络都要连得上，且极致快）的纯逻辑单测：
/// 端点合并、成功连接后的刷新节流、并行探测排序/预算、以及一轮连接的拨号顺序。
final class EndpointHealingTests: XCTestCase {

    // MARK: - 端点合并（Mac 广播的 /health.deviceEndpoints 写回候选）

    /// Mac 换网后广播的新地址必须排在陈旧地址前面，当前 origin 永远第一。
    func testMergeAdvertisedKeepsCurrentFirstThenFreshEndpoints() {
        let merged = EndpointHealing.mergeAdvertised(
            current: "https://192.168.5.10:3466",
            stored: ["https://192.168.5.10:3466", "https://172.20.10.2:3466"],
            advertised: ["https://192.168.9.31:3466", "https://121.41.112.232:30000"]
        )
        XCTAssertEqual(merged, [
            "https://192.168.5.10:3466",
            "https://192.168.9.31:3466",
            "https://121.41.112.232:30000",
            "https://172.20.10.2:3466",
        ], "新地址必须前置，陈旧地址只能作为保底排在后面")
    }

    /// 陈旧地址不会无限膨胀：fresh + stale 截断到 maxCandidates。
    func testMergeAdvertisedCapsStaleTail() {
        let stored = (1...20).map { "https://10.0.0.\($0):3466" }
        let merged = EndpointHealing.mergeAdvertised(
            current: "https://192.168.5.10:3466",
            stored: stored,
            advertised: ["https://192.168.5.10:3466"]
        )
        XCTAssertEqual(merged.count, EndpointHealing.maxCandidates)
        XCTAssertEqual(merged.first, "https://192.168.5.10:3466")
    }

    /// 只接受 https origin（http / 空 host / 垃圾字符串一律丢弃）。
    func testMergeAdvertisedRejectsNonHTTPS() {
        let merged = EndpointHealing.mergeAdvertised(
            current: nil,
            stored: nil,
            advertised: [
                "http://192.168.5.10:3466",
                "https://?bad",
                "https://192.168.5.10:3466/",
            ]
        )
        XCTAssertEqual(merged, ["https://192.168.5.10:3466"], "仅保留唯一的合法 https origin")
    }

    func testNormalizedHTTPSOriginStripsTrailingSlashes() {
        XCTAssertEqual(
            EndpointHealing.normalizedHTTPSOrigin("https://121.41.112.232:30000///"),
            "https://121.41.112.232:30000"
        )
        XCTAssertNil(EndpointHealing.normalizedHTTPSOrigin("http://121.41.112.232:30000"))
        XCTAssertNil(EndpointHealing.normalizedHTTPSOrigin("  "))
    }

    // MARK: - 成功连接后的端点刷新节流

    /// 网络路径变化必须强制刷新：这正是地址最可能过期的时候。
    func testRefreshForcedOnNetworkPathChange() {
        let now = Date()
        XCTAssertTrue(EndpointHealing.shouldRefreshEndpoints(
            lastRefreshAt: now.addingTimeInterval(-1),
            now: now,
            networkPathChanged: true
        ))
    }

    func testRefreshThrottledWithinInterval() {
        let now = Date()
        XCTAssertFalse(EndpointHealing.shouldRefreshEndpoints(
            lastRefreshAt: now.addingTimeInterval(-10),
            now: now,
            networkPathChanged: false
        ))
        XCTAssertTrue(EndpointHealing.shouldRefreshEndpoints(
            lastRefreshAt: now.addingTimeInterval(-61),
            now: now,
            networkPathChanged: false
        ))
    }

    func testRefreshWhenNeverRefreshed() {
        XCTAssertTrue(EndpointHealing.shouldRefreshEndpoints(
            lastRefreshAt: nil,
            now: Date(),
            networkPathChanged: false
        ))
    }

    // MARK: - 并行探测排序与预算

    /// healthy 按延迟升序 → rejected → unreachable；unreachable 不会被前置。
    func testRankProbesHealthyByLatencyThenRejectedThenUnreachable() {
        let observations = [
            EndpointHealing.ProbeObservation(origin: "https://c:1", result: .unreachable, latencyMs: 5),
            EndpointHealing.ProbeObservation(origin: "https://b:1", result: .healthy, latencyMs: 180),
            EndpointHealing.ProbeObservation(origin: "https://a:1", result: .healthy, latencyMs: 40),
            EndpointHealing.ProbeObservation(origin: "https://d:1", result: .rejected, latencyMs: 60),
        ]
        XCTAssertEqual(
            EndpointHealing.rankProbes(observations).map(\.origin),
            ["https://a:1", "https://b:1", "https://d:1", "https://c:1"]
        )
    }

    /// 同一 origin 多条记录只保留最好的结果（healthy 覆盖 unreachable）。
    func testRankProbesDedupesByBestResult() {
        let observations = [
            EndpointHealing.ProbeObservation(origin: "https://a:1", result: .unreachable, latencyMs: 900),
            EndpointHealing.ProbeObservation(origin: "https://A:1", result: .healthy, latencyMs: 120),
        ]
        let ranked = EndpointHealing.rankProbes(observations)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.result, .healthy)
    }

    func testProbeBudgetAndDiscoveryBudget() {
        XCTAssertFalse(EndpointHealing.shouldProbe(candidateCount: 1), "单候选没有可切换目标，直接拨")
        XCTAssertTrue(EndpointHealing.shouldProbe(candidateCount: 2))
        XCTAssertEqual(EndpointHealing.probeTimeout(candidateCount: 2), 1.2)
        XCTAssertEqual(EndpointHealing.probeTimeout(candidateCount: 5), 1.5)
        XCTAssertEqual(EndpointHealing.discoveryBudget(hasLANCandidate: true), 1.0)
        XCTAssertEqual(EndpointHealing.discoveryBudget(hasLANCandidate: false), 0.6)
    }

    // MARK: - 拨号顺序（一轮连接实际拨哪些地址、按什么顺序）

    private var lanNetwork: LocalIPv4Network {
        LocalIPv4Network.fromInterface(address: "192.168.5.10", netmask: "255.255.255.0")!
    }

    /// 同一 Wi-Fi：mDNS 发现的同网段 LAN 地址排在公网中继前面。
    func testDialOrderPrefersDiscoveredSameSubnetLANOnLANPath() {
        let order = LinkService.dialOrder(
            discovered: ["https://121.41.112.232:30000", "https://192.168.5.10:3466"],
            observations: [],
            fallback: [URL(string: "https://172.20.10.2:3466")!],
            local: lanNetwork,
            prefersRelay: false
        )
        XCTAssertEqual(order.first?.absoluteString, "https://192.168.5.10:3466",
                       "同网段 LAN 是最快路径，必须第一个拨")
    }

    /// 蜂窝 / 跨网段：中继优先，LAN 只做兜底（旧实现第一条就拨 LAN → 每次白等）。
    func testDialOrderPrefersRelayOnRelayPath() {
        let order = LinkService.dialOrder(
            discovered: ["https://192.168.5.10:3466"],
            observations: [],
            fallback: [URL(string: "https://121.41.112.232:30000")!],
            local: nil,
            prefersRelay: true
        )
        XCTAssertEqual(order.first?.absoluteString, "https://121.41.112.232:30000")
    }

    /// 并行探测把 healthy/rejected 前置，unreachable 只留在兜底尾部（不浪费预算去拨）。
    func testDialOrderPromotesHealthyProbeAndKeepsUnreachableAsFallback() {
        let dead = URL(string: "https://172.20.10.2:3466")!
        let healthy = URL(string: "https://121.41.112.232:30000")!
        let order = LinkService.dialOrder(
            discovered: [],
            observations: [
                EndpointHealing.ProbeObservation(origin: dead.absoluteString, result: .unreachable, latencyMs: 1200),
                EndpointHealing.ProbeObservation(origin: healthy.absoluteString, result: .healthy, latencyMs: 260),
            ],
            fallback: [dead, healthy],
            local: nil,
            prefersRelay: true
        )
        XCTAssertEqual(order.first?.absoluteString, healthy.absoluteString)
        XCTAssertEqual(order.last?.absoluteString, dead.absoluteString, "unreachable 只能兜底，不能前置")
    }

    /// mDNS 端点与存量候选重复时只拨一次。
    func testDialOrderDedupesDiscoveredAndFallback() {
        let lan = URL(string: "https://192.168.5.10:3466")!
        let order = LinkService.dialOrder(
            discovered: ["https://192.168.5.10:3466/"],
            observations: [
                EndpointHealing.ProbeObservation(origin: lan.absoluteString, result: .healthy, latencyMs: 30),
            ],
            fallback: [lan],
            local: lanNetwork,
            prefersRelay: false
        )
        XCTAssertEqual(order.filter { $0.host == "192.168.5.10" }.count, 1)
    }
}

// MARK: - 2026-10-23 真机根因修复（N-04）：mDNS 自愈的 hostId 校验

/// 端点自愈只能在「确认是已配对的同一台 Mac」时使用发现结果：
/// 已知 hostId 必须精确匹配（绝不「唯一一台就采纳」）；旧凭据没有 hostId 时
/// 只有唯一一台广播才可采用。否则公司 Wi-Fi 下同事的 Mac 会被当成自己的，
/// 把错误的中继端点注入当前配对（隔离 stack 已复现 → 连不上 Mac）。
final class LANEndpointDiscoveryMatchTests: XCTestCase {

    private func mac(hostId: String, name: String, relay: String? = nil) -> DiscoveredMac {
        DiscoveredMac(
            hostId: hostId,
            hostName: name,
            serviceName: name + "._dshm._tcp.local",
            txt: ["hostId": hostId],
            endpoint: .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: 3466) ?? 3466
            ),
            relayOrigin: relay
        )
    }

    func testMatchMacsUsesExactHostIdOnly() {
        let mine = mac(hostId: "4aca5cf901a94a2c", name: "DSH-m-Mac")
        let other = mac(hostId: "deadbeefdeadbeef", name: "Colleague-Mac", relay: "https://10.0.0.9:30000")

        XCTAssertEqual(
            LANEndpointDiscovery.matchMacs([other, mine], hostId: "4aca5cf901a94a2c").map(\.hostId),
            ["4aca5cf901a94a2c"]
        )
        // Known hostId + only a different Mac broadcasting -> never adopt it.
        XCTAssertTrue(
            LANEndpointDiscovery.matchMacs([other], hostId: "4aca5cf901a94a2c").isEmpty,
            "已知 hostId 不匹配时绝不能采纳别的 Mac 的广播"
        )
    }

    func testMatchMacsUniqueAdoptOnlyWhenHostIdUnknown() {
        let other = mac(hostId: "deadbeefdeadbeef", name: "Colleague-Mac")
        XCTAssertEqual(
            LANEndpointDiscovery.matchMacs([other], hostId: nil).map(\.hostId),
            ["deadbeefdeadbeef"],
            "旧凭据没有 hostId 时，唯一一台广播是唯一可采纳的兼容路径"
        )
        XCTAssertTrue(
            LANEndpointDiscovery.matchMacs([other, other], hostId: nil).isEmpty,
            "多台广播时绝不猜"
        )
    }
}
