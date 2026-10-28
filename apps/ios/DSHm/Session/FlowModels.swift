import Foundation

// MARK: - Flow row model (built purely from session events; see SessionRowBuilder)

// MARK: - 过程组步骤内容签名（折叠组高度缓存 / 展开动画 Δ 的有效性校验）

extension FlowRowGroup {
 /// 步骤内容高度（不含组头）的**公式估算**：步骤行是固定行高——
 /// 28pt 行 + 非高亮/非实时行前 1pt hairline（与 ProcessGroupView 的
 /// stepRowHeight = 29 口径一致）。精确值仍由展开态 reader 测一次回写
 /// GroupStepsHeightStore；公式只用于「缓存未命中时先给出 Δ」，
 /// 避免为测量而把整组步骤再渲染一遍（超级组 291 步时是双倍布局成本）。
    var estimatedStepsHeight: CGFloat {
        estimatedStepsHeight(limit: Int.max)
    }

 /// 前 limit 步的步骤内容高度（巨型组首屏限量渲染时用于精确 offset 补偿）。
    func estimatedStepsHeight(limit: Int) -> CGFloat {
        guard case .process(let steps) = self else { return 0 }
        guard limit > 0 else { return 0 }
        var height: CGFloat = 0
        for step in steps.prefix(limit) {
            height += 28
 // 实时行 / 运行中工具行自带底色与 accent 顶边，不再叠 hairline。
            let highlighted = step.isLive || step.isRunning
            if !highlighted { height += 1 }
        }
        return height
    }

 /// 过程组的步骤数（.single 行 = 1；非过程组 = 0）。
    var stepCount: Int {
        switch self {
        case .single: return 1
        case .process(let steps): return steps.count
        }
    }

 /// 步骤内容的稳定签名。
 ///
 /// 为什么需要它：过程组 id 用**首 step**（流式追加时 id 不变，保证 diff 稳定），
 /// 所以「折叠后组内又流入新步骤 / 实时思考文本变长」不会改 id——只按 id 缓存
 /// 展开高度会命中过期值，展开动画的 Δ 就会错、组头会跳。签名把
 /// 「步骤数 + 首/尾 step id + 组内实时行文本长度」拼进来，内容一变即失效。
    var stepsContentSignature: String {
        switch self {
        case .single:
            return "single"
        case .process(let steps):
            guard let first = steps.first, let last = steps.last else { return "process-empty" }
            var liveBytes = 0
            for step in steps where step.isLive {
                switch step.kind {
                case .reasoning(let text): liveBytes &+= text.count
                case .preparing(_, let args): liveBytes &+= args.count
                default: liveBytes &+= 1
                }
            }
            return "process|\(steps.count)|\(first.id)|\(last.id)|\(liveBytes)"
        }
    }
}

struct ImageRef: Equatable, Hashable {
    var attachmentId: String?
    var mediaType: String?
    var width: Int?
    var height: Int?
    var name: String?
    var bytes: Int?

    static func parse(_ value: JSONValue?) -> ImageRef? {
        guard let value else { return nil }
        let attachment = value["attachment"] ?? value
        let id = attachment["attachmentId"]?.stringValue
        guard id != nil else { return nil }
        return ImageRef(
            attachmentId: id,
            mediaType: attachment["mediaType"]?.stringValue,
            width: attachment["width"]?.int,
            height: attachment["height"]?.int,
            name: attachment["name"]?.stringValue,
            bytes: attachment["bytes"]?.int
        )
    }
}

struct TodoItem: Identifiable, Equatable {
    var content: String
    var status: String
    var id: String { content + status }
}

struct ToolResultItem: Equatable {
    var isError: Bool
    var text: String
    var meta: JSONValue?
    var images: [ImageRef]
 /// 协议 v1 lazy-fetch（契约 §7）：被截断的字段名（`text`/`lines`/`diffs`）。
 /// nil = 本行未截断（默认模式；展开入口走本地展开、零网络）。
    var truncated: [String]? = nil
 /// 该结果事件自己的 seq（`tool/result` 行的 seq），lazy-fetch 窄页请求的 key。
 /// 注意不是调用行的 seq：截断发生在 `tool/result` 事件上。
    var sourceSeq: Int? = nil

 /// 是否需要先 lazy-fetch 才能拿到全文（截断 + 知道目标 seq）。
    var needsLazyFullFetch: Bool {
        guard let truncated, !truncated.isEmpty else { return false }
        return sourceSeq != nil
    }
}

/// 工具参数的惰性解析持有者。
///
/// 行构建只保留原始 JSON 字符串（argumentsRaw，线上本来就是这个形态）；参数只在
/// 真正要显示摘要（summary）或参数面板时才解码一次并缓存——全量/增量构建不再为
/// 不可见的工具行付出 JSONDecoder 成本。同一 ToolCallItem 的拷贝共享同一个 box，
/// 解析结果也随之共享（主线程 / MainActor 使用，与视图读取同一线程）。
final class ToolArgumentsBox {
    private var parsed: [String: JSONValue]?
    private let raw: String?
    private let fallback: [String: JSONValue]

    init(raw: String?, fallback: [String: JSONValue]) {
        self.raw = raw
        self.fallback = fallback
    }

    var value: [String: JSONValue] {
        if let parsed { return parsed }
        let resolved = resolve()
        parsed = resolved
        return resolved
    }

    private func resolve() -> [String: JSONValue] {
        if let raw, !raw.isEmpty, let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
           let object = decoded.objectValue {
            return object
        }
        return fallback
    }
}

struct ToolCallItem: Identifiable, Equatable {
    var callId: String?
    var name: String
    var argumentsRaw: String?
    private var argumentsBox: ToolArgumentsBox
    var result: ToolResultItem?
    var children: [ToolCallItem]
    var turn: Int
    var step: Int?

 /// 惰性解析后的参数（首次访问时解码 argumentsRaw 并缓存）。
    var arguments: [String: JSONValue] { argumentsBox.value }

    init(
        callId: String?,
        name: String,
        argumentsRaw: String?,
        arguments: [String: JSONValue] = [:],
        result: ToolResultItem?,
        children: [ToolCallItem],
        turn: Int,
        step: Int?
    ) {
        self.callId = callId
        self.name = name
        self.argumentsRaw = argumentsRaw
        self.argumentsBox = ToolArgumentsBox(raw: argumentsRaw, fallback: arguments)
        self.result = result
        self.children = children
        self.turn = turn
        self.step = step
    }

    var id: String { callId ?? "call-\(name)-\(turn)-\(step ?? 0)" }

    var isRunning: Bool { result == nil }
    var isError: Bool { result?.isError == true }

 /// raw 相同即参数相同（解析是纯函数）：视图 diff 不该触发 JSON 解码。
 /// 只有 raw 缺失（本地构造 / 参数本来就是对象）时才比较解析后的值。
    static func == (lhs: ToolCallItem, rhs: ToolCallItem) -> Bool {
        guard lhs.callId == rhs.callId,
              lhs.name == rhs.name,
              lhs.argumentsRaw == rhs.argumentsRaw,
              lhs.result == rhs.result,
              lhs.children == rhs.children,
              lhs.turn == rhs.turn,
              lhs.step == rhs.step else { return false }
        if lhs.argumentsRaw != nil || rhs.argumentsRaw != nil { return true }
        return lhs.arguments == rhs.arguments
    }

 /// One-line argument summary per tool (v5.1 compact row spec):
 /// bash=command first line; read/edit/write/read_image=file basename;
 /// grep/glob=pattern; long text is middle-truncated by the row.
    var summary: String {
        switch name {
        case "bash":
            return firstLine(arguments["command"]?.stringValue) ?? ""
        case "read", "edit", "write", "read_image":
            if let path = arguments["file_path"]?.stringValue, !path.isEmpty {
                return (path as NSString).lastPathComponent
            }
            return arguments["file_path"]?.stringValue ?? ""
        case "grep":
            return arguments["pattern"]?.stringValue ?? ""
        case "glob":
            return arguments["pattern"]?.stringValue ?? ""
        case "web_search":
            if let queries = arguments["queries"]?.arrayValue {
                return queries.compactMap { $0.stringValue }.joined(separator: ", ")
            }
            return ""
        case "web_fetch":
            return arguments["url"]?.stringValue ?? ""
        case "run_code":
            return arguments["description"]?.stringValue ?? firstLine(arguments["code"]?.stringValue) ?? ""
        case "todo_write":
            if let todos = arguments["todos"]?.arrayValue {
                return L10n.f("%lld 项", todos.count)
            }
            return ""
        case "present":
            if let files = arguments["files"]?.arrayValue {
                return L10n.f("%lld 个文件", files.count)
            }
            return ""
        default:
            for key in ["description", "prompt", "command", "path", "url"] {
                if let value = arguments[key]?.stringValue, !value.isEmpty { return value }
            }
            return ""
        }
    }

    var statusText: String {
        if let result {
            return result.isError ? L10n.t("失败") : L10n.t("成功")
        }
        return L10n.t("运行中")
    }

    private func firstLine(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text.components(separatedBy: .newlines).first
    }
}

struct ApprovalItem: Identifiable, Equatable {
    var id: String
    var toolName: String?
    var reason: String?
    var outcome: String?
}

struct JobItem: Identifiable, Equatable {
    var id: String { jobId }
    var jobId: String
    var kind: String
    var label: String
    var status: String?
    var startedAt: Int64?
    var finishedAt: Int64?
}

struct PresentedFile: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var description: String?
}

struct UserBubble: Equatable {
    var text: String
    var images: [ImageRef]
    var time: Int64?
    var messageId: String?
}

struct RelayCard: Equatable {
    var text: String
    var senderSessionId: String?
    var summary: String?
    var images: [ImageRef]
}

/// One entry of the parent session's `subagentCatalog` projection (v5.4 §1 /
/// task-13): `{id, createdAt, mode:"one-shot"|"external"|"continuable", label?}`.
struct SubagentCatalogEntry: Identifiable, Equatable {
    var id: String
    var createdAt: Int64?
    var mode: String?
    var label: String?

 /// Explicit memberwise init (the `init?(json:)` below otherwise removes it);
 /// used when a child is discovered from `session/list` instead of the
 /// projection.
    init(id: String, createdAt: Int64? = nil, mode: String? = nil, label: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.label = label
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        self.createdAt = json["createdAt"]?.intValue
        self.mode = json["mode"]?.stringValue
        self.label = json["label"]?.stringValue
    }

 /// Display label used by relay cards / the subagent capsule.
    var displayLabel: String {
        if let label, !label.isEmpty { return label }
        return String(id.prefix(8))
    }

    var isContinuable: Bool { mode == "continuable" }
}

struct NoticeCard: Equatable {
    var title: String
    var text: String
    var kind: String
}

/// 主会话里的「工作目录变更」行（v7 步骤块统一）。
///
/// 来源：`user/message` 且 `data.source.kind == "working-directory"` —— Host 注入的
/// 合成用户消息，正文形如 `The working directory changed from "/old" to "/new".`。
/// 桌面端把它当作一条普通步骤混在步骤块里；App 之前落到 `handleUserMessage` 的
/// default 分支，被渲染成标题为 `working-directory` 的独立通知卡（用户报障：
/// 把一大块步骤块割裂成几块）。现在由 `SessionFlowGrouping` 映射成组内紧凑步骤行。
struct WorkingDirectoryChange: Equatable {
 /// 事件正文原文（解析失败时兜底展示）。
    var text: String
 /// 从正文里解析出的新工作目录；解析不出为 nil。
    var cwd: String?

    init(text: String) {
        self.text = text
        self.cwd = Self.parseCwd(from: text)
    }

 /// 取正文里**最后一个** ASCII 双引号片段作为新工作目录：
 /// `The working directory changed from "/old" to "/new".` → `/new`。
 /// 解析不出（无引号/空串/宿主改了文案）时返回 nil，调用方退回原文展示。
    static func parseCwd(from text: String) -> String? {
        guard let close = text.range(of: "\"", options: .backwards) else { return nil }
        let head = text[..<close.lowerBound]
        guard let open = head.range(of: "\"", options: .backwards) else { return nil }
        let value = String(text[open.upperBound..<close.lowerBound])
        return value.isEmpty ? nil : value
    }
}

struct FileChangeSummary: Equatable {
    var files: [String]
    var additions: Int
    var deletions: Int
}

enum FlowContent: Equatable {
    case user(UserBubble)
    case relay(RelayCard)
    case notice(NoticeCard)
    case reasoning(String)
    case text(String)
    case tool(ToolCallItem)
    case approval(ApprovalItem)
    case plan(todos: [TodoItem], status: String?)
    case goal(objective: String, phase: String?)
    case deliverable(files: [PresentedFile])
    case job(JobItem)
    case error(String)
    case systemNote(String)
    case command(String)
}

struct FlowRow: Identifiable, Equatable {
    var id: String
    var seq: Int
    var content: FlowContent
}

/// 会话详情的完整数据：**一条平铺的消息流**（对齐 DSH 桌面端）。
///
/// `turn/start` / `turn/end` 只是事件流里的逻辑边界，用来推导运行状态与「最近一轮」
/// 的文件变更；它们**不再**对应任何 UI 区块（无 turn 卡片 / 状态点 / 折叠）。
/// 设计决策：App 端删除 turn UI，与桌面端保持一致。
struct SessionFlow: Equatable {
    var rows: [FlowRow] = []
 /// 已加载窗口里最新一轮已 `turn/start` 但尚未 `turn/end`。
    var isRunning: Bool = false
 /// 最新一轮 `workspace/changes` 事件的 seq（/api/changes.summary 精确取数的 key）。
    var latestFileChangeSeq: Int?
 /// 最新一轮工具结果 `meta.diffs` 的客户端聚合（精确取数不可用时的回退）。
    var latestFileChanges: FileChangeSummary?
}

// MARK: - Content block helpers

enum MessageContent {
    static func blocks(from value: JSONValue?) -> [JSONValue] {
        value?.arrayValue ?? []
    }

    static func text(from value: JSONValue?) -> String {
        let blocks = blocks(from: value)
        var pieces: [String] = []
        for block in blocks {
            if block["type"]?.stringValue == "text", let text = block["text"]?.stringValue, !text.isEmpty {
                pieces.append(text)
            }
        }
        return pieces.joined(separator: "\n\n")
    }

    static func images(from value: JSONValue?) -> [ImageRef] {
        blocks(from: value).compactMap { block in
            guard block["type"]?.stringValue == "image" else { return nil }
            return ImageRef.parse(block["attachment"] ?? block)
        }
    }
}
