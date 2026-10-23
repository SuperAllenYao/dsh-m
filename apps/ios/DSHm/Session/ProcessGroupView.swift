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

    private var exceptions: [ProcessStep] {
        SessionFlowGrouping.exceptionSteps(steps, pendingApprovalCallIds: pendingApprovalCallIds)
    }

    private var foldable: [ProcessStep] {
        SessionFlowGrouping.foldableSteps(steps, pendingApprovalCallIds: pendingApprovalCallIds)
    }

    private var summaryText: String {
        SessionFlowGrouping.localizedSummaryText(steps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if foldable.count >= 2 {
                container {
                    headerRow
                    switch mode {
                    case .window:
                        stepsWindow
                    case .full, .expanded:
                        stepsInline
                    case .collapsed:
                        EmptyView()
                    }
                }
            } else if let only = foldable.first {
                // 单步过程不成组：保持内联一行（无四态）。
                container {
                    stepRow(only)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("process-single-row")
                }
            }

            // 失败/待审批步骤始终可见（即使组处于折叠态），保持既有语义。
            if !exceptions.isEmpty {
                container {
                    ForEach(Array(exceptions.enumerated()), id: \.element.id) { index, step in
                        if index > 0 { hairline(inset: 34) }
                        stepRow(step)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("process-exception-row")
                    }
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
                Text(L10n.f("过程 · %lld 步", steps.count))
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

    /// 纯图标切换件（无文字）：运行中＝向外/向内双箭头；已结束＝chevron。
    @ViewBuilder
    private var toggleGlyph: some View {
        switch mode {
        case .window, .full:
            Image(systemName: mode == .window ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 26, height: 26)
                .background(Theme.Palette.surfaceRaised, in: Circle())
                .overlay(Circle().strokeBorder(Theme.Palette.borderStrong, lineWidth: 1))
                .accessibilityIdentifier("process-group-toggle")
        case .collapsed:
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
                .accessibilityIdentifier("process-group-toggle")
        case .expanded:
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
                .accessibilityIdentifier("process-group-toggle")
        }
    }

    // MARK: - 步骤列表

    /// 运行中：固定高度窗口内滚动。
    ///
    /// v0.2.7 真机复核：scrollTo(last) / scrollPosition 在自撑高 cell 里会被夹断一行
    /// （首帧滚动早于行高重测，落不到位）。这里沿用外层消息列表已验证的「反转滚动」方案：
    /// ScrollView 与内容各自翻转一次 → offset 0 = 视觉底部，窗口初次出现就停在最新一步；
    /// 新步骤追加到数据头部（reversed 后 index 0）时继续贴底，不依赖任何滚动时序。
    /// 用户上滑（offset 增大）仍可回看更早步骤。
    private var stepsWindow: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                ForEach(Array(foldable.reversed())) { step in
                    hairline(inset: 34)
                    stepRow(step)
                        .scaleEffect(x: 1, y: -1)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("process-step-row")
                }
            }
        }
        .scaleEffect(x: 1, y: -1)
        .frame(height: windowHeight)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("process-steps-window")
    }

    /// 全量内联（运行中「全高」/ 已结束「展开历史」）：同步 VStack。
    private var stepsInline: some View {
        VStack(spacing: 0) {
            ForEach(foldable) { step in
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
