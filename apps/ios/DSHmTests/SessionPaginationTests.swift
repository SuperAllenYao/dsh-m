import XCTest
@testable import DSHm

/// task session-history 门禁：`session/page` 向上分页的 fixture 单测（Host 不可用，
/// 全部由测试内的参考 Host 驱动）。
///
/// 协议语义已从 DSH 安装包的 session-controller 源码核实（2026-10-22）：
///   - `end = min(throughSeq + 1, beforeSeq ?? throughSeq + 1)` -> **beforeSeq 独有（exclusive）**，
///     throughSeq 含（inclusive）；
///   - records 是该 seq 区间的**全量事件**（turn/start、工具事件都在），不是纯消息；
///   - maxMessages 只数 append-origin 的 user/assistant 消息，工具组按 sourceEventSeqs
///     的 groupStart 归并，所以返回事件条数可以 > maxMessages；
///   - turnWindow 在 `turn/start` 处检查 `count >= minMessages && turns >= minTurns`，
///     先到 maxMessages 或历史耗尽则按前者；
///   - `hasMore = cut > 0`（页面最老下界 > 0 才有更早历史）。
///
/// `FixtureSessionHost` 是上述 `paginate` 的测试参考实现：它让状态机测试走真实的
/// 请求/响应形状（经 JSONValue 往返），并把 beforeSeq exclusive、页边界、hasMore 的
/// 语义一起锁死；同时校验客户端 wire 参数（缺键/键名错就直接失败）。
final class SessionPaginationTests: XCTestCase {

    // MARK: - Fixture host（Host paginate 的测试参考实现）

    struct FixtureHostError: Error, LocalizedError {
        var code: String
        var message: String
        var errorDescription: String? { "\(code): \(message)" }
    }

    final class FixtureSessionHost {
        let events: [SessionEvent]
        private let messageTypes: Set<String> = ["user/message", "assistant/message"]

        init(events: [SessionEvent]) {
            self.events = events
            XCTAssertEqual(events.map(\.seq), Array(0..<events.count), "fixture 必须是 dense 0-based 日志")
        }

        var cursor: Int { events.last?.seq ?? -1 }

        struct Page {
            var events: [SessionEvent]
            var hasMore: Bool
            var cut: Int
        }

        /// opening / reconnect 的 `session/follow` 快照帧。
        func openingSnapshot(
            maxMessages: Int,
            turnWindow: SessionWindowPolicy.TurnWindow?
        ) -> JSONValue {
            let page = paginate(
                throughSeq: cursor,
                beforeSeq: nil,
                maxMessages: maxMessages,
                turnWindow: turnWindow
            )
            return .object([
                "type": .string("snapshot"),
                "header": .object([
                    "version": .int(4),
                    "id": .string("fixture-session"),
                    "cwd": .string("/tmp/ws"),
                ]),
                "cursor": .int(Int64(cursor)),
                "records": .array(page.events.map(record)),
                "hasMore": .bool(page.hasMore),
                "projections": .object([
                    "asOfSeq": .int(Int64(cursor)),
                    "values": .object(["title": .string("Fixture session")]),
                ]),
                "assistantStream": .object(["revision": .int(0)]),
            ])
        }

        /// opening 快照的最老事件 seq（首个 page 之前客户端已加载的最老记录）。
        func openingOldest(maxMessages: Int, turnWindow: SessionWindowPolicy.TurnWindow?) -> Int? {
            paginate(throughSeq: cursor, beforeSeq: nil, maxMessages: maxMessages, turnWindow: turnWindow)
                .events.first?.seq
        }

        /// `session/page` 响应 `{records, hasMore}`。
        func page(
            throughSeq: Int,
            beforeSeq: Int?,
            maxMessages: Int,
            turnWindow: SessionWindowPolicy.TurnWindow?
        ) throws -> JSONValue {
            // 与 Host 相同的入参校验（顺序/错误码无关紧要，只锁拒绝行为）。
            guard throughSeq >= -1 else {
                throw FixtureHostError(code: "gateway/bad-request", message: "throughSeq must be an integer greater than or equal to -1")
            }
            guard throughSeq <= cursor else {
                throw FixtureHostError(code: "gateway/bad-request", message: "session page through seq \(throughSeq) is past cursor \(cursor)")
            }
            if let beforeSeq, beforeSeq < 0 {
                throw FixtureHostError(code: "gateway/bad-request", message: "beforeSeq must be a non-negative safe integer")
            }
            guard maxMessages > 0 else {
                throw FixtureHostError(code: "gateway/bad-request", message: "maxMessages must be a positive safe integer")
            }
            if let turnWindow {
                guard turnWindow.minMessages > 0,
                      turnWindow.minMessages <= maxMessages else {
                    throw FixtureHostError(code: "gateway/bad-request", message: "turnWindow.minMessages must be a positive safe integer no greater than maxMessages")
                }
                guard turnWindow.minTurns > 0 else {
                    throw FixtureHostError(code: "gateway/bad-request", message: "turnWindow.minTurns must be a positive safe integer")
                }
            }
            let page = paginate(
                throughSeq: throughSeq,
                beforeSeq: beforeSeq,
                maxMessages: maxMessages,
                turnWindow: turnWindow
            )
            return .object([
                "records": .array(page.events.map(record)),
                "hasMore": .bool(page.hasMore),
            ])
        }

        /// Host session-controller 的 `paginate` 逐行移植。
        func paginate(
            throughSeq: Int,
            beforeSeq: Int?,
            maxMessages: Int,
            turnWindow: SessionWindowPolicy.TurnWindow?
        ) -> Page {
            let end = min(throughSeq + 1, beforeSeq ?? (throughSeq + 1))
            var count = 0
            var turns = 0
            var cut = 0
            if end > 0 {
                for index in stride(from: end - 1, through: 0, by: -1) {
                    let event = events[index]
                    if let turnWindow, event.type == "turn/start" {
                        turns += 1
                        if count >= turnWindow.minMessages && turns >= turnWindow.minTurns {
                            cut = index
                            break
                        }
                    }
                    guard messageTypes.contains(event.type), isAppendSurfaceEvent(event) else { continue }
                    count += 1
                    var groupStart = event.seq
                    for source in event.sourceEventSeqs ?? [] where source < groupStart {
                        groupStart = source
                    }
                    if count >= maxMessages {
                        cut = groupStart
                        break
                    }
                }
            }
            return Page(events: Array(events[cut..<max(end, cut)]), hasMore: cut > 0, cut: cut)
        }

        /// 当前 surface 的 append 事件（Host: isSurfaceEvent && surfaceOp === "append"）。
        private func isAppendSurfaceEvent(_ event: SessionEvent) -> Bool {
            guard let op = event.surfaceOp else { return false }
            if let value = op.stringValue { return value == "append" }
            return op["op"]?.stringValue == "append"
        }

        private func record(_ event: SessionEvent) -> JSONValue {
            .object(["type": .string("event"), "event": wireValue(event)])
        }

        private func wireValue(_ event: SessionEvent) -> JSONValue {
            let data = try! JSONEncoder().encode(event)
            return try! JSONValue.jsonObject(from: data)
        }
    }

    // MARK: - Fixtures

    /// 40 个 turn、每个 turn 6 个事件（turn/start、user、tool/call、tool/result、
    /// assistant、turn/end）= 240 个 dense 事件 / 80 条 append 消息；首窗 16 条消息
    /// 只覆盖最近 8 个 turn，向后分页需要 2 页才能到 seq 0。
    private func fixtureEvents(turns: Int = 40) -> [SessionEvent] {
        var events: [SessionEvent] = []
        var seq = 0
        for turn in 1...turns {
            events.append(event("turn/start", seq: seq, data: .object(["turn": .int(Int64(turn))])))
            seq += 1
            events.append(event("user/message", seq: seq, append: true, data: .object(["content": .array([])])))
            seq += 1
            events.append(event("tool/call", seq: seq, data: .object(["callId": .string("call-\(turn)")])))
            seq += 1
            events.append(event("tool/result", seq: seq, data: .object(["callId": .string("call-\(turn)")])))
            seq += 1
            events.append(event("assistant/message", seq: seq, append: true, data: .object(["message": .object(["content": .array([])])])))
            seq += 1
            events.append(event("turn/end", seq: seq, data: .object(["turn": .int(Int64(turn))])))
            seq += 1
        }
        return events
    }

    private func event(
        _ type: String,
        seq: Int,
        append: Bool = false,
        data: JSONValue? = nil,
        sources: [Int]? = nil
    ) -> SessionEvent {
        SessionEvent(
            type: type,
            seq: seq,
            time: 1_792_510_000_000 + Int64(seq),
            data: data,
            surfaceOp: append ? .string("append") : nil,
            sourceEventSeqs: sources
        )
    }

    private func makeStore() -> SessionWindowCacheStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionPaginationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return SessionWindowCacheStore(directory: directory, identity: { "pagination-tests" })
    }

    @MainActor
    private func makeViewModel(
        host: FixtureSessionHost,
        store: SessionWindowCacheStore,
        firstWindow: Int = 16
    ) -> SessionViewModel {
        let viewModel = SessionViewModel(address: .session(sessionId: "fixture"), windowCache: store)
        viewModel.applyStreamValue(host.openingSnapshot(
            maxMessages: firstWindow,
            turnWindow: SessionWindowPolicy.firstWindowTurnWindow(messages: firstWindow)
        ))
        return viewModel
    }

    /// 生产 loader 的替身：从 wire args 里取 throughSeq/beforeSeq/maxMessages/turnWindow
    /// 并交给参考 Host —— 参数键名/类型错就直接失败，等于把 wire 契约纳入门禁。
    private func hostLoader(
        host: FixtureSessionHost,
        onRequest: @escaping (Int, Int) -> Void = { _, _ in }
    ) -> ([String: JSONValue]) async throws -> JSONValue {
        { args in
            guard let request = args["request"]?.objectValue else {
                throw FixtureHostError(code: "client/bad-request", message: "missing request")
            }
            let throughSeq = Int(try Self.requireInt(request, "throughSeq"))
            let beforeSeq = Int(try Self.requireInt(request, "beforeSeq"))
            let maxMessages = Int(try Self.requireInt(request, "maxMessages"))
            guard let window = request["turnWindow"]?.objectValue else {
                throw FixtureHostError(code: "client/bad-request", message: "missing turnWindow")
            }
            let turnWindow = SessionWindowPolicy.TurnWindow(
                minMessages: Int(try Self.requireInt(window, "minMessages")),
                minTurns: Int(try Self.requireInt(window, "minTurns"))
            )
            onRequest(throughSeq, beforeSeq)
            return try host.page(
                throughSeq: throughSeq,
                beforeSeq: beforeSeq,
                maxMessages: maxMessages,
                turnWindow: turnWindow
            )
        }
    }

    private static func requireInt(_ object: [String: JSONValue], _ key: String) throws -> Int64 {
        guard let value = object[key]?.intValue else {
            throw FixtureHostError(code: "client/bad-request", message: "missing \(key)")
        }
        return value
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - 1. wire 参数精确匹配 Host schema

    func testOlderPageRequestMatchesHostSchemaExactly() throws {
        let args = SessionViewModel.olderPageRequestArgs(
            address: .session(sessionId: "s1"),
            throughSeq: 42,
            beforeSeq: 7
        )
        XCTAssertEqual(Set(args.keys), Set(["request"]))
        let request = try XCTUnwrap(args["request"]?.objectValue)
        XCTAssertEqual(
            Set(request.keys),
            Set(["address", "throughSeq", "beforeSeq", "maxMessages", "turnWindow"]),
            "键名必须与 Host 的 session/page schema 逐字一致"
        )
        XCTAssertEqual(
            request["address"],
            .object(["kind": .string("session"), "sessionId": .string("s1")])
        )
        XCTAssertEqual(request["throughSeq"]?.intValue, 42)
        XCTAssertEqual(request["beforeSeq"]?.intValue, 7)
        XCTAssertEqual(request["maxMessages"]?.intValue, Int64(SessionWindowPolicy.pageWindowMessages))
        XCTAssertTrue((40...60).contains(SessionWindowPolicy.pageWindowMessages))

        let window = try XCTUnwrap(request["turnWindow"]?.objectValue)
        XCTAssertEqual(Set(window.keys), Set(["minMessages", "minTurns"]))
        XCTAssertEqual(window["minMessages"]?.intValue, Int64(SessionWindowPolicy.pageTurnWindow.minMessages))
        XCTAssertEqual(window["minTurns"]?.intValue, Int64(SessionWindowPolicy.pageTurnWindow.minTurns))
        XCTAssertLessThanOrEqual(
            SessionWindowPolicy.pageTurnWindow.minMessages,
            SessionWindowPolicy.pageWindowMessages,
            "Host 校验: turnWindow.minMessages <= maxMessages"
        )
        XCTAssertGreaterThanOrEqual(SessionWindowPolicy.pageTurnWindow.minTurns, 6)

        // 子会话（Agent Teams 成员）用 durable parent 地址。
        let subagentArgs = SessionViewModel.olderPageRequestArgs(
            address: .subagent(parentSessionId: "p", childSessionId: "c", mode: "unknown"),
            throughSeq: 3,
            beforeSeq: 1
        )
        XCTAssertEqual(
            subagentArgs["request"]?["address"],
            .object([
                "kind": .string("subagent"),
                "parentSessionId": .string("p"),
                "childSessionId": .string("c"),
                "mode": .string("unknown"),
            ])
        )
    }

    // MARK: - 2. 连续加载到第一条事件：无空洞、无重复请求、停在 hasMore=false

    @MainActor
    func testPagingWalksBackToFirstEventWithoutHoles() async throws {
        let host = FixtureSessionHost(events: fixtureEvents())
        let viewModel = makeViewModel(host: host, store: makeStore(), firstWindow: 16)
        XCTAssertTrue(viewModel.hasMoreOlder, "follow 首帧 hasMore=true -> 视图才会触发\"加载更早\"")
        let openingOldest = try XCTUnwrap(viewModel.oldestLoadedSeq)
        XCTAssertEqual(openingOldest, host.openingOldest(
            maxMessages: 16,
            turnWindow: SessionWindowPolicy.firstWindowTurnWindow(messages: 16)
        ))

        var requests: [(throughSeq: Int, beforeSeq: Int)] = []
        viewModel.olderPageLoader = hostLoader(host: host) { throughSeq, beforeSeq in
            requests.append((throughSeq, beforeSeq))
        }

        var iterations = 0
        while viewModel.hasMoreOlder {
            iterations += 1
            XCTAssertLessThan(iterations, 20, "分页循环必须有界")
            await viewModel.loadOlderPageNowForTesting()
            let seqs = viewModel.eventSeqs
            XCTAssertEqual(Set(seqs).count, seqs.count, "窗口内不得出现重复 seq")
            XCTAssertEqual(seqs, Array(seqs.first!...seqs.last!), "每次前置合并后窗口必须无空洞")
        }

        XCTAssertEqual(viewModel.eventSeqs, Array(0...host.cursor), "必须一路加载到第一条事件（seq 0）")
        XCTAssertEqual(viewModel.oldestLoadedSeq, 0)
        XCTAssertGreaterThanOrEqual(iterations, 2, "144 事件的会话首窗只覆盖最近一段，需要多页")

        XCTAssertEqual(
            requests.map(\.throughSeq),
            Array(repeating: host.cursor, count: requests.count),
            "throughSeq 全程使用 follow 首帧 cursor"
        )
        XCTAssertEqual(requests.first?.beforeSeq, openingOldest, "首页 beforeSeq = 当前最老已加载 seq")
        XCTAssertEqual(
            requests.map(\.beforeSeq),
            requests.map(\.beforeSeq).sorted(by: >),
            "beforeSeq 必须严格向后走"
        )
        XCTAssertEqual(
            Set(requests.map(\.beforeSeq)).count,
            requests.count,
            "不重复请求同一页"
        )
        XCTAssertFalse(requests.contains { $0.beforeSeq == 0 }, "beforeSeq=0 永远不发（到 0 后 hasMore=false 停止）")
    }

    // MARK: - 3. 视图契约：重复/高频调用与并发去重

    @MainActor
    func testLoadOlderIfNeededDeduplicatesConcurrentCalls() async throws {
        let host = FixtureSessionHost(events: fixtureEvents())
        let viewModel = makeViewModel(host: host, store: makeStore(), firstWindow: 16)
        var calls: [[String: JSONValue]] = []
        var gate: CheckedContinuation<Void, Never>?
        let delegate = hostLoader(host: host)
        viewModel.olderPageLoader = { args in
            calls.append(args)
            await withCheckedContinuation { gate = $0 }
            return try await delegate(args)
        }

        viewModel.loadOlderIfNeeded()
        await waitUntil { !calls.isEmpty }
        // 高频道重复调用（滚动回调）不允许叠加请求。
        viewModel.loadOlderIfNeeded()
        viewModel.loadOlderIfNeeded()
        viewModel.loadOlderIfNeeded()
        XCTAssertEqual(calls.count, 1, "并发去重：同一时间只有一个请求")
        XCTAssertTrue(viewModel.isLoadingOlder)

        gate?.resume()
        gate = nil
        await waitUntil { !viewModel.isLoadingOlder }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(viewModel.eventSeqs, Array(viewModel.eventSeqs.first!...host.cursor))

        // 加载完成后再次上滑：下一请求用新的最老 seq。
        viewModel.loadOlderIfNeeded()
        await waitUntil { calls.count == 2 }
        gate?.resume()
        gate = nil
        await waitUntil { !viewModel.isLoadingOlder }
        XCTAssertEqual(calls.count, 2)
    }

    // MARK: - 4. 失败可重试、不破坏窗口、走 actionErrorText

    @MainActor
    func testFailedPageKeepsWindowAndIsRetryable() async throws {
        let host = FixtureSessionHost(events: fixtureEvents())
        let viewModel = makeViewModel(host: host, store: makeStore(), firstWindow: 16)
        let before = viewModel.eventSeqs
        let oldestBefore = try XCTUnwrap(viewModel.oldestLoadedSeq)
        let delegate = hostLoader(host: host)
        var attempts = 0
        viewModel.olderPageLoader = { args in
            attempts += 1
            if attempts == 1 {
                throw FixtureHostError(code: "transport", message: "连接中断")
            }
            return try await delegate(args)
        }

        await viewModel.loadOlderPageNowForTesting()
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(viewModel.hasMoreOlder, "失败后必须允许重试")
        XCTAssertFalse(viewModel.isLoadingOlder)
        XCTAssertNotNil(viewModel.actionErrorText, "失败用现有 actionErrorText 呈现，不弹 alert")
        XCTAssertEqual(viewModel.eventSeqs, before, "分页失败不得破坏当前窗口")
        XCTAssertEqual(viewModel.oldestLoadedSeq, oldestBefore)

        await viewModel.loadOlderPageNowForTesting()
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(viewModel.actionErrorText, "成功一次后清掉分页错误")
        let oldestAfter = try XCTUnwrap(viewModel.oldestLoadedSeq)
        XCTAssertLessThan(oldestAfter, oldestBefore, "重试成功后向前合并了一页")
        XCTAssertEqual(
            viewModel.eventSeqs,
            Array(oldestAfter...(before.last ?? 0)),
            "窗口保持连续、不丢最新一段"
        )
        XCTAssertTrue(viewModel.hasMoreOlder, "首窗 + 一页仍未到 seq 0")
    }

    // MARK: - 5. 没有更早历史时立即 no-op

    @MainActor
    func testLoadOlderIfNeededIsNoOpWithoutOlderHistory() async throws {
        let host = FixtureSessionHost(events: fixtureEvents(turns: 2))
        let viewModel = makeViewModel(host: host, store: makeStore(), firstWindow: 16)
        XCTAssertFalse(viewModel.hasMoreOlder, "短会话首帧 hasMore=false")

        var calls = 0
        viewModel.olderPageLoader = { _ in
            calls += 1
            return .object([:])
        }
        viewModel.loadOlderIfNeeded()
        viewModel.loadOlderIfNeeded()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(calls, 0, "hasMoreOlder=false 立即 no-op，不发请求")
        XCTAssertFalse(viewModel.isLoadingOlder)
    }

    // MARK: - 6. 空页/异常页不得造成死循环

    @MainActor
    func testEmptyPageStopsPagingInsteadOfRequestingForever() async throws {
        let host = FixtureSessionHost(events: fixtureEvents())
        let viewModel = makeViewModel(host: host, store: makeStore(), firstWindow: 16)
        var calls = 0
        viewModel.olderPageLoader = { _ in
            calls += 1
            return .object(["records": .array([]), "hasMore": .bool(true)])
        }
        await viewModel.loadOlderPageNowForTesting()
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(viewModel.hasMoreOlder, "空页必须终止分页")
        await viewModel.loadOlderPageNowForTesting()
        XCTAssertEqual(calls, 1, "终止后 loadOlderIfNeeded 是 no-op")
    }

    @MainActor
    func testHostBadRequestSurfacesWithoutLosingWindow() async throws {
        let host = FixtureSessionHost(events: fixtureEvents())
        let viewModel = makeViewModel(host: host, store: makeStore(), firstWindow: 16)
        let before = viewModel.eventSeqs
        viewModel.olderPageLoader = { _ in
            // Host 校验：throughSeq 越过 cursor。
            try host.page(
                throughSeq: host.cursor + 100,
                beforeSeq: nil,
                maxMessages: 40,
                turnWindow: SessionWindowPolicy.pageTurnWindow
            )
        }
        await viewModel.loadOlderPageNowForTesting()
        XCTAssertNotNil(viewModel.actionErrorText)
        XCTAssertEqual(viewModel.eventSeqs, before)
        XCTAssertTrue(viewModel.hasMoreOlder)

        // 换成正常 loader 后仍可恢复分页（窗口没有被破坏）。
        viewModel.olderPageLoader = hostLoader(host: host)
        await viewModel.loadOlderPageNowForTesting()
        XCTAssertNil(viewModel.actionErrorText)
        XCTAssertLessThan(viewModel.oldestLoadedSeq ?? Int.max, before.first ?? 0)
    }

    // MARK: - 7. 分页与重连 snapshot 共存

    @MainActor
    func testPagingSurvivesReconnectSnapshot() async throws {
        let host = FixtureSessionHost(events: fixtureEvents())
        let viewModel = makeViewModel(host: host, store: makeStore(), firstWindow: 16)
        viewModel.olderPageLoader = hostLoader(host: host)

        await viewModel.loadOlderPageNowForTesting()
        let loadedBeforeReconnect = viewModel.eventSeqs
        XCTAssertGreaterThan(loadedBeforeReconnect.count, 20)

        // 重连：新快照窗口仍是最新一段（与已加载区间重叠）。
        viewModel.applyStreamValue(host.openingSnapshot(
            maxMessages: 16,
            turnWindow: SessionWindowPolicy.firstWindowTurnWindow(messages: 16)
        ))
        XCTAssertEqual(viewModel.eventSeqs, loadedBeforeReconnect, "重连不得丢掉已加载历史")
        XCTAssertEqual(viewModel.oldestLoadedSeq, loadedBeforeReconnect.first)

        while viewModel.hasMoreOlder {
            await viewModel.loadOlderPageNowForTesting()
        }
        XCTAssertEqual(viewModel.eventSeqs, Array(0...host.cursor))
        XCTAssertEqual(viewModel.oldestLoadedSeq, 0)
    }

    // MARK: - 8. 冷启动：分页结果进缓存、下次打开不退化

    @MainActor
    func testPagedHistorySurvivesCacheRoundTripAndColdOpen() async throws {
        let host = FixtureSessionHost(events: fixtureEvents())
        let store = makeStore()
        let viewModel = makeViewModel(host: host, store: store, firstWindow: 16)
        viewModel.olderPageLoader = hostLoader(host: host)
        while viewModel.hasMoreOlder {
            await viewModel.loadOlderPageNowForTesting()
        }
        XCTAssertEqual(viewModel.eventSeqs, Array(0...host.cursor))
        viewModel.saveWindowCacheNow()

        let reopened = SessionViewModel(address: .session(sessionId: "fixture"), windowCache: store)
        XCTAssertTrue(reopened.isShowingCachedWindow)
        XCTAssertEqual(reopened.eventSeqs, Array(0...host.cursor), "冷启动恢复已加载区间，不退回 40 条窗口")
        XCTAssertEqual(reopened.oldestLoadedSeq, 0)
        XCTAssertFalse(reopened.hasMoreOlder)
    }

    // MARK: - 9. 参考 Host 语义（锁 beforeSeq exclusive / 工具组 / turnWindow）

    func testFixtureHostPaginateMatchesVerifiedHostSemantics() {
        let host = FixtureSessionHost(events: fixtureEvents(turns: 6))
        let noWindow = host.paginate(throughSeq: host.cursor, beforeSeq: nil, maxMessages: 5, turnWindow: nil)
        XCTAssertEqual(noWindow.events.last?.seq, host.cursor, "end 含 throughSeq")
        XCTAssertEqual(noWindow.events.filter { $0.type == "user/message" || $0.type == "assistant/message" }.count, 5)
        XCTAssertTrue(noWindow.hasMore)

        // beforeSeq exclusive：绝不返回 seq >= beforeSeq 的事件。
        let boundary = noWindow.events.first!.seq
        let older = host.paginate(throughSeq: host.cursor, beforeSeq: boundary, maxMessages: 5, turnWindow: nil)
        XCTAssertTrue(older.events.allSatisfy { $0.seq < boundary })
        XCTAssertEqual(older.events.last?.seq, boundary - 1, "页尾紧贴 beforeSeq - 1，两页无重叠")
        XCTAssertTrue(older.hasMore)

        // 历史耗尽：cut == 0 -> hasMore = false。
        let all = host.paginate(throughSeq: host.cursor, beforeSeq: nil, maxMessages: 10_000, turnWindow: nil)
        XCTAssertEqual(all.cut, 0)
        XCTAssertFalse(all.hasMore)

        // maxMessages=1 + sourceEventSeqs 工具组：cut 落在 groupStart（可能不是消息）。
        var withGroup = fixtureEvents(turns: 1)
        // 在 assistant/message 上挂 sourceEventSeqs，指向更早的工具事件。
        let assistantSeq = withGroup.first { $0.type == "assistant/message" }!.seq
        withGroup[assistantSeq] = SessionEvent(
            type: "assistant/message",
            seq: assistantSeq,
            time: withGroup[assistantSeq].time,
            data: withGroup[assistantSeq].data,
            surfaceOp: .string("append"),
            sourceEventSeqs: [assistantSeq - 1]
        )
        let groupedHost = FixtureSessionHost(events: withGroup)
        let grouped = groupedHost.paginate(throughSeq: groupedHost.cursor, beforeSeq: nil, maxMessages: 1, turnWindow: nil)
        XCTAssertEqual(grouped.cut, assistantSeq - 1, "maxMessages 截断时按 sourceEventSeqs 的 groupStart 切")
        XCTAssertEqual(grouped.events.first?.seq, assistantSeq - 1)

        // turnWindow 组合：够 minMessages + minTurns 后停在 turn/start 起点。
        let turning = host.paginate(
            throughSeq: host.cursor,
            beforeSeq: nil,
            maxMessages: 20,
            turnWindow: SessionWindowPolicy.TurnWindow(minMessages: 8, minTurns: 2)
        )
        XCTAssertEqual(turning.events.first?.type, "turn/start", "turnWindow 生效时页首对齐 turn 起点")
        XCTAssertGreaterThanOrEqual(turning.events.filter { $0.type == "turn/start" }.count, 2)
        let messageCount = turning.events.filter { $0.type == "user/message" || $0.type == "assistant/message" }.count
        XCTAssertGreaterThanOrEqual(messageCount, 8)
        XCTAssertLessThanOrEqual(messageCount, 20)

        // 参数校验与 Host 一致。
        XCTAssertThrowsError(try host.page(
            throughSeq: host.cursor + 1,
            beforeSeq: nil,
            maxMessages: 10,
            turnWindow: nil
        ), "throughSeq 越过 cursor 必须被拒绝")
        XCTAssertThrowsError(try host.page(
            throughSeq: host.cursor,
            beforeSeq: 0,
            maxMessages: 10,
            turnWindow: SessionWindowPolicy.TurnWindow(minMessages: 11, minTurns: 1)
        ), "minMessages > maxMessages 必须被拒绝")
    }

    // MARK: - 10. task-6：到达最早事件后必须终止分页

    /// 事件序列 [0..N] 上连续 session/page 直到覆盖 seq 0：必须彻底终止。
    @MainActor
    func testReachingFirstEventTerminatesPaginationForGood() async throws {
        let host = FixtureSessionHost(events: fixtureEvents())
        let store = makeStore()
        let viewModel = makeViewModel(host: host, store: store, firstWindow: 16)
        var requests: [(throughSeq: Int, beforeSeq: Int)] = []
        viewModel.olderPageLoader = hostLoader(host: host) { throughSeq, beforeSeq in
            requests.append((throughSeq, beforeSeq))
        }

        var iterations = 0
        while viewModel.hasMoreOlder {
            iterations += 1
            XCTAssertLessThan(iterations, 20, "分页循环必须有界")
            await viewModel.loadOlderPageNowForTesting()
        }

        XCTAssertEqual(viewModel.oldestLoadedSeq, 0, "必须覆盖到首条事件 seq 0")
        XCTAssertEqual(viewModel.eventSeqs, Array(0...host.cursor))
        XCTAssertTrue(viewModel.reachedFirstEvent, "已到最早应置粘滞终止位")
        XCTAssertFalse(viewModel.hasMoreOlder, "到达最早后 hasMoreOlder 必须为 false")
        XCTAssertFalse(viewModel.isLoadingOlder)
        XCTAssertFalse(requests.contains { $0.beforeSeq == 0 }, "永不发 beforeSeq=0 的请求")

        // 高频重复调用（下拉手势/按钮连点）不再发请求，也不会留加载态。
        let requestsAtTermination = requests.count
        for _ in 0..<20 { viewModel.loadOlderIfNeeded() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(requests.count, requestsAtTermination, "到达最早后不得再发 session/page")
        XCTAssertFalse(viewModel.hasMoreOlder)
        XCTAssertFalse(viewModel.isLoadingOlder)
    }

    /// Host 保守/异常边界：一页已经含 seq 0，却仍报 hasMore=true —— 也必须收敛。
    @MainActor
    func testConservativePageContainingFirstEventConverges() async throws {
        let host = FixtureSessionHost(events: fixtureEvents())
        let viewModel = makeViewModel(host: host, store: makeStore(), firstWindow: 16)
        let openingOldest = try XCTUnwrap(viewModel.oldestLoadedSeq)
        var calls = 0
        viewModel.olderPageLoader = { _ in
            calls += 1
            let records: [JSONValue] = (0..<openingOldest).map { seq in
                .object(["type": .string("event"), "event": self.wireEvent(host.events[seq])])
            }
            return .object(["records": .array(records), "hasMore": .bool(true)])
        }

        await viewModel.loadOlderPageNowForTesting()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(viewModel.oldestLoadedSeq, 0)
        XCTAssertFalse(viewModel.hasMoreOlder, "page.hasMore=true 但页内已含 seq 0 必须收敛")
        XCTAssertFalse(viewModel.isLoadingOlder)

        // 后续调用不再请求。
        await viewModel.loadOlderPageNowForTesting()
        viewModel.loadOlderIfNeeded()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(viewModel.hasMoreOlder)
    }

    /// Lead 回归 (a)：分页到 seq 0 后，来一个 preserved.isEmpty（不连续窗口）且
    /// hasMore=true 的新快照 —— 终止状态不得被重新武装。
    @MainActor
    func testTerminatedPaginationSurvivesDiscontinuousSnapshot() async throws {
        let host = FixtureSessionHost(events: fixtureEvents())
        let viewModel = makeViewModel(host: host, store: makeStore(), firstWindow: 16)
        var calls = 0
        viewModel.olderPageLoader = hostLoader(host: host) { _, _ in calls += 1 }
        while viewModel.hasMoreOlder { await viewModel.loadOlderPageNowForTesting() }
        XCTAssertFalse(viewModel.hasMoreOlder)

        // 窗口整体跳到更晚的一段（与已加载 0...239 不连续）：preserved.isEmpty 分支。
        let laterHost = FixtureSessionHost(events: fixtureEvents(turns: 80))
        viewModel.applyStreamValue(laterHost.openingSnapshot(
            maxMessages: 16,
            turnWindow: SessionWindowPolicy.firstWindowTurnWindow(messages: 16)
        ))
        XCTAssertGreaterThan(try XCTUnwrap(viewModel.oldestLoadedSeq), 0, "窗口按不连续策略被替换")
        XCTAssertTrue(viewModel.reachedFirstEvent, "粘滞位不因窗口替换而回退")
        XCTAssertFalse(viewModel.hasMoreOlder, "新快照 hasMore=true 不得复活入口")

        let callsAfterSnapshot = calls
        for _ in 0..<10 { viewModel.loadOlderIfNeeded() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(calls, callsAfterSnapshot, "终止后不再发请求")
    }

    /// Lead 回归 (b)：缓存恢复（含旧 v3 schema 缺粘滞字段）后若已到 seq 0 → false
    /// 且 loadOlderIfNeeded 不再发请求。
    @MainActor
    func testCachedWindowAtFirstEventRestoresTerminated() async throws {
        let host = FixtureSessionHost(events: fixtureEvents())
        let store = makeStore()
        let viewModel = makeViewModel(host: host, store: store, firstWindow: 16)
        viewModel.olderPageLoader = hostLoader(host: host)
        while viewModel.hasMoreOlder { await viewModel.loadOlderPageNowForTesting() }
        XCTAssertTrue(viewModel.reachedFirstEvent)
        viewModel.saveWindowCacheNow()

        // 旧 v3 payload：没有 hasReachedOldest 字段，必须按 oldestSeq==0 推导。
        var legacy = try XCTUnwrap(store.load(sessionId: "fixture")?.payload)
        legacy.schemaVersion = SessionWindowCacheStore.olderRangeSchemaVersion
        legacy.hasReachedOldest = nil
        XCTAssertTrue(CacheIO.writeAtomically(legacy, to: store.fileURL(for: "fixture")))

        let reopened = SessionViewModel(address: .session(sessionId: "fixture"), windowCache: store)
        XCTAssertTrue(reopened.isShowingCachedWindow)
        XCTAssertEqual(reopened.oldestLoadedSeq, 0)
        XCTAssertTrue(reopened.reachedFirstEvent, "旧 schema 按已到 seq 0 推导粘滞终止")
        XCTAssertFalse(reopened.hasMoreOlder)

        var calls = 0
        reopened.olderPageLoader = { _ in calls += 1; return .object([:]) }
        for _ in 0..<10 { reopened.loadOlderIfNeeded() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(calls, 0, "恢复后已到最早，loadOlderIfNeeded 不得发请求")
        XCTAssertFalse(reopened.hasMoreOlder)
        XCTAssertFalse(reopened.isLoadingOlder)
    }

    private func wireEvent(_ event: SessionEvent) -> JSONValue {
        let data = try! JSONEncoder().encode(event)
        return try! JSONValue.jsonObject(from: data)
    }

    /// task-7 (c) + task-10：非相邻/带洞的页不得插入窗口；自动用最新 front
    /// 重试一次，仍失败则必须给出可见错误（不能静默 no-op），入口保持可重试。
    @MainActor
    func testNonAdjacentPageIsRejectedWithoutPunchingHole() async throws {
        let host = FixtureSessionHost(events: fixtureEvents())
        let viewModel = makeViewModel(host: host, store: makeStore(), firstWindow: 16)
        let before = viewModel.eventSeqs
        let oldestBefore = try XCTUnwrap(viewModel.oldestLoadedSeq)
        var calls = 0
        viewModel.olderPageLoader = { _ in
            calls += 1
            // 与当前最老 seq 之间缺了 6...oldestBefore-1：整页拒绝。
            let records: [JSONValue] = (0..<6).map { seq in
                .object(["type": .string("event"), "event": self.wireEvent(host.events[seq])])
            }
            return .object(["records": .array(records), "hasMore": .bool(true)])
        }
        await viewModel.loadOlderPageNowForTesting()
        XCTAssertEqual(calls, 2, "一次自动重试后仍被拒")
        XCTAssertEqual(viewModel.eventSeqs, before, "带洞的页不得插入")
        XCTAssertEqual(viewModel.oldestLoadedSeq, oldestBefore)
        XCTAssertNotNil(viewModel.actionErrorText, "静默失败不允许：被拒必须可见")
        XCTAssertTrue(viewModel.hasMoreOlder, "拒绝后保持可重试")
        XCTAssertFalse(viewModel.isLoadingOlder)

        // 换成相邻的正确页后可以继续分页。
        viewModel.olderPageLoader = hostLoader(host: host)
        await viewModel.loadOlderPageNowForTesting()
        let newOldest = try XCTUnwrap(viewModel.oldestLoadedSeq)
        XCTAssertLessThan(newOldest, oldestBefore)
        XCTAssertEqual(viewModel.eventSeqs, Array(newOldest...host.cursor))
    }

    // MARK: - 9. Silent-failure guard (task-10 bug2b, real-device 2026-10-22)

    /// A stale/non-adjacent page (the window front moved while the request was in
    /// flight) must be retried once against the fresh front, not silently dropped:
    /// the user saw the spinner but no older rows ever appeared.
    @MainActor
    func testStaleNonAdjacentPageRetriesWithFreshFrontThenMerges() async throws {
        let host = FixtureSessionHost(events: fixtureEvents())
        let viewModel = makeViewModel(host: host, store: makeStore(), firstWindow: 16)
        let oldestBefore = try XCTUnwrap(viewModel.oldestLoadedSeq)
        let newestBefore = try XCTUnwrap(viewModel.eventSeqs.last)
        var calls = 0
        let normalLoader = hostLoader(host: host)
        viewModel.olderPageLoader = { args in
            calls += 1
            if calls == 1 {
                // Stale page: front moved on, so this page is not adjacent to the
                // current window front (journal rejects the whole block).
                let records: [JSONValue] = (0..<6).map { seq in
                    .object(["type": .string("event"), "event": self.wireEvent(host.events[seq])])
                }
                return .object(["records": .array(records), "hasMore": .bool(true)])
            }
            return try await normalLoader(args)
        }
        await viewModel.loadOlderPageNowForTesting()
        XCTAssertEqual(calls, 2, "a stale page must be retried once against the fresh front")
        let oldestAfter = try XCTUnwrap(viewModel.oldestLoadedSeq)
        XCTAssertLessThan(oldestAfter, oldestBefore, "the retry must really prepend (oldest strictly decreases)")
        XCTAssertEqual(viewModel.eventSeqs.last, newestBefore, "the retry must not touch the window tail")
        XCTAssertNil(viewModel.actionErrorText, "a successful retry must not surface an error")
        XCTAssertEqual(viewModel.eventSeqs.count, newestBefore - oldestAfter + 1, "the merged window must stay contiguous")
    }

    /// Retry rejected too: the user-visible failure must be surfaced (retryable),
    /// never a silent no-op.
    @MainActor
    func testPersistentlyRejectedPageSurfacesVisibleErrorAndStaysRetryable() async throws {
        let host = FixtureSessionHost(events: fixtureEvents())
        let viewModel = makeViewModel(host: host, store: makeStore(), firstWindow: 16)
        let before = viewModel.eventSeqs
        let oldestBefore = try XCTUnwrap(viewModel.oldestLoadedSeq)
        var calls = 0
        viewModel.olderPageLoader = { _ in
            calls += 1
            let records: [JSONValue] = (0..<6).map { seq in
                .object(["type": .string("event"), "event": self.wireEvent(host.events[seq])])
            }
            return .object(["records": .array(records), "hasMore": .bool(true)])
        }
        await viewModel.loadOlderPageNowForTesting()
        XCTAssertEqual(calls, 2, "one automatic retry, then stop")
        XCTAssertNotNil(viewModel.actionErrorText, "no silent no-op: a rejected page must surface an error")
        XCTAssertEqual(viewModel.eventSeqs, before, "the window must not be damaged")
        XCTAssertEqual(viewModel.oldestLoadedSeq, oldestBefore)
        XCTAssertTrue(viewModel.hasMoreOlder, "the paging entry must stay retryable")
        XCTAssertFalse(viewModel.isLoadingOlder)

        viewModel.olderPageLoader = hostLoader(host: host)
        await viewModel.loadOlderPageNowForTesting()
        XCTAssertNil(viewModel.actionErrorText, "a later success clears the paging error")
        XCTAssertLessThan(try XCTUnwrap(viewModel.oldestLoadedSeq), oldestBefore)
    }

    /// E2E diagnostics: request/response/merge are recorded on `e2eLastPageDebug`
    /// (read by the hidden `e2e-lastpage` element), and failures carry `error=`.
    @MainActor
    func testE2ELastPageDebugRecordsMergeAndFailure() async throws {
        SessionViewModel.e2ePageDiagnosticsTestOverride = true
        defer { SessionViewModel.e2ePageDiagnosticsTestOverride = false }
        let host = FixtureSessionHost(events: fixtureEvents())
        let viewModel = makeViewModel(host: host, store: makeStore(), firstWindow: 16)
        viewModel.olderPageLoader = hostLoader(host: host)
        await viewModel.loadOlderPageNowForTesting()
        let success = viewModel.e2eLastPageDebug
        XCTAssertTrue(success.contains("req(before="), success)
        XCTAssertTrue(success.contains("through="), success)
        XCTAssertTrue(success.contains("resp(records="), success)
        XCTAssertTrue(success.contains("prepend(olderPrepended(inserted="), success)
        XCTAssertTrue(success.contains("merged=1"), success)
        XCTAssertTrue(success.contains("oldest="), success)
        XCTAssertTrue(success.contains("ctx(firstPage=1"), success)
        XCTAssertTrue(success.contains("pagesLoaded="), success)
        XCTAssertFalse(success.contains("error="), success)

        viewModel.olderPageLoader = { _ in
            throw FixtureHostError(code: "gateway/internal", message: "boom")
        }
        await viewModel.loadOlderPageNowForTesting()
        let failure = viewModel.e2eLastPageDebug
        XCTAssertTrue(failure.contains("error="), "失败路径也要有诊断，不能静默: \(failure)")
    }

    /// task-10 bug2b / E2E pull #5: a pull that lands while the link is reconnecting
    /// used to be a silent no-op (no request, no spinner, no error). It must be
    /// visible and must load (or replay) afterwards.
    @MainActor
    func testPullWhileReconnectingSurfacesVisibleErrorAndRetries() async throws {
        SessionViewModel.e2ePageDiagnosticsTestOverride = true
        defer { SessionViewModel.e2ePageDiagnosticsTestOverride = false }
        let host = FixtureSessionHost(events: fixtureEvents())
        let viewModel = makeViewModel(host: host, store: makeStore(), firstWindow: 16)
        let oldestBefore = try XCTUnwrap(viewModel.oldestLoadedSeq)
        // No page loader and no attached link => "not connected".
        await viewModel.loadOlderPageNowForTesting()
        XCTAssertNotNil(viewModel.actionErrorText, "a pull during a reconnect must not be silent")
        XCTAssertTrue(viewModel.e2eLastPageDebug.contains("blocked(not-connected)"), viewModel.e2eLastPageDebug)
        XCTAssertTrue(viewModel.hasMoreOlder, "the entry stays retryable")
        XCTAssertEqual(viewModel.oldestLoadedSeq, oldestBefore)

        // Link is back (here: the loader seam): the retried pull loads and clears it.
        viewModel.olderPageLoader = hostLoader(host: host)
        await viewModel.loadOlderPageNowForTesting()
        XCTAssertNil(viewModel.actionErrorText, "a successful load clears the reconnect error")
        XCTAssertLessThan(try XCTUnwrap(viewModel.oldestLoadedSeq), oldestBefore)
    }

    /// 2026-10-22 真机 A5（原「展开最老 turn」）：turn UI/折叠已删除，下拉加载的
    /// 更早历史不再需要「展开」动作——合并成功后新行必须直接出现在平铺流的头部，
    /// 用户立刻看到刚拉下来的消息（oldest 前进 + rows 增长 + 原有行不乱序/不重复）。
    @MainActor
    func testOlderPageMergePrependsRowsAndAdvancesOldest() async throws {
        let host = FixtureSessionHost(events: fixtureEvents())
        let viewModel = makeViewModel(host: host, store: makeStore(), firstWindow: 16)
        // 首帧 rows rebuild 是 40ms debounce：先等它落地，才有稳定的基线。
        await waitUntil { !viewModel.rows.isEmpty }
        let oldestBefore = try XCTUnwrap(viewModel.oldestLoadedSeq)
        let rowsBefore = viewModel.rows
        let firstRowSeqBefore = try XCTUnwrap(rowsBefore.first?.seq)

        viewModel.olderPageLoader = hostLoader(host: host)
        await viewModel.loadOlderPageNowForTesting()
        // rows rebuild is debounced (~40ms) — the view-driven path lands it async.
        await waitUntil { viewModel.rows.count > rowsBefore.count }

        XCTAssertLessThan(
            try XCTUnwrap(viewModel.oldestLoadedSeq),
            oldestBefore,
            "前置加载后窗口最老 seq 必须前进"
        )
        XCTAssertGreaterThan(
            viewModel.rows.count,
            rowsBefore.count,
            "更早的历史必须立即变成可渲染行（折叠已不存在，无需展开动作）"
        )
        XCTAssertLessThan(
            try XCTUnwrap(viewModel.rows.first?.seq),
            firstRowSeqBefore,
            "前置页的行必须出现在平铺流头部"
        )
        XCTAssertEqual(
            viewModel.rows.suffix(rowsBefore.count).map(\.seq),
            rowsBefore.map(\.seq),
            "前置加载只向前追加更早的行，不得打乱/重复原窗口的行"
        )
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
