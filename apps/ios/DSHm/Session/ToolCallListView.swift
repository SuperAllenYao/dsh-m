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
///
/// DD-03 / AC-04：`read/edit/write/read_image` 的行，中间的文件名是**独立命中区**
/// （打开文件面板或图片预览），行内其它区域仍是「开工具详情」；其余工具行维持
/// 整行一个按钮。
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

    @Environment(\.fileOpenAction) private var fileOpenAction

    /// 行内文件名的打开目标：文件路径可分类 **且** 有承载方（`fileOpenAction != nil`）
    /// 才拆命中区；否则整行维持现状（不会出现点了没反应的「死按钮」）。
    private var fileOpenTarget: FileOpenTarget? {
        guard fileOpenAction != nil else { return nil }
        return FileEntryTarget.openTarget(for: item)
    }

    /// 行内展示的文件名（与 `item.summary` 同口径；参数只给 `path` 时退回路径末段）。
    private var fileDisplayName: String {
        guard let path = FileEntryTarget.path(for: item) else { return item.summary }
        return FileEntryTarget.displayName(for: item, path: path)
    }

    var body: some View {
        if let target = fileOpenTarget, let open = fileOpenAction {
            splitRow(target: target, open: open)
        } else {
            unifiedRow
        }
    }

 // MARK: 现状：整行一个按钮 → 工具详情

    /// 默认行：整行一个按钮开工具详情（既有 E2E「点整行开详情」依赖这一形状）。
    private var unifiedRow: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Spacing.xs) {
                glyph
                name
                summaryText
                statusDot
                chevron
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

 // MARK: AC-04：文件名独立命中区

    /// 文件工具行：拆成**互不重叠的同级 Button**（不嵌套按钮、不依赖手势优先级）。
    ///
    /// - 左区（图标 + 工具名，`tool-row-<name>`）与右区（状态点 + chevron）仍是
    ///   「开工具详情」，语义与原整行按钮一致；
    /// - 中间的文件名（`tool-row-file-<文件名>`）经 `FileOpenRouter` 分类后打开文件
    ///   面板或图片预览（AC-15：图片走预览，不进面板）；
    /// - 命中矩形互不重叠，所以同一次点击不可能既开面板又开详情；左右两区的 12pt
    ///   内边距与整行高度都算在按钮 label 里，点左右区域仍是原来的手感。
    private func splitRow(target: FileOpenTarget, open: @escaping (FileOpenTarget) -> Void) -> some View {
        // 区域间距全部由各命中区的内边距承担：视觉与改造前一致，但三块之间没有
        // 点不动的空隙（整行横向都被某个按钮覆盖）。
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: Theme.Spacing.xs) {
                    glyph
                    name
                }
                .padding(.leading, Theme.Spacing.s)
                .padding(.trailing, Theme.Spacing.xs)
                .padding(.vertical, 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tool-row-\(item.name)")
            .accessibilityLabel(rowAccessibilityLabel)

            Button {
                open(target)
            } label: {
                Text(fileDisplayName)
                    .underline(true, pattern: .dash, color: Theme.Palette.accentBorder)
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.Palette.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tool-row-file-\(fileDisplayName)")

            Button(action: onTap) {
                HStack(spacing: Theme.Spacing.xs) {
                    statusDot
                    chevron
                }
                .padding(.leading, Theme.Spacing.xs)
                .padding(.trailing, Theme.Spacing.s)
                .padding(.vertical, 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 与左区同义（开工具详情）：隐藏，避免 VoiceOver 把同一个动作播报两次。
            .accessibilityHidden(true)
        }
        .frame(height: 28)
        .liveStepHighlight(tone == .running)
    }

 // MARK: 行内元素（两种形状共用，保证视觉一致）

    private var glyph: some View {
        Image(systemName: ToolGlyph.symbol(for: item.name))
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(item.isError ? Theme.Palette.danger : Theme.Palette.accent)
            .frame(width: 14)
    }

    private var name: some View {
        Text(ToolGlyph.displayName(for: item.name))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 64, alignment: .leading)
    }

    private var summaryText: some View {
        Text(item.summary)
            .font(.system(size: 11.5, weight: .regular, design: .monospaced))
            .foregroundStyle(Theme.Palette.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

 // v7 task-9：只留 6pt 状态圆点（颜色见 StepStatusTone），不再有文案。
    private var statusDot: some View {
        StatusDot(color: tone.dotColor, size: 6, pulsing: tone.isPulsing)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Theme.Palette.textTertiary)
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
        // 先声明容器再命名：标识落在详情层自身，标题/文件入口等子元素保留自己的标识（DEF-007）。
        .accessibilityElement(children: .contain)
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
