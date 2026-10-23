import Combine
import Foundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

/// P0 (detail spinner): what a deferred `session/follow` open should do next.
///
/// `openStream()` cannot open while the link is down; the old code simply returned
/// there and recovery relied on `generation` changing. That misses two real paths:
/// (a) a **silent dsh-m/2 resume**, which keeps the generation on purpose
/// (`P1ResumePlan.bumpGeneration == false`), and (b) a phase flip that lands before
/// SwiftUI installs the view's `.onChange`. This policy makes the recovery explicit
/// and bounded: wait while the link is busy, open exactly once as soon as it is
/// connected, and surface a retryable error after `deferredStreamOpenTimeout`
/// instead of spinning forever.
enum DeferredStreamOpenPolicy {
    enum Action: Equatable {
 /// Nothing was deferred (or the stream is already open): do nothing.
        case idle
 /// Link not ready yet: keep waiting; the deadline task owns the failure.
        case wait
 /// Link is ready and nothing is open: open the stream now (idempotent).
        case open
 /// Deadline elapsed with the link still down: surface the retry entry.
        case fail
    }

    static func action(
        phaseIsConnected: Bool,
        isDeferred: Bool,
        hasOpenStream: Bool,
        deadlineElapsed: Bool
    ) -> Action {
        guard isDeferred else { return .idle }
 // A stream that is already open wins over any stale deferral: reopening it
 // would replace the live handle and drop frames.
        if hasOpenStream { return .idle }
        if phaseIsConnected { return .open }
        return deadlineElapsed ? .fail : .wait
    }
}

/// Retry policy for the exact `/api/changes.summary` fetch (task-2: cross-end
/// file-change consistency, handoff §2.4).
///
/// The protocol says the Host keeps one turn's file summary in process memory and
/// drops it on a restart / session release, so **404 is the only terminal failure**.
/// Everything else — timeout / TLS / relay 5xx / the relay proxy's own 404
/// `route/not-allowed` (packages/dsh-m-link/lib/link-server.js:1618-1623) — is
/// retried with a 1 s → 2 s → 4 s backoff so a network handover or relay hiccup
/// does not pin the meta.diffs aggregate for the rest of the session.
enum FileChangesFetchPolicy {
 /// Reply bodies the relay proxy uses when the failure is on the relay side, not
 /// the Host releasing the summary. A bare 404 without these is the Host's.
    static let relayFailureMarkers = [
        "route/not-allowed",
        "upstream-connect-failed",
        "upstream-unreachable",
    ]

    enum FailureKind: Equatable {
 /// Host really dropped the summary: stop; the fallback is all we have.
        case hostReleased
 /// Network / relay / auth / decoding fault: retry with backoff.
        case transient
    }

    enum Decision: Equatable {
        case retry(delay: TimeInterval)
        case giveUp
    }

 /// 1 s → 2 s → 4 s (three retries after the first attempt).
    static let backoff: [TimeInterval] = [1, 2, 4]
    static var maxRetries: Int { backoff.count }

    static func failureKind(for error: Error) -> FailureKind {
        guard let linkError = error as? LinkError,
              case let .httpStatus(status, body) = linkError,
              status == 404 else { return .transient }
        if relayFailureMarkers.contains(where: { body.contains($0) }) { return .transient }
        return .hostReleased
    }

    static func decision(afterFailure kind: FailureKind, retriesMade: Int) -> Decision {
        guard kind == .transient else { return .giveUp }
        guard retriesMade < maxRetries else { return .giveUp }
        return .retry(delay: backoff[max(0, retriesMade)])
    }
}

/// Bookkeeping for the newest turn's exact summary fetch: which seq is loading,
/// how many retries were made, and which seqs are 404-terminal. Value type so the
/// transitions are unit-tested. `loadingSeqs` is what keeps the card/sheet from
/// presenting the fallback numbers while the exact ones are still being fetched
/// (the reported 18-vs-50-file mismatch, handoff §2.1).
struct FileChangesFetchState: Equatable {
    enum Outcome: Equatable {
        case scheduledRetry(delay: TimeInterval)
        case failedPermanently
        case failedTransiently
    }

    private(set) var loadingSeqs: Set<Int> = []
    private(set) var attempts: [Int: Int] = [:]
    private(set) var terminalSeqs: Set<Int> = []

    mutating func begin(seq: Int) {
        loadingSeqs.insert(seq)
        if attempts[seq] == nil { attempts[seq] = 0 }
    }

    mutating func succeeded(seq: Int) {
        loadingSeqs.remove(seq)
        attempts[seq] = nil
    }

    mutating func failed(seq: Int, error: Error) -> Outcome {
        let kind = FileChangesFetchPolicy.failureKind(for: error)
        let retriesMade = attempts[seq] ?? 0
        switch FileChangesFetchPolicy.decision(afterFailure: kind, retriesMade: retriesMade) {
        case .giveUp:
            loadingSeqs.remove(seq)
            attempts[seq] = nil
            if kind == .hostReleased { terminalSeqs.insert(seq) }
            return kind == .hostReleased ? .failedPermanently : .failedTransiently
        case .retry(let delay):
            attempts[seq] = retriesMade + 1
            return .scheduledRetry(delay: delay)
        }
    }

    mutating func reset() {
        loadingSeqs.removeAll()
        attempts.removeAll()
        terminalSeqs.removeAll()
    }

    func isLoading(_ seq: Int?) -> Bool {
        guard let seq else { return false }
        return loadingSeqs.contains(seq)
    }

    func isTerminal(_ seq: Int) -> Bool { terminalSeqs.contains(seq) }
    func retriesMade(_ seq: Int) -> Int { attempts[seq] ?? 0 }
}

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

 /// 会话流：**一条平铺的消息行流** + 运行状态 + 最新一轮文件变更。
 /// 设计决策删除 turn UI，与 DSH 桌面端一致；turn 边界只参与派生状态。
    @Published private(set) var flow = SessionFlow()
 /// 渲染行速记（视图/单测读它，等价于 `flow.rows`）。
    var rows: [FlowRow] { flow.rows }
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
 /// Exact-fetch (protocol §3.9) summaries keyed by workspace/changes seq.
    @Published private(set) var fileChangeSummaries: [Int: ChangesSummaryValue] = [:]
 /// task-2: loading/retry/404-terminal bookkeeping of the exact fetch. While
 /// `loadingSeqs` contains the newest seq the card/sheet show a loading state
 /// instead of the meta.diffs fallback numbers.
    @Published private(set) var fileChangeFetch = FileChangesFetchState()
 /// Seqs the Host really released (404 only). Computed view of the fetch state.
    var fileChangeUnavailableSeqs: Set<Int> { fileChangeFetch.terminalSeqs }

    private(set) var journal = SessionJournal()
 /// M2b-2: the detail was first painted from the on-disk window cache. The live
 /// `session/follow` snapshot replaces it (sequence de-duplication in
 /// `SessionJournal`); the detail banner clears as soon as that snapshot lands.
    @Published private(set) var isShowingCachedWindow = false
 /// M2b-2: the restored window is older than the 24h display TTL (still shown).
    @Published private(set) var cachedWindowIsStale = false

 // MARK: - Automatic full-history load (view contract)

 /// Increments after each merged history batch. The detail view re-anchors the
 /// scroll position when it changes (bottom-follow or visible-row anchor).
    @Published private(set) var historyBatchToken: Int = 0
 /// Cached render groups (folded process groups), rebuilt together with the rows.
 /// The view body reads this directly and never recomputes O(rows) per render.
    @Published private(set) var flowGroups: [FlowRowGroup] = []
 /// E2E-only filler diagnostics (e2e-history-fill). The product path leaves it nil.
    @Published private(set) var historyFillProbeValue: String?

 /// Internal filler state; there is deliberately no UI for it (user: 无痕).
    enum HistoryFillState: String {
        case idle
        case loading
        case completed
        case failed
        case pausedOffline
    }
    private(set) var historyFillState: HistoryFillState = .idle
    private var historyFillTask: Task<Void, Never>?
    private var historyFillStartedAt: Date?
    private var historyFillCompletedAt: Date?
    private var historyFillPages = 0
    private var historyFillBytes = 0
    private var historyFillFailures = 0
 /// Consecutive *transient* (link/transport) page failures. Reset on any progress;
 /// bounded by `historyFillTransientRetryLimit` so a flaky 5G/relay burst keeps
 /// retrying (unconditional full history) without spinning forever.
    private var historyFillTransientRetries = 0
 /// ~30 retries with 1/2/4s capped backoff ≈ 2 minutes of tolerated link trouble.
 /// A real-device 10× run once hit 6 consecutive transient failures (~30s) and the
 /// old code marked the fill terminally `failed` with `hasMore=1` — the session
 /// never reached its first event until reopened.
    private static let historyFillTransientRetryLimit = 30

 // MARK: - DEBUG-only 自动化取证钩子（生产 env 不设置 → 零行为）
 //
 // `DSHM_FILL_PACE_MS`：把补齐每页之间的间隔拉长，好让自动化真机场景能跨多个
 // 插入批次持续滚动（只改节奏，不改数据/布局/发布语义）。
    private static let jitterFillPaceSeconds: Double = {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["DSHM_FILL_PACE_MS"],
              let ms = Double(raw), ms > 0 else { return 0 }
        return ms / 1000.0
        #else
        return 0
        #endif
    }()

 /// A history/older batch was merged but its rows rebuild has not run yet: the
 /// view anchors on historyBatchToken, so the token must change *after* the rows
 /// are on screen.
    private var pendingHistoryBatch = false
 /// True between start() and stop(): the filler only runs while the detail lives.
    private var detailOnScreen = false

 /// Oldest loaded log position (diagnostics/tests only: the view has no entry).
    var oldestLoadedSeq: Int? { journal.oldestSeq }
 /// The session's first event is loaded (filler terminal state).
    var reachedFirstEvent: Bool { journal.hasReachedOldest }

 /// M2b-2: first-paint cache read+apply cost (ms).
    private(set) var cacheLoadMilliseconds: Double = 0
    private let windowCache: SessionWindowCacheStore
 /// Phone-sized first session/follow window (12-20 messages).
    private(set) var firstWindowMessages: Int
    private var cacheSaveTask: Task<Void, Never>?
    private var firstPaintCacheTask: Task<Void, Never>?
    private var cachedChunksTask: Task<Void, Never>?
    private(set) var didRestoreFirstPaintCache = false
 /// Compatibility alias for older tests/E2E (same value).
    var didRestoreWindowFromCache: Bool { didRestoreFirstPaintCache }
 /// 打开阶段的锚底信号：缓存窗口先上屏、live 快照后到；视图在它为 true 之前
 /// 必须无条件贴底（冷启动/通知深链进入时"停在旧消息"的根因）。
    @Published private(set) var hasLiveSnapshot = false

 // MARK: - Detail state / seams (unchanged by the autoload refactor)

 /// E2E-gated in-app detail timing (detail-metrics hidden element).
    @Published private(set) var detailMetricsValue: String?
 /// E2E in-app send clock (send-metrics hidden element).
    @Published private(set) var sendMetricsValue: String?
    private var detailViewVisible = false
    private var detailFirstFrameMarked = false
    private var requestedFileChangeSeqs: Set<Int> = []
 /// task-2: retry timers and stale-completion guards per changes seq.
    private var fileChangeRetryTasks: [Int: Task<Void, Never>] = [:]
    private var fileChangeFetchTokens: [Int: Int] = [:]
    private var fileChangeFetchTokenValue = 0
 /// task-2: lifecycle reset triggers (network path / foreground / reconnect).
    private var lastFileChangeNetworkGeneration = NetworkPathMonitor.shared.changeGeneration
    private var lastFileChangeLinkConnected = false
    #if canImport(UIKit)
    private var fileChangeForegroundObserver: NSObjectProtocol?
    #endif
    private weak var link: LinkService?
 /// M5 test seams (unit tests have no socket).
    var permissionCatalogLoader: (() async throws -> PermissionPresetCatalog)?
    var permissionSwitcher: ((String) async throws -> SessionPermissionUpdate)?
    private var permissionCatalogLoaded = false
 /// v0.2.0 model-selection test seams.
    var modelCatalogLoader: (() async throws -> ModelCatalog)?
    var modelSelector: ((ModelSelection) async throws -> ModelSelection)?
    private var modelCatalogLoaded = false
    private var modelCatalogUnknownSelection: ModelSelection?
    private var stream: RemoteStreamHandle?
    private var restartTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var pendingEchoStaleTask: Task<Void, Never>?
    private var liveTextThrottleTask: Task<Void, Never>?
    private var observedGeneration = -1
 /// P0: `openStream()` ran while the link was down; the phase sink (and the
 /// view's `.onChange` fallback) re-opens it once the link is ready. A silent
 /// dsh-m/2 resume deliberately does not bump `generation`, so generation
 /// alone cannot recover this.
    private var streamOpenDeferred = false
 /// Bounded wait for a deferred open: after this the UI shows a retryable
 /// error instead of an unbounded spinner.
    private var deferredStreamOpenDeadlineTask: Task<Void, Never>?
 /// Budget for the deferred open (P0 detail-spinner fix: ≤10 s, then retry UI).
    static let deferredStreamOpenTimeout: TimeInterval = 10
    private var pendingRebuild = false
 /// Incremental render state (B's FlowState): auto-detects append/prepend/reset
 /// from the journal window so a running turn does not rebuild all rows.
    private var renderState = SessionRowBuilder.FlowState()
    private var lastKnownRunning = false
    private var subagentDebounceTask: Task<Void, Never>?
    private var lastSubagentCatalogIds: [String] = []
    private var projectionUserQuestions: [UserQuestionCall] = []
    private var liveUserQuestionWaterfalls: [UserQuestionWaterfall] = []
    private var pendingUserQuestionsCancellable: AnyCancellable?
    private var phaseCancellable: AnyCancellable?
    private var locallyAnsweredCallIds: Set<String> = []
    private var userQuestionSubmitGate = UserQuestionSubmitGate()
    private var dismissedLiveWaterfallEventIds: Set<String> = []

 /// Display text for the v5.5 status-strip context cell.
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
 // Phone-sized first window; the full history is filled automatically in the
 // background (the manual "load earlier" feature is gone).
        self.firstWindowMessages = SessionWindowPolicy.deviceFirstWindowMessages
        DetailMetrics.setFirstWindow(self.firstWindowMessages)
 // The first-paint cache is read/decoded off-main after init: the route switch
 // and the first render must never wait for disk IO / JSON decoding (user bug:
 // tapping a session froze ~1s before the detail appeared). The cached chunks
 // are applied when they arrive; the live follow snapshot supersedes the tail.
        startFirstPaintCacheRestore()
    }

 /// Plain-session shorthand (APNs deep links know only the session id).
    convenience init(sessionId: String) {
        self.init(address: .session(sessionId: sessionId))
    }

 // MARK: - 会话流排障日志（DSHM_DEBUG_STREAM=1 时才有输出）

    private static let debugStreamLogging =
        ProcessInfo.processInfo.environment["DSHM_DEBUG_STREAM"] == "1"

    private func dbg(_ message: @autoclosure () -> String) {
        guard Self.debugStreamLogging else { return }
        NSLog("[STREAMDBG] %@", message())
    }

 /// 真机闪回取证的轻量日志（仅 `DSHM_SCROLLDBG=1`；不做编码/无额外 UI 影响）。
    private static let scrollDbgLogging =
        ProcessInfo.processInfo.environment["DSHM_SCROLLDBG"] == "1"

    private func scrollDbg(_ message: @autoclosure () -> String) {
        guard Self.scrollDbgLogging else { return }
        NSLog("[SCROLLDBG] %@", message())
    }

 // MARK: - First-paint cache (newest up-to-4 screens, chunked)

 /// Kicks off the off-main cache read. Called from init: it must never block the
 /// first render, so the disk read + JSON decode + synthetic snapshot build all
 /// happen away from the main thread.
    private func startFirstPaintCacheRestore() {
        guard firstPaintCacheTask == nil else { return }
        let store = windowCache
        let targetSessionId = sessionId
        firstPaintCacheTask = Task { [weak self] in
            let started = Date()
            let loaded = await Task.detached(priority: .userInitiated) {
                store.load(sessionId: targetSessionId)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.cacheLoadMilliseconds = Date().timeIntervalSince(started) * 1000
            guard let loaded else {
                self.dbg("first-paint cache miss")
                return
            }
            self.applyFirstPaintCache(loaded)
        }
    }

 /// Test seam: wait for the off-main first-paint cache restore (hit or miss).
    func awaitFirstPaintCacheForTesting() async {
        await firstPaintCacheTask?.value
    }

    private func applyFirstPaintCache(_ loaded: SessionWindowCacheStore.Loaded) {
        let payload = loaded.payload
        guard !payload.chunks.isEmpty else { return }
        didRestoreFirstPaintCache = true
 // fix(autoload): the cache read/decode runs off-main, so on a hot
 // cache + fast link the live `session/follow` snapshot can land *before* this
 // restore finishes. The snapshot frame clears `isShowingCachedWindow`
 // (see `applyJournalUpdate`), so setting it here afterwards would re-arm the
 // 「显示本地缓存，正在同步…」banner/spinner with no further snapshot to clear it
 // (real-device manual repro: still visible after 65s on an idle session).
 // Only advertise the cached window when no live snapshot has been applied.
        if !hasLiveSnapshot {
            isShowingCachedWindow = true
            cachedWindowIsStale = loaded.isStale
        }
        DetailMetrics.setCacheHit(true)
        DetailMetrics.markCacheRestored(milliseconds: cacheLoadMilliseconds)
        #if DEBUG
        PerfProbe.shared.measure("cacheRestoreApply", ["chunks": payload.chunks.count]) {
            if journal.events.isEmpty {
                applyCachedSyntheticSnapshot(payload)
            } else {
                mergeCachedOlderEvents(payload: payload, olderThan: journal.oldestSeq ?? Int.max)
            }
        }
        #else
        if journal.events.isEmpty {
            applyCachedSyntheticSnapshot(payload)
        } else {
            mergeCachedOlderEvents(payload: payload, olderThan: journal.oldestSeq ?? Int.max)
        }
        #endif
        isLoading = false
        syncFillDiagnostics()
        rebuildRows()
        maybeMarkDetailFirstFrame()
 // 真机闪回修复：只应用 chunk0（最新一屏，用于首帧秒开）。
 // 其余缓存屏不再逐块 prepend 进可见列表——每块都会重建 rows 并触发一次滚底，
 // 真机上表现为「内容出现后 1–2 秒内整页快速闪两次 + 视口上跳再回底」
 // （热缓存每次打开必现，与会话大小无关）。更早的历史交给后台补齐引擎
 // （HistoryFiller）从 Host 拉，用户看到的内容一致，但不再有中途插入抖动。
        startHistoryFillIfPossible()
    }

 /// Applies the newest cached screen as a synthetic snapshot: header/projections
 /// plus that screen's records. The live follow snapshot replaces the tail later
 /// and the journal keeps the (contiguous) cached prefix.
    private func applyCachedSyntheticSnapshot(_ payload: SessionWindowCachePayload) {
        guard let chunk0 = payload.chunks.first, !chunk0.isEmpty else { return }
        let records = chunk0.map { SnapshotRecord(type: "event", event: $0, seq: $0.seq) }
        let header = payload.header ?? SessionHeader(
            version: nil, id: sessionId, createdAt: nil, cwd: nil, isSeeded: nil, agentPreset: nil
        )
        let snapshot = SessionSnapshot(
            type: "snapshot",
            header: header,
            cursor: payload.cursor,
            records: records,
            hasMore: payload.hasMore ?? true,
            projections: payload.projections,
            assistantStream: nil
        )
        let update = journal.apply(snapshot: snapshot)
        applyJournalUpdate(update)
        contextPressure = journal.contextPressure
    }

 /// Merges the cached screens older than the current window front (contiguous
 /// suffix only) when the live snapshot beat the cache restore.
    private func mergeCachedOlderEvents(payload: SessionWindowCachePayload, olderThan: Int) {
        var older = payload.chunks.flatMap { $0 }.filter { $0.seq < olderThan }
        older.sort { $0.seq < $1.seq }
        guard let front = journal.oldestSeq, !older.isEmpty else { return }
        var kept: [SessionEvent] = []
        var expected = front - 1
        for event in older.reversed() {
            guard event.seq == expected else { break }
            kept.append(event)
            expected -= 1
        }
        guard !kept.isEmpty else { return }
        let update = journal.prepend(events: Array(kept.reversed()), hasMoreOlder: true)
        applyJournalUpdate(update)
    }

 /// Test seam: apply one raw session/follow item value (snapshot/event/...).
 /// 测试 seam：**同步**应用一帧。生产路径走后台解码流水线（handleItem），
 /// 但单测需要在一次调用内看到效果，因此这里保持同步解码 + 同步处理。
    func applyStreamValue(_ value: JSONValue?) {
        guard let value else { return }
        lastEventAt = Date()
        do {
            processFrame(try SessionStreamFrame.decode(value))
        } catch {
            let detail = FrameDecodeFailure.describe(error, frame: value)
            dbg("frame decode failed: " + detail)
            streamErrorText = "帧解析失败: " + detail
        }
    }

 /// Test seam: sequence numbers currently in the journal window.
    var eventSeqs: [Int] { journal.events.map(\.seq) }

 /// Debounced window write so a running turn does not write on every frame.
    private func scheduleCacheSave() {
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.cacheSaveTask = nil
            self.saveWindowCacheNow()
        }
    }

 /// Persists the newest up-to-4 screens (chunked first-paint cache). Only after a
 /// live snapshot: a cache restored without a network round-trip must keep its
 /// original savedAt (it may be stale).
    func saveWindowCacheNow() {
        guard hasLiveSnapshot, !journal.events.isEmpty else { return }
        let projections = ProjectionValues(
            asOfSeq: journal.projectionsAsOfSeq,
            values: journal.projections
        )
        #if DEBUG
        PerfProbe.shared.measure("cacheSave", [
            "events": journal.events.count,
            "cursor": journal.cursor,
        ]) {
            writeWindowCache(projections: projections)
        }
        #else
        writeWindowCache(projections: projections)
        #endif
    }

    private func writeWindowCache(projections: ProjectionValues) {
        windowCache.saveAsync(
            sessionId: sessionId,
            cursor: journal.cursor,
            hasMore: journal.hasMore,
            header: journal.header,
            projections: projections,
            events: journal.events,
            windowMessages: firstWindowMessages
        )
    }

 // MARK: - M2b-2c detail in-app timing

 /// Called from the detail view's onAppear: marks the shell frame (header /
 /// composer / message skeleton on screen, content not required yet).
    func markDetailShellFrame() {
        DetailMetrics.markShellFrame()
        publishDetailMetricsValue()
    }

 /// Called from the detail view when the first message content is painted.
    func markDetailFirstContent() {
        DetailMetrics.markFirstContent()
        detailFirstFrameMarked = true
        publishDetailMetricsValue()
    }

 /// Publishes the legacy detail metrics plus the autoload key group
 /// (tapMs / shellMs / contentMs / fillMs / fillPages / fillOldest).
    private func publishDetailMetricsValue() {
        guard let base = DetailMetrics.valueString else {
            detailMetricsValue = nil
            return
        }
        if let extra = DetailMetrics.autoloadValueString {
            detailMetricsValue = base + ";" + extra
        } else {
            detailMetricsValue = base
        }
    }

 /// Called from the detail view's onAppear: marks the detail's first content once
 /// the header title and/or the first message rows are available. Idempotent.
    func markDetailViewAppeared() {
        detailViewVisible = true
        maybeMarkDetailFirstFrame()
    }

    private func maybeMarkDetailFirstFrame() {
        guard detailViewVisible, !detailFirstFrameMarked else { return }
        guard title != nil || !rows.isEmpty else { return }
        detailFirstFrameMarked = true
        DetailMetrics.markFirstContent()
        publishDetailMetricsValue()
    }

    private func markDetailNetworkApplied() {
        DetailMetrics.markNetworkApplied()
        publishDetailMetricsValue()
    }

 /// Called from SessionDetailView once the running/turn indicator is on screen
 /// after a send (E2E in-app metric; no product behavior).
    func markSendTurnVisible() {
        SendMetrics.markTurnVisible()
        sendMetricsValue = SendMetrics.valueString
    }

 // MARK: - Lifecycle

    func attach(link: LinkService) {
        self.link = link
 // G1 (task-6): merge live $events user-question waterfalls into the published
 // cards — on current builds the projection is always empty.
        pendingUserQuestionsCancellable = link.$pendingUserQuestions
            .receive(on: RunLoop.main)
            .sink { [weak self] waterfalls in
                self?.applyPendingUserQuestionWaterfalls(waterfalls)
            }
 // Prompts typed while the transport is reconnecting are queued locally and
 // flushed on reconnect; the automatic history filler pauses/resumes with the
 // link phase as well.
        phaseCancellable = link.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
 // P0 detail-open fallback: a stream deferred while the link was
 // down must be opened the moment the link is ready. Doing it on
 // `phase` (not only `generation`) also covers silent dsh-m/2
 // resumes, which keep the generation on purpose.
                self.handleLinkPhaseChange(phase)
                if phase.isConnected {
                    self.maybeFlushQueued()
                    self.resumeHistoryFillAfterReconnect()
                } else {
                    self.pauseHistoryFillForOffline()
                }
            }
    }

    func start() {
        guard let link else { return }
        observedGeneration = link.generation
 // task-2: (re)entering the detail re-arms the exact file-change fetch; a
 // 404/transient failure from a previous visit must not pin the fallback.
        lastFileChangeLinkConnected = link.phase.isConnected
        lastFileChangeNetworkGeneration = NetworkPathMonitor.shared.changeGeneration
        installFileChangeForegroundObserver()
        resetFileChangesExactFetch(reason: "detail-open")
 // Restore the live half immediately: the Combine sink only re-fires on
 // changes, and a stop()/start() cycle clears the local cache.
        applyPendingUserQuestionWaterfalls(link.pendingUserQuestionWaterfalls(forSession: sessionId))
        detailOnScreen = true
        openStream()
        startHistoryFillIfPossible()
    }

    func stop() {
        detailOnScreen = false
        restartTask?.cancel()
        rebuildTask?.cancel()
        subagentDebounceTask?.cancel()
        historyFillTask?.cancel()
        historyFillTask = nil
        cachedChunksTask?.cancel()
        cachedChunksTask = nil
        firstPaintCacheTask?.cancel()
        firstPaintCacheTask = nil
        pendingHistoryBatch = false
 // P0: leaving the screen retires the deferred-open wait; a late phase flip
 // must not open a stream for a detail that is gone.
        clearDeferredStreamOpen()
        liveTextThrottleTask?.cancel()
        liveTextThrottleTask = nil
        stream?.cancel()
        stream = nil
 // Flush a pending debounced window write before leaving the screen.
        cacheSaveTask?.cancel()
        cacheSaveTask = nil
        saveWindowCacheNow()
        liveUserQuestionWaterfalls = []
        rebuildActiveUserQuestions()
 // task-2: no background retries for a detail that is gone; the next
 // start() resets the bookkeeping and re-fetches.
        cancelFileChangeFetchTasks()
        removeFileChangeForegroundObserver()
    }

 /// Called when the link generation changed (reconnect): rebuild from snapshot.
    func handleGenerationChange(_ generation: Int) {
        guard generation != observedGeneration else { return }
        observedGeneration = generation
        if generation > 0 {
            reopenStream()
        }
        maybeFlushQueued()
        resetFileChangesExactFetch(reason: "generation-change")
    }

    private func reopenStream() {
        restartTask?.cancel()
        historyFillTask?.cancel()
        historyFillTask = nil
 // Allow the filler to restart for the new window: the in-flight page keyed
 // on the old front is cancelled, and the next snapshot/front will re-arm it.
        historyFillState = .idle
        pendingHistoryBatch = false
 // An explicit reopen supersedes any pending deferred open; `openStream()`
 // re-arms the wait when the link is still down.
        clearDeferredStreamOpen()
        stream?.cancel()
        stream = nil
        openStream()
    }

    func retry() {
        streamErrorText = nil
        reopenStream()
    }

 /// M4 §4: a background (silent) push asked for fresh data while this detail is
 /// open. Reopens session/follow so the snapshot replaces the cached rows.
    func refreshFromSilentPush() {
        guard let link, link.phase.isConnected else { return }
        reopenStream()
    }

    private func openStream() {
        guard let link else { return }
        guard link.phase.isConnected else {
            dbg("openStream deferred: phase=" + String(describing: link.phase) + " busy=" + String(link.phase.isBusy) + " sections=" + String(rows.count))
 // P0: never drop the open silently — arm a phase-driven retry plus a
 // bounded deadline (see DeferredStreamOpenPolicy).
            armDeferredStreamOpen()
            isLoading = rows.isEmpty
            streamErrorText = link.phase.isBusy ? nil : "连接未就绪"
            return
        }
        let messages = firstWindowMessages
        isLoading = rows.isEmpty
        do {
            let turnWindow = SessionWindowPolicy.firstWindowTurnWindow(messages: messages)
            let args: [String: JSONValue] = [
                "request": .object([
                    "address": address.jsonValue,
                    "assistantStream": .bool(true),
                    "maxMessages": .int(Int64(messages)),
                    "turnWindow": turnWindow.jsonValue,
                ]),
            ]
            dbg("session/follow send: messages=" + String(messages) + " sections=" + String(rows.count) + " cache=" + String(didRestoreFirstPaintCache) + " hasLive=" + String(hasLiveSnapshot))
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
 // P0: the open succeeded; retire any pending deferred-open wait.
            clearDeferredStreamOpen()
        } catch {
            clearDeferredStreamOpen()
            streamErrorText = NetworkErrorInterpreter.message(for: error)
            isLoading = false
        }
    }

 // MARK: - P0: deferred stream open (detail spinner)

 /// Phase observer shared by the Combine sink (`attach`) and the view's
 /// `.onChange(of: app.link.phase)` fallback. Idempotent by construction:
 /// opening a second stream would replace the live handle and drop frames.
    func handleLinkPhaseChange(_ phase: LinkService.Phase) {
 // task-2: a reconnect (phase flips back to connected) re-arms the exact
 // file-change fetch; the fallback must not survive a transport recovery.
        if phase.isConnected, !lastFileChangeLinkConnected {
            resetFileChangesExactFetch(reason: "reconnect")
        }
        lastFileChangeLinkConnected = phase.isConnected
        switch DeferredStreamOpenPolicy.action(
            phaseIsConnected: phase.isConnected,
            isDeferred: streamOpenDeferred,
            hasOpenStream: stream != nil,
            deadlineElapsed: false
        ) {
        case .open:
            dbg("deferred open resumed: phase=" + String(describing: phase) + " sections=" + String(rows.count))
            openStream()
        case .idle, .wait, .fail:
            break
        }
    }

    private func armDeferredStreamOpen() {
        streamOpenDeferred = true
        guard deferredStreamOpenDeadlineTask == nil else { return }
        deferredStreamOpenDeadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.deferredStreamOpenTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.handleDeferredOpenDeadline()
        }
    }

 /// Deadline for the deferred open: a link that came up meanwhile still opens
 /// (and retires the wait); one that did not surfaces a retryable error so the
 /// detail never sits on an unbounded spinner.
    private func handleDeferredOpenDeadline() {
 // This task is the one currently armed: clear the handle so a re-armed
 // wait (link came up but the open attempt itself failed transiently) can
 // schedule a fresh deadline instead of believing one is still pending.
        deferredStreamOpenDeadlineTask = nil
        if let link, link.phase.isConnected {
            handleLinkPhaseChange(link.phase)
            return
        }
        guard DeferredStreamOpenPolicy.action(
            phaseIsConnected: false,
            isDeferred: streamOpenDeferred,
            hasOpenStream: stream != nil,
            deadlineElapsed: true
        ) == .fail else { return }
        clearDeferredStreamOpen()
        isLoading = false
        streamErrorText = "连接未就绪（已等待 " + String(Int(Self.deferredStreamOpenTimeout)) + " 秒）"
        dbg("deferred open timed out; surfacing retry entry")
    }

    private func clearDeferredStreamOpen() {
        streamOpenDeferred = false
        deferredStreamOpenDeadlineTask?.cancel()
        deferredStreamOpenDeadlineTask = nil
    }

 // MARK: - Automatic full-history filler (no UI)

 /// Test seam (unit tests have no socket): replaces the session/page unary.
    var historyPageLoader: (([String: JSONValue]) async throws -> JSONValue)?

 /// session/page wire request (same key names the old manual pager used).
    nonisolated static func historyPageRequestArgs(
        address: SessionFollowAddress,
        throughSeq: Int,
        beforeSeq: Int,
        maxMessages: Int
    ) -> [String: JSONValue] {
        [
            "request": .object([
                "address": address.jsonValue,
                "throughSeq": .int(Int64(throughSeq)),
                "beforeSeq": .int(Int64(beforeSeq)),
                "maxMessages": .int(Int64(maxMessages)),
            ]),
        ]
    }

    private var historyPageMessages: Int {
        #if DEBUG
 // 自动化真机取证：允许把页调小，让补齐插入分成更多批次（只影响测试节奏）。
        if let raw = ProcessInfo.processInfo.environment["DSHM_FILL_PAGE_MESSAGES"],
           let value = Int(raw), value > 0 {
            return value
        }
        #endif
        return SessionWindowPolicy.historyPageMessages(isRelay: NetworkPathMonitor.shared.prefersRelay)
    }

 /// Starts the automatic fill when the prerequisites are met. Safe to call from
 /// every trigger (start / cache restore / snapshot / reconnect): idempotent.
    func startHistoryFillIfPossible() {
        guard detailOnScreen, historyFillTask == nil else { return }
        guard historyFillState != .completed, historyFillState != .failed else { return }
        guard journal.cursor >= 0, journal.oldestSeq != nil, !journal.events.isEmpty else { return }
        if !journal.hasMoreOlder {
            markHistoryFillCompleted()
            return
        }
        guard historyPageLoader != nil || (link?.phase.isConnected ?? false) else {
            pauseHistoryFillForOffline()
            return
        }
        if historyFillStartedAt == nil { historyFillStartedAt = Date() }
        historyFillState = .loading
        syncFillDiagnostics()
        historyFillTask = Task { [weak self] in
            await self?.runHistoryFillLoop()
        }
    }

    private enum HistoryPageOutcome {
        case progress
        case terminal
        case retryStalePage
 /// Transport/link failure: retry with capped backoff instead of failing the
 /// whole fill (the requirement is unconditional full history).
        case retryTransient
        case failed
        case cancelled
    }

 /// Pulls pages backwards until the session's first event is loaded. Silent: no
 /// spinner, no error banner; offline pauses and reconnects resume automatically.
    private func runHistoryFillLoop() async {
        defer { historyFillTask = nil }
        var retriedStalePage = false
        while !Task.isCancelled {
            guard detailOnScreen else { return }
            guard journal.hasMoreOlder else {
                markHistoryFillCompleted()
                return
            }
            guard journal.cursor >= 0, let oldest = journal.oldestSeq else {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            guard historyPageLoader != nil || (link?.phase.isConnected ?? false) else {
                pauseHistoryFillForOffline()
                return
            }
            let outcome = await fetchHistoryPage(beforeSeq: oldest)
            switch outcome {
            case .progress:
                retriedStalePage = false
                historyFillFailures = 0
                historyFillTransientRetries = 0
 // v0.2.6 滚动修复：逐批发布（不再延迟）。视口稳定性由视图侧的
 // scrollPosition(id:anchor:) 锚定保证，插入本身不改变可见内容。
                rebuildNowForHistoryBatch()
                syncFillDiagnostics()
 // 卡顿修复：补齐期间不再逐批写窗口缓存。
 // 单次写盘要编码 ~4MB JSON（实测每批 ~59ms），即便挪到后台也会和滑动抢 CPU；
 // 最终状态由 markHistoryFillCompleted() 统一写，中途被杀最多重拉一次历史。
 // DEBUG 取证：拉长页间隔，让自动化场景跨越多个插入批次（生产 0）。
                if Self.jitterFillPaceSeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(Self.jitterFillPaceSeconds * 1_000_000_000))
                }
            case .terminal:
                markHistoryFillCompleted()
                return
            case .retryStalePage:
                if retriedStalePage {
                    historyFillFailures += 1
                    await sleepToBackoffIfNeeded()
                } else {
                    retriedStalePage = true
                }
            case .retryTransient:
 // Offline: park the fill and let the reconnect path resume it.
                guard historyPageLoader != nil || (link?.phase.isConnected ?? false) else {
                    pauseHistoryFillForOffline()
                    return
                }
                historyFillTransientRetries += 1
                if historyFillTransientRetries > Self.historyFillTransientRetryLimit {
                    historyFillState = .failed
                    syncFillDiagnostics()
                    return
                }
                await sleepTransientBackoff()
            case .failed:
                historyFillFailures += 1
                if historyFillFailures > 5 {
                    historyFillState = .failed
                    syncFillDiagnostics()
                    return
                }
                await sleepToBackoffIfNeeded()
            case .cancelled:
                return
            }
        }
    }

    private func sleepToBackoffIfNeeded() async {
        let exponent = max(0, min(historyFillFailures - 1, 3))
        let seconds = pow(2.0, Double(exponent))
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

 /// Backoff for transient transport failures: 1s, 2s, then 4s cap (never 8s):
 /// a 5G/relay hiccup should recover quickly instead of freezing the fill for
 /// long stretches; the retry budget bounds the total.
    private func sleepTransientBackoff() async {
        let exponent = max(0, min(historyFillTransientRetries - 1, 2))
        let seconds = min(pow(2.0, Double(exponent)), 4.0)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func fetchHistoryPage(beforeSeq: Int) async -> HistoryPageOutcome {
        let args = Self.historyPageRequestArgs(
            address: address,
            throughSeq: journal.cursor,
            beforeSeq: beforeSeq,
            maxMessages: historyPageMessages
        )
        #if DEBUG
        let fetchStart = CACurrentMediaTime()
        #endif
        let value: JSONValue
        do {
            if let historyPageLoader {
                value = try await historyPageLoader(args)
            } else if let link {
                value = try await link.unary("session/page", args: args)
            } else {
                return .failed
            }
        } catch {
            if Task.isCancelled { return .cancelled }
            dbg("history page fetch failed: " + NetworkErrorInterpreter.message(for: error))
 // Real link failures are transient (5G/relay hiccups); retrying with a
 // bounded budget is what makes "unconditional full history" hold. The
 // test-only loader keeps the old semantics (count as terminal failure)
 // so the filler unit tests can still drive the failure path deterministically.
            return historyPageLoader == nil ? .retryTransient : .failed
        }
        if Task.isCancelled { return .cancelled }
        #if DEBUG
        PerfProbe.shared.record("pageNetwork", ms: (CACurrentMediaTime() - fetchStart) * 1000)
        #endif
        let page: SessionPage
        do {
 // A payload/contract break is deterministic: retrying would spin forever.
 // 卡顿修复：JSONValue.decode 内部是
 // JSONEncoder(JSONValue) + JSONDecoder(目标类型) 的双重转换，多 MB 历史页
 // 在 main actor 上做是数百毫秒级卡死（用户实测每批 ~0.5s）。改到后台队列。
            page = try await Self.decodeOffMain(value, SessionPage.self, name: "pageDecodeBG")
        } catch {
            dbg("history page decode failed: " + String(describing: error))
            return .failed
        }
        let oldestBefore = journal.oldestSeq
        #if DEBUG
        let prependStart = CACurrentMediaTime()
        let update = journal.prepend(page: page)
        PerfProbe.shared.record("pagePrepend", ms: (CACurrentMediaTime() - prependStart) * 1000)
        let applyStart2 = CACurrentMediaTime()
        applyJournalUpdate(update)
        PerfProbe.shared.record("pageApplyJournal", ms: (CACurrentMediaTime() - applyStart2) * 1000)
        #else
        let update = journal.prepend(page: page)
        applyJournalUpdate(update)
        #endif
        let oldestAfter = journal.oldestSeq
        let merged: Bool = {
            guard let before = oldestBefore, let after = oldestAfter else { return false }
            return after < before
        }()
 // Count the page even when it is also the terminal one (a short session
 // that fits in one page used to report pages=0).
        if merged {
            historyFillPages += 1
            if Self.e2eFillDiagnosticsEnabled || Self.e2eFillDiagnosticsTestOverride {
                historyFillBytes += CacheIO.encode(value)?.count ?? 0
            }
        }
        if page.records.isEmpty || !journal.hasMoreOlder {
            return .terminal
        }
        guard merged else { return .retryStalePage }
        dbg("history page merged: pages=" + String(historyFillPages)
            + " oldest=" + String(journal.oldestSeq ?? -1)
            + " rows=" + String(rows.count))
        return .progress
    }

    private func markHistoryFillCompleted() {
        guard historyFillState != .completed else { return }
        historyFillState = .completed
        historyFillCompletedAt = Date()
        if let started = historyFillStartedAt {
            let milliseconds = Date().timeIntervalSince(started) * 1000
            DetailMetrics.markHistoryFillCompleted(
                milliseconds: milliseconds,
                pages: historyFillPages,
                oldestSeq: journal.oldestSeq ?? -1
            )
        }
        historyFillTask?.cancel()
        historyFillTask = nil
        syncFillDiagnostics()
        saveWindowCacheNow()
        publishDetailMetricsValue()
    }

    private func pauseHistoryFillForOffline() {
 // From idle too: a cold open while offline must show pausedOffline so the
 // reconnect resumes it (a plain idle would look like "nothing to load").
        guard historyFillState == .loading || historyFillState == .idle else { return }
        historyFillTask?.cancel()
        historyFillTask = nil
        historyFillState = .pausedOffline
        syncFillDiagnostics()
    }

    private func resumeHistoryFillAfterReconnect() {
        guard historyFillState == .pausedOffline || historyFillState == .failed else { return }
        historyFillState = .idle
        startHistoryFillIfPossible()
    }

    private static let e2eFillDiagnosticsEnabled =
        ProcessInfo.processInfo.environment["DSHM_E2E"] == "1"
        || ProcessInfo.processInfo.environment["DSHM_DEBUG_STREAM"] == "1"
 /// Unit-test seam: the simulator test runner has no E2E env.
    static var e2eFillDiagnosticsTestOverride = false

 /// E2E-only filler probe (e2e-history-fill hidden element).
    private func syncFillDiagnostics() {
        guard Self.e2eFillDiagnosticsEnabled || Self.e2eFillDiagnosticsTestOverride else { return }
        let elapsedMs: Int
        if let started = historyFillStartedAt {
            elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        } else {
            elapsedMs = -1
        }
        let holes = journal.isWindowContiguous ? 0 : 1
        historyFillProbeValue = "state=" + historyFillState.rawValue
            + ";pages=" + String(historyFillPages)
            + ";oldest=" + String(journal.oldestSeq ?? -1)
            + ";bytes=" + String(historyFillBytes)
            + ";ms=" + String(elapsedMs)
            + ";rows=" + String(rows.count)
            + ";holes=" + String(holes)
            + ";hasMore=" + (journal.hasMoreOlder ? "1" : "0")
            + ";failures=" + String(historyFillFailures)
            + ";retries=" + String(historyFillTransientRetries)
            + ";gen=" + String(link?.generation ?? -1)
    }

 /// Test seam: run the filler until it completes / fails / has nothing to do.
 /// Sets the on-screen gate so unit tests can drive the state machine without a
 /// real view/link.
    func runHistoryFillForTesting() async {
        detailOnScreen = true
        startHistoryFillIfPossible()
        await historyFillTask?.value
    }

 // MARK: - Frame handling

 /// 待解码的 stream frame（保证顺序：单飞 + FIFO）。
    private var pendingFrameValues: [JSONValue] = []
    private var frameDecodeInFlight = false

 /// JSONValue.decode 内部是「JSONValue → JSON 编码 → 目标类型解码」的双重转换，
 /// 大会话的 snapshot / 大 tool result 事件在 main actor 解码会造成数百毫秒卡顿。
 /// 这里把解码放到后台串行队列，按 FIFO 回主线程处理，顺序与原来一致。
    private func handleItem(_ value: JSONValue?) {
        guard let value else { return }
        lastEventAt = Date()
        pendingFrameValues.append(value)
        drainFrameDecodeIfNeeded()
    }

    private func drainFrameDecodeIfNeeded() {
        guard !frameDecodeInFlight, !pendingFrameValues.isEmpty else { return }
        let value = pendingFrameValues.removeFirst()
        frameDecodeInFlight = true
        let started = CACurrentMediaTime()
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<SessionStreamFrame, Error> = Result {
                try SessionStreamFrame.decode(value)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                #if DEBUG
                PerfProbe.shared.record("frameDecodeBG", ms: (CACurrentMediaTime() - started) * 1000)
                #endif
                self.frameDecodeInFlight = false
                switch result {
                case .success(let frame):
                    self.processFrame(frame)
                case .failure(let error):
 // Include the frame type and the failing coding path: the bare
 // Foundation text ("The data couldn't be read…") names nothing.
                    let detail = FrameDecodeFailure.describe(error, frame: value)
                    self.dbg("frame decode failed: " + detail)
                    self.streamErrorText = "帧解析失败: " + detail
                }
                self.drainFrameDecodeIfNeeded()
            }
        }
    }

 /// 把 JSONValue.decode（内部是 JSONValue→JSON 编码→目标类型解码 的双重转换）
 /// 挪到后台队列执行；主线程只做一次 await，不阻塞渲染。
    private nonisolated static func decodeOffMain<T: Decodable>(
        _ value: JSONValue,
        _ type: T.Type,
        name: String
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = CACurrentMediaTime()
                do {
                    let decoded = try value.decode(type)
                    #if DEBUG
                    PerfProbe.shared.record(name, ms: (CACurrentMediaTime() - started) * 1000)
                    #endif
                    continuation.resume(returning: decoded)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func processFrame(_ frame: SessionStreamFrame) {
        switch frame {
            case .snapshot(let snapshot):
                dbg("snapshot: records=" + String(snapshot.records.count) + " cursor=" + String(snapshot.cursor) + " hasMore=" + String(describing: snapshot.hasMore))
                #if DEBUG
                let update = PerfProbe.shared.measure("snapshotJournalApply", ["records": snapshot.records.count]) {
                    journal.apply(snapshot: snapshot)
                }
                PerfProbe.shared.measure("snapshotApplyJournalUpdate") {
                    applyJournalUpdate(update)
                }
                #else
                let update = journal.apply(snapshot: snapshot)
                applyJournalUpdate(update)
                #endif
 // v5.5 §14.5 first frame: seed the context window from the
 // snapshot projections (M1 gets no incremental projection pushes).
                contextPressure = journal.contextPressure
                isLoading = false
                streamErrorText = nil
                hasLiveSnapshot = true
                isShowingCachedWindow = false
                cachedWindowIsStale = false
                scheduleCacheSave()
 // M2b-2c: live snapshot network cost (detail in-app metric).
                markDetailNetworkApplied()
                if !detailFirstFrameMarked {
 // First content: paint without the 40ms rebuild debounce.
                    rebuildNowForHistoryBatch()
                }
 // User decision: entering the detail starts the full-history
 // fill immediately; no user gesture, no visible indicator.
                startHistoryFillIfPossible()
            case .event(let event):
                dbg("event: " + event.type + " seq=" + String(event.seq))
                let update = journal.apply(event: event)
                applyJournalUpdate(update)
 // Window cache: debounced write of the newest 4 screens (only events
 // the journal actually appended keep the payload contiguous).
                if case .eventsApplied = update {
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
    }

    private func applyJournalUpdate(_ update: SessionJournal.Update) {
 // task-2: a network-path change (Wi-Fi ⇄ cellular) invalidates the exact
 // fetch that failed on the old path; reset + refetch on the new one.
        checkFileChangeNetworkGeneration()
        switch update {
        case .snapshotReplaced:
            scrollDbg("journal snapshotReplaced")
            pendingRebuild = true
            scheduleRebuild()
        case .eventsApplied:
            scrollDbg("journal eventsApplied")
            pendingRebuild = true
            scheduleRebuild()
        case .olderPrepended(let seqs):
 // Front merge: the rows above the current position changed, the newest
 // end did not. An empty result (defensive) has nothing to re-render.
            scrollDbg("journal olderPrepended n=\(seqs.count) fillState=\(historyFillState.rawValue)")
            if seqs.isEmpty {
                publishLiveAssistantText()
            } else {
                pendingHistoryBatch = true
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

 /// Drops a pending debounced rebuild and rebuilds now. Used for the first
 /// content paint and for history batches (the view anchors on the token).
    private func rebuildNowForHistoryBatch() {
        rebuildTask?.cancel()
        rebuildTask = nil
        pendingRebuild = false
        #if DEBUG
        PerfProbe.shared.measure("rebuildHistoryBatch", [
            "events": journal.events.count,
        ]) {
            rebuildRows()
        }
        #else
        rebuildRows()
        #endif
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
        #if DEBUG
        PerfProbe.shared.measure("rebuildRows", ["events": journal.events.count]) {
            rebuildRowsImpl()
        }
        #else
        rebuildRowsImpl()
        #endif
    }

    private func rebuildRowsImpl() {
 // Optimistic echoes (round2 §3): retire the ones whose durable
 // `user/message` arrived (matched by `data.source.rpcId`), then paint
 // the rest at the tail of the flow. Sitting outside the journal means a
 // rebuild / pagination recompute never drops the user's own message.
        let echoCountBefore = pendingUserEchoes.count
        pendingUserEchoes.reconcile(events: journal.events)
        let retiredEchoes = echoCountBefore - pendingUserEchoes.count
        let events = journal.events
        let nowMs = Self.epochMilliseconds()
        var branch = "none"
 // Incremental render: the journal window only changes at the
 // tail (live events), at the front (history pages) or wholesale (snapshot /
 // reconnect reset). Auto-detect which one happened so a running session with
 // the full history loaded does not re-fold thousands of events per frame.
        if let range = renderState.loadedSeqRange,
           let first = events.first?.seq,
           let last = events.last?.seq {
            if first == range.lowerBound, last == range.upperBound {
 // Window unchanged (derived refresh only): keep the folded rows.
                branch = "unchanged"
            } else if first == range.lowerBound, last > range.upperBound {
                branch = "append"
                let appended = events.filter { $0.seq > range.upperBound }
                renderState.append(events: appended, pendingUserEchoes: pendingUserEchoes.echoes, nowMs: nowMs)
            } else if last == range.upperBound, first < range.lowerBound {
                branch = "prepend"
                let prepended = events.filter { $0.seq < range.lowerBound }
                renderState.prepend(events: prepended, pendingUserEchoes: pendingUserEchoes.echoes, nowMs: nowMs)
            } else {
                branch = "reset"
                renderState.reset(events: events, pendingUserEchoes: pendingUserEchoes.echoes, nowMs: nowMs)
            }
        } else {
            branch = "initial-reset"
            renderState.reset(events: events, pendingUserEchoes: pendingUserEchoes.echoes, nowMs: nowMs)
        }
        flow = renderState.flow
        flowGroups = renderState.groups
        scrollDbg("rebuild branch=\(branch) events=\(events.count) rows=\(flow.rows.count) oldest=\(journal.oldestSeq ?? -1) hasMore=\(journal.hasMoreOlder ? 1 : 0)")
        dbg("rebuild: events=" + String(events.count) + " rows=" + String(flow.rows.count) + " hasMoreOlder=" + String(journal.hasMoreOlder) + " oldest=" + String(journal.oldestSeq ?? -1) + " pendingEchoes=" + String(pendingUserEchoes.count) + (retiredEchoes > 0 ? " retired=" + String(retiredEchoes) : "") + (flow.isRunning ? " running" : " idle"))
        syncFillDiagnostics()
        title = journal.title
        permissionsValue = journal.permissionsValue
        todos = journal.todos
        planActive = journal.plan?["active"]?.boolValue ?? false
        let wasRunning = lastKnownRunning
        isRunning = flow.isRunning
        lastKnownRunning = isRunning
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
        requestFileChangeSummariesIfNeeded()
 // v5.4 queue: a finished turn automatically releases the oldest queued
 // prompt with mode=queue; the rest keep waiting for the next turn/end.
        if SessionQueuePolicy.shouldFlush(wasRunning: wasRunning, isRunning: isRunning, queuedCount: queuedPrompts.count) {
            flushNextQueuedPrompt()
        }
        if pendingHistoryBatch {
            pendingHistoryBatch = false
            historyBatchToken &+= 1
        }
        syncFillDiagnostics()
 // M2b-2c: if the detail is already on screen (cache or live snapshot), this
 // is the first visible content.
        maybeMarkDetailFirstFrame()
    }

 // MARK: - Session-list derived refresh (v5.4 task-13 / v5.5 §14.5)

 /// One `session/list` read that refreshes everything derived from the list:
 /// - v5.5 §14.5: the context window of **this** session (normal detail or
 /// subagent detail — a subagent child is listed under its own child id, so
 /// `sessionId` matches both);
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
 // Repaint only the optimistic tail rows through the incremental state so
 // flowGroups stays in sync with flow.rows (the view reads flowGroups).
        renderState.repaintPendingEchoes(
            pendingUserEchoes.echoes,
            nowMs: Self.epochMilliseconds()
        )
        flow = renderState.flow
        flowGroups = renderState.groups
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
 /// Host .
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
        SessionRowBuilder.findToolCall(in: rows, callId: callId)
    }

 // MARK: - File changes (exact-fetch §3.9, meta.diffs fallback)

 /// 最新一轮合并后的文件变更视图：Host 仍保留时用精确取数，否则退回
 /// 客户端 meta.diffs 聚合。turn UI 删除后只在流末尾保留「最近一轮」卡片。
 ///
 /// task-2: while the exact fetch is still loading (first try or backoff) the
 /// fallback numbers are NOT surfaced as truth — the card/sheet render a loading
 /// state instead (reported illusion: App 18 files +712 −42 vs desktop 50 files).
    var latestTurnFileChanges: TurnFileChanges? {
        if let seq = flow.latestFileChangeSeq, let summary = fileChangeSummaries[seq] {
            return TurnFileChanges(
                source: .exactFetch,
                files: summary.files,
                added: summary.added ?? summary.files.reduce(0) { $0 + ($1.added ?? 0) },
                deleted: summary.deleted ?? summary.files.reduce(0) { $0 + ($1.deleted ?? 0) },
                seq: seq,
                total: summary.total
            )
        }
        if let pendingSeq = flow.latestFileChangeSeq, isFileChangeFetchUnsettled(pendingSeq) {
            return TurnFileChanges(
                source: .metaDiffsFallback,
                files: [],
                added: 0,
                deleted: 0,
                seq: pendingSeq,
                isLoading: true
            )
        }
        guard let fallback = flow.latestFileChanges else { return nil }
        return TurnFileChanges(
            source: .metaDiffsFallback,
            files: fallback.files.map { ChangesSummaryValue.File(path: $0, display: ($0 as NSString).lastPathComponent, added: nil, deleted: nil) },
            added: fallback.additions,
            deleted: fallback.deletions,
            seq: flow.latestFileChangeSeq
        )
    }

 /// True while the newest turn's exact summary is in flight (card/sheet loading).
    var fileChangesExactFetchPending: Bool {
        guard let seq = flow.latestFileChangeSeq else { return false }
        return isFileChangeFetchUnsettled(seq)
    }

 /// No summary yet, not a terminal 404, and the fetch is in flight or about to be
 /// requested → show loading instead of the fallback numbers (avoids the flash of
 /// the aggregate口径 before the first request starts).
    private func isFileChangeFetchUnsettled(_ seq: Int) -> Bool {
        if fileChangeFetch.isLoading(seq) { return true }
        return !fileChangeFetch.isTerminal(seq) && !requestedFileChangeSeqs.contains(seq)
    }

 /// Requests the exact-fetch summary of the newest turn's workspace/changes
 /// event. Only a real 404 is terminal; everything else retries 1/2/4 s and is
 /// re-armed by every lifecycle reset (network / foreground / reconnect / reopen).
    private func requestFileChangeSummariesIfNeeded() {
        guard let seq = flow.latestFileChangeSeq else { return }
        guard fileChangeSummaries[seq] == nil else { return }
        guard !fileChangeFetch.isTerminal(seq) else { return }
        guard !requestedFileChangeSeqs.contains(seq) else { return }
        requestedFileChangeSeqs.insert(seq)
        ChangesDebugLog.log("request seq=\(seq) networkGen=\(NetworkPathMonitor.shared.changeGeneration) prefersRelay=\(NetworkPathMonitor.shared.prefersRelay ? 1 : 0) fallbackFiles=\(flow.latestFileChanges?.files.count ?? -1)")
        beginFileChangeSummaryFetch(seq: seq)
    }

 /// One attempt for `seq`; retries are scheduled by `scheduleFileChangeSummaryRetry`
 /// after `FileChangesFetchPolicy.decision`.
    private func beginFileChangeSummaryFetch(seq: Int) {
        guard let link else { return }
        fileChangeFetch.begin(seq: seq)
        let token = makeFileChangeFetchToken(seq: seq)
        let started = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await link.changesSummary(sessionId: self.sessionId, seq: seq)
                guard self.isCurrentFileChangeFetch(seq: seq, token: token), !Task.isCancelled else { return }
                self.fileChangeFetch.succeeded(seq: seq)
                self.fileChangeSummaries[seq] = summary
                let added = summary.added ?? summary.files.reduce(0) { $0 + ($1.added ?? 0) }
                let deleted = summary.deleted ?? summary.files.reduce(0) { $0 + ($1.deleted ?? 0) }
                ChangesDebugLog.log("summary ok seq=\(seq) files=\(summary.files.count) added=\(added) deleted=\(deleted) ms=\(Self.millisSince(started))")
            } catch {
                guard self.isCurrentFileChangeFetch(seq: seq, token: token), !Task.isCancelled else { return }
                let retriesMade = self.fileChangeFetch.retriesMade(seq)
                let kind = FileChangesFetchPolicy.failureKind(for: error)
                let outcome = self.fileChangeFetch.failed(seq: seq, error: error)
                let fallback = self.flow.latestFileChanges
                let origin = link.credentials?.originURL?.absoluteString ?? "-"
                ChangesDebugLog.log("summary fail seq=\(seq) retriesMade=\(retriesMade) kind=\(kind) outcome=\(outcome) status=\(LinkService.httpStatus(of: error).map(String.init) ?? "-") err=\(Self.describeChangesError(error)) origin=\(origin) relay=\(NetworkPathMonitor.shared.prefersRelay ? 1 : 0) ms=\(Self.millisSince(started)) fallbackFiles=\(fallback?.files.count ?? -1) fallbackAdded=\(fallback?.additions ?? -1) fallbackDeleted=\(fallback?.deletions ?? -1)")
                switch outcome {
                case .scheduledRetry(let delay):
                    self.scheduleFileChangeSummaryRetry(seq: seq, delay: delay, token: token)
                case .failedPermanently, .failedTransiently:
                    break
                }
            }
        }
    }

    private func scheduleFileChangeSummaryRetry(seq: Int, delay: TimeInterval, token: Int) {
        fileChangeRetryTasks[seq]?.cancel()
        ChangesDebugLog.log("summary retry seq=\(seq) delayMs=\(Int(delay * 1000))")
        fileChangeRetryTasks[seq] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.isCurrentFileChangeFetch(seq: seq, token: token) else { return }
            self.fileChangeRetryTasks[seq] = nil
            self.beginFileChangeSummaryFetch(seq: seq)
        }
    }

    private func makeFileChangeFetchToken(seq: Int) -> Int {
        fileChangeFetchTokenValue += 1
        fileChangeFetchTokens[seq] = fileChangeFetchTokenValue
        return fileChangeFetchTokenValue
    }

    private func isCurrentFileChangeFetch(seq: Int, token: Int) -> Bool {
        fileChangeFetchTokens[seq] == token
    }

 /// Cancels timers + in-flight bookkeeping and re-arms the request. Called on
 /// network path change / foreground / reconnect (phase or generation) / detail
 /// (re)open / sheet open. Only a fresh 404 can pin the fallback again.
 /// - Parameter reason: included in the DSHM_CHANGESDBG=1 diagnostics.
    private func resetFileChangesExactFetch(reason: String) {
        let hadState = !requestedFileChangeSeqs.isEmpty
            || !fileChangeFetch.loadingSeqs.isEmpty
            || !fileChangeFetch.attempts.isEmpty
            || !fileChangeFetch.terminalSeqs.isEmpty
        for task in fileChangeRetryTasks.values { task.cancel() }
        fileChangeRetryTasks.removeAll()
        fileChangeFetchTokens.removeAll()
        fileChangeFetch.reset()
        requestedFileChangeSeqs.removeAll()
        if hadState {
            ChangesDebugLog.log("reset reason=\(reason) networkGen=\(NetworkPathMonitor.shared.changeGeneration) prefersRelay=\(NetworkPathMonitor.shared.prefersRelay ? 1 : 0)")
        }
        requestFileChangeSummariesIfNeeded()
    }

 /// Public hook for `FileChangesSheet.onAppear`: opening the detail sheet is an
 /// explicit request for the exact numbers, so re-arm a previously failed fetch
 /// instead of leaving the fallback pinned.
    func retryFileChangesExactFetchIfNeeded() {
        guard let seq = flow.latestFileChangeSeq else { return }
        guard fileChangeSummaries[seq] == nil else { return }
        guard !fileChangeFetch.isLoading(seq) else { return }
        resetFileChangesExactFetch(reason: "sheet-open")
    }

    private func checkFileChangeNetworkGeneration() {
        let generation = NetworkPathMonitor.shared.changeGeneration
        guard generation != lastFileChangeNetworkGeneration else { return }
        lastFileChangeNetworkGeneration = generation
        resetFileChangesExactFetch(reason: "network-path-change")
    }

    private static func millisSince(_ start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private static func describeChangesError(_ error: Error) -> String {
        if let linkError = error as? LinkError {
            return "LinkError(\(String(describing: linkError)))"
        }
        return "\(type(of: error)): \(String(describing: error))"
    }

    #if canImport(UIKit)
    private func installFileChangeForegroundObserver() {
        guard fileChangeForegroundObserver == nil else { return }
        fileChangeForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetFileChangesExactFetch(reason: "foreground")
            }
        }
    }

    private func removeFileChangeForegroundObserver() {
        if let observer = fileChangeForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        fileChangeForegroundObserver = nil
    }
    #endif

    private func cancelFileChangeFetchTasks() {
        for task in fileChangeRetryTasks.values { task.cancel() }
        fileChangeRetryTasks.removeAll()
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
