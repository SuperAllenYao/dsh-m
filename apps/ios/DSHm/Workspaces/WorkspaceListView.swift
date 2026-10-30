import Combine
import Foundation
import SwiftUI

struct WorkspaceListView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var viewModel = WorkspaceViewModel()
    @State private var showConnectionMenu = false
    @State private var didAutoOpen = false
    @State private var didAutoDemo = false
 /// 最近一次横滑结束时刻：抑制「滑动尾随 tap」把刚展开的 rail 关掉。
    @State private var lastSwipeEndAt = Date.distantPast
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
            #if DEBUG
            bindPinFlightProbe()
            #endif
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
            if flight != nil { settleFlight(reason: .interrupted) }
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
 // R3 原行为「列表刷新即收起左滑」在真实 Host 下不可用：运行态会话会持续触发
 // session/list 刷新，用户刚滑出的按钮会被立刻收回。
 // 现在只在被滑开的那一行「已不存在」时清理，其余情况保留用户的手势状态。
            if let openId = viewModel.swipedSessionId,
               !viewModel.allSessions.contains(where: { $0.sessionId == openId }) {
                #if DEBUG
                SwipeDebugLog.log("refresh cleanup: open row gone \(openId)")
                #endif
                viewModel.swipedSessionId = nil
            }
            autoOpenFirstSessionIfNeeded()
        }
        #if DEBUG
        .onChange(of: app.link.phase) { _, _ in
            Task { await autoDemoPinFlight() }
        }
        .task {
 // 列表视图出现后跑一次自动演示（配对完成后才开始轮询等待在线）。
            await autoDemoPinFlight()
        }
        #endif
        .onScrollPhaseChange { _, phase in
 // R3 (design 3.2): scrolling closes the revealed action block.
 // 注意：只有「用户真的纵向滚动」才收起左滑——横向拖拽在 ScrollView 里也可能
 // 让 phase 进入.scrolling，若按相位直接收起，用户刚滑出按钮就立刻被收回，
 // 根本点不到。真正的判定在下面的几何回调里。
 // DD-17 ⑤：动画期用户滚动 → 立即结束飞行、直接落位（不续播）。
 // 只认用户滚动相位：视口锚点补偿是自己发起的程序化滚动（.animating），
 // 不能被它打断飞行。
            if Self.isUserScrollPhase(phase), flight != nil {
                settleFlight(reason: .interrupted)
            }
        }
        .onTapGesture {
            #if DEBUG
            SwipeDebugLog.log("root onTapGesture close (open=\(viewModel.swipedSessionId ?? "nil"))")
            #endif
 // R3: tapping outside any card (group headers, paddings) closes the
 // revealed actions; button taps win the hit-test inside cards.
            if viewModel.swipedSessionId != nil { viewModel.swipedSessionId = nil }
 // DD-17 ⑤：动画期用户点击 → 立即结束飞行、直接落位。
            if flight != nil { settleFlight(reason: .interrupted) }
        }
        #if DEBUG
        .onChange(of: viewModel.swipedSessionId) { oldValue, newValue in
            SwipeDebugLog.log("swipedSessionId \(oldValue ?? "nil") -> \(newValue ?? "nil")")
        }
        #endif
                .onChange(of: viewModel.swipedSessionId) { _, newValue in
 // 探针真值：rail 打开说明该行在屏上（点击前的基线帧）；置顶/取消置顶
 // 把 rail 收起后源行随即不可见。
            listGeometry.sourceVisible = newValue != nil
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
        .onReceive(NotificationCenter.default.publisher(for: .dshmPushPresentedInForeground)) { _ in
 // 用户停在列表页时，推送到达即静默刷新一次卡片状态（AC-13/AC-14）。
            viewModel.noteForegroundPushHint()
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

 // MARK: - DD-16 / DD-17 列表容器与置顶飞行层状态

 /// 列表内容坐标空间名：行几何、飞行卡 frame、DEBUG 探针都用同一个空间。
    private static let listCoordinateSpace = "workspace-session-list-space"

 /// 列表几何收集：刻意做成引用类型（非 @State），滚动/动画逐帧写入不触发重绘。
    @State private var listGeometry = SessionListGeometry()

 /// iOS 18 程序化滚动位置：DD-17 的视口锚点校正在这里落地。
    @State private var scrollPosition = ScrollPosition()

 /// 当前飞行（一次只允许一层；新操作先结算旧的，禁止叠层）。
 /// 位置/高度/底色/两层内容的逐帧值都由 `TimelineView` 从 `flight.startedAt`
 /// 显式插值（`SessionPinFlightMath`），不再用隐式动画（原因见 `flightLayer`）。
    @State private var flight: SessionPinFlight?
    @State private var flightToken = UUID()

 /// R3 (design 3.2): pin has no confirmation - optimistic toggle straight
 /// from the swipe block. Offline taps surface the disconnect hint and send
 /// nothing (never queue, never fail silently).
 ///
 /// DD-16/DD-17：置顶 = 按钮当帧消失 + 同一事务集合变更 + 150ms
 /// 飞行层（`Theme.Motion.pin`）；取消置顶 = `disablesAnimations` 事务（0 动画帧）；
 /// 列表滚深（> 40pt）时同步校正滚动偏移（视口锚点）。
    private func handlePinToggle(_ session: SessionListItem) {
        guard app.link.phase.isConnected else {
            viewModel.showInlineError(L10n.t("连接已断开"))
            return
        }
        let sessionId = session.sessionId
        let wasPinned = viewModel.followState.pinnedSessionIds.contains(sessionId)
 // 极快连点：新操作接管——先把上一段飞行直接落位，禁止叠出第二层。
        if flight != nil { settleFlight(reason: .interrupted) }
        #if DEBUG
        PinFlightProbe.shared?.click(
            action: wasPinned ? "unpin" : "pin",
            sessionId: sessionId,
            groupsVersion: viewModel.groupsVersion
        )
        #endif
        if wasPinned {
            unpinSession(session)
        } else {
            pinSession(session)
        }
    }

 /// 置顶：按钮当帧隐藏 → 飞行层从源行几何出发 → 单一 withAnimation 驱动集合变更
 /// （其它行/置顶区高度同曲线让位）→ 滚深时同曲线校正滚动偏移。
    private func pinSession(_ session: SessionListItem) {
        let sessionId = session.sessionId
        let pinnedCountBefore = viewModel.pinnedSessions.count
 // 源行几何：必须是「行」的 frame（卡片左滑后内容被平移，不能用卡片内容）。
        let sourceRect = listGeometry.groupRowFrames[sessionId]
 // 目标几何：置顶行插入后由 onGeometryChange 实测覆盖；未上报时按常量推算。
        let targetRect = SessionPinFlightMath.targetFrame(
            index: 0,   // 新置顶插到置顶区首位（follow state：most recently pinned first）
            pinnedAreaTop: listGeometry.pinnedAreaTop,
            listWidth: listGeometry.listWidth,
            horizontalInset: Theme.Spacing.pageInset
        )
 // 视口锚点计划必须在改数据之前取（改完行几何/滚动偏移都会变）。
        let anchorPlan = makeAnchorPlan(
            excluding: sessionId,
            sourceRect: sourceRect,
            pinnedCountBefore: pinnedCountBefore
        )
        var instant = Transaction()
        instant.disablesAnimations = true
 // ① 两个按钮当帧消失：与集合变更同一事件，收起动画不播（DD-16/DD-17）。
        withTransaction(instant) { viewModel.swipedSessionId = nil }
 // ② 飞行层插入：先落在源行几何上；目标先按常量推算，实测先到时覆盖。
        #if DEBUG
        if ProcessInfo.processInfo.environment["DSHM_PIN_AUTODEMO"] == "1" {
            autoDemoLog("pinSession source=\(String(describing: sourceRect)) target=\(targetRect) pinnedAreaTop=\(listGeometry.pinnedAreaTop)")
        }
        #endif
        if let sourceRect, sourceRect.height > 0, targetRect.width > 0 {
            let card = flightCardSnapshot(session)
            let token = UUID()
            withTransaction(instant) {
                flight = SessionPinFlight(
                    sessionId: sessionId,
                    sourceRect: sourceRect,
                    targetRect: targetRect,
                    card: card,
                    startedAt: Date()
                )
                flightToken = token
                listGeometry.targetRowOpacity = 0
                listGeometry.sourceVisible = false
            }
 // 150ms 后直接落位：飞行动画的时间轴从点击当帧起算（不依赖 onAppear
 // 的调度），落位点正好是曲线的 100%（回稳），不会停在过冲上。
            DispatchQueue.main.asyncAfter(deadline: .now() + SessionPinFlightMath.duration) {
                guard flightToken == token, self.flight != nil else { return }
                settleFlight(reason: .finished)
            }
        }
 // ③ 单一 withAnimation 驱动集合变更：分组移除 + 置顶插入 + 其它行让位。
        let toggle = withAnimation(Theme.Motion.pin) {
            viewModel.beginPinToggle(sessionId: sessionId)
        }
 // ④ 视口锚点：滚深时把滚动偏移校正 shift（同一条曲线、同一拍启动），
 // 让布局位移在视口里被抵消，锚点行不整列跳动。
 //
 // 实现说明（偏离 DD-17 字面的「校正无动画」）：SwiftUI 的隐式布局动画
 // 不是 FLIP——若瞬时改 offset、布局却仍按动画插值，锚点行会先跳 shift
 // 再被动画拉回（TC-43 的 ≤2pt 直接破）；因此这里让 offset 与布局在同一个
 // withAnimation(Theme.Motion.pin) 里一起走，可见结果里没有第二段动画。
        if let anchorPlan {
            withAnimation(Theme.Motion.pin) {
                scrollPosition.scrollTo(y: anchorPlan.correctedOffset)
            }
        }
        finishPinRequest(sessionId: sessionId, toggle: toggle, action: "pin")
    }

 /// 取消置顶：`disablesAnimations` 事务 → 置顶卡当帧消失、会话卡当帧回分组、
 /// 其余瞬间到位（0 动画帧，不做反向飞行/补位动画）。
    private func unpinSession(_ session: SessionListItem) {
        let sessionId = session.sessionId
        var instant = Transaction()
        instant.disablesAnimations = true
        let toggle = withTransaction(instant) {
            viewModel.swipedSessionId = nil
            return viewModel.beginPinToggle(sessionId: sessionId)
        }
        #if DEBUG
        PinFlightProbe.shared?.settle(action: "unpin", reason: "finished")
        #endif
        finishPinRequest(sessionId: sessionId, toggle: toggle, action: "unpin")
    }

    private func finishPinRequest(
        sessionId: String,
        toggle: (previous: [String], pinned: Bool),
        action: String
    ) {
        #if DEBUG
 // E2E 脚手架（仅 DEBUG）：隔离栈里的 mock 会话在真实 Host 上没有登记，
 // `session/pin` 会被 Host 拒绝；`DSHM_PIN_SIMULATE_OK=1` 时跳过网络往返、
 // 保留乐观结果，用于测量 150ms 飞行动效的真值（业务成功路径由真机验证段覆盖）。
        if ProcessInfo.processInfo.environment["DSHM_PIN_SIMULATE_OK"] == "1" {
            autoDemoLog("finishPinRequest simulated success action=\(action)")
            return
        }
        #endif
        Task { @MainActor in
            await viewModel.finishPinToggle(
                sessionId: sessionId,
                pinned: toggle.pinned,
                previous: toggle.previous,
                link: app.link
            )
 // 请求被拒：直接回原布局，不播反向飞行、不补动画（DD-17 ⑤）。
            let applied = viewModel.followState.pinnedSessionIds.contains(sessionId) == toggle.pinned
            if !applied {
                if flight != nil {
                    settleFlight(reason: .failed)
                } else {
                    #if DEBUG
                    PinFlightProbe.shared?.settle(action: action, reason: "failed")
                    #endif
                }
            }
        }
    }

 // MARK: - DD-17 视口锚点

    private struct PinAnchorPlan {
 /// 最靠上且未参与本次变更的行。
        let anchorId: String
 /// 变更前该行的视口 y（记录用于校对）。
        let viewportY: CGFloat
 /// 该行在内容坐标里的预计位移。
        let shift: CGFloat
 /// 变更后应恢复到的滚动偏移（= 变更前 offset + shift）。
        let correctedOffset: CGFloat
    }

 /// 列表滚动 > 40pt 时，取「最靠上且未参与本次变更的行」，记录它的视口 y 与
 /// 内容位移；变更后用同一条曲线把滚动偏移校正回同值。列表在顶部（≤ 40pt）不做
 /// 补偿，保证置顶卡与飞行终点在视口内可见。
    private func makeAnchorPlan(
        excluding sessionId: String,
        sourceRect: CGRect?,
        pinnedCountBefore: Int
    ) -> PinAnchorPlan? {
        let offset = listGeometry.scrollOffset
        guard SessionPinFlightMath.needsViewportCompensation(scrollOffset: offset) else { return nil }
        var candidates: [(id: String, rect: CGRect)] = []
        for (id, rect) in listGeometry.groupRowFrames
        where id != sessionId && listGeometry.visibleRowIds.contains(id) && rect.maxY > offset + 0.5 {
            candidates.append((id, rect))
        }
        for (id, rect) in listGeometry.pinnedRowFrames
        where id != sessionId && listGeometry.visiblePinnedRowIds.contains(id) && rect.maxY > offset + 0.5 {
            candidates.append((id, rect))
        }
        guard let anchor = candidates.min(by: { $0.rect.minY < $1.rect.minY }) else { return nil }
        let growth = SessionPinFlightMath.pinnedAreaGrowth(
            pinning: true,
            pinnedCountBefore: pinnedCountBefore
        )
        let shift = SessionPinFlightMath.anchorShift(
            pinnedAreaGrowth: growth,
            removedSourceHeight: sourceRect?.height,
            sourceAboveAnchor: (sourceRect?.minY ?? .greatestFiniteMagnitude) < anchor.rect.minY
        )
        return PinAnchorPlan(
            anchorId: anchor.id,
            viewportY: anchor.rect.minY - offset,
            shift: shift,
            correctedOffset: SessionPinFlightMath.compensatedScrollOffset(
                currentOffset: offset,
                shift: shift
            )
        )
    }

 // MARK: - DD-17 飞行层生命周期

 /// 飞行动画不使用隐式 `withAnimation`：位置/高度/底色描边/两层内容都由
 /// `flightLayer` 的 `TimelineView` 按 `flightProgress(elapsed:)` 显式插值，
 /// 时间原点 = `flight.startedAt`（点击当帧）；落位定时器在 `pinSession` 里排。

    private enum PinFlightSettleReason: String {
        case finished
        case interrupted
        case failed
    }

 /// 用户滚动相位（拖动/交互/惯性）。`.animating` 是程序化滚动（本文件的视口锚点
 /// 补偿与 `.scrollPosition` 驱动的滚动都算），不当作「用户滚动」去打断飞行。
    private static func isUserScrollPhase(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating:
            return true
        case .idle, .animating:
            return false
        @unknown default:
            return false
        }
    }

 /// 结束飞行并直接落位：恢复真实置顶行（opacity 1 + 可点击）、移除飞行卡。
 /// 全部在禁动画事务里完成——不会出现「飞行卡 + 真实行」同屏或淡出叠影。
    private func settleFlight(reason: PinFlightSettleReason) {
        guard flight != nil else { return }
        flightToken = UUID()
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            flight = nil
            listGeometry.targetRowOpacity = 1
        }
        #if DEBUG
        PinFlightProbe.shared?.frameRecorder.rect = nil
        PinFlightProbe.shared?.settle(action: "pin", reason: reason.rawValue)
        #endif
    }

 /// 飞行目标 frame 的实测覆盖窗口：约一个显示帧（首个飞行帧渲染前）。
 /// 窗口内到达的实测值会在任何一帧渲染前生效，不产生可见跳动。
    private static let flightTargetOverrideWindow: TimeInterval = 1.0 / 60.0

 /// 置顶行实测几何先报到：用实测值覆盖常量推算的目标 frame（DD-17 ②）。
 /// 只接受「首个显示帧之前」到达的实测值——飞行时间轴从点击当帧起算，之后再改
 /// 目标会让飞行卡二次跳动；更晚的实测值只更新 `pinnedRowFrames`（锚点用）。
    private func recordPinnedRowFrame(_ rect: CGRect, sessionId: String) {
        guard var current = flight,
              current.sessionId == sessionId,
              rect.width > 0, rect.height > 0,
              Date().timeIntervalSince(current.startedAt) < Self.flightTargetOverrideWindow
        else { return }
        current.targetRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: SessionPinFlightMath.pinnedCardHeight
        )
        flight = current
    }

 /// 飞行卡内容快照（关闭卡片自绘 chrome，由飞行卡统一插值底色/描边）。
    private func flightCardSnapshot(_ session: SessionListItem) -> SessionCardView {
        SessionCardView(
            session: session,
            pendingApprovals: viewModel.pendingApprovalCount(sessionId: session.sessionId, link: app.link),
            isConnected: app.link.phase.isConnected,
            liveQuestionCallIds: liveQuestionKeys(for: session),
            dismissedQuestionCallIds: dismissedQuestionCallIds(),
            draftPreview: session.blank == true
                ? viewModel.phoneCreatedDraftPreviews[session.sessionId]
                : nil,
            isPinned: false,
            compact: false,
            drawsChrome: false,
            onTap: {}
        )
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
 // DD-17 ⑤：动画期点击（含 rail 的归档按钮）→ 立即结束飞行、直接落位。
        if flight != nil { settleFlight(reason: .interrupted) }
 // 归档走确认弹窗：先收起左滑，避免 rail 留在遮罩后面（自定义左滑没有系统
 // swipeActions 的「点击即收起」）。
        viewModel.swipedSessionId = nil
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
            sessionList
        }
    }

 /// DD-16（用户 裁决）：会话列表容器 = `ScrollView + LazyVStack`。
 ///
 /// - 置顶区是一个**无 header** 的 Section；每个分组是一个 `Section`，分组头用
 /// `header:`（吸顶由 `pinnedViews: [.sectionHeaders]` 提供，不透明底色盖住
 /// 滚动中的卡片）。
 /// - 行由同一个 `SessionCardView` 按 `isPinned/compact` 渲染，外套自定义左滑
 /// `SwipeableSessionCard`（替代系统 `swipeActions`）。
 /// - 跨 Section 不共享视图身份：行 id 用 `card:<sessionId>:<pinned>`。
 /// - 纵向节奏：行上下各 6pt、分组间 20pt、底部 tail 32pt；置顶区顶部 10pt、
 /// 置顶行间 12pt。
    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let errorText = viewModel.errorText {
                    InlineErrorView(message: errorText) {
                        Task { await viewModel.refresh() }
                    }
                    .padding(.horizontal, Theme.Spacing.pageInset)
                    .padding(.bottom, Theme.Spacing.s)
                    .accessibilityIdentifier("workspace-list-error")
                }
                pinnedAreaAnchor
                if !viewModel.pinnedSessions.isEmpty {
                    pinnedSection
                }
                ForEach(Array(viewModel.groups.enumerated()), id: \.element.id) { index, group in
                    workspaceSection(group, index: index)
                }
 // Bottom breathing room: a tail row inside the scroll content (a
 // .contentMargins modifier here would propagate through the
 // NavigationStack into the pushed session detail).
                Color.clear
                    .frame(height: Theme.Spacing.xxl)
                    .accessibilityHidden(true)
            }
            .coordinateSpace(.named(Self.listCoordinateSpace))
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                listGeometry.listWidth = width
            }
            .overlay(alignment: .topLeading) { flightLayer }
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { oldValue, newValue in
            listGeometry.scrollOffset = newValue
 // 真实纵向滚动（>4pt）才收起已展开的左滑；横向拖拽不改 contentOffset，
 // 所以不会再把用户刚滑出的按钮抢走。
            if viewModel.swipedSessionId != nil, abs(newValue - oldValue) > 4 {
                #if DEBUG
                SwipeDebugLog.log("scroll close delta=\(newValue - oldValue)")
                #endif
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { viewModel.swipedSessionId = nil }
            }
        }
        .accessibilityIdentifier("workspace-session-list")
    }

 /// 置顶区插入点：恒存在的零高锚点，钉住内容坐标 y。
 /// 常量推算的目标 frame 用它 + 10pt + index×56；错误横幅出现/消失时随之变化。
    private var pinnedAreaAnchor: some View {
        Color.clear
            .frame(height: 0)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(Self.listCoordinateSpace)).minY
            } action: { top in
                listGeometry.pinnedAreaTop = top
            }
    }

 /// 置顶区（无分组头）：紧凑 44pt 卡片，行间 12pt、顶部 10pt、与分组间 20pt。
    private var pinnedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: SessionPinFlightMath.pinnedRowSpacing) {
                ForEach(Array(viewModel.pinnedSessions.enumerated()), id: \.element.id) { index, session in
                    pinnedRow(session, index: index)
                }
            }
            .padding(.top, SessionPinFlightMath.pinnedAreaTopPadding)
            .padding(.bottom, SessionPinFlightMath.pinnedAreaBottomPadding)
            .padding(.horizontal, Theme.Spacing.pageInset)
        }
    }

 /// DD-17 飞行层：列表内容上层的一张不吃点击、不进 a11y 树的飞行卡。
 ///
 /// 逐帧几何/样式由显示帧时钟显式插值：`flightProgress(elapsed:)` 与
 /// `Theme.Motion.pin` 是同一条 cubic-bezier（同一份控制点），位置、高度、
 /// 底色描边、两层内容都从 `flight.startedAt`（点击当帧）起算。
 ///
 /// 不用隐式 `withAnimation` 的原因：在插入
 /// 视图的 `.onAppear` 里启动的隐式动画要 ~84ms 才真正开始插值——位置和高度
 /// 同被拖到 ~168ms 才首次到位（AC-10 要求 60–100ms）；显式时间轴不依赖
 /// 插入事务/`.onAppear` 的调度。
    @ViewBuilder
    private var flightLayer: some View {
        if let flight {
            TimelineView(.animation(minimumInterval: 1.0 / 120.0)) { context in
                let elapsed = context.date.timeIntervalSince(flight.startedAt)
                let progress = SessionPinFlightMath.flightProgress(elapsed: elapsed)
                let frame = SessionPinFlightMath.flightFrame(
                    source: flight.sourceRect,
                    target: flight.targetRect,
                    progress: progress
                )
                let layers = SessionPinFlightMath.contentLayerOpacities(elapsed: elapsed)
                SessionPinFlightCard(
                    flight: flight,
                    position: frame.origin,
                    height: frame.height,
                    chromeProgress: progress,
                    normalOpacity: layers.normal,
                    pinnedOpacity: layers.pinned,
                    recorder: flightFrameRecorder
                )
            }
 // 逐帧值直接生效：不允许任何环境动画再对它们做二次插值（否则位置会
 // 落后于高度/底色，回到「两条曲线」的老问题）。
            .transaction { transaction in transaction.animation = nil }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

 /// 探针逐帧真值采集器（仅 DEBUG + `DSHM_PIN_PROBE=1`）。
    private var flightFrameRecorder: PinFlightFrameRecorder? {
        #if DEBUG
        return PinFlightProbe.shared?.frameRecorder
        #else
        return nil
        #endif
    }

    #if DEBUG
 /// 把列表侧的真值来源绑给探针（飞行卡 frame 由 `PinFlightFrameRecorder` 逐帧写入）。
    private func bindPinFlightProbe() {
        guard let probe = PinFlightProbe.shared else { return }
        let geometry = listGeometry
        let model = viewModel
        probe.bind(
            targetOpacity: { geometry.targetRowOpacity },
            sourceVisible: { geometry.sourceVisible },
            railVisible: { model.swipedSessionId != nil },
            groupsVersion: { model.groupsVersion }
        )
    }
    #endif

 // MARK: - Live question state (DD-04)

 /// Live `$events` user-question dedup keys for one card (DD-04). The key is the
 /// question-id fingerprint (falling back to callId/eventId): the live host
 /// omits `callId` on many waterfalls, and dropping those would leave the card
 /// stuck on 「进行中」 while the session actually waits for an answer.
 /// A waterfall without `agentId` cannot be attributed to a card, so it is not
 /// counted anywhere on the list (the detail page still answers it).
    private func liveQuestionKeys(for session: SessionListItem) -> Set<String> {
        var keys = Set<String>()
        for waterfall in app.link.pendingUserQuestions
        where waterfall.agentId == session.sessionId {
            keys.insert(waterfall.questionKey)
        }
        return keys
    }

 /// callIds the user answered/cancelled within the dismiss TTL: the snapshot
 /// projection may still list them as active until the next `session/list`, so
 /// subtracting them makes waiting → running/idle immediate (AC-13).
    private func dismissedQuestionCallIds() -> Set<String> {
        let now = Date()
        let live = app.link.dismissedQuestionCallIds
        return Set(
            live
                .filter { now.timeIntervalSince($0.value) < Self.dismissedQuestionTTL }
                .map { $0.key }
        )
    }

 /// Dismiss-entry TTL (DD-04 / design §4): answered or cancelled questions stay
 /// suppressed for 60 s, after which a refreshed snapshot is the truth again.
    private static let dismissedQuestionTTL: TimeInterval = 60

 /// One pinned row above the workspace groups: compact 44pt card, same custom
 /// swipe actions as a normal row (pin toggle / archive). No section header.
    private func pinnedRow(_ session: SessionListItem, index: Int) -> some View {
        let sessionId = session.sessionId
        let pinned = viewModel.followState.pinnedSessionIds.contains(sessionId)
        return SwipeableSessionCard(
            sessionId: sessionId,
            isPinned: pinned,
            open: viewModel.swipedSessionId == sessionId,
            onSwipeBegan: { openedId in viewModel.swipedSessionId = openedId },
            onSwipeSettled: { openedId, isOpen in
                viewModel.swipedSessionId = isOpen ? openedId : nil
                lastSwipeEndAt = Date()
            },
            onPin: { handlePinToggle(session) },
            onArchive: { handleArchiveRequest(session) }
        ) {
            sessionCard(
                session,
                compact: true,
                isPinned: pinned,
                identifier: "pinned-session-card-\(index)"
            )
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.listCoordinateSpace))
        } action: { rect in
            listGeometry.pinnedRowFrames[sessionId] = rect
 // 飞行期间真实置顶行隐藏，实测几何仍可用于目标 frame 校正。
            recordPinnedRowFrame(rect, sessionId: sessionId)
        }
        .onAppear {
            listGeometry.visiblePinnedRowIds.insert(sessionId)
 // Same first-frame contract as `sessionRow`: when every visible
 // session is pinned (or all groups are collapsed) this is the only
 // row that reaches the screen.
            viewModel.markFirstFrameVisible()
        }
        .onDisappear {
            listGeometry.visiblePinnedRowIds.remove(sessionId)
            listGeometry.pinnedRowFrames[sessionId] = nil
        }
 // 飞行期间真实置顶行不可见、不可点；落位后恢复（DD-17 ⑤）。
        .opacity(flight?.sessionId == sessionId ? 0 : 1)
        .allowsHitTesting(flight?.sessionId != sessionId)
        .id("card:\(sessionId):pinned")
        .transition(.identity)
    }

    private func workspaceSection(_ group: WorkspaceViewModel.WorkspaceGroup, index: Int) -> some View {
        let collapsed = viewModel.isCollapsed(group.path)
        return Section {
            if !collapsed {
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { _, session in
                    sessionRow(session)
                }
            }
 // 分组之间的 20pt 节奏（行下 6 + 这里 14）：随内容滚走，不粘在吸顶头上。
            Color.clear
                .frame(height: Theme.Spacing.l - SessionPinFlightMath.groupRowVerticalInset)
                .accessibilityHidden(true)
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
 // DD-16：吸顶头必须是不透明底色（否则滚动中的卡片会从字后穿过）。
            .background(Theme.Palette.background)
    }

 /// One session row inside a workspace group: the equatable card wrapped by the
 /// custom left-swipe (DD-16). Pin toggles straight away (no confirmation,
 /// optimistic + reconcile); archive always confirms first.
    private func sessionRow(_ session: SessionListItem) -> some View {
        let sessionId = session.sessionId
        let cardIndex = globalIndex(of: session)
        let pinned = viewModel.followState.pinnedSessionIds.contains(sessionId)
        return SwipeableSessionCard(
            sessionId: sessionId,
            isPinned: pinned,
            open: viewModel.swipedSessionId == sessionId,
            onSwipeBegan: { openedId in viewModel.swipedSessionId = openedId },
            onSwipeSettled: { openedId, isOpen in
                viewModel.swipedSessionId = isOpen ? openedId : nil
                lastSwipeEndAt = Date()
            },
            onPin: { handlePinToggle(session) },
            onArchive: { handleArchiveRequest(session) }
        ) {
            sessionCard(
                session,
                compact: false,
                isPinned: pinned,
                identifier: Self.e2eCardId(session: session, index: cardIndex)
            )
        }
 // 源行几何：量「行」而不是卡片内容（左滑后卡片内容会被平移）。
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.listCoordinateSpace))
        } action: { rect in
            listGeometry.groupRowFrames[sessionId] = rect
        }
        .onAppear {
            listGeometry.visibleRowIds.insert(sessionId)
            #if DEBUG
            SwipeDebugLog.log("row appear \(sessionId) open=\(viewModel.swipedSessionId == sessionId)")
            #endif
        }
        .onDisappear {
            listGeometry.visibleRowIds.remove(sessionId)
            #if DEBUG
            SwipeDebugLog.log("row disappear \(sessionId)")
            #endif
        }
        .padding(.horizontal, Theme.Spacing.pageInset)
        .padding(.vertical, SessionPinFlightMath.groupRowVerticalInset)
 // 跨 Section 不共享视图身份；源行移除必须整行当帧消失（不随布局动画淡出）。
        .id("card:\(sessionId):unpinned")
        .transition(.identity)
    }

 /// 同一个卡片构建函数（置顶/分组共用）：`isPinned/compact` 决定形态。
    private func sessionCard(
        _ session: SessionListItem,
        compact: Bool,
        isPinned: Bool,
        identifier: String
    ) -> some View {
        SessionCardView(
            session: session,
            pendingApprovals: viewModel.pendingApprovalCount(sessionId: session.sessionId, link: app.link),
            isConnected: app.link.phase.isConnected,
            liveQuestionCallIds: liveQuestionKeys(for: session),
            dismissedQuestionCallIds: dismissedQuestionCallIds(),
            draftPreview: session.blank == true
                ? viewModel.phoneCreatedDraftPreviews[session.sessionId]
                : nil,
            isPinned: isPinned,
            compact: compact
        ) {
            handleCardTap(session)
        }
        .equatable()
        .accessibilityIdentifier(identifier)
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
 // DD-16：系统 swipeActions 自带的 VoiceOver 滑动入口已随容器替换消失，
 // 卡片（a11y 元素本身）用自定义 accessibilityAction 提供等价入口，
 // label 与 rail 按钮一致（「置顶/取消置顶」「归档」）。
        .accessibilityAction(named: Text(isPinned ? L10n.t("取消置顶") : L10n.t("置顶"))) {
            handlePinToggle(session)
        }
        .accessibilityAction(named: Text(L10n.t("归档"))) {
            handleArchiveRequest(session)
        }
    }

 /// 卡片点击：动画期先结束飞行并直接落位；已展开左滑时先收起，否则打开会话。
    private func handleCardTap(_ session: SessionListItem) {
 // 横滑结束后 350ms 内的这次 tap 属于手势尾随，不当作「点卡片」：
 // 否则刚滑出的 rail 会被自己立刻关掉。
        if Date().timeIntervalSince(lastSwipeEndAt) < 0.35 {
            #if DEBUG
            SwipeDebugLog.log("suppressed trailing tap sid=\(session.sessionId)")
            #endif
            return
        }
        if flight != nil { settleFlight(reason: .interrupted) }
        if viewModel.swipedSessionId == session.sessionId {
            viewModel.swipedSessionId = nil
        } else {
 // t0 for the user-perceived detail latency (tap ->
 // first content). The route switch must stay synchronous and
 // cheap; the detail's own work happens after this mark.
            DetailMetrics.beginTap()
            app.openSession(session.followAddress)
        }
    }

    #if DEBUG
 /// E2E scaffolding (env-gated, DEBUG only): `DSHM_PIN_AUTODEMO=1` 在列表就绪且在线后
 /// 自动对第一个会话做 4 次「置顶/取消置顶」交替（先程序化露出左滑，再走真实
 /// `handlePinToggle`）。用于 DSHM_PIN_PROBE 采集动效逐帧真值；不改变用户路径，
 /// 生产构建不包含。
    private func autoDemoPinFlight() async {
        guard ProcessInfo.processInfo.environment["DSHM_PIN_AUTODEMO"] == "1", !didAutoDemo else { return }
        didAutoDemo = true
        autoDemoLog("scheduled connected=\(app.link.phase.isConnected) groups=\(viewModel.groups.count)")
        var sessionId: String?
        for i in 0..<150 {
            if app.link.phase.isConnected,
               let first = viewModel.groups.first(where: { !$0.sessions.isEmpty })?.sessions.first {
                sessionId = first.sessionId
                break
            }
            if i % 10 == 0 {
                autoDemoLog("poll \(i) connected=\(app.link.phase.isConnected) groups=\(viewModel.groups.count) sessions=\(viewModel.groups.first(where: { !$0.sessions.isEmpty })?.sessions.count ?? -1)")
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let sessionId else {
            autoDemoLog("aborted: no connected session")
            return
        }
        autoDemoLog("start sid=\(sessionId) connected=\(app.link.phase.isConnected) groups=\(viewModel.groups.count)")
        var instant = Transaction()
        instant.disablesAnimations = true
        for cycle in 0..<4 {
            withTransaction(instant) { viewModel.swipedSessionId = sessionId }
            try? await Task.sleep(nanoseconds: 450_000_000)
            if let session = viewModel.allSessions.first(where: { $0.sessionId == sessionId }) {
                handlePinToggle(session)
                autoDemoLog("cycle \(cycle) toggled pinned=\(viewModel.followState.pinnedSessionIds.contains(sessionId))")
            } else {
                autoDemoLog("cycle \(cycle) session missing")
            }
            try? await Task.sleep(nanoseconds: 1_100_000_000)
        }
        withTransaction(instant) { viewModel.swipedSessionId = nil }
        autoDemoLog("done")
    }

    private func autoDemoLog(_ message: String) {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("pin-demo.log") else { return }
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
    #endif

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

/// 列表几何收集（DD-16/DD-17），全部是**列表内容坐标**（`listCoordinateSpace`）。
///
/// 刻意做成引用类型而不是 @State：滚动与动画期间逐帧写入时不该触发整个列表重绘。
final class SessionListGeometry {
 /// 当前滚动偏移（= ScrollGeometry.contentOffset.y）。
    var scrollOffset: CGFloat = 0
 /// LazyVStack 宽度（ScrollView 内容宽）。
    var listWidth: CGFloat = 0
 /// 置顶区在内容坐标里的插入点（错误横幅之后、置顶区 padding 之前）。
    var pinnedAreaTop: CGFloat = 0
 /// 分组行几何（未左滑的「行」frame，不是被平移的卡片内容）。
    var groupRowFrames: [String: CGRect] = [:]
 /// 置顶行几何（44pt 紧凑卡）。
    var pinnedRowFrames: [String: CGRect] = [:]
    var visibleRowIds: Set<String> = []
    var visiblePinnedRowIds: Set<String> = []
 /// 探针真值：真实置顶行 opacity（飞行期间 0，落位后 1）。
    var targetRowOpacity: Double = 1
 /// 探针真值：被移除的源行是否仍可见。
    var sourceVisible = false
}

/// 会话卡片（v5 02）：标题 / 最近提问时间 / 运行点 + 状态 / 审批徽标。
struct SessionCardView: View, Equatable {
    var session: SessionListItem
    var pendingApprovals: Int
    var isConnected: Bool
 /// DD-04: live `$events` user-question callIds for this session.
    var liveQuestionCallIds: Set<String> = []
 /// DD-04: callIds answered/cancelled within the dismiss TTL — the snapshot
 /// projection may still list them as active until the next `session/list`.
    var dismissedQuestionCallIds: Set<String> = []
    var draftPreview: String? = nil
    var isPinned: Bool = false
 /// 44pt single row for the pinned area.
    var compact: Bool = false
 /// DD-17：飞行卡自己做底色/描边插值，两层内容层关掉卡片自绘 chrome。
    var drawsChrome: Bool = true
    var onTap: () -> Void

 /// cold-launch freeze: the workspace list re-renders several times
 /// while the cached list, the live `session/list` snapshot and the
 /// `workspace/follow` baseline arrive. `.equatable()` skips the card body when
 /// its visible inputs did not change (the tap closure is intentionally ignored).
    static func == (lhs: SessionCardView, rhs: SessionCardView) -> Bool {
        lhs.session == rhs.session
            && lhs.pendingApprovals == rhs.pendingApprovals
            && lhs.isConnected == rhs.isConnected
            && lhs.liveQuestionCallIds == rhs.liveQuestionCallIds
            && lhs.dismissedQuestionCallIds == rhs.dismissedQuestionCallIds
            && lhs.draftPreview == rhs.draftPreview
            && lhs.isPinned == rhs.isPinned
            && lhs.compact == rhs.compact
            && lhs.drawsChrome == rhs.drawsChrome
    }

 /// v5.4 status: waiting-for-answer > in-progress > not-started > idle; offline
 /// overrides while the link is down. Approvals come from the live `$events`
 /// list; user questions from the `session/list` snapshot ∪ the live `$events`
 /// waterfalls, deduped by callId and minus the answered/cancelled callIds
 /// (DD-04). Neither source paints new visuals: the row keeps its status word.
    private var status: SessionListStatus {
        let dismissed = dismissedQuestionCallIds
        return SessionListStatusResolver.status(
            for: session,
            pendingApprovals: pendingApprovals,
            liveQuestionKeys: liveQuestionCallIds.subtracting(dismissed),
            snapshotQuestionKeys: SessionListStatusResolver
                .snapshotQuestionKeys(for: session)
                .subtracting(dismissed),
            isConnected: isConnected
        )
    }

    var body: some View {
        Button(action: onTap) {
            cardSurface
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cardSurface: some View {
        if drawsChrome {
            cardContent
                .background(
 // R3 (design 3.2): pinned = accent-soft fill (10%) + accent
 // border (28%); every other card keeps the neutral surface.
                    isPinned
                        ? AnyShapeStyle(Theme.Palette.accentSoft)
                        : AnyShapeStyle(Theme.Palette.surface),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                )
 // DD-16：自定义左滑的 rail 就画在卡片下面；置顶卡的 accentSoft 是 10% 透明，
 // 必须再垫一层不透明的 App 底色，否则 rail 的按钮会透出来（List 时代有系统
 // cell 底色挡着，换容器后暴露）。
                .background(
                    Theme.Palette.background,
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
        } else {
            cardContent
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        if compact {
            compactContent
        } else {
            regularContent
        }
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
