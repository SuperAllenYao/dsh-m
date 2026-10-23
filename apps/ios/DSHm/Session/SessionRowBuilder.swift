import Foundation

/// Builds the conversation flow (one flat stream of rows) from a session event log.
///
/// Data-driven per ui-baseline: every row maps to an event / field; internal
/// events listed in the baseline hidden list are skipped here.
///
/// 2026-10-23 用户拍板：App 端删除 turn UI，与 DSH 桌面端一致——会话就是一条
/// 平铺的消息流。`turn/start`/`turn/end` 只用于推导运行状态与「最近一轮」的文件
/// 变更，不再产生任何区块。
enum SessionRowBuilder {

    // MARK: - Hidden event types (ui-baseline §3 hidden list)

    static let hiddenEventTypes: Set<String> = [
        "developer/message",
        "request/header",
        "request/context",
        "session/title-llm-request",
        "web/deepseek-search-llm-request",
        "session-log-deepseek/delivery-accepted",
        "tool-workflow/run-start",
        "tool-workflow/run-end",
        "tool-workflow/agent-start",
        "tool-workflow/agent-end",
        "compaction/prune",
        "compaction/start",
        "compaction/summary",
        "compaction/end",
        "llm/retry",
        "llm/retry-started",
        "assistant/attempt",
        "model/selection",
        "working-directory/change",
        "session/end-seed",
        "agent-preset/selected",
        "step/start",
        "step/end",
        "session/title",
        "workspace/changes",
        "agent/inbox/spliced",
        "system/message",
        "approval/policy",
        "sandbox/mode",
        "permission/preset",
    ]

    // MARK: - Optimistic user echo (send now, durable event arrives later)

    /// One locally echoed user prompt whose durable `user/message` has not arrived yet.
    ///
    /// Why this exists: `session/prompt` with `mode:"steer"` only inserts the
    /// message into the host agent's inbox (`agent/inbox/spliced`); the durable
    /// `user/message` is appended when the running turn claims that inbox at its
    /// **next step** (dsh-agent-loop `step()`), which can lag the RPC by a whole
    /// tool call. The phone used to paint nothing until then, so "插队发送"
    /// looked like the message was swallowed.
    ///
    /// `requestId` is the prompt RPC id: the host records it on the durable
    /// message as `data.source.rpcId` (with `kind:"user"`), so
    /// `PendingUserEchoStore.reconcile(events:)` can retire the echo exactly when
    /// the real row shows up.
    struct PendingUserEcho: Identifiable, Equatable {
        var requestId: String
        var text: String
        var images: [ImageRef]
        /// Milliseconds since epoch, aligned with `SessionEvent.time`.
        var sentAt: Int64?
        /// Delivery mode the prompt used: "queue" (followup) or "steer".
        var mode: String

        var id: String { requestId }

        init(
            requestId: String,
            text: String,
            images: [ImageRef] = [],
            sentAt: Int64? = nil,
            mode: String = "queue"
        ) {
            self.requestId = requestId
            self.text = text
            self.images = images
            self.sentAt = sentAt
            self.mode = mode
        }
    }

    /// Insertion-ordered set of optimistic echoes, keyed by prompt `requestId`.
    ///
    /// Owned by `SessionViewModel` next to the journal; `build(events:pendingUserEchoes:)`
    /// paints it and `reconcile(events:)` retires entries as the durable events
    /// land. Keeping it outside the journal means a rebuild / pagination
    /// recompute never drops the user's own message.
    struct PendingUserEchoStore: Equatable {
        /// How long the optimistic row may claim "发送中…". A steer prompt can
        /// legitimately wait minutes for the running turn's next step, so the
        /// bubble itself is kept until the durable event retires it; only the
        /// progress marker expires (no permanent "发送中…").
        static let sendingIndicatorTimeoutMs: Int64 = 120_000

        private(set) var echoes: [PendingUserEcho] = []

        var isEmpty: Bool { echoes.isEmpty }
        var count: Int { echoes.count }

        /// Earliest still-in-the-future moment some echo's "发送中…" marker stops
        /// being truthful (nil when every indicator already expired — the VM's
        /// stale-repaint task must not reschedule itself in a busy loop).
        func nextSendingIndicatorDeadline(nowMs: Int64) -> Int64? {
            echoes.compactMap { echo -> Int64? in
                guard let sentAt = echo.sentAt else { return nil }
                let deadline = sentAt + Self.sendingIndicatorTimeoutMs
                return deadline > nowMs ? deadline : nil
            }.min()
        }

        /// Whether the echo still deserves the "发送中…" marker at `nowMs`.
        static func showsSendingIndicator(sentAt: Int64?, nowMs: Int64) -> Bool {
            guard let sentAt else { return true }
            return nowMs - sentAt < sendingIndicatorTimeoutMs
        }

        init(echoes: [PendingUserEcho] = []) {
            self.echoes = echoes
        }

        /// Insert (or replace) the echo for its `requestId`; retries never duplicate rows.
        mutating func record(_ echo: PendingUserEcho) {
            if let index = echoes.firstIndex(where: { $0.requestId == echo.requestId }) {
                echoes[index] = echo
            } else {
                echoes.append(echo)
            }
        }

        /// Drop one echo: the send failed / the host rejected it (caller surfaces the error).
        mutating func remove(requestId: String) {
            echoes.removeAll { $0.requestId == requestId }
        }

        mutating func removeAll() {
            echoes.removeAll()
        }

        /// Retire every echo whose durable `user/message` (`data.source.rpcId`)
        /// reached the journal. Unmatched echoes are kept: a rebuild must never
        /// make the user's own message disappear.
        mutating func reconcile(events: [SessionEvent]) {
            guard !echoes.isEmpty else { return }
            var durable: Set<String> = []
            for event in events where event.type == "user/message" {
                if let rpcId = SessionRowBuilder.userMessageRpcId(of: event) {
                    durable.insert(rpcId)
                }
            }
            guard !durable.isEmpty else { return }
            echoes.removeAll { durable.contains($0.requestId) }
        }
    }

    /// `data.source.rpcId` of a durable user message (the prompt RPC id recorded
    /// by the host); nil for messages that were not sent through `session/prompt`.
    static func userMessageRpcId(of event: SessionEvent) -> String? {
        guard event.type == "user/message" else { return nil }
        return event.data?["source"]?["rpcId"]?.stringValue
    }

    // MARK: - Build (full rebuild entry point)

    /// Flattens the event log into one continuous row stream.
    ///
    /// Turn boundaries only feed two derived values:
    /// - isRunning: the newest turn of the loaded window started but has not ended
    ///   (a window that starts mid-turn has no turn/start, so turn-scoped rows
    ///   after the last turn/end keep the indicator truthful — and an ended
    ///   session can never claim 运行中 any more);
    /// - latestFileChangeSeq / latestFileChanges: the newest turn's file changes.
    ///
    /// 全量重建入口（冷恢复 / journal snapshot 替换 / 测试 oracle）。live 尾部与
    /// history 前置走 FlowState 的增量接口；两者共用同一折叠核心，因此增量结果
    /// 与全量重建结果逐行等价（见 RowBuilderBenchTests）。
    static func build(
        events: [SessionEvent],
        pendingUserEchoes: [PendingUserEcho] = [],
        nowMs: Int64 = currentEpochMs()
    ) -> SessionFlow {
        var state = FlowState()
        state.replaceAll(events: events, pendingUserEchoes: pendingUserEchoes, nowMs: nowMs, computeGroups: false)
        return state.flow
    }

    static func currentEpochMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Incremental flow state

    /// 增量渲染状态：视图模型持有一个实例，避免每批事件都全量重建。
    ///
    /// - reset：全量替换（冷恢复 / journal snapshot 替换 / 重连 gap）；
    /// - append：live 尾部——只折叠 seq 大于已加载最大 seq 的事件；
    /// - prepend：更早一页（可一次多页）——只折叠 seq 小于已加载最小 seq 的事件，
    ///   行直接前置；跨页边界相邻的 reasoning/tool 行由分组缓存重新合并；
    /// - repaintPendingEchoes：只重画尾部乐观回显行，不重扫事件日志。
    ///
    /// flow / groups 是发布给视图的快照：flow.rows 含尾部乐观回显行，
    /// groups 是同一批行的渲染分组缓存（视图 body 直接读，不再每次 O(N) 重算）。
    struct FlowState {
        private(set) var flow = SessionFlow()
        private(set) var groups: [FlowRowGroup] = []

        /// 已折叠的行：前 baseRowCount 行来自事件，其后是乐观回显行（重画时整段替换）。
        private var rows: [FlowRow] = []
        private var baseRowCount = 0
        private var fold = FoldState()
        private var groupCache = FlowGroupCache()

        init() {}

        /// 全量替换（冷恢复 / journal snapshot 替换 / generation 重置）。
        mutating func reset(
            events: [SessionEvent],
            pendingUserEchoes: [PendingUserEcho] = [],
            nowMs: Int64 = SessionRowBuilder.currentEpochMs()
        ) {
            replaceAll(events: events, pendingUserEchoes: pendingUserEchoes, nowMs: nowMs, computeGroups: true)
        }

        /// 追加 live 尾部事件；已加载过的 seq 会被丢弃（幂等）。
        mutating func append(
            events: [SessionEvent],
            pendingUserEchoes: [PendingUserEcho] = [],
            nowMs: Int64 = SessionRowBuilder.currentEpochMs()
        ) {
            let batch = orderedAppendBatch(events)
            stripPendingEchoRows()
            var change: FlowGroupCache.Change = .tail
            if !batch.isEmpty {
                let removedDeferredRows = SessionRowBuilder.foldBatch(batch, mode: .append, state: &fold, rows: &rows)
                let resolvedOrphanRows = SessionRowBuilder.resolveOrphanResults(state: &fold, rows: &rows)
                if removedDeferredRows || resolvedOrphanRows || SessionRowBuilder.touchesExistingRows(batch) {
                    change = .full
                }
            }
            baseRowCount = rows.count
            applyPendingEchoes(pendingUserEchoes, nowMs: nowMs)
            publish(computeGroups: true, change: change)
        }

        /// 前置更早的一页/一批事件；已加载过的 seq 会被丢弃（幂等）。
        mutating func prepend(
            events: [SessionEvent],
            pendingUserEchoes: [PendingUserEcho] = [],
            nowMs: Int64 = SessionRowBuilder.currentEpochMs()
        ) {
            let batch = orderedPrependBatch(events)
            stripPendingEchoRows()
            if !batch.isEmpty {
                var segment: [FlowRow] = []
                _ = SessionRowBuilder.foldBatch(batch, mode: .prepend, state: &fold, rows: &segment)
                rows.insert(contentsOf: segment, at: 0)
                SessionRowBuilder.resolveOrphanResults(state: &fold, rows: &rows)
            }
            baseRowCount = rows.count
            applyPendingEchoes(pendingUserEchoes, nowMs: nowMs)
            publish(computeGroups: true, change: .full)
        }

        /// 只重画乐观回显行（发送 / 失败 / 超时），不重扫事件日志。
        mutating func repaintPendingEchoes(
            _ echoes: [PendingUserEcho],
            nowMs: Int64 = SessionRowBuilder.currentEpochMs()
        ) {
            stripPendingEchoRows()
            baseRowCount = rows.count
            applyPendingEchoes(echoes, nowMs: nowMs)
            publish(computeGroups: true, change: .tail)
        }

        /// 已折叠事件的 seq 范围（nil 表示还没有事件）。filler 的 cursor 仍由 VM 维护，
        /// 这里只读兜底。
        var loadedSeqRange: ClosedRange<Int>? {
            guard let min = fold.loadedMinSeq, let max = fold.loadedMaxSeq else { return nil }
            return min...max
        }

        // MARK: internals

        fileprivate mutating func replaceAll(
            events: [SessionEvent],
            pendingUserEchoes: [PendingUserEcho],
            nowMs: Int64,
            computeGroups: Bool
        ) {
            let sorted = events.sorted { $0.seq < $1.seq }
            rows = []
            baseRowCount = 0
            fold = FoldState()
            if !sorted.isEmpty {
                _ = SessionRowBuilder.foldBatch(sorted, mode: .replace, state: &fold, rows: &rows)
                SessionRowBuilder.resolveOrphanResults(state: &fold, rows: &rows)
            }
            baseRowCount = rows.count
            applyPendingEchoes(pendingUserEchoes, nowMs: nowMs)
            publish(computeGroups: computeGroups, change: .full)
        }

        private mutating func stripPendingEchoRows() {
            if rows.count > baseRowCount {
                rows.removeSubrange(baseRowCount...)
            }
        }

        private mutating func applyPendingEchoes(_ echoes: [PendingUserEcho], nowMs: Int64) {
            guard !echoes.isEmpty else { return }
            var echoRows: [FlowRow] = []
            SessionRowBuilder.appendPendingUserEchoes(echoes, to: &echoRows, nowMs: nowMs, startingAfter: fold.maxRowSeq)
            rows.append(contentsOf: echoRows)
        }

        private mutating func publish(computeGroups: Bool, change: FlowGroupCache.Change) {
            let derived = SessionRowBuilder.replay(fold)
            let aggregateStart = fold.newestTurnStarted ? min(fold.newestTurnRowStart, rows.count) : 0
            flow = SessionFlow(
                rows: rows,
                isRunning: derived.isRunning,
                latestFileChangeSeq: derived.latestFileChangeSeq,
                latestFileChanges: SessionRowBuilder.aggregateFileChanges(rows: rows, from: aggregateStart)
            )
            guard computeGroups else { return }
            switch change {
            case .tail:
                groupCache.refreshTail(rows: rows)
            case .full:
                groupCache.rebuild(rows: rows)
            }
            groups = groupCache.groups
        }

        private func orderedAppendBatch(_ events: [SessionEvent]) -> [SessionEvent] {
            guard !events.isEmpty else { return [] }
            let lowerBound = fold.loadedMaxSeq.map { $0 &+ 1 } ?? Int.min
            let sorted = events.count > 1 ? events.sorted { $0.seq < $1.seq } : events
            var result: [SessionEvent] = []
            result.reserveCapacity(sorted.count)
            var lastSeq = Int.min
            for event in sorted where event.seq >= lowerBound && event.seq > lastSeq {
                result.append(event)
                lastSeq = event.seq
            }
            return result
        }

        private func orderedPrependBatch(_ events: [SessionEvent]) -> [SessionEvent] {
            guard !events.isEmpty else { return [] }
            let upperBound = fold.loadedMinSeq.map { $0 &- 1 } ?? Int.max
            let sorted = events.count > 1 ? events.sorted { $0.seq < $1.seq } : events
            var result: [SessionEvent] = []
            result.reserveCapacity(sorted.count)
            var lastSeq = Int.min
            for event in sorted where event.seq <= upperBound && event.seq > lastSeq {
                result.append(event)
                lastSeq = event.seq
            }
            return result
        }
    }

    // MARK: - Fold core (shared by build and FlowState)

    private struct FoldState {
        /// 有独立 tool/call 或 ptc-dispatch-start 事件的 callId：assistant/message
        /// 里同 id 的 tool-call block 不再重复成行。
        var callIdsWithEvents: Set<String> = []
        /// 已渲染但尚未等到 tool/call 的 assistant tool-call block 行（callId -> rowID）。
        /// 后续批次出现同 callId 时删除该行，保持与全量重建等价。
        var deferredBlockRowIDs: [String: String] = [:]
        /// 只保留 turn 状态的紧凑轨迹：全量重建与增量折叠共用同一 isRunning /
        /// latestFileChangeSeq 推导，O(事件数) 但常数极小（16B/条）。
        var turnTrace: [TurnTraceEntry] = []
        var newestTurnStarted = false
        var newestTurnRowStart = 0
        var maxRowSeq = 0
        var loadedMinSeq: Int?
        var loadedMaxSeq: Int?
        /// 已渲染但还没等到调用行的孤儿 tool/result 行。更早的一页 prepend 后可能
        /// 补上调用行：那时把结果挂载到调用行并删掉孤儿行，才能与全量重建
        /// （按 seq 顺序处理，结果总能找到更早的调用行）逐行等价。
        var orphanResultRows: [OrphanResultRow] = []
    }

    private struct OrphanResultRow {
        var rowID: String
        var callId: String
        var result: ToolResultItem
    }

    private enum FoldMode {
        case replace
        case append
        case prepend
    }

    private struct TurnTraceEntry {
        enum Kind: UInt8 {
            case turnStart
            case turnEnd
            case workspace
            case row
        }

        var seq: Int
        var kind: Kind
        var turn: Int
    }

    /// - Returns: 是否删除了已渲染的行（跨批次补上的 tool/call 让之前的 block 行退场）。
    ///   调用方据此决定分组缓存能否只重算尾部（删中间行必须全量重算）。
    private static func foldBatch(
        _ batch: [SessionEvent],
        mode: FoldMode,
        state: inout FoldState,
        rows: inout [FlowRow]
    ) -> Bool {
        var removedExistingRows = false
        var batchCallIds = Set<String>()
        for event in batch {
            if event.type == "tool/call", let id = event.data?["callId"]?.stringValue {
                batchCallIds.insert(id)
            } else if event.type == "tool/ptc-dispatch-start", let id = event.data?["subCallId"]?.stringValue {
                batchCallIds.insert(id)
            }
        }
        switch mode {
        case .replace:
            state.callIdsWithEvents = batchCallIds
            state.deferredBlockRowIDs = [:]
            state.orphanResultRows = []
        case .append, .prepend:
            let unresolved = batchCallIds.subtracting(state.callIdsWithEvents)
            state.callIdsWithEvents.formUnion(batchCallIds)
            if !unresolved.isEmpty,
               removeDeferredBlocks(for: unresolved, state: &state, rows: &rows) {
                removedExistingRows = true
            }
        }

        var traceEntries: [TurnTraceEntry] = []
        traceEntries.reserveCapacity(batch.count)
        var batchTurnStartRow: Int?
        var batchMaxRowSeq = 0

        func appendRow(_ content: FlowContent, event: SessionEvent, suffix: String) {
            rows.append(FlowRow(id: "\(event.seq)-\(suffix)", seq: event.seq, content: content))
            if event.seq > batchMaxRowSeq { batchMaxRowSeq = event.seq }
        }

        for event in batch {
            // workspace/changes 只带 turn 字段，其 seq 是精确取数 summary/diff 的 key。
            // 只保留最新一轮的那条：新的 turn/start 让上一条让位（见 replay）。
            if event.type == "workspace/changes" {
                traceEntries.append(TurnTraceEntry(seq: event.seq, kind: .workspace, turn: 0))
                continue
            }
            guard !hiddenEventTypes.contains(event.type) else { continue }
            let data = event.data
            switch event.type {
            case "turn/start":
                traceEntries.append(TurnTraceEntry(seq: event.seq, kind: .turnStart, turn: 0))
                batchTurnStartRow = rows.count
            case "turn/end":
                traceEntries.append(TurnTraceEntry(
                    seq: event.seq,
                    kind: .turnEnd,
                    turn: data?["turn"]?.int ?? 0
                ))
                if data?["reason"]?["kind"]?.stringValue == "error",
                   let error = data?["reason"]?["error"] {
                    let message = error["message"]?.stringValue ?? "未知错误"
                    let code = error["code"]?.stringValue
                    appendRow(.error(code.map { "\($0): \(message)" } ?? message), event: event, suffix: "turn-end-error")
                }
            default:
                // 窗口可能从一轮中间开始（其 turn/start 在窗口外）：最后一条
                // turn/end 之后又出现带 turn 的行事件，等价于新一轮已开始。
                if let turn = data?["turn"]?.int {
                    traceEntries.append(TurnTraceEntry(seq: event.seq, kind: .row, turn: turn))
                }
                switch event.type {
                case "user/message":
                    handleUserMessage(event: event, data: data, appendRow: appendRow)
                case "assistant/message":
                    let deferred = handleAssistantMessage(
                        event: event,
                        data: data,
                        callIdsWithEvents: state.callIdsWithEvents,
                        appendRow: appendRow
                    )
                    for block in deferred {
                        state.deferredBlockRowIDs[block.callId] = block.rowID
                    }
                case "tool/call":
                    let item = toolCall(from: data, event: event)
                    appendRow(.tool(item), event: event, suffix: "tool-\(item.callId ?? "seq-\(event.seq)")")
                case "tool/result":
                    // Orphan results are appended here (not inside the handler) so the
                    // handler's inout rows access never overlaps the closure's
                    // mutation of the same array (Swift exclusivity abort).
                    if let orphan = handleToolResult(event: event, data: data, rows: &rows) {
                        appendRow(orphan.content, event: event, suffix: orphan.suffix)
                        if case .tool(let item) = orphan.content,
                           let callId = item.callId,
                           let result = item.result {
                            state.orphanResultRows.append(OrphanResultRow(
                                rowID: "\(event.seq)-\(orphan.suffix)",
                                callId: callId,
                                result: result
                            ))
                        }
                    }
                case "tool/ptc-dispatch-start":
                    handlePTCDispatchStart(event: event, data: data, rows: &rows)
                case "tool/ptc-dispatch":
                    handlePTCDispatch(event: event, data: data, rows: &rows)
                case "approval/asked":
                    let id = data?["id"]?.stringValue ?? "approval-\(event.seq)"
                    appendRow(.approval(ApprovalItem(
                        id: id,
                        toolName: data?["toolName"]?.stringValue,
                        reason: data?["reason"]?.stringValue,
                        outcome: nil
                    )), event: event, suffix: "approval")
                case "approval/decided":
                    updateApprovalRow(id: data?["id"]?.stringValue, outcome: data?["outcome"]?.stringValue, rows: &rows)
                case "todo/write":
                    let todos = (data?["todos"]?.arrayValue ?? []).compactMap { item -> TodoItem? in
                        guard let content = item["content"]?.stringValue else { return nil }
                        return TodoItem(content: content, status: item["status"]?.stringValue ?? "pending")
                    }
                    if !todos.isEmpty {
                        appendRow(.plan(todos: todos, status: nil), event: event, suffix: "todos")
                    }
                case "goal/change":
                    if let goal = data?["goal"] {
                        appendRow(.goal(objective: goal["objective"]?.stringValue ?? "", phase: goal["phase"]?.stringValue), event: event, suffix: "goal")
                    }
                case "deliverables/presented":
                    let files = (data?["files"]?.arrayValue ?? []).compactMap { item -> PresentedFile? in
                        guard let path = item["path"]?.stringValue else { return nil }
                        return PresentedFile(path: path, description: item["description"]?.stringValue)
                    }
                    if !files.isEmpty {
                        appendRow(.deliverable(files: files), event: event, suffix: "deliverables")
                    }
                case "job/registered":
                    // v5.3 "one row per step": tool-backed jobs are telemetry for a
                    // tool row that is already rendered (and whose result lives in
                    // the 05 detail sheet) — do not duplicate them in the main flow.
                    if data?["toolCall"] != nil { continue }
                    let job = JobItem(
                        jobId: data?["jobId"]?.stringValue ?? "job-\(event.seq)",
                        kind: data?["kind"]?.stringValue ?? "job",
                        label: data?["label"]?.stringValue ?? "后台任务",
                        status: "running",
                        startedAt: data?["startedAt"]?.intValue,
                        finishedAt: nil
                    )
                    appendRow(.job(job), event: event, suffix: "job-start")
                case "job/settled":
                    if data?["toolCall"] != nil { continue }
                    updateJobRow(data: data, rows: &rows)
                case "command/run":
                    appendRow(.command(data?["name"]?.stringValue ?? "命令"), event: event, suffix: "command")
                case "command/done":
                    if let text = data?["text"]?.stringValue, !text.isEmpty {
                        appendRow(.notice(NoticeCard(title: "命令结果", text: text, kind: "command-done")), event: event, suffix: "command-done")
                    }
                default:
                    continue
                }
            }
        }

        let insertedCount: Int
        switch mode {
        case .prepend:
            insertedCount = rows.count
        default:
            insertedCount = 0
        }
        switch mode {
        case .replace:
            state.turnTrace = traceEntries
            state.newestTurnStarted = batchTurnStartRow != nil
            state.newestTurnRowStart = batchTurnStartRow ?? 0
            state.maxRowSeq = batchMaxRowSeq
            state.loadedMinSeq = batch.first?.seq
            state.loadedMaxSeq = batch.last?.seq
            return removedExistingRows
        case .append:
            state.turnTrace.append(contentsOf: traceEntries)
            if let rowStart = batchTurnStartRow {
                state.newestTurnStarted = true
                state.newestTurnRowStart = rowStart
            }
            if batchMaxRowSeq > state.maxRowSeq { state.maxRowSeq = batchMaxRowSeq }
            if let last = batch.last?.seq {
                state.loadedMaxSeq = max(state.loadedMaxSeq ?? Int.min, last)
            }
        case .prepend:
            state.turnTrace.insert(contentsOf: traceEntries, at: 0)
            if let rowStart = batchTurnStartRow {
                if state.newestTurnStarted {
                    state.newestTurnRowStart += insertedCount
                } else {
                    state.newestTurnStarted = true
                    state.newestTurnRowStart = rowStart
                }
            } else {
                state.newestTurnRowStart += insertedCount
            }
            if batchMaxRowSeq > state.maxRowSeq { state.maxRowSeq = batchMaxRowSeq }
            if let first = batch.first?.seq {
                state.loadedMinSeq = min(state.loadedMinSeq ?? Int.max, first)
            }
        }
        return removedExistingRows
    }

    @discardableResult
    private static func removeDeferredBlocks(
        for callIds: Set<String>,
        state: inout FoldState,
        rows: inout [FlowRow]
    ) -> Bool {
        var removable = Set<String>()
        for callId in callIds {
            if let rowID = state.deferredBlockRowIDs.removeValue(forKey: callId) {
                removable.insert(rowID)
            }
        }
        guard !removable.isEmpty else { return false }
        rows.removeAll { removable.contains($0.id) }
        return true
    }

    /// prepend 更早的一页之后：把新补上的调用行与之前的孤儿 tool/result 行合并
    /// （结果挂到调用行上、删除孤儿行），行序与全量重建保持一致。
    @discardableResult
    private static func resolveOrphanResults(state: inout FoldState, rows: inout [FlowRow]) -> Bool {
        guard !state.orphanResultRows.isEmpty else { return false }
        var remaining: [OrphanResultRow] = []
        var removable = Set<String>()
        for orphan in state.orphanResultRows {
            guard let index = rows.firstIndex(where: { $0.id == orphan.rowID }) else { continue }
            if attachToolResult(callId: orphan.callId, result: orphan.result, rows: &rows, before: index) {
                removable.insert(orphan.rowID)
            } else {
                remaining.append(orphan)
            }
        }
        guard !removable.isEmpty else {
            state.orphanResultRows = remaining
            return false
        }
        rows.removeAll { removable.contains($0.id) }
        state.orphanResultRows = remaining
        return true
    }

    /// 这批事件里有会「原地修改已有行」的类型：工具结果挂载 / 审批结论 / 后台任务结算。
    /// 分组缓存遇到这种批次要走全量重算（行的分组结构不变，但组内内容变了）。
    private static func touchesExistingRows(_ batch: [SessionEvent]) -> Bool {
        for event in batch {
            switch event.type {
            case "tool/result", "approval/decided", "job/settled", "tool/ptc-dispatch", "tool/ptc-dispatch-start":
                return true
            default:
                continue
            }
        }
        return false
    }

    /// 由紧凑 turn 轨迹重放派生值（与全量折叠同一套规则）。
    private static func replay(_ state: FoldState) -> (isRunning: Bool, latestFileChangeSeq: Int?) {
        var isRunning = false
        var lastEndedTurn = 0
        var lastTurnStartSeq = Int.min
        var lastWorkspaceSeq: Int?
        for entry in state.turnTrace {
            switch entry.kind {
            case .turnStart:
                isRunning = true
                lastTurnStartSeq = entry.seq
            case .turnEnd:
                isRunning = false
                if entry.turn > lastEndedTurn { lastEndedTurn = entry.turn }
            case .workspace:
                lastWorkspaceSeq = entry.seq
            case .row:
                if !isRunning, entry.turn > lastEndedTurn { isRunning = true }
            }
        }
        let latestFileChangeSeq = lastWorkspaceSeq.flatMap { $0 > lastTurnStartSeq ? $0 : nil }
        return (isRunning, latestFileChangeSeq)
    }

    /// Repaint only the optimistic tail rows (idempotent): the view model calls
    /// this right after `session/prompt` is accepted so the bubble shows in the
    /// same frame, *without* re-running the full journal rebuild (turn status /
    /// queue-flush side effects) before `turn/start` lands.
    static func appendingPendingEchoes(
        _ echoes: [PendingUserEcho],
        to rows: [FlowRow],
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> [FlowRow] {
        var result = rows.filter { !$0.id.hasPrefix("pending-") }
        appendPendingUserEchoes(echoes, to: &result, nowMs: nowMs)
        return result
    }

    /// Append the optimistic echo rows at the end of the flat flow: the user bubble
    /// itself plus a subtle "发送中…" system note. Two rows per echo with ids
    /// derived from `requestId`; the next rebuild replaces the whole pair when
    /// `reconcile(events:)` retires the echo (no duplicate bubble).
    private static func appendPendingUserEchoes(
        _ echoes: [PendingUserEcho],
        to rows: inout [FlowRow],
        nowMs: Int64,
        startingAfter seqBase: Int? = nil
    ) {
        guard !echoes.isEmpty else { return }
        var seq = seqBase ?? (rows.map(\.seq).max() ?? 0)
        for echo in echoes {
            seq += 1
            rows.append(FlowRow(
                id: "pending-\(echo.requestId)-user",
                seq: seq,
                content: .user(UserBubble(
                    text: echo.text,
                    images: echo.images,
                    time: echo.sentAt,
                    messageId: nil
                ))
            ))
            // The bubble stays until the durable event retires the echo; only
            // the progress marker expires so "发送中…" can never hang forever.
            guard PendingUserEchoStore.showsSendingIndicator(sentAt: echo.sentAt, nowMs: nowMs) else { continue }
            seq += 1
            rows.append(FlowRow(
                id: "pending-\(echo.requestId)-status",
                seq: seq,
                content: .systemNote("发送中…")
            ))
        }
    }

    // MARK: - Parsing helpers

    static func toolCall(from data: JSONValue?, event: SessionEvent) -> ToolCallItem {
        // 参数 JSON 解析推迟到真正要显示时（ToolCallItem.arguments 懒解析 + 缓存）：
        // 构建/滚动不再为「不可见的工具行」解码 arguments 字符串。
        let argumentsValue = data?["arguments"]
        let argumentsRaw = argumentsValue?.stringValue
        return ToolCallItem(
            callId: data?["callId"]?.stringValue,
            name: data?["name"]?.stringValue ?? "tool",
            argumentsRaw: argumentsRaw,
            arguments: argumentsValue?.objectValue ?? [:],
            result: nil,
            children: [],
            turn: data?["turn"]?.int ?? 0,
            step: data?["step"]?.int
        )
    }

    static func aggregateFileChanges(rows: [FlowRow]) -> FileChangeSummary? {
        aggregateFileChanges(rows: rows, from: 0)
    }

    /// 只聚合 rows[from...]（最新一轮）——「窗口从一轮中间开始」时退化为整窗。
    /// 增量回路每批只需要重算最新一轮的尾部窗口，避免全量重扫。
    static func aggregateFileChanges(rows: [FlowRow], from startIndex: Int) -> FileChangeSummary? {
        var files = Set<String>()
        var additions = 0
        var deletions = 0
        func walk(_ item: ToolCallItem) {
            if let meta = item.result?.meta, let diffs = meta["diffs"]?.arrayValue {
                for diff in diffs {
                    guard let path = diff["path"]?.stringValue else { continue }
                    files.insert(path)
                    let oldLines = lineCount(diff["oldText"]?.stringValue)
                    let newLines = lineCount(diff["newText"]?.stringValue)
                    if newLines > oldLines { additions += newLines - oldLines }
                    if oldLines > newLines { deletions += oldLines - newLines }
                }
            }
            if let meta = item.result?.meta, let path = meta["path"]?.stringValue, meta["diffs"] == nil {
                // read/write without diffs: only count actual write/edit operations
                if item.name == "write" || item.name == "edit" {
                    files.insert(path)
                }
            }
            for child in item.children { walk(child) }
        }
        var index = min(max(startIndex, 0), rows.count)
        while index < rows.count {
            if case .tool(let item) = rows[index].content { walk(item) }
            index += 1
        }
        guard !files.isEmpty else { return nil }
        return FileChangeSummary(files: files.sorted(), additions: additions, deletions: deletions)
    }

    /// 等价于 components(separatedBy: "\n").count，但不分配切分数组。
    private static func lineCount(_ text: String?) -> Int {
        guard let text else { return 0 }
        guard !text.isEmpty else { return 1 }
        var count = 1
        for byte in text.utf8 where byte == 0x0A { count += 1 }
        return count
    }

    static func findToolCall(in rows: [FlowRow], callId: String?) -> ToolCallItem? {
        guard let callId else { return nil }
        func search(_ item: ToolCallItem) -> ToolCallItem? {
            if item.callId == callId { return item }
            for child in item.children {
                if let hit = search(child) { return hit }
            }
            return nil
        }
        for row in rows {
            if case .tool(let item) = row.content, let hit = search(item) {
                return hit
            }
        }
        return nil
    }

    // MARK: - Row update handlers (implemented in SessionRowBuilder+Handlers.swift)
}
