import SwiftUI

/// 消息区列表**容器后端**选择。
///
/// 背景：会话详情消息区原为 SwiftUI `ScrollView + LazyVStack`；SwiftUI 自撑高行
/// 首次物化必然做全量布局，超长 Markdown 行（1000–1800 字符）一次 50–116ms，
/// 真机连续滚动/快速 fling 出现可感知掉帧。用户批准的唯一例外：**消息区列表容器**
/// 允许 UIKit（循环复用 + 行宿主缓存），行内容仍 SwiftUI（`UIHostingController`
/// 宿主，每行只布局一次），外观/交互必须与现状一致。
///
/// - `uikit`（默认）：UITableView 反转 + cell 循环复用（`SessionMessageUIKitListView`）。
/// - `swiftui`：改造前的 `ScrollView + LazyVStack` 实现
/// （`SessionMessageSwiftUIListView`）。**回退用**，验收通过前保留。
///
/// env 只在 DEBUG 下可改（生产固定走默认后端，避免线上被环境变量意外影响）。
enum SessionMessageListBackend {
 /// 生效后端标识（HUD / 探针可读，便于真机取证）。
    static let selected: String = {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["DSHM_LIST_BACKEND"],
           raw == "swiftui" || raw == "uikit" {
            return raw
        }
        #endif
 // 定稿（设计决策 A，门禁全过后默认启用）：
 // - 模拟器真实手势门禁全过（能滑/能点/能展开/组头定住 0.00pt/
 // 280ms easeOutCubic/AX frame 有效）
 // - 真机 60s 性能采样：稳态 p99=18.7ms、零 >50ms 帧（对照 SwiftUI 容器
 // 130s 长帧 143、p99=75ms）
 // - 真机手指滑动验证：offset 跟手 ±3 万 pt（05:36 evidence）
 // - 全量单测 1114/0
 // 回退开关（DEBUG）：DSHM_LIST_BACKEND=swiftui。
        return "uikit"
    }()

    static var isUIKit: Bool { selected != "swiftui" }
}

/// 会话详情消息区的**后端 façade**：对外接口（init 签名、回调、AX identifier 契约）
/// 与改造前完全一致，`SessionDetailView` 无需感知后端差异。
struct SessionMessageListView: View {
    let items: [SessionMessageItem]
    let sessionId: String
    let attachments: AttachmentStore
    let pendingApprovalCallIds: Set<String>
    let subagentLabels: [String: String]
    let isRunning: Bool
    let historyBatchToken: Int
    let scrollToBottomToken: Int
    var isFillingHistory: Bool = false
    var processGroupModes: [String: ProcessGroupMode] = [:]
    var processGroupWindowHeight: CGFloat = 300
    var currentTurnStartSeq: Int = Int.min
    var onToggleGroupMode: ((String, ProcessGroupMode) -> Void)? = nil
    var onOpenReasoning: ((String) -> Void)? = nil
    let onOpenTool: (ToolCallItem) -> Void
    var onOpenRelay: ((RelayCard) -> Void)? = nil
    let onOpenFileChanges: (TurnFileChanges) -> Void
    let onNearBottomChange: (Bool) -> Void
    let onUserScrolled: () -> Void
 /// DD-02: 列表拖拽/惯性开始（true）与结束（false），用于冻结流式尾部发布。
 /// 只有 UIKit 后端会回调；SwiftUI 回退后端保持现行为（DEBUG 回退用）。
    var onInteractionChange: (Bool) -> Void = { _ in }
    let onFirstContent: () -> Void
    let onRetry: () -> Void

    init(items: [SessionMessageItem],
         sessionId: String,
         attachments: AttachmentStore,
         pendingApprovalCallIds: Set<String>,
         subagentLabels: [String: String],
         isRunning: Bool,
         historyBatchToken: Int,
         scrollToBottomToken: Int,
         isFillingHistory: Bool = false,
         processGroupModes: [String: ProcessGroupMode] = [:],
         processGroupWindowHeight: CGFloat = 300,
         currentTurnStartSeq: Int = Int.min,
         onToggleGroupMode: ((String, ProcessGroupMode) -> Void)? = nil,
         onOpenReasoning: ((String) -> Void)? = nil,
         onOpenTool: @escaping (ToolCallItem) -> Void,
         onOpenRelay: ((RelayCard) -> Void)? = nil,
         onOpenFileChanges: @escaping (TurnFileChanges) -> Void,
         onNearBottomChange: @escaping (Bool) -> Void,
         onUserScrolled: @escaping () -> Void,
         onInteractionChange: @escaping (Bool) -> Void = { _ in },
         onFirstContent: @escaping () -> Void,
         onRetry: @escaping () -> Void) {
        self.items = items
        self.sessionId = sessionId
        self.attachments = attachments
        self.pendingApprovalCallIds = pendingApprovalCallIds
        self.subagentLabels = subagentLabels
        self.isRunning = isRunning
        self.historyBatchToken = historyBatchToken
        self.scrollToBottomToken = scrollToBottomToken
        self.isFillingHistory = isFillingHistory
        self.processGroupModes = processGroupModes
        self.processGroupWindowHeight = processGroupWindowHeight
        self.currentTurnStartSeq = currentTurnStartSeq
        self.onToggleGroupMode = onToggleGroupMode
        self.onOpenReasoning = onOpenReasoning
        self.onOpenTool = onOpenTool
        self.onOpenRelay = onOpenRelay
        self.onOpenFileChanges = onOpenFileChanges
        self.onNearBottomChange = onNearBottomChange
        self.onUserScrolled = onUserScrolled
        self.onInteractionChange = onInteractionChange
        self.onFirstContent = onFirstContent
        self.onRetry = onRetry
    }

    var body: some View {
        Group {
            if SessionMessageListBackend.isUIKit {
                SessionMessageUIKitListView(
                    items: items,
                    sessionId: sessionId,
                    attachments: attachments,
                    pendingApprovalCallIds: pendingApprovalCallIds,
                    subagentLabels: subagentLabels,
                    isRunning: isRunning,
                    historyBatchToken: historyBatchToken,
                    scrollToBottomToken: scrollToBottomToken,
                    isFillingHistory: isFillingHistory,
                    processGroupModes: processGroupModes,
                    processGroupWindowHeight: processGroupWindowHeight,
                    currentTurnStartSeq: currentTurnStartSeq,
                    onToggleGroupMode: onToggleGroupMode,
                    onOpenReasoning: onOpenReasoning,
                    onOpenTool: onOpenTool,
                    onOpenRelay: onOpenRelay,
                    onOpenFileChanges: onOpenFileChanges,
                    onNearBottomChange: onNearBottomChange,
                    onUserScrolled: onUserScrolled,
                    onInteractionChange: onInteractionChange,
                    onFirstContent: onFirstContent,
                    onRetry: onRetry
                )
            } else {
                SessionMessageSwiftUIListView(
                    items: items,
                    sessionId: sessionId,
                    attachments: attachments,
                    pendingApprovalCallIds: pendingApprovalCallIds,
                    subagentLabels: subagentLabels,
                    isRunning: isRunning,
                    historyBatchToken: historyBatchToken,
                    scrollToBottomToken: scrollToBottomToken,
                    isFillingHistory: isFillingHistory,
                    processGroupModes: processGroupModes,
                    processGroupWindowHeight: processGroupWindowHeight,
                    currentTurnStartSeq: currentTurnStartSeq,
                    onToggleGroupMode: onToggleGroupMode,
                    onOpenReasoning: onOpenReasoning,
                    onOpenTool: onOpenTool,
                    onOpenRelay: onOpenRelay,
                    onOpenFileChanges: onOpenFileChanges,
                    onNearBottomChange: onNearBottomChange,
                    onUserScrolled: onUserScrolled,
                    onFirstContent: onFirstContent,
                    onRetry: onRetry
                )
            }
        }
    }
}
