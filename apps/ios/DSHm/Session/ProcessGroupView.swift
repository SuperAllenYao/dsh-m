import SwiftUI

/// 内联「模型工作步骤」块（v0.2.7，对齐 DSH 桌面端）：
/// - 运行中默认 `.window`：块内是一个固定高度窗口（≈会话可视高 1/3），步骤在窗口内
///   滚动并自动跟随最新一步；点 header 右上角图标切换 `.full`（取消高度限制，全量内联）；
/// - 这一轮结束自动进入 `.collapsed`（一行摘要）；点一行展开 `.expanded`（历史步骤全量内联）。
///
/// 渲染要点（v0.2.7 修复 + 四态）：
/// 1. 全量模式用同步 `VStack`：自撑高 cell 里 `LazyVStack` 没有视口，只实体化末尾几条
///    （用户报障截图：展开 10 步只看到 3 步 + 大块空白）。
/// 2. 显示态由页面持有（`mode` + `onToggleMode`），cell reconfigure/复用时不会丢。
/// 3. 工具/思考详情弹层回调到页面级 `SessionDetailSheet`，cell 重建不丢弹层。
struct ProcessGroupView: View {
    var steps: [ProcessStep]
    var isRunning: Bool
    var pendingApprovalCallIds: Set<String> = []
    var mode: ProcessGroupMode = .collapsed
    /// `.window` 模式的固定高度（≈会话可视高度 1/3，由页面计算后传入）。
    var windowHeight: CGFloat = 300
    var onToggleMode: (() -> Void)? = nil
    var onOpenTool: ((ToolCallItem) -> Void)? = nil
    var onOpenReasoning: ((String) -> Void)? = nil

    private var summaryText: String {
        SessionFlowGrouping.localizedSummaryText(steps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            // 步骤按事件顺序整体分组（失败/待审批步骤也在序列里，见 v0.2.7 用户口径）：
            // 折叠态只有一行摘要；展开后按原始顺序展示全部步骤。
            if steps.count >= 2 {
                container {
                    headerRow
                    Group {
                        switch mode {
                        case .window:
                            stepsWindow
                        case .full, .expanded:
                            stepsInline
                        case .collapsed:
                            EmptyView()
                        }
                    }
                    .clipped()
                    // 用户口径（2026-10-24）：展开/收起 150ms ease-in-out 非线性动画，
                    // 向下展开、向上收起；UIKit 侧同步动画 row 高度与 contentOffset。
                    .animation(.easeInOut(duration: 0.15), value: mode)
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

    // MARK: - Header（整行可点：运行中 window⇄full；已结束 collapsed⇄expanded）

    private var headerRow: some View {
        Button {
            onToggleMode?()
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 14)
                // 用户口径（2026-10-24）：组头不出现「过程」二字。
                Text(L10n.f("%lld 步", steps.count))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                if isRunning {
                    HStack(spacing: 4) {
                        StatusDot(color: Theme.Palette.accent, size: 6, pulsing: true)
                        Text(L10n.t("运行中"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    .fixedSize()
                }
                Text(summaryText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    /// 纯图标切换件（无文字），与 DSH 桌面端 TurnProcess 箭头一致：
    /// 折叠/窗口态＝右箭头 ▶（chevron.right），展开/全高态＝下箭头 ▼（chevron.down）；
    /// 旋转 100ms 过渡（桌面端箭头 transition:transform .1s）。
    @ViewBuilder
    private var toggleGlyph: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.Palette.textTertiary)
            .rotationEffect(.degrees(isExpandedForGlyph ? 0 : -90))
            .animation(.easeInOut(duration: 0.1), value: mode)
            .accessibilityIdentifier("process-group-toggle")
    }

    /// 箭头是否处于「展开」朝向（下箭头）。
    private var isExpandedForGlyph: Bool {
        mode == .full || mode == .expanded
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
                hairline(inset: 34)
                stepRow(step)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("process-step-row")
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

    /// 全量内联（运行中「全高」/ 已结束「展开历史」）：同步 VStack。
    private var stepsInline: some View {
        VStack(spacing: 0) {
            ForEach(steps) { step in
                hairline(inset: 34)
                stepRow(step)
                    // 每行一个显式 AX 元素：容器 VStack 不是独立 AX 节点，
                    // 标识会污染子行，E2E 无法按容器统计行数（真机实测）。
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("process-step-row")
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

    @ViewBuilder
    private func container<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
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
        if let tool = step.tool {
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
