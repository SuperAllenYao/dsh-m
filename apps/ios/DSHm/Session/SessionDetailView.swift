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
    /// 问题三 + 问题一：向上加载更早历史时的视觉锚点（旧的首条 section id）。
    /// 前置插入会让可见内容整体下移，加载完成后用它把旧视口重新钉回顶部。
    @State private var pendingPrependAnchorID: String?

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
            // M2b-2c: detail in-app first-frame mark (idempotent).
            viewModel.markDetailViewAppeared()
        }
        .overlay(alignment: .topLeading) {
            VStack(spacing: 0) {
                detailMetricsElement
                sendMetricsElement
            }
        }
        .onChange(of: app.link.generation) { generation in
            viewModel.handleGenerationChange(generation)
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
        // E2E paging self-test (env-gated, DEBUG): 自动向上翻页到最早事件，用来在真机上
        // 验证 turn 分组/终止条件，无需手势。DSHM_E2E_PAGING=1 时启动。
        .task(id: viewModel.hasLiveSnapshot) {
            guard app.isE2EMode,
                  ProcessInfo.processInfo.environment["DSHM_E2E_PAGING"] == "1",
                  viewModel.hasLiveSnapshot,
                  viewModel.hasMoreOlder else { return }
            for _ in 0..<40 {
                guard viewModel.hasMoreOlder else { break }
                viewModel.loadOlderIfNeeded()
                var spins = 0
                while viewModel.isLoadingOlder, spins < 100 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    spins += 1
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            NSLog("[STREAMDBG] paging self-test done: hasMoreOlder=%@ oldest=%@", String(viewModel.hasMoreOlder), String(viewModel.oldestLoadedSeq ?? -1))
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
        } else if !viewModel.sections.isEmpty {
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

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    if viewModel.hasMoreOlder || viewModel.isLoadingOlder {
                        loadOlderRow
                    }
                    if viewModel.isLoading {
                        HStack(spacing: Theme.Spacing.xs) {
                            ProgressView().tint(Theme.Palette.accent)
                            Text("正在加载会话…")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Spacing.xxl)
                    } else if viewModel.sections.isEmpty, viewModel.streamErrorText == nil {
                        EmptyStateView(
                            icon: "text.bubble",
                            title: "还没有消息",
                            message: "在下方输入框发一条消息开始这个会话。"
                        )
                        .accessibilityIdentifier("session-empty")
                    }

                    ForEach(viewModel.sections) { section in
                        TurnSectionView(
                            section: section,
                            expandedTurnIDs: $viewModel.expandedTurnIDs,
                            sessionId: sessionId,
                            attachments: attachments,
                            pendingApprovalCallIds: Set(app.link.pendingApprovals.compactMap(\.callId)),
                            subagentLabels: viewModel.subagentLabels,
                            onOpenTool: { present(.tool($0)) },
                            fileChanges: viewModel.turnFileChanges(for: section),
                            onOpenFileChanges: { present(.fileChanges($0)) }
                        )
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
                guard !viewModel.sections.isEmpty else { return }
                isNearBottom = true
                scrollToBottom(proxy: proxy)
            }
            // 打开阶段：只要用户还没手动滚动过，新内容到达就贴底（含流式增长）。
            .onChange(of: viewModel.hasLiveSnapshot) { _, live in
                guard live, !userHasScrolled else { return }
                isNearBottom = true
                scrollToBottom(proxy: proxy)
            }
            // 粘底判定：iOS 18+ 用 ScrollGeometry 精确算距离；iOS 17 退化看底部锚点可见性。
            .modifier(StickToBottomObserver(isNearBottom: $isNearBottom))
            // 用户手动滚动后不再强制贴底（上滑读历史时新内容不得把视图拉回底部）。
            .modifier(UserScrollObserver { userHasScrolled = true })
            // 问题一对接：滑到接近顶部自动加载更早历史（问题一的分页状态机由 SessionViewModel 提供）。
            .modifier(NearTopObserver(onPullAtTop: triggerLoadOlder))
            .onChange(of: viewModel.isLoadingOlder) { _, loading in
                if !loading { restorePrependAnchor(proxy: proxy) }
            }
            .onChange(of: viewModel.sections) { _ in
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
        guard !viewModel.sections.isEmpty else { return }
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
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    /// 顶部"加载更早"兜底入口：自动触发失败时可手动重试；加载中显示菊花。
    private var loadOlderRow: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Spacer(minLength: 0)
            if viewModel.isLoadingOlder {
                ProgressView().tint(Theme.Palette.accent)
                Text("正在加载更早的消息…")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            } else {
                Button {
                    viewModel.loadOlderIfNeeded()
                } label: {
                    Text("加载更早的消息")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityIdentifier("session-load-older")
        // iOS 17 退化触发点：这一行被实体化说明用户已滑到顶部附近。
        .modifier(TopRowTrigger(onAppear: triggerLoadOlder))
    }

    /// 滑近顶部自动加载更早历史；到底/并发由 ViewModel 的 loadOlderIfNeeded 去重。
    private func triggerLoadOlder() {
        guard viewModel.hasMoreOlder, !viewModel.isLoadingOlder else { return }
        if pendingPrependAnchorID == nil {
            pendingPrependAnchorID = viewModel.sections.first?.id
        }
        viewModel.loadOlderIfNeeded()
    }

    /// 前置插入完成后，把旧的视口首条重新钉回顶部，避免用户"读着读着被推下去"。
    private func restorePrependAnchor(proxy: ScrollViewProxy) {
        guard let anchor = pendingPrependAnchorID else { return }
        pendingPrependAnchorID = nil
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(anchor, anchor: .top)
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

/// One turn: collapsed summary when completed, expanded while running.
struct TurnSectionView: View {
    var section: TurnSection
    @Binding var expandedTurnIDs: Set<String>
    var sessionId: String
    @ObservedObject var attachments: AttachmentStore
    var pendingApprovalCallIds: Set<String> = []
    /// Child session id -> subagent catalog label (v5.4 collapsed relay cards).
    var subagentLabels: [String: String] = [:]
    var onOpenTool: ((ToolCallItem) -> Void)? = nil
    var fileChanges: TurnFileChanges? = nil
    var onOpenFileChanges: ((TurnFileChanges) -> Void)? = nil

    /// v5.3: consecutive reasoning + tool-call rows fold into one process group;
    /// everything else is a normal row.
    private var rowGroups: [FlowRowGroup] {
        SessionFlowGrouping.groups(rows: section.rows)
    }

    private var isExpanded: Bool {
        section.isRunning || expandedTurnIDs.contains(section.id)
    }

    private var statusColor: Color {
        switch section.status {
        case .running: return Theme.Palette.accent
        case .completed: return Theme.Palette.textTertiary
        case .aborted, .interrupted: return Theme.Palette.warning
        case .error: return Theme.Palette.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Button {
                guard !section.isRunning else { return }
                withAnimation(Theme.Motion.quick) {
                    if isExpanded {
                        expandedTurnIDs.remove(section.id)
                    } else {
                        expandedTurnIDs.insert(section.id)
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Text("Turn \(section.turn)")
                        .font(Theme.Typography.captionMedium)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Text(section.shortSummary)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Spacing.xs)
                    StatusDot(color: statusColor, size: 5, pulsing: section.isRunning)
                    Text(section.status.label)
                        .font(Theme.Typography.label)
                        .foregroundStyle(statusColor)
                        .accessibilityIdentifier("turn-status-\(section.turn)")
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .padding(Theme.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(section.isRunning ? Theme.Palette.accentBorder : Theme.Palette.border, lineWidth: 1)
            )
            .accessibilityIdentifier("turn-header-\(section.turn)")

            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(rowGroups) { group in
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
                                isRunning: section.isRunning,
                                sessionId: sessionId,
                                attachments: attachments,
                                pendingApprovalCallIds: pendingApprovalCallIds,
                                onOpenTool: onOpenTool
                            )
                        }
                    }
                    if let fileChanges {
                        FileChangesCard(changes: fileChanges) { onOpenFileChanges?(fileChanges) }
                    }
                }
                .padding(.leading, Theme.Spacing.xxs)
            }
        }
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

/// 问题一/问题三：**每次下拉手势**到达顶部时加载一页更早历史。
///
/// 旧实现只在"是否贴顶"这个 Bool 翻转时触发。但前置加载完成后锚点恢复会把视口
/// 留在顶部附近，Bool 一直是 true、不再翻转，于是后面几次下拉完全不触发，
/// 用户只能去点按钮（2026-10-22 报障）。修正后改为：
/// - 用 ScrollGeometry 持续跟踪"是否在顶部附近"；
/// - 用户每一次滚动手势结束（interacting/decelerating → idle）时，只要还在顶部附近
///   就触发一次加载 —— 天然做到"一次下拉加载一页"，不会无节制连发。
///
/// 2026-10-22 二次反馈："加载更早的消息"出现后稍微一滑就自动加载，极易误触。
/// 因此把触发所需的滑动距离整体放大 2 倍（120 → 240），并额外要求**本次手势
/// 实际向上拉动的距离**也 ≥ 240pt：只认"用户真的把内容拉上去一屏"，
/// 贴顶状态下的小幅抖动不再触发。程序化跟随是瞬时无动画滚动，不产生
/// interacting/decelerating，因此不会自我触发。
/// 常量集中在 `Trigger`，真机微调手感只改这一处。
/// iOS 17 由顶部加载行是否实体化兜底（TopRowTrigger）。
/// 「下拉加载更早」的触发判定，抽成纯逻辑以便单测（真机手势仍需 UITest 覆盖）。
///
/// 关键口径：量的是 **contentOffset 的下降量**（内容被向上拉动的距离），不是手指位移。
/// 已经贴顶时继续下拉会进入 rubber-band，offset 变负、松手又弹回 0 ——
/// 所以必须在滚动过程中累计**峰值**，不能在手势结束时用起止 offset 相减
/// （2026-10-22 真机回归：贴顶下拉永远算成 0，加载彻底失效）。
struct NearTopPullTracker: Equatable {
    /// 触发条件（集中调参处；真机调手感只改这一处）。
    enum Trigger {
        /// 视口距顶部多少 pt 以内算"已到达顶部附近"。
        static let nearTopThreshold: CGFloat = 240
        /// 本次手势实际向上拉动的距离下限（相对原 120 放大 2 倍）。
        static let minimumPullDistance: CGFloat = 240
    }

    /// 最近一次 ScrollGeometry 提交的 contentOffset.y。
    private(set) var offsetY: CGFloat = 0
    /// 当前视口是否在顶部附近（用于手势结束时的判定）。
    private(set) var isNearTop = true
    /// 本次用户手势开始时的 contentOffset.y（nil = 当前没有进行中的手势）。
    private var startOffsetY: CGFloat?
    /// 本次手势过程中累计的最大向上拉动距离（含 rubber-band 峰值）。
    private(set) var maxPullDistance: CGFloat = 0

    /// 每次 ScrollGeometry 变化都调用；手势进行中会累计拉动峰值。
    mutating func updateOffset(_ y: CGFloat) {
        if let start = startOffsetY {
            maxPullDistance = max(maxPullDistance, start - y)
        }
        offsetY = y
        isNearTop = y <= Trigger.nearTopThreshold
    }

    /// 用户手势开始（ScrollPhase 进入 .interacting）。
    mutating func gestureBegan() {
        startOffsetY = offsetY
        maxPullDistance = 0
    }

    /// 用户手势结束（.interacting/.decelerating → .idle）：返回是否应加载一页，并清空手势状态。
    mutating func gestureEnded() -> Bool {
        let triggered = isNearTop && maxPullDistance >= Trigger.minimumPullDistance
        resetGesture()
        return triggered
    }

    /// 手势未以"用户驱动"方式结束（或需要显式清理）时调用，避免陈旧峰值串到下一次手势。
    mutating func resetGesture() {
        startOffsetY = nil
        maxPullDistance = 0
    }
}

private struct NearTopObserver: ViewModifier {
    let onPullAtTop: () -> Void
    @State private var tracker = NearTopPullTracker()

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, y in
                    tracker.updateOffset(y)
                }
                .onScrollPhaseChange { previousPhase, phase in
                    switch phase {
                    case .interacting:
                        if previousPhase != .interacting { tracker.gestureBegan() }
                    case .idle:
                        let wasUserDriven = previousPhase == .interacting || previousPhase == .decelerating
                        if wasUserDriven {
                            if tracker.gestureEnded() { onPullAtTop() }
                        } else {
                            tracker.resetGesture()
                        }
                    default:
                        break
                    }
                }
        } else {
            content
        }
    }
}

/// iOS 17 退化：顶部加载行进入视图树即视为"用户已接近顶部"。
private struct TopRowTrigger: ViewModifier {
    let onAppear: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
        } else {
            content.onAppear(perform: onAppear)
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
