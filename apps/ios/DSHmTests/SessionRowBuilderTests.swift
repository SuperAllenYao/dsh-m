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
}
