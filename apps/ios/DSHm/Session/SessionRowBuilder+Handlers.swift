import Foundation

// MARK: - Per-event row handlers for SessionRowBuilder

extension SessionRowBuilder {

    static func handleUserMessage(
        event: SessionEvent,
        data: JSONValue?,
        appendRow: (FlowContent, SessionEvent, String) -> Void
    ) {
        let source = data?["source"]
        let kind = source?["kind"]?.stringValue ?? "user"
        let form = source?["form"]?.stringValue
        let content = data?["content"]
        let text = MessageContent.text(from: content)
        let images = MessageContent.images(from: content)
        switch kind {
        case "user":
            guard !text.isEmpty || !images.isEmpty else { return }
            appendRow(.user(UserBubble(
                text: text,
                images: images,
                time: event.time,
                messageId: data?["id"]?.stringValue
            )), event, "user")
        case "agent-message":
            let summary = source?["summary"]?.stringValue
            appendRow(.relay(RelayCard(
                text: text.isEmpty ? (summary ?? "") : text,
                senderSessionId: source?["senderSessionId"]?.stringValue,
                summary: summary,
                images: images
            )), event, "relay")
        case "subagent-settled":
            appendRow(.notice(NoticeCard(
                title: "子代理结算",
                text: source?["summary"]?.stringValue ?? text,
                kind: kind
            )), event, "notice-settled")
        case "tool-jobs":
            appendRow(.notice(NoticeCard(title: "后台任务", text: source?["summary"]?.stringValue ?? text, kind: kind)), event, "notice-jobs")
        case "repeat-tool-reminder":
            appendRow(.notice(NoticeCard(title: "提醒", text: text, kind: kind)), event, "notice-reminder")
        case "user-approval":
            appendRow(.notice(NoticeCard(title: "审批回答", text: text, kind: kind)), event, "notice-approval")
        case "agent-instructions", "runtime-context", "skill-catalog", "time-context", "ptc-mode":
            return
        default:
            let summary = source?["summary"]?.stringValue
            let body = text.isEmpty ? (summary ?? "") : text
            guard !body.isEmpty else { return }
            appendRow(.notice(NoticeCard(
                title: noticeTitle(kind: kind, form: form),
                text: body,
                kind: kind
            )), event, "notice-\(kind)")
        }
    }

    static func noticeTitle(kind: String, form: String?) -> String {
        switch kind {
        case "tool-jobs": return "后台任务"
        case "subagent-settled": return "子代理结算"
        case "repeat-tool-reminder": return "提醒"
        case "user-approval": return "审批回答"
        case "agent-message": return "子代理消息"
        default:
            if form == "notice" { return "通知" }
            return kind
        }
    }

    static func handleAssistantMessage(
        event: SessionEvent,
        data: JSONValue?,
        callIdsWithEvents: Set<String>,
        appendRow: (FlowContent, SessionEvent, String) -> Void
    ) {
        let blocks = data?["message"]?["content"]?.arrayValue ?? []
        for (index, block) in blocks.enumerated() {
            switch block["type"]?.stringValue {
            case "reasoning":
                if let text = block["text"]?.stringValue, !text.isEmpty {
                    appendRow(.reasoning(text), event, "reasoning-\(index)")
                }
            case "text":
                if let text = block["text"]?.stringValue, !text.isEmpty {
                    appendRow(.text(text), event, "text-\(index)")
                }
            case "tool-call":
                let callId = block["id"]?.stringValue ?? block["callId"]?.stringValue
                if let callId, callIdsWithEvents.contains(callId) { continue }
                let argumentsRaw = block["arguments"]?.stringValue
                var arguments: [String: JSONValue] = [:]
                if let argumentsRaw,
                   let argumentsData = argumentsRaw.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(JSONValue.self, from: argumentsData),
                   let object = parsed.objectValue {
                    arguments = object
                } else if let object = block["arguments"]?.objectValue {
                    arguments = object
                }
                let item = ToolCallItem(
                    callId: callId,
                    name: block["name"]?.stringValue ?? "tool",
                    argumentsRaw: argumentsRaw,
                    arguments: arguments,
                    result: nil,
                    children: [],
                    turn: data?["message"]?["turn"]?.int ?? 0,
                    step: nil
                )
                appendRow(.tool(item), event, "tool-block-\(index)")
            default:
                continue
            }
        }
    }

 /// Attaches a tool result to its already-rendered tool row; an orphan result
 /// (no matching tool/call) is returned to the caller as a row to append.
 ///
 /// The orphan path used to take an `appendRow` closure as well as
 /// `rows: inout`. That closure captures and mutates the same `rows` array the
 /// inout access is still active on, which the Swift runtime reports as an
 /// exclusivity violation and aborts the process (SIGABRT) in Debug/test
 /// builds: replaying paged history that contains a tool result whose call row is
 /// outside the loaded page crashed `SessionRowBuilder.build`. Returning the
 /// content instead keeps the inout access exclusive.
    static func handleToolResult(
        event: SessionEvent,
        data: JSONValue?,
        rows: inout [FlowRow]
    ) -> (content: FlowContent, suffix: String)? {
        let message = data?["message"]
        let content = message?["content"]
        let result = ToolResultItem(
            isError: message?["isError"]?.boolValue ?? false,
            text: MessageContent.text(from: content),
            meta: data?["meta"],
            images: MessageContent.images(from: content)
        )
        let toolCallId = message?["toolCallId"]?.stringValue
            ?? data?["toolCallId"]?.stringValue
            ?? data?["callId"]?.stringValue
        if let toolCallId, attachToolResult(callId: toolCallId, result: result, rows: &rows) {
            return nil
        }
        let item = ToolCallItem(
            callId: toolCallId,
            name: data?["name"]?.stringValue ?? "tool",
            argumentsRaw: nil,
            arguments: [:],
            result: result,
            children: [],
            turn: data?["turn"]?.int ?? 0,
            step: nil
        )
        return (.tool(item), "tool-result")
    }

    static func handlePTCDispatchStart(event: SessionEvent, data: JSONValue?, rows: inout [FlowRow]) {
        let argumentsRaw = data?["arguments"]?.stringValue
        var arguments: [String: JSONValue] = [:]
        if let argumentsRaw,
           let argumentsData = argumentsRaw.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(JSONValue.self, from: argumentsData),
           let object = parsed.objectValue {
            arguments = object
        }
        let child = ToolCallItem(
            callId: data?["subCallId"]?.stringValue,
            name: data?["name"]?.stringValue ?? "tool",
            argumentsRaw: argumentsRaw,
            arguments: arguments,
            result: nil,
            children: [],
            turn: data?["turn"]?.int ?? 0,
            step: nil
        )
        guard let parentCallId = data?["parentCallId"]?.stringValue else { return }
        appendToolChild(parentCallId: parentCallId, child: child, rows: &rows)
    }

    static func handlePTCDispatch(event: SessionEvent, data: JSONValue?, rows: inout [FlowRow]) {
        let message = data
        let result = ToolResultItem(
            isError: message?["isError"]?.boolValue ?? false,
            text: MessageContent.text(from: message?["content"]),
            meta: message?["meta"],
            images: MessageContent.images(from: message?["content"])
        )
        guard let subCallId = data?["subCallId"]?.stringValue else { return }
        _ = attachToolResult(callId: subCallId, result: result, rows: &rows)
    }

    static func updateApprovalRow(id: String?, outcome: String?, rows: inout [FlowRow]) {
        guard let id else { return }
        for rowIndex in rows.indices {
            if case .approval(var item) = rows[rowIndex].content, item.id == id {
                item.outcome = outcome
                rows[rowIndex].content = .approval(item)
            }
        }
    }

    static func updateJobRow(data: JSONValue?, rows: inout [FlowRow]) {
        guard let jobId = data?["jobId"]?.stringValue else { return }
        for rowIndex in rows.indices {
            if case .job(var item) = rows[rowIndex].content, item.jobId == jobId {
                item.status = data?["status"]?.stringValue ?? item.status
                item.finishedAt = data?["finishedAt"]?.intValue
                rows[rowIndex].content = .job(item)
            }
        }
    }

 // MARK: - Row attachment helpers

    static func attachToolResult(callId: String, result: ToolResultItem, rows: inout [FlowRow]) -> Bool {
        for rowIndex in rows.indices.reversed() {
            if case .tool(var item) = rows[rowIndex].content {
                if item.callId == callId {
                    item.result = result
                    rows[rowIndex].content = .tool(item)
                    return true
                }
                if applyResultRecursively(callId: callId, result: result, item: &item) {
                    rows[rowIndex].content = .tool(item)
                    return true
                }
            }
        }
        return false
    }

    static func applyResultRecursively(callId: String, result: ToolResultItem, item: inout ToolCallItem) -> Bool {
        for index in item.children.indices {
            if item.children[index].callId == callId {
                item.children[index].result = result
                return true
            }
            if applyResultRecursively(callId: callId, result: result, item: &item.children[index]) {
                return true
            }
        }
        return false
    }

    static func appendToolChild(parentCallId: String, child: ToolCallItem, rows: inout [FlowRow]) {
        for rowIndex in rows.indices.reversed() {
            if case .tool(var item) = rows[rowIndex].content {
                if appendChildRecursively(parentCallId: parentCallId, child: child, item: &item) {
                    rows[rowIndex].content = .tool(item)
                    return
                }
            }
        }
    }

    static func appendChildRecursively(parentCallId: String, child: ToolCallItem, item: inout ToolCallItem) -> Bool {
        if item.callId == parentCallId {
            item.children.append(child)
            return true
        }
        for index in item.children.indices {
            if appendChildRecursively(parentCallId: parentCallId, child: child, item: &item.children[index]) {
                return true
            }
        }
        return false
    }
}
