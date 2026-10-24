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

 /// 「用户自己的滚动意图」阈值：用户把内容拖离底部超过该值即视为在读历史
 /// （立即 unpin），与程序化贴底判定用的 140pt nearBottomThreshold 分开。
 /// 旧实现两者共用 140pt：小幅上滑松手后仍判 pinned → 立即 pinBottom 拉回底部
 /// = 用户眼中的「一滑动就跳」。
    static let userUnpinThreshold: CGFloat = 24

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

 /// 读历史（不贴底）时仍必须应用的尾部变化：
 ///
 /// 1. 尾部行**内容**原地更新（id 不变、行数与顺序不变）。典型场景：#2 精确数据
 /// 未就绪时卡片先显示工具聚合数字，exact 到达后同一行原地替换——旧实现只接收
 /// 前置历史，尾部内容永远停在首次渲染的值；
 /// 2. `running` 期间把文件变更卡行直接摘掉（#1 卡片只在空闲存在）。尾部行移除
 /// 不会移动当前视口内的行，阅读锚点保持不动。
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

 // MARK: - 贴底 pinned 状态机

 /// `pinnedToBottom` 的唯一决策函数（纯函数，可单测）。
 ///
 /// - pinned 表示「视图应始终跟随最新内容」，初值 true；
 /// - 只有**用户自己的滚动**才允许改变它：交互窗口内按实际是否贴底改写
 /// （拖回底部 → repin；上拖离底超过阈值 → unpin）；
 /// - 交互窗口外保持原值：程序化内容变化（历史补齐 prepend、尾部追加、流式
 /// live text、卡片数字更新）**绝不允许**把 pinned 改成 false。
 ///
 /// 旧实现把 `isNearBottom` 当状态：内容一长就把贴底判成 false，尾部结构性
 /// 更新从此被冻结。
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
 /// 应用它们不会移动阅读位置，必须永远应用（不再冻结尾部）；
 /// 只有 prepend（历史补齐插到上方）会移动可见行 → 按锚点还原阅读位置。
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

 // MARK: - 贴底自证/重试

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

/// **原生 SwiftUI 消息列表（v0.2.7 方案 B)**
///
/// 用 ScrollView + LazyVStack 取代 inverted UITableView：
/// - 展开/收起完全交回 SwiftUI 布局动画（行视图内部 withAnimation +.clipped()），
/// 不存在「self-sizing 行高与隐式动画错配」这一类跳变；
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

 /// 当前渲染的显示窗口（最近 N 行；不是全量 items）。
    @State private var displayedItems: [SessionMessageItem]
 /// 显示窗口起点行 id：**nil = 默认窗口（最近 N 行，跟随新内容）**；
 /// 非 nil = 用户向上扩展过，窗口固定从该行开始（autoload 更早历史不再插入显示）。
    @State private var windowStartItemID: String?
 /// 显式「贴底跟随」状态（初值 true）：只有「用户手势结束后的 settle 判定」能改它，
 /// 程序化内容变化永远不能把它改成 false（旧实现的卡死根因）。
    @State private var pinnedToBottom = true
 /// 首屏贴底定位是否完成：完成前内容 opacity 0，避免「先显示顶部、再跳到底」。
    @State private var didInitialBottom = false
 /// 首屏定位完成、内容可以显示。
    @State private var isContentReady = false
    @State private var metrics = ScrollMetrics()
    @State private var lastScrollToBottomToken: Int = 0
 /// 用户是否真的用手滚动过（只用来让上层 onUserScrolled 回调一次）。
    @State private var userHasScrolled = false

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
 // 默认窗口 = 最近 N 行；随着新内容/autoload 到达自动跟随（不固定起点）。
        _displayedItems = State(initialValue: MessageListWindowPolicy.initialWindow(items: items))
        _windowStartItemID = State(initialValue: nil)
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

 // 底部哨兵行：首屏贴底定位与「是否真的到底」的真值信号。
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
 // 只读拿到底层 UIScrollView：contentOffset/contentSize/isDragging 是真值，
 // 不受 LazyVStack 内容估算与坐标系问题影响。
                    .background(
                        ScrollViewGeometryInstaller(handle: metrics.scrollHandle) { oldSize, newSize in
                            self.handleContentSizeChange(old: oldSize, new: newSize)
                        }
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                    )
 // 首屏贴底定位完成前不显示：不允许「先显示顶部、再跳到底」。
                    .opacity(isContentReady ? 1 : 0)
                }
                .coordinateSpace(name: Self.space)
                .scrollIndicators(.visible)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ListViewportFramePreferenceKey.self,
                            value: geo.frame(in: .global)
                        )
                    }
                )
                .onPreferenceChange(ListViewportFramePreferenceKey.self) { frame in
                    guard !frame.isNull else { return }
                    metrics.viewportFrame = frame
                    metrics.viewportHeight = frame.height
                    traceGestureOffsetIfNeeded()
                    layoutDidChange(proxy: proxy)
                }
                .onPreferenceChange(ListOffsetPreferenceKey.self) { topMinY in
                    metrics.topMinY = topMinY
                }
                .onPreferenceChange(ListContentHeightPreferenceKey.self) { height in
                    metrics.contentHeight = height
                    traceGestureOffsetIfNeeded()
                    layoutDidChange(proxy: proxy)
                }
                .onPreferenceChange(ListBottomFramePreferenceKey.self) { frame in
                    metrics.bottomFrame = frame.isNull ? nil : frame
                    traceGestureOffsetIfNeeded()
                    layoutDidChange(proxy: proxy)
                }
                .onPreferenceChange(RowFramePreferenceKey.self) { frames in
                    metrics.rowFrames = frames
                    runAnchorVerificationIfNeeded()
                    traceGestureOffsetIfNeeded()
                    layoutDidChange(proxy: proxy)
                }
                .simultaneousGesture(
 // 只用于「手势开始/结束」的边界与 settle 判定：滚动本身仍由 ScrollView 原生
 // 处理，保证 1:1 跟手。
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            let now = CACurrentMediaTime()
                            if !metrics.isDragging {
                                metrics.lastTraceOffset = currentOffsetY()
                                metrics.gestureMaxFrameDelta = 0
                                metrics.gestureFrameCount = 0
                            }
                            metrics.isDragging = true
                            metrics.interactingUntil = now + 0.12
                            metrics.lockAnchor = nil
                            metrics.lockAnchorFixAttempts = 0
                            metrics.pendingPrependHeight = false
                            metrics.compensationSinceTrace = 0
                            markUserScrolledIfNeeded()
                            finishInitialBottomIfInterrupted()
                        }
                        .onEnded { _ in
                            let now = CACurrentMediaTime()
                            metrics.isDragging = false
 // 松手后还有减速惯性：给一段「用户正在操作」的静默期。
                            metrics.interactingUntil = now + 0.55
                            startSettlePoll(proxy: proxy)
                        }
                )
                .onAppear {
                    metrics.viewportHeight = outer.size.height
                    scrollDebug("list onAppear items=\(items.count) displayed=\(displayedItems.count) didInitialBottom=\(didInitialBottom) ready=\(isContentReady)")
                    attemptInitialBottom(proxy: proxy)
                }
                .onChange(of: outer.size.height) { _, height in
                    metrics.viewportHeight = height
                    if didInitialBottom, pinnedToBottom {
                        requestFollow(.immediate)
                        scheduleLayoutCorrection(proxy: proxy)
                    } else {
                        attemptInitialBottom(proxy: proxy)
                    }
                }
                .onChange(of: signature) { _, _ in
                    applyItemsChange(proxy: proxy)
                }
                .onChange(of: scrollToBottomToken) { _, token in
                    guard token != lastScrollToBottomToken else { return }
                    lastScrollToBottomToken = token
 // 上层请求强制回底（发送消息 / 答完问答）：等同用户回到底部。
                    if !pinnedToBottom {
                        pinnedToBottom = true
                        onNearBottomChange(true)
                    }
                    guard didInitialBottom else { return }
                    windowStartItemID = nil
                    displayedItems = MessageListWindowPolicy.initialWindow(items: items)
                    metrics.contentRevision += 1
                    requestFollow(.immediate)
                    scheduleLayoutCorrection(proxy: proxy)
                }
                .onDisappear {
                    metrics.settlePollGeneration += 1
                    metrics.correctionScheduled = false
                    metrics.pendingAnchor = nil
                    metrics.pendingFollow = nil
                    metrics.pendingVerify = nil
                }
                .overlay(alignment: .topLeading) { scrollProbeElement }
                .overlay(alignment: .top) { scrollHUD }
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

 // MARK: - 几何真值

 /// 底层 UIScrollView 的 contentOffset 真值（pt，>=0）。nil = 还没找到 scroll view。
    private func currentOffsetY() -> CGFloat {
        if let scrollView = metrics.scrollHandle.scrollView {
            return max(0, scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        }
        guard !metrics.viewportFrame.isNull else { return 0 }
        return max(0, metrics.viewportFrame.minY - metrics.topMinY)
    }

 /// UIScrollView 真值下「还能往下滚多远」：0 = 已到可滚动极限，<0 = 过滚/内容不足一屏。
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

 /// 距底距离：UIScrollView 真值优先（contentSize 与 LazyVStack 真实布局高度一致），
 /// 底部哨兵 frame 只作兜底——它在 LazyVStack 回收/未刷新时会陈旧（实测 1366/5312pt 假值）。
    private func currentDistanceFromBottom() -> CGFloat {
        if let truth = trueDistanceFromBottom() { return truth }
        return sentinelDistanceFromBottom() ?? .greatestFiniteMagnitude
    }

 /// 当前是否处于用户交互（按压/拖拽/惯性）中。
 /// 必须同时看我们自己的手势状态：手指刚按下、UIScrollView 还没置 isDragging 的那段时间里，
 /// 程序化贴底会把内容偷偷挪走。
    private func isUserInteractingNow() -> Bool {
        if metrics.isDragging || CACurrentMediaTime() < metrics.interactingUntil { return true }
        if let scrollView = metrics.scrollHandle.scrollView {
            return scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking
        }
        return false
    }

    private func markUserScrolledIfNeeded() {
        guard !userHasScrolled else { return }
        userHasScrolled = true
        onUserScrolled()
    }

 // MARK: - items 变化：可视锚点 / 贴底跟随

 /// 内容变化时**不冻结、不阻塞**：整批应用后，要么贴底跟随，要么把「首个完整可见行」
 /// 的相对偏移在布局后按测量差值精确补偿回来（插入多少补多少）。
    private func applyItemsChange(proxy: ScrollViewProxy) {
        let allItems = items
        guard !allItems.isEmpty else { return }
 // 固定起点失效（快照替换/裁剪）时回到默认「最近 N 行」窗口。
        if let startID = windowStartItemID, !allItems.contains(where: { $0.id == startID }) {
            windowStartItemID = nil
        }
        let newItems = windowedItems(from: allItems)
        guard !newItems.isEmpty else { return }
        guard newItems != displayedItems else {
 // 数据变化但显示窗口未变（常见：已满 300 行后 autoload 继续 prepend）：
 // 仍检查一次窗口是否需要向上扩展（用户可能正停在窗口顶部附近）。
            scheduleWindowExpansionCheck(proxy: proxy)
            return
        }
        let scrollView = metrics.scrollHandle.scrollView
 // 1. 内容应用前：判断是否贴底、捕获可视锚点（必须是应用前的布局值）。
 // pinned 语义 = 用户想停在底部：内容变化后就跟随（不再用 12pt 距离二次门限，
 // 否则一次补不干净的残差会让后续 prepend 只做锚点、永远不追回底部）。
        let wasAtBottom = pinnedToBottom && !isUserInteractingNow()
        let anchor = visibleAnchorSnapshot()
        let oldTailIDs = Array(displayedItems.suffix(2)).map(\.id)
        let prepended = !MessageListUpdatePolicy.historyPrefix(displayed: displayedItems, incoming: newItems).isEmpty
        metrics.contentSizeAtApply = scrollView?.contentSize.height ?? -1
        metrics.contentHeightAtApply = metrics.contentHeight
        metrics.lockAnchor = nil
        metrics.lockAnchorFixAttempts = 0
        metrics.pinnedContentSizeFixes = 0
 // 2. 应用数据（不冻结、不排队、不阻塞用户操作）。
        displayedItems = newItems
        metrics.contentRevision += 1
        metrics.tailStable = !oldTailIDs.isEmpty && Array(newItems.suffix(2)).map(\.id) == oldTailIDs
        metrics.pendingPrependHeight = prepended && metrics.tailStable
        metrics.prependCompensationUntil = (prepended && metrics.tailStable) ? CACurrentMediaTime() + 1.5 : 0
        if prepended { metrics.prependCount += 1 }
        metrics.settleFollowUntil = CACurrentMediaTime() + 1.5
        metrics.settleFollowAttempts = 0
        scheduleSettledProbe()
        scrollDebug("apply pinned=\(pinnedToBottom ? 1 : 0) displayed=\(displayedItems.count) incoming=\(newItems.count) atBottom=\(wasAtBottom ? 1 : 0) anchor=\(anchor?.id ?? "-") prepended=\(prepended ? 1 : 0) contentSizeAtApply=\(fmt(metrics.contentSizeAtApply)) \(scrollGeometrySummary())")
        guard didInitialBottom else {
            scheduleLayoutCorrection(proxy: proxy)
            return
        }
 // 3. 计划：
 // - 贴底 + 纯 prepend：由 UIScrollView contentSize 的 KVO 回调在同一布局事务内按
 // 真实增量精确补偿（handleContentSizeChange），这里不排队 anchor/follow，
 // 否则用旧 contentSize 的 follow 会把刚补好的 offset 又拉回去；
 // - 贴底 + 尾部增长 → 平滑跟随新内容（约 150ms 缓动）；
 // - 读历史 → 纯 prepend 同样交给 KVO 补偿；其他结构变化按可视锚点补偿。
        if wasAtBottom {
            metrics.pendingAnchor = nil
            metrics.pendingVerify = nil
            metrics.pendingFollow = (prepended && metrics.tailStable) ? nil : .animated
        } else if let anchor {
            metrics.pendingFollow = nil
            metrics.pendingAnchor = anchor
            metrics.pendingVerify = nil
        } else {
            metrics.pendingAnchor = nil
            metrics.pendingFollow = nil
        }
        scheduleLayoutCorrection(proxy: proxy)
    }

 /// 显示窗口：只渲染「最近 N 行」（默认 300，与本地缓存深度对齐）。
 /// autoload 补进来的更早历史不会进入显示内容 → 用户拖动期间没有上方插入，
 /// 1:1 跟手与「非手势位移 0 像素」都不再受后台加载影响。
    private func windowedItems(from incoming: [SessionMessageItem]) -> [SessionMessageItem] {
        guard !incoming.isEmpty else { return [] }
        if let startID = windowStartItemID,
           let index = incoming.firstIndex(where: { $0.id == startID }) {
            return Array(incoming[index...])
        }
 // 默认窗口：最近 N 行（跟随新内容；autoload 更早历史在未扩展前也先装进窗口，
 // 直到达到 N 行后不再插入显示内容）。
        return MessageListWindowPolicy.initialWindow(items: incoming)
    }

 /// 下一拍检查窗口扩展（布局回调之外的触发点：首屏定位完成/items 变化后）。
    private func scheduleWindowExpansionCheck(proxy: ScrollViewProxy) {
        guard !metrics.windowExpansionScheduled else { return }
        metrics.windowExpansionScheduled = true
        DispatchQueue.main.async {
            self.metrics.windowExpansionScheduled = false
            self.maybeExpandWindow(proxy: proxy)
        }
    }

 /// 用户滚到窗口顶部预留区时向上扩展显示窗口（一次 100 行）。
 /// 扩展是纯 prepend：交给 contentSize KVO 在同一布局事务内按真实增量精确补偿，
 /// 因此触摸中也可以安全扩展（不会把手指位移吃掉）。
    private func maybeExpandWindow(proxy: ScrollViewProxy) {
        guard didInitialBottom, let first = displayedItems.first else { return }
        guard !metrics.viewportFrame.isNull, let firstFrame = metrics.rowFrames[first.id] else { return }
        guard MessageListWindowPolicy.shouldExpand(firstRow: firstFrame, viewport: metrics.viewportFrame) else { return }
        guard let currentStart = items.firstIndex(where: { $0.id == first.id }) else { return }
        let newStart = MessageListWindowPolicy.expandedStartIndex(currentStart: currentStart, itemCount: items.count)
        guard newStart < currentStart else { return }
        guard !metrics.windowExpansionScheduled else { return }
 // 不在 preference 回调里直接改 @State（避免 "Modifying state during view update"）：
 // 下一拍执行，插入高度由 contentSize KVO 在同一布局事务内补偿。
        metrics.windowExpansionScheduled = true
        DispatchQueue.main.async {
            self.metrics.windowExpansionScheduled = false
            self.performWindowExpansion(newStart: newStart, proxy: proxy)
        }
    }

    private func performWindowExpansion(newStart: Int, proxy: ScrollViewProxy) {
        guard newStart >= 0, newStart < items.count else { return }
        let expanded = Array(items[newStart...])
        guard expanded != displayedItems else { return }
        windowStartItemID = items[newStart].id
 // 纯 prepend：不排队 anchor/follow，KVO 同帧补偿处理插入高度。
        metrics.pendingAnchor = nil
        metrics.pendingFollow = nil
        metrics.pendingVerify = nil
        metrics.pendingPrependHeight = true
        metrics.tailStable = true
        metrics.prependCompensationUntil = CACurrentMediaTime() + 1.5
        metrics.contentRevision += 1
        metrics.prependCount += 1
        displayedItems = expanded
        scrollDebug("window expand start=\(newStart) displayed=\(expanded.count)/\(items.count)")
        scheduleLayoutCorrection(proxy: proxy)
    }

 /// 内容应用前的「可视锚点」：首个完整可见行（没有则取第一个与视口相交的行）。
    private func visibleAnchorSnapshot() -> AnchorSnapshot? {
        guard !metrics.viewportFrame.isNull else { return nil }
        let visibleIDs = Set(displayedItems.map(\.id))
        guard let candidate = ScrollFollowPolicy.anchorCandidate(
            rowFrames: metrics.rowFrames,
            viewport: metrics.viewportFrame,
            visibleIDs: visibleIDs
        ) else { return nil }
        return AnchorSnapshot(id: candidate.id, relativeY: candidate.relativeY, rowHeight: candidate.rowHeight)
    }

    private func requestFollow(_ mode: FollowMode) {
        metrics.pendingAnchor = nil
        metrics.pendingVerify = nil
        metrics.pendingFollow = mode
        metrics.pendingPrependHeight = false
    }

 // MARK: - 布局后校正（可视锚点精确补偿 / 贴底跟随）

 /// 每次布局/滚动几何变化后调用：
 /// - 首屏：推进贴底定位；
 /// - 有 pending：优先在**同一 runloop 内**完成精确补偿（同一 CATransaction，不产生可见跳动）；
 /// 量不到（大 prepend 后锚点行被 LazyVStack 回收）才退到下一拍兜底。
    private func layoutDidChange(proxy: ScrollViewProxy) {
        if !didInitialBottom {
            syncLayoutBaseline()
            attemptInitialBottom(proxy: proxy)
            return
        }
        if metrics.pendingAnchor != nil || metrics.pendingFollow != nil {
 // 同一 runloop（同一 CATransaction）内完成补偿：行 frame / contentSize 都量不到时
 // 用 scrollTo 兜底（同样是同步的，不跨帧，不产生可见跳动）。
            let didSynchronously = performPendingCorrection(proxy: proxy, allowFallback: true, allowScrollToFallback: true)
            if didSynchronously {
                metrics.syncCorrectionCount += 1
            } else {
                scheduleLayoutCorrection(proxy: proxy)
            }
            syncLayoutBaseline()
            return
        }
 // 无 pending：处理「布局完成后内容高度继续微调」造成的位移（事件驱动、有界）。
 // 贴底态的 growth 已由 contentSize KVO 同帧补偿，这里只处理读历史时的锚点锁定。
        maybeExpandWindow(proxy: proxy)
        applyIdleLayoutGrowthCompensation()
        syncLayoutBaseline()
        settlePinnedBottomIfNeeded(proxy: proxy)
        trackIdleBottomStability()
    }

 /// 所有程序化滚动都走这里：把「本帧我们主动改动的 offset」计入 compensationSinceTrace，
 /// 逐帧取证（gestureMaxFrameDelta）会扣掉这部分，只统计**无法归因**的位移（方案 A 允许
 /// 手势期间的精确补偿，不允许的是无归因跳变）。
    private func programmaticOffset(delta: CGFloat, scrollView: UIScrollView) {
        guard abs(delta) > 0.0001 else { return }
        metrics.compensationSinceTrace += delta
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: scrollView.contentOffset.y + delta),
            animated: false
        )
 // 逐帧取证基线同步前移：这次位移是我们主动做的精确补偿，不能算进「无归因跳变」。
        if metrics.lastTraceOffset >= 0 { metrics.lastTraceOffset += delta }
    }

    private func programmaticOffset(to targetY: CGFloat, scrollView: UIScrollView) {
        programmaticOffset(delta: targetY - scrollView.contentOffset.y, scrollView: scrollView)
    }

 /// UIScrollView contentSize 的 KVO 同步回调：SwiftUI 在布局中设置 contentSize 的那一刻
 /// 就会触发，是「上方插入高度」最早、最精确、与手指完全无关的测量。
 /// - 贴底（且无手势）：内容末端移动多少，offset 跟随多少（含尾部增长/估值修正）；
 /// - 读历史 / 手势中：只有「纯 prepend」才把内容尺寸增量当作上方插入高度，精确补偿。
 /// 在设置 contentSize 的同一布局事务内执行，不跨帧，因此不会出现「补偿晚一帧 = 可见跳动」。
    private func handleContentSizeChange(old: CGSize, new: CGSize) {
        guard didInitialBottom else { return }
        guard let scrollView = metrics.scrollHandle.scrollView else { return }
        let delta = new.height - old.height
        guard abs(delta) > ScrollFollowPolicy.compensationTolerance, abs(delta) < 200_000 else { return }
        if pinnedToBottom, !isUserInteractingNow() {
            programmaticOffset(delta: delta, scrollView: scrollView)
            metrics.contentSizeKVOCompensations += 1
            metrics.pendingPrependHeight = false
            scrollDebug("kvo follow delta=\(fmt(delta)) \(scrollGeometrySummary())")
            return
        }
 // 读历史 / 手势中：只有纯 prepend 才适用（尾部增长不会移动上方可见内容）。
 // 注意不能只补偿「第一次」contentSize 变化：真机实测 82 行批量插入只触发 2 次 KVO 回调，
 // 之后 LazyVStack 行高估算/滚动中物化还会继续改 contentSize（3s 内共欠 6832pt）。
 // 因此在 prepend 补偿窗口内，每一次 contentSize 变化都要按增量补回。
        let inPrependWindow = metrics.pendingPrependHeight || CACurrentMediaTime() < metrics.prependCompensationUntil
        guard inPrependWindow, metrics.tailStable else { return }
        let wasInteracting = metrics.isDragging || CACurrentMediaTime() < metrics.interactingUntil
        programmaticOffset(delta: delta, scrollView: scrollView)
        metrics.contentSizeKVOCompensations += 1
        if wasInteracting { metrics.anchorCorrectionDuringGesture += 1 }
        if let anchor = metrics.pendingAnchor {
 // 插入高度已精确补回：锚点行回到原相对位置，后续布局成长按它继续锁定。
            metrics.lockAnchor = anchor
            metrics.lockAnchorFixAttempts = 0
            metrics.pendingAnchor = nil
        }
        metrics.pendingPrependHeight = false
        scrollDebug("kvo prepend delta=\(fmt(delta)) \(scrollGeometrySummary())")
    }

 /// 记录当前布局的内容高度基线（只有真的变化才允许做一次成长补偿，避免 idle 自滚）。
    private func syncLayoutBaseline() {
        guard let scrollView = metrics.scrollHandle.scrollView else { return }
        metrics.lastLayoutContentSize = scrollView.contentSize.height
    }

 /// 布局完成后内容高度仍会微调（LazyVStack 估值/末行高度）：
 /// - pinned：底部语义 = 视口跟着内容末端走 → offset 同量补偿（保持贴底、可见内容不动）；
 /// - 读历史：用「可视锚点行」的真实 frame 差值补偿（与手指无关，且尾部增长不会触发）。
 /// 每次真实高度变化只补一次（事件驱动），高度稳定后不再滚动。
    private func applyIdleLayoutGrowthCompensation() {
        guard let scrollView = metrics.scrollHandle.scrollView, scrollView.bounds.height > 1 else { return }
        guard !isUserInteractingNow() else { return }
        let previous = metrics.lastLayoutContentSize
        guard previous > 0 else { return }
        let contentSize = scrollView.contentSize.height
        let grown = contentSize - previous
        guard abs(grown) > 1.0 else { return }
 // 贴底时的内容尺寸增长已由 KVO 同帧补偿（handleContentSizeChange），这里不重复。
        if pinnedToBottom { return }
        guard let lock = metrics.lockAnchor,
              metrics.lockAnchorFixAttempts < 12,
              !metrics.viewportFrame.isNull,
              let frame = metrics.rowFrames[lock.id] else { return }
        let currentRelativeY = frame.minY - metrics.viewportFrame.minY
        if let delta = ScrollFollowPolicy.compensationDelta(oldRelativeY: lock.relativeY, newRelativeY: currentRelativeY) {
            programmaticOffset(delta: delta, scrollView: scrollView)
            metrics.lockAnchorFixAttempts += 1
            metrics.lockAnchorFixes += 1
            scrollDebug("growth lock delta=\(fmt(delta)) \(scrollGeometrySummary())")
        }
    }

 /// 兜底校正（异步一拍）：只在大 prepend 且同一 runloop 量不到锚点行时用到。
    private func scheduleLayoutCorrection(proxy: ScrollViewProxy) {
        guard !metrics.correctionScheduled else { return }
        metrics.correctionScheduled = true
        DispatchQueue.main.async {
            self.metrics.correctionScheduled = false
            guard self.metrics.pendingAnchor != nil || self.metrics.pendingFollow != nil else { return }
            if self.metrics.pendingPrependHeight {
 // KVO 没来（contentSize 未变）：宽限两拍后退回旧测量路径，避免 pending 永久悬挂。
                self.metrics.prependKVOGraceAttempts += 1
                if self.metrics.prependKVOGraceAttempts > 2 { self.metrics.pendingPrependHeight = false }
            }
            if self.performPendingCorrection(proxy: proxy, allowFallback: true, allowScrollToFallback: true) {
                self.metrics.asyncCorrectionCount += 1
            }
        }
    }

    @discardableResult
    private func performPendingCorrection(proxy: ScrollViewProxy, allowFallback: Bool, allowScrollToFallback: Bool) -> Bool {
        guard let scrollView = metrics.scrollHandle.scrollView, scrollView.bounds.height > 1 else { return false }
        var didWork = false
        if let anchor = metrics.pendingAnchor {
 // 顺序不变量：锚点还没补偿完，绝不能先做贴底跟随（否则 follow 会把
 // 「上方插入的高度」当成滚动距离播一次可见动画 = 静置时自己滚动）。
            guard applyAnchorCorrection(anchor, scrollView: scrollView, proxy: proxy, allowFallback: allowFallback, allowScrollToFallback: allowScrollToFallback) else {
                return didWork
            }
            metrics.pendingAnchor = nil
            if !pinnedToBottom {
 // 读历史：补偿完成后把该行记为「内容锁定锚点」，后续布局成长按真实 frame 继续锁。
                metrics.lockAnchor = anchor
                metrics.lockAnchorFixAttempts = 0
            }
            didWork = true
        }
        if let follow = metrics.pendingFollow {
            if applyFollowCorrection(follow, scrollView: scrollView) {
                metrics.pendingFollow = nil
                didWork = true
            }
        }
        return didWork
    }

 /// 可视锚点补偿：把锚点行放回它在内容变化前的视口相对位置。
 /// 返回 true = 本次已经处理完（或已交回布局等待），false = 当前量不到、等下一拍。
    private func applyAnchorCorrection(_ anchor: AnchorSnapshot, scrollView: UIScrollView, proxy: ScrollViewProxy, allowFallback: Bool, allowScrollToFallback: Bool) -> Bool {
 // 锚点行已不在新列表里：不滚动（按猜测补偿会乱跳）。
        guard displayedItems.contains(where: { $0.id == anchor.id }) else { return true }
 // 手势/惯性期间**禁止用行 frame 差分**：拖动本身在改变行 frame，差分会把手指位移
 // 一起「补偿」掉。
 // 手势期间只用与手指无关的「内容高度增长量」补偿上方插入。
        let interacting = isUserInteractingNow()
 // 0) 纯 prepend 的插入高度由 contentSize KVO 在同一布局事务内精确补偿
 // （handleContentSizeChange）。这里直接让位：不要用第二套测量重复补偿。
        if metrics.pendingPrependHeight, metrics.tailStable { return false }
 // 手势/惯性期间：行 frame 差分不可用、contentSize 本拍也常常还没更新 → 用 scrollTo
 // 同步把「锚点行 + 行内偏移」放回原处（scrollTo 只需布局，不需要高度测量；同步执行，
 // 同一 CATransaction 内生效，不跨帧，不会出现一帧整页位移）。
        if interacting, allowScrollToFallback {
            restoreAnchorByScrollTo(anchor, proxy: proxy, reason: "gesture")
            return true
        }
 // 1) 锚点行仍在布局里且不在手势中：按「相对偏移差」精确补偿（同一 runloop，插入多少补多少）。
        if !interacting, !metrics.viewportFrame.isNull, let frame = metrics.rowFrames[anchor.id] {
            let newRelativeY = frame.minY - metrics.viewportFrame.minY
            if let delta = ScrollFollowPolicy.compensationDelta(oldRelativeY: anchor.relativeY, newRelativeY: newRelativeY) {
                programmaticOffset(delta: delta, scrollView: scrollView)
                metrics.anchorCorrectionCount += 1
                metrics.lastAnchorDelta = delta
                scrollDebug("anchor compensate(rowFrame) delta=\(fmt(delta)) \(scrollGeometrySummary())")
            }
            return true
        }
        guard allowFallback else { return false }
 // 2) 大 prepend 后锚点行被 LazyVStack 回收：用内容高度的增长量作为「上方插入高度」补偿。
 // 仅在尾部行未变（纯 prepend）时成立；否则交回第 3 条兜底。
        let newContentSize = scrollView.contentSize.height
        let oldContentSize = metrics.contentSizeAtApply
        if metrics.tailStable, oldContentSize > 0, newContentSize > oldContentSize {
            let delta = newContentSize - oldContentSize
            if abs(delta) > ScrollFollowPolicy.compensationTolerance {
                programmaticOffset(delta: delta, scrollView: scrollView)
                metrics.anchorContentSizeCount += 1
                metrics.lastAnchorDelta = delta
                if metrics.isDragging || CACurrentMediaTime() < metrics.interactingUntil {
                    metrics.anchorCorrectionDuringGesture += 1
                }
                scrollDebug("anchor compensate(contentSize) delta=\(fmt(delta)) \(scrollGeometrySummary())")
            }
 // 内容尺寸是 LazyVStack 估算：下一拍按锚点行的真实 frame 复核一次残差。
            scheduleAnchorVerification(anchor)
            return true
        }
        guard allowScrollToFallback else { return false }
 // 3) 兜底：scrollTo 锚点行 + 行内比例偏移（同步执行，同一 CATransaction 内生效）。
        restoreAnchorByScrollTo(anchor, proxy: proxy, reason: "fallback")
        return true
    }

 /// 用 scrollTo 把锚点行放回内容变化前的视口相对位置（同步；不依赖高度测量）。
    private func restoreAnchorByScrollTo(_ anchor: AnchorSnapshot, proxy: ScrollViewProxy, reason: String) {
        proxy.scrollTo(anchor.id, anchor: .top)
        if let fraction = MessageListUpdatePolicy.anchorFraction(
            relativeY: anchor.relativeY,
            rowHeight: anchor.rowHeight,
            viewportHeight: metrics.viewportHeight
        ) {
            proxy.scrollTo(anchor.id, anchor: UnitPoint(x: 0, y: fraction))
        }
        metrics.anchorScrollToCount += 1
        if metrics.isDragging || CACurrentMediaTime() < metrics.interactingUntil {
            metrics.anchorCorrectionDuringGesture += 1
        }
 // scrollTo 是 SwiftUI 内部的滚动请求，拿不到精确 delta：作废逐帧基线，避免把这次
 // 主动补偿误记成「无归因跳变」（真要发生可见跳变，截图/元素 frame 断言仍会失败）。
        metrics.lastTraceOffset = -1
        scrollDebug("anchor compensate(scrollTo,\(reason)) relativeY=\(fmt(anchor.relativeY)) \(scrollGeometrySummary())")
        scheduleAnchorVerification(anchor)
    }

 /// 大 prepend 兜底补偿后按锚点行真实 frame 复核残差（只复核一次，不循环）。
    private func scheduleAnchorVerification(_ anchor: AnchorSnapshot) {
        metrics.pendingVerify = anchor
        guard !metrics.verifyScheduled else { return }
        metrics.verifyScheduled = true
        DispatchQueue.main.async {
            self.metrics.verifyScheduled = false
            self.runAnchorVerificationIfNeeded()
        }
    }

    private func runAnchorVerificationIfNeeded() {
        guard let verify = metrics.pendingVerify else { return }
        guard !metrics.viewportFrame.isNull,
              let frame = metrics.rowFrames[verify.id],
              let scrollView = metrics.scrollHandle.scrollView else { return }
        let currentRelativeY = frame.minY - metrics.viewportFrame.minY
        if let delta = ScrollFollowPolicy.compensationDelta(oldRelativeY: verify.relativeY, newRelativeY: currentRelativeY) {
            programmaticOffset(delta: delta, scrollView: scrollView)
            metrics.anchorResidualFixes += 1
            metrics.lastAnchorResidual = currentRelativeY - verify.relativeY
            scrollDebug("anchor verify residual=\(fmt(delta)) fixes=\(metrics.anchorResidualFixes)")
        } else {
            metrics.lastAnchorResidual = currentRelativeY - verify.relativeY
        }
        metrics.pendingVerify = nil
    }

 /// 贴底跟随：内容底部对齐视口底部；距离大时 150ms 缓动，距离小（<60pt）直接定位。
    @discardableResult
    private func applyFollowCorrection(_ mode: FollowMode, scrollView: UIScrollView) -> Bool {
 // 跟随已经定义了「应处的位置」：之前 contentSize 兜底补偿留下的残差复核必须作废，
 // 否则复核会按旧锚点把视口从底部再挪走。
        metrics.pendingVerify = nil
        let insets = scrollView.adjustedContentInset
        let target = ScrollFollowPolicy.followTargetOffset(
            contentHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height,
            bottomInset: insets.bottom
        )
        let distance = ScrollFollowPolicy.followDistance(currentOffset: scrollView.contentOffset.y, targetOffset: target)
        guard abs(distance) > ScrollFollowPolicy.compensationTolerance else { return true }
        let targetPoint = CGPoint(x: scrollView.contentOffset.x, y: target)
        switch mode {
        case .immediate:
            programmaticOffset(to: targetPoint.y, scrollView: scrollView)
        case .animated:
            if abs(distance) > ScrollFollowPolicy.animatedFollowThreshold {
                metrics.compensationSinceTrace += distance
                UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                    scrollView.setContentOffset(targetPoint, animated: false)
                }
            } else {
                programmaticOffset(to: targetPoint.y, scrollView: scrollView)
            }
        }
        metrics.followCount += 1
        scrollDebug("follow mode=\(mode == .animated ? "anim" : "now") distance=\(fmt(distance)) target=\(fmt(target)) \(scrollGeometrySummary())")
        return true
    }

 // MARK: - 首屏贴底定位（无定时器，只由布局回调推进）

    private func attemptInitialBottom(proxy: ScrollViewProxy) {
        guard !didInitialBottom, !metrics.initialAttemptPending else { return }
        metrics.initialAttemptPending = true
        DispatchQueue.main.async {
            self.metrics.initialAttemptPending = false
            self.performInitialBottomAttempt(proxy: proxy)
            guard !self.didInitialBottom else { return }
 // 无定时器：每次布局/下一拍继续推进（次数由 attempts / handle 未命中上限约束）。
            if self.metrics.scrollHandle.scrollView == nil {
                self.metrics.initialHandleMisses += 1
                if self.metrics.initialHandleMisses < 90 {
                    self.attemptInitialBottom(proxy: proxy)
                } else {
 // 底层 scroll view 一直找不到：宁可显示内容，也不能无限隐藏。
                    self.finishInitialBottom()
                }
            } else {
                self.attemptInitialBottom(proxy: proxy)
            }
        }
    }

    private func performInitialBottomAttempt(proxy: ScrollViewProxy) {
        guard !didInitialBottom else { return }
        guard let scrollView = metrics.scrollHandle.scrollView, scrollView.bounds.height > 1 else { return }
        if isUserInteractingNow() {
            finishInitialBottomIfInterrupted()
            return
        }
        if let sentinel = sentinelDistanceFromBottom(), sentinel <= ScrollFollowPolicy.initialBottomTolerance {
            finishInitialBottom()
            return
        }
        metrics.initialBottomAttempts += 1
        if metrics.initialBottomAttempts <= 2 {
 // 先用 contentSize 真值直接定位；多数情况下一次到位（首屏缓存窗口已贴底）。
            let insets = scrollView.adjustedContentInset
            let target = ScrollFollowPolicy.followTargetOffset(
                contentHeight: scrollView.contentSize.height,
                viewportHeight: scrollView.bounds.height,
                bottomInset: insets.bottom
            )
            if abs(scrollView.contentOffset.y - target) > 0.5 {
                programmaticOffset(to: target, scrollView: scrollView)
            }
        } else {
 // LazyVStack 首帧只物化顶部行：scrollTo 哨兵行强制到底，再靠下一拍布局校准。
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
        scrollDebug("initial bottom attempt=\(metrics.initialBottomAttempts) distance=\(fmt(currentDistanceFromBottom())) \(scrollGeometrySummary())")
        if metrics.initialBottomAttempts >= ScrollFollowPolicy.initialBottomMaxAttempts {
 // 兜底：绝不无限隐藏内容（宁可见、位置稍差，也不能像断网）。
            finishInitialBottom()
        }
    }

 /// 用户已经接管滚动：不再强行贴底（避免和手势抢位置），直接显示当前内容。
    private func finishInitialBottomIfInterrupted() {
        guard !didInitialBottom else { return }
        scrollDebug("initial bottom interrupted by touch")
        finishInitialBottom()
    }

    private func finishInitialBottom() {
        guard !didInitialBottom else { return }
        let distance = currentDistanceFromBottom()
        didInitialBottom = true
        isContentReady = true
        metrics.pendingAnchor = nil
        if pinnedToBottom, distance.isFinite, distance > 0.5, let scrollView = metrics.scrollHandle.scrollView {
            _ = applyFollowCorrection(.immediate, scrollView: scrollView)
        }
        metrics.settleFollowUntil = CACurrentMediaTime() + 1.5
        metrics.settleFollowAttempts = 0
        metrics.lockAnchor = nil
        metrics.pendingPrependHeight = false
        scheduleSettledProbe()
        syncLayoutBaseline()
        scrollDebug("initial bottom done distance=\(fmt(distance)) attempts=\(metrics.initialBottomAttempts) \(scrollGeometrySummary())")
        onFirstContent()
    }

 // MARK: - 用户手势结束后的 settle 判定（pinned 只在这里改写）

 /// 松手后的 settle 轮询：等 UIScrollView 的惯性/回弹结束，按「距底 <= 12pt」判定 pinned；
 /// 判定后立即结束轮询（不常驻、不会在 idle 时自己滚动）。
    private func startSettlePoll(proxy: ScrollViewProxy) {
        metrics.settlePollGeneration += 1
        let generation = metrics.settlePollGeneration
        pollSettle(generation: generation, remaining: 20)
    }

    private func pollSettle(generation: Int, remaining: Int) {
        guard generation == metrics.settlePollGeneration, remaining > 0 else { return }
        if isUserInteractingNow() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard generation == self.metrics.settlePollGeneration else { return }
                self.pollSettle(generation: generation, remaining: remaining - 1)
            }
            return
        }
        let distance = currentDistanceFromBottom()
        let next = ScrollFollowPolicy.pinnedAfterGesture(distanceFromBottom: distance)
        if next != pinnedToBottom {
            pinnedToBottom = next
            if !next { metrics.pinnedBaselineActive = false }
            onNearBottomChange(next)
            scrollDebug("settle pin=\(next ? 1 : 0) distance=\(fmt(distance))")
        }
        if next, let scrollView = metrics.scrollHandle.scrollView, distance.isFinite, distance > 0.5 {
 // 用户在底部松手：贴回底部（距离 <= tolerance，本身就是「用户想回到底部」）。
            _ = applyFollowCorrection(.immediate, scrollView: scrollView)
        }
    }

 // MARK: - 诊断/取证

 /// 手势窗口内的逐帧 offset 位移（E2E 用它断言「1:1 跟手、无跳变帧」）。
    private func traceGestureOffsetIfNeeded() {
 // 诊断：用户拖动时 UIScrollView 的 pan 是否真的接管了（区分「触摸被丢」与「被跟随吸走」）。
        if let sv = metrics.scrollHandle.scrollView {
            if sv.isDragging { metrics.panSeen = true }
            if sv.isTracking { metrics.panTrackingSeen = true }
            if sv.isDecelerating { metrics.panDecelSeen = true }
        }
        let offset = currentOffsetY()
        if metrics.lastTraceOffset < 0 {
            metrics.lastTraceOffset = offset
            return
        }
 // programmaticOffset 已把主动补偿并入 lastTraceOffset，这里的 delta 是「无法归因」的位移。
        let delta = offset - metrics.lastTraceOffset
        metrics.compensationSinceTrace = 0
        guard abs(delta) > 0.5 else { metrics.lastTraceOffset = offset; return }
        let now = CACurrentMediaTime()
        let inGestureWindow = metrics.isDragging
            || now < metrics.interactingUntil
            || (metrics.scrollHandle.scrollView?.isDragging ?? false)
            || (metrics.scrollHandle.scrollView?.isDecelerating ?? false)
        if inGestureWindow {
            metrics.gestureFrameCount += 1
            if abs(delta) > metrics.gestureMaxFrameDelta { metrics.gestureMaxFrameDelta = abs(delta) }
        }
        metrics.lastTraceOffset = offset
    }

 /// 内容变化/首屏定位后 1.5s 内的「贴底收敛」：LazyVStack 的内容高度估算会在布局后
 /// 继续微调，单拍 follow 可能留下 3–35pt 的残差；窗口内有界地按真值再贴一次。
 /// 窗口外绝不滚动（pinned 且无 pending 时列表必须完全静止）。
    private func settlePinnedBottomIfNeeded(proxy: ScrollViewProxy) {
        guard didInitialBottom, pinnedToBottom, !isUserInteractingNow(),
              metrics.pendingAnchor == nil, metrics.pendingFollow == nil else { return }
        let now = CACurrentMediaTime()
        guard now < metrics.settleFollowUntil else { return }
        guard metrics.settleFollowAttempts < 8 else { return }
        let distance = currentDistanceFromBottom()
        guard distance.isFinite, distance > 1.5 else { return }
        metrics.settleFollowAttempts += 1
        metrics.pendingFollow = .immediate
        _ = performPendingCorrection(proxy: proxy, allowFallback: true, allowScrollToFallback: false)
        if metrics.pendingFollow != nil {
            scheduleLayoutCorrection(proxy: proxy)
        }
    }

 /// 诊断：内容静默约 1.6s 后做一次「已贴底」判定，只写探针字段，**不做任何滚动**。
 /// 纯静态等待时 SwiftUI 不再产生布局回调，探针的 settledOnce 需要在静置后主动记录一次。
    private func scheduleSettledProbe() {
        metrics.settledProbeGeneration += 1
        let generation = metrics.settledProbeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard generation == self.metrics.settledProbeGeneration else { return }
            guard self.didInitialBottom, self.pinnedToBottom, !self.isUserInteractingNow(),
                  self.metrics.pendingAnchor == nil, self.metrics.pendingFollow == nil else { return }
            let distance = self.currentDistanceFromBottom()
            guard distance.isFinite, distance <= 2.5 else { return }
            self.metrics.hasSettledOnce = true
            if distance > self.metrics.maxIdleDistance { self.metrics.maxIdleDistance = distance }
        }
    }

 /// 空闲态稳定性取证：pinned 且无任何 pending 时，距底距离不应变大（变大 = 列表自己滚）。
    private func trackIdleBottomStability() {
        guard didInitialBottom, pinnedToBottom,
              metrics.pendingAnchor == nil, metrics.pendingFollow == nil else { return }
        guard !isUserInteractingNow() else { return }
        guard CACurrentMediaTime() >= metrics.settleFollowUntil else { return }
        let distance = currentDistanceFromBottom()
        guard distance.isFinite else { return }
        if distance <= 2.5 { metrics.hasSettledOnce = true }
        guard metrics.hasSettledOnce else { return }
        if distance > metrics.maxIdleDistance { metrics.maxIdleDistance = distance }
        if distance > ScrollFollowPolicy.settlePinTolerance + 2 { metrics.idleDriftCount += 1 }
    }

    private static let scrollDebugEnabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DSHM_SCROLLDBG"] == "1"
        #else
        return false
        #endif
    }()

    private func scrollDebug(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard Self.scrollDebugEnabled else { return }
        NSLog("[SCROLLDBG] %@", message())
        #endif
    }

    private func fmt(_ value: CGFloat) -> String {
        let tenths = (value * 10).rounded() / 10
        return String(describing: tenths)
    }

 /// 几何快照：handle/坐标/distance/offset/contentSize 全量打印，真机可直接对照。
    private func scrollGeometrySummary() -> String {
        let viewportMaxY = metrics.viewportFrame.isNull ? -9999 : metrics.viewportFrame.maxY
        let scrollContentSize = metrics.scrollHandle.scrollView?.contentSize.height ?? -9999
        return "handle=" + (metrics.scrollHandle.scrollView != nil ? "1" : "0")
            + " topMinY=\(fmt(metrics.topMinY))"
            + " viewportMaxY=\(fmt(viewportMaxY))"
            + " viewportH=\(fmt(metrics.viewportHeight))"
            + " bottomMaxY=\(fmt(metrics.bottomFrame?.maxY ?? -9999))"
            + " distance=\(fmt(currentDistanceFromBottom()))"
            + " offset=\(fmt(currentOffsetY()))"
            + " contentH=\(fmt(metrics.contentHeight))"
            + " contentSize=\(fmt(scrollContentSize))"
    }

 // MARK: - 可见 HUD（DEBUG + DSHM_E2E_HUD=1；真机 XCUITest 可读，用于矩阵取证）

    private static let hudEnabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DSHM_E2E_HUD"] == "1"
        #else
        return false
        #endif
    }()

    @ViewBuilder
    private var scrollHUD: some View {
        #if DEBUG
        if Self.hudEnabled {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Text(hudText())
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.6))
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("e2e-scroll-hud")
                    .accessibilityLabel(hudText())
            }
        } else {
            EmptyView()
        }
        #else
        EmptyView()
        #endif
    }

    private func hudText() -> String {
        let scrollView = metrics.scrollHandle.scrollView
        let offset = scrollView.map { $0.contentOffset.y + $0.adjustedContentInset.top } ?? -9999
        let contentSize = scrollView?.contentSize.height ?? -9999
        let distance = currentDistanceFromBottom()
        let distanceText = distance.isFinite ? fmt(distance) : "-9999"
        let windowStartIndex = displayedItems.first.flatMap { first in
            items.firstIndex(where: { $0.id == first.id })
        } ?? -1
        return "o=\(fmt(offset)) d=\(distanceText) i=\(displayedItems.count)/\(items.count) ws=\(windowStartIndex) pre=\(metrics.prependCount) ch=\(fmt(contentSize)) vh=\(fmt(metrics.viewportHeight)) pin=\(pinnedToBottom ? 1 : 0) ini=\(didInitialBottom ? 1 : 0) gm=\(fmt(metrics.gestureMaxFrameDelta)) ac=\(metrics.anchorCorrectionCount) cs=\(metrics.anchorContentSizeCount) sf=\(metrics.anchorScrollToCount) acg=\(metrics.anchorCorrectionDuringGesture) fw=\(metrics.followCount) rs=\(fmt(metrics.lastAnchorResidual)) sy=\(metrics.syncCorrectionCount) lag=\(metrics.asyncCorrectionCount) dr=\(metrics.idleDriftCount) mx=\(fmt(metrics.maxIdleDistance)) kvo=\(metrics.contentSizeKVOCompensations) pan=\(metrics.panSeen ? 1 : 0) ptrk=\(metrics.panTrackingSeen ? 1 : 0) pdec=\(metrics.panDecelSeen ? 1 : 0) it=\(isUserInteractingNow() ? 1 : 0) drag=\(metrics.isDragging ? 1 : 0)"
    }

 // MARK: - 隐藏探针（模拟器 E2E 契约；键名保持不变）

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
        let distance = currentDistanceFromBottom()
        let distanceText = distance.isFinite ? fmt(distance) : "-1"
        let scrollView = metrics.scrollHandle.scrollView
        let contentSize = scrollView?.contentSize.height ?? -1
        let windowStartIndex = displayedItems.first.flatMap { first in
            items.firstIndex(where: { $0.id == first.id })
        } ?? -1
        return "pinned=" + (pinnedToBottom ? "1" : "0")
            + ";displayed=" + String(displayedItems.count)
            + ";incoming=" + String(items.count)
            + ";distance=" + distanceText
            + ";attempts=0"
            + ";seq=" + String(latestAppliedSeq())
            + ";dragging=" + (metrics.isDragging ? "1" : "0")
            + ";chain=0"
            + ";bottomMaxY=" + fmt(metrics.bottomFrame?.maxY ?? -9999)
            + ";viewport=" + fmt(metrics.viewportHeight)
            + ";viewportMaxY=" + fmt(metrics.viewportFrame.isNull ? -9999 : metrics.viewportFrame.maxY)
            + ";topMinY=" + fmt(metrics.topMinY)
            + ";offset=" + fmt(currentOffsetY())
            + ";contentH=" + fmt(metrics.contentHeight)
            + ";handle=" + (scrollView != nil ? "1" : "0")
            + ";settledOnce=" + (metrics.hasSettledOnce ? "1" : "0")
            + ";maxDist=" + fmt(metrics.maxIdleDistance)
            + ";drifts=" + String(metrics.idleDriftCount)
            + ";anchor=" + (pinnedToBottom && didInitialBottom ? "bottom" : "none")
            + ";pins=0"
            + ";gesturePins=0"
            + ";userScrolled=" + (userHasScrolled ? "1" : "0")
            + ";gestureMaxDelta=" + fmt(metrics.gestureMaxFrameDelta)
            + ";gestureFrames=" + String(metrics.gestureFrameCount)
            + ";prepends=" + String(metrics.prependCount)
            + ";anchorFixes=" + String(metrics.anchorCorrectionCount + metrics.anchorContentSizeCount + metrics.anchorScrollToCount + metrics.anchorResidualFixes)
            + ";pref=" + String(metrics.anchorPreferenceCount)
            + ";pb=" + String(metrics.pinnedBaselineFixes)
            + ";kvo=" + String(metrics.contentSizeKVOCompensations)
            + ";pan=" + (metrics.panSeen ? "1" : "0")
            + ";ptrk=" + (metrics.panTrackingSeen ? "1" : "0")
            + ";pdec=" + (metrics.panDecelSeen ? "1" : "0")
            + ";os=" + fmt(overscrollAmount())
            + ";csf=" + String(metrics.pinnedContentSizeFixes)
            + ";lk=" + String(metrics.lockAnchorFixes)
            + ";sa=" + String(metrics.settleFollowAttempts)
            + ";contentSize=" + fmt(contentSize)
            + ";ready=" + (isContentReady ? "1" : "0")
            + ";wstart=" + String(windowStartIndex)
            + ";win=" + String(MessageListWindowPolicy.defaultWindow)
    }

 /// 过滚量（pt）：>0 = 当前 contentOffset 超过「内容底部对齐视口底部」的极限值。
    private func overscrollAmount() -> CGFloat {
        guard let scrollView = metrics.scrollHandle.scrollView, scrollView.bounds.height > 1 else { return -9999 }
        let maxOffset = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
        return scrollView.contentOffset.y - maxOffset
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

/// 布局后贴底跟随的两种模式：立即（用户主动回底/首屏）或约 150ms 缓动（流式新内容）。
enum FollowMode {
    case immediate
    case animated
}

/// 会话详情「显示窗口」策略（纯逻辑，可单测）。
///
/// 目的：列表只渲染「最近 N 行」（默认 300，与本地缓存深度 300 对齐）。
/// - autoload 补进来的更早历史只进数据层，不进入显示内容 → 用户拖动期间**没有上方插入**，
/// 1:1 跟手与「非手势位移 0 物理像素」不再受后台加载影响；
/// - 用户滚动到窗口顶部预留区时，一次向上扩展 100 行（纯 prepend，由 contentSize KVO
/// 同帧补偿），因此快速上滑也不会撞到「假顶部」。
enum MessageListWindowPolicy {
 /// 显示窗口行数（与缓存最近 300 条对齐）。
    static let defaultWindow = 300
 /// 每次向上扩展的行数。
    static let expandChunk = 100
 /// 距窗口顶部预留区（pt）：提前这么多开始向上扩展，避免用户撞到窗口顶。
    static let expandMargin: CGFloat = 1200

 /// 默认显示窗口的起点下标：最近 N 行（不足 N 行时为 0）。
    static func initialStartIndex(itemCount: Int, window: Int = defaultWindow) -> Int {
        max(0, itemCount - window)
    }

 /// 默认显示窗口：最近 N 行（不足 N 行时全量）。
    static func initialWindow(items: [SessionMessageItem], window: Int = defaultWindow) -> [SessionMessageItem] {
        guard items.count > window else { return items }
        return Array(items.suffix(window))
    }

 /// 由「窗口起点 id」解析出在 ids 里的下标；id 失效时退回「最近 N 行」起点。
 /// 用 id 数组而不是 items，便于纯逻辑单测（不依赖 SessionMessageItem 的具体构造）。
    static func resolvedStartIndex(currentStartID: String?,
                                   itemIDs: [String],
                                   window: Int = defaultWindow) -> Int {
        if let id = currentStartID, let index = itemIDs.firstIndex(of: id) {
            return index
        }
        return initialStartIndex(itemCount: itemIDs.count, window: window)
    }

 /// 窗口首行进入视口顶部预留区（或已到视口内）时，需要向上扩展。
 /// 视野坐标统一用全局 frame（与列表其它几何判定一致）。
    static func shouldExpand(firstRow: CGRect,
                             viewport: CGRect,
                             margin: CGFloat = expandMargin) -> Bool {
        guard !viewport.isNull, viewport.height > 1, !firstRow.isNull, firstRow.height > 0 else { return false }
        return viewport.minY - firstRow.maxY <= margin
    }

 /// 一次扩展后的新起点下标（最多向前 expandChunk 行，不小于 0）。
    static func expandedStartIndex(currentStart: Int,
                                   itemCount: Int,
                                   chunk: Int = expandChunk) -> Int {
        guard currentStart > 0 else { return 0 }
        return max(0, min(currentStart, itemCount) - chunk)
    }
}

/// 方案 A（可视锚点 + contentOffset 精确补偿）的纯逻辑：可单测、不依赖 UI。
///
/// 不变量（回归测试必须覆盖）：
/// 1. 无内容变化时不得产生任何滚动；
/// 2. 手势期间的补偿只允许「按测量差值的精确补偿」；
/// 3. 后台历史 prepend 后，可见内容相对屏幕位置不变（≤1 物理像素）；
/// 4. pinned 只在用户手势结束 settle 时改写，内容变化绝不改 pinned。
enum ScrollFollowPolicy {
 /// 手势结束「判定贴底」的容差（pt）：≤ 12pt 视为用户想回到底部。
    static let settlePinTolerance: CGFloat = 12
 /// 锚点补偿的最小位移（pt）：低于该值不滚动（3x 屏 1 物理像素 = 1/3 pt）。
    static let compensationTolerance: CGFloat = 0.34
 /// 贴底跟随时「缓动」与「直接跳」的分界（pt）。
    static let animatedFollowThreshold: CGFloat = 60
 /// 首屏贴底定位的判定容差（pt）。
    static let initialBottomTolerance: CGFloat = 2
 /// 首屏贴底定位的最大布局重试次数（无定时器，只靠布局回调推进）。
    static let initialBottomMaxAttempts: Int = 8

 /// 首个完整可见行：返回（行 id, 行顶相对视口顶部的偏移, 行高）。
 /// 没有完整可见行时退回「第一个与视口相交的行」（行顶可能为负，补偿同样精确）。
    static func anchorCandidate(rowFrames: [String: CGRect],
                                viewport: CGRect,
                                visibleIDs: Set<String>) -> (id: String, relativeY: CGFloat, rowHeight: CGFloat)? {
        guard !viewport.isNull, viewport.height > 1 else { return nil }
        let visible = rowFrames.filter { id, frame in
            visibleIDs.contains(id)
                && frame.height > 0
                && frame.maxY > viewport.minY + 1
                && frame.minY < viewport.maxY - 1
        }
        .sorted { $0.value.minY < $1.value.minY }
        guard !visible.isEmpty else { return nil }
        for (id, frame) in visible {
            let relativeY = frame.minY - viewport.minY
            if relativeY >= 0, relativeY <= viewport.height - frame.height + 0.5 {
                return (id, relativeY, frame.height)
            }
        }
        let first = visible[0]
        return (first.key, first.value.minY - viewport.minY, first.value.height)
    }

 /// 锚点补偿量（新相对偏移 - 旧相对偏移）；|值| <= tolerance 时返回 nil（不滚动）。
    static func compensationDelta(oldRelativeY: CGFloat,
                                  newRelativeY: CGFloat,
                                  tolerance: CGFloat = compensationTolerance) -> CGFloat? {
        guard oldRelativeY.isFinite, newRelativeY.isFinite else { return nil }
        let delta = newRelativeY - oldRelativeY
        return abs(delta) > tolerance ? delta : nil
    }

 /// 贴底跟随的目标 contentOffset.y（内容底部对齐视口底部）。
    static func followTargetOffset(contentHeight: CGFloat,
                                   viewportHeight: CGFloat,
                                   bottomInset: CGFloat) -> CGFloat {
        contentHeight + bottomInset - viewportHeight
    }

 /// 贴底跟随还需要移动的距离（>0 还没到底；<0 已过滚）。
    static func followDistance(currentOffset: CGFloat, targetOffset: CGFloat) -> CGFloat {
        targetOffset - currentOffset
    }

 /// 手势结束后的 pinned 判定：距底 <= 12pt 视为贴底。
    static func pinnedAfterGesture(distanceFromBottom: CGFloat) -> Bool {
        distanceFromBottom <= settlePinTolerance
    }
}

/// 滚动几何/校正状态（引用类型：不触发 SwiftUI body 重算，每帧滚动零成本）。
private final class ScrollMetrics {
 /// 列表顶部（0 高哨兵行）的全局 minY；offset = viewportFrame.minY - topMinY。
    var topMinY: CGFloat = 0
 /// LazyVStack 内容高度（preference 值，仅诊断）。
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
 /// ScrollView 自身的全局 frame（统一用全局坐标，避免 named coordinate space 解析失败）。
    var viewportFrame: CGRect = .null
    var rowFrames: [String: CGRect] = [:]
 /// 底部哨兵行的全局 frame（nil = 未被 LazyVStack 物化 = 距底很远）。
    var bottomFrame: CGRect?
 /// SwiftUI ScrollView 底层 UIScrollView 的只读句柄（真值来源）。
    let scrollHandle = ScrollViewGeometryHandle()

 // MARK: - 交互
 /// 用户拖拽中（onChanged 置 true / onEnded 置 false）。
    var isDragging = false
 /// 松手后的交互静默期截止时间（惯性/回弹也算用户交互）。
    var interactingUntil: CFTimeInterval = 0

 // MARK: - 布局后校正（方案 A）
 /// 待补偿的可视锚点（内容变化前捕获）。
    var pendingAnchor: AnchorSnapshot?
 /// 待执行的贴底跟随模式。
    var pendingFollow: FollowMode?
 /// 异步兜底校正是否已排队（去重）。
    var correctionScheduled = false
 /// 大 prepend 兜底补偿后待复核的锚点（只复核一次）。
    var pendingVerify: AnchorSnapshot?
    var verifyScheduled = false
 /// 应用新内容前的 UIScrollView contentSize.height（大 prepend 兜底补偿用）。
    var contentSizeAtApply: CGFloat = -1
 /// 尾部两行 id 是否未变（纯 prepend 才允许用内容高度增长量补偿）。
    var tailStable = false
 /// 内容版本：displayedItems 真的变化一次 +1。
    var contentRevision = 0

 // MARK: - 首屏贴底定位
    var initialBottomAttempts = 0
    var initialAttemptPending = false
    var initialBottomFinishing = false
    var initialHandleMisses = 0

 // MARK: - 手势 settle
    var settlePollGeneration = 0

 // MARK: - 诊断/取证
 /// 逐帧 offset 采样的上一值（手势窗口内统计单帧最大位移）。
    var lastTraceOffset: CGFloat = -1
    var gestureMaxFrameDelta: CGFloat = 0
    var gestureFrameCount = 0
 /// 首屏贴底成功后置 true：此后 pinned 空闲态距底距离变大 = 列表自己漂移。
    var hasSettledOnce = false
    var maxIdleDistance: CGFloat = 0
    var idleDriftCount = 0
 /// 后台历史 prepend 批次数（HUD/探针）。
    var prependCount = 0
 /// 可视锚点补偿次数（按来源分类，HUD/探针取证用）。
    var anchorCorrectionCount = 0
    var anchorPreferenceCount = 0
    var anchorContentSizeCount = 0
    var anchorScrollToCount = 0
    var anchorCorrectionDuringGesture = 0
    var anchorResidualFixes = 0
 /// 贴底跟随执行次数。
    var followCount = 0
    var lastAnchorDelta: CGFloat = 0
    var lastAnchorResidual: CGFloat = 0
 /// 同步（同一 runloop）/异步（下一拍）完成的校正次数：异步次数 >0 说明有可见跳动风险。
    var syncCorrectionCount = 0
    var asyncCorrectionCount = 0
 /// 贴底收敛窗口（内容变化/首屏定位后 1.5s 内允许按真值再贴一次，窗口外绝不滚动）。
    var settleFollowUntil: CFTimeInterval = 0
    var settleFollowAttempts = 0
 /// 上方插入高度偏好测量：apply 前的 LazyVStack 内容高度 + 本次变化是否为纯 prepend。
    var contentHeightAtApply: CGFloat = -1
    var pendingPrependHeight = false
 /// 静置诊断探针的代（新的内容变化会让旧的静置判定失效）。
    var settledProbeGeneration = 0
 /// contentSize KVO 同帧补偿次数（诊断/取证）。
    var contentSizeKVOCompensations = 0
 /// 诊断：滚动视图的 pan 是否接管过（isDragging / isTracking / isDecelerating）。
    var panSeen = false
    var panTrackingSeen = false
    var panDecelSeen = false
 /// KVO 未触发时的宽限拍数（超过后退回旧测量路径）。
    var prependKVOGraceAttempts = 0
 /// prepend 补偿窗口截止时间：窗口内每次 contentSize 变化都按增量补偿（覆盖多次估算修正）。
    var prependCompensationUntil: CFTimeInterval = 0
 /// 窗口扩展是否已排队（避免同一帧多次扩展）。
    var windowExpansionScheduled = false
 /// 自上次逐帧采样以来我们主动做的 offset 补偿量（逐帧取证时扣除，只统计无归因位移）。
    var compensationSinceTrace: CGFloat = 0
 /// 贴底 + 纯 prepend 的幂等基线：offset/内容高度在内容应用前的值。
    var pinnedBaselineActive = false
    var pinnedBaselineOffset: CGFloat = -1
    var pinnedBaselineHeight: CGFloat = -1
    var pinnedBaselineFixes = 0
 /// 布局成长补偿：上一次观测到的 UIScrollView contentSize 高度（事件驱动、有界）。
    var lastLayoutContentSize: CGFloat = -1
    var pinnedContentSizeFixes = 0
 /// 读历史时的「内容锁定锚点」：内容变化补偿完成后记录，后续布局成长继续按真实 frame 锁定。
    var lockAnchor: AnchorSnapshot?
    var lockAnchorFixes = 0
    var lockAnchorFixAttempts = 0
 /// 首次拿到视口 frame 时打一条诊断日志（只打一次）。
    var didLogFirstViewport = false
}

/// SwiftUI ScrollView 底层 UIScrollView 的只读句柄（弱引用，不 retain、不改 delegate）。
/// 额外提供 contentSize 的 KVO 同步回调：SwiftUI 在布局里设置 contentSize 的那一刻回调，
/// 是「上方插入高度」最早、最精确、与手指位移完全无关的测量。
private final class ScrollViewGeometryHandle {
    weak var scrollView: UIScrollView?
    var onContentSizeChange: ((CGSize, CGSize) -> Void)?

    private var contentSizeObservation: NSKeyValueObservation?

    func installContentSizeObservationIfNeeded() {
        guard let scrollView, contentSizeObservation == nil else { return }
        contentSizeObservation = scrollView.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
            guard let self, let old = change.oldValue, let new = change.newValue, old != new else { return }
            self.onContentSizeChange?(old, new)
        }
    }
}

/// 挂在列表内容背景上的零尺寸探针：沿 superview 链找到包裹内容的 UIScrollView。
/// 只读坐标/尺寸/交互标志（contentOffset/contentSize/bounds/isDragging/isDecelerating），
/// 不替换 delegate、不写 contentOffset，避免和 SwiftUI 争滚动状态。
private struct ScrollViewGeometryInstaller: UIViewRepresentable {
    let handle: ScrollViewGeometryHandle
    let onContentSizeChange: (CGSize, CGSize) -> Void

    final class HostView: UIView {
        weak var handle: ScrollViewGeometryHandle?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
        }

        func attach() {
            guard let handle else { return }
            if handle.scrollView == nil {
                var candidate: UIView? = superview
                while let view = candidate {
                    if let scrollView = view as? UIScrollView {
                        handle.scrollView = scrollView
                        break
                    }
                    candidate = view.superview
                }
            }
            handle.installContentSizeObservationIfNeeded()
        }
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.handle = handle
        handle.onContentSizeChange = onContentSizeChange
 // didMoveToWindow 时 superview 链可能还没接到 UIScrollView 上，延迟一拍再找。
        DispatchQueue.main.async { view.attach() }
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        uiView.handle = handle
        handle.onContentSizeChange = onContentSizeChange
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
 // 哨兵行被 LazyVStack 回收时必须回到.null（区别于「还在视口下方」的陈旧 frame）：
 // 旧实现保留上一次的非空值，真机/模拟器实测出现过 bottomMaxY 比视口低 1366pt 的
 // 陈旧读数，直接污染「是否贴底」的判定。
        value = nextValue()
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
