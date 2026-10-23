import XCTest
@testable import DSHm

/// 渲染层微基准 + 增量等价性验收（ios-render-perf / task-4）。
///
/// 覆盖两件事：
/// 1. **等价性**：FlowState 的增量路径（reset / append / prepend / repaint）必须与
///    一次全量 SessionRowBuilder.build(events:) 逐行等价（含 rows / isRunning /
///    latestFileChangeSeq / latestFileChanges / 分组缓存 groups）。
/// 2. **微基准**：3500 events（约本机最大顶层会话量级）下的全量构建、尾部增量、
///    prepend 一页、回显重画、分组缓存耗时。计时用 ContinuousClock，warmup 1 次后
///    取 5 次中位数；本文件跑在 Debug 测试宿主里，绝对值比 Release 大 5-9 倍，
///    只用于相对比较与回归护栏（Release 数字见任务报告 /tmp/dshm-render-bench.md）。
final class RowBuilderBenchTests: XCTestCase {

    // MARK: - Corpus

    /// 3500 条事件的合成会话（确定性、无随机数，约 300 轮 turn）。
    static let corpus: [SessionEvent] = makeCorpus(eventTarget: 3500)

    private static func makeCorpus(seqOffset: Int = 0, turnOffset: Int = 0, eventTarget: Int) -> [SessionEvent] {
        var events: [SessionEvent] = []
        var seq = seqOffset
        func next() -> Int { seq += 1; return seq }

        let reasoning = String(repeating: "分析渲染路径并核对调用契约，", count: 40)
        let body = String(repeating: "这是助手输出的正文段落，用于测量行构建与解析开销。", count: 24)
        let bashOutput = String(repeating: "ok test case passed in 0.012s" + "\\n", count: 55)
        let diffOld = String(repeating: "old line of the file" + "\\n", count: 18)
        let diffNew = String(repeating: "new line of the file" + "\\n", count: 22)
        var turn = turnOffset

        while events.count < eventTarget {
            turn += 1
            events.append(TestJSON.event("turn/start", seq: next(), data: .object(["turn": .int(Int64(turn))])))
            events.append(TestJSON.event("user/message", seq: next(), data: TestJSON.value("""
            {"content":[{"type":"text","text":"请检查第 \(turn) 个模块并跑测试"}],"source":{"kind":"user"},"role":"user","id":"m\(turn)"}
            """)))
            let bashArgs = "{\"command\":\"pnpm --filter module-\(turn) test\"}"
            let readArgs = "{\"file_path\":\"/Users/demo/project/apps/ios/DSHm/Session/Module\(turn).swift\"}"
            let assistantJSON = """
            {"message":{"content":[
              {"type":"reasoning","text":"\(reasoning)"},
              {"type":"text","text":"\(body)"},
              {"type":"tool-call","name":"bash","arguments":\(TestJSON.quoted(bashArgs)),"id":"call_\(turn)_1"},
              {"type":"tool-call","name":"read","arguments":\(TestJSON.quoted(readArgs)),"id":"call_\(turn)_2"}
            ]},"source":{"provider":"mock","model":"mock-tool"}}
            """
            events.append(TestJSON.event("assistant/message", seq: next(), data: TestJSON.value(assistantJSON)))
            events.append(TestJSON.event("tool/call", seq: next(), data: TestJSON.value("""
            {"callId":"call_\(turn)_1","name":"bash","arguments":\(TestJSON.quoted(bashArgs)),"turn":\(turn),"step":1}
            """)))
            events.append(TestJSON.event("tool/result", seq: next(), data: TestJSON.value("""
            {"name":"bash","message":{"content":[{"type":"text","text":"\(bashOutput)"}],"isError":false,"toolCallId":"call_\(turn)_1"},"meta":{"cwd":"/Users/demo/project"}}
            """)))
            events.append(TestJSON.event("tool/call", seq: next(), data: TestJSON.value("""
            {"callId":"call_\(turn)_2","name":"read","arguments":\(TestJSON.quoted(readArgs)),"turn":\(turn),"step":1}
            """)))
            events.append(TestJSON.event("tool/result", seq: next(), data: TestJSON.value("""
            {"name":"read","message":{"content":[{"type":"text","text":"\(body)"}],"isError":false,"toolCallId":"call_\(turn)_2"},"meta":{"path":"/Users/demo/Module\(turn).swift","diffs":[{"path":"/Users/demo/Module\(turn).swift","oldText":"\(diffOld)","newText":"\(diffNew)"}]}}
            """)))
            if turn % 7 == 0 {
                events.append(TestJSON.event("approval/asked", seq: next(), data: .object(["id": .string("approval-\(turn)"), "toolName": .string("bash"), "reason": .string("执行命令需要确认")])))
                events.append(TestJSON.event("approval/decided", seq: next(), data: .object(["id": .string("approval-\(turn)"), "outcome": .string("approved")])))
            }
            if turn % 11 == 0 {
                events.append(TestJSON.event("todo/write", seq: next(), data: TestJSON.value("""
                {"todos":[{"content":"检查模块 \(turn)","status":"in_progress"},{"content":"跑测试","status":"pending"}]}
                """)))
            }
            if turn % 13 == 0 {
                events.append(TestJSON.event("job/registered", seq: next(), data: .object(["jobId": .string("job-\(turn)"), "kind": .string("bash"), "label": .string("后台任务 \(turn)")])))
            }
            events.append(TestJSON.event("workspace/changes", seq: next(), data: .object(["turn": .int(Int64(turn))])))
            events.append(TestJSON.event("turn/end", seq: next(), data: .object(["turn": .int(Int64(turn)), "reason": TestJSON.reason("completed")])))
        }
        return Array(events.prefix(eventTarget))
    }

    // MARK: - Timing helpers

    private func timeMs(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    @discardableResult
    private func bench(_ label: String, iterations: Int = 5, _ body: () -> Void) -> Double {
        body()
        var samples: [Double] = []
        for _ in 0..<iterations { samples.append(timeMs(body)) }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let rendered = samples.map { String(format: "%.2f", $0) }.joined(separator: ",")
        print(String(format: "[bench] %@ median=%.2fms min=%.2fms samples=[%@]", label, median, sorted[0], rendered))
        return median
    }

    // MARK: - Equivalence helpers

    private func assertEquivalent(
        _ incremental: SessionFlow,
        to events: [SessionEvent],
        groups: [FlowRowGroup]? = nil,
        pendingEchoes: [SessionRowBuilder.PendingUserEcho] = [],
        nowMs: Int64 = 1_792_510_000_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let full = SessionRowBuilder.build(events: events, pendingUserEchoes: pendingEchoes, nowMs: nowMs)
        XCTAssertEqual(incremental.rows.map(\.id), full.rows.map(\.id), "row ids differ", file: file, line: line)
        XCTAssertEqual(incremental.rows, full.rows, "row contents differ", file: file, line: line)
        XCTAssertEqual(incremental.isRunning, full.isRunning, "isRunning differs", file: file, line: line)
        XCTAssertEqual(incremental.latestFileChangeSeq, full.latestFileChangeSeq, "latestFileChangeSeq differs", file: file, line: line)
        XCTAssertEqual(incremental.latestFileChanges, full.latestFileChanges, "latestFileChanges differs", file: file, line: line)
        if let groups {
            XCTAssertEqual(groups, SessionFlowGrouping.groups(rows: incremental.rows), "group cache differs from full grouping", file: file, line: line)
        }
    }

    // MARK: - Equivalence: reset

    func testIncrementalResetEqualsFullBuild() {
        var state = SessionRowBuilder.FlowState()
        state.reset(events: Self.corpus)
        assertEquivalent(state.flow, to: Self.corpus, groups: state.groups)
    }

    func testIncrementalResetEqualsFullBuildWithPendingEcho() {
        let nowMs: Int64 = 1_792_510_000_000
        let echo = SessionRowBuilder.PendingUserEcho(
            requestId: "req-reset-echo",
            text: "帮我先看下日志",
            images: [],
            sentAt: nowMs - 500,
            mode: "queue"
        )
        var state = SessionRowBuilder.FlowState()
        state.reset(events: Self.corpus, pendingUserEchoes: [echo], nowMs: nowMs)
        assertEquivalent(state.flow, to: Self.corpus, groups: state.groups, pendingEchoes: [echo], nowMs: nowMs)
    }

    // MARK: - Equivalence: live tail append (40-event batches)

    func testIncrementalAppendEqualsFullBuildInBatches() {
        let corpus = Self.corpus
        var state = SessionRowBuilder.FlowState()
        state.reset(events: Array(corpus[0..<40]))
        var start = 40
        while start < corpus.count {
            let end = min(start + 40, corpus.count)
            state.append(events: Array(corpus[start..<end]))
            let expected = SessionRowBuilder.build(events: Array(corpus[0..<end]))
            XCTAssertEqual(state.flow.rows, expected.rows, "rows differ after appending up to \(end)")
            XCTAssertEqual(state.groups, SessionFlowGrouping.groups(rows: state.flow.rows), "groups differ after appending up to \(end)")
            start = end
        }
        assertEquivalent(state.flow, to: corpus, groups: state.groups)
    }

    // MARK: - Equivalence: prepend history pages (200-event pages)

    func testIncrementalPrependEqualsFullBuildInPages() {
        let corpus = Self.corpus
        var state = SessionRowBuilder.FlowState()
        state.reset(events: Array(corpus[600...]))
        var pageEnd = 600
        while pageEnd > 0 {
            let start = max(0, pageEnd - 200)
            state.prepend(events: Array(corpus[start..<pageEnd]))
            pageEnd = start
        }
        assertEquivalent(state.flow, to: corpus, groups: state.groups)
    }

    /// mixed：从中间窗口开始 → 前置两页 → 尾部追加，跨页边界的孤儿 tool/result 要补挂。
    func testMixedPrependAppendEqualsFullBuild() {
        let corpus = Self.corpus
        var state = SessionRowBuilder.FlowState()
        state.reset(events: Array(corpus[1200..<3200]))
        state.prepend(events: Array(corpus[900..<1200]))
        state.prepend(events: Array(corpus[600..<900]))
        state.append(events: Array(corpus[3200..<3500]))
        assertEquivalent(state.flow, to: Array(corpus[600...]), groups: state.groups)
        XCTAssertEqual(state.loadedSeqRange, corpus[600].seq...corpus[3499].seq)
    }

    /// 重复 append / prepend 已加载的 seq 必须是 no-op（幂等）。
    func testIncrementalIdempotentForAlreadyLoadedEvents() {
        let corpus = Self.corpus
        var state = SessionRowBuilder.FlowState()
        state.reset(events: Array(corpus[600...]))
        let before = state.flow
        state.append(events: Array(corpus[3300..<3500]))
        state.prepend(events: Array(corpus[600..<900]))
        XCTAssertEqual(state.flow.rows, before.rows)
    }

    /// assistant/message 的 tool-call block 与独立 tool/call 事件跨批次到达：
    /// 先渲染的 block 行必须在 tool/call 到达时被删掉，与全量重建（预扫描 callId）等价。
    func testDeferredToolCallBlockAcrossBatchesMatchesFullBuild() {
        let splitArgs = "{\"command\":\"ls\"}"
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("assistant/message", seq: 2, data: TestJSON.value("""
            {"message":{"content":[
              {"type":"reasoning","text":"先看结构"},
              {"type":"tool-call","name":"bash","arguments":\(TestJSON.quoted(splitArgs)),"id":"call_split_1"}
            ]},"turn":1}
            """)),
            TestJSON.event("tool/call", seq: 3, data: TestJSON.value("""
            {"callId":"call_split_1","name":"bash","arguments":\(TestJSON.quoted(splitArgs)),"turn":1,"step":1}
            """)),
            TestJSON.event("tool/result", seq: 4, data: TestJSON.value("""
            {"name":"bash","message":{"content":[{"type":"text","text":"a.swift"}],"isError":false,"toolCallId":"call_split_1"},"meta":{"cwd":"/tmp"}}
            """)),
        ]
        var state = SessionRowBuilder.FlowState()
        state.reset(events: Array(events[0...1]))
        state.append(events: Array(events[2...]))
        assertEquivalent(state.flow, to: events, groups: state.groups)
    }


    /// 跨批次补上的 tool/call 会让**列表中部**的 block 行退场：分组缓存必须走全量重算，
    /// 否则尾部增量刷新会留下一条已删除行的分组（视图会画出幽灵行）。
    func testDeferredToolCallBlockRemovedFromMiddleRefreshesGroups() {
        let splitArgs = "{\"command\":\"ls\"}"
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("assistant/message", seq: 2, data: TestJSON.value("""
            {"message":{"content":[
              {"type":"reasoning","text":"先看看"},
              {"type":"tool-call","name":"bash","arguments":\(TestJSON.quoted(splitArgs)),"id":"call_mid_1"}
            ],"turn":1}}
            """)),
            TestJSON.event("assistant/message", seq: 3, data: TestJSON.value("""
            {"message":{"content":[{"type":"text","text":"第一段正文"}],"turn":1}}
            """)),
            TestJSON.event("assistant/message", seq: 4, data: TestJSON.value("""
            {"message":{"content":[{"type":"text","text":"第二段正文"}],"turn":1}}
            """)),
            TestJSON.event("tool/call", seq: 5, data: TestJSON.value("""
            {"callId":"call_mid_1","name":"bash","arguments":\(TestJSON.quoted(splitArgs)),"turn":1,"step":1}
            """)),
            TestJSON.event("turn/end", seq: 6, data: .object(["turn": .int(1), "reason": TestJSON.reason("completed")])),
        ]
        var state = SessionRowBuilder.FlowState()
        state.reset(events: Array(events[0...1]))
        state.append(events: Array(events[2...3]))
        state.append(events: Array(events[4...5]))
        assertEquivalent(state.flow, to: events, groups: state.groups)
    }

    /// 更早一页里的孤儿 tool/result：prepend 补上调用行后，结果要挂到调用行并删掉孤儿行。
    func testPrependResolvesOrphanToolResultRow() {
        let earlyPage = [
            TestJSON.event("tool/result", seq: 10, data: TestJSON.value("""
            {"name":"bash","message":{"content":[{"type":"text","text":"orphan output"}],"isError":false,"toolCallId":"call_missing"},"meta":{}}
            """)),
        ]
        let laterWindow = [
            TestJSON.event("tool/call", seq: 11, data: TestJSON.value("""
            {"callId":"call_missing","name":"bash","arguments":"{}","turn":2,"step":1}
            """)),
            TestJSON.event("assistant/message", seq: 12, data: TestJSON.value("""
            {"message":{"content":[{"type":"text","text":"继续"}],"turn":2}}
            """)),
        ]
        var state = SessionRowBuilder.FlowState()
        state.reset(events: laterWindow)
        state.prepend(events: earlyPage)
        assertEquivalent(state.flow, to: earlyPage + laterWindow, groups: state.groups)
    }

    /// 窗口从一轮中间开始（没有 turn/start）→ 尾部追加 turn/end。
    func testMidTurnWindowAppendMatchesFullBuild() {
        let events = [
            TestJSON.event("assistant/message", seq: 5, data: TestJSON.value("""
            {"message":{"content":[{"type":"text","text":"中途"}],"turn":3}}
            """)),
            TestJSON.event("assistant/message", seq: 6, data: TestJSON.value("""
            {"message":{"content":[{"type":"text","text":"继续"}],"turn":3}}
            """)),
            TestJSON.event("turn/end", seq: 7, data: .object(["turn": .int(3), "reason": TestJSON.reason("completed")])),
        ]
        var state = SessionRowBuilder.FlowState()
        state.reset(events: Array(events[0...1]))
        state.append(events: [events[2]])
        assertEquivalent(state.flow, to: events, groups: state.groups)
    }

    // MARK: - Equivalence: incremental grouping cache

    func testFlowGroupCacheTailRefreshMatchesFullGrouping() {
        let rows = SessionRowBuilder.build(events: Self.corpus).rows
        var cache = FlowGroupCache()
        cache.rebuild(rows: Array(rows[0..<(rows.count - 20)]))
        cache.refreshTail(rows: rows)
        XCTAssertEqual(cache.groups, SessionFlowGrouping.groups(rows: rows))
    }

    // MARK: - Benchmarks

    func testBenchFullBuild3500Events() {
        let corpus = Self.corpus
        XCTAssertEqual(corpus.count, 3500)
        var rowCount = 0
        let median = bench("full-build-3500") { rowCount = SessionRowBuilder.build(events: corpus).rows.count }
        print("[bench] full-build-3500 rows=\(rowCount)")
        XCTAssertGreaterThan(rowCount, 0)
        XCTAssertLessThan(median, 2000, "debug build must stay far below pathological levels")
    }

    func testBenchIncrementalResetAndTailUpdates() {
        let corpus = Self.corpus
        var state = SessionRowBuilder.FlowState()
        bench("flowstate-reset-3500") { state.reset(events: corpus) }
        let rowCount = state.flow.rows.count

        bench("tail-append-1-event") {
            let seq = state.loadedSeqRange!.upperBound + 1
            state.append(events: [TestJSON.event("assistant/message", seq: seq, data: TestJSON.value("""
            {"message":{"content":[{"type":"text","text":"单个流式片段"}],"turn":999}}
            """))])
        }

        var streamState = SessionRowBuilder.FlowState()
        streamState.reset(events: corpus)
        var seqCursor = streamState.loadedSeqRange!.upperBound + 1
        bench("tail-append-10-events") {
            var batch: [SessionEvent] = []
            for offset in 0..<10 {
                batch.append(TestJSON.event("assistant/message", seq: seqCursor + offset, data: TestJSON.value("""
                {"message":{"content":[{"type":"reasoning","text":"流式思考片段 \(offset)"},{"type":"text","text":"流式正文片段 \(offset)"}],"turn":999}}
                """)))
            }
            seqCursor += 10
            streamState.append(events: batch)
        }

        var toolState = SessionRowBuilder.FlowState()
        toolState.reset(events: corpus)
        var toolSeq = toolState.loadedSeqRange!.upperBound + 1
        bench("tail-append-tool-result") {
            toolSeq += 3
            let callId = "call_live_\(toolSeq)"
            toolState.append(events: [
                TestJSON.event("tool/call", seq: toolSeq, data: TestJSON.value("""
                {"callId":"\(callId)","name":"bash","arguments":"{}","turn":999,"step":1}
                """)),
                TestJSON.event("tool/result", seq: toolSeq + 1, data: TestJSON.value("""
                {"name":"bash","message":{"content":[{"type":"text","text":"live output"}],"isError":false,"toolCallId":"\(callId)"},"meta":{"cwd":"/tmp","path":"/tmp/a.swift"}}
                """)),
            ])
        }

        var echoState = SessionRowBuilder.FlowState()
        echoState.reset(events: corpus)
        let echo = SessionRowBuilder.PendingUserEcho(requestId: "req-bench", text: "补一条", images: [], sentAt: 1_792_510_000_000, mode: "steer")
        bench("repaint-pending-echo") { echoState.repaintPendingEchoes([echo], nowMs: 1_792_510_000_500) }
        print("[bench] incremental rows=\(rowCount)")
    }

    func testBenchPrependHistoryPage() {
        let loaded = Self.makeCorpus(seqOffset: 20000, turnOffset: 500, eventTarget: 3500)
        let older = Self.makeCorpus(seqOffset: 0, turnOffset: 0, eventTarget: 3000)
        var pages: [[SessionEvent]] = []
        var sliceEnd = older.count
        while sliceEnd > 0 && pages.count < 6 {
            let start = max(0, sliceEnd - 300)
            pages.append(Array(older[start..<sliceEnd]))
            sliceEnd = start
        }
        var state = SessionRowBuilder.FlowState()
        state.reset(events: loaded)
        var pageIndex = 0
        bench("prepend-page-300") {
            if pageIndex < pages.count {
                state.prepend(events: pages[pageIndex])
                pageIndex += 1
            }
        }
        print("[bench] prepend-page-300 pages=\(pageIndex) rows=\(state.flow.rows.count)")
    }

    func testBenchGroupingCachedVsFull() {
        let rows = SessionRowBuilder.build(events: Self.corpus).rows
        var cache = FlowGroupCache()
        cache.rebuild(rows: rows)
        bench("groups-full-\(rows.count)-rows") { _ = SessionFlowGrouping.groups(rows: rows) }
        bench("groups-cache-tail-refresh") { cache.refreshTail(rows: rows) }
    }

    /// 旧回路（每批 live 事件全量重建）的等价基线，便于报告对比。
    func testBenchOldTailUpdateViaFullRebuild() {
        let corpus = Self.corpus
        bench("tail-update-old(full-rebuild)") { _ = SessionRowBuilder.build(events: corpus) }
        let page = Array(corpus.prefix(300))
        bench("prepend-page-old(full-rebuild)") { _ = SessionRowBuilder.build(events: page + corpus) }
    }
}
