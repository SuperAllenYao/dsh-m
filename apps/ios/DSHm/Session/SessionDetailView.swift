import Combine
import SwiftUI

/// 消息流 item 构建的纯函数（#1：主会话 running 期间不产生「本轮文件变更」行）。
/// 抽成纯函数让「卡片可见性」可直接单测，不需要起 SwiftUI 视图。
enum SessionMessageItemsBuilder {
    static func build(
        groups: [FlowRowGroup],
        isRunning: Bool,
        fileChanges: TurnFileChanges?,
        processPreviewSteps: [ProcessStep]?,
        liveProcessSteps: [ProcessStep] = [],
        liveAssistantText: String,
        streamErrorText: String?,
        actionErrorText: String?
    ) -> [SessionMessageItem] {
        var items: [SessionMessageItem] = []
        items.reserveCapacity(groups.count + 4)
        for group in groups { items.append(.group(group)) }
        if let processPreviewSteps {
            items.append(.group(.process(processPreviewSteps)))
        }
 // v6：实时步骤（实时思考 / 工具准备行）并入最后一个过程组；若末行不是过程组
 // 则自成一组排到末尾（组头计步数与运行态随实时行更新）。
        if !liveProcessSteps.isEmpty {
            if let lastIndex = items.indices.last, case .group(.process(let steps)) = items[lastIndex] {
                items[lastIndex] = .group(.process(steps + liveProcessSteps))
            } else {
                items.append(.group(.process(liveProcessSteps)))
            }
        }
 // #1 设计决策：卡片只在主会话不执行任务时存在；
 // running 期间完全不渲染（不占位、不转圈）。
        if !isRunning, let fileChanges {
            items.append(.fileChanges(fileChanges))
        }
        if !liveAssistantText.isEmpty {
            items.append(.liveText(liveAssistantText))
        }
        if let streamErrorText {
            items.append(.streamError(streamErrorText))
        }
        if let actionErrorText {
            items.append(.actionError(actionErrorText))
        }
        return items
    }
}

/// Session detail (v5 03/04): turn-grouped message flow + status strip + composer,
/// with approval / permission sheets driven by $events and projections.
struct SessionDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let address: SessionFollowAddress
    let sessionId: String
 /// v5.4 task-13: non-nil when this detail is a child subagent session.
    let subagentContext: SubagentSessionContext?
 /// 是否在导航栈顶（RootView 注入）：被上层详情覆盖时暂停派生发布（P0）。
    @Environment(\.sessionDetailIsTopmost) private var sessionDetailIsTopmost

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
 /// （用户 报障：点通知进入停在 turn 8，实际已到 turn 9）。
    @State private var userHasScrolled = false
 /// 强制回底请求序号：发送消息 / 答完问答时 +1，UIKit 列表据此钉住 offset 0
 /// （读历史时冻结尾部内容，发送后必须立刻看到自己刚发的消息）。
    @State private var scrollToBottomToken = 0
 /// v0.2.7：过程组显示态覆盖（key = `FlowRowGroup.id`，已用首 step 作稳定 id）。
 /// 默认态由「是否正在跑」推导：运行中.window（固定高度窗口）/ 已结束.collapsed（一行）；
 /// 用户点击写入覆盖；这一轮结束自动清掉运行期覆盖（→ 自动折叠）。
    @State private var processGroupModes: [String: ProcessGroupMode] = [:]

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
 // E2E 注入闸门：基线会话详情页实际出现（push tap / 网络切换
 // 注入以此为 t0 计延迟，杜绝「注入早于测试基线」的假红）。
            app.noteE2EDetailAppeared(sessionId: sessionId)
 // task-4 E2E seam: inject a synthetic exact changes summary
 // (DSHM_E2E=1 + DSHM_E2E_CHANGES_SUMMARY) so the cross-end title口径
 // (Host total=50 vs files.length=18) is assertable on a real device.
 // DEBUG-only; product launches never set these env vars.
            if app.isE2EMode {
                viewModel.installE2EChangesSummaryPreviewIfRequested()
 // 文件对比 E2E：sheet → 行 → diff 页可显示注入的 hunk（DSHM_E2E_CHANGES_DIFF）。
                viewModel.installE2EChangesDiffPreviewIfRequested()
            }
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
            #if DEBUG
            if ProcessInfo.processInfo.environment["DSHM_E2E"] == "1" {
                NSLog("[NAVLIFE] detail disappear session=%@ sub=%d", sessionId, subagentContext != nil ? 1 : 0)
            }
            #endif
 // R2 (design 2.4): persist the composer draft on leave (the 500 ms
 // debounce may still be pending); an empty draft removes the file.
            viewModel.flushDraft()
            viewModel.stop()
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["DSHM_E2E"] == "1" {
                NSLog("[NAVLIFE] detail appear session=%@ sub=%d", sessionId, subagentContext != nil ? 1 : 0)
            }
            #endif
 // P0：被子会话覆盖时父页暂停派生发布（数据加载/订阅不暂停）。
            viewModel.setDetailCovered(!sessionDetailIsTopmost)
 // 壳优先：header/返回/输入框/消息区骨架这一帧就上屏（幂等）。
            viewModel.markDetailShellFrame()
 // M2b-2c: detail in-app first-frame mark (idempotent).
            viewModel.markDetailViewAppeared()
 // 内容已在首帧前就绪（缓存命中窗口）时，onChange 不会触发，这里补标一次。
            if !viewModel.rows.isEmpty {
                markFirstContentAfterLayout()
            }
        }
        .onChange(of: sessionDetailIsTopmost) { _, topmost in
 // 回到栈顶：立即补一次发布（setDetailCovered 内部 flush pending rebuild）。
            viewModel.setDetailCovered(!topmost)
        }
        .overlay(alignment: .topLeading) {
            VStack(spacing: 0) {
                detailMetricsElement
                sendMetricsElement
                e2eHistoryFillElement
                e2eFollowProbeElement
                e2eLinkDebugElement
                e2ePathChangeTriggerElement
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
 // v6：v6 默认态已是.expanded，旧的
 // 「filter ==.expanded」等于把用户手动收起的组也一起丢掉，下一帧按
 // 默认态全部弹开。现在只保留用户收起覆盖，旧.window/.full 运行态
 // 覆盖按 resolver 回落 expanded。
                processGroupModes = ProcessGroupModeResolver.prunedAfterTurnEnd(processGroupModes)
 // A finished turn is a natural refresh point: child runtimes and
 // the context window may have changed while the parent streamed.
 // The 8 s tick must not be the only source of truth for the beam.
                refreshDerivedState()
            }
        }
        .onChange(of: scenePhase) { _, phase in
 // R2 (design 2.4): backgrounding while editing persists the draft
 // right away — the debounce may never fire after suspension.
            if phase != .active { viewModel.flushDraft() }
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
        case .reasoning(let text):
            ReasoningDetailSheet(text: text)
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
 // 真机闪回修复：不再插入「显示本地缓存，正在同步…」横幅。
 // 横幅随快照到达而移除，会让列表高度突变 → 内容上跳/回落 + 一帧整页闪烁；
 // 热缓存每次打开必现。首屏缓存本来就是无感加速，不需要这条提示。
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
            onSend: {
                viewModel.submitDraft()
 // 发送后强制回到底部：读历史时也立即看到自己刚发的消息（§6.2 回归点）。
                scrollToBottomToken += 1
            },
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

 // MARK: - E2E autoload state (全量历史自动补齐)

 /// 隐藏元素 `e2e-history-fill`：后台自动补齐的诊断值（VM 只在 E2E/DEBUG 时写入，
 /// 产品路径为 nil → 不渲染）。前缀由 VM 固定为 state/pages/oldest/ms/rows/failures，
 /// 这里只在末尾追加滚动几何 key（不影响前缀顺序）。
 /// E2E follow lifecycle probe (blank-session realtime regression).
 ///
 /// E2E-gated: it used to render unconditionally, and reading
 /// `viewModel.followProbeValue` here made the whole detail body depend on a
 /// follow-frame `@Published` — every follow frame invalidated this view
 /// during the initial load / history fill (the exact recompute source the
 /// 250 ms probe coalescing was added for). XCUITest suites launch with
 /// `DSHM_E2E=1`, so the marker is still there for them; product builds no
 /// longer pay for it.
    @ViewBuilder
    private var e2eFollowProbeElement: some View {
        if app.isE2EMode {
            Text("probe")
                .font(.system(size: 1))
                .frame(width: 2, height: 2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("e2e-follow-probe")
                .accessibilityLabel(viewModel.followProbeValue)
                .accessibilityValue(viewModel.followProbeValue)
        }
    }

    @ViewBuilder
    private var e2eHistoryFillElement: some View {
        if app.isE2EMode, let probe = viewModel.historyFillProbeValue {
            let value = probe
                + ";scrolled=" + (userHasScrolled ? "1" : "0")
                + ";nearBottom=" + (isNearBottom ? "1" : "0")
                + ";prepend=-"
                + ";visible=0"
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

 // MARK: - E2E link state (跨网络用例的可观测判据)

 /// 隐藏元素：链路相位 + 连接代号。网络切换用例用它区分「已经重连成功」和
 /// 「只是旧内容还留在屏上」，并给出可测的重连耗时（轮询到 connected=1）。
 /// 格式：`connected=0|1;phase=<文案>;generation=<n>;switchMs=<n>`。
 /// `switchMs` = 最近一次网络切换信号 → 连接成功的 App 侧真实耗时（毫秒，
 /// -1 表示本进程还没有切换锚定的重连），E2E 断言与手动切换验收都读它。
    @ViewBuilder
    private var e2eLinkDebugElement: some View {
        if app.isE2EMode {
            let value = "connected=" + (app.link.phase.isConnected ? "1" : "0")
                + ";phase=" + app.link.phase.label
                + ";generation=" + String(app.link.generation)
                + ";switchMs=" + String(app.link.lastSwitchReconnectMs ?? -1)
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

 /// E2E 隐藏触发器：网络切换用例在**读完基线后**由测试 tap 它，
 /// 走与真实切换完全相同的 `simulateNetworkPathChangeForE2E` 路径。
 /// 取代旧的 `DSHM_E2E_SIMULATE_PATH_CHANGE_AFTER_MS` 定时注入——设备繁忙时
 /// 测试侧基线读取慢于注入延迟，generation 基线读到切换后的值，断言假红
 /// 。测试驱动 = 零竞态，测试时长也省 ~25s。
    @ViewBuilder
    private var e2ePathChangeTriggerElement: some View {
        if app.isE2EMode {
            Button {
                app.link.simulateNetworkPathChangeForE2E()
            } label: {
 // Color.clear 本身不渲染也不挡视觉；不能用.opacity —— 低透明度
 // 会禁用 SwiftUI 命中测试，tap 打不中。
                Color.clear
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .accessibilityIdentifier("e2e-path-change-trigger")
        }
    }

 // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
 // probe evidence: the list's onAppear/refreshBlankCardState
 // runs ~580 ms BEFORE this view's onDisappear, so a draft still in
 // its 500 ms debounce window was not on disk yet when the list
 // refreshed — the blank card was pruned. Flush synchronously
 // before the pop; onDisappear keeps covering edge-swipe back.
                viewModel.flushDraft()
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

 // title only — the host · 运行中/空闲 subtitle row below the
 // title was removed by requirement (no small second line in the header).
            Text(viewModel.title?.isEmpty == false ? (viewModel.title ?? "") : L10n.t("会话"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .accessibilityIdentifier("session-title")
 // E2E hook (env-gated, no visible/product behavior): lets the
 // push deep-link test prove which session the notification
 // opened. Empty for normal users; VoiceOver reads the title.
                .accessibilityValue(e2eSessionIdValue)
            Spacer(minLength: Theme.Spacing.xs)
 // 右上角常显会话状态图标（A 线性，纯展示不可点）。
 // 等待审批/作答的处理入口保留在底部面板与折叠输入条（BlockedComposerBar）。
            SessionStatusIcon(kind: sessionStatusKind, size: 24)
                .accessibilityIdentifier("session-status-icon")
                .accessibilityValue(sessionStatusKind.a11yValue)
                .frame(width: 36, height: 36)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.xs)
    }

 /// 当前会话状态（右上角图标的唯一数据源）：离线 > 等待审批 > 等待作答 >
 /// 进行中 > 出错 > 未开始 > 空闲。审批/问答来自 live waterfall 与 projection；
 /// 出错包含链路流错误与本轮失败（turn/end.reason）；未开始 = 会话尚无任何事件。
    private var sessionStatusKind: SessionStatusKind {
        if !app.link.phase.isConnected { return .offline }
        if currentApproval != nil { return .approval }
        if !visibleUserQuestionCalls.isEmpty { return .answer }
        if viewModel.isRunning { return .running }
        if viewModel.streamErrorText != nil || viewModel.lastTurnFailed { return .error }
        if viewModel.isBlankSession { return .notStarted }
        return .idle
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

 /// E2E-only context-window percentage injection .
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
 /// 性能：分组结果由 SessionViewModel 缓存并随 rows 一起发布，
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

 // MARK: - Message list (UIKit 底座：布局期锚定，见 SessionMessageListView)

 /// 消息流渲染单元：groups（历史+live）+ 尾部内容（文件变更/流式文本/错误）统一进列表。
    private var messageItems: [SessionMessageItem] {
        #if DEBUG
        let groups = viewModel.flowGroups.count
        return PerfProbe.shared.measure("messageItems", ["groups": groups]) {
            let items = buildMessageItems()
 // 帧级卡顿探针：父视图 body 每次重算都会重建 items（O(groups)），
 // 这是「滚动期间是否有整表重算」的直接计数点。
            ScrollHitchProbe.mark("messageItems", ["groups": groups, "items": items.count])
            return items
        }
        #else
        return buildMessageItems()
        #endif
    }

    private func buildMessageItems() -> [SessionMessageItem] {
 // v6 E2E：注入合成步骤组时不叠加样本会话行，保证几何/模式断言稳定。
        if e2eProcessHistoryPreview { return e2eProcessHistoryItems }
 // 方案① E2E：注入超长 Markdown 行（单视图渲染视觉冒烟/取证）。
        if e2eMarkdownSingleViewPreview { return e2eMarkdownSingleViewItems }
        return SessionMessageItemsBuilder.build(
            groups: viewModel.flowGroups,
            isRunning: isRunningForMessageItems,
            fileChanges: viewModel.latestTurnFileChanges,
 // E2E 证据钩子：样本会话里不一定有正在跑的 turn，这里注入一组合成「运行中」步骤，
 // 用于稳定复现/断言「固定窗口 ⇄ 全高」两态（仅 DEBUG + DSHM_E2E=1）。
            processPreviewSteps: e2eProcessRunningPreview ? e2eProcessPreviewSteps : nil,
            liveProcessSteps: viewModel.liveProcessSteps,
            liveAssistantText: viewModel.liveAssistantText,
            streamErrorText: viewModel.streamErrorText,
            actionErrorText: viewModel.actionErrorText
        )
    }

 /// 卡片/列表统一的 running 判定：#1 生产态就是「本轮真的在跑」；DEBUG E2E 下还可被
 /// `DSHM_E2E_FORCE_RUNNING=1` 强制视作 running（卡片不渲染、列表按运行态渲染）。
    private var isRunningForMessageItems: Bool {
        viewModel.isRunning || e2eProcessRunningPreview || e2eForceRunningPreview
    }

    private var messageList: some View {
        let items = messageItems
        return Group {
            if viewModel.isLoading, items.isEmpty {
                loadingPlaceholder
            } else if items.isEmpty, viewModel.streamErrorText == nil {
 // Blank-session fix: the empty states
 // used to size to their content (~120-260pt), so the whole
 // session VStack collapsed to a strip in the middle of the
 // screen with black bands above/below. Fill the available
 // height so a brand-new blank session lays out exactly like a
 // session with messages (header / empty body / strip /
 // composer). Pre-existing layout, first exposed by R2 opening
 // blank sessions on the phone.
                if viewModel.hasLiveSnapshot {
                    EmptyStateView(
                        icon: "text.bubble",
                        title: "还没有消息",
                        message: "在下方输入框发一条消息开始这个会话。"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("session-empty")
                } else {
                    messageSkeleton
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                SessionMessageListView(
                    items: items,
                    sessionId: sessionId,
                    attachments: attachments,
                    pendingApprovalCallIds: Set(app.link.pendingApprovals.compactMap(\.callId)),
                    subagentLabels: viewModel.subagentLabels,
                    isRunning: isRunningForMessageItems,
                    historyBatchToken: viewModel.historyBatchToken,
                    scrollToBottomToken: scrollToBottomToken,
                    isFillingHistory: viewModel.historyFillProgress != nil,
                    processGroupModes: processGroupModes,
                    processGroupWindowHeight: processGroupWindowHeight,
                    currentTurnStartSeq: currentTurnStartSeq,
                    onToggleGroupMode: { id, target in
                        processGroupModes[id] = target
                    },
                    onOpenReasoning: { present(.reasoning($0)) },
                    onOpenTool: { present(.tool($0)) },
 // v7：步骤块里的「子代理消息」行点击 → 打开该子代理会话
 // （与子代理半层同一路径；sender 不在 catalog 时用裸 id 兜底）。
                    onOpenRelay: { card in
                        guard let sender = card.senderSessionId, !sender.isEmpty else { return }
                        let entry = subagentListEntries.first { $0.id == sender }
                            ?? SubagentCatalogEntry(id: sender)
                        app.openSubagentSession(entry, parentAddress: address, parentSessionId: sessionId)
                    },
                    onOpenFileChanges: { present(.fileChanges($0)) },
                    onNearBottomChange: {
                        isNearBottom = $0
 // 读历史（不贴底）时降低派生行发布频率：加载/补齐不受影响，
 // 只是尾部冻结内容的 UI 发布不再和滑动手势抢主线程。
                        viewModel.setReadingHistory(!$0)
                    },
                    onUserScrolled: {
                        userHasScrolled = true
                        isNearBottom = false
                        viewModel.setReadingHistory(true)
                    },
                    onFirstContent: {
                        markFirstContentAfterLayout()
                    },
                    onRetry: { viewModel.retry() }
                )
                .accessibilityIdentifier("session-message-list")
            }
        }
 // 设计稿 r2：后台自动补齐历史 → 顶部 2pt
 // 确定态进度条。overlay 不参与布局（不撑高、不挤压消息）、不拦截点击；
 // 视图只在 VM 发布进度时存在（hidden 即移除），完成后的 100% 停留与淡出
 // 由 VM 的定时器收尾。
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                if let progress = viewModel.historyFillProgress {
                    HistoryFillProgressBar(progress: progress)
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .animation(reduceMotion ? nil : Theme.Motion.standard, value: viewModel.historyFillProgress)
        }
    }

 /// 运行中过程组固定窗口高度：整屏 1/3（设计稿基线），夹在 280–360pt。
    private var processGroupWindowHeight: CGFloat {
        min(360, max(280, UIScreen.main.bounds.height / 3))
    }

 /// 本轮起点 seq：最后一条用户消息所在行的 seq；没有用户消息时为 Int.min。
    private var currentTurnStartSeq: Int {
        viewModel.rows.last(where: { if case .user = $0.content { return true }; return false })?.seq ?? Int.min
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ProgressView().tint(Theme.Palette.accent)
            Text("正在加载会话…")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, Theme.Spacing.xxl)
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

 // MARK: - v0.2.7 E2E 过程组四态预览（仅 DEBUG + E2E）

 /// 运行中两态（固定窗口 / 全高）需要真实的 running turn 才能复现；
 /// 样本会话不保证有，因此提供合成步骤注入：`DSHM_E2E=1` + `DSHM_E2E_PROCGROUP=running`。
 /// 只影响 E2E 证据构建，无产品行为。
    private var e2eProcessRunningPreview: Bool {
        #if DEBUG
        guard app.isE2EMode else { return false }
        return ProcessInfo.processInfo.environment["DSHM_E2E_PROCGROUP"] == "running"
        #else
        return false
        #endif
    }

 /// #1 E2E 钩子：`DSHM_E2E=1` + `DSHM_E2E_FORCE_RUNNING=1` 把主会话视作 running，
 /// 用于断言「running 期间文件变更卡完全不渲染」。只影响视图判定，不改 VM 状态，
 /// 也不影响任何真实 turn（Release 不编译）。
    private var e2eForceRunningPreview: Bool {
        #if DEBUG
        guard app.isE2EMode else { return false }
        return ProcessInfo.processInfo.environment["DSHM_E2E_FORCE_RUNNING"] == "1"
        #else
        return false
        #endif
    }

    private var e2eProcessPreviewSteps: [ProcessStep] {
        let specs: [(String, String)] = [
            ("思考", "先确认 rebuild 流程，再看布局为什么被裁剪"),
            ("bash", "grep -rn 'rowHeight' apps/ios/DSHm"),
            ("read", "SessionMessageListView.swift"),
            ("思考", "锚点只认真实 frame，需要强制重测行高"),
            ("bash", "xcodebuild build -scheme DSHm"),
            ("edit", "ProcessGroupView.swift"),
            ("思考", "展开体不能再用 LazyVStack：cell 里没有视口"),
            ("bash", "xcodebuild test -only-testing:DSHmTests"),
            ("思考", "等真机回归后再决定窗口默认高度"),
            ("read", "ProcessStepRow.swift"),
            ("grep", "process-group-row"),
            ("bash", "run-processgroup-e2e.sh"),
        ]
        return specs.enumerated().map { index, spec in
 // 合成步骤的 seq 必须大于任何样本会话的 seq，才能被判定为「本轮运行中」组。
            let previewSeq = Int.max / 2 + index
            if spec.0 == "思考" {
                return ProcessStep(id: "e2e-proc-\(index)", kind: .reasoning(spec.1), seq: previewSeq)
            }
            var arguments: [String: JSONValue] = [:]
            switch spec.0 {
            case "bash": arguments = ["command": .string(spec.1)]
            default: arguments = ["file_path": .string(spec.1)]
            }
            let item = ToolCallItem(
                callId: "e2e-call-\(index)",
                name: spec.0,
                argumentsRaw: nil,
                arguments: arguments,
                result: index == specs.count - 1
                    ? nil
                    : ToolResultItem(isError: false, text: "ok", meta: nil, images: []),
                children: [],
                turn: 1,
                step: index
            )
            return ProcessStep(id: "e2e-proc-\(index)", kind: .tool(item), seq: previewSeq)
        }
    }

 /// v6 E2E：`DSHM_E2E=1` + `DSHM_E2E_PROCGROUP=history` 注入合成内容
 /// （12 步主组 + 10 条垫高组），回归「默认平铺展开 / 大折叠 / 组头定住」；
 /// 不依赖真实长会话，仅 DEBUG 生效，无产品行为。
 ///
 /// 几何约束：inverted 列表把内容钉在最新端（offset=0 =
 /// 视觉底），组头定住必须靠 offset 反向补偿 Δ；补偿余量 = 组头下方（更新侧）
 /// 的内容高度。主组是最旧的一行（视觉顶部），所以其下方必须垫 ≥348pt 内容，
 /// 否则「收起 348pt」物理上滚不满（内容不足一屏时 maxOffset=0，任何实现
 /// 都无法把组头钉住）。10 × 2 步组 ≈ 1100pt 提供充裕余量。
    private var e2eProcessHistoryPreview: Bool {
        #if DEBUG
        guard app.isE2EMode else { return false }
        return ProcessInfo.processInfo.environment["DSHM_E2E_PROCGROUP"] == "history"
        #else
        return false
        #endif
    }

    private var e2eProcessHistoryItems: [SessionMessageItem] {
 // 升序 = 视觉从下往上：主组（12 步）在最旧端（视觉顶部），其后（更新侧）
 // 垫 10 个 2 步组 ≈ 1100pt，给「组头定住」的 offset 补偿留出余量。
 // 垫高组用 reasoning 步骤（行高同样 29pt，但 AX id 是 process-reasoning-row，
 // 不污染 E2E 的 `tool-row-` 计数断言）。
 // 步数可注入（DSHM_E2E_PROCGROUP_STEPS，默认 12）：>40 即巨型组路径，
 // 用于复现真机 90 步巨型组的展开/「展开其余」缺陷。
        let giantSteps = Int(ProcessInfo.processInfo.environment["DSHM_E2E_PROCGROUP_STEPS"] ?? "") ?? 12
 // 主组上方垫高（DSHM_E2E_PROCGROUP_PAD_ABOVE， v4）：复现真机
 // 「长会话中段、组上方还有大量历史」的几何——组头钉住必须扛住上方内容的
 // 行高估算漂移；主组在内容顶部时钉住是平凡成立的，测不出该缺陷。
        let padAbove = Int(ProcessInfo.processInfo.environment["DSHM_E2E_PROCGROUP_PAD_ABOVE"] ?? "") ?? 0
        var items: [SessionMessageItem] = []
        for index in 0..<max(0, padAbove) {
            items.append(.group(.process(Self.e2eReasoningSteps(count: 2, idPrefix: "e2e-above\(index)"))))
        }
        items.append(.group(.process(Self.e2eHistorySteps(count: giantSteps, idPrefix: "e2e-hist"))))
        for index in 0..<10 {
            items.append(.group(.process(Self.e2eReasoningSteps(count: 2, idPrefix: "e2e-pad\(index)"))))
        }
        return items
    }

    private static func e2eReasoningSteps(count: Int, idPrefix: String) -> [ProcessStep] {
        (0..<count).map { index in
            ProcessStep(
                id: "\(idPrefix)-\(index)",
                kind: .reasoning("垫高组 \(idPrefix) 思考步骤 \(index)"),
                seq: Int.max / 2 + 100 + index
            )
        }
    }

    private static func e2eHistorySteps(count: Int, idPrefix: String) -> [ProcessStep] {
        let names = ["bash", "read", "edit", "grep"]
        return (0..<count).map { index in
            let name = names[index % names.count]
            let arguments: [String: JSONValue] = name == "bash"
                ? ["command": .string("xcodebuild build -scheme DSHm #\(index)")]
                : ["file_path": .string("apps/ios/DSHm/Session/ProcessGroupView.swift")]
            let item = ToolCallItem(
                callId: "\(idPrefix)-call-\(index)",
                name: name,
                argumentsRaw: nil,
                arguments: arguments,
                result: ToolResultItem(isError: false, text: "ok", meta: nil, images: []),
                children: [],
                turn: 1,
                step: index
            )
            return ProcessStep(id: "\(idPrefix)-\(index)", kind: .tool(item), seq: Int.max / 2 + index)
        }
    }

 // MARK: - 方案① E2E：超长 Markdown 单视图渲染注入（仅 DEBUG + E2E）

 /// `DSHM_E2E=1` + `DSHM_E2E_MD_SINGLEVIEW=1` 注入一条 ~1700 字符、覆盖全部
 /// block 类型的超长 Markdown 行（命中 `MarkdownRenderPolicy.shouldFlatten`），
 /// 用于单视图渲染的视觉冒烟与滚动取证。不叠加样本会话行，无产品行为。
    private var e2eMarkdownSingleViewPreview: Bool {
        #if DEBUG
        guard app.isE2EMode else { return false }
        return ProcessInfo.processInfo.environment["DSHM_E2E_MD_SINGLEVIEW"] == "1"
        #else
        return false
        #endif
    }

    private var e2eMarkdownSingleViewItems: [SessionMessageItem] {
        var items: [SessionMessageItem] = []
        for index in 0..<4 {
            items.append(.group(.single(FlowRow(
                id: "e2e-md-pad-\(index)",
                seq: 100 + index,
                content: .text("垫高短消息 \(index)：方案①单视图渲染 E2E 注入样本。")
            ))))
        }
        items.append(.group(.single(FlowRow(
            id: "e2e-md-long",
            seq: 200,
            content: .text(Self.e2eLongMarkdown)
        ))))
        for index in 0..<2 {
            items.append(.group(.single(FlowRow(
                id: "e2e-md-tail-\(index)",
                seq: 300 + index,
                content: .text("尾部最新消息 \(index)：超长行上方（更新侧）的垫高内容。")
            ))))
        }
        return items
    }

 /// 全 block 类型超长 Markdown（标题/行内代码/列表/任务/引用/代码块/表格/分隔线 + 拉长段落）。
    private static let e2eLongMarkdown: String = {
        let head = """
        ## 方案①单视图渲染验收样本

        正文段落：这是一条超长 Markdown 消息，验证「单视图富文本渲染」的视觉效果；正文混排行内代码 `inlineChip()`、加粗 **重点内容**、斜体 _强调文本_ 与链接 [示例链接](https://example.com)。

        - 列表项：第一项内容
        - 列表项：第二项含行内代码 `count > 800`
        - [x] 已完成任务项
        - [ ] 未完成任务项

        > 引用块第一行：引用内容样本
        > 引用块第二行：继续引用

        ```swift
        let value = 42
        func render() -> Text { Text(flattened) }
        ```

        | 列A | 列B | 列C |
        | --- | --- | --- |
        | 值1 | 值2 | 值3 |

        ---
        """
        let filler = (1...12).map {
            "补充段落 \($0)：继续填充字符数以超过 800 字符阈值，确保命中单视图渲染分支；每一段都计入真实的文本测量与渲染成本。"
        }.joined(separator: "\n\n")
        return head + "\n" + filler
    }()

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
 // 答完问答后会话继续产出内容：贴底时强制回底；读历史时尊重用户位置。
        if isNearBottom { scrollToBottomToken += 1 }
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
 /// v6：过程组显示态由页面持有，cell 只读不存（默认展开）。
    var mode: ProcessGroupMode = .expanded
 /// 展开/收起手驱动动画的步骤内容高度覆盖（nil = 自然高度，见 SessionMessageListView）。
    var animatedStepsHeight: CGFloat? = nil
 /// 「展开后步骤内容高度」缓存命中值（见 GroupStepsHeightStore）：命中时折叠组
 /// 跳过隐藏测量副本，滚动期行物化成本减半。
    var cachedStepsHeight: CGFloat? = nil
 /// 步骤内容签名（缓存校验用，随组内容变化）。
    var stepsContentSignature: String = ""
 /// 巨型组「展开其余 N 步」追加后，行高增加了多少（列表同帧补偿 offset）。
    var onStepsHeightDelta: ((CGFloat) -> Void)? = nil
 /// v7.1：巨型组已渲染步数的外部真值 + 变化回调（UIKit 后端持有；nil = 内部 @State）。
    var revealedStepsOverride: Int? = nil
    var onRevealStepsChange: ((Int) -> Void)? = nil
    var windowHeight: CGFloat = 300
    var onToggleMode: (() -> Void)? = nil
    var onOpenReasoning: ((String) -> Void)? = nil
    var onOpenTool: ((ToolCallItem) -> Void)? = nil
 /// v7：子代理消息步骤行点击 → 打开该子代理会话（nil = 该行不可点）。
    var onOpenRelay: ((RelayCard) -> Void)? = nil

 /// 只比较影响渲染的值：流式更新时未变化的组直接跳过 body 重算
 /// 。回调闭包与 attachments 不参与比较。
    static func == (lhs: FlowRowGroupView, rhs: FlowRowGroupView) -> Bool {
        lhs.group == rhs.group
            && lhs.sessionId == rhs.sessionId
            && lhs.pendingApprovalCallIds == rhs.pendingApprovalCallIds
            && lhs.subagentLabels == rhs.subagentLabels
            && lhs.isNewestGroupRunning == rhs.isNewestGroupRunning
            && lhs.mode == rhs.mode
            && lhs.animatedStepsHeight == rhs.animatedStepsHeight
            && lhs.cachedStepsHeight == rhs.cachedStepsHeight
            && lhs.stepsContentSignature == rhs.stepsContentSignature
            && lhs.revealedStepsOverride == rhs.revealedStepsOverride
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
 // v6：带实时步骤的组即本轮运行中的组——即便.liveText/错误行排在组后，
 // 组头也要显示「运行中」（isNewest 只看列表最后一行）。
                ProcessGroupView(
                    steps: steps,
                    isRunning: isNewestGroupRunning || steps.contains { $0.isLive },
                    pendingApprovalCallIds: pendingApprovalCallIds,
                    mode: mode,
                    measurementID: group.id,
                    animatedStepsHeight: animatedStepsHeight,
                    cachedStepsHeight: cachedStepsHeight,
                    measurementSignature: stepsContentSignature,
                    windowHeight: windowHeight,
                    onToggleMode: onToggleMode,
                    onOpenTool: onOpenTool,
                    onOpenReasoning: onOpenReasoning,
                    subagentLabels: subagentLabels,
                    onOpenRelay: onOpenRelay,
                    revealedStepsOverride: revealedStepsOverride,
                    onRevealStepsChange: onRevealStepsChange,
                    onStepsHeightDelta: onStepsHeightDelta
                )
            }
        }
 // SwiftUI 只会把 identifier 挂到「可访问元素」上：单个 Text/Markdown/卡片内部的
 // identifier 不会冒泡成元素，所以 XCUITest 数不到行。`children:.contain`
 // 把每个渲染单元显式包成一个可访问容器（子元素仍逐个可达，供点击/断言）。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(axIdentifier)
    }
}

/// Sheet slot shared by tool detail / file changes / permissions / subagents.
enum SessionDetailSheet: Identifiable {
    case tool(ToolCallItem)
    case fileChanges(TurnFileChanges)
 /// v0.2.7：思考全文（原先由过程组 cell 内的.sheet 呈现，cell 重建会丢弹层）。
    case reasoning(String)
    case permission
 /// v5.4 task-13: half-sheet subagent list of the parent session.
    case subagentList
 /// v0.2.0: composer model selection panel.
    case modelSelection

    var id: String {
        switch self {
        case .tool(let item): return "tool-\(item.id)"
        case .fileChanges(let changes): return "changes-\(changes.seq ?? -1)"
        case .reasoning(let text): return "reasoning-\(text.count)-\(text.prefix(24))"
        case .permission: return "permission"
        case .subagentList: return "subagent-list"
        case .modelSelection: return "model-selection"
        }
    }
}

#Preview {
    SessionDetailView(address: .session(sessionId: "session-preview"))
        .environmentObject(AppModel())
}

/// E2E / VoiceOver 稳定值：状态图标的可访问值用 ASCII，避免中文文案影响断言。
private extension SessionStatusKind {
    var a11yValue: String {
        switch self {
        case .offline: return "offline"
        case .approval: return "approval"
        case .answer: return "answer"
        case .running: return "running"
        case .notStarted: return "notStarted"
        case .idle: return "idle"
        case .error: return "error"
        }
    }
}
