import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Session detail state: owns the session/follow subscription, applies frames
/// through SessionJournal and rebuilds render rows (turn grouping).
@MainActor
final class SessionViewModel: ObservableObject {
    let sessionId: String
    /// `session/follow` address. Subagent sessions (Agent Teams teammates) carry a
    /// durable parent address; see SessionFollowAddress.
    let address: SessionFollowAddress
    /// v5.4 task-13: non-nil when this detail was opened as a child subagent
    /// session from its parent (drives subagents/prompt + interruptByParent).
    let subagentContext: SubagentSessionContext?

    @Published private(set) var sections: [TurnSection] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isRunning = false
    @Published private(set) var liveAssistantText: String = ""
    @Published private(set) var streamErrorText: String?
    @Published private(set) var title: String?
    @Published private(set) var permissionsValue: String?
    @Published private(set) var todos: [JSONValue]?
    @Published private(set) var planActive: Bool = false
    @Published private(set) var modelSelectionText: String?
    /// v0.2.0 model selection: `session/modelCatalog` result.
    @Published private(set) var modelCatalog: ModelCatalog?
    /// v0.2.0: current durable selection parsed from
    /// `projections.values.modelSelection.next` (falls back to `lastUsed`).
    @Published private(set) var modelSelection: ModelSelection?
    @Published private(set) var modelCatalogLoading = false
    @Published private(set) var modelCatalogErrorText: String?
    /// A `session/selectModel` round trip is in flight (rows disabled).
    @Published private(set) var modelSelecting = false
    /// Selection submitted and awaiting the Host's answer (row spinner).
    @Published private(set) var modelSelectionPending: ModelSelection?
    /// Sheet-local failure text of the last selection attempt.
    @Published private(set) var modelSelectionErrorText: String?
    @Published private(set) var approvalPolicy: String?
    @Published private(set) var sandboxMode: String?
    /// M5: selectable permission presets of this session. Loaded lazily from the
    /// read-only `permissionPresets/catalog` proxy when the permission sheet opens;
    /// a failed load leaves the list empty so re-opening the sheet retries.
    @Published private(set) var presetOptions: [PermissionPresetOption] = []
    /// M5: host-recommended preset — the sheet's highlight fallback until the
    /// session's own `permissions.currentValue` lands in the projections.
    @Published private(set) var presetDefault: String?
    /// M5: a `POST /session/permission` round trip is in flight (rows disabled).
    @Published private(set) var permissionSwitching = false
    /// M5: sheet-local failure text (preset switch or catalog load).
    @Published private(set) var permissionSwitchError: String?
    /// M5: catalog fetch in flight (drives the sheet placeholder).
    @Published private(set) var permissionCatalogLoading = false
    @Published private(set) var sending = false
    @Published private(set) var actionErrorText: String?
    @Published private(set) var lastEventAt: Date?

    /// v5.5 §14.5: context-window usage of this session. Seeded from the
    /// `session/follow` snapshot projections (first frame), then refreshed by the
    /// throttled `session/list` read after `assistant/attempt` / turn activity.
    @Published private(set) var contextPressure: ContextPressureValue?
    /// v5.4: client-side prompt queue while a turn runs (see `PromptQueue`).
    @Published private(set) var queuedPrompts = PromptQueue()
    /// Round2 §3 (task-2): optimistic echoes for prompts the host accepted but has
    /// not materialized as durable `user/message` events yet. The important case
    /// is `mode:"steer"`: the host only inserts it into the running agent's inbox
    /// and appends the durable message when the turn reaches its next step, which
    /// can lag by a whole tool call — the App used to paint nothing until then.
    @Published private(set) var pendingUserEchoes = SessionRowBuilder.PendingUserEchoStore()
    /// task-2 / tech-design §14: pending user-question calls of this session
    /// (projection `userQuestions.active`; refreshed by snapshot and after answers).
    @Published private(set) var activeUserQuestions: [UserQuestionCall] = []
    /// v5.4 compatibility: the detail/list status line only needs the count.
    var userQuestionsActiveCount: Int { activeUserQuestions.count }
    /// v5.4: parsed parent `subagentCatalog` projection (task-13 consumes it).
    @Published private(set) var subagentCatalog: [SubagentCatalogEntry] = []
    /// v0.2.0 live discovery: the projection only arrives with a journal snapshot,
    /// so children reported by `session/list` are kept separately and merged into
    /// `subagentCatalog` (see `SubagentCatalogMerge`).
    private var projectionSubagents: [SubagentCatalogEntry] = []
    private var discoveredSubagents: [SubagentCatalogEntry] = []
    /// v5.4 task-13: runtime status of child subagent sessions (parent detail only).
    @Published private(set) var subagentRuntimes: [String: SubagentRuntime] = [:]
    @Published var draft: String = ""
    @Published var expandedTurnIDs: Set<String> = []
    /// Exact-fetch (protocol §3.9) summaries keyed by workspace/changes seq.
    @Published private(set) var fileChangeSummaries: [Int: ChangesSummaryValue] = [:]
    @Published private(set) var fileChangeUnavailableSeqs: Set<Int> = []

    private(set) var journal = SessionJournal()
    /// M2b-2: the detail was first painted from the on-disk window cache. The live
    /// `session/follow` snapshot replaces it (sequence de-duplication in
    /// `SessionJournal`); the detail banner clears as soon as that snapshot lands.
    @Published private(set) var isShowingCachedWindow = false
    /// M2b-2: the restored window is older than the 24h display TTL (still shown).
    @Published private(set) var cachedWindowIsStale = false

    // MARK: - Older history pagination (task session-history: view contract)

    /// The Host still has events older than `oldestLoadedSeq`: the follow snapshot's
    /// `hasMore` on open (a long session starts at `true`), then the last
    /// `session/page` `hasMore`. The view calls `loadOlderIfNeeded()` when the
    /// scroll approaches the top; `false` means the first event is loaded.
    @Published private(set) var hasMoreOlder: Bool = false
    /// One `session/page` round trip is in flight. Repeated scroll callbacks are
    /// no-ops while this is true (concurrent requests are deduplicated).
    @Published private(set) var isLoadingOlder: Bool = false
    /// E2E/DEBUG paging diagnostics: the last `session/page` request/response/merge
    /// (task-10 bug2b — "pull shows a spinner but nothing loads" was a silent
    /// no-op). Only written when `DSHM_E2E`/`DSHM_DEBUG_STREAM` is set; the
    /// product path keeps it empty. Read by SessionDetailView's hidden
    /// `e2e-lastpage` accessibility element.
    @Published private(set) var e2eLastPageDebug: String = ""
    /// Oldest event seq currently loaded (front of the window), read-only view
    /// contract: the detail can anchor/verify the scroll position against it.
    var oldestLoadedSeq: Int? { journal.oldestSeq }
    /// Sticky "the session's first event has been loaded" (task-6): once true the
    /// detail must hide the "load earlier" entry forever — even if a reconnect /
    /// background-fill snapshot with `hasMore = true` arrives afterwards.
    var reachedFirstEvent: Bool { journal.hasReachedOldest }
    /// M2b-2: cache read + journal replay + first row rebuild inside `init`, in ms.
        private(set) var cacheLoadMilliseconds: Double = 0
    private let windowCache: SessionWindowCacheStore
    /// P1.5-B: phone-sized first `session/follow` window (12–20 messages) and the
    /// legacy 40-message window filled in the background after the first rows paint.
    private(set) var firstWindowMessages: Int
    private(set) var fillWindowMessages: Int
    /// Raw wire frames kept for the next cache write: the latest snapshot frame and
    /// the contiguous `event` objects that followed it.
    private var cachedSnapshotFrame: JSONValue?
    private var cachedEventFrames: [JSONValue] = []
    private var cacheSaveTask: Task<Void, Never>?
    /// 打开阶段的锚底信号：缓存窗口先上屏、live 快照后到；视图在它为 true 之前
    /// 必须无条件贴底（冷启动/通知深链进入时"停在旧消息"的根因）。
    @Published private(set) var hasLiveSnapshot = false
    /// P1.5-B background fill: the delayed task + the second `session/follow`
    /// stream that requeststhe legacy 40-message window. When its snapshot lands it
    /// replaces the small window and becomes the live stream.
    private var fillTask: Task<Void, Never>?
    private var fillStream: RemoteStreamHandle?
    /// Fill attempts for this open (bounded so a failing fill cannot loop).
    private var fillAttempts = 0
    /// True once the legacy full window (40 messages) is on screen.
    private var hasFullWindow = false
    /// Bound the persisted tail; when full, later events are no longer appended —
    /// the cached window stays contiguous (and therefore replayable), just older.
    private static let maxCachedEvents = 200

    // MARK: - Older history pagination state (task session-history)

    /// Raw `event` objects of the loaded older range (front of the snapshot window,
    /// filled by `session/page`), ascending by seq. Persisted so a cold open replays
    /// the loaded history instead of regressing to the phone-sized window.
    private var cachedOlderEventFrames: [JSONValue] = []
    /// Serialized size per seq of `cachedOlderEventFrames` (kept incrementally so
    /// the budget check never re-encodes the whole history).
    private var cachedOlderFrameBytes: [Int: Int] = [:]
    private var cachedOlderFramesBytes: Int = 0
    /// Older frames were dropped to stay within the cache budget: the persisted
    /// window then reports `hasMoreOlder = true` so the prefix can be refetched.
    private var cachedOlderFramesTruncated = false
    /// Budget for the raw older range inside the window cache (~1.5MB keeps the
    /// cold-start payload/parse cost near the existing 4MB design cap while still
    /// restoring hundreds of events, not 40 messages).
    private static let maxCachedOlderBytes = 1_500_000
    /// Unary `session/page` seam (unit tests have no socket). Production leaves nil
    /// and the loader rides `LinkService.unary("session/page", args:)`.
    var olderPageLoader: (([String: JSONValue]) async throws -> JSONValue)?
    private var olderPageTask: Task<Void, Never>?
    /// True while `actionErrorText` is the paging failure; a later success clears it
    /// once (other action errors are left alone).
    private var olderPageErrorShown = false
    /// A pull was dropped because the link was reconnecting (task-10 bug2b); it is
    /// replayed once the link reports connected again.
    private var olderPageAwaitingReconnect = false
    /// Pages merged by this VM instance — marks the "first page after a push
    /// deep-link reentry" in the E2E diagnostics (a reentry builds a fresh VM).
    private var olderPageMergedCount = 0
    /// Set when an older page just merged, consumed by `rebuildRows()` to expand
    /// the newly loaded oldest turn (A5: within-turn prepend landed inside a
    /// collapsed completed turn, so the pull looked like it did nothing).
    private var olderPageJustMerged = false
    /// M2b-2c: in-app detail timing (`firstFrameMs=..;cacheHit=1;networkMs=..`),
    /// E2E-gated; surfaced through the hidden `detail-metrics` element.
    @Published private(set) var detailMetricsValue: String?
    /// 体验收尾: E2E in-app send clock (`send-metrics` hidden element).
    @Published private(set) var sendMetricsValue: String?
    /// True when `init` restored the detail from the on-disk window cache.
    private(set) var didRestoreWindowFromCache = false
    private var detailViewVisible = false
    private var detailFirstFrameMarked = false
    private var requestedFileChangeSeqs: Set<Int> = []
    private weak var link: LinkService?
    /// M5 test seams: when set, the permission-sheet state machine reads/ writes
    /// through these instead of the attached `LinkService` (unit tests have no
    /// socket). Production leaves both nil.
    var permissionCatalogLoader: (() async throws -> PermissionPresetCatalog)?
    var permissionSwitcher: ((String) async throws -> SessionPermissionUpdate)?
    /// M5: one successful catalog load per detail; failures stay retryable.
    private var permissionCatalogLoaded = false
    /// v0.2.0 model-selection test seams (unit tests have no socket).
    var modelCatalogLoader: (() async throws -> ModelCatalog)?
    var modelSelector: ((ModelSelection) async throws -> ModelSelection)?
    /// v0.2.0: one successful model-catalog load per detail; failures retryable.
    private var modelCatalogLoaded = false
    /// Last live selection the cached catalog could not name (refresh trigger for
    /// a desktop-side switch to a model this detail had not loaded yet).
    private var modelCatalogUnknownSelection: ModelSelection?
    private var stream: RemoteStreamHandle?
    private var restartTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    /// One-shot wakeup that rebuilds the rows when a pending echo's "发送中…"
    /// marker expires (see `schedulePendingEchoStaleRefresh`).
    private var pendingEchoStaleTask: Task<Void, Never>?
    /// 流式文本节流任务：assistant-stream 每个增量都写 @Published 会让整页 Markdown
    /// 重解析/重绘 → 真机滚动卡顿/频闪（2026-10-23 用户反馈）。合并到最多 10Hz。
    private var liveTextThrottleTask: Task<Void, Never>?
    private var observedGeneration = -1
    private var pendingRebuild = false
    /// Last `isRunning` value used for the v5.4 queue flush (turn/end transition).
    private var lastKnownRunning = false
    /// 问题三 H3：turn 结束后保持展开的 turn id（对齐桌面端 ui-chat.collapseTiming:
    /// next-input）——turn 一结束就折叠成一行摘要会让视口上方高度骤减，内容"向上跳飞"。
    /// 只记住自动展开的那一轮：用户手动折叠后不再自动展开。
    private var stickyExpandedTurnID: String?
    /// v5.4 task-13: debounced `session/list` refresh after relay/turn activity.
    private var subagentDebounceTask: Task<Void, Never>?
    private var lastSubagentCatalogIds: [String] = []
    /// Projection half of `activeUserQuestions` (`userQuestions.active`).
    private var projectionUserQuestions: [UserQuestionCall] = []
    /// Live half: `$events` `user-questions/request` waterfalls for this session.
    /// Current builds use the legacy/blocking ask_user_question schema, so the
    /// projection stays `{active: [], settled: []}` and this is the only source.
    private var liveUserQuestionWaterfalls: [UserQuestionWaterfall] = []
    private var pendingUserQuestionsCancellable: AnyCancellable?
    /// M2a fix: link-phase observer that flushes prompts queued while offline.
    private var phaseCancellable: AnyCancellable?
    /// Call ids this client already answered (P0-1/P1-1): the journal projection
    /// only refreshes on snapshots and `session/list` can return a stale
    /// `active` list, so answered calls are suppressed until the Host stops
    /// listing them. Ids are never reused, so suppression is permanent for the
    /// lifetime of this view model.
    private var locallyAnsweredCallIds: Set<String> = []
    /// Duplicate/concurrent submit guard (T10): one answer batch per call at a
    /// time; a racing second submit is rejected instead of double-sending.
    private var userQuestionSubmitGate = UserQuestionSubmitGate()
    /// Live waterfall ids dismissed because their turn was aborted (T10). The
    /// Host does not always deliver a `$events` cancel frame for legacy blocking
    /// asks, so aborting clears the card locally and keeps it hidden if the
    /// pending list is republished.
    private var dismissedLiveWaterfallEventIds: Set<String> = []

    /// Display text for the v5.5 status-strip context cell.
    /// `12.4k / 200k · 6%` when usage and window are known, `12.4k` with usage
    /// only, `—` when nothing has been reported yet.
    var contextPressureText: String { contextPressure?.displayText ?? "—" }

    // MARK: - Model selection (v0.2.0)

    /// Status-strip model entry content. `nil` for subagent sessions (desktop
    /// parity: addressed subagent sessions expose no model selection).
    var modelTriggerState: ModelTriggerState? {
        guard !isSubagentSession else { return nil }
        if let catalog = modelCatalog {
            return catalog.triggerState(for: modelSelection, isLoading: modelCatalogLoading)
        }
        if modelCatalogLoading {
            return ModelTriggerState(text: L10n.t("正在加载模型…"), isLoading: true)
        }
        return ModelTriggerState(text: L10n.t("请选择模型"), isLoading: false)
    }

    /// True when the status-strip model entry should open the selection sheet.
    var canSelectModel: Bool { !isSubagentSession }

    /// Child session id -> catalog label, used by collapsed relay cards.
    var subagentLabels: [String: String] {
        var labels: [String: String] = [:]
        for entry in subagentCatalog {
            labels[entry.id] = entry.displayLabel
        }
        return labels
    }

    // MARK: - Subagent context / capsule (v5.4 task-13)

    var isSubagentSession: Bool { subagentContext != nil }
    var isReadOnlySubagent: Bool { subagentContext?.isReadOnly ?? false }
    var subagentReadOnlyReason: String? { subagentContext?.readOnlyReason }

    /// Bottom capsule state for the parent (main) session detail.
    var subagentCapsule: SubagentCapsuleState {
        SubagentCapsuleState.resolve(catalogCount: subagentCatalog.count, runtimes: Array(subagentRuntimes.values))
    }

    init(
        address: SessionFollowAddress,
        subagentContext: SubagentSessionContext? = nil,
        windowCache: SessionWindowCacheStore = SessionWindowCacheStore()
    ) {
        // M2b-2c: t0 for the detail in-app metric (init entry = first in-app work
        // after the tap). E2E-gated; no product behavior.
        DetailMetrics.begin(sessionId: address.sessionId)
        self.address = address
        self.sessionId = address.sessionId
        self.subagentContext = subagentContext
        self.windowCache = windowCache
        // P1.5-B: the first live window is phone-sized; the legacy 40-message
        // window is filled in the background once the first rows are on screen.
        let firstWindow = SessionWindowPolicy.deviceFirstWindowMessages
        self.firstWindowMessages = firstWindow
        self.fillWindowMessages = SessionWindowPolicy.fillMessages(firstWindow: firstWindow)
        // P1.5-B evidence before the first request is even opened; `openStream`
        // overrides it when the actual request differs (cache hit -> wide window).
        DetailMetrics.setFirstWindow(firstWindow)
        // M2b-2: replay the cached window inside `init` (before the first SwiftUI
        // render) so opening a session shows content immediately; `start()` then
        // subscribes to the live stream and the snapshot replaces this window.
        restoreCachedWindow()
        DetailMetrics.setCacheHit(didRestoreWindowFromCache)
        if didRestoreWindowFromCache {
            DetailMetrics.markCacheRestored(milliseconds: cacheLoadMilliseconds)
        }
    }

    /// Plain-session shorthand (APNs deep links know only the session id).
    convenience init(sessionId: String) {
        self.init(address: .session(sessionId: sessionId))
    }

    // MARK: - 会话流排障日志（DSHM_DEBUG_STREAM=1 时才有输出）

    private static let debugStreamLogging =
        ProcessInfo.processInfo.environment["DSHM_DEBUG_STREAM"] == "1"

    /// E2E paging diagnostics (`e2e-lastpage`) are written only in E2E/debug runs;
    /// the product path leaves `e2eLastPageDebug` empty.
    private static let e2ePageDiagnosticsEnabled =
        ProcessInfo.processInfo.environment["DSHM_E2E"] == "1"
        || debugStreamLogging
    /// Unit-test seam: the simulator test runner has no E2E env, so paging tests
    /// flip this on to assert the `e2e-lastpage` diagnostics.
    static var e2ePageDiagnosticsTestOverride = false

    private func dbg(_ message: @autoclosure () -> String) {
        guard Self.debugStreamLogging else { return }
        NSLog("[STREAMDBG] %@", message())
    }

    // MARK: - M2b-2 cold-start window cache

    /// Rebuilds the journal from the cached snapshot + following events. A cache that
    /// is corrupt, from another schema, or not contiguous is dropped silently and the
    /// normal loading path takes over.
    private func restoreCachedWindow() {
        let started = Date()
        defer { cacheLoadMilliseconds = Date().timeIntervalSince(started) * 1000 }
        guard let cached = windowCache.load(sessionId: sessionId) else { dbg("cache miss"); return }
        do {
            let frame = try SessionStreamFrame.decode(cached.payload.snapshot)
            guard case .snapshot(let snapshot) = frame else { return }
            journal.apply(snapshot: snapshot)
            dbg("cache restore: snapshotRecords=" + String(snapshot.records.count) + " events=" + String(journal.events.count) + " olderFrames=" + String(cached.payload.olderEvents?.count ?? 0))
            // v3: replay the loaded older range *before* the live tail, so the
            // restored window is [oldestLoadedSeq, cursor] instead of only the
            // newest message window (cold start must not regress to 40 messages).
            //
            // task-7: only a gap-free suffix that is adjacent to the snapshot window
            // may be replayed. A cache written by an older build could carry a
            // non-contiguous prefix; restoring it hides whole turns (turn 1 keeps
            // "running", turns 2–7 vanish) and paging can never repair an interior
            // hole, so the prefix is dropped and the entry is re-armed instead.
            let olderFrames = cached.payload.olderEvents ?? []
            var restoredWindowWasRepaired = false
            if !olderFrames.isEmpty {
                let decodedOlder = olderFrames.compactMap { try? $0.decode(SessionEvent.self) }
                let snapshotOldest = snapshot.records.compactMap { $0.event?.seq }.min()
                let usableOlder = Self.contiguousOlderSuffix(decodedOlder, snapshotOldest: snapshotOldest)
                if !usableOlder.isEmpty {
                    journal.prepend(events: usableOlder, hasMoreOlder: true)
                }
                if usableOlder.count != decodedOlder.count {
                    restoredWindowWasRepaired = true
                }
            }
            for eventValue in cached.payload.events {
                let event = try eventValue.decode(SessionEvent.self)
                if case .gap = journal.apply(event: event) {
                    // Cached events are not contiguous with the snapshot: showing a
                    // window with holes would be worse than showing nothing.
                    journal = SessionJournal()
                    return
                }
            }
            // Whole-window continuity gate (task-7): if anything still leaves a hole,
            // keep only the gap-free suffix that ends at the newest event.
            if !journal.isWindowContiguous {
                let dropped = journal.trimToContiguousSuffix()
                if dropped > 0 { restoredWindowWasRepaired = true }
            }
            if cached.payload.schemaVersion >= SessionWindowCacheStore.olderRangeSchemaVersion {
                journal.setHasMoreOlder(cached.payload.hasMoreOlder ?? journal.hasMore)
            } else {
                // Legacy v2 payload = the old 40-message window: no older range was
                // persisted, so `oldestSeq` is the earliest cached record and
                // `hasMoreOlder` is the old `hasMore` (snapshot hasMore fallback).
                journal.setHasMoreOlder(cached.payload.hasMore ?? journal.hasMore)
            }
            // task-6: restore the sticky termination flag. v4 payloads carry it
            // explicitly; older payloads derive it (Lead-agreed rule): a cached front
            // at seq 0 proves the earliest event was loaded.
            journal.setHasReachedOldest(
                cached.payload.hasReachedOldest
                    ?? (cached.payload.oldestSeq == 0 || journal.oldestSeq == 0)
            )
            if restoredWindowWasRepaired {
                // The discarded prefix must be pulled again: re-arm the entry for good
                // (this also clears the sticky terminal state — the first event is no
                // longer in the window).
                journal.markOlderHistoryUnloaded()
            }
            // task-5: the persisted paging state can be internally inconsistent — a
            // cache written by an older build (stale/empty page path) can carry
            // `hasMoreOlder = false` and even `hasReachedOldest = true` while the
            // restored front is not the session's first event (`oldestSeq > 0`).
            // Taking that at face value hides the "load earlier" entry forever: the
            // user can never scroll back to the missing older turns (real device:
            // oldest=3232 yet hasMoreOlder=false while the session starts at seq 0).
            // A terminal state is only valid when seq 0 is actually loaded, so
            // re-arm pagination whenever the flags disagree with the window.
            if (journal.oldestSeq ?? 0) > 0, !journal.hasMoreOlder {
                dbg("cache restore: re-arm paging (cached state said terminal but oldest="
                    + String(journal.oldestSeq ?? -1) + ")")
                journal.markOlderHistoryUnloaded()
            }
            cachedSnapshotFrame = cached.payload.snapshot
            cachedEventFrames = cached.payload.events
            // Cache only the raw older frames that actually landed in the repaired
            // window (a dropped hole must not be written back on the next save).
            let keptSeqs = Set(journal.events.lazy.map(\.seq))
            cachedOlderEventFrames = Self.mergedEventFrames(olderFrames.filter { frame in
                guard let seq = Self.eventFrameSeq(frame) else { return false }
                return keptSeqs.contains(seq)
            })
            rebuildCachedOlderFrameBytes()
            didRestoreWindowFromCache = true
            isShowingCachedWindow = true
            cachedWindowIsStale = cached.isStale
            isLoading = false
            syncOlderState()
            rebuildRows()
            contextPressure = journal.contextPressure
        } catch {
            journal = SessionJournal()
            cachedOlderEventFrames = []
            cachedOlderFrameBytes = [:]
            cachedOlderFramesBytes = 0
            cachedOlderFramesTruncated = false
        }
    }

    /// Test seam: apply one raw `session/follow` item value (snapshot/event/...).
    func applyStreamValue(_ value: JSONValue?) {
        handleItem(value)
    }

    /// Test seam: apply one raw item from the background-fill stream (the wide
    /// legacy window that replaces the small first window).
    func applyFillStreamValue(_ value: JSONValue?) {
        handleItem(value, isFill: true)
    }

    /// Test seam: sequence numbers currently in the journal window.
    var eventSeqs: [Int] { journal.events.map(\.seq) }

    /// P1.5-B test seam: the window is still the small first one and a legacy
    /// 40-message fill is warranted (`hasMore` = older history exists).
    var needsFullWindowFill: Bool {
        hasLiveSnapshot && !hasFullWindow && journal.hasMore
            && fillWindowMessages > firstWindowMessages
    }

    /// Persists the latest snapshot + contiguous event tail, debounced so a running
    /// turn does not write on every frame.
    private func scheduleCacheSave() {
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.cacheSaveTask = nil
            self.saveWindowCacheNow()
        }
    }

    /// Writes the cache only after a live snapshot exists: a cache restored without a
    /// network round-trip must keep its original `savedAt` (it may be stale).
    func saveWindowCacheNow() {
        guard hasLiveSnapshot, let snapshot = cachedSnapshotFrame else { return }
        // P1 resume base: record the channel cursor this window is aligned with (nil
        // on the legacy path). Reserved for the Net/ stream-resume change; recording
        // it now keeps the cache evidence complete without changing behaviour.
        let channel = link?.p1Channel
        // v3: persist the loaded older range too. The recovered oldest seq is
        // `olderEvents.first` (or the snapshot window's first record when the user
        // has not scrolled up yet); if the raw range had to be trimmed the payload
        // keeps `hasMoreOlder = true` so scrolling up refetches the dropped prefix.
        let restoredOldest = cachedOlderEventFrames.first.flatMap(Self.eventFrameSeq)
            ?? Self.snapshotOldestSeq(in: snapshot)
        windowCache.save(
            sessionId: sessionId,
            snapshot: snapshot,
            events: cachedEventFrames,
            windowMessages: hasFullWindow ? fillWindowMessages : firstWindowMessages,
            hasMore: journal.hasMore,
            p1Epoch: channel?.epoch,
            p1Sid: channel?.lastAppliedSid,
            olderEvents: cachedOlderEventFrames,
            oldestSeq: restoredOldest,
            hasMoreOlder: journal.hasMoreOlder || cachedOlderFramesTruncated,
            // task-6: sticky — a cold open must not show "load earlier" again after
            // the user already reached the session's first event.
            hasReachedOldest: journal.hasReachedOldest
        )
    }

    // MARK: - M2b-2c detail in-app timing

    /// Called from `SessionDetailView.onAppear`: marks the detail's first frame once
    /// the header title and/or the first message rows are available. Idempotent.
    func markDetailViewAppeared() {
        detailViewVisible = true
        maybeMarkDetailFirstFrame()
    }

    private func maybeMarkDetailFirstFrame() {
        guard detailViewVisible, !detailFirstFrameMarked else { return }
        // First visible content = header title and/or the first message rows.
        guard title != nil || !sections.isEmpty else { return }
        detailFirstFrameMarked = true
        DetailMetrics.markFirstFrame()
        detailMetricsValue = DetailMetrics.valueString
    }

    private func markDetailNetworkApplied() {
        DetailMetrics.markNetworkApplied()
        detailMetricsValue = DetailMetrics.valueString
    }

    /// Called from `SessionDetailView` once the running/turn indicator is on
    /// screen after a send (E2E in-app metric; no product behavior).
    func markSendTurnVisible() {
        SendMetrics.markTurnVisible()
        sendMetricsValue = SendMetrics.valueString
    }

    // MARK: - Lifecycle

    func attach(link: LinkService) {
        self.link = link
        // G1 (task-6): merge live `$events` user-question waterfalls into the
        // published cards — on current builds the projection is always empty.
        pendingUserQuestionsCancellable = link.$pendingUserQuestions
            .receive(on: RunLoop.main)
            .sink { [weak self] waterfalls in
                self?.applyPendingUserQuestionWaterfalls(waterfalls)
            }
        // M2a fix: prompts typed while the transport is reconnecting are queued
        // locally; flush the oldest one as soon as the link is connected again.
        phaseCancellable = link.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self, phase.isConnected else { return }
                self.maybeFlushQueued()
                // task-10 bug2b: a pull during a reconnect used to be dropped
                // silently; replay it as soon as the link is back.
                self.retryOlderPageAfterReconnect()
            }
    }

    func start() {
        guard let link else { return }
        observedGeneration = link.generation
        // Restore the live half immediately: the Combine sink only re-fires on
        // changes, and a stop()/start() cycle clears the local cache.
        applyPendingUserQuestionWaterfalls(link.pendingUserQuestionWaterfalls(forSession: sessionId))
        openStream()
    }

    func stop() {
        restartTask?.cancel()
        rebuildTask?.cancel()
        subagentDebounceTask?.cancel()
        olderPageTask?.cancel()
        olderPageTask = nil
        liveTextThrottleTask?.cancel()
        liveTextThrottleTask = nil
        olderPageAwaitingReconnect = false
        olderPageJustMerged = false
        isLoadingOlder = false
        fillTask?.cancel()
        fillTask = nil
        fillStream?.cancel()
        fillStream = nil
        fillAttempts = 0
        stream?.cancel()
        stream = nil
        // M2b-2: flush a pending debounced window write before leaving the screen.
        cacheSaveTask?.cancel()
        cacheSaveTask = nil
        saveWindowCacheNow()
        // Leaving the screen: drop the live half (the projection half stays in
        // the journal and is restored by the next snapshot).
        liveUserQuestionWaterfalls = []
        rebuildActiveUserQuestions()
    }

    /// Called when the link generation changed (reconnect): rebuild from snapshot.
    func handleGenerationChange(_ generation: Int) {
        guard generation != observedGeneration else { return }
        observedGeneration = generation
        if generation > 0 {
            reopenStream()
        }
        // M2a fix: prompts queued while offline go out as soon as we are back.
        maybeFlushQueued()
    }

    private func reopenStream() {
        restartTask?.cancel()
        fillTask?.cancel()
        fillTask = nil
        fillStream?.cancel()
        fillStream = nil
        fillAttempts = 0
        hasFullWindow = false
        stream?.cancel()
        stream = nil
        openStream()
    }

    func retry() {
        streamErrorText = nil
        reopenStream()
    }

    /// M4 §4: a background (silent) push asked for fresh data while this detail is
    /// open. Reopens `session/follow` so the snapshot replaces the cached rows —
    /// the same path as the retry button. No-op while offline so a background
    /// push can never paint a connection-error banner over the open session.
    func refreshFromSilentPush() {
        guard let link, link.phase.isConnected else { return }
        reopenStream()
    }

    /// P1.5-B: window size for the next `session/follow`.
    /// - First open with nothing on screen: phone-sized first window (fast paint).
    /// - Anything already on screen (cache hit, reconnect, retry): the legacy full
    ///   window, so a refresh never shrinks what the user can already see.
    private func requestedWindowMessages() -> Int {
        if hasLiveSnapshot || didRestoreWindowFromCache || !sections.isEmpty {
            return fillWindowMessages
        }
        return firstWindowMessages
    }

    private func openStream() {
        guard let link else { return }
        guard link.phase.isConnected else {
            dbg("openStream deferred: phase=" + String(describing: link.phase) + " busy=" + String(link.phase.isBusy) + " sections=" + String(sections.count))
            isLoading = sections.isEmpty
            streamErrorText = link.phase.isBusy ? nil : "连接未就绪"
            return
        }
        let messages = requestedWindowMessages()
        if !hasLiveSnapshot && !didRestoreWindowFromCache && sections.isEmpty {
            // P1.5-B evidence: what the very first request asked for.
            DetailMetrics.setFirstWindow(messages)
        }
        isLoading = sections.isEmpty
        do {
            let turnWindow = messages >= fillWindowMessages
                ? SessionWindowPolicy.fillWindowTurnWindow(messages: messages)
                : SessionWindowPolicy.firstWindowTurnWindow(messages: messages)
            let args: [String: JSONValue] = [
                "request": .object([
                    "address": address.jsonValue,
                    "assistantStream": .bool(true),
                    // P1.5-B: phone-sized window on a cold open; older history is
                    // filled in the background (see scheduleBackgroundFillIfNeeded).
                    "maxMessages": .int(Int64(messages)),
                    // Task session-history: stop the window at a complete-turn
                    // boundary when the message budget allows it (the Host never
                    // returns more messages than `maxMessages`, so the first paint
                    // cost is unchanged).
                    "turnWindow": turnWindow.jsonValue,
                ]),
            ]
            dbg("session/follow send: messages=" + String(messages) + " turnWindow=" + String(describing: turnWindow) + " sections=" + String(sections.count) + " cache=" + String(didRestoreWindowFromCache) + " hasLive=" + String(hasLiveSnapshot))
            stream = try link.openStream(
                endpoint: "session/follow",
                args: args,
                onItem: { [weak self] value in
                    self?.handleItem(value)
                },
                onEnd: { [weak self] in
                    self?.dbg("session/follow ended by host")
                    self?.streamErrorText = "会话流已结束"
                },
                onError: { [weak self] error in
                    self?.dbg("session/follow error: " + error.code + " " + error.message)
                    self?.streamErrorText = error.message.isEmpty ? error.code : error.message
                    self?.isLoading = false
                },
                onClose: { [weak self] _, _ in
                    // Transport lost: LinkService reconnects and bumps generation,
                    // the view calls handleGenerationChange then.
                    self?.isLoading = false
                }
            )
            // A wide request (cache hit / reconnect) is already the full window; a
            // small first window schedules the background fill after its snapshot.
            hasFullWindow = messages >= fillWindowMessages
        } catch {
            streamErrorText = NetworkErrorInterpreter.message(for: error)
            isLoading = false
        }
    }

    // MARK: - P1.5-B background fill (legacy 40-message window)

    /// Bound on fill retries per open: a persistent stream error must not loop.
    private static let maxFillAttempts = 2

    /// After the small first window is on screen, fetch the legacy 40-message window
    /// on a second `session/follow` and promote it to the live stream. Short
    /// sessions (`hasMore == false`) never fill: their first window is complete.
    private func scheduleBackgroundFillIfNeeded() {
        guard let link, link.phase.isConnected, stream != nil else { return }
        guard needsFullWindowFill, fillAttempts < Self.maxFillAttempts else { return }
        guard fillTask == nil, fillStream == nil else { return }
        fillTask = Task { [weak self] in
            // Let the first rows settle first: the user already sees content, and
            // this delay keeps the fill from competing with the first paint.
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.fillTask = nil
            self.openFillStream()
        }
    }

    private func openFillStream() {
        guard let link, link.phase.isConnected, stream != nil, needsFullWindowFill else { return }
        fillAttempts += 1
        do {
            fillStream = try link.openStream(
                endpoint: "session/follow",
                args: [
                    "request": .object([
                        "address": address.jsonValue,
                        "assistantStream": .bool(true),
                        "maxMessages": .int(Int64(fillWindowMessages)),
                        // Same turn-stop contract as the first window: the fill is
                        // the legacy 40-message window, aligned to a turn start when
                        // 32 messages + 8 turns are already covered.
                        "turnWindow": SessionWindowPolicy.fillWindowTurnWindow(
                            messages: fillWindowMessages
                        ).jsonValue,
                    ])
                ],
                onItem: { [weak self] value in
                    self?.handleItem(value, isFill: true)
                },
                onEnd: { [weak self] in self?.handleFillStreamFailure() },
                onError: { [weak self] _ in self?.handleFillStreamFailure() },
                onClose: { [weak self] _, _ in self?.handleFillStreamFailure() }
            )
        } catch {
            fillStream = nil
            handleFillStreamFailure()
        }
    }

    /// The fill stream died before its snapshot: keep the small window live and
    /// retry once (bounded by `maxFillAttempts`).
    private func handleFillStreamFailure() {
        fillStream = nil
        guard needsFullWindowFill else { return }
        scheduleBackgroundFillIfNeeded()
    }

    /// The fill snapshot replaced the small window: keep consuming that stream as
    /// the live one and drop the small-window stream.
    private func promoteFillStream() {
        fillTask?.cancel()
        fillTask = nil
        stream?.cancel()
        stream = fillStream
        fillStream = nil
    }

    /// Paint the first rows without waiting for the 40ms rebuild debounce. Only the
    /// first snapshot benefits (subsequent frames still coalesce).
    private func paintFirstRowsImmediately() {
        guard detailViewVisible, !detailFirstFrameMarked else { return }
        rebuildTask?.cancel()
        rebuildTask = nil
        pendingRebuild = false
        rebuildRows()
    }

    // MARK: - Older history pagination (unary session/page)

    /// `session/page` wire request. Key names and shape are the Host schema exactly
    /// (`spikes/protocol/samples/endpoints.json` → `session/page`, verified
    /// 2026-10-22): `{request:{address, throughSeq, beforeSeq, maxMessages,
    /// turnWindow}}`.
    ///
    /// `throughSeq` is the inclusive log cut taken from the corresponding
    /// `session/follow` opening frame (`snapshot.cursor`); `beforeSeq` is
    /// **exclusive** (Host: `end = min(throughSeq + 1, beforeSeq ?? throughSeq + 1)`),
    /// so the next request passes the current oldest loaded seq and walks strictly
    /// backwards. `maxMessages` counts only append-origin user/assistant messages —
    /// a page still contains *all* events of its seq range (tool calls, turn
    /// starts, ...), which is what the journal front-merge consumes.
    nonisolated static func olderPageRequestArgs(
        address: SessionFollowAddress,
        throughSeq: Int,
        beforeSeq: Int
    ) -> [String: JSONValue] {
        [
            "request": .object([
                "address": address.jsonValue,
                "throughSeq": .int(Int64(throughSeq)),
                "beforeSeq": .int(Int64(beforeSeq)),
                "maxMessages": .int(Int64(SessionWindowPolicy.pageWindowMessages)),
                "turnWindow": SessionWindowPolicy.pageTurnWindow.jsonValue,
            ]),
        ]
    }

    /// View contract: called whenever the scroll approaches the top (may be called
    /// repeatedly and at high frequency). No-op when there is no older history, a
    /// request is already in flight, or no snapshot/cursor exists yet. A pull while
    /// the link is reconnecting is **not** a silent no-op (task-10 bug2b): it
    /// surfaces a visible error and is replayed as soon as the link is back.
    func loadOlderIfNeeded() {
        // task-6: settle the terminal state before deciding anything, so a stale
        // cache/restore flag can never resurrect the entry after seq 0 is loaded.
        syncOlderState()
        if let block = olderPageBlock {
            noteOlderPageBlocked(block)
            return
        }
        isLoadingOlder = true
        let throughSeq = journal.cursor
        let beforeSeq = journal.oldestSeq ?? 0
        olderPageTask = Task { [weak self] in
            await self?.performOlderPageLoad(throughSeq: throughSeq, beforeSeq: beforeSeq)
        }
    }

    /// Test seam: runs one page load and awaits it. The view path runs the same
    /// `performOlderPageLoad` from a Task; unit tests drive the state machine
    /// deterministically through this wrapper.
    func loadOlderPageNowForTesting() async {
        syncOlderState()
        if let block = olderPageBlock {
            noteOlderPageBlocked(block)
            return
        }
        isLoadingOlder = true
        await performOlderPageLoad(throughSeq: journal.cursor, beforeSeq: journal.oldestSeq ?? 0)
    }

    /// Why a pull cannot start a page load (nil = it can). Classified instead of a
    /// bare `canStart` bool so the silent-no-op guard (task-10 bug2b) can surface
    /// a visible reason — and E2E can tell "the gesture never reached us" from
    /// "the load was blocked/rejected".
    private enum OlderPageBlock: String {
        case noOlderHistory = "no-more-history"
        case alreadyLoading = "already-loading"
        case windowNotReady = "window-not-ready"
        case notConnected = "not-connected"
    }

    private var olderPageBlock: OlderPageBlock? {
        guard hasMoreOlder else { return .noOlderHistory }
        guard !isLoadingOlder else { return .alreadyLoading }
        // Never ask for a page in front of seq 0: reaching the first event is the
        // terminal state (a `beforeSeq=0` request would only return an empty page).
        guard journal.cursor >= 0, let oldest = journal.oldestSeq, oldest > 0 else { return .windowNotReady }
        guard olderPageLoader != nil || (link?.phase.isConnected ?? false) else { return .notConnected }
        return nil
    }

    /// task-10 bug2b: a user pull that cannot start must not be a silent no-op.
    /// Only the reconnect case is a *failure* worth surfacing (it is replayed
    /// automatically); the other blocks are legitimate no-ops (already loading /
    /// nothing older / window not painted yet), but they still leave an E2E trace.
    private func noteOlderPageBlocked(_ block: OlderPageBlock) {
        switch block {
        case .notConnected:
            olderPageAwaitingReconnect = true
            if !olderPageErrorShown {
                actionErrorText = L10n.f("加载更早历史失败：%@", "网络连接中断，恢复后会自动重试")
                olderPageErrorShown = true
            }
            publishOlderPageDebug("blocked(not-connected);" + olderPageContext())
            dbg("older page blocked: not-connected")
        case .windowNotReady:
            publishOlderPageDebug("blocked(window-not-ready);" + olderPageContext())
            dbg("older page blocked: window-not-ready")
        case .noOlderHistory:
            publishOlderPageDebug("blocked(no-more-history);" + olderPageContext())
        case .alreadyLoading:
            break
        }
    }

    /// E2E context tying a page attempt to its lifecycle: a push deep-link reentry
    /// opens a **fresh VM** (firstPage=1) that may paint from the on-disk cache
    /// (cacheRestore=1) before the live snapshot (hasLive) lands.
    private func olderPageContext() -> String {
        "ctx(firstPage=\(olderPageMergedCount == 0 ? 1 : 0),cacheRestore=\(didRestoreWindowFromCache ? 1 : 0),hasLive=\(hasLiveSnapshot ? 1 : 0),pagesLoaded=\(olderPageMergedCount))"
    }

    /// Replays the pull that was dropped while the link was reconnecting.
    private func retryOlderPageAfterReconnect() {
        guard olderPageAwaitingReconnect else { return }
        olderPageAwaitingReconnect = false
        guard hasMoreOlder, !isLoadingOlder else { return }
        dbg("older page: replay pull after reconnect (oldest=" + String(journal.oldestSeq ?? -1) + ")")
        loadOlderIfNeeded()
    }

    /// Publishes the paging front from the journal. `hasMoreOlder` can never be true
    /// once the first event is loaded; every path that learns about older history
    /// (cache restore, live snapshot, page merge, row rebuild) goes through here so
    /// the view-facing flag cannot drift from the window it describes.
    private func syncOlderState() {
        hasMoreOlder = journal.hasMoreOlder
    }

    /// One `session/page` round trip + front merge.
    ///
    /// Failure policy (task-10 bug2b): the current window is left untouched and
    /// `hasMoreOlder` stays true, but a page that cannot be merged is **never a
    /// silent no-op** — the user pulled, saw the spinner and must either see older
    /// rows or a visible, retryable error:
    /// - the page is stale/non-adjacent (the window front moved while the request
    ///   was in flight: reconnect snapshot, concurrent prepend) → retry once
    ///   against the *fresh* front;
    /// - the retry is rejected too → surface `actionErrorText`;
    /// - an empty page (or Host `hasMore == false`) terminates pagination; the
    ///   entry row disappearing is the visible state change.
    private func performOlderPageLoad(throughSeq: Int, beforeSeq: Int) async {
        defer { isLoadingOlder = false }
        let startedAt = Date()
        var attempt = 0
        while true {
            attempt += 1
            let retrying = attempt > 1
            // The retry re-reads the front: the first request was keyed on the
            // window front at *trigger* time, which may already be stale.
            let requestThrough = retrying ? journal.cursor : throughSeq
            let requestBefore = retrying ? (journal.oldestSeq ?? 0) : beforeSeq
            let oldestBefore = journal.oldestSeq
            let args = Self.olderPageRequestArgs(
                address: address,
                throughSeq: requestThrough,
                beforeSeq: requestBefore
            )
            do {
                let value: JSONValue
                if let olderPageLoader {
                    value = try await olderPageLoader(args)
                } else if let link {
                    value = try await link.unary("session/page", args: args)
                } else {
                    throw LinkError.notPaired
                }
                let page = try value.decode(SessionPage.self)
                let rawFrames = value["records"]?.arrayValue?.compactMap { $0["event"] } ?? []
                let update = journal.prepend(page: page)
                applyJournalUpdate(update)
                let oldestAfter = journal.oldestSeq
                let merged: Bool = {
                    guard let before = oldestBefore, let after = oldestAfter else { return false }
                    return after < before
                }()
                if merged, case .olderPrepended(let inserted) = update, !inserted.isEmpty {
                    let insertedSet = Set(inserted)
                    let addedFrames = rawFrames.filter { frame in
                        guard let seq = Self.eventFrameSeq(frame) else { return false }
                        return insertedSet.contains(seq)
                    }
                    appendCachedOlderFrames(addedFrames)
                    scheduleCacheSave()
                }
                syncOlderState()
                let usedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                let debugContext = olderPageContext()
                let debugLine = Self.olderPageDebugLine(
                    requestBefore: requestBefore,
                    requestThrough: requestThrough,
                    records: page.records.count,
                    hasMore: page.hasMore,
                    update: update,
                    merged: merged,
                    oldestBefore: oldestBefore,
                    oldestAfter: oldestAfter,
                    retried: retrying,
                    usedMs: usedMs,
                    context: debugContext
                )
                if merged { olderPageMergedCount += 1 }
                if merged {
                    olderPageAwaitingReconnect = false
                    olderPageJustMerged = true
                    if olderPageErrorShown {
                        actionErrorText = nil
                        olderPageErrorShown = false
                    }
                    publishOlderPageDebug(debugLine)
                    dbg("older page: " + debugLine)
                    return
                }
                if page.records.isEmpty || !journal.hasMoreOlder {
                    // Terminal by design: the page carried nothing older (or the
                    // Host reached the log start); the entry row goes away.
                    olderPageAwaitingReconnect = false
                    publishOlderPageDebug(debugLine)
                    dbg("older page terminal: " + debugLine)
                    return
                }
                if !retrying {
                    // Stale/non-adjacent page: the front moved under us. Retry
                    // once with the fresh front instead of dropping the gesture.
                    dbg("older page rejected, retrying with fresh front: " + debugLine)
                    continue
                }
                let reason = "分页窗口已变化，请重试"
                actionErrorText = L10n.f("加载更早历史失败：%@", reason)
                olderPageErrorShown = true
                publishOlderPageDebug(debugLine + ";error=" + reason)
                dbg("older page rejected after retry: " + debugLine)
                return
            } catch {
                let message = NetworkErrorInterpreter.message(for: error)
                actionErrorText = L10n.f("加载更早历史失败：%@", message)
                olderPageErrorShown = true
                publishOlderPageDebug(
                    "req(before=\(requestBefore),through=\(requestThrough));error=" + message + ";" + olderPageContext()
                )
                dbg("older page failed: " + message)
                return
            }
        }
    }

    /// E2E/DEBUG only: publishes the last paging attempt for the hidden
    /// `e2e-lastpage` element. The product path never writes it.
    private func publishOlderPageDebug(_ value: String) {
        guard Self.e2ePageDiagnosticsEnabled || Self.e2ePageDiagnosticsTestOverride else { return }
        e2eLastPageDebug = value
    }

    /// `req(before=3232,through=4179);resp(records=263,hasMore=1);prepend(olderPrepended(inserted=2880-3231,count=352),merged=1);oldest=3232->2880;usedMs=812;retry=0`
    nonisolated private static func olderPageDebugLine(
        requestBefore: Int,
        requestThrough: Int,
        records: Int,
        hasMore: Bool,
        update: SessionJournal.Update,
        merged: Bool,
        oldestBefore: Int?,
        oldestAfter: Int?,
        retried: Bool,
        usedMs: Int,
        context: String
    ) -> String {
        let before = oldestBefore.map(String.init) ?? "-"
        let after = oldestAfter.map(String.init) ?? "-"
        return "req(before=\(requestBefore),through=\(requestThrough))"
            + ";resp(records=\(records),hasMore=\(hasMore ? 1 : 0))"
            + ";prepend(\(describeOlderPageUpdate(update)),merged=\(merged ? 1 : 0))"
            + ";oldest=\(before)->\(after)"
            + ";usedMs=\(usedMs)"
            + ";retry=\(retried ? 1 : 0)"
            + ";" + context
    }

    nonisolated private static func describeOlderPageUpdate(_ update: SessionJournal.Update) -> String {
        switch update {
        case .olderPrepended(let seqs):
            guard let first = seqs.first, let last = seqs.last else { return "olderPrepended(empty)" }
            return "olderPrepended(inserted=\(first)-\(last),count=\(seqs.count))"
        case .snapshotReplaced:
            return "snapshotReplaced"
        case .eventsApplied(let seqs):
            return "eventsApplied(count=\(seqs.count))"
        case .duplicate(let seq):
            return "duplicate(\(seq))"
        case .gap(let expected, let received):
            return "gap(expected=\(expected),received=\(received))"
        case .assistantRevisionGap(let expected, let received):
            return "assistantRevisionGap(expected=\(expected),received=\(received))"
        case .assistantStreamProgress(let revision):
            return "assistantStreamProgress(\(revision))"
        case .ignored:
            return "ignored"
        }
    }

    // MARK: - Raw older-range tracking (window cache)

    /// Mirrors the journal's snapshot merge for the raw frames kept for the cache:
    /// after `apply(snapshot:)` the loaded older prefix is exactly those previous
    /// raw frames whose seq is still in the journal *and* older than the new
    /// snapshot window.
    private func refreshCachedOlderFrames(
        previousSnapshotFrame: JSONValue?,
        newSnapshotOldest: Int?
    ) {
        let previousSnapshotEvents = previousSnapshotFrame?["records"]?.arrayValue?
            .compactMap { $0["event"] } ?? []
        let candidates = cachedOlderEventFrames + previousSnapshotEvents + cachedEventFrames
        let preserved = Set(journal.events.lazy.map(\.seq))
        var kept: [JSONValue] = []
        for frame in candidates {
            guard let seq = Self.eventFrameSeq(frame) else { continue }
            if let newSnapshotOldest, seq >= newSnapshotOldest { continue }
            guard preserved.contains(seq) else { continue }
            kept.append(frame)
        }
        cachedOlderEventFrames = Self.mergedEventFrames(kept)
        // task-7: never persist a prefix that is not a gap-free run ending right
        // below the snapshot window. A hole written into the cache comes back as a
        // hole-y cold-start window (whole turns missing / a finished turn shows
        // "running"), and paging can never fill an interior hole.
        if let newSnapshotOldest {
            let seqs = cachedOlderEventFrames.compactMap { Self.eventFrameSeq($0) }
            let contiguous = zip(seqs, seqs.dropFirst()).allSatisfy { $0 + 1 == $1 }
            let adjacent = seqs.last.map { $0 + 1 == newSnapshotOldest } ?? true
            if !contiguous || !adjacent {
                cachedOlderEventFrames = []
                cachedOlderFramesTruncated = true
            }
        }
        rebuildCachedOlderFrameBytes()
    }

    /// Adds newly paged raw frames to the front of the cache range, keeping the
    /// serialized budget. Dropped frames are refetched by scrolling up because the
    /// saved payload then reports `hasMoreOlder = true`.
    private func appendCachedOlderFrames(_ frames: [JSONValue]) {
        guard !frames.isEmpty else { return }
        cachedOlderEventFrames = Self.mergedEventFrames(cachedOlderEventFrames + frames)
        for frame in frames {
            guard let seq = Self.eventFrameSeq(frame),
                  cachedOlderFrameBytes[seq] == nil else { continue }
            let bytes = Self.serializedBytes(frame)
            cachedOlderFrameBytes[seq] = bytes
            cachedOlderFramesBytes += bytes
        }
        // Re-align the size table with the merged (de-duplicated) frame list.
        if cachedOlderFrameBytes.count != cachedOlderEventFrames.count {
            let kept = Set(cachedOlderEventFrames.compactMap { Self.eventFrameSeq($0) })
            cachedOlderFrameBytes = cachedOlderFrameBytes.filter { kept.contains($0.key) }
            cachedOlderFramesBytes = cachedOlderFrameBytes.values.reduce(0, +)
        }
        var dropped = 0
        while cachedOlderFramesBytes > Self.maxCachedOlderBytes,
              let oldest = cachedOlderEventFrames.first,
              let seq = Self.eventFrameSeq(oldest) {
            cachedOlderEventFrames.removeFirst()
            if let bytes = cachedOlderFrameBytes.removeValue(forKey: seq) {
                cachedOlderFramesBytes -= bytes
            }
            dropped += 1
        }
        if dropped > 0 {
            cachedOlderFramesTruncated = true
        }
    }

    private func rebuildCachedOlderFrameBytes() {
        var sizes: [Int: Int] = [:]
        var total = 0
        for frame in cachedOlderEventFrames {
            guard let seq = Self.eventFrameSeq(frame) else { continue }
            let bytes = Self.serializedBytes(frame)
            sizes[seq] = bytes
            total += bytes
        }
        cachedOlderFrameBytes = sizes
        cachedOlderFramesBytes = total
    }

    /// Longest gap-free suffix of a decoded older range that is adjacent to the
    /// snapshot window's first record. Anything else is unusable: restoring a
    /// non-contiguous prefix would render a window with a hole (task-7).
    static func contiguousOlderSuffix(_ events: [SessionEvent], snapshotOldest: Int?) -> [SessionEvent] {
        guard let snapshotOldest else { return [] }
        let older = events.filter { $0.seq < snapshotOldest }.sorted { $0.seq < $1.seq }
        guard let last = older.last, last.seq + 1 == snapshotOldest else { return [] }
        var start = older.count - 1
        while start > 0, older[start].seq == older[start - 1].seq + 1 {
            start -= 1
        }
        return Array(older[start...])
    }

    /// Sorted, seq-de-duplicated raw `event` objects.
    private static func mergedEventFrames(_ frames: [JSONValue]) -> [JSONValue] {
        var bySeq: [Int: JSONValue] = [:]
        for frame in frames {
            guard let seq = eventFrameSeq(frame), bySeq[seq] == nil else { continue }
            bySeq[seq] = frame
        }
        return bySeq.keys.sorted().compactMap { bySeq[$0] }
    }

    /// `seq` of a raw `event` object (the `event` field of an `{"type":"event"}`
    /// frame / `session/page` record).
    private static func eventFrameSeq(_ frame: JSONValue) -> Int? {
        guard let raw = frame["seq"]?.intValue else { return nil }
        let seq = Int(raw)
        return seq >= 0 ? seq : nil
    }

    /// Oldest record seq of a raw `{"type":"snapshot",...}` frame.
    private static func snapshotOldestSeq(in snapshot: JSONValue) -> Int? {
        guard let records = snapshot["records"]?.arrayValue else { return nil }
        var oldest: Int?
        for record in records {
            guard let eventValue = record["event"],
                  let seq = eventFrameSeq(eventValue) else { continue }
            if oldest == nil || seq < oldest! {
                oldest = seq
            }
        }
        return oldest
    }

    private static func serializedBytes(_ value: JSONValue) -> Int {
        (try? JSONEncoder().encode(value))?.count ?? 0
    }

    // MARK: - Frame handling

    private func handleItem(_ value: JSONValue?, isFill: Bool = false) {
        guard let value else { return }
        lastEventAt = Date()
        do {
            let frame = try SessionStreamFrame.decode(value)
            switch frame {
            case .snapshot(let snapshot):
                dbg("snapshot: records=" + String(snapshot.records.count) + " cursor=" + String(snapshot.cursor) + " hasMore=" + String(describing: snapshot.hasMore) + " isFill=" + String(isFill))
                let previousSnapshotFrame = cachedSnapshotFrame
                let newSnapshotOldest = Self.snapshotOldestSeq(in: value)
                let update = journal.apply(snapshot: snapshot)
                applyJournalUpdate(update)
                // v5.5 §14.5 first frame: seed the context window from the
                // snapshot projections (M1 gets no incremental projection pushes).
                contextPressure = journal.contextPressure
                isLoading = false
                streamErrorText = nil
                // Task session-history: the snapshot replaces only the newest part
                // of the window; the journal keeps the loaded older prefix. Mirror
                // that in the raw frames kept for the cache write, then adopt the
                // new snapshot frame / reset the live tail (M2b-2).
                refreshCachedOlderFrames(
                    previousSnapshotFrame: previousSnapshotFrame,
                    newSnapshotOldest: newSnapshotOldest
                )
                cachedSnapshotFrame = value
                cachedEventFrames = []
                syncOlderState()
                hasLiveSnapshot = true
                isShowingCachedWindow = false
                cachedWindowIsStale = false
                scheduleCacheSave()
                ensureExpandedCurrentTurn()
                if isFill {
                    // P1.5-B: the legacy 40-message window replaced the small one;
                    // this stream becomes the live one from now on.
                    hasFullWindow = true
                    promoteFillStream()
                } else {
                    // M2b-2c: live snapshot network cost (detail in-app metric).
                    markDetailNetworkApplied()
                    if !hasFullWindow {
                        // P1.5-B: paint the first rows immediately (no 40ms debounce);
                        // the full window is filled in behind.
                        paintFirstRowsImmediately()
                    }
                }
                if !hasFullWindow {
                    scheduleBackgroundFillIfNeeded()
                }
            case .event(let event):
                dbg("event: " + event.type + " seq=" + String(event.seq))
                let update = journal.apply(event: event)
                applyJournalUpdate(update)
                // M2b-2: cache only events the journal actually appended, so the
                // persisted tail stays contiguous with the cached snapshot (a
                // duplicate/gap frame would make the cache unreplayable).
                if case .eventsApplied = update,
                   let rawEvent = value["event"],
                   cachedEventFrames.count < Self.maxCachedEvents {
                    cachedEventFrames.append(rawEvent)
                    scheduleCacheSave()
                }
                // v5.4 task-13 / v5.5 §14.5: relay, turn and assistant-attempt
                // activity refresh session-list-derived state (child runtime
                // metadata + the context window). Debounced ≥2s so this never
                // becomes a high-frequency poll.
                if event.type == "turn/start" || event.type == "turn/end"
                    || event.type == "assistant/attempt"
                    || event.type.hasPrefix("agent-message")
                    || event.type.hasPrefix("agent/") {
                    scheduleSubagentRefreshFromActivity()
                }
            case .assistantStream(let frame):
                let update = journal.apply(assistantStream: frame)
                applyJournalUpdate(update)
            case .unknown:
                break
            }
        } catch {
            // Include the frame type and the failing coding path: the bare
            // Foundation text ("The data couldn't be read…") names nothing.
            dbg("frame decode failed: " + FrameDecodeFailure.describe(error, frame: value))
            streamErrorText = "帧解析失败: \(FrameDecodeFailure.describe(error, frame: value))"
        }
    }

    private func applyJournalUpdate(_ update: SessionJournal.Update) {
        switch update {
        case .snapshotReplaced:
            pendingRebuild = true
            scheduleRebuild()
        case .eventsApplied:
            pendingRebuild = true
            scheduleRebuild()
        case .olderPrepended(let seqs):
            // Front merge: the rows above the current position changed, the newest
            // end did not. An empty result (defensive) has nothing to re-render.
            if seqs.isEmpty {
                publishLiveAssistantText()
            } else {
                pendingRebuild = true
                scheduleRebuild()
            }
        case .duplicate, .ignored, .assistantStreamProgress:
            publishLiveAssistantText()
        case .gap, .assistantRevisionGap:
            // MVP policy: discard the local window and rebuild from a new
            // snapshot (session/page hole patching is M2, protocol §4.3).
            reopenStream()
        }
    }

    /// 流式文本最多 10Hz 发布；`flush` 用于 turn 结束/重建，立即同步到最新文本。
    private func publishLiveAssistantText(flush: Bool = false) {
        let latest = journal.liveAssistantText
        if flush {
            liveTextThrottleTask?.cancel()
            liveTextThrottleTask = nil
            if liveAssistantText != latest { liveAssistantText = latest }
            return
        }
        if liveTextThrottleTask != nil { return }
        if liveAssistantText != latest { liveAssistantText = latest }
        liveTextThrottleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self, !Task.isCancelled else { return }
            self.liveTextThrottleTask = nil
            let newest = self.journal.liveAssistantText
            if self.liveAssistantText != newest { self.liveAssistantText = newest }
        }
    }

    private func scheduleRebuild() {
        guard pendingRebuild else { return }
        guard rebuildTask == nil else { return }
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard let self, !Task.isCancelled else { return }
            self.rebuildTask = nil
            guard self.pendingRebuild else { return }
            self.pendingRebuild = false
            self.rebuildRows()
        }
    }

    private func rebuildRows() {
        // Optimistic echoes (round2 §3): retire the ones whose durable
        // `user/message` arrived (matched by `data.source.rpcId`), then paint
        // the rest at the tail of the flow. Sitting outside the journal means a
        // rebuild / pagination recompute never drops the user's own message.
        let echoCountBefore = pendingUserEchoes.count
        pendingUserEchoes.reconcile(events: journal.events)
        let retiredEchoes = echoCountBefore - pendingUserEchoes.count
        sections = SessionRowBuilder.build(
            events: journal.events,
            pendingUserEchoes: pendingUserEchoes.echoes,
            nowMs: Self.epochMilliseconds()
        )
        dbg("rebuild: events=" + String(journal.events.count) + " sections=" + String(sections.count) + " hasMoreOlder=" + String(journal.hasMoreOlder) + " oldest=" + String(journal.oldestSeq ?? -1) + " pendingEchoes=" + String(pendingUserEchoes.count) + (retiredEchoes > 0 ? " retired=" + String(retiredEchoes) : "") + " turns=" + sections.prefix(12).map { String($0.turn) + ($0.isRunning ? "*" : "") }.joined(separator: ","))
        syncOlderState()
        title = journal.title
        permissionsValue = journal.permissionsValue
        todos = journal.todos
        planActive = journal.plan?["active"]?.boolValue ?? false
        let wasRunning = lastKnownRunning
        isRunning = sections.last?.isRunning ?? false
        lastKnownRunning = isRunning
        // 问题三 H3：running → completed 的这一次刷新，把刚结束的 turn 留在展开态，
        // 直到用户下一次发送输入（sendPrompt）或新 turn 开始才折叠回摘要。
        if wasRunning, !isRunning, let last = sections.last {
            if let previous = stickyExpandedTurnID, previous != last.id {
                expandedTurnIDs.remove(previous)
            }
            stickyExpandedTurnID = last.id
            expandedTurnIDs.insert(last.id)
        }
        publishLiveAssistantText(flush: true)
        approvalPolicy = journal.events.last(where: { $0.type == "approval/policy" })?.data?["policy"]?.stringValue
        sandboxMode = journal.events.last(where: { $0.type == "sandbox/mode" })?.data?["mode"]?.stringValue
        // One parse feeds both surfaces: the strip/catalog display the durable
        // intent (`next`), and the permission sheet shows the same model id (it
        // used to read the lagging `lastUsed` only).
        let liveModelSelection = ModelSelection(projection: journal.modelSelection)
        modelSelection = liveModelSelection
        modelSelectionText = liveModelSelection?.model
        refreshModelCatalogForLiveSelectionIfNeeded()
        applyUserQuestionProjection(journal.userQuestions)
        projectionSubagents = (journal.subagentCatalog ?? []).compactMap(SubagentCatalogEntry.init(json:))
        subagentCatalog = SubagentCatalogMerge.merge(
            projection: projectionSubagents,
            discovered: discoveredSubagents
        )
        let catalogIds = subagentCatalog.map(\.id)
        if subagentContext == nil, !catalogIds.isEmpty, catalogIds != lastSubagentCatalogIds {
            lastSubagentCatalogIds = catalogIds
            Task { [weak self] in
                await self?.refreshSubagentRuntime()
            }
        }
        ensureExpandedCurrentTurn()
        expandNewlyLoadedOlderTurnIfNeeded()
        requestFileChangeSummariesIfNeeded()
        // v5.4 queue: a finished turn automatically releases the oldest queued
        // prompt with mode=queue; the rest keep waiting for the next turn/end.
        if SessionQueuePolicy.shouldFlush(wasRunning: wasRunning, isRunning: isRunning, queuedCount: queuedPrompts.count) {
            flushNextQueuedPrompt()
        }
        // M2b-2c: if the detail is already on screen (no cache hit -> first rows came
        // from the live snapshot), this is the first visible content.
        maybeMarkDetailFirstFrame()
        // P1.5-B: the legacy 40-message window is on screen (background fill landed,
        // or the open used the wide window). Evidence only, idempotent.
        if hasFullWindow {
            DetailMetrics.markFullWindowApplied()
            detailMetricsValue = DetailMetrics.valueString
        }
    }

    /// 2026-10-22 真机 A5：更早页合并进一个**已存在的、已完成的 turn** 时，那条 turn
    /// 的 section 默认是折叠的 —— 用户下拉后只看到原来的 header，看起来「没刷出更早
    /// 消息」。合并成功后展开最老的 section，让刚加载的行立刻上屏。
    private func expandNewlyLoadedOlderTurnIfNeeded() {
        guard olderPageJustMerged else { return }
        olderPageJustMerged = false
        guard let first = sections.first else { return }
        expandedTurnIDs.insert(first.id)
    }

    private func ensureExpandedCurrentTurn() {
        guard let last = sections.last else { return }
        // 运行中的 turn 必须展开（哪怕用户展开了别的历史 turn）。
        // 已结束的 turn 不在这里反复插入：turn/end 那一次由 stickyExpandedTurnID 插入一次，
        // 用户手动折叠后不应该被下一次刷新再展开回来（交接文档 §7.4 第 3 条）。
        if last.isRunning || expandedTurnIDs.isEmpty {
            expandedTurnIDs.insert(last.id)
        }
    }

    // MARK: - Session-list derived refresh (v5.4 task-13 / v5.5 §14.5)

    /// One `session/list` read that refreshes everything derived from the list:
    /// - v5.5 §14.5: the context window of **this** session (normal detail or
    ///   subagent detail — a subagent child is listed under its own child id, so
    ///   `sessionId` matches both);
    /// - v5.4 task-13: child `subagentRuntimes` for a parent detail with a catalog.
    ///
    /// Callers must debounce/poll: the activity trigger is a trailing ≥2s debounce
    /// and the detail view's tick is 8s, so this is never a per-frame request.
    /// A refresh that cannot read the list keeps the last known value.
    func refreshSessionListDerived(pendingApprovalAgentIds: Set<String> = []) async {
        guard let link else {
            subagentRuntimes = [:]
            return
        }
        guard let sessions = try? await link.listSessions() else { return }
        contextPressure = ContextPressureResolver.refreshValue(
            current: contextPressure,
            sessionId: sessionId,
            sessions: sessions
        )
        guard subagentContext == nil else {
            subagentRuntimes = [:]
            return
        }
        // v0.2.0 live discovery: the `subagentCatalog` projection only ships with a
        // journal snapshot, so a child that starts while this detail is open would
        // otherwise stay invisible until a reopen. `session/list` (already fetched)
        // carries the same children — merge them in so the capsule/beam follows
        // reality within one activity debounce.
        let discovered = SubagentCatalogMerge.discovered(
            sessions: sessions,
            parentSessionId: sessionId
        )
        if discovered != discoveredSubagents {
            discoveredSubagents = discovered
            let merged = SubagentCatalogMerge.merge(
                projection: projectionSubagents,
                discovered: discovered
            )
            if merged != subagentCatalog {
                subagentCatalog = merged
            }
        }
        guard !subagentCatalog.isEmpty else {
            subagentRuntimes = [:]
            return
        }
        subagentRuntimes = SubagentRuntimeBuilder.make(
            catalog: subagentCatalog,
            sessions: sessions,
            pendingApprovalAgentIds: pendingApprovalAgentIds
        )
    }

    /// v5.4 compatibility wrapper: existing call sites keep their signature and
    /// the legacy gating (only a parent detail with a catalog issues the request;
    /// the detail view's 8s tick therefore stays network-free for other sessions).
    /// The v5.5 context window for those sessions arrives through the activity
    /// debounce below, whose first frame already comes from the snapshot.
    func refreshSubagentRuntime(pendingApprovalAgentIds: Set<String> = []) async {
        guard subagentContext == nil, !subagentCatalog.isEmpty else {
            subagentRuntimes = [:]
            return
        }
        await refreshSessionListDerived(pendingApprovalAgentIds: pendingApprovalAgentIds)
    }

    /// Trailing ≥2s debounced refresh after relay / turn / assistant-attempt
    /// activity. v5.5: no longer gated on having a subagent catalog, so subagent
    /// details and plain main sessions refresh their context window too.
    private func scheduleSubagentRefreshFromActivity() {
        subagentDebounceTask?.cancel()
        subagentDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.refreshSessionListDerived()
        }
    }

    // MARK: - Intents

    /// Unified composer send (v5.4): while a turn runs the message joins the
    /// client-side queue; when idle it is sent immediately with `mode=queue`.
    ///
    /// M2a fix: never dead-end on transport state. If the link is reconnecting or
    /// offline the prompt is queued locally (with feedback) and flushed as soon as
    /// the next connected phase arrives — the button used to be disabled/greyed
    /// out in that window, which users read as "无法发送".
    func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        draft = ""
        SendMetrics.begin()
        let connected = link?.phase.isConnected ?? false
        if isRunning || !connected {
            queuedPrompts.enqueue(text: text)
            SendMetrics.markQueued()
            sendMetricsValue = SendMetrics.valueString
            // M2a UX: make the "queued" outcome perceptible (the user used to read
            // the silent queue / grey button as a send failure).
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            maybeFlushQueued()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let sent = await sendPrompt(text: text, mode: "queue")
            if !sent {
                // Transport hiccup: keep the text (queue + offline banner) instead
                // of silently dropping it.
                queuedPrompts.enqueue(text: text)
            }
        }
    }

    /// Send queued prompts automatically once the link is connected and idle
    /// (offline queue after a reconnect, or the running -> idle turn transition).
    private func maybeFlushQueued() {
        guard let link, link.phase.isConnected, !isRunning, !sending, !queuedPrompts.isEmpty else { return }
        flushNextQueuedPrompt()
    }

    /// Queue bar tap: release the oldest queued prompt immediately as `steer`.
    func steerFirstQueued() {
        guard let link, link.phase.isConnected, !sending, let prompt = queuedPrompts.takeFirst() else { return }
        Task { [weak self] in
            guard let self else { return }
            let sent = await self.sendPrompt(text: prompt.text, mode: "steer")
            if !sent { self.queuedPrompts.restore(prompt) }
        }
    }

    /// Turn/end flush: send the oldest queued prompt with `mode=queue`.
    private func flushNextQueuedPrompt() {
        guard !sending, let prompt = queuedPrompts.takeFirst() else { return }
        Task { [weak self] in
            guard let self else { return }
            let sent = await self.sendPrompt(text: prompt.text, mode: "queue")
            if !sent { self.queuedPrompts.restore(prompt) }
        }
    }

    @discardableResult
    private func sendPrompt(text: String, mode: String) async -> Bool {
        guard let link else { return false }
        // The prompt RPC id doubles as the optimistic-echo key: the host records
        // it on the durable message as `data.source.rpcId` (kind "user").
        let requestId = UUID().uuidString.lowercased()
        sending = true
        actionErrorText = nil
        defer { sending = false }
        do {
            if let context = subagentContext {
                // v5.4 task-13: continuable subagents accept subagents/prompt;
                // one-shot / external children are read-only from the phone.
                guard context.mode.isContinuable else {
                    actionErrorText = context.readOnlyReason ?? "该子代理只读"
                    return false
                }
                _ = try await link.subagentsPrompt(
                    parentSessionId: context.parentSessionId,
                    childSessionId: context.childSessionId,
                    delivery: mode == "steer" ? "steer" : "queue",
                    text: text
                )
            } else {
                _ = try await link.unary("session/prompt", args: [
                    "request": .object([
                        "requestId": .string(requestId),
                        "sessionId": .string(sessionId),
                        "mode": .string(mode),
                        "content": .array([
                            .object(["type": .string("text"), "text": .string(text)]),
                        ]),
                        "clientTimeZone": .string(TimeZone.current.identifier),
                    ]),
                ])
            }
            // 问题三 H3：用户发出下一条输入时才折叠上一轮（桌面端 next-input 语义）。
            if let sticky = stickyExpandedTurnID {
                expandedTurnIDs.remove(sticky)
                stickyExpandedTurnID = nil
            }
            isRunning = true
            lastKnownRunning = true
            // Round2 §3: the host accepted the prompt, but `user/message` is only
            // durable once the running turn claims its inbox (steer: next step).
            // Paint the bubble now; `rebuildRows` retires it by rpcId later.
            if subagentContext == nil {
                recordPendingUserEcho(requestId: requestId, text: text, mode: mode)
            }
            SendMetrics.markAccepted()
            sendMetricsValue = SendMetrics.valueString
            return true
        } catch {
            SendMetrics.markFailed()
            sendMetricsValue = SendMetrics.valueString
            actionErrorText = NetworkErrorInterpreter.message(for: error)
            return false
        }
    }

    // MARK: - Optimistic user echo (round2 §3, task-2)

    /// Paints a prompt immediately instead of waiting for the host's durable
    /// `user/message`. Failure paths never record (the caller keeps the existing
    /// error toast / queue restore), so a failed send leaves no ghost bubble.
    private func recordPendingUserEcho(requestId: String, text: String, mode: String) {
        let now = Self.epochMilliseconds()
        pendingUserEchoes.record(SessionRowBuilder.PendingUserEcho(
            requestId: requestId,
            text: text,
            images: [],
            sentAt: now,
            mode: mode
        ))
        dbg("pending echo recorded: " + requestId + " mode=" + mode)
        // Race guard: a fast idle followup can materialize the durable event before
        // this response is processed — retire the echo before it is ever painted.
        pendingUserEchoes.reconcile(events: journal.events)
        repaintPendingUserEchoes()
        schedulePendingEchoStaleRefresh()
    }

    /// Repaint the optimistic tail rows in place. Deliberately NOT a full
    /// `rebuildRows()`: that would recompute `isRunning` from the journal and
    /// could briefly report idle between `session/prompt` and `turn/start`
    /// (queue-flush side effects). A pending row only ever needs appending.
    private func repaintPendingUserEchoes() {
        sections = SessionRowBuilder.appendingPendingEchoes(
            pendingUserEchoes.echoes,
            to: sections,
            nowMs: Self.epochMilliseconds()
        )
    }

    /// `mode:"steer"` can legitimately wait minutes for the running turn's next
    /// step. The bubble is kept until the durable event retires it, but the
    /// "发送中…" marker must not hang forever: this one-shot wakeup repaints the
    /// rows when the oldest echo's indicator expires (works with no event traffic).
    private func schedulePendingEchoStaleRefresh() {
        pendingEchoStaleTask?.cancel()
        let now = Self.epochMilliseconds()
        guard let deadline = pendingUserEchoes.nextSendingIndicatorDeadline(nowMs: now) else {
            pendingEchoStaleTask = nil
            return
        }
        let delayMs = max(0, deadline - now)
        pendingEchoStaleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingEchoStaleTask = nil
            guard !self.pendingUserEchoes.isEmpty else { return }
            self.dbg("pending echo indicator expired; repaint")
            self.repaintPendingUserEchoes()
            // Later echoes may still be inside their own window.
            self.schedulePendingEchoStaleRefresh()
        }
    }

    private static func epochMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    func abort() async {
        guard let link else { return }
        actionErrorText = nil
        do {
            if let context = subagentContext {
                // v5.4 task-13: interrupt a child session from its parent.
                _ = try await link.subagentsInterruptByParent(
                    parentSessionId: context.parentSessionId,
                    childSessionId: context.childSessionId
                )
            } else {
                _ = try await link.unary("session/cancel", args: [
                    "request": .object(["sessionId": .string(sessionId)]),
                ])
            }
            // T10: the aborted turn's pending live question can no longer be
            // answered; clear the card without waiting for a $events cancel frame.
            dismissLiveUserQuestionsForAbortedTurn()
        } catch {
            actionErrorText = NetworkErrorInterpreter.message(for: error)
        }
    }

    func respond(approval: ApprovalWaterfall, outcome: ApprovalOutcome) async {
        guard let link else { return }
        actionErrorText = nil
        do {
            try await link.respondApproval(approval, outcome: outcome)
        } catch {
            actionErrorText = NetworkErrorInterpreter.message(for: error)
        }
    }

    // MARK: - Session permission preset (M5)

    /// Lazily loads the selectable preset catalog. Called when the permission sheet
    /// opens; `force` re-fetches after a failure (the sheet's retry affordance).
    /// A successful load is cached for the lifetime of this detail; a failure is
    /// not, so re-opening the sheet retries.
    func loadPermissionCatalogIfNeeded(force: Bool = false) async {
        if !force, permissionCatalogLoaded { return }
        guard !permissionCatalogLoading else { return }
        permissionCatalogLoading = true
        defer { permissionCatalogLoading = false }
        do {
            let catalog = try await fetchPermissionCatalog()
            presetOptions = catalog.options
            if let defaultPreset = catalog.defaultPreset, !defaultPreset.isEmpty {
                presetDefault = defaultPreset
            }
            permissionCatalogLoaded = true
            permissionSwitchError = nil
        } catch {
            permissionCatalogLoaded = false
            permissionSwitchError = PermissionSwitchErrorText.message(for: error)
        }
    }

    /// Selects `value` as this session's permission preset.
    ///
    /// Success updates `permissionsValue` optimistically; the host then emits
    /// `permission/preset`, `approval/policy` and `sandbox/mode`, which
    /// `rebuildRows` re-syncs from the journal — so the strip and the sheet agree
    /// even when another client changes the preset meanwhile. Failure only fills
    /// `permissionSwitchError`; the previous preset stays selected.
    func switchPermissionPreset(_ value: String) async {
        guard !permissionSwitching else { return }
        permissionSwitching = true
        permissionSwitchError = nil
        defer { permissionSwitching = false }
        do {
            let update = try await submitPermission(preset: value)
            permissionsValue = update.preset.isEmpty ? value : update.preset
            if !update.catalog.options.isEmpty {
                presetOptions = update.catalog.options
                if let defaultPreset = update.catalog.defaultPreset, !defaultPreset.isEmpty {
                    presetDefault = defaultPreset
                }
                permissionCatalogLoaded = true
            }
        } catch {
            permissionSwitchError = PermissionSwitchErrorText.message(for: error)
        }
    }

    /// True when `value` is the selected preset: the session's current value, or
    /// the host default while `permissions.currentValue` has not landed yet.
    func isPermissionPresetSelected(_ value: String) -> Bool {
        (permissionsValue ?? presetDefault) == value
    }

    private func fetchPermissionCatalog() async throws -> PermissionPresetCatalog {
        if let permissionCatalogLoader { return try await permissionCatalogLoader() }
        guard let link else { throw LinkError.notConnected }
        return try await link.permissionPresetCatalog()
    }

    private func submitPermission(preset: String) async throws -> SessionPermissionUpdate {
        if let permissionSwitcher { return try await permissionSwitcher(preset) }
        guard let link else { throw LinkError.notConnected }
        return try await link.setSessionPermission(sessionId: sessionId, preset: preset)
    }

    // MARK: - Model selection (v0.2.0)

    /// Loads `session/modelCatalog` once per detail (failure keeps the entry
    /// retryable). Subagent sessions never load it.
    func loadModelCatalogIfNeeded(force: Bool = false) async {
        guard !isSubagentSession else { return }
        if !force, modelCatalogLoaded { return }
        guard !modelCatalogLoading else { return }
        modelCatalogLoading = true
        defer { modelCatalogLoading = false }
        do {
            let catalog = try await fetchModelCatalog()
            modelCatalog = catalog
            modelCatalogLoaded = true
            modelCatalogErrorText = nil
        } catch {
            modelCatalogLoaded = false
            modelCatalogErrorText = NetworkErrorInterpreter.message(for: error)
        }
    }

    /// A model switch made on the desktop arrives live as a `model/selection`
    /// event (patched into the projection by `SessionJournal`). When the cached
    /// catalog cannot name that route yet — a provider/model added after this
    /// detail loaded its catalog — the strip would fall back to "请选择模型", so
    /// refresh the catalog once per unknown selection. `modelCatalogUnknownSelection`
    /// makes that idempotent: repeated rebuilds for the same selection do not
    /// re-fetch, and a failing refresh cannot loop.
    private func refreshModelCatalogForLiveSelectionIfNeeded() {
        guard !isSubagentSession, modelCatalogLoaded, let selection = modelSelection else { return }
        guard let catalog = modelCatalog,
              catalog.model(provider: selection.provider, id: selection.model) == nil else {
            modelCatalogUnknownSelection = nil
            return
        }
        guard modelCatalogUnknownSelection != selection else { return }
        modelCatalogUnknownSelection = selection
        Task { [weak self] in
            await self?.loadModelCatalogIfNeeded(force: true)
        }
    }

    /// Applies one model selection. The Host installs it for the next request
    /// boundary; a running step keeps its model (desktop parity). On success the
    /// local selection updates immediately so the strip/sheet agree; on failure
    /// the sheet stays open with the error and the previous selection survives.
    func selectModel(_ selection: ModelSelection) async {
        guard !isSubagentSession, !modelSelecting else { return }
        modelSelecting = true
        modelSelectionPending = selection
        modelSelectionErrorText = nil
        defer {
            modelSelecting = false
            modelSelectionPending = nil
        }
        do {
            let selected = try await submitModelSelection(selection)
            modelSelection = selected
            modelCatalogErrorText = nil
        } catch {
            modelSelectionErrorText = NetworkErrorInterpreter.message(for: error)
        }
    }

    /// Clears the sheet-local selection error (called when the sheet opens).
    func clearModelSelectionError() {
        modelSelectionErrorText = nil
    }

    private func fetchModelCatalog() async throws -> ModelCatalog {
        if let modelCatalogLoader { return try await modelCatalogLoader() }
        guard let link else { throw LinkError.notConnected }
        return try await link.modelCatalog()
    }

    private func submitModelSelection(_ selection: ModelSelection) async throws -> ModelSelection {
        if let modelSelector { return try await modelSelector(selection) }
        guard let link else { throw LinkError.notConnected }
        return try await link.selectModel(sessionId: sessionId, selection: selection)
    }

    #if DEBUG
    /// E2E screenshot hook: deterministic context-window percentage without a
    /// Host ().
    func installE2EContextPreview(percent: Int) {
        let window = 1_000_000
        contextPressure = ContextPressureValue(
            projectedTokens: window * max(0, percent) / 100,
            contextWindow: window
        )
    }

    /// E2E screenshot hook: deterministic catalog/selection without a Host.
    /// Gated by `DSHM_E2E=1` + `DSHM_E2E_MODEL=1` in SessionDetailView; no
    /// product behavior.
    func installE2EModelPreview() {
        guard !isSubagentSession else { return }
        modelCatalog = ModelCatalog(
            defaultSelection: .init(provider: "deepseek-official", model: "deepseek-flash", reasoningEffort: "high"),
            routableProviders: ["deepseek-official"],
            groups: [
                .init(id: "deepseek-account", name: "DeepSeek 账号", models: [
                    .init(id: "deepseek-v3", name: "deepseek-v3", description: nil, reasoning: .init(
                        efforts: [
                            .init(id: "medium", name: "medium", description: nil),
                            .init(id: "high", name: "high", description: nil),
                        ],
                        defaultEffort: "high"
                    )),
                ]),
                .init(id: "deepseek-official", name: "DeepSeek", models: [
                    .init(id: "deepseek-flash", name: "deepseek-flash", description: nil, reasoning: .init(
                        efforts: [
                            .init(id: "low", name: "low", description: nil),
                            .init(id: "high", name: "high", description: nil),
                            .init(id: "max", name: "max", description: nil),
                        ],
                        defaultEffort: "high"
                    )),
                    .init(id: "deepseek-pro", name: "deepseek-pro", description: nil, reasoning: .init(
                        efforts: [
                            .init(id: "medium", name: "medium", description: nil),
                            .init(id: "high", name: "high", description: nil),
                        ],
                        defaultEffort: "medium"
                    )),
                ]),
            ],
            failures: []
        )
        modelCatalogLoaded = true
        modelCatalogLoading = false
        modelCatalogErrorText = nil
        modelSelectionErrorText = nil
        modelSelection = ModelSelection(
            provider: "deepseek-official",
            model: "deepseek-flash",
            reasoningEffort: "high"
        )
    }
    #endif

    // MARK: - User questions (task-2 / tech-design §14)

    /// Applies `projections.values.userQuestions` to the published state.
    /// Called from `rebuildRows` (snapshot) and testable in isolation.
    func applyUserQuestionProjection(_ value: JSONValue?) {
        projectionUserQuestions = UserQuestionsProjection.parse(value).active
        rebuildActiveUserQuestions()
    }

    /// True when `callId` was answered by this client and must stay hidden even
    /// if a stale snapshot/event replay or a stale `session/list` read brings it
    /// back (P0-1 / P1-1).
    func isUserQuestionAnsweredLocally(_ callId: String) -> Bool {
        locallyAnsweredCallIds.contains(callId)
    }

    /// Applies the live `$events` pending waterfalls (Combine subscription on
    /// `link.$pendingUserQuestions`). Live calls are the only source on builds
    /// whose projection stays empty (legacy/blocking ask_user_question schema);
    /// on the same `callId` the projection wins.
    func applyPendingUserQuestionWaterfalls(_ waterfalls: [UserQuestionWaterfall]) {
        liveUserQuestionWaterfalls = waterfalls.filter {
            $0.agentId == nil || $0.agentId == sessionId
        }
        rebuildActiveUserQuestions()
    }

    /// Merges the projection half and the live half into `activeUserQuestions`.
    /// A live call without `wait.callId` uses its `eventId` as stable identity.
    private func rebuildActiveUserQuestions() {
        // A call without usable questions cannot be answered (it would render an
        // empty card and submit an empty batch); hide it like an unparsable
        // entry, mirroring the P1-4 guard on live waterfalls.
        let projectionCalls = projectionUserQuestions.filter { !$0.questions.isEmpty }
        var seen = Set(projectionCalls.map(\.callId))
        var merged = projectionCalls
        for waterfall in liveUserQuestionWaterfalls
        where !dismissedLiveWaterfallEventIds.contains(waterfall.eventId) {
            let callId = waterfall.callId ?? waterfall.eventId
            guard !seen.contains(callId) else { continue }
            seen.insert(callId)
            merged.append(UserQuestionCall(callId: callId, state: .open, questions: waterfall.questions))
        }
        if !locallyAnsweredCallIds.isEmpty {
            merged.removeAll { locallyAnsweredCallIds.contains($0.callId) }
        }
        activeUserQuestions = merged
    }

    /// Path that `submitUserQuestionAnswers(callId:)` will take; internal so the
    /// open/live routing stays unit-testable without networking.
    func userQuestionSubmitPath(callId: String) -> UserQuestionSubmitPath {
        UserQuestionSubmitPlanner.path(
            for: activeUserQuestions.first { $0.callId == callId },
            pending: pendingUserQuestionWaterfallsForSubmit()
        )
    }

    /// Union of the cached live half and the link's authoritative pending list
    /// (deduplicated by `eventId`).
    private func pendingUserQuestionWaterfallsForSubmit() -> [UserQuestionWaterfall] {
        var result = liveUserQuestionWaterfalls
        if let link {
            for waterfall in link.pendingUserQuestionWaterfalls(forSession: sessionId)
            where !result.contains(where: { $0.eventId == waterfall.eventId }) {
                result.append(waterfall)
            }
        }
        return result
    }

    /// Re-reads this session's `userQuestions.active` from `session/list`
    /// (lighter than reopening `session/follow`) and republishes it.
    ///
    /// When `callId` is given, retries briefly until the answered call is gone
    /// from the refreshed projection (guards against a stale list read).
    func refreshUserQuestions(afterAnswering callId: String? = nil) async {
        guard let link else { return }
        var attempt = 0
        while attempt < 3 {
            guard let sessions = try? await link.listSessions() else { return }
            guard let item = sessions.first(where: { $0.sessionId == sessionId }) else { return }
            projectionUserQuestions = item.activeUserQuestions
            rebuildActiveUserQuestions()
            guard let callId, activeUserQuestions.contains(where: { $0.callId == callId }) else { return }
            attempt += 1
            if attempt < 3 { try? await Task.sleep(nanoseconds: 300_000_000) }
        }
    }

    /// Answers one pending user-question call. Path selection depends on the
    /// projection state: `continued` → unary `userQuestions/answer`;
    /// `open` → live `$events/result` waterfall (only if this client holds the
    /// live request), otherwise `UserQuestionSubmitError.noLiveRequest`.
    ///
    /// The answer always refreshes `activeUserQuestions` so the card disappears
    /// (write-back), and `REPLY_QUEUED` is reported as `.queued` instead of an
    /// error. Other errors are thrown to the UI (show NetworkErrorInterpreter).
    @discardableResult
    func submitUserQuestionAnswers(
        callId: String,
        answers: [UserQuestionAnswer]
    ) async throws -> UserQuestionSubmitOutcome {
        // Duplicate/concurrent guard (T10): reject a second submit for the same
        // call while the first is in flight instead of sending twice.
        guard userQuestionSubmitGate.begin(callId) else {
            throw UserQuestionSubmitError.alreadySubmitting(callId)
        }
        defer { userQuestionSubmitGate.end(callId) }
        let path = userQuestionSubmitPath(callId: callId)
        switch path {
        case .callNotFound:
            throw UserQuestionSubmitError.callNotFound(callId)
        case .noLiveRequest:
            throw UserQuestionSubmitError.noLiveRequest
        case .unsupportedState(let raw):
            throw UserQuestionSubmitError.unsupportedState(raw)
        case .unary, .live:
            break
        }
        guard let link else { throw LinkError.notConnected }
        switch path {
        case .unary:
            do {
                let accepted = try await link.answerUserQuestions(
                    sessionId: sessionId,
                    callId: callId,
                    answers: answers
                )
                let outcome = UserQuestionSubmitPlanner.outcome(accepted: accepted)
                markUserQuestionAnsweredLocally(callId: callId)
                await refreshUserQuestions(afterAnswering: callId)
                return outcome
            } catch {
                if let outcome = UserQuestionSubmitPlanner.outcome(for: error) {
                    markUserQuestionAnsweredLocally(callId: callId)
                    await refreshUserQuestions(afterAnswering: callId)
                    return outcome
                }
                throw error
            }
        case .live(let eventId):
            try await link.answerUserQuestionsLive(eventId: eventId, answers: answers)
            markUserQuestionAnsweredLocally(callId: callId)
            await refreshUserQuestions(afterAnswering: callId)
            return .answeredViaLiveEvents
        case .callNotFound, .noLiveRequest, .unsupportedState:
            // Validated above; kept for exhaustiveness.
            throw UserQuestionSubmitError.callNotFound(callId)
        }
    }

    /// Skips every question of one call (`selected: []`, protocol §3.7.2).
    @discardableResult
    func skipUserQuestion(callId: String) async throws -> UserQuestionSubmitOutcome {
        guard let call = activeUserQuestions.first(where: { $0.callId == callId }) else {
            throw UserQuestionSubmitError.callNotFound(callId)
        }
        return try await submitUserQuestionAnswers(
            callId: callId,
            answers: UserQuestionSubmitPlanner.skipAnswers(for: call)
        )
    }

    /// T10: aborting the turn makes any still-pending live question of this
    /// session unanswerable (the legacy blocking ask has no timeout, and the
    /// Host may not send a `$events` cancel frame). Dismiss those cards locally;
    /// a later cancel frame or projection refresh stays consistent because the
    /// dismissed event ids are never shown again.
    func dismissLiveUserQuestionsForAbortedTurn() {
        guard !liveUserQuestionWaterfalls.isEmpty else { return }
        dismissedLiveWaterfallEventIds.formUnion(liveUserQuestionWaterfalls.map(\.eventId))
        liveUserQuestionWaterfalls = []
        rebuildActiveUserQuestions()
    }

    /// Optimistic write-back: the answered call disappears immediately (from
    /// both the projection half and the live half); the following
    /// `session/list` / `$events` refresh corrects the truth.
    func markUserQuestionAnsweredLocally(callId: String) {
        // Suppress the call until the Host's projection stops listing it; this
        // is what keeps a replayed stale snapshot / event rebuild from re-adding
        // an already answered card (P0-1, P1-1).
        locallyAnsweredCallIds.insert(callId)
        projectionUserQuestions.removeAll { $0.callId == callId }
        liveUserQuestionWaterfalls.removeAll { ($0.callId ?? $0.eventId) == callId }
        rebuildActiveUserQuestions()
    }

    func toolCall(callId: String?) -> ToolCallItem? {
        SessionRowBuilder.findToolCall(in: sections, callId: callId)
    }

    // MARK: - File changes (exact-fetch §3.9, meta.diffs fallback)

    /// Merged view for one turn: exact-fetch summary when the Host still holds it,
    /// otherwise the client-side meta.diffs aggregation.
    func turnFileChanges(for section: TurnSection) -> TurnFileChanges? {
        if let seq = section.fileChangeSeq, let summary = fileChangeSummaries[seq] {
            return TurnFileChanges(
                source: .exactFetch,
                files: summary.files,
                added: summary.added ?? summary.files.reduce(0) { $0 + ($1.added ?? 0) },
                deleted: summary.deleted ?? summary.files.reduce(0) { $0 + ($1.deleted ?? 0) },
                seq: seq
            )
        }
        guard let fallback = section.fileChanges else { return nil }
        return TurnFileChanges(
            source: .metaDiffsFallback,
            files: fallback.files.map { ChangesSummaryValue.File(path: $0, display: ($0 as NSString).lastPathComponent, added: nil, deleted: nil) },
            added: fallback.additions,
            deleted: fallback.deletions,
            seq: section.fileChangeSeq
        )
    }

    /// Requests exact-fetch summaries for turns whose workspace/changes event is
    /// known; 404 (host restarted / session released) marks the turn for fallback.
    private func requestFileChangeSummariesIfNeeded() {
        guard let link else { return }
        for section in sections {
            guard let seq = section.fileChangeSeq else { continue }
            if fileChangeSummaries[seq] != nil || fileChangeUnavailableSeqs.contains(seq) { continue }
            if requestedFileChangeSeqs.contains(seq) { continue }
            requestedFileChangeSeqs.insert(seq)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let summary = try await link.changesSummary(sessionId: self.sessionId, seq: seq)
                    self.fileChangeSummaries[seq] = summary
                } catch {
                    self.fileChangeUnavailableSeqs.insert(seq)
                }
            }
        }
    }

    /// Loads `/api/changes.diff` for one file in a turn's change set.
    func loadFileDiff(seq: Int, index: Int) async -> ChangesDiffValue? {
        guard let link else { return nil }
        do {
            return try await link.changesDiff(sessionId: sessionId, seq: seq, index: index)
        } catch {
            actionErrorText = NetworkErrorInterpreter.message(for: error)
            return nil
        }
    }
}
