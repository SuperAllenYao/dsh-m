import Foundation
import QuartzCore
import SwiftUI
import UIKit

/// 过程组高度常量与显示态内容高度（公式真值，纯函数；可单测）。
///
/// 与 `ProcessGroupView` 的渲染尺寸严格一致：组头 36pt；步骤行 28pt 行内容 +
/// 1pt hairline = 29pt；窗口态按整行吸附（只算完整行）。
/// 折叠态行高 = `headerHeight + Theme.Spacing.s`（cell 上下 padding 合计，见行视图）。
/// 展开/收起的滚动补偿与行高动画都依赖这里的预测值与真实布局零误差。
private enum UILProcessGroupMetrics {
 /// 组头行高（`headerRow` 的 `.frame(height: 36)`）。
    static let headerHeight: CGFloat = 36
 /// 单条步骤行高：28pt 行内容 + 1pt hairline。
    static let stepRowHeight: CGFloat = 29
 /// 折叠态整行高度（组头 + 行上下 padding；padding 两侧相消，Δ 只来自内容区）。
    static let collapsedRowHeight: CGFloat = headerHeight + Theme.Spacing.s

 /// 窗口态实际展示的步骤数（尾部切片，整行吸附：只展示完整行）。
    static func windowStepCount(totalSteps: Int, windowHeight: CGFloat) -> Int {
        guard totalSteps > 0 else { return 0 }
        let capacity = max(1, Int(windowHeight / stepRowHeight))
        return min(totalSteps, capacity)
    }

 /// 各显示态的内容高度（不含行外层 vertical padding——补偿计算两侧相消）。
    static func contentHeight(mode: ProcessGroupMode, stepCount: Int, windowHeight: CGFloat) -> CGFloat {
        switch mode {
        case .collapsed:
            return headerHeight
        case .window:
            return headerHeight
                + CGFloat(windowStepCount(totalSteps: stepCount, windowHeight: windowHeight)) * stepRowHeight
        case .full, .expanded:
            return headerHeight + CGFloat(stepCount) * stepRowHeight
        }
    }
}


// MARK: - 过程组展开/收起锚点数学（纯函数，可单测）

/// 展开/收起的滚动补偿计划。
///
/// UIKit 反转底座下 Coordinator 用 `predictedOffset` 直接 `setContentOffset`
/// （逐帧 `pinRowTop` 伺服）；探针事件（E2E 判定）用 `heightDelta`/`anchorUnitY`。
enum ProcessGroupExpandAnchor {
    struct Plan: Equatable {
 /// 新旧显示态内容高度差（pt）。正 = 展开（推开下方内容），负 = 收起。
        var heightDelta: CGFloat
 /// scrollTo 锚点 y；nil = 无法补偿（测量缺失/退化），退化为无补偿展开。
        var anchorUnitY: CGFloat?
 /// 补偿后的预期 offset（贴底判定用）；nil = 同上。
        var predictedOffset: CGFloat?
    }

    static func plan(rowFrame: CGRect,
                     oldMode: ProcessGroupMode,
                     newMode: ProcessGroupMode,
                     stepCount: Int,
                     windowHeight: CGFloat,
                     offset: CGFloat,
                     viewportHeight: CGFloat,
                     contentHeight: CGFloat) -> Plan {
        let oldHeight = UILProcessGroupMetrics.contentHeight(mode: oldMode, stepCount: stepCount, windowHeight: windowHeight)
        let newHeight = UILProcessGroupMetrics.contentHeight(mode: newMode, stepCount: stepCount, windowHeight: windowHeight)
        let delta = newHeight - oldHeight
        guard rowFrame != .null, rowFrame.height > 0,
              offset.isFinite, viewportHeight > 1 else {
            return Plan(heightDelta: delta, anchorUnitY: nil, predictedOffset: nil)
        }
 // 行 frame 含 padding：Δ 只来自内容区（padding 两侧相消）。
        let hNew = rowFrame.height + delta
 // 夹取上界必须用「新内容高度 − 视口」：内容不足一屏时 maxOffset 恒 0，
 // `maxOffset + Δ` 会高估可滚空间（短会话展开会把组头顶飞）。
        let maxNew = max(0, contentHeight + delta - viewportHeight)
        let target = min(max(offset + delta, 0), maxNew)
        guard abs(viewportHeight - hNew) > 0.5 else {
 // 行将与视口同高：锚点退化，无法定位（仍给出 offset 供贴底判定）。
            return Plan(heightDelta: delta, anchorUnitY: nil, predictedOffset: target)
        }
        let unitY = (target - rowFrame.minY) / (hNew - viewportHeight)
        return Plan(heightDelta: delta, anchorUnitY: unitY, predictedOffset: target)
    }
}

// MARK: - UIKit 底座支撑

/// 过程组行高取证开关：真机 DEBUG 构建下设 `DSHM_PROCDBG=1` 时，
/// 每次行重测后打印可见过程组的行高与 hosting 内容高度（默认关闭，零开销）。
enum UILProcessGroupDebug {
    static let enabled = ProcessInfo.processInfo.environment["DSHM_PROCDBG"] == "1"
}

/// cell 内容实际高度（SwiftUI 内部状态变化后上报给 table，用于自撑高重测）。
private struct UILRowContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 布局回调型 UITableView：每次布局完成（屏幕提交前）通知协调器做「锚点行位置保持」。
final class UILAnchoredTableView: UITableView {
    var onLayoutPass: (() -> Void)?
    private var isReentrant = false
    override func layoutSubviews() {
        #if DEBUG
        let probeStart = CACurrentMediaTime()
        #endif
        super.layoutSubviews()
        guard !isReentrant else {
            #if DEBUG
            PerfProbe.shared.record("layoutPass", ms: (CACurrentMediaTime() - probeStart) * 1000, ["reentrant": 1])
            #endif
            return
        }
        isReentrant = true
        onLayoutPass?()
        isReentrant = false
        #if DEBUG
        PerfProbe.shared.record("layoutPass", ms: (CACurrentMediaTime() - probeStart) * 1000, [
            "visible": visibleCells.count,
            "h": Double(bounds.height),
        ])
        #endif
    }
}

/// **UIKit 消息列表底座（常规 UITableView + 行宿主缓存）** —— 定稿。
///
/// 演进：WIP用 `scaleY(-1)` 翻转 table → 真机实测**行级 AX frame
/// 系统性为 (0,0,0,0)**（VoiceOver/XCUITest 无法聚焦，且 UIHostingConfiguration
/// 自撑高 = 每行双次 SwiftUI 布局，滚动长帧反而比 SwiftUI 容器差 1.8×）。
/// 定稿架构（全部实测数据见 docs/STATUS-20261027-uikit-scroll.md）：
/// - **常规（非翻转）** `UITableView`：数据源时间正序（旧→新），最新在内容底部；
/// 贴底跟随由布局期伺服（stabilizeAfterLayout）钉住内容底端。
/// - **行内容宿主缓存**：Coordinator 持有每行 `UIHostingController`（一次离屏
/// 布局记住高度），cell 复用只做挂载/卸载——滚动回看**零重排**；`heightForRowAt`
/// 直接返回缓存高度，不再走自撑高测量（实测 130s 场景 I 长帧 143 → 11，
/// 且稳态滚动零 >50ms 帧）。
/// - 显示窗口（最近 300 行 + 100 行扩展）+ 读历史时尾部新行冻结（iMessage 语义）
/// + `withoutTailInsertions`，与 SwiftUI 回退后端同口径。
/// - 过程组展开/收起：普通组 CADisplayLink 逐帧插值**行高**（easeOutCubic 280ms，
/// 组头 = rowMinY 天然钉住）；巨型组同帧切态（不做逐帧动画，设计决策）。
/// - 回退开关：DEBUG 下 `DSHM_LIST_BACKEND=swiftui` 用回 `SessionMessageSwiftUIListView`。
struct SessionMessageUIKitListView: View {
    let items: [SessionMessageItem]
    let sessionId: String
    let attachments: AttachmentStore
    let pendingApprovalCallIds: Set<String>
    let subagentLabels: [String: String]
    let isRunning: Bool
    let historyBatchToken: Int
 /// 递增即请求「强制回到底部」（发送消息 / 答完问答时由上层 +1）。
    let scrollToBottomToken: Int
 /// 过程组显示态覆盖（key = `FlowRowGroup.id`）；默认态由 isRunning + 是否最新组推导。
    var processGroupModes: [String: ProcessGroupMode] = [:]
 /// 运行中固定窗口高度（页面按会话可视高度 1/3 传入）。
    var processGroupWindowHeight: CGFloat = 300
 /// 本轮起点 seq（最后一条用户消息）。只有本轮内的组才可能是「运行中」组。
    var currentTurnStartSeq: Int = Int.min
 /// 点击过程组 header：回调目标态（页面写入覆盖）。
    var onToggleGroupMode: ((String, ProcessGroupMode) -> Void)? = nil
    var onOpenReasoning: ((String) -> Void)? = nil
    let onOpenTool: (ToolCallItem) -> Void
 /// v7：子代理消息步骤行点击 → 打开该子代理会话（nil = 行不可点）。
    var onOpenRelay: ((RelayCard) -> Void)? = nil
    let onOpenFileChanges: (TurnFileChanges) -> Void
    let onNearBottomChange: (Bool) -> Void
    let onUserScrolled: () -> Void
 /// DD-02: 滚动交互开始/结束（手指拖拽/惯性），供详情页冻结流式尾部发布。
    var onInteractionChange: (Bool) -> Void = { _ in }
    let onFirstContent: () -> Void
    let onRetry: () -> Void
 /// 历史补齐进行中（VM `historyFillProgress!= nil`；上层进度条用）。
 /// 反转底座下历史补齐 = 数据尾部 append = 布局远端插入，offset 数学上零漂移，
 /// 此参数仅为接口兼容保留。
    var isFillingHistory: Bool = false

 /// Coordinator ↔ SwiftUI overlay（自绘滚动条/HUD/探针）共享状态。
    @StateObject private var shared = UILListSharedModel()
 /// Reduce Motion：过程组展开/收起压成 ≈2 帧（终态一致、无过渡）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
 /// 动态字号 / 语言：步骤高度缓存按「宽度 + 字号 + 语言」失效（行高会变）。
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @State private var lastScrollToBottomToken: Int = 0

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
        _lastScrollToBottomToken = State(initialValue: scrollToBottomToken)
    }

    var body: some View {
        MessageTableRepresentable(
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
            onRetry: onRetry,
            shared: shared,
            reduceMotion: reduceMotion,
            stepsLayoutSignature: "\(dynamicTypeSize)|\(locale.identifier)",
            dynamicTypeSize: dynamicTypeSize,
            locale: locale
        )
 // DD-03：删除自绘 `InvertedScrollIndicator` overlay（含 20Hz TimelineView），
 // 只保留 makeUIView 里的系统原生滚动条 `showsVerticalScrollIndicator = true`。
 // 骨架屏（无内容拉取中）：挂在 representable 外层不被翻转。
        .overlay {
            if items.isEmpty {
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
        .overlay(alignment: .topLeading) { scrollProbeElement }
        .overlay(alignment: .top) { scrollHUD }
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

 /// HUD 字段串：与 SwiftUI 回退后端（SessionMessageSwiftUIListView.hudText）
 /// **逐字段一致**——DeviceScrollJumpReproUITests 按 key 解析。
    private func hudText() -> String {
        let distance = shared.facts.distanceFromBottom
        let distanceText = distance.isFinite ? fmt(distance) : "-9999"
        return "o=\(fmt(shared.facts.offset)) d=\(distanceText) i=\(shared.displayedCount)/\(shared.incomingCount) ws=\(shared.windowStartIndex) pre=\(shared.prependCount) ch=\(fmt(shared.facts.contentHeight)) vh=\(fmt(shared.facts.viewportHeight)) pin=\(shared.pinned ? 1 : 0) ini=\(shared.isContentReady ? 1 : 0) gm=\(fmt(shared.gestureMaxFrameDelta)) ac=0 cs=0 sf=0 acg=0 fw=\(shared.followCount) rs=0.0 sy=0 lag=0 dr=\(shared.idleDriftCount) mx=\(fmt(shared.maxIdleDistance)) kvo=0 pan=\(shared.panSeen ? 1 : 0) ptrk=\(shared.panTrackingSeen ? 1 : 0) pdec=\(shared.panDecelSeen ? 1 : 0) it=\(isUserInteractingNow() ? 1 : 0) drag=\(shared.isDragging ? 1 : 0)"
            // AC-11 验证字段（追加在末尾，既有 key 不变）：显式窗口起点 id + 历史补齐中标记。
            + ";wsid=" + shared.windowStartSourceID
            + ";fill=" + (isFillingHistory ? "1" : "0")
    }

    private func isUserInteractingNow() -> Bool {
        if shared.isDragging || CACurrentMediaTime() < shared.interactingUntil { return true }
        return false
    }

 // MARK: - 隐藏探针（E2E 契约；键名保持与 SwiftUI 后端一致）

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

 /// 隐藏探针字段串：与 SwiftUI 回退后端（scrollProbeValue）**逐字段一致**
 /// （SessionDetailScrollE2ETests / DeviceScrollJumpReproUITests 按 key 解析）。
    private func scrollProbeValue() -> String {
        let distance = shared.facts.distanceFromBottom
        let distanceText = distance.isFinite ? fmt(distance) : "-1"
        return "mid=" + shared.uuid
            + ";calls=" + String(shared.factsCalls)
            + ";pinned=" + (shared.pinned ? "1" : "0")
            + ";displayed=" + String(shared.displayedCount)
            + ";incoming=" + String(shared.incomingCount)
            + ";distance=" + distanceText
            + ";attempts=0"
            + ";seq=" + String(shared.latestSeq)
            + ";dragging=" + (shared.isDragging ? "1" : "0")
            + ";chain=0"
            + ";bottomMaxY=" + fmt(shared.viewportFrame.isNull ? -9999 : shared.viewportFrame.maxY - shared.facts.offset)
            + ";viewport=" + fmt(shared.facts.viewportHeight)
            + ";viewportMaxY=" + fmt(shared.viewportFrame.isNull ? -9999 : shared.viewportFrame.maxY)
            + ";topMinY=" + fmt(shared.facts.offset)
            + ";offset=" + fmt(shared.facts.offset)
            + ";contentH=" + fmt(shared.facts.contentHeight)
            + ";handle=1"
            + ";settledOnce=" + (shared.hasSettledOnce ? "1" : "0")
            + ";maxDist=" + fmt(shared.maxIdleDistance)
            + ";drifts=" + String(shared.idleDriftCount)
            + ";anchor=" + (shared.pinned ? "bottom" : "none")
            + ";pins=0"
            + ";gesturePins=0"
            + ";userScrolled=" + (shared.userScrolled ? "1" : "0")
            + ";gestureMaxDelta=" + fmt(shared.gestureMaxFrameDelta)
            + ";gestureFrames=" + String(shared.gestureFrameCount)
            + ";prepends=" + String(shared.prependCount)
            + ";anchorFixes=0"
            + ";pref=0"
            + ";pb=0"
            + ";kvo=0"
            + ";pan=" + (shared.panSeen ? "1" : "0")
            + ";ptrk=" + (shared.panTrackingSeen ? "1" : "0")
            + ";pdec=" + (shared.panDecelSeen ? "1" : "0")
            + ";os=" + fmt(max(0, shared.facts.overscroll))
            + ";cmd=" + shared.lastScrollCommand
            + ";vid=" + shared.lastScrollCommand
            + ";ini=" + (shared.isContentReady ? "1" : "0")
            + ";att=0"
            + ";csf=0"
            + ";lk=0"
            + ";sa=0"
            + ";contentSize=" + fmt(shared.facts.contentHeight)
            + ";ready=" + (shared.isContentReady ? "1" : "0")
            + ";wstart=" + String(shared.windowStartIndex)
            + ";win=" + String(MessageListWindowPolicy.defaultWindow)
            + ";wsid=" + shared.windowStartSourceID
            + ";fill=" + (isFillingHistory ? "1" : "0")
    }

    private func fmt(_ value: CGFloat) -> String {
        let tenths = (value * 10).rounded() / 10
        return String(describing: tenths)
    }
}

// MARK: - UIKit representable

private struct MessageTableRepresentable: UIViewRepresentable {
    let items: [SessionMessageItem]
    let sessionId: String
    let attachments: AttachmentStore
    let pendingApprovalCallIds: Set<String>
    let subagentLabels: [String: String]
    let isRunning: Bool
    let historyBatchToken: Int
    let scrollToBottomToken: Int
 /// 历史补齐进行中：回填期所有「重主线程的显示侧工作」（闲置行高测量 / 面板扩窗 /
 /// 自动扩窗 / 行高精确测量）都必须让路，否则会与「逐帧合入」抢主线程，把
 /// fullHistory 从 <1s 拖到数秒(真机归因：page1 leg 1664ms /
 /// page2 leg 2787ms，两段主线程空档全部由行宿主物化造成）。
 /// **必须由 body 显式接线**（不给默认值：漏接线会静默失去全部让路）。
    let isFillingHistory: Bool
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
 /// DD-02: 拖拽/惯性开始（true）与结束（false），供详情页冻结流式尾部发布。
    var onInteractionChange: (Bool) -> Void = { _ in }
    let onFirstContent: () -> Void
    let onRetry: () -> Void
    let shared: UILListSharedModel
 /// Reduce Motion：过程组展开/收起压成 ≈2 帧（终态一致、无过渡）。
    let reduceMotion: Bool
 /// 步骤高度缓存的布局签名（动态字号|语言；宽度由 tableView 侧补齐）。
    let stepsLayoutSignature: String
 /// 动态字号 / 语言：行内容宿主**离屏测量**时显式透传（见 RowContent），
 /// 否则按默认 traits 测得的高度与大字号用户的真实显示高度不一致。
    var dynamicTypeSize: DynamicTypeSize = .large
    var locale: Locale = .current

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITableView {
        let tableView = UILAnchoredTableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
 // 原生滚动指示条：旧代码关闭它是翻转布局
 // （scaleY(-1) 会把系统指示条甩到左缘且方向反）时代的遗产；现已改回
 // 常规（非翻转）底座，原生指示条位置/方向正常。自绘 InvertedScrollBar
 // 只存在于 SwiftUI 回退后端，UIKit 后端此前两个都没有 = 滚动条消失
 // 。
        tableView.showsVerticalScrollIndicator = true
        tableView.contentInsetAdjustmentBehavior = .never
 // self-sizing 依赖非零估算开启。估算引发的 contentOffset 自动调整由
 // 「动画期间冻结可见行高度快照 + 目标行显式高度」压制（contentSize 变化
 // 全部确定化，无估算差值）。estimatedRowHeight=0 会禁用自撑高（展开行
 // 不再长高—— E2E 实测），不能用。
        tableView.estimatedRowHeight = 160
        tableView.rowHeight = UITableView.automaticDimension
        tableView.keyboardDismissMode = .interactive
        tableView.allowsSelection = false
 // 常规（非翻转）底座：数据顺序 = 视觉顺序（旧→新，最新在内容底部）。
 // 去翻转：`scaleY(-1)` 会系统性破坏 **行级 AX frame**
 // （实测 process-group-row/flow-row frame 全为 (0,0,0,0)、hittable=0，
 // VoiceOver 与 XCUITest 都无法聚焦/点击）——无障碍是用户可感知质量问题，
 // 必须修。改回常规几何 + 锚定补偿/贴底伺服后，滚动性能不回退。
        context.coordinator.attach(tableView: tableView)
        return tableView
    }

    func updateUIView(_ tableView: UITableView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyFromSwiftUI(items: items, batchToken: historyBatchToken)
    }

    static func dismantleUIView(_ tableView: UITableView, coordinator: Coordinator) {
        coordinator.detach()
    }

 // MARK: - Cell

    final class MessageCell: UITableViewCell {
        static let reuseID = "SessionMessageCell"
        var rowID: String = ""
 /// 用于上报「cell 内容高度」→ 触发自撑高重测（点击展开这类 SwiftUI 内部状态变化
 /// 不会让 UITableView 自动重测行高，内容会一直被旧行高裁剪）。
        weak var coordinator: Coordinator?
 /// 当前挂载的行内容宿主视图。**不拥有**它（归 Coordinator 的行宿主缓存）：
 /// cell 复用只切换挂载，宿主与已完成的 SwiftUI 布局继续留在缓存里，
 /// 滚回同一行时直接再挂载 = 零重排。
        private weak var hostView: UIView?
 /// 行宿主缓存条目（高度真值来源；见 layoutSubviews 注释）。
        private weak var rowHostRef: RowHost?
 /// 宿主高度（= 内容高度）：cell 布局时按它把宿主顶端对齐摆放。
 /// attach 时初值 + layoutSubviews 每次以 rowHostRef.height 活值校正。
        private var hostHeight: CGFloat = 0

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            backgroundColor = .clear
            contentView.backgroundColor = .clear
            selectionStyle = .none
 // 展开/收起动画期间按 cell 边界裁剪内容，避免行高过渡中内容溢出压到相邻行。
            contentView.clipsToBounds = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

 /// 挂载一行的 hosted SwiftUI 内容（内容与行高已由 Coordinator 缓存完成布局）。
        #if DEBUG
        private static let traceEnabled = ProcessInfo.processInfo.environment["DSHM_UIL_DUMP"] == "1"
        #endif

        func attach(rowID: String, hostView: UIView, coordinator: Coordinator, host: RowHost) {
            self.coordinator = coordinator
            self.rowID = rowID
            self.rowHostRef = host
 // 同一行的宿主视图可能在「reloadItems 的旧 cell → 新 cell」之间转移：
 // 先把旧 cell 的引用清掉，避免旧 cell 的 prepareForReuse 把已经挂到新
 // cell 上的宿主视图 removeFromSuperview（= 新 cell 整行空白）。
            if let previous = host.attachedCell, previous !== self {
                previous.detachHostReference(hostView)
            }
            host.attachedCell = self
            #if DEBUG
            if Self.traceEnabled {
                print("[uilattach] \(rowID) cell=\(ObjectIdentifier(self)) subsBefore=\(contentView.subviews.count) hostSame=\(self.hostView === hostView)")
            }
            #endif
            guard self.hostView !== hostView else { return }
            self.hostView?.removeFromSuperview()
            hostView.removeFromSuperview()
 // 宿主高度 = 完整内容高度、**顶端对齐**，高度不随行高动画变化：
 // 行高动画 = 裁剪窗口从顶端生长（内容 1:1、不重排、不缩放）。
 // 若让 autoresizing 跟随 cell 高度，动画每帧都会改宿主尺寸 → SwiftUI
 // 每帧重排内容（280ms × 60fps = 大量布局），既卡又变形。
 // 注意：cell 刚创建时 contentView.bounds 可能还是 0 宽（尚未布局），
 // 直接用它当宿主宽度会让内容宽度为 0（整屏空白， 实测）。
 // 先用已知的测量宽度，layoutSubviews 再按真实 contentView 宽度校正。
            self.hostHeight = host.height
            hostView.frame = CGRect(x: 0, y: 0,
                                    width: max(1, contentView.bounds.width > 1 ? contentView.bounds.width : host.width),
                                    height: host.height)
            hostView.autoresizingMask = [.flexibleWidth]
            contentView.addSubview(hostView)
            self.hostView = hostView
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let hostView else { return }
            #if DEBUG
            if Self.traceEnabled, rowID.hasPrefix("process") {
                NSLog("[GEO] row=%@ cell=%@ hostFrame=%@ hostH=%.0f clip=%d",
                      rowID, NSCoder.string(for: frame), NSCoder.string(for: hostView.frame),
                      hostHeight, contentView.clipsToBounds ? 1 : 0)
            }
            #endif
 // 高度真值跟随宿主缓存条目：needsRemeasure 路径会原地重测并更新
 // host.height（不经 attach），用 attach 时的过期拷贝会把宿主视图压回
 // 旧高度——巨型组展开后内容全渲染但 hit-test 只覆盖旧高度（组头
 // 48pt），「展开其余」按钮永远点不到(E2E [GEO] 实锤：
 // cell=1240 host=48）。这里每次布局都取活值，压回操作永远对齐真值。
            if let liveHeight = rowHostRef?.height, liveHeight > 0 {
                hostHeight = liveHeight
            }
            let width = contentView.bounds.width
            if width > 1, abs(hostView.frame.width - width) > 0.5
                || abs(hostView.frame.height - hostHeight) > 0.5 {
                hostView.frame = CGRect(x: 0, y: 0, width: width, height: hostHeight)
            }
        }

        #if DEBUG
 /// 布局取证（DSHM_UIL_DUMP=1）：一度用来定位「行存在但屏幕全黑」。
        var uiDump: String {
            let hv = hostView.map { "host=\(type(of: $0)) frame=\($0.frame) hidden=\($0.isHidden) inCV=\($0.superview === contentView)" } ?? "host=nil"
            return "cell=\(ObjectIdentifier(self)) row=(\(rowID)) frame=\(frame) subs=\(contentView.subviews.count) \(hv)"
        }
        #endif

 /// 宿主转移到别的 cell 时，清掉本 cell 对它的引用（不碰视图层级）。
        func detachHostReference(_ view: UIView) {
            if hostView === view { hostView = nil }
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            #if DEBUG
            if Self.traceEnabled {
                print("[uilreuse] rowID=\(rowID) cell=\(ObjectIdentifier(self)) host=\(hostView != nil) subsBefore=\(contentView.subviews.count)")
            }
            #endif
 // 内容宿主归缓存所有：只断开**本 cell 实际挂着的**那个宿主，不销毁
 // （滚回来可直接复用已完成的布局）。宿主可能已被转移到别的 cell：
 // 此时 superview 不是本 cell 的 contentView，绝不能 remove（否则把
 // 正在显示的那一行内容撤掉 = 整行空白）。
            if let hostView, hostView.superview === contentView {
                hostView.removeFromSuperview()
            }
            hostView = nil
            rowID = ""
            rowHostRef = nil
        }
    }

 /// 一行的 SwiftUI 内容（原 `UIHostingConfiguration` 内容逐字搬移）。
    struct RowContent: View {
        let item: SessionMessageItem
        let isNewest: Bool
        let parent: MessageTableRepresentable
 /// 内容版本号：签名变化（流式/显示态/展开其余）时递增 → `.id(serial)` 强制重建
 /// SwiftUI 视图身份（与旧 UIHostingConfiguration 每次 reconfigure 重建一致）。
        let serial: Int
 /// **weak**：unowned 在「页面退出 →
 /// Coordinator 已释放、宿主视图晚一帧仍被渲染」时 swift_abortRetainUnowned
 /// 直接闪退。weak + body 守卫：释放后渲染空内容（页面都没了，行内容无意义）。
        weak var coordinator: Coordinator?

        @ViewBuilder
        var body: some View {
            if let coordinator {
                rowBody(coordinator: coordinator)
            }
        }

        private func rowBody(coordinator: Coordinator) -> some View {
            VStack(spacing: 0) {
                Group {
                    switch item {
                    case .group(let group):
 // 显示态真值：父级 processGroupModes 覆盖（含本端动画中的
 // 乐观覆盖）+ ProcessGroupModeResolver（巨型组默认折叠）。
                        let mode = coordinator.resolvedMode(forGroup: group, isNewest: isNewest)
                        let contentSignature = group.stepsContentSignature
                        let cachedStepsHeight = coordinator.cachedStepsHeight(
                            forGroupID: group.id,
                            contentSignature: contentSignature
                        )
                        FlowRowGroupView(
                            group: group,
                            sessionId: parent.sessionId,
                            attachments: parent.attachments,
                            pendingApprovalCallIds: parent.pendingApprovalCallIds,
                            subagentLabels: parent.subagentLabels,
                            isNewestGroupRunning: isNewest,
                            mode: mode,
 // 动画期间钉住步骤内容高度：既禁用 SwiftUI 隐式动画
 // （否则与 UIKit 行高动画叠加 = 弹跳），又让内容高度
 // 确定化（行高裁剪窗口 1:1 揭示）。
                            animatedStepsHeight: coordinator.animatedStepsHeightOverride(forGroupID: group.id),
                            cachedStepsHeight: cachedStepsHeight,
                            stepsContentSignature: contentSignature,
                            onStepsHeightDelta: { delta in
                                MainActor.assumeIsolated {
                                    coordinator.handleGiantStepsHeightDelta(groupID: group.id, delta: delta)
                                }
                            },
 // 巨型组「展开其余」步数真值由容器持有（cell 重建不丢）。
                            revealedStepsOverride: coordinator.giantRevealedStepsOverride(for: group.id),
                            onRevealStepsChange: { count in
                                MainActor.assumeIsolated {
                                    coordinator.setGiantRevealedSteps(groupID: group.id, count: count)
                                }
                            },
                            windowHeight: parent.processGroupWindowHeight,
                            onToggleMode: {
                                MainActor.assumeIsolated {
                                    coordinator.handleGroupModeToggleTap(groupID: group.id)
                                }
                            },
                            onOpenReasoning: parent.onOpenReasoning,
                            onOpenTool: parent.onOpenTool,
                            onOpenRelay: parent.onOpenRelay
                        )
                        .equatable()
                    case .fileChanges(let changes):
                        FileChangesCard(changes: changes) { parent.onOpenFileChanges(changes) }
                    case .liveText(let text):
                        MarkdownText(text: text)
                            .padding(Theme.Spacing.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                            .accessibilityIdentifier("live-assistant-stream")
                    case .streamError(let message):
                        InlineErrorView(message: message) { parent.onRetry() }
                            .accessibilityIdentifier("session-stream-error")
                    case .actionError(let message):
                        InlineErrorView(message: message)
                    }
                }
 // 底部弹性垫：容器（cell）高于内容时撑底 → 内容恒贴行固定端。
 // 顶对齐是「裁剪揭示」的前提（行高动画 = 裁剪窗口从固定端渐变，
 // 内容 1:1 不变形、逐步露出）；此前 maxHeight.infinity 会把自撑高
 // 测量顶到异常大值（行被撑过头 = 弹跳过冲 + 收起回不到原位，
 // 真机目击）。VStack+Spacer 的 ideal = 内容高，测量正常。
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.pageInset)
            .padding(.vertical, Theme.Spacing.s / 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(serial)
 // 离屏测量（未挂窗口）时显式透传动态字号/语言：否则按默认 traits 测得的高度
 // 与真实显示高度不一致（大字号用户会一律偏矮）。
            .environment(\.dynamicTypeSize, parent.dynamicTypeSize)
            .environment(\.locale, parent.locale)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: UILRowContentHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(UILRowContentHeightKey.self) { height in
                coordinator.rowContentHeightChanged(
                    rowID: item.id, contentHeight: height, serial: serial
                )
            }
 // 过程组步骤内容高度测量上报（展开态 reader）→ 缓存（组头点击 Δ 数据源）。
            .onPreferenceChange(ProcessGroupStepsHeightKey.self) { heights in
                guard !heights.isEmpty else { return }
                coordinator.groupStepsHeightsReported(heights)
            }
 // 只有用户主动点开的展开体（思考块/子代理卡/问题详情）才上报「用户交互」，
 // 供 coordinator 区分「用户点击导致的行高变化」与「布局期/流式内容的高度变化」。
            .environment(\.userToggleReporter, { coordinator.noteUserToggle(rowID: item.id) })
        }
    }

 /// 行内容宿主：UIHostingController 一次性完成 SwiftUI 布局并记住高度；
 /// 之后无论 cell 复用多少次，再挂载都不用重排。
    final class RowHost {
        let id: String
        var signature: String
        let width: CGFloat
        var height: CGFloat
        let hosting: UIHostingController<RowContent>
        var lastUsed: CFTimeInterval
 /// 内容版本号：旧宿主被替换释放前的最后一次高度上报会被丢弃（见
 /// rowContentHeightChanged—— 真机/模拟器实锤：收起刚落地
 /// 48，3ms 后被旧宿主（396）的临终上报污染，行高永久停在展开态）。
        var serial: Int = 0
 /// 内容高度上报触发的重测标记：上报的是「被分配高度」（GeometryReader
 /// 在布局链里拿到的尺寸，cell 高时内容会被拉伸），**不能直接当理想高度写回**
 /// （收起瞬间 cell 仍 396 → 上报 396 → 行高永久卡展开态， 实锤）。
 /// 真值统一由 sizeThatFits（理想高度，不受 cell 拉伸影响）重测。
        var needsRemeasure = false
 /// 当前挂载它的 cell（evict 时跳过，避免把正在显示的行释放掉）。
        weak var attachedCell: MessageCell?

        init(id: String, signature: String, width: CGFloat, height: CGFloat,
             hosting: UIHostingController<RowContent>) {
            self.id = id
            self.signature = signature
            self.width = width
            self.height = height
            self.hosting = hosting
            self.lastUsed = CACurrentMediaTime()
        }
    }

 // MARK: - Coordinator

    final class Coordinator: NSObject, UITableViewDelegate {
        var parent: MessageTableRepresentable
        weak var tableView: UILAnchoredTableView?
        private var dataSource: UITableViewDiffableDataSource<String, String>?
 /// 显示窗口（视觉顺序旧→新；不是全量 items）。
        private var displayedItems: [SessionMessageItem] = []
 /// 显示窗口起点行 id：nil = 默认窗口（最近 N 行，跟随新内容）；
 /// 非 nil = 用户向上扩展过，窗口固定从该行开始。
        private var windowStartItemID: String?
        private var groupLookup: [String: FlowRowGroup] = [:]
        private var didInitialBottom = false
 /// 贴底跟随状态（r7 语义）：只有用户手势 settle 判定能改写，内容变化绝不改写。
        private var pinned = true
        private var userHasScrolled = false
 /// 读历史期间被冻结的尾部内容（回到近底部时一次性应用，iMessage 语义）。
        private var pendingFrozenItems: [SessionMessageItem]?
 /// 用户主动展开/收起的行（时间戳）：只有这些行的行高变化才走「入口行固定」
 /// 锚点会话，其余（首屏布局/流式内容/历史补齐）走无锚点重测。
        private var pendingUserToggleRowIDs: [String: CFAbsoluteTime] = [:]
        private var userIsScrolling = false
        private var isAdjustingOffset = false
 /// 静止阅读时的冻结锚点（最上方可见行 + 屏幕位置）；每次布局后保持它不动。
        private var desiredAnchor: (rowID: String, screenY: CGFloat)?
 /// 已处理到的「强制回底」请求序号（发送消息 / 答完问答）。
        private var lastScrollToBottomToken: Int = 0
 /// 上一次布局时的视口高度：键盘/内联行/输入框增高会改变它，读历史时需要补偿。
        private var lastViewportHeight: CGFloat = 0
 /// 上一次应用时的过程组显示态覆盖，用于把「点击/阶段切换」转成行重测。
        private var lastGroupModes: [String: ProcessGroupMode] = [:]
 /// 上一次应用时的 running 标记：true→false 时最新组要从窗口态切到折叠态。
        private var lastRunningFlag = false
 /// 窗口扩展防重入。
        private var isExpandingWindow = false
 /// DD-01：分段扩窗的延后 apply 尚未落地。`isExpandingWindow` 要一直保持到
 /// 那次 apply 真正执行完（`heightForRowAt` 对远端的估算让路依赖它）。
        private var windowExpansionPendingApply = false
 /// DD-01：`apply` 重入守卫。diffable data source 的批次更新进行中再 apply 一次
 /// 快照会触发 `BUG_IN_CLIENT_OF_DIFFABLE_DATA_SOURCE` abort(设备
 /// 崩溃日志：`scrollViewDidScroll → maybeExpandWindow → apply`）。守卫为真时
 /// 新请求只落进 `pendingApply`（后到覆盖先到），本次应用结束后延后一拍续跑。
        private var isApplying = false
 /// DD-01：应用进行中收到的最后一拍请求（后到覆盖先到；内容不丢）。
        private var pendingApply: (items: [SessionMessageItem], batchToken: Int, skipModeChange: Bool)?
 /// DD-01：滚动回调/扩窗的「同一拍合并」请求槽（`requestApply` 用）——只保留
 /// 最后一次的 `skipModeChange`；真正的 items/batchToken 在执行那一拍重取最新值。
        private var pendingRequestedApply: Bool?
 /// 本拍是否已排期一次延后 apply（同一拍多次 requestApply 只跑一次）。
        private var isApplyRequestScheduled = false
 /// 上次窗口扩展时刻（扩展冷却，抑制扩展/回落振荡）。
        private var lastWindowExpandAt: CFTimeInterval = 0
 /// 本次 apply 是否跳过锚定修正（动画刚结束的收敛窗口）。
        private var settleSkipAnchorApply = false

 /// 上次展开/收起动画结束时刻：动画结束后 2s 内禁止扩窗——扩窗的
 /// 全窗重排会打断刚完成的锚定(逐帧数据：收起后数据批
 /// 触发的扩窗使 off 2030→1598，终态漂移 216pt）。
        private var lastAnimationEndAt: CFTimeInterval = 0
 /// 手势窗口 offset 采样（HUD gm/gf 字段）。
        private var lastTraceOffset: CGFloat = -1

 /// DD-03：`facts` 的 @Published 只服务 DEBUG HUD / e2e 探针（自绘指示条已删除）。
 /// 无读者时不发布——否则每帧一次 objectWillChange 会让 SwiftUI 持续重算。
        private static let debugFactsReaderEnabled: Bool = {
            #if DEBUG
            let env = ProcessInfo.processInfo.environment
            return env["DSHM_E2E_HUD"] == "1"
                || env["DSHM_E2E"] == "1"
                || env["DSHM_SCROLLDBG"] == "1"
                || env["DSHM_DEBUG_STREAM"] == "1"
            #else
            return false
            #endif
        }()

 // MARK: - 行内容宿主缓存
 //
 // 背景：`UIHostingConfiguration` 自撑高 cell 每出现一条
 // Markdown 行要付两次 SwiftUI 布局（自撑高测量 + 显示布局），中位帧
 // 48.5ms vs SwiftUI 容器 16.7ms。改成「Coordinator 持有 UIHostingController
 // 宿主 + 显式行高」后：每行只布局一次，之后无论 cell 复用多少次再挂载都不重排。
        private var rowHosts: [String: RowHost] = [:]
        private var rowHostSerials: [String: Int] = [:]
 /// 巨型组「已渲染步数」真值（key = group.id）：cell 复用/重建不丢状态
 /// （契约审计回归项 v7.1；SwiftUI 回退后端行身份稳定，不需要）。
        private var giantRevealedSteps: [String: Int] = [:]
        private var rowHostWidth: CGFloat = 0
        private var lastStepsLayoutSignature = ""
        private var hostReloadScheduled = false

 // MARK: - v7：自动连续滚动 / 内容高度探针

 /// App 内自动连续滚动（DEBUG + DSHM_AUTOSCROLL=1）的帧时钟/目标/方向。
        private var autoScrollTicker: GroupToggleTicker?
        private var lastAutoScrollTime: CFTimeInterval = 0
        private var autoScrollTarget: CGFloat = -1
        private var autoScrollDirection: CGFloat = 1
 /// 上一次 facts 的内容高度（contentSizeChange 探针：只在真变化时上报）。
        private var lastFactsContentHeight: CGFloat = 0

        init(_ parent: MessageTableRepresentable) {
            self.parent = parent
        }

        #if DEBUG
 /// 布局取证（DSHM_UIL_DUMP=1）：输出 table/可见 cell/宿主视图的真实 frame。
        private func dumpLayout(_ reason: String) {
            guard let tableView else { return }
            print("[uildump] \(reason) tableFrame=\(tableView.frame) bounds=\(tableView.bounds) off=\(tableView.contentOffset.y) ch=\(tableView.contentSize.height) visible=\(tableView.indexPathsForVisibleRows?.count ?? -1) window=\(tableView.window != nil)")
            for (i, cell) in tableView.visibleCells.enumerated().prefix(6) {
                if let c = cell as? MessageCell {
                    print("[uildump] visible[\(i)] \(c.uiDump)")
                } else {
                    print("[uildump] visible[\(i)] other \(type(of: cell)) frame=\(cell.frame)")
                }
            }
        }
        #endif

        func attach(tableView: UILAnchoredTableView) {
            self.tableView = tableView
            tableView.onLayoutPass = { [weak self] in self?.stabilizeAfterLayout() }
            tableView.delegate = self
            #if DEBUG
            maybeStartE2EAutopilot()
            #endif
            tableView.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseID)
            lastScrollToBottomToken = parent.scrollToBottomToken
            lastViewportHeight = tableView.bounds.height
            lastRunningFlag = parent.isRunning
            lastGroupModes = parent.processGroupModes
            let dataSource = UITableViewDiffableDataSource<String, String>(tableView: tableView) { [weak self] tableView, indexPath, itemID in
                guard let self,
                      let cell = tableView.dequeueReusableCell(withIdentifier: MessageCell.reuseID, for: indexPath) as? MessageCell,
                      let item = self.item(for: itemID) else {
                    return UITableViewCell()
                }
                cell.coordinator = self   // 点击展开后上报内容高度 → 触发自撑高重测
                let host = self.rowHost(for: item, isNewest: self.isNewest(item), reason: "cell")
                cell.attach(rowID: itemID, hostView: host.hosting.view, coordinator: self, host: host)
                #if DEBUG
                ScrollJitterProbe.shared?.register(rowID: itemID, view: cell)
                #endif
                return cell
            }
            self.dataSource = dataSource
            #if DEBUG
            if ProcessInfo.processInfo.environment["DSHM_UIL_DUMP"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                    self?.dumpLayout("t+4s")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                    self?.dumpLayout("t+8s")
                }
            }
            #endif
            #if DEBUG
            ScrollJitterProbe.shared?.attach(table: tableView)
            installProbeObservers(tableView)
            ProcessToggleProbe.shared?.bind(
                offset: { [weak tableView] in
                    guard let tableView else { return 0 }
 // CA 动画期间 contentOffset getter 返回模型终值；presentation
 // layer 的 bounds.origin 才是这一帧真正上屏的偏移（E2E 动效判定）。
                    if let presentation = tableView.layer.presentation() {
                        return presentation.bounds.origin.y
                    }
                    return tableView.contentOffset.y
                },
                viewportHeight: { [weak tableView] in tableView?.bounds.height ?? 0 },
                contentHeight: { [weak tableView] in tableView?.contentSize.height ?? 0 },
                rowFrame: { [weak self] id in
                    guard let self,
                          let tableView = self.tableView,
                          let dataSource = self.dataSource,
                          let indexPath = dataSource.indexPath(for: id) else { return .null }
 // 行高动画期间 rectForRow 返回模型终值；presentation layer 的
 // frame 才是这一帧真正上屏的行位置（动效/逐帧定住判定用）。
                    if let cell = tableView.cellForRow(at: indexPath),
                       let layer = cell.layer.presentation() {
                        return layer.frame
                    }
                    return tableView.rectForRow(at: indexPath)
                }
            )
            #endif
 // 帧级卡顿探针：列表上屏即开始逐帧采样（DEBUG + DSHM_HITCHDBG=1 才生效）。
            ScrollHitchProbe.start()
 // 步骤高度缓存的布局签名（宽度在 table 侧补齐；字号/语言变化会失效）。
            prepareStepsHeightStore()
            #if DEBUG
            startAutoScrollIfNeeded()
            #endif
        }

        func detach() {
            ScrollHitchProbe.stop()
            heightTicker?.stop()
            heightTicker = nil
            giantRepinTicker?.stop()
            giantRepinTicker = nil
            rowHosts.removeAll(keepingCapacity: false)
            rowHostSerials.removeAll(keepingCapacity: false)
            rowHeightEstimates.removeAll(keepingCapacity: false)
            giantRevealedSteps.removeAll(keepingCapacity: false)
            pendingMeasure.removeAll()
            stopMeasureDrainTimer()
            heightAnimator?.stopAnimation(true)
            heightAnimator = nil
            heightAnimationActive = false
 // DD-01: 视图已拆除——丢弃已排期的延后 apply（主队列闭包自查空槽退出）。
            pendingApply = nil
            pendingRequestedApply = nil
            isApplyRequestScheduled = false
            windowExpansionPendingApply = false
            isExpandingWindow = false
            animatedTargetHeight = nil
            groupToggleOverride.removeAll()
            pendingModeOverride.removeAll()
            legacyHeightRefreshWork?.cancel()
            legacyHeightRefreshWork = nil
            heightMeasureWork?.cancel()
            heightMeasureWork = nil
            giantRevealWork?.cancel()
            giantRevealWork = nil
            #if DEBUG
            autoScrollTicker?.stop()
            autoScrollTicker = nil
            offsetObservation?.invalidate()
            offsetObservation = nil
            sizeObservation?.invalidate()
            sizeObservation = nil
            if let tableView { ScrollJitterProbe.shared?.detachTable(tableView) }
            #endif
        }

        #if DEBUG
 // MARK: - E2E autopilot（DSHM_E2E_PROCGROUP=history 专用）

 /// XCUITest 的合成点击在「翻转 table + UIHostingConfiguration」下不可用
 /// （AX frame 系统性损坏， 取证 5 轮）。E2E 注入场景改为 App 内
 /// 自驱动：滚动到注入组头可见 → **同一路径调用 onToggleGroupMode**（与手指
 /// 点击组头完全同一闭包入口）→ 展开 → 收起。探针照常逐帧记录，判定脚本
 /// 不变；真机人工验收仍是最终 UX 确认。
        private var autopilotWork: DispatchWorkItem?

        private func maybeStartE2EAutopilot() {
 // 专用开关：autopilot 会自己滚到注入组头并展开/收起，与「测试自己点组头」
 // 的方向回归用例抢同一个组（时序不可控）。因此只在
 // `DSHM_E2E_PROCGROUP_AUTOPILOT=1` 时启动，不再由 DSHM_E2E_PROCGROUP=history
 // 隐式触发（契约审计）。
            guard ProcessInfo.processInfo.environment["DSHM_E2E_PROCGROUP_AUTOPILOT"] == "1",
                  ProcessToggleProbe.shared != nil,
                  autopilotWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.runE2EAutopilotStep(0) }
            autopilotWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }

        private func runE2EAutopilotStep(_ step: Int, retry: Int = 0) {
            guard let tableView, let dataSource else { return }
            let anchorID = "process-e2e-hist-proc-0"
            guard let indexPath = dataSource.indexPath(for: anchorID) else {
 // 内容尚未 apply（慢加载）：重试（1s × 最多 6 次）。
                if retry < 6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.runE2EAutopilotStep(step, retry: retry + 1)
                    }
                } else {
                    pinLog("autopilot anchor missing after retries")
                }
                return
            }
            switch step {
            case 0:
 // 滚到注入组头行进视口中部：行布局 minY 距视口参考端 vh/2
 // （翻转下无论内容朝向哪端，行都落在视口中部）。
                let maxOff = max(0, tableView.contentSize.height - tableView.bounds.height)
                let rect = tableView.rectForRow(at: indexPath)
                let target = max(0, min(rect.minY - tableView.bounds.height / 2, maxOff))
 // 布局期间的 stabilizeAfterLayout 会按**旧锚点**把 offset 钉回
 /// 滚动前位置(取证：target=518 被 stabilize 拉回 52，
 /// 组头留屏外、视口外行自撑高异常 Δ452≠348）——整个滚动+布局+
 /// 重冻结包在 isAdjustingOffset 里（stabilize 对其跳过）。
                isAdjustingOffset = true
                tableView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                tableView.layoutIfNeeded()
                freezeAnchorFromCurrentViewport(tableView)
                isAdjustingOffset = false
                pinLog("autopilot scroll off=\(String(format: "%.1f", target)) rowMinY=\(String(format: "%.1f", rect.minY))")
 // 等内容稳定再点击：真实用户点击时数据静止；E2E 会话在 VM 连续
 /// 补齐（每秒百行 + 显示窗口翻转），与动画叠加会污染一切判定
 /// 。
                waitForContentStable(tableView) { [weak self] in self?.runE2EAutopilotStep(1) }
            case 1:
                pinLog("autopilot expand (same path as user tap)")
                self.handleGroupModeToggleTap(groupID: anchorID)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.runE2EAutopilotStep(2) }
            case 2:
                pinLog("autopilot collapse (same path as user tap)")
                self.handleGroupModeToggleTap(groupID: anchorID)
            default:
                break
            }
        }

 /// contentSize 连续 stableFor 秒不变（或超时 maxWait）后执行 continuation。
        private func waitForContentStable(_ tableView: UITableView,
                                           stableFor: CFTimeInterval = 1.0,
                                           maxWait: CFTimeInterval = 8.0,
                                           _ continuation: @escaping () -> Void) {
            autopilotStableTick(tableView, stableFor: stableFor, maxWait: maxWait,
                                start: CACurrentMediaTime(), lastHeight: -1,
                                lastChange: CACurrentMediaTime(), continuation: continuation)
        }

        private func autopilotStableTick(_ tableView: UITableView,
                                          stableFor: CFTimeInterval,
                                          maxWait: CFTimeInterval,
                                          start: CFTimeInterval,
                                          lastHeight: CGFloat,
                                          lastChange: CFTimeInterval,
                                          continuation: @escaping () -> Void) {
            let now = CACurrentMediaTime()
            let h = tableView.contentSize.height
            var height = lastHeight, change = lastChange
            if abs(h - lastHeight) > 1 {
                height = h
                change = now
            }
            if now - change >= stableFor || now - start >= maxWait {
                pinLog("autopilot content stable ch=\(Int(h)) waited=\(String(format: "%.1f", now - start))")
                continuation()
                return
            }
            let work = DispatchWorkItem { [weak self] in
                self?.autopilotStableTick(tableView, stableFor: stableFor, maxWait: maxWait, start: start, lastHeight: height, lastChange: change, continuation: continuation)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }

        private var offsetObservation: NSKeyValueObservation?
        private var sizeObservation: NSKeyValueObservation?

 /// 取证：谁在「用户没滚动、代码也没主动调 offset」时改了 contentOffset/contentSize？
        private func installProbeObservers(_ tableView: UITableView) {
            guard ScrollJitterProbe.shared != nil else { return }
            offsetObservation = tableView.observe(\.contentOffset, options: [.old, .new]) { [weak self] table, change in
                guard let self, self.didInitialBottom,
                      !self.userIsScrolling, !self.isAdjustingOffset,
                      !table.isTracking, !table.isDecelerating else { return }
                guard let old = change.oldValue, let new = change.newValue else { return }
                let delta = new.y - old.y
                guard abs(delta) > 1.0 else { return }
                MainActor.assumeIsolated {
                    ScrollJitterProbe.shared?.event("offsetKVO", [
                        "delta": Double(delta),
                        "off": Double(new.y),
                        "ch": Double(table.contentSize.height),
                        "stack": Coordinator.compactStack(),
                    ])
                }
            }
            sizeObservation = tableView.observe(\.contentSize, options: [.old, .new]) { [weak self] table, change in
                guard let self, self.didInitialBottom,
                      !self.userIsScrolling, !self.isAdjustingOffset,
                      !table.isTracking, !table.isDecelerating else { return }
                guard let old = change.oldValue, let new = change.newValue else { return }
                let delta = new.height - old.height
                guard abs(delta) > 2.0 else { return }
                MainActor.assumeIsolated {
                    ScrollJitterProbe.shared?.event("sizeKVO", [
                        "delta": Double(delta),
                        "ch": Double(new.height),
                        "off": Double(table.contentOffset.y),
                        "stack": Coordinator.compactStack(),
                    ])
                }
            }
        }

        static func compactStack(_ limit: Int = 18) -> String {
            Thread.callStackSymbols.prefix(limit).compactMap { line -> String? in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 4 else { return nil }
                return String(parts[1]) + "!" + String(parts[3])
            }.joined(separator: ";")
        }

 /// E2E 诊断：把锚点决策写到 App Documents/heighpin.log。
        private func pinLog(_ message: String) {
            guard ProcessInfo.processInfo.environment["DSHM_E2E"] == "1" else { return }
            guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = dir.appendingPathComponent("heighpin.log")
            let line = String(format: "%.3f ", Date().timeIntervalSince1970) + message + "\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }

 /// DSHM_PROCDBG=1 取证：行高（UIKit 自撑高结果）vs hosting 内容实际高度。
        private func logProcessRowHeights(_ tableView: UITableView, reason: String) {
            guard UILProcessGroupDebug.enabled else { return }
            var parts: [String] = []
            for indexPath in tableView.indexPathsForVisibleRows ?? [] {
                guard let id = dataSource?.itemIdentifier(for: indexPath), id.hasPrefix("process-") else { continue }
                let rowHeight = tableView.rectForRow(at: indexPath).height
                let hosting = tableView.cellForRow(at: indexPath)?.contentView.subviews.first?.bounds.height ?? -1
                parts.append("\(id.suffix(8)) row=\(Int(rowHeight)) hosting=\(Int(hosting))")
            }
            guard !parts.isEmpty else { return }
            print("[procdbg] \(reason) " + parts.joined(separator: " | "))
        }
        #endif

        private func item(for id: String) -> SessionMessageItem? {
            if let group = groupLookup[id] { return .group(group) }
            return displayedItems.first { $0.id == id }
        }

 // MARK: - 行内容宿主缓存

 /// 行渲染签名：命中即复用已完成的 SwiftUI 布局，变化则按新状态重建内容。
        private func rowSignature(_ item: SessionMessageItem, isNewest: Bool) -> String {
            switch item {
            case .group(let group):
                let mode = resolvedMode(forGroup: group, isNewest: isNewest).rawValue
                let revealed = giantRevealedStepsOverride(for: group.id).map { "|r\($0)" } ?? ""
                return "g|\(group.id)|\(group.stepsContentSignature)|\(mode)|\(isNewest ? 1 : 0)\(revealed)"
            case .fileChanges(let changes):
                return "f|\(changes.source)|\(changes.titleFileCount)|\(changes.files.count)|\(changes.added)|\(changes.deleted)"
            case .liveText(let text):
                return "l|\(text)"
            case .streamError(let message):
                return "se|\(message)"
            case .actionError(let message):
                return "ae|\(message)"
            }
        }

 /// 取（必要时构建）一行的内容宿主。**每行只布局一次**：命中缓存直接返回，
 /// 不再有自撑高测量；未命中则用 UIHostingController 做一次离屏布局并记住高度。
        func rowHost(for item: SessionMessageItem, isNewest: Bool, reason: String = "-") -> RowHost {
            let width = max(1, tableView?.bounds.width ?? UIScreen.main.bounds.width)
            if abs(width - rowHostWidth) > 0.5 {
 // 宽度变化（旋转/分屏/首次布局）：所有行高度失效，整体重建，
 // 并异步重挂已显示行的 cell（否则 cell 里还挂着旧宽度的宿主视图）。
                rowHostWidth = width
                rowHosts.removeAll(keepingCapacity: true)
                rowHostSerials.removeAll(keepingCapacity: true)
                rowHeightEstimates.removeAll(keepingCapacity: false)
                scheduleHostReloadAfterLayoutChange()
            }
            let signature = rowSignature(item, isNewest: isNewest)
            if let existing = rowHosts[item.id], existing.signature == signature,
               abs(existing.width - width) <= 0.5 {
                existing.lastUsed = CACurrentMediaTime()
                if existing.needsRemeasure {
                    existing.needsRemeasure = false
                    let fitted = existing.hosting.sizeThatFits(
                        in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                    )
                    existing.height = max(1, ceil(fitted.height))
                    existing.hosting.view.frame = CGRect(
                        x: 0, y: 0, width: width, height: existing.height
                    )
                }

                return existing
            }
            let rebuild = rowHosts[item.id] != nil
            rowHostSerials[item.id, default: 0] += 1
            let serial = rowHostSerials[item.id] ?? 1
            if let existing = rowHosts[item.id] { existing.serial = serial }
 // 构建/更新宿主期间关闭隐式动画（内容版本变化不应做过渡）。
            let previousAnimations = UIView.areAnimationsEnabled
            UIView.setAnimationsEnabled(false)
            defer { UIView.setAnimationsEnabled(previousAnimations) }
            let content = RowContent(item: item, isNewest: isNewest, parent: parent,
                                     serial: serial, coordinator: self)
            let host: RowHost
            if let existing = rowHosts[item.id] {
                existing.signature = signature
                existing.hosting.rootView = content
                host = existing
            } else {
                let hosting = UIHostingController(rootView: content)
                hosting.view.backgroundColor = .clear
                hosting.view.translatesAutoresizingMaskIntoConstraints = true
                hosting.view.frame = CGRect(x: 0, y: 0, width: width, height: 1)
                host = RowHost(id: item.id, signature: signature, width: width,
                               height: 1, hosting: hosting)
                rowHosts[item.id] = host
            }
 // 一次离屏布局：拿到真实内容高度（宿主 view 尺寸与最终行高一致，
 // 挂到 cell 上时不再触发重排）。
 // 【滚动丝滑 v6】宿主因 LRU 逐出后被**同签名**重建时（内容/显示态都没
 // 变，纯滚动回归），直接复用上次实测高度、跳过 sizeThatFits 的整次
 // SwiftUI 布局——大 Markdown 行首现 50-95ms 的主成本就是这一步，
 // 复用后滚动回归的物化成本近似减半。
            var height: CGFloat
            if let cached = rowHeightEstimates[item.id],
               cached.signature == signature, cached.height > 1 {
                height = cached.height
            } else {
                let fitted = host.hosting.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
                height = max(1, ceil(fitted.height))
                rowHeightEstimates[item.id] = RowHeightEstimate(signature: signature, height: height)
            }
            host.height = height
            host.hosting.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.lastUsed = CACurrentMediaTime()
            #if DEBUG
            ScrollHitchProbe.mark("rowHostBuild", [
                "from": reason,
                "id": item.id,
                "kind": item.rowKindForProbe,
                "steps": item.stepCountForProbe,
                "ch": Double(height).rounded(),
                "rebuild": rebuild ? 1 : 0,
            ])
            #endif
            evictRowHostsIfNeeded()
            return host
        }

 /// 宽度/字号/语言变化后：已显示行的宿主视图已被重建，需要让 cell 重新挂载。
 /// （diffable 数据源下不能直接 reloadData，用 snapshot.reloadItems。）
        private func scheduleHostReloadAfterLayoutChange() {
            guard !hostReloadScheduled else { return }
            hostReloadScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let tableView = self.tableView, let dataSource = self.dataSource else {
                    self?.hostReloadScheduled = false
                    return
                }
                self.hostReloadScheduled = false
                guard dataSource.numberOfSections(in: tableView) > 0 else { return }
                var snapshot = dataSource.snapshot()
                let ids = snapshot.itemIdentifiers
                guard !ids.isEmpty else { return }
                UIView.performWithoutAnimation {
                    snapshot.reloadItems(ids)
                    dataSource.apply(snapshot, animatingDifferences: false)
                    tableView.layoutIfNeeded()
                }
                self.freezeAnchorFromCurrentViewport(tableView)
            }
        }

 /// 宿主缓存上限（内存 vs 复用率的折中）：最近用过的 ~160 行保留，
 /// 超出后按 LRU 淘汰（跳过仍挂载在 cell 上的行）。
        private func evictRowHostsIfNeeded() {
            let cap = 160
            guard rowHosts.count > cap else { return }
            var overflow = rowHosts.count - cap + 24
            let sorted = rowHosts.values.sorted { $0.lastUsed < $1.lastUsed }
            for host in sorted where overflow > 0 {
                if host.attachedCell != nil { continue }
                rowHosts.removeValue(forKey: host.id)
                rowHostSerials.removeValue(forKey: host.id)
                overflow -= 1
            }
        }

 /// 巨型组展开后的组头钉位伺服（对抗 UIKit 的延迟 offset adjustment）。
        private var giantRepinTicker: GroupToggleTicker?
        private var giantRepinDeadline: CFTimeInterval = 0

        private func startGiantRepin(groupID: String, targetOffset: CGFloat, tableView: UITableView) {
            giantRepinTicker?.stop()
            giantRepinDeadline = CACurrentMediaTime() + 3.0
            let ticker = GroupToggleTicker()
            giantRepinTicker = ticker
            ticker.start { [weak self, weak tableView] _ in
                guard let self, let tableView else { return }
                if CACurrentMediaTime() > self.giantRepinDeadline || tableView.isTracking
                    || self.userIsScrolling {
                    ticker.stop()
                    if self.giantRepinTicker === ticker { self.giantRepinTicker = nil }
                    return
                }
 // **scrollToRow(.top) 官方定位，无条件执行**：
 // offset/rect 判据都会被 UIKit 的延迟 adjustment / 采样时序欺骗
 // （实锤：off 恒 0 导致条件分支从未执行）。scrollToRow 幂等——
 // 已对齐时是 no-op，未对齐时把被点行钉回视口顶。
                if let dataSource = self.dataSource,
                   let indexPath = dataSource.indexPath(for: groupID) {
                    self.isAdjustingOffset = true
                    tableView.scrollToRow(at: indexPath, at: .top, animated: false)
                    self.isAdjustingOffset = false
                    ScrollHitchProbe.mark("giantRepin", [
                        "engine": "scrollToRow",
                        "to": Double(tableView.contentOffset.y).rounded(),
                    ])
                }
            }
        }

 /// 巨型组已渲染步数：容器侧真值（RowContent 构建时读取）。
        func giantRevealedStepsOverride(for groupID: String) -> Int? {
            guard case .group(.process(let steps))? = displayedItems.first(where: { $0.id == groupID }),
                  ProcessGroupStepsLayoutPolicy.isGiant(steps.count) else { return nil }
            return giantRevealedSteps[groupID]
        }

        func setGiantRevealedSteps(groupID: String, count: Int) {
            NSLog("[GAPP] setGiantRevealedSteps id=%@ count=%d tableView=%d", groupID, count, tableView != nil ? 1 : 0)
            guard let tableView else { return }
            giantRevealedSteps[groupID] = count
 // **必须下一 runloop 再动表格**：回调发生在 SwiftUI 按钮 action 里
 // （hosting 布局过程中），同步 dataSource.apply + layoutIfNeeded 会
 // 重入表格布局 → 点击无效(真机报障"展开更多点了没反应"；
 // 同路径的 handleGiantStepsHeightDelta 也是为此走 async）。
            DispatchQueue.main.async { [weak self] in
                guard let self, let tableView = self.tableView else { return }
                self.animateGiantReveal(groupID: groupID, tableView: tableView)
            }
        }

 /// 巨型组「展开其余」追加一批：与展开/收起同款 easeOutCubic 高度动画
 /// （v5 设计决策 第三轮：交互动效一致）。
 /// 行高从当前实测 → 新揭示态实测逐帧插值；内容钉新揭示高度、行高裁剪
 /// 窗口 1:1 揭示，组头（rowMinY）布局位置不动 ⇒ 屏幕位置天然钉住。
        private func animateGiantReveal(groupID: String, tableView: UITableView) {
            guard let item = item(for: groupID),
                  let indexPath = dataSource?.indexPath(for: groupID),
                  case .group(let group) = item else { return }
            let oldRowHeight = tableView.rectForRow(at: indexPath).height
 // 按已写入的新揭示值重建宿主 → 目标行高实测（字典已先行写入）。
            invalidateRowHosts([groupID])
            let newRowHeight = rowHost(for: item, isNewest: isNewest(item), reason: "reconfigure").height
            guard abs(newRowHeight - oldRowHeight) > ScrollFollowPolicy.compensationTolerance else {
                reconfigureRow(groupID: groupID, tableView: tableView)
                return
            }
            ScrollHitchProbe.mark("giantRevealAnim", [
                "group": groupID,
                "from": Double(oldRowHeight).rounded(),
                "to": Double(newRowHeight).rounded(),
            ])
 // v5 终版：平行实现（无论钉序）渲染上都是
 // 单帧瞬跳、300ms 动画零像素变化；唯一经确认平滑渲染的是「展开」
 // 路径（beginGroupModeAnimation 展开分支：先切内容、后钉旧行高、
 // ticker 逐帧）。reveal = 行高变化的展开语义，直接复用同一入口，
 // 不再维护第二套序列（巨组行高由 giantRowHeights 实测提供）。
            beginGroupModeAnimation(
                groupID: groupID,
                group: group,
                currentMode: .expanded,
                targetMode: .expanded,
                stepsHeight: max(0, newRowHeight - collapsedGroupRowHeight),
                giantExpandedHeight: max(0, newRowHeight - collapsedGroupRowHeight),
                giantRowHeights: (oldRowHeight, newRowHeight),
                notifyParent: false,
                tableView: tableView,
                indexPath: indexPath
            )
        }

 // MARK: - 闲置预测量（v5 第三轮）

 /// 已加载但从未测量的行（估算粗 → UIKit offset 调整/插入补偿漂移 + 滚动
 /// 到达时同步测量卡顿）。静止时每 tick 实测一行：estimatedHeightForRowAt
 /// 逐步变精确，滚动到达时宿主/高度已就绪。
        private var pendingMeasure = PendingMeasureQueue()
        private var measureDrainTimer: DispatchSourceTimer?
 /// 回填期 drain 让路的状态（仅在状态翻转时打一个探针点）。
        private var measureDrainSkipMarked = false
 /// 回填期伺服让路状态（仅在状态翻转时打一个探针点）。
        private var servoFillSkipMarked = false

        private func queueUnmeasuredRowsForIdleMeasure(_ items: [SessionMessageItem]) {
 // v6.2 冻结修复：未测量行先去重再入队。旧实现
 // 每次 apply 全量追加且不去重——流式会话 10-25Hz 的 apply 把队列以
 // 每秒上千条推大，drain 只消化 ~60 条/秒 → 队列爆炸后重排比较器
 // O(队列 × 行数) 直接烧死主线程（真机 CPU Resource 报告 23:51:41：
 // 92% CPU × 97s，栈为 apply → queueUnmeasured → prioritize → id 拷贝）。
            var unmeasured: [String] = []
            for item in items where rowHosts[item.id] == nil && rowHeightEstimates[item.id] == nil {
                unmeasured.append(item.id)
            }
            guard pendingMeasure.enqueue(unmeasured) else { return }
            prioritizePendingMeasureByProximity()
            startMeasureDrainTimer()
        }

 /// 【滚动丝滑 v6】按**距视口的远近**重排待测量队列：FIFO（最旧在前）会把
 /// 预算全花在远处行——用户向上滚动时即将到达的是「视口上方紧邻」的行，
 /// 就近排序让短暂停顿的 drain 都花在刀刃上（回填期滚动卡顿的主源之一
 /// 是新页行被滚动追上时的现场物化，真机 rowAppear 间隙 35-511ms）。
 ///
 /// v6.2 冻结修复：位置表一次 O(n) 构建后排序只做 O(1) 查表。旧实现每个
 /// 比较都做两次 displayedItems.firstIndex 线性扫描并现算行 id（组 id 需
 /// 拷贝 ProcessStep/JSONValue 负载），复杂度 O(m log m × n)，队列一大多
 /// 即主线程爆炸。
        private func prioritizePendingMeasureByProximity() {
            guard pendingMeasure.count > 1, let tableView, let dataSource,
                  let first = tableView.indexPathsForVisibleRows?.first,
                  let anchorID = dataSource.itemIdentifier(for: first) else { return }
            var positions: [String: Int] = [:]
            positions.reserveCapacity(displayedItems.count)
            for (idx, item) in displayedItems.enumerated() { positions[item.id] = idx }
            guard let anchor = positions[anchorID] else { return }
            pendingMeasure.reorder(
                MeasureProximityPolicy.ordered(pendingMeasure.ids, positions: positions, anchor: anchor)
            )
        }

        private func startMeasureDrainTimer() {
            guard measureDrainTimer == nil, tableView != nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .main)
 // 每拍至多一行（长文本行的 SwiftUI 测量本身可达几十 ms；滚动/动画/
 // 拖拽期间一律让出主线程，只在静止时消化）。
            timer.schedule(deadline: .now() + 0.2, repeating: 0.016)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                guard let tableView = self.tableView else {
                    self.stopMeasureDrainTimer()
                    return
                }
 // 【v6.1 复盘】曾在拖拽/惯性中测轻行（12ms/帧预算）——实测**有害**
 // （滚动帧 >50ms 6→13、p95 17→21：任何构建工作进入滚动帧都直接
 // 变成卡顿，SwiftUI 构建不可抢占）。滚动/动画期间一律让路。
 // 【 回填期让路】历史补齐进行中同样一律让路：单行 SwiftUI
 // 测量 20-40ms，逐帧合入期间每 16ms 一拍会把主线程占满，实测让
 // relay 档 page1/page2 的合入各停摆 1.0s/2.5s（fullHistory 4339ms）。
 // 行高仍走估算 + 可见行按需物化，补齐结束后队列按就近顺序继续 drain。
                if tableView.isTracking || tableView.isDecelerating || tableView.isDragging
                    || self.heightAnimationActive || self.userIsScrolling {
                    return
                }
 // 回填期让路：与滚动/动画同等级，整段 drain 暂停；
 // 补齐结束后自动恢复（队列按就近顺序继续消化）。首次跳过/恢复各打一个点，
 // 便于真机归因确认闸门真的生效（不逐 tick 打点）。
                if self.parent.isFillingHistory {
                    if !self.measureDrainSkipMarked {
                        self.measureDrainSkipMarked = true
                        ScrollHitchProbe.mark("drainSkipForFill", ["queued": self.pendingMeasure.count])
                    }
                    return
                }
                if self.measureDrainSkipMarked {
                    self.measureDrainSkipMarked = false
                    ScrollHitchProbe.mark("drainResume", ["queued": self.pendingMeasure.count])
                }
                if self.pendingMeasure.isEmpty {
                    self.stopMeasureDrainTimer()
                    return
                }
                guard let id = self.pendingMeasure.removeFirst() else { return }
                if let item = self.item(for: id) {
 // rowHost 构建路径内部会把 (签名, 高度) 写入 rowHeightEstimates。
                    _ = self.rowHost(for: item, isNewest: self.isNewest(item), reason: "drain")
                }
            }
            timer.resume()
            measureDrainTimer = timer
        }

        private func stopMeasureDrainTimer() {
            measureDrainTimer?.cancel()
            measureDrainTimer = nil
        }

 /// 拖拽期间允许测量的「轻行」：短文本 / 小组 / 卡片行（构建成本 <10ms）。
        private static func isLightMeasureItem(_ item: SessionMessageItem) -> Bool {
            switch item {
            case .group(let group):
                let steps = group.stepCount
                return !ProcessGroupStepsLayoutPolicy.isGiant(steps) && steps <= 8
            case .liveText(let text):
                return text.count < 500
            case .fileChanges, .streamError, .actionError:
                return true
            }
        }

 /// 行内容变化（数据批）：让签名失配，下次取宿主时重建。
        private func invalidateRowHosts(_ ids: [String]) {
            for id in ids where rowHosts[id] != nil {
                rowHosts[id]?.signature = "invalidated"
            }
        }

        private func isNewest(_ item: SessionMessageItem) -> Bool {
 // 与 SwiftUI 回退后端（基线 SessionMessageListView.isNewest）同口径：
 // 运行中 + 过程组 + 全局最后一行就是这个组。刻意不用
 // currentTurnStartSeq / displayedItems——两个后端对「运行中窗口 ⇄ 折叠」
 // 必须完全一致，否则同一会话在两种容器下显示态不同（契约审计）。
            guard parent.isRunning else { return false }
            guard case .group(let group) = item else { return false }
            guard case .process = group else { return false }
            guard case .group(let last)? = parent.items.last else { return false }
            return last.id == group.id
        }

 // MARK: - 过程组展开/收起（easeOutCubic 280ms / 巨型组同帧切态）

 /// 诊断开关（**仅性能取证用**，默认关闭 = 生产行为）：
 /// - `DSHM_UIL_NO_HEIGHT_REFRESH=1` 关闭「非用户交互行高变化 → 合并重测」；
 /// - `DSHM_UIL_NO_SERVO=1` 关闭布局期锚定伺服。
 /// 用途：定位 UIKit 后端逐行物化成本（A/B 实测每行比 SwiftUI 高约 30ms）。
        static let noHeightRefresh: Bool = ProcessInfo.processInfo.environment["DSHM_UIL_NO_HEIGHT_REFRESH"] == "1"
        static let noServo: Bool = ProcessInfo.processInfo.environment["DSHM_UIL_NO_SERVO"] == "1"

 /// 行高动画进行中标志（UIViewPropertyAnimator 驱动；stabilize / apply 对其跳过）。
        private var heightAnimationActive = false
 /// 行高动画的显式高度（钉住中间态；UITableView 只对显式行高做 CA 插值）。
        private var animatedTargetHeight: (rowID: String, height: CGFloat)?
 /// 行高动画器（翻转时代遗留；非翻转底座已改 CADisplayLink 手动插值，见 heightTicker）。
        private var heightAnimator: UIViewPropertyAnimator?
 /// 普通组展开/收起动画的帧时钟（逐帧插值显式行高）。
        private var heightTicker: GroupToggleTicker?
 /// 展开/收起动画中「步骤内容高度」覆盖（key = FlowRowGroup.id）：
 /// 传给行内容的 animatedStepsHeight —— 固定内容高度并禁用 SwiftUI 隐式动画，
 /// 内容按 `cell.contentView.clipsToBounds` 的裁剪窗口 1:1 揭示。
        private var groupToggleOverride: [String: CGFloat] = [:]
 /// 物化过的行高记忆（签名 + 高度）：estimatedHeightForRowAt 的非过程组
 /// 兜底 + 宿主重建时的「跳过重复测量」依据（签名一致 = 同输入同高度）。
        private struct RowHeightEstimate {
            let signature: String
            let height: CGFloat
        }
        private var rowHeightEstimates: [String: RowHeightEstimate] = [:]
 /// 本端乐观显示态覆盖：父级状态更新是异步的（self.parent 是值拷贝），
 /// 点击到 apply 之间先用它解析显示态，避免内容闪回旧态。
        private var pendingModeOverride: [String: ProcessGroupMode] = [:]
 /// 过程组步骤内容高度缓存（内容签名校验；组头点击 Δ 的数据源）。
        private var groupStepsHeightStore = GroupStepsHeightStore()
 /// 步骤高度缓存布局签名（宽度|字号|语言）。
        private var stepsLayoutSignature: String = ""
 /// 上次构建签名用的 table 宽度（未变时跳过签名重建）。
        private var stepsStoreWidth: CGFloat = -1
 /// 巨型组「展开其余 N 步」的 offset 补偿（合并到下一 runloop，避免在
 /// SwiftUI 布局/按钮回调里同步重入 tableView 更新）。
        private var giantRevealWork: DispatchWorkItem?

 /// 非用户交互的行高变化合并重测（思考块/子代理卡/问题卡之外的内容增长）。
        private var legacyHeightRefreshWork: DispatchWorkItem?
        private var heightMeasureWork: DispatchWorkItem?

 /// 折叠态整行高度（公式真值：组头 36 + 行上下 padding 12）。
        private var collapsedGroupRowHeight: CGFloat { UILProcessGroupMetrics.collapsedRowHeight }

 /// 显示态真值：父级覆盖（含本端乐观覆盖）+ 巨型组默认折叠策略。
        func resolvedMode(forGroup group: FlowRowGroup, isNewest: Bool) -> ProcessGroupMode {
            let override = pendingModeOverride[group.id] ?? parent.processGroupModes[group.id]
            return ProcessGroupModeResolver.resolve(
                isRunning: isNewest,
                override: override,
                stepCount: group.stepCount
            )
        }

 /// 展开态步骤内容高度缓存（内容签名一致才命中）。
        func cachedStepsHeight(forGroupID id: String, contentSignature: String) -> CGFloat? {
            groupStepsHeightStore.height(forGroup: id, contentSignature: contentSignature)
        }

 /// 动画期间传给行内容的步骤内容高度覆盖（非 nil = 固定内容高度 + 禁用隐式动画）。
        func animatedStepsHeightOverride(forGroupID id: String) -> CGFloat? {
            groupToggleOverride[id]
        }

 /// 行内容（展开态 reader）上报的过程组步骤内容高度 → 合并缓存。
        func groupStepsHeightsReported(_ heights: [String: ProcessGroupStepsHeight]) {
            ScrollHitchProbe.mark("groupStepsHeights", [
                "count": heights.count,
                "changed": heights.count != groupStepsHeightStore.heights.count ? 1 : 0,
            ])
            groupStepsHeightStore.update(heights)
        }

 /// 重配置单行（内容态变化后必须 reconfigure：UIHostingConfiguration 的
 /// hosted 内容只在 configure 时重建；行高由后续 batchUpdates 重测）。
        private func reconfigureRow(groupID: String, tableView: UITableView) {
            guard let dataSource, dataSource.indexPath(for: groupID) != nil else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([groupID])
            dataSource.apply(snapshot, animatingDifferences: false)
            tableView.layoutIfNeeded()
        }

 /// 点击过程组头（组件内 `onToggleMode` 的唯一落点）。
 ///
 /// 普通组（≤ 巨型阈值）：easeOutCubic 280ms —— 行高与 contentOffset 在
 /// **同一个动画器、同一条曲线**里插值，组头逐帧定住。
 /// 巨型组：同帧切态 + 一次 offset 补偿（设计决策：不做逐帧高度动画）。
        func handleGroupModeToggleTap(groupID: String) {
            guard heightAnimationActive == false, heightAnimator == nil,
                  let tableView,
                  let indexPath = dataSource?.indexPath(for: groupID),
                  let item = item(for: groupID),
                  case .group(let group) = item else { return }
            let isNewest = self.isNewest(item)
            let currentMode = resolvedMode(forGroup: group, isNewest: isNewest)
            let targetMode = ProcessGroupModeResolver.toggled(currentMode)
            let stepCount = group.stepCount
            let contentSignature = group.stepsContentSignature
 // 高度来源优先级：内容签名命中的实测缓存 > 公式估算（步骤行固定行高，
 // 误差 ≤ 高亮行数）。缓存签名不一致（折叠期间内容变化）时**不用旧值**。
            let stepsHeight = max(
                0,
                groupStepsHeightStore.height(forGroup: groupID, contentSignature: contentSignature)
                    ?? group.estimatedStepsHeight
            )
 // 巨型组展开态步骤内容高（initialSteps 步 + 可能存在的「展开其余」按钮行）。
            var giantExpandedHeight = group.estimatedStepsHeight(limit: ProcessGroupStepsLayoutPolicy.initialSteps)
                + (stepCount > ProcessGroupStepsLayoutPolicy.initialSteps
                    ? ProcessGroupStepsLayoutPolicy.revealRowHeight
                    : 0)
 // v5（设计决策 第三轮）：巨型组展开/收起与普通组**同款
 // easeOutCubic 动画**。可行性前提都已就位：
 // - 分批揭示后单次 Δ ≤ ~1240pt（首展 40 步 / 每批 40 步）；
 // - 实测高度（下方 current/target 双态实测）消除公式二次收敛；
 // - estimatedHeightForRowAt 让 UIKit 的 offset 调整不再跳变。
            var giantRowHeights: (current: CGFloat, target: CGFloat)?
            if ProcessGroupStepsLayoutPolicy.isGiant(stepCount) {
 // 现态实测（宿主缓存命中，零成本）；再置目标态重建实测。
 // giantExpandedHeight = **展开态步骤内容高**（动画期内容钉高用，
 // 两个方向都取展开侧：展开=target、收起=current）。
                let currentHeight = rowHost(for: item, isNewest: isNewest, reason: "toggle-current").height
                pendingModeOverride[groupID] = targetMode
                let targetHeight = rowHost(for: item, isNewest: isNewest, reason: "toggle-target").height
                giantRowHeights = (currentHeight, targetHeight)
                let expandedTotal = targetMode == .collapsed ? currentHeight : targetHeight
                giantExpandedHeight = max(0, expandedTotal - collapsedGroupRowHeight)
            }
            beginGroupModeAnimation(
                groupID: groupID,
                group: group,
                currentMode: currentMode,
                targetMode: targetMode,
                stepsHeight: stepsHeight,
                giantExpandedHeight: giantExpandedHeight,
                giantRowHeights: giantRowHeights,
                notifyParent: true,
                tableView: tableView,
                indexPath: indexPath
            )
        }

 /// 展开/收起统一入口：普通组与巨型组同款 easeOutCubic 高度动画
 /// （v5 设计决策 第三轮：动效一致；巨型组单次 Δ 有界 + 高度实测）。
        private func beginGroupModeAnimation(
            groupID: String,
            group: FlowRowGroup,
            currentMode: ProcessGroupMode,
            targetMode: ProcessGroupMode,
            stepsHeight: CGFloat,
            giantExpandedHeight: CGFloat,
            giantRowHeights: (current: CGFloat, target: CGFloat)?,
            notifyParent: Bool,
            tableView: UITableView,
            indexPath: IndexPath
        ) {
            let isCollapse = targetMode == .collapsed
 // 行高真值：巨型组 = 双态实测（v5）；普通组 = 公式（组头 36 + padding 12 +
 // 步骤内容高度），**不用** rectForRow 自撑高缓存（反复交互后会读到旧值 →
 // 行高累积漂移， 真机「下方空一块 + 多次跳变」根因）。
            let collapsedRowHeight = collapsedGroupRowHeight
            let oldRowHeight: CGFloat
            let newRowHeight: CGFloat
            if let heights = giantRowHeights {
                oldRowHeight = heights.current
                newRowHeight = heights.target
            } else {
                let expandedRowHeight = collapsedRowHeight + stepsHeight
                oldRowHeight = isCollapse ? expandedRowHeight : collapsedRowHeight
                newRowHeight = isCollapse ? collapsedRowHeight : expandedRowHeight
            }
            let deltaH = newRowHeight - oldRowHeight
            guard abs(deltaH) > ScrollFollowPolicy.compensationTolerance else {
                pendingModeOverride[groupID] = targetMode
                reconfigureRow(groupID: groupID, tableView: tableView)
                if notifyParent { parent.onToggleGroupMode?(groupID, targetMode) }
                return
            }
            let targetTop = visualTop(ofRow: groupID, tableView: tableView)
            let offsetBefore = tableView.contentOffset.y
 // 常规（非翻转）底座：行高变化只影响该行**下方**内容；被点行的顶端
 // （组头）布局位置不变 ⇒ 屏幕位置天然钉住，无需 offset 补偿。
            let targetOffset = offsetBefore
            ScrollHitchProbe.mark("toggleStart", [
                "group": groupID,
                "delta": Double(deltaH).rounded(),
                "from": currentMode.rawValue,
                "to": targetMode.rawValue,
                "engine": "uikit",
            ])
            #if DEBUG
            emitProcessToggleProbeEvent(
                groupID: groupID,
                from: currentMode,
                to: targetMode,
                delta: deltaH,
                tableView: tableView
            )
            #endif
 // 动画期间给行内容固定步骤内容高度：禁用 SwiftUI 隐式动画
 // （ProcessGroupView 的.animation(..., value: mode) 与 CA 行高动画
 // 叠加 = 弹跳），内容按裁剪窗口 1:1 揭示。
            groupToggleOverride[groupID] = stepsHeight
            heightAnimationActive = true
 // 展开：立即切显示态（内容挂载终态，显式行高从收起高长到展开高）；
 // 收起：保持展开态到动画终帧，completion 里再 reconfigure 到折叠态。
            if !isCollapse {
                pendingModeOverride[groupID] = targetMode
                reconfigureRow(groupID: groupID, tableView: tableView)
                if notifyParent { parent.onToggleGroupMode?(groupID, targetMode) }
            }
 // 钉旧显式行高，先做一次非动画布局（把行高落到 oldRowHeight）。
            animatedTargetHeight = (groupID, oldRowHeight)
            isAdjustingOffset = true
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
                tableView.layoutIfNeeded()
            }
            let duration = parent.reduceMotion
                ? GroupToggleAnimation.reducedMotionDuration
                : GroupToggleAnimation.duration
 // 实测修正：`UIViewPropertyAnimator` + 空 `beginUpdates/endUpdates`
 // 对**显式行高**不做 CA 插值（probe 逐帧数据：rowMaxY 48→396 瞬跳，
 // 0 过渡帧）。改用 CADisplayLink 逐帧手动插值（与 SwiftUI 回退后端同款，
 // easeOutCubic 280ms 已真机验证）：每帧显式设置插值行高 → cell 以
 // 裁剪窗口逐步生长（内容挂终态、1:1 揭示），组头（rowMinY）天然不动。
            let start = CACurrentMediaTime()
            let ticker = GroupToggleTicker()
            heightTicker = ticker
            ticker.start { [weak self, weak tableView] presentationTime in
                guard let self, let tableView else { return }
                let elapsed = max(0, presentationTime - start)
                let linear = duration > 0 ? min(1, elapsed / duration) : 1
                let eased = GroupToggleAnimation.eased(linear)
                let height = GroupToggleAnimation.interpolate(
                    from: oldRowHeight, to: newRowHeight, progress: eased
                )
                self.animatedTargetHeight = (groupID, height)
                UIView.performWithoutAnimation {
                    tableView.beginUpdates()
                    tableView.endUpdates()
                }
                if linear >= 1 {
                    ticker.stop()
                    if self.heightTicker === ticker { self.heightTicker = nil }
                    self.finishGroupModeAnimation(
                        groupID: groupID,
                        targetMode: targetMode,
                        isCollapse: isCollapse,
                        targetTop: targetTop,
                        targetOffset: targetOffset,
                        tableView: tableView
                    )
                }
            }
        }

 /// 普通组动画终帧：高度归位、终态落实、残差精校、收敛窗口。
        private func finishGroupModeAnimation(
            groupID: String,
            targetMode: ProcessGroupMode,
            isCollapse: Bool,
            targetTop: CGFloat,
            targetOffset: CGFloat,
            tableView: UITableView
        ) {
            heightAnimator = nil
            heightAnimationActive = false
            animatedTargetHeight = nil
            isAdjustingOffset = false
            lastAnimationEndAt = CACurrentMediaTime()
 // 终值精校（±1-3pt 预测残差只在这里吸收，视觉不可感）。
            pinRowTop(groupID, targetTop: targetTop, tableView: tableView)
            if isCollapse {
 // 收起路径收尾：内容重配置到折叠态。reconfigure 会让行高从显式插值
 // 值回落到自撑高（contentSize 突变）——**必须在 reconfigure 后再钉一次**
 // 吸收，否则终态漂移。
                pendingModeOverride[groupID] = targetMode
 // 先 reconfigure（override 仍非 nil ⇒ ProcessGroupView 的
 // `.animation(..., value: mode)` 被禁用，避免收起末帧再叠一层
 // SwiftUI 隐式动画），随后清 override 并重测真实行高。
                reconfigureRow(groupID: groupID, tableView: tableView)
                groupToggleOverride[groupID] = nil
                remeasureRowHeight(groupID: groupID, targetTop: targetTop, tableView: tableView)
                parent.onToggleGroupMode?(groupID, targetMode)
            } else {
 // 展开路径收尾：显式行高释放回自撑高终值（内容已天然展开），
 // 重配置为「无 override」的自然高度后重测一次行高（公式估算
 // 与真实自然高度可能有 ± 几 pt 残差）并钉住组头。
                groupToggleOverride[groupID] = nil
                reconfigureRow(groupID: groupID, tableView: tableView)
                remeasureRowHeight(groupID: groupID, targetTop: targetTop, tableView: tableView)
            }
            freezeAnchorFromCurrentViewport(tableView)
            updateSharedFacts()
 // 用户主动展开/收起后不再贴底跟随（正在查看该组内容；回到底部由手势
 // settle 判定恢复）——否则动画结束后贴底伺服会把组头重新拉走。
            if pinned {
                pinned = false
                parent.shared.pinned = false
                parent.onNearBottomChange(false)
            }
            commitModesAfterLocalToggle()
 // UIKit 底座：行高/offset 由 Core Animation 在渲染服务端插值，
 // 主线程没有逐帧工作（frames=0 是预期值，不是漏采样）。
            ScrollHitchProbe.mark("toggleEnd", [
                "group": groupID,
                "target": Double(targetOffset).rounded(),
                "collapse": isCollapse ? 1 : 0,
                "frames": 0,
                "maxFrameMs": 0.0,
                "totalMs": 0.0,
                "engine": "uikit",
            ])
            #if DEBUG
            PerfProbe.shared.record("groupToggle", ms: 0, [
                "collapse": isCollapse ? 1 : 0,
                "engine": 1,
            ])
            #endif
            flushPendingItemsAfterAnimation()
        }


 /// 巨型组「展开其余 N 步」：内容高度 +Δ → 同帧补偿 offset（组头不跳）。
 ///
 /// 回调发生在 SwiftUI 按钮 action 里（hosting 布局过程中），这里只捕获
 /// 目标组头位置与旧行高，补偿合并到下一 runloop 执行（避免同步重入表格）。
        func handleGiantStepsHeightDelta(groupID: String, delta: CGFloat) {
            guard delta.isFinite, abs(delta) > ScrollFollowPolicy.compensationTolerance,
                  let tableView, let dataSource,
                  let indexPath = dataSource.indexPath(for: groupID) else { return }
 // **巨型组必须忽略「全组测量高度」上报**：stepsHeightReader 为步骤高度
 // 缓存测的是**整组**（含未渲染步骤，90 步 = 2610pt），而限量渲染下可见
 // 内容只有 initialSteps 步+按钮（v3 时期为 60 步 1820pt）。用全组高度
 // 驱动行高会把行推到 2658pt
 // → 838pt 空白（黑区）+ 行高二次暴涨触发 UIKit offset adjustment 推走
 // 组头。巨型组行高真值 =
 // giantExpandedHeight（展开）/ reveal 追加流程。
            if let item = item(for: groupID), case .group(let group) = item,
               ProcessGroupStepsLayoutPolicy.isGiant(group.stepCount) {
                ScrollHitchProbe.mark("giantReveal", [
                    "ignored": 1,
                    "delta": Double(delta).rounded(),
                    "steps": group.stepCount,
                ])
                return
            }
            let targetTop = visualTop(ofRow: groupID, tableView: tableView)
            let oldRowHeight = tableView.rectForRow(at: indexPath).height
            ScrollHitchProbe.mark("giantReveal", ["delta": Double(delta).rounded()])
            giantRevealWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak tableView] in
                guard let self, let tableView,
                      let indexPath = self.dataSource?.indexPath(for: groupID) else { return }
 // 常规底座：追加步骤只让被点行变高（下方内容下移），组头不动 ⇒ 无需补偿。
                let targetOffset = tableView.contentOffset.y
                self.heightAnimationActive = true
                self.isAdjustingOffset = true
                UIView.performWithoutAnimation {
                    self.animatedTargetHeight = (groupID, max(1, oldRowHeight + delta))
                    tableView.beginUpdates()
                    tableView.endUpdates()
                    tableView.layoutIfNeeded()
                    let maxOffsetNow = max(0, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
                    tableView.setContentOffset(
                        CGPoint(x: 0, y: min(max(targetOffset, 0), maxOffsetNow)),
                        animated: false
                    )
                }
                self.animatedTargetHeight = nil
                UIView.performWithoutAnimation {
                    tableView.performBatchUpdates(nil) { _ in }
                }
                tableView.layoutIfNeeded()
                self.pinRowTop(groupID, targetTop: targetTop, tableView: tableView)
                self.heightAnimationActive = false
                self.isAdjustingOffset = false
                self.lastAnimationEndAt = CACurrentMediaTime()
                self.freezeAnchorFromCurrentViewport(tableView)
                self.updateSharedFacts()
                if self.pinned {
                    self.pinned = false
                    self.parent.shared.pinned = false
                    self.parent.onNearBottomChange(false)
                }
                _ = indexPath
                self.flushPendingItemsAfterAnimation()
            }
            giantRevealWork = work
            DispatchQueue.main.async(execute: work)
        }

 /// 本端动画完成后把「父级当前覆盖 + 本端乐观覆盖」提交为基线：
 /// 之后 apply 不再把这次点击当成一次新的显示态变化（避免二次动画）。
        private func commitModesAfterLocalToggle() {
            lastGroupModes = parent.processGroupModes.merging(pendingModeOverride) { $1 }
            lastRunningFlag = parent.isRunning
            for (id, mode) in pendingModeOverride where parent.processGroupModes[id] == mode {
                pendingModeOverride.removeValue(forKey: id)
            }
        }

 /// 动画/同帧切态期间到达的数据批：动画结束后立即应用（VM items 是数据真相）。
        private func flushPendingItemsAfterAnimation() {
            guard pendingItemsDuringAnimation != nil else { return }
            pendingItemsDuringAnimation = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
 // 用最新 parent.items（数据真相）而不是动画期间缓存的快照：
 // 动画窗口内可能又到了更新批，缓存快照会旧。
                self.apply(items: self.parent.items, batchToken: self.parent.historyBatchToken)
            }
        }

        #if DEBUG
 /// 过程组展开/收起逐帧取证（DSHM_PROCGROUP_PROBE=1）：写 NDJSON 供
 /// analyze-proctoggle.py 判定「组头定住 / 方向 / 非线性」。
        private func emitProcessToggleProbeEvent(
            groupID: String,
            from: ProcessGroupMode,
            to: ProcessGroupMode,
            delta: CGFloat,
            tableView: UITableView
        ) {
            guard ProcessToggleProbe.shared != nil,
                  let indexPath = dataSource?.indexPath(for: groupID),
                  let group = groupLookup[groupID],
                  case .process(let steps) = group else { return }
            let frame = tableView.rectForRow(at: indexPath)
            let plan = ProcessGroupExpandAnchor.plan(
                rowFrame: frame,
                oldMode: from,
                newMode: to,
                stepCount: steps.count,
                windowHeight: parent.processGroupWindowHeight,
                offset: tableView.contentOffset.y,
                viewportHeight: tableView.bounds.height,
                contentHeight: tableView.contentSize.height
            )
            ProcessToggleProbe.shared?.event("toggle", [
                "id": groupID,
                "from": from.rawValue,
                "to": to.rawValue,
 // 巨型组同帧切态（无逐帧高度动画）：analyze-proctoggle.py 按
 // 该标志跳过「动效存在/非线性」判据，只判定布局生长+组头定住。
                "giant": ProcessGroupStepsLayoutPolicy.isGiant(steps.count) ? 1 : 0,
                "delta": plan.heightDelta,
                "u": plan.anchorUnitY ?? -1,
                "predicted": Double(plan.predictedOffset ?? -1),
                "rowMinY": Double(frame.minY),
                "rowMaxY": Double(frame.maxY),
                "offset": Double(tableView.contentOffset.y),
                "viewport": Double(tableView.bounds.height),
            ])
        }
        #endif

 // MARK: - 非过程组行高变化（SwiftUI 内部展开/收起）

 /// 行视觉顶边（组头所在端）。用户口径定案：
 /// SwiftUI 组头渲染在行的视觉**顶端**（常规底座 = rect.minY 端）。
 /// 展开时行高 +Δ 使该端视觉上移 Δ —— 必须 offset 同步 +Δ 补偿钉住组头：
 /// 组头不动 ⇒ 上方（历史）不动 ⇒ 下方（更新）被推开。收起反向。
        private func visualTop(ofRow rowID: String, tableView: UITableView) -> CGFloat {
            guard let dataSource, let indexPath = dataSource.indexPath(for: rowID) else { return 0 }
            let rect = tableView.rectForRow(at: indexPath)
 // 常规（非翻转）底座：行视觉顶 = rect.minY - offset。
 // （翻转时代的 `bounds.height - (rect.maxY - offset)` 是错的：展开后
 // maxY 增大 Δ 会让"视觉顶"凭空偏 Δ → pinRowTop 反向补偿 → 组头跳
 // 348pt，模拟器 E2E 实测。）
            return rect.minY - tableView.contentOffset.y
        }

 /// 把某行的视觉顶边钉回目标屏幕位置（反算 contentOffset）。
        private func pinRowTop(_ rowID: String, targetTop: CGFloat, tableView: UITableView) {
            guard let dataSource, let indexPath = dataSource.indexPath(for: rowID) else { return }
            let rect = tableView.rectForRow(at: indexPath)
            let currentTop = rect.minY - tableView.contentOffset.y
            let delta = targetTop - currentTop
            guard abs(delta) > 0.5 else { return }
            #if DEBUG
            if ProcessToggleProbe.shared != nil {
                ProcessToggleProbe.shared?.event("offdbg", [
                    "who": "pinRowTop", "row": rowID,
                    "from": Double(tableView.contentOffset.y).rounded(),
                    "to": Double(tableView.contentOffset.y + delta).rounded(),
                ])
            }
            #endif
            var offset = tableView.contentOffset
            offset.y += delta
            let maxY = max(0, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
            offset.y = min(max(offset.y, 0), maxY)
            tableView.setContentOffset(offset, animated: false)
        }

 /// 显式行高释放后重测自撑高真实值，并把组头钉回目标屏幕位置（残差吸收）。
        private func remeasureRowHeight(groupID: String, targetTop: CGFloat, tableView: UITableView) {
            UIView.performWithoutAnimation {
                tableView.performBatchUpdates(nil) { _ in }
            }
            tableView.layoutIfNeeded()
            isAdjustingOffset = true
            pinRowTop(groupID, targetTop: targetTop, tableView: tableView)
            isAdjustingOffset = false
        }

 /// 行高动画的显式高度（钉住中间态）。
 /// 动画期间返回目标行显式高度（钉住旧行高直到动画开始）。
        func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            if let animated = animatedTargetHeight,
               let id = dataSource?.itemIdentifier(for: indexPath), id == animated.rowID {
                return max(1, animated.height)
            }
 // 显式行高 = 行内容宿主的真实测量高度（宿主已完成布局）：
 // 不再走 `automaticDimension` 的自撑高测量（那是第二次布局）。
            guard let id = dataSource?.itemIdentifier(for: indexPath),
                  let item = item(for: id) else {
                return UITableView.automaticDimension
            }
 // 【 回填期布局让路】历史补齐的插入全部落在视口**上方**，但 UIKit
 // 会为每个新插入行索取精确高度 → 逐行构建 SwiftUI 宿主 + sizeThatFits
 // （实测 15-40ms/行；一次补齐 48-83 行 = 1.0-2.5s 主线程空档，就是 relay
 // fullHistory 4339ms 的主因：page1 leg 1664ms / page2 leg 2787ms）。
 // 回填期对「宿主尚未构建且远离视口」的行直接返回估算高度（与
 // estimatedHeightForRowAt 同源公式，零宿主构建）；可见/邻近行仍精确测量。
 // 补齐结束后该分支自然失效，恢复原有精确行高语义（滚动到该行时按需测量）。
 // 回填期 **或** 分段扩窗插入期（isExpandingWindow）：新插入行都落在视口上方，
 // 由估算高度让路；否则扩窗时 UIKit 会为最多 100 个新插入行同步建宿主
 // （20-40ms/行 = 2-4s 卡顿， 审查 P2）。
            if parent.isFillingHistory || isExpandingWindow,
               rowHosts[id] == nil, !isRowNearViewport(indexPath) {
                #if DEBUG
                ScrollHitchProbe.mark("heightEstimateSkip", ["row": indexPath.row])
                #endif
                return estimatedRowHeight(for: item, id: id)
            }
            #if DEBUG
            ScrollHitchProbe.mark("heightExactCall", ["row": indexPath.row, "filling": parent.isFillingHistory ? 1 : 0])
            #endif
            let h = rowHost(for: item, isNewest: isNewest(item), reason: "height").height
            return h
        }

 /// 行是否在可见区附近（±3 行）。用于回填期布局让路：只对远处行用估算高度。
 /// 几何未知（尚未布局/无可见行）时按「精确」处理，避免首屏行高估算偏差。
        private func isRowNearViewport(_ indexPath: IndexPath) -> Bool {
            guard let tableView,
                  let visible = tableView.indexPathsForVisibleRows, !visible.isEmpty else {
                return true
            }
            let rows = visible.map(\.row)
            guard let low = rows.min(), let high = rows.max() else { return true }
            return indexPath.row >= low - 3 && indexPath.row <= high + 3
        }

 /// 未物化行的高度估算：**必须便宜**（滚动/offset 调整高频调用，绝不构建宿主）。
 /// 优先级：签名一致的宿主缓存实测值 → 过程组折叠/展开公式 → 最近物化记忆 → 160。
        func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
            guard let id = dataSource?.itemIdentifier(for: indexPath),
                  let item = item(for: id) else { return 160 }
            return estimatedRowHeight(for: item, id: id)
        }

 /// 估算高度的单一实现（estimatedHeightForRowAt 与回填期 heightForRowAt 共用）：
 /// 保证两条路径的估算口径完全一致，回填期不会出现「同一行两个高度」。
        private func estimatedRowHeight(for item: SessionMessageItem, id: String) -> CGFloat {
 // 注意：这里**不做**签名比对——rowSignature 对多步骤组是 O(steps)
 // 字符串构建，UIKit 滚动布局期间高频调用会直接打满主线程（卡顿源）。
 // 估算允许用「上一显示态」的旧值（误差 ≤ 一次切换的 Δ，仍远优于 160）。
            if let host = rowHosts[id] {
                return host.height
            }
            if case .group(let group) = item {
                let newest = isNewest(item)
                if resolvedMode(forGroup: group, isNewest: newest) == .collapsed {
                    return collapsedGroupRowHeight
                }
                let limit = ProcessGroupStepsLayoutPolicy.isGiant(group.stepCount)
                    ? ProcessGroupStepsLayoutPolicy.initialSteps
                    : group.stepCount
                var stepsHeight = group.estimatedStepsHeight(limit: limit)
                if limit < group.stepCount {
                    stepsHeight += ProcessGroupStepsLayoutPolicy.revealRowHeight
                }
                return collapsedGroupRowHeight + stepsHeight
            }
            if let known = rowHeightEstimates[id] { return known.height }
            return 160
        }

 /// 动画期间到达的数据批（推迟到动画 completion 应用：展开动画期间
 /// 流式数据批的 apply 会做锚定/贴底修正，与动画抢 contentOffset——
 /// 这是展开「整页弹跳」的时序竞争根因，收起时数据静所以总是正确）。
        private var pendingItemsDuringAnimation: [SessionMessageItem]?

 /// 行视图按钮上报「用户主动展开/收起」（toggle 之前调用）：
 /// 记录标记；高度变化由 rowContentHeightChanged 检测后走
 /// animateContentRowHeight（思考块/子代理卡/问题卡——内容高度不可预测）。
        func noteUserToggle(rowID: String) {
            let now = CACurrentMediaTime()
            pendingUserToggleRowIDs = pendingUserToggleRowIDs.filter { now - $0.value < 1.0 }
            pendingUserToggleRowIDs[rowID] = now
        }

        private func consumeUserToggle(rowID: String) -> Bool {
            let now = CACurrentMediaTime()
            pendingUserToggleRowIDs = pendingUserToggleRowIDs.filter { now - $0.value < 1.0 }
            return pendingUserToggleRowIDs.removeValue(forKey: rowID) != nil
        }

        func rowContentHeightChanged(rowID: String, contentHeight: CGFloat, serial: Int) {
            guard contentHeight > 1, let tableView, let dataSource else { return }
            guard let indexPath = dataSource.indexPath(for: rowID) else { return }
 // 动画/同帧切态进行中：忽略（终值布局由动画块管理）。
            if heightAnimationActive { return }
 // 内容高度上报 = **失效信号**，不是真值：GeometryReader 上报的是
 // 「容器分配的高度」（cell 高时内容被 Spacer 拉伸），直接写回会把
 // 收起态行高永久污染在展开值（17.868 建 48 → 17.870 被拉到 396 上报）。
 // 真值由 rowHost(for:) 的 sizeThatFits 重测（理想高度不受拉伸影响）。
 // 版本号校验：旧宿主临终上报直接丢弃。
            if let host = rowHosts[rowID] {
                guard host.serial == serial else { return }
                if abs(host.height - contentHeight) > 0.5 {
                    host.needsRemeasure = true
                }
            }
            let rowHeight = tableView.rectForRow(at: indexPath).height
            guard rowHeight > 1, abs(contentHeight - rowHeight) > 1 else { return }
 // 非用户交互的高度变化（首屏/流式/历史补齐）：无锚点重测。
            if consumeUserToggle(rowID: rowID) {
                let top = visualTop(ofRow: rowID, tableView: tableView)
                animateContentRowHeight(rowID: rowID, targetTop: top, rowHeight: contentHeight)
                return
            }
            scheduleLegacyHeightRefresh()
        }

 /// 内容行（思考块/子代理卡/问题卡）展开收起：入口行固定 + 150ms easeInOut，
 /// 与 SwiftUI 回退后端现行为一致（行高真值用上报的内容高度）。
        private func animateContentRowHeight(rowID: String, targetTop: CGFloat, rowHeight: CGFloat) {
            guard let tableView, let dataSource,
                  let indexPath = dataSource.indexPath(for: rowID) else { return }
            let oldHeight = tableView.rectForRow(at: indexPath).height
            guard abs(rowHeight - oldHeight) > 0.5 else { return }
            let deltaH = rowHeight - oldHeight
            animatedTargetHeight = (rowID, oldHeight)
            heightAnimationActive = true
            isAdjustingOffset = true
            UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) {
                self.animatedTargetHeight = (rowID, rowHeight)
                tableView.beginUpdates()
                tableView.endUpdates()
                let maxOff = max(0, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
                let target = min(max(tableView.contentOffset.y + deltaH, 0), maxOff)
                tableView.contentOffset = CGPoint(x: 0, y: target)
            } completion: { _ in
                self.heightAnimationActive = false
                self.lastAnimationEndAt = CACurrentMediaTime()
                self.isAdjustingOffset = false
                self.animatedTargetHeight = nil
                self.pinRowTop(rowID, targetTop: targetTop, tableView: tableView)
                self.freezeAnchorFromCurrentViewport(tableView)
                self.updateSharedFacts()
                self.flushPendingItemsAfterAnimation()
            }
        }

 /// 非用户交互的行高变化：合并重测 + 底部可见行锚点，不做入口行固定。
        private func scheduleLegacyHeightRefresh() {
            if Self.noHeightRefresh { return }
            legacyHeightRefreshWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refreshHeightsLegacy() }
            legacyHeightRefreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }

        private func refreshHeightsLegacy() {
            guard let tableView, let dataSource else { return }

            guard !heightAnimationActive else { return }
            guard !tableView.isTracking, !tableView.isDecelerating else { return }
            let anchor = captureAnchor(tableView: tableView)
            isAdjustingOffset = true
            UIView.performWithoutAnimation {
                tableView.performBatchUpdates(nil) { _ in }
            }
            tableView.layoutIfNeeded()
            if let anchor, let indexPath = dataSource.indexPath(for: anchor.rowID) {
                let rect = tableView.rectForRow(at: indexPath)
                let delta = (rect.minY - tableView.contentOffset.y) - anchor.screenY
                if abs(delta) > 0.5 {
                    var offset = tableView.contentOffset
                    offset.y += delta
                    let maxY = max(0, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
                    offset.y = min(max(offset.y, 0), maxY)
                    tableView.setContentOffset(offset, animated: false)
                }
            }
            isAdjustingOffset = false
            freezeAnchorFromCurrentViewport(tableView)
            updateSharedFacts()
        }

 // MARK: - DD-01 / DD-02 / DD-09：输入去重、滚动门闸、冻结尾部快照

 /// DD-01：`updateUIView` 入口的输入键——覆盖 `applyCore` 实际读取的全部输入
 /// （items 内容签名 + batchToken + scrollToBottomToken + processGroupModes +
 /// isRunning + isFillingHistory + stepsLayoutSignature）。
        private struct ApplyInputKey: Equatable {
            var signature: MessageListSignature
            var batchToken: Int
            var scrollToBottomToken: Int
            var modes: [String: ProcessGroupMode]
            var fillingHistory: Bool
            var stepsLayoutSignature: String
        }

 /// 上一次 `updateUIView` 的输入键：未变直接返回，不进入 apply。
        private var lastUpdateViewKey: ApplyInputKey?
 /// 上一次真正应用的数据特征（DD-02 判定「仅尾部流式变化」）。
        private var lastAppliedBatchToken = Int.min
        private var lastAppliedSourceIDs: [String] = []
        private var lastAppliedLastItem: SessionMessageItem?
 /// 上一次应用时**实际参与窗口计算**的窗口起点（扩窗请求未落地前不能提前记为已应用）。
        private var lastAppliedWindowStartID: String?
 /// DD-02：滚动/惯性（tracking/decelerating）期间为 true。
        private var isScrollInteracting = false
 /// DD-05：交互 deadline 续期节流时间戳（ViewModel 侧 O(1) 更新，不重建 Task）。
        private var lastInteractionPingAt: CFTimeInterval = 0
 /// DD-02：滚动期被挂起的纯尾部流式更新（结束滚动后应用一次；内容以 parent.items 为准）。
        private var pendingTailApply: (items: [SessionMessageItem], batchToken: Int)?
 /// DD-09：滚动开始时的实时步骤内容快照（step.id → 旧 kind）。
        private var frozenStepKinds: [String: ProcessStep.Kind] = [:]
 /// DD-09：滚动开始时的 liveText 行文本（nil = 无该行）。
        private var frozenLiveTextRow: String?

 /// DD-01：只在 `updateUIView` 入口按全量输入去重。
 /// `apply` 还会被 `requestApply`（扩窗/settle）与重入续跑调用：它们的输入键可能
 /// 相同但内部窗口状态（windowStartItemID/isExpandingWindow）已变，不能在这里短路。
        func applyFromSwiftUI(items: [SessionMessageItem], batchToken: Int) {
            let key = ApplyInputKey(
                signature: messageListSignature(items: items),
                batchToken: batchToken,
                scrollToBottomToken: parent.scrollToBottomToken,
                modes: parent.processGroupModes,
                fillingHistory: parent.isFillingHistory,
                stepsLayoutSignature: parent.stepsLayoutSignature
            )
            if key == lastUpdateViewKey { return }
            lastUpdateViewKey = key
            apply(items: items, batchToken: batchToken)
        }

 /// 与 SwiftUI 回退后端 `MessageListSignature` 同口径（O(1) + 尾部 16 行扫描）：
 /// 只纳入真正影响渲染的内容，避免长会话每帧做 O(rows) 深比较。
        private func messageListSignature(items: [SessionMessageItem]) -> MessageListSignature {
            var newestStepCount = 0
            var newestFingerprint = ""
            if case .group(.process(let steps))? = items.last {
                newestStepCount = steps.count
                newestFingerprint = MessageListUpdatePolicy.processFingerprint(steps)
            }
            var liveText: String?
            var liveScanned = 0
            for item in items.reversed() {
                if liveScanned >= 16 { break }
                liveScanned += 1
                if case .liveText(let text) = item { liveText = text; break }
            }
            var parts: [String] = []
            var scanned = 0
            for item in items.reversed() {
                if scanned >= 16 || parts.count >= 8 { break }
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
            return MessageListSignature(
                count: items.count,
                firstID: items.first?.id,
                lastID: items.last?.id,
                liveText: liveText,
                running: parent.isRunning,
                newestGroupStepCount: newestStepCount,
                newestGroupFingerprint: newestFingerprint,
                tailSignature: parts.joined(separator: "#")
            )
        }

 /// DD-02：滚动/惯性期间，只有「批次不变、ids 不变、末项仍是同一过程组且步骤数不变、
 /// 窗口/回底请求没变」的纯实时文本变化才挂起；工具行（步骤数增加）、历史批次
 /// （batchToken 变化）、扩窗（窗口起点变化）等一律立即应用。
        private func shouldSuspendTailApply(items: [SessionMessageItem], batchToken: Int, skipModeChange: Bool) -> Bool {
            guard isScrollInteracting, !skipModeChange, !isExpandingWindow else { return false }
            guard batchToken == lastAppliedBatchToken else { return false }
            guard windowStartItemID == lastAppliedWindowStartID else { return false }
            guard parent.scrollToBottomToken == lastScrollToBottomToken else { return false }
            guard items.count == lastAppliedSourceIDs.count,
                  items.map(\.id) == lastAppliedSourceIDs,
                  let last = items.last,
                  let oldLast = lastAppliedLastItem else { return false }
            switch last {
            case .group(.process(let steps)):
                guard case .group(.process(let oldSteps)) = oldLast else { return false }
                return steps.count == oldSteps.count
            case .liveText:
                guard case .liveText = oldLast else { return false }
                return true
            default:
                return false
            }
        }

 /// 滚动开始：冻结尾部实时文本（步骤 id 稳定，文本以滚动开始时为准）。
        private func captureFrozenTailSnapshot() {
            frozenStepKinds.removeAll(keepingCapacity: true)
            frozenLiveTextRow = nil
            for item in displayedItems.reversed() {
                if case .group(.process(let steps)) = item {
                    for step in steps {
                        switch step.kind {
                        case .reasoning, .preparing: frozenStepKinds[step.id] = step.kind
                        default: break
                        }
                    }
                    break
                }
            }
            for item in displayedItems.reversed() {
                if case .liveText(let text) = item {
                    frozenLiveTextRow = text
                    break
                }
            }
        }

 /// DD-09：头部/工具行取最新；末组实时思考文本与 liveText 行用滚动开始时的旧内容。
        private func frozenTailInput(_ incoming: [SessionMessageItem]) -> [SessionMessageItem] {
            guard !frozenStepKinds.isEmpty || frozenLiveTextRow != nil else { return incoming }
            var result = incoming
            var frozeGroup = false
            var frozeLiveRow = false
            for index in result.indices.reversed() {
                if frozeGroup && frozeLiveRow { break }
                switch result[index] {
                case .group(.process(var steps)):
                    if frozeGroup { continue }
                    var replaced = false
                    for i in steps.indices {
                        guard let old = frozenStepKinds[steps[i].id] else { continue }
                        if applyFrozenKind(old, to: &steps[i]) { replaced = true }
                    }
                    if replaced { result[index] = .group(.process(steps)) }
                    frozeGroup = true
                case .liveText:
                    guard !frozeLiveRow, let old = frozenLiveTextRow else { continue }
                    result[index] = .liveText(old)
                    frozeLiveRow = true
                case .group, .fileChanges, .streamError, .actionError:
                    break
                }
            }
            return result
        }

 /// 只回填同类步骤内容（实时思考文本 / 准备行参数）；工具行等结构性内容保留最新。
        private func applyFrozenKind(_ old: ProcessStep.Kind, to step: inout ProcessStep) -> Bool {
            switch (step.kind, old) {
            case (.reasoning, .reasoning(let text)):
                step.kind = .reasoning(text)
                return true
            case (.preparing(let name, _), .preparing(let oldName, let oldArgs)):
                step.kind = .preparing(name: name ?? oldName, args: oldArgs)
                return true
            default:
                return false
            }
        }

 /// 记录「上一次真正与屏幕对齐」的输入，供 DD-02 判定尾部流式变化。
 /// `windowStart` 必须是该次 apply 实际参与窗口计算的值（扩窗请求要等落地后才算数）。
        private func commitAppliedInput(_ items: [SessionMessageItem], batchToken: Int, windowStart: String?) {
            lastAppliedBatchToken = batchToken
            lastAppliedSourceIDs = items.map(\.id)
            lastAppliedLastItem = items.last
            lastAppliedWindowStartID = windowStart
        }

 // MARK: - apply（显示窗口 + 冻结尾部 + 锚定）

 /// 显示窗口：只渲染「最近 N 行」（默认 300，与本地缓存深度对齐）。
        private func windowedItems(from incoming: [SessionMessageItem]) -> [SessionMessageItem] {
            guard !incoming.isEmpty else { return [] }
            if let startID = windowStartItemID,
               let index = incoming.firstIndex(where: { $0.id == startID }) {
                return Array(incoming[index...])
            }
            return MessageListWindowPolicy.initialWindow(items: incoming)
        }

 /// DD-01：唯一 apply 入口。重入时（滚动回调/扩窗在同一同步栈里再次进入）
 /// 不嵌套执行，只记录最后一拍请求，本次应用结束后由主队列下一拍续跑。
        func apply(items: [SessionMessageItem], batchToken: Int, skipModeChange: Bool = false) {
 // DD-02：滚动/惯性期间「仅尾部流式文本变化」挂起，结束滚动后用真实数据收口一次；
 // 历史批次/扩窗/工具行/运行态等其它输入必须立即应用。
            if shouldSuspendTailApply(items: items, batchToken: batchToken, skipModeChange: skipModeChange) {
                pendingTailApply = (items, batchToken)
                return
            }
 // DD-09：滚动中执行其它 apply 时，尾部实时文本用滚动开始时的快照（工具行等结构性
 // 变化立即出现）；滚动结束后用真实 items 追平。
            let effectiveItems = isScrollInteracting ? frozenTailInput(items) : items
            if isApplying {
                pendingApply = (effectiveItems, batchToken, skipModeChange)
                return
            }
            guard tableView != nil, dataSource != nil else { return }
            isApplying = true
            defer {
                isApplying = false
                if let pending = pendingApply {
                    pendingApply = nil
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.apply(
                            items: pending.items,
                            batchToken: pending.batchToken,
                            skipModeChange: pending.skipModeChange
                        )
                    }
                }
            }
            applyCore(items: effectiveItems, batchToken: batchToken, skipModeChange: skipModeChange)
        }

 /// DD-01：滚动回调/扩窗专用入口——同一拍内的多次请求合并为最后一拍，
 /// 由 `DispatchQueue.main.async` 延后一拍执行，不在滚动/批次更新的同步栈里
 /// 改数据源（崩溃与掉帧的共同来源）；执行那一拍取 coordinator 的最新输入。
        func requestApply(skipModeChange: Bool = false) {
            pendingRequestedApply = skipModeChange
            guard !isApplyRequestScheduled else { return }
            isApplyRequestScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isApplyRequestScheduled = false
                guard let pendingSkipModeChange = self.pendingRequestedApply else { return }
                self.pendingRequestedApply = nil
 // DD-02：执行这一拍时重取 coordinator 的最新输入（`parent` 由 `updateUIView`
 // 刷新）。交互结束的 ViewModel flush 与这一拍只差一个 runloop，沿用调用瞬间的
 // 快照会让结束 apply 把刚 flush 的尾部文本盖回旧值，而同一 key 的后续
 // `updateUIView` 已被 DD-01 去重、不会自动修复。
                self.apply(
                    items: self.parent.items,
                    batchToken: self.parent.historyBatchToken,
                    skipModeChange: pendingSkipModeChange
                )
            }
        }

        private func applyCore(items: [SessionMessageItem], batchToken: Int, skipModeChange: Bool) {
            defer {
 // 还有延后 apply 在排队时保持让路标志，等那次真正应用完再收口。
                if windowExpansionPendingApply,
                   pendingApply == nil,
                   pendingRequestedApply == nil {
                    windowExpansionPendingApply = false
                    isExpandingWindow = false
                }
            }
            guard let tableView, let dataSource else { return }
            #if DEBUG
            let applyStart = CACurrentMediaTime()
            #endif
            ScrollHitchProbe.mark("applyItemsChangeStart", [
                "displayed": displayedItems.count,
                "incoming": items.count,
                "pinned": pinned ? 1 : 0,
                "filling": parent.isFillingHistory ? 1 : 0,
                "wsid": windowStartItemID ?? "-",
                "interacting": isScrollInteracting ? 1 : 0,
            ])
 // 展开/收起动画期间：数据批推迟到 completion（避免修正 offset 与动画竞争）。
            if heightAnimationActive {
                pendingItemsDuringAnimation = items
                return
            }
 // 动画刚结束的 0.5s 内：布局尚在收敛（reconfigure/自撑高重测），
 // 锚定修正会用陈旧 rect 算错位移(逐帧：收起后 off 被
 // 追加修正 216pt）——此窗口内只更新数据，不做偏移修正。
            let settleDeadline = CACurrentMediaTime() - lastAnimationEndAt < 0.5
            if settleDeadline {
                settleSkipAnchorApply = true
            }
            parent.shared.incomingCount = items.count

 // 「强制回底」请求（发送消息 / 答完问答）：窗口回最新、放弃冻结、直接回底。
            let wantsBottom = parent.scrollToBottomToken != lastScrollToBottomToken
            if wantsBottom {
                lastScrollToBottomToken = parent.scrollToBottomToken
                pendingFrozenItems = nil
                windowStartItemID = nil
                parent.shared.lastScrollCommand = "token"
                if !pinned {
                    pinned = true
                    parent.shared.pinned = true
                    parent.onNearBottomChange(true)
                }
            }

 // 显示窗口解析。起点 id 失效（重连/截断/组 id 变化导致整窗重建）时**重新锚定到
 // 当前仍存在的最老已显示行**，而不是回落到 initialWindow（最近 300 行）——否则
 // 身处历史深处的用户会被抛回最新区，且 2545 的锚点修正解析不到 indexPath 而失效
 // 。
            if let startID = windowStartItemID, !items.contains(where: { $0.id == startID }) {
                let presentIDs = Set(items.map(\.id))
                windowStartItemID = displayedItems.first(where: { presentIDs.contains($0.id) })?.id
            }
 // 【回填期显示窗口锚定 · 真机归因】回填期间数据只在**头部**长出新
 // 历史行；若显示窗口跟着数据全量走（initialWindow＝最近 300 行），每次 apply
 // 都会往 UITableView 头部插入新行 → UIKit 在布局里逐行构建 SwiftUI 宿主 +
 // sizeThatFits（实测 20-40ms/行；一次补齐 36-145 行 = 1.0-2.5s 主线程空档 ×2，
 // 正是 relay fullHistory 4.0-4.5s 的主因）。
 // 回填期把窗口起点锚在「当前最老可见行」：新历史行只进 journal/数据层，不进显示
 // 表（数据层仍逐帧 prepend、页末整窗重建，AC-06 不变）；用户向上滑动时由
 // maybeExpandWindow 按 100 行分段扩窗，逐段物化历史行，不再一次性塞入整段历史。
 // 回填结束后锚点保留：显示窗口保持用户当前视野，滚动到顶部预留区再正常扩窗。
            if parent.isFillingHistory, windowStartItemID == nil,
               let oldestDisplayed = displayedItems.first?.id,
               items.contains(where: { $0.id == oldestDisplayed }) {
                windowStartItemID = oldestDisplayed
                #if DEBUG
                ScrollHitchProbe.mark("fillWindowAnchor", [
                    "displayed": displayedItems.count, "total": items.count,
                ])
                #endif
            }
            let windowStartAtApply = windowStartItemID
            var windowed = windowedItems(from: items)
            guard !windowed.isEmpty else {
 // 无内容（无缓存会话拉取中）：清空显示，骨架屏兜底。
                if !displayedItems.isEmpty {
                    displayedItems = []
                    groupLookup = [:]
                    var empty = NSDiffableDataSourceSnapshot<String, String>()
                    empty.appendSections(["main"])
                    dataSource.apply(empty, animatingDifferences: false)
                }
                commitAppliedInput(items, batchToken: batchToken, windowStart: windowStartAtApply)
                updateSharedWindow(items: items)
                ScrollHitchProbe.mark("applyItemsChangeEnd", ["displayed": 0, "incoming": items.count])
                return
            }

 // diff 检测（displayedItems ↔ windowed，视觉顺序旧→新）。
            var previous: [String: SessionMessageItem] = [:]
            for item in displayedItems { previous[item.id] = item }
            var changedIDs: [String] = []
            var newIDs: Set<String> = []
            var previousIDs: Set<String> = []
            var newGroupLookup: [String: FlowRowGroup] = [:]
            for item in windowed {
                newIDs.insert(item.id)
                if case .group(let group) = item { newGroupLookup[group.id] = group }
                if let old = previous[item.id], old != item { changedIDs.append(item.id) }
            }
            for item in displayedItems { previousIDs.insert(item.id) }

 // 动态字号/语言变化：行高全部变化 → 宿主整体失效重建。
            if parent.stepsLayoutSignature != lastStepsLayoutSignature {
                lastStepsLayoutSignature = parent.stepsLayoutSignature
                if !rowHosts.isEmpty {
                    rowHosts.removeAll(keepingCapacity: true)
                    rowHostSerials.removeAll(keepingCapacity: true)
                    scheduleHostReloadAfterLayoutChange()
                }
            }
 // 数据变化行 → 宿主签名失效（下次取宿主时按新内容重建）。
            invalidateRowHosts(changedIDs)
 // 显示态覆盖变化（父级覆盖 + 本端乐观覆盖）：reconfigure 对应行。
 // 用户点击组的行高/offset 动画由 handleGroupModeToggleTap 显式驱动
 // （pendingModeOverride 已把内容切到新态），这里只做 diff 与 bookkeeping，
 // 绝不重复启动第二套动画（两套叠加 = 弹跳）。
            let effectiveModes = parent.processGroupModes.merging(pendingModeOverride) { $1 }
            let pendingModeChange = !skipModeChange && effectiveModes != lastGroupModes
            if pendingModeChange {
                for id in effectiveModes.keys where newIDs.contains(id) {
                    if !changedIDs.contains(id) { changedIDs.append(id) }
                }
            }
 // 阶段切换（running true→false）：最新组要从「运行中窗口」自动切到「折叠一行」。
            let pendingPhaseChange = !skipModeChange && parent.isRunning != lastRunningFlag
            if pendingPhaseChange,
               let lastGroupID = windowed.last(where: { if case .group = $0 { return true }; return false })?.id,
               !changedIDs.contains(lastGroupID) {
                changedIDs.append(lastGroupID)
            }

            let insertedIDs = newIDs.subtracting(previousIDs)
            #if DEBUG
 // apply 来源标记（尾部流式 / 历史批次 / 扩窗 / 工具行 / 其它）：验证段按来源归因
 // 滚动相位内的 apply 成本；探针未开启时 `mark` 为 no-op（默认零开销）。
            let previousLastGroupStepCount: Int = {
                for item in displayedItems.reversed() {
                    if case .group(.process(let steps)) = item { return steps.count }
                }
                return 0
            }()
            let currentLastGroupStepCount: Int = {
                for item in windowed.reversed() {
                    if case .group(.process(let steps)) = item { return steps.count }
                }
                return 0
            }()
            let applySource: String
            if isExpandingWindow {
                applySource = "windowExpand"
            } else if batchToken != lastAppliedBatchToken {
                applySource = "historyBatch"
            } else if currentLastGroupStepCount > previousLastGroupStepCount {
                applySource = "toolRow"
            } else if items.last?.id != lastAppliedLastItem?.id {
                applySource = "tailInsert"
            } else if !insertedIDs.isEmpty {
                applySource = "idsInsert"
            } else {
                applySource = isScrollInteracting ? "tailStreamFrozen" : "tailStream"
            }
            ScrollHitchProbe.mark("applySource", [
                "src": applySource,
                "batch": batchToken,
                "disp": displayedItems.count,
                "incoming": items.count,
                "wsid": windowStartItemID ?? "-",
                "fill": parent.isFillingHistory ? 1 : 0,
            ])
            #endif
 // 【滚动丝滑 v6】新到行**先预热解析再走 apply 的数据工作**：后台解析
 // 与主线程 apply/滚动并发，等滚动追上这些行时 Markdown 已解析缓存
 // （此前 prewarm 在 apply 之后才看到新行，回填期存在 100-300ms 竞速）。
            if !insertedIDs.isEmpty {
                let insertedItems = windowed.filter { insertedIDs.contains($0.id) }
                MarkdownPrewarm.prewarm(items: Array(insertedItems.prefix(150)))
            }
 // 数据顺序（新→旧）：数据开头新增 = 视觉底部新内容；数据末尾新增 = 视觉顶部历史补齐。
 // 常规（非翻转）底座：数据顺序 = 视觉顺序（旧→新，最新在末尾/底部）。
            let ids = windowed.map(\.id)
 // 尾部新增 = 新消息/新过程组（时间序末尾，视觉底部）；头部新增 = 历史补齐。
            let tailAppend = !insertedIDs.isEmpty
                && ids.last.map { insertedIDs.contains($0) } == true
                && ids.first.map { insertedIDs.contains($0) } != true
            let historyAppend = !insertedIDs.isEmpty
                && ids.first.map { insertedIDs.contains($0) } == true
                && insertedIDs.contains(ids.last ?? "") == false

            #if DEBUG
            ScrollJitterProbe.shared?.startIfNeeded()
            if !insertedIDs.isEmpty {
                ScrollJitterProbe.shared?.event("rows", [
                    "old": displayedItems.count, "new": windowed.count,
                    "inserted": insertedIDs.count, "token": batchToken,
                    "tail": tailAppend ? 1 : 0, "history": historyAppend ? 1 : 0,
                ])
            }
            #endif

 // 读历史冻结（r7 语义）：只截掉**尾部新行**（新消息/新过程组 = 反转布局的
 // 数据头 insert，会推动视口）；保留已显示行的原地更新与旧端（历史）扩展
 // ——二者渲染为数据尾部 append，反转布局下零漂移。用户交互（点击展开/
 // 收起、阶段切换、强制回底）必须立刻生效，不能被冻结门吞掉
 // 。
            if didInitialBottom, !pinned, !wantsBottom,
               !pendingModeChange, !pendingPhaseChange {
                let frozen = MessageListUpdatePolicy.withoutTailInsertions(
                    displayed: displayedItems, incoming: windowed
                )
                if frozen.count < windowed.count {
                    parent.shared.lastScrollCommand = "freeze"
                }
                pendingFrozenItems = items
                windowed = frozen
            } else if didInitialBottom, pinned || wantsBottom {
                pendingFrozenItems = nil
            }

 // 只有确定要 apply 时才提交交互 bookkeeping（effectiveModes = 父级 + 本端乐观覆盖）。
            lastGroupModes = effectiveModes
            lastRunningFlag = parent.isRunning
 // 父级状态已追上本端乐观覆盖：安全丢弃本地覆盖（之后显示态以父级为真值）。
            for (id, mode) in pendingModeOverride where parent.processGroupModes[id] == mode {
                pendingModeOverride.removeValue(forKey: id)
            }

            let lastDataIDs = displayedItems.reversed().map(\.id)
            if ids == lastDataIDs && changedIDs.isEmpty {
                if wantsBottom { forceBottom(tableView) }
                displayedItems = windowed
                groupLookup = newGroupLookup
                commitAppliedInput(items, batchToken: batchToken, windowStart: windowStartAtApply)
                updateSharedWindow(items: items)
                maybeExpandWindow()
                applyFullRangeWindowIfPossible()
                return
            }

            groupLookup = newGroupLookup
            displayedItems = windowed
            queueUnmeasuredRowsForIdleMeasure(windowed)
            let anchorBeforeSnapshot = captureAnchor(tableView: tableView)
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            snapshot.appendSections(["main"])
            snapshot.appendItems(ids, toSection: "main")
            if !changedIDs.isEmpty { snapshot.reconfigureItems(changedIDs) }
            dataSource.apply(snapshot, animatingDifferences: false)
            tableView.layoutIfNeeded()
 // UIHostingConfiguration 自撑高行在 reconfigure 后不会自动重测高度，
 // 内容变高（展开/折叠、流式步骤增长）会沿用旧行高 → 内容溢出/裁剪/重叠。
 // 有变化行时做一次可见行重测（performBatchUpdates(nil) 会失效自撑高缓存）。
            if !changedIDs.isEmpty {
                UIView.performWithoutAnimation {
                    tableView.performBatchUpdates(nil) { _ in }
                }
                tableView.layoutIfNeeded()
                #if DEBUG
                logProcessRowHeights(tableView, reason: "changed=\(changedIDs.count)")
                #endif
            }
 // 布局期锚定兜底修正：锚点行是已实体化/可见行，位置是真实布局结果；
 // 若布局后它偏离了原屏幕位置，在屏幕提交前按真实差值修正 contentOffset。
 // 例外：贴底/强制回底时新内容在视觉底部，锚点补偿会把 offset 推离底部，
 // 此时直接钉住 offset 0。
 // 贴底判定用**实时几何**（off ≤ nearThreshold），不能用 pinned 状态：
 // 拖拽中（读历史）pinned 要等松手 settle 才改写，若用 pinned=true 判定，
 // 流式尾部更新会在用户手势进行中 forceBottom 把列表拽回底部
 // 。
            let nearBottomNow = max(0, bottomOffset(tableView) - tableView.contentOffset.y)
                <= MessageListUpdatePolicy.nearBottomThreshold
 // 用户手指仍在列表上（拖拽/惯性）时不强制回底：否则上滑阅读或拖拽中
 // 有新消息/尾部更新到达，会把列表从当前位置一把拽回底部（用户视角「抢滚动」）。
 // 基线 applyItemsChange 从不发滚动指令；这里只在手势外跟随。
 // **展开/收起收敛窗口内同样不回底**（巨型组行高暴增会短暂压低距底值，
 // 误触发 forceBottom = 把刚展开的组头拉出视口，与 servo/repin 同源）。
            let withinToggleConvergence = CACurrentMediaTime() - lastAnimationEndAt < 1.2
            if wantsBottom || (tailAppend && nearBottomNow && !withinToggleConvergence
                               && !tableView.isTracking && !tableView.isDecelerating) {
                forceBottom(tableView)
            } else if settleSkipAnchorApply {
                settleSkipAnchorApply = false
                freezeAnchorFromCurrentViewport(tableView)
            } else if let before = anchorBeforeSnapshot,
               !isAdjustingOffset,
               let indexPath = dataSource.indexPath(for: before.rowID) {
                let rect = tableView.rectForRow(at: indexPath)
                let delta = (rect.minY - tableView.contentOffset.y) - before.screenY
 // 手势进行中只放行「历史补齐插入」的锚定修正：插入发生在视口上方，
 // delta 是该插入位移的精确补偿（保可见内容不动，不与手指抢滚动）；
 // 跳过它会让估算位移裸露 → 回填期间快速滑动「页面位移超过手指位移」
 // 。其余更新（尾部流式等）
 // 手势中仍不做程序化修正（旧问题：拖拽被回拉）。
                let gestureOwnsPosition = tableView.isTracking || tableView.isDecelerating
                if abs(delta) > 0.5, !gestureOwnsPosition || historyAppend {
                    #if DEBUG
                    if ProcessToggleProbe.shared != nil {
                        ProcessToggleProbe.shared?.event("offdbg", [
                            "who": gestureOwnsPosition ? "apply-anchor-gesture" : "apply-anchor",
                            "row": before.rowID,
                            "from": Double(tableView.contentOffset.y).rounded(),
                            "to": Double(tableView.contentOffset.y + delta).rounded(),
                        ])
                    }
                    #endif
                    isAdjustingOffset = true
                    var offset = tableView.contentOffset
                    offset.y += delta
                    let maxY = max(0, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
                    offset.y = min(max(offset.y, 0), maxY)
                    tableView.setContentOffset(offset, animated: false)
                    isAdjustingOffset = false
                }
            }

            applyFullRangeWindowIfPossible()
            if !didInitialBottom, !displayedItems.isEmpty {
                didInitialBottom = true
 // 常规底座：最新消息在内容底部 → 首屏定位到 offset 最大值；
 // 行高/宿主布局收敛过程中由 stabilizeAfterLayout 的贴底伺服继续校正。
                snapToBottom(tableView, animated: false)
                if !parent.shared.isContentReady {
                    parent.shared.isContentReady = true
                }
                parent.onFirstContent()
 // 【滚动丝滑 v6 】首屏落定后一次性把显示窗口扩到**已加载
 // 全量**：旧机制滚动到顶部预留区才 +100 行扩窗（0.8s 冷却），完全
 // 加载的会话快速滚动时反复 apply + 头部插入 = 44 次/30s 的中段卡顿
 // 。UITableView 本身虚拟化，全量快照只
 // 是 ID 列表；一次性在用户开始滚动**之前**付掉这笔成本，滚动中
 // 零 apply。同时把全量文本交给 Markdown 后台预解析。
                scheduleFullRangeApply()
            }
            commitAppliedInput(items, batchToken: batchToken, windowStart: windowStartAtApply)
            freezeAnchorFromCurrentViewport(tableView)
            updateSharedFacts()
            updateSharedWindow(items: items)
            maybeExpandWindow()
            ScrollHitchProbe.mark("applyItemsChangeEnd", [
                "displayed": displayedItems.count,
                "incoming": items.count,
            ])
            #if DEBUG
            PerfProbe.shared.record(
                "applyItemsChange",
                ms: (CACurrentMediaTime() - applyStart) * 1000,
                ["displayed": displayedItems.count, "incoming": items.count]
            )
            #endif
 // 后台预解析窗口内文本行的 Markdown（主线程首次物化只做布局/绘制）。
            MarkdownPrewarm.prewarm(items: displayedItems)
        }

 /// 强制回到底部（反转列表：offset 0 = 视觉底部）。
        private func forceBottom(_ tableView: UITableView) {
            parent.shared.lastScrollCommand = "follow"
            ScrollHitchProbe.mark("scrollCmd", ["source": "follow"])
            pendingFrozenItems = nil
            snapToBottom(tableView, animated: false)
            if !pinned {
                pinned = true
                parent.shared.pinned = true
                parent.onNearBottomChange(true)
            }
            parent.shared.followCount += 1
            freezeAnchorFromCurrentViewport(tableView)
            updateSharedFacts()
        }

        private struct Anchor {
            let rowID: String
            let screenY: CGFloat
        }

        private func captureAnchor(tableView: UITableView) -> Anchor? {
            guard let visible = tableView.indexPathsForVisibleRows?.min(),
                  let id = dataSource?.itemIdentifier(for: visible) else { return nil }
            let rect = tableView.rectForRow(at: visible)
            return Anchor(rowID: id, screenY: rect.minY - tableView.contentOffset.y)
        }

 /// 每次布局后把冻结锚点行放回原屏幕位置（真实 frame，不依赖估算）。
 /// 贴底目标 offset（常规底座：内容底部）。
        private func bottomOffset(_ tableView: UITableView) -> CGFloat {
            max(0, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
        }

        private func snapToBottom(_ tableView: UITableView, animated: Bool) {
            let target = bottomOffset(tableView)
            guard abs(tableView.contentOffset.y - target) > 0.5 else { return }
            #if DEBUG
            if ProcessToggleProbe.shared != nil {
                ProcessToggleProbe.shared?.event("offdbg", [
                    "who": "snapToBottom", "from": Double(tableView.contentOffset.y).rounded(),
                    "to": Double(target).rounded(),
                ])
            }
            #endif
            isAdjustingOffset = true
            tableView.setContentOffset(CGPoint(x: 0, y: target), animated: animated)
            isAdjustingOffset = false
        }

        func stabilizeAfterLayout() {
            guard let tableView, didInitialBottom else { return }
            prepareStepsHeightStore()
 // 展开/收起动画期间：每次布局提交前把被点行视觉顶边钉回目标位置，
 // 行高逐帧变化与 offset 补偿同帧生效，不会先渲染出一帧位移再纠正。
            if heightAnimationActive {
                return
            }
 // 程序化连续滚动（场景 I 压测，DSHM_AUTOSCROLL=1）期间不做锚定伺服：
 // 每帧 setContentOffset 都会触发布局回调，而伺服按**上一帧**的锚点把
 // offset 拉回原位 → 与自动滚动互相拉扯(实测：offset 卡死
 // 在 1568.7、90s 内 10581 次 rowAppear 物化风暴、帧 p50=148ms）。
 // 真实手势/内容变化路径不经过这里（autoScrollTicker 只在压测 env 下存在）。
            if autoScrollTicker != nil {
                return
            }
            if Self.noServo {
                return
            }
 // 【回填期伺服让路 · 真机归因】历史补齐期间行高从估算→实测的
 // 收敛会让 contentSize 持续变化：本伺服每次布局都把 pinned 视口重钉到底，
 // setContentOffset → 下一轮布局 → 新行物化/实测 → contentSize 再变 → 再钉，
 // 形成「物化风暴」（真机实测一次补齐内两段 1.0s/2.7s 空档、每段 4200-8500 次
 // willDisplay、36-84 行新宿主=36-84×20-40ms，正是 fullHistory 4.3s 的主因）。
 // 回填期的贴底/锚定已由 apply 末尾按批完成（每帧一次，而不是每次布局一次）；
 // 补齐结束后本伺服自动恢复原语义（贴底跟随 / 读历史锚定）。
            if parent.isFillingHistory {
                if !servoFillSkipMarked {
                    servoFillSkipMarked = true
                    ScrollHitchProbe.mark("servoSkipForFill")
                }
 // 回填期「粗钉」：只在大漂移（>1 行估算高度）时补钉一次。逐 0.5pt 追钉会
 // 形成「钉→布局→再测量→再钉」的物化风暴；完全不钉则 contentSize 随行高
 // 实测增长、offset 落后 → 视口在内容里向上滑动 → 离屏历史行被大批物化
 // 。
                if pinned, !userIsScrolling, !isAdjustingOffset,
                   !tableView.isTracking, !tableView.isDecelerating,
                   CACurrentMediaTime() - lastAnimationEndAt > 1.2 {
                    let target = bottomOffset(tableView)
                    if abs(tableView.contentOffset.y - target) > 160 {
                        isAdjustingOffset = true
                        tableView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                        isAdjustingOffset = false
                    }
                }
                return
            }
            if servoFillSkipMarked {
                servoFillSkipMarked = false
                ScrollHitchProbe.mark("servoResume")
            }
 // 贴底跟随（常规底座）：pinned 且用户不在拖拽/惯性/动画中时，把视口
 // 钉在内容底部（新消息、行高收敛、宿主重测都会让底部下移）。
 // 这是「贴底跟随」的唯一执行点；不贴底时走下面的锚定伺服（保可见内容不动）。
            if pinned, !userIsScrolling, !isAdjustingOffset,
               !tableView.isTracking, !tableView.isDecelerating,
               CACurrentMediaTime() - lastAnimationEndAt > 1.2 {
                let target = bottomOffset(tableView)
                if abs(tableView.contentOffset.y - target) > 0.5 {
                    #if DEBUG
                    if ProcessToggleProbe.shared != nil {
                        ProcessToggleProbe.shared?.event("offdbg", [
                            "who": "servo-bottom", "from": Double(tableView.contentOffset.y).rounded(),
                            "to": Double(target).rounded(),
                        ])
                    }
                    #endif
                    isAdjustingOffset = true
                    tableView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                    isAdjustingOffset = false
                }
                return
            }
 // 视口高度变化（键盘弹出/收起、内联提示行、输入框多行增高）：
 // 读历史时保持可见内容不动；贴底时不动 offset（底部本就随视口移动）。
            let height = tableView.bounds.height
            if height > 1 {
                let previous = lastViewportHeight
                lastViewportHeight = height
                if previous > 1, abs(height - previous) > 0.5,
                   !pinned, !userIsScrolling, !isAdjustingOffset,
                   let anchor = desiredAnchor {
                    desiredAnchor = (anchor.rowID, anchor.screenY - (previous - height))
                }
            }
            guard !userIsScrolling, !isAdjustingOffset,
                  let desired = desiredAnchor,
                  let indexPath = dataSource?.indexPath(for: desired.rowID) else { return }
            let rect = tableView.rectForRow(at: indexPath)
            let delta = (rect.minY - tableView.contentOffset.y) - desired.screenY
            guard abs(delta) > 0.5 else { return }
            #if DEBUG
            if ProcessToggleProbe.shared != nil {
                ProcessToggleProbe.shared?.event("offdbg", [
                    "who": "servo-anchor", "row": desired.rowID,
                    "from": Double(tableView.contentOffset.y).rounded(),
                    "to": Double(tableView.contentOffset.y + delta).rounded(),
                ])
            }
            #endif
            #if DEBUG
            pinLog("stabilize row=\(desired.rowID) delta=\(String(format: "%.1f", delta)) offset=\(String(format: "%.1f", tableView.contentOffset.y))")
            #endif
            isAdjustingOffset = true
            var offset = tableView.contentOffset
            offset.y += delta
            let maxY = max(0, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
            offset.y = min(max(offset.y, 0), maxY)
            tableView.setContentOffset(offset, animated: false)
            isAdjustingOffset = false
        }

        private func freezeAnchorFromCurrentViewport(_ tableView: UITableView) {
            if let anchor = captureAnchor(tableView: tableView) {
                desiredAnchor = (anchor.rowID, anchor.screenY)
            }
        }

 // MARK: - 共享状态（自绘滚动条 / HUD / 探针）

 /// 重几何（convert/rectForRow）节流间隔：scrollViewDidScroll 每帧触发，
 /// convert×2 + rectForRow 在模拟器上叠加取证探针会造成明显掉帧
 /// （用户目击「滚动像 PPT」)；这些值只供 HUD/probe（0.1-0.2s
 /// 轮询）与收起校验使用，150ms 节流足够新鲜。
        private var lastHeavyGeometryAt: CFTimeInterval = 0

        private func updateSharedFacts() {
            guard let tableView else { return }
            let contentHeight = tableView.contentSize.height
            let viewportHeight = tableView.bounds.height
            let maxOffset = max(0, contentHeight - viewportHeight)
            let offset = tableView.contentOffset.y
 // 常规底座：offset 从内容顶部起算；距最新端 = 距底部距离。
            let facts = ScrollFacts(
                contentHeight: contentHeight,
                offset: max(0, offset),
                viewportHeight: viewportHeight,
                distanceFromBottom: max(0, maxOffset - offset),
                overscroll: max(0, offset - maxOffset),
                maxOffset: maxOffset
            )
 // DD-03：自绘指示条已删除，`facts` 的 @Published 只在 DEBUG HUD/探针轮询时
 // 按 30Hz（或位移 >4pt）写入；生产无观察者时不发布，避免每帧一次 SwiftUI 更新事务。
            let now = CACurrentMediaTime()
            if Self.debugFactsReaderEnabled,
               now - parent.shared.lastIndicatorPublishAt >= 1.0 / 30.0
                || !(abs(facts.offset - parent.shared.facts.offset) <= 4) {
                parent.shared.lastIndicatorPublishAt = now
                parent.shared.facts = facts
                parent.shared.factsCalls += 1
            }
            if abs(offset - lastTraceOffset) > 0.1 {
                parent.shared.lastActiveAt = now
            }
 // 帧级卡顿探针（DEBUG + DSHM_HITCHDBG=1；未开启时 no-op）：
 // 把逐帧滚动几何/列表规模喂给探针，与 mark 事件按时间对齐做卡顿归因。
            ScrollHitchProbe.feedGeometry(
                offset: facts.offset,
                contentHeight: facts.contentHeight,
                viewportHeight: facts.viewportHeight
            )
            ScrollHitchProbe.feedRows(
                displayed: displayedItems.count,
                total: parent.items.count,
                pinned: pinned
            )
 // 内容高度变化 = 行物化/收敛：记 contentSizeChange（滚动长帧归因）。
            let heightDelta = facts.contentHeight - lastFactsContentHeight
            if abs(heightDelta) > 0.5 {
                if abs(heightDelta) >= 2 {
                    ScrollHitchProbe.mark("contentSizeChange", [
                        "height": Double(facts.contentHeight).rounded(),
                        "delta": Double(heightDelta).rounded(),
                    ])
                }
                lastFactsContentHeight = facts.contentHeight
            }
            if now - lastHeavyGeometryAt > 0.15 {
                lastHeavyGeometryAt = now
                updateAnchorScreenY(tableView: tableView)
                parent.shared.viewportFrame = tableView.convert(tableView.bounds, to: nil)
            }
 // 冷启动/静止进入的 settle 置位：基线在每次几何回调里更新 hasSettledOnce
 // （distance<=2.5），UIKit 版若只在 scrollViewDidScroll 里更新，首帧没有
 // offset 变化时探针 `settledOnce` 恒 0 → SessionDetailScrollE2ETests 断言失败
 // （契约审计）。
            trackIdleBottomStability(tableView)
        }

 /// E2E 注入组头的屏幕绝对 Y（UIKit 真值直算）。DSHM_E2E_PROCGROUP=history
 /// 注入的主组 id 固定；生产会话中该 id 不存在，恒 -1（一次查找的开销）。
 /// 背景：AX frame 对「翻转 table cell 内 SwiftUI 内容」系统性损坏（
 /// 取证 12 采样 10 次 (0,0,0,0)），E2E 定位/点击必须走这条真值通道。
        private func updateAnchorScreenY(tableView: UITableView) {
            let anchorID = "process-e2e-hist-proc-0"
            guard let dataSource,
                  let indexPath = dataSource.indexPath(for: anchorID) else {
                parent.shared.anchorScreenY = -1
                return
            }
            let rect = tableView.rectForRow(at: indexPath)
 // convert 会应用翻转 transform：把行两端的布局点（减 offset 归到视口
 // 坐标）分别转换到 window，取 min/max 即行的视觉区域——无论翻转方向
 // 如何这都是渲染真值，避免手写翻转公式再出错。
            let pTop = tableView.convert(CGPoint(x: 0, y: rect.minY - tableView.contentOffset.y), to: nil).y
            let pBottom = tableView.convert(CGPoint(x: 0, y: rect.maxY - tableView.contentOffset.y), to: nil).y
            parent.shared.anchorScreenY = min(pTop, pBottom)
            parent.shared.anchorAltScreenY = max(pTop, pBottom)
            parent.shared.tableTopScreenY = tableView.convert(CGPoint.zero, to: nil).y
        }

        private func updateSharedWindow(items: [SessionMessageItem]) {
            parent.shared.displayedCount = displayedItems.count
            parent.shared.displayedItems = displayedItems
            parent.shared.windowStartSourceID = windowStartItemID ?? "-"
            if let first = displayedItems.first,
               let index = items.firstIndex(where: { $0.id == first.id }) {
                parent.shared.windowStartIndex = index
            } else {
                parent.shared.windowStartIndex = -1
            }
 // 最新已应用事件 seq（E2E 断言实时镜像单调递增）。
            var seq = -1
            for item in displayedItems.reversed() {
                switch item {
                case .group(.single(let row)):
                    seq = row.seq
                case .group(.process(let steps)):
                    if let s = steps.last?.seq, s > 0 { seq = s }
                    else if let s = steps.first?.seq, s > 0 { seq = s }
                case .fileChanges(let changes):
                    if let s = changes.seq { seq = s }
                case .liveText, .streamError, .actionError:
                    continue
                }
                if seq > 0 { break }
            }
            parent.shared.latestSeq = seq
        }

 // MARK: - 窗口扩展（向旧端 append 100 行，零滚动）

 /// 用户滚到窗口最旧端（数据尾部 = 布局远端）预留区时扩展显示窗口。
 /// 反转底座下扩展 = 数据源尾部 append：已有内容 content 坐标不变，
 /// 视口纹丝不动（无需锚点补偿）。
 /// 已执行过一次性全量窗口应用（见 scheduleFullRangeApply）。
        private var didFullRangeApply = false
 /// 一次性全量扩窗已排期（防重复排期；执行成功后由 didFullRangeApply 收口）。
        private var fullRangeApplyScheduled = false

 /// 首屏落定后一次性把窗口扩到已加载全量（延迟 0.6s 等初始收敛；动画中
 /// 顺延）。之后滚动期间零窗口扩展 apply；Markdown 预热也覆盖全量。
        private func scheduleFullRangeApply() {
            guard !didFullRangeApply, !fullRangeApplyScheduled else { return }
            fullRangeApplyScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.fullRangeApplyScheduled = false
                self.applyFullRangeWindowIfPossible()
            }
        }

 /// 一次性全量扩窗的**唯一执行点**（成功才置 `didFullRangeApply`）。
 ///
 /// 审查修复（P2）：原实现先把 `didFullRangeApply = true` 再判回填期，
 /// 回填期跳过 = **永久丢弃**（没有重排点）；补齐后用户滑动扩窗时，最多 100 个
 /// 新插入行会在 `heightForRowAt` 里同步建宿主（20-40ms/行 = 2-4s 卡顿）。
 /// 现在：回填期/动画期不执行也不置位；补齐结束后的下一次 apply（以及延迟定时器）
 /// 会再次尝试，真正执行后才置位。
        private func applyFullRangeWindowIfPossible() {
 // 动画结束 0.5s 收敛窗（与 apply 内 settleSkipAnchorApply 同口径）内不执行：
 // 全量扩窗一次在视口上方插入最多数百行，此窗内 apply 不做 offset 锚定修正
 // → 可见内容整块跳变。不执行也不置位，后续 apply 会再试。
            guard !didFullRangeApply, let tableView,
                  didInitialBottom, !heightAnimationActive,
                  CACurrentMediaTime() - lastAnimationEndAt >= 0.5,
                  !parent.isFillingHistory,
                  parent.items.count > displayedItems.count else { return }
            didFullRangeApply = true
            isExpandingWindow = true
 // DD-01: apply 在重入时会被延后一拍；让 `heightForRowAt` 的估算让路
 // 跟随到那次 apply 真正执行完（由 applyCore 的 defer 收口）。
            windowExpansionPendingApply = true
            windowStartItemID = parent.items.first?.id
            apply(items: parent.items, batchToken: parent.historyBatchToken)
            ScrollHitchProbe.mark("windowExpandFull", [
                "displayed": displayedItems.count,
                "total": parent.items.count,
            ])
 // 全量文本后台预解析（prewarm 自带去重/预算；分三片让长会话排满）。
            let all = parent.items
            let chunk = max(1, all.count / 3)
            var start = 0
            while start < all.count {
                MarkdownPrewarm.prewarm(items: Array(all[start..<min(all.count, start + chunk)]))
                start += chunk
            }
        }

        private func maybeExpandWindow() {
            ScrollHitchProbe.feedRows(
                displayed: displayedItems.count,
                total: parent.items.count,
                pinned: pinned
            )
 // 已是全量窗口：无需再扩（scheduleFullRangeApply 之后恒成立）。
            if displayedItems.count >= parent.items.count { return }
            guard !isExpandingWindow, didInitialBottom,
                  let tableView, dataSource != nil else { return }
 // 需求「不能因为用户滑动就停止加载」：**不按手势/惯性闸门**。
 // 旧 WIP 的 `!isTracking /!isDecelerating` 闸会让连续拖拽期间完全不扩窗
 // （松手后才一次扩 100 行 = 用户视角「滑的时候不加载」）。反转底座下扩窗是
 // 数据尾部 append：已有内容 content 坐标不变、零 offset 补偿，手势中执行也
 // 不推动视口；冷却（0.15s，DD-07）保留以防数据批振荡。
            guard !heightAnimationActive else { return }
            guard let oldest = displayedItems.first else { return }
 // 【回填期自动扩窗闸门 】初始内容较短时 contentOffset 天然落在
 // 顶部预留区，回填期每批数据都会触发「自动扩窗 → 整段历史塞进显示表 →
 // 逐行物化（20-40ms/行）」。回填期只放行**用户手势**触发的扩窗
 // （tracking/decelerating/userIsScrolling），保证「滑动即加载、逐段出现」；
 // 非手势的自动扩窗推迟到补齐结束（补齐后锚点保留，用户滑动时正常扩窗）。
            if parent.isFillingHistory,
               !tableView.isTracking, !tableView.isDecelerating, !userIsScrolling {
                return
            }
 // 常规底座：最旧端 = 内容顶部。offset 进入顶部预留区即向旧端扩窗
 // （数据头部插入 + 锚定伺服保持可见内容不动）。
            guard tableView.contentOffset.y <= MessageListWindowPolicy.expandMargin else { return }
            guard let currentStart = parent.items.firstIndex(where: { $0.id == oldest.id }) else { return }
            let newStart = MessageListWindowPolicy.expandedStartIndex(currentStart: currentStart, itemCount: parent.items.count)
            guard newStart < currentStart else { return }
 // 冷却：距上次扩展 < 0.15s 不扩（DD-07：原 0.8s 在快速上滑时会让预留区被
 // 追平；数据批持续到达时扩展/回落振荡仍由「动画结束 2s 内不扩」兜底）。
            let now = CACurrentMediaTime()
            guard now - lastWindowExpandAt > 0.15 else { return }
            guard now - lastAnimationEndAt > 2.0 else { return }
            lastWindowExpandAt = now
            isExpandingWindow = true
            windowExpansionPendingApply = true
            windowStartItemID = parent.items[newStart].id
            let expandStart = CACurrentMediaTime()
 // DD-01: 扩窗不再在滚动回调的同步栈里直接 apply（重入 diffable 数据源 =
 // 崩溃来源），交给 `requestApply` 合并并延后一拍；`isExpandingWindow`
 // 保持到这次延后 apply 真正执行完（heightForRowAt 的估算让路依赖它）。
            requestApply()
            parent.shared.prependCount += 1
            ScrollHitchProbe.mark("windowExpand", [
                "start": newStart,
                "displayed": displayedItems.count,
                "total": parent.items.count,
            ])
            #if DEBUG
            PerfProbe.shared.record(
                "windowExpand",
                ms: (CACurrentMediaTime() - expandStart) * 1000,
                ["displayed": displayedItems.count, "total": parent.items.count]
            )
            #endif
 // 向旧端扩展 = 马上要滚到的历史行：提前后台预解析这些文本行。
 // 延后 apply 生效前 `displayedItems` 还是旧窗口，直接按新窗口起点取。
            let prewarmEnd = min(parent.items.count, newStart + 120)
            MarkdownPrewarm.prewarm(items: Array(parent.items[newStart..<prewarmEnd]))
        }

 // MARK: - 步骤高度缓存 / 自动连续滚动

 /// 步骤高度缓存布局签名（宽度｜动态字号｜语言）：任一变化 ⇒ 行高会变 ⇒ 缓存失效。
 ///
 /// 每次布局都会调用（旋转/分屏），宽度未变时直接短路——滚动期 layoutPass
 /// 每帧触发，避免每帧拼签名串。
        private func prepareStepsHeightStore() {
            guard let tableView else { return }
            let width = tableView.bounds.width
            guard abs(width - stepsStoreWidth) > 0.5 else { return }
            stepsStoreWidth = width
            let roundedWidth = width.isFinite ? Int(width.rounded()) : 0
            let signature = "\(roundedWidth)|\(parent.stepsLayoutSignature)"
            groupStepsHeightStore.prepare(layoutSignature: signature)
        }

 /// 探针相位馈入：App 内自动连续滚动期间统一记 autoscroll，避免程序滚动
 /// 被记为 animating/idle 导致分析器把压测帧算成非滚动。
        private func feedProbePhase(_ phase: String) {
            ScrollHitchProbe.feedPhase(autoScrollTicker != nil ? "autoscroll" : phase)
        }

        #if DEBUG
 /// 以固定速度连续滚动（到达一端后反向），模拟用户「持续快速滑动」，
 /// 但不经过 XCUITest 手势合成 → 没有 XCTest 无障碍快照的主线程占用，
 /// 能测到 App 侧真实的掉帧/卡顿（场景 I：真机丝滑判定）。
        private func startAutoScrollIfNeeded() {
            guard ProcessInfo.processInfo.environment["DSHM_AUTOSCROLL"] == "1" else { return }
            guard autoScrollTicker == nil else { return }
            let speed = ProcessInfo.processInfo.environment["DSHM_AUTOSCROLL_SPEED"]
                .flatMap(Double.init) ?? 2600
            let ticker = GroupToggleTicker()
            autoScrollTicker = ticker
            lastAutoScrollTime = 0
            autoScrollTarget = -1
            autoScrollDirection = 1
            ScrollHitchProbe.feedPhase("autoscroll")
            ScrollHitchProbe.mark("autoscrollStart", ["speed": speed])
            ticker.start { [weak self] presentationTime in
                guard let self, let current = self.autoScrollTicker, current === ticker else { return }
                let now = presentationTime
                let last = self.lastAutoScrollTime
                self.lastAutoScrollTime = now
                guard last > 0, let tableView = self.tableView else { return }
                let dt = max(0, min(0.05, now - last))
 // inverted 底座：offset 0 = 视觉底部（最新），maxOffset = 最旧端。
                let maxOffset = max(0, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
                guard maxOffset > 1 else { return }
                var target = self.autoScrollTarget
                if target < 0 { target = tableView.contentOffset.y }
                target += self.autoScrollDirection * CGFloat(speed) * CGFloat(dt)
                if target >= maxOffset {
                    target = maxOffset
                    self.autoScrollDirection = -1
                    ScrollHitchProbe.mark("autoscrollFlip", ["dir": -1])
                } else if target <= 0 {
                    target = 0
                    self.autoScrollDirection = 1
                    ScrollHitchProbe.mark("autoscrollFlip", ["dir": 1])
                }
                self.autoScrollTarget = target
                self.isAdjustingOffset = true
                tableView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                self.isAdjustingOffset = false
                self.updateSharedFacts()
            }
        }
        #endif

 // MARK: - UIScrollViewDelegate

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            userIsScrolling = true
 // DD-05：交互态只在「未交互 → 交互」时切换一次；DD-02：手指开始拖动 → 详情页
 // 冻结尾部流式发布（数据仍在 journal 里）；同时记下滚动开始时的尾部文本快照（DD-09）。
            beginScrollInteractionIfNeeded()
            parent.shared.isDragging = true
            parent.shared.interactingUntil = CACurrentMediaTime() + 0.12
            parent.shared.panSeen = true
            parent.shared.panTrackingSeen = true
 // 每次手势起点清零逐帧位移统计与采样基线（基线口径；否则 HUD gm 会变成
 // 终身最大值，E2E「gm<150」会被历史快速手势污染）。
            parent.shared.gestureMaxFrameDelta = 0
            parent.shared.gestureFrameCount = 0
            lastTraceOffset = -1
            feedProbePhase("tracking")
            #if DEBUG
            ScrollJitterProbe.shared?.setPhase("tracking")
            #endif
            if !userHasScrolled {
                userHasScrolled = true
                parent.shared.userScrolled = true
                parent.onUserScrolled()
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            feedProbePhase(decelerate ? "decelerating" : "idle")
            #if DEBUG
            ScrollJitterProbe.shared?.setPhase(decelerate ? "decelerating" : "idle")
            #endif
            parent.shared.panDecelSeen = parent.shared.panDecelSeen || decelerate
            if decelerate {
                parent.shared.interactingUntil = CACurrentMediaTime() + 0.55
                return
            }
            parent.shared.isDragging = false
 // DD-02/DD-05: 不再惯性滚动 → 交互结束（惯性滚动由 didEndDecelerating 收尾）。
            endScrollInteraction()
            if let tableView = scrollView as? UILAnchoredTableView {
                userIsScrolling = false
                settleAfterGesture(tableView)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
 // DD-02/DD-05: 惯性滚动结束 → 交互结束。
            endScrollInteraction()
            userIsScrolling = false
            parent.shared.isDragging = false
            feedProbePhase("idle")
            #if DEBUG
            ScrollJitterProbe.shared?.setPhase("idle")
            #endif
            if let tableView = scrollView as? UILAnchoredTableView {
                settleAfterGesture(tableView)
            }
        }

 /// DD-02/DD-05/DD-09：滚动交互开始（仅首次通知 + 冻结尾部实时文本快照）。
        private func beginScrollInteractionIfNeeded() {
            guard !isScrollInteracting else { return }
            isScrollInteracting = true
            captureFrozenTailSnapshot()
            parent.onInteractionChange(true)
        }

 /// DD-02/DD-05：滚动交互结束。顺序：先让 ViewModel flush 尾部 live 值
 /// （`onInteractionChange(false)`），再对滚动期挂起的尾部 apply 收口一次（用
 /// `parent.items` 数据真相，不用冻结快照）；锚点恢复由 applyCore 统一处理。
        private func endScrollInteraction() {
            guard isScrollInteracting else { return }
            let hadFrozenTail = !frozenStepKinds.isEmpty || frozenLiveTextRow != nil
            isScrollInteracting = false
            frozenStepKinds.removeAll(keepingCapacity: true)
            frozenLiveTextRow = nil
            parent.onInteractionChange(false)
            if pendingTailApply != nil || hadFrozenTail {
                pendingTailApply = nil
                requestApply()
            }
        }

 /// 松手 settle：距最新端 <= 12pt（ScrollFollowPolicy.pinnedAfterGesture 同口径）
 /// 视为用户想贴底（repin），否则 unpin（读历史）。
        private func settleAfterGesture(_ tableView: UITableView) {
            let distance = max(0, bottomOffset(tableView) - tableView.contentOffset.y)
            ScrollHitchProbe.mark("settle", ["distance": Double(max(0, distance)).rounded()])
            let next = ScrollFollowPolicy.pinnedAfterGesture(distanceFromBottom: distance)
            if next != pinned {
                pinned = next
                parent.shared.pinned = next
                parent.onNearBottomChange(next)
            }
            if next {
                if distance.isFinite, distance > 0.5 {
 // 用户在最新附近松手：推到最新（完成用户意图，手势的收尾）。
                    snapToBottom(tableView, animated: false)
                    parent.shared.followCount += 1
                    parent.shared.lastScrollCommand = "settle"
                    ScrollHitchProbe.mark("scrollCmd", ["source": "settle"])
                }
                if pendingFrozenItems != nil {
                    pendingFrozenItems = nil
 // DD-01: 手势结束回调里同样延后合并（用最新数据真相，
 // 不用冻结快照，避免与同一拍内更新互相覆盖）。
                    requestApply()
                }
            }
            freezeAnchorFromCurrentViewport(tableView)
            stabilizeAfterLayout()
            updateSharedFacts()
            maybeExpandWindow()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let tableView = scrollView as? UITableView else { return }
 // 手势滚动相位：基线喂 tracking/interacting/decelerating/animating 四类，
 // 分析器按相位分类统计长帧（缺类会让帧被记成 idle）。
            if userIsScrolling {
                feedProbePhase(tableView.isTracking ? "interacting" : "decelerating")
 // DD-05：状态化交互回调——只在「未交互 → 交互」时通知一次，didEnd* 回调负责
 // 结束；不再每帧 cancel + 新建 Task（帧级堆分配）。
                if tableView.isTracking || tableView.isDecelerating {
                    beginScrollInteractionIfNeeded()
 // DD-05：续期 ViewModel 的交互 deadline（O(1)），避免手指按住不动超过
 // 兜底窗口（0.6s）时提前解冻尾部；按 0.2s 节流，不重建 Task。
                    let pingNow = CACurrentMediaTime()
                    if pingNow - lastInteractionPingAt > 0.2 {
                        lastInteractionPingAt = pingNow
                        parent.onInteractionChange(true)
                    }
                }
            }
            traceGestureOffset(tableView)
            trackIdleBottomStability(tableView)
            updateSharedFacts()
 // 回到底部区域 → 应用冻结的尾部内容（iMessage 语义：回到底部才出现）。
 // **展开/收起收敛窗口内不 repin**：行高暴增（巨型组 +1772）会让 offset
 // 瞬间逼近新底部，此处若 repin，贴底伺服会把刚展开的组头拉出视口
 // 。
            let distanceFromBottom = max(0, bottomOffset(tableView) - tableView.contentOffset.y)
            if pendingFrozenItems != nil,
               distanceFromBottom <= MessageListUpdatePolicy.nearBottomThreshold,
               CACurrentMediaTime() - lastAnimationEndAt > 1.2 {
                pendingFrozenItems = nil
                if !pinned {
                    pinned = true
                    parent.shared.pinned = true
                    parent.onNearBottomChange(true)
                }
 // DD-01: 滚动回调里不直接 apply（重入 diffable 数据源 = 崩溃来源），
 // 合并到下一拍执行。延后执行时用 `parent.items`（数据真相）而不是
 // 冻结时的快照，避免同一拍内更新被旧数据覆盖。
                requestApply()
            }
            maybeExpandWindow()
        }

 /// 手势窗口内的逐帧 offset 位移（HUD gm/gf 字段：1:1 跟手、无跳变帧）。
        private func traceGestureOffset(_ tableView: UITableView) {
            let offset = tableView.contentOffset.y
            defer { lastTraceOffset = offset }
            guard lastTraceOffset >= 0 else { return }
            let delta = offset - lastTraceOffset
            guard abs(delta) > 0.5 else { return }
            if userIsScrolling {
                parent.shared.gestureFrameCount += 1
                if abs(delta) > parent.shared.gestureMaxFrameDelta {
                    parent.shared.gestureMaxFrameDelta = abs(delta)
                }
            }
        }

 /// 空闲态稳定性取证：pinned 且无手势时，距最新距离不应变大。
        private func trackIdleBottomStability(_ tableView: UITableView) {
            guard pinned, didInitialBottom else { return }
            guard !userIsScrolling, !isAdjustingOffset,
                  !tableView.isTracking, !tableView.isDecelerating else { return }
            let distance = max(0, bottomOffset(tableView) - tableView.contentOffset.y)
            guard distance.isFinite else { return }
            if distance <= 2.5 { parent.shared.hasSettledOnce = true }
            guard parent.shared.hasSettledOnce else { return }
            if distance > parent.shared.maxIdleDistance { parent.shared.maxIdleDistance = distance }
            if distance > ScrollFollowPolicy.settlePinTolerance + 2 { parent.shared.idleDriftCount += 1 }
        }

 // MARK: - UITableViewDelegate

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            if let item = dataSource?.itemIdentifier(for: indexPath).flatMap({ self.item(for: $0) }) {
                ScrollHitchProbe.mark("rowAppear", [
                    "id": item.id,
                    "kind": item.rowKindForProbe,
                    "steps": item.stepCountForProbe,
                    "disp": displayedItems.count,
                ])
            }
            #if DEBUG
            if let id = dataSource?.itemIdentifier(for: indexPath), let cell = cell as? MessageCell {
                ScrollJitterProbe.shared?.register(rowID: id, view: cell)
            }
            #endif
        }

        func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            #if DEBUG
            if let id = dataSource?.itemIdentifier(for: indexPath) {
                ScrollJitterProbe.shared?.unregister(rowID: id)
            }
            #endif
        }
    }
}

#if DEBUG
/// 帧级探针的行标识（协议只在 DEBUG 存在，Release 构建不得引用）。
extension MessageTableRepresentable.MessageCell: JitterProbeIdentifiable {
    var jitterRowID: String { rowID }
}
#endif

/// UIKit Coordinator ↔ SwiftUI（HUD / e2e 探针）共享状态：
/// `facts` 只在 DEBUG HUD/探针需要时由 `updateSharedFacts` 写入（DD-03：自绘
/// 滚动条已删除）；其余字段为普通存储属性，不触发消息列表 body 重算。
final class UILListSharedModel: ObservableObject {
    @Published var facts = ScrollFacts(contentHeight: 0, offset: 0, viewportHeight: 0, distanceFromBottom: .greatestFiniteMagnitude, overscroll: 0, maxOffset: 0)
 /// 实例指纹（诊断：双实例分叉取证）。
    let uuid = UUID().uuidString.prefix(8)
 /// E2E 注入组头的屏幕绝对 Y（rectForRow+convert 直算；AX frame 在翻转
 /// cell 下系统性损坏，不能用）。生产会话无该注入组，恒 -1。
    var anchorScreenY: CGFloat = -1
 /// 注入组头行的视觉底端屏幕 Y（convert 真值；与 anchorScreenY 联用可判定
 /// SwiftUI 内容锚定在行的哪一端）。
    var anchorAltScreenY: CGFloat = -1
 /// tableView convert(.zero) 的屏幕 Y（翻转 transform 下 = 视口视觉底边）。
    var tableTopScreenY: CGFloat = -1
 /// 最近一次滚动活跃时刻（自绘滚动条淡出计时用）。
    var lastActiveAt: CFTimeInterval = 0
 /// facts 更新计数（指示条诊断用）。
    var factsCalls = 0
 /// 指示条 facts 更新节流（30Hz 或位移 >4pt；仅 DEBUG HUD/探针开启时写入）。
    var lastIndicatorPublishAt: CFTimeInterval = 0
 /// 显式窗口起点 id（nil = 默认窗口）：DEBUG 探针输出窗口真值，验证段读 AC-11。
    var windowStartSourceID = "-"

 // HUD / e2e-scroll-probe 字段（E2E 契约，键名不变）。
    var displayedItems: [SessionMessageItem] = []
    var displayedCount = 0
    var incomingCount = 0
    var windowStartIndex = -1
    var prependCount = 0
    var followCount = 0
    var latestSeq = -1
    var pinned = true
    var isContentReady = false
    var viewportFrame: CGRect = .null
    var isDragging = false
    var interactingUntil: CFTimeInterval = 0
    var panSeen = false
    var panTrackingSeen = false
    var panDecelSeen = false
    var userScrolled = false
    var gestureMaxFrameDelta: CGFloat = 0
    var gestureFrameCount = 0
    var hasSettledOnce = false
    var maxIdleDistance: CGFloat = 0
    var idleDriftCount = 0
    var lastScrollCommand = "-"
}

// MARK: - 待测量队列（v6.2 冻结修复， 真机 P0）

/// 行高**闲置预测量**的有界去重队列。
///
/// 背景：旧实现用一个裸 `[String]` 累积待测量行，
/// 每次 `apply()`（SwiftUI updateUIView 触发，流式会话下 10-25Hz）把窗口内所有
/// 「未测量」行**重复追加**；而排空器只在静止时以 1 行/16ms 消化（~60 行/秒）。
/// 流式大会话里未测量行持续再生 → 队列以每秒上千条膨胀 → 重排比较器对每次比较
/// 做两次 `displayedItems.firstIndex`（O(n)）并现算行 id（组 id 需拷贝
/// ProcessStep/JSONValue 负载）→ 单次排序可达数十秒，主线程 92% 占空比连续
/// 97 秒（系统 CPU Resource 报告 DSHm.cpu_resource--235141：栈为
/// SwiftUI 布局 → Coordinator.apply → queueUnmeasuredRowsForIdleMeasure →
/// prioritizePendingMeasureByProximity → FlowRowGroup.id / JSONValue 拷贝），
/// 用户表现为「无法滚动、动效卡死」。
///
/// 修复：成员 `Set` 去重 + 封顶 `cap` + 重排（见 `MeasureProximityPolicy`）
/// 改为 O(m log m) 排序 + O(1) 位置查表。
struct PendingMeasureQueue {
    private(set) var ids: [String] = []
    private var members: Set<String> = []
    let cap: Int

    init(cap: Int = 512) {
        self.cap = max(1, cap)
    }

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

 /// 追加待测量行 id（去重 + 封顶）。返回是否真的入队了新行。
    @discardableResult
    mutating func enqueue(_ newIDs: [String]) -> Bool {
        var queued = false
        for id in newIDs where !members.contains(id) {
            guard ids.count < cap else { break }
            members.insert(id)
            ids.append(id)
            queued = true
        }
        return queued
    }

 /// 按给定顺序重排（成员集合不变，仅调整排空优先级）。
    mutating func reorder(_ ordered: [String]) {
        guard ordered.count == ids.count, Set(ordered) == members else { return }
        ids = ordered
    }

    mutating func removeFirst() -> String? {
        guard !ids.isEmpty else { return nil }
        let id = ids.removeFirst()
        members.remove(id)
        return id
    }

    mutating func removeAll() {
        ids.removeAll(keepingCapacity: false)
        members.removeAll(keepingCapacity: false)
    }
}

/// 待测量队列的就近排序（纯逻辑，可单测）：按「距视口锚点行」由近到远。
///
/// 旧实现把位置查找塞进 `sorted(by:)` 比较器（每比较 O(n) 线性扫描 + 现算 id），
/// 与队列长度相乘即主线程爆炸源。这里要求调用方先一次 O(n) 构建位置表，
/// 比较器只做字典查表。
enum MeasureProximityPolicy {
    static func ordered(_ ids: [String], positions: [String: Int], anchor: Int) -> [String] {
        guard ids.count > 1 else { return ids }
        return ids.sorted { a, b in
            let da = positions[a].map { abs($0 - anchor) } ?? Int.max
            let db = positions[b].map { abs($0 - anchor) } ?? Int.max
            return da < db
        }
    }
}
