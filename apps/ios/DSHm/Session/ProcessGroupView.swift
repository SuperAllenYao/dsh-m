import SwiftUI

/// 内联「模型工作步骤」块（v6：平铺 + 大折叠 + 实时行，对齐 DSH 桌面端）：
/// - 默认 `.expanded`（运行中与已结束都全量平铺）；点组头收起 → `.collapsed`（只留组头），
/// 再点展开恢复（v7 task-9：组头只留 chevron，视觉不显示「展开/收起」文案）；
/// - 组头桌面式：▣ N 步 + 运行中 ●/已完成 + chevron（不写分类计数摘要）；
/// - 运行中组内可出现实时行：实时思考（3 行 + 渐隐，点开 190pt 内滚）与工具准备行；
/// - 旧 `.window`（固定高度窗口）/`.full`（无高度限制）保留但不再默认；
/// - v7 步骤块统一：组内步骤 = 思考 / 工具 + 子代理消息 / 子代理结算 / 工作目录
/// （桌面端混排形态），**单步也成组**——孤立思考块不再走独立行渲染，组头/chevron/
/// 手势热区/收起动画锚定与多步组完全一致。
///
/// 渲染要点：
/// 1. 全量模式用同步 `VStack`：自撑高 cell 里 `LazyVStack` 没有视口，只实体化末尾几条
/// （用户报障截图：展开 10 步只看到 3 步 + 大块空白）。
/// 2. 显示态由页面持有（`mode` + `onToggleMode`），cell reconfigure/复用时不会丢。
/// 3. 工具/思考详情弹层回调到页面级 `SessionDetailSheet`，cell 重建不丢弹层。
struct ProcessGroupView: View {
    var steps: [ProcessStep]
    var isRunning: Bool
    var pendingApprovalCallIds: Set<String> = []
    var mode: ProcessGroupMode = .expanded
 /// 行高测量标识（= FlowRowGroup.id）：折叠态也上报「展开后步骤内容高度」，
 /// 供消息列表在点击瞬间预测行高变化量 Δ，用逐帧驱动把 contentOffset 反向
 /// 移动 Δ，从而把组头钉住（inverted 列表：行高 ±Δ ⇒ 组头屏幕位置 ∓Δ）。
    var measurementID: String = ""
 /// 展开/收起动画中的「步骤内容高度」覆盖（nil = 自然高度）。
 /// 列表的手驱动动画逐帧写入它，并与 contentOffset 在**同一次状态提交**里更新，
 /// 保证组头逐帧定住（不依赖 SwiftUI 隐式动画与滚动动画的时间对齐）。
    var animatedStepsHeight: CGFloat? = nil
 /// 「展开后步骤内容高度」缓存命中值（列表侧 GroupStepsHeightStore 提供）。
 /// 命中（组内容签名 + 布局签名都一致）时不再渲染隐藏测量副本——折叠组每行的
 /// N 个步骤因此不参与布局，滚动期行物化成本减半；未命中仍按原路径测一次并回写。
    var cachedStepsHeight: CGFloat? = nil
 /// 步骤内容签名（缓存校验用）：步骤数/首尾 step id/实时行文本变化都会改变它。
    var measurementSignature: String = ""
 /// `.window` 模式的固定高度（≈会话可视高度 1/3，由页面计算后传入）。
    var windowHeight: CGFloat = 300
    var onToggleMode: (() -> Void)? = nil
    var onOpenTool: ((ToolCallItem) -> Void)? = nil
    var onOpenReasoning: ((String) -> Void)? = nil
 /// v7：子代理会话 label（child session id → catalog label），子代理消息步骤行展示用。
    var subagentLabels: [String: String] = [:]
 /// v7：点击「子代理消息」步骤行 → 打开该子代理会话（nil = 该行不提供可点手势）。
    var onOpenRelay: ((RelayCard) -> Void)? = nil

 /// Reduce Motion：关掉高度动画，配合列表的瞬时补偿（终态与动效一致、无过渡抖动）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
 /// 巨型组展开态当前已渲染的步骤数（首屏限量；点「展开其余」按 chunk 追加）。
 /// v7.1：外部真值优先——UIKit 后端的 cell 会被复用/重建，
 /// @State 会丢（「展开其余」后滚走再滚回，步数回落 60）。列表容器持有
 /// 字典真值传入；SwiftUI 回退后端行身份稳定，传 nil 用内部 @State。
    var revealedStepsOverride: Int? = nil
 /// 已渲染步数变化时上报（UIKit 容器写字典 + 触发行重建）。
    var onRevealStepsChange: ((Int) -> Void)? = nil
    @State private var revealedStepState: Int = ProcessGroupStepsLayoutPolicy.initialSteps
 /// 巨型组追加步骤后，行高增加了多少（列表据此同帧补偿 offset，组头钉住）。
    var onStepsHeightDelta: ((CGFloat) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
 // 步骤按事件顺序整体分组（失败/待审批步骤也在序列里，见 v0.2.7 用户口径）：
 // v6 默认平铺展开；折叠态只留组头一行。
 // v7：**单步也成组**（组内 1 步同样渲染组头）——用户问题 4 要求孤立思考块
 // 的点击展开/折叠、手势热区、动画锚定、chevron 语义与步骤块完全一致；
 // 旧的单步内联分支（process-single-row）会让组内思考行走独立单行渲染。
            if !steps.isEmpty {
                container {
                    headerRow
                    Group {
                        switch mode {
                        case .window:
                            stepsWindow
                        case .full, .expanded:
 // 巨型组降载：子会话存在 291/243/98 步
 // 的过程组，旧实现一帧内同步布局整组 → 几百 ms 主线程长任务，
 // 快速滑动必卡死。策略见 ProcessGroupStepsLayoutPolicy
 // （默认.full 保持现状，待设计决策后切换默认/通过 env 取证）。
                            if giantStepsRendersWindow {
                                stepsWindow
                            } else if isGiantGroup {
 // 巨型组展开态（设计决策）：首屏只渲染 initialSteps 步 +
 // 「展开其余 N 步」按钮；组头下方逐次追加，不做逐帧动画。
                                stepsGiantExpanded
                            } else {
                                stepsInline
 // 展开态：可见内容自报高度（点击收起的预测 Δ 来源）。
 // 缓存已命中时跳过这个 GeometryReader（少一条每布局
 // 都传播的尺寸测量链，滚动期行物化更便宜）。
                                    .background {
                                        if cachedStepsHeight == nil {
                                            stepsHeightReader
                                        }
                                    }
 // 手驱动动画的高度覆盖（nil = 自然高度）；顶部对齐 +
 // 裁掉溢出 = 步骤从组头下方长入/收回（inverted 布局里
 // 行内 top = 视觉顶边 = 组头所在边）。
                                    .frame(height: animatedStepsHeight, alignment: .top)
                                    .clipped()
                            }
                        case .collapsed:
                            EmptyView()
                        }
                    }
                    .clipped()
 // 用户口径：展开/收起 150ms ease-in-out 非线性动画，
 // 向下展开、向上收起；row 高度与 contentOffset 同步由列表在同一
 // 动画事务内完成（见 SessionMessageListView.handleGroupModeToggle）。
 // Reduce Motion：取消高度过渡，避免「高度动画 + 瞬时补偿」错拍。
 // 手驱动动画期间禁用隐式动画（高度由列表逐帧驱动，避免双重动画）。
                    .animation(reduceMotion || animatedStepsHeight != nil ? nil : .easeInOut(duration: 0.15),
                               value: mode)
                }
 // 折叠态**不再渲染隐藏测量副本**：
 // 步骤行是固定行高（28pt + 1pt hairline），展开高度由
 // FlowRowGroup.estimatedStepsHeight 公式给出；精确值由展开态
 // reader 测一次回写 GroupStepsHeightStore 缓存（内容签名校验）。
 // 旧实现为每个折叠组再渲染一遍全部步骤行，29x 步的组等于双倍布局。
            }
        }
    }

 // MARK: - Header（整行可点：expanded⇄collapsed 大折叠；旧 window⇄full 保留）

    private var headerRow: some View {
        Button {
            onToggleMode?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cube")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 14)
 // 用户口径：组头不出现「过程」二字。
                Text(L10n.f("%lld 步", steps.count))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                if isRunning {
                    HStack(spacing: 4) {
                        Text(L10n.t("运行中"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.accent)
                        StatusDot(color: Theme.Palette.accent, size: 6, pulsing: true)
                    }
                    .fixedSize()
                } else {
 // v6 桌面式组头：不写分类计数摘要，只表达运行/完成。
                    Text(L10n.t("已完成"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                toggleGlyph
            }
            .padding(.horizontal, Theme.Spacing.s)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("process-group-row")
 // E2E：组头暴露当前显示态（window/full/collapsed/expanded），
 // 供真机断言四态切换（AX 容器 id 在 SwiftUI 下不可靠）。
        .accessibilityValue("mode:\(mode.rawValue)")
 // 探针（v5）：组头**全局** frame 逐帧上报——表格几何探针
 // （off/rowMinY，presentation 层）已证明稳定，用户可见的漂移若存在
 // 只能发生在 cell 内部 SwiftUI 内容；组头全局 Y 是内容滑动的直接证据。
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            ProcessToggleProbe.shared?.headerFrame(id: measurementID, frame)
        }
        #endif
    }

 /// v7 task-9 桌面式切换件：只留 chevron（视觉不再显示「展开 / 收起」文案），
 /// 朝向仍表达折叠态（折叠 ⌄ / 展开 ⌃）；文案退到无障碍标签，点击热区仍是整行组头。
    @ViewBuilder
    private var toggleGlyph: some View {
        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.Palette.textTertiary)
            .animation(.easeInOut(duration: 0.1), value: mode)
            .accessibilityLabel(isCollapsed ? L10n.t("展开") : L10n.t("收起"))
            .accessibilityIdentifier("process-group-toggle")
    }

 /// 是否折叠态（决定 chevron 朝向；「展开/收起」文案只在 a11y 标签里，视觉不显示）。
    private var isCollapsed: Bool {
        mode == .collapsed
    }

 // MARK: - 步骤列表

 /// 运行中：固定高度窗口，**只展示最近 N 步**（N = 窗口高度 / 28pt 行高）。
 ///
 /// v0.2.7 真机回归（用户报障「屏幕根本没办法上下滑动」）：
 /// 之前这里放了一个嵌套 ScrollView，它嵌在「自撑高 UIHostingConfiguration cell +
 /// 反转（scaleY(-1)）列表」里会抢走纵向 pan 手势，导致整页消息列表滑不动。
 /// 现在窗口**不做嵌套滚动**：只渲染最近 N 步、底部对齐、新步骤到达时整体上移
 /// （animation 过渡），手势全部留给外层消息列表；要看全部步骤点右上「全高」图标。
    private var stepsWindow: some View {
        VStack(spacing: 0) {
            ForEach(windowSteps) { step in
                if step.isLive {
                    stepRow(step)
                } else {
                    if !showsLiveHighlight(step) { hairline(inset: 34) }
                    stepRow(step)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("process-step-row")
                }
            }
        }
        .frame(height: resolvedWindowHeight, alignment: .bottom)
        .clipped()
        .animation(Theme.Motion.quick, value: steps.count)
        .accessibilityIdentifier("process-steps-window")
    }

 /// 固定窗口内展示的「最近 N 步」（尾部切片，随新步骤上移）。
    private var windowSteps: [ProcessStep] {
 // 整行吸附（向下取整）：窗口只展示完整行，高度 = 行数 × 29 ≤ 设计窗口高，
 // 不会出现半行/底部空白（大屏 1/3 屏 318.7pt 实测 → 10 行 = 290pt，仍在 280–360 区间）。
        let capacity = max(1, Int(windowHeight / Self.stepRowHeight))
        return Array(steps.suffix(capacity))
    }

 /// 窗口实际高度：内容不足一屏 1/3 时按内容收紧（用户口径：不允许一大片空白），
 /// 最多不超过设计高度（≈会话可视高 1/3，页面传入 clamp 280–360pt）。
    private var resolvedWindowHeight: CGFloat {
        min(windowHeight, CGFloat(windowSteps.count) * Self.stepRowHeight)
    }

 /// 单步行高（28pt 行 + 1pt hairline），与 windowSteps 的容量计算保持一致。
    private static let stepRowHeight: CGFloat = 29

 /// 全量内联（v6 默认态：运行中与已结束都平铺）：同步 VStack。
    private var stepsInline: some View {
        VStack(spacing: 0) {
            ForEach(steps) { step in
                if step.isLive {
 // v6 实时行自带 accent 细边 + 淡色底，作为组内一行（不套普通 hairline）。
                    stepRow(step)
                } else {
 // v7 task-9：运行中的工具行也自带 accent 顶边 + 浅蓝底，同上不叠 hairline。
                    if !showsLiveHighlight(step) { hairline(inset: 34) }
                    stepRow(step)
 // 每行一个显式 AX 元素：容器 VStack 不是独立 AX 节点，
 // 标识会污染子行，E2E 无法按容器统计行数。
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("process-step-row")
                }
            }
        }
        .accessibilityIdentifier("process-steps-full")
    }

 // MARK: - 巨型组降载策略

 /// 该组是否按巨型组处理（策略.full 下恒为 false = 旧行为）。
    private var isGiantGroup: Bool {
        ProcessGroupStepsLayoutPolicy.isGiant(steps.count)
    }

 /// 策略.window（实验）：巨型组展开态用既有固定高度窗口展示（行高有界）。
    private var giantStepsRendersWindow: Bool {
        ProcessGroupStepsLayoutPolicy.giantUsesWindow(steps.count)
    }

 /// 巨型组展开态：首屏只同步布局 initialSteps 步（单帧成本有界），其余通过
 /// 「展开其余 N 步」按钮追加（设计决策：不做逐帧高度动画，点一次追加一批）。
    private var stepsGiantExpanded: some View {
        VStack(spacing: 0) {
            ForEach(Array(steps.prefix(renderedStepCount))) { step in
                if step.isLive {
                    stepRow(step)
                } else {
                    if !showsLiveHighlight(step) { hairline(inset: 34) }
                    stepRow(step)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("process-step-row")
                }
            }
            if renderedStepCount < steps.count {
                revealMoreButton
            }
        }
 // 始终上报当前可见高度（不是整组高度）：巨型组折叠 Δ 要靠它保持组头钉住。
        .background(stepsHeightReader)
        .frame(height: animatedStepsHeight, alignment: .top)
        .clipped()
        .accessibilityIdentifier("process-steps-full")
 // E2E 取证（DEBUG + DSHM_HITCHDBG=1）：已渲染步数/总步数，断言限量渲染生效。
        .overlay(alignment: .topLeading) {
            if ProcessGroupStepsLayoutPolicy.probeAXEnabled {
                Text("giant")
                    .font(.system(size: 1))
                    .frame(width: 2, height: 2)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("process-giant-rendered")
                    .accessibilityValue("(renderedStepCount)/(steps.count)")
            }
        }
        .onAppear { clampRevealedStepCount() }
        .onChange(of: mode) { _, newMode in
            if newMode == .collapsed {
 // 重新展开时回到首屏限量（确定性的行高，列表 offset 补偿才可预测）。
                revealedStepCount = ProcessGroupStepsLayoutPolicy.initialSteps
            }
            clampRevealedStepCount()
        }
        .onChange(of: steps.count) { _, _ in clampRevealedStepCount() }
    }

 /// 设计决策：巨型组展开后按按钮继续追加（一次一批，避免二次卡顿）。
    private var revealMoreButton: some View {
        Button {
            revealMoreGiantSteps()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.f("展开其余 %lld 步", steps.count - renderedStepCount))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: ProcessGroupStepsLayoutPolicy.revealRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("process-steps-reveal-more")
    }

 /// 读写入口：外部真值（UIKit 容器字典）优先，否则内部 @State（SwiftUI 后端）。
    private var revealedStepCount: Int {
        get { revealedStepsOverride ?? revealedStepState }
        nonmutating set {
            revealedStepState = newValue
            onRevealStepsChange?(newValue)
        }
    }

    private var renderedStepCount: Int {
        min(max(0, revealedStepCount), steps.count)
    }

    private func clampRevealedStepCount() {
        if revealedStepCount < ProcessGroupStepsLayoutPolicy.initialSteps {
            revealedStepCount = ProcessGroupStepsLayoutPolicy.initialSteps
        }
        if revealedStepCount > steps.count {
            revealedStepCount = steps.count
        }
    }

 /// 追加一批步骤：先按公式算出行高增量，交给列表同帧补偿 offset（组头钉住）。
    private func revealMoreGiantSteps() {
        NSLog("[GAPP] reveal tap: rendered=%d total=%d", renderedStepCount, steps.count)
        let before = renderedStepsHeight(renderedStepCount)
        let next = min(
            steps.count,
            renderedStepCount + ProcessGroupStepsLayoutPolicy.revealChunk
        )
        guard next > renderedStepCount else { return }
 // v5：UIKit 容器下**不写 @State**——同步重渲染
 // 会在动画开始前把新一批内容一次性铺上屏（tap 帧整屏瞬跳 +135px/10.7%
 // 像素、随后的 300ms 动画零像素变化）。真值切换交给容器：写字典 → 下一
 // runloop 重建宿主（钉旧行高、ticker 裁剪窗口逐帧揭示）。
 // SwiftUI 回退后端（无容器字典，override == nil）保留 @State 直写。
        if revealedStepsOverride == nil {
            revealedStepCount = next
        } else {
            onRevealStepsChange?(next)
        }
        let after = renderedStepsHeight(next)
        onStepsHeightDelta?(after - before)
    }

 /// 已渲染步骤内容的高度（与 FlowRowGroup.estimatedStepsHeight 同口径；
 /// 有「展开其余」按钮时把按钮行也算进去，保证折叠 Δ 准确）。
    private func renderedStepsHeight(_ count: Int) -> CGFloat {
        let capped = min(max(0, count), steps.count)
        var height: CGFloat = 0
        for step in steps.prefix(capped) {
            height += 28
            if !(step.isLive || showsLiveHighlight(step)) { height += 1 }
        }
        if capped < steps.count {
            height += ProcessGroupStepsLayoutPolicy.revealRowHeight
        }
        return height
    }

    private func stepRow(_ step: ProcessStep) -> some View {
        ProcessStepRow(
            step: step,
            pendingApprovalCallIds: pendingApprovalCallIds,
            onOpenTool: onOpenTool,
            onOpenReasoning: onOpenReasoning,
            subagentLabels: subagentLabels,
            onOpenRelay: onOpenRelay
        )
    }

 /// 该步骤行是否自带浅蓝底（运行中的工具行）。
 /// 自带底的行不再叠加分隔 hairline：否则灰线 + accent 顶边会叠成两道线，
 /// 与实时思考行（无 hairline、只有 accent 顶边）不一致。
    private func showsLiveHighlight(_ step: ProcessStep) -> Bool {
        guard let tool = step.tool else { return false }
        let pending = tool.callId.map { pendingApprovalCallIds.contains($0) } ?? false
        return StepStatusTone.resolve(item: tool, pendingApproval: pending) == .running
    }

 // MARK: - 行高测量（滚动锚定补偿用）

 /// 步骤内容（不含组头）的自然高度上报：measurementID -> (内容签名, height)。
 /// 展开态量可见内容，折叠态量隐藏副本——列表点击组头时据此预测行高 Δ，
 /// 并按内容签名缓存，避免折叠期间内容变化后命中过期高度。
    private var stepsHeightReader: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ProcessGroupStepsHeightKey.self,
                value: [
                    measurementID: ProcessGroupStepsHeight(
                        signature: measurementSignature,
                        height: max(0, geo.size.height)
                    ),
                ]
            )
        }
    }

    @ViewBuilder
    private func container<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
 // v6：组内实时行自带底色，裁圆角避免方角溢出卡片。
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )
    }

    private func hairline(inset: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.Palette.border)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// 单条过程步骤行（28pt）：工具调用或思考摘要。
/// 供折叠过程组与后续面板复用同一套行渲染。
struct ProcessStepRow: View {
    var step: ProcessStep
    var pendingApprovalCallIds: Set<String> = []
    var onOpenTool: ((ToolCallItem) -> Void)? = nil
    var onOpenReasoning: ((String) -> Void)? = nil
 /// v7：子代理会话 label（child session id → catalog label）。
    var subagentLabels: [String: String] = [:]
 /// v7：子代理消息行点击 → 打开子代理会话（nil = 该行不可点）。
    var onOpenRelay: ((RelayCard) -> Void)? = nil

    var body: some View {
 // v6：运行中实时步骤（实时思考 / 工具准备行）优先于历史步骤行渲染。
        if step.isLive, let text = step.reasoningText, !text.isEmpty {
            LiveReasoningStepRow(text: text, onOpenReasoning: onOpenReasoning)
        } else if step.isPreparing {
            PreparingStepRow(step: step)
        } else if let tool = step.tool {
            ToolCallCompactRow(
                item: tool,
                pendingApproval: tool.callId.map { pendingApprovalCallIds.contains($0) } ?? false
            ) {
                onOpenTool?(tool)
            }
        } else if let card = step.relayCard {
 // v7：子代理消息混在步骤里（桌面端形态）；点击直接打开该子代理会话。
            SubagentMessageStepRow(
                card: card,
                label: card.senderSessionId.flatMap { subagentLabels[$0] },
                onOpen: onOpenRelay
            )
        } else if let text = step.subagentSettledText {
 // v7：子代理结算混在步骤里，纯展示（不做可点手势，避免假交互）。
            SubagentSettledStepRow(text: text)
        } else if let change = step.workingDirectoryChange {
 // v7：工作目录变更混在步骤里，纯展示。
            WorkingDirectoryStepRow(change: change)
        } else if let text = step.reasoningText {
            Button {
                onOpenReasoning?(text)
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 14)
                    Text("思考")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: 64, alignment: .leading)
                    Text(text.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .padding(.horizontal, Theme.Spacing.s)
                .frame(height: 20)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("process-reasoning-row")
        }
    }
}

// MARK: - v7 混在步骤块里的桌面端步骤行（子代理消息 / 子代理结算 / 工作目录）

/// v7 子代理消息步骤行（组内 28pt 紧凑行）：
/// person.2 + 「子代理消息」+ 子代理 label/短 id + 正文首行预览 + chevron。
/// 点击打开该子代理会话（v7 口径：桌面端混在步骤里、点了就进子会话）。
struct SubagentMessageStepRow: View {
    var card: RelayCard
 /// `subagentCatalog` label（nil 时退回 sender id 前 8 位）。
    var label: String? = nil
 /// nil = 该行不提供可点手势（页面尚未接线时，避免「点了没反应」）。
    var onOpen: ((RelayCard) -> Void)? = nil

    private var senderLabel: String {
        if let label, !label.isEmpty { return label }
        if let sender = card.senderSessionId, !sender.isEmpty { return String(sender.prefix(8)) }
        return ""
    }

    private var preview: String {
        if let summary = card.summary, !summary.isEmpty { return StepRowPreview.singleLine(summary) }
        return StepRowPreview.singleLine(card.text)
    }

    var body: some View {
        if let onOpen {
            Button {
                onOpen(card)
            } label: {
                row
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("process-subagent-message-row")
        } else {
            row
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("process-subagent-message-row")
        }
    }

    private var row: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "person.2")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 14)
            Text(L10n.t("子代理消息"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 64, alignment: .leading)
            if !senderLabel.isEmpty {
                Text(senderLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(preview)
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(.horizontal, Theme.Spacing.s)
        .frame(height: 20)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// v7 子代理结算步骤行（组内 28pt 紧凑行，纯展示）：盖章图标 +「子代理结算」+ 摘要首行。
struct SubagentSettledStepRow: View {
    var text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 14)
            Text(L10n.t("子代理结算"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 64, alignment: .leading)
            Text(StepRowPreview.singleLine(text))
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.s)
        .frame(height: 20)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("process-subagent-settled-row")
    }
}

/// v7 工作目录变更步骤行（组内 28pt 紧凑行，纯展示）：文件夹 +「工作目录」+ 新路径
/// （从 Host 正文里解析出的最后一个引号路径；解析失败退回原文首行）。
struct WorkingDirectoryStepRow: View {
    var change: WorkingDirectoryChange

    private var pathText: String {
        if let cwd = change.cwd, !cwd.isEmpty { return cwd }
        return StepRowPreview.singleLine(change.text)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "folder")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 14)
            Text(L10n.t("工作目录"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 64, alignment: .leading)
            Text(pathText)
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.s)
        .frame(height: 20)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("process-working-directory-row")
    }
}

/// 组内步骤行的单行预览：换行压平（行高固定 28pt，多行会被裁切）。
enum StepRowPreview {
    static func singleLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// v6 运行中实时思考行（组内平铺，不是独立卡片）：
/// 头部 34pt「✦ 思考 + 实时（6pt 脉冲点）+ 点击展开/收起」，正文 12.5pt/20pt 最多 3 行
/// （60pt）+ 底部渐隐；点行内联展开（限高 190pt + 内部滚动），再点收起；
/// 行尾 chevron 调 `onOpenReasoning` 打开现有全文弹层。
struct LiveReasoningStepRow: View {
    var text: String
    var onOpenReasoning: ((String) -> Void)? = nil

    @State private var expanded = false

 /// 折叠态底部渐隐：从透明渐变到卡片底色（覆盖第 2.5–3 行文字）。
    private var collapsedFade: LinearGradient {
        LinearGradient(
            colors: [Theme.Palette.surface.opacity(0), Theme.Palette.surface],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(Theme.Motion.quick) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(width: 14)
                        Text(L10n.t("思考"))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.Palette.accent)
                            .lineLimit(1)
                            .fixedSize()
                        HStack(spacing: 4) {
                            StatusDot(color: Theme.Palette.accent, size: 6, pulsing: true)
                            Text(L10n.t("实时"))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Palette.accent)
                        }
                        .fixedSize()
                        Spacer(minLength: 4)
                        Text(expanded ? L10n.t("点击收起") : L10n.t("点击展开"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .padding(.leading, Theme.Spacing.s)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    onOpenReasoning?(text)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(width: 28, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("查看思考全文"))
            }

            if expanded {
                ScrollView(.vertical) {
                    Text(text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 190)
                .scrollBounceBehavior(.basedOnSize)
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.bottom, 8)
            } else {
                ZStack(alignment: .bottom) {
                    Text(text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineSpacing(5)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    collapsedFade
                        .frame(height: 34)
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.bottom, 8)
            }
        }
 // 浅蓝底样式抽成共用 modifier（v7 task-9）：运行中的普通步骤行用同一份 token/透明度。
        .liveStepHighlight()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("process-live-reasoning-row")
    }
}

/// v6 工具准备行（28pt，参数流式阶段）：旋转环 + 「准备运行命令…」 + mono arguments
/// 预览（截断） + 行尾「准备中」。派发（tool/call）后由真实工具行替换。
struct PreparingStepRow: View {
    var step: ProcessStep

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            PreparingSpinner()
            Text(L10n.t(step.verb) + "…")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.accent)
                .lineLimit(1)
                .fixedSize()
            Text(step.preparingArgs ?? "")
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.t("准备中"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.accent)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, Theme.Spacing.s)
        .frame(height: 28)
 // 与实时思考行 / 运行中步骤行同一份浅蓝底 + 顶部 accent 细边。
        .liveStepHighlight()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("process-preparing-row")
    }
}

/// 8pt 旋转环（accent，带缺口）：工具准备行的「准备中」指示。Reduce Motion 时静止。
struct PreparingSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(Theme.Palette.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(
                reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false),
                value: spinning
            )
            .onAppear { spinning = true }
            .accessibilityHidden(true)
    }
}


/// 思考全文弹层（页面级 `SessionDetailSheet.reasoning` 复用）。
struct ReasoningDetailSheet: View {
    var text: String

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L10n.t("思考"))
            Rectangle().fill(Theme.Palette.border).frame(height: 1)
            ScrollView {
 // 桌面端思考内容同样走 Markdown（ReasoningContent → MarkdownText）；
 // 这里用 compact 字号档，代码块/列表/标题与桌面端一致。
                MarkdownDocumentView(
                    text: text,
                    color: Theme.Palette.textSecondary,
                    variant: .compact
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.m)
                .measureSheetContentHeight()
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// 过程组「步骤内容高度」测量（key = FlowRowGroup.id，值 = 步骤内容自然高度）。
///
/// 滚动锚定补偿的唯一输入：inverted 列表里组行高度变化 Δ 会让组头屏幕位置
/// 反向漂移 Δ，列表在点击瞬间用该值预测 Δ，逐帧把「步骤内容高度 override」与
/// contentOffset 同一次提交（高度 ±δ 与 offset ∓δ 严格配平），组头逐帧定住；
/// 折叠态由隐藏副本持续上报，保证「展开」方向也能预知目标高度。
struct ProcessGroupStepsHeightKey: PreferenceKey {
    static var defaultValue: [String: ProcessGroupStepsHeight] = [:]
    static func reduce(
        value: inout [String: ProcessGroupStepsHeight],
        nextValue: () -> [String: ProcessGroupStepsHeight]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 一个过程组的步骤内容高度测量值 + 内容签名。
///
/// signature 必须随「步骤数 / 首尾 step id / 组内实时行文本」变化（见
/// FlowRowGroup.stepsContentSignature）：折叠期间组内容变化时缓存失效，避免
/// 展开动画用过期 Δ 把组头带跑。
struct ProcessGroupStepsHeight: Equatable {
    var signature: String
    var height: CGFloat
}
