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
enum FlowRowGroup: Identifiable, Equatable {
    case single(FlowRow)
    case process([ProcessStep])

    var id: String {
        switch self {
        case .single(let row):
            return row.id
        case .process(let steps):
            // v0.2.6 滚动修复：组 id 用**最后一条 step**，保证「向历史方向 prepend」
            // 时既有组的 id 不变（新 step 只会加在组头，尾 step 保持不变），
            // scrollPosition(id:) 的锚点因此不会在补齐插入时失效。
            return "process-" + (steps.last?.id ?? "empty")
        }
    }
}

/// v5.3 rule: consecutive reasoning + tool-call rows form one folded process
/// group; everything else stays a normal row.
enum SessionFlowGrouping {
    /// 全量分组（首帧 / 测试 oracle / 增量缓存的兜底）。
    static func groups(rows: [FlowRow]) -> [FlowRowGroup] {
        makeGroups(rows: rows, fromRow: 0).groups
    }

    /// 从 fromRow 行开始分组，同时返回每个分组对应的行区间——增量缓存只需重算
    /// 变化的尾部区间（见 FlowGroupCache）。
    static func makeGroups(rows: [FlowRow], fromRow: Int) -> (groups: [FlowRowGroup], ranges: [Range<Int>]) {
        var groups: [FlowRowGroup] = []
        var ranges: [Range<Int>] = []
        var pendingIndexes: [Int] = []
        var pendingSteps: [ProcessStep] = []
        var groupStart = max(fromRow, 0)

        func flush() {
            guard !pendingSteps.isEmpty else { return }
            if pendingSteps.count >= 2 {
                groups.append(.process(pendingSteps))
                ranges.append(groupStart..<(groupStart + pendingSteps.count))
            } else {
                for index in pendingIndexes {
                    groups.append(.single(rows[index]))
                    ranges.append(index..<(index + 1))
                }
            }
            pendingIndexes = []
            pendingSteps = []
        }

        let start = min(max(fromRow, 0), rows.count)
        for index in start..<rows.count {
            let row = rows[index]
            switch row.content {
            case .reasoning(let text):
                if pendingSteps.isEmpty { groupStart = index }
                pendingIndexes.append(index)
                pendingSteps.append(ProcessStep(id: row.id, kind: .reasoning(text)))
            case .tool(let item):
                if pendingSteps.isEmpty { groupStart = index }
                pendingIndexes.append(index)
                pendingSteps.append(ProcessStep(id: row.id, kind: .tool(item)))
            default:
                flush()
                groups.append(.single(row))
                ranges.append(index..<(index + 1))
            }
        }
        flush()
        return (groups, ranges)
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

/// 渲染分组缓存（会话详情的行 → 分组）。
///
/// 视图 body 只读缓存结果，不再每次 O(N) 重算；FlowState 在行变化时按变更类型
/// 增量刷新：
/// - tail：只有尾部行变化（live 追加 / 乐观回显重画）——丢掉最后一个分组，从它的
///   起点重算尾部；
/// - full：前置历史页 / 原地挂载工具结果 / 全量替换——整表重算（跨页边界相邻
///   reasoning/tool 行的合并由全量分组保证正确）。
struct FlowGroupCache {
    enum Change {
        case tail
        case full
    }

    private(set) var groups: [FlowRowGroup] = []
    private var ranges: [Range<Int>] = []
    private var rowCount = 0

    mutating func rebuild(rows: [FlowRow]) {
        let result = SessionFlowGrouping.makeGroups(rows: rows, fromRow: 0)
        groups = result.groups
        ranges = result.ranges
        rowCount = rows.count
    }

    mutating func refreshTail(rows: [FlowRow]) {
        guard rowCount > 0,
              let lastRange = ranges.last,
              rows.count >= rowCount,
              lastRange.lowerBound < rows.count else {
            rebuild(rows: rows)
            return
        }
        groups.removeLast()
        ranges.removeLast()
        let result = SessionFlowGrouping.makeGroups(rows: rows, fromRow: lastRange.lowerBound)
        groups.append(contentsOf: result.groups)
        ranges.append(contentsOf: result.ranges)
        rowCount = rows.count
    }
}
