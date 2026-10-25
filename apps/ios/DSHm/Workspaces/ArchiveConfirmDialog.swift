import SwiftUI

/// R3 archive confirmation (design 3.2 / m4-archive-dialogs): one configurable
/// alert with two states sharing the same skeleton (320pt wide, r20, raised
/// surface + strong border, dimmed backdrop):
/// - idle: title 归档会话？, three explanation lines (name highlighted),
/// primary button 归档 (warning);
/// - running: title 会话正在运行任务, a 44pt status badge (accent-soft circle
/// with the running dot), explanation adds the interrupt warning,
/// primary button 停止任务并归档 (warning).
struct ArchiveConfirmDialog: View {
    var sessionTitle: String
    var isRunning: Bool
    var onCancel: () -> Void
    var onConfirm: (_ stopActivity: Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Theme.Spacing.s) {
                if isRunning { statusBadge }
                Text(isRunning ? L10n.t("会话正在运行任务") : L10n.t("归档会话？"))
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                explanation
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.xl)
            Divider().overlay(Theme.Palette.borderStrong)
            HStack(spacing: 0) {
                Button(action: onCancel) {
                    Text(L10n.t("取消"))
                        .font(Theme.Typography.button.weight(.regular))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("archive-confirm-cancel")
                Rectangle().fill(Theme.Palette.borderStrong).frame(width: 1)
                Button {
                    onConfirm(isRunning)
                } label: {
                    Text(isRunning ? L10n.t("停止任务并归档") : L10n.t("归档"))
                        .font(Theme.Typography.button)
                        .foregroundStyle(Theme.Palette.warning)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("archive-confirm-action")
            }
            .frame(height: 44)
        }
        .frame(width: 320)
        .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .strokeBorder(Theme.Palette.borderStrong, lineWidth: 1)
        )
    }

 /// m4 ②: 44pt circle, accent-soft fill, the list's running dot semantics
 /// (icon states the status, the yellow button states the risk).
    private var statusBadge: some View {
        ZStack {
            Circle().fill(Theme.Palette.accentSoft)
            StatusDot(color: Theme.Palette.accent, size: 14, pulsing: true)
        }
        .frame(width: 44, height: 44)
    }

    private var explanation: Text {
        let name = sessionTitle.isEmpty ? L10n.t("未命名会话") : sessionTitle
        if isRunning {
            return Text(L10n.t("未完成的步骤将中断；归档后可在 Mac 桌面端恢复。"))
        }
        return Text(name).foregroundStyle(Theme.Palette.textPrimary)
            + Text(L10n.t(" 将从列表移除，"))
            + Text(L10n.t("并同步归档到 Mac 桌面端。"))
            + Text(L10n.t("可在桌面端恢复。"))
    }
}

/// Full-screen scrim hosting the dialog (design m4: backdrop dimmed to 55%).
struct ArchiveConfirmOverlay: View {
    var dialog: ArchiveConfirmDialog

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture { }
            dialog
        }
        .transition(.opacity)
    }
}
