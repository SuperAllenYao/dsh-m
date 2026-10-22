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
/// status dot + text · chevron.
struct ToolCallCompactRow: View {
    var item: ToolCallItem
    var pendingApproval: Bool
    var onTap: () -> Void

    private var statusColor: Color {
        if item.isError { return Theme.Palette.danger }
        if pendingApproval { return Theme.Palette.warning }
        if item.isRunning { return Theme.Palette.accent }
        return Theme.Palette.textTertiary
    }

    private var statusText: String {
        if item.isError { return L10n.t("失败") }
        if pendingApproval { return L10n.t("待审批") }
        if item.isRunning { return L10n.t("运行中") }
        return L10n.t("成功")
    }

    private var pulsating: Bool { item.isRunning || pendingApproval }

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
                HStack(spacing: 4) {
                    StatusDot(color: statusColor, size: 6, pulsing: pulsating)
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(item.isError ? Theme.Palette.danger : (item.isRunning ? Theme.Palette.accent : Theme.Palette.textTertiary))
                }
                .fixedSize()
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
        .accessibilityIdentifier("tool-row-\(item.name)")
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
