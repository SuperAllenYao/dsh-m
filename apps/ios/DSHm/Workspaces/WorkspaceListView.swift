import Combine
import SwiftUI

struct WorkspaceListView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var viewModel = WorkspaceViewModel()
    @State private var showConnectionMenu = false
    @State private var didAutoOpen = false
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Theme.Spacing.pageInset)
                .padding(.top, Theme.Spacing.xs)

            if viewModel.loadedFromCache && (viewModel.isRefreshing || viewModel.cacheIsStale) {
                cacheStatusBanner
                    .padding(.horizontal, Theme.Spacing.pageInset)
                    .padding(.bottom, Theme.Spacing.s)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !app.link.phase.isConnected {
                connectionBanner
                    .padding(.horizontal, Theme.Spacing.pageInset)
                    .padding(.bottom, Theme.Spacing.s)
            }
        }
        .background(Theme.Palette.background.ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(app)
        }
        .task {
            // task-2 (reconnect < 1s): t0 = page enter. Cancels a pending backoff
            // wait and invalidates a stale (network-changed) mux before the view
            // model asks for the snapshot, so the list request overlaps the mux
            // handshake instead of queueing behind it.
            app.link.handlePageEnter()
            viewModel.attach(link: app.link)
            viewModel.start()
        }
        .onDisappear {
            // Leaving the list: stop consuming the workspace stream (protocol §3.13).
            viewModel.stop()
        }
        .refreshable {
            await viewModel.refresh()
        }
        .onChange(of: viewModel.sessionsSnapshotVersion) { _ in
            // The FULL session list (including subagent/blank/archived/ungrouped
            // rows) feeds deep-link address resolution; display is filtered by the
            // registry + desktop visibility rules.
            app.updateKnownSessions(viewModel.allSessions)
        }
        .onChange(of: viewModel.groupsVersion) { _ in
            autoOpenFirstSessionIfNeeded()
        }
        .onChange(of: app.link.generation) { generation in
            viewModel.handleGenerationChange(generation)
        }
        .onChange(of: app.link.phase) { _ in
            viewModel.handleConnectionChange()
            autoOpenFirstSessionIfNeeded()
        }
        .onReceive(app.$silentPushRefreshVersion.dropFirst()) { _ in
            // M4 §4: a silent push passed AppModel's ≥2s throttle while the list
            // is on screen; reload the registry + session snapshot so the list is
            // already fresh when the user opens the app.
            Task { await viewModel.refresh() }
        }
        .overlay(alignment: .topLeading) {
            VStack(spacing: 0) {
                startupMetricsElement
                prewarmMetricsElement
                connectMetricsElement
                reconnectMetricsElement
            }
        }
    }

    /// M2b-2b E2E-gated in-app startup metrics (invisible; read by `M2ALiveUITests`
    /// and logged as `[M2A-LIVE] startup metrics: cacheMs=..;firstFrameMs=..;networkMs=..`).
    @ViewBuilder
    private var startupMetricsElement: some View {
        if let metrics = viewModel.startupMetricsValue {
            Text("startup-metrics")
                .font(.system(size: 1))
                .frame(width: 2, height: 2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("startup-metrics")
                .accessibilityLabel(metrics)
                .accessibilityValue(metrics)
        }
    }

    /// 体验收尾 E2E-gated detail-prewarm diagnostics (invisible; logged by
    /// `M2ALiveUITests` as `[M2A-LIVE] prewarm metrics: starts=..;top=..;saved=..`).
    @ViewBuilder
    private var prewarmMetricsElement: some View {
        if let metrics = viewModel.prewarmMetricsValue {
            Text("prewarm-metrics")
                .font(.system(size: 1))
                .frame(width: 2, height: 2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("prewarm-metrics")
                .accessibilityLabel(metrics)
                .accessibilityValue(metrics)
        }
    }

    /// P0 E2E-gated connection bring-up segmentation (invisible; logged by
    /// `M2ALiveUITests` as `[M2A-LIVE] connect metrics: connectMs=..;...`).
    @ViewBuilder
    private var connectMetricsElement: some View {
        if let metrics = app.link.connectionMetricsValue {
            Text("connect-metrics")
                .font(.system(size: 1))
                .frame(width: 2, height: 2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("connect-metrics")
                .accessibilityLabel(metrics)
                .accessibilityValue(metrics)
        }
    }

    /// task-2 E2E-gated reconnect-chain summary (`totalMs=..;pageEnterMs=..;...`,
    /// handoff §2.3(6)). Hidden leaf element, same pattern as `connect-metrics`.
    @ViewBuilder
    private var reconnectMetricsElement: some View {
        if let metrics = app.link.reconnectMetricsValue {
            Text("reconnect-metrics")
                .font(.system(size: 1))
                .frame(width: 2, height: 2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("reconnect-metrics")
                .accessibilityLabel(metrics)
                .accessibilityValue(metrics)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                BrandMark()
                Spacer()
                ConnectionStatusPill(phase: app.link.phase, detail: app.link.credentials?.originURL?.host)
                Menu {
                    Button {
                        showSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    Button {
                        app.link.reconnectNow()
                    } label: {
                        Label("重新连接", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        app.link.disconnect(clearCredentials: false)
                    } label: {
                        Label("断开连接", systemImage: "wifi.slash")
                    }
                    Button(role: .destructive) {
                        app.startOverPairing()
                    } label: {
                        Label("清除配对并重新配对", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Theme.Palette.surface, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.Palette.border, lineWidth: 1))
                }
                .accessibilityIdentifier("workspace-menu")
            }
            .padding(.top, Theme.Spacing.xs)

            ScreenTitle(title: "工作区", subtitle: subtitle)
                .accessibilityIdentifier("workspace-title")
        }
        .padding(.bottom, Theme.Spacing.m)
    }

    private var subtitle: String {
        if let detail = app.link.statusDetail.isEmpty ? nil : app.link.statusDetail, !app.link.phase.isConnected {
            return detail
        }
        // 1:1 with the desktop sidebar: registered workspaces (even empty ones) and
        // their visible sessions only — no ungrouped bucket on the phone.
        let summary = viewModel.groups.isEmpty
            ? L10n.t("暂无会话")
            : L10n.f("%lld 个工作区 · %lld 个会话", viewModel.groups.count, viewModel.sessionCount)
        // M2b-2: the first paint came from disk; say so while the network refresh
        // runs (or when the snapshot is past the 24h display TTL).
        guard viewModel.loadedFromCache else { return summary }
        if viewModel.isRefreshing { return L10n.f("%@ · 本地缓存", summary) }
        if viewModel.cacheIsStale { return L10n.f("%@ · 缓存已过期", summary) }
        return summary
    }

    /// M2b-2: cache-first paint indicator (a fresh network list hides it).
    private var cacheStatusBanner: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if viewModel.isRefreshing {
                ProgressView()
                    .tint(Theme.Palette.accent)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.Palette.warning)
            }
            Text(L10n.t(viewModel.isRefreshing ? "本地缓存 · 正在刷新…" : "本地缓存 · 已超过 24 小时"))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .accessibilityIdentifier("workspace-cache-status")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            VStack {
                ProgressView().tint(Theme.Palette.accent)
                Text("正在加载会话…")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.groups.isEmpty {
            ScrollView {
                VStack(spacing: Theme.Spacing.m) {
                    if let errorText = viewModel.errorText {
                        InlineErrorView(message: errorText) {
                            Task { await viewModel.refresh() }
                        }
                    }
                    EmptyStateView(
                        icon: "square.stack.3d.up.slash",
                        title: "还没有会话",
                        message: "在 Mac 上的 DSH 创建一个会话后，这里会出现会话列表。"
                    )
                    .accessibilityIdentifier("workspace-empty")
                }
                .padding(.horizontal, Theme.Spacing.pageInset)
                .padding(.top, Theme.Spacing.xl)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    if let errorText = viewModel.errorText {
                        InlineErrorView(message: errorText) {
                            Task { await viewModel.refresh() }
                        }
                        .padding(.horizontal, Theme.Spacing.pageInset)
                    }
                    ForEach(Array(viewModel.groups.enumerated()), id: \.element.id) { index, group in
                        workspaceSection(group, index: index)
                    }
                }
                .padding(.horizontal, Theme.Spacing.pageInset)
                .padding(.bottom, Theme.Spacing.xxl)
            }
        }
    }

    private func workspaceSection(_ group: WorkspaceViewModel.WorkspaceGroup, index: Int) -> some View {
        let collapsed = viewModel.isCollapsed(group.path)
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            // The whole header row toggles the group; collapsed groups show their
            // session count so a "missing" workspace still reads as non-empty.
            Button {
                withAnimation(Theme.Motion.quick) {
                    viewModel.toggleCollapsed(group.path)
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text(group.displayName)
                        .font(Theme.Typography.bodyMedium)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Text(group.path)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Theme.Spacing.xs)
                    if collapsed {
                        Text(L10n.f("%lld 个会话", group.sessions.count))
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace-toggle-\(index)")
            .accessibilityValue(collapsed ? "collapsed" : "expanded")

            if !collapsed {
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { _, session in
                    let cardIndex = globalIndex(of: session)
                    SessionCardView(
                        session: session,
                        pendingApprovals: viewModel.pendingApprovalCount(sessionId: session.sessionId, link: app.link),
                        isConnected: app.link.phase.isConnected
                    ) {
                        app.openSession(session.followAddress)
                    }
                    .accessibilityIdentifier("session-card-\(cardIndex)")
                    .onAppear {
                        // M2b-2b: the first list card on screen marks the in-app first
                        // frame. Any card may be the first visibly rendered one: the
                        // first workspace group can be collapsed (persisted collapse
                        // state) or the global card order can differ per host, so
                        // gating on `cardIndex == 0` silently lost the metric.
                        // `markFirstFrameVisible()` is idempotent.
                        viewModel.markFirstFrameVisible()
                    }
                }
            }
        }
    }

    /// E2E scaffolding (env-gated): DSHM_OPEN_FIRST_SESSION=1 opens the first
    /// visible session once the workspace stream + session snapshot are ready.
    private func autoOpenFirstSessionIfNeeded() {
        guard ProcessInfo.processInfo.environment["DSHM_OPEN_FIRST_SESSION"] == "1", !didAutoOpen,
              app.link.phase.isConnected,
              let first = viewModel.groups.first?.sessions.first else { return }
        didAutoOpen = true
        app.openSession(first.followAddress)
    }

    private func globalIndex(of session: SessionListItem) -> Int {
        var index = 0
        for group in viewModel.groups {
            for item in group.sessions {
                if item.id == session.id { return index }
                index += 1
            }
        }
        return 0
    }

    /// One-line connection state; the specific failure reason wins.
    private var connectionBannerText: String {
        if !app.link.statusDetail.isEmpty, !app.link.phase.isConnected {
            return app.link.statusDetail
        }
        return app.link.phase.isBusy ? L10n.t("正在连接 Mac…") : L10n.t("连接已断开")
    }

    private var connectionBanner: some View {
        HStack(spacing: Theme.Spacing.xs) {
            StatusDot(color: app.link.phase.isBusy ? Theme.Palette.warning : Theme.Palette.danger, size: 6, pulsing: app.link.phase.isBusy)
            // Cross-network requirement (handoff §2.3): never only 「重连中」. The
            // last failed round's classified one-line reason (desktop plugin not
            // ready / network unreachable / gateway rejected) wins over the generic
            // busy label.
            Text(connectionBannerText)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("workspace-connection-reason")
            Spacer()
            if app.link.phase.isBusy {
                ProgressView().tint(Theme.Palette.accent).scaleEffect(0.7)
            } else {
                Button("重连") { app.link.reconnectNow() }
                    .font(Theme.Typography.captionMedium)
                    .foregroundStyle(Theme.Palette.accent)
                    .accessibilityIdentifier("workspace-reconnect")
            }
        }
        .padding(Theme.Spacing.s)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Palette.border, lineWidth: 1))
    }
}

/// One session card (v5 02): title / lastPromptAt / running dot + text / approval badge.
struct SessionCardView: View {
    var session: SessionListItem
    var pendingApprovals: Int
    var isConnected: Bool
    var onTap: () -> Void

    /// v5.4 status: waiting-for-answer > in-progress > not-started > idle; offline
    /// overrides while the link is down. Approval counts come from the live
    /// `$events` list, user questions from the `session/list` projections.
    private var status: SessionListStatus {
        SessionListStatusResolver.status(
            for: session,
            pendingApprovals: pendingApprovals,
            isConnected: isConnected
        )
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text(session.title?.isEmpty == false
                         ? (session.title ?? "")
                         : (session.blank == true ? L10n.t("新会话") : L10n.t("未命名会话")))
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Spacing.xs)
                    Text(DisplayFormat.relativeTime(session.lastPromptAt ?? session.updatedAt))
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                HStack(spacing: Theme.Spacing.xs) {
                    StatusDot(color: status.color, size: 6, pulsing: status.isPulsing)
                    Text(status.localizedLabel)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(status.color)
                    Spacer(minLength: 0)
                }
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(
                        status.emphasizedBorderColor ?? Theme.Palette.border,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    WorkspaceListView().environmentObject(AppModel())
}
