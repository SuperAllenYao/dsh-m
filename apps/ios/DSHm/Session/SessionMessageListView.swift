import Foundation
import QuartzCore
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

 /// 读历史（inverted，r7）：截掉 incoming 相对 displayed 的**尾部新行**
 /// （升序尾 = 新消息/新过程组 = 倒序渲染的布局顶 insert，会推动视口）。
 /// 保留：已显示行的原地更新、旧端（头部）扩展——二者渲染为尾部 append，零漂移。
 /// 尾行被替换（流式 liveText → process 组）时从尾往前找第一个幸存行截断，
 /// 冻结继续生效；displayed 的行全部不在 incoming（快照替换）才全量应用。
    static func withoutTailInsertions(displayed: [SessionMessageItem], incoming: [SessionMessageItem]) -> [SessionMessageItem] {
        guard !displayed.isEmpty else { return incoming }
        for survivorID in displayed.reversed().map(\.id) {
            if let idx = incoming.lastIndex(where: { $0.id == survivorID }) {
                return Array(incoming[...idx])
            }
        }
        return incoming
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
/// **SwiftUI 消息列表（回退后端）**。
///
/// 设计决策方案 A 之后，生产默认走 UIKit 循环复用后端
/// （`SessionMessageUIKitListView`，见 SessionMessageListBackend.swift 的 façade）；
/// 本实现保留为回退路径（env `DSHM_LIST_BACKEND=swiftui`），验收通过前不删除。
/// 两个后端共用本文件里的纯逻辑层（SessionMessageItem / MessageListUpdatePolicy /
/// ScrollFacts / MessageListWindowPolicy / ScrollFollowPolicy 等）。
struct SessionMessageSwiftUIListView: View {
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
 /// v7：子代理消息步骤行点击 → 打开该子代理会话（nil = 行不可点）。
    var onOpenRelay: ((RelayCard) -> Void)? = nil
    let onOpenTool: (ToolCallItem) -> Void
    let onOpenFileChanges: (TurnFileChanges) -> Void
    let onNearBottomChange: (Bool) -> Void
    let onUserScrolled: () -> Void
    let onFirstContent: () -> Void
    let onRetry: () -> Void
 /// 历史补齐进行中（VM `historyFillProgress!= nil`；上层进度条用）。
 /// inverted：历史补齐 = 倒序尾部 append = 布局远端插入，
 /// offset 数学上零漂移——旧「冻结攒批」机制删除，此参数仅为接口兼容保留。
    var isFillingHistory: Bool = false

    private static let rowVerticalPadding: CGFloat = Theme.Spacing.s / 2

 /// 程序化滚动的唯一通道（iOS 18 ScrollPosition 值绑定）：
 /// **edge 滚动是 offset 语义，不依赖行物化**——行绑定 scrollTo(id:) 对未物化
 /// 行静默失败(取证：视口冻结在顶时 bottomID 哨兵在几万 pt 外，
 /// 交替赋值也不滚），edge 滚动始终有效。跟随用「滞后(40pt)+节流(120ms)」防
 /// LazyVStack 估值抖动期的反复补偿（=弹跳）。
    @State private var scrollPosition = ScrollPosition()

 /// 当前渲染的显示窗口（最近 N 行；不是全量 items）。
    @State private var displayedItems: [SessionMessageItem]
 /// 显示窗口起点行 id：**nil = 默认窗口（最近 N 行，跟随新内容）**；
 /// 非 nil = 用户向上扩展过，窗口固定从该行开始（autoload 更早历史不再插入显示）。
    @State private var windowStartItemID: String?
 /// 显式「贴底跟随」状态（初值 true）：只有「用户手势结束后的 settle 判定」能改它，
 /// 程序化内容变化永远不能把它改成 false（旧实现的卡死根因）。
    @State private var pinnedToBottom = true
 // inverted：无首屏定位链（offset=0 天然贴最新），didInitialBottom 状态删除。
 /// 首屏定位完成、内容可以显示。
    @State private var isContentReady = false
 /// 滚动测量真值（ScrollMetrics 是 class：写字段不会触发 SwiftUI 失效，
 /// 只有 HUD/探针在 TimelineView 里读当前值）。
    @State private var metrics = ScrollMetrics()
 /// 过程组步骤内容高度（key = FlowRowGroup.id，来自 ProcessGroupStepsHeightKey）：
 /// 点击组头瞬间据此预测行高 Δ，同事务反向补偿 contentOffset（组头定住）。
 /// 用**非可观察引用**持有（不是 @State）：滚动中行物化会持续上报测量值，
 /// 写成 @State 时每次上报都会让列表 body 整表重算。
    @State private var groupStepsHeightStore = GroupStepsHeightStore()
 /// 过程组展开/收起的显式驱动动画（行高与 offset 同帧插值，组头逐帧定住）。
    @State private var groupToggleRun: GroupToggleRun?
 /// 动画中的步骤内容高度覆盖（key = FlowRowGroup.id；缺省 = 自然高度）。
    @State private var groupToggleOverride: [String: CGFloat] = [:]
 /// 展开/收起动画的帧时钟（CADisplayLink；与屏幕刷新对齐，替代 Task.sleep 非对齐唤醒）。
    @State private var groupToggleTicker: GroupToggleTicker?
 /// P0 真机取证：App 内自动连续滚动（DSHM_AUTOSCROLL=1）——不经过 XCUITest
 /// 手势合成，因此没有 XCTest 无障碍快照（每次 90–290ms）污染，能测到真实的
 /// 渲染/行物化掉帧。仅 DEBUG + env 开启，生产零影响。
    @State private var autoScrollTicker: GroupToggleTicker?
 /// Reduce Motion：补偿跟随系统——高度与 offset 都走瞬时切换（终态一致）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
 /// 动态字号：步骤高度缓存按「宽度 + 字号」失效（行高随字号变化）。
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
 /// 语言：步骤行文案来自本地化库，切换语言后行高会变 ⇒ 缓存同样要失效。
    @Environment(\.locale) private var locale
 /// 自绘滚动条数据镜像（@Published 驱动指示条重算；与 metrics 分离避免列表 body 重算）。
    @StateObject private var indicatorModel = ScrollIndicatorModel()
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
        self.onOpenRelay = onOpenRelay
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

 /// 列表内容签名：**O(1)**（只看尾部有限行）。
 /// body 每次更新都会求值它（含展开/收起动画的逐帧更新、流式更新），
 /// 旧实现对 items 全量 reverse 遍历 + 字符串拼接，长会话下是每帧固定开销。
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

 /// 尾部签名扫描窗口：非 group 行（文件变更卡 / 流式文本 / 错误行）只出现在尾部，
 /// 且尾部最多 4 条；16 行窗口足以覆盖，超出窗口的行变化由 count/firstID/lastID
 /// 以及 newestGroupFingerprint 触发，不会漏更新。
    private static let tailSignatureScanLimit = 16
    private static let tailSignatureMaxParts = 8

    private var tailSignature: String {
        var parts: [String] = []
        var scanned = 0
        for item in items.reversed() {
            if scanned >= Self.tailSignatureScanLimit || parts.count >= Self.tailSignatureMaxParts {
                break
            }
            scanned += 1
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
        var scanned = 0
        for item in items.reversed() {
            if scanned >= Self.tailSignatureScanLimit { return nil }
            scanned += 1
            if case .liveText(let text) = item { return text }
        }
        return nil
    }

    var body: some View {
        GeometryReader { outer in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
 // inverted 渲染：窗口倒序（最新在数组头 = 布局顶 = 视觉底部）。
 // items/displayedItems 数据层保持升序，只有渲染序列反转。
                    ForEach(displayedItems.reversed(), id: \.id) { item in
                        rowView(item, isNewest: isNewest(item))
 // 帧级探针：标记「行进入视图层级（物化）」的瞬间 ——
 // 滚动长帧归因用（巨型/多步骤行首次物化的布局成本）。
                            .onAppear {
                                guard ScrollHitchProbe.isEnabled else { return }
                                ScrollHitchProbe.mark("rowAppear", [
                                    "id": item.id,
                                    "kind": item.rowKindForProbe,
                                    "steps": item.stepCountForProbe,
                                    "disp": displayedItems.count,
                                ])
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Spacing.pageInset)
                            .padding(.vertical, Self.rowVerticalPadding)
 // 行内容正读：对抗整体 scaleEffect 的双轴翻转。
                            .rotationEffect(.radians(.pi))
                            .id(item.id)
                    }
                }
 // P0：删除「内容高度 GeometryReader preference」。
 // 它挂在每个布局都重新求值的 LazyVStack 上，真机实测在一次滚动里
 // 可以自激成 866 次/秒的 onPreferenceChange（随后 3s 主线程卡死）。
 // 内容高度已有官方 ScrollGeometry（onScrollGeometryChange 的
 // contentSize）作为权威真值，不再需要额外测量链。
 // 无内容（无缓存会话拉取中）隐藏列表，骨架屏兜底。
                .opacity(displayedItems.isEmpty ? 0 : 1)
            }
 // 官方几何观察（替代 KVO contentSize / offset 读取）：
 // 一个 Equatable 投影拿到 全部真值。挂在 scale 内层（取证：读数正常）。
            .onScrollGeometryChange(for: ScrollFacts.self) { geometry in
                ScrollFacts(geometry: geometry)
            } action: { old, new in
                handleScrollFactsChange(old: old, new: new)
            }
 // 官方滚动相位（替代 isDragging/isDecelerating/isTracking + settle 轮询）。
            .onScrollPhaseChange { oldPhase, newPhase in
                handleScrollPhaseChange(old: oldPhase, new: newPhase)
            }
 // 系统指示条在 scale 内层就藏掉（翻转会跑到左缘且方向反）。
            .scrollIndicators(.hidden)
 // inverted 挂载：
 // - scaleEffect(x:-1,y:-1) 双轴翻转 + 每行 rotationEffect(.pi) = 视觉
 // 180° 旋转；数据头（最新）显示在视觉底部。
 // - rotationEffect 挂 ScrollView 会杀死滚动管线（V1：程序化 scrollTo 与
 // 手势全失效）；scaleEffect 不影响滚动。scrollPosition 挂 scale 外层。
 // - offset=0 即贴最新（免初始定位）；历史补齐 = 倒序尾部 append = 布局
 // 远端插入，offset 数学上零漂移——删除全部补偿链。
 // - edge 语义反转：.top = 布局顶 = 视觉底（最新）；.bottom = 最旧端。
            .scaleEffect(x: -1, y: -1)
            .scrollPosition($scrollPosition)

 // 过程组步骤内容高度（折叠态由隐藏副本持续上报）：组头点击补偿的数据源。
            .onPreferenceChange(ProcessGroupStepsHeightKey.self) { heights in
 // 帧级探针：步骤组测量 preference 每次变化都意味着「组被重新测量」
 // （滚动中行物化/折叠组隐藏副本）——是滚动卡顿的重点嫌疑点。
                ScrollHitchProbe.mark("groupStepsHeights", [
                    "count": heights.count,
                    "changed": heights.count != groupStepsHeightStore.heights.count ? 1 : 0,
                ])
 // 只写非可观察存储：滚动中行物化时的测量上报不再触发整表 body 重算。
 // 合并而不是替换（缓存命中的组不再上报，不能被冲掉）。
                groupStepsHeightStore.update(heights)
            }
 // viewport frame 测量：挂在 scale/position 外层（layout frame 不受
 // 翻转影响），供探针 bottomMaxY/viewportMaxY 输出（E2E 契约）。
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
            }
 // 自绘滚动条（系统指示条被翻转错位；对标 UIKit 外观，语义贴底=最新）。
            .overlay(alignment: .trailing) {
                InvertedScrollIndicator(model: indicatorModel)
            }
 // 骨架屏（无内容拉取中）：挂在 scale 外层不被翻转。
            .overlay {
                if displayedItems.isEmpty {
                    VStack(spacing: Theme.Spacing.s) {
                        Spacer()
                        ProgressView()
                            .tint(Theme.Palette.accent)
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            ForEach(0..<4, id: \.self) { index in
                                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                                    .fill(Theme.Palette.surface)
                                    .frame(height: index == 1 ? 64 : 40)
                                    .frame(maxWidth: index == 2 ? 220 : .infinity)
                                    .opacity(0.6)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.pageInset)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("session-firstscreen-locating")
                }
            }
            .onAppear {
                metrics.viewportHeight = outer.size.height
                groupStepsHeightStore.prepare(
                    layoutSignature: Self.stepsCacheLayoutSignature(
                        width: outer.size.width,
                        dynamicTypeSize: dynamicTypeSize,
                        locale: locale
                    )
                )
 // 帧级卡顿探针：列表上屏即开始逐帧采样（DEBUG + DSHM_HITCHDBG=1 才生效）。
                ScrollHitchProbe.start()
                startAutoScrollIfNeeded()
 // 首屏窗口文本行后台预解析（用户随时可能开始滑）。
                MarkdownPrewarm.prewarm(items: displayedItems)
 // inverted：offset=0 天然贴最新，无初始定位链；已有内容直接显示。
                if !displayedItems.isEmpty, !isContentReady {
                    isContentReady = true
                    onFirstContent()
                }
            }
            .onChange(of: outer.size.height) { _, height in
                metrics.viewportHeight = height
 // 视口尺寸变化无需滚动指令：offset=0 恒贴最新；系统自动夹 maxOffset。
            }
            .onChange(of: outer.size.width) { _, width in
                groupStepsHeightStore.prepare(
                    layoutSignature: Self.stepsCacheLayoutSignature(
                        width: width,
                        dynamicTypeSize: dynamicTypeSize,
                        locale: locale
                    )
                )
            }
            .onChange(of: dynamicTypeSize) { _, size in
                groupStepsHeightStore.prepare(
                    layoutSignature: Self.stepsCacheLayoutSignature(
                        width: outer.size.width,
                        dynamicTypeSize: size,
                        locale: locale
                    )
                )
            }
            .onChange(of: locale) { _, newLocale in
                groupStepsHeightStore.prepare(
                    layoutSignature: Self.stepsCacheLayoutSignature(
                        width: outer.size.width,
                        dynamicTypeSize: dynamicTypeSize,
                        locale: newLocale
                    )
                )
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
                windowStartItemID = nil
                withAnimation(nil) {
                    displayedItems = MessageListWindowPolicy.initialWindow(items: items)
                }
 // inverted edge 语义反转：.top = 布局顶 = 视觉底（最新）。
                scrollWithoutAnimation("token") { scrollPosition.scrollTo(edge: .top) }
                metrics.followCount += 1
            }
            .onDisappear {
                ScrollHitchProbe.stop()
                metrics.windowExpansionScheduled = false
                groupToggleTicker?.stop()
                groupToggleTicker = nil
                groupToggleRun = nil
                groupToggleOverride = [:]
                autoScrollTicker?.stop()
                autoScrollTicker = nil
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
                override: processGroupModes[group.id],
                stepCount: group.stepCount
            )
 // 步骤内容签名 + 高度缓存：命中时折叠组不再渲染隐藏测量副本（见
 // GroupStepsHeightStore / ProcessGroupView.cachedStepsHeight）。
            let contentSignature = group.stepsContentSignature
            let cachedStepsHeight = groupStepsHeightStore.height(
                forGroup: group.id,
                contentSignature: contentSignature
            )
 // 公式估算：缓存未命中时先给出 Δ（不再为测量而把整组步骤渲染一遍）。
            let estimatedStepsHeight = group.estimatedStepsHeight
            let stepCount = group.stepCount
 // 巨型组展开态的首屏行高（initialSteps 步 + 可能存在的「展开其余」按钮行）：
 // 巨型组不做逐帧动画，直接同帧切态 + 用这个 Δ 补偿 offset。
            let giantExpandedHeight = group.estimatedStepsHeight(
                limit: ProcessGroupStepsLayoutPolicy.initialSteps
            ) + (stepCount > ProcessGroupStepsLayoutPolicy.initialSteps
                ? ProcessGroupStepsLayoutPolicy.revealRowHeight
                : 0)
            FlowRowGroupView(
                group: group,
                sessionId: sessionId,
                attachments: attachments,
                pendingApprovalCallIds: pendingApprovalCallIds,
                subagentLabels: subagentLabels,
                isNewestGroupRunning: isNewest,
                mode: mode,
                animatedStepsHeight: groupToggleOverride[group.id],
                cachedStepsHeight: cachedStepsHeight,
                stepsContentSignature: contentSignature,
                onStepsHeightDelta: { delta in
                    handleGroupStepsHeightDelta(delta)
                },
                windowHeight: processGroupWindowHeight,
                onToggleMode: {
 // 显式驱动动画：行高与 offset 每帧同一次提交（组头逐帧定住）。
                    handleGroupModeToggle(
                        groupID: group.id,
                        contentSignature: contentSignature,
                        estimatedStepsHeight: estimatedStepsHeight,
                        giantExpandedHeight: giantExpandedHeight,
                        stepCount: stepCount,
                        currentMode: mode
                    )
                },
                onOpenReasoning: onOpenReasoning,
                onOpenTool: onOpenTool,
                onOpenRelay: onOpenRelay
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

 // MARK: - 过程组显示态切换：手驱动行高 + offset（组头逐帧定住）

 /// 一次展开/收起动画的参数：行高与 offset 用**同一条 easeOutCubic 曲线**
 /// （GroupToggleAnimation）插值，组头逐帧定住；同时累计逐帧主线程成本供取证。
    private struct GroupToggleRun {
        var groupID: String
        var targetMode: ProcessGroupMode
        var fromStepsHeight: CGFloat
        var toStepsHeight: CGFloat
        var fromOffset: CGFloat
        var targetOffset: CGFloat
 /// true = 收起（展开态保持到终帧再落实 collapsed）。
        var isCollapse: Bool
        var start: CFTimeInterval
 /// 逐帧主线程成本（DEBUG 探针：证明动画帧内没有重活）。
        var frameCost = GroupToggleAnimation.FrameCost()
    }

    private static let groupToggleDuration = GroupToggleAnimation.duration
 /// Reduce Motion 下的驱动时长（≈2 帧，视觉瞬时但保持「高度 + offset 同帧」语义）。
    private static let groupToggleReducedDuration = GroupToggleAnimation.reducedMotionDuration

 /// 点击过程组头：手驱动「步骤内容高度 + contentOffset」同帧插值，组头逐帧定住。
 ///
 /// inverted 列表几何：组头屏幕位置 = 视口底 + offset −
 /// 组行内容坐标 maxY；组行高度变化 Δ 时组头反向漂移 Δ。步骤内容高度是行高
 /// 唯一变化的量（组头与间距不变），offset 同量移动 Δ 即可定住组头。
 ///
 /// 为什么不用「模式变化 + withAnimation(scrollTo)」隐式动画（首版实测）：
 /// 展开时目标 offset = from + Δ 超出**当前**内容高度的 maxOffset（内容还没长
 /// 出来），ScrollPosition 被 clamp（取证：off=485=maxOff，target=833 未生效，
 /// 组头跳 348）。手驱动每帧把「高度 override + offset」写进同一次状态提交，
 /// 目标恒在当帧可滚动范围内，两者插值参数相同 ⇒ 组头不动。
 /// Reduce Motion：整段动画压成两帧瞬时提交（终态一致、无过渡）。
    private func handleGroupModeToggle(
        groupID: String,
        contentSignature: String,
        estimatedStepsHeight: CGFloat,
        giantExpandedHeight: CGFloat,
        stepCount: Int,
        currentMode: ProcessGroupMode
    ) {
 // 动画进行中忽略再次点击（280ms 窗口；避免出现两个锚点/中途反向）。
        guard groupToggleRun == nil else { return }
        let targetMode = ProcessGroupModeResolver.toggled(currentMode)
        let facts = metrics.facts
 // 设计决策：巨型组不做逐帧高度动画（Δ 可能上万 pt）——
 // 同帧切态 + 一次 offset 补偿，组头仍钉住；普通组继续走 easeOutCubic 280ms。
        if ProcessGroupStepsLayoutPolicy.isGiant(stepCount) {
            handleGiantGroupModeToggle(
                groupID: groupID,
                contentSignature: contentSignature,
                estimatedStepsHeight: estimatedStepsHeight,
                targetMode: targetMode,
                giantExpandedHeight: giantExpandedHeight,
                currentMode: currentMode
            )
            return
        }
 // 高度来源优先级：内容签名命中的实测缓存 > 公式估算（步骤行固定行高，
 // 误差 ≤ 高亮行数）。缓存签名不一致（折叠期间内容变化）时**不用旧值**。
        let stepsHeight = max(
            0,
            groupStepsHeightStore.height(forGroup: groupID, contentSignature: contentSignature)
                ?? estimatedStepsHeight
        )
        let delta = ScrollFollowPolicy.toggleHeightDelta(
            from: currentMode,
            to: targetMode,
            stepsHeight: stepsHeight
        )
        let targetOffset = ScrollFollowPolicy.anchoredOffset(
            offset: facts.offset,
            delta: delta,
            maxOffset: facts.maxOffset
        )
 // 没有测量值 / 无可滚动余量：保持旧行为（直接切态，不做补偿）。
        guard abs(delta) > ScrollFollowPolicy.compensationTolerance,
              abs(targetOffset - facts.offset) > ScrollFollowPolicy.compensationTolerance
        else {
            onToggleGroupMode?(groupID, targetMode)
            return
        }
        let isCollapse = delta < 0
        let run = GroupToggleRun(
            groupID: groupID,
            targetMode: targetMode,
            fromStepsHeight: isCollapse ? stepsHeight : 0,
            toStepsHeight: isCollapse ? 0 : stepsHeight,
            fromOffset: facts.offset,
            targetOffset: targetOffset,
            isCollapse: isCollapse,
            start: CACurrentMediaTime()
        )
        metrics.lastScrollCommand = "toggle-anchor"
        ScrollHitchProbe.mark("toggleStart", [
            "group": groupID,
            "delta": Double(delta).rounded(),
            "from": currentMode.rawValue,
            "to": targetMode.rawValue,
        ])
 // 展开：立即切显示态（内容出现但被 override=0 裁掉），随后逐帧长出；
 // 收起：动画期间保持展开态（逐帧裁矮），终帧再落实 collapsed。
        groupToggleOverride[groupID] = run.fromStepsHeight
        if !isCollapse { onToggleGroupMode?(groupID, targetMode) }
        groupToggleRun = run
        scrollDebug("toggle enter group=\(groupID) \(currentMode.rawValue)->\(targetMode.rawValue) stepsH=\(fmt(stepsHeight)) off=\(fmt(facts.offset)) maxOff=\(fmt(facts.maxOffset)) target=\(fmt(targetOffset)) collapse=\(isCollapse ? 1 : 0) reduce=\(reduceMotion ? 1 : 0)")
 // Reduce Motion：压成 2 帧（≈33ms）的逐帧提交——仍保证「高度 + offset
 // 同帧生效」，避免单帧跳变时滚动被 clamp；终态与常规动画一致。
        startGroupToggleTicker(
            run,
            duration: reduceMotion ? Self.groupToggleReducedDuration : Self.groupToggleDuration
        )
    }

 /// 巨型组展开/收起：**不做逐帧动画**（设计决策）。
 ///
 /// 原因：巨型组步骤数可达 291 步（展开高度上万 pt），逐帧插值 + 每帧布局
 /// 反而会制造二次卡顿。这里在同一帧里完成「显示态切换 + contentOffset 补偿」，
 /// 组头仍然钉住（inverted：行高 +Δ ⇒ 组头屏幕位置 −Δ，offset 同量 +Δ）。
    private func handleGiantGroupModeToggle(
        groupID: String,
        contentSignature: String,
        estimatedStepsHeight: CGFloat,
        targetMode: ProcessGroupMode,
        giantExpandedHeight: CGFloat,
        currentMode: ProcessGroupMode
    ) {
        let facts = metrics.facts
        let isCollapse = targetMode == .collapsed
 // 收起 Δ：用实测缓存（巨型组展开态始终上报当前可见高度）；缓存未命中时
 // 退化为整组公式估算（只会让补偿略大/略小，不会跳动到别的位置）。
        let currentRenderedHeight = groupStepsHeightStore.height(
            forGroup: groupID,
            contentSignature: contentSignature
        ) ?? estimatedStepsHeight
        let delta: CGFloat = isCollapse ? -currentRenderedHeight : giantExpandedHeight
        guard abs(delta) > ScrollFollowPolicy.compensationTolerance else {
            onToggleGroupMode?(groupID, targetMode)
            return
        }
        let targetOffset = ScrollFollowPolicy.anchoredOffset(
            offset: facts.offset,
            delta: delta,
            maxOffset: facts.maxOffset
        )
        metrics.lastScrollCommand = "toggle-instant"
        ScrollHitchProbe.mark("toggleStart", [
            "group": groupID,
            "delta": Double(delta).rounded(),
            "from": currentMode.rawValue,
            "to": targetMode.rawValue,
            "giant": 1,
        ])
        onToggleGroupMode?(groupID, targetMode)
        withAnimation(nil) { scrollPosition.scrollTo(y: targetOffset) }
        if pinnedToBottom, targetOffset > ScrollFollowPolicy.compensationTolerance {
            pinnedToBottom = false
            onNearBottomChange(false)
        }
        ScrollHitchProbe.mark("toggleEnd", [
            "group": groupID,
            "collapse": isCollapse ? 1 : 0,
            "giant": 1,
            "delta": Double(delta).rounded(),
            "target": Double(targetOffset).rounded(),
        ])
        scrollDebug("toggle instant group=\(groupID) delta=\(fmt(delta)) off=\(fmt(facts.offset)) target=\(fmt(targetOffset))")
    }

 /// 巨型组「展开其余 N 步」：行高增加 delta，同帧补偿 offset（组头不跳）。
    private func handleGroupStepsHeightDelta(_ delta: CGFloat) {
        guard delta.isFinite, abs(delta) > ScrollFollowPolicy.compensationTolerance else { return }
        let facts = metrics.facts
        let targetOffset = ScrollFollowPolicy.anchoredOffset(
            offset: facts.offset,
            delta: delta,
            maxOffset: facts.maxOffset
        )
        metrics.lastScrollCommand = "giant-reveal"
        ScrollHitchProbe.mark("giantReveal", ["delta": Double(delta).rounded()])
        withAnimation(nil) { scrollPosition.scrollTo(y: targetOffset) }
        if pinnedToBottom, targetOffset > ScrollFollowPolicy.compensationTolerance {
            pinnedToBottom = false
            onNearBottomChange(false)
        }
    }

 /// 用 CADisplayLink 逐帧驱动（与屏幕刷新同拍）。
 ///
 /// 旧实现用 Task.sleep(16ms) 是**非对齐唤醒**：唤醒点相对 vsync 漂移，会出现
 /// 「一帧写两次 / 下一帧不写」的抖动；sleep 精度还受主线程负载影响（越忙越不匀）。
 /// CADisplayLink 在每次刷新回调，进度用 targetTimestamp（该帧上屏时间）计算，
 /// 逐帧严格单调、与刷新同拍。
    private func startGroupToggleTicker(_ run: GroupToggleRun, duration: Double) {
        groupToggleTicker?.stop()
        let ticker = GroupToggleTicker()
        groupToggleTicker = ticker
 // 注意：SessionMessageListView 是 struct，不能用 weak self；这里捕获的是
 // 视图值拷贝 + 共享 @State 存储，ticker.stop() 会释放闭包（无泄漏）。
        ticker.start { presentationTime in
            guard var current = self.groupToggleRun, current.groupID == run.groupID else {
                ticker.stop()
                return
            }
            let elapsed = presentationTime - current.start
            let linear = min(1, max(0, elapsed / max(0.001, duration)))
            if linear >= 1 {
                ticker.stop()
                self.groupToggleTicker = nil
                self.finishGroupToggle(current)
                return
            }
            let frameStarted = CACurrentMediaTime()
            self.applyGroupToggleFrame(
                current,
                eased: CGFloat(GroupToggleAnimation.eased(linear))
            )
            current.frameCost.add((CACurrentMediaTime() - frameStarted) * 1000)
            self.groupToggleRun = current
        }
    }

 /// 一帧：步骤内容高度 override 与 offset 在**同一次状态提交**里更新（无动画），
 /// 用同一条非线性曲线的同一个进度插值 ⇒ 组头逐帧定住。
    private func applyGroupToggleFrame(_ run: GroupToggleRun, eased: CGFloat) {
        let height = GroupToggleAnimation.interpolate(
            from: run.fromStepsHeight,
            to: run.toStepsHeight,
            progress: eased
        )
        let offset = GroupToggleAnimation.interpolate(
            from: run.fromOffset,
            to: run.targetOffset,
            progress: eased
        )
        groupToggleOverride[run.groupID] = height
        withAnimation(nil) { scrollPosition.scrollTo(y: offset) }
    }

 /// 终帧：高度归位、offset 落终值、收起态落实 collapsed（同一次提交）。
    private func finishGroupToggle(_ run: GroupToggleRun) {
        if run.isCollapse {
            groupToggleOverride[run.groupID] = 0
        } else {
            groupToggleOverride[run.groupID] = nil
        }
        withAnimation(nil) { scrollPosition.scrollTo(y: run.targetOffset) }
        if run.isCollapse {
            onToggleGroupMode?(run.groupID, run.targetMode)
            groupToggleOverride[run.groupID] = nil
        }
 // 补偿把视口推离最新端（展开 = 推开下方更新内容）＝不再贴底；
 // 回到底部仍由用户手势 settle 判定恢复（不在这里抢手势语义）。
        if pinnedToBottom, run.targetOffset > ScrollFollowPolicy.compensationTolerance {
            pinnedToBottom = false
            onNearBottomChange(false)
        }
        ScrollHitchProbe.mark("toggleEnd", [
            "group": run.groupID,
            "target": Double(run.targetOffset).rounded(),
            "collapse": run.isCollapse ? 1 : 0,
            "frames": run.frameCost.frames,
            "maxFrameMs": (run.frameCost.maxMilliseconds * 100).rounded() / 100,
            "totalMs": (run.frameCost.totalMilliseconds * 100).rounded() / 100,
        ])
        #if DEBUG
 // 逐帧主线程成本（不是布局成本）：证明动画帧内没有同步重活；
 // 掉帧/布局成本由帧级探针的 toggleStart->toggleEnd 窗口判定。
        PerfProbe.shared.record(
            "groupToggle",
            ms: run.frameCost.totalMilliseconds,
            [
                "frames": run.frameCost.frames,
                "maxFrameMs": (run.frameCost.maxMilliseconds * 100).rounded() / 100,
                "collapse": run.isCollapse ? 1 : 0,
            ]
        )
        #endif
        scrollDebug("toggle end group=\(run.groupID) offset=\(fmt(run.targetOffset)) \(scrollGeometrySummary())")
        groupToggleRun = nil
        groupToggleTicker = nil
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

 /// 所有程序化滚动统一走这里：`withAnimation(nil)`（明确无动画）。
 /// 注意不能用 Transaction.disablesAnimations——iOS 26 实测它会把
 /// ScrollPosition.scrollTo 整个吞掉（offset 冻结取证）。记录指令来源（探针
 /// 输出 cmd=），跳动取证时区分「我们滚的」与「系统滚的」。
 // MARK: - 自动连续滚动

 /// 以固定速度连续滚动（到达一端后停顿 0.35s 反向），模拟用户「持续快速滑动」，
 /// 但不经过 XCUITest 手势合成 → 没有 XCTest 无障碍快照的主线程占用，能测到
 /// App 侧真实的掉帧/卡顿（用于回答「自动化测不出用户卡顿」的盲区）。
    private func startAutoScrollIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["DSHM_AUTOSCROLL"] == "1" else { return }
        guard autoScrollTicker == nil else { return }
        let speed = ProcessInfo.processInfo.environment["DSHM_AUTOSCROLL_SPEED"]
            .flatMap(Double.init) ?? 2600
        let ticker = GroupToggleTicker()
        autoScrollTicker = ticker
 // 状态放在 metrics（class）里：逐帧写不会触发 SwiftUI 失效，测量本身不制造卡顿。
        metrics.lastAutoScrollTime = 0
        metrics.autoScrollTarget = -1
        metrics.autoScrollDirection = 1
        ScrollHitchProbe.feedPhase("autoscroll")
        ScrollHitchProbe.mark("autoscrollStart", ["speed": speed])
        ticker.start { presentationTime in
            guard let current = autoScrollTicker, current === ticker else { return }
            let now = presentationTime
            let last = metrics.lastAutoScrollTime
            metrics.lastAutoScrollTime = now
            guard last > 0 else { return }
            let dt = max(0, min(0.05, now - last))
            let facts = metrics.facts
            guard facts.maxOffset > 1 else { return }
            var target = metrics.autoScrollTarget
            if target < 0 { target = facts.offset }
            target += metrics.autoScrollDirection * CGFloat(speed) * CGFloat(dt)
            if target >= facts.maxOffset {
                target = facts.maxOffset
                metrics.autoScrollDirection = -1
                ScrollHitchProbe.mark("autoscrollFlip", ["dir": -1])
            } else if target <= 0 {
                target = 0
                metrics.autoScrollDirection = 1
                ScrollHitchProbe.mark("autoscrollFlip", ["dir": 1])
            }
            metrics.autoScrollTarget = target
            withAnimation(nil) { scrollPosition.scrollTo(y: target) }
        }
        #endif
    }

    private func scrollWithoutAnimation(_ source: String, _ body: () -> Void) {
        metrics.lastScrollCommand = source
        ScrollHitchProbe.mark("scrollCmd", ["source": source])
        withAnimation(nil) { body() }
    }

 // MARK: - 官方几何观察（替代 contentSize KVO）

 /// 几何变化入口（onScrollGeometryChange action，主线程非布局回调）。
 ///
 /// inverted：内容变化（头部 insert 新消息 / 尾部 append 历史）不产生任何滚动
 /// 指令——offset=0 恒贴最新；尾部 append（历史补齐）在布局远端，offset 数学上
 /// 不变。这里只更新事实与取证。
    private func handleScrollFactsChange(old: ScrollFacts, new: ScrollFacts) {
        metrics.facts = new
        metrics.factsCalls += 1
 // 指示条更新节流到 30Hz（或位移 >4pt）：@Published 每帧写会带来每帧的
 // SwiftUI 更新事务；指示条自身是 20Hz TimelineView，30Hz 输入足够顺滑。
        let indicatorNow = CACurrentMediaTime()
        if indicatorNow - metrics.lastIndicatorPublishAt >= 1.0 / 30.0
            || !(abs(new.offset - metrics.lastIndicatorOffset) <= 4) {
            metrics.lastIndicatorPublishAt = indicatorNow
            metrics.lastIndicatorOffset = new.offset
            indicatorModel.facts = new
            indicatorModel.factsCalls = metrics.factsCalls
        }
 // 帧级卡顿探针（DEBUG + DSHM_HITCHDBG=1；未开启时 no-op）：
 // 把逐帧滚动几何/列表规模喂给探针，与 mark 事件按时间对齐做卡顿归因。
        ScrollHitchProbe.feedGeometry(
            offset: new.offset,
            contentHeight: new.contentHeight,
            viewportHeight: metrics.viewportHeight
        )
        ScrollHitchProbe.feedRows(
            displayed: displayedItems.count,
            total: items.count,
            pinned: pinnedToBottom
        )
        traceGestureOffsetIfNeeded(offset: new.offset)
 // 指示条可见性用 offset 驱动（手势/惯性/程序滚动时 offset 必然逐帧变化）。
 // 不依赖 onScrollPhaseChange：该事件在 scaleEffect 翻转下未实证触发过，
 // 若不触发则 phase 链死锁 = 指示条永不显示。
        if abs(new.offset - old.offset) > 0.1 {
            metrics.lastActiveAt = CACurrentMediaTime()
            indicatorModel.lastActiveAt = metrics.lastActiveAt
        }
        trackIdleBottomStability()
 // 内容高度变化 = 行物化/估算收敛：窗口扩展检查改由官方 ScrollGeometry 驱动
 // （旧实现是 LazyVStack 上的 GeometryReader preference，见列表背景注释）。
        let heightDelta = new.contentHeight - old.contentHeight
        if abs(heightDelta) > 0.5 || metrics.contentHeight <= 0 {
            metrics.contentHeight = new.contentHeight
            if abs(heightDelta) >= 2 {
                ScrollHitchProbe.mark("contentSizeChange", [
                    "height": Double(new.contentHeight).rounded(),
                    "delta": Double(heightDelta).rounded(),
                ])
            }
            layoutDidChange()
        }
    }

 /// 探针相位馈入：App 内自动连续滚动（DSHM_AUTOSCROLL=1）期间统一记 autoscroll，
 /// 避免程序的 scrollTo 被记为.animating/.idle 导致分析器把压测帧算成非滚动。
    private func feedProbePhase(_ phase: String) {
        ScrollHitchProbe.feedPhase(autoScrollTicker != nil ? "autoscroll" : phase)
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
            feedProbePhase(new == .tracking ? "tracking" : "interacting")
            markUserScrolledIfNeeded()
        case .decelerating:
            metrics.panDecelSeen = true
            metrics.interactingUntil = CACurrentMediaTime() + 0.55
            feedProbePhase("decelerating")
        case .animating:
 // 程序化滚动（我们的 scrollTo 意图）执行中：不视为用户交互。
            feedProbePhase("animating")
            break
        case .idle:
            metrics.isDragging = false
            metrics.panTrackingSeen = metrics.panTrackingSeen || old == .tracking
            feedProbePhase("idle")
            settleAfterGesture()
        @unknown default:
            break
        }
    }

 /// 松手 settle（相位到.idle 的事件驱动，替代 asyncAfter 轮询）：
 /// 距最新 <= 12pt 视为用户想贴底（repin），否则 unpin。
    private func settleAfterGesture() {
        let distance = currentDistanceFromBottom()
        ScrollHitchProbe.mark("settle", ["distance": Double(distance).rounded()])
        let next = ScrollFollowPolicy.pinnedAfterGesture(distanceFromBottom: distance)
        if next != pinnedToBottom {
            pinnedToBottom = next
            onNearBottomChange(next)
            scrollDebug("settle pin=\(next ? 1 : 0) distance=\(fmt(distance))")
        }
        if next, distance.isFinite, distance > 0.5 {
 // 用户在最新附近松手：推到最新（完成用户意图，手势的收尾而非程序抢位）。
 // inverted edge 语义：.top = 布局顶 = 视觉底（最新）。
            scrollWithoutAnimation("settle") { scrollPosition.scrollTo(edge: .top) }
            metrics.followCount += 1
        }
    }

 // MARK: - items 变化：可视锚点 / 贴底跟随

 /// 内容变化：整批应用，零滚动指令。
 ///
 /// inverted 几何保证：
 /// - 新消息（数组尾 append，升序）→ 渲染头部 insert → offset=0 视口自动显示，
 /// 视觉上新内容从底部冒出、上方不动；
 /// - 历史补齐（窗口起点前移 → 渲染尾部 append）→ 布局远端插入，视口纹丝不动；
 /// - 读历史中（offset>0）：头部 insert 只在 pinned 视口（offset≈0）可见，
 /// 对当前阅读位置零影响。
    private func applyItemsChange() {
        #if DEBUG
        let applyStart = CACurrentMediaTime()
        #endif
        ScrollHitchProbe.mark("applyItemsChangeStart", [
            "displayed": displayedItems.count,
            "incoming": items.count,
            "pinned": pinnedToBottom ? 1 : 0,
        ])
        let allItems = items
        guard !allItems.isEmpty else { return }
 // 固定起点失效（快照替换/裁剪）时回到默认「最近 N 行」窗口。
        if let startID = windowStartItemID, !allItems.contains(where: { $0.id == startID }) {
            windowStartItemID = nil
        }
        var newItems = windowedItems(from: allItems)
        guard !newItems.isEmpty else { return }
 // 读历史（!pinned）：冻结尾部新增。升序尾部的**新行**（新消息/新过程组）
 // 在倒序渲染里是布局顶 insert——会把整个内容向下推 = 视口漂移。冻结它们
 // （保留原地更新与旧端扩展，二者均零漂移），用户回底（settle repin/token）
 // 后恢复全量跟随；期间新消息静默等待，与 iMessage 读历史行为一致。
        if !pinnedToBottom {
            let frozen = MessageListUpdatePolicy.withoutTailInsertions(
                displayed: displayedItems, incoming: newItems
            )
            if frozen.count < newItems.count {
                scrollDebug("freeze tail inserts displayed=\(frozen.count) incoming=\(newItems.count)")
            }
            newItems = frozen
        }
        guard newItems != displayedItems else {
 // 数据变化但显示窗口未变：仍检查一次窗口是否需要向旧端扩展
 // （用户可能正停在窗口最旧端附近）。
            scheduleWindowExpansionCheck()
            return
        }
 // 无动画应用：中间态 1 帧，肉眼不可见（沿用 r7 验收策略）。
        withAnimation(nil) {
            displayedItems = newItems
        }
        if !isContentReady {
            isContentReady = true
            onFirstContent()
        }
        scrollDebug("apply displayed=\(displayedItems.count) incoming=\(newItems.count) pinned=\(pinnedToBottom ? 1 : 0) \(scrollGeometrySummary())")
        ScrollHitchProbe.mark("applyItemsChangeEnd", [
            "displayed": displayedItems.count,
            "incoming": newItems.count,
        ])
        #if DEBUG
        PerfProbe.shared.record(
            "applyItemsChange",
            ms: (CACurrentMediaTime() - applyStart) * 1000,
            ["displayed": displayedItems.count, "incoming": newItems.count]
        )
        #endif
 // 后台预解析窗口内文本行的 Markdown（block + inline token）：
 // 主线程首次物化只做布局/绘制（P0 滚动长帧修复）。
        MarkdownPrewarm.prewarm(items: displayedItems)
        scheduleWindowExpansionCheck()
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

 // MARK: - 窗口扩展（向旧端 append 100 行，零滚动）

    private func scheduleWindowExpansionCheck() {
        guard !metrics.windowExpansionScheduled else { return }
        metrics.windowExpansionScheduled = true
        DispatchQueue.main.async {
            self.metrics.windowExpansionScheduled = false
            self.maybeExpandWindow()
        }
    }

 /// 用户滚到窗口最旧端（布局底）预留区时扩展显示窗口（一次 100 行）。
 /// inverted：扩展 = 渲染序列尾部 append（布局远端）→ 视口纹丝不动，
 /// 无锚点回位、无滚动指令（旧实现的 prepend 补偿链已全部删除）。
    private func maybeExpandWindow() {
        guard let oldest = displayedItems.first else { return }
        ScrollHitchProbe.feedRows(
            displayed: displayedItems.count,
            total: items.count,
            pinned: pinnedToBottom
        )
        guard MessageListWindowPolicy.shouldExpandNearTail(
            offset: metrics.facts.offset,
            contentHeight: metrics.facts.contentHeight,
            viewportHeight: metrics.facts.viewportHeight
        ) else { return }
        guard let currentStart = items.firstIndex(where: { $0.id == oldest.id }) else { return }
        let newStart = MessageListWindowPolicy.expandedStartIndex(currentStart: currentStart, itemCount: items.count)
        guard newStart < currentStart else { return }
        metrics.windowExpansionScheduled = true
        DispatchQueue.main.async {
            self.metrics.windowExpansionScheduled = false
            self.performWindowExpansion(newStart: newStart)
        }
    }

    private func performWindowExpansion(newStart: Int) {
        #if DEBUG
        let expandStart = CACurrentMediaTime()
        #endif
        guard newStart >= 0, newStart < items.count else { return }
        var expanded = Array(items[newStart...])
 // 读历史冻结一致：扩展批次同样截掉尾部新行（与 applyItemsChange 同语义，
 // 避免扩展路径绕过冻结把新消息 insert 到布局顶推动视口）。
        if !pinnedToBottom {
            expanded = MessageListUpdatePolicy.withoutTailInsertions(displayed: displayedItems, incoming: expanded)
        }
        guard expanded != displayedItems else { return }
        windowStartItemID = items[newStart].id
        withAnimation(nil) {
            displayedItems = expanded
        }
        metrics.prependCount += 1
        ScrollHitchProbe.mark("windowExpand", [
            "start": newStart,
            "displayed": expanded.count,
            "total": items.count,
        ])
        #if DEBUG
        PerfProbe.shared.record(
            "windowExpand",
            ms: (CACurrentMediaTime() - expandStart) * 1000,
            ["displayed": expanded.count, "total": items.count]
        )
        #endif
 // 向旧端扩展 = 马上要滚到的历史行：提前后台预解析这些文本行。
        MarkdownPrewarm.prewarm(items: Array(expanded.prefix(120)))
        scrollDebug("window expand start=\(newStart) displayed=\(expanded.count)/\(items.count)")
    }

 /// 布局（contentHeight preference）变化后：检查窗口是否需要向旧端扩展。
    private func layoutDidChange() {
        maybeExpandWindow()
    }

 /// 空闲态稳定性取证：pinned 且无手势时，距最新距离不应变大（变大 = 列表自己滚）。
    private func trackIdleBottomStability() {
        guard pinnedToBottom else { return }
        guard !isUserInteractingNow() else { return }
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

 /// 步骤高度缓存的布局签名：容器宽度（取整）+ 动态字号 + 语言。
 /// 任一变化 ⇒ 行高会变 ⇒ 缓存必须整体失效重测。
    private static func stepsCacheLayoutSignature(
        width: CGFloat,
        dynamicTypeSize: DynamicTypeSize,
        locale: Locale
    ) -> String {
 // CGFloat→Int 前必须判有限：.infinity/.nan 会 fatalError。
        let roundedWidth = width.isFinite ? Int(width.rounded()) : 0
        return "\(roundedWidth)|\(dynamicTypeSize)|\(locale.identifier)"
    }

 /// 几何快照：facts/坐标/distance/offset/contentHeight 全量打印，真机可直接对照。
    private func scrollGeometrySummary() -> String {
        let viewportMaxY = metrics.viewportFrame.isNull ? -9999 : metrics.viewportFrame.maxY
        return "facts=1"
            + " viewportMaxY=\(fmt(viewportMaxY))"
            + " viewportH=\(fmt(metrics.viewportHeight))"
            + " bottomMaxY=\(fmt(metrics.viewportFrame.isNull ? -9999 : metrics.viewportFrame.maxY - metrics.facts.offset))"
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
        return "o=\(fmt(metrics.facts.offset)) d=\(distanceText) i=\(displayedItems.count)/\(items.count) ws=\(windowStartIndex) pre=\(metrics.prependCount) ch=\(fmt(metrics.facts.contentHeight)) vh=\(fmt(metrics.viewportHeight)) pin=\(pinnedToBottom ? 1 : 0) ini=\(isContentReady ? 1 : 0) gm=\(fmt(metrics.gestureMaxFrameDelta)) ac=0 cs=0 sf=0 acg=0 fw=\(metrics.followCount) rs=0.0 sy=0 lag=0 dr=\(metrics.idleDriftCount) mx=\(fmt(metrics.maxIdleDistance)) kvo=0 pan=\(metrics.panSeen ? 1 : 0) ptrk=\(metrics.panTrackingSeen ? 1 : 0) pdec=\(metrics.panDecelSeen ? 1 : 0) it=\(isUserInteractingNow() ? 1 : 0) drag=\(metrics.isDragging ? 1 : 0)"
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
        return "mid=" + metrics.uuid
            + ";calls=" + String(metrics.factsCalls)
            + ";pinned=" + (pinnedToBottom ? "1" : "0")
            + ";displayed=" + String(displayedItems.count)
            + ";incoming=" + String(items.count)
            + ";distance=" + distanceText
            + ";attempts=0"
            + ";seq=" + String(latestAppliedSeq())
            + ";dragging=" + (metrics.isDragging ? "1" : "0")
            + ";chain=0"
            + ";bottomMaxY=" + fmt(metrics.viewportFrame.isNull ? -9999 : metrics.viewportFrame.maxY - metrics.facts.offset)
            + ";viewport=" + fmt(metrics.viewportHeight)
            + ";viewportMaxY=" + fmt(metrics.viewportFrame.isNull ? -9999 : metrics.viewportFrame.maxY)
            + ";topMinY=" + fmt(metrics.facts.offset)
            + ";offset=" + fmt(metrics.facts.offset)
            + ";contentH=" + fmt(metrics.contentHeight)
            + ";handle=1"
            + ";settledOnce=" + (metrics.hasSettledOnce ? "1" : "0")
            + ";maxDist=" + fmt(metrics.maxIdleDistance)
            + ";drifts=" + String(metrics.idleDriftCount)
            + ";anchor=" + (pinnedToBottom ? "bottom" : "none")
            + ";pins=0"
            + ";gesturePins=0"
            + ";userScrolled=" + (userHasScrolled ? "1" : "0")
            + ";gestureMaxDelta=" + fmt(metrics.gestureMaxFrameDelta)
            + ";gestureFrames=" + String(metrics.gestureFrameCount)
            + ";prepends=" + String(metrics.prependCount)
            + ";anchorFixes=0"
            + ";pref=0"
            + ";pb=0"
            + ";kvo=0"
            + ";pan=" + (metrics.panSeen ? "1" : "0")
            + ";ptrk=" + (metrics.panTrackingSeen ? "1" : "0")
            + ";pdec=" + (metrics.panDecelSeen ? "1" : "0")
            + ";os=" + fmt(overscrollAmount())
            + ";cmd=" + metrics.lastScrollCommand
            + ";vid=" + (metrics.lastScrollCommand)
            + ";ini=" + (isContentReady ? "1" : "0")
            + ";att=0"
            + ";csf=0"
            + ";lk=0"
            + ";sa=0"
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
 /// 最大合法 offset（自绘滚动条的分母；内容不足一屏时 0）。
    var maxOffset: CGFloat

    init(geometry: ScrollGeometry) {
        let insets = geometry.contentInsets
        let maxOffset = geometry.contentSize.height + insets.bottom - geometry.containerSize.height
        self.contentHeight = geometry.contentSize.height
        self.offset = max(0, geometry.contentOffset.y + insets.top)
        self.viewportHeight = geometry.containerSize.height
 // inverted（r7）：最新消息在布局顶。距最新端 = 归一 offset
 // （0 = 贴最新 = 视觉底部；读历史 offset 增大）。字段名保留（E2E 契约）。
        self.distanceFromBottom = self.offset
 // inverted 过滚 = 布局顶越界（= 视觉底部下拉 rubber band）。
        self.overscroll = max(0, -(geometry.contentOffset.y + insets.top))
        self.maxOffset = max(0, maxOffset)
    }

    init(contentHeight: CGFloat, offset: CGFloat, viewportHeight: CGFloat, distanceFromBottom: CGFloat, overscroll: CGFloat, maxOffset: CGFloat = 0) {
        self.contentHeight = contentHeight
        self.offset = offset
        self.viewportHeight = viewportHeight
        self.distanceFromBottom = distanceFromBottom
        self.overscroll = overscroll
        self.maxOffset = maxOffset
    }
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

 /// inverted（r7）：视口接近窗口最旧端（布局底）预留区时，向旧端扩展。
 /// 纯 offset 数学（不依赖行 frame 的翻转后坐标）：内容底到视口底的距离 <= margin。
    static func shouldExpandNearTail(offset: CGFloat,
                                     contentHeight: CGFloat,
                                     viewportHeight: CGFloat,
                                     margin: CGFloat = expandMargin) -> Bool {
        guard contentHeight.isFinite, contentHeight > 1, viewportHeight > 1 else { return false }
        return contentHeight - (offset + viewportHeight) <= margin
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
 /// 贴底跟随的滞后（pt）：距底超过该值才拉回，吸收 LazyVStack 高度估值抖动。
    static let followHysteresis: CGFloat = 40
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

 /// 过程组显示态切换引起的组行高度变化 Δ（inverted：行高 +Δ ⇒ 组头屏幕位移 −Δ）。
 /// 只有「展开⇄收起」改变行高，变化量 = 步骤内容高度；旧 window/full 之间切换
 /// 行高不变，不补偿。
    static func toggleHeightDelta(from current: ProcessGroupMode,
                                  to target: ProcessGroupMode,
                                  stepsHeight: CGFloat) -> CGFloat {
        guard stepsHeight.isFinite else { return 0 }
        let height = max(0, stepsHeight)
        switch (current, target) {
        case (.expanded, .collapsed), (.full, .collapsed):
            return -height
        case (.collapsed, .expanded), (.collapsed, .full):
            return height
        default:
            return 0
        }
    }

 /// 过程组行高变化的滚动锚定目标 offset：offset 同量移动 Δ，clamp 到
 /// [0, maxOffset + Δ]（Δ 同时改变内容高度与 maxOffset）。
 /// 内容余量不足时物理上滚不满，退化为部分补偿（clamp 感知，不额外跳动）。
    static func anchoredOffset(offset: CGFloat, delta: CGFloat, maxOffset: CGFloat) -> CGFloat {
        guard offset.isFinite, delta.isFinite, maxOffset.isFinite else { return offset }
        return min(max(offset + delta, 0), max(0, maxOffset + delta))
    }
}

/// 自绘滚动条几何（纯函数，可单测）。inverted 语义：进度 0 = 最新 = 视觉底部。
enum ScrollIndicatorGeometry {
 /// 滑块长度比例 = 视口/内容；下限保证可抓握（对标 UIKit 最小指示块）。
    static func thumbLength(track: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat, minimum: CGFloat = 20) -> CGFloat {
        guard contentHeight > 1, track > 0 else { return 0 }
        return min(track, max(minimum, viewportHeight / contentHeight * track))
    }

 /// 滑块顶边 y（track 顶为 0）：inverted 下 offset=0（最新）→ y = track-len（底部）。
 /// 过滚端（rubber band）贴边并压缩（对标 UIKit 行为）。
    static func thumbY(track: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat,
                       offset: CGFloat, maxOffset: CGFloat, minimum: CGFloat = 20) -> CGFloat {
        let len = thumbLength(track: track, contentHeight: contentHeight, viewportHeight: viewportHeight, minimum: minimum)
        guard len > 0 else { return 0 }
        let span = track - len
        guard maxOffset > 1 else { return span }   // 内容不足一屏：贴底部（最新）
        let progress = min(1, max(0, offset / maxOffset))
        return (1 - progress) * span
    }

 /// rubber band 压缩系数（0...1，越大压得越短）：视觉底下拉（offset<0 侧）/
 /// 视觉顶下拉（offset>maxOffset 侧）都把滑块压向对应边缘。
    static func rubberBandCompression(overscroll: CGFloat) -> CGFloat {
        guard overscroll > 0 else { return 0 }
        return min(0.5, overscroll / 400)
    }
}

/// 自绘滚动条（r7-inverted）：翻转使系统指示条错位（左缘+反向），
/// 在 scale 外层自绘，外观对标 UIKit 系统指示条：3pt 胶囊、右缘 2.5pt、
/// primary 30%（自适配深浅色）、最小 20pt；手势/惯性期间显示，停稳后淡出。
/// TimelineView 轮询 metrics（引用类型）——重绘隔离在指示条自身，不触发列表 body。
private struct InvertedScrollIndicator: View {
 /// @Published facts 变化直接驱动本视图重算（TimelineView 轮询读引用属性
 /// 不构成依赖追踪，AX 输出冻结在首次快照——真机取证 04:0x）。
    @ObservedObject var model: ScrollIndicatorModel

    private static let width: CGFloat = 4.5
    private static let trailingInset: CGFloat = 2.5
    private static let fadeAfter: TimeInterval = 0.7

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            GeometryReader { geo in
                let f = model.facts
                let track = geo.size.height
 // 诊断探针（无条件存在）：输出显示条件真值，E2E 一次定位。
                Text("scroll-indicator-diag")
                    .font(.system(size: 1))
                    .frame(width: 2, height: 2)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("scroll-indicator-diag")
                    .accessibilityValue("mid=\(model.uuid);maxOff=\(sessionSafeInt(f.maxOffset));track=\(sessionSafeInt(track));ch=\(sessionSafeInt(f.contentHeight));calls=\(model.factsCalls);off=\(sessionSafeInt(f.offset))")
                if f.maxOffset > 1, track > 40, f.contentHeight > 1 {
                    let base = ScrollIndicatorGeometry.thumbLength(track: track, contentHeight: f.contentHeight, viewportHeight: f.viewportHeight)
                    let y = ScrollIndicatorGeometry.thumbY(track: track, contentHeight: f.contentHeight, viewportHeight: f.viewportHeight, offset: f.offset, maxOffset: f.maxOffset)
                    let compression = max(
                        ScrollIndicatorGeometry.rubberBandCompression(overscroll: f.overscroll),
                        ScrollIndicatorGeometry.rubberBandCompression(overscroll: f.offset - f.maxOffset)
                    )
                    let now = CACurrentMediaTime()
                    let visible = now < model.lastActiveAt + Self.fadeAfter
 // rubber band：滑块向对应边缘压短（简化：保持顶边，缩短长度）。
                    let len = max(8, base * (1 - compression))
                    Capsule()
                        .fill(Color.primary.opacity(0.3))
                        .frame(width: Self.width, height: len)
 // GeometryReader 子视图默认 topLeading 对齐（上一版贴左缘
 // 的根因）——position 显式钉在右缘。
                        .position(x: geo.size.width - Self.trailingInset - Self.width / 2,
                                  y: y + len / 2)
                        .opacity(visible ? 1 : 0)
                        .animation(.easeOut(duration: 0.25), value: visible)
 // E2E 探针（Text 通道——Capsule 即使 accessibilityElement() 也
 // 不稳定进 AX 树，Text 手法已被 probe/diag 两轮真机验证）。
 // GeometryReader 子视图默认 topLeading 对齐，探针同样要 position
 // 钉右缘（位置断言的锚点）。
                    Text("scroll-indicator")
                        .font(.system(size: 1))
                        .frame(width: 2, height: 2)
                        .opacity(0.02)
                        .allowsHitTesting(false)
                        .position(x: geo.size.width - Self.trailingInset - 1,
                                  y: geo.size.height - 1)
                        .accessibilityIdentifier("scroll-indicator")
                        .accessibilityValue("visible=\(visible ? 1 : 0);maxOff=\(sessionSafeInt(f.maxOffset));off=\(sessionSafeInt(f.offset));track=\(sessionSafeInt(track));len=\(sessionSafeInt(len))")
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 自绘滚动条专用发布器：@Published 变化只触发订阅它的指示条重算（列表零影响）。
private final class ScrollIndicatorModel: ObservableObject {
    @Published var facts = ScrollFacts(contentHeight: 0, offset: 0, viewportHeight: 0, distanceFromBottom: .greatestFiniteMagnitude, overscroll: 0, maxOffset: 0)
    var lastActiveAt: CFTimeInterval = 0
    var factsCalls = 0
    let uuid = UUID().uuidString.prefix(8)
}

/// 滚动几何/校正状态（引用类型：不触发 SwiftUI body 重算，每帧滚动零成本）。
private final class ScrollMetrics {
 /// 实例指纹（诊断：双实例分叉取证）。
    let uuid = UUID().uuidString.prefix(8)
 /// 官方几何观察的最新事实。
    var facts = ScrollFacts(contentHeight: 0, offset: 0, viewportHeight: 0, distanceFromBottom: .greatestFiniteMagnitude, overscroll: 0, maxOffset: 0)
 /// 最近一次用户手势活跃时刻（自绘滚动条淡出计时用）。
    var lastActiveAt: CFTimeInterval = 0
 /// onScrollGeometryChange action 调用计数（指示条诊断用）。
    var factsCalls = 0
 /// LazyVStack 内容高度（preference 值，仅诊断）。
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
 /// ScrollView 自身的全局 frame（scale 外层测量，不受翻转影响；探针输出用）。
    var viewportFrame: CGRect = .null

 // MARK: - 交互（相位驱动）
 /// 用户拖拽中（ScrollPhase.tracking/.interacting）。
    var isDragging = false
 /// 松手后的交互静默期截止时间（惯性/回弹也算用户交互）。
    var interactingUntil: CFTimeInterval = 0

 // MARK: - 诊断/取证
 /// 逐帧 offset 采样的上一值（手势窗口内统计单帧最大位移）。
    var lastTraceOffset: CGFloat = -1
    var gestureMaxFrameDelta: CGFloat = 0
    var gestureFrameCount = 0
    var hasSettledOnce = false
    var maxIdleDistance: CGFloat = 0
    var idleDriftCount = 0
    var prependCount = 0
    var followCount = 0
    var panSeen = false
    var panTrackingSeen = false
    var panDecelSeen = false
    var windowExpansionScheduled = false
 /// 最近一次程序化滚动指令来源（跳动取证：cmd 有值且时间近 = 我们滚的）。
    var lastScrollCommand: String = "-"
 /// 指示条 @Published 更新节流（30Hz 或位移 >4pt）。
    var lastIndicatorPublishAt: CFTimeInterval = 0
    var lastIndicatorOffset: CGFloat = .nan
 /// App 内自动连续滚动（DSHM_AUTOSCROLL=1）的帧时钟/目标/方向。
    var lastAutoScrollTime: CFTimeInterval = 0
    var autoScrollTarget: CGFloat = -1
    var autoScrollDirection: CGFloat = 1
}


/// CGFloat→Int 的安全转换（HUD/探针/日志读取滚动几何真值时使用）。
/// 直接 Int(.infinity)/Int(.nan) 会 fatalError —— 真机在 SwiftUI unspecified
/// proposal 下踩过一次 EXC_BREAKPOINT，所有浮点转整型都必须先判有限。
private func sessionSafeInt(_ value: CGFloat, fallback: Int = 0) -> Int {
    guard value.isFinite else { return fallback }
    let rounded = value.rounded()
    guard rounded >= CGFloat(Int.min), rounded <= CGFloat(Int.max) else { return fallback }
    return Int(rounded)
}

// MARK: - PreferenceKeys（SwiftUI 原生测量）


/// 帧探针用：行类型 / 步骤数（只读，无副作用；DEBUG 探针用）。
extension SessionMessageItem {
    var rowKindForProbe: String {
        switch self {
        case .group(let group):
            switch group {
            case .process: return "process"
            case .single: return "single"
            }
        case .fileChanges: return "fileChanges"
        case .liveText: return "liveText"
        case .streamError: return "streamError"
        case .actionError: return "actionError"
        }
    }

    var stepCountForProbe: Int {
        if case .group(let group) = self {
            return group.stepCount
        }
        return 0
    }
}

/// 过程组「步骤内容高度」存储（key = FlowRowGroup.id）。
///
/// 刻意做成**非可观察引用**：ScrollView 内容里每个过程组的 stepsHeightReader
/// 会在行物化/布局变化时上报测量值，如果回写成 @State，每次上报都会让整个
/// 消息列表 body 重算（长会话快速滚动时 = 周期性丢帧）。只有点击组头时才读取它，
/// 因此不需要参与视图依赖。
@MainActor
final class GroupStepsHeightStore {
    private(set) var heights: [String: ProcessGroupStepsHeight] = [:]
 /// 布局签名（容器宽度 + 动态字号）：变化时所有缓存失效（行高会变）。
    private(set) var layoutSignature: String = ""

 /// 布局签名变化时整体失效（旋转 / 分屏 / 字号变化后重新测量）。
    func prepare(layoutSignature: String) {
        guard self.layoutSignature != layoutSignature else { return }
        self.layoutSignature = layoutSignature
        heights.removeAll(keepingCapacity: true)
    }

 /// 缓存命中：内容签名一致才可用（折叠期间内容变化 → 签名变化 → 未命中重测）。
    func height(forGroup id: String, contentSignature: String) -> CGFloat? {
        guard let entry = heights[id], entry.signature == contentSignature, entry.height > 0 else {
            return nil
        }
        return entry.height
    }

 /// 合并上报值（不是整体替换：命中缓存的组不再上报，不能把已有缓存冲掉）。
    func update(_ reported: [String: ProcessGroupStepsHeight]) {
        for (id, entry) in reported {
            heights[id] = entry
        }
    }
}

/// 展开/收起动画的帧时钟：CADisplayLink（主 runloop common mode，与滚动手势并存）。
///
/// 回调参数是 targetTimestamp——该帧被上屏的时间，用它算动画进度可以抵消一帧的
/// 提交延迟，逐帧严格单调；替代旧 Task.sleep(16ms) 的相对漂移 / 一帧写两次的抖动。
@MainActor
final class GroupToggleTicker: NSObject {
    private var link: CADisplayLink?
    private var onFrame: ((CFTimeInterval) -> Void)?

    func start(onFrame: @escaping (CFTimeInterval) -> Void) {
        self.onFrame = onFrame
        let link = CADisplayLink(target: self, selector: #selector(handleFrame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        onFrame = nil
    }

    @objc private func handleFrame(_ link: CADisplayLink) {
        onFrame?(link.targetTimestamp)
    }
}

/// ScrollView 自身的全局 frame（挂在 scale 外层，测量不受翻转影响；探针输出用）。
private struct ListViewportFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}
