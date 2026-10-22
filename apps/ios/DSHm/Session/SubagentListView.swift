import SwiftUI

/// v5.4 task-13: half-sheet list of the parent session's subagents.
///
/// Row: catalog label / mode tag (连续 / 一次性 / 外部) / status
/// (运行中 orange, 等待作答 green, 空闲 neutral) / recent activity. Tapping a row
/// opens that child session detail with the subagent `session/follow` address.
///
/// v5.5 §14.4: the top-left 「关闭」 toolbar button is gone — the sheet is closed
/// by swiping it down (the drag indicator stays visible for discoverability).
struct SubagentListView: View {
    var entries: [SubagentCatalogEntry]
    var runtimes: [String: SubagentRuntime]
    var onSelect: (SubagentCatalogEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L10n.t("子代理"))
            Rectangle().fill(Theme.Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    if entries.isEmpty {
                        EmptyStateView(
                            icon: "person.2",
                            title: "暂无子代理",
                            message: "主会话派生子代理后会显示在这里。"
                        )
                        .accessibilityIdentifier("subagent-list-empty")
                    }
                    ForEach(entries) { entry in
                        Button {
                            onSelect(entry)
                        } label: {
                            row(entry)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("subagent-row-\(entry.id)")
                    }
                }
                .padding(Theme.Spacing.m)
                .measureSheetContentHeight()
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityIdentifier("subagent-list-sheet")
    }

    private func row(_ entry: SubagentCatalogEntry) -> some View {
        let runtime = runtimes[entry.id]
        let status = runtime?.status ?? .idle
        return HStack(spacing: Theme.Spacing.xs) {
            StatusDot(color: status.color, size: 6, pulsing: status == .running)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayLabel)
                    .font(Theme.Typography.captionMedium)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(SubagentMode(raw: entry.mode).localizedDisplayLabel)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.Palette.surfaceRaised, in: Capsule())
                    if let activity = SubagentActivityText.localizedRelative(fromMillis: runtime?.lastActivityAt) {
                        Text(activity)
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
            }
            Spacer(minLength: Theme.Spacing.xs)
            Text(status.localizedLabel)
                .font(Theme.Typography.label)
                .foregroundStyle(status.color)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(status == .waiting ? Theme.Palette.waiting.opacity(0.4) : Theme.Palette.border, lineWidth: 1)
        )
    }
}
