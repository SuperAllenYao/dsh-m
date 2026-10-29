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

            if viewModel.loadedFromCache && (viewModel.showCacheRefreshBanner || viewModel.cacheIsStale) {
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
        .overlay {
 // R3 (m4): the archive confirmation is the only readable layer
 // while pending (55% scrim blocks interaction behind it).
            if let pending = pendingArchive {
                ArchiveConfirmOverlay(
                    dialog: ArchiveConfirmDialog(
                        sessionTitle: pending.title,
                        isRunning: pending.isRunning,
                        onCancel: { pendingArchive = nil },
                        onConfirm: { stop in confirmArchive(pending, stopActivity: stop) }
                    )
                )
                .zIndex(10)
            }
        }
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
 // v6：进列表先叠一次 `$events` 实时运行态（详情页里发生的变化，
 // 返回列表时立刻生效，不等下一次 session/list）。
            viewModel.applyLiveSessionRunning()
        }
        .onAppear {
 // R2 (design 2.3/2.4): returning from a session page re-reads the
 // draft store — the blank card appears with its preview, or closes
 // out when the draft is gone (2.3 b).
            viewModel.refreshBlankCardState()
            viewModel.applyLiveSessionRunning()
 // Edge-swipe back has no back-button hook: its flush runs in the
 // detail's onDisappear, which lands ~580 ms after this onAppear
 // (probe-measured). Refresh once more after the pop settles so the
 // draft card appears instead of staying hidden.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                viewModel.refreshBlankCardState()
            }
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
 // R3: a list refresh closes any revealed swipe actions.
            viewModel.swipedSessionId = nil
            autoOpenFirstSessionIfNeeded()
        }
        .onScrollPhaseChange { _, phase in
 // R3 (design 3.2): scrolling closes the revealed action block.
            if phase.isScrolling, viewModel.swipedSessionId != nil {
                viewModel.swipedSessionId = nil
            }
        }
        .onTapGesture {
 // R3: tapping outside any card (group headers, paddings) closes the
 // revealed actions; button taps win the hit-test inside cards.
            if viewModel.swipedSessionId != nil { viewModel.swipedSessionId = nil }
        }
        .onChange(of: app.link.generation) { generation in
            viewModel.handleGenerationChange(generation)
        }
        .onChange(of: app.link.phase) { _ in
            viewModel.handleConnectionChange()
            viewModel.applyLiveSessionRunning()
            autoOpenFirstSessionIfNeeded()
        }
        .onChange(of: app.link.liveSessionStatusRevision) { _ in
 // v6：`$events` 的 api-session/status emit 实时刷新卡片状态（进行中/空闲），
 // 不用等下一次 session/list；从会话详情返回列表时也靠这里立刻收敛。
            viewModel.applyLiveSessionRunning()
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
            HStack(spacing: Theme.Spacing.xs) {
                BrandMark(showWordmark: false)
 // R1 (design m1-header): name + version stack into a
 // 30pt lockup matching the logo height exactly — 16pt name
 // tucked to the top edge, 11pt mono version to the bottom.
                ZStack(alignment: .leading) {
                    Text("DSH·m")
                        .font(Theme.Typography.workspaceName)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Text(appVersionText)
                        .font(Theme.Typography.monoSmallMedium)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .accessibilityIdentifier("app-version")
                }
                .frame(height: 30)
                Spacer()
 // IP/host detail removed by requirement — the pill
 // shows only the dot + phase label (在线 etc.).
                ConnectionStatusPill(phase: app.link.phase)
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

            ScreenTitle(title: "工作区", subtitle: subtitle, subtitleInline: true)
                .accessibilityIdentifier("workspace-title")
        }
        .padding(.bottom, Theme.Spacing.m)
    }

 /// R2 (design 2.2): "+" creates a session in this workspace and pushes the
 /// session page right away. Failures surface
 /// through the list's inline error banner (viewModel.errorText) — including
 /// the old-plugin 404, which reads as the upgrade hint.
 /// R3: one pending archive confirmation (m4 two-state dialog).
    private struct PendingArchive: Identifiable, Equatable {
        let id = UUID()
        let sessionId: String
        let title: String
        var isRunning: Bool
    }

    @State private var pendingArchive: PendingArchive?

 /// R3 (design 3.2): pin has no confirmation - optimistic toggle straight
 /// from the swipe block. Offline taps surface the disconnect hint and send
 /// nothing (never queue, never fail silently).
    private func handlePinToggle(_ session: SessionListItem) {
        guard app.link.phase.isConnected else {
            viewModel.showInlineError(L10n.t("连接已断开"))
            return
        }
        let sessionId = session.sessionId
        Task { @MainActor in
            await viewModel.togglePin(sessionId: sessionId, link: app.link)
        }
    }

 /// R3: archive always confirms first (m4); the running state is known from
 /// the list row, the 409 path re-opens the dialog in running mode.
    #if DEBUG
 /// E2E (DSHM_E2E + DSHM_E2E_STABLE_CARD_IDS=1): sessionId-keyed card ids so
 /// write-capable tests can only address the session they created. Every
 /// other mode keeps the positional ids the read-only suites rely on.
    private static func e2eCardId(session: SessionListItem, index: Int) -> String {
        E2EScaffolding.stableCardIds ? "session-card-\(session.sessionId)" : "session-card-\(index)"
    }
    #else
    private static func e2eCardId(session: SessionListItem, index: Int) -> String {
        "session-card-\(index)"
    }
    #endif

    private func handleArchiveRequest(_ session: SessionListItem) {
        guard app.link.phase.isConnected else {
            viewModel.showInlineError(L10n.t("连接已断开"))
            return
        }
        pendingArchive = PendingArchive(
            sessionId: session.sessionId,
            title: session.title ?? "",
            isRunning: session.isRunning
        )
    }

    private func confirmArchive(_ pending: PendingArchive, stopActivity: Bool) {
        pendingArchive = nil
        let sessionId = pending.sessionId
        Task { @MainActor in
            do {
                try await viewModel.archiveSession(
                    sessionId: sessionId, stopActivity: stopActivity, link: app.link
                )
            } catch {
                if case LinkError.remote(let remote) = error,
                   remote.code == "archive/session-active" {
 // The session started running between the list read and the
 // call: swap the idle dialog for the running one (m4 state 2).
                    pendingArchive = PendingArchive(
                        sessionId: sessionId,
                        title: pending.title,
                        isRunning: true
                    )
                } else {
                    viewModel.showInlineError(NetworkErrorInterpreter.message(for: error))
                }
            }
        }
    }

    private func createSession(in group: WorkspaceViewModel.WorkspaceGroup) {
        guard viewModel.creatingWorkspaceId == nil else { return }
        Task { @MainActor in
            if let sessionId = await viewModel.createSession(inWorkspace: group.workspaceId, link: app.link) {
                app.openSession(.session(sessionId: sessionId))
            }
        }
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
 // 冷启动 <1s：只有「刷新真正变慢」（>800ms，见
 // WorkspaceViewModel.cacheRefreshBannerDelayMs）才提示本地缓存；正常的
 // 亚秒级刷新不再出现「· 本地缓存」字样。
        if viewModel.showCacheRefreshBanner { return L10n.f("%@ · 本地缓存", summary) }
        if viewModel.cacheIsStale { return L10n.f("%@ · 缓存已过期", summary) }
        return summary
    }

 /// App version shown next to the wordmark: marketing version + build number,
 /// e.g. `v2.8.0 (8)` (from `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`).
    private var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

 /// M2b-2: cache-first paint indicator (a fresh network list hides it). The
 /// refreshing variant is delayed (`showCacheRefreshBanner`) so a <1s refresh
 /// never flashes 「本地缓存 · 正在刷新…」.
    private var cacheStatusBanner: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if viewModel.showCacheRefreshBanner {
                ProgressView()
                    .tint(Theme.Palette.accent)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.Palette.warning)
            }
            Text(L10n.t(viewModel.showCacheRefreshBanner ? "本地缓存 · 正在刷新…" : "本地缓存 · 已超过 24 小时"))
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
 // Step4R: the session list rides a native
 // List so the swipe actions get system-grade reveal/snap/dismisson-
 // tap-outside behaviour. Cards keep their exact custom look through
 // row insets/background/separator; pull-to-refresh and every a11y
 // identifier survive unchanged.
            List {
                if let errorText = viewModel.errorText {
                    InlineErrorView(message: errorText) {
                        Task { await viewModel.refresh() }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.pageInset, bottom: Theme.Spacing.s, trailing: Theme.Spacing.pageInset))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowSeparatorTint(.clear)
                    .accessibilityIdentifier("workspace-list-error")
                }
                if !viewModel.pinnedSessions.isEmpty {
 // No section header: the compact cards sit
 // directly under the 工作区 title, above the first workspace.
                    Section {
                        ForEach(Array(viewModel.pinnedSessions.enumerated()), id: \.element.id) { index, session in
                            pinnedRow(session, index: index)
                        }
                    }
                }
                ForEach(Array(viewModel.groups.enumerated()), id: \.element.id) { index, group in
                    workspaceSection(group, index: index)
                }
 // Bottom breathing room: a tail row inside the list (a
 // .contentMargins modifier here would propagate through the
 // NavigationStack into the pushed session detail).
                Color.clear
                    .frame(height: Theme.Spacing.xxl)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowSeparatorTint(.clear)
                    .accessibilityHidden(true)
            }
            .listStyle(.plain)
            .listSectionSpacing(Theme.Spacing.l)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("workspace-session-list")
        }
    }

 /// One pinned row above the workspace groups: compact 44pt card, same swipe
 /// actions as a normal row (pin toggle / archive). No section header.
    private func pinnedRow(_ session: SessionListItem, index: Int) -> some View {
        let pinned = viewModel.followState.pinnedSessionIds.contains(session.sessionId)
        return SessionCardView(
            session: session,
            pendingApprovals: viewModel.pendingApprovalCount(sessionId: session.sessionId, link: app.link),
            isConnected: app.link.phase.isConnected,
            draftPreview: nil,
            isPinned: pinned,
            compact: true
        ) {
            DetailMetrics.beginTap()
            app.openSession(session.followAddress)
        }
        .equatable()
        .accessibilityIdentifier("pinned-session-card-\(index)")
        .listRowInsets(EdgeInsets(top: 6, leading: Theme.Spacing.pageInset, bottom: 6, trailing: Theme.Spacing.pageInset))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowSeparatorTint(.clear)
        .onAppear {
 // Same first-frame contract as `sessionRow`: when every visible
 // session is pinned (or all groups are collapsed) this is the only
 // row that reaches the screen.
            viewModel.markFirstFrameVisible()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                handlePinToggle(session)
            } label: {
                Image(systemName: pinned ? "pin.slash" : "pin")
            }
            .tint(pinned ? Theme.Palette.borderStrong : Theme.Palette.accent)
            .accessibilityLabel(pinned ? L10n.t("取消置顶") : L10n.t("置顶"))
            .accessibilityIdentifier("pinned-swipe-pin-" + session.sessionId)
            Button {
                handleArchiveRequest(session)
            } label: {
                Image(systemName: "archivebox")
            }
            .tint(Theme.Palette.warning)
            .accessibilityLabel(L10n.t("归档"))
            .accessibilityIdentifier("pinned-swipe-archive-" + session.sessionId)
        }
    }

    private func workspaceSection(_ group: WorkspaceViewModel.WorkspaceGroup, index: Int) -> some View {
        let collapsed = viewModel.isCollapsed(group.path)
        return Section {
            if !collapsed {
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { _, session in
                    sessionRow(session)
                }
            }
        } header: {
            groupHeader(group, index: index, collapsed: collapsed)
        }
    }

 /// The whole header row toggles the group; collapsed groups show their
 /// session count so a "missing" workspace still reads as non-empty.
    private func groupHeader(_ group: WorkspaceViewModel.WorkspaceGroup, index: Int, collapsed: Bool) -> some View {
        Button {
                withAnimation(Theme.Motion.quick) {
                    viewModel.toggleCollapsed(group.path)
                }
            } label: {
                HStack(alignment: .center, spacing: Theme.Spacing.xs) {
 // open-folder glyph + accent color when expanded
 // (SF Symbols has no open-folder symbol; see WorkspaceFolderIcon).
                    WorkspaceFolderIcon(expanded: !collapsed)
 // name enlarged to 16pt and path moved onto its own
 // second line instead of sharing the name's line.
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
 // M2 rev2 (m2-groupheader-v2): the name line always
 // carries the session count - a dot separator in
 // tertiary and the bare number in secondary, baseline-
 // aligned; the collapsed-state count text is gone.
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                            Text(group.displayName)
                                .font(Theme.Typography.workspaceName)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .accessibilityIdentifier("workspace-name-\(index)")
                            Text("·")
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Palette.textTertiary)
                            Text("\(group.sessions.count)")
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .accessibilityIdentifier("workspace-count-\(index)")
                        }
                        Text(group.path)
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("workspace-path-\(index)")
                    }
                    Spacer(minLength: Theme.Spacing.xs)
 // R2 (design 2.2, M2): per-group "+" mints a session in this
 // workspace. 30x30 r10 accent block, 44pt hit area; a 1pt
 // divider separates it from the group's collapse chevron.
                    Button {
                        createSession(in: group)
                    } label: {
                        Group {
                            if viewModel.creatingWorkspaceId == group.workspaceId {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(Theme.Palette.accent)
                            } else {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                        }
                        .frame(width: 30, height: 30)
                        .background(Theme.Palette.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Palette.accentBorder, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .frame(width: 44, height: 44)
                    .buttonStyle(.plain)
                    .disabled(viewModel.creatingWorkspaceId != nil)
                    .accessibilityIdentifier("workspace-new-session-\(index)")
 // M2 rev2: the plus button is the ONLY trailing accessory -
 // no chevron, no hairline, no collapsed count text.
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace-toggle-\(index)")
            .accessibilityValue(collapsed ? "collapsed" : "expanded")
            .padding(.horizontal, Theme.Spacing.pageInset)
            .padding(.bottom, Theme.Spacing.xxs)
 // Plain-list section headers carry their own system insets; zero
 // them so the header width matches the cards exactly.
            .listRowInsets(EdgeInsets())
 // No separator above/below a workspace header.
            .listRowSeparator(.hidden)
            .listRowSeparatorTint(.clear)
    }

 /// One session row inside the native List: the equatable card plus the
 /// system swipe actions (Step4R). Pin toggles straight away (no
 /// confirmation, optimistic + reconcile); archive always confirms first.
    private func sessionRow(_ session: SessionListItem) -> some View {
        let cardIndex = globalIndex(of: session)
        let pinned = viewModel.followState.pinnedSessionIds.contains(session.sessionId)
 // R3 (design 3.2): the swipeable wrapper owns the left-swipe
 // reveal; the equatable card stays the content.
        return SessionCardView(
                        session: session,
                        pendingApprovals: viewModel.pendingApprovalCount(sessionId: session.sessionId, link: app.link),
                        isConnected: app.link.phase.isConnected,
                        draftPreview: session.blank == true
                            ? viewModel.phoneCreatedDraftPreviews[session.sessionId]
                            : nil,
                        isPinned: pinned
        ) {
 // Step4R: system swipeActions handle reveal/close;
 // the card tap only opens the session now.
            if true {
 // t0 for the user-perceived detail latency (tap ->
 // first content). The route switch must stay synchronous and
 // cheap; the detail's own work happens after this mark.
                            DetailMetrics.beginTap()
                            app.openSession(session.followAddress)
                        }
                    }
        .equatable()
        .accessibilityIdentifier(Self.e2eCardId(session: session, index: cardIndex))
        .overlay(alignment: .topLeading) {
 // E2E-only marker (runtime-gated, invisible, 2pt): rendered exactly
 // on the row whose sessionId matches the most recent phone-side
 // create RPC. Tests read its value and address cards/actions by id.
            if app.isE2EMode, session.sessionId == viewModel.e2eCreatedSessionId {
                Text("probe")
                    .font(.system(size: 1))
                    .frame(width: 2, height: 2)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("e2e-created-session")
                    .accessibilityLabel(viewModel.e2eCreatedSessionId)
                    .accessibilityValue(viewModel.e2eCreatedSessionId)
            }
        }
        .onAppear {
 // M2b-2b: the first list card on screen marks the in-app first
 // frame. Any card may be the first visibly rendered one: the
 // first workspace group can be collapsed (persisted collapse
 // state) or the global card order can differ per host, so
 // gating on `cardIndex == 0` silently lost the metric.
 // `markFirstFrameVisible()` is idempotent.
            viewModel.markFirstFrameVisible()
        }
        .listRowInsets(EdgeInsets(top: 6, leading: Theme.Spacing.pageInset, bottom: 6, trailing: Theme.Spacing.pageInset))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowSeparatorTint(.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                handlePinToggle(session)
            } label: {
 // v6 §4: system swipe buttons render the glyph only (no title
 // text); the accessibility label keeps the wording for E2E.
                Image(systemName: pinned ? "pin.slash" : "pin")
            }
 // Pinned = accent fill; unpin = neutral raised fill (tokens only).
            .tint(pinned ? Theme.Palette.borderStrong : Theme.Palette.accent)
            .accessibilityIdentifier("swipe-pin-" + session.sessionId)
            .accessibilityLabel(pinned ? L10n.t("取消置顶") : L10n.t("置顶"))
            Button {
                handleArchiveRequest(session)
            } label: {
 // v6 §4: glyph-only swipe action; text lives in the a11y label.
                Image(systemName: "archivebox")
            }
            .tint(Theme.Palette.warning)
            .accessibilityIdentifier("swipe-archive-" + session.sessionId)
            .accessibilityLabel(L10n.t("归档"))
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
struct SessionCardView: View, Equatable {
    var session: SessionListItem
    var pendingApprovals: Int
    var isConnected: Bool
    var draftPreview: String? = nil
    var isPinned: Bool = false
 /// 44pt single row for the pinned area.
    var compact: Bool = false
    var onTap: () -> Void

 /// cold-launch freeze: the workspace list re-renders several times
 /// while the cached list, the live `session/list` snapshot and the
 /// `workspace/follow` baseline arrive. `.equatable()` skips the card body when
 /// its visible inputs did not change (the tap closure is intentionally ignored).
    static func == (lhs: SessionCardView, rhs: SessionCardView) -> Bool {
        lhs.session == rhs.session
            && lhs.pendingApprovals == rhs.pendingApprovals
            && lhs.isConnected == rhs.isConnected
            && lhs.draftPreview == rhs.draftPreview
            && lhs.isPinned == rhs.isPinned
            && lhs.compact == rhs.compact
    }

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
            Group {
                if compact {
                    compactContent
                } else {
                    regularContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
 // R3 (design 3.2): pinned = accent-soft fill (10%) + accent
 // border (28%); every other card keeps the neutral surface.
                isPinned ? AnyShapeStyle(Theme.Palette.accentSoft) : AnyShapeStyle(Theme.Palette.surface),
                in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(
                        isPinned
                            ? Theme.Palette.accentBorder
                            : (status.emphasizedBorderColor ?? Theme.Palette.border),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

 /// 44pt single-row pinned card: pin mark + title +
 /// relative time + status icon. The status word is dropped; the icon
 /// colour carries the state.
    private var compactContent: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if isPinned {
                PinMark(size: 12)
            }
            titleText
            Spacer(minLength: Theme.Spacing.xs)
            Text(DisplayFormat.relativeTime(session.lastPromptAt ?? session.updatedAt))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1)
            SessionStatusIcon(kind: status.kind, size: 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(height: 44)
    }

    private var regularContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
 // R3 (m3 panel 1): the pinned card leads its title with the
 // 13pt pin mark (Lucide path, accent) - no chip.
                if isPinned {
                    PinMark()
                        .alignmentGuide(.firstTextBaseline) { dimension in
 // v6 §4: guide = 12.0 for the 13pt pin (was 10.5,
 // 1.27pt low). The title line box centre is
 // 14.67 - 9 = 5.67pt below the baseline; 5.5 is
 // the rounded constant and keeps row height intact.
                            pinTitleBaselineGuide(pinSize: dimension.height)
                        }
                }
                titleText
                Spacer(minLength: Theme.Spacing.xs)
                Text(DisplayFormat.relativeTime(session.lastPromptAt ?? session.updatedAt))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            if let draftPreview {
 // M2: draft chip (warning text on hairline pill) + one-line
 // preview; replaces the status row on a blank card.
                HStack(spacing: Theme.Spacing.xs) {
                    Text(L10n.t("草稿"))
                        .font(Theme.Typography.diffGutter)
                        .foregroundStyle(Theme.Palette.warning)
                        .padding(.horizontal, Theme.Spacing.xxs + 2)
                        .padding(.vertical, 2)
                        .background(Theme.Palette.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.Palette.border, lineWidth: 1))
                    Text(draftPreview)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: Theme.Spacing.xs) {
 // v6: the same A-form linear icon as the detail header,
 // 14pt; icon and status word share the semantic color
 // (design mockup 04).
                    SessionStatusIcon(kind: status.kind, size: 14)
                    Text(status.localizedLabel)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(status.kind.color)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(Theme.Spacing.m)
    }

    private var titleText: some View {
        Text(session.title?.isEmpty == false
             ? (session.title ?? "")
             : (session.blank == true ? L10n.t("新会话") : L10n.t("未命名会话")))
            .font(Theme.Typography.cardTitle)
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(1)
    }
}

#Preview {
    WorkspaceListView().environmentObject(AppModel())
}
