import Network
import XCTest
@testable import DSHm

// MARK: - ReconnectMetrics

/// task-2 (reconnect chain < 1s): stage math + one-line format of `ReconnectMetrics`.
final class ReconnectMetricsTests: XCTestCase {
    private var now: TimeInterval = 1_000

    override func setUp() {
        super.setUp()
        ReconnectMetrics.forceEnabledForTesting = true
        ReconnectMetrics.clock = { [weak self] in self?.now ?? 1_000 }
        ReconnectMetrics.reset()
    }

    override func tearDown() {
        ReconnectMetrics.forceEnabledForTesting = nil
        ReconnectMetrics.reset()
        ReconnectMetrics.clock = { ProcessInfo.processInfo.systemUptime }
        super.tearDown()
    }

    func testFullChainEmitsStageOffsetsAndTotal() throws {
        ReconnectMetrics.beginPageEnter(reason: "listPage")
        now += 0.050
        ReconnectMetrics.markReconnectStart()
        now += 0.250
        ReconnectMetrics.markConnected()
        now += 0.100
        ReconnectMetrics.markListApplied()

        let value = try XCTUnwrap(ReconnectMetrics.valueString)
        XCTAssertTrue(value.hasPrefix("totalMs=400"), value)
        XCTAssertTrue(value.contains("pageEnterMs=0"), value)
        XCTAssertTrue(value.contains("reconnectStartMs=50"), value)
        XCTAssertTrue(value.contains("connectedMs=300"), value)
        XCTAssertTrue(value.contains("listAppliedMs=400"), value)
        XCTAssertTrue(value.contains("reuse=0"), value)
        XCTAssertTrue(value.contains("stage=complete"), value)
        XCTAssertTrue(value.contains("reason=listPage"), value)
        XCTAssertTrue(value.contains("beginEpochMs="), value)
    }

    func testTotalIsIncompleteUntilBothHalvesOfT1AreIn() {
        ReconnectMetrics.beginPageEnter(reason: "listPage")
        now += 0.100
        ReconnectMetrics.markListApplied()
        // connected missing: t1 is not reached, so no total yet.
        XCTAssertTrue(ReconnectMetrics.valueString?.contains("totalMs=-1") ?? false)
        now += 0.200
        ReconnectMetrics.markConnected()
        XCTAssertTrue(ReconnectMetrics.valueString?.contains("totalMs=300") ?? false)
    }

    func testEarlyListAppliedDoesNotShortenTotalBelowConnected() {
        ReconnectMetrics.beginPageEnter(reason: "listPage")
        now += 0.100
        ReconnectMetrics.markListApplied() // early snapshot won the race
        now += 0.300
        ReconnectMetrics.markConnected()
        // total = max(connected, listApplied) - t0
        XCTAssertTrue(ReconnectMetrics.valueString?.contains("totalMs=400") ?? false)
    }

    func testReuseChainMeasuresListRefreshOnly() {
        ReconnectMetrics.beginPageEnter(reason: "sceneActive")
        ReconnectMetrics.markReuseDecision()
        now += 0.120
        ReconnectMetrics.markReuseConfirmed() // first baseline arrived in budget
        ReconnectMetrics.markListApplied()
        let value = ReconnectMetrics.valueString ?? ""
        XCTAssertTrue(value.contains("reuse=1"), value)
        XCTAssertTrue(value.contains("connectedMs=0"), value)
        XCTAssertTrue(value.contains("totalMs=120"), value)
        XCTAssertTrue(value.contains("stage=complete"), value)
    }

    func testProvisionalReuseDemotedByFirstByteTimeout() {
        ReconnectMetrics.beginPageEnter(reason: "sceneActive")
        ReconnectMetrics.markReuseDecision()
        now += 0.500
        // The reused mux never delivered a baseline: this is a real reconnect.
        ReconnectMetrics.markFirstByteTimeout(source: "workspaceBaseline")
        XCTAssertTrue((ReconnectMetrics.valueString ?? "").contains("reuse=0"))
        now += 0.300
        ReconnectMetrics.markReconnectStart()
        now += 0.250
        ReconnectMetrics.markConnected()
        now += 0.050
        ReconnectMetrics.markListApplied()
        let value = ReconnectMetrics.valueString ?? ""
        XCTAssertTrue(value.contains("reuse=0"), value)
        XCTAssertTrue(value.contains("connectedMs=1050"), value)
        XCTAssertTrue(value.contains("totalMs=1100"), value)
        XCTAssertTrue(value.contains("stage=complete"), value)
    }

    func testPageEnterAgainKeepsEarliestT0() {
        ReconnectMetrics.beginPageEnter(reason: "listPage")
        now += 0.100
        ReconnectMetrics.beginPageEnter(reason: "sceneActive") // same resume, second callback
        now += 0.200
        ReconnectMetrics.markConnected()
        now += 0.100
        ReconnectMetrics.markListApplied()
        // t0 stays the first page-enter callback: 300ms to connected, 400ms total.
        let value = ReconnectMetrics.valueString ?? ""
        XCTAssertTrue(value.contains("connectedMs=300"), value)
        XCTAssertTrue(value.contains("totalMs=400"), value)
    }

    func testPageEnterAfterLifetimeStartsFreshChain() {
        ReconnectMetrics.beginPageEnter(reason: "listPage")
        now += ReconnectMetrics.chainLifetime + 1
        ReconnectMetrics.beginPageEnter(reason: "listPage")
        now += 0.100
        ReconnectMetrics.markConnected()
        ReconnectMetrics.markListApplied()
        let value = ReconnectMetrics.valueString ?? ""
        XCTAssertTrue(value.contains("connectedMs=100"), value)
        XCTAssertTrue(value.contains("totalMs=100"), value)
    }

    func testPathChangeAndFirstByteTimeoutAreCounted() {
        ReconnectMetrics.beginPageEnter(reason: "listPage")
        ReconnectMetrics.markPathChange()
        ReconnectMetrics.markPathChange()
        ReconnectMetrics.markFirstByteTimeout(source: "workspaceBaseline")
        let value = ReconnectMetrics.valueString ?? ""
        XCTAssertTrue(value.contains("pathChanges=2"), value)
        XCTAssertTrue(value.contains("firstByteTimeouts=1"), value)
        XCTAssertTrue(value.contains("invalidatedBy=firstByte/workspaceBaseline"), value)
    }

    func testMarksWithoutChainAreIgnored() {
        ReconnectMetrics.markConnected()
        ReconnectMetrics.markListApplied()
        ReconnectMetrics.markReconnectStart()
        XCTAssertNil(ReconnectMetrics.valueString)
    }

    func testDisabledUnlessE2EGateIsOn() {
        ReconnectMetrics.forceEnabledForTesting = false
        ReconnectMetrics.reset()
        ReconnectMetrics.beginPageEnter(reason: "listPage")
        ReconnectMetrics.markConnected()
        XCTAssertNil(ReconnectMetrics.valueString, "no product behavior and no metrics outside E2E")
    }

    func testOnChangeHostReceivesSummary() {
        var observed: [String] = []
        ReconnectMetrics.onChange = { value in
            if let value { observed.append(value) }
        }
        defer { ReconnectMetrics.onChange = nil }
        ReconnectMetrics.beginPageEnter(reason: "listPage")
        ReconnectMetrics.markConnected()
        ReconnectMetrics.markListApplied()
        XCTAssertFalse(observed.isEmpty)
        XCTAssertTrue(observed.last?.contains("stage=complete") ?? false)
    }

    func testCandidateAttemptsPickedOriginAndBudgetFlagAreRecorded() throws {
        ReconnectMetrics.beginPageEnter(reason: "listPage")
        ReconnectMetrics.markReconnectStart()
        ReconnectMetrics.markCandidateAttempt(
            host: "relay.example.com", milliseconds: 123, result: "plugin-not-ready"
        )
        ReconnectMetrics.markCandidateAttempt(host: "192.168.1.9", milliseconds: 42, result: "ok")
        ReconnectMetrics.markPickedOrigin("192.168.1.9")
        ReconnectMetrics.markConnected()
        ReconnectMetrics.markListApplied()
        let value = try XCTUnwrap(ReconnectMetrics.valueString)
        XCTAssertTrue(
            value.contains("candidates=relay.example.com:123:plugin-not-ready|192.168.1.9:42:ok"),
            value
        )
        XCTAssertTrue(value.contains("picked=192.168.1.9"), value)
        XCTAssertTrue(value.contains("budgetExhausted=0"), value)
        XCTAssertTrue(value.contains("stage=complete"), value)
    }

    func testRoundBudgetExhaustionIsRecorded() throws {
        ReconnectMetrics.beginPageEnter(reason: "listPage")
        ReconnectMetrics.markReconnectStart()
        ReconnectMetrics.markRoundBudgetExhausted()
        let value = try XCTUnwrap(ReconnectMetrics.valueString)
        XCTAssertTrue(value.contains("budgetExhausted=1"), value)
        XCTAssertTrue(value.contains("stage=budgetExhausted"), value)
    }

    func testTotalMillisecondsPureFunction() throws {
        XCTAssertNil(ReconnectMetrics.totalMilliseconds(pageEnterAt: 100, connectedAt: nil, listAppliedAt: nil))
        XCTAssertEqual(
            try XCTUnwrap(ReconnectMetrics.totalMilliseconds(pageEnterAt: 100, connectedAt: 100.3, listAppliedAt: 100.1)),
            300,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(ReconnectMetrics.totalMilliseconds(pageEnterAt: 100, connectedAt: 100.1, listAppliedAt: 100.4)),
            400,
            accuracy: 0.001
        )
    }
}

// MARK: - Network path change detection

/// task-2: only an interface/satisfaction flip may invalidate a live socket; a
/// repeated identical path update must not restart a connection.
final class NetworkPathChangeTests: XCTestCase {
    private let wifi = NetworkPathSnapshot(
        interface: .wifi, isSatisfied: true, isExpensive: false, isConstrained: false
    )
    private let cellular = NetworkPathSnapshot(
        interface: .cellular, isSatisfied: true, isExpensive: true, isConstrained: false
    )
    private let offline = NetworkPathSnapshot(
        interface: .unknown, isSatisfied: false, isExpensive: false, isConstrained: false
    )

    func testFirstSampleOnlyEstablishesTheBaseline() {
        XCTAssertFalse(NetworkPathMonitor.isMeaningfulChange(from: nil, to: wifi))
        XCTAssertFalse(NetworkPathMonitor.isMeaningfulChange(from: nil, to: offline))
    }

    func testInterfaceFlipIsMeaningful() {
        XCTAssertTrue(NetworkPathMonitor.isMeaningfulChange(from: wifi, to: cellular))
        XCTAssertTrue(NetworkPathMonitor.isMeaningfulChange(from: cellular, to: wifi))
    }

    func testSatisfactionFlipIsMeaningful() {
        XCTAssertTrue(NetworkPathMonitor.isMeaningfulChange(from: wifi, to: offline))
        XCTAssertTrue(NetworkPathMonitor.isMeaningfulChange(from: offline, to: wifi))
    }

    func testIdenticalPathIsNotMeaningful() {
        XCTAssertFalse(NetworkPathMonitor.isMeaningfulChange(from: wifi, to: wifi))
        XCTAssertFalse(NetworkPathMonitor.isMeaningfulChange(from: cellular, to: cellular))
    }

    func testExpenseOrConstraintChangeOnSameSatisfiedInterfaceIsMeaningful() {
        let constrained = NetworkPathSnapshot(
            interface: .cellular, isSatisfied: true, isExpensive: true, isConstrained: true
        )
        XCTAssertTrue(NetworkPathMonitor.isMeaningfulChange(from: cellular, to: constrained))
    }

    func testPreferredRelayMatchesPathSemantics() {
        XCTAssertTrue(offline.prefersRelay, "unknown/offline keeps the relay-first legacy order")
        XCTAssertTrue(cellular.prefersRelay)
        XCTAssertFalse(wifi.prefersRelay)
    }

    @MainActor
    func testMonitorIncrementsGenerationAndFiresOnlyOnMeaningfulChange() {
        let monitor = NetworkPathMonitor(startImmediately: false)
        var fired = 0
        monitor.onMeaningfulChange = { fired += 1 }

        monitor.applyForTesting(wifi)
        XCTAssertEqual(monitor.changeGeneration, 0, "baseline sample is not a change")
        XCTAssertEqual(fired, 0)

        monitor.applyForTesting(wifi)
        XCTAssertEqual(monitor.changeGeneration, 0)
        XCTAssertEqual(fired, 0)

        monitor.applyForTesting(cellular)
        XCTAssertEqual(monitor.changeGeneration, 1)
        XCTAssertEqual(fired, 1)
        XCTAssertTrue(monitor.prefersRelay)

        monitor.applyForTesting(offline)
        XCTAssertEqual(monitor.changeGeneration, 2)
        XCTAssertEqual(fired, 2)
    }
}

// MARK: - Reconnect scheduling policy

/// task-2: pure reconnect decisions extracted from `LinkService` (backoff bounds,
/// candidate budget, path-aware dial order, connecting-round restart).
final class ReconnectPolicyTests: XCTestCase {
    func testBackoffBoundsAndCap() {
        XCTAssertEqual(LinkService.reconnectDelayMs(attempt: 1, randomUnit: 0), 250, accuracy: 0.001)
        XCTAssertEqual(LinkService.reconnectDelayMs(attempt: 1, randomUnit: 1), 500, accuracy: 0.001)
        XCTAssertEqual(LinkService.reconnectDelayMs(attempt: 2, randomUnit: 0), 500, accuracy: 0.001)
        XCTAssertEqual(LinkService.reconnectDelayMs(attempt: 2, randomUnit: 1), 1_000, accuracy: 0.001)
        // Cap (10s) applies before jitter: 5-10s from attempt 6 on.
        XCTAssertEqual(LinkService.reconnectDelayMs(attempt: 10, randomUnit: 1), 10_000, accuracy: 0.001)
        // Jitter input is clamped.
        XCTAssertEqual(LinkService.reconnectDelayMs(attempt: 1, randomUnit: -1), 250, accuracy: 0.001)
        XCTAssertEqual(LinkService.reconnectDelayMs(attempt: 1, randomUnit: 9), 500, accuracy: 0.001)
    }

    func testCandidateBudget() {
        // 2026-10-23 real-device calibration: a healthy 5G+relay round measured
        // candidateMs=1577–1602ms, so non-last candidates need >2s.
        XCTAssertEqual(LinkService.candidateTimeoutSeconds(index: 0, count: 2, pathChanged: false), 3)
        XCTAssertEqual(LinkService.candidateTimeoutSeconds(index: 1, count: 2, pathChanged: false), 8)
        XCTAssertEqual(LinkService.candidateTimeoutSeconds(index: 0, count: 2, pathChanged: true), 2.5)
        XCTAssertEqual(LinkService.candidateTimeoutSeconds(index: 1, count: 3, pathChanged: true), 2.5)
        XCTAssertEqual(LinkService.candidateTimeoutSeconds(index: 2, count: 3, pathChanged: true), 8)
        // Single candidate: keeps the long budget.
        XCTAssertEqual(LinkService.candidateTimeoutSeconds(index: 0, count: 1, pathChanged: true), 8)
    }

    func testRoundBudgetPerPath() {
        // Single candidate: nothing to switch to — the full candidate budget.
        XCTAssertEqual(
            LinkService.roundBudgetSeconds(candidateCount: 1, hasSameSubnetLAN: false, hasRelay: true),
            8
        )
        // Same LAN: LAN should answer fast, relay fallback still usable.
        XCTAssertEqual(
            LinkService.roundBudgetSeconds(candidateCount: 2, hasSameSubnetLAN: true, hasRelay: true),
            4
        )
        // Cross-network: relay first + stale LAN fallback. Must cover one healthy
        // relay round (~1.6s measured on a real device) plus a bounded fallback;
        // the old 1.5s budget was shorter than the round itself.
        XCTAssertEqual(
            LinkService.roundBudgetSeconds(candidateCount: 2, hasSameSubnetLAN: false, hasRelay: true),
            5
        )
        // LAN-only fallback keeps a usable budget.
        XCTAssertEqual(
            LinkService.roundBudgetSeconds(candidateCount: 2, hasSameSubnetLAN: false, hasRelay: false),
            4
        )
    }

    /// 2026-10-23 冷启动 <1s：relay-first 跨网路径必须跳过拨号前的串行发现+探测
    /// （真机实测该段 1577–1614ms，占 connectMs 的 ~65%），直接拨 relay。
    func testRelayFirstFastPathDecision() {
        let relay = URL(string: "https://121.41.112.232:30000")!
        let lan = URL(string: "https://192.168.5.10:3466")!
        // Cross-network (cellular) with relay ordered first: dial immediately.
        XCTAssertTrue(LinkService.shouldDialRelayImmediately(
            prefersRelay: true,
            orderedCandidates: [relay, lan],
            local: nil
        ))
        // Same-Wi-Fi LAN-first path keeps the convergence budget (it decides which
        // LAN origin is reachable).
        XCTAssertFalse(LinkService.shouldDialRelayImmediately(
            prefersRelay: false,
            orderedCandidates: [lan, relay],
            local: nil
        ))
        // Single candidate: nothing to converge / discover before dialing.
        XCTAssertFalse(LinkService.shouldDialRelayImmediately(
            prefersRelay: true,
            orderedCandidates: [relay],
            local: nil
        ))
        // Relay-first but the first ordered candidate is not a relay -> no fast path.
        XCTAssertFalse(LinkService.shouldDialRelayImmediately(
            prefersRelay: true,
            orderedCandidates: [lan, relay],
            local: nil
        ))
    }

    func testAttemptBudgetNeverExceedsTheRoundBudget() {        XCTAssertNil(LinkService.attemptBudget(baseTimeout: 8, remainingRoundBudget: 0))
        XCTAssertNil(
            LinkService.attemptBudget(baseTimeout: 8, remainingRoundBudget: 0.05),
            "no point dialing with 50ms of the round budget left"
        )
        XCTAssertEqual(LinkService.attemptBudget(baseTimeout: 8, remainingRoundBudget: 0.4), 0.4)
        XCTAssertEqual(LinkService.attemptBudget(baseTimeout: 2, remainingRoundBudget: 1.4), 1.4)
        XCTAssertEqual(LinkService.attemptBudget(baseTimeout: 1.5, remainingRoundBudget: 3), 1.5)
    }

    func testConnectingRoundRestartRule() {
        XCTAssertFalse(
            LinkService.shouldRestartConnectingRound(roundStartGeneration: 3, pathGeneration: 3),
            "a round already dialed on the new path must be allowed to finish"
        )
        XCTAssertTrue(
            LinkService.shouldRestartConnectingRound(roundStartGeneration: 2, pathGeneration: 3),
            "a round dialed before the path change is on the wrong network"
        )
    }
}

// MARK: - Cross-network candidate routing

/// task-2 cross-network: candidate roles + path-aware ordering, including the
/// subnet judgement that decides LAN-first vs relay-first.
final class CandidateRoutingTests: XCTestCase {
    /// Phone: 192.168.1.5/24 (home Wi-Fi).
    private let local = LocalIPv4Network(address: 0xC0A8_0105, prefixLength: 24)
    private let sameLAN = URL(string: "https://192.168.1.9:8443")!
    private let otherLAN = URL(string: "https://172.20.10.2:3466")!
    private let relay = URL(string: "https://121.41.112.232:30000")!

    func testLocalIPv4ParsingAndSubnetMatching() {
        XCTAssertEqual(LocalIPv4Network.parseIPv4("192.168.1.9"), 0xC0A8_0109)
        XCTAssertNil(LocalIPv4Network.parseIPv4("192.168.1"))
        XCTAssertNil(LocalIPv4Network.parseIPv4("not-an-ip"))
        XCTAssertEqual(LocalIPv4Network.prefixLength(mask: 0xFFFF_FF00), 24)
        XCTAssertEqual(LocalIPv4Network.prefixLength(mask: 0xFFFF_0000), 16)
        XCTAssertEqual(LocalIPv4Network.prefixLength(mask: 0xFFFF_FFFF), 32)
        XCTAssertTrue(local.contains(host: "192.168.1.9"))
        XCTAssertFalse(local.contains(host: "192.168.2.9"), "different /24")
        XCTAssertFalse(local.contains(host: "172.20.10.2"))
        XCTAssertFalse(local.contains(host: "not-an-ip"))
        // /16 compares 16 bits.
        let wide = LocalIPv4Network(address: 0xAC14_0005, prefixLength: 16) // 172.20.0.5/16
        XCTAssertTrue(wide.contains(host: "172.20.10.2"))
        XCTAssertFalse(wide.contains(host: "172.21.10.2"))
    }

    func testCandidateRoleUsesSubnetNotJustPrivateAddressRange() {
        XCTAssertEqual(LinkService.candidateRole(host: "121.41.112.232", local: local), .relay)
        XCTAssertEqual(LinkService.candidateRole(host: "192.168.1.9", local: local), .lanSameSubnet)
        XCTAssertEqual(LinkService.candidateRole(host: "172.20.10.2", local: local), .lanOther)
        XCTAssertEqual(LinkService.candidateRole(host: "172.20.10.2", local: nil), .lanOther)
    }

    func testSameLANPathPutsLANFirst() {
        let ordered = LinkService.orderedCandidatesForPath(
            [relay, otherLAN, sameLAN],
            prefersRelay: false,
            local: local,
            pathChanged: false
        )
        XCTAssertEqual(ordered, [sameLAN, relay, otherLAN])
    }

    func testCrossNetworkPathPutsRelayFirstAndKeepsLANFallback() {
        // Phone left the Mac's network (e.g. 172.20.10.x hotspot): the stale LAN
        // origin must not be dialed first, but it is still kept as a fallback.
        let ordered = LinkService.orderedCandidatesForPath(
            [otherLAN, relay],
            prefersRelay: false,
            local: local,
            pathChanged: false
        )
        XCTAssertEqual(ordered, [relay, otherLAN])
        XCTAssertEqual(ordered.count, 2, "the stale LAN origin is never dropped")
    }

    func testCellularPutsRelayFirst() {
        let ordered = LinkService.orderedCandidatesForPath(
            [sameLAN, relay],
            prefersRelay: true,
            local: nil,
            pathChanged: false
        )
        XCTAssertEqual(ordered, [relay, sameLAN])
    }

    func testUnknownLocalNetworkKeepsLegacyOrder() {
        let candidates = [otherLAN, relay]
        XCTAssertEqual(
            LinkService.orderedCandidatesForPath(
                candidates,
                prefersRelay: false,
                local: nil,
                pathChanged: false
            ),
            candidates
        )
    }

    func testSingleCandidateIsNeverReordered() {
        XCTAssertEqual(
            LinkService.orderedCandidatesForPath(
                [otherLAN],
                prefersRelay: true,
                local: nil,
                pathChanged: true
            ),
            [otherLAN]
        )
    }

    func testSameSubnetLANStaysFirstEvenAfterPathChange() {
        let ordered = LinkService.orderedCandidatesForPath(
            [sameLAN, relay],
            prefersRelay: false,
            local: local,
            pathChanged: true
        )
        XCTAssertEqual(ordered, [sameLAN, relay], "same-subnet LAN remains the fastest path")
    }
}

// MARK: - Fast reject / failure classification

/// task-2 cross-network: `HTTP 503 {error:"host/inactive"}` must be a **fast
/// reject** (switch candidate immediately, no timeout wait, no retry of the same
/// origin); 5xx/401/timeout classes drive retryability + the one-line banner text.
final class CandidateFailureTests: XCTestCase {
    func testPluginState503IsAFastRejectAndRetryable() {
        let failure = LinkService.failureClass(for: LinkError.httpStatus(503, "host/inactive"))
        XCTAssertEqual(failure, .pluginNotReady)
        XCTAssertTrue(failure.isFastReject, "switch candidate immediately, do not wait for a timeout")
        XCTAssertTrue(failure.isRetryable, "a restarted desktop plugin recovers on a later backoff round")
        XCTAssertEqual(
            LinkService.failureClass(for: LinkError.httpStatus(503, "{error:host/starting}")),
            .pluginNotReady
        )
        XCTAssertEqual(
            LinkService.failureClass(for: LinkError.httpStatus(503, "host/incompatible")),
            .pluginNotReady
        )
    }

    func testOther5xxIsGatewayRejectFastReject() {
        for status in [500, 502, 504] {
            let failure = LinkService.failureClass(for: LinkError.httpStatus(status, "bad gateway"))
            XCTAssertEqual(failure, .gatewayRejected, "HTTP \(status)")
            XCTAssertTrue(failure.isFastReject)
            XCTAssertTrue(failure.isRetryable)
        }
    }

    func test401IsCredentialRejectionAndNotRetryable() {
        let failure = LinkService.failureClass(for: LinkError.httpStatus(401, "auth/token-expired"))
        XCTAssertEqual(failure, .credentialRejected)
        XCTAssertFalse(failure.isRetryable, "only re-pairing can recover")
        XCTAssertFalse(failure.isFastReject, "handled by the needsRepair path, not the candidate walk")
    }

    func testTimeoutAndUnreachableClassification() {
        XCTAssertEqual(LinkService.failureClass(for: LinkError.timeout("auth")), .timeout)
        XCTAssertEqual(LinkService.classifyFailureMessage("连接 Mac 超时（code: 60）"), .timeout)
        XCTAssertEqual(
            LinkService.classifyFailureMessage("无法连接 Mac（连接被拒绝：地址或端口不可达）"),
            .unreachable
        )
        XCTAssertEqual(LinkService.classifyFailureMessage("首字节超时（复用连接 800ms 无响应）"), .timeout)
        XCTAssertEqual(
            LinkService.classifyFailureMessage("HTTP 503: host/inactive"),
            .pluginNotReady
        )
    }

    func testRoundFailureSummaryPutsTheActionableReasonFirst() {
        let plugin = LinkService.roundFailureSummary(
            classes: [.pluginNotReady, .timeout],
            details: ["relay: HTTP 503: host/inactive"]
        )
        XCTAssertTrue(plugin.contains("桌面端插件未就绪"), plugin)
        XCTAssertTrue(plugin.contains("重启"), plugin)
        let gateway = LinkService.roundFailureSummary(classes: [.gatewayRejected], details: [])
        XCTAssertTrue(gateway.contains("网关"), gateway)
        let timeout = LinkService.roundFailureSummary(classes: [.timeout], details: [])
        XCTAssertTrue(timeout.contains("超时"), timeout)
        let generic = LinkService.roundFailureSummary(classes: [.unreachable], details: ["h: 不可达"])
        XCTAssertEqual(generic, "h: 不可达")
    }
}

// MARK: - HTTPConnection first-byte watchdog

/// task-2: the reused-socket first-byte watchdog (Lead-approved scope:
/// `Net/HTTPConnection.swift`). Fake-clock seam = `simulateFirstByteTimeoutForTesting`
/// so no test waits the real 0.8s budget.
final class FirstByteTimeoutTests: XCTestCase {
    private func request(_ path: String) -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            path: path,
            headers: ["content-type": "application/json"],
            body: Data("{}".utf8)
        )
    }

    private func key(_ server: HoldableHTTPServer) -> HTTPConnectionKey {
        HTTPConnectionKey(host: "127.0.0.1", port: server.port, pin: nil)
    }

    private func makePool() -> HTTPConnectionPool {
        HTTPConnectionPool(config: HTTPConnectionPoolConfig(maxIdlePerOrigin: 2, idleTimeout: 10))
    }

    private func makeClient(pool: HTTPConnectionPool, server: HoldableHTTPServer) -> HTTPSClient {
        HTTPSClient(
            host: "127.0.0.1",
            port: server.port,
            leafPin: nil,
            pool: pool,
            parameters: NWParameters.tcp
        )
    }

    func testBudgetIsTheSingleLeadApprovedConstant() {
        // 2026-10-23: raised 0.8 -> 1.5 after a real-device false kill on a slow
        // (but alive) 5G relay path; the teardown decision now also verifies the
        // path with a fresh /health probe before invalidating the transport.
        XCTAssertEqual(HTTPConnection.firstByteTimeout, 1.5, accuracy: 0.0001)
    }

    func testReusedConnectionWithoutFirstByteFailsNotifiesAndIsDropped() async throws {
        let server = try HoldableHTTPServer()
        try await server.start()
        defer { server.stop() }
        let pool = makePool()
        let client = makeClient(pool: pool, server: server)
        // First request establishes the keep-alive connection (normal response).
        let first = try await client.perform(request("/api/a"), timeout: 5)
        XCTAssertEqual(first.status, 200)
        let reused = try await checkout(pool: pool, key: key(server))
        XCTAssertEqual(server.acceptedConnections, 1)

        // Second request on the reused connection: the server never sends a byte.
        server.holdsResponses = true
        let timeoutNote = expectation(forNotification: .dshmHTTPFirstByteTimeout, object: nil) { note in
            (note.userInfo?["endpoint"] as? String) == "/api/b"
        }
        let task = Task { try await reused.perform(self.request("/api/b"), timeout: 10) }
        await server.waitForNextRequest()
        reused.simulateFirstByteTimeoutForTesting()

        await fulfillment(of: [timeoutNote], timeout: 2)
        do {
            _ = try await task.value
            XCTFail("a reused socket with zero response bytes must fail")
        } catch let error as LinkError {
            guard case .timeout(let message) = error else {
                return XCTFail("expected LinkError.timeout, got \(error)")
            }
            XCTAssertTrue(message.contains("首字节超时"), message)
        }
        XCTAssertTrue(reused.isClosed, "the dead socket must not be reusable")
        XCTAssertEqual(pool.idleCount(for: key(server)), 0, "the dead socket must not be re-pooled")
        XCTAssertEqual(server.acceptedConnections, 1)
    }

    func testFreshConnectionIsNotKilledByFirstByteWatchdog() async throws {
        let server = try HoldableHTTPServer()
        try await server.start()
        defer { server.stop() }
        server.holdsResponses = true
        let connection = HTTPConnection(
            key: key(server),
            host: "127.0.0.1",
            port: server.port,
            leafPin: nil,
            parametersOverride: NWParameters.tcp,
            pool: nil
        )
        let task = Task { try await connection.perform(self.request("/api/slow"), timeout: 10) }
        await server.waitForNextRequest()
        // Not claimed from the pool: the watchdog must have no opinion (TCP/TLS and
        // a slow first flight are legitimate).
        connection.simulateFirstByteTimeoutForTesting()
        server.releaseHeldResponse()
        let response = try await task.value
        XCTAssertEqual(response.status, 200, "a fresh connection's slow first byte is not a dead socket")
    }

    func testReusedConnectionWithPromptResponseIsUnchanged() async throws {
        let server = try HoldableHTTPServer()
        try await server.start()
        defer { server.stop() }
        let pool = makePool()
        let client = makeClient(pool: pool, server: server)
        let first = try await client.perform(request("/api/a"), timeout: 5)
        XCTAssertEqual(first.status, 200)
        let reused = try await checkout(pool: pool, key: key(server))
        let second = try await reused.perform(request("/api/b"), timeout: 5)
        XCTAssertEqual(second.status, 200)
        // A completed request has no pending watchdog left to fire.
        reused.simulateFirstByteTimeoutForTesting()
        XCTAssertFalse(reused.isClosed)
        XCTAssertEqual(server.acceptedConnections, 1, "keep-alive reuse must be unaffected")
    }

    private func checkout(
        pool: HTTPConnectionPool,
        key: HTTPConnectionKey
    ) async throws -> HTTPConnection {
        for _ in 0..<100 {
            if let connection = pool.checkout(key) { return connection }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let message = "the keep-alive connection was never pooled"
        XCTFail(message)
        throw NSError(domain: "FirstByteTimeoutTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Loopback server that can hold responses

/// Minimal HTTP/1.1 loopback server for the first-byte watchdog tests: one
/// keep-alive connection, records each completed request, and can withhold the
/// response until the test releases it.
final class HoldableHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.dshm.tests.holdable-server")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var buffer = Data()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var received = 0
    private var delivered = 0
    private var accepted = 0
    private(set) var port: UInt16 = 0
    var holdsResponses = false

    init() throws {
        listener = try NWListener(using: NWParameters.tcp, on: .any)
    }

    var acceptedConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] nw in
            self?.accept(nw)
        }
        let ready = FirstByteResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    ready.resume { continuation.resume() }
                case .failed(let error):
                    ready.resume { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let current = connection
        connection = nil
        lock.unlock()
        current?.cancel()
    }

    func waitForNextRequest() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if received > delivered {
                delivered += 1
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func releaseHeldResponse() {
        lock.lock()
        let current = connection
        lock.unlock()
        if let current { respond(on: current) }
    }

    private func accept(_ nw: NWConnection) {
        lock.lock()
        accepted += 1
        connection = nw
        lock.unlock()
        nw.start(queue: queue)
        receive(on: nw)
    }

    private func receive(on nw: NWConnection) {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var completedRequest = false
            if let data, !data.isEmpty {
                self.lock.lock()
                self.buffer.append(data)
                if self.headerBlockComplete(self.buffer) {
                    self.buffer.removeAll()
                    self.received += 1
                    completedRequest = true
                    if !self.waiters.isEmpty {
                        self.delivered += 1
                        self.waiters.removeFirst().resume()
                    }
                }
                let hold = self.holdsResponses
                self.lock.unlock()
                if completedRequest, !hold {
                    self.respond(on: nw)
                }
            }
            if error == nil, !isComplete {
                self.receive(on: nw)
            }
        }
    }

    private func headerBlockComplete(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return false }
        var index = 0
        while index <= bytes.count - 4 {
            if bytes[index] == 13, bytes[index + 1] == 10, bytes[index + 2] == 13, bytes[index + 3] == 10 {
                return true
            }
            index += 1
        }
        return false
    }

    private func respond(on nw: NWConnection) {
        let body = Data("{}".utf8)
        let head = "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: \(body.count)\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        nw.send(content: data, completion: .contentProcessed { _ in })
    }
}

/// 桌面端重启窗口：重连退避不能滚到 10s（用户实测重启桌面端后开 App 等了约 10 秒）。
final class ReconnectBootWindowTests: XCTestCase {
    func testAllCandidatesUnreadyIsBootWindow() {
        XCTAssertTrue(LinkService.isBootWindow(classes: [.pluginNotReady]))
        XCTAssertTrue(LinkService.isBootWindow(classes: [.pluginNotReady, .unreachable, .timeout]))
        XCTAssertTrue(LinkService.isBootWindow(classes: [.gatewayRejected, .timeout]))
    }

    func testCredentialOrCancelledFailuresAreNotBootWindow() {
        XCTAssertFalse(LinkService.isBootWindow(classes: [.credentialRejected]))
        XCTAssertFalse(LinkService.isBootWindow(classes: [.pluginNotReady, .credentialRejected]))
        XCTAssertFalse(LinkService.isBootWindow(classes: [.cancelled]))
        XCTAssertFalse(LinkService.isBootWindow(classes: [.ok]))
    }

    func testEmptyFailureSetIsNotBootWindow() {
        XCTAssertFalse(LinkService.isBootWindow(classes: []))
    }

    func testBootWindowDelayStartsShortAndCapsAt1500ms() {
        XCTAssertEqual(LinkService.bootWindowDelayMs(attempt: 1), 400, accuracy: 0.001)
        XCTAssertEqual(LinkService.bootWindowDelayMs(attempt: 2), 600, accuracy: 0.001)
        XCTAssertEqual(LinkService.bootWindowDelayMs(attempt: 3), 800, accuracy: 0.001)
        XCTAssertEqual(LinkService.bootWindowDelayMs(attempt: 6), 1_400, accuracy: 0.001)
        // 上限 1.5s：第 7 轮之后不再增长，保证桌面端一就绪就能在 ≤1.5s 内连上。
        XCTAssertEqual(LinkService.bootWindowDelayMs(attempt: 7), 1_500, accuracy: 0.001)
        XCTAssertEqual(LinkService.bootWindowDelayMs(attempt: 30), 1_500, accuracy: 0.001)
        // 对比：指数退避在第 6 轮已经要等 8–10s。
        XCTAssertGreaterThan(LinkService.reconnectDelayMs(attempt: 6, randomUnit: 1), 6_000)
    }
}

/// Resumes a continuation exactly once (listener state updates can fire repeatedly).
final class FirstByteResumeOnce {
    private let lock = NSLock()
    private var done = false

    func resume(_ body: () -> Void) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        body()
    }
}
