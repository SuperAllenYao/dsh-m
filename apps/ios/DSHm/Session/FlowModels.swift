import Foundation

// MARK: - Flow row model (built purely from session events; see SessionRowBuilder)

enum TurnStatus: Equatable {
    case running
    case completed
    case aborted
    case interrupted
    case error

    var label: String {
        switch self {
        case .running: return L10n.t("运行中")
        case .completed: return L10n.t("已完成")
        case .aborted: return L10n.t("已中止")
        case .interrupted: return L10n.t("已中断")
        case .error: return L10n.t("出错")
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
}

struct ToolCallItem: Identifiable, Equatable {
    var callId: String?
    var name: String
    var argumentsRaw: String?
    var arguments: [String: JSONValue]
    var result: ToolResultItem?
    var children: [ToolCallItem]
    var turn: Int
    var step: Int?

    var id: String { callId ?? "call-\(name)-\(turn)-\(step ?? 0)" }

    var isRunning: Bool { result == nil }
    var isError: Bool { result?.isError == true }

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

struct TurnSection: Identifiable, Equatable {
    var turn: Int
    var status: TurnStatus
    var summary: String?
    var rows: [FlowRow]
    var stepCount: Int
    var startedAt: Int64?
    var endedAt: Int64?
    var fileChanges: FileChangeSummary?
    /// seq of the turn's `workspace/changes` event (key for /api/changes.summary).
    var fileChangeSeq: Int?

    var id: String { turn == 0 ? "orphan" : "turn-\(turn)" }

    var isRunning: Bool { status == .running }

    var shortSummary: String {
        if let summary, !summary.isEmpty {
            let oneLine = summary.replacingOccurrences(of: "\n", with: " ")
            return oneLine.count > 42 ? String(oneLine.prefix(42)) + "…" : oneLine
        }
        return "Turn \(turn)"
    }
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
