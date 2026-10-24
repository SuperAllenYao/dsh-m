import Foundation
import SwiftUI

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

/// **纯 SwiftUI 原生消息列表**
///
/// 架构不变量（黑屏与闪退的根治，替代 r4-r6 的 UIScrollView KVO/contentOffset 互操作）：
///
/// 1. **滚动意图只通过 `ScrollPosition` 的 `scrollTo(edge:)` / `scrollTo(id:anchor:)` 表达**，
/// 永不直接读写 `contentOffset`。id/edge 是锚点式滚动：SwiftUI 负责在新位置物化行，
/// 不存在「offset 被搬走但 LazyVStack 未物化行 = 整屏黑」的路径（r6 黑屏根因，
/// HUD 现场 vr=0 bf=-1 pin=1 mch==ch）。
/// 2. **几何真值来自官方 `onScrollGeometryChange`**（ScrollGeometry：contentSize/
/// contentOffset/visibleRect），替代 KVO 观察 UIScrollView.contentSize。
/// 3. **交互状态来自官方 `onScrollPhaseChange`**（ScrollPhase：interacting/
/// decelerating/idle...），替代读取 UIScrollView.isDragging/isDecelerating/isTracking；
/// settle 判定由 `.idle` 相位事件驱动，不再 asyncAfter 轮询。
/// 4. 行 frame 测量保留 PreferenceKey（SwiftUI 原生机制），用于锚点捕获/复核。
///
/// 行为契约保持：贴底跟随、读历史 prepend 阅读位置不变、窗口扩展、发送回底、
/// 首屏贴底不闪顶帧、HUD/探针字段兼容（E2E 契约）。
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

    private static let bottomID = "__session_list_bottom__"
    private static let rowVerticalPadding: CGFloat = Theme.Spacing.s / 2

 /// 程序化滚动的唯一通道（iOS 18 ScrollPosition）：
 /// 只发 id/edge 意图，由系统完成布局物化。初值贴底 = 首屏定位的第一步。
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

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
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
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

 // 底部哨兵行：贴底自证的真值信号（frame 偏好）。
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
 // 首屏贴底定位完成前不显示：不允许「先显示顶部、再跳到底」。
                .opacity(isContentReady ? 1 : 0)
            }
 // 程序化滚动的唯一通道：锚点式意图（edge/id），系统负责物化行。
            .scrollPosition($scrollPosition)
 // 官方几何观察（替代 KVO contentSize / offset 读取）：
 // 一个 Equatable 投影拿到 全部真值。
            .onScrollGeometryChange(for: ScrollFacts.self) { geometry in
                ScrollFacts(geometry: geometry)
            } action: { old, new in
                handleScrollFactsChange(old: old, new: new)
            }
 // 官方滚动相位（替代 isDragging/isDecelerating/isTracking + settle 轮询）。
            .onScrollPhaseChange { oldPhase, newPhase in
                handleScrollPhaseChange(old: oldPhase, new: newPhase)
            }
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
                layoutDidChange()
            }
            .onPreferenceChange(ListContentHeightPreferenceKey.self) { height in
                metrics.contentHeight = height
                layoutDidChange()
            }
            .onPreferenceChange(ListBottomFramePreferenceKey.self) { frame in
                metrics.bottomFrame = frame.isNull ? nil : frame
                layoutDidChange()
            }
            .onPreferenceChange(RowFramePreferenceKey.self) { frames in
                metrics.rowFrames = frames
                runAnchorVerificationIfNeeded()
                layoutDidChange()
            }
            .onAppear {
                metrics.viewportHeight = outer.size.height
                scrollDebug("list onAppear items=\(items.count) displayed=\(displayedItems.count) didInitialBottom=\(didInitialBottom) ready=\(isContentReady)")
                advanceInitialBottomIfNeeded()
            }
            .onChange(of: outer.size.height) { _, height in
                metrics.viewportHeight = height
                if didInitialBottom, pinnedToBottom {
                    requestFollow(.immediate)
                    scheduleLayoutCorrection()
                } else {
                    advanceInitialBottomIfNeeded()
                }
            }
            .onChange(of: signature) { _, _ in
                applyItemsChange()
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
                requestFollow(.immediate)
                scheduleLayoutCorrection()
            }
            .onDisappear {
                metrics.correctionScheduled = false
                metrics.pendingAnchor = nil
                metrics.pendingFollow = nil
                metrics.pendingVerify = nil
            }
            .overlay(alignment: .topLeading) { scrollProbeElement }
            .overlay(alignment: .top) { scrollHUD }
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

 // MARK: - 几何真值（ScrollGeometry 官方投影）

 /// 当前是否处于用户交互（按压/拖拽/惯性）中：相位 + 松手静默窗口。
    private func isUserInteractingNow() -> Bool {
        if metrics.isDragging || CACurrentMediaTime() < metrics.interactingUntil { return true }
        return false
    }

    private func currentDistanceFromBottom() -> CGFloat {
        return metrics.facts.distanceFromBottom
    }

    private func currentOffsetY() -> CGFloat {
        return metrics.facts.offset
    }

    private func overscrollAmount() -> CGFloat {
        return metrics.facts.overscroll
    }

    private func markUserScrolledIfNeeded() {
        guard !userHasScrolled else { return }
        userHasScrolled = true
        onUserScrolled()
    }

 // MARK: - 官方几何观察（替代 contentSize KVO）

 /// 几何变化入口（onScrollGeometryChange action，主线程非布局回调）。
 ///
 /// - 首屏：推进贴底定位自证；
 /// - pinned 且内容高度增长（尾部流式/prepend）：发 `scrollTo(edge:.bottom)` 意图。
 /// 系统按锚点物化行——这是 r6 黑屏（raw contentOffset 搬走后 LazyVStack 零行物化）
 /// 的根治性替代；
 /// - 其余：只更新事实与取证，不滚动。
    private func handleScrollFactsChange(old: ScrollFacts, new: ScrollFacts) {
        let previous = metrics.facts
        metrics.facts = new
        traceGestureOffsetIfNeeded(offset: new.offset)
        guard didInitialBottom else {
            advanceInitialBottomIfNeeded()
            return
        }
        let growth = new.contentHeight - previous.contentHeight
        if growth > ScrollFollowPolicy.compensationTolerance, pinnedToBottom, !isUserInteractingNow() {
 // 贴底跟随：内容长多少贴多少。edge 意图由系统物化（黑屏根治点）。
            scrollPosition.scrollTo(edge: .bottom)
            metrics.followCount += 1
            metrics.contentSizeFollows += 1
            scrollDebug("facts follow growth=\(fmt(growth)) \(scrollGeometrySummary())")
            return
        }
        settlePinnedBottomIfNeeded()
        trackIdleBottomStability()
    }

 // MARK: - 官方滚动相位（替代 isDragging/isDecelerating + settle 轮询）

    private func handleScrollPhaseChange(old: ScrollPhase, new: ScrollPhase) {
        switch new {
        case .tracking, .interacting:
            if !metrics.isDragging {
                metrics.lastTraceOffset = currentOffsetY()
                metrics.gestureMaxFrameDelta = 0
                metrics.gestureFrameCount = 0
            }
            metrics.isDragging = true
            metrics.interactingUntil = CACurrentMediaTime() + 0.12
            metrics.panSeen = true
            markUserScrolledIfNeeded()
            finishInitialBottomIfInterrupted()
        case .decelerating:
            metrics.panDecelSeen = true
            metrics.interactingUntil = CACurrentMediaTime() + 0.55
        case .animating:
 // 程序化滚动（我们的 scrollTo 意图）执行中：不视为用户交互。
            break
        case .idle:
            metrics.isDragging = false
            metrics.panTrackingSeen = metrics.panTrackingSeen || old == .tracking
            settleAfterGesture()
        @unknown default:
            break
        }
    }

 /// 松手 settle（相位到.idle 的事件驱动，替代 asyncAfter 轮询）：
 /// 距底 <= 12pt 视为用户想贴底（repin），否则 unpin。
    private func settleAfterGesture() {
        guard didInitialBottom else { return }
        let distance = currentDistanceFromBottom()
        let next = ScrollFollowPolicy.pinnedAfterGesture(distanceFromBottom: distance)
        if next != pinnedToBottom {
            pinnedToBottom = next
            onNearBottomChange(next)
            scrollDebug("settle pin=\(next ? 1 : 0) distance=\(fmt(distance))")
        }
        if next, distance.isFinite, distance > 0.5 {
 // 用户在底部松手：贴回底部（本身就是「用户想回到底部」）。
            scrollPosition.scrollTo(edge: .bottom)
            metrics.followCount += 1
        }
    }

 // MARK: - items 变化：可视锚点 / 贴底跟随

 /// 内容变化时**不冻结、不阻塞**：整批应用后，要么贴底跟随，要么把「首个完整可见行」
 /// 用锚点式 scrollTo 放回原位（系统物化，不直接搬 offset）。
    private func applyItemsChange() {
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
            scheduleWindowExpansionCheck()
            return
        }
 // 1. 内容应用前：判断是否贴底、捕获可视锚点（必须是应用前的布局值）。
        let wasAtBottom = pinnedToBottom && !isUserInteractingNow()
        let anchor = visibleAnchorSnapshot()
        let oldTailIDs = Array(displayedItems.suffix(2)).map(\.id)
        let prepended = !MessageListUpdatePolicy.historyPrefix(displayed: displayedItems, incoming: newItems).isEmpty
        metrics.contentSizeAtApply = metrics.facts.contentHeight
        metrics.lockAnchor = nil
        metrics.lockAnchorFixAttempts = 0
        metrics.tailStable = !oldTailIDs.isEmpty && Array(newItems.suffix(2)).map(\.id) == oldTailIDs
        if prepended { metrics.prependCount += 1 }
        metrics.settleFollowUntil = CACurrentMediaTime() + 1.5
        metrics.settleFollowAttempts = 0
 // 2. 应用数据（不冻结、不排队、不阻塞用户操作）。
        displayedItems = newItems
        scrollDebug("apply pinned=\(pinnedToBottom ? 1 : 0) displayed=\(displayedItems.count) incoming=\(newItems.count) atBottom=\(wasAtBottom ? 1 : 0) anchor=\(anchor?.id ?? "-") prepended=\(prepended ? 1 : 0) \(scrollGeometrySummary())")
        guard didInitialBottom else {
            scheduleLayoutCorrection()
            return
        }
 // 3. 计划（全部经 ScrollPosition 锚点意图执行）：
 // - 贴底（含 prepend）：跟随到底部（edge 意图，系统物化）；
 // - 读历史 + prepend：锚点行放回原相对位置（id+UnitPoint 意图）；
 // - 读历史 + 尾部变化：不滚动（视口下方的内容不影响阅读位置）。
        if wasAtBottom {
            metrics.pendingAnchor = nil
            metrics.pendingVerify = nil
            requestFollow(prepended ? .immediate : .animated)
        } else if prepended, let anchor {
            metrics.pendingFollow = nil
            metrics.pendingAnchor = anchor
        } else {
            metrics.pendingAnchor = nil
            metrics.pendingFollow = nil
        }
        scheduleLayoutCorrection()
    }

 /// 显示窗口：只渲染「最近 N 行」（默认 300，与本地缓存深度对齐）。
    private func windowedItems(from incoming: [SessionMessageItem]) -> [SessionMessageItem] {
        guard !incoming.isEmpty else { return [] }
        if let startID = windowStartItemID,
           let index = incoming.firstIndex(where: { $0.id == startID }) {
            return Array(incoming[index...])
        }
        return MessageListWindowPolicy.initialWindow(items: incoming)
    }

 // MARK: - 窗口扩展（向上 prepend 100 行）

    private func scheduleWindowExpansionCheck() {
        guard !metrics.windowExpansionScheduled else { return }
        metrics.windowExpansionScheduled = true
        DispatchQueue.main.async {
            self.metrics.windowExpansionScheduled = false
            self.maybeExpandWindow()
        }
    }

 /// 用户滚到窗口顶部预留区时向上扩展显示窗口（一次 100 行）。
 /// 扩展是纯 prepend：捕获锚点 → 应用 → 锚点式 scrollTo 放回（系统物化）。
    private func maybeExpandWindow() {
        guard didInitialBottom, let first = displayedItems.first else { return }
        guard !metrics.viewportFrame.isNull, let firstFrame = metrics.rowFrames[first.id] else { return }
        guard MessageListWindowPolicy.shouldExpand(firstRow: firstFrame, viewport: metrics.viewportFrame) else { return }
        guard let currentStart = items.firstIndex(where: { $0.id == first.id }) else { return }
        let newStart = MessageListWindowPolicy.expandedStartIndex(currentStart: currentStart, itemCount: items.count)
        guard newStart < currentStart else { return }
        metrics.windowExpansionScheduled = true
        DispatchQueue.main.async {
            self.metrics.windowExpansionScheduled = false
            self.performWindowExpansion(newStart: newStart)
        }
    }

    private func performWindowExpansion(newStart: Int) {
        guard newStart >= 0, newStart < items.count else { return }
        let expanded = Array(items[newStart...])
        guard expanded != displayedItems else { return }
        let anchor = visibleAnchorSnapshot()
        windowStartItemID = items[newStart].id
        metrics.pendingFollow = nil
        metrics.pendingVerify = nil
        if let anchor {
            metrics.pendingAnchor = anchor
            metrics.pendingPrependHeight = true
        }
        metrics.tailStable = true
        displayedItems = expanded
        metrics.prependCount += 1
        scrollDebug("window expand start=\(newStart) displayed=\(expanded.count)/\(items.count)")
        scheduleLayoutCorrection()
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

 // MARK: - 布局后校正（锚点式 scrollTo 意图）

 /// 布局（preference/geometry）变化后：执行 pending 的滚动意图。
    private func layoutDidChange() {
        if !didInitialBottom {
            advanceInitialBottomIfNeeded()
            return
        }
        if metrics.pendingAnchor != nil || metrics.pendingFollow != nil {
            if performPendingCorrection() {
                metrics.syncCorrectionCount += 1
            } else {
                scheduleLayoutCorrection()
            }
            return
        }
        maybeExpandWindow()
        applyIdleLayoutGrowthCompensation()
        settlePinnedBottomIfNeeded()
        trackIdleBottomStability()
    }

 /// 兜底校正（异步一拍）：pending 意图本拍量不到时退到下一拍。
    private func scheduleLayoutCorrection() {
        guard !metrics.correctionScheduled else { return }
        metrics.correctionScheduled = true
        DispatchQueue.main.async {
            self.metrics.correctionScheduled = false
            guard self.metrics.pendingAnchor != nil || self.metrics.pendingFollow != nil else { return }
            if self.performPendingCorrection() {
                self.metrics.asyncCorrectionCount += 1
            }
        }
    }

    @discardableResult
    private func performPendingCorrection() -> Bool {
        var didWork = false
 // 顺序不变量：锚点还没回位，绝不能先做贴底跟随（否则 follow 会把
 // 「上方插入的高度」当成滚动距离 = 静置时自己滚动）。
        if let anchor = metrics.pendingAnchor {
            applyAnchorCorrection(anchor)
            metrics.pendingAnchor = nil
            if !pinnedToBottom {
                metrics.lockAnchor = anchor
                metrics.lockAnchorFixAttempts = 0
            }
            didWork = true
        }
        if let follow = metrics.pendingFollow {
            applyFollowCorrection(follow)
            metrics.pendingFollow = nil
            didWork = true
        }
        return didWork
    }

 /// 可视锚点回位：锚点式 scrollTo（id + 行内比例点），系统负责物化。
    private func applyAnchorCorrection(_ anchor: AnchorSnapshot) {
        guard displayedItems.contains(where: { $0.id == anchor.id }) else { return }
        let fraction = MessageListUpdatePolicy.anchorFraction(
            relativeY: anchor.relativeY,
            rowHeight: anchor.rowHeight,
            viewportHeight: metrics.viewportHeight
        )
        if let fraction {
            scrollPosition.scrollTo(id: anchor.id, anchor: UnitPoint(x: 0, y: fraction))
        } else {
            scrollPosition.scrollTo(id: anchor.id, anchor: .top)
        }
        metrics.anchorScrollToCount += 1
        if isUserInteractingNow() {
            metrics.anchorCorrectionDuringGesture += 1
        }
        scrollDebug("anchor scrollTo(id) relativeY=\(fmt(anchor.relativeY)) fraction=\(fraction.map { fmt($0) } ?? "-") \(scrollGeometrySummary())")
        scheduleAnchorVerification(anchor)
    }

 /// 锚点回位后的残差复核（只一次）：按行 frame 真值差再放一次。
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
              let frame = metrics.rowFrames[verify.id] else { return }
        let currentRelativeY = frame.minY - metrics.viewportFrame.minY
        if let delta = ScrollFollowPolicy.compensationDelta(oldRelativeY: verify.relativeY, newRelativeY: currentRelativeY),
           let fraction = MessageListUpdatePolicy.anchorFraction(
               relativeY: verify.relativeY,
               rowHeight: frame.height,
               viewportHeight: metrics.viewportHeight
           ) {
 // 残差仍超容差：再发一次锚点意图（不是搬 offset）。
            scrollPosition.scrollTo(id: verify.id, anchor: UnitPoint(x: 0, y: fraction))
            metrics.anchorResidualFixes += 1
            metrics.lastAnchorResidual = delta
            scrollDebug("anchor verify residual=\(fmt(delta)) fixes=\(metrics.anchorResidualFixes)")
        } else {
            metrics.lastAnchorResidual = currentRelativeY - verify.relativeY
        }
        metrics.pendingVerify = nil
    }

 /// 贴底跟随（edge 意图）：immediate 无动画；animated 由 withAnimation 缓动。
    private func applyFollowCorrection(_ mode: FollowMode) {
        metrics.pendingVerify = nil
        switch mode {
        case .immediate:
            scrollPosition.scrollTo(edge: .bottom)
        case .animated:
            withAnimation(.easeOut(duration: 0.16)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        metrics.followCount += 1
        scrollDebug("follow mode=\(mode == .animated ? "anim" : "now") \(scrollGeometrySummary())")
    }

 // MARK: - 首屏贴底定位（初值 edge=.bottom + 自证 + 有界重试）

    private func advanceInitialBottomIfNeeded() {
        guard !didInitialBottom else { return }
        guard metrics.facts.viewportHeight > 1 else { return }
        if metrics.facts.distanceFromBottom <= ScrollFollowPolicy.initialBottomTolerance {
            finishInitialBottom()
            return
        }
        guard !metrics.initialAttemptPending else { return }
        metrics.initialAttemptPending = true
        metrics.initialBottomAttempts += 1
 // 初值 ScrollPosition(edge:.bottom) 已请求贴底；自证失败时按重试链再发。
        scrollPosition.scrollTo(edge: .bottom)
        scrollDebug("initial bottom attempt=\(metrics.initialBottomAttempts) distance=\(fmt(metrics.facts.distanceFromBottom)) \(scrollGeometrySummary())")
        if metrics.initialBottomAttempts >= ScrollFollowPolicy.initialBottomMaxAttempts {
            finishInitialBottom() // 兜底：绝不无限隐藏内容。
        } else {
            let delay = MessageListUpdatePolicy.stickRetryDelay(
                attempt: metrics.initialBottomAttempts - 1,
                isAtBottom: metrics.facts.distanceFromBottom <= MessageListUpdatePolicy.stickBottomTolerance,
                elapsed: 0
            ) ?? 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.metrics.initialAttemptPending = false
                self.advanceInitialBottomIfNeeded()
            }
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
        let distance = metrics.facts.distanceFromBottom
        didInitialBottom = true
        isContentReady = true
        metrics.pendingAnchor = nil
        metrics.settleFollowUntil = CACurrentMediaTime() + 1.5
        metrics.settleFollowAttempts = 0
        metrics.lockAnchor = nil
        metrics.pendingPrependHeight = false
        scrollDebug("initial bottom done distance=\(fmt(distance)) attempts=\(metrics.initialBottomAttempts) \(scrollGeometrySummary())")
        onFirstContent()
    }

 // MARK: - 贴底收敛 / 空闲取证

 /// 内容变化/首屏定位后 1.5s 内的「贴底收敛」：LazyVStack 内容高度估算会在布局后
 /// 继续微调，单拍 edge 意图可能留下残差；窗口内有界地再贴一次。
    private func settlePinnedBottomIfNeeded() {
        guard didInitialBottom, pinnedToBottom, !isUserInteractingNow(),
              metrics.pendingAnchor == nil, metrics.pendingFollow == nil else { return }
        let now = CACurrentMediaTime()
        guard now < metrics.settleFollowUntil, metrics.settleFollowAttempts < 8 else { return }
        let distance = metrics.facts.distanceFromBottom
        guard distance.isFinite, distance > 1.5 else { return }
        metrics.settleFollowAttempts += 1
        scrollPosition.scrollTo(edge: .bottom)
        metrics.followCount += 1
    }

 /// 读历史时「内容锁定锚点」：布局成长后按真实 frame 差再放一次（锚点意图）。
    private func applyIdleLayoutGrowthCompensation() {
        guard didInitialBottom, !pinnedToBottom, !isUserInteractingNow() else { return }
        guard let lock = metrics.lockAnchor,
              metrics.lockAnchorFixAttempts < 12,
              !metrics.viewportFrame.isNull,
              let frame = metrics.rowFrames[lock.id] else { return }
        let currentRelativeY = frame.minY - metrics.viewportFrame.minY
        if let delta = ScrollFollowPolicy.compensationDelta(oldRelativeY: lock.relativeY, newRelativeY: currentRelativeY),
           let fraction = MessageListUpdatePolicy.anchorFraction(
               relativeY: lock.relativeY,
               rowHeight: frame.height,
               viewportHeight: metrics.viewportHeight
           ) {
            scrollPosition.scrollTo(id: lock.id, anchor: UnitPoint(x: 0, y: fraction))
            metrics.lockAnchorFixAttempts += 1
            metrics.lockAnchorFixes += 1
            scrollDebug("growth lock delta=\(fmt(delta)) \(scrollGeometrySummary())")
        }
    }

 /// 空闲态稳定性取证：pinned 且无 pending 时，距底距离不应变大（变大 = 列表自己滚）。
    private func trackIdleBottomStability() {
        guard didInitialBottom, pinnedToBottom,
              metrics.pendingAnchor == nil, metrics.pendingFollow == nil else { return }
        guard !isUserInteractingNow() else { return }
        guard CACurrentMediaTime() >= metrics.settleFollowUntil else { return }
        let distance = metrics.facts.distanceFromBottom
        guard distance.isFinite else { return }
        if distance <= 2.5 { metrics.hasSettledOnce = true }
        guard metrics.hasSettledOnce else { return }
        if distance > metrics.maxIdleDistance { metrics.maxIdleDistance = distance }
        if distance > ScrollFollowPolicy.settlePinTolerance + 2 { metrics.idleDriftCount += 1 }
    }

 // MARK: - 诊断/取证

 /// 手势窗口内的逐帧 offset 位移（E2E 用它断言「1:1 跟手、无跳变帧」）。
    private func traceGestureOffsetIfNeeded(offset: CGFloat) {
        if metrics.lastTraceOffset < 0 {
            metrics.lastTraceOffset = offset
            return
        }
        let delta = offset - metrics.lastTraceOffset
        guard abs(delta) > 0.5 else { metrics.lastTraceOffset = offset; return }
        if isUserInteractingNow() {
            metrics.gestureFrameCount += 1
            if abs(delta) > metrics.gestureMaxFrameDelta { metrics.gestureMaxFrameDelta = abs(delta) }
        }
        metrics.lastTraceOffset = offset
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

 /// 几何快照：facts/坐标/distance/offset/contentHeight 全量打印，真机可直接对照。
    private func scrollGeometrySummary() -> String {
        let viewportMaxY = metrics.viewportFrame.isNull ? -9999 : metrics.viewportFrame.maxY
        return "facts=1"
            + " viewportMaxY=\(fmt(viewportMaxY))"
            + " viewportH=\(fmt(metrics.viewportHeight))"
            + " bottomMaxY=\(fmt(metrics.bottomFrame?.maxY ?? -9999))"
            + " distance=\(fmt(metrics.facts.distanceFromBottom))"
            + " offset=\(fmt(metrics.facts.offset))"
            + " contentH=\(fmt(metrics.contentHeight))"
            + " contentSize=\(fmt(metrics.facts.contentHeight))"
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
        let distance = metrics.facts.distanceFromBottom
        let distanceText = distance.isFinite ? fmt(distance) : "-9999"
        let windowStartIndex = displayedItems.first.flatMap { first in
            items.firstIndex(where: { $0.id == first.id })
        } ?? -1
        return "o=\(fmt(metrics.facts.offset)) d=\(distanceText) i=\(displayedItems.count)/\(items.count) ws=\(windowStartIndex) pre=\(metrics.prependCount) ch=\(fmt(metrics.facts.contentHeight)) vh=\(fmt(metrics.viewportHeight)) pin=\(pinnedToBottom ? 1 : 0) ini=\(didInitialBottom ? 1 : 0) gm=\(fmt(metrics.gestureMaxFrameDelta)) ac=\(metrics.anchorScrollToCount) cs=\(metrics.contentSizeFollows) sf=\(metrics.anchorScrollToCount) acg=\(metrics.anchorCorrectionDuringGesture) fw=\(metrics.followCount) rs=\(fmt(metrics.lastAnchorResidual)) sy=\(metrics.syncCorrectionCount) lag=\(metrics.asyncCorrectionCount) dr=\(metrics.idleDriftCount) mx=\(fmt(metrics.maxIdleDistance)) kvo=\(metrics.contentSizeFollows) pan=\(metrics.panSeen ? 1 : 0) ptrk=\(metrics.panTrackingSeen ? 1 : 0) pdec=\(metrics.panDecelSeen ? 1 : 0) it=\(isUserInteractingNow() ? 1 : 0) drag=\(metrics.isDragging ? 1 : 0)"
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
        let distance = metrics.facts.distanceFromBottom
        let distanceText = distance.isFinite ? fmt(distance) : "-1"
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
            + ";topMinY=" + fmt(metrics.facts.offset)
            + ";offset=" + fmt(metrics.facts.offset)
            + ";contentH=" + fmt(metrics.contentHeight)
            + ";handle=1"
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
            + ";anchorFixes=" + String(metrics.anchorScrollToCount + metrics.anchorResidualFixes + metrics.lockAnchorFixes)
            + ";pref=" + String(metrics.anchorPreferenceCount)
            + ";pb=0"
            + ";kvo=" + String(metrics.contentSizeFollows)
            + ";pan=" + (metrics.panSeen ? "1" : "0")
            + ";ptrk=" + (metrics.panTrackingSeen ? "1" : "0")
            + ";pdec=" + (metrics.panDecelSeen ? "1" : "0")
            + ";os=" + fmt(overscrollAmount())
            + ";csf=0"
            + ";lk=" + String(metrics.lockAnchorFixes)
            + ";sa=" + String(metrics.settleFollowAttempts)
            + ";contentSize=" + fmt(metrics.facts.contentHeight)
            + ";ready=" + (isContentReady ? "1" : "0")
            + ";wstart=" + String(windowStartIndex)
            + ";win=" + String(MessageListWindowPolicy.defaultWindow)
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

// MARK: - 支撑类型

/// 官方 ScrollGeometry 的 Equatable 投影：一次观察拿到全部真值（替代 KVO/直读）。
struct ScrollFacts: Equatable {
 /// 内容总高度（contentSize.height）。
    var contentHeight: CGFloat
 /// 当前 offset（含 top inset 归一，>= 0）。
    var offset: CGFloat
 /// 视口（容器）高度。
    var viewportHeight: CGFloat
 /// 距底距离（0 = 贴底；内容不足一屏时 0）。
    var distanceFromBottom: CGFloat
 /// 过滚量（offset 超过最大 offset 的部分）。
    var overscroll: CGFloat

    init(geometry: ScrollGeometry) {
        let insets = geometry.contentInsets
        let maxOffset = geometry.contentSize.height + insets.bottom - geometry.containerSize.height
        self.contentHeight = geometry.contentSize.height
        self.offset = max(0, geometry.contentOffset.y + insets.top)
        self.viewportHeight = geometry.containerSize.height
        self.distanceFromBottom = maxOffset <= -insets.top + 1 ? 0 : maxOffset - geometry.contentOffset.y
        self.overscroll = geometry.contentOffset.y - maxOffset
    }

    init(contentHeight: CGFloat, offset: CGFloat, viewportHeight: CGFloat, distanceFromBottom: CGFloat, overscroll: CGFloat) {
        self.contentHeight = contentHeight
        self.offset = offset
        self.viewportHeight = viewportHeight
        self.distanceFromBottom = distanceFromBottom
        self.overscroll = overscroll
    }
}

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
/// - 用户滚动到窗口顶部预留区时，一次向上扩展 100 行（纯 prepend，锚点式 scrollTo 回位）。
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
    static func resolvedStartIndex(currentStartID: String?,
                                   itemIDs: [String],
                                   window: Int = defaultWindow) -> Int {
        if let id = currentStartID, let index = itemIDs.firstIndex(of: id) {
            return index
        }
        return initialStartIndex(itemCount: itemIDs.count, window: window)
    }

 /// 窗口首行进入视口顶部预留区（或已到视口内）时，需要向上扩展。
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

/// 滚动跟随的纯逻辑：可单测、不依赖 UI。
///
/// 不变量（回归测试必须覆盖）：
/// 1. 无内容变化时不得产生任何滚动；
/// 2. 后台历史 prepend 后，可见内容相对屏幕位置不变（≤1 物理像素）；
/// 3. pinned 只在用户手势结束 settle 时改写，内容变化绝不改 pinned。
enum ScrollFollowPolicy {
 /// 手势结束「判定贴底」的容差（pt）：≤ 12pt 视为用户想回到底部。
    static let settlePinTolerance: CGFloat = 12
 /// 锚点回位的最小位移（pt）：低于该值不滚动（3x 屏 1 物理像素 = 1/3 pt）。
    static let compensationTolerance: CGFloat = 0.34
 /// 贴底跟随时「缓动」与「直接跳」的分界（pt）。
    static let animatedFollowThreshold: CGFloat = 60
 /// 首屏贴底定位的判定容差（pt）。
    static let initialBottomTolerance: CGFloat = 2
 /// 首屏贴底定位的最大布局重试次数。
    static let initialBottomMaxAttempts: Int = 8

 /// 首个完整可见行：返回（行 id, 行顶相对视口顶部的偏移, 行高）。
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

 /// 锚点回位量（新相对偏移 - 旧相对偏移）；|值| <= tolerance 时返回 nil（不滚动）。
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
 /// 官方几何观察的最新事实。
    var facts = ScrollFacts(contentHeight: 0, offset: 0, viewportHeight: 0, distanceFromBottom: .greatestFiniteMagnitude, overscroll: 0)
 /// LazyVStack 内容高度（preference 值，仅诊断）。
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
 /// ScrollView 自身的全局 frame（与行 frame 同坐标系，锚点捕获用）。
    var viewportFrame: CGRect = .null
    var rowFrames: [String: CGRect] = [:]
 /// 底部哨兵行的全局 frame（nil = 未被 LazyVStack 物化 = 距底很远）。
    var bottomFrame: CGRect?

 // MARK: - 交互（相位驱动）
 /// 用户拖拽中（ScrollPhase.tracking/.interacting）。
    var isDragging = false
 /// 松手后的交互静默期截止时间（惯性/回弹也算用户交互）。
    var interactingUntil: CFTimeInterval = 0

 // MARK: - 布局后校正
 /// 待回位的可视锚点（内容变化前捕获）。
    var pendingAnchor: AnchorSnapshot?
 /// 待执行的贴底跟随模式。
    var pendingFollow: FollowMode?
 /// 异步兜底校正是否已排队（去重）。
    var correctionScheduled = false
 /// 锚点回位后待复核的锚点（只复核一次）。
    var pendingVerify: AnchorSnapshot?
    var verifyScheduled = false
 /// 应用新内容前的 contentSize.height（诊断）。
    var contentSizeAtApply: CGFloat = -1
 /// 尾部两行 id 是否未变（纯 prepend 判定）。
    var tailStable = false
 /// 窗口扩展 prepend 标记。
    var pendingPrependHeight = false

 // MARK: - 首屏贴底定位
    var initialBottomAttempts = 0
    var initialAttemptPending = false

 // MARK: - 诊断/取证
 /// 逐帧 offset 采样的上一值（手势窗口内统计单帧最大位移）。
    var lastTraceOffset: CGFloat = -1
    var gestureMaxFrameDelta: CGFloat = 0
    var gestureFrameCount = 0
    var hasSettledOnce = false
    var maxIdleDistance: CGFloat = 0
    var idleDriftCount = 0
    var prependCount = 0
    var anchorPreferenceCount = 0
    var anchorScrollToCount = 0
    var anchorCorrectionDuringGesture = 0
    var anchorResidualFixes = 0
    var followCount = 0
    var lastAnchorResidual: CGFloat = 0
    var syncCorrectionCount = 0
    var asyncCorrectionCount = 0
    var settleFollowUntil: CFTimeInterval = 0
    var settleFollowAttempts = 0
    var contentSizeFollows = 0
    var panSeen = false
    var panTrackingSeen = false
    var panDecelSeen = false
    var windowExpansionScheduled = false
    var lockAnchor: AnchorSnapshot?
    var lockAnchorFixes = 0
    var lockAnchorFixAttempts = 0
}

// MARK: - PreferenceKeys（SwiftUI 原生测量）

private struct ListContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 底部哨兵行的全局 frame：贴底自证信号。哨兵行未物化时回到.null → 视为「距底很远」。
private struct ListBottomFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// ScrollView 自身的全局 frame：与哨兵行/行 frame 同坐标系。
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
