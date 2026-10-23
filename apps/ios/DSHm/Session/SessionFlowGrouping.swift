import Foundation

/// One step inside a turn's "process group" (v5.3): reasoning text or a tool call.
struct ProcessStep: Identifiable, Equatable {
    enum Kind: Equatable {
        case reasoning(String)
        case tool(ToolCallItem)
    }

    var id: String
    var kind: Kind
    /// 该步骤对应事件 seq（v0.2.7：用于判定过程组是否属于「本轮」，
    /// 避免刚发消息、新步骤未到时上一轮的组闪成运行中窗口）。
    var seq: Int = 0

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

    /// 组内第一条步骤的事件 seq（.single 取行 seq）。
    var firstSeq: Int {
        switch self {
        case .single(let row): return row.seq
        case .process(let steps): return steps.first?.seq ?? Int.min
        }
    }

    var id: String {
        switch self {
        case .single(let row):
            return row.id
        case .process(let steps):
            // v0.2.7：组 id 改用**首 step**。
            // v0.2.6 用尾 step 的动机是历史补齐时 id 不变，但代价是**流式追加**
            // （新 step 加在组尾）每一步都换 id：diffable 把它当「删旧行 + 插新行」，
            // 行高重测、展开态随 cell 重建丢失——即用户报障的过程组渲染错乱。
            // 反转列表下历史补齐是数据尾部追加、既有内容坐标不变，锚点不依赖 id 复用，
            // 因此这里选「流式身份稳定」优先（真机滚动门禁见 apps/ios/scripts）。
            return "process-" + (steps.first?.id ?? "empty")
        }
    }
}

/// 过程组显示态（v0.2.7，对齐 DSH 桌面端「内联工作步骤」）：
/// - `window`：运行中默认 —— 固定高度窗口内滚动、自动跟随最新步骤；
/// - `full`：运行中点图标 —— 取消高度限制，全部步骤内联撑开；
/// - `collapsed`：这一轮步骤结束 —— 自动折叠成一行摘要；
/// - `expanded`：点折叠行 —— 展开该轮全部历史步骤。
enum ProcessGroupMode: String, Equatable {
    case window
    case full
    case collapsed
    case expanded
}

/// 过程组显示态解析（默认态由「是否正在跑」推导，用户点击产生覆盖）。
/// 阶段切换时自动丢弃不适用的覆盖，保证「结束即折叠」不被运行期覆盖卡住。
enum ProcessGroupModeResolver {
    static func resolve(isRunning: Bool, override: ProcessGroupMode?) -> ProcessGroupMode {
        let fallback: ProcessGroupMode = isRunning ? .window : .collapsed
        guard let override else { return fallback }
        switch (isRunning, override) {
        case (true, .collapsed), (true, .expanded):
            return fallback
        case (false, .window), (false, .full):
            return fallback
        default:
            return override
        }
    }

    /// 同一个控件点击后的目标态：运行中 window⇄full；已结束 collapsed⇄expanded。
    static func toggled(_ current: ProcessGroupMode) -> ProcessGroupMode {
        switch current {
        case .window: return .full
        case .full: return .window
        case .collapsed: return .expanded
        case .expanded: return .collapsed
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
                pendingSteps.append(ProcessStep(id: row.id, kind: .reasoning(text), seq: row.seq))
            case .tool(let item):
                if pendingSteps.isEmpty { groupStart = index }
                pendingIndexes.append(index)
                pendingSteps.append(ProcessStep(id: row.id, kind: .tool(item), seq: row.seq))
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
