import SwiftUI

// MARK: - Pending interaction model (v0.2.0)

/// What the bottom interaction panel is currently asking for. One item at a
/// time: tool approvals win over user questions when both are pending.
enum PendingInteraction: Equatable, Identifiable {
    case approval(ApprovalWaterfall)
    case question(UserQuestionCall)

    enum Kind: Equatable {
        case approval
        case question
    }

    var id: String {
        switch self {
        case .approval(let approval): return "approval-\(approval.eventId)"
        case .question(let call): return "question-\(call.callId)"
        }
    }

    var kind: Kind {
        switch self {
        case .approval: return .approval
        case .question: return .question
        }
    }
}

extension PendingInteraction.Kind {
    var title: String {
        switch self {
        case .approval: return L10n.t("工具调用审批")
        case .question: return L10n.t("需要你的回答")
        }
    }

    var badgeText: String {
        switch self {
        case .approval: return L10n.t("等待审批")
        case .question: return L10n.t("等待作答")
        }
    }

    var badgeIcon: String {
        switch self {
        case .approval: return "exclamationmark.shield.fill"
        case .question: return "questionmark.bubble.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .approval: return Theme.Palette.warning
        case .question: return Theme.Palette.waiting
        }
    }

    var badgeBackground: Color {
        switch self {
        case .approval: return Theme.Palette.warningMuted
        case .question: return Theme.Palette.waiting.opacity(0.12)
        }
    }

    var badgeBorder: Color {
        switch self {
        case .approval: return Theme.Palette.warningBorder
        case .question: return Theme.Palette.waiting.opacity(0.32)
        }
    }

 /// Placeholder of the blocked composer shown while the panel is collapsed.
    var blockedComposerHint: String {
        switch self {
        case .approval: return L10n.t("请先处理审批，处理后可继续输入")
        case .question: return L10n.t("请先作答，作答后可继续输入")
        }
    }
}

// MARK: - Header badge

/// Top-right waiting badge of the session header. Shown while any approval or
/// user question is pending; tapping it toggles the interaction panel.
struct WaitingStatusBadge: View {
    var kind: PendingInteraction.Kind
    var collapsed: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: kind.badgeIcon)
                    .font(.system(size: 10, weight: .semibold))
                Text(kind.badgeText)
                    .font(Theme.Typography.label)
                    .lineLimit(1)
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.8)
            }
            .foregroundStyle(kind.badgeColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(kind.badgeBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(kind.badgeBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("waiting-status-badge")
        .accessibilityLabel(kind.badgeText)
        .accessibilityValue(collapsed ? "collapsed" : "expanded")
    }
}

// MARK: - Bottom interaction panel

/// Full-width bottom panel that replaces the composer while an approval or a
/// user question is pending. It blocks the input (answering is mandatory) and
/// can be folded away so the conversation output stays readable; the header
/// badge re-opens it.
struct PendingInteractionPanel: View {
    let interaction: PendingInteraction
    var toolCall: ToolCallItem?
    var isSubmittingApproval: Bool
    var approvalErrorText: String?
    var onApprovalDecision: (ApprovalOutcome) -> Void

    var questionIsSubmitting: Bool
    var questionErrorText: String?
    var onSubmitQuestion: ([UserQuestionAnswer]) -> Void
    var onSkipQuestion: () -> Void
    var onRetryQuestion: () -> Void

    var onCollapse: () -> Void
 /// Upper bound of the scrollable content (the panel itself sizes to content).
    var maxContentHeight: CGFloat? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.Palette.border).frame(height: 1)
            switch interaction {
            case .approval(let approval):
                ScrollView {
                    ApprovalPanelContent(
                        approval: approval,
                        toolCall: toolCall,
                        isSubmitting: isSubmittingApproval,
                        errorText: approvalErrorText,
                        onDecision: onApprovalDecision
                    )
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.s)
                    .measureSheetContentHeight()
                }
                .scrollIndicators(.hidden)
 // Short approvals used to fill the panel's upper bound, leaving a
 // blank band under the buttons; cap the scroll view at the content.
                .fitHeightToMeasuredContent(maxHeight: maxContentHeight)
                .accessibilityIdentifier("approval-panel")
            case .question(let call):
                UserQuestionCardView(
                    call: call,
                    isSubmitting: questionIsSubmitting,
                    errorText: questionErrorText,
                    onSubmit: onSubmitQuestion,
                    onSkip: onSkipQuestion,
                    onRetry: onRetryQuestion,
                    showsHeader: false,
                    embedded: true
                )
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.top, Theme.Spacing.s)
                .padding(.bottom, Theme.Spacing.xs)
                .accessibilityIdentifier("question-panel")
            }
        }
        .background {
 // Unified panel surface. The fill ignores the bottom safe area so the
 // home-indicator strip is the same colour as the panel (it used to
 // show a black band under the last row).
            UnevenRoundedRectangle(
                topLeadingRadius: Theme.Radius.xl,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: Theme.Radius.xl,
                style: .continuous
            )
            .fill(Theme.Palette.surfaceRaised)
 // The surface reaches the physical bottom edge (home-indicator band).
            .ignoresSafeArea(edges: .bottom)
        }
        .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: -6)
        .accessibilityIdentifier("pending-panel")
    }

    private var header: some View {
        SheetHeader(title: interaction.kind.title, titleIdentifier: "pending-panel-title") {
            Chip(
                text: interaction.kind.badgeText,
                color: interaction.kind.badgeColor,
                background: interaction.kind.badgeBackground,
                borderColor: interaction.kind.badgeBorder,
                icon: interaction.kind.badgeIcon
            )
            Button(action: onCollapse) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pending-panel-collapse")
            .accessibilityLabel(L10n.t("收起面板"))
        }
    }
}

// MARK: - Approval content

/// Content of the approval panel (moved out of the old half sheet). Wire source:
/// `approval/request` waterfall {toolName, callId, reason, displayReason}; the
/// command/diff preview is joined from the matching `tool/call` record.
struct ApprovalPanelContent: View {
    let approval: ApprovalWaterfall
    let toolCall: ToolCallItem?
    let isSubmitting: Bool
    let errorText: String?
    let onDecision: (ApprovalOutcome) -> Void

    private var toolName: String {
        approval.toolName ?? toolCall?.name ?? "tool"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: ToolGlyph.symbol(for: toolName))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                Text(ToolGlyph.displayName(for: toolName))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if let reason = approval.localizedReason, !reason.isEmpty {
                Text(reason)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("approval-reason")
            }

            preview

            if let errorText, !errorText.isEmpty {
                InlineErrorView(message: errorText)
                    .accessibilityIdentifier("approval-error")
            }

            HStack(spacing: Theme.Spacing.s) {
                Button {
                    onDecision(.rejected)
                } label: {
                    Text(L10n.t("拒绝"))
                }
                .buttonStyle(OutlineButtonStyle(tint: Theme.Palette.danger, border: Theme.Palette.dangerBorder))
                .disabled(isSubmitting)
                .accessibilityIdentifier("approval-reject")

                Button {
                    onDecision(.allowedOnce)
                } label: {
                    HStack(spacing: 6) {
                        if isSubmitting { ProgressView().tint(Theme.Palette.accentInk) }
                        Text(isSubmitting ? L10n.t("提交中…") : L10n.t("允许一次"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle(glow: true, enabled: !isSubmitting))
                .disabled(isSubmitting)
                .accessibilityIdentifier("approval-allow")
            }

            Text(L10n.t("允许仅对本次调用生效；拒绝后该工具不会执行。"))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let toolCall {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                SectionLabel(text: "调用预览")
                MonoBlock(text: previewText(toolCall), maxLines: 8)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(approval.callId.map { L10n.f("该调用没有关联的工具参数记录（callId %@）", String($0.prefix(12))) }
                     ?? L10n.t("该调用没有关联的工具参数记录"))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private func previewText(_ toolCall: ToolCallItem) -> String {
        let args = toolCall.arguments
        switch toolCall.name {
        case "bash":
            return "$ " + (args["command"]?.stringValue ?? "")
        case "edit", "write":
            let path = args["file_path"]?.stringValue ?? toolCall.summary
            if let oldText = args["old_string"]?.stringValue, let newText = args["new_string"]?.stringValue {
                let oldPreview = oldText.components(separatedBy: "\n").prefix(3).map { "- " + $0 }.joined(separator: "\n")
                let newPreview = newText.components(separatedBy: "\n").prefix(3).map { "+ " + $0 }.joined(separator: "\n")
                return path + "\n" + oldPreview + "\n" + newPreview
            }
            return path
        case "read", "read_image":
            return args["file_path"]?.stringValue ?? toolCall.summary
        case "grep", "glob":
            return args["pattern"]?.stringValue ?? toolCall.summary
        case "web_fetch":
            return args["url"]?.stringValue ?? toolCall.summary
        default:
            if let raw = toolCall.argumentsRaw, !raw.isEmpty {
                return String(raw.prefix(400))
            }
            return toolCall.summary
        }
    }
}

// MARK: - Blocked composer

/// Disabled composer strip shown instead of the real input while an interaction
/// is pending and the panel is collapsed. Tapping it re-opens the panel: the
/// input must stay unusable until the approval/question is answered.
struct BlockedComposerBar: View {
    var kind: PendingInteraction.Kind
    var onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.Palette.border)
                .frame(height: 1)
            Button(action: onTap) {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(kind.blockedComposerHint)
                        .font(Theme.Typography.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: Theme.Spacing.xs)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.horizontal, Theme.Spacing.m)
                .frame(height: Theme.Size.control)
                .frame(maxWidth: .infinity)
                .background(Theme.Palette.surfaceRaised)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer-blocked")
            .accessibilityLabel(kind.badgeText)
            .accessibilityHint(kind.blockedComposerHint)
        }
        .background(Theme.Palette.surfaceRaised, ignoresSafeAreaEdges: .bottom)
    }
}
