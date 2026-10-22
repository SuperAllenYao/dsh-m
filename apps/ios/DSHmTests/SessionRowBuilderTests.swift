import XCTest
@testable import DSHm

/// 平铺会话流契约（2026-10-23 用户拍板删除 turn UI 后）：
///
/// - `SessionRowBuilder.build(events:pendingUserEchoes:nowMs:)` 返回 `SessionFlow`：
///   一条**连续**的 `rows` 消息流，跨 turn 不再分组（没有 turn 卡片 / 状态点 / 折叠）。
/// - `turn/start` / `turn/end` **不产生任何行**，只推导两个值：
///   - `isRunning`：窗口内最新一轮已 `turn/start` 未 `turn/end`；窗口从一轮中间开始时，
///     最后一条 `turn/end` 之后又出现带 `data.turn` 的行事件也视为新一轮开始；
///   - `latestFileChangeSeq` / `latestFileChanges`：只保留**最新一轮**的文件变更
///     （`workspace/changes` 取最后一个 seq；工具结果 `meta.diffs` 客户端聚合回退）。
/// - 乐观回显（`PendingUserEcho`）以「用户气泡 + 发送中…」两行追加在流尾，按
///   `requestId` 幂等，由持久 `user/message` 的 `data.source.rpcId` 退休。
///
/// 旧的 `[TurnSection]` 分组、`TurnStatus` 与 `status(from:)` / `firstUserText(in:)`
/// 已随 turn UI 一起删除；本文件只断言行顺序 / 行内容 / 行类型 / 工具结果挂载
/// 以及上面三个派生值。
final class SessionRowBuilderTests: XCTestCase {

    // MARK: - Fixtures & helpers

    /// Builds a session/follow-like event log (fixtures are JSON strings so they
    /// exercise the same decoding path as the wire).
    private func sampleEvents() -> [SessionEvent] {
        let bashArgs = #"{"command":"pnpm test","description":"run tests"}"#
        let assistantJSON = """
        {"message":{"content":[
          {"type":"reasoning","text":"先看看仓库结构"},
          {"type":"text","text":"我来执行。"},
          {"type":"tool-call","name":"bash","arguments":\(TestJSON.quoted(bashArgs)),"id":"call_1"}
        ]},"source":{"provider":"mock","model":"mock-tool"}}
        """
        let toolCallJSON = """
        {"callId":"call_1","name":"bash","arguments":\(TestJSON.quoted(bashArgs)),"turn":1,"step":1}
        """
        return [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("user/message", seq: 2, data: TestJSON.value("""
            {"content":[{"type":"text","text":"跑一下测试"}],"source":{"kind":"user"},"role":"user","id":"m1"}
            """)),
            TestJSON.event("assistant/message", seq: 3, data: TestJSON.value(assistantJSON)),
            TestJSON.event("tool/call", seq: 4, data: TestJSON.value(toolCallJSON)),
            TestJSON.event("tool/result", seq: 5, data: TestJSON.value("""
            {"name":"bash","message":{"content":[{"type":"text","text":"✓ 14 tests passed"}],"isError":false,"toolCallId":"call_1"},"meta":{"cwd":"/Users/example/dsh-m"}}
            """)),
            TestJSON.event("turn/end", seq: 6, data: .object(["turn": .int(1), "reason": TestJSON.reason("completed")])),
        ]
    }

    private func userTexts(in rows: [FlowRow]) -> [String] {
        rows.compactMap { row -> String? in
            if case .user(let bubble) = row.content { return bubble.text }
            return nil
        }
    }

    private func sendingNotes(in rows: [FlowRow]) -> [String] {
        rows.compactMap { row -> String? in
            if case .systemNote(let text) = row.content { return text }
            return nil
        }
    }

    private func texts(in rows: [FlowRow]) -> [String] {
        rows.compactMap { row -> String? in
            if case .text(let text) = row.content { return text }
            return nil
        }
    }

    // MARK: - Flat rows (the whole session is one stream)

    func testFlatRowsAndToolPairing() {
        let flow = SessionRowBuilder.build(events: sampleEvents())
        // turn/start (seq 1) and turn/end (seq 6) must not add rows: the stream is
        // user + reasoning + text + one tool row (the assistant tool-call block is
        // deduped by callId because a tool/call event exists).
        XCTAssertEqual(flow.rows.map(\.seq), [2, 3, 3, 4])
        XCTAssertEqual(userTexts(in: flow.rows), ["跑一下测试"])

        var userCount = 0
        var reasoningCount = 0
        var textCount = 0
        var toolCalls: [ToolCallItem] = []
        for row in flow.rows {
            switch row.content {
            case .user: userCount += 1
            case .reasoning: reasoningCount += 1
            case .text: textCount += 1
            case .tool(let item): toolCalls.append(item)
            default: break
            }
        }
        XCTAssertEqual(userCount, 1)
        XCTAssertEqual(reasoningCount, 1)
        XCTAssertEqual(textCount, 1)
        XCTAssertEqual(toolCalls.count, 1, "assistant tool-call block must not duplicate the tool/call row")
        let call = try! XCTUnwrap(toolCalls.first)
        XCTAssertEqual(call.callId, "call_1")
        XCTAssertEqual(call.summary, "pnpm test")
        XCTAssertEqual(call.result?.text, "✓ 14 tests passed")
        XCTAssertFalse(call.result?.isError ?? true)

        let found = SessionRowBuilder.findToolCall(in: flow.rows, callId: "call_1")
        XCTAssertEqual(found?.arguments["description"]?.stringValue, "run tests")
        XCTAssertFalse(flow.isRunning, "the only turn has ended")
    }

    func testUserMessageSourceClassification() {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("user/message", seq: 2, data: TestJSON.value("""
            {"content":[{"type":"text","text":"子代理汇报"}],"source":{"kind":"agent-message","form":"relay","senderSessionId":"session-child-1"}}
            """)),
            TestJSON.event("user/message", seq: 3, data: TestJSON.value("""
            {"content":[{"type":"text","text":"子代理已完成"}],"source":{"kind":"subagent-settled","form":"notice"}}
            """)),
            TestJSON.event("user/message", seq: 4, data: TestJSON.value("""
            {"content":[{"type":"text","text":"runtime context"}],"source":{"kind":"runtime-context","form":"snapshot"}}
            """)),
        ]
        let flow = SessionRowBuilder.build(events: events)
        var relayCount = 0
        var noticeCount = 0
        for row in flow.rows {
            switch row.content {
            case .relay: relayCount += 1
            case .notice: noticeCount += 1
            default: break
            }
        }
        XCTAssertEqual(relayCount, 1)
        XCTAssertEqual(noticeCount, 1, "subagent-settled -> notice card")
        XCTAssertEqual(flow.rows.count, 2, "runtime-context must be hidden")
    }

    func testApprovalAskedDecidedPairing() {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(3)])),
            TestJSON.event("approval/asked", seq: 2, data: TestJSON.value("""
            {"id":"evt-1","toolName":"bash","callId":"call_9","reason":"escalate sandbox"}
            """)),
            TestJSON.event("approval/decided", seq: 3, data: TestJSON.value(#"{"id":"evt-1","outcome":"allowed-once"}"#)),
        ]
        let flow = SessionRowBuilder.build(events: events)
        let approvals = flow.rows.compactMap { row -> ApprovalItem? in
            if case .approval(let item) = row.content { return item }
            return nil
        }
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals.first?.toolName, "bash")
        XCTAssertEqual(approvals.first?.outcome, "allowed-once")
    }

    func testFileChangesAggregatedFromToolResultDiffs() {
        let editArgs = #"{"file_path":"a.ts"}"#
        let toolCallJSON = """
        {"callId":"call_edit","name":"edit","arguments":\(TestJSON.quoted(editArgs)),"turn":1,"step":1}
        """
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("tool/call", seq: 2, data: TestJSON.value(toolCallJSON)),
            TestJSON.event("tool/result", seq: 3, data: TestJSON.value("""
            {"name":"edit","message":{"content":[{"type":"text","text":"ok"}],"isError":false,"toolCallId":"call_edit"},
             "meta":{"path":"a.ts","diffs":[{"path":"a.ts","oldText":"a","newText":"a\\nb"}]}}
            """)),
        ]
        let flow = SessionRowBuilder.build(events: events)
        let changes = try! XCTUnwrap(flow.latestFileChanges)
        XCTAssertEqual(changes.files, ["a.ts"])
        XCTAssertGreaterThan(changes.additions, 0)
        XCTAssertNil(flow.latestFileChangeSeq, "no workspace/changes event in this window")
    }

    func testWorkspaceChangesSeqIsCapturedForExactFetch() {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(2)])),
            TestJSON.event("workspace/changes", seq: 7, data: .object(["turn": .int(2)])),
            TestJSON.event("turn/end", seq: 9, data: .object(["turn": .int(2), "reason": TestJSON.reason("completed")])),
        ]
        let flow = SessionRowBuilder.build(events: events)
        XCTAssertEqual(flow.latestFileChangeSeq, 7, "workspace/changes seq keys /api/changes.summary")
        XCTAssertTrue(flow.rows.isEmpty, "workspace/changes stays hidden from the flow")
        XCTAssertFalse(flow.isRunning)
    }

    func testChangesSummaryAndDiffDecode() throws {
        let summary = try JSONDecoder().decode(ChangesSummaryValue.self, from: Data("""
        {"turn":1,"files":[{"path":"notes.txt","display":"notes.txt","added":1,"deleted":0}],"total":1,"added":1,"deleted":0}
        """.utf8))
        XCTAssertEqual(summary.files.first?.path, "notes.txt")
        XCTAssertEqual(summary.added, 1)

        let diff = try JSONDecoder().decode(ChangesDiffValue.self, from: Data("""
        {"kind":"text","path":"notes.txt","display":"notes.txt","before":false,"after":true,
         "hunks":[{"oldStart":1,"oldLines":0,"newStart":1,"newLines":1,"lines":["+hello"]}],"coarse":false}
        """.utf8))
        XCTAssertEqual(diff.hunks?.first?.lines, ["+hello"])
        XCTAssertEqual(diff.coarse, false)
    }

    func testToolBackedJobEventsAreHiddenAsDuplicateRows() {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("job/registered", seq: 2, data: TestJSON.value("""
            {"jobId":"job-1","owner":"tool","kind":"bash","label":"printf ...","startedAt":1,
             "toolCall":{"callId":"call_1","rootCallId":"call_1"}}
            """)),
            TestJSON.event("job/settled", seq: 3, data: TestJSON.value("""
            {"jobId":"job-1","kind":"bash","label":"printf ...","status":"completed","finishedAt":2,
             "toolCall":{"callId":"call_1","rootCallId":"call_1"}}
            """)),
            TestJSON.event("job/registered", seq: 4, data: TestJSON.value("""
            {"jobId":"job-2","owner":"agent","kind":"bash","label":"vite dev","startedAt":3}
            """)),
        ]
        let flow = SessionRowBuilder.build(events: events)
        let jobRows = flow.rows.compactMap { row -> JobItem? in
            if case .job(let job) = row.content { return job }
            return nil
        }
        XCTAssertEqual(jobRows.count, 1, "tool-backed job events must not duplicate the step row")
        XCTAssertEqual(jobRows.first?.jobId, "job-2", "standalone background jobs still render")
    }

    func testHiddenEventTypesAreSkipped() {
        let events = [
            TestJSON.event("developer/message", seq: 1),
            TestJSON.event("request/header", seq: 2),
            TestJSON.event("compaction/prune", seq: 3),
            TestJSON.event("turn/start", seq: 4, data: .object(["turn": .int(1)])),
        ]
        let flow = SessionRowBuilder.build(events: events)
        XCTAssertTrue(flow.rows.isEmpty)
        XCTAssertTrue(flow.isRunning, "turn/start feeds isRunning even though it renders no row")
    }

    // MARK: - Optimistic user echo (steer / send-then-wait, round2 §3)

    /// Fixed wall clock for the echo tests: real time must not decide whether a
    /// fixture's "发送中…" marker is still fresh.
    private let echoNowMs: Int64 = 1_792_510_100_000

    private func steerEcho(
        requestId: String = "req-steer-1",
        text: String = "插队：先别跑长命令"
    ) -> SessionRowBuilder.PendingUserEcho {
        SessionRowBuilder.PendingUserEcho(
            requestId: requestId,
            text: text,
            sentAt: echoNowMs,
            mode: "steer"
        )
    }

    private func runningTurnWithoutSteerEvent() -> [SessionEvent] {
        [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("user/message", seq: 2, data: TestJSON.value("""
            {"content":[{"type":"text","text":"跑一遍全量测试"}],"source":{"kind":"user"},"role":"user","id":"m1"}
            """)),
            TestJSON.event("tool/call", seq: 3, data: TestJSON.value("""
            {"callId":"call_1","name":"bash","arguments":"{\\"command\\":\\"xcodebuild test\\"}","turn":1,"step":1}
            """)),
        ]
    }

    private func durableSteerEvent(seq: Int = 6, rpcId: String = "req-steer-1", text: String = "插队：先别跑长命令") -> SessionEvent {
        let source: String
        if rpcId.isEmpty {
            source = #""source":{"kind":"user"}"#
        } else {
            source = "\"source\":{\"kind\":\"user\",\"rpcId\":\"\(rpcId)\"}"
        }
        return TestJSON.event("user/message", seq: seq, data: TestJSON.value("""
        {"content":[{"type":"text","text":"\(text)"}],\(source),"role":"user","id":"m2"}
        """))
    }

    func testPendingUserEchoPaintsImmediatelyAtEndOfRunningTurn() {
        let echo = steerEcho()
        let flow = SessionRowBuilder.build(
            events: runningTurnWithoutSteerEvent(),
            pendingUserEchoes: [echo],
            nowMs: echoNowMs
        )
        // The pending prompt adds only its bubble + progress note to the flat flow:
        // user(seq 2) + tool(seq 3) + the two echo rows.
        XCTAssertEqual(flow.rows.count, 4, "the pending prompt must not invent extra rows")
        XCTAssertTrue(flow.isRunning)
        XCTAssertEqual(userTexts(in: flow.rows), ["跑一遍全量测试", "插队：先别跑长命令"])
        XCTAssertEqual(sendingNotes(in: flow.rows), ["发送中…"])
        let rows = flow.rows
        XCTAssertEqual(rows[rows.count - 2].id, "pending-\(echo.requestId)-user")
        XCTAssertEqual(rows[rows.count - 1].id, "pending-\(echo.requestId)-status")
        XCTAssertEqual(rows[rows.count - 2].seq, 4)
        XCTAssertEqual(rows[rows.count - 1].seq, 5)
    }

    func testPendingUserEchoIsRetiredByDurableRpcId() {
        var store = SessionRowBuilder.PendingUserEchoStore()
        store.record(steerEcho())
        let events = runningTurnWithoutSteerEvent() + [durableSteerEvent()]
        store.reconcile(events: events)
        XCTAssertTrue(store.isEmpty, "durable user/message carried source.rpcId === requestId")
        let flow = SessionRowBuilder.build(events: events, pendingUserEchoes: store.echoes, nowMs: echoNowMs)
        XCTAssertEqual(userTexts(in: flow.rows), ["跑一遍全量测试", "插队：先别跑长命令"], "exactly one steer bubble, no duplicate")
        XCTAssertTrue(sendingNotes(in: flow.rows).isEmpty, "sending marker disappears when the echo retires")
        XCTAssertEqual(SessionRowBuilder.userMessageRpcId(of: events[events.count - 1]), "req-steer-1")
    }

    func testRebuildKeepsPendingEchoWhenDurableEventNotYetArrived() {
        var store = SessionRowBuilder.PendingUserEchoStore()
        store.record(steerEcho())
        for events in [
            runningTurnWithoutSteerEvent(),
            Array(runningTurnWithoutSteerEvent().prefix(1)),
            [SessionEvent](),
        ] {
            store.reconcile(events: events)
            let flow = SessionRowBuilder.build(events: events, pendingUserEchoes: store.echoes, nowMs: echoNowMs)
            XCTAssertEqual(store.count, 1)
            XCTAssertEqual(userTexts(in: flow.rows).last, "插队：先别跑长命令", "pending bubble still painted after rebuild")
            XCTAssertEqual(sendingNotes(in: flow.rows), ["发送中…"])
        }
    }

    func testSendFailureRemovesPendingEchoRow() {
        var store = SessionRowBuilder.PendingUserEchoStore()
        store.record(steerEcho())
        store.remove(requestId: "req-steer-1")
        XCTAssertTrue(store.isEmpty)
        let flow = SessionRowBuilder.build(
            events: runningTurnWithoutSteerEvent(),
            pendingUserEchoes: store.echoes,
            nowMs: echoNowMs
        )
        XCTAssertEqual(userTexts(in: flow.rows), ["跑一遍全量测试"], "failed steer leaves no ghost bubble")
        XCTAssertTrue(sendingNotes(in: flow.rows).isEmpty)
    }

    func testDurableMessageWithoutRpcIdDoesNotRetireEcho() {
        var store = SessionRowBuilder.PendingUserEchoStore()
        store.record(steerEcho())
        let events = runningTurnWithoutSteerEvent() + [
            durableSteerEvent(seq: 6, rpcId: "", text: "桌面端发的消息"),
        ]
        store.reconcile(events: events)
        XCTAssertEqual(store.count, 1, "only our own rpcId retires the echo (desktop messages have none)")
    }

    func testPendingEchoOnEmptyJournalPaintsFlatRows() {
        let flow = SessionRowBuilder.build(events: [], pendingUserEchoes: [steerEcho()], nowMs: echoNowMs)
        // No turn section is invented: the echo is two rows at the end of the
        // otherwise empty stream, and no boundary event means "not running".
        XCTAssertEqual(flow.rows.count, 2)
        XCTAssertFalse(flow.isRunning, "a pending echo does not invent a running turn")
        XCTAssertEqual(userTexts(in: flow.rows), ["插队：先别跑长命令"])
        XCTAssertEqual(sendingNotes(in: flow.rows), ["发送中…"])
    }

    func testUnknownUserMessageSourceKindRendersNoticeInsteadOfBeingDropped() {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("user/message", seq: 2, data: TestJSON.value("""
            {"content":[{"type":"text","text":"来自未知来源"}],"source":{"kind":"steer"}}
            """)),
        ]
        let flow = SessionRowBuilder.build(events: events)
        let notices = flow.rows.compactMap { row -> NoticeCard? in
            if case .notice(let card) = row.content { return card }
            return nil
        }
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.kind, "steer")
        XCTAssertEqual(notices.first?.text, "来自未知来源")
    }

    func testSendingIndicatorExpiresButPendingBubbleStays() {
        let echo = steerEcho()
        let timeout = SessionRowBuilder.PendingUserEchoStore.sendingIndicatorTimeoutMs
        let fresh = SessionRowBuilder.build(
            events: runningTurnWithoutSteerEvent(),
            pendingUserEchoes: [echo],
            nowMs: echoNowMs + timeout - 1
        )
        XCTAssertEqual(sendingNotes(in: fresh.rows), ["发送中…"], "still inside the timeout")
        let stale = SessionRowBuilder.build(
            events: runningTurnWithoutSteerEvent(),
            pendingUserEchoes: [echo],
            nowMs: echoNowMs + timeout
        )
        XCTAssertTrue(sendingNotes(in: stale.rows).isEmpty, "\"发送中…\" must never hang after the timeout")
        XCTAssertEqual(
            userTexts(in: stale.rows).last,
            "插队：先别跑长命令",
            "the user's own bubble is kept until the durable event retires it"
        )
    }

    func testStaleEchoStillRetiresWhenDurableEventArrivesEventually() {
        var store = SessionRowBuilder.PendingUserEchoStore()
        store.record(steerEcho())
        let events = runningTurnWithoutSteerEvent() + [durableSteerEvent()]
        store.reconcile(events: events)
        XCTAssertTrue(store.isEmpty)
        let flow = SessionRowBuilder.build(
            events: events,
            pendingUserEchoes: store.echoes,
            nowMs: echoNowMs + SessionRowBuilder.PendingUserEchoStore.sendingIndicatorTimeoutMs * 10
        )
        XCTAssertEqual(userTexts(in: flow.rows), ["跑一遍全量测试", "插队：先别跑长命令"])
        XCTAssertTrue(sendingNotes(in: flow.rows).isEmpty)
    }

    func testNextSendingIndicatorDeadlineIsEarliestEchoTimeout() {
        var store = SessionRowBuilder.PendingUserEchoStore()
        let timeout = SessionRowBuilder.PendingUserEchoStore.sendingIndicatorTimeoutMs
        let first = SessionRowBuilder.PendingUserEcho(requestId: "req-a", text: "a", sentAt: echoNowMs, mode: "steer")
        let second = SessionRowBuilder.PendingUserEcho(requestId: "req-b", text: "b", sentAt: echoNowMs + 5_000, mode: "queue")
        store.record(second)
        store.record(first)
        XCTAssertEqual(
            store.nextSendingIndicatorDeadline(nowMs: echoNowMs),
            echoNowMs + timeout,
            "the VM timer must wake for the oldest echo"
        )
        store.remove(requestId: "req-a")
        XCTAssertEqual(
            store.nextSendingIndicatorDeadline(nowMs: echoNowMs),
            echoNowMs + 5_000 + timeout
        )
        // Expired indicators must yield nil: the stale-repaint task would
        // otherwise reschedule itself in a busy loop.
        XCTAssertNil(store.nextSendingIndicatorDeadline(nowMs: echoNowMs + 5_000 + timeout))
        store.removeAll()
        XCTAssertNil(store.nextSendingIndicatorDeadline(nowMs: echoNowMs))
    }

    func testRepaintPendingEchoesIsIdempotent() {
        // The view model repaints the tail right after the RPC and again when the
        // "发送中…" marker expires; the same requestId must never paint twice.
        let echo = steerEcho()
        var rows = SessionRowBuilder.build(events: runningTurnWithoutSteerEvent(), nowMs: echoNowMs).rows
        for _ in 0..<3 {
            rows = SessionRowBuilder.appendingPendingEchoes([echo], to: rows, nowMs: echoNowMs)
        }
        XCTAssertEqual(userTexts(in: rows), ["跑一遍全量测试", "插队：先别跑长命令"])
        XCTAssertEqual(sendingNotes(in: rows), ["发送中…"])
        let refreshed = SessionRowBuilder.appendingPendingEchoes(
            [echo],
            to: rows,
            nowMs: echoNowMs + SessionRowBuilder.PendingUserEchoStore.sendingIndicatorTimeoutMs
        )
        XCTAssertEqual(userTexts(in: refreshed), ["跑一遍全量测试", "插队：先别跑长命令"])
        XCTAssertTrue(sendingNotes(in: refreshed).isEmpty, "expiry repaint drops only the marker")
    }

    func testRecordIsIdempotentPerRequestId() {
        var store = SessionRowBuilder.PendingUserEchoStore()
        store.record(steerEcho(text: "旧文本"))
        store.record(steerEcho(text: "新文本"))
        XCTAssertEqual(store.count, 1, "a retried prompt must not leave two pending bubbles")
        XCTAssertEqual(store.echoes.first?.text, "新文本")
    }

    // MARK: - Mid-turn window (real-device regression 2026-10-22)

    /// Window shape taken from the real session log (session-daa07b5a…): the
    /// follow window starts at seq 3232 while `turn/start` for turn 8 is seq
    /// 3225, i.e. outside the window. The first row-producing event is a
    /// `user/message`, which carries no `data.turn`.
    private func midTurnWindowEvents() -> [SessionEvent] {
        [
            TestJSON.event("user/message", seq: 3232, data: TestJSON.value("""
            {"content":[{"type":"text","text":"跑一遍真机回归"}],"source":{"kind":"user"},"role":"user","id":"m1"}
            """)),
            TestJSON.event("assistant/message", seq: 3235, data: TestJSON.value("""
            {"turn":8,"message":{"content":[{"type":"text","text":"收到，开始跑。"}]},"source":{"provider":"mock","model":"mock"}}
            """)),
            TestJSON.event("user/message", seq: 3236, data: TestJSON.value("""
            {"content":[{"type":"text","text":"子代理结算摘要"}],"source":{"kind":"subagent-settled","summary":"子代理结算摘要"}}
            """)),
            TestJSON.event("turn/end", seq: 3240, data: .object(["turn": .int(8), "reason": TestJSON.reason("completed")])),
            TestJSON.event("turn/start", seq: 3244, data: .object(["turn": .int(9)])),
            TestJSON.event("assistant/message", seq: 3245, data: TestJSON.value("""
            {"turn":9,"message":{"content":[{"type":"text","text":"下一轮输出。"}]}}
            """)),
            TestJSON.event("turn/end", seq: 3246, data: .object(["turn": .int(9), "reason": TestJSON.reason("completed")])),
        ]
    }

    func testWindowStartingMidTurnKeepsFlatRows() {
        let flow = SessionRowBuilder.build(events: midTurnWindowEvents())
        // Both turns share one continuous stream: the window tail that belongs to
        // turn 8 and the turn-9 rows are just adjacent rows (no Turn 0 / headers).
        XCTAssertEqual(flow.rows.map(\.seq), [3232, 3235, 3236, 3245])
        XCTAssertEqual(userTexts(in: flow.rows).first, "跑一遍真机回归", "the window's first rows belong to turn 8")
        let noticeKinds = flow.rows.compactMap { row -> String? in
            if case .notice(let notice) = row.content { return notice.kind }
            return nil
        }
        XCTAssertEqual(noticeKinds, ["subagent-settled"])
        XCTAssertTrue(flow.rows.contains { row in
            if case .text(let text) = row.content { return text == "收到，开始跑。" }
            return false
        })
        XCTAssertTrue(flow.rows.contains { row in
            if case .text(let text) = row.content { return text == "下一轮输出。" }
            return false
        })
        XCTAssertFalse(flow.isRunning, "the newest turn (9) ended")
    }

    func testPureNoticeWindowIsNotRunning() {
        let events = [
            TestJSON.event("user/message", seq: 10, data: TestJSON.value("""
            {"content":[{"type":"text","text":"子代理结算摘要"}],"source":{"kind":"subagent-settled","summary":"子代理结算摘要"}}
            """)),
            TestJSON.event("user/message", seq: 11, data: TestJSON.value("""
            {"content":[{"type":"text","text":"后台任务"}],"source":{"kind":"tool-jobs","summary":"后台任务"}}
            """)),
            TestJSON.event("job/registered", seq: 12, data: TestJSON.value("""
            {"jobId":"job-1","kind":"bash","label":"xcodebuild","startedAt":1}
            """)),
        ]
        let flow = SessionRowBuilder.build(events: events)
        // An orphan window (no turn/start) paints its rows, but no row carries a
        // live turn, so the flow must not claim 运行中.
        XCTAssertEqual(flow.rows.map(\.seq), [10, 11, 12])
        XCTAssertNil(flow.latestFileChangeSeq)
        XCTAssertFalse(flow.isRunning, "an orphan window has no live turn to run")
    }

    func testMidTurnWindowOfALiveTurnStaysRunning() {
        // Same window shape, but the turn has not ended and its rows carry
        // `data.turn`: the flat flow still reports running.
        let events = [
            TestJSON.event("user/message", seq: 3232, data: TestJSON.value("""
            {"content":[{"type":"text","text":"跑一遍真机回归"}],"source":{"kind":"user"},"role":"user","id":"m1"}
            """)),
            TestJSON.event("assistant/message", seq: 3235, data: TestJSON.value("""
            {"turn":8,"message":{"content":[{"type":"text","text":"正在跑。"}]}}
            """)),
        ]
        let flow = SessionRowBuilder.build(events: events)
        XCTAssertEqual(flow.rows.count, 2)
        XCTAssertTrue(flow.isRunning, "a live mid-turn window must keep the running indicator")
    }

    func testMidTurnWindowClosedByTurnEndStopsRunning() {
        let events = [
            TestJSON.event("user/message", seq: 3232, data: TestJSON.value("""
            {"content":[{"type":"text","text":"收尾消息"}],"source":{"kind":"user"},"role":"user","id":"m1"}
            """)),
            TestJSON.event("turn/end", seq: 3240, data: .object(["turn": .int(8), "reason": TestJSON.reason("completed")])),
        ]
        let flow = SessionRowBuilder.build(events: events)
        // turn/end renders nothing; it only closes the tail whose turn/start is
        // outside the page, so the rows stay and running becomes false.
        XCTAssertEqual(flow.rows.map(\.seq), [3232])
        XCTAssertEqual(userTexts(in: flow.rows), ["收尾消息"])
        XCTAssertFalse(flow.isRunning, "turn/end closes a window whose turn/start is outside the page")
    }

    // MARK: - Flat contract across turn boundaries (turn-UI removal 2026-10-23)

    func testTurnBoundariesProduceNoRowsAcrossTurns() {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("user/message", seq: 2, data: TestJSON.value("""
            {"content":[{"type":"text","text":"第一轮"}],"source":{"kind":"user"},"role":"user","id":"m1"}
            """)),
            TestJSON.event("assistant/message", seq: 3, data: TestJSON.value("""
            {"turn":1,"message":{"content":[{"type":"text","text":"回复一"}]},"source":{"provider":"mock","model":"mock"}}
            """)),
            TestJSON.event("turn/end", seq: 4, data: .object(["turn": .int(1), "reason": TestJSON.reason("completed")])),
            TestJSON.event("turn/start", seq: 5, data: .object(["turn": .int(2)])),
            TestJSON.event("user/message", seq: 6, data: TestJSON.value("""
            {"content":[{"type":"text","text":"第二轮"}],"source":{"kind":"user"},"role":"user","id":"m2"}
            """)),
            TestJSON.event("assistant/message", seq: 7, data: TestJSON.value("""
            {"turn":2,"message":{"content":[{"type":"text","text":"回复二"}]},"source":{"provider":"mock","model":"mock"}}
            """)),
            TestJSON.event("turn/end", seq: 8, data: .object(["turn": .int(2), "reason": TestJSON.reason("completed")])),
        ]
        let flow = SessionRowBuilder.build(events: events)
        XCTAssertEqual(
            flow.rows.map(\.seq),
            [2, 3, 6, 7],
            "turn/start and turn/end add no rows; both turns share one continuous stream"
        )
        XCTAssertEqual(userTexts(in: flow.rows), ["第一轮", "第二轮"])
        XCTAssertEqual(texts(in: flow.rows), ["回复一", "回复二"])
        XCTAssertFalse(flow.isRunning)
    }

    // MARK: - isRunning derivation (boundaries only feed the indicator)

    func testIsRunningBecomesTrueOnTurnStart() {
        let flow = SessionRowBuilder.build(events: [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
        ])
        XCTAssertTrue(flow.rows.isEmpty, "turn/start renders nothing")
        XCTAssertTrue(flow.isRunning)
    }

    func testIsRunningBecomesFalseOnTurnEnd() {
        let flow = SessionRowBuilder.build(events: [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("turn/end", seq: 2, data: .object(["turn": .int(1), "reason": TestJSON.reason("completed")])),
        ])
        XCTAssertTrue(flow.rows.isEmpty)
        XCTAssertFalse(flow.isRunning)
    }

    func testIsRunningIsFalseForWindowStartingMidTurn() {
        // No turn/start and no turn/end inside the window, and no row event carries
        // `data.turn`: the flow cannot know about a live turn, so it must not claim one.
        let flow = SessionRowBuilder.build(events: [
            TestJSON.event("user/message", seq: 3232, data: TestJSON.value("""
            {"content":[{"type":"text","text":"窗口内消息"}],"source":{"kind":"user"},"role":"user","id":"m1"}
            """)),
        ])
        XCTAssertEqual(userTexts(in: flow.rows), ["窗口内消息"])
        XCTAssertFalse(flow.isRunning)
    }

    func testIsRunningTurnsTrueWhenRowAfterLastTurnEndCarriesNewerTurn() {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(3)])),
            TestJSON.event("turn/end", seq: 2, data: .object(["turn": .int(3), "reason": TestJSON.reason("completed")])),
            TestJSON.event("assistant/message", seq: 3, data: TestJSON.value("""
            {"turn":4,"message":{"content":[{"type":"text","text":"下一轮已经开始"}]},"source":{"provider":"mock","model":"mock"}}
            """)),
        ]
        let flow = SessionRowBuilder.build(events: events)
        XCTAssertEqual(texts(in: flow.rows), ["下一轮已经开始"])
        XCTAssertTrue(flow.isRunning, "a turn-scoped row after the last turn/end means a new turn started")
    }

    // MARK: - Latest-turn file changes (only the newest turn counts)

    func testLatestFileChangeSeqUsesLastWorkspaceChangesOfNewestTurn() {
        let oldArgs = #"{"file_path":"old.ts"}"#
        let newArgs = #"{"file_path":"new.ts"}"#
        let oldCallJSON = """
        {"callId":"call_old","name":"edit","arguments":\(TestJSON.quoted(oldArgs)),"turn":1,"step":1}
        """
        let newCallJSON = """
        {"callId":"call_new","name":"edit","arguments":\(TestJSON.quoted(newArgs)),"turn":2,"step":1}
        """
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("workspace/changes", seq: 2, data: .object(["turn": .int(1)])),
            TestJSON.event("tool/call", seq: 3, data: TestJSON.value(oldCallJSON)),
            TestJSON.event("tool/result", seq: 4, data: TestJSON.value("""
            {"name":"edit","message":{"content":[{"type":"text","text":"ok"}],"isError":false,"toolCallId":"call_old"},
             "meta":{"path":"old.ts","diffs":[{"path":"old.ts","oldText":"x","newText":"x\\ny"}]}}
            """)),
            TestJSON.event("turn/end", seq: 5, data: .object(["turn": .int(1), "reason": TestJSON.reason("completed")])),
            TestJSON.event("turn/start", seq: 6, data: .object(["turn": .int(2)])),
            TestJSON.event("workspace/changes", seq: 7, data: .object(["turn": .int(2)])),
            TestJSON.event("workspace/changes", seq: 8, data: .object(["turn": .int(2)])),
            TestJSON.event("tool/call", seq: 9, data: TestJSON.value(newCallJSON)),
            TestJSON.event("tool/result", seq: 10, data: TestJSON.value("""
            {"name":"edit","message":{"content":[{"type":"text","text":"ok"}],"isError":false,"toolCallId":"call_new"},
             "meta":{"path":"new.ts","diffs":[{"path":"new.ts","oldText":"x","newText":"x\\nz"}]}}
            """)),
            TestJSON.event("turn/end", seq: 11, data: .object(["turn": .int(2), "reason": TestJSON.reason("completed")])),
        ]
        let flow = SessionRowBuilder.build(events: events)
        XCTAssertEqual(flow.latestFileChangeSeq, 8, "the last workspace/changes seq of the newest turn wins")
        let changes = try! XCTUnwrap(flow.latestFileChanges)
        XCTAssertEqual(changes.files, ["new.ts"], "the previous turn's diffs must not leak into the newest turn")
        XCTAssertFalse(flow.isRunning)
    }

    func testNewTurnStartDropsPreviousWorkspaceChangesSeq() {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("workspace/changes", seq: 2, data: .object(["turn": .int(1)])),
            TestJSON.event("turn/end", seq: 3, data: .object(["turn": .int(1), "reason": TestJSON.reason("completed")])),
            TestJSON.event("turn/start", seq: 4, data: .object(["turn": .int(2)])),
        ]
        let flow = SessionRowBuilder.build(events: events)
        XCTAssertNil(flow.latestFileChangeSeq, "a new turn makes the previous turn's seq stale")
        XCTAssertTrue(flow.rows.isEmpty)
        XCTAssertTrue(flow.isRunning)
    }

    /// The only turn boundary that still paints a row: a failed turn surfaces its
    /// error in the flat flow (aborted turns stay silent — no status UI any more).
    func testTurnEndErrorStillRendersErrorRow() {
        let flow = SessionRowBuilder.build(events: [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(2)])),
            TestJSON.event("turn/end", seq: 2, data: TestJSON.value(#"{"turn":2,"reason":{"kind":"error","error":{"message":"boom","code":"E42"}}}"#)),
        ])
        XCTAssertEqual(flow.rows.count, 1)
        if case .error(let text) = flow.rows[0].content {
            XCTAssertEqual(text, "E42: boom")
        } else {
            XCTFail("turn/end error must render an error row")
        }
        XCTAssertFalse(flow.isRunning)
    }
}
