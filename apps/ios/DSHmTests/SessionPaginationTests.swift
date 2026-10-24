import XCTest
@testable import DSHm

/// 2026-10-23 全量历史自动补齐引擎（HistoryFiller）门禁：
/// 用户决策「打开会话后无条件自动加载全部历史到最早一条（无 UI、无痕）」的状态机
/// 由 `historyPageLoader` seam + 合成 Host 分页驱动，不依赖 socket/UI。
///
/// 覆盖：成功到 seq0 / 多页顺序与 wire 参数 / Host 说没更早 / 空页终止 /
/// 失败重试 / 离线暂停与恢复 / 取消 / 补齐期间 live snapshot / 幂等。
final class SessionPaginationTests: XCTestCase {

    // MARK: - 合成 Host（session/page 语义：beforeSeq exclusive，throughSeq inclusive）

    private struct FakeHost {
        /// 时间序事件，seq == 下标（从 0 开始）。
        let events: [SessionEvent]

        init(eventCount: Int) {
            self.events = (0..<eventCount).map { seq in
                let type = seq % 3 == 0 ? "user/message" : (seq % 3 == 1 ? "assistant/message" : "turn/start")
                return SessionEvent(
                    type: type, seq: seq, time: 1_792_510_000_000 + Int64(seq),
                    data: .object(["index": .int(Int64(seq))]),
                    surfaceOp: .string("append"), sourceEventSeqs: nil
                )
            }
        }

        func page(args: [String: JSONValue]) throws -> [String: JSONValue] {
            let request = try XCTUnwrap(args["request"]?.objectValue)
            let throughSeq = Int(try XCTUnwrap(request["throughSeq"]?.intValue))
            let beforeSeq = Int(try XCTUnwrap(request["beforeSeq"]?.intValue))
            let maxMessages = Int(try XCTUnwrap(request["maxMessages"]?.intValue))
            let end = min(throughSeq + 1, beforeSeq, events.count)
            var start = end
            var messages = 0
            while start > 0, messages < maxMessages {
                start -= 1
                let type = events[start].type
                if type == "user/message" || type == "assistant/message" { messages += 1 }
            }
            let records = events[start..<end].map { event -> JSONValue in
                let encoder = JSONEncoder()
                let data = (try? encoder.encode(event)) ?? Data()
                let value = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
                return .object(["type": .string("event"), "event": value])
            }
            return [
                "records": .array(records),
                "hasMore": .bool(start > 0),
            ]
        }
    }

    // MARK: - fixtures / helpers

    private func snapshotJSON(events: [SessionEvent], cursor: Int, hasMore: Bool) -> JSONValue {
        let encoder = JSONEncoder()
        let records = events.map { event -> String in
            let data = (try? encoder.encode(event)) ?? Data()
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return "{\"type\":\"event\",\"event\":\(text)}"
        }.joined(separator: ",")
        let json = "{\"type\":\"snapshot\",\"header\":{\"version\":4,\"id\":\"fixture\"},"
            + "\"cursor\":\(cursor),\"records\":[\(records)],\"hasMore\":\(hasMore),"
            + "\"projections\":{\"asOfSeq\":\(cursor),\"values\":{}},\"assistantStream\":{\"revision\":0}}"
        return TestJSON.value(json)
    }

    /// 创建 detail VM 并把首窗设成「Host 还有更早历史」。
    @MainActor
    private func makeViewModel(
        host: FakeHost,
        firstWindowMessages: Int = 8,
        hasMore: Bool = true
    ) -> SessionViewModel {
        SessionViewModel.e2eFillDiagnosticsTestOverride = true
        let viewModel = SessionViewModel(
            address: .session(sessionId: "fixture"),
            windowCache: SessionWindowCacheStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("AutoFill-\(UUID().uuidString)", isDirectory: true),
                identity: { "autoload-tests" }
            )
        )
        // 单测把 filler 的退避 sleep 折叠为 0：失败/空页的多轮 1/2/4s 序列即时跑完。
        viewModel.historyFillBackoffScale = 0
        let firstWindow = Array(host.events.suffix(firstWindowMessages))
        let cursor = firstWindow.last?.seq ?? 0
        viewModel.applyStreamValue(snapshotJSON(events: firstWindow, cursor: cursor, hasMore: hasMore))
        return viewModel
    }

    private func loader(
        host: FakeHost,
        onRequest: @escaping ([String: JSONValue]) -> Void = { _ in }
    ) -> ([String: JSONValue]) async throws -> JSONValue {
        { args in
            onRequest(args)
            return .object(try host.page(args: args))
        }
    }

    @MainActor
    private func probe(_ viewModel: SessionViewModel) -> [String: String] {
        var result: [String: String] = [:]
        for field in (viewModel.historyFillProbeValue ?? "").split(separator: ";") {
            let pair = field.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            result[String(pair[0])] = String(pair[1])
        }
        return result
    }

    private let fixtureEventCount = 60

    // MARK: - 成功路径

    @MainActor
    func testHistoryFillCompletesAutomaticallyToFirstEvent() async throws {
        let host = FakeHost(eventCount: fixtureEventCount)
        let viewModel = makeViewModel(host: host)
        XCTAssertEqual(viewModel.historyFillState, .idle)
        XCTAssertEqual(viewModel.oldestLoadedSeq, fixtureEventCount - 8)

        viewModel.historyPageLoader = loader(host: host)
        await viewModel.runHistoryFillForTesting()

        XCTAssertEqual(viewModel.historyFillState, .completed, "补齐完成：无 UI 的终态")
        XCTAssertEqual(viewModel.oldestLoadedSeq, 0, "必须补到会话第一条（seq 0）")
        XCTAssertEqual(viewModel.eventSeqs, Array(0..<fixtureEventCount), "窗口连续覆盖全量历史")
        XCTAssertEqual(Set(viewModel.eventSeqs).count, viewModel.eventSeqs.count, "不得重复")
        XCTAssertTrue(viewModel.reachedFirstEvent)
    }

    @MainActor
    func testHistoryFillMergesMultiplePagesWithCorrectWireArgs() async throws {
        // 400 events / ~266 条消息 > LAN 页预算 160 -> 必然跨多页。
        let host = FakeHost(eventCount: 400)
        let viewModel = makeViewModel(host: host, firstWindowMessages: 4)
        var requests: [[String: JSONValue]] = []
        viewModel.historyPageLoader = loader(host: host) { requests.append($0) }
        await viewModel.runHistoryFillForTesting()
        XCTAssertEqual(viewModel.oldestLoadedSeq, 0)
        XCTAssertEqual(viewModel.eventSeqs, Array(0..<400))
        XCTAssertGreaterThan(requests.count, 1, "跨多页补齐")
        var previousBeforeSeq: Int?
        for requestValue in requests {
            let request = try XCTUnwrap(requestValue["request"]?.objectValue)
            XCTAssertEqual(request["throughSeq"]?.intValue, 399, "throughSeq 固定为 journal cursor")
            XCTAssertNil(request["turnWindow"], "自动补齐不传 turnWindow")
            let beforeSeq = Int(try XCTUnwrap(request["beforeSeq"]?.intValue))
            if let previousBeforeSeq {
                XCTAssertLessThan(beforeSeq, previousBeforeSeq, "每页从新的窗口前沿继续向上")
            }
            previousBeforeSeq = beforeSeq
        }
    }

    @MainActor
    func testHistoryFillStopsWhenHostHasNoOlderHistory() async throws {
        let host = FakeHost(eventCount: 20)
        let viewModel = makeViewModel(host: host, firstWindowMessages: 12)
        var calls = 0
        viewModel.historyPageLoader = loader(host: host) { _ in calls += 1 }
        await viewModel.runHistoryFillForTesting()
        XCTAssertEqual(viewModel.oldestLoadedSeq, 0)
        XCTAssertEqual(viewModel.historyFillState, .completed)
        let callsAfterComplete = calls

        // 已完成后再次触发（视图重建 / 重连）不得再发请求。
        await viewModel.runHistoryFillForTesting()
        XCTAssertEqual(calls, callsAfterComplete, "completed 后补齐必须幂等（不发请求）")
    }

    @MainActor
    func testHistoryFillStopsOnEmptyPageInsteadOfRequestLoop() async throws {
        let host = FakeHost(eventCount: fixtureEventCount)
        let viewModel = makeViewModel(host: host, firstWindowMessages: 4)
        var calls = 0
        viewModel.historyPageLoader = { _ in
            calls += 1
            return .object(["records": .array([]), "hasMore": .bool(true)])
        }
        await viewModel.runHistoryFillForTesting()
        XCTAssertEqual(calls, 4, "空页按 1/2/4s 退避最多重试 3 次后终止，不能无限请求")
        XCTAssertEqual(viewModel.historyFillState, .completed)
        XCTAssertEqual(viewModel.oldestLoadedSeq, fixtureEventCount - 4, "空页没有前进")
        let callsAtCompletion = calls
        await viewModel.runHistoryFillForTesting()
        XCTAssertEqual(calls, callsAtCompletion, "completed 后空页不得再请求")
    }

    @MainActor
    func testHistoryFillRetriesEmptyPageWithBackoffThenSucceeds() async throws {
        // 2026-10-24 真机：Host 瞬时回空页时旧代码直接 completed，补齐永久停在
        // hasMoreOlder=1。新语义：1/2/4s 退避重试，拿到真页后继续补到 seq0。
        let host = FakeHost(eventCount: fixtureEventCount)
        let viewModel = makeViewModel(host: host, firstWindowMessages: 4)
        var calls = 0
        viewModel.historyPageLoader = { args in
            calls += 1
            if calls == 1 {
                return .object(["records": .array([]), "hasMore": .bool(true)])
            }
            return .object(try host.page(args: args))
        }
        await viewModel.runHistoryFillForTesting()
        XCTAssertEqual(calls, 2, "空页退避后必须重试，并在第二页成功")
        XCTAssertEqual(viewModel.historyFillState, .completed)
        XCTAssertEqual(viewModel.oldestLoadedSeq, 0, "重试成功后必须补到会话第一条")
        XCTAssertEqual(Set(viewModel.eventSeqs).count, viewModel.eventSeqs.count, "不得重复")
    }

    @MainActor
    func testHistoryFillWatchdogRestartsAfterTerminalFailure() async throws {
        // .failed 是确定性失败（loader 直接 throw）的终态；真机上它没有任何重试
        // 入口。watchdog 冷却后必须把 failed 置 idle 并重启，链路恢复即可补完。
        let host = FakeHost(eventCount: fixtureEventCount)
        let viewModel = makeViewModel(host: host, firstWindowMessages: 4)
        var calls = 0
        viewModel.historyPageLoader = { _ in
            calls += 1
            throw NSError(domain: "test", code: 7)
        }
        await viewModel.runHistoryFillForTesting()
        XCTAssertEqual(viewModel.historyFillState, .failed, "连续确定性失败进入 failed")
        XCTAssertGreaterThan(calls, 0)

        // 链路恢复（loader 可用）+ 冷却时间到 -> watchdog 自动重启并补完。
        viewModel.historyPageLoader = loader(host: host)
        viewModel.historyFillWatchdogCooldown = 0
        await viewModel.runHistoryFillWatchdogForTesting()
        XCTAssertEqual(viewModel.historyFillState, .completed)
        XCTAssertEqual(viewModel.oldestLoadedSeq, 0, "watchdog 恢复后必须补完")
        let fields = probe(viewModel)
        XCTAssertNotNil(fields["watchdogRestarts"], "probe 必须带 watchdogRestarts（真机取证字段）")
        XCTAssertNotEqual(fields["watchdogRestarts"], "0", "watchdog 至少重启过一次")
        XCTAssertNotNil(fields["lastProgressAt"], "probe 必须带 lastProgressAt（真机取证字段）")
    }

    @MainActor
    func testHistoryFillWatchdogDoesNotRestartAfterCompletion() async throws {
        let host = FakeHost(eventCount: fixtureEventCount)
        let viewModel = makeViewModel(host: host, firstWindowMessages: 4)
        var calls = 0
        viewModel.historyPageLoader = loader(host: host) { _ in calls += 1 }
        await viewModel.runHistoryFillForTesting()
        XCTAssertEqual(viewModel.historyFillState, .completed)
        let callsAtCompletion = calls

        viewModel.historyFillWatchdogCooldown = 0
        await viewModel.runHistoryFillWatchdogForTesting()
        XCTAssertEqual(calls, callsAtCompletion, "completed 后 watchdog 不得重启补齐")
        XCTAssertEqual(viewModel.historyFillState, .completed)
    }

    @MainActor
    func testHistoryFillSkipsWorkWhenFirstWindowAlreadyReachedOldest() async throws {
        let host = FakeHost(eventCount: 10)
        let viewModel = makeViewModel(host: host, firstWindowMessages: 20, hasMore: false) // 首窗覆盖全部
        var calls = 0
        viewModel.historyPageLoader = loader(host: host) { _ in calls += 1 }
        await viewModel.runHistoryFillForTesting()
        XCTAssertEqual(calls, 0, "首窗已覆盖 seq0 且 hasMore=false -> 不需要补齐")
        XCTAssertEqual(viewModel.oldestLoadedSeq, 0)
        XCTAssertTrue(viewModel.reachedFirstEvent)
    }

    // MARK: - 失败 / 离线 / 取消

    @MainActor
    func testHistoryFillRetriesAfterTransientFailure() async throws {
        let host = FakeHost(eventCount: fixtureEventCount)
        let viewModel = makeViewModel(host: host, firstWindowMessages: 4)
        var calls = 0
        viewModel.historyPageLoader = { args in
            calls += 1
            if calls == 1 { throw NSError(domain: "test", code: 1) }
            return .object(try host.page(args: args))
        }
        await viewModel.runHistoryFillForTesting()
        XCTAssertEqual(calls, 2, "单次失败后退避重试并成功")
        XCTAssertEqual(viewModel.historyFillState, .completed)
        XCTAssertEqual(viewModel.oldestLoadedSeq, 0)
    }

    @MainActor
    func testHistoryFillPausesWithoutTransportAndResumesAfterReconnect() async throws {
        let host = FakeHost(eventCount: fixtureEventCount)
        let viewModel = makeViewModel(host: host, firstWindowMessages: 4)
        // 无 loader 且无 link（等价断线）：补齐必须暂停而不是失败/报错。
        await viewModel.runHistoryFillForTesting()
        // 当前源码在「冷启动即无链路」时保持 idle（不报错、不发请求）；补齐进行中
        // 掉线才是 pausedOffline（E2E F1 覆盖）。这里先锁「不失败、不出 UI、窗口不动」。
        XCTAssertNotEqual(viewModel.historyFillState, .completed)
        XCTAssertNotEqual(viewModel.historyFillState, .failed, "断线不得进入 failed/错误态")
        XCTAssertEqual(viewModel.oldestLoadedSeq, fixtureEventCount - 4, "暂停期间窗口不动")

        // 重连：loader 可用后继续补齐（视图/链路恢复触发的同一入口）。
        viewModel.historyPageLoader = loader(host: host)
        await viewModel.runHistoryFillForTesting()
        XCTAssertEqual(viewModel.historyFillState, .completed)
        XCTAssertEqual(viewModel.oldestLoadedSeq, 0)
    }

    @MainActor
    func testHistoryFillCancelStopsRequestsAndKeepsWindow() async throws {
        let host = FakeHost(eventCount: fixtureEventCount)
        let viewModel = makeViewModel(host: host, firstWindowMessages: 4)
        var calls = 0
        viewModel.historyPageLoader = { args in
            calls += 1
            try? await Task.sleep(nanoseconds: 300_000_000)
            return .object(try host.page(args: args))
        }
        let fill = Task { await viewModel.runHistoryFillForTesting() }
        try? await Task.sleep(nanoseconds: 80_000_000)
        viewModel.stop()
        await fill.value
        let callsAtCancel = calls
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(calls, callsAtCancel, "取消后不得再发分页请求（视图消失/返回）")
        XCTAssertNotEqual(viewModel.historyFillState, .completed)
        XCTAssertLessThan(viewModel.oldestLoadedSeq ?? 0, fixtureEventCount, "取消不破坏已有窗口")
    }

    // MARK: - 补齐期间 live snapshot（并发流式帧）

    @MainActor
    func testHistoryFillSurvivesConcurrentLiveSnapshotWithoutDuplicates() async throws {
        let host = FakeHost(eventCount: fixtureEventCount)
        let viewModel = makeViewModel(host: host, firstWindowMessages: 4)
        viewModel.historyPageLoader = { args in
            try? await Task.sleep(nanoseconds: 60_000_000)
            return .object(try host.page(args: args))
        }
        let fill = Task { await viewModel.runHistoryFillForTesting() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        // live 尾部继续产事件：快照替换最新窗口（cursor 前移，内容连续）。
        let live = Array(host.events.suffix(6))
        viewModel.applyStreamValue(snapshotJSON(events: live, cursor: fixtureEventCount - 1, hasMore: true))
        await fill.value
        XCTAssertEqual(Set(viewModel.eventSeqs).count, viewModel.eventSeqs.count, "并发 snapshot 后不得重复 seq")
        XCTAssertEqual(viewModel.eventSeqs.sorted(), viewModel.eventSeqs, "窗口必须按 seq 升序")
        XCTAssertNotNil(viewModel.historyFillProbeValue)
    }

    // MARK: - E2E 探针契约

    @MainActor
    func testHistoryFillProbeContract() async throws {
        // 400 events 保证至少一次 .progress 合并（单页直接到底时 pages 语义见 VM 注释）。
        let host = FakeHost(eventCount: 400)
        let viewModel = makeViewModel(host: host, firstWindowMessages: 4)
        viewModel.historyPageLoader = loader(host: host)
        await viewModel.runHistoryFillForTesting()
        let value = try XCTUnwrap(viewModel.historyFillProbeValue)
        XCTAssertTrue(value.hasPrefix("state=completed;pages="), "E2E 探针前缀契约: \(value)")
        let fields = probe(viewModel)
        XCTAssertEqual(fields["state"], "completed")
        XCTAssertEqual(fields["oldest"], "0")
        XCTAssertEqual(fields["holes"], "0", "补齐后窗口必须无空洞")
        XCTAssertEqual(fields["hasMore"], "0")
        XCTAssertNotEqual(fields["pages"], "0", "至少合并了一页")
        XCTAssertEqual(fields["failures"], "0")
        XCTAssertNotNil(fields["ms"])
        XCTAssertNotNil(fields["rows"])
    }
}

// MARK: - P0: detail deferred open (link not ready → unbounded spinner)

/// `openStream()` cannot open while the link is down. The old code dropped that
/// open and relied on `generation` changing, which misses silent dsh-m/2 resumes
/// (P1 retain keeps the generation) and any phase flip that lands before the
/// view's `.onChange` is installed. These tests pin the bounded recovery policy:
/// wait while the link is busy → open exactly once when it is connected → surface
/// a retryable error after the deadline instead of spinning forever.
final class DeferredStreamOpenTests: XCTestCase {

    func testDeferredOpenWaitsWhileLinkIsBusy() {
        XCTAssertEqual(
            DeferredStreamOpenPolicy.action(
                phaseIsConnected: false,
                isDeferred: true,
                hasOpenStream: false,
                deadlineElapsed: false
            ),
            .wait,
            "a busy/reconnecting link must keep waiting, not fail early and not open"
        )
    }

    func testDeferredOpenOpensOnceWhenLinkBecomesConnected() {
        XCTAssertEqual(
            DeferredStreamOpenPolicy.action(
                phaseIsConnected: true,
                isDeferred: true,
                hasOpenStream: false,
                deadlineElapsed: false
            ),
            .open,
            "phase → connected must open the deferred session/follow once"
        )
    }

    func testDeferredOpenIsIdempotentWhenStreamAlreadyOpen() {
        // Covers the double trigger: the Combine phase sink and the view's
        // `.onChange(of: app.link.phase)` both fire for the same transition.
        XCTAssertEqual(
            DeferredStreamOpenPolicy.action(
                phaseIsConnected: true,
                isDeferred: true,
                hasOpenStream: true,
                deadlineElapsed: false
            ),
            .idle,
            "an already-open stream must never be reopened (frames would be dropped)"
        )
        XCTAssertEqual(
            DeferredStreamOpenPolicy.action(
                phaseIsConnected: true,
                isDeferred: true,
                hasOpenStream: true,
                deadlineElapsed: true
            ),
            .idle,
            "a late deadline must not fail a detail whose stream is already live"
        )
    }

    func testDeferredOpenFailsAfterDeadlineWhileStillOffline() {
        XCTAssertEqual(
            DeferredStreamOpenPolicy.action(
                phaseIsConnected: false,
                isDeferred: true,
                hasOpenStream: false,
                deadlineElapsed: true
            ),
            .fail,
            "after the budget the detail must show the retry entry, not an endless spinner"
        )
    }

    func testDeferredOpenWithoutDeferralIsIdle() {
        for connected in [true, false] {
            for elapsed in [true, false] {
                XCTAssertEqual(
                    DeferredStreamOpenPolicy.action(
                        phaseIsConnected: connected,
                        isDeferred: false,
                        hasOpenStream: false,
                        deadlineElapsed: elapsed
                    ),
                    .idle,
                    "nothing was deferred: the phase observer must be a no-op"
                )
            }
        }
    }

    @MainActor
    func testDeferredOpenBudgetIsBounded() {
        XCTAssertEqual(
            SessionViewModel.deferredStreamOpenTimeout,
            10,
            "P0 spec: a deferred detail open gives up after 10 s and shows retry"
        )
    }
}

/// 2026-10-23 冷启动 <1s（用户人工验收）的列表缓存策略：
/// - 「本地缓存 · 正在刷新…」只在刷新真正变慢（≥800ms）时出现，亚秒级刷新不闪文案；
/// - 缓存首帧期间对 live `session/list` 做有界重试（400→5000ms，最多 5 次），
///   让「桌面端重启后首次启动」这类连接慢启动窗口内的列表在 1s 级自愈。
@MainActor
final class CacheRefreshPolicyTests: XCTestCase {

    func testCacheRefreshBannerIsHiddenForFastRefresh() {
        XCTAssertFalse(WorkspaceViewModel.shouldShowCacheRefreshBanner(elapsedMs: 0))
        XCTAssertFalse(
            WorkspaceViewModel.shouldShowCacheRefreshBanner(elapsedMs: 799),
            "a sub-1s refresh must not flash the cache banner"
        )
        XCTAssertTrue(WorkspaceViewModel.shouldShowCacheRefreshBanner(elapsedMs: 800))
        XCTAssertTrue(WorkspaceViewModel.shouldShowCacheRefreshBanner(elapsedMs: 10_000))
        XCTAssertEqual(WorkspaceViewModel.cacheRefreshBannerDelayMs, 800)
    }

    func testStaleListRetryScheduleIsBoundedAndIncreasing() {
        let delays = WorkspaceViewModel.staleListRetryDelaysMs
        XCTAssertEqual(delays, [400, 800, 1600, 3200, 5_000])
        XCTAssertEqual(delays.count, 5, "bounded retries: no infinite polling")
        for (previous, next) in zip(delays, delays.dropFirst()) {
            XCTAssertLessThan(previous, next, "retry backoff must grow")
        }
        XCTAssertLessThanOrEqual(delays.last ?? 0, 5_000, "last retry stays inside the cold-start window")
    }
}
