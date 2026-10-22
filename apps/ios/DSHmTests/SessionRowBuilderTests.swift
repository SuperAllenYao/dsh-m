import XCTest
@testable import DSHm

final class SessionRowBuilderTests: XCTestCase {

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

    func testTurnGroupingAndToolPairing() {
        let sections = SessionRowBuilder.build(events: sampleEvents())
        XCTAssertEqual(sections.count, 1)
        let section = sections[0]
        XCTAssertEqual(section.turn, 1)
        XCTAssertEqual(section.status, .completed)
        XCTAssertEqual(section.summary, "跑一下测试")

        // user + reasoning + text + one tool row (assistant tool-call block is
        // deduped by callId because a tool/call event exists)
        var userCount = 0
        var reasoningCount = 0
        var textCount = 0
        var toolCalls: [ToolCallItem] = []
        for row in section.rows {
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

        let found = SessionRowBuilder.findToolCall(in: sections, callId: "call_1")
        XCTAssertEqual(found?.arguments["description"]?.stringValue, "run tests")
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
        let sections = SessionRowBuilder.build(events: events)
        let rows = sections.first?.rows ?? []
        var relayCount = 0
        var noticeCount = 0
        for row in rows {
            switch row.content {
            case .relay: relayCount += 1
            case .notice: noticeCount += 1
            default: break
            }
        }
        XCTAssertEqual(relayCount, 1)
        XCTAssertEqual(noticeCount, 1, "subagent-settled -> notice card")
        XCTAssertEqual(rows.count, 2, "runtime-context must be hidden")
    }

    func testApprovalAskedDecidedPairing() {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(3)])),
            TestJSON.event("approval/asked", seq: 2, data: TestJSON.value("""
            {"id":"evt-1","toolName":"bash","callId":"call_9","reason":"escalate sandbox"}
            """)),
            TestJSON.event("approval/decided", seq: 3, data: TestJSON.value(#"{"id":"evt-1","outcome":"allowed-once"}"#)),
        ]
        let sections = SessionRowBuilder.build(events: events)
        let approvals = sections.first?.rows.compactMap { row -> ApprovalItem? in
            if case .approval(let item) = row.content { return item }
            return nil
        } ?? []
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals.first?.toolName, "bash")
        XCTAssertEqual(approvals.first?.outcome, "allowed-once")
    }

    func testTurnEndAbortedStatus() {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("turn/end", seq: 2, data: .object(["turn": .int(1), "reason": TestJSON.reason("aborted")])),
        ]
        let sections = SessionRowBuilder.build(events: events)
        XCTAssertEqual(sections.first?.status, .aborted)
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
        let sections = SessionRowBuilder.build(events: events)
        let changes = try! XCTUnwrap(sections.first?.fileChanges)
        XCTAssertEqual(changes.files, ["a.ts"])
        XCTAssertGreaterThan(changes.additions, 0)
    }

    func testWorkspaceChangesSeqIsCapturedForExactFetch() {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(2)])),
            TestJSON.event("workspace/changes", seq: 7, data: .object(["turn": .int(2)])),
            TestJSON.event("turn/end", seq: 9, data: .object(["turn": .int(2), "reason": TestJSON.reason("completed")])),
        ]
        let sections = SessionRowBuilder.build(events: events)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].fileChangeSeq, 7, "workspace/changes seq keys /api/changes.summary")
        XCTAssertTrue(sections[0].rows.isEmpty, "workspace/changes stays hidden from the flow")
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
        let sections = SessionRowBuilder.build(events: events)
        let jobRows = sections.first?.rows.compactMap { row -> JobItem? in
            if case .job(let job) = row.content { return job }
            return nil
        } ?? []
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
        let sections = SessionRowBuilder.build(events: events)
        XCTAssertEqual(sections.count, 1)
        XCTAssertTrue(sections[0].rows.isEmpty)
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

    private func userTexts(in sections: [TurnSection]) -> [String] {
        sections.flatMap { $0.rows }.compactMap { row -> String? in
            if case .user(let bubble) = row.content { return bubble.text }
            return nil
        }
    }

    private func sendingNotes(in sections: [TurnSection]) -> [String] {
        sections.flatMap { $0.rows }.compactMap { row -> String? in
            if case .systemNote(let text) = row.content { return text }
            return nil
        }
    }

    func testPendingUserEchoPaintsImmediatelyAtEndOfRunningTurn() {
        let echo = steerEcho()
        let sections = SessionRowBuilder.build(
            events: runningTurnWithoutSteerEvent(),
            pendingUserEchoes: [echo],
            nowMs: echoNowMs
        )
        XCTAssertEqual(sections.count, 1, "the pending prompt must not invent a second turn section")
        XCTAssertEqual(sections[0].status, .running)
        XCTAssertEqual(userTexts(in: sections), ["跑一遍全量测试", "插队：先别跑长命令"])
        XCTAssertEqual(sendingNotes(in: sections), ["发送中…"])
        let rows = sections[0].rows
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
        let sections = SessionRowBuilder.build(events: events, pendingUserEchoes: store.echoes, nowMs: echoNowMs)
        XCTAssertEqual(userTexts(in: sections), ["跑一遍全量测试", "插队：先别跑长命令"], "exactly one steer bubble, no duplicate")
        XCTAssertTrue(sendingNotes(in: sections).isEmpty, "sending marker disappears when the echo retires")
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
            let sections = SessionRowBuilder.build(events: events, pendingUserEchoes: store.echoes, nowMs: echoNowMs)
            XCTAssertEqual(store.count, 1)
            XCTAssertEqual(userTexts(in: sections).last, "插队：先别跑长命令", "pending bubble still painted after rebuild")
            XCTAssertEqual(sendingNotes(in: sections), ["发送中…"])
        }
    }

    func testSendFailureRemovesPendingEchoRow() {
        var store = SessionRowBuilder.PendingUserEchoStore()
        store.record(steerEcho())
        store.remove(requestId: "req-steer-1")
        XCTAssertTrue(store.isEmpty)
        let sections = SessionRowBuilder.build(
            events: runningTurnWithoutSteerEvent(),
            pendingUserEchoes: store.echoes,
            nowMs: echoNowMs
        )
        XCTAssertEqual(userTexts(in: sections), ["跑一遍全量测试"], "failed steer leaves no ghost bubble")
        XCTAssertTrue(sendingNotes(in: sections).isEmpty)
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

    func testPendingEchoOnEmptyJournalStartsRunningPlaceholderSection() {
        let sections = SessionRowBuilder.build(events: [], pendingUserEchoes: [steerEcho()], nowMs: echoNowMs)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].turn, 1)
        XCTAssertEqual(sections[0].status, .running)
        XCTAssertEqual(userTexts(in: sections), ["插队：先别跑长命令"])
        XCTAssertEqual(sendingNotes(in: sections), ["发送中…"])
    }

    func testUnknownUserMessageSourceKindRendersNoticeInsteadOfBeingDropped() {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("user/message", seq: 2, data: TestJSON.value("""
            {"content":[{"type":"text","text":"来自未知来源"}],"source":{"kind":"steer"}}
            """)),
        ]
        let sections = SessionRowBuilder.build(events: events)
        let notices = sections[0].rows.compactMap { row -> NoticeCard? in
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
        XCTAssertEqual(sendingNotes(in: fresh), ["发送中…"], "still inside the timeout")
        let stale = SessionRowBuilder.build(
            events: runningTurnWithoutSteerEvent(),
            pendingUserEchoes: [echo],
            nowMs: echoNowMs + timeout
        )
        XCTAssertTrue(sendingNotes(in: stale).isEmpty, "\"发送中…\" must never hang after the timeout")
        XCTAssertEqual(
            userTexts(in: stale).last,
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
        let sections = SessionRowBuilder.build(
            events: events,
            pendingUserEchoes: store.echoes,
            nowMs: echoNowMs + SessionRowBuilder.PendingUserEchoStore.sendingIndicatorTimeoutMs * 10
        )
        XCTAssertEqual(userTexts(in: sections), ["跑一遍全量测试", "插队：先别跑长命令"])
        XCTAssertTrue(sendingNotes(in: sections).isEmpty)
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
        var sections = SessionRowBuilder.build(events: runningTurnWithoutSteerEvent(), nowMs: echoNowMs)
        for _ in 0..<3 {
            sections = SessionRowBuilder.appendingPendingEchoes([echo], to: sections, nowMs: echoNowMs)
        }
        XCTAssertEqual(userTexts(in: sections), ["跑一遍全量测试", "插队：先别跑长命令"])
        XCTAssertEqual(sendingNotes(in: sections), ["发送中…"])
        let refreshed = SessionRowBuilder.appendingPendingEchoes(
            [echo],
            to: sections,
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
}
