import Foundation

/// One step inside a turn's "process group" (v5.3): reasoning text or a tool call.
struct ProcessStep: Identifiable, Equatable {
    enum Kind: Equatable {
        case reasoning(String)
        case tool(ToolCallItem)
 /// v6：工具参数流式阶段（tool-call-delta）的「准备…」占位行；派发（tool/call）后
 /// 由真实.tool 行替换。name 可能尚未到达（nil）。
        case preparing(name: String?, args: String)
 /// v7：子代理消息（主会话 `user/message` + `source.kind=="agent-message"`）。
 /// 桌面端把它混在步骤块里；组内渲染成紧凑行，点击直接打开子代理会话。
        case subagentMessage(RelayCard)
 /// v7：子代理结算（`source.kind=="subagent-settled"`），组内纯展示紧凑行。
        case subagentSettled(text: String)
 /// v7：工作目录变更（`source.kind=="working-directory"`），组内纯展示紧凑行。
        case workingDirectory(WorkingDirectoryChange)
    }

    var id: String
    var kind: Kind
 /// 该步骤对应事件 seq（v0.2.7：用于判定过程组是否属于「本轮」，
 /// 避免刚发消息、新步骤未到时上一轮的组闪成运行中窗口）。
    var seq: Int = 0
 /// v6：本轮运行中实时追加的步骤（实时思考 / 工具准备行），渲染为组内实时行。
 /// 历史步骤恒为 false。
    var isLive: Bool = false

    var tool: ToolCallItem? {
        if case .tool(let item) = kind { return item }
        return nil
    }

    var reasoningText: String? {
        if case .reasoning(let text) = kind { return text }
        return nil
    }

 /// 工具准备行（参数流式中）的工具名；未到达时为 nil。
    var preparingName: String? {
        if case .preparing(let name, _) = kind { return name }
        return nil
    }

 /// 工具准备行已累积的 arguments 原文（可能不是合法 JSON）。
    var preparingArgs: String? {
        if case .preparing(_, let args) = kind { return args }
        return nil
    }

    var isPreparing: Bool {
        if case .preparing = kind { return true }
        return false
    }

 /// v7：子代理消息卡片（非 nil 表示本步骤是「子代理消息」行）。
    var relayCard: RelayCard? {
        if case .subagentMessage(let card) = kind { return card }
        return nil
    }

 /// v7：子代理结算摘要（非 nil 表示本步骤是「子代理结算」行）。
    var subagentSettledText: String? {
        if case .subagentSettled(let text) = kind { return text }
        return nil
    }

 /// v7：工作目录变更（非 nil 表示本步骤是「工作目录」行）。
    var workingDirectoryChange: WorkingDirectoryChange? {
        if case .workingDirectory(let change) = kind { return change }
        return nil
    }

    var isFailure: Bool { tool?.isError ?? false }
    var isRunning: Bool {
        if isPreparing { return true }
        return tool?.isRunning ?? false
    }

 /// Chinese verb used by the folded summary ("运行命令 / 读取 / 编辑 / …").
    var verb: String {
        switch kind {
        case .reasoning:
            return "思考"
        case .tool(let item):
            return SessionFlowGrouping.verb(for: item.name)
        case .preparing(let name, _):
            return SessionFlowGrouping.preparingVerb(for: name)
        case .subagentMessage, .subagentSettled:
            return "子代理"
        case .workingDirectory:
            return "工作目录"
        }
    }

    var localizedVerb: String { L10n.t(verb) }

    var summary: String {
        switch kind {
        case .reasoning(let text):
            return text.replacingOccurrences(of: "\n", with: " ")
        case .tool(let item):
            return item.summary
        case .preparing(_, let args):
            return args
        case .subagentMessage(let card):
            return card.summary ?? card.text
        case .subagentSettled(let text):
            return text
        case .workingDirectory(let change):
            return change.cwd ?? change.text
        }
    }
}

/// Grouped rows for one turn: plain rows plus a process group.
/// v7：组内可以是 1 步（单步也成组，交互与多步组完全一致）。
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
 // 因此这里选「流式身份稳定」优先。
            return "process-" + (steps.first?.id ?? "empty")
        }
    }
}

/// 过程组显示态（v6，对齐 DSH 桌面端「内联工作步骤」平铺 + 大折叠）：
/// - `expanded`：默认态（运行中与已结束都默认）—— 全部步骤平铺内联；
/// - `collapsed`：点组头「收起」—— 折叠成一行（▣ N 步 + 状态 + 展开 ⌄）；
/// - `window`：v0.2.7 旧运行态（固定高度窗口内展示最近 N 步），保留但不再默认；
/// - `full`：v0.2.7 旧运行态（无高度限制全量内联），保留但不再默认。
enum ProcessGroupMode: String, Equatable {
    case window
    case full
    case collapsed
    case expanded
}

/// 过程组显示态解析（v6：默认展开，用户点击产生覆盖）。
/// - 无覆盖 → `expanded`（运行中与已结束都全量平铺，不再自动折叠/固定窗口）；
/// - `collapsed`/`expanded` 覆盖在两种阶段都保留（用户收起状态不因阶段切换丢失）；
/// - 旧 `window`/`full` 仅在运行中有效，结束后丢弃回落到 `expanded`。
enum ProcessGroupModeResolver {
    static func resolve(
        isRunning: Bool,
        override: ProcessGroupMode?,
        stepCount: Int = 0
    ) -> ProcessGroupMode {
        guard let override else {
 // 设计决策：巨型组默认折叠，只渲染组头；
 // 普通组保持默认展开（v6 口径）。阈值/策略见 ProcessGroupStepsLayoutPolicy。
            if ProcessGroupStepsLayoutPolicy.giantCollapsedByDefault(stepCount) {
                return .collapsed
            }
            return .expanded
        }
        switch override {
        case .window, .full:
            return isRunning ? override : .expanded
        case .collapsed, .expanded:
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

 /// turn 结束后修剪用户覆盖（v6 语义）。
 ///
 /// v6 默认态是 `.expanded`，所以 `.expanded` 覆盖与「无覆盖」等价，丢弃无副作用；
 /// 旧运行态覆盖 `.window`/`.full` 只在运行中有效，结束后按 resolver 回落 expanded。
 /// 用户手动收起（`.collapsed`）必须保留——它跨阶段保留是 v6 契约
 /// （见 `testProcessGroupModeUserCollapseIsKeptAcrossPhases`）；v0.2.7 遗留的
 /// 「只保留.expanded」过滤会在每轮结束时把用户收起的历史组全部弹开。
    static func prunedAfterTurnEnd(_ modes: [String: ProcessGroupMode]) -> [String: ProcessGroupMode] {
        modes.filter { $0.value == .collapsed }
    }
}

/// 过程组规则（v7）：连续「步骤行」合成一个 process 组——reasoning / tool，
/// 以及桌面端混在步骤里的子代理消息 / 子代理结算 / 工作目录变更（v7 新增）；
/// **单步也成组**（统一组头交互，替换旧的独立思考块）。其余内容仍是普通行。
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
        var pendingSteps: [ProcessStep] = []
        var groupStart = max(fromRow, 0)

        func flush() {
            guard !pendingSteps.isEmpty else { return }
 // v7：**单步也成组**。v6 的「单步不成组」让孤立思考/工具行走独立的
 // 单行渲染（思考是 `ReasoningRowView`：默认折叠、chevron right→down、
 // 行内向下展开），与步骤块（默认展开、chevron up=收起）交互相反
 // （用户问题 4：单独思考块的展开/折叠跟步骤块反过来）。统一进
 // `ProcessGroupView` 后，组头/chevron/手势热区/滚动锚定动画与多步组
 // 完全一致；组 id 仍是首 step，流式追加不换 id（v6 契约）。
            groups.append(.process(pendingSteps))
            ranges.append(groupStart..<(groupStart + pendingSteps.count))
            pendingSteps = []
        }

        let start = min(max(fromRow, 0), rows.count)
        for index in start..<rows.count {
            let row = rows[index]
            if let step = processStep(from: row) {
                if pendingSteps.isEmpty { groupStart = index }
                pendingSteps.append(step)
            } else {
                flush()
                groups.append(.single(row))
                ranges.append(index..<(index + 1))
            }
        }
        flush()
        return (groups, ranges)
    }

 /// 单个行 → 组内步骤的映射（v7）：reasoning/tool 之外，桌面端混在步骤块里的
 /// 子代理消息 / 子代理结算 / 工作目录变更也进同一组；其余内容仍是普通行。
    static func processStep(from row: FlowRow) -> ProcessStep? {
        switch row.content {
        case .reasoning(let text):
            return ProcessStep(id: row.id, kind: .reasoning(text), seq: row.seq)
        case .tool(let item):
            return ProcessStep(id: row.id, kind: .tool(item), seq: row.seq)
        case .relay(let card):
            return ProcessStep(id: row.id, kind: .subagentMessage(card), seq: row.seq)
        case .notice(let notice):
            switch notice.kind {
            case "subagent-settled":
                return ProcessStep(id: row.id, kind: .subagentSettled(text: notice.text), seq: row.seq)
            case "working-directory":
                return ProcessStep(
                    id: row.id,
                    kind: .workingDirectory(WorkingDirectoryChange(text: notice.text)),
                    seq: row.seq
                )
            default:
                return nil
            }
        default:
            return nil
        }
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
        let canonicalOrder = ["运行命令", "读取", "编辑", "搜索", "联网", "计划", "交付", "子代理", "工作目录", "后台任务", "工具", "思考", "准备运行命令", "准备读取", "准备编辑", "准备搜索", "准备调用工具"]
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

 /// v6：工具准备行的动词（参数流式阶段、工具名未到达时按「准备调用工具」兜底）。
    static func preparingVerb(for toolName: String?) -> String {
        let name = (toolName ?? "").lowercased()
        if name.contains("bash") || name.contains("run_code") { return "准备运行命令" }
        if name.contains("read") { return "准备读取" }
        if name.contains("edit") || name.contains("write") { return "准备编辑" }
        if name.contains("grep") || name.contains("glob") { return "准备搜索" }
        return "准备调用工具"
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
        let canonicalOrder = ["运行命令", "读取", "编辑", "搜索", "联网", "计划", "交付", "子代理", "工作目录", "后台任务", "工具", "思考", "准备运行命令", "准备读取", "准备编辑", "准备搜索", "准备调用工具"]
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
/// 起点重算尾部；
/// - full：前置历史页 / 原地挂载工具结果 / 全量替换——整表重算（跨页边界相邻
/// reasoning/tool 行的合并由全量分组保证正确）。
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
