import SwiftUI

/// 用户主动展开/收起（cell 内 SwiftUI 状态）的信号。
///
/// 只有「用户点击」触发的行高变化才需要「入口行固定」的锚点动画；布局期/流式内容/
/// 首次渲染的高度变化不走这条路径。
struct UserToggleReporterKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var userToggleReporter: (() -> Void)? {
        get { self[UserToggleReporterKey.self] }
        set { self[UserToggleReporterKey.self] = newValue }
    }
}

/// Dispatches one FlowRow to its renderer. Every row maps to a DSH event/field;
/// see §2/§3 and session-field-inventory §2.
struct FlowRowView: View {
    var row: FlowRow
    var sessionId: String
    @ObservedObject var attachments: AttachmentStore
 /// Child session id -> subagent catalog label (v5.4 relay cards).
    var subagentLabels: [String: String] = [:]
    var onOpenTool: ((ToolCallItem) -> Void)? = nil

    var body: some View {
        switch row.content {
        case .user(let bubble):
            UserBubbleView(bubble: bubble, sessionId: sessionId, attachments: attachments)
        case .relay(let card):
            RelayCardView(
                card: card,
                sessionId: sessionId,
                attachments: attachments,
                agentLabel: card.senderSessionId.flatMap { subagentLabels[$0] }
            )
        case .notice(let notice):
            NoticeCardView(card: notice)
        case .reasoning(let text):
            ReasoningRowView(text: text)
        case .text(let text):
            MarkdownText(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let item):
            ToolCallListView(items: [item], sessionId: sessionId, attachments: attachments, onOpenTool: onOpenTool)
        case .approval(let approval):
            ApprovalHistoryRowView(item: approval)
        case .plan(let todos, let status):
            PlanCardView(todos: todos, status: status)
        case .goal(let objective, let phase):
            GoalCardView(objective: objective, phase: phase)
        case .deliverable(let files):
            DeliverableCardView(files: files)
        case .job(let job):
            JobCardView(job: job)
        case .error(let message):
            ErrorRowView(message: message)
        case .systemNote(let text):
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        case .command(let name):
            HStack(spacing: 6) {
                Image(systemName: "slash.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text("/" + name)
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - User bubble (right aligned; §3: user -> right bubble)

struct UserBubbleView: View {
    var bubble: UserBubble
    var sessionId: String
    @ObservedObject var attachments: AttachmentStore

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if !bubble.text.isEmpty {
                    MarkdownText(text: bubble.text)
                }
                if !bubble.images.isEmpty {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(bubble.images, id: \.self) { ref in
                            AttachmentThumbnail(ref: ref, attachments: attachments, maxHeight: 140)
                        }
                    }
                }
            }
            .padding(Theme.Spacing.s)
            .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Palette.borderStrong, lineWidth: 1)
            )
            .accessibilityIdentifier("user-bubble")
        }
    }
}

// MARK: - Relay / subagent card (v5.4: collapsed by default)

/// A child agent's message relayed into the parent session. v5.4 collapses it to
/// one header line (icon + 子代理消息 + catalog label/short id + chevron); tapping
/// animates it open to show summary / markdown text / images.
struct RelayCardView: View {
    var card: RelayCard
    var sessionId: String
    @ObservedObject var attachments: AttachmentStore
 /// `subagentCatalog` label for the sender child session (falls back to id prefix).
    var agentLabel: String? = nil
    @State private var isExpanded = false
    @Environment(\.userToggleReporter) private var userToggleReporter

    private var senderLabel: String {
        if let agentLabel, !agentLabel.isEmpty { return agentLabel }
        if let sender = card.senderSessionId, !sender.isEmpty { return String(sender.prefix(8)) }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button {
                userToggleReporter?()
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.accent)
                    Text(L10n.t("子代理消息"))
                        .font(Theme.Typography.captionMedium)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    if !senderLabel.isEmpty {
                        Text(senderLabel)
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("relay-card-toggle")
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")

            if isExpanded {
                if let summary = card.summary, !summary.isEmpty, summary != card.text {
                    Text(summary)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                if !card.text.isEmpty {
                    MarkdownText(text: card.text, color: Theme.Palette.textSecondary)
                }
                if !card.images.isEmpty {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(card.images, id: \.self) { ref in
                            AttachmentThumbnail(ref: ref, attachments: attachments, maxHeight: 120)
                        }
                    }
                }
            }
        }
 // 行高由 SessionMessageListView 显式逐帧驱动；这里只做边界裁剪。
        .clipped()
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Palette.accentBorder, lineWidth: 1)
        )
        .accessibilityIdentifier("relay-card")
    }
}

// MARK: - Notice card (§3: */notice -> notice card)

struct NoticeCardView: View {
    var card: NoticeCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t(card.title))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
            if !card.text.isEmpty {
                Text(card.text)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .accessibilityIdentifier("notice-card")
    }
}

// MARK: - Reasoning (collapsed by default; §2 03)

struct ReasoningRowView: View {
    var text: String
    @State private var expanded = false
    @Environment(\.userToggleReporter) private var userToggleReporter

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button {
                userToggleReporter?()
                expanded.toggle()
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Palette.accent)
                    Text("思考")
                        .font(Theme.Typography.captionMedium)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .padding(Theme.Spacing.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reasoning-row")
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            if expanded {
                Text(text)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineSpacing(3)
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.bottom, Theme.Spacing.s)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("reasoning-full-text")
            }
        }
 // 行高由 SessionMessageListView 显式逐帧驱动（hosted 内容高度是瞬间变化的，
 // 无法靠 SwiftUI 动画带动 hosting intrinsic size），这里只做边界裁剪。
        .clipped()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
    }
}

// MARK: - Approval history row

struct ApprovalHistoryRowView: View {
    var item: ApprovalItem

    private var outcomeText: String {
        switch item.outcome {
        case "allowed-once": return L10n.t("已允许（一次）")
        case "rejected": return L10n.t("已拒绝")
        case "cancelled": return L10n.t("已取消")
        case "unavailable": return L10n.t("无人应答")
        default: return item.outcome == nil ? L10n.t("等待审批") : (item.outcome ?? "")
        }
    }

    private var isPending: Bool { item.outcome == nil }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isPending ? Theme.Palette.warning : Theme.Palette.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("工具调用审批")
                    .font(Theme.Typography.captionMedium)
                    .foregroundStyle(Theme.Palette.textSecondary)
                if let toolName = item.toolName {
                    Text(toolName)
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                if let reason = item.reason, !reason.isEmpty {
                    Text(reason)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if isPending {
                Chip(text: outcomeText, color: Theme.Palette.warning, background: Theme.Palette.warningMuted, borderColor: Theme.Palette.warningBorder)
            } else {
                Text(outcomeText)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(isPending ? Theme.Palette.warningBorder : Theme.Palette.border, lineWidth: 1)
        )
        .accessibilityIdentifier("approval-row")
    }
}

// MARK: - Plan / todo

struct PlanCardView: View {
    var todos: [TodoItem]
    var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
                Text("计划")
                    .font(Theme.Typography.captionMedium)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Text("\(todos.filter { $0.status == "completed" }.count)/\(todos.count)")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            ForEach(todos) { todo in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: todo.status == "completed" ? "checkmark.circle.fill" : (todo.status == "in_progress" ? "circle.dotted" : "circle"))
                        .font(.system(size: 11))
                        .foregroundStyle(todo.status == "completed" ? Theme.Palette.accent : Theme.Palette.textTertiary)
                    Text(todo.content)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(todo.status == "completed" ? Theme.Palette.textTertiary : Theme.Palette.textSecondary)
                        .strikethrough(todo.status == "completed", color: Theme.Palette.textTertiary)
                }
            }
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .accessibilityIdentifier("plan-card")
    }
}

struct GoalCardView: View {
    var objective: String
    var phase: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "target")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
                Text(L10n.t("目标"))
                    .font(Theme.Typography.captionMedium)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                if let phase {
                    Text(phase)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            Text(objective)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
    }
}

struct DeliverableCardView: View {
    var files: [PresentedFile]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
                Text(L10n.t("交付物"))
                    .font(Theme.Typography.captionMedium)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            ForEach(files) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.path)
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let description = file.description, !description.isEmpty {
                        Text(description)
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
            }
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
    }
}

struct JobCardView: View {
    var job: JobItem

    private var statusText: String {
        switch job.status {
        case "completed": return L10n.t("已完成")
        case "killed": return L10n.t("已终止")
        case "running": return L10n.t("运行中")
        default: return job.status ?? ""
        }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(job.status == "running" ? Theme.Palette.accent : Theme.Palette.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                Text(job.kind + " · " + statusText)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Spacer()
            if let finished = job.finishedAt, let started = job.startedAt {
                Text(DisplayFormat.duration(finished - started))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .accessibilityIdentifier("job-card")
    }
}

struct ErrorRowView: View {
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.danger)
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.dangerMuted, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Theme.Palette.dangerBorder, lineWidth: 1)
        )
        .accessibilityIdentifier("error-row")
    }
}
