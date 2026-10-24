import Compression
import Network
import XCTest
@testable import DSHm

/// task-4（2026-10-24）「#1 跨端文件变更一致性」修复回归单测。
///
/// 三个行为契约（① 真 bug；② 稳健性兼容；③ 跨端标题口径）：
/// 1. HTTPSClient.decodeBody：响应头声明 gzip 但 body 实际不是 gzip 时（典型：链路
///    插件 exact-fetch 透传的 Host 404），必须回退原始 body、保留 HTTP status，让
///    FileChangesFetchPolicy 看到 404 terminal，而不是被 transport 错误重试耗尽。
/// 2. SessionRowBuilder.handleToolResult：真实宿主 tool/result 的 diffs 在 data.meta
///    （优先，扫真实会话日志确认）；部分静态 fixture / 部分恢复快照只保留
///    message.meta，兜底做兼容——两种位置都要能聚合出文件（稳健性兼容，不是真实
///    用户 bug；真实口径不变）。
/// 3. 跨端标题口径：卡片标题用 Host total，不是客户端 files.length；DEBUG E2E
///    seam 注入的 summary 与真实 exact fetch 共用同一口径。
final class FileChangesConsistencyFixTests: XCTestCase {

    // MARK: - ① gzip 头 + 非 gzip body：回退原始 body，不吞 HTTP status

    private func rawDeflate(_ data: Data) throws -> Data {
        var destination = [UInt8](repeating: 0, count: max(64, data.count + 1024))
        let written = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return destination.withUnsafeMutableBufferPointer { buffer in
                compression_encode_buffer(buffer.baseAddress!, buffer.count, base, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw HTTPCompression.DecodeError.decoderFailure(-2) }
        return Data(destination.prefix(written))
    }

    private func gzipWrap(_ data: Data) throws -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff])
        out.append(try rawDeflate(data))
        out.append(Data(count: 8))
        return out
    }

    func testDecodeBodyGunzipsValidGzipBody() throws {
        let payload = Data(#"{"ok":true,"value":{"files":[]}}"#.utf8)
        let response = HTTPResponse(
            status: 200,
            headers: ["content-type": "application/json", "content-encoding": "gzip"],
            body: try gzipWrap(payload),
            observedLeafPin: nil
        )
        let decoded = try HTTPSClient.decodeBody(of: response)
        XCTAssertEqual(decoded.status, 200)
        XCTAssertEqual(decoded.body, payload, "a real gzip body must still be inflated")
        XCTAssertEqual(decoded.bodyText, String(decoding: payload, as: UTF8.self))
    }

    /// 真 bug 场景：链路插件把 Host 404 的响应头 content-encoding: gzip 原样透传，
    /// 但 undici 已把 body 解压成明文 JSON。旧代码在这里抛 transport，404 被重试耗尽后
    /// 「本轮文件变更」卡整张消失。现在必须返回原始 body + 404。
    func testDecodeBodyFallsBackToRawBodyWhenGzipHeaderWrapsPlainJSON() throws {
        let plain = Data(#"{"ok":false,"error":"summary/not-found","message":"Host released the turn"}"#.utf8)
        XCTAssertNotEqual(plain.first, 0x1f, "fixture body is deliberately NOT gzip")
        let response = HTTPResponse(
            status: 404,
            headers: ["content-type": "application/json", "content-encoding": "gzip"],
            body: plain,
            observedLeafPin: nil
        )
        let decoded = try HTTPSClient.decodeBody(of: response)
        XCTAssertEqual(decoded.status, 404, "the HTTP status must survive the decode failure")
        XCTAssertEqual(decoded.body, plain, "the raw body must be handed back untouched")
        XCTAssertTrue(decoded.bodyText.contains("summary/not-found"))
    }

    func testDecodeBodyPassesThroughIdentityAndHeaderlessResponses() throws {
        let payload = Data(#"{"ok":true}"#.utf8)
        let identity = HTTPResponse(
            status: 200,
            headers: ["content-encoding": "identity"],
            body: payload,
            observedLeafPin: nil
        )
        XCTAssertEqual(try HTTPSClient.decodeBody(of: identity).body, payload)

        let headerless = HTTPResponse(status: 200, headers: [:], body: payload, observedLeafPin: nil)
        XCTAssertEqual(try HTTPSClient.decodeBody(of: headerless).body, payload)
    }

    /// 安全边界（lead 要求保留）：回退只针对「gzip 头 + 非 gzip body」；
    /// 其他不支持的 content-encoding（br/deflate 等）仍然必须报错，不能被
    /// 静默当明文放行，否则请求协商会被悄悄降级。
    func testDecodeBodyStillRejectsUnsupportedContentEncoding() {
        let response = HTTPResponse(
            status: 200,
            headers: ["content-encoding": "br"],
            body: Data(#"{"ok":true}"#.utf8),
            observedLeafPin: nil
        )
        XCTAssertThrowsError(try HTTPSClient.decodeBody(of: response)) { error in
            guard case LinkError.transport(let message) = error else {
                return XCTFail("unsupported coding must stay a transport error, got: \(error)")
            }
            XCTAssertTrue(message.contains("br"), "error must name the unsupported coding: \(message)")
        }
    }

    /// 端到端（进程内 loopback）：旧代码把 404 变成 LinkError.transport，这里断言
    /// 上层拿到的是 LinkError.httpStatus(404, body) —— exact-fetch 判定与 404 兜底
    /// 都依赖这个 error 形状。
    func testUnaryJSONSurfacesHTTP404WhenGzipHeaderWrapsPlainJSON() async throws {
        let errorBody = Data(#"{"ok":false,"error":"summary/not-found"}"#.utf8)
        let server = try TransportPerfTests.TestServer(handler: { _ in
            TransportPerfTests.TestResponse(
                status: 404,
                headers: ["content-type": "application/json", "content-encoding": "gzip"],
                body: errorBody
            )
        })
        try await server.start()
        defer { server.stop() }

        let pool = HTTPConnectionPool(
            config: HTTPConnectionPoolConfig(maxIdlePerOrigin: 2, idleTimeout: 10)
        )
        let origin = URL(string: "http://127.0.0.1:\(server.port)")!
        do {
            _ = try await HTTPSClient.unaryJSON(
                origin: origin,
                endpoint: "changes.summary",
                args: [:],
                token: "test-token",
                leafPin: "",
                timeout: 5,
                pool: pool,
                parameters: NWParameters.tcp
            )
            XCTFail("a 404 must never be reported as success")
        } catch let LinkError.httpStatus(status, body) {
            XCTAssertEqual(status, 404)
            XCTAssertTrue(body.contains("summary/not-found"), "error body must be readable: \(body)")
        } catch {
            XCTFail("404 was masked as a non-HTTP error (the reported bug): \(error)")
        }
    }

    // MARK: - ② diffs 兼容口径：data.meta 优先，message.meta 兜底

    /// 稳健性兼容：真实会话 diffs 在 data.meta（优先级由下一个用例验证），但部分
    /// 静态 fixture / 部分恢复快照只保留 message.meta。兜底必须在这种形态下也能
    /// 聚合出文件，否则 404 回退会没有文件可展示。
    func testToolResultFallsBackToMessageMetaWhenTopLevelMetaIsAbsent() throws {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("tool/call", seq: 2, data: TestJSON.value(#"""
            {"callId":"call_edit","name":"edit","arguments":"{}","turn":1,"step":1}
            """#)),
            TestJSON.event("tool/result", seq: 3, data: TestJSON.value(#"""
            {"name":"edit","message":{"content":[{"type":"text","text":"ok"}],"isError":false,
             "toolCallId":"call_edit",
             "meta":{"diffs":[{"path":"Sources/A.swift","oldText":"a","newText":"a\nb"}]}}}
            """#)),
        ]
        let flow = SessionRowBuilder.build(events: events)
        let changes = try XCTUnwrap(flow.latestFileChanges, "restored-session message.meta.diffs must aggregate")
        XCTAssertEqual(changes.files, ["Sources/A.swift"])
        XCTAssertEqual(changes.additions, 1, "a -> a\\nb is one added line")
        XCTAssertEqual(changes.deletions, 0)

        let call = try XCTUnwrap(SessionRowBuilder.findToolCall(in: flow.rows, callId: "call_edit"))
        XCTAssertNotNil(call.result?.meta?["diffs"]?.arrayValue, "the diffs must attach to the tool row for the result view")
    }

    /// 原优先级必须保留：live 事件顶层 data.meta 优先于 message.meta（两者不同时以
    /// data.meta 为准，避免 live 结果被持久化副本覆盖）。
    func testToolResultPrefersTopLevelMetaOverMessageMeta() throws {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("tool/call", seq: 2, data: TestJSON.value(#"""
            {"callId":"call_edit","name":"edit","arguments":"{}","turn":1,"step":1}
            """#)),
            TestJSON.event("tool/result", seq: 3, data: TestJSON.value(#"""
            {"name":"edit","message":{"content":[{"type":"text","text":"ok"}],"isError":false,
             "toolCallId":"call_edit",
             "meta":{"diffs":[{"path":"stale/Persisted.swift","oldText":"x","newText":"x\ny"}]}},
             "meta":{"diffs":[{"path":"live/TopLevel.swift","oldText":"x","newText":"x\ny"}]}}
            """#)),
        ]
        let flow = SessionRowBuilder.build(events: events)
        let changes = try XCTUnwrap(flow.latestFileChanges)
        XCTAssertEqual(changes.files, ["live/TopLevel.swift"], "data.meta keeps its original priority")
    }

    // MARK: - ③ 跨端口径：标题用 Host total，不是 files.length

    func testExactSummaryTitleUsesHostTotalNotFileCount() throws {
        let summary = try JSONDecoder().decode(ChangesSummaryValue.self, from: Data(#"""
        {"turn":3,
         "files":[{"path":"Sources/A.swift","display":"A.swift","added":3,"deleted":1},
                  {"path":"Sources/B.swift","display":"B.swift","added":1,"deleted":0}],
         "total":50,"added":123,"deleted":45}
        """#.utf8))
        let changes = TurnFileChanges.exact(from: summary, seq: 9)
        XCTAssertEqual(changes.titleFileCount, 50, "卡片标题必须用 Host total(50)，不是 files.count(2)")
        XCTAssertEqual(changes.files.count, 2, "sheet 列表仍用 files.length")
        XCTAssertEqual(changes.added, 123)
        XCTAssertEqual(changes.deleted, 45)
        XCTAssertEqual(changes.source, .exactFetch)
        XCTAssertEqual(changes.seq, 9)
    }

    func testTitleFallsBackToFileCountWhenHostOmitsTotal() throws {
        let summary = try JSONDecoder().decode(ChangesSummaryValue.self, from: Data(#"""
        {"files":[{"path":"a.swift","added":2,"deleted":0},{"path":"b.swift","added":0,"deleted":1}]}
        """#.utf8))
        let changes = TurnFileChanges.exact(from: summary, seq: nil)
        XCTAssertNil(changes.total)
        XCTAssertEqual(changes.titleFileCount, 2, "without a Host total the title falls back to files.count")
        XCTAssertEqual(changes.added, 2, "added/deleted are summed from files when the Host omits them")
        XCTAssertEqual(changes.deleted, 1)
    }

    /// DEBUG E2E seam 与真实 exact fetch 共用 TurnFileChanges.exact：注入 total=50 /
    /// files=18 后，卡片（latestTurnFileChanges）必须按 50 渲染，且不进入 loading 态。
    @MainActor
    func testE2EChangesSummarySeamDrivesCardWithHostTotal() throws {
        let files = (0..<18).map { index in
            #"{"path":"Sources/File\#(index).swift","display":"File\#(index).swift","added":1,"deleted":0}"#
        }
        let json = #"{"turn":1,"files":[\#(files.joined(separator: ","))],"total":50,"added":123,"deleted":45}"#
        let viewModel = SessionViewModel(sessionId: "session-e2e-changes")
        viewModel.installE2EChangesSummaryPreview(json: json)

        let changes = try XCTUnwrap(viewModel.latestTurnFileChanges)
        XCTAssertEqual(changes.source, .exactFetch)
        XCTAssertEqual(changes.titleFileCount, 50, "seam must reproduce the Host-total title口径")
        XCTAssertEqual(changes.files.count, 18, "sheet list length stays 18 (files.length)")
        XCTAssertEqual(changes.added, 123)
        XCTAssertEqual(changes.deleted, 45)
        XCTAssertFalse(viewModel.fileChangesExactFetchPending)
    }

    @MainActor
    func testE2EChangesSummarySeamIgnoresMalformedJSON() {
        let viewModel = SessionViewModel(sessionId: "session-e2e-changes")
        viewModel.installE2EChangesSummaryPreview(json: "{not-json")
        XCTAssertNil(viewModel.latestTurnFileChanges, "malformed seam JSON must be ignored, not crash the card")
    }

    // MARK: - 2026-10-24 #1/#2 回归：仅空闲显示 + 零转圈取数 + 尾部刷新

    private func decodeSummary(_ json: String) throws -> ChangesSummaryValue {
        try JSONDecoder().decode(ChangesSummaryValue.self, from: Data(json.utf8))
    }

    private func eventJSON(_ type: String, seq: Int, data: String) -> String {
        "{\"type\":\"\(type)\",\"seq\":\(seq),\"time\":1792510000000,\"data\":\(data)}"
    }

    private func eventFrame(_ event: String) -> JSONValue {
        TestJSON.value("{\"type\":\"event\",\"event\":\(event)}")
    }

    private func snapshotValue(sessionId: String, cursor: Int, eventJSONs: [String]) -> JSONValue {
        let records = eventJSONs.map { "{\"type\":\"event\",\"event\":\($0)}" }.joined(separator: ",")
        let json = """
        {"type":"snapshot","header":{"version":4,"id":"\(sessionId)"},"cursor":\(cursor),
         "records":[\(records)],"hasMore":false,
         "projections":{"asOfSeq":\(cursor),"values":{}},
         "assistantStream":{"revision":0}}
        """
        return TestJSON.value(json)
    }

    /// 一轮已结束、带工具 meta.diffs 的会话（latestFileChangeSeq=4）。
    private func endedTurnEvents() -> [String] {
        [
            eventJSON("turn/start", seq: 1, data: #"{"turn":1}"#),
            eventJSON("tool/call", seq: 2, data: #"{"callId":"call_edit","name":"edit","arguments":"{}","turn":1,"step":1}"#),
            eventJSON(
                "tool/result",
                seq: 3,
                data: #"{"name":"edit","toolCallId":"call_edit","meta":{"diffs":[{"path":"src/App.swift","oldText":"a","newText":"a\nb"}]}}"#
            ),
            eventJSON("workspace/changes", seq: 4, data: #"{"turn":1}"#),
            eventJSON("turn/end", seq: 5, data: #"{"turn":1}"#),
        ]
    }

    /// SessionViewModel 的行重建有 40ms 防抖，断言派生状态前等一拍。
    @MainActor
    private func waitForRowsRebuild() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// #1 可见性纯函数：running 期间 items 里完全不出现文件变更卡行。
    func testMessageItemsHideFileChangesCardWhileRunning() {
        let changes = TurnFileChanges(source: .exactFetch, files: [], added: 12, deleted: 3, seq: 4, total: 7)
        let make = { (running: Bool) in
            SessionMessageItemsBuilder.build(
                groups: [],
                isRunning: running,
                fileChanges: changes,
                processPreviewSteps: nil,
                liveAssistantText: "streaming",
                streamErrorText: nil,
                actionErrorText: nil
            )
        }
        let idle = make(false)
        XCTAssertEqual(idle.filter { if case .fileChanges = $0 { return true } else { return false } }.count, 1)
        let running = make(true)
        XCTAssertTrue(running.allSatisfy { if case .fileChanges = $0 { return false } else { return true } },
                      "#1 running 期间文件变更卡完全不渲染")
        XCTAssertEqual(running.count, 1, "只有流式文本行，没有卡片占位")
    }

    /// #2 数据源纯函数：内存 exact → 磁盘缓存 exact → 工具聚合；永不 loading。
    @MainActor
    func testResolveLatestTurnFileChangesPrecedenceAndNeverLoading() throws {
        let memory = try decodeSummary(#"{"files":[{"path":"mem.swift"}],"total":7,"added":12,"deleted":3}"#)
        let cached = try decodeSummary(#"{"files":[{"path":"cache.swift"}],"total":9,"added":4,"deleted":1}"#)
        let fallback = FileChangeSummary(files: ["src/App.swift"], additions: 2, deletions: 1)

        let memoryHit = try XCTUnwrap(SessionViewModel.resolveLatestTurnFileChanges(
            seq: 4, memorySummary: memory, cachedSummary: cached, fallback: fallback
        ))
        XCTAssertEqual(memoryHit.source, .exactFetch)
        XCTAssertEqual(memoryHit.titleFileCount, 7, "内存 exact 优先于磁盘缓存")

        let cacheHit = try XCTUnwrap(SessionViewModel.resolveLatestTurnFileChanges(
            seq: 4, memorySummary: nil, cachedSummary: cached, fallback: fallback
        ))
        XCTAssertEqual(cacheHit.source, .exactFetch, "Host 404 后磁盘缓存仍提供精确数字")
        XCTAssertEqual(cacheHit.titleFileCount, 9)

        let aggregate = try XCTUnwrap(SessionViewModel.resolveLatestTurnFileChanges(
            seq: 4, memorySummary: nil, cachedSummary: nil, fallback: fallback
        ))
        XCTAssertEqual(aggregate.source, .metaDiffsFallback, "精确数据未就绪先显示工具聚合数字")
        XCTAssertEqual(aggregate.titleFileCount, 1)
        XCTAssertEqual(aggregate.added, 2)
        XCTAssertEqual(aggregate.deleted, 1)

        XCTAssertNil(SessionViewModel.resolveLatestTurnFileChanges(
            seq: 4, memorySummary: nil, cachedSummary: nil, fallback: nil
        ), "没有任何数据时返回 nil，而不是渲染空的 loading 卡片")
    }

    /// #1 取数时机：running 期间卡片不提供数据、也不发请求；turn/end 后才请求 latest seq。
    @MainActor
    func testCardHiddenWhileRunningAndRequestOnlyAfterTurnEnd() async throws {
        let sessionId = "session-card-running-\(UUID().uuidString)"
        let viewModel = SessionViewModel(sessionId: sessionId)
        viewModel.applyStreamValue(snapshotValue(sessionId: sessionId, cursor: 2, eventJSONs: [
            eventJSON("turn/start", seq: 1, data: #"{"turn":1}"#),
            eventJSON("workspace/changes", seq: 2, data: #"{"turn":1}"#),
        ]))
        await waitForRowsRebuild()

        XCTAssertTrue(viewModel.isRunning)
        XCTAssertNil(viewModel.latestTurnFileChanges, "#1 running 期间不提供卡片数据")
        XCTAssertTrue(viewModel.requestedFileChangeSeqs.isEmpty, "#1 running 期间绝不发 exact 请求")

        viewModel.applyStreamValue(eventFrame(eventJSON("turn/end", seq: 3, data: #"{"turn":1}"#)))
        await waitForRowsRebuild()

        XCTAssertFalse(viewModel.isRunning)
        XCTAssertEqual(viewModel.requestedFileChangeSeqs, [2], "turn 结束才请求，且只请求 latest seq")
    }

    /// #2 无缓存时显示工具聚合数字；磁盘缓存命中时显示精确数字（Host 重启 404 后仍精确）。
    @MainActor
    func testLatestTurnFileChangesFallsBackToAggregateThenUsesDiskCachedExact() async throws {
        let fallbackSessionId = "session-fallback-\(UUID().uuidString)"
        let fallbackVM = SessionViewModel(sessionId: fallbackSessionId)
        fallbackVM.applyStreamValue(snapshotValue(
            sessionId: fallbackSessionId,
            cursor: 5,
            eventJSONs: endedTurnEvents()
        ))
        await waitForRowsRebuild()

        let fallback = try XCTUnwrap(fallbackVM.latestTurnFileChanges)
        XCTAssertEqual(fallback.source, .metaDiffsFallback)
        XCTAssertEqual(fallback.seq, 4)
        XCTAssertEqual(fallback.titleFileCount, 1)
        XCTAssertEqual(fallback.added, 1, "a -> a\nb 是 1 行新增")

        let suiteName = "FileChangesConsistencyFixTests.vm.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cachedSessionId = "session-cached-\(UUID().uuidString)"
        var cache = FileChangesSummaryCache(defaults: defaults)
        let summary = try decodeSummary(#"{"turn":1,"files":[{"path":"src/App.swift","display":"App.swift","added":5,"deleted":2}],"total":7,"added":12,"deleted":3}"#)
        cache.save(summary, sessionId: cachedSessionId, seq: 4)

        let cachedVM = SessionViewModel(sessionId: cachedSessionId)
        cachedVM.fileChangesSummaryCache = cache
        cachedVM.applyStreamValue(snapshotValue(
            sessionId: cachedSessionId,
            cursor: 5,
            eventJSONs: endedTurnEvents()
        ))
        await waitForRowsRebuild()

        let cached = try XCTUnwrap(cachedVM.latestTurnFileChanges)
        XCTAssertEqual(cached.source, .exactFetch, "缓存命中必须显示精确数字")
        XCTAssertEqual(cached.titleFileCount, 7, "标题仍用 Host total，不是 files.count")
        XCTAssertEqual(cached.added, 12)
        XCTAssertEqual(cached.deleted, 3)
        XCTAssertEqual(cached.seq, 4)
    }

    /// #2 磁盘缓存：sessionId+seq 往返、覆盖写与容量淘汰。
    func testExactSummaryDiskCacheRoundTripAndCapacity() throws {
        let suiteName = "FileChangesConsistencyFixTests.cache.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var cache = FileChangesSummaryCache(defaults: defaults)
        cache.maxEntries = 2

        let a = try decodeSummary(#"{"files":[{"path":"a.swift"}],"total":5,"added":1,"deleted":0}"#)
        let b = try decodeSummary(#"{"files":[{"path":"b.swift","display":"B.swift","added":2,"deleted":1}],"total":6,"added":2,"deleted":1}"#)
        let c = try decodeSummary(#"{"files":[{"path":"c.swift"}],"total":7}"#)
        cache.save(a, sessionId: "s1", seq: 10)
        cache.save(b, sessionId: "s1", seq: 11)
        cache.save(c, sessionId: "s2", seq: 12)

        let s1 = cache.load(sessionId: "s1")
        XCTAssertEqual(Set(s1.keys), [11], "超出容量时淘汰最旧条目")
        XCTAssertEqual(s1[11]?.total, 6)
        XCTAssertEqual(s1[11]?.files.first?.display, "B.swift", "files/display/added/deleted 全字段往返")
        XCTAssertEqual(cache.load(sessionId: "s2")[12]?.total, 7)

        cache.save(a, sessionId: "s1", seq: 11)
        XCTAssertEqual(cache.load(sessionId: "s1")[11]?.total, 5, "同 sessionId+seq 覆盖写")
    }

    /// 尾部冻结修复：读历史（不贴底）时，尾部行内容变化必须原地应用，且不移动行序。
    func testTrailingUpdatesApplyExactNumbersWhileReadingHistory() {
        let group = FlowRowGroup.single(FlowRow(id: "row-1", seq: 1, content: .text("hello")))
        let fallback = TurnFileChanges(source: .metaDiffsFallback, files: [], added: 0, deleted: 0, seq: 4)
        let exact = TurnFileChanges(source: .exactFetch, files: [], added: 12, deleted: 3, seq: 4, total: 7)
        let displayed: [SessionMessageItem] = [.group(group), .fileChanges(fallback)]
        let incoming: [SessionMessageItem] = [.group(group), .fileChanges(exact)]

        let update = MessageListUpdatePolicy.applyingTrailingUpdates(
            displayed: displayed, incoming: incoming, running: false
        )
        XCTAssertTrue(update.changed, "尾部内容变化必须被应用，否则数字永远停在旧值")
        XCTAssertEqual(update.items.count, 2, "行数与顺序不变 → 阅读锚点不动")
        guard case .fileChanges(let applied)? = update.items.last else {
            return XCTFail("尾部仍是文件变更行")
        }
        XCTAssertEqual(applied.source, .exactFetch)
        XCTAssertEqual(applied.titleFileCount, 7)
        XCTAssertEqual(applied.added, 12)

        let unchanged = MessageListUpdatePolicy.applyingTrailingUpdates(
            displayed: update.items, incoming: incoming, running: false
        )
        XCTAssertFalse(unchanged.changed, "内容没变时不做多余的状态更新")
    }

    /// 历史补齐与 exact 到达同帧：前置补齐照旧，尾部数字同帧更新。
    func testTrailingUpdatesApplyWhenHistoryPrependAndExactArriveTogether() {
        let older = FlowRowGroup.single(FlowRow(id: "row-0", seq: 0, content: .text("older")))
        let group = FlowRowGroup.single(FlowRow(id: "row-1", seq: 1, content: .text("hello")))
        let fallback = TurnFileChanges(source: .metaDiffsFallback, files: [], added: 0, deleted: 0, seq: 4)
        let exact = TurnFileChanges(source: .exactFetch, files: [], added: 2, deleted: 1, seq: 4, total: 3)
        let displayed: [SessionMessageItem] = [.group(group), .fileChanges(fallback)]
        let incoming: [SessionMessageItem] = [.group(older), .group(group), .fileChanges(exact)]

        let prepended = MessageListUpdatePolicy.leadingPrependedItems(displayed: displayed, incoming: incoming)
        XCTAssertEqual(prepended.map { $0.id }, [older.id])
        let update = MessageListUpdatePolicy.applyingTrailingUpdates(
            displayed: displayed, incoming: incoming, running: false
        )
        XCTAssertTrue(update.changed)
        let combined = prepended + update.items
        XCTAssertEqual(combined.map { $0.id }, incoming.map { $0.id }, "补齐 + 尾部更新后与 incoming 行序一致")
        guard case .fileChanges(let applied)? = combined.last else { return XCTFail("尾部必须是文件变更行") }
        XCTAssertEqual(applied.source, .exactFetch)
    }

    /// #1 读历史时再次进入 running：已显示的卡片行必须被摘掉（只动尾部，锚点不动）。
    func testTrailingUpdatesDropCardWhileRunningEvenReadingHistory() {
        let group = FlowRowGroup.single(FlowRow(id: "row-1", seq: 1, content: .text("hello")))
        let fallback = TurnFileChanges(source: .metaDiffsFallback, files: [], added: 0, deleted: 0, seq: 4)
        let displayed: [SessionMessageItem] = [.group(group), .fileChanges(fallback)]
        let incoming: [SessionMessageItem] = [.group(group)]

        let update = MessageListUpdatePolicy.applyingTrailingUpdates(
            displayed: displayed, incoming: incoming, running: true
        )
        XCTAssertTrue(update.changed)
        XCTAssertEqual(update.items.map { $0.id }, [group.id], "running 期间卡片行必须消失，其余行保持不动")
    }

    /// E2E diff seam：按 index 返回注入的 ChangesDiffValue，越界返回 nil。
    @MainActor
    func testE2EChangesDiffSeamReturnsInjectedHunksByIndex() async throws {
        let viewModel = SessionViewModel(sessionId: "session-e2e-diff")
        viewModel.installE2EChangesDiffPreview(json: #"""
        [
          {"kind":"update","path":"src/App.swift","display":"App.swift","hunks":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":2,"lines":["@@ -1,1 +1,2 @@"," a","+b"]}],"coarse":false},
          {"kind":"update","path":"docs/README.md","display":"README.md","hunks":[],"coarse":true}
        ]
        """#)

        let firstDiff = await viewModel.loadFileDiff(seq: 1, index: 0)
        let first = try XCTUnwrap(firstDiff)
        XCTAssertEqual(first.path, "src/App.swift")
        XCTAssertEqual(first.hunks?.first?.lines.count, 3)
        let secondDiff = await viewModel.loadFileDiff(seq: 1, index: 1)
        let second = try XCTUnwrap(secondDiff)
        XCTAssertEqual(second.path, "docs/README.md")
        XCTAssertEqual(second.coarse, true)
        let outOfRange = await viewModel.loadFileDiff(seq: 1, index: 5)
        XCTAssertNil(outOfRange, "数组形态越界返回 nil，与 Host「index 不存在」一致")
    }
}
