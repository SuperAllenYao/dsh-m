import Combine
import SwiftUI

/// Session detail (v5 03/04): turn-grouped message flow + status strip + composer,
/// with approval / permission sheets driven by $events and projections.
struct SessionDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let address: SessionFollowAddress
    let sessionId: String
    /// v5.4 task-13: non-nil when this detail is a child subagent session.
    let subagentContext: SubagentSessionContext?

    @StateObject private var viewModel: SessionViewModel
    @StateObject private var attachments: AttachmentStore
    @State private var submittingApproval = false
    /// v0.2.0 interaction panel: folded while the user reads the conversation
    /// output; the header badge re-opens it. Input stays blocked meanwhile.
    @State private var pendingPanelCollapsed = false
    @State private var lastPendingId: String?
    /// One sheet slot for tool detail / file changes / permissions. Multiple
    /// `.sheet` modifiers on the same view can race on iOS (the tool detail sheet
    /// stopped presenting after a fourth sheet was added), so they share a slot.
    @State private var detailSheet: SessionDetailSheet?
    /// v5.6 user questions: per-call in-flight/error state. The answer batch and
    /// the projection refresh live in SessionViewModel; on success the call is
    /// removed from activeUserQuestions, which is what dismisses the card.
    @State private var submittingQuestionCallId: String?
    @State private var questionErrorText: String?
    @State private var questionErrorCallId: String?
    @State private var answeredQuestionCallId: String?
    @State private var answeredQuestionNote: String?
    /// 问题三（滚动定位）：粘底语义——只有用户停在底部附近时才自动跟随新内容，
    /// 上滑阅读历史时绝不被强制拉回底部（交接文档 §7.4 第 2 条）。
    @State private var isNearBottom = true
    /// 问题三：用户是否**手动滚动过**。没有手动滚动之前，"贴最后一条消息"是硬约束
    /// （打开阶段 + 流式增长都持续跟随）；只有用户真的上滑，才交还给粘底语义。
    ///
    /// 不能再用几何阈值/快照落地来判断"打开阶段结束"：冷启动与流式增长时布局中间态
    /// 会让距离阈值瞬间判成"不在底部"，跟随就此停住，页面卡在会话中间
    /// （用户 2026-10-22 报障：点通知进入停在 turn 8，实际已到 turn 9）。
    @State private var userHasScrolled = false
    /// E2E-only：真实滚动几何快照（真机空白屏定位用，产品路径不渲染）。
    @State private var e2eScrollDebug = "offset=-;size=-;viewport=-"
    /// 兜底重锚次数：内容已就绪、用户没滚过却离底很远时自动拉回底部（最多 3 次）。
    @State private var bottomRecoveryAttempts = 0
    /// 贴底重锚代号 + 首屏加固次数（高频写入，放非观察容器避免逐次触发整页重绘）。
    @StateObject private var scrollAnchorState = ScrollAnchorState()
    /// 兜底重锚冷却时间（systemUptime），避免流式几何抖动反复触发滚动。
    @State private var lastRecoveryUptime: TimeInterval = 0
    /// 打开后的「贴底兜底」观察窗口截止时间：只在这段时间内做几何兜底，
    /// 之后不再逐帧观察，避免长期占用主线程（滚动卡顿）。
    @State private var bottomSettleDeadline: TimeInterval = 0

    init(address: SessionFollowAddress, subagentContext: SubagentSessionContext? = nil) {
        self.address = address
        self.sessionId = address.sessionId
        self.subagentContext = subagentContext
        _viewModel = StateObject(wrappedValue: SessionViewModel(address: address, subagentContext: subagentContext))
        _attachments = StateObject(wrappedValue: AttachmentStore(sessionId: address.sessionId))
    }

    private var currentApproval: ApprovalWaterfall? {
        app.link.pendingApprovals.first { approval in
            approval.agentId == nil || approval.agentId == sessionId
        }
    }

    var body: some View {
        // The interaction panel is a screen-edge overlay, never a layout sibling:
        // opening an approval must not resize the conversation (the old in-flow
        // panel pushed the whole session screen up). It covers the topmost layer
        // from the very bottom of the screen, surface + home-indicator band。
        sessionContent
            .background(Theme.Palette.background.ignoresSafeArea())
            .overlay {
                pendingInteractionOverlay
            }
        .task {
            viewModel.attach(link: app.link)
            attachments.attach(link: app.link)
            viewModel.start()
            #if DEBUG
            if let percent = e2eContextPreviewPercent {
                viewModel.installE2EContextPreview(percent: percent)
            }
            let modelPreviewMode = app.isE2EMode
                ? ProcessInfo.processInfo.environment["DSHM_E2E_MODEL"]
                : nil
            switch modelPreviewMode {
            case "1", "fake":
                // Isolated stack: deterministic fake catalog (screenshot only).
                viewModel.installE2EModelPreview()
                present(.modelSelection)
            case "entry":
                viewModel.installE2EModelPreview()
            case "open":
                // Real device evidence: real catalog + real sheet, no fake data.
                await viewModel.loadModelCatalogIfNeeded()
                present(.modelSelection)
            case "swap":
                // Real device evidence: real catalog + a real `session/selectModel`
                // round trip; the strip then shows the Host-confirmed selection.
                await viewModel.loadModelCatalogIfNeeded()
                if let target = viewModel.modelCatalog?.firstAlternativeSelection(
                    to: viewModel.modelSelection
                ) {
                    await viewModel.selectModel(target)
                }
            default:
                await viewModel.loadModelCatalogIfNeeded()
            }
            // Real-sheet evidence hooks (no data injection): open the permission
            // sheet / subagent list so their fitted height can be screenshot-checked.
            if app.isE2EMode,
               ProcessInfo.processInfo.environment["DSHM_E2E_PERMISSION"] == "1" {
                await viewModel.loadPermissionCatalogIfNeeded()
                present(.permission)
            }
            if app.isE2EMode,
               ProcessInfo.processInfo.environment["DSHM_E2E_SUBAGENT_LIST"] == "1" {
                present(.subagentList)
            }
            #else
            await viewModel.loadModelCatalogIfNeeded()
            #endif
            syncPendingPanel()
            if app.isE2EMode,
               ProcessInfo.processInfo.environment["DSHM_E2E_PANEL_COLLAPSED"] == "1" {
                pendingPanelCollapsed = true
            }
        }
        // v0.2.0 interaction panel: a new pending item expands the panel and
        // dismisses the composer keyboard; resolving everything restores the input.
        .onChange(of: pendingInteraction?.id) { _, _ in
            syncPendingPanel()
        }
        .task(id: viewModel.subagentCatalog.count) {
            // v5.5 §14.5: light 8s poll while the parent has subagents; every tick
            // refreshes the v5.4 runtimes and the v5.5 context window. The
            // activity-triggered 2s debounce lives in SessionViewModel.
            guard subagentContext == nil, !viewModel.subagentCatalog.isEmpty else { return }
            while !Task.isCancelled {
                await viewModel.refreshSessionListDerived(pendingApprovalAgentIds: pendingApprovalAgentIds)
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
        .onDisappear {
            viewModel.stop()
        }
        .onAppear {
            // 壳优先：header/返回/输入框/消息区骨架这一帧就上屏（幂等）。
            viewModel.markDetailShellFrame()
            // M2b-2c: detail in-app first-frame mark (idempotent).
            viewModel.markDetailViewAppeared()
            // 内容已在首帧前就绪（缓存命中窗口）时，onChange 不会触发，这里补标一次。
            if !viewModel.rows.isEmpty {
                markFirstContentAfterLayout()
            }
        }
        .overlay(alignment: .topLeading) {
            VStack(spacing: 0) {
                detailMetricsElement
                sendMetricsElement
                e2eHistoryFillElement
                e2eLinkDebugElement
            }
        }
        .onChange(of: app.link.generation) { generation in
            viewModel.handleGenerationChange(generation)
        }
        .onChange(of: app.link.phase) { _, phase in
            // P0 fallback: the generation-only path misses silent dsh-m/2 resumes
            // (P1 retain keeps the generation) and any phase flip that lands before
            // this `.onChange` is installed. The view-model call is idempotent, so
            // the extra trigger can never open a second `session/follow`.
            viewModel.handleLinkPhaseChange(phase)
        }
        .onChange(of: viewModel.isRunning) { _, running in
            // E2E in-app send metric: the running/turn indicator is now on screen.
            if running {
                viewModel.markSendTurnVisible()
            } else {
                // A finished turn is a natural refresh point: child runtimes and
                // the context window may have changed while the parent streamed.
                // The 8 s tick must not be the only source of truth for the beam.
                refreshDerivedState()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // A background gap can leave the last poll stale; refresh once when
            // we come back so the capsule never animates for a stopped child.
            guard phase == .active else { return }
            refreshDerivedState()
        }
        .onReceive(app.$silentPushRefreshVersion.dropFirst()) { _ in
            // M4 §4: refresh the open detail only when the silent push names this
            // session (nil = generic sync hint). AppModel already throttled ≥2s.
            let pushedSessionId = app.silentPushSessionId
            guard pushedSessionId == nil || pushedSessionId == sessionId else { return }
            viewModel.refreshFromSilentPush()
        }
        .overlay {
            detailSheetLayer
        }
    }

    // MARK: - v0.2.0 bottom popups

    /// Unified bottom popup layer: full width, anchored to the physical bottom
    /// edge (auto content + home-indicator band); drag the grabber down to
    /// dismiss. iOS 26 system sheets render as inset floating cards, so the
    /// popups are custom overlays.
    @ViewBuilder
    private var detailSheetLayer: some View {
        if let sheet = detailSheet {
            BottomSheetLayer(onDismiss: dismissSheet) {
                sheetBody(sheet)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func present(_ sheet: SessionDetailSheet) {
        withAnimation(Theme.Motion.standard) { detailSheet = sheet }
    }

    private func dismissSheet() {
        withAnimation(Theme.Motion.standard) { detailSheet = nil }
    }

    @ViewBuilder
    private func sheetBody(_ sheet: SessionDetailSheet) -> some View {
        switch sheet {
        case .tool(let item):
            ToolResultDetailView(item: item, sessionId: sessionId, attachments: attachments)
        case .fileChanges(let changes):
            FileChangesSheet(viewModel: viewModel, changes: changes)
        case .permission:
            PermissionSheet(
                permissionsValue: viewModel.permissionsValue,
                approvalPolicy: viewModel.approvalPolicy,
                sandboxMode: viewModel.sandboxMode,
                modelSelection: viewModel.modelSelectionText,
                presetOptions: viewModel.presetOptions,
                presetDefault: viewModel.presetDefault,
                isSwitching: viewModel.permissionSwitching,
                isCatalogLoading: viewModel.permissionCatalogLoading,
                errorText: viewModel.permissionSwitchError,
                onSelectPreset: { value in
                    Task { await viewModel.switchPermissionPreset(value) }
                },
                onRetryCatalog: {
                    Task { await viewModel.loadPermissionCatalogIfNeeded(force: true) }
                }
            )
        case .subagentList:
            SubagentListView(
                entries: subagentListEntries,
                runtimes: subagentListRuntimes
            ) { entry in
                app.openSubagentSession(entry, parentAddress: address, parentSessionId: sessionId)
                dismissSheet()
            }
        case .modelSelection:
            ModelSelectionSheet(
                catalog: viewModel.modelCatalog,
                current: viewModel.modelSelection,
                isLoading: viewModel.modelCatalogLoading,
                isSelecting: viewModel.modelSelecting,
                pending: viewModel.modelSelectionPending,
                errorText: viewModel.modelSelectionErrorText ?? viewModel.modelCatalogErrorText,
                onSelect: { selection in
                    Task { await viewModel.selectModel(selection) }
                },
                onRetry: {
                    Task { await viewModel.loadModelCatalogIfNeeded(force: true) }
                },
                onDismiss: dismissSheet
            )
        }
    }

    // MARK: - v0.2.0 bottom interaction overlay

    /// The normal session screen. It keeps the composer in place even while an
    /// interaction is pending; the panel covers it from above (overlay), so the
    /// conversation never jumps when an approval arrives.
    private var sessionContent: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.Palette.border).frame(height: 1)
            if viewModel.isShowingCachedWindow {
                cacheStatusBanner
            }
            messageList
            if let note = answeredQuestionNote {
                answeredQuestionRow(note)
            }
            SessionStatusStrip(
                permissionsValue: viewModel.permissionsValue,
                contextPressure: viewModel.contextPressure,
                modelTrigger: viewModel.modelTriggerState,
                subagentCount: stripSubagentCount,
                subagentRunning: stripSubagentRunning,
                onPermissionTap: {
                    present(.permission)
                    // M5: the preset catalog is a lazy read; a failed load keeps
                    // the sheet's retry affordance.
                    Task { await viewModel.loadPermissionCatalogIfNeeded() }
                },
                onModelTap: modelEntryPoint,
                onSubagentTap: subagentEntryPoint
            )
            composer
        }
    }

    /// Pending approval / user question. Overlays the composer (and part of the
    /// flow when tall); collapsing leaves only the disabled composer bar. The
    /// input must stay unusable until the approval/question is answered.
    @ViewBuilder
    private var pendingInteractionOverlay: some View {
        if let interaction = pendingInteraction {
            // The panel reaches the physical bottom edge: its content sits above
            // the home-indicator band it paints itself.
            ZStack(alignment: .bottom) {
                // Must not swallow taps: the session-header waiting badge has to
                // stay tappable so a collapsed panel can be re-expanded.
                Color.clear.allowsHitTesting(false)
                Group {
                    if pendingPanelCollapsed {
                        BlockedComposerBar(
                            kind: interaction.kind,
                            onTap: {
                                withAnimation(Theme.Motion.standard) { pendingPanelCollapsed = false }
                            }
                        )
                    } else {
                        PendingInteractionPanel(
                            interaction: interaction,
                            toolCall: approvalToolCall(interaction),
                            isSubmittingApproval: submittingApproval,
                            approvalErrorText: viewModel.actionErrorText,
                            onApprovalDecision: { outcome in
                                submitApproval(interaction, outcome: outcome)
                            },
                            questionIsSubmitting: questionIsSubmitting(interaction),
                            questionErrorText: currentQuestionErrorText(interaction),
                            onSubmitQuestion: { answers in
                                submitQuestion(interaction, answers: answers)
                            },
                            onSkipQuestion: { skipQuestion(interaction) },
                            onRetryQuestion: { retryQuestion(interaction) },
                            onCollapse: {
                                withAnimation(Theme.Motion.standard) { pendingPanelCollapsed = true }
                            },
                            maxContentHeight: pendingPanelMaxContentHeight
                        )
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var composer: some View {
        ComposerView(
            draft: $viewModel.draft,
            isConnected: app.link.phase.isConnected,
            isRunning: viewModel.isRunning,
            sending: viewModel.sending,
            queued: viewModel.queuedPrompts,
            isReadOnly: viewModel.isReadOnlySubagent,
            readOnlyReason: viewModel.subagentReadOnlyReason,
            onSend: { viewModel.submitDraft() },
            onAbort: {
                // T10: the pending live question belongs to the turn being
                // aborted; drop the card immediately instead of waiting for the
                // session/cancel round-trip or a $events cancel frame.
                viewModel.dismissLiveUserQuestionsForAbortedTurn()
                Task { await viewModel.abort() }
            },
            onSteerFirst: { viewModel.steerFirstQueued() }
        )
    }

    /// Upper bound of the interaction panel's scrollable content area.
    private var pendingPanelMaxContentHeight: CGFloat {
        max(220, UIScreen.main.bounds.height * 0.68 - SheetHeader<EmptyView>.height - 1)
    }

    private var modelEntryPoint: (() -> Void)? {
        guard viewModel.canSelectModel else { return nil }
        return {
            viewModel.clearModelSelectionError()
            present(.modelSelection)
            Task { await viewModel.loadModelCatalogIfNeeded() }
        }
    }

    /// One-shot refresh of the `session/list`-derived state (context window +
    /// child subagent runtimes). Called where freshness may have been lost — turn
    /// end, app foreground, silent push — so a stopped child cannot keep the
    /// capsule beam animating until the next steady 8 s tick.
    private func refreshDerivedState() {
        Task { await viewModel.refreshSessionListDerived(pendingApprovalAgentIds: pendingApprovalAgentIds) }
    }

    // MARK: - v0.2.0 pending interaction wiring

    private func syncPendingPanel() {
        guard let interaction = pendingInteraction else {
            pendingPanelCollapsed = false
            lastPendingId = nil
            return
        }
        guard interaction.id != lastPendingId else { return }
        lastPendingId = interaction.id
        withAnimation(Theme.Motion.standard) {
            pendingPanelCollapsed = false
        }
        dismissComposerKeyboard()
    }

    private func dismissComposerKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func approvalToolCall(_ interaction: PendingInteraction) -> ToolCallItem? {
        guard case .approval(let approval) = interaction else { return nil }
        return viewModel.toolCall(callId: approval.callId)
    }

    private func submitApproval(_ interaction: PendingInteraction, outcome: ApprovalOutcome) {
        guard case .approval(let approval) = interaction, !submittingApproval else { return }
        submittingApproval = true
        Task {
            await viewModel.respond(approval: approval, outcome: outcome)
            submittingApproval = false
        }
    }

    private func questionIsSubmitting(_ interaction: PendingInteraction) -> Bool {
        guard case .question(let call) = interaction else { return false }
        return submittingQuestionCallId == call.callId
    }

    private func currentQuestionErrorText(_ interaction: PendingInteraction) -> String? {
        guard case .question(let call) = interaction,
              questionErrorCallId == call.callId else { return nil }
        return questionErrorText
    }

    private func submitQuestion(_ interaction: PendingInteraction, answers: [UserQuestionAnswer]) {
        guard case .question(let call) = interaction else { return }
        if e2eUserQuestionPreview != nil {
            handleE2EUserQuestionPreviewSubmit(call)
        } else {
            submitUserQuestion(call, answers: answers)
        }
    }

    private func skipQuestion(_ interaction: PendingInteraction) {
        guard case .question(let call) = interaction else { return }
        if e2eUserQuestionPreview != nil {
            handleUserQuestionOutcome(.answered, callId: call.callId)
        } else {
            skipUserQuestion(call)
        }
    }

    private func retryQuestion(_ interaction: PendingInteraction) {
        guard case .question(let call) = interaction else { return }
        retryUserQuestion(call)
    }

    // MARK: - M2b-2c detail in-app metrics (E2E only)

    /// Invisible `detail-metrics` element read by `M2ALiveUITests`:
    /// `firstFrameMs=..;cacheHit=1;networkMs=..;beginEpochMs=..`.
    @ViewBuilder
    private var detailMetricsElement: some View {
        if let metrics = viewModel.detailMetricsValue {
            Text("detail-metrics")
                .font(.system(size: 1))
                .frame(width: 2, height: 2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("detail-metrics")
                .accessibilityLabel(metrics)
                .accessibilityValue(metrics)
        }
    }

    /// 体验收尾 invisible `send-metrics` element read by `M2ALiveUITests`:
    /// `tapToAcceptedMs=..;tapToTurnVisibleMs=..;queued=0;failed=0`.
    @ViewBuilder
    private var sendMetricsElement: some View {
        if let metrics = viewModel.sendMetricsValue {
            Text("send-metrics")
                .font(.system(size: 1))
                .frame(width: 2, height: 2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("send-metrics")
                .accessibilityLabel(metrics)
                .accessibilityValue(metrics)
        }
    }

    // MARK: - E2E autoload state (全量历史自动补齐, 2026-10-23)

    /// 隐藏元素 `e2e-history-fill`：后台自动补齐的诊断值（VM 只在 E2E/DEBUG 时写入，
    /// 产品路径为 nil → 不渲染）。前缀由 VM 固定为 state/pages/oldest/ms/rows/failures，
    /// 这里只在末尾追加滚动几何 key（不影响前缀顺序）。
    @ViewBuilder
    private var e2eHistoryFillElement: some View {
        if app.isE2EMode, let probe = viewModel.historyFillProbeValue {
            let value = probe
                + ";scrolled=" + (userHasScrolled ? "1" : "0")
                + ";nearBottom=" + (isNearBottom ? "1" : "0")
                + ";prepend=" + scrollAnchorState.lastPrependHandling
                + ";visible=" + String(scrollAnchorState.visibleRowIDs.count)
                + ";" + e2eScrollDebug
            Text("e2e-history-fill")
                .font(.system(size: 1))
                .frame(width: 2, height: 2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("e2e-history-fill")
                .accessibilityLabel(value)
                .accessibilityValue(value)
        }
    }

    // MARK: - E2E link state (跨网络用例的可观测判据, 2026-10-23)

    /// 隐藏元素：链路相位 + 连接代号。网络切换用例用它区分「已经重连成功」和
    /// 「只是旧内容还留在屏上」，并给出可测的重连耗时（轮询到 connected=1）。
    /// 格式：`connected=0|1;phase=<文案>;generation=<n>`。
    @ViewBuilder
    private var e2eLinkDebugElement: some View {
        if app.isE2EMode {
            let value = "connected=" + (app.link.phase.isConnected ? "1" : "0")
                + ";phase=" + app.link.phase.label
                + ";generation=" + String(app.link.generation)
            Text("e2e-link")
                .font(.system(size: 1))
                .frame(width: 2, height: 2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("e2e-link")
                .accessibilityLabel(value)
                .accessibilityValue(value)
        }
    }

    // MARK: - M2b-2 cache-first banner

    /// The cached window is on screen while the live `session/follow` snapshot is
    /// still in flight; it disappears by itself once the snapshot lands.
    private var cacheStatusBanner: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ProgressView()
                .tint(Theme.Palette.accent)
                .scaleEffect(0.7)
            Text(viewModel.cachedWindowIsStale
                 ? L10n.t("显示本地缓存（已过期），正在同步…")
                 : L10n.t("显示本地缓存，正在同步…"))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Palette.surface)
        .accessibilityIdentifier("session-cache-status")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
                viewModel.stop()
                // v5.4 task-13: child subagent -> parent session; normal -> list.
                app.backFromSession()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Theme.Palette.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.Palette.border, lineWidth: 1))
            }
            .accessibilityIdentifier("session-back")

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.title?.isEmpty == false ? (viewModel.title ?? "") : L10n.t("会话"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .accessibilityIdentifier("session-title")
                    // E2E hook (env-gated, no visible/product behavior): lets the
                    // push deep-link test prove which session the notification
                    // opened. Empty for normal users; VoiceOver reads the title.
                    .accessibilityValue(e2eSessionIdValue)
                HStack(spacing: 5) {
                    // v5.4: semantic connection dot replaces the old 在线 pill.
                    ConnectionDot(phase: app.link.phase)
                    Text(subtitle)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Theme.Spacing.xs)
            if let interaction = pendingInteraction {
                WaitingStatusBadge(
                    kind: interaction.kind,
                    collapsed: pendingPanelCollapsed
                ) {
                    withAnimation(Theme.Motion.standard) {
                        pendingPanelCollapsed.toggle()
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let cwd = app.link.credentials?.originURL?.host {
            parts.append(cwd)
        }
        if viewModel.isRunning {
            parts.append(L10n.t("运行中"))
        } else if !viewModel.rows.isEmpty {
            parts.append(L10n.t("空闲"))
        }
        return parts.joined(separator: " · ")
    }

    /// Test-only accessibility value exposing the opened session id (empty in
    /// normal use). The push deep-link test reads it from `session-title`.
    private var e2eSessionIdValue: String {
        app.isE2EMode ? "sessionId:\(sessionId)" : ""
    }

    /// v0.2.0 pending interaction: approvals and user questions share one bottom
    /// panel; approvals win while both are pending. E2E preview hooks keep the
    /// screenshot runs host-free.
    private var pendingInteraction: PendingInteraction? {
        if let approval = currentApproval { return .approval(approval) }
        if let preview = e2eApprovalPreview { return .approval(preview) }
        if let call = visibleUserQuestionCalls.first { return .question(call) }
        return nil
    }

    /// E2E-only context-window percentage injection ().
    private var e2eContextPreviewPercent: Int? {
        guard app.isE2EMode,
              let raw = ProcessInfo.processInfo.environment["DSHM_E2E_CONTEXT"],
              let percent = Int(raw), percent >= 0 else { return nil }
        return percent
    }

    /// E2E-only approval preview for the panel/layout evidence screenshots:
    /// `DSHM_E2E=1` + `DSHM_E2E_APPROVAL=1`.
    private var e2eApprovalPreview: ApprovalWaterfall? {
        guard app.isE2EMode,
              ProcessInfo.processInfo.environment["DSHM_E2E_APPROVAL"] == "1" else { return nil }
        return ApprovalWaterfall(
            eventId: "e2e-approval",
            agentId: nil,
            toolName: "bash",
            callId: "e2e-approval-call",
            reason: "预览：允许执行这次命令吗？",
            displayReason: "预览：允许执行这次命令吗？"
        )
    }

    /// Live approval waterfall owners (v5.4 task-13 subagent "等待作答" rows).
    private var pendingApprovalAgentIds: Set<String> {
        Set(app.link.pendingApprovals.compactMap(\.agentId))
    }

    // MARK: - Message list

    /// 平铺流的渲染分组：连续 reasoning/tool 行折成一个过程组，其余一行一组。
    /// 与桌面端一致：分组是行级的，不按 turn 分块。
    /// 2026-10-23 性能：分组结果由 SessionViewModel 缓存并随 rows 一起发布，
    /// body 直接读，不再每次渲染 O(rows) 重算（全量历史后 rows 可达 3000+）。
    private var flowGroups: [FlowRowGroup] {
        viewModel.flowGroups
    }

    /// 详情壳首帧的消息区占位：只在「还没有任何行、live 快照也没到」时出现。
    /// 静态无动画、无菊花——不是后台补齐进度提示，只是壳先出的骨架。
    private var messageSkeleton: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(Theme.Palette.surface)
                    .frame(maxWidth: index == 2 ? 220 : .infinity)
                    .frame(height: index == 1 ? 64 : 40)
                    .opacity(0.6)
            }
        }
        .padding(.top, Theme.Spacing.s)
        .allowsHitTesting(false)
        .accessibilityIdentifier("session-skeleton")
    }

    private var messageList: some View {
        let pendingCallIds = Set(app.link.pendingApprovals.compactMap(\.callId))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    if viewModel.isLoading {
                        HStack(spacing: Theme.Spacing.xs) {
                            ProgressView().tint(Theme.Palette.accent)
                            Text("正在加载会话…")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Spacing.xxl)
                    } else if viewModel.rows.isEmpty, viewModel.streamErrorText == nil {
                        if viewModel.hasLiveSnapshot {
                            EmptyStateView(
                                icon: "text.bubble",
                                title: "还没有消息",
                                message: "在下方输入框发一条消息开始这个会话。"
                            )
                            .accessibilityIdentifier("session-empty")
                        } else {
                            messageSkeleton
                        }
                    }

                    // 2026-10-23 用户拍板：删除 turn UI，与 DSH 桌面端一致——
                    // 会话是一条平铺消息流，每行/每个折叠过程组都是 LazyVStack
                    // 的直接子项（懒加载粒度从「整个 turn」降到「一行」）。
                    ForEach(Array(flowGroups.enumerated()), id: \.element.id) { index, group in
                        FlowRowGroupView(
                            group: group,
                            sessionId: sessionId,
                            attachments: attachments,
                            pendingApprovalCallIds: pendingCallIds,
                            subagentLabels: viewModel.subagentLabels,
                            isNewestGroupRunning: viewModel.isRunning && index == flowGroups.count - 1,
                            onOpenTool: { present(.tool($0)) }
                        )
                        .equatable()
                    }

                    // 最新一轮的文件变更（turn UI 删除后不再挂在 turn 收起区里）。
                    if let fileChanges = viewModel.latestTurnFileChanges {
                        FileChangesCard(changes: fileChanges) {
                            present(.fileChanges(fileChanges))
                        }
                    }

                    if !viewModel.liveAssistantText.isEmpty {
                        MarkdownText(text: viewModel.liveAssistantText)
                            .padding(Theme.Spacing.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                            .accessibilityIdentifier("live-assistant-stream")
                    }

                    if let errorText = viewModel.streamErrorText {
                        InlineErrorView(message: errorText) {
                            viewModel.retry()
                        }
                        .accessibilityIdentifier("session-stream-error")
                    }
                    if let actionError = viewModel.actionErrorText {
                        InlineErrorView(message: actionError)
                    }
                }
                .padding(.horizontal, Theme.Spacing.pageInset)
                .padding(.vertical, Theme.Spacing.s)
                // 自动补齐视口锚定（HistoryViewportAnchor）需要把每个流分组登记成滚动目标。
                .scrollTargetLayout()
                // 问题三关键修复：锚点必须放在 LazyVStack 外面。
                // 放里面时 LazyVStack 尚未实体化该行，scrollTo(bottom) 会按估算布局滚到
                // 非法位置；等内容上屏后视图停在 content 之外 → 整屏空白
                // （冷启动 / 通知深链进入时必现，从列表进入则不一定）。
                bottomSentinel
            }
            // 问题三 H1：首帧锚底。iOS 17+ 原生能力；初始内容即缓存窗口时这是唯一生效点。
            .defaultScrollAnchor(.bottom)
            // 问题三 H1：内容已在首帧前就绪（缓存窗口/历史窗口）时，
            // `.defaultScrollAnchor(.bottom)` 之外的这次补锚是唯一机会——onChange 不会触发。
            .onAppear {
                guard !viewModel.rows.isEmpty else { return }
                isNearBottom = true
                scrollAnchorState.hardeningRemaining = 2
                bottomSettleDeadline = ProcessInfo.processInfo.systemUptime + 5
                scrollToBottom(proxy: proxy)
            }
            // 打开阶段：只要用户还没手动滚动过，新内容到达就贴底（含流式增长）。
            .onChange(of: viewModel.hasLiveSnapshot) { _, live in
                guard live, !userHasScrolled else { return }
                isNearBottom = true
                // 快照替换/大窗口落屏：允许前 2 次多拍加固，之后单拍跟随。
                scrollAnchorState.hardeningRemaining = 2
                bottomSettleDeadline = ProcessInfo.processInfo.systemUptime + 5
                scrollToBottom(proxy: proxy)
            }
            // 粘底判定：iOS 18+ 用 ScrollGeometry 精确算距离；iOS 17 退化看底部锚点可见性。
            .modifier(StickToBottomObserver(isNearBottom: $isNearBottom))
            // 真机空白屏兜底 + E2E 滚动几何埋点（ScrollGeometry 仅 iOS 18+）。
            .modifier(ScrollBoundsWatch(
                debugEnabled: app.isE2EMode,
                e2eScrollDebug: $e2eScrollDebug,
                recoveryAttempts: $bottomRecoveryAttempts,
                lastRecoveryUptime: $lastRecoveryUptime,
                settleDeadline: bottomSettleDeadline,
                userHasScrolled: userHasScrolled,
                hasSections: !viewModel.rows.isEmpty,
                scrollToBottom: {
                    // 兜底重锚按「加固」处理：允许多拍让懒加载收敛。
                    scrollAnchorState.hardeningRemaining = max(scrollAnchorState.hardeningRemaining, 1)
                    scrollToBottom(proxy: proxy)
                }
            ))
            // 用户手动滚动后不再强制贴底（上滑读历史时新内容不得把视图拉回底部）。
            .modifier(UserScrollObserver { userHasScrolled = true })
            // 自动补齐阅读锚定：iOS 18+ 采集「当前可见的流分组 id」（写非观察容器，滚动不重绘）。
            .modifier(HistoryViewportAnchor(state: scrollAnchorState))
            // 首屏消息内容上屏（布局提交后标记，用于 tap→firstContent 口径；幂等）。
            .onChange(of: viewModel.rows.isEmpty) { _, isEmpty in
                guard !isEmpty else { return }
                markFirstContentAfterLayout()
            }
            // 后台自动补齐合并了一批更早历史 → 视口稳定（不含任何补齐提示）。
            .onChange(of: viewModel.historyBatchToken) { _, _ in
                handleHistoryPrepend(proxy: proxy)
            }
            .onChange(of: viewModel.rows) { oldRows, newRows in
                // 后台自动补齐只在列表最前面插入更早历史：尾部 id 不变、首行 id 变了。
                // 这类变化由 historyBatchToken 的处理器统一做视口稳定，绝不能进入贴底
                // 跟随，否则正在上滑读历史的用户会被拽回底部（用户拍板禁止）。
                let prependOnly = newRows.count > oldRows.count
                    && oldRows.first?.id != newRows.first?.id
                    && oldRows.last?.id == newRows.last?.id
                if prependOnly { return }
                // Keep the newest activity visible; LazyVStack off-screen rows are
                // not in the accessibility tree, so this also keeps the live tool
                // row reachable for UI automation.
                // 问题三 H2/H3：只在贴底时跟随，且等布局提交后再滚、不加动画
                // （动画会把 turn 结束时的高度突变放大成"跳飞"）。
                applySectionChange(proxy: proxy)
            }
            .onChange(of: viewModel.liveAssistantText) { _ in
                followLiveText(proxy: proxy)
            }
            // 问题三：ScrollView 的兄弟视图会改变视口高度（缓存横幅插在列表上方、
            // 底部问答提示插在列表下方），高度一变底部就会被裁掉，所以贴底时重锚一次。
            .onChange(of: viewModel.isShowingCachedWindow) { _ in
                rescrollIfNeeded(proxy: proxy)
            }
            .onChange(of: answeredQuestionCallId) { _ in
                rescrollIfNeeded(proxy: proxy)
            }
        }
    }

    // MARK: - 问题三：滚动锚定（首帧锚底 / 粘底 / 布局突变重锚）

    private static let bottomAnchorID = "bottom"

    /// 底部锚点：滚动目标 + iOS 17 上"是否接近底部"的退化探测点。
    private var bottomSentinel: some View {
        Color.clear
            .frame(height: 1)
            .id(Self.bottomAnchorID)
            .modifier(BottomSentinelFallback(isNearBottom: $isNearBottom))
    }

    /// 内容变化时的跟随策略：
    /// - 用户还没手动滚动过 → **无条件贴底**（打开即贴底，缓存窗口→live 窗口切换、
    ///   流式增长期间也持续贴底）；
    /// - 用户手动滚动过 → 只有当前还在底部附近才跟随（上滑读历史时绝不被拉回）。
    private func followNewContent(proxy: ScrollViewProxy) {
        guard !viewModel.rows.isEmpty else { return }
        if !userHasScrolled {
            isNearBottom = true
            scrollToBottom(proxy: proxy)
            return
        }
        guard isNearBottom else { return }
        scrollToBottom(proxy: proxy)
    }

    /// 新的会话 rows（缓存窗口 / 快照 / 增量事件）就绪。
    private func applySectionChange(proxy: ScrollViewProxy) {
        followNewContent(proxy: proxy)
    }

    /// 流式增量文本。
    private func followLiveText(proxy: ScrollViewProxy) {
        followNewContent(proxy: proxy)
    }

    /// 视口高度因兄弟视图插入/移除而变化时重新锚底。
    private func rescrollIfNeeded(proxy: ScrollViewProxy) {
        followNewContent(proxy: proxy)
    }

    /// H5：等布局提交后再滚，避免目标在 LazyVStack 里尚未实体化时 `scrollTo` 静默失效；
    /// 自动跟随一律不加动画（H2：动画会把高度突变放大成跳变）。
    private func scrollToBottom(proxy: ScrollViewProxy) {
        // 多拍重锚（真机 A3/A4 回归）：
        // 1) 只滚 LazyVStack 外的 bottomSentinel 时，大窗口会出现「offset 已在底部、
        //    但末段行没有实体化 → 整屏空白」；先滚最后一个 section（强制实体化末段），
        //    再滚 bottomSentinel 对齐底部。
        // 2) LazyVStack 高度估算要等行落定才收敛，大窗口需要 0/120/400ms 三拍。
        // 3) 每次贴底请求递增代号，旧请求的延迟拍自动作废，避免互相抢跑。
        scrollAnchorState.generation += 1
        let generation = scrollAnchorState.generation
        // 加固贴底只在打开/快照替换后的前 2 次请求里多拍；流式更新期间单拍，
        // 否则每次文本增量都会触发 3 次滚动 → 真机滚动卡顿/频闪（用户 2026-10-23）。
        let harden = scrollAnchorState.hardeningRemaining > 0
        if harden { scrollAnchorState.hardeningRemaining -= 1 }
        let passes: [UInt64] = harden ? [0, 120, 400] : [0]
        for (pass, delayMs) in passes.enumerated() {
            Task { @MainActor in
                if delayMs > 0 { try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
                guard generation == scrollAnchorState.generation else { return }
                await Task.yield()
                guard generation == scrollAnchorState.generation else { return }
                // 第 2 拍起先「唤醒末段实体化」：滚到最后一个 section 的**顶部**
                // （真实布局落点，不用估算），再滚 LazyVStack 外的 bottomSentinel
                // 对齐底部。顺序不能反：.bottom+未实体化目标会按估算落点，反而制造
                // 上方空白（模拟器 A3 对照实测）。
                if pass >= 1, !userHasScrolled, let lastRow = viewModel.rows.last?.id {
                    proxy.scrollTo(lastRow, anchor: .top)
                    await Task.yield()
                }
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    // MARK: - 后台自动补齐（全量历史）视口稳定

    /// 后台自动补齐合并了一批「更早历史」（只在列表最前面插入，尾部 id 不变）。
    ///
    /// 用户拍板：补齐完全无痕（无按钮/文案/进度/菊花），且视口不得被拽走——
    /// - 用户贴底（或打开后还没手动滚动过）→ 无动画把视口保持/贴回底部，内容不跳；
    /// - 用户已上滑读历史 → 用「当前视口最上方可见行」把阅读位置钉回原处，
    ///   **绝不**滚回底部；没有可用锚点（iOS 17 / 尚未采集）时宁可不滚动，也不拽底。
    private func handleHistoryPrepend(proxy: ScrollViewProxy) {
        scrollAnchorState.prependEpoch += 1
        let epoch = scrollAnchorState.prependEpoch
        if !userHasScrolled || isNearBottom {
            scrollAnchorState.lastPrependHandling = "pin"
            pinToBottomAfterPrepend(proxy: proxy, epoch: epoch)
            return
        }
        guard let anchorID = firstVisibleRowID() else {
            // iOS 17 无可见性 API / 尚未采集到可见行：宁可不滚动，也绝不拽回底部。
            scrollAnchorState.lastPrependHandling = "skip-no-anchor"
            return
        }
        scrollAnchorState.lastPrependHandling = "anchor:" + anchorID
        restoreReadingAnchor(proxy: proxy, anchorID: anchorID, epoch: epoch)
    }

    /// 首屏内容帧标记：等一次布局提交（yield 两拍）再标记，尽量贴近"内容真的可见"的时刻。
    /// 幂等由 VM 保证（detailFirstFrameMarked）。
    private func markFirstContentAfterLayout() {
        Task { @MainActor in
            await Task.yield()
            await Task.yield()
            viewModel.markDetailFirstContent()
        }
    }

    /// 当前视口内最上方（文档顺序最靠前）的可见行 id；prepend 后用它锚定阅读位置。
    private func firstVisibleRowID() -> String? {
        let visible = scrollAnchorState.visibleRowIDs
        guard !visible.isEmpty else { return nil }
        for group in flowGroups where visible.contains(group.id) {
            return group.id
        }
        return nil
    }

    /// 贴底保持：补齐只从顶部插入，末尾内容的位置语义不变，单拍无动画对齐底部。
    private func pinToBottomAfterPrepend(proxy: ScrollViewProxy, epoch: Int) {
        isNearBottom = true
        // 自动补齐每批都要贴底，不做首屏加固多拍（多拍 = 每批 3 次滚动 → 闪动）。
        scrollAnchorState.hardeningRemaining = 0
        scrollAnchorState.generation += 1
        let generation = scrollAnchorState.generation
        let lastRow = viewModel.rows.last?.id
        Task { @MainActor in
            await Task.yield()
            guard generation == scrollAnchorState.generation else { return }
            // 2026-10-23 真机回归（热缓存打开 13.2MB 大会话：补齐期间内容区全黑 3.5s，
            // 几何一直「贴底 + 尺寸正常」，但 AX 只有 3 行 → 末段行未实体化）：
            // 这是本文件 `scrollToBottom` 注释里记录过的已知问题——只滚 LazyVStack 外的
            // bottomSentinel 时 offset 已贴底、末段行却没实体化，渲染出整屏空白。
            // 补齐每批 prepend 后先滚真实末行强制实体化末段，再对齐 sentinel（顺序不能反，
            // 与 scrollToBottom 的 pass>=1 修复一致）；两次滚动同一拍提交，不引入多拍闪动。
            if let lastRow {
                proxy.scrollTo(lastRow, anchor: .top)
                guard generation == scrollAnchorState.generation else { return }
            }
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            // LazyVStack 前置插入后高度估算会再收敛一次；120ms 后补一拍校正。
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard epoch == scrollAnchorState.prependEpoch,
                  generation == scrollAnchorState.generation,
                  isNearBottom else { return }
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    /// 阅读位置锚定：把 prepend 前视口最上方的行重新对齐回视口顶部（无动画、不贴底）。
    private func restoreReadingAnchor(proxy: ScrollViewProxy, anchorID: String, epoch: Int) {
        Task { @MainActor in
            await Task.yield()
            guard epoch == scrollAnchorState.prependEpoch, !isNearBottom else { return }
            proxy.scrollTo(anchorID, anchor: .top)
            // 前置内容落定后再对齐一次；若新批次已到（新锚点由新批次负责）则放弃。
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard epoch == scrollAnchorState.prependEpoch, !isNearBottom else { return }
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }

    // MARK: - v5.5 status-strip entry points

    /// v5.5 §14.3/§14.6: tapping the icon-only subagent cell opens the half-sheet.
    private var subagentEntryPoint: (() -> Void)? {
        guard stripSubagentCount > 0 else { return nil }
        return { present(.subagentList) }
    }

    // MARK: - v5.5 E2E subagent preview (evidence only)

    /// The isolated simulator stack has no real subagents, but the v5.5 evidence
    /// run needs the running/idle capsule and a populated half-sheet. Opt in with
    /// `DSHM_E2E=1` + `DSHM_E2E_SUBAGENTS=running|idle` (same E2E scaffolding
    /// pattern as `DSHM_OPEN_FIRST_SESSION`); no product behavior otherwise.
    private var e2eSubagentPreviewMode: String? {
        guard app.isE2EMode else { return nil }
        let mode = ProcessInfo.processInfo.environment["DSHM_E2E_SUBAGENTS"]
        return mode == "running" || mode == "idle" ? mode : nil
    }

    private var stripSubagentCount: Int {
        e2eSubagentPreviewMode == nil ? viewModel.subagentCapsule.count : 3
    }

    private var stripSubagentRunning: Bool {
        e2eSubagentPreviewMode.map { $0 == "running" } ?? viewModel.subagentCapsule.isPulsing
    }

    /// Real projection data, unless the isolated-stack E2E screenshot hook is on.
    private var visibleUserQuestionCalls: [UserQuestionCall] {
        if let preview = e2eUserQuestionPreview {
            return answeredQuestionCallId == preview.callId ? [] : [preview]
        }
        guard !viewModel.isReadOnlySubagent else { return [] }
        return viewModel.activeUserQuestions
    }

    // MARK: - v5.6 user-question actions

    /// Answers one call. The view model owns path selection (unary vs live
    /// waterfall), the write-back and the projection refresh; on success it
    /// removes the call from activeUserQuestions, which dismisses the card.
    private func submitUserQuestion(_ call: UserQuestionCall, answers: [UserQuestionAnswer]) {
        guard submittingQuestionCallId == nil else { return }
        submittingQuestionCallId = call.callId
        questionErrorCallId = nil
        questionErrorText = nil
        Task {
            do {
                let outcome = try await viewModel.submitUserQuestionAnswers(callId: call.callId, answers: answers)
                handleUserQuestionOutcome(outcome, callId: call.callId)
            } catch {
                submittingQuestionCallId = nil
                questionErrorCallId = call.callId
                questionErrorText = NetworkErrorInterpreter.message(for: error)
            }
        }
    }

    /// Skip = one empty selection per question (protocol §3.7.2).
    private func skipUserQuestion(_ call: UserQuestionCall) {
        guard submittingQuestionCallId == nil else { return }
        submittingQuestionCallId = call.callId
        questionErrorCallId = nil
        questionErrorText = nil
        Task {
            do {
                let outcome = try await viewModel.skipUserQuestion(callId: call.callId)
                handleUserQuestionOutcome(outcome, callId: call.callId)
            } catch {
                submittingQuestionCallId = nil
                questionErrorCallId = call.callId
                questionErrorText = NetworkErrorInterpreter.message(for: error)
            }
        }
    }

    /// P1-2: the error banner's retry entry. A failed submit (typically
    /// `noLiveRequest` after the live waterfall was settled elsewhere) used to
    /// have no way to re-sync; this re-reads the projection + live pending list
    /// and clears the banner.
    private func retryUserQuestion(_ call: UserQuestionCall) {
        guard submittingQuestionCallId == nil else { return }
        submittingQuestionCallId = call.callId
        questionErrorCallId = nil
        questionErrorText = nil
        Task {
            await viewModel.refreshUserQuestions()
            submittingQuestionCallId = nil
        }
    }

    /// Every outcome is terminal for the card: the view model already removed the
    /// call locally and is re-syncing the projection. Keep a short acknowledgement
    /// row (uq-answered) while the card area collapses.
    private func handleUserQuestionOutcome(_ outcome: UserQuestionSubmitOutcome, callId: String) {
        submittingQuestionCallId = nil
        questionErrorCallId = nil
        questionErrorText = nil
        withAnimation(Theme.Motion.standard) {
            answeredQuestionCallId = callId
            switch outcome {
            case .answered, .answeredViaLiveEvents:
                answeredQuestionNote = L10n.t("已作答，等待会话继续")
            case .queued:
                answeredQuestionNote = L10n.t("已提交（排队中），等待会话继续")
            case .noLongerPending:
                answeredQuestionNote = L10n.t("该问答已失效或已在其他端作答")
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if answeredQuestionCallId == callId {
                withAnimation(Theme.Motion.quick) {
                    answeredQuestionCallId = nil
                    answeredQuestionNote = nil
                }
            }
        }
    }

    private func answeredQuestionRow(_ note: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
            Text(note)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Palette.accentSoft, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Palette.accentBorder, lineWidth: 1))
        .accessibilityIdentifier("uq-answered")
        .accessibilityElement(children: .combine)
    }

    /// Isolated-stack UI evidence hook. Variants (env `DSHM_E2E_USERQUESTION`):
    /// `single`/`1` (default): single-select + detail;
    /// `multi`: multi-select (3 options);
    /// `multi10`: eight questions (pager / scroll regression evidence);
    /// `error`: submit surfaces the uq-error banner instead of answering.
    private var e2eUserQuestionPreviewMode: String? {
        guard app.isE2EMode else { return nil }
        switch ProcessInfo.processInfo.environment["DSHM_E2E_USERQUESTION"] {
        case "1", "single": return "single"
        case "multi": return "multi"
        case "multi10": return "multi10"
        case "error": return "error"
        default: return nil
        }
    }

    private var e2eUserQuestionPreview: UserQuestionCall? {
        switch e2eUserQuestionPreviewMode {
        case "multi10":
            return UserQuestionCall(
                callId: "e2e-user-question-multi10",
                state: .continued,
                questions: (1...8).map { index in
                    UserQuestion(
                        id: "e2e-m10-\(index)",
                        question: "第 \(index) 题：这个探针应该使用哪种抓包模式？",
                        detail: index == 2
                            ? "长详情：waterfall 复用当前会话流；stream 单独开一条 probe 流。这段文案用来验证题目内容区限高、可滚动，而选项始终整块铺开。"
                            : nil,
                        header: "取证 \(index)/8",
                        options: [
                            UserQuestionOption(label: "waterfall", description: "复用当前会话流，最贴近真实链路"),
                            UserQuestionOption(label: "stream", description: "独立 probe 流，隔离性更好"),
                            UserQuestionOption(label: "packet", description: "只看抓包，不注入"),
                        ],
                        multiSelect: index % 3 == 0
                    )
                }
            )
        case "multi":
            return UserQuestionCall(
                callId: "e2e-user-question-multi",
                state: .continued,
                questions: [
                    UserQuestion(
                        id: "e2e-m1",
                        question: "需要包含哪些检查项？",
                        header: "检查项",
                        options: [
                            UserQuestionOption(label: "健康检查", description: "GET /api/remote.health"),
                            UserQuestionOption(label: "审计日志", description: "dsh-m-link audit.log"),
                            UserQuestionOption(label: "配对列表", description: "deviceEndpoints"),
                        ],
                        multiSelect: true
                    ),
                ]
            )
        case "single", "error":
            return UserQuestionCall(
                callId: "e2e-user-question",
                state: .continued,
                questions: [
                    UserQuestion(
                        id: "e2e-q1",
                        question: "这个探针应该使用哪种抓包模式？",
                        detail: "waterfall 复用当前会话流；stream 单独开一条 probe 流。",
                        header: "Gap capture",
                        options: [
                            UserQuestionOption(label: "waterfall", description: "复用当前会话流，最贴近真实链路"),
                            UserQuestionOption(label: "stream", description: "独立 probe 流，隔离性更好"),
                        ],
                        multiSelect: false
                    ),
                ]
            )
        default:
            return nil
        }
    }

    /// Preview-mode submit: `error` keeps the card and shows uq-error; the other
    /// variants close the card through the normal acknowledgement row.
    private func handleE2EUserQuestionPreviewSubmit(_ call: UserQuestionCall) {
        if e2eUserQuestionPreviewMode == "error" {
            submittingQuestionCallId = nil
            withAnimation(Theme.Motion.quick) {
                questionErrorCallId = call.callId
                questionErrorText = L10n.t("提交失败：连接已断开，请检查与 Mac 的连接后重试")
            }
        } else {
            handleUserQuestionOutcome(.answered, callId: call.callId)
        }
    }

    private var subagentListEntries: [SubagentCatalogEntry] {
        e2eSubagentPreviewMode == nil ? viewModel.subagentCatalog : Self.e2eSubagentEntries
    }

    private var subagentListRuntimes: [String: SubagentRuntime] {
        guard let mode = e2eSubagentPreviewMode else { return viewModel.subagentRuntimes }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return Dictionary(uniqueKeysWithValues: Self.e2eSubagentEntries.enumerated().map { index, entry in
            (entry.id, SubagentRuntime(
                sessionId: entry.id,
                isRunning: mode == "running" && index == 0,
                isWaitingAnswer: index == 1,
                lastActivityAt: now - Int64(index + 1) * 120_000,
                agentAvailable: true
            ))
        })
    }

    private static var e2eSubagentEntries: [SubagentCatalogEntry] {
        ["research", "reviewer", "writer"].enumerated().compactMap { index, label in
            SubagentCatalogEntry(json: .object([
                "id": .string("e2e-agent-\(index + 1)"),
                "createdAt": .int(1_760_000_000_000),
                "mode": .string(index == 2 ? "one-shot" : "continuable"),
                "label": .string("Agent Teams · \(label)"),
            ]))
        }
    }
}

/// One render unit of the flat conversation stream (desktop parity: no turn cards):
/// either a single row or a folded process group of consecutive reasoning/tool rows.
/// Only the newest group may show the running step (the desktop paints a single
/// tail indicator, never a per-turn status badge).
struct FlowRowGroupView: View, Equatable {
    var group: FlowRowGroup
    var sessionId: String
    @ObservedObject var attachments: AttachmentStore
    var pendingApprovalCallIds: Set<String> = []
    /// Child session id -> subagent catalog label (v5.4 collapsed relay cards).
    var subagentLabels: [String: String] = [:]
    /// True only for the last group while the session runs.
    var isNewestGroupRunning: Bool = false
    var onOpenTool: ((ToolCallItem) -> Void)? = nil

    /// 只比较影响渲染的值：流式更新时未变化的组直接跳过 body 重算
    /// （真机滚动卡顿/频闪修复的一半原因）。回调闭包与 attachments 不参与比较。
    static func == (lhs: FlowRowGroupView, rhs: FlowRowGroupView) -> Bool {
        lhs.group == rhs.group
            && lhs.sessionId == rhs.sessionId
            && lhs.pendingApprovalCallIds == rhs.pendingApprovalCallIds
            && lhs.subagentLabels == rhs.subagentLabels
            && lhs.isNewestGroupRunning == rhs.isNewestGroupRunning
    }

    private var axIdentifier: String {
        switch group {
        case .single: return "flow-row"
        case .process: return "process-group"
        }
    }

    var body: some View {
        Group {
            switch group {
            case .single(let row):
                FlowRowView(
                    row: row,
                    sessionId: sessionId,
                    attachments: attachments,
                    subagentLabels: subagentLabels,
                    onOpenTool: onOpenTool
                )
            case .process(let steps):
                ProcessGroupView(
                    steps: steps,
                    isRunning: isNewestGroupRunning,
                    sessionId: sessionId,
                    attachments: attachments,
                    pendingApprovalCallIds: pendingApprovalCallIds,
                    onOpenTool: onOpenTool
                )
            }
        }
        // SwiftUI 只会把 identifier 挂到「可访问元素」上：单个 Text/Markdown/卡片内部的
        // identifier 不会冒泡成元素，所以 XCUITest 数不到行。`children: .contain`
        // 把每个渲染单元显式包成一个可访问容器（子元素仍逐个可达，供点击/断言）。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(axIdentifier)
    }
}

/// Sheet slot shared by tool detail / file changes / permissions / subagents.
enum SessionDetailSheet: Identifiable {
    case tool(ToolCallItem)
    case fileChanges(TurnFileChanges)
    case permission
    /// v5.4 task-13: half-sheet subagent list of the parent session.
    case subagentList
    /// v0.2.0: composer model selection panel.
    case modelSelection

    var id: String {
        switch self {
        case .tool(let item): return "tool-\(item.id)"
        case .fileChanges(let changes): return "changes-\(changes.seq ?? -1)"
        case .permission: return "permission"
        case .subagentList: return "subagent-list"
        case .modelSelection: return "model-selection"
        }
    }
}

/// 自动补齐阅读锚定（iOS 18+）：把「当前视口内可见的流分组 id」写入非观察容器。
/// 只写普通 class 属性、不写 @State——滚动时逐帧写状态会让整个详情页重绘
/// （2026-10-23 真机反馈的滚动卡顿/频闪根因）。iOS 17 无此 API：不采集，
/// prepend 时宁可不滚动也不拽回底部（见 handleHistoryPrepend）。
private struct HistoryViewportAnchor: ViewModifier {
    let state: ScrollAnchorState
    /// 阈值取小值：让「刚在顶部露出一点」的行也进入集合，锚点更贴近真实视口顶部。
    private static let threshold: Double = 0.05

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollTargetVisibilityChange(
                idType: String.self,
                threshold: Self.threshold
            ) { ids in
                // 该 API 回调是 [ID]（可见顺序不定）；存成集合，锚定时再按文档顺序取最靠前的行。
                state.visibleRowIDs = Set(ids)
            }
        } else {
            content
        }
    }
}

/// 用户手动滚动的判定：iOS 18 用滚动阶段（`.interacting` 一定是手指拖动，
/// `.decelerating` 只会出现在手势之后）；iOS 17 用 simultaneousGesture 兜底。
/// 自动跟随是**无动画**的程序化滚动，不会进入 interacting/decelerating，
/// 因此不会把自己误判成"用户滚动"。
private struct UserScrollObserver: ViewModifier {
    let onUserScroll: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting, .decelerating:
                    onUserScroll()
                default:
                    break
                }
            }
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 8).onChanged { _ in onUserScroll() }
            )
        }
    }
}

/// 问题三：粘底判定。iOS 18+ 用 ScrollGeometry 精确计算"距底距离"，
/// 用户在底部附近（阈值内）才恢复自动跟随；上滑阅读时保持不动。
private struct StickToBottomObserver: ViewModifier {
    @Binding var isNearBottom: Bool
    /// 距底阈值：约一屏的 1/5，覆盖"用户只是轻轻上推一下"仍在底部的语义。
    private static let threshold: CGFloat = 140

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                let distance = geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.containerSize.height
                return distance <= Self.threshold
            } action: { _, near in
                isNearBottom = near
            }
        } else {
            content
        }
    }
}

/// 贴底重锚的代号与首屏加固次数（同上：高频写入，不参与渲染）。
private final class ScrollAnchorState: ObservableObject {
    var generation = 0
    var hardeningRemaining = 0
    /// iOS 18+：当前视口内可见的流分组 id 集合（iOS 18 的可见性回调写入）。
    /// 后台自动补齐 prepend 后用它把「正在读的那一行」锚回视口顶部，绝不拽回底部。
    /// 写普通 class 而不是 @State：滚动时不触发整页重绘。
    var visibleRowIDs: Set<String> = []
    /// 自动补齐批次代号：每前置一批 +1，旧批次的延迟校正自动作废。
    var prependEpoch = 0
    /// E2E 诊断：最近一批历史补齐的视口处理结果（pin / anchor:<id> / skip-no-anchor）。
    var lastPrependHandling = "-"
}

/// 真机空白屏兜底 + E2E 滚动几何埋点。
///
/// 2026-10-23 真机 A4 回归：推送重入一个「大窗口 + 运行中」会话时，列表区整屏空白，
/// 但 sections 非空、无 isLoading/empty-state（paging 埋点证明数据已到）——是
/// LazyVStack 高度估算与首帧贴底/流式增量抢跑，把视口留在了内容之外。
/// 这里在 iOS 18+ 用真实几何做两件事：
/// 1) 暴露 offset/size/viewport 给 E2E 测试（仅 DSHM_E2E 时被读取）；
/// 2) 兜底：有内容、用户没手动滚过、却离底 >120pt → 自动再贴底（最多 3 次）。
/// 正常上滑读历史时 userHasScrolled=true，不受影响。
private struct ScrollBoundsWatch: ViewModifier {
    /// 仅 DSHM_E2E 时写调试状态：每帧写 @State 会触发逐帧重绘 → 真机滚动卡顿/频闪。
    let debugEnabled: Bool
    @Binding var e2eScrollDebug: String
    @Binding var recoveryAttempts: Int
    @Binding var lastRecoveryUptime: TimeInterval
    /// 只在这个 systemUptime 之前做「贴底兜底」观察（打开/快照落屏窗口）。
    let settleDeadline: TimeInterval
    let userHasScrolled: Bool
    let hasSections: Bool
    let scrollToBottom: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: String.self) { geometry in
                    guard debugEnabled else { return "" }
                    return "offset=" + String(Int(geometry.contentOffset.y))
                        + ";size=" + String(Int(geometry.contentSize.height))
                        + ";viewport=" + String(Int(geometry.containerSize.height))
                } action: { _, value in
                    guard debugEnabled else { return }
                    e2eScrollDebug = value
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height)
                } action: { _, distance in
                    guard !userHasScrolled, hasSections else { return }
                    guard ProcessInfo.processInfo.systemUptime < settleDeadline else { return }
                    if distance <= 120 {
                        // 只在需要时写状态：每帧写 @State 会让整页重绘（滚动卡顿根因）。
                        if recoveryAttempts != 0 { recoveryAttempts = 0 }
                        return
                    }
                    guard recoveryAttempts < 3 else { return }
                    // 冷却 1s：流式增量时几何会抖动，避免反复触发滚动。
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now - lastRecoveryUptime > 1.0 else { return }
                    lastRecoveryUptime = now
                    recoveryAttempts += 1
                    scrollToBottom()
                }
        } else {
            content
        }
    }
}

/// iOS 17 退化路径：LazyVStack 只有接近视口才实体化底部锚点，
/// 因此"锚点在视图树上"≈"用户离底部不超过约一屏"。
private struct BottomSentinelFallback: ViewModifier {
    @Binding var isNearBottom: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
        } else {
            content
                .onAppear { isNearBottom = true }
                .onDisappear { isNearBottom = false }
        }
    }
}

#Preview {
    SessionDetailView(address: .session(sessionId: "session-preview"))
        .environmentObject(AppModel())
}
