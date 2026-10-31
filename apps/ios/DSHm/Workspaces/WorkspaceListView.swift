import Combine
import Foundation
import SwiftUI

struct WorkspaceListView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var viewModel = WorkspaceViewModel()
    @State private var showConnectionMenu = false
    @State private var didAutoOpen = false
    @State private var didAutoDemo = false
    /// 最近一次横滑结束时刻：抑制「滑动尾随 tap」把刚展开的 rail 关掉（真机缺陷）。
    @State private var lastSwipeEndAt = Date.distantPast
    @State private var showSettings = false

    /// 列表主体（header / 缓存横幅 / 内容 / 连接横幅）：拆成独立属性，
    /// 避免 `body` 表达式过大触发 Swift 类型检查超时。
    private var mainStack: some View {
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
    }

    var body: some View {
        observedList
    }

    /// 视觉壳层：列表主体 + 背景 + 归档确认遮罩。
    private var chromeList: some View {
        mainStack
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
    }

    /// 生命周期：设置页、进入/离开、下拉刷新。
    private var lifecycleList: some View {
        chromeList
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
            if pinMotion != nil || pinGhost != nil { settlePinMotion(reason: .interrupted) }
            viewModel.stop()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    /// 数据/通知观察 + 滚动/点击/指标条。
    private var observedList: some View {
        lifecycleList
        .onChange(of: viewModel.sessionsSnapshotVersion) { _ in
            // The FULL session list (including subagent/blank/archived/ungrouped
            // rows) feeds deep-link address resolution; display is filtered by the
            // registry + desktop visibility rules.
            app.updateKnownSessions(viewModel.allSessions)
        }
        .onChange(of: viewModel.groupsVersion) { _ in
            // R3 原行为「列表刷新即收起左滑」在真实 Host 下不可用：运行态会话会持续触发
            // session/list 刷新，用户刚滑出的按钮会被立刻收回（真机实测缺陷）。
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
            // 让 phase 进入 .scrolling，若按相位直接收起，用户刚滑出按钮就立刻被收回，
            // 根本点不到（真机实测缺陷）。真正的判定在下面的几何回调里。
            // AC-04 / DD-07：动画期用户滚动 → 立即 settle（应用全部缓冲 + 最新数据），
            // 继续插值会和真实视口错位。只认用户滚动相位：程序化滚动（.animating）
            // 不打断过渡。
            if Self.isUserScrollPhase(phase) {
                settlePinMotion(reason: .interrupted)
            }
        }
        .onTapGesture {
            #if DEBUG
            SwipeDebugLog.log("root onTapGesture close (open=\(viewModel.swipedSessionId ?? "nil"))")
            #endif
            // R3: tapping outside any card (group headers, paddings) closes the
            // revealed actions; button taps win the hit-test inside cards.
            if viewModel.swipedSessionId != nil { viewModel.swipedSessionId = nil }
            // AC-04：动画期用户点击 → 立即 settle。
            settlePinMotion(reason: .interrupted)
        }
        #if DEBUG
        .onChange(of: viewModel.swipedSessionId) { oldValue, newValue in
            SwipeDebugLog.log("swipedSessionId \(oldValue ?? "nil") -> \(newValue ?? "nil")")
        }
        #endif
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
        .overlay(alignment: .topLeading) { diagnosticsMetricsOverlay }
    }

    /// 启动/连接指标条（E2E 读取，不可见）：拆成独立属性，避免 body 表达式过复杂。
    @ViewBuilder
    private var diagnosticsMetricsOverlay: some View {
        VStack(spacing: 0) {
            startupMetricsElement
            prewarmMetricsElement
            connectMetricsElement
            reconnectMetricsElement
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
                // R1 design m1-header: name + version stack into a
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
    /// session page right away (user decision, design M2). Failures surface
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

    /// iOS 18 程序化滚动位置：DD-04 屏外分支的滚动偏移校正在这里落地。
    @State private var scrollPosition = ScrollPosition()

    /// 当前过渡段（DD-01/DD-07：一次只允许一段，段 1…3）。行位移由每行的
    /// `TimelineView` 按 `startedAt` 显式插值（实测隐式布局动画不接管这条变更）。
    @State private var pinMotion: PinMotionState?
    /// 幽灵卡（DD-05）：源行/被取消卡的原位快照，150ms 内按锚点等比缩小消失。
    @State private var pinGhost: SessionPinGhost?

    /// AC-05：系统「减弱动态效果」时当帧到位，不建位移/幽灵卡。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 诊断开关（仅 DEBUG + 自测）：`DSHM_PIN_DIAG_NO_GHOST=1` 不建幽灵卡，
    /// 用来定位「首帧提交延迟」是否来自幽灵层插入。生产构建恒为 false。
    private static var diagSkipGhost: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DSHM_PIN_DIAG_NO_GHOST"] == "1"
        #else
        return false
        #endif
    }

    /// 自测开关（仅 DEBUG）：`DSHM_PIN_ANCHOR_BIAS=<pt>` 故意少校正 N pt，
    /// 制造 >2pt 的锚点预测偏差，用来验证 DD-04「实测替换」真的落地。
    /// 生产恒为 0（校正量 = growth）。
    private static var anchorBias: CGFloat {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["DSHM_PIN_ANCHOR_BIAS"],
              let value = Double(raw) else { return 0 }
        return CGFloat(value)
        #else
        return 0
        #endif
    }
    /// 段开始时的预测内容坐标：段末（布局落地后）与实测比较，>2pt 记一条 deviation。
    @State private var pendingDeviation: PinDeviationCheck?
    /// DD-04 锚点实测替换（仅屏外分支）：登记锚点行的旧屏幕位置，等该行**首个**
    /// 几何回调（首帧布局阶段）用实测校验 `growth` 预测；晚于首帧即放弃替换。
    @State private var pendingAnchorCheck: PinAnchorCheck?
    /// 本次操作（含后续刷新段）的首次数据变更时刻：DD-07 三段共享 ≤450ms 预算。
    @State private var pinTransitionFirstStartedAt: Date?

    /// DD-07：自首次操作起的三段总预算（设计 3 × 150ms）。
    private static let pinSegmentBudget: TimeInterval = 0.45
    /// 段末落位检测余量（一帧内）；后段时长按剩余预算扣掉这段，保证总时长 ≤450ms。
    private static let pinSettleMargin: TimeInterval = 0.01
    /// 剩余预算不足该值时不再开新段，段末直接落位。
    private static let pinMinSegmentDuration: TimeInterval = 0.08

    /// R3 (design 3.2): pin has no confirmation - optimistic toggle straight
    /// from the swipe block. Offline taps surface the disconnect hint and send
    /// nothing (never queue, never fail silently).
    ///
    /// DD-02 / DD-04（动效口径 v4）：置顶 = 同一事务里的集合变更 + 行位移预测
    /// +（插入点屏外时）滚动偏移校正；取消置顶 = 同事务的集合变更 + 归位公式。列表
    /// 位移不再依赖 SwiftUI 隐式布局动画（实测一帧到终值），由行 `TimelineView` 按
    /// `startedAt` 显式插值。
    private func handlePinToggle(_ session: SessionListItem) {
        guard app.link.phase.isConnected else {
            viewModel.showInlineError(L10n.t("连接已断开"))
            return
        }
        let sessionId = session.sessionId
        let wasPinned = viewModel.followState.pinnedSessionIds.contains(sessionId)
        #if DEBUG
        PinFlightProbe.shared?.click(
            action: wasPinned ? "unpin" : "pin",
            sessionId: sessionId,
            groupsVersion: viewModel.groupsVersion
        )
        #endif
        // AC-04：任一过渡（含刷新段）中再操作 → 立即落位（应用全部缓冲）后完整重播。
        if pinMotion != nil || pinGhost != nil || viewModel.hasPendingPinRefresh {
            settlePinMotion(reason: .interrupted)
        }
        if wasPinned {
            unpinSession(session)
        } else {
            pinSession(session)
        }
    }

    // MARK: - DD-02 / DD-04 / DD-05 置顶与取消置顶

    /// 置顶：同一次更新内完成「数据变更 + 行位移预测 + 屏外滚动校正」；源卡换成幽灵卡
    /// 按锚点等比缩小消失；插入点在屏内时新置顶卡从上边缘中心长出，屏外时不播。
    private func pinSession(_ session: SessionListItem) {
        let sessionId = session.sessionId
        let pinnedCountBefore = viewModel.pinnedSessions.count
        let growth = SessionPinFlightMath.pinnedAreaGrowth(
            pinning: true,
            pinnedCountBefore: pinnedCountBefore
        )
        let sourceRect = listGeometry.groupRowFrames[sessionId]
        let sourceSlot = listGeometry.rowHeights[sessionId]
            ?? sourceRect.map { $0.height + 2 * SessionPinFlightMath.groupRowVerticalInset }
            ?? SessionPinFlightMath.defaultSessionRowSlot
        // DD-03：插入点 = 置顶区首位新行；与视口有交集 → 屏内，否则屏外。
        let insertVisible = insertPointVisible()
        let mode: PinMotionState.Mode = insertVisible ? .inPlace : .anchored
        // DD-04 内容底部（DEC-13）：可用滚动余量 = 旧内容最大偏移 − 当前偏移。
        // 余量不足 sourceSlot 时，保持上方不动所需的 growth 被底部钳位截断：
        // 滚动只能吸收 `growth − residual`，缺口 `residual = sourceSlot − 余量`
        // 转为受影响可见行的连续 shift（不留底部空白、不单帧落位）。
        let headroom = mode == .anchored ? listGeometry.scrollHeadroom() : 0
        let residual = mode == .anchored
            ? SessionPinFlightMath.anchoredResidual(sourceSlot: sourceSlot, headroom: headroom)
            : 0
        let scrollCorrection = mode == .anchored ? growth - residual : 0
        // DD-05 / DEC-13：幽灵卡锚点——①②上边缘水平中心；内容底部（residual > 0，
        // 上方列表同步向下补位）下边缘水平中心。
        let ghostAnchor = SessionPinFlightMath.ghostAnchor(for: mode, residual: residual)
        // 公式自己排除被置顶的源行，但需要它作为「上方/下方」的分界。
        let rows = visibleTransitionRows()
        // 吸顶分组头的屏幕位置由吸顶决定（变更前后都在视口顶部）：shift 必须为 0，
        // 不参与内容位移公式，否则 bottom 分支的残余 shift 会把它向上拉 85.7pt。
        let stickyHeaderIds = Set(listGeometry.headerFrames.compactMap { path, rect in
            rect.minY - listGeometry.scrollOffset <= 0.5
                ? SessionPinFlightMath.headerId(forPath: path)
                : nil
        })
        let shifts = insertVisible
            ? SessionPinFlightMath.inPlacePinShifts(
                rows: rows,
                sourceId: sessionId,
                growth: growth,
                sourceSlot: sourceSlot
            )
            : SessionPinFlightMath.anchoredShifts(
                rows: rows,
                sourceId: sessionId,
                sourceSlot: sourceSlot,
                residual: residual,
                zeroShiftIds: stickyHeaderIds
            )
        // 诊断：行在「新布局内容坐标」里的预测位置（inPlace 直接叠加；屏外分支还要
        // 加上滚动校正吸收的内容位移，内容坐标整体 +scrollCorrection）。
        var deviationTargets: [String: CGFloat] = [:]
        for row in rows where row.id != sessionId {
            let shift = shifts[row.id] ?? 0
            deviationTargets[row.id] = row.minY + shift + (mode == .anchored ? scrollCorrection : 0)
        }
        if insertVisible {
            deviationTargets[sessionId] = listGeometry.pinnedAreaTop
                + SessionPinFlightMath.pinnedAreaTopPadding
        }
        let oldTops = predictedContentTops()
        let now = Date()

        // AC-05 / DD-08：减弱动态效果 → 当帧到位（不建位移、不建幽灵卡、不播缩放）。
        if reduceMotion {
            var instant = Transaction()
            instant.disablesAnimations = true
            let toggle = withTransaction(instant) {
                viewModel.swipedSessionId = nil
                return viewModel.beginPinToggle(sessionId: sessionId)
            }
            finishPinRequest(sessionId: sessionId, toggle: toggle, action: "pin")
            return
        }

        let token = UUID()
        let clock = PinTransitionClock()
        // 时间轴从数据变更（同一次更新）起算；晚提交的帧由逐帧限速兜住。
        clock.begin(at: now)
        pinTransitionFirstStartedAt = now
        var instant = Transaction()
        instant.disablesAnimations = true
        let toggle = withTransaction(instant) {
            // DD-06：按钮当帧收起；缩放只作用于卡片，不作用于含 rail 的行容器。
            viewModel.swipedSessionId = nil
            let toggle = viewModel.beginPinToggle(sessionId: sessionId)
            // DD-07：段内到达的刷新先缓冲，段末应用；本次操作自身不算刷新。
            viewModel.pinTransitionHoldsRefresh = true
            // DD-04：插入点屏外时用滚动偏移吸收 growth（与数据变更同一次更新）。
            // 优先直接改底层 UIScrollView 的 contentOffset：`scrollPosition.scrollTo`
            // 会晚一帧落地，那一帧内上方行会被 growth 推开（AC-03 的 ≤2pt 直接破）。
            // 校正量 = growth 预测；锚点实测在首帧布局阶段校验（同号 >2pt 替换）。
            if mode == .anchored {
                // 锚点旧屏幕位置必须在改偏移之前取（此时 scrollOffset 仍是变更前的值）。
                // 吸顶分组头不算锚点：它的 frame 跟随滚动偏移（恒在屏幕顶部），
                // 既不是「内容位移」的参照，也会让 DD-04 的「源行即最上方可见行」
                // 分支永远走不到（TC-12）。排除后：源行上方还有可见卡/行才走锚点
                // 校验，否则校正量就是 growth。
                let anchorCandidates = rows.filter { !$0.id.hasPrefix("header:") }
                let anchor = SessionPinFlightMath.anchorRow(rows: anchorCandidates, sourceId: sessionId)
                let anchorOldScreenTop = anchor.map { $0.minY - listGeometry.scrollOffset }
                // DEC-13：校正量 = growth − residual（底部余量不足时只施加可用余量，
                // 剩余缺口由行 shift 连续承担）。`anchorBias` 是 DEBUG 诊断开关，
                // 故意少校正 N pt 来验证锚点实测替换分支（生产为 0）。
                let correction = scrollCorrection - Self.anchorBias
                if let scrollView = listGeometry.scrollView {
                    let hidden = scrollView.contentOffset
                    scrollView.setContentOffset(
                        CGPoint(x: hidden.x, y: hidden.y + correction),
                        animated: false
                    )
                } else {
                    scrollPosition.scrollTo(y: listGeometry.scrollOffset + correction)
                }
                if let anchor, let anchorOldScreenTop {
                    pendingAnchorCheck = PinAnchorCheck(
                        segment: 1,
                        token: token,
                        anchorId: anchor.id,
                        anchorOldScreenTop: anchorOldScreenTop,
                        growth: growth,
                        expectedScreenShift: residual
                    )
                }
            }
            // 探针起始真值按新一次过渡重置（幽灵卡缩放 0→1 的起点）。
            listGeometry.ghostStartScale = nil
            listGeometry.restoredScale = 1
            pinGhost = Self.diagSkipGhost ? nil : sourceRect.map { rect in
                SessionPinGhost(
                    sessionId: sessionId,
                    frame: rect,
                    card: flightCardSnapshot(session, pinned: false, compact: false),
                    clock: clock,
                    startedAt: now,
                    pinned: false,
                    anchor: ghostAnchor
                )
            }
            pinMotion = PinMotionState(
                mode: mode,
                kind: .pin,
                segment: 1,
                shifts: shifts,
                startedAt: now,
                clock: clock,
                token: token,
                sourceId: sessionId,
                insertedId: insertVisible ? sessionId : nil,
                restoredId: nil,
                ghostAnchor: ghostAnchor,
                dataVersion: viewModel.groupsVersion,
                oldContentTops: oldTops,
                headroom: headroom,
                residual: residual,
                scrollCorrection: scrollCorrection
            )
            pendingDeviation = PinDeviationCheck(segment: 1, predicted: deviationTargets)
            return toggle
        }
        #if DEBUG
        probeTransition(
            phase: "start",
            motion: pinMotion,
            shifts: shifts,
            oldTops: oldTops,
            newTops: predictedContentTops(),
            sourceId: sessionId,
            insertedId: insertVisible ? sessionId : nil,
            restoredId: nil
        )
        #endif
        schedulePinSegmentEnd(token: token, clock: clock)
        finishPinRequest(sessionId: sessionId, toggle: toggle, action: "pin")
    }

    /// 取消置顶：被取消卡换幽灵卡原位缩小；归位卡在排序位屏内时同段上边缘中心长出、
    /// 屏外时当帧出现（不播缩放）；
    /// 上方置顶卡不动，下方置顶卡与分组行按 DD-02 公式连续补位。
    private func unpinSession(_ session: SessionListItem) {
        let sessionId = session.sessionId
        let pinnedCountBefore = viewModel.pinnedSessions.count
        let sectionGrowth = abs(SessionPinFlightMath.pinnedAreaGrowth(
            pinning: false,
            pinnedCountBefore: pinnedCountBefore
        ))
        let sourceRect = listGeometry.pinnedRowFrames[sessionId]
        let restoredSlot = listGeometry.rowHeights[sessionId]
            ?? SessionPinFlightMath.defaultSessionRowSlot
        let rows = visibleTransitionRows()
        let oldTops = predictedContentTops()
        let now = Date()

        if reduceMotion {
            var instant = Transaction()
            instant.disablesAnimations = true
            let toggle = withTransaction(instant) {
                viewModel.swipedSessionId = nil
                return viewModel.beginPinToggle(sessionId: sessionId)
            }
            finishPinRequest(sessionId: sessionId, toggle: toggle, action: "unpin")
            return
        }

        let token = UUID()
        let clock = PinTransitionClock()
        // 时间轴从数据变更（同一次更新）起算；晚提交的帧由逐帧限速兜住。
        clock.begin(at: now)
        pinTransitionFirstStartedAt = now
        var instant = Transaction()
        instant.disablesAnimations = true
        var restoredId: String?
        var restoredVisible = false
        var deviationTargets: [String: CGFloat] = [:]
        var shifts: [String: CGFloat] = [:]
        let toggle = withTransaction(instant) {
            viewModel.swipedSessionId = nil
            let toggle = viewModel.beginPinToggle(sessionId: sessionId)
            viewModel.pinTransitionHoldsRefresh = true
            // 归位点 = 新数据里该会话在分组中的排序位；分组头/会话行同一套全序。
            let order = flattenedOrderIndex()
            let restoredIndex = order[sessionId]
            restoredId = restoredIndex == nil ? nil : sessionId
            // DD-05 / AC-02：归位卡是否在过渡开始时视口内——新排序位置（与 DD-07 同一套
            // 内容坐标预测）与当前视口相交才播「上边缘中心长出」，否则当帧出现、不播缩放。
            if restoredIndex != nil, let newTop = predictedContentTops()[sessionId] {
                let cardHeight = max(
                    0,
                    (listGeometry.rowHeights[sessionId]
                        ?? SessionPinFlightMath.defaultSessionRowSlot)
                        - 2 * SessionPinFlightMath.groupRowVerticalInset
                )
                restoredVisible = SessionPinFlightMath.restoredCardVisible(
                    newContentTop: newTop,
                    cardHeight: cardHeight,
                    scrollOffset: listGeometry.scrollOffset,
                    viewportHeight: listGeometry.viewportHeight
                )
            }
            shifts = SessionPinFlightMath.inPlaceUnpinShifts(
                rows: rows,
                canceledId: sessionId,
                sectionGrowth: sectionGrowth,
                restoredSlot: restoredIndex == nil ? 0 : restoredSlot,
                isBeforeRestored: { row in
                    guard let restoredIndex else { return false }
                    return (order[row.id] ?? Int.max) < restoredIndex
                }
            )
            for row in rows where row.id != sessionId {
                deviationTargets[row.id] = row.minY + (shifts[row.id] ?? 0)
            }
            // 探针起始真值按新一次过渡重置（幽灵卡缩放 0→1 的起点、归位卡缩放）。
            listGeometry.ghostStartScale = nil
            listGeometry.restoredScale = 1
            pinGhost = sourceRect.map { rect in
                SessionPinGhost(
                    sessionId: sessionId,
                    frame: rect,
                    card: flightCardSnapshot(session, pinned: true, compact: true),
                    clock: clock,
                    startedAt: now,
                    pinned: true,
                    anchor: .top
                )
            }
            pinMotion = PinMotionState(
                mode: .inPlace,
                kind: .unpin,
                segment: 1,
                shifts: shifts,
                startedAt: now,
                clock: clock,
                token: token,
                sourceId: sessionId,
                insertedId: nil,
                restoredId: restoredId,
                restoredVisible: restoredVisible,
                dataVersion: viewModel.groupsVersion,
                oldContentTops: oldTops
            )
            pendingDeviation = PinDeviationCheck(segment: 1, predicted: deviationTargets)
            return toggle
        }
        #if DEBUG
        probeTransition(
            phase: "start",
            motion: pinMotion,
            shifts: shifts,
            oldTops: oldTops,
            newTops: predictedContentTops(),
            sourceId: sessionId,
            insertedId: nil,
            restoredId: restoredId
        )
        #endif
        schedulePinSegmentEnd(token: token, clock: clock)
        finishPinRequest(sessionId: sessionId, toggle: toggle, action: "unpin")
    }

    // MARK: - 过渡段几何与状态机（DD-01 / DD-07）

    /// DD-03：插入点（置顶区首位新行）是否与视口有交集。贴视口上沿（不可见）按屏外。
    private func insertPointVisible() -> Bool {
        let top = listGeometry.pinnedAreaTop + SessionPinFlightMath.pinnedAreaTopPadding
        let screenTop = top - listGeometry.scrollOffset
        let viewport = listGeometry.viewportHeight > 1 ? listGeometry.viewportHeight : 1
        return screenTop + SessionPinFlightMath.pinnedCardHeight > 0.5 && screenTop < viewport
    }

    /// 过渡开始时与视口相交的行（AC-09：只动画屏幕内可见行）。
    private func visibleTransitionRows(
        excluding excludedId: String? = nil
    ) -> [SessionPinFlightMath.Row] {
        let offset = listGeometry.scrollOffset
        let viewport = listGeometry.viewportHeight > 1
            ? listGeometry.viewportHeight
            : .greatestFiniteMagnitude
        var rows: [SessionPinFlightMath.Row] = []
        func add(_ id: String, _ rect: CGRect, pinned: Bool) {
            guard id != excludedId else { return }
            let screenTop = rect.minY - offset
            guard screenTop + rect.height > 0, screenTop < viewport else { return }
            rows.append(
                SessionPinFlightMath.Row(
                    id: id,
                    minY: rect.minY,
                    height: rect.height,
                    isPinned: pinned
                )
            )
        }
        // 模型真值过滤：行在置顶区/分组之间移动时几何缓存可能残留旧 frame。
        // 用**已发布**的置顶数组，而不是 followState：DD-07 缓冲刷新期间
        // followState 已更新、pinnedSessions 还是旧布局，两者混用会把行归错区。
        let pinnedIds = Set(viewModel.pinnedSessions.map(\.sessionId))
        for (id, rect) in listGeometry.pinnedRowFrames where pinnedIds.contains(id) {
            add(id, rect, pinned: true)
        }
        for (id, rect) in listGeometry.groupRowFrames where !pinnedIds.contains(id) {
            add(id, rect, pinned: false)
        }
        for (path, rect) in listGeometry.headerFrames {
            add(SessionPinFlightMath.headerId(forPath: path), rect, pinned: false)
        }
        return rows
    }

    /// 当前数据（含段内缓冲已应用）下每行的预测内容坐标（DD-07：预测与判定同源）。
    private func predictedContentTops() -> [String: CGFloat] {
        let input = SessionPinFlightMath.LayoutInput(
            pinnedAreaTop: listGeometry.pinnedAreaTop,
            pinnedIds: viewModel.pinnedSessions.map(\.sessionId),
            groups: viewModel.groups.map { group in
                SessionPinFlightMath.GroupLayout(
                    path: group.path,
                    collapsed: viewModel.isCollapsed(group.path),
                    sessionIds: group.sessions.map(\.sessionId)
                )
            },
            rowSlot: { id in
                listGeometry.rowHeights[id] ?? SessionPinFlightMath.defaultSessionRowSlot
            },
            headerHeight: { path in
                if let measured = listGeometry.headerHeights[path] { return measured }
                let fallback = listGeometry.lastHeaderHeight
                return fallback > 0 ? fallback : SessionPinFlightMath.defaultGroupHeaderHeight
            }
        )
        return SessionPinFlightMath.predictedContentTops(input)
    }

    /// 新数据里分组行/分组头的全序（取消置顶判「归位点之前/之后」）。
    private func flattenedOrderIndex() -> [String: Int] {
        var order: [String: Int] = [:]
        var index = 0
        for group in viewModel.groups {
            order[SessionPinFlightMath.headerId(forPath: group.path)] = index
            index += 1
            for session in group.sessions {
                order[session.sessionId] = index
                index += 1
            }
        }
        return order
    }

    /// 段末回调：时间轴从数据变更起算，跑满 `clock.duration` 且渲染进度到终值
    /// （逐帧限速追赶）后进入段末处置（DD-07）。到点前休眠、到点后按 1/120 轮询，
    /// 把落位检测延迟压到一帧内（DD-07 总 ≤450ms 预算靠它）。
    private func schedulePinSegmentEnd(token: UUID, clock: PinTransitionClock) {
        let deadline = Date().addingTimeInterval(0.6)
        func poll() {
            guard self.pinMotion?.token == token else { return }
            let now = Date()
            if now >= deadline {
                self.settlePinMotion(reason: .segmentLimit)
                return
            }
            if clock.isSettled(now: now) {
                self.pinSegmentDidComplete()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { poll() }
            }
        }
        if let started = clock.startedAt {
            let wait = max(
                0,
                clock.duration - Date().timeIntervalSince(started) + 0.001
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { poll() }
        } else {
            poll()
        }
    }

    /// DD-07 段末：先核对上一段的预测/实测，再应用缓冲刷新 → 预测可见布局变化；
    /// > 0.5pt 且未到段 3 则再播一段，否则落位回 idle。段 3 段末是唯一允许的非用户落位。
    private func pinSegmentDidComplete() {
        guard let motion = pinMotion else { return }
        runPendingDeviationCheck()
        let oldTops = predictedContentTops()
        guard let pending = viewModel.takePendingPinRefresh() else {
            #if DEBUG
            probeTransition(
                phase: "end",
                motion: motion,
                shifts: motion.shifts,
                oldTops: oldTops,
                newTops: oldTops,
                sourceId: motion.sourceId,
                insertedId: motion.insertedId,
                restoredId: motion.restoredId
            )
            #endif
            settlePinMotion(reason: .finished)
            return
        }
        // 段开始时（新数据布局尚未落地）的可见行屏幕位置。
        let current = currentVisibleScreenTops()
        let nextSegment = motion.segment + 1
        let nextStart = Date()
        let budgetLeft = Self.pinSegmentBudget
            - nextStart.timeIntervalSince(pinTransitionFirstStartedAt ?? motion.startedAt)
        // DD-07：三段共享 450ms 预算；后段按剩余预算缩短（仍 ≤150ms），
        // 并预留一帧的段末落位检测余量。
        let nextDuration = min(
            SessionPinFlightMath.duration,
            budgetLeft - Self.pinSettleMargin
        )
        var shiftTops: [String: CGFloat] = [:]
        var newTops: [String: CGFloat] = [:]
        var maxShift: CGFloat = 0
        var next: PinMotionState?
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            viewModel.pinTransitionHoldsRefresh = false
            viewModel.applyPendingPinRefresh(pending)
            viewModel.pinTransitionHoldsRefresh = true
            newTops = predictedContentTops()
            shiftTops = SessionPinFlightMath.refreshShifts(
                currentScreenTops: current,
                predictedContentTops: newTops,
                scrollOffset: listGeometry.scrollOffset
            )
            maxShift = shiftTops.values.map { abs($0) }.max() ?? 0
            if maxShift > 0.5, motion.segment < 3,
               nextDuration >= Self.pinMinSegmentDuration {
                let clock = PinTransitionClock(duration: nextDuration)
                clock.begin(at: nextStart)
                next = PinMotionState(
                    mode: .refresh,
                    kind: .refresh,
                    segment: nextSegment,
                    shifts: shiftTops,
                    startedAt: nextStart,
                    clock: clock,
                    token: UUID(),
                    sourceId: nil,
                    insertedId: nil,
                    restoredId: nil,
                    dataVersion: viewModel.groupsVersion,
                    oldContentTops: newTops
                )
            }
            // 数据与段状态放在同一次更新里：行不会先用「新数据 + 旧位移」渲染一帧。
            pinGhost = nil
            pinMotion = next
            pendingAnchorCheck = nil
        }
        clearPinGhostProbeGeometry()
        #if DEBUG
        probeTransition(
            phase: "end",
            motion: motion,
            shifts: motion.shifts,
            oldTops: oldTops,
            newTops: newTops,
            sourceId: motion.sourceId,
            insertedId: motion.insertedId,
            restoredId: motion.restoredId
        )
        #endif
        guard let next else {
            // 段 3 段末落位 / 无可感知变化：数据已与落位同一次更新。
            pendingDeviation = PinDeviationCheck(segment: motion.segment, predicted: newTops)
            scheduleDeviationCheck()
            finishSettledSegment(reason: maxShift > 0.5 ? .segmentLimit : .refreshApplied)
            return
        }
        pendingDeviation = PinDeviationCheck(segment: next.segment, predicted: newTops)
        #if DEBUG
        probeTransition(
            phase: "start",
            motion: next,
            shifts: shiftTops,
            oldTops: oldTops,
            newTops: newTops,
            sourceId: nil,
            insertedId: nil,
            restoredId: nil
        )
        #endif
        schedulePinSegmentEnd(token: next.token, clock: next.clock)
    }

    /// 段开始时可见行的屏幕 minY（实测布局坐标 − 滚动偏移）。
    private func currentVisibleScreenTops() -> [String: CGFloat] {
        let offset = listGeometry.scrollOffset
        let viewport = listGeometry.viewportHeight > 1
            ? listGeometry.viewportHeight
            : .greatestFiniteMagnitude
        var result: [String: CGFloat] = [:]
        func add(_ id: String, _ rect: CGRect) {
            let screenTop = rect.minY - offset
            guard screenTop + rect.height > 0, screenTop < viewport else { return }
            result[id] = screenTop
        }
        // 用**已发布**的置顶数组，而不是 followState：DD-07 缓冲刷新期间
        // followState 已更新、pinnedSessions 还是旧布局，两者混用会把行归错区。
        let pinnedIds = Set(viewModel.pinnedSessions.map(\.sessionId))
        for (id, rect) in listGeometry.groupRowFrames where !pinnedIds.contains(id) {
            add(id, rect)
        }
        for (id, rect) in listGeometry.pinnedRowFrames where pinnedIds.contains(id) {
            add(id, rect)
        }
        for (path, rect) in listGeometry.headerFrames {
            add(SessionPinFlightMath.headerId(forPath: path), rect)
        }
        return result
    }

    private enum PinMotionSettleReason: String {
        case finished
        case interrupted
        case refreshApplied
        /// 段 3 段末：唯一允许的落位。
        case segmentLimit
    }

    /// 立即落位：应用全部缓冲与最新数据、清掉过渡/幽灵卡（无动画）。
    /// 连点（AC-04）、用户滚动、段末无变化、段 3 段末落位都走这里。
    private func settlePinMotion(reason: PinMotionSettleReason) {
        let hadMotion = pinMotion != nil || pinGhost != nil
        let hadPending = viewModel.hasPendingPinRefresh
        viewModel.pinTransitionHoldsRefresh = false
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            viewModel.settlePendingPinRefresh()
            pinMotion = nil
            pinGhost = nil
            pendingAnchorCheck = nil
        }
        clearPinGhostProbeGeometry()
        #if DEBUG
        if hadMotion || hadPending {
            PinFlightProbe.shared?.settle(action: "motion", reason: reason.rawValue)
        }
        #endif
    }

    /// 段末已在本事务内落位（数据改动 + `pinMotion` 清零同一次更新）后的收尾：
    /// 只补缓冲与探针，不再重复清状态（否则会丢掉 settle 真值）。
    private func finishSettledSegment(reason: PinMotionSettleReason) {
        viewModel.pinTransitionHoldsRefresh = false
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.settlePendingPinRefresh() }
        clearPinGhostProbeGeometry()
        #if DEBUG
        PinFlightProbe.shared?.settle(action: "motion", reason: reason.rawValue)
        #endif
    }

    /// 探针真值收尾：过渡结束/幽灵卡移除后清掉残留的逐帧缩放值，避免下一次点击前的
    /// tick 读到上一段的 `ghostStartScale`/`restoredScale`（只在探针开启时执行）。
    private func clearPinGhostProbeGeometry() {
        #if DEBUG
        guard PinFlightProbe.isEnabled else { return }
        listGeometry.ghostStartScale = nil
        listGeometry.ghostRect = nil
        listGeometry.restoredScale = 1
        #endif
    }

    /// 用户滚动相位（拖动/交互/惯性）。`.animating` 是程序化滚动（本文件的滚动
    /// 偏移校正与 `.scrollPosition` 驱动都算），不当作「用户滚动」去打断过渡。
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

    // MARK: - DD-04 锚点实测替换（屏外分支）

    /// 段开始时登记的锚点校验：锚点行的旧屏幕位置 + 预测校正后的屏幕位移。
    private struct PinAnchorCheck {
        var segment: Int
        var token: UUID
        var anchorId: String
        var anchorOldScreenTop: CGFloat
        var growth: CGFloat
        /// 预测的锚点屏幕位移：普通屏外分支 0；内容底部（DEC-13）为 residual。
        var expectedScreenShift: CGFloat = 0
    }

    /// 锚点行实测几何回调（首帧布局阶段）。命中登记行时校验 `growth` 预测：
    /// 同号且偏差 >2pt 且**仍在首帧**（时钟最多推进 1 帧）→ 直接补滚动偏移，
    /// 与数据变更落在同一帧，不产生段内二次跳变；晚于首帧则放弃替换，保留
    /// `growth` 并只记一条诊断（设计 DD-04：反号/测得晚保留预测）。
    private func noteRowGeometry(rowId: String, contentMinY: CGFloat) {
        guard let check = pendingAnchorCheck, check.anchorId == rowId else { return }
        pendingAnchorCheck = nil
        guard let motion = pinMotion,
              motion.token == check.token,
              motion.segment == check.segment else { return }
        // 用底层滚动视图的实时偏移：`listGeometry.scrollOffset` 由滚动回调异步更新，
        // 首帧布局阶段可能还停在改偏移之前。
        let liveOffset = listGeometry.scrollView?.contentOffset.y ?? listGeometry.scrollOffset
        let measuredScreenTop = contentMinY - liveOffset
        let deviation = measuredScreenTop - check.anchorOldScreenTop - check.expectedScreenShift
        let decision = SessionPinFlightMath.anchorReplacement(
            deviation: deviation,
            growth: check.growth
        )
        // 首帧门控：renderedFrames > 1 说明首帧已提交，再改滚动偏移就是二次跳变。
        let inFirstFrame = motion.clock.renderedFrames <= 1
        var applied = false
        if case .replace(let adjustment) = decision, inFirstFrame,
           let scrollView = listGeometry.scrollView {
            let offset = scrollView.contentOffset
            scrollView.setContentOffset(
                CGPoint(x: offset.x, y: offset.y + adjustment),
                animated: false
            )
            applied = true
        }
        #if DEBUG
        probeAnchor(
            segment: check.segment,
            anchorId: check.anchorId,
            deviation: deviation,
            decision: decision,
            inFirstFrame: inFirstFrame,
            applied: applied
        )
        #endif
    }

    // MARK: - 预测/实测诊断（只记录，不改用实测）

    /// 段开始时记录的预测内容坐标；段末（布局落地后）与实测比较，>2pt 记一条 deviation。
    private struct PinDeviationCheck {
        var segment: Int
        var predicted: [String: CGFloat]
    }

    private func runPendingDeviationCheck() {
        guard let check = pendingDeviation else { return }
        pendingDeviation = nil
        #if DEBUG
        probeDeviation(segment: check.segment, predicted: check.predicted)
        #endif
    }

    private func scheduleDeviationCheck(delay: TimeInterval = 0.05) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.runPendingDeviationCheck()
        }
    }

    #if DEBUG
    /// 段开始/结束快照：全量行（含屏外）旧/新预测内容坐标 + 实测位置。
    private func probeTransition(
        phase: String,
        motion: PinMotionState?,
        shifts: [String: CGFloat],
        oldTops: [String: CGFloat],
        newTops: [String: CGFloat],
        sourceId: String?,
        insertedId: String?,
        restoredId: String?
    ) {
        guard let probe = PinFlightProbe.shared, let motion else { return }
        let offset = listGeometry.scrollOffset
        let viewport = listGeometry.viewportHeight
        let ids = Set(oldTops.keys).union(newTops.keys).union(shifts.keys)
        let rows: [(id: String, oldY: CGFloat?, newY: CGFloat?, measuredY: CGFloat?, shift: CGFloat, visible: Bool)] = ids.sorted().map { id in
            let measured = measuredContentTop(forRowId: id)
            let visible: Bool
            if let measured {
                let screenTop = measured - offset
                visible = screenTop + 44 > 0 && screenTop < viewport
            } else {
                visible = false
            }
            return (id, oldTops[id], newTops[id], measured, shifts[id] ?? 0, visible)
        }
        probe.transition(
            phase: phase,
            segment: motion.segment,
            mode: motion.mode.rawValue,
            kind: motion.kind.rawValue,
            dataVersion: motion.dataVersion,
            pinnedCount: viewModel.pinnedSessions.count,
            sourceId: sourceId,
            insertedId: insertedId,
            restoredId: restoredId,
            rows: rows
        )
    }

    private func measuredContentTop(forRowId id: String) -> CGFloat? {
        if viewModel.followState.pinnedSessionIds.contains(id) {
            return listGeometry.pinnedRowFrames[id]?.minY
        }
        if let rect = listGeometry.groupRowFrames[id] { return rect.minY }
        if let rect = listGeometry.pinnedRowFrames[id] { return rect.minY }
        if id.hasPrefix("header:") {
            let path = String(id.dropFirst("header:".count))
            return listGeometry.headerFrames[path]?.minY
        }
        return nil
    }

    /// 预测 vs 实测差异（只诊断，不改用实测）。
    private func probeDeviation(segment: Int, predicted: [String: CGFloat]) {
        guard let probe = PinFlightProbe.shared, !predicted.isEmpty else { return }
        var rows: [(id: String, predicted: CGFloat, measured: CGFloat)] = []
        for (id, value) in predicted {
            guard let measured = measuredContentTop(forRowId: id) else { continue }
            if abs(measured - value) > 0.1 {
                rows.append((id, value, measured))
            }
        }
        probe.deviation(segment: segment, rows: rows)
    }

    /// DD-04 锚点实测校验真值：偏差、判定、是否仍在首帧、是否已落地替换。
    private func probeAnchor(
        segment: Int,
        anchorId: String,
        deviation: CGFloat,
        decision: SessionPinFlightMath.AnchorReplacement,
        inFirstFrame: Bool,
        applied: Bool
    ) {
        guard let probe = PinFlightProbe.shared else { return }
        let outcome: String
        switch decision {
        case .noAnchor:
            outcome = "noAnchor"
        case .keepPrediction:
            outcome = "keepPrediction"
        case .keepOppositeSign:
            outcome = "keepOppositeSign"
        case .keepImplausible:
            outcome = "keepImplausible"
        case .replace:
            outcome = applied ? "replaced" : "replaceTooLate"
        }
        probe.anchor(
            segment: segment,
            anchorId: anchorId,
            deviation: deviation,
            inFirstFrame: inFirstFrame,
            outcome: outcome
        )
    }
    #endif

    private func finishPinRequest(
        sessionId: String,
        toggle: (previous: [String], pinned: Bool),
        action: String
    ) {
        #if DEBUG
        // E2E 脚手架（仅 DEBUG）：隔离栈里的 mock 会话在真实 Host 上没有登记，
        // `session/pin` 会被 Host 拒绝；`DSHM_PIN_SIMULATE_OK=1` 时跳过网络往返、
        // 保留乐观结果，用于测量 150ms 动效的真值（业务成功路径由真机验证段覆盖）。
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
            // 请求被拒：回滚走同一条数据发布路径；过渡中由 DD-07 缓冲到段末应用，
            // 不额外插一段反向动画。
        }
    }

    /// 幽灵卡内容快照（源行/被取消卡原样渲染；卡片自绘 chrome 保留）。
    private func flightCardSnapshot(
        _ session: SessionListItem,
        pinned: Bool,
        compact: Bool
    ) -> SessionCardView {
        SessionCardView(
            session: session,
            pendingApprovals: viewModel.pendingApprovalCount(sessionId: session.sessionId, link: app.link),
            isConnected: app.link.phase.isConnected,
            liveQuestionCallIds: liveQuestionKeys(for: session),
            dismissedQuestionCallIds: dismissedQuestionCallIds(),
            draftPreview: session.blank == true
                ? viewModel.phoneCreatedDraftPreviews[session.sessionId]
                : nil,
            isPinned: pinned,
            compact: compact,
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
        // AC-04：动画期点击（含 rail 的归档按钮）→ 立即 settle。
        settlePinMotion(reason: .interrupted)
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

    /// DD-16（列表容器口径）：会话列表容器 = `ScrollView + LazyVStack`。
    ///
    /// - 置顶区是一个**无 header** 的 Section；每个分组是一个 `Section`，分组头用
    ///   `header:`（吸顶由 `pinnedViews: [.sectionHeaders]` 提供，不透明底色盖住
    ///   滚动中的卡片）。
    /// - 行由同一个 `SessionCardView` 按 `isPinned/compact` 渲染，外套自定义左滑
    ///   `SwipeableSessionCard`（替代系统 `swipeActions`）。
    /// - 跨 Section 不共享视图身份：行 id 用 `card:<sessionId>:<pinned>`。
    /// - 纵向节奏：行上下各 6pt、分组间 20pt、底部 tail 32pt；置顶区顶部 10pt、
    ///   置顶行间 12pt。
    private var sessionList: some View {
        ScrollView {
            // 返工（TC-10）：错误横幅 / 置顶区放在 LazyVStack **外面**。
            // LazyVStack 对滚出视口的子视图只保留缓存尺寸：置顶区完全在视口上方时，
            // 置顶卡片增删不会触发 Height 重算（实测 3 张置顶仍按 2 张的 130pt 排组内容），
            // DD-04 的 growth 校正就落成「滚动 +56、内容没长」的一帧 −56。非懒容器每次
            // 布局都重新测量置顶区高度，组内容随之下移，校正才与内容变化同源。
            VStack(alignment: .leading, spacing: 0) {
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
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
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
            }
            .coordinateSpace(.named(Self.listCoordinateSpace))
            .background(PinScrollViewFinder { listGeometry.scrollView = $0 })
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                listGeometry.listWidth = width
            }
            .overlay(alignment: .topLeading) { ghostLayer }
        }
        .scrollPosition($scrollPosition)
        #if DEBUG
        // 录屏取证专用：simctl 录屏是变帧率的（画面不变就不产帧），每帧变一次的心跳
        // 像素钉在 ScrollView 视口内，才能按 60fps 出帧、逐帧量屏幕上的真实位移。
        .overlay(alignment: .topTrailing) { frameHeartbeatForRecording }
        #endif
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.height
        } action: { _, newValue in
            listGeometry.viewportHeight = newValue
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { oldValue, newValue in
            listGeometry.scrollOffset = newValue
            // 真实纵向滚动（>4pt）才收起已展开的左滑；横向拖拽不改 contentOffset，
            // 所以不会再把用户刚滑出的按钮抢走（真机缺陷）。
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
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                listGeometry.pinnedAreaMeasuredHeight = height
            }
        }
    }

    /// DD-05 幽灵卡层：源行/被取消卡的原位快照，150ms 内按锚点等比缩小消失
    /// （①②上边缘水平中心；内容底部 DEC-13 下边缘水平中心）。
    /// 逐帧缩放由显示帧时钟显式插值（不依赖隐式动画调度）。
    @ViewBuilder
    private var ghostLayer: some View {
        if let ghost = pinGhost {
            TimelineView(.animation(minimumInterval: 1.0 / 120.0)) { context in
                // 与行同一时间轴，但用**自己的**键限速（跨消费者互不影响）。
                let progress = ghost.clock.progress(key: "ghost", now: context.date)
                let scale = SessionPinFlightMath.ghostScale(progress: progress)
                // 探针真值：闭包内直接记录（仅 DEBUG + 探针开启时 record 非 nil）。
                let _ = probeGhostRecorder?(scale, ghost.frame)
                ghost.card
                    .frame(
                        width: ghost.frame.width,
                        height: ghost.frame.height,
                        alignment: .topLeading
                    )
                    // transform-origin：上边缘水平中心（50% 0%）或下边缘水平中心（50% 100%）。
                    .scaleEffect(scale, anchor: ghost.anchor.unitPoint)
                    .opacity(SessionPinFlightMath.ghostOpacity(progress: progress))
                    .offset(x: ghost.frame.minX, y: ghost.frame.minY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // 逐帧值直接生效：不允许任何环境动画对它们做二次插值。
            .transaction { transaction in transaction.animation = nil }
        }
    }

    /// DD-05：新置顶卡从**上边缘水平中心**向四周长出（`scale 0 → 1`，仅插入点可见时播；
    /// 屏外不播）。由过渡段显式时间轴驱动，与下方内容下推同一段。
    @ViewBuilder
    private func insertedCardScale<Content: View>(
        _ sessionId: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if let motion = pinMotion, motion.insertedId == sessionId {
            TimelineView(.animation(minimumInterval: 1.0 / 120.0)) { context in
                // 与行同一时间轴，独立键限速（卡片缩放不跟随某一行的跳帧）。
                let progress = motion.clock.progress(key: "card:\(sessionId)", now: context.date)
                let scale = SessionPinFlightMath.insertedCardScale(progress: progress)
                let _ = probeInsertedScaleRecorder?(scale, nil)
                content()
                    .scaleEffect(scale, anchor: PinCardAnchor.top.unitPoint)
            }
            .transaction { transaction in transaction.animation = nil }
        } else {
            content()
        }
    }

    /// DD-05 / AC-02：归位卡长出（仅过渡开始时排序位置在视口内才播）。与新置顶卡同款：
    /// 从**上边缘水平中心**向四周 `scale 0 → 1`；屏外时视图层直接按 `scale 1` 出现。
    @ViewBuilder
    private func restoredCardScale<Content: View>(
        _ sessionId: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if let motion = pinMotion, motion.restoredVisible, motion.restoredId == sessionId {
            TimelineView(.animation(minimumInterval: 1.0 / 120.0)) { context in
                // 与缩卡/补位同一时间轴，独立键限速。
                let progress = motion.clock.progress(key: "restored:\(sessionId)", now: context.date)
                let scale = SessionPinFlightMath.restoredCardScale(progress: progress)
                let _ = probeRestoredScaleRecorder?(scale)
                content()
                    .scaleEffect(scale, anchor: motion.restoredAnchor.unitPoint)
            }
            .transaction { transaction in transaction.animation = nil }
        } else {
            content()
        }
    }

    // MARK: - 探针真值记录器（仅 DEBUG + DSHM_PIN_PROBE=1 时非 nil）

    private var probeGhostRecorder: ((CGFloat, CGRect?) -> Void)? {
        #if DEBUG
        guard PinFlightProbe.isEnabled else { return nil }
        let geometry = listGeometry
        return { scale, rect in
            // 起始值真值：幽灵卡第一帧渲染的 scale（首帧零点：零点=首帧 → 应 ≈1.0）。
            if geometry.ghostStartScale == nil { geometry.ghostStartScale = scale }
            geometry.ghostScale = scale
            if let rect { geometry.ghostRect = rect }
        }
        #else
        return nil
        #endif
    }

    private var probeInsertedScaleRecorder: ((CGFloat, CGRect?) -> Void)? {
        #if DEBUG
        guard PinFlightProbe.isEnabled else { return nil }
        let geometry = listGeometry
        return { scale, _ in geometry.newPinnedScale = scale }
        #else
        return nil
        #endif
    }

    private var probeRestoredScaleRecorder: ((CGFloat) -> Void)? {
        #if DEBUG
        guard PinFlightProbe.isEnabled else { return nil }
        let geometry = listGeometry
        return { scale in geometry.restoredScale = scale }
        #else
        return nil
        #endif
    }

    private func probeRowShiftRecorder(_ rowId: String) -> ((CGFloat) -> Void)? {
        #if DEBUG
        guard PinFlightProbe.isEnabled else { return nil }
        let geometry = listGeometry
        return { offset in
            geometry.rowShift[rowId] = offset
            geometry.rowShiftRenderCount += 1
            // AC-09 任务真值：settle 后行偏移仍在逐帧渲染 → 探针侧计数增长。
            PinFlightProbe.shared?.noteRowShiftRender()
        }
        #else
        return nil
        #endif
    }
    #if DEBUG
    /// 录屏心跳（仅 `DSHM_PIN_PROBE=1`）：每帧切换一个 3×3 像素，迫使 simctl 录屏
    /// 按 60fps 产帧，用来量「屏幕上的真实位移」，而不是只量 SwiftUI 的布局值。
    private var frameHeartbeatForRecording: some View {
        Group {
            if PinFlightProbe.isEnabled {
                TimelineView(.animation(minimumInterval: 1.0 / 120.0)) { context in
                    let on = Int(context.date.timeIntervalSinceReferenceDate * 120) % 2 == 0
                    Color(on ? Color.black : Color.white)
                        .frame(width: 3, height: 3)
                        .opacity(0.05)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }
    #endif

    #if DEBUG
    /// 把列表侧的真值来源绑给探针（行 frame / 渲染偏移 / 缩放 / 过渡段真值）。
    private func bindPinFlightProbe() {
        guard let probe = PinFlightProbe.shared else { return }
        let geometry = listGeometry
        let model = viewModel
        probe.bind(
            targetOpacity: { 1 },
            sourceVisible: { false },
            railVisible: { model.swipedSessionId != nil },
            groupsVersion: { model.groupsVersion },
            listSnapshot: {
                var snapshot = PinListSnapshot()
                snapshot.scrollOffset = geometry.scrollOffset
                snapshot.viewportHeight = geometry.viewportHeight
                // 与行/探测口径一致：用已发布布局的置顶数组（见 visibleTransitionRows）。
                let pinnedIds = Set(model.pinnedSessions.map(\.sessionId))
                snapshot.rowFrames = geometry.groupRowFrames.filter { !pinnedIds.contains($0.key) }
                for (id, rect) in geometry.pinnedRowFrames where pinnedIds.contains(id) {
                    snapshot.rowFrames[id] = rect
                }
                for (path, rect) in geometry.headerFrames {
                    snapshot.rowFrames[SessionPinFlightMath.headerId(forPath: path)] = rect
                }
                snapshot.pinnedIds = model.pinnedSessions.map(\.sessionId)
                snapshot.rowShift = geometry.rowShift
                snapshot.newPinnedScale = geometry.newPinnedScale
                snapshot.ghostScale = geometry.ghostScale
                snapshot.ghostStartScale = geometry.ghostStartScale
                snapshot.ghostVisible = geometry.ghostRect != nil
                snapshot.restoredScale = geometry.restoredScale
                snapshot.pinnedAreaHeight = geometry.pinnedAreaMeasuredHeight
                if let scrollView = geometry.scrollView {
                    snapshot.contentHeight = scrollView.contentSize.height
                    snapshot.rawOffset = scrollView.contentOffset.y
                }
                return snapshot
            },
            motion: {
                var state = PinMotionProbeState()
                if let motion = self.pinMotion {
                    state.mode = motion.mode.rawValue
                    state.kind = motion.kind.rawValue
                    state.segment = motion.segment
                    state.elapsedMs = motion.clock.elapsed(now: Date()) * 1000
                    state.progress = motion.clock.renderedProgress
                    state.renderedFrames = motion.clock.renderedFrames
                    state.clockStartMediaMs = motion.clock.startedAtMediaTime
                    state.durationMs = motion.clock.duration * 1000
                    state.shifts = motion.shifts
                    state.insertedId = motion.insertedId
                    state.restoredId = motion.restoredId
                    state.restoredVisible = motion.restoredVisible
                    state.ghostAnchor = motion.ghostAnchor.rawValue
                    state.insertedAnchor = PinCardAnchor.top.rawValue
                    state.restoredAnchor = motion.restoredAnchor.rawValue
                    state.headroom = motion.headroom
                    state.residual = motion.residual
                    state.scrollCorrection = motion.scrollCorrection
                }
                state.pendingRefresh = model.hasPendingPinRefresh
                state.taskActive = self.pinMotion != nil || self.pinGhost != nil
                return state
            }
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
            // DD-06：卡片长出期间 rail 不可见（缩放不作用于按钮）。
            railHidden: pinMotion?.insertedId == sessionId,
            onSwipeBegan: { openedId in viewModel.swipedSessionId = openedId },
            onSwipeSettled: { openedId, isOpen in
                viewModel.swipedSessionId = isOpen ? openedId : nil
                lastSwipeEndAt = Date()
            },
            onPin: { handlePinToggle(session) },
            onArchive: { handleArchiveRequest(session) }
        ) {
            // DD-05：插入点可见时新置顶卡从上边缘中心长出；屏外不播。
            insertedCardScale(sessionId) {
                sessionCard(
                    session,
                    compact: true,
                    isPinned: pinned,
                    identifier: "pinned-session-card-\(index)"
                )
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.listCoordinateSpace))
        } action: { rect in
            listGeometry.pinnedRowFrames[sessionId] = rect
            listGeometry.pinnedRowHeights[sessionId] = rect.height
                + 2 * SessionPinFlightMath.groupRowVerticalInset
            // DD-04：锚点实测（首帧布局阶段）校验 growth 预测。
            noteRowGeometry(rowId: sessionId, contentMinY: rect.minY)
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
        .id("card:\(sessionId):pinned")
        .transition(.identity)
        // DD-01：行渲染偏移由显式时间轴驱动（首个渲染帧起算）。
        .modifier(
            PinRowOffsetModifier(
                rowId: sessionId,
                motion: pinMotion,
                record: probeRowShiftRecorder(sessionId)
            )
        )
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
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.listCoordinateSpace))
            } action: { rect in
                listGeometry.headerFrames[group.path] = rect
                listGeometry.headerHeights[group.path] = rect.height
                listGeometry.lastHeaderHeight = rect.height
                // DD-04：锚点若是分组头，同样用首个几何回调校验 growth 预测。
                noteRowGeometry(
                    rowId: SessionPinFlightMath.headerId(forPath: group.path),
                    contentMinY: rect.minY
                )
            }
            // DD-01：分组头也参与让位（与分组行同一条公式）。
            .modifier(
                PinRowOffsetModifier(
                    rowId: SessionPinFlightMath.headerId(forPath: group.path),
                    motion: pinMotion,
                    record: probeRowShiftRecorder(SessionPinFlightMath.headerId(forPath: group.path))
                )
            )
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
            // DD-05 / AC-02：取消置顶的归位卡在过渡开始时视口内 → 上边缘中心长出；
            // 屏外时此修饰符直接透传（当帧出现、不播缩放）。
            restoredCardScale(sessionId) {
                sessionCard(
                    session,
                    compact: false,
                    isPinned: pinned,
                    identifier: Self.e2eCardId(session: session, index: cardIndex)
                )
            }
        }
        // 源行几何：量「行」而不是卡片内容（左滑后卡片内容会被平移）。
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.listCoordinateSpace))
        } action: { rect in
            listGeometry.groupRowFrames[sessionId] = rect
            // DD-07：槽位高缓存（卡高 + 12），刷新段布局预测用。
            listGeometry.rowHeights[sessionId] = rect.height
                + 2 * SessionPinFlightMath.groupRowVerticalInset
            // DD-04：锚点实测（首帧布局阶段）校验 growth 预测。
            noteRowGeometry(rowId: sessionId, contentMinY: rect.minY)
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
        .modifier(
            PinRowOffsetModifier(
                rowId: sessionId,
                motion: pinMotion,
                record: probeRowShiftRecorder(sessionId)
            )
        )
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
        // 否则刚滑出的 rail 会被自己立刻关掉（真机实测：open 后 ~90ms 被清空）。
        if Date().timeIntervalSince(lastSwipeEndAt) < 0.35 {
            #if DEBUG
            SwipeDebugLog.log("suppressed trailing tap sid=\(session.sessionId)")
            #endif
            return
        }
        settlePinMotion(reason: .interrupted)
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
    /// 自动执行置顶/取消置顶动作，供 `DSHM_PIN_PROBE` 采集逐帧真值。
    ///
    /// `DSHM_PIN_DEMO` 选择场景（弹跳取证新增）：
    /// - `cycle4`（默认）：第一个会话连续 4 次交替；
    /// - `unpin-middle`：先乐观置顶 5 个，再取消「从下往上数第 3 个」——复现用户口径；
    /// - `pin-top`：置顶 2 个后，在顶部置顶区可见时置顶一个分组会话；
    /// - `pin-scrolled`：置顶 2 个后滚到 `DSHM_PIN_SCROLL`（默认 600），置顶一个可见会话；
    /// - `pin-rail`（AC-06）：左滑 rail 展开后从 rail 置顶，rail 当帧收起且动画期不露出；
    /// - `pin-rapid`（AC-04）：置顶后 60ms 内再置顶另一个 → 立即 settle 后完整重播；
    /// - `pin-refresh`（AC-07）：置顶后 60ms 注入一次刷新快照（DEBUG 模拟发布路径）。
    private func autoDemoPinFlight() async {
        guard ProcessInfo.processInfo.environment["DSHM_PIN_AUTODEMO"] == "1", !didAutoDemo else { return }
        didAutoDemo = true
        autoDemoLog("scheduled connected=\(app.link.phase.isConnected) groups=\(viewModel.groups.count)")
        var ready = false
        for i in 0..<150 {
            if app.link.phase.isConnected, viewModel.allSessions.count >= 2 {
                ready = true
                break
            }
            if i % 10 == 0 {
                autoDemoLog("poll \(i) connected=\(app.link.phase.isConnected) groups=\(viewModel.groups.count) sessions=\(viewModel.allSessions.count)")
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard ready else {
            autoDemoLog("aborted: no connected session")
            return
        }
        // 自测期间关掉宿主驱动的后台刷新：真实 session/list 会覆盖乐观置顶集合，
        // prepin 数量会抖动（实测 3→1→2，依赖 5 张置顶卡的自测直接 aborted）。
        viewModel.sessionListRefreshOverride = {}
        let mode = ProcessInfo.processInfo.environment["DSHM_PIN_DEMO"] ?? "cycle4"
        autoDemoLog("start mode=\(mode) sessions=\(viewModel.allSessions.count) pinned=\(viewModel.pinnedSessions.count)")
        switch mode {
        case "unpin-middle":
            await autoDemoUnpinMiddle()
        case "unpin-index":
            await autoDemoUnpinIndex()
        case "pin-edge":
            await autoDemoPinEdge()
        case "pin-bottom":
            await autoDemoPinBottom()
        case "pin-toggle-rapid":
            await autoDemoPinToggleRapid()
        case "pin-refresh-seg2-hit":
            await autoDemoPinRefreshSegment2Hit()
        case "refresh-invisible":
            await autoDemoRefreshInvisible()
        case "refresh-insert":
            await autoDemoRefreshInsert()
        case "refresh-double":
            await autoDemoRefreshDouble()
        case "pin-scroll-hit":
            await autoDemoPinScrollHit()
        case "pin-top":
            await autoDemoPin(mode: "pin-top")
        case "pin-scrolled":
            await autoDemoPin(mode: "pin-scrolled")
        case "pin-rail":
            await autoDemoPinFromRail()
        case "pin-rapid":
            await autoDemoPinRapid()
        case "pin-refresh":
            await autoDemoPinRefresh()
        case "pin-refresh3":
            await autoDemoPinRefresh3()
        case "pin-refresh-real":
            await autoDemoPinRefreshReal()
        case "smoke":
            await autoDemoListSmoke()
        case "banner":
            await autoDemoBannerCalibration()
        case "collapse":
            // 传感器标定：分组折叠走 withAnimation(Theme.Motion.quick)，行位移动画是
            // 已知的（约 200ms）。用来验证 onGeometryChange 是否能采到隐式布局动画的
            // 中间帧——采不到，就不能用「行 frame 只有一跳」判定置顶是瞬移。
            await autoDemoCollapseCalibration()
        default:
            await autoDemoCycle4()
        }
        autoDemoLog("done mode=\(mode)")
    }

    /// 默认场景：第一个会话连续 4 次交替（保留给既有回归用例）。
    private func autoDemoCycle4() async {
        guard let sessionId = viewModel.groups.first(where: { !$0.sessions.isEmpty })?.sessions.first?.sessionId else {
            autoDemoLog("cycle4 aborted: no session")
            return
        }
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
    }

    /// 用户口径复现：置顶区可见时有 5 张置顶卡，取消从下往上数第 3 张。
    private func autoDemoUnpinMiddle() async {
        await autoDemoPrepinPinned(count: 5)
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let pinned = viewModel.pinnedSessions
        guard pinned.count >= 3 else {
            autoDemoLog("unpin-middle aborted: pinned=\(pinned.count)")
            return
        }
        let target = pinned[pinned.count - 3]
        autoDemoLog("unpin-middle target=\(target.sessionId) pinned=\(pinned.count) scroll=\(listGeometry.scrollOffset)")
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = target.sessionId }
        try? await Task.sleep(nanoseconds: 450_000_000)
        handlePinToggle(target)
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    /// 置顶区在屏内 / 滚深两种情况下各置顶一个分组会话。
    private func autoDemoPin(mode: String) async {
        await autoDemoPreparePinned(2)
        let scrolled = mode == "pin-scrolled"
        let targetY = scrolled
            ? (Double(ProcessInfo.processInfo.environment["DSHM_PIN_SCROLL"] ?? "") ?? 600)
            : 0
        scrollTo(y: CGFloat(targetY))
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let target = pickVisibleGroupSession() else {
            autoDemoLog("\(mode) aborted: no visible group session scroll=\(listGeometry.scrollOffset)")
            return
        }
        autoDemoLog("\(mode) target=\(target.sessionId) scroll=\(listGeometry.scrollOffset)")
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = target.sessionId }
        try? await Task.sleep(nanoseconds: 450_000_000)
        handlePinToggle(target)
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    // MARK: - 验证补测钩子（仅 DEBUG，TC-06/08/09/12/14/15/23/24/25/27）

    /// 验证钩子专用：等关注态基线落地、列表稳定后再把置顶数补到 `count`。
    /// 连接后首次 `workspace/follow` 基线会覆盖乐观置顶（实测 prepin 5 → 0.7s 后 0），
    /// 所有补测钩子都先过这一步，避免用空置顶区构造。
    private func autoDemoPreparePinned(_ count: Int) async {
        for _ in 0..<60 {
            if viewModel.followState.baselineApplied, viewModel.allSessions.count >= 2 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        for _ in 0..<8 {
            if viewModel.pinnedSessions.count >= count { return }
            await autoDemoPrepinPinned(count: count)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }


    private func demoEnvDouble(_ key: String, default fallback: Double) -> Double {
        guard let raw = ProcessInfo.processInfo.environment[key], let value = Double(raw) else { return fallback }
        return value
    }

    private func demoEnvInt(_ key: String, default fallback: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[key], let value = Int(raw) else { return fallback }
        return value
    }

    /// TC-06/08/09：置顶 N 张后滚到指定位置，左滑展开指定置顶卡（rail）再点取消置顶。
    /// - `DSHM_PIN_PINNED_COUNT`（默认 5）、`DSHM_PIN_SCROLL`（默认 0）、
    ///   `DSHM_PIN_INDEX`（默认 -1 = 末位；负数从末位倒数）。
    /// TC-06 = index -1 / scroll 0；TC-08 = index 2 / scroll 120；TC-09 = index 2 / scroll 0。
    private func autoDemoUnpinIndex() async {
        let pinnedCount = demoEnvInt("DSHM_PIN_PINNED_COUNT", default: 5)
        await autoDemoPreparePinned(pinnedCount)
        scrollTo(y: CGFloat(demoEnvDouble("DSHM_PIN_SCROLL", default: 0)))
        try? await Task.sleep(nanoseconds: 700_000_000)
        let pinned = viewModel.pinnedSessions
        let rawIndex = demoEnvInt("DSHM_PIN_INDEX", default: -1)
        let index = rawIndex >= 0 ? rawIndex : pinned.count + rawIndex
        guard pinned.indices.contains(index) else {
            autoDemoLog("unpin-index aborted: pinned=\(pinned.count) index=\(rawIndex)")
            return
        }
        let target = pinned[index]
        let screenTop = listGeometry.pinnedRowFrames[target.sessionId]
            .map { $0.minY - listGeometry.scrollOffset } ?? -1
        autoDemoLog("unpin-index index=\(index) id=\(target.sessionId) scroll=\(listGeometry.scrollOffset) pinned=\(pinned.count) screen=\(screenTop)")
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = target.sessionId }
        try? await Task.sleep(nanoseconds: 450_000_000)
        autoDemoLog("unpin-index railOpen=\(viewModel.swipedSessionId == target.sessionId)")
        handlePinToggle(target)
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    /// TC-12：源行即最上方可见卡（无上方锚点）。把第一个分组的第一张卡摆到吸顶分组头
    /// 下方（屏幕 y≈54），置顶区完全滚出视口 → 插入点屏外、无内容行/置顶卡在其上方。
    private func autoDemoPinEdge() async {
        await autoDemoPreparePinned(2)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let group = viewModel.groups.first(where: { !viewModel.isCollapsed($0.path) && !$0.sessions.isEmpty }),
              let target = group.sessions.first,
              let frame = listGeometry.groupRowFrames[target.sessionId] else {
            autoDemoLog("pin-edge aborted: no first group session")
            return
        }
        // 吸顶分组头底边约 48pt；把源行顶边摆在 54pt（行内边距 6pt 之下）。
        scrollTo(y: max(0, frame.minY - 54))
        try? await Task.sleep(nanoseconds: 700_000_000)
        autoDemoLog("pin-edge target=\(target.sessionId) scroll=\(listGeometry.scrollOffset) " +
            "screen=\(frame.minY - listGeometry.scrollOffset) pinnedAreaTop=\(listGeometry.pinnedAreaTop) " +
            "insertVisible=\(insertPointVisible())")
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = target.sessionId }
        try? await Task.sleep(nanoseconds: 450_000_000)
        handlePinToggle(target)
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    /// TC-10 诊断（内容底部）：5 张置顶、滚到内容底部后置顶一张可见卡。
    private func autoDemoPinBottom() async {
        await autoDemoPreparePinned(5)
        scrollTo(y: 100_000)
        try? await Task.sleep(nanoseconds: 800_000_000)
        autoDemoLog("pin-bottom start scroll=\(listGeometry.scrollOffset) contentH=\(listGeometry.scrollView?.contentSize.height ?? -1) headroom=\(listGeometry.scrollHeadroom())")
        guard let target = pickVisibleGroupSession() else {
            autoDemoLog("pin-bottom aborted: no visible group session")
            return
        }
        autoDemoLog("pin-bottom target=\(target.sessionId) scroll=\(listGeometry.scrollOffset)")
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = target.sessionId }
        try? await Task.sleep(nanoseconds: 450_000_000)
        handlePinToggle(target)
        if let motion = pinMotion {
            autoDemoLog("pin-bottom motion residual=\(motion.residual) correction=\(motion.scrollCorrection) headroom=\(motion.headroom)")
        }
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        autoDemoLog("pin-bottom done scroll=\(listGeometry.scrollOffset) contentH=\(listGeometry.scrollView?.contentSize.height ?? -1)")
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    /// TC-15：同一张卡置顶后约 60ms 取消置顶（立即落位 + 取消动画完整重播）。
    private func autoDemoPinToggleRapid() async {
        await autoDemoPreparePinned(2)
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let target = pickVisibleGroupSession() else {
            autoDemoLog("pin-toggle-rapid aborted: no visible group session")
            return
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = target.sessionId }
        try? await Task.sleep(nanoseconds: 400_000_000)
        autoDemoLog("pin-toggle-rapid target=\(target.sessionId)")
        handlePinToggle(target)
        try? await Task.sleep(nanoseconds: 60_000_000)
        if let current = viewModel.pinnedSessions.first(where: { $0.sessionId == target.sessionId })
            ?? viewModel.allSessions.first(where: { $0.sessionId == target.sessionId }) {
            autoDemoLog("pin-toggle-rapid cancel at 60ms pinned=\(viewModel.pinnedSessions.count)")
            handlePinToggle(current)
        } else {
            autoDemoLog("pin-toggle-rapid cancel skipped: session missing")
        }
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    /// TC-14：段 2 播放中且已有缓冲刷新时点另一张卡置顶。
    /// 段 1 内注入 #1 → 段 2 内注入 #2（缓冲）→ 段 2 内点第二张卡。
    private func autoDemoPinRefreshSegment2Hit() async {
        await autoDemoPreparePinned(2)
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let first = pickVisibleGroupSession() else {
            autoDemoLog("pin-refresh-seg2-hit aborted: no visible group session")
            return
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = first.sessionId }
        try? await Task.sleep(nanoseconds: 400_000_000)
        handlePinToggle(first)
        try? await Task.sleep(nanoseconds: 60_000_000)
        var excluded = Set([first.sessionId] + viewModel.followState.pinnedSessionIds)
        let victim1 = viewModel.debugSimulateRefreshDisappearance(
            excluding: excluded,
            preferVisible: listGeometry.visibleRowIds
        )
        excluded.formUnion([victim1].compactMap { $0 })
        autoDemoLog("pin-refresh-seg2-hit inject#1 victim=\(victim1 ?? "-") pending=\(viewModel.hasPendingPinRefresh)")
        guard await waitForPinSegment(2) else {
            autoDemoLog("pin-refresh-seg2-hit aborted: segment 2 never started")
            return
        }
        try? await Task.sleep(nanoseconds: 40_000_000)
        let victim2 = viewModel.debugSimulateRefreshDisappearance(
            excluding: excluded,
            preferVisible: listGeometry.visibleRowIds
        )
        excluded.formUnion([victim2].compactMap { $0 })
        autoDemoLog("pin-refresh-seg2-hit seg2 inject#2 victim=\(victim2 ?? "-") pending=\(viewModel.hasPendingPinRefresh)")
        try? await Task.sleep(nanoseconds: 40_000_000)
        if let second = pickVisibleGroupSession(excluding: excluded) {
            autoDemoLog("pin-refresh-seg2-hit second=\(second.sessionId) seg=\(pinMotion?.segment ?? 0) pending=\(viewModel.hasPendingPinRefresh)")
            handlePinToggle(second)
        } else {
            autoDemoLog("pin-refresh-seg2-hit aborted: no second target")
        }
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    /// TC-23：段 1 内刷新只改不可见内容（不改变可见布局）。
    private func autoDemoRefreshInvisible() async {
        await autoDemoPreparePinned(2)
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let target = pickVisibleGroupSession() else {
            autoDemoLog("refresh-invisible aborted: no visible group session")
            return
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = target.sessionId }
        try? await Task.sleep(nanoseconds: 400_000_000)
        handlePinToggle(target)
        try? await Task.sleep(nanoseconds: 60_000_000)
        let victim = viewModel.debugSimulateRefreshInvisibleMutation(
            visible: listGeometry.visibleRowIds,
            excluding: Set([target.sessionId] + viewModel.followState.pinnedSessionIds)
        )
        autoDemoLog("refresh-invisible victim=\(victim ?? "-") visible=\(listGeometry.visibleRowIds.count) pending=\(viewModel.hasPendingPinRefresh)")
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        autoDemoLog("refresh-invisible done version=\(viewModel.groupsVersion) pending=\(viewModel.hasPendingPinRefresh) pinned=\(viewModel.pinnedSessions.count)")
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    /// TC-24：段 1 内刷新新增一个会话（新增行造成可见布局变化）。
    private func autoDemoRefreshInsert() async {
        await autoDemoPreparePinned(2)
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let target = pickVisibleGroupSession() else {
            autoDemoLog("refresh-insert aborted: no visible group session")
            return
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = target.sessionId }
        try? await Task.sleep(nanoseconds: 400_000_000)
        handlePinToggle(target)
        try? await Task.sleep(nanoseconds: 60_000_000)
        let inserted = viewModel.debugSimulateRefreshInsertion(
            excluding: Set([target.sessionId] + viewModel.followState.pinnedSessionIds)
        )
        autoDemoLog("refresh-insert inserted=\(inserted ?? "-") pending=\(viewModel.hasPendingPinRefresh)")
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        autoDemoLog("refresh-insert done version=\(viewModel.groupsVersion) pending=\(viewModel.hasPendingPinRefresh)")
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    /// TC-25：同一段内连续两次刷新（缓冲合并为最新 → 只跑一次段 2）。
    private func autoDemoRefreshDouble() async {
        await autoDemoPreparePinned(2)
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let target = pickVisibleGroupSession() else {
            autoDemoLog("refresh-double aborted: no visible group session")
            return
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = target.sessionId }
        try? await Task.sleep(nanoseconds: 400_000_000)
        handlePinToggle(target)
        var excluded = Set([target.sessionId] + viewModel.followState.pinnedSessionIds)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let victim1 = viewModel.debugSimulateRefreshDisappearance(
            excluding: excluded,
            preferVisible: listGeometry.visibleRowIds
        )
        excluded.formUnion([victim1].compactMap { $0 })
        try? await Task.sleep(nanoseconds: 30_000_000)
        let victim2 = viewModel.debugSimulateRefreshDisappearance(
            excluding: excluded,
            preferVisible: listGeometry.visibleRowIds
        )
        autoDemoLog("refresh-double victims=\(victim1 ?? "-")/\(victim2 ?? "-") pending=\(viewModel.hasPendingPinRefresh)")
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        autoDemoLog("refresh-double done version=\(viewModel.groupsVersion) pending=\(viewModel.hasPendingPinRefresh)")
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    /// TC-27：动画进行中（约 60ms）触发一次用户滚动相位（DEBUG 合成；真实手势在
    /// XCUITest 里最早 +799ms 才到，动画已结束）。走与 `onScrollPhaseChange` 相同的
    /// settle 路径。
    private func autoDemoPinScrollHit() async {
        await autoDemoPreparePinned(2)
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let target = pickVisibleGroupSession() else {
            autoDemoLog("pin-scroll-hit aborted: no visible group session")
            return
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = target.sessionId }
        try? await Task.sleep(nanoseconds: 400_000_000)
        handlePinToggle(target)
        try? await Task.sleep(nanoseconds: 60_000_000)
        autoDemoLog("pin-scroll-hit trigger seg=\(pinMotion?.segment ?? 0) offset=\(listGeometry.scrollOffset)")
        debugTriggerUserScrollInterruption()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        autoDemoLog("pin-scroll-hit done pinned=\(viewModel.pinnedSessions.count) offset=\(listGeometry.scrollOffset) pending=\(viewModel.hasPendingPinRefresh) motion=\(pinMotion != nil)")
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    /// TC-27 钩子（仅 DEBUG）：动画中真实改一次滚动偏移，再走用户滚动相位的 settle。
    private func debugTriggerUserScrollInterruption() {
        if let scrollView = listGeometry.scrollView {
            let offset = scrollView.contentOffset
            scrollView.setContentOffset(CGPoint(x: offset.x, y: offset.y + 40), animated: false)
        } else {
            scrollTo(y: listGeometry.scrollOffset + 40)
        }
        settlePinMotion(reason: .interrupted)
    }

    /// AC-06：rail 展开后从 rail 置顶——按钮当帧收起，缩放/让位期间不露出。
    private func autoDemoPinFromRail() async {
        await autoDemoPrepinPinned(count: 2)
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let target = pickVisibleGroupSession() else {
            autoDemoLog("pin-rail aborted: no visible group session")
            return
        }
        autoDemoLog("pin-rail target=\(target.sessionId) scroll=\(listGeometry.scrollOffset)")
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = target.sessionId }
        // 等 rail 展开并让探针采到 railVisible=true 的基线帧。
        try? await Task.sleep(nanoseconds: 400_000_000)
        handlePinToggle(target)
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    /// AC-04：第一段未播完就再置顶另一个会话 → 立即 settle，新操作完整重播。
    private func autoDemoPinRapid() async {
        await autoDemoPrepinPinned(count: 2)
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let first = pickVisibleGroupSession() else {
            autoDemoLog("pin-rapid aborted: no visible group session")
            return
        }
        let second = viewModel.groups.flatMap { $0.sessions }.first { session in
            session.sessionId != first.sessionId
                && !viewModel.followState.pinnedSessionIds.contains(session.sessionId)
                && listGeometry.visibleRowIds.contains(session.sessionId)
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = first.sessionId }
        try? await Task.sleep(nanoseconds: 400_000_000)
        autoDemoLog("pin-rapid first=\(first.sessionId) second=\(second?.sessionId ?? "-")")
        handlePinToggle(first)
        // 60ms：第一段（150ms）还没播完。
        try? await Task.sleep(nanoseconds: 60_000_000)
        if let second {
            handlePinToggle(second)
        }
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    /// AC-07：置顶后段内注入刷新——先真实 refresh（无可见变化时也应缓冲），再用
    /// DEBUG 模拟一次可见布局变化（走同一 `rebuildGroups` 缓冲/发布路径）。
    private func autoDemoPinRefresh() async {
        await autoDemoPrepinPinned(count: 2)
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let target = pickVisibleGroupSession() else {
            autoDemoLog("pin-refresh aborted: no visible group session")
            return
        }
        autoDemoLog("pin-refresh target=\(target.sessionId) scroll=\(listGeometry.scrollOffset)")
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = target.sessionId }
        try? await Task.sleep(nanoseconds: 400_000_000)
        handlePinToggle(target)
        try? await Task.sleep(nanoseconds: 60_000_000)
        let victim = viewModel.debugSimulateRefreshDisappearance(
            excluding: Set([target.sessionId] + viewModel.followState.pinnedSessionIds)
        )
        autoDemoLog("pin-refresh injected victim=\(victim ?? "-") pending=\(viewModel.hasPendingPinRefresh)")
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    /// AC-07 / TC-21：三段刷新。段 1 内刷新 → 段 2；段 2 内再刷新 → 段 3；
    /// 段 3 内再刷新 → 段末直接落位，不再加第 4 段（自首次操作总时长 ≤450ms）。
    private func autoDemoPinRefresh3() async {
        await autoDemoPrepinPinned(count: 2)
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let target = pickVisibleGroupSession() else {
            autoDemoLog("pin-refresh3 aborted: no visible group session")
            return
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = target.sessionId }
        try? await Task.sleep(nanoseconds: 400_000_000)
        handlePinToggle(target)
        let t0 = Date()
        func sinceStartMs() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

        // 段 1 内注入第 1 次刷新。
        try? await Task.sleep(nanoseconds: 60_000_000)
        var excluded = Set([target.sessionId] + viewModel.followState.pinnedSessionIds)
        var victim = viewModel.debugSimulateRefreshDisappearance(excluding: excluded)
        excluded.formUnion([victim].compactMap { $0 })
        autoDemoLog("refresh3 seg\(pinMotion?.segment ?? 0) inject#1 victim=\(victim ?? "-") at \(sinceStartMs())ms pending=\(viewModel.hasPendingPinRefresh)")

        if await waitForPinSegment(2) {
            try? await Task.sleep(nanoseconds: 40_000_000)
            victim = viewModel.debugSimulateRefreshDisappearance(excluding: excluded)
            excluded.formUnion([victim].compactMap { $0 })
            autoDemoLog("refresh3 seg2 inject#2 victim=\(victim ?? "-") at \(sinceStartMs())ms pending=\(viewModel.hasPendingPinRefresh)")
        } else {
            autoDemoLog("refresh3 seg2 never started at \(sinceStartMs())ms")
        }

        if await waitForPinSegment(3) {
            try? await Task.sleep(nanoseconds: 40_000_000)
            victim = viewModel.debugSimulateRefreshDisappearance(excluding: excluded)
            autoDemoLog("refresh3 seg3 inject#3 victim=\(victim ?? "-") at \(sinceStartMs())ms pending=\(viewModel.hasPendingPinRefresh)")
        } else {
            autoDemoLog("refresh3 seg3 never started at \(sinceStartMs())ms")
        }

        try? await Task.sleep(nanoseconds: 1_200_000_000)
        autoDemoLog("refresh3 done at \(sinceStartMs())ms pinned=\(viewModel.pinnedSessions.count) version=\(viewModel.groupsVersion) pending=\(viewModel.hasPendingPinRefresh)")
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    /// AC-07 真实刷新路径（非 DEBUG 注入）：过渡段内触发真实 `session/list`
    /// （`viewModel.refresh()`，与下拉刷新同一路径）。Host 快照覆盖乐观置顶集合，
    /// 可见布局变化走 `rebuildGroups` 的段内缓冲、段末应用 → 段 2。
    private func autoDemoPinRefreshReal() async {
        await autoDemoPrepinPinned(count: 2)
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let target = pickVisibleGroupSession() else {
            autoDemoLog("pin-refresh-real aborted: no visible group session")
            return
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { viewModel.swipedSessionId = target.sessionId }
        try? await Task.sleep(nanoseconds: 400_000_000)
        handlePinToggle(target)
        let t0 = Date()
        func sinceStartMs() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
        // 段 1 内触发真实刷新（本地链路往返应在 100ms 内）。
        try? await Task.sleep(nanoseconds: 30_000_000)
        autoDemoLog("refresh-real request at \(sinceStartMs())ms version=\(viewModel.groupsVersion) pinned=\(viewModel.pinnedSessions.count)")
        await viewModel.refresh()
        autoDemoLog("refresh-real returned at \(sinceStartMs())ms version=\(viewModel.groupsVersion) pinned=\(viewModel.pinnedSessions.count) pending=\(viewModel.hasPendingPinRefresh) segment=\(pinMotion?.segment ?? 0)")
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        autoDemoLog("refresh-real done at \(sinceStartMs())ms pinned=\(viewModel.pinnedSessions.count) version=\(viewModel.groupsVersion)")
        withTransaction(instant) { viewModel.swipedSessionId = nil }
    }

    /// 自测：等过渡进入指定段（超时返回 false）。
    private func waitForPinSegment(_ segment: Int, timeoutMs: Int = 800) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if pinMotion?.segment == segment { return true }
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
        return false
    }

    /// AC-08 列表基础路径冒烟：加载 → 滚动 → 回顶 → 左滑展开/收起 → 置顶/取消置顶。
    private func autoDemoListSmoke() async {
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 600_000_000)
        autoDemoLog("smoke loaded groups=\(viewModel.groups.count) sessions=\(viewModel.allSessions.count) pinned=\(viewModel.pinnedSessions.count) viewport=\(listGeometry.viewportHeight) offset=\(listGeometry.scrollOffset)")
        scrollTo(y: 400)
        try? await Task.sleep(nanoseconds: 700_000_000)
        autoDemoLog("smoke scrolled offset=\(listGeometry.scrollOffset) rows=\(listGeometry.groupRowFrames.count)")
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        autoDemoLog("smoke back offset=\(listGeometry.scrollOffset)")
        var instant = Transaction()
        instant.disablesAnimations = true
        if let target = pickVisibleGroupSession() {
            withTransaction(instant) { viewModel.swipedSessionId = target.sessionId }
            try? await Task.sleep(nanoseconds: 400_000_000)
            autoDemoLog("smoke rail open id=\(target.sessionId) open=\(viewModel.swipedSessionId != nil)")
            withTransaction(instant) { viewModel.swipedSessionId = nil }
            try? await Task.sleep(nanoseconds: 300_000_000)
            autoDemoLog("smoke rail closed open=\(viewModel.swipedSessionId != nil)")
        } else {
            autoDemoLog("smoke rail: no visible group session")
        }
        if let target = pickVisibleGroupSession() {
            let before = viewModel.pinnedSessions.count
            handlePinToggle(target)
            try? await Task.sleep(nanoseconds: 600_000_000)
            autoDemoLog("smoke pinned before=\(before) after=\(viewModel.pinnedSessions.count) offset=\(listGeometry.scrollOffset)")
            if let current = viewModel.allSessions.first(where: { $0.sessionId == target.sessionId }) {
                handlePinToggle(current)
                try? await Task.sleep(nanoseconds: 600_000_000)
                autoDemoLog("smoke unpinned pinned=\(viewModel.pinnedSessions.count) offset=\(listGeometry.scrollOffset)")
            }
        }
        autoDemoLog("smoke done")
    }

    /// 传感器标定 2：给列表顶部插一条错误横幅（简单 `if` 插入 + 3s 线性隐式动画），
    /// 看 LazyVStack 的布局位移到底会不会被 withAnimation 插值。
    private func autoDemoBannerCalibration() async {
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        autoDemoLog("banner start scroll=\(listGeometry.scrollOffset)")
        withAnimation(.linear(duration: 3.0)) {
            viewModel.showInlineError("diagnostic banner")
        }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        autoDemoLog("banner done")
    }

    /// 传感器标定：用「分组折叠」这段已知会走隐式布局动画的位移，检查逐帧探针能否
    /// 采到中间帧。采不到中间帧 ⇒ 后续不能用行 frame 的单跳判定置顶是瞬移。
    private func autoDemoCollapseCalibration() async {
        scrollTo(y: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let group = viewModel.groups.first(where: { $0.sessions.count >= 2 }) else {
            autoDemoLog("collapse aborted: no group")
            return
        }
        #if DEBUG
        PinFlightProbe.shared?.click(
            action: "collapse",
            sessionId: group.path,
            groupsVersion: viewModel.groupsVersion
        )
        #endif
        withAnimation(Theme.Motion.quick) { viewModel.toggleCollapsed(group.path) }
        try? await Task.sleep(nanoseconds: 900_000_000)
        #if DEBUG
        PinFlightProbe.shared?.settle(action: "collapse", reason: "finished")
        #endif
        autoDemoLog("collapse done version=\(viewModel.groupsVersion)")
    }

    /// 乐观置顶 N 个（不走网络、不播飞行）：只为构造「置顶区已在屏内」的初始状态。
    private func autoDemoPrepinPinned(count: Int) async {
        // 等分组落地：workspace/follow 可能晚于 session/list 到达，此时 groups 为空，
        // 候选集为空会让 prepin 少置顶（实测 pinned 只到 2，依赖 5 张卡的自测跑不了）。
        for _ in 0..<25 {
            let visible = viewModel.groups.flatMap { $0.sessions }.count
                + viewModel.pinnedSessions.count
            if visible >= count { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        // 只从「分组里可见的会话」里挑：allSessions 含归档项，置顶它们不会出现在置顶区。
        let candidates = viewModel.groups.flatMap { $0.sessions }
            .filter { !viewModel.followState.pinnedSessionIds.contains($0.sessionId) }
        for session in candidates.prefix(max(0, count - viewModel.pinnedSessions.count)) {
            withTransaction(instant) { _ = viewModel.beginPinToggle(sessionId: session.sessionId) }
            autoDemoLog("prepin \(session.sessionId) pinned=\(viewModel.pinnedSessions.count)")
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        autoDemoLog("prepin done pinned=\(viewModel.pinnedSessions.count)")
    }

    /// 当前视口内、未置顶的分组会话（优先取靠近视口中部的行）。
    private func pickVisibleGroupSession(excluding excludedIds: Set<String> = []) -> SessionListItem? {
        let offset = listGeometry.scrollOffset
        let candidates = viewModel.groups.flatMap { $0.sessions }.filter { session in
            let id = session.sessionId
            guard !excludedIds.contains(id),
                  !viewModel.followState.pinnedSessionIds.contains(id),
                  listGeometry.visibleRowIds.contains(id),
                  let rect = listGeometry.groupRowFrames[id] else { return false }
            return rect.maxY > offset + 80
        }
        let centerY = offset + 400
        return candidates.min {
            abs((listGeometry.groupRowFrames[$0.sessionId]?.midY ?? 0) - centerY)
                < abs((listGeometry.groupRowFrames[$1.sessionId]?.midY ?? 0) - centerY)
        }
    }

    /// 程序化滚动（禁动画）：仅用于把列表摆到取证需要的起始位置。
    private func scrollTo(y: CGFloat) {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { scrollPosition.scrollTo(y: y) }
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
    /// 视口高度（屏幕坐标，pt）；DD-03 插入点判定与 AC-09 可见行筛选用。
    var viewportHeight: CGFloat = 0
    /// 分组头几何（path → 内容坐标 frame）。
    var headerFrames: [String: CGRect] = [:]
    var visibleRowIds: Set<String> = []
    var visiblePinnedRowIds: Set<String> = []
    /// 会话行（分组内）槽位高（行 frame 高 + 12）。DD-07 布局预测 / 归位槽位用。
    var rowHeights: [String: CGFloat] = [:]
    /// 置顶行槽位高（44 + 12 = 56），与分组行槽位分开缓存（同一会话可能跨区移动）。
    var pinnedRowHeights: [String: CGFloat] = [:]
    /// 分组 path → 分组头高（槽位高 = 实测头高）。DD-07 布局预测用。
    var headerHeights: [String: CGFloat] = [:]
    /// 最近一次实测的分组头高（新分组无缓存时的兜底）。
    var lastHeaderHeight: CGFloat = 0
    /// 底层 UIScrollView（DD-04 屏外分支需要与数据变更同帧改 contentOffset）。
    weak var scrollView: UIScrollView?
    /// DD-04 内容底部（DEC-13）可用余量：当前偏移到最大偏移还能增加多少（≥0）。
    /// 到底时为 0；无底层视图时按「无限余量」处理（退回普通屏外分支）。
    func scrollHeadroom() -> CGFloat {
        guard let scrollView else { return .greatestFiniteMagnitude }
        let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
            + scrollView.adjustedContentInset.bottom
        return max(0, maxOffset - scrollView.contentOffset.y)
    }
    /// 诊断：置顶区实测高度（内容坐标，含上下 padding；DD-04 屏外分支的布局增长源）。
    var pinnedAreaMeasuredHeight: CGFloat = 0
    /// 探针真值：逐帧行渲染偏移（`PinRowShiftModifier` 写入）。
    var rowShift: [String: CGFloat] = [:]
    /// 探针真值：行偏移逐帧渲染次数（AC-09 settle 后无逐帧任务）。
    var rowShiftRenderCount = 0
    /// 探针真值：新置顶卡当帧缩放。
    var newPinnedScale: CGFloat = 1
    /// 探针真值：幽灵卡当帧缩放与原位 frame。
    var ghostScale: CGFloat = 0
    var ghostRect: CGRect?
    /// 探针真值：本段幽灵卡**首个渲染帧**的缩放（首帧零点：零点=首帧 → ≈1.0）。
    var ghostStartScale: CGFloat?
    /// 探针真值：归位卡当帧缩放（无归位卡或无动画时恒为 1）。
    var restoredScale: CGFloat = 1
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
    /// 44pt single row for the pinned area .
    var compact: Bool = false
    /// DD-17：飞行卡自己做底色/描边插值，两层内容层关掉卡片自绘 chrome。
    var drawsChrome: Bool = true
    var onTap: () -> Void

    ///  cold-launch freeze: the workspace list re-renders several times
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

    /// 44pt single-row pinned card (pinned card): pin mark + title +
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

// MARK: - 置顶过渡的行位移（DD-01）

/// 行渲染偏移：按过渡时钟显式插值 `offset(y: −shift × (1 − progress))`。
///
/// - 时钟在**首个渲染帧**起算（`PinTransitionClock`）：数据变更后的首帧提交可能晚于
///   点击，若按点击起算，首帧会直接跳到曲线上很大的进度（单帧位移超过总位移 1/2）。
/// - 结构恒定（空闲时 `TimelineView(paused:)`），不在起止时重建行子树（否则行几何
///   回调被清掉、左滑状态丢失）；空闲时无逐帧任务（AC-09）。
/// - `record` 仅 DEBUG + 探针开启时非 nil，逐帧写回渲染偏移供帧级真值采集。
struct PinRowOffsetModifier: ViewModifier {
    var rowId: String
    var motion: PinMotionState?
    var record: ((CGFloat) -> Void)?

    /// 空闲 = 没有任何过渡段（TimelineView paused，AC-09：结束后无逐帧任务）。
    /// 有过渡时**所有已渲染行**都保持 ticking：段 2 新增的位移行如果从 paused 唤醒，
    /// 首帧仍会用旧内容（offset 0）渲染一次，出现一帧布局跳变。
    private var isIdle: Bool { motion == nil }

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: isIdle)) { context in
            let dy = offset(at: context.date)
            let _ = record?(dy)
            content.offset(y: dy)
        }
        // 逐帧值直接生效：不允许环境动画再做二次插值。
        .transaction { transaction in transaction.animation = nil }
    }

    /// 当前渲染偏移（由过渡时钟的「首个渲染帧」起算，掉帧时段不追赶）。
    private func offset(at date: Date) -> CGFloat {
        guard let motion, let value = motion.shifts[rowId], value != 0 else { return 0 }
        let progress = motion.clock.progress(key: rowId, now: date)
        return -value * CGFloat(1 - progress)
    }
}

/// 找到 SwiftUI `ScrollView` 底层的 `UIScrollView`（DD-04 屏外分支同步校正滚动偏移）。
/// 只做弱引用登记，不参与布局与交互。
struct PinScrollViewFinder: UIViewRepresentable {
    var onFound: (UIScrollView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        DispatchQueue.main.async {
            if let scrollView = view.pinEnclosingScrollView { onFound(scrollView) }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let scrollView = uiView.pinEnclosingScrollView { onFound(scrollView) }
    }
}

private extension UIView {
    var pinEnclosingScrollView: UIScrollView? {
        var current: UIView? = superview
        while let view = current {
            if let scrollView = view as? UIScrollView { return scrollView }
            current = view.superview
        }
        return nil
    }
}

#Preview {
    WorkspaceListView().environmentObject(AppModel())
}
