import SwiftUI

/// Two-tab background sheet shared by the subagent list and the session's
/// background jobs. The default tab follows the
/// content: both -> subagents, jobs-only -> jobs.
enum BackgroundTasksTab: String, Hashable {
    case subagents
    case jobs

    var title: String {
        switch self {
        case .subagents: return L10n.t("子代理列表")
        case .jobs: return L10n.t("后台任务")
        }
    }
}

struct BackgroundTasksSheet: View {
    var initialTab: BackgroundTasksTab
    var entries: [SubagentCatalogEntry]
    var runtimes: [String: SubagentRuntime]
    @ObservedObject var jobs: JobListModel
    var isConnected: Bool
    var killJob: (JobRow) async throws -> String?
    var onOpenSubagent: (SubagentCatalogEntry) -> Void

    @State private var tab: BackgroundTasksTab
    @State private var armedJobId: String?
    @State private var stoppingJobId: String?
    @State private var actionError: String?
    @State private var actionNotice: String?
    @State private var resetTask: Task<Void, Never>?

    init(
        initialTab: BackgroundTasksTab,
        entries: [SubagentCatalogEntry],
        runtimes: [String: SubagentRuntime],
        jobs: JobListModel,
        isConnected: Bool,
        killJob: @escaping (JobRow) async throws -> String?,
        onOpenSubagent: @escaping (SubagentCatalogEntry) -> Void
    ) {
        self.initialTab = initialTab
        self.entries = entries
        self.runtimes = runtimes
        self.jobs = jobs
        self.isConnected = isConnected
        self.killJob = killJob
        self.onOpenSubagent = onOpenSubagent
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle().fill(Theme.Palette.border).frame(height: 1)
            Group {
                switch tab {
                case .subagents:
                    SubagentListView(
                        entries: entries,
                        runtimes: runtimes,
                        showsHeader: false,
                        onSelect: onOpenSubagent
                    )
                case .jobs:
                    jobsList
                }
            }
        }
        .accessibilityIdentifier("background-tasks-sheet")
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach([BackgroundTasksTab.subagents, .jobs], id: \.self) { candidate in
                Button {
                    withAnimation(Theme.Motion.quick) { tab = candidate }
                } label: {
                    Text(candidate.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tab == candidate ? Theme.Palette.accent : Theme.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            tab == candidate ? Theme.Palette.accentSoft : Color.clear,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("background-tab-" + candidate.rawValue)
                .accessibilityAddTraits(tab == candidate ? [.isSelected] : [])
            }
        }
        .overlay(alignment: .center) {
 // verification (TC-30): a tap 1–2pt inside the 4pt gap
 // still selected a tab (system hit slop around the enlarged labels).
 // This no-op strip owns the gap, so the gap itself never switches.
            Color.clear
                .frame(width: 4)
                .contentShape(Rectangle())
                .onTapGesture { }
                .accessibilityHidden(true)
        }
        .padding(4)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm + 2, style: .continuous))
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.s)
    }

    @ViewBuilder
    private var jobsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if let actionError {
                    inlineError(actionError)
                }
                if let actionNotice {
                    inlineNotice(actionNotice)
                }
                if !isConnected {
                    EmptyStateView(
                        icon: "wifi.slash",
                        title: "连接已断开",
                        message: "重新连接后可查看后台任务。"
                    )
                    .accessibilityIdentifier("background-jobs-disconnected")
                } else {
                switch jobs.state {
                case .unavailable:
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "后台任务暂不可用",
                        message: "当前主机暂不支持后台任务列表。"
                    )
                    .accessibilityIdentifier("background-jobs-unavailable")
                case .idle, .loading:
                    if jobs.jobs.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView().tint(Theme.Palette.accent)
                            Spacer()
                        }
                        .padding(.top, Theme.Spacing.xl)
                    }
                case .available:
                    if jobs.jobs.isEmpty {
                        EmptyStateView(
                            icon: "terminal",
                            title: "暂无后台任务",
                            message: "本会话启动的后台命令会显示在这里。"
                        )
                        .accessibilityIdentifier("background-jobs-empty")
                    }
                }
                }
                ForEach(jobs.jobs) { job in
                    jobRow(job)
                }
            }
            .padding(Theme.Spacing.m)
            .measureSheetContentHeight()
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("background-jobs-list")
    }

    private func jobRow(_ job: JobRow) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Circle()
                .fill(job.status.color)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.label)
                    .font(Theme.Typography.captionMedium)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(job.status.localizedLabel)
                        .font(Theme.Typography.label)
                        .foregroundStyle(job.status.color)
                    Text(timeText(for: job))
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Spacing.xs)
            if job.status.isLive {
                stopButton(job)
            }
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .accessibilityIdentifier("background-job-\(job.id)")
    }

    private func stopButton(_ job: JobRow) -> some View {
        let armed = armedJobId == job.id
        let stopping = stoppingJobId == job.id
        return Button {
            stopTapped(job)
        } label: {
            Text(stopping ? L10n.t("正在停止") : (armed ? L10n.t("确认停止") : L10n.t("停止")))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(armed ? Theme.Palette.danger : Theme.Palette.textSecondary)
                .frame(width: 68, height: 36)
                .background(armed ? Theme.Palette.dangerMuted : Theme.Palette.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .strokeBorder(armed ? Theme.Palette.dangerBorder : Theme.Palette.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(stoppingJobId != nil || !isConnected)
        .accessibilityIdentifier("background-job-stop-\(job.id)")
    }

    private func inlineError(_ text: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.danger)
            Text(text)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.danger)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.s)
        .background(Theme.Palette.dangerMuted, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .accessibilityIdentifier("background-jobs-error")
    }

    private func inlineNotice(_ text: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(text)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.s)
        .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .accessibilityIdentifier("background-jobs-notice")
    }

    private func timeText(for job: JobRow) -> String {
        guard let started = job.startedAt else { return "" }
        let end = job.finishedAt ?? Int64(Date().timeIntervalSince1970 * 1000)
        let seconds = max(0, (end - started) / 1000)
        let minutes = seconds / 60
        let rest = seconds % 60
        let duration = minutes > 0
            ? L10n.f("%@分%@秒", String(minutes), String(rest))
            : L10n.f("%@秒", String(rest))
        if job.status.isLive {
            return L10n.f("已运行 %@", duration)
        }
        if let finished = job.finishedAt {
            let date = Date(timeIntervalSince1970: TimeInterval(finished) / 1000)
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return L10n.f("%@ 结束 · 耗时 %@", formatter.string(from: date), duration)
        }
        return L10n.f("耗时 %@", duration)
    }

    private func stopTapped(_ job: JobRow) {
        guard stoppingJobId == nil else { return }
        resetTask?.cancel()
        if armedJobId == job.id {
            armedJobId = nil
            actionError = nil
            stoppingJobId = job.id
            Task { @MainActor in
                do {
                    let outcome = try await killJob(job)
                    if outcome == "already-finished" {
                        actionNotice = L10n.t("任务已结束")
                        resetTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            guard !Task.isCancelled else { return }
                            actionNotice = nil
                        }
                    }
                } catch {
                    actionError = L10n.f("停止失败：%@", NetworkErrorInterpreter.message(for: error))
                }
                stoppingJobId = nil
            }
            return
        }
        armedJobId = job.id
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            armedJobId = nil
        }
    }
}
