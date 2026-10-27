import SwiftUI

/// Compact tool-call list (v5.1 spec): one rounded surface container with 1px
/// hairline separators, 36pt single-line rows, no inline output. Tapping a row
/// opens the 05 tool-result detail sheet.
struct ToolCallListView: View {
    var items: [ToolCallItem]
    var sessionId: String
    @ObservedObject var attachments: AttachmentStore
    var pendingApprovalCallIds: Set<String> = []
 /// When set, the parent owns detail presentation (stable across row rebuilds).
    var onOpenTool: ((ToolCallItem) -> Void)? = nil

    @State private var selected: ToolCallItem?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ToolCallCompactRow(
                    item: item,
                    pendingApproval: item.callId.map { pendingApprovalCallIds.contains($0) } ?? false
                ) {
                    if let onOpenTool {
                        onOpenTool(item)
                    } else {
                        selected = item
                    }
                }
                if index < items.count - 1 {
                    Rectangle()
                        .fill(Theme.Palette.border)
                        .frame(height: 1)
                        .padding(.leading, 34)
                }
            }
        }
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .sheet(item: $selected) { item in
            ToolResultDetailView(item: item, sessionId: sessionId, attachments: attachments)
        }
    }
}

/// 36pt single-line tool row: glyph · name · mono summary (middle ellipsis) ·
/// 6pt status dot · chevron.
///
/// v7 task-9（用户口径）：右侧不再出现「成功 / 失败 / 运行中 / 待审批」文案，
/// 状态只用彩色圆点表达（成功绿 / 失败红 / 运行中蓝 / 待审批黄）；运行中的行
/// 整行复用实时思考行的浅蓝底（liveStepHighlight）。状态文案只保留在无障碍
/// 标签里，VoiceOver 仍能读出结果。
struct ToolCallCompactRow: View {
    var item: ToolCallItem
    var pendingApproval: Bool
    var onTap: () -> Void

 /// 状态判定纯逻辑（失败 > 待审批 > 运行中 > 成功）。
    private var tone: StepStatusTone {
        StepStatusTone.resolve(item: item, pendingApproval: pendingApproval)
    }

 /// 视觉已无状态文案（v7 task-9）；状态拼进 a11y 标签，VoiceOver 可读。
    private var rowAccessibilityLabel: String {
        [ToolGlyph.displayName(for: item.name), StepRowPreview.singleLine(item.summary), tone.accessibilityText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: ToolGlyph.symbol(for: item.name))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(item.isError ? Theme.Palette.danger : Theme.Palette.accent)
                    .frame(width: 14)
                Text(ToolGlyph.displayName(for: item.name))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 64, alignment: .leading)
                Text(item.summary)
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
 // v7 task-9：只留 6pt 状态圆点（颜色见 StepStatusTone），不再有文案。
                StatusDot(color: tone.dotColor, size: 6, pulsing: tone.isPulsing)
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
 // 运行中的步骤行整行复用实时思考行的浅蓝底（同一 token，非新颜色）。
        .liveStepHighlight(tone == .running)
        .accessibilityIdentifier("tool-row-\(item.name)")
        .accessibilityLabel(rowAccessibilityLabel)
    }
}

extension StepStatusTone {
 /// 由「工具调用 + 是否待审批」推导（步骤行圆点与组内分隔线共用同一判定）。
    static func resolve(item: ToolCallItem, pendingApproval: Bool) -> StepStatusTone {
        resolve(isError: item.isError, pendingApproval: pendingApproval, isRunning: item.isRunning)
    }
}

/// Tool result detail (05) — reused by the compact list; keeps the existing
/// meta renderers (bash / read / edit / grep / glob / web / read_image).
struct ToolResultDetailView: View {
    var item: ToolCallItem
    var sessionId: String
    @ObservedObject var attachments: AttachmentStore

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: ToolGlyph.displayName(for: item.name),
                icon: ToolGlyph.symbol(for: item.name)
            )
            Rectangle().fill(Theme.Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    HStack(spacing: 5) {
                        StatusDot(color: item.isError ? Theme.Palette.danger : (item.isRunning ? Theme.Palette.accent : Theme.Palette.textTertiary), size: 6, pulsing: item.isRunning)
                        Text(item.statusText)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(item.isError ? Theme.Palette.danger : Theme.Palette.textSecondary)
                        Spacer()
                    }

                    if let arguments = argumentsText {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            SectionLabel(text: "参数")
                            MonoBlock(text: arguments, maxLines: 12)
                        }
                    }

                    if let result = item.result {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            SectionLabel(text: "结果")
                            ToolResultContentView(result: result, toolName: item.name, attachments: attachments)
                        }
                    } else {
                        HStack(spacing: Theme.Spacing.xs) {
                            ProgressView().tint(Theme.Palette.accent)
                            Text(L10n.t("工具仍在运行…"))
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }

                    if !item.children.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            SectionLabel(text: "嵌套调用")
                            ForEach(item.children) { child in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.Palette.textTertiary)
                                        Text(child.name)
                                            .font(Theme.Typography.monoSmall)
                                            .foregroundStyle(Theme.Palette.textSecondary)
                                        Text(child.summary)
                                            .font(Theme.Typography.monoSmall)
                                            .foregroundStyle(Theme.Palette.textTertiary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(child.statusText)
                                            .font(Theme.Typography.label)
                                            .foregroundStyle(child.isError ? Theme.Palette.danger : Theme.Palette.textTertiary)
                                    }
                                    if let result = child.result {
                                        ToolResultContentView(result: result, toolName: child.name, attachments: attachments)
                                    }
                                }
                                .padding(.leading, Theme.Spacing.xs)
                            }
                        }
                    }

                    if !item.children.isEmpty {
                        EmptyView()
                    }
                }
                .padding(Theme.Spacing.m)
                .measureSheetContentHeight()
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityIdentifier("tool-detail-sheet")
    }

    private var argumentsText: String? {
        if let raw = item.argumentsRaw, !raw.isEmpty { return raw }
        guard !item.arguments.isEmpty else { return nil }
        guard let data = try? JSONValue.object(item.arguments).encodedData(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
