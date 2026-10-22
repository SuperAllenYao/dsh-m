import SwiftUI

/// Folded process group (v5.3): reasoning + tool calls collapse into one 28pt
/// row; the currently running step may occupy one extra 28pt row; failures and
/// pending-approval steps are always visible. Expanded shows LazyVStack of
/// v5.2 compact step rows.
struct ProcessGroupView: View {
    var steps: [ProcessStep]
    var isRunning: Bool
    var sessionId: String
    @ObservedObject var attachments: AttachmentStore
    var pendingApprovalCallIds: Set<String> = []
    var onOpenTool: ((ToolCallItem) -> Void)? = nil

    @State private var expanded = false
    @State private var selectedTool: ToolCallItem?
    @State private var reasoningDetail: String?

    private var exceptions: [ProcessStep] {
        SessionFlowGrouping.exceptionSteps(steps, pendingApprovalCallIds: pendingApprovalCallIds)
    }

    private var foldable: [ProcessStep] {
        SessionFlowGrouping.foldableSteps(steps, pendingApprovalCallIds: pendingApprovalCallIds)
    }

    private var currentStep: ProcessStep? {
        guard isRunning, !expanded else { return nil }
        return SessionFlowGrouping.currentStep(foldable)
    }

    private var secondaryText: String {
        if isRunning, let current = SessionFlowGrouping.currentStep(foldable) {
            let detail = current.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? L10n.f("… · 正在：%@", current.localizedVerb) : L10n.f("… · 正在：%@ %@", current.localizedVerb, detail)
        }
        return SessionFlowGrouping.localizedSummaryText(steps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if foldable.count >= 2 {
                container {
                    groupRow
                    if expanded {
                        LazyVStack(spacing: 0) {
                            ForEach(foldable) { step in
                                hairline(inset: 34)
                                stepRow(step)
                            }
                        }
                    } else if let current = currentStep {
                        hairline(inset: 34)
                        stepRow(current)
                    }
                }
            } else if let only = foldable.first {
                container {
                    stepRow(only)
                }
            }

            if !exceptions.isEmpty {
                container {
                    ForEach(Array(exceptions.enumerated()), id: \.element.id) { index, step in
                        if index > 0 { hairline(inset: 34) }
                        stepRow(step)
                    }
                }
            }
        }
        .sheet(item: $selectedTool) { item in
            ToolResultDetailView(item: item, sessionId: sessionId, attachments: attachments)
        }
        .sheet(item: Binding(
            get: { reasoningDetail.map { ReasoningDetailBox(text: $0) } },
            set: { reasoningDetail = $0?.text }
        )) { box in
            ReasoningDetailSheet(text: box.text)
        }
    }

    // MARK: - Rows

    private var groupRow: some View {
        Button {
            withAnimation(Theme.Motion.quick) { expanded.toggle() }
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
                Text(secondaryText)
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.s)
            .frame(height: 20)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("process-group-row")
    }

    @ViewBuilder
    private func stepRow(_ step: ProcessStep) -> some View {
        if let tool = step.tool {
            ToolCallCompactRow(
                item: tool,
                pendingApproval: tool.callId.map { pendingApprovalCallIds.contains($0) } ?? false
            ) {
                if let onOpenTool {
                    onOpenTool(tool)
                } else {
                    selectedTool = tool
                }
            }
        } else if let text = step.reasoningText {
            Button {
                reasoningDetail = text
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

private struct ReasoningDetailBox: Identifiable {
    var text: String
    var id: String { "\(text.count)-\(text.prefix(24))" }
}

private struct ReasoningDetailSheet: View {
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
