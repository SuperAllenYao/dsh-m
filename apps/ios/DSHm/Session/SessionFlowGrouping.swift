import Foundation

/// One step inside a turn's "process group" (v5.3): reasoning text or a tool call.
struct ProcessStep: Identifiable, Equatable {
    enum Kind: Equatable {
        case reasoning(String)
        case tool(ToolCallItem)
    }

    var id: String
    var kind: Kind

    var tool: ToolCallItem? {
        if case .tool(let item) = kind { return item }
        return nil
    }

    var reasoningText: String? {
        if case .reasoning(let text) = kind { return text }
        return nil
    }

    var isFailure: Bool { tool?.isError ?? false }
    var isRunning: Bool { tool?.isRunning ?? false }

    /// Chinese verb used by the folded summary ("运行命令 / 读取 / 编辑 / …").
    var verb: String {
        guard let tool else { return "思考" }
        return SessionFlowGrouping.verb(for: tool.name)
    }

    var localizedVerb: String { L10n.t(verb) }

    var summary: String {
        tool?.summary ?? (reasoningText ?? "").replacingOccurrences(of: "\n", with: " ")
    }
}

/// Grouped rows for one turn: plain rows plus a folded process group.
enum FlowRowGroup: Identifiable {
    case single(FlowRow)
    case process([ProcessStep])

    var id: String {
        switch self {
        case .single(let row):
            return row.id
        case .process(let steps):
            return "process-" + (steps.first?.id ?? "empty")
        }
    }
}

/// v5.3 rule: consecutive reasoning + tool-call rows form one folded process
/// group; everything else stays a normal row.
enum SessionFlowGrouping {
    static func groups(rows: [FlowRow]) -> [FlowRowGroup] {
        var groups: [FlowRowGroup] = []
        var pendingRows: [FlowRow] = []
        var pendingSteps: [ProcessStep] = []

        func flush() {
            guard !pendingSteps.isEmpty else { return }
            if pendingSteps.count >= 2 {
                groups.append(.process(pendingSteps))
            } else {
                groups.append(contentsOf: pendingRows.map { FlowRowGroup.single($0) })
            }
            pendingRows = []
            pendingSteps = []
        }

        for row in rows {
            switch row.content {
            case .reasoning(let text):
                pendingRows.append(row)
                pendingSteps.append(ProcessStep(id: row.id, kind: .reasoning(text)))
            case .tool(let item):
                pendingRows.append(row)
                pendingSteps.append(ProcessStep(id: row.id, kind: .tool(item)))
            default:
                flush()
                groups.append(.single(row))
            }
        }
        flush()
        return groups
    }

    /// Steps that may be folded: completed tools + reasoning.
    static func foldableSteps(_ steps: [ProcessStep], pendingApprovalCallIds: Set<String>) -> [ProcessStep] {
        steps.filter { !isException($0, pendingApprovalCallIds: pendingApprovalCallIds) }
    }

    /// Failures and pending-approval steps must stay visible (v5.3 exception rule).
    static func exceptionSteps(_ steps: [ProcessStep], pendingApprovalCallIds: Set<String>) -> [ProcessStep] {
        steps.filter { isException($0, pendingApprovalCallIds: pendingApprovalCallIds) }
    }

    static func isException(_ step: ProcessStep, pendingApprovalCallIds: Set<String>) -> Bool {
        if step.isFailure { return true }
        if let callId = step.tool?.callId, pendingApprovalCallIds.contains(callId) { return true }
        return false
    }

    /// "运行命令 2 · 读取 1 · 思考 3"
    static func summaryText(_ steps: [ProcessStep]) -> String {
        guard !steps.isEmpty else { return "" }
        var counts: [String: Int] = [:]
        for step in steps {
            counts[step.verb, default: 0] += 1
        }
        let canonicalOrder = ["运行命令", "读取", "编辑", "搜索", "联网", "计划", "交付", "子代理", "后台任务", "工具", "思考"]
        let known = canonicalOrder.filter { counts[$0] != nil }
        let unknown = counts.keys.filter { !canonicalOrder.contains($0) }.sorted()
        return (known + unknown)
            .map { "\($0) \(counts[$0] ?? 0)" }
            .joined(separator: " · ")
    }

    /// The step highlighted while the turn runs (extra 28pt row, v5.3).
    static func currentStep(_ steps: [ProcessStep]) -> ProcessStep? {
        if let running = steps.last(where: { $0.isRunning }) { return running }
        return steps.last
    }

    static func verb(for toolName: String) -> String {
        switch toolName.lowercased() {
        case "bash", "run_code":
            return "运行命令"
        case "read", "read_image":
            return "读取"
        case "edit", "write":
            return "编辑"
        case "grep", "glob":
            return "搜索"
        case "web_search", "web_fetch":
            return "联网"
        case "todo_write":
            return "计划"
        case "present":
            return "交付"
        case "subagent", "spawn_teammate", "send_message", "wait_agent", "interrupt_agent", "list_agents":
            return "子代理"
        case "job_output", "job_kill", "job_list":
            return "后台任务"
        default:
            return "工具"
        }
    }

    /// Localized display verb (canonical `verb(for:)` stays Chinese for tests).
    static func localizedVerb(for toolName: String) -> String {
        L10n.t(verb(for: toolName))
    }

    /// Localized folded-summary text ("Run command 2 · Read 1 · Thinking 3").
    static func localizedSummaryText(_ steps: [ProcessStep]) -> String {
        guard !steps.isEmpty else { return "" }
        var counts: [String: Int] = [:]
        for step in steps { counts[step.verb, default: 0] += 1 }
        let canonicalOrder = ["运行命令", "读取", "编辑", "搜索", "联网", "计划", "交付", "子代理", "后台任务", "工具", "思考"]
        let known = canonicalOrder.filter { counts[$0] != nil }
        let unknown = counts.keys.filter { !canonicalOrder.contains($0) }.sorted()
        return (known + unknown)
            .map { L10n.f("%@ %lld", L10n.t($0), counts[$0] ?? 0) }
            .joined(separator: " · ")
    }
}
