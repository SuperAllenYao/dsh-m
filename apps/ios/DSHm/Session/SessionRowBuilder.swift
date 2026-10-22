import Foundation

/// Builds the conversation flow (turn -> rows) from a session event log.
///
/// Data-driven per: every row maps to an event / field; internal
/// events listed in the baseline hidden list are skipped here.
enum SessionRowBuilder {

 // MARK: - Hidden event types (§3 hidden list)

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

 // MARK: - Build

    static func build(
        events: [SessionEvent],
        pendingUserEchoes: [PendingUserEcho] = [],
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> [TurnSection] {
        let sorted = events.sorted { $0.seq < $1.seq }
        var callIdsWithEvents = Set<String>()
        for event in sorted {
            if event.type == "tool/call", let id = event.data?["callId"]?.stringValue {
                callIdsWithEvents.insert(id)
            }
            if event.type == "tool/ptc-dispatch-start", let id = event.data?["subCallId"]?.stringValue {
                callIdsWithEvents.insert(id)
            }
        }

        var sections: [TurnSection] = []
        var currentIndex: Int?

        func ensureSection(turn: Int, time: Int64?) -> Int {
            if let currentIndex, sections[currentIndex].turn == turn { return currentIndex }
            if let existing = sections.firstIndex(where: { $0.turn == turn }) {
                currentIndex = existing
                return existing
            }
            sections.append(TurnSection(
                turn: turn,
                status: .running,
                summary: nil,
                rows: [],
                stepCount: 0,
                startedAt: time,
                endedAt: nil,
                fileChanges: nil,
                fileChangeSeq: nil
            ))
            currentIndex = sections.count - 1
            return sections.count - 1
        }

 /// Promote the turn-0 orphan in place once an event names its real turn.
 ///
 /// A follow window can start mid-turn (its `turn/start` is outside the
 /// window), so the first row-producing events — `user/message` and other
 /// notices carry no `data.turn` — open a section through
 /// `activeIndex(for:)` with turn 0. Without promotion that section stays
 /// "Turn 0 运行中" forever and the real `turn/end` can never close it
 /// (real-device regression, oldest=3232 / turn/start(8)=3225).
 /// - Returns: the section index that now owns `turn`.
        func promoteOrphan(at index: Int, to turn: Int) -> Int {
            if let existing = sections.firstIndex(where: { $0.turn == turn }) {
 // The orphan rows precede this section's rows in seq order, so
 // merge them in front, then drop the orphan.
                sections[existing].rows.insert(contentsOf: sections[index].rows, at: 0)
                if sections[existing].startedAt == nil {
                    sections[existing].startedAt = sections[index].startedAt
                }
                sections.remove(at: index)
                return existing > index ? existing - 1 : existing
            }
            sections[index].turn = turn
            return index
        }

        func activeIndex(for event: SessionEvent) -> Int {
            if let index = currentIndex {
 // Mid-turn window: the orphan gets its real turn as soon as an
 // event carries one (`assistant/message`/`tool/call` do,
 // `user/message` does not). Rows and order are preserved.
                if sections[index].turn == 0,
                   let turn = event.data?["turn"]?.int,
                   turn > 0 {
                    let promoted = promoteOrphan(at: index, to: turn)
                    currentIndex = promoted
                    return promoted
                }
                return index
            }
            let turn = event.data?["turn"]?.int ?? 0
            return ensureSection(turn: turn, time: event.time)
        }

        func appendRow(_ content: FlowContent, event: SessionEvent, suffix: String, section explicitIndex: Int? = nil) {
            let index = explicitIndex ?? activeIndex(for: event)
            let row = FlowRow(id: "\(event.seq)-\(suffix)", seq: event.seq, content: content)
            sections[index].rows.append(row)
        }

        for event in sorted {
 // workspace/changes carries only {turn}; its seq is the key for the
 // exact-fetch summary/diff routes (§3.9). Keep the seq per turn.
            if event.type == "workspace/changes" {
                if let currentIndex {
                    sections[currentIndex].fileChangeSeq = event.seq
                } else if let turn = event.data?["turn"]?.int,
                          let index = sections.firstIndex(where: { $0.turn == turn }) {
                    sections[index].fileChangeSeq = event.seq
                }
                continue
            }
            guard !hiddenEventTypes.contains(event.type) else { continue }
            let data = event.data
            switch event.type {
            case "turn/start":
                let turn = data?["turn"]?.int ?? ((sections.last?.turn ?? 0) + 1)
                let index = ensureSection(turn: turn, time: event.time)
                sections[index].status = .running
            case "turn/end":
                let turn = data?["turn"]?.int ?? (sections.last?.turn ?? 0)
 // Mid-turn window whose tail has no turn-bearing row event yet:
 // this `turn/end` is the first event that names the turn, so
 // close the promoted orphan as that turn instead of leaving
 // "Turn 0" behind.
                if turn > 0,
                   !sections.contains(where: { $0.turn == turn }),
                   let orphan = sections.firstIndex(where: { $0.turn == 0 }) {
                    currentIndex = promoteOrphan(at: orphan, to: turn)
                }
                if let index = sections.firstIndex(where: { $0.turn == turn }) {
                    let reason = data?["reason"]
                    sections[index].status = status(from: reason)
                    sections[index].endedAt = event.time
                    if case .error = sections[index].status, let error = reason?["error"] {
                        let message = error["message"]?.stringValue ?? "未知错误"
                        let code = error["code"]?.stringValue
                        appendRow(.error(code.map { "\($0): \(message)" } ?? message), event: event, suffix: "turn-end-error", section: index)
                    }
                }
            case "user/message":
                handleUserMessage(event: event, data: data, appendRow: appendRow)
            case "assistant/message":
                handleAssistantMessage(event: event, data: data, callIdsWithEvents: callIdsWithEvents, appendRow: appendRow)
            case "tool/call":
                let item = toolCall(from: data, event: event)
                appendRow(.tool(item), event: event, suffix: "tool-\(item.callId ?? "seq-\(event.seq)")")
            case "tool/result":
 // Orphan results are appended here (not inside the handler) so the
 // handler's inout `sections` access never overlaps the closure's
 // mutation of the same array (Swift exclusivity abort).
                if let orphan = handleToolResult(event: event, data: data, sections: &sections) {
                    appendRow(orphan.content, event: event, suffix: orphan.suffix)
                }
            case "tool/ptc-dispatch-start":
                handlePTCDispatchStart(event: event, data: data, sections: &sections)
            case "tool/ptc-dispatch":
                handlePTCDispatch(event: event, data: data, sections: &sections)
            case "approval/asked":
                let id = data?["id"]?.stringValue ?? "approval-\(event.seq)"
                appendRow(.approval(ApprovalItem(
                    id: id,
                    toolName: data?["toolName"]?.stringValue,
                    reason: data?["reason"]?.stringValue,
                    outcome: nil
                )), event: event, suffix: "approval")
            case "approval/decided":
                let id = data?["id"]?.stringValue
                let outcome = data?["outcome"]?.stringValue
                updateApprovalRow(id: id, outcome: outcome, sections: &sections)
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
                updateJobRow(data: data, sections: &sections)
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

 // Closing guard: a window that starts mid-turn may never see the
 // `turn/start`/`turn/end` owning its first rows (pagination window,
 // restored cache hole). Such a detached section must never render as
 // "运行中" — an ended session showed a permanent "Turn 0 运行中" card.
        sections.removeAll { $0.turn == 0 && $0.rows.isEmpty }
        for index in sections.indices where sections[index].turn == 0 {
            sections[index].status = .completed
        }

 // Optimistic echo: painted last, so a prompt the user just sent stays at
 // the end of the flow until its durable user/message retires it.
        sections = appendingPendingEchoes(pendingUserEchoes, to: sections, nowMs: nowMs)

 // Aggregate file changes per turn from tool/result.meta.diffs
 // (workspace/changes carries only {turn}; baseline §3.5/§6).
        for index in sections.indices {
            sections[index].fileChanges = aggregateFileChanges(rows: sections[index].rows)
            if sections[index].summary == nil {
                sections[index].summary = firstUserText(in: sections[index].rows)
            }
        }
        return sections
    }

 /// Repaint only the optimistic tail rows (idempotent): the view model calls
 /// this right after `session/prompt` is accepted so the bubble shows in the
 /// same frame, *without* re-running the full journal rebuild (turn status /
 /// queue-flush side effects) before `turn/start` lands.
    static func appendingPendingEchoes(
        _ echoes: [PendingUserEcho],
        to sections: [TurnSection],
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> [TurnSection] {
        var result = sections
        for index in result.indices {
            result[index].rows.removeAll { $0.id.hasPrefix("pending-") }
        }
        appendPendingUserEchoes(echoes, to: &result, nowMs: nowMs)
        return result
    }

 /// Append the optimistic echo rows to the newest section: the user bubble
 /// itself plus a subtle "发送中…" system note. Two rows per echo with ids
 /// derived from `requestId`; the next rebuild replaces the whole pair when
 /// `reconcile(events:)` retires the echo (no duplicate bubble).
    private static func appendPendingUserEchoes(
        _ echoes: [PendingUserEcho],
        to sections: inout [TurnSection],
        nowMs: Int64
    ) {
        guard !echoes.isEmpty else { return }
        if sections.isEmpty {
 // No turn events yet (fresh session): paint a running placeholder so
 // the just-sent prompt is visible before `turn/start` lands.
            sections.append(TurnSection(
                turn: 1,
                status: .running,
                summary: nil,
                rows: [],
                stepCount: 0,
                startedAt: echoes.first?.sentAt,
                endedAt: nil,
                fileChanges: nil,
                fileChangeSeq: nil
            ))
        }
        var seq = sections.flatMap { $0.rows }.map(\.seq).max() ?? 0
        let index = sections.count - 1
        for echo in echoes {
            seq += 1
            sections[index].rows.append(FlowRow(
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
            sections[index].rows.append(FlowRow(
                id: "pending-\(echo.requestId)-status",
                seq: seq,
                content: .systemNote("发送中…")
            ))
        }
    }

 // MARK: - Status / parsing helpers

    static func status(from reason: JSONValue?) -> TurnStatus {
        switch reason?["kind"]?.stringValue {
        case "completed": return .completed
        case "aborted": return .aborted
        case "interrupted": return .interrupted
        case "error": return .error
        case .some(let other): return other == "completed" ? .completed : .completed
        case .none: return .completed
        }
    }

    static func toolCall(from data: JSONValue?, event: SessionEvent) -> ToolCallItem {
        let argumentsRaw = data?["arguments"]?.stringValue
        var arguments: [String: JSONValue] = [:]
        if let argumentsRaw,
           let argumentsData = argumentsRaw.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(JSONValue.self, from: argumentsData),
           let object = parsed.objectValue {
            arguments = object
        } else if let object = data?["arguments"]?.objectValue {
            arguments = object
        }
        return ToolCallItem(
            callId: data?["callId"]?.stringValue,
            name: data?["name"]?.stringValue ?? "tool",
            argumentsRaw: argumentsRaw,
            arguments: arguments,
            result: nil,
            children: [],
            turn: data?["turn"]?.int ?? 0,
            step: data?["step"]?.int
        )
    }

    static func aggregateFileChanges(rows: [FlowRow]) -> FileChangeSummary? {
        var files = Set<String>()
        var additions = 0
        var deletions = 0
        func walk(_ item: ToolCallItem) {
            if let meta = item.result?.meta, let diffs = meta["diffs"]?.arrayValue {
                for diff in diffs {
                    guard let path = diff["path"]?.stringValue else { continue }
                    files.insert(path)
                    let oldLines = diff["oldText"]?.stringValue?.components(separatedBy: "\n").count ?? 0
                    let newLines = diff["newText"]?.stringValue?.components(separatedBy: "\n").count ?? 0
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
        for row in rows {
            if case .tool(let item) = row.content { walk(item) }
        }
        guard !files.isEmpty else { return nil }
        return FileChangeSummary(files: files.sorted(), additions: additions, deletions: deletions)
    }

    static func firstUserText(in rows: [FlowRow]) -> String? {
        for row in rows {
            if case .user(let bubble) = row.content, !bubble.text.isEmpty {
                return bubble.text
            }
        }
        return nil
    }

    static func findToolCall(in sections: [TurnSection], callId: String?) -> ToolCallItem? {
        guard let callId else { return nil }
        func search(_ item: ToolCallItem) -> ToolCallItem? {
            if item.callId == callId { return item }
            for child in item.children {
                if let hit = search(child) { return hit }
            }
            return nil
        }
        for section in sections {
            for row in section.rows {
                if case .tool(let item) = row.content, let hit = search(item) {
                    return hit
                }
            }
        }
        return nil
    }

 // MARK: - Row update handlers (implemented in SessionRowBuilder+Handlers.swift)
}
