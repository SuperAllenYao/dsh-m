import Foundation
import SwiftUI
import UIKit

/// 消息流的一行（groups 之后的尾部内容也作为可滚动行参与同一列表）。
enum SessionMessageItem: Equatable {
    case group(FlowRowGroup)
    case fileChanges(TurnFileChanges)
    case liveText(String)
    case streamError(String)
    case actionError(String)

    var id: String {
        switch self {
        case .group(let group): return group.id
        case .fileChanges: return "\u{1F}footer-file-changes"
        case .liveText: return "\u{1F}footer-live-text"
        case .streamError: return "\u{1F}footer-stream-error"
        case .actionError: return "\u{1F}footer-action-error"
        }
    }
}

/// 列表变化签名：只在「真的会影响渲染」时触发 items 变更处理，
/// 避免每帧对流式内容做 O(rows) 的全量 Equatable 比较（长会话 rows 可达 3000+）。
struct MessageListSignature: Equatable {
    var count: Int
    var firstID: String?
    var lastID: String?
    var liveText: String?
    var running: Bool
    var newestGroupStepCount: Int
    /// 最新过程组的内容指纹：步骤 id/摘要长度/运行态/失败态。
    /// 步骤内容原地更新（tool 结果到达、reasoning 追加）时行数不变，但不纳入签名
    /// 就会漏掉重绘——「App 是桌面会话的实时镜像」要求思考步骤/工具结果实时出现。
    var newestGroupFingerprint: String
    /// 尾部非 group 行（文件变更卡/错误行）的内容指纹：它们在流式过程中会原地更新，
    /// 但 id 不变；不纳入签名会导致卡片状态（如 404 回退文案）不刷新。
    var tailSignature: String
}

/// 纯逻辑：列表更新策略（可单测，不依赖 UI）。
enum MessageListUpdatePolicy {
    static let nearBottomThreshold: CGFloat = 140

    /// 用户拖拽结束后的「交互窗口」（秒）：只有这个窗口内的几何变化才允许 **unpin**
    /// （用户上滑去读历史）；窗口外（历史补齐 prepend、尾部追加、流式文本、卡片更新
    /// 造成的内容高度变化）一律保持 pinned 原值。
    static let userInteractionWindow: Double = 0.6

    /// 松手后允许 **repin** 的窗口（秒，比 unpin 窗口长）：手指离开后惯性/回弹
    /// 可能把视口带回底部，用户视角仍是「我滚回底部了」。repin 只在明确到底
    /// （near == true）时生效，不会把读历史的人拽回底部。
    static let userRepinWindow: Double = 2.0

    /// 距底部距离 <= 阈值（或内容不足一屏）算「贴底」。
    static func isNearBottom(distanceFromBottom: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        if contentHeight <= viewportHeight + 1 { return true }
        return distanceFromBottom <= nearBottomThreshold
    }

    /// 读历史（不贴底）时：只接收「前置的历史补齐行」，尾部新内容冻结。
    /// 判定条件：已显示行必须是新列表的**严格后缀**（历史补齐只会在前面插入），
    /// 这样尾部追加、中间替换、流式文本变化都不会被误判成补齐。
    static func leadingPrependedItems(displayed: [SessionMessageItem], incoming: [SessionMessageItem]) -> [SessionMessageItem] {
        guard !displayed.isEmpty else { return [] }
        let shownIDs = displayed.map(\.id)
        let incomingIDs = incoming.map(\.id)
        guard incomingIDs.count > shownIDs.count else { return [] }
        guard Array(incomingIDs.suffix(shownIDs.count)) == shownIDs else { return [] }
        return Array(incoming.prefix(incomingIDs.count - shownIDs.count))
    }

    /// 非贴底（读历史）时尾部更新的结果：`changed` 为 false 时调用方可直接返回。
    struct TailUpdate {
        var items: [SessionMessageItem]
        var changed: Bool
    }

    /// 读历史（不贴底）时仍必须应用的尾部变化（2026-10-24 修「数字停在旧值」）：
    ///
    /// 1. 尾部行**内容**原地更新（id 不变、行数与顺序不变）。典型场景：#2 精确数据
    ///    未就绪时卡片先显示工具聚合数字，exact 到达后同一行原地替换——旧实现只接收
    ///    前置历史，尾部内容永远停在首次渲染的值；
    /// 2. `running` 期间把文件变更卡行直接摘掉（#1 卡片只在空闲存在）。尾部行移除
    ///    不会移动当前视口内的行，阅读锚点保持不动。
    ///
    /// 结构变化（历史补齐、尾部增删）不在这里处理，仍由调用方冻结/解冻策略决定。
    static func applyingTrailingUpdates(
        displayed: [SessionMessageItem],
        incoming: [SessionMessageItem],
        running: Bool
    ) -> TailUpdate {
        var result = displayed
        var changed = false
        if running {
            let kept = result.filter { item in
                if case .fileChanges = item { return false }
                return true
            }
            if kept.count != result.count {
                result = kept
                changed = true
            }
        }
        // 已显示行的尾部与 incoming 的**后缀**按 id 对齐（前置历史补齐不会改变尾部
        // 行在 incoming 里的相对位置；running 摘卡后行数可能比 incoming 少）。
        // 结构变化（尾部增删）保持冻结，交给回到贴底时的整体应用。
        if result.count <= incoming.count {
            let offset = incoming.count - result.count
            var index = result.count - 1
            while index >= 0 {
                if case .group = result[index] { break }
                guard result[index].id == incoming[offset + index].id else { break }
                if result[index] != incoming[offset + index] {
                    result[index] = incoming[offset + index]
                    changed = true
                }
                index -= 1
            }
        }
        return TailUpdate(items: result, changed: changed)
    }

    // MARK: - 贴底 pinned 状态机（2026-10-24 真机验收 bug1/bug2）

    /// `pinnedToBottom` 的唯一决策函数（纯函数，可单测）。
    ///
    /// - pinned 表示「视图应始终跟随最新内容」，初值 true；
    /// - 只有**用户自己的滚动**才允许改变它：交互窗口内按实际是否贴底改写
    ///   （拖回底部 → repin；上拖离底超过阈值 → unpin）；
    /// - 交互窗口外保持原值：程序化内容变化（历史补齐 prepend、尾部追加、流式
    ///   live text、卡片数字更新）**绝不允许**把 pinned 改成 false。
    ///
    /// 旧实现把 `isNearBottom` 当状态：内容一长就把贴底判成 false，尾部结构性
    /// 更新从此被冻结（真机表现为新消息/思考步骤不再出现，上滑也回不来）。
    static func nextPinnedToBottom(current: Bool,
                                   isNearBottom: Bool,
                                   userInteractionActive: Bool,
                                   userCanRepin: Bool = false) -> Bool {
        if userInteractionActive { return isNearBottom }
        // unpin 窗口外只允许 repin（用户惯性/回弹到底部），且必须明确贴底。
        if !current, userCanRepin, isNearBottom { return true }
        return current
    }

    /// 冻结态下识别「前置历史补齐」：允许同批还有尾部追加/尾部内容变化（尾部继续
    /// 冻结即可），只要已显示行仍按原顺序连续出现在 incoming 里。
    ///
    /// 旧实现要求 incoming 是 displayed 的**严格后缀**，历史页和 live 事件同帧到达时
    /// 整批被丢弃 → 用户上滑也看不到新补齐的历史。
    static func historyPrefix(displayed: [SessionMessageItem], incoming: [SessionMessageItem]) -> [SessionMessageItem] {
        guard !displayed.isEmpty, incoming.count > displayed.count else { return [] }
        let shownIDs = displayed.map(\.id)
        var searchStart = incoming.startIndex
        while searchStart < incoming.endIndex {
            guard let start = incoming[searchStart...].firstIndex(where: { $0.id == shownIDs[0] }) else { return [] }
            if start + shownIDs.count <= incoming.count {
                var matches = true
                for offset in 0..<shownIDs.count where incoming[start + offset].id != shownIDs[offset] {
                    matches = false
                    break
                }
                if matches { return Array(incoming[..<start]) }
            }
            searchStart = start + 1
        }
        return []
    }

    /// 一次 items 变化的执行计划（纯函数，可单测）。
    struct ItemsChangePlan: Equatable {
        /// 新的 displayedItems。
        var items: [SessionMessageItem]
        /// 是否需要在下一帧贴回底部（pinned 场景，可验证+重试）。
        var stickToBottom: Bool
        /// 是否需要按可见锚点回滚阅读位置（unpinned 的历史补齐）。
        var restoreAnchor: Bool
    }

    /// **App 是桌面会话的实时镜像**：任何一批 items 变化都整批应用。
    /// - 贴底：应用后请求「可验证的贴底」；
    /// - 读历史：尾部 append / 步骤数变化 / live text / 卡片更新在视口下方，
    ///   应用它们不会移动阅读位置，必须永远应用（不再冻结尾部）；
    ///   只有 prepend（历史补齐插到上方）会移动可见行 → 按锚点还原阅读位置。
    static func plan(pinned: Bool,
                     displayed: [SessionMessageItem],
                     incoming: [SessionMessageItem]) -> ItemsChangePlan {
        guard !pinned else {
            return ItemsChangePlan(items: incoming, stickToBottom: true, restoreAnchor: false)
        }
        let restoreAnchor = !historyPrefix(displayed: displayed, incoming: incoming).isEmpty
        return ItemsChangePlan(items: incoming, stickToBottom: false, restoreAnchor: restoreAnchor)
    }

    /// 锚点恢复用的 UnitPoint.y：把「整行可见」的行放回它在视口里的相对偏移处。
    ///
    /// `scrollTo(id, anchor:)` 把行内比例点对上视口同名比例点：
    /// 行 top 落在 f * (viewportHeight - rowHeight)，因此 f = relativeY / (viewportHeight - rowHeight)。
    /// 返回 nil 表示该偏移无法用 UnitPoint 表达（调用方退化为 `.top`）。
    static func anchorFraction(relativeY: CGFloat, rowHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat? {
        guard viewportHeight > 1, rowHeight > 0 else { return nil }
        let span = viewportHeight - rowHeight
        guard abs(span) > 1 else { return nil }
        let fraction = relativeY / span
        guard fraction >= -0.001, fraction <= 1.001 else { return nil }
        return min(1, max(0, fraction))
    }

    // MARK: - 贴底自证/重试（真机大 prepend 后 scrollTo 会静默失败）

    /// 底部哨兵行 maxY 与视口底边的容差（pt）：在此范围内算「已真实贴底」。
    static let stickBottomTolerance: CGFloat = 3

    /// 贴底自证失败后的重试退避（秒）。首拍 scrollTo 常因 LazyVStack 布局尚未提交
    /// 而静默失败；必须等布局 settle 后重滚，直到「底部哨兵行真的进入视口」。
    static let stickRetryDelays: [TimeInterval] = [0.02, 0.05, 0.1, 0.2, 0.4]

    /// 单轮贴底链最长持续时间（秒），防止流式内容持续增长时无限重试。
    static let stickMaxDuration: TimeInterval = 1.5

    /// 最新过程组的内容指纹（纯函数，可单测）：步骤数量不变、但步骤内容原地更新
    /// （tool 结果到达 / reasoning 文本追加 / 运行态变化）时也必须触发重绘。
    static func processFingerprint(_ steps: [ProcessStep]) -> String {
        steps.map { step in
            step.id
                + "|" + String(step.summary.count)
                + (step.isRunning ? "|r" : "")
                + (step.isFailure ? "|f" : "")
        }.joined(separator: "#")
    }

    /// 贴底自证「停滞」判定（纯函数，可单测）：连续两次测量距离没有改善且仍不在
    /// 容差内 → scrollTo 已经无法再靠近（物理极限/内容 inset 偏差），继续重试无意义。
    static func stickStalled(previousDistance: CGFloat, currentDistance: CGFloat) -> Bool {
        guard previousDistance.isFinite, currentDistance.isFinite else { return false }
        guard currentDistance > stickBottomTolerance else { return false }
        return abs(previousDistance - currentDistance) < 0.5
    }

    /// 贴底自证重试决策（纯函数，可单测）：nil = 停止（已贴底/重试耗尽），
    /// 否则为下一次重试延迟。
    /// - isAtBottom：底部哨兵行已进入视口（真实贴底，不是内容高度估算）；
    /// - attempt：本轮已安排的重试次数；elapsed：本轮链已持续时间。
    static func stickRetryDelay(attempt: Int, isAtBottom: Bool, elapsed: TimeInterval) -> TimeInterval? {
        if isAtBottom { return nil }
        guard attempt >= 0, attempt < stickRetryDelays.count, elapsed < stickMaxDuration else { return nil }
        return stickRetryDelays[attempt]
    }
}

/// **原生 SwiftUI 消息列表（v0.2.7 方案 B，2026-10-24）**
///
/// 用 ScrollView + LazyVStack 取代 inverted UITableView：
/// - 展开/收起完全交回 SwiftUI 布局动画（行视图内部 withAnimation + .clipped()），
///   不存在「self-sizing 行高与隐式动画错配」这一类跳变；
/// - 置底跟随、读历史冻结尾部、历史补齐保持阅读位置、强制回底等行为在 SwiftUI 层实现；
/// - 行视图与视觉样式完全复用（FlowRowGroupView / FileChangesCard / MarkdownText 等）。
struct SessionMessageListView: View {
    let items: [SessionMessageItem]
    let sessionId: String
    let attachments: AttachmentStore
    let pendingApprovalCallIds: Set<String>
    let subagentLabels: [String: String]
    let isRunning: Bool
    let historyBatchToken: Int
    /// 递增即请求「强制回到底部」（发送消息 / 答完问答时由上层 +1）。
    let scrollToBottomToken: Int
    /// v0.2.7：过程组显示态覆盖（key = FlowRowGroup.id）；默认态由 isRunning + 是否最新组推导。
    var processGroupModes: [String: ProcessGroupMode] = [:]
    /// 运行中固定窗口高度（页面按会话可视高度 1/3 传入）。
    var processGroupWindowHeight: CGFloat = 300
    /// 本轮起点 seq（最后一条用户消息）。只有本轮内的组才可能是「运行中」组。
    var currentTurnStartSeq: Int = Int.min
    /// 点击过程组 header：回调目标态（页面写入覆盖）。
    var onToggleGroupMode: ((String, ProcessGroupMode) -> Void)? = nil
    var onOpenReasoning: ((String) -> Void)? = nil
    let onOpenTool: (ToolCallItem) -> Void
    let onOpenFileChanges: (TurnFileChanges) -> Void
    let onNearBottomChange: (Bool) -> Void
    let onUserScrolled: () -> Void
    let onFirstContent: () -> Void
    let onRetry: () -> Void

    private static let space = "session-message-list-space"
    private static let bottomID = "__session_list_bottom__"
    private static let rowVerticalPadding: CGFloat = Theme.Spacing.s / 2

    @State private var displayedItems: [SessionMessageItem]
    /// 显式「贴底跟随」状态（初值 true）。只有用户自己的滚动能改它；
    /// 程序化内容变化永远不能把它改成 false（旧实现的卡死根因）。
    @State private var pinnedToBottom = true
    @State private var didInitialBottom = false
    @State private var metrics = ScrollMetrics()
    @State private var lastScrollToBottomToken: Int = 0
    @State private var userHasScrolled = false
    /// 用户是否真的用手滚动过（位移 >= 8pt；轻点不算）。冷启动 autoload 期间
    /// 只有未手动滚动才保留原生底部锚点，避免多批 prepend 让视口漂到旧内容。
    @State private var didUserScroll = false
    /// autoload 内容静默后撤销底部锚点（否则行内展开会被锚点顶上去）。
    @State private var autoloadAnchorExpired = false

    init(items: [SessionMessageItem],
         sessionId: String,
         attachments: AttachmentStore,
         pendingApprovalCallIds: Set<String>,
         subagentLabels: [String: String],
         isRunning: Bool,
         historyBatchToken: Int,
         scrollToBottomToken: Int,
         processGroupModes: [String: ProcessGroupMode] = [:],
         processGroupWindowHeight: CGFloat = 300,
         currentTurnStartSeq: Int = Int.min,
         onToggleGroupMode: ((String, ProcessGroupMode) -> Void)? = nil,
         onOpenReasoning: ((String) -> Void)? = nil,
         onOpenTool: @escaping (ToolCallItem) -> Void,
         onOpenFileChanges: @escaping (TurnFileChanges) -> Void,
         onNearBottomChange: @escaping (Bool) -> Void,
         onUserScrolled: @escaping () -> Void,
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
        self.processGroupModes = processGroupModes
        self.processGroupWindowHeight = processGroupWindowHeight
        self.currentTurnStartSeq = currentTurnStartSeq
        self.onToggleGroupMode = onToggleGroupMode
        self.onOpenReasoning = onOpenReasoning
        self.onOpenTool = onOpenTool
        self.onOpenFileChanges = onOpenFileChanges
        self.onNearBottomChange = onNearBottomChange
        self.onUserScrolled = onUserScrolled
        self.onFirstContent = onFirstContent
        self.onRetry = onRetry
        _displayedItems = State(initialValue: items)
        _lastScrollToBottomToken = State(initialValue: scrollToBottomToken)
    }

    private var signature: MessageListSignature {
        var newestStepCount = 0
        var newestGroupFingerprint = ""
        if case .group(.process(let steps))? = items.last {
            newestStepCount = steps.count
            newestGroupFingerprint = MessageListUpdatePolicy.processFingerprint(steps)
        }
        return MessageListSignature(
            count: items.count,
            firstID: items.first?.id,
            lastID: items.last?.id,
            liveText: liveTextValue,
            running: isRunning,
            newestGroupStepCount: newestStepCount,
            newestGroupFingerprint: newestGroupFingerprint,
            tailSignature: tailSignature
        )
    }

    private var tailSignature: String {
        var parts: [String] = []
        for item in items.reversed() {
            switch item {
            case .group: break
            case .liveText(let text): parts.append("lt:\(text.count)")
            case .streamError(let message): parts.append("se:\(message)")
            case .actionError(let message): parts.append("ae:\(message)")
            case .fileChanges(let changes):
                parts.append("fc:\(changes.source)|\(changes.titleFileCount)|\(changes.files.count)|\(changes.added)|\(changes.deleted)")
            }
        }
        return parts.joined(separator: "#")
    }

    private var liveTextValue: String? {
        for item in items.reversed() {
            if case .liveText(let text) = item { return text }
        }
        return nil
    }

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .background(
                                GeometryReader { geo in
                                    // 全局坐标：named coordinate space 偶发解析失败时
                                    // frame(in:) 会退回 global，混用会导致 offset 失真，
                                    // 所以贴底/锚点判定统一用 global（见 ListViewportFrame）。
                                    Color.clear.preference(
                                        key: ListOffsetPreferenceKey.self,
                                        value: geo.frame(in: .global).minY
                                    )
                                }
                            )

                        ForEach(displayedItems, id: \.id) { item in
                            rowView(item, isNewest: isNewest(item))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.Spacing.pageInset)
                                .padding(.vertical, Self.rowVerticalPadding)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: RowFramePreferenceKey.self,
                                            value: [item.id: geo.frame(in: .global)]
                                        )
                                    }
                                )
                                .id(item.id)
                        }

                        // 底部哨兵行：既用于 scrollTo，也用于「贴底自证」——
                        // 它的视口坐标是「是否真的到底」的唯一可信信号（LazyVStack 的内容
                        // 高度只是已物化行的估算，大 prepend 后不可信）。
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ListBottomFramePreferenceKey.self,
                                        value: geo.frame(in: .global)
                                    )
                                }
                            )
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ListContentHeightPreferenceKey.self,
                                value: geo.size.height
                            )
                        }
                    )
                    // 只读拿到底层 UIScrollView：贴底自证用 contentOffset/contentSize 真值，
                    // 不受 LazyVStack 内容估算与坐标系问题影响。
                    .background(
                        ScrollViewGeometryInstaller(handle: metrics.scrollHandle)
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                    )
                }
                .coordinateSpace(name: Self.space)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ListViewportFramePreferenceKey.self,
                            value: geo.frame(in: .global)
                        )
                    }
                )
                // 冷启动 autoload 防漂移（真机 2026-10-24 残留 1）：用户还没主动滚动过、
                // 视图处于贴底态期间保留原生底部锚点——内容 prepend/append 时系统自动
                // 保持底部，不会出现「前 5-8s 停在旧内容」。用户首次主动滚动后撤销锚点，
                // 交给显式 pinned/锚点逻辑（避免展开行时滚动视图把底部锚住）。
                .defaultScrollAnchor(
                    pinnedToBottom && !didUserScroll && !autoloadAnchorExpired ? .bottom : nil
                )
                .scrollIndicators(.visible)
                .onPreferenceChange(ListViewportFramePreferenceKey.self) { frame in
                    guard !frame.isNull else { return }
                    metrics.viewportFrame = frame
                    metrics.viewportHeight = frame.height
                    recomputeNearBottom(proxy: proxy)
                }
                .onPreferenceChange(ListOffsetPreferenceKey.self) { topMinY in
                    metrics.topMinY = topMinY
                    recomputeNearBottom(proxy: proxy)
                }
                .onPreferenceChange(ListContentHeightPreferenceKey.self) { height in
                    // 只做辅助指标（探针/短内容判定），不参与「是否贴底」的主判定。
                    metrics.contentHeight = height
                    recomputeNearBottom(proxy: proxy)
                }
                .onPreferenceChange(ListBottomFramePreferenceKey.self) { frame in
                    metrics.bottomFrame = frame.isNull ? nil : frame
                    // 底部哨兵行位置变化 = 布局/滚动发生了变化：贴底态下做一次自证，
                    // 没到底就按退避重试（这是真机大 prepend 后不再漂移的关键）。
                    recomputeNearBottom(proxy: proxy)
                }
                .onPreferenceChange(RowFramePreferenceKey.self) { frames in
                    metrics.rowFrames = frames
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            let now = CACurrentMediaTime()
                            metrics.isDragging = true
                            metrics.interactingUntil = now + 0.12
                            markUserScrolledIfNeeded()
                        }
                        .onEnded { value in
                            let now = CACurrentMediaTime()
                            metrics.isDragging = false
                            // 松手后还有减速惯性，给一段「用户正在操作」的静默期。
                            metrics.interactingUntil = now + 0.55
                            // 轻点（无明显位移）不算用户主动滚动：不开放 pin 改写窗口，
                            // 避免「程序化内容刚长出来时点一下」就把贴底状态丢掉。
                            let moved = abs(value.translation.height) >= 8
                            if moved {
                                didUserScroll = true
                                metrics.interactionWindowUntil = now + MessageListUpdatePolicy.userInteractionWindow
                                metrics.repinWindowUntil = now + MessageListUpdatePolicy.userRepinWindow
                                metrics.offsetAtInteractionRelease = currentOffsetY()
                            }
                            // 松手即按松手位置判定 pinned：上拖离底 → unpin（读历史）；拖回底部 → repin。
                            recomputeNearBottom(proxy: proxy, userDecision: moved)
                            // 松手后的惯性/回弹用真值轮询兜住（UIScrollView isDecelerating），
                            // 这样 fling settle 慢于手势结束也能正确 repin/unpin。
                            startInteractionTailPoll(proxy: proxy)
                            if pinnedToBottom { requestStickToBottom(proxy: proxy) }
                        }
                )
                .onAppear {
                    metrics.viewportHeight = outer.size.height
                    DispatchQueue.main.async { scheduleInitialBottomFinish(proxy: proxy) }
                }
                .onChange(of: outer.size.height) { _, height in
                    metrics.viewportHeight = height
                    recomputeNearBottom(proxy: proxy)
                    if pinnedToBottom { requestStickToBottom(proxy: proxy) }
                }
                .onDisappear {
                    metrics.stickChainRunning = false
                }
                .onChange(of: signature) { _, _ in
                    applyItemsChange(proxy: proxy)
                }
                .onChange(of: scrollToBottomToken) { _, token in
                    guard token != lastScrollToBottomToken else { return }
                    lastScrollToBottomToken = token
                    // 上层请求强制回底（发送消息 / 答完问答）：等同用户拖回底部，恢复 pinned。
                    if !pinnedToBottom {
                        pinnedToBottom = true
                        onNearBottomChange(true)
                    }
                    displayedItems = items
                    metrics.interactingUntil = 0
                    metrics.anchorRestoreGeneration += 1
                    pinBottom(proxy: proxy, animated: false)
                    // 首拍 scrollTo 可能因 LazyVStack 布局未提交而静默失败：
                    // 交给「可验证 + 退避重试」的贴底链，直到哨兵行真的进入视口。
                    requestStickToBottom(proxy: proxy)
                }
                .overlay(alignment: .topLeading) { scrollProbeElement }
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func rowView(_ item: SessionMessageItem, isNewest: Bool) -> some View {
        switch item {
        case .group(let group):
            let mode = ProcessGroupModeResolver.resolve(
                isRunning: isNewest,
                override: processGroupModes[group.id]
            )
            FlowRowGroupView(
                group: group,
                sessionId: sessionId,
                attachments: attachments,
                pendingApprovalCallIds: pendingApprovalCallIds,
                subagentLabels: subagentLabels,
                isNewestGroupRunning: isNewest,
                mode: mode,
                windowHeight: processGroupWindowHeight,
                onToggleMode: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        onToggleGroupMode?(group.id, ProcessGroupModeResolver.toggled(mode))
                    }
                },
                onOpenReasoning: onOpenReasoning,
                onOpenTool: onOpenTool
            )
            .equatable()
        case .fileChanges(let changes):
            FileChangesCard(changes: changes) { onOpenFileChanges(changes) }
        case .liveText(let text):
            MarkdownText(text: text)
                .padding(Theme.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                .accessibilityIdentifier("live-assistant-stream")
        case .streamError(let message):
            InlineErrorView(message: message) { onRetry() }
                .accessibilityIdentifier("session-stream-error")
        case .actionError(let message):
            InlineErrorView(message: message)
        }
    }

    private func isNewest(_ item: SessionMessageItem) -> Bool {
        guard case .group(let group) = item else { return false }
        guard isRunning else { return false }
        guard case .process = group else { return false }
        guard case .group(let last)? = items.last else { return false }
        return last.id == group.id
    }

    // MARK: - Behavior

    /// 底层 UIScrollView 的 contentOffset 真值（pt，>=0）。nil = 还没找到 scroll view。
    private func currentOffsetY() -> CGFloat {
        if let scrollView = metrics.scrollHandle.scrollView {
            return max(0, scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        }
        guard !metrics.viewportFrame.isNull else { return 0 }
        return max(0, metrics.viewportFrame.minY - metrics.topMinY)
    }

    /// UIScrollView 真值下「还能往下滚多远」：0 = 已到可滚动极限，<0 = 过滚/内容不足一屏。
    /// 这是贴底自证的唯一真值来源（contentSize/contentOffset 由 UIScrollView 维护，
    /// 不受 LazyVStack 内容估算、named coordinate space 解析失败影响）。
    private func trueDistanceFromBottom() -> CGFloat? {
        guard let scrollView = metrics.scrollHandle.scrollView,
              scrollView.bounds.height > 1 else { return nil }
        let insets = scrollView.adjustedContentInset
        let maxOffsetY = scrollView.contentSize.height + insets.bottom - scrollView.bounds.height
        if maxOffsetY <= -insets.top + 1 { return 0 } // 内容不足一屏
        return maxOffsetY - scrollView.contentOffset.y
    }

    /// 底部哨兵行相对视口底边的距离（全局坐标，nil = 哨兵未物化）。
    private func sentinelDistanceFromBottom() -> CGFloat? {
        guard !metrics.viewportFrame.isNull, let bottom = metrics.bottomFrame else { return nil }
        return bottom.maxY - metrics.viewportFrame.maxY
    }

    /// 距底距离：底部哨兵可见时以它为准（用户真正看到的内容底边），
    /// 未物化时退回 UIScrollView 真值。
    ///
    /// 两个信号在真机上会互相矛盾的两种情况都已覆盖：
    /// - 真值说 0、但哨兵还在视口下方（contentSize 估算落后于实际布局）→ 用哨兵，
    ///   继续重试等布局追上，避免「最后一屏还没出来就以为到底」；
    /// - 真值说还能滚 75pt、但哨兵已在视口底边（contentSize 多了底部 inset/空白）→
    ///   用哨兵判贴底，避免自证永远差一截、重试链空转。
    private func distanceFromBottomForPin() -> CGFloat {
        if let sentinel = sentinelDistanceFromBottom() { return sentinel }
        return trueDistanceFromBottom() ?? .greatestFiniteMagnitude
    }

    /// 「真的贴底」：哨兵已在视口底边（优先）；哨兵未物化时用可滚动极限真值。
    private func isSettledAtBottom() -> Bool {
        if let sentinel = sentinelDistanceFromBottom() {
            return sentinel <= 1
        }
        if let truth = trueDistanceFromBottom() {
            return truth <= 1
        }
        return false
    }

    /// 当前是否处于用户交互（拖拽/惯性）中：UIScrollView 真值优先，退回手势/静默期。
    private func isUserInteractingNow() -> Bool {
        if let scrollView = metrics.scrollHandle.scrollView {
            return scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking
        }
        return metrics.isDragging || CACurrentMediaTime() < metrics.interactingUntil
    }

    /// 判定是否贴底，并维护显式的 `pinnedToBottom`。
    ///
    /// 关键约束（真机验收 bug1/bug2 根因）：只有**用户自己的滚动**才允许把 pinned
    /// 改成 false。程序化内容变化绝不能因此 unpin。
    private func recomputeNearBottom(proxy: ScrollViewProxy, userDecision: Bool = false) {
        guard !metrics.viewportFrame.isNull || metrics.scrollHandle.scrollView != nil else { return }
        // UIScrollView 报 isDragging = 用户真的在拖：冷启动的底部锚点到此撤销
        // （轻点/程序化滚动不会置位，不会误撤）。
        if !didUserScroll,
           let scrollView = metrics.scrollHandle.scrollView,
           scrollView.isDragging || scrollView.isDecelerating {
            didUserScroll = true
        }
        let offset = currentOffsetY()
        let near = distanceFromBottomForPin() <= MessageListUpdatePolicy.nearBottomThreshold
        let now = CACurrentMediaTime()
        // 几何只做辅助：只有「用户自己的滚动」才能改写 pinned。
        // 「松手后 offset 真的继续变化」才算用户驱动（程序化内容增长只改内容高度，
        // 不改 scroll offset，不能因此改 pin）。
        let offsetMoved = metrics.offsetAtInteractionRelease >= 0
            && abs(offset - metrics.offsetAtInteractionRelease) > 8
        let interacting = isUserInteractingNow()
        let userDriven: Bool
        if userDecision {
            userDriven = true
        } else {
            userDriven = !interacting && now < metrics.interactionWindowUntil && offsetMoved
        }
        // repin 窗口更长：手指离开后的惯性/回弹把视口带回底部，用户意图仍是「回到底部」。
        let userCanRepin = !interacting && now < metrics.repinWindowUntil && offsetMoved
        let next = MessageListUpdatePolicy.nextPinnedToBottom(
            current: pinnedToBottom,
            isNearBottom: near,
            userInteractionActive: userDriven,
            userCanRepin: userCanRepin
        )
        if next != pinnedToBottom {
            pinnedToBottom = next
            onNearBottomChange(next)
            scrollDebug("pin -> \(next ? 1 : 0) near=\(near) userDriven=\(userDriven) distance=\(fmt(distanceFromBottomForPin()))")
            if next {
                // 用户拖回底部：立即应用最新内容，并请求可验证的贴底。
                displayedItems = items
                metrics.anchorRestoreGeneration += 1
                requestStickToBottom(proxy: proxy)
            }
            return
        }
        guard pinnedToBottom, !interacting else { return }
        // pinned 场景：内容/布局变化把底部挤出视口 → 请求贴底（可验证 + 退避重试，不改 pinned）。
        if !isSettledAtBottom() { requestStickToBottom(proxy: proxy) }
    }

    /// autoload 内容静默 2.5s 后撤销冷启动底部锚点：保留窗口覆盖多批 prepend，
    /// 静默后回到显式 pinned/锚点逻辑，避免行内展开时被系统底部锚点顶走。
    private func scheduleAutoloadAnchorExpiry() {
        guard !didUserScroll, !autoloadAnchorExpired else { return }
        metrics.quietGeneration += 1
        let generation = metrics.quietGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard generation == self.metrics.quietGeneration, !self.didUserScroll else { return }
            self.autoloadAnchorExpired = true
            self.scrollDebug("anchor expired (autoload content quiet)")
        }
    }

    /// 松手后的交互尾巴轮询：UIScrollView 惯性可能持续 1-2s，用真值（isDecelerating/
    /// contentOffset）在 repin 窗口内每 100ms 重新判定一次，避免「fling settle 晚于手势
    /// 结束 → 永远 repin 不回来」。
    private func startInteractionTailPoll(proxy: ScrollViewProxy) {
        metrics.interactionPollGeneration += 1
        let generation = metrics.interactionPollGeneration
        pollInteractionTail(generation: generation, proxy: proxy, remaining: 25)
    }

    private func pollInteractionTail(generation: Int, proxy: ScrollViewProxy, remaining: Int) {
        guard generation == metrics.interactionPollGeneration, remaining > 0 else { return }
        recomputeNearBottom(proxy: proxy)
        let now = CACurrentMediaTime()
        let settledAndPinned = pinnedToBottom && isSettledAtBottom() && !isUserInteractingNow()
        if now >= metrics.repinWindowUntil || settledAndPinned {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard generation == self.metrics.interactionPollGeneration else { return }
            self.pollInteractionTail(generation: generation, proxy: proxy, remaining: remaining - 1)
        }
    }

    private func markUserScrolledIfNeeded() {
        guard !userHasScrolled else { return }
        userHasScrolled = true
        onUserScrolled()
    }

    /// 首屏结束：等底部锚点把最后一屏布局出来后再撤销锚点（两拍足够覆盖首次布局）。
    private func scheduleInitialBottomFinish(proxy: ScrollViewProxy) {
        guard !didInitialBottom else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard !self.didInitialBottom else { return }
            self.markInitialBottomIfNeeded(proxy: proxy)
        }
    }

    private func markInitialBottomIfNeeded(proxy: ScrollViewProxy) {
        guard !didInitialBottom else { return }
        didInitialBottom = true
        onFirstContent()
        // 撤销底部锚点后补一次「可验证贴底」，保证首屏仍停在最新消息（pinned 初值 true）。
        if pinnedToBottom { requestStickToBottom(proxy: proxy) }
    }

    private func pinBottom(proxy: ScrollViewProxy, animated: Bool, forceJump: Bool = false) {
        guard !displayedItems.isEmpty else { return }
        // 大 prepend 后底部哨兵行可能还没物化，scrollTo(bottomID) 会静默失败；
        // 重试时先滚到最后一条**具体行**（LazyVStack 更容易解析具体 id），再滚哨兵，
        // 同一拍内完成，最终位置仍由哨兵决定。
        if forceJump, let lastID = displayedItems.last?.id, lastID != Self.bottomID {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(lastID, anchor: .bottom) }
            } else {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    private func applyItemsChange(proxy: ScrollViewProxy) {
        let newItems = items
        guard !newItems.isEmpty else { return }
        if !didInitialBottom {
            displayedItems = newItems
            DispatchQueue.main.async { self.scheduleInitialBottomFinish(proxy: proxy) }
            return
        }
        let plan = MessageListUpdatePolicy.plan(
            pinned: pinnedToBottom,
            displayed: displayedItems,
            incoming: newItems
        )
        // 尾部 append / 步骤数变化 / live text / 卡片更新永远应用（App = 桌面会话实时镜像）；
        // 应用在视口下方的变化不会移动阅读位置。
        let changed = plan.items != displayedItems
        if changed { displayedItems = plan.items }
        scrollDebug("apply pinned=\(pinnedToBottom ? 1 : 0) displayed=\(displayedItems.count) incoming=\(newItems.count) stick=\(plan.stickToBottom ? 1 : 0) anchor=\(plan.restoreAnchor ? 1 : 0) \(scrollGeometrySummary())")
        if plan.stickToBottom {
            // pinned：prepend/append 都不允许可见内容向后推 → 可验证贴底（失败退避重试）。
            requestStickToBottom(proxy: proxy)
            scheduleAutoloadAnchorExpiry()
            return
        }
        guard changed, plan.restoreAnchor else { return }
        // unpinned：只有 prepend（历史补齐插到上方）会移动可见行 → 按可见锚点回滚阅读位置。
        guard let anchor = anchorSnapshotForRestore() else {
            // 量不到可见锚点：宁可不滚也不要乱跳（内容已经整批应用，尾部仍是实时的）。
            scrollDebug("anchor missing: skip scroll restore")
            return
        }
        scheduleAnchorRestore(anchor, proxy: proxy)
    }

    /// 记录当前可见锚点：优先取「整行可见」的行（其视口偏移可用 UnitPoint 精确还原）。
    /// 行 frame 是全局坐标，这里统一换算成「相对视口顶部的偏移」。
    private func anchorSnapshotForRestore() -> AnchorSnapshot? {
        guard !metrics.viewportFrame.isNull else { return nil }
        let viewport = metrics.viewportFrame
        let visible = metrics.rowFrames
            .filter { $0.value.maxY > viewport.minY + 1 && $0.value.minY < viewport.maxY - 1 }
            .sorted { $0.value.minY < $1.value.minY }
        guard !visible.isEmpty else { return nil }
        let shownIDs = Set(displayedItems.map(\.id))
        for (id, frame) in visible {
            let relativeY = frame.minY - viewport.minY
            guard shownIDs.contains(id), frame.height > 0 else { continue }
            guard relativeY >= 0, relativeY <= viewport.height - frame.height + 0.5 else { continue }
            return AnchorSnapshot(id: id, relativeY: relativeY, rowHeight: frame.height)
        }
        return nil
    }

    /// 历史页插入后还原读历史的位置：等一帧布局（并让 LazyVStack 物化锚点行）
    /// → scrollTo(锚点, .top) → 下一拍按该行在视口里的相对偏移二次校正。
    private func scheduleAnchorRestore(_ anchor: AnchorSnapshot, proxy: ScrollViewProxy) {
        metrics.anchorRestoreGeneration += 1
        let generation = metrics.anchorRestoreGeneration
        DispatchQueue.main.async {
            self.performAnchorRestore(anchor, generation: generation, proxy: proxy)
        }
    }

    private func performAnchorRestore(_ anchor: AnchorSnapshot, generation: Int, proxy: ScrollViewProxy) {
        guard generation == metrics.anchorRestoreGeneration, !pinnedToBottom else { return }
        // 锚点行已不在新列表里：不滚动（按 contentOffset 变化的猜测补偿会乱跳）。
        guard displayedItems.contains(where: { $0.id == anchor.id }) else { return }
        // 先把锚点行滚进视口（LazyVStack 里该 id 可能尚未物化），同一拍内立刻按行内
        // 相对偏移回位，不跨帧、避免中间帧闪一下。
        proxy.scrollTo(anchor.id, anchor: .top)
        let fraction = MessageListUpdatePolicy.anchorFraction(
            relativeY: anchor.relativeY,
            rowHeight: anchor.rowHeight,
            viewportHeight: metrics.viewportHeight
        )
        if let fraction {
            proxy.scrollTo(anchor.id, anchor: UnitPoint(x: 0, y: fraction))
        }
        // 等一帧核对一次：首拍没物化/被布局吞掉时再校一次（只校一次，不循环、不乱跳）。
        guard let fraction else { return }
        DispatchQueue.main.async {
            guard generation == self.metrics.anchorRestoreGeneration, !self.pinnedToBottom else { return }
            guard !self.metrics.viewportFrame.isNull,
                  let frame = self.metrics.rowFrames[anchor.id] else { return }
            let currentRelativeY = frame.minY - self.metrics.viewportFrame.minY
            guard abs(currentRelativeY - anchor.relativeY) > 2 else { return }
            proxy.scrollTo(anchor.id, anchor: UnitPoint(x: 0, y: fraction))
        }
    }

    // MARK: - 可验证的贴底（自证 + 退避重试）

    /// 请求贴底：启动（或延长）一条贴底链。每个新内容变化都会调用它，
    /// 首拍 scrollTo 若因布局未提交而静默失败，链会按退避重试直到自证到底。
    private func requestStickToBottom(proxy: ScrollViewProxy) {
        guard pinnedToBottom, didInitialBottom else { return }
        let now = CACurrentMediaTime()
        if metrics.stickChainRunning {
            // 已有链条在跑：不重复启动（它会在每次尝试时重新读取实时 metrics 自证）。
            return
        }
        metrics.stickChainRunning = true
        metrics.stickAttempts = 0
        metrics.stickWaitCount = 0
        metrics.stickStartedAt = now
        metrics.lastStickDistance = .greatestFiniteMagnitude
        scrollDebug("stick start displayed=\(displayedItems.count) settled=\(isSettledAtBottom()) \(scrollGeometrySummary())")
        runStickAttempt(proxy: proxy)
    }

    private func runStickAttempt(proxy: ScrollViewProxy) {
        guard pinnedToBottom else {
            metrics.stickChainRunning = false
            scrollDebug("stick stop unpinned")
            return
        }
        guard !metrics.isDragging else {
            // 拖拽中绝不抢滚动；松手会重新判定 pinned 并再次请求贴底。
            metrics.stickChainRunning = false
            scrollDebug("stick stop dragging")
            return
        }
        let now = CACurrentMediaTime()
        let interacting = isUserInteractingNow()
        if interacting || now < metrics.interactingUntil {
            // 松手后的惯性静默期：等它结束再贴，避免和用户滚动抢位置。
            metrics.stickWaitCount += 1
            guard metrics.stickWaitCount <= 40 else {
                metrics.stickChainRunning = false
                scrollDebug("stick stop wait-exhausted")
                return
            }
            let delay = max(0.03, metrics.interactingUntil - now + 0.02)
            scrollDebug("stick wait inertia \(fmtMilliseconds(delay)) interacting=\(interacting)")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [proxy] in
                self.runStickAttempt(proxy: proxy)
            }
            return
        }
        let attempt = metrics.stickAttempts
        let elapsed = max(0, now - metrics.stickStartedAt)
        let distance = distanceFromBottomForPin()
        let settled = isSettledAtBottom()
        // 真机修复：scrollTo 到物理极限后距离不再改善（inset/内容估算偏差），
        // 连续两次相同就判定「已尽力」，停止无意义重试链（避免一直空转）。
        let stalled = MessageListUpdatePolicy.stickStalled(
            previousDistance: metrics.lastStickDistance,
            currentDistance: distance
        )
        metrics.lastStickDistance = distance
        guard let retryDelay = MessageListUpdatePolicy.stickRetryDelay(
            attempt: attempt,
            isAtBottom: settled || stalled,
            elapsed: elapsed
        ) else {
            metrics.stickChainRunning = false
            scrollDebug("stick stop attempt=\(attempt) elapsed=\(fmtMilliseconds(elapsed)) settled=\(settled) stalled=\(stalled) \(scrollGeometrySummary())")
            return
        }
        pinBottom(proxy: proxy, animated: false, forceJump: attempt > 0)
        metrics.stickAttempts = attempt + 1
        scrollDebug("stick pin attempt=\(attempt + 1) settledBefore=\(settled) retryIn=\(fmtMilliseconds(retryDelay)) \(scrollGeometrySummary())")
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [proxy] in
            self.runStickAttempt(proxy: proxy)
        }
    }

    // MARK: - Debug probes (DEBUG only; DSHM_SCROLLDBG / DSHM_E2E)

    private static let scrollDebugEnabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DSHM_SCROLLDBG"] == "1"
        #else
        return false
        #endif
    }()

    /// E2E 隐藏探针门禁：只在 DEBUG + (DSHM_E2E=1 或 DSHM_SCROLLDBG=1) 下渲染。
    private static let scrollProbeEnabled: Bool = {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["DSHM_E2E"] == "1"
            || env["DSHM_SCROLLDBG"] == "1"
            || env["DSHM_DEBUG_STREAM"] == "1"
        #else
        return false
        #endif
    }()

    private func scrollDebug(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard Self.scrollDebugEnabled else { return }
        print("[SCROLLDBG] " + message())
        #endif
    }

    private func fmt(_ value: CGFloat) -> String {
        let tenths = (value * 10).rounded() / 10
        return String(describing: tenths)
    }

    private func fmtMilliseconds(_ value: TimeInterval) -> String {
        String(describing: Int((value * 1000).rounded())) + "ms"
    }

    /// SCROLLDBG 几何快照：topMinY/contentHeight/viewportHeight/bottomMaxY/distance 全量打印，
    /// 真机上可直接对照判断「是否到底」与坐标系是否一致。
    private func scrollGeometrySummary() -> String {
        let viewportMaxY = metrics.viewportFrame.isNull ? -9999 : metrics.viewportFrame.maxY
        return "handle=" + (metrics.scrollHandle.scrollView != nil ? "1" : "0")
            + " topMinY=\(fmt(metrics.topMinY))"
            + " viewportMaxY=\(fmt(viewportMaxY))"
            + " viewportH=\(fmt(metrics.viewportHeight))"
            + " bottomMaxY=\(fmt(metrics.bottomFrame?.maxY ?? -9999))"
            + " distance=\(fmt(distanceFromBottomForPin()))"
            + " offset=\(fmt(currentOffsetY()))"
            + " contentH=\(fmt(metrics.contentHeight))"
    }

    /// e2e-scroll-probe：给 E2E 用例读的视图层实时状态（AX label = 同值）。
    /// 格式：pinned=0|1;displayed=<int>;incoming=<int>;distance=<float>;attempts=<int>;...
    @ViewBuilder
    private var scrollProbeElement: some View {
        #if DEBUG
        if Self.scrollProbeEnabled {
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                let value = scrollProbeValue()
                Text("e2e-scroll-probe")
                    .font(.system(size: 1))
                    .frame(width: 2, height: 2)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("e2e-scroll-probe")
                    .accessibilityLabel(value)
                    .accessibilityValue(value)
            }
        } else {
            EmptyView()
        }
        #else
        EmptyView()
        #endif
    }

    private func scrollProbeValue() -> String {
        let distance = distanceFromBottomForPin()
        let distanceText = distance.isFinite ? fmt(distance) : "-1"
        // 契约顺序：pinned;displayed;incoming;distance;attempts;seq（E2E 按 key 解析，
        // 顺序不敏感；后面是额外诊断字段）。
        return "pinned=" + (pinnedToBottom ? "1" : "0")
            + ";displayed=" + String(displayedItems.count)
            + ";incoming=" + String(items.count)
            + ";distance=" + distanceText
            + ";attempts=" + String(metrics.stickAttempts)
            + ";seq=" + String(latestAppliedSeq())
            + ";dragging=" + (metrics.isDragging ? "1" : "0")
            + ";chain=" + (metrics.stickChainRunning ? "1" : "0")
            + ";bottomMaxY=" + fmt(metrics.bottomFrame?.maxY ?? -9999)
            + ";viewport=" + fmt(metrics.viewportHeight)
            + ";viewportMaxY=" + fmt(metrics.viewportFrame.isNull ? -9999 : metrics.viewportFrame.maxY)
            + ";topMinY=" + fmt(metrics.topMinY)
            + ";offset=" + fmt(currentOffsetY())
            + ";contentH=" + fmt(metrics.contentHeight)
            + ";handle=" + (metrics.scrollHandle.scrollView != nil ? "1" : "0")
    }

    /// 最新已应用事件 seq（给 E2E 断言实时镜像单调递增）。-1 = 当前无可用 seq 行。
    private func latestAppliedSeq() -> Int {
        for item in displayedItems.reversed() {
            switch item {
            case .group(.single(let row)):
                return row.seq
            case .group(.process(let steps)):
                if let seq = steps.last?.seq, seq > 0 { return seq }
                if let seq = steps.first?.seq, seq > 0 { return seq }
            case .fileChanges(let changes):
                if let seq = changes.seq { return seq }
            case .liveText, .streamError, .actionError:
                continue
            }
        }
        return -1
    }
}

/// 读历史时的可见锚点：行 id + 该行在视口中的相对偏移（pt）+ 行高。
private struct AnchorSnapshot {
    let id: String
    let relativeY: CGFloat
    let rowHeight: CGFloat
}

/// 滚动几何（引用类型，避免每帧滚动都触发 SwiftUI body 重算）。
private final class ScrollMetrics {
    /// 列表顶部（0 高哨兵行）的全局 minY；offset = viewportFrame.minY - topMinY。
    var topMinY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    /// ScrollView 自身的全局 frame（贴底/锚点判定统一用全局坐标，避免 named
    /// coordinate space 偶发解析失败时 frame 退回 global 导致 distance 失真）。
    var viewportFrame: CGRect = .null
    var rowFrames: [String: CGRect] = [:]
    var interactingUntil: CFTimeInterval = 0
    /// 用户拖拽中（onChanged 置 true / onEnded 置 false）：拖拽期间不抢滚动、不改 pinned。
    var isDragging = false
    /// 拖拽结束后的交互窗口：只有这个窗口内的几何变化才允许 unpin。
    var interactionWindowUntil: CFTimeInterval = 0
    /// 拖拽结束后的 repin 窗口（比 unpin 窗口长，覆盖惯性/回弹到底部）。
    var repinWindowUntil: CFTimeInterval = 0
    /// 用户松手时的 scroll offset：窗口内只有 offset 真的继续变化才算用户驱动
    /// （程序化内容增长只改 contentHeight，不能因此 unpin）。-1 表示未记录。
    var offsetAtInteractionRelease: CGFloat = -1
    /// 底部哨兵行的全局 frame（nil = 未被 LazyVStack 物化 = 距底很远）。
    var bottomFrame: CGRect?
    /// SwiftUI ScrollView 底层 UIScrollView 的只读句柄：contentOffset/contentSize/
    /// isDragging/isDecelerating 是真值（iOS 17 没有 onScrollGeometryChange）。
    let scrollHandle = ScrollViewGeometryHandle()
    /// 松手后的交互尾巴轮询代数（新一次交互会让旧的轮询失效）。
    var interactionPollGeneration = 0
    /// 冷启动 autoload 内容静默代数（新内容会让旧的静默计时失效）。
    var quietGeneration = 0
    /// 贴底链状态：可验证 + 退避重试，防止大 prepend 后 scrollTo 静默失败漏掉。
    var stickChainRunning = false
    var stickAttempts = 0
    /// 等待用户交互结束的轮次数（防 UIScrollView 标志异常时忙轮询）。
    var stickWaitCount = 0
    var stickStartedAt: CFTimeInterval = 0
    /// 上一次自证测量的距底距离（用于识别「重试不再改善」的停滞）。
    var lastStickDistance: CGFloat = .greatestFiniteMagnitude
    /// 锚点恢复代数：新请求让旧的异步恢复失效。
    var anchorRestoreGeneration = 0
}

/// SwiftUI ScrollView 底层 UIScrollView 的只读句柄（弱引用，不 retain、不改 delegate）。
private final class ScrollViewGeometryHandle {
    weak var scrollView: UIScrollView?
}

/// 挂在列表内容背景上的零尺寸探针：沿 superview 链找到包裹内容的 UIScrollView。
/// 只读坐标/尺寸/交互标志（contentOffset/contentSize/bounds/isDragging/isDecelerating），
/// 不替换 delegate、不写 contentOffset，避免和 SwiftUI 争滚动状态。
private struct ScrollViewGeometryInstaller: UIViewRepresentable {
    let handle: ScrollViewGeometryHandle

    final class HostView: UIView {
        weak var handle: ScrollViewGeometryHandle?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
        }

        func attach() {
            guard let handle else { return }
            if handle.scrollView != nil { return }
            var candidate: UIView? = superview
            while let view = candidate {
                if let scrollView = view as? UIScrollView {
                    handle.scrollView = scrollView
                    return
                }
                candidate = view.superview
            }
        }
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.handle = handle
        // didMoveToWindow 时 superview 链可能还没接到 UIScrollView 上，延迟一拍再找。
        DispatchQueue.main.async { view.attach() }
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        uiView.handle = handle
        uiView.attach()
    }
}

private struct ListOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ListContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 底部哨兵行的全局 frame：贴底自证的唯一可信信号（contentHeight 只是估算）。
/// 哨兵行未物化时 reduce 会回到 defaultValue(.null) → 视为「距底很远」。
private struct ListBottomFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next } else if value.isNull { value = .null }
    }
}

/// ScrollView 自身的全局 frame：与哨兵行/行 frame 同坐标系，用于算
/// distance / offset，避免 named coordinate space 解析失败导致的失真。
private struct ListViewportFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}

private struct RowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
