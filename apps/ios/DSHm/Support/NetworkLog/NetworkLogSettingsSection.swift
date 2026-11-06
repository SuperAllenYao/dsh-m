import SwiftUI

/// Settings page section for the always-on network log (design v1, screen ①).
///
/// Layout: `SectionLabel("网络日志")` + one card row + caption; the red error hint
/// sits below the caption. Copy and state machine follow the confirmed design and
/// DD-09 exactly:
/// - idle: row tappable, title "导出网络日志", sub "最近 72 小时的连接与重连记录"
/// - empty: row greyed out, sub "暂无网络日志记录", no chevron, tap does nothing
/// - generating: in-row spinner + "正在生成…", sub "正在打包最近 72 小时的记录",
///   repeated taps ignored
/// - sharing: archive built → system share sheet; cancel/finish discards the file
///   and returns to idle
/// - error: "生成失败，请重试。" below the row; row tappable again
///
/// Only this row talks to `NetworkLog`; the settings page stays unchanged otherwise.
struct NetworkLogSettingsSection: View {
    private enum ExportState: Equatable {
        case idle
        case empty
        case generating
        case sharing
        case error
    }

    @State private var state: ExportState = .idle
    @State private var shareURL: URL?
    @State private var isSharing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionLabel(text: "网络日志")
            exportCard
            Text("仅本机保存，72 小时后自动清理；不含会话内容，不上传。")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .accessibilityIdentifier("settings-netlog-caption")
            if state == .error {
                Text("生成失败，请重试。")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.danger)
                    .accessibilityIdentifier("settings-netlog-error")
            }
        }
        .task { await refreshAvailability() }
        .sheet(isPresented: $isSharing, onDismiss: finishSharing) {
            if let shareURL {
                ActivityView(items: [shareURL]) {
                    // Shared or cancelled: dismiss the wrapper, cleanup follows in
                    // `onDismiss`. Hop to main explicitly so the state change is
                    // never applied from a background callback.
                    DispatchQueue.main.async { isSharing = false }
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Row

    private var exportCard: some View {
        Button(action: startExport) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 26, height: 26)
                    .background(
                        Theme.Palette.accentSoft,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.inlineCode, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .accessibilityIdentifier("settings-netlog-title")
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .accessibilityIdentifier("settings-netlog-subtitle")
                }

                Spacer(minLength: 0)
                tail
            }
            .padding(.vertical, 13)
            .padding(.horizontal, Theme.Spacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(NetworkLogRowButtonStyle())
        .disabled(state == .empty || state == .generating)
        .opacity(state == .empty ? 0.45 : 1)
        .background(
            Theme.Palette.surface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .accessibilityIdentifier("settings-netlog-export")
    }

    @ViewBuilder
    private var tail: some View {
        switch state {
        case .empty:
            EmptyView()
        case .generating:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Theme.Palette.accent)
                .scaleEffect(0.8)
                .accessibilityIdentifier("settings-netlog-progress")
        default:
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private var title: String {
        state == .generating ? "正在生成…" : "导出网络日志"
    }

    private var subtitle: String {
        switch state {
        case .empty:
            return "暂无网络日志记录"
        case .generating:
            return "正在打包最近 72 小时的记录"
        default:
            return "最近 72 小时的连接与重连记录"
        }
    }

    // MARK: - Actions

    private func startExport() {
        guard state == .idle || state == .error else { return }
        state = .generating
        Task {
            do {
                let url = try await NetworkLog.exportZip()
                await MainActor.run {
                    shareURL = url
                    state = .sharing
                    isSharing = true
                }
            } catch {
                NSLog("[NetworkLog] export failed: \(error)")
                await MainActor.run { state = .error }
            }
        }
    }

    /// Runs when the share sheet is dismissed (shared, cancelled, or swiped away):
    /// delete the temporary archive and return the row to idle.
    private func finishSharing() {
        if let url = shareURL {
            NetworkLogExport.discard(url)
        }
        shareURL = nil
        state = .idle
        Task { await refreshAvailability() }
    }

    /// Background availability probe (DD-16): disables the row when the log is empty.
    @MainActor
    private func refreshAvailability() async {
        guard state == .idle || state == .empty else { return }
        let hasEvents = await Task.detached(priority: .utility) {
            NetworkLog.hasEvents()
        }.value
        let next: ExportState = hasEvents ? .idle : .empty
        if state != next { state = next }
    }
}

/// Row press feedback: a subtle raised surface behind the label, clipped to the card.
private struct NetworkLogRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Theme.Palette.surfaceRaised : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
            )
    }
}
