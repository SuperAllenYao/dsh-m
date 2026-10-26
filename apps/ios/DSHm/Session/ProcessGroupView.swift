import SwiftUI

/// 内联「模型工作步骤」块（v6：平铺 + 大折叠 + 实时行，对齐 DSH 桌面端）：
/// - 默认 `.expanded`（运行中与已结束都全量平铺）；点组头「收起」→ `.collapsed`（只留组头），
/// 再点「展开」恢复；
/// - 组头桌面式：▣ N 步 + 运行中 ●/已完成 + 收起 ⌃/展开 ⌄（不写分类计数摘要）；
/// - 运行中组内可出现实时行：实时思考（3 行 + 渐隐，点开 190pt 内滚）与工具准备行；
/// - 旧 `.window`（固定高度窗口）/`.full`（无高度限制）保留但不再默认。
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
 /// `.window` 模式的固定高度（≈会话可视高度 1/3，由页面计算后传入）。
    var windowHeight: CGFloat = 300
    var onToggleMode: (() -> Void)? = nil
    var onOpenTool: ((ToolCallItem) -> Void)? = nil
    var onOpenReasoning: ((String) -> Void)? = nil

 /// Reduce Motion：关掉高度动画，配合列表的瞬时补偿（终态与动效一致、无过渡抖动）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
 // 步骤按事件顺序整体分组（失败/待审批步骤也在序列里，见 v0.2.7 用户口径）：
 // v6 默认平铺展开；折叠态只留组头一行。
            if steps.count >= 2 {
                container {
                    headerRow
                    Group {
                        switch mode {
                        case .window:
                            stepsWindow
                        case .full, .expanded:
                            stepsInline
 // 展开态：可见内容自报高度（点击收起的预测 Δ 来源）。
                                .background(stepsHeightReader)
 // 手驱动动画的高度覆盖（nil = 自然高度）；顶部对齐 +
 // 裁掉溢出 = 步骤从组头下方长入/收回（inverted 布局里
 // 行内 top = 视觉顶边 = 组头所在边）。
                                .frame(height: animatedStepsHeight, alignment: .top)
                                .clipped()
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
 // 折叠态隐藏测量：算出「展开后步骤内容会占的高度」，点击瞬间即可
 // 预测行高变化量 Δ（= 步骤内容高度，组头与间距不变）。背景测量
 // 不参与布局/交互/无障碍，不产生产品行为。
                .background(alignment: .top) {
                    if mode == .collapsed, !measurementID.isEmpty {
                        stepsInline
                            .fixedSize(horizontal: false, vertical: true)
                            .background(stepsHeightReader)
                            .hidden()
                    }
                }
            } else if let only = steps.first {
 // 单步过程不成组：保持内联一行（无四态）。
                container {
                    stepRow(only)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("process-single-row")
                }
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
    }

 /// v6 桌面式切换件：11pt 文案 + chevron（折叠态「展开 ⌄」/ 展开态「收起 ⌃」）。
    @ViewBuilder
    private var toggleGlyph: some View {
        HStack(spacing: 2) {
            Text(isCollapsed ? L10n.t("展开") : L10n.t("收起"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1)
            Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .fixedSize()
        .animation(.easeInOut(duration: 0.1), value: mode)
        .accessibilityIdentifier("process-group-toggle")
    }

 /// 是否折叠态（决定「展开 ⌄ / 收起 ⌃」文案与箭头朝向）。
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
                    hairline(inset: 34)
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
                    hairline(inset: 34)
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

    private func stepRow(_ step: ProcessStep) -> some View {
        ProcessStepRow(
            step: step,
            pendingApprovalCallIds: pendingApprovalCallIds,
            onOpenTool: onOpenTool,
            onOpenReasoning: onOpenReasoning
        )
    }

 // MARK: - 行高测量（滚动锚定补偿用）

 /// 步骤内容（不含组头）的自然高度上报：measurementID -> height。
 /// 展开态量可见内容，折叠态量隐藏副本——列表点击组头时据此预测行高 Δ。
    private var stepsHeightReader: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ProcessGroupStepsHeightKey.self,
                value: [measurementID: max(0, geo.size.height)]
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
        .background(Theme.Palette.accent.opacity(0.05))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Palette.accentBorder)
                .frame(height: 1)
        }
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
        .background(Theme.Palette.accent.opacity(0.05))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Palette.accentBorder)
                .frame(height: 1)
        }
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
                Text(text)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.m)
                    .textSelection(.enabled)
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
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
