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
 /// shared entry: subagent count + live (subagent or job) state.
    var backgroundCount: Int = 0
    var backgroundRunning: Bool = false
    var onPermissionTap: () -> Void
    var onModelTap: (() -> Void)? = nil
    var onBackgroundTap: (() -> Void)? = nil

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
                if let onBackgroundTap {
                    cellDivider
                    BackgroundEntryCapsule(
                        count: backgroundCount,
                        isRunning: backgroundRunning,
                        onTap: onBackgroundTap
                    )
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

/// shared entry for subagents + background jobs.
///
/// Fused icon (subagent top-left, terminal bottom-right, diagonal seam) inside
/// a 24pt-tall capsule; the width follows the measured content width so the
/// left/right padding is exactly half of the former fixed 52pt capsule padding
/// (0 digits ≈34pt, 1 digit ≈38pt, 2 digits ≈41pt). The count is the subagent
/// count (hidden when 0). While any subagent or job is live the existing
/// 26%-perimeter beam animates along the border; Reduce Motion degrades to a
/// static accent border.
struct BackgroundEntryCapsule: View {
    var count: Int
    var isRunning: Bool
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

 /// Measured natural width of the content row (icon + optional digits).
 /// Defaults to the one-digit width (15 + 3 + ≈6.3) so the first layout pass
 /// starts near the final width instead of a visibly wrong one.
    @State private var contentWidth: CGFloat = 24.3

    private var tint: Color { Theme.Palette.accent }

 /// Width formula (AC-12/AC-13). The pre-fix capsule was 52pt wide with the
 /// content centred, so keeping exactly half of that padding gives
 /// `(52 + w) / 2`; the 0/1/2-digit states all stay on this exact formula.
    static let referenceWidth: CGFloat = 52
 /// Floor for very wide counts: the halving formula would otherwise let the
 /// digits touch the 1pt stroke (only 3+ digits with `w > 44` are affected).
    static let minSidePadding: CGFloat = 4

    static func width(contentWidth: CGFloat) -> CGFloat {
        let halvedPadding = (referenceWidth + contentWidth) / 2
        return max(halvedPadding, contentWidth + minSidePadding * 2)
    }

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
                HStack(spacing: 3) {
                    FusedBackgroundIcon(
                        size: 15,
                        color: isRunning ? tint : Theme.Palette.textSecondary
                    )
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .foregroundStyle(isRunning ? tint : Theme.Palette.textSecondary)
                    }
                }
 // fixedSize keeps the reported width at the content's natural
 // size (never compressed by the capsule's current width), so a
 // wide count can't get the measurement stuck too small.
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { measured in
 // 未完成布局时可能上报 0，不能把胶囊宽度带偏。
                    guard measured > 0 else { return }
                    if measured != contentWidth {
                        contentWidth = measured
                    }
                    Self.probe(measured: measured, count: count)
                }
            }
            .frame(width: Self.width(contentWidth: contentWidth), height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("background-entry")
        .accessibilityLabel(L10n.t("后台任务"))
        .accessibilityValue("\(isRunning ? "running" : "idle"):\(count)")
    }

 /// 探针（设计 §7.1）：`DSHM_CAPSULE_PROBE=1` 时输出实测内容宽与胶囊宽，
 /// 验证段据此对照宽度公式；非 DEBUG 或未开启时零开销。
    private static func probe(measured: CGFloat, count: Int) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["DSHM_CAPSULE_PROBE"] == "1" else { return }
        NSLog("[CAPSULE] content=%.2f width=%.2f count=%d",
              measured, width(contentWidth: measured), count)
        #endif
    }

    private var borderColor: Color {
        isRunning && reduceMotion ? tint.opacity(0.65) : Theme.Palette.border
    }

    private var borderWidth: CGFloat {
        isRunning && reduceMotion ? 1.2 : 1
    }
}

/// Fused "subagent + terminal" icon approved on: both glyphs are
/// authored in the same 24-unit box, each clipped by the square's diagonal
/// (seam endpoints (3.4,20.4)-(19.4,4.5)); glyph stroke 1.25, seam 1.1.
struct FusedBackgroundIcon: View {
    var size: CGFloat = 15
    var color: Color

    private var glyphStroke: StrokeStyle { StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round) }

    var body: some View {
        ZStack {
            subagent
                .clipShape(FusedTopLeftHalf())
            terminal
                .clipShape(FusedBottomRightHalf())
            Path { path in
                path.move(to: CGPoint(x: 3.4, y: 20.4))
                path.addLine(to: CGPoint(x: 19.4, y: 4.5))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        }
        .frame(width: 24, height: 24)
        .scaleEffect(size / 24)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var subagent: some View {
        ZStack {
            Path(ellipseIn: CGRect(x: 5.3, y: 4.5, width: 6.2, height: 6.2))
                .stroke(color, style: glyphStroke)
            Path { path in
                path.addArc(
                    center: CGPoint(x: 8.9, y: 17.2),
                    radius: 5.5,
                    startAngle: .degrees(180),
                    endAngle: .degrees(0),
                    clockwise: false
                )
            }
            .stroke(color, style: glyphStroke)
            Path(ellipseIn: CGRect(x: 14.1, y: 8.4, width: 3.6, height: 3.6))
                .stroke(color, style: glyphStroke)
        }
    }

    private var terminal: some View {
        ZStack {
            Path(roundedRect: CGRect(x: 6.6, y: 12.2, width: 12.8, height: 8.2), cornerRadius: 2)
                .stroke(color, style: glyphStroke)
            Path { path in
                path.move(to: CGPoint(x: 9.9, y: 15.2))
                path.addLine(to: CGPoint(x: 12.3, y: 17))
                path.addLine(to: CGPoint(x: 9.9, y: 18.8))
            }
            .stroke(color, style: glyphStroke)
            Path { path in
                path.move(to: CGPoint(x: 14.6, y: 18.8))
                path.addLine(to: CGPoint(x: 17.4, y: 18.8))
            }
            .stroke(color, style: glyphStroke)
        }
    }
}

private struct FusedTopLeftHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct FusedBottomRightHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
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
