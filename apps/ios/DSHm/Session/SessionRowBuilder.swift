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

 // MARK: - Build

    static func build(events: [SessionEvent]) -> [TurnSection] {
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

        func activeIndex(for event: SessionEvent) -> Int {
            if let currentIndex { return currentIndex }
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
