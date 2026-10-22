import SwiftUI

/// Message composer (v5.4): one unified send/abort button + client-side queue bar.
///
/// Button rules are resolved by `ComposerButtonState` (pure, unit-tested):
/// text -> send (queues while a turn runs), empty + running -> abort, empty +
/// idle -> disabled send, prompt in flight -> spinner.
struct ComposerView: View {
    @Binding var draft: String
    var isConnected: Bool
    var isRunning: Bool
    var sending: Bool
    var queued: PromptQueue = PromptQueue()
    /// v5.4 task-13: one-shot/external subagents are read-only from the phone.
    var isReadOnly: Bool = false
    var readOnlyReason: String? = nil
    var onSend: () -> Void
    var onAbort: () -> Void
    var onSteerFirst: () -> Void

    private var state: ComposerButtonState {
        ComposerButtonState.resolve(draft: draft, isRunning: isRunning, sending: sending)
    }

    private var isButtonEnabled: Bool {
        guard state.isEnabled, !isReadOnly else { return false }
        if state.action == .abort { return true }
        // M2a fix: a non-empty draft must always be actionable. When the transport
        // is reconnecting/offline the tap now queue the prompt locally (SessionViewModel
        // flushes it on the next connected phase) instead of showing a dead grey button.
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.Palette.border)
                .frame(height: 1)
            if isReadOnly, let readOnlyReason {
                HStack(spacing: 5) {
                    Image(systemName: "lock")
                        .font(.system(size: 10, weight: .semibold))
                    Text(readOnlyReason)
                        .font(Theme.Typography.label)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.surfaceRaised)
                .accessibilityIdentifier("composer-readonly-hint")
            }
            if !isReadOnly, let banner = queued.localizedBannerText {
                queueBar(isConnected ? banner : banner + L10n.t("（未连接，重连后自动发送）"), tappable: isConnected)
            }
            HStack(alignment: .bottom, spacing: Theme.Spacing.xs) {
                TextField(isReadOnly ? L10n.t("只读子代理，不能发送消息") : L10n.t("发消息给会话…"), text: $draft, axis: .vertical)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1...6)
                    .padding(.horizontal, Theme.Spacing.s)
                    // v5.5 §14.1: single-line height == 44pt button height; the
                    // vertical padding centres the text and multi-line drafts
                    // still grow past the minimum.
                    .padding(.vertical, 12)
                    .frame(minHeight: Theme.Size.control)
                    .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                            .strokeBorder(Theme.Palette.border, lineWidth: 1)
                    )
                    .disabled(isReadOnly)
                    .accessibilityIdentifier("composer-input")
                    // v5.5 §14.1: a vertical-axis SwiftUI TextField exposes only
                    // its text line (17pt) as the accessibility frame, so this
                    // read-only element reports the real control height for the
                    // UI-test regression assertion (== send/abort button height).
                    // It must sit after the identifier so it is not overridden.
                    .overlay(
                        Color.clear
                            .accessibilityElement()
                            .accessibilityIdentifier("composer-input-frame")
                            .allowsHitTesting(false)
                    )
                actionButton
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.xs)
        }
        .background(Theme.Palette.background)
    }

    /// v5.4 thin queue bar: `排队中 N 条 · <首行…> · 点击立即介入`; tapping steers
    /// the oldest queued prompt immediately.
    private func queueBar(_ banner: String, tappable: Bool = true) -> some View {
        Button(action: { if tappable { onSteerFirst() } }) {
            HStack(spacing: 5) {
                Image(systemName: tappable ? "clock.arrow.circlepath" : "icloud.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tappable ? Theme.Palette.accent : Theme.Palette.textTertiary)
                Text(banner)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surfaceRaised)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer-queue-bar")
    }

    private var actionButton: some View {
        Button {
            switch state.action {
            case .send: onSend()
            case .abort: onAbort()
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(background)
                if state.showsSpinner {
                    ProgressView().tint(Theme.Palette.accentInk)
                } else {
                    Image(systemName: state.action == .abort ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(iconColor)
                }
            }
            .frame(width: Theme.Size.control, height: Theme.Size.control)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
        }
        .disabled(!isButtonEnabled)
        .accessibilityIdentifier(state.action == .abort ? "composer-abort" : "composer-send")
    }

    private var background: Color {
        if state.showsSpinner { return Theme.Palette.surfaceRaised }
        switch state.action {
        case .send: return state.isEnabled ? Theme.Palette.accent : Theme.Palette.surfaceRaised
        case .abort: return Theme.Palette.dangerMuted
        }
    }

    private var iconColor: Color {
        if state.showsSpinner { return Theme.Palette.accentInk }
        switch state.action {
        case .send: return state.isEnabled ? Theme.Palette.accentInk : Theme.Palette.textTertiary
        case .abort: return Theme.Palette.danger
        }
    }

    private var borderColor: Color {
        if state.showsSpinner { return Theme.Palette.border }
        switch state.action {
        case .send: return state.isEnabled && isConnected ? .clear : Theme.Palette.border
        case .abort: return Theme.Palette.dangerBorder
        }
    }
}

/// Session status strip (v0.2.0): composer-adjacent row, left to right:
/// permission icon → context window → model entry → subagent entry. The old
/// waiting-answer cell moved to the session-header badge (see
/// PendingInteractionPanel.swift).
struct SessionStatusStrip: View {
    var permissionsValue: String?
    /// Context-window usage (`projections.values.contextPressure`); the cell shows
    /// the window value + a colour-coded percentage (e.g. `1M · 53%`), never the
    /// literal "上下文窗口" wording (v0.2.0 revision).
    var contextPressure: ContextPressureValue?
    /// Model entry trigger state; nil hides the cell (subagent sessions).
    var modelTrigger: ModelTriggerState?
    /// v5.4 task-13: child subagent count + running animation state.
    var subagentCount: Int = 0
    var subagentRunning: Bool = false
    var onPermissionTap: () -> Void
    var onModelTap: (() -> Void)? = nil
    var onSubagentTap: (() -> Void)? = nil

    static func permissionLabel(_ value: String?) -> String {
        switch value {
        case "read-only": return L10n.t("只读")
        case "workspace-write": return L10n.t("工作区可写")
        case "danger-full-access": return L10n.t("完全访问")
        case .some(let other): return other
        case .none: return L10n.t("权限未知")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.Palette.border)
                .frame(height: 1)
            HStack(spacing: 0) {
                permissionCell
                cellDivider
                contextWindowCell
                cellDivider
                if let modelTrigger, let onModelTap {
                    modelCell(modelTrigger, tap: onModelTap)
                } else {
                    Spacer(minLength: 0)
                }
                if subagentCount > 0, let onSubagentTap {
                    cellDivider
                    SubagentCapsuleButton(
                        count: subagentCount,
                        isRunning: subagentRunning,
                        onTap: onSubagentTap
                    )
                    .frame(width: 52)
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(height: Theme.Size.statusStrip)
            .background(Theme.Palette.background)
        }
    }

    // MARK: - Model entry (v0.2.0, always visible)

    private func modelCell(_ trigger: ModelTriggerState, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 4) {
                Text(trigger.text)
                    .font(Theme.Typography.label)
                    .foregroundStyle(trigger.isLoading ? Theme.Palette.textTertiary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.8)
                if trigger.isLoading {
                    ProgressView()
                        .tint(Theme.Palette.accent)
                        .scaleEffect(0.6)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .padding(.horizontal, Theme.Spacing.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("model-chip")
        .accessibilityLabel(L10n.t("模型"))
        .accessibilityValue(trigger.text)
    }

    // MARK: - Context window (v0.2.0: window value + percentage, no wording)

    private var contextWindowCell: some View {
        HStack(spacing: 4) {
            Text(contextPressure?.windowText ?? "—")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
            if contextPressure?.windowText != nil, let percent = contextPressure?.percent {
                Text("·")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                Text("\(percent)%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(usageColor(contextPressure?.usageLevel))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, Theme.Spacing.s)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("context-window")
        .accessibilityLabel(L10n.t("上下文窗口"))
        .accessibilityValue(contextPressure?.displayText ?? "—")
    }

    /// Four severity buckets: <50 neutral, 50–79 accent, 80–89 warning, >=90 danger.
    private func usageColor(_ level: ContextPressureValue.UsageLevel?) -> Color {
        switch level {
        case .low: return Theme.Palette.textSecondary
        case .moderate: return Theme.Palette.accent
        case .high: return Theme.Palette.warning
        case .critical: return Theme.Palette.danger
        case .none: return Theme.Palette.textTertiary
        }
    }

    /// v5.5 §14.2: icon only (no label text, no chip fill / stroke); still opens
    /// the permission sheet. The accessibility label keeps the wording.
    private var permissionCell: some View {
        Button(action: onPermissionTap) {
            Image(systemName: "lock.shield")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 44)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("permission-chip")
        .accessibilityLabel(L10n.f("权限：%@", Self.permissionLabel(permissionsValue)))
        .accessibilityValue(Self.permissionLabel(permissionsValue))
    }

    /// v5.5 §14.6: 1pt column divider (Theme.Palette.border) between the cells.
    private var cellDivider: some View {
        Rectangle()
            .fill(Theme.Palette.border)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

/// v0.2.0 subagent entry (B "边框流光"): compact 44×24 capsule; the icon + count
/// form one centred group, and while any child runs a 26%-perimeter accent beam
/// travels along the capsule border (1.6 s loop). Reduce Motion degrades to a
/// static accent border. This animation is the only stroke layer: the former
/// nested ring + capsule double stroke is gone.
struct SubagentCapsuleButton: View {
    var count: Int
    var isRunning: Bool
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { Theme.Palette.accent }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Capsule()
                    .fill(Theme.Palette.surfaceRaised)
                Capsule()
                    .strokeBorder(borderColor, lineWidth: borderWidth)
                if isRunning, !reduceMotion {
                    SubagentBeamOverlay()
                        .accessibilityHidden(true)
                }
                HStack(spacing: 2) {
                    Image(systemName: isRunning ? "person.2.fill" : "person.2")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(height: 12)
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .foregroundStyle(isRunning ? tint : Theme.Palette.textSecondary)
            }
            .frame(width: 44, height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("subagent-capsule")
        .accessibilityLabel(L10n.t("子代理"))
        .accessibilityValue("\(isRunning ? "running" : "idle"):\(count)")
    }

    private var borderColor: Color {
        isRunning && reduceMotion ? tint.opacity(0.65) : Theme.Palette.border
    }

    private var borderWidth: CGFloat {
        isRunning && reduceMotion ? 1.2 : 1
    }
}

/// Traveling accent beam along the capsule outline (B, "边框流光").
private struct SubagentBeamOverlay: View {
    var duration: Double = 1.6
    var span: Double = 0.26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: duration) / duration
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            ZStack {
                beam(shape: shape, progress: phase, color: Theme.Palette.accent.opacity(0.30), width: 4.5)
                    .blur(radius: 1.5)
                beam(shape: shape, progress: phase, color: Theme.Palette.accent, width: 1.8)
            }
        }
    }

    @ViewBuilder
    private func beam(shape: RoundedRectangle, progress: Double, color: Color, width: CGFloat) -> some View {
        let end = progress + span
        if end <= 1 {
            shape.trim(from: CGFloat(progress), to: CGFloat(end))
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
        } else {
            shape.trim(from: CGFloat(progress), to: 1)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
            shape.trim(from: 0, to: CGFloat(end - 1))
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }
}
