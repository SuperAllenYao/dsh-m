import XCTest
@testable import DSHm

final class SessionFlowGroupingTests: XCTestCase {

    private func reasoning(_ id: String, _ text: String = "思考内容") -> FlowRow {
        FlowRow(id: id, seq: Int(id.suffix(3)) ?? 0, content: .reasoning(text))
    }

    private func tool(_ id: String, name: String = "bash", result: ToolResultItem? = nil, callId: String? = nil) -> FlowRow {
        let item = ToolCallItem(
            callId: callId ?? id,
            name: name,
            argumentsRaw: nil,
            arguments: name == "bash" ? ["command": .string("pnpm test")] : ["file_path": .string("src/a.ts")],
            result: result,
            children: [],
            turn: 1,
            step: nil
        )
        return FlowRow(id: id, seq: Int(id.suffix(3)) ?? 0, content: .tool(item))
    }

    private func completedResult() -> ToolResultItem {
        ToolResultItem(isError: false, text: "ok", meta: nil, images: [])
    }

    func testTwentyStepTurnFoldsIntoOneProcessGroup() {
        var rows: [FlowRow] = []
        for index in 0..<20 {
            if index % 2 == 0 {
                rows.append(reasoning("r\(String(format: "%03d", index))"))
            } else {
                rows.append(tool("t\(String(format: "%03d", index))", result: completedResult()))
            }
        }
        let groups = SessionFlowGrouping.groups(rows: rows)
        XCTAssertEqual(groups.count, 1)
        guard case .process(let steps) = groups[0] else {
            return XCTFail("20-step run must fold into one process group")
        }
        XCTAssertEqual(steps.count, 20)
        // Collapsed + running current step == at most 2 rows (56pt) per v5.3.
        XCTAssertNotNil(SessionFlowGrouping.currentStep(steps))
    }

    func testSingleReasoningOrToolStaysSingleRow() {
        // A lone reasoning row or tool row must not become a "过程" group.
        let reasoningGroups = SessionFlowGrouping.groups(rows: [reasoning("r001")])
        XCTAssertEqual(reasoningGroups.count, 1)
        if case .single = reasoningGroups[0] {} else { XCTFail("single reasoning must stay a row") }

        let toolGroups = SessionFlowGrouping.groups(rows: [tool("t002", result: completedResult())])
        XCTAssertEqual(toolGroups.count, 1)
        if case .single = toolGroups[0] {} else { XCTFail("single tool call must stay a row") }
    }

    func testPlainRowsBreakTheGroup() {
        let rows: [FlowRow] = [
            reasoning("r001"),
            tool("t002", result: completedResult()),
            FlowRow(id: "m003", seq: 3, content: .text("正文")),
            reasoning("r004"),
            tool("t005", result: completedResult()),
        ]
        let groups = SessionFlowGrouping.groups(rows: rows)
        XCTAssertEqual(groups.count, 3)
        if case .process(let steps) = groups[0] { XCTAssertEqual(steps.count, 2) } else { XCTFail("first group") }
        if case .single(let row) = groups[1] { XCTAssertEqual(row.id, "m003") } else { XCTFail("middle row") }
        if case .process(let steps) = groups[2] { XCTAssertEqual(steps.count, 2) } else { XCTFail("second group") }
    }

    func testFailuresAndPendingApprovalsAreExceptions() {
        let failed = ToolResultItem(isError: true, text: "boom", meta: nil, images: [])
        let rows: [FlowRow] = [
            reasoning("r001"),
            tool("t002", result: completedResult(), callId: "call-ok"),
            tool("t003", result: failed, callId: "call-fail"),
            tool("t004", result: nil, callId: "call-pending"),
        ]
        guard case .process(let steps) = SessionFlowGrouping.groups(rows: rows)[0] else {
            return XCTFail("expected process group")
        }
        let pending: Set<String> = ["call-pending"]
        let exceptions = SessionFlowGrouping.exceptionSteps(steps, pendingApprovalCallIds: pending)
        let foldable = SessionFlowGrouping.foldableSteps(steps, pendingApprovalCallIds: pending)
        XCTAssertEqual(exceptions.count, 2, "failure + pending approval must stay visible")
        XCTAssertEqual(foldable.count, 2)
        XCTAssertEqual(foldable.first?.reasoningText, "思考内容")
    }

    func testSummaryTextCountsByVerb() {
        let rows: [FlowRow] = [
            reasoning("r001"),
            tool("t002", result: completedResult()),
            tool("t003", result: completedResult()),
            tool("t004", name: "read", result: completedResult()),
            reasoning("r005"),
            reasoning("r006"),
        ]
        guard case .process(let steps) = SessionFlowGrouping.groups(rows: rows)[0] else {
            return XCTFail("expected process group")
        }
        XCTAssertEqual(SessionFlowGrouping.summaryText(steps), "运行命令 2 · 读取 1 · 思考 3")
    }

    func testCurrentStepPrefersRunningTool() {
        let completed = tool("t002", result: completedResult())
        let running = tool("t003", result: nil)
        guard case .process(let steps) = SessionFlowGrouping.groups(rows: [completed, running])[0] else {
            return XCTFail("expected process group")
        }
        let current = SessionFlowGrouping.currentStep(steps)
        XCTAssertEqual(current?.tool?.name, "bash")
        XCTAssertEqual(current?.isRunning, true)
        XCTAssertEqual(current?.verb, "运行命令")
    }

    func testVerbMapping() {
        XCTAssertEqual(SessionFlowGrouping.verb(for: "bash"), "运行命令")
        XCTAssertEqual(SessionFlowGrouping.verb(for: "read"), "读取")
        XCTAssertEqual(SessionFlowGrouping.verb(for: "edit"), "编辑")
        XCTAssertEqual(SessionFlowGrouping.verb(for: "grep"), "搜索")
        XCTAssertEqual(SessionFlowGrouping.verb(for: "web_fetch"), "联网")
        XCTAssertEqual(SessionFlowGrouping.verb(for: "unknown_tool"), "工具")
    }

    // MARK: - v0.2.7 组 id 稳定性（过程组展开态/行高缓存依赖它）

    /// 组 id 必须由**首 step**决定：流式追加（新 step 进组尾）时组身份不变，
    /// diffable 才不会把「同一组长大」当成「删旧行 + 插新行」。
    func testProcessGroupIDUsesFirstStepSoStreamingAppendKeepsIdentity() {
        var rows: [FlowRow] = [reasoning("r001"), tool("t002", result: completedResult())]
        let initialID = SessionFlowGrouping.groups(rows: rows)[0].id
        XCTAssertEqual(initialID, "process-r001")

        // 流式再追加两步（组尾增长）：id 必须不变。
        rows.append(reasoning("r003"))
        rows.append(tool("t004", result: completedResult()))
        let afterStreaming = SessionFlowGrouping.groups(rows: rows)[0]
        guard case .process(let steps) = afterStreaming else {
            return XCTFail("expected process group")
        }
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(afterStreaming.id, initialID, "流式追加不得改变过程组 id")
    }

    /// 历史补齐把更早的 step 合并进同组时 id 会变（首 step 变了）——这是有意的取舍：
    /// 反转列表的补齐是数据尾部追加，既有内容坐标不变，锚点不依赖 id 复用。
    func testProcessGroupIDChangesOnlyWhenEarlierStepsPrepend() {
        let rows: [FlowRow] = [reasoning("r010"), reasoning("r011")]
        let newer = SessionFlowGrouping.groups(rows: rows)[0].id
        let prepended: [FlowRow] = [reasoning("r001"), tool("t002", result: completedResult())] + rows
        let afterPrepend = SessionFlowGrouping.groups(rows: prepended)
        XCTAssertEqual(afterPrepend.count, 1)
        XCTAssertEqual(afterPrepend[0].id, "process-r001")
        XCTAssertNotEqual(afterPrepend[0].id, newer)
    }

    // MARK: - v0.2.7 过程组四态（内联工作步骤）

    func testProcessGroupModeDefaultsFollowRunningState() {
        XCTAssertEqual(ProcessGroupModeResolver.resolve(isRunning: true, override: nil), .window)
        XCTAssertEqual(ProcessGroupModeResolver.resolve(isRunning: false, override: nil), .collapsed)
    }

    func testProcessGroupModeAppliesUserOverrideWithinItsPhase() {
        XCTAssertEqual(ProcessGroupModeResolver.resolve(isRunning: true, override: .full), .full)
        XCTAssertEqual(ProcessGroupModeResolver.resolve(isRunning: false, override: .expanded), .expanded)
    }

    /// 阶段切换后旧覆盖必须失效：运行中残留的 .expanded / 结束后残留的 .window 不能卡住状态。
    func testProcessGroupModeDropsStaleOverrideAcrossPhaseChange() {
        XCTAssertEqual(ProcessGroupModeResolver.resolve(isRunning: true, override: .expanded), .window)
        XCTAssertEqual(ProcessGroupModeResolver.resolve(isRunning: true, override: .collapsed), .window)
        XCTAssertEqual(ProcessGroupModeResolver.resolve(isRunning: false, override: .window), .collapsed)
        XCTAssertEqual(ProcessGroupModeResolver.resolve(isRunning: false, override: .full), .collapsed)
    }

    /// 组内步骤保留事件 seq，组 firstSeq = 首 step seq（用于判定「本轮」过程组）。
    func testGroupFirstSeqTracksFirstStepSeq() {
        let rows: [FlowRow] = [reasoning("r101"), tool("t102", result: completedResult())]
        let groups = SessionFlowGrouping.groups(rows: rows)
        guard case .process(let steps) = groups[0] else {
            return XCTFail("expected process group")
        }
        XCTAssertEqual(steps.map(\.seq), [101, 102])
        XCTAssertEqual(groups[0].firstSeq, 101)
    }

    func testProcessGroupModeToggleIsSameControlBothPhases() {
        XCTAssertEqual(ProcessGroupModeResolver.toggled(.window), .full)
        XCTAssertEqual(ProcessGroupModeResolver.toggled(.full), .window)
        XCTAssertEqual(ProcessGroupModeResolver.toggled(.collapsed), .expanded)
        XCTAssertEqual(ProcessGroupModeResolver.toggled(.expanded), .collapsed)
    }
}
