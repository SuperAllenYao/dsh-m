import Combine
import Foundation

/// Workspace/session list state.
///
/// The projects and their session membership come from the Host's registry via the
/// `workspace/follow` stream (baseline + incremental frames) — the same source the
/// desktop DSH sidebar uses — instead of inferring groups from session cwd. Session
/// metadata (title/running/blank/updatedAt) still comes from `session/list` and is
/// joined by session id.
///
/// Live sync with the desktop (task-1): because membership and
/// metadata come from two different sources, a desktop-side change is only
/// visible after BOTH are fresh. The Host pushes membership on
/// `workspace/follow` and session-list hints on `$events`
/// (`api-session/added`/`activity`/`removed`), so this model
/// - refreshes `session/list` (debounced) when a follow frame introduces a
/// sessionId the joined snapshot has never seen — the actual root cause of
/// "desktop-created session never appears on the phone";
/// - refreshes on the forwarded `$events` hints (first message flips
/// `blank`, materialises the title, reorders by activity);
/// - runs one low-frequency fallback snapshot while the list page is on screen
/// (desktop-side rename broadcasts nothing at all: probe-verified).
///
/// Visibility mirrors the desktop sidebar (`sessionVisible()` in
/// dsh-client-ui-workspace):
/// - subagent sessions are hidden;
/// - blank sessions are hidden (the desktop only shows the *current* blank session;
/// the phone list page has no current session);
/// - archived session ids are hidden;
/// - sessions not accounted to any registered workspace ("未归组") are not shown.
@MainActor
final class WorkspaceViewModel: ObservableObject {
    struct WorkspaceGroup: Identifiable, Equatable {
        var id: String { workspaceId }
        var workspaceId: String
        var path: String
        var title: String
        var sessions: [SessionListItem]
        var displayName: String
    }

    @Published private(set) var groups: [WorkspaceGroup] = []
 /// Pinned sessions rendered above the workspace groups.
 /// Derived from `followState.pinnedSessionIds`; the groups exclude them so
 /// a pinned session appears exactly once in the list.
    @Published private(set) var pinnedSessions: [SessionListItem] = []
    @Published private(set) var isLoading = true
    @Published private(set) var errorText: String?
    @Published private(set) var lastLoadedAt: Date?
 /// Visible (registered, top-level, non-blank, non-archived) session count.
    @Published private(set) var sessionCount = 0
 /// Increments whenever a fresh `session/list` snapshot is applied — the view
 /// forwards the full list to `AppModel.updateKnownSessions` for deep links.
    @Published private(set) var sessionsSnapshotVersion = 0
 /// Increments whenever `groups` is rebuilt (drives the env-gated auto-open).
    @Published private(set) var groupsVersion = 0
 /// M2b-2: the list currently on screen came from the on-disk cache. The next
 /// network refresh replaces it in place (diffed, no empty-state flash).
    @Published private(set) var loadedFromCache = false
 /// M2b-2: the cached snapshot is older than the display TTL (still shown).
    @Published private(set) var cacheIsStale = false
 /// M2b-2: a background `session/list` refresh is in flight (view shows it).
    @Published private(set) var isRefreshing = false
 /// M2b-2: cache read + decode + first `groups` rebuild inside `init`, in ms.
        private(set) var cacheLoadMilliseconds: Double = 0
 /// M2b-2: same measurement as the time from view-model creation to the first
 /// non-empty cached list (target < 100 ms).
    private(set) var timeToFirstContentMilliseconds: Double = 0
 /// Workspace paths whose session list is collapsed (persisted by path).
    @Published private var collapsedPaths: Set<String> = []
 /// R2 (design 2.3): blank sessions minted through this phone's plus button.
 /// Only these blanks may show the new-session card - a blank the desktop
 /// created or focused never becomes visible here just because a draft exists.
    @Published private(set) var phoneCreatedBlanks: Set<String> = []
 /// Draft preview lines for the phone-created blank cards (sessionId -> first
 /// line). Refreshed on list appear / draft flush; the cards read from it so
 /// SessionCardView stays equatable on value identity.
    @Published private(set) var phoneCreatedDraftPreviews: [String: String] = [:]
 /// Two-phase close-out guard: on returning from a
 /// session page this list refreshes ~580 ms BEFORE the detail's onDisappear
 /// flush reaches DraftStore, so a pending 500 ms draft debounce reads as "no
 /// draft" and used to prune the blank for good. Missing-draft blanks are kept
 /// for one refresh (hidden by isVisible) and pruned only if still missing on
 /// the next one.
    private var blankDraftMissIds: Set<String> = []
 /// Workspace whose plus button is currently minting a session (spinner state).
    @Published private(set) var creatingWorkspaceId: String?
 /// R3: the one session card whose swipe actions are revealed (single-card
 /// exclusivity). Closed by tapping elsewhere, another swipe, a scroll, or a
 /// groups refresh (design 3.2).
    @Published var swipedSessionId: String?

 /// Every session from the last `session/list`, including subagent/blank/
 /// archived/ungrouped rows. Kept for deep-link address resolution only.
    private(set) var allSessions: [SessionListItem] = []
    private(set) var followState = WorkspaceFollowState()

    private var sessionsById: [String: SessionListItem] = [:]
 /// 最近一次网络快照（overlay 前）的原始 running 值，按 sessionId。
 /// live 运行态 overlay 必须能整体撤销：`$events` 流丢失/重连清空 live map 时，
 /// 已写进 `allSessions` 的旧 overlay 要按这份快照真值回退。
    private var snapshotRunningById: [String: Bool] = [:]
    private var sessionsLoaded = false
    private weak var link: LinkService?
    private var workspaceStream: RemoteStreamHandle?
    private var loadTask: Task<Void, Never>?
    private var observedGeneration = -1
 /// P0-4: monotonically increasing id so a superseded `session/list` response
 /// (cancelled load, or the pre-`connected` early request that lost the race
 /// with the mux bring-up) can never overwrite a newer snapshot.
    private var sessionListRequestID = 0
 /// P0-5: observer for "app resumed with the live link reused" (AppModel).
    private var resumeObserver: NSObjectProtocol?
 /// P0-4/P0-5: when the last live snapshot was applied, so the reconnect path
 /// does not re-fetch the full list immediately after a successful early one.
    private var lastNetworkListAppliedAt: Date?

 // MARK: - task-2 reconnect chain (page enter / stale-socket liveness)

 /// Budget for the reused mux's first byte after a page enter / foreground
 /// resume. Reusing a believed-alive mux means the first `workspace/follow`
 /// baseline is the socket's first byte; a silently dead socket (network switch,
 /// Mac sleep) delivers nothing and used to hang until the system TCP timeout.
 /// 300-500ms per handoff §2.3(2); env-tunable for the live bench only.
    static var reuseBaselineTimeoutMs: Int = {
        let raw = ProcessInfo.processInfo.environment["DSHM_MUX_FIRST_BYTE_MS"] ?? ""
        return Int(raw).map { min(5_000, max(50, $0)) } ?? 500
    }()
    private var baselineProbeTask: Task<Void, Never>?
    private var baselineProbeGeneration = 0
 /// One early `session/list` per bring-up window: it overlaps the mux handshake
 /// instead of waiting for `.connected` (P0-4), and dedupes repeated phase changes.
    private var lastEarlySnapshotAt: Date?
    private let defaults: UserDefaults
    private let cacheStore: SessionListCacheStore
 /// Raw wire JSON of the last successful `session/list` and `workspace/follow`
 /// baseline; cached so a cold launch can replay the same decoding path.
    private var lastSessionListJSON: JSONValue?
    private var listCacheSaveTask: Task<Void, Never>?
    private var didExposeCachedSessions = false

 // MARK: - 冷启动 <1s（用户人工验收）

 /// 缓存刷新指示器延迟出现：低于阈值的刷新（正常 <1s）用户完全看不到；
 /// 只有真正变慢（如桌面端重启后首次启动）才显示「本地缓存 · 正在刷新…」。
    @Published private(set) var showCacheRefreshBanner = false
    private var cacheBannerDelayTask: Task<Void, Never>?
 /// 阈值：低于它完成的刷新不显示指示器（需求「连接 + 缓存刷新 <1s」，
 /// 1s 内完成的刷新不该闪一下文案）。
    static let cacheRefreshBannerDelayMs: Int = 800
 /// 缓存仍是首帧时对 live `session/list` 的有界重试节奏（ms）。真机现场：
 /// 桌面端重启后 App 首次启动，连接重试持续 13s，而 live 列表只在「连上」后
 /// 才重试一次 → 用户看到 10s+ 的「正在刷新」。有界重试让列表在 1s 内自愈。
    static let staleListRetryDelaysMs: [Int] = [400, 800, 1600, 3200, 5_000]
    private var staleListRetryTask: Task<Void, Never>?
 /// 最近一次 live list 请求的开始时间：用于（a）冷启动耗时埋点，（b）重试循环在
 /// 请求挂起 >1.2s 时允许**并行重发**（更高 requestID 胜出），避免 20s unary
 /// 超时把「缓存刷新」拖到 10s+。
    private var lastListRequestStartedAt: Date?

 // MARK: - 桌面端实时同步（task-1）

 /// 列表页是否在屏（`start()` 与 `stop()` 之间）：宿主事件与兜底快照只在
 /// 此时工作；进详情/离屏立即停，不做后台轮询。
    private var isListPageActive = false
 /// `$events` 元数据失效信号观察者（见 LinkService+Streams 的
 /// HostSessionListInvalidation）。
    private var hostSessionListHintObserver: NSObjectProtocol?
 /// 去抖后的补刷任务：follow 未知 sessionId 与 `$events` 信号合并成一次快照。
    private var hostDrivenRefreshTask: Task<Void, Never>?
 /// 低频兜底快照循环（桌面端改名没有广播，只能靠快照收敛）。
    private var fallbackRefreshTask: Task<Void, Never>?
 /// 补刷落地后 follow 仍缺元数据时的有界重试计数（Host list work-slice 竞态）。
    private var missingFollowSessionRetries = 0

 /// 失效信号去抖窗口（ms）：新建会话时 follow upsert 与 api-session/added
 /// 几乎同时到，合并成一次 `session/list`。
    static let hostDrivenRefreshDelayMs: Int = 350
 /// 兜底快照间隔（ms）。桌面端改名不会广播任何帧，只能低频收敛；15s 是
 /// 「桌面端改成什么样，手机稍后跟到」与「禁止轮询风暴」的折中（只在列表页
 /// 在屏时跑）。E2E 可用 `DSHM_LIST_FALLBACK_REFRESH_MS` 缩短（DEBUG 环境变量，
 /// 与既有 DSHM_* 脚手架同族）；单测直接改这个 static。
    static var fallbackRefreshIntervalMs: Int = fallbackRefreshIntervalFromEnvironment()
 /// 兜底跳过窗口（ms）：刚发过列表请求就不重复发，由去抖/重连路径合并。
    static let fallbackRefreshMinGapMs: Int = 4_000
 /// follow 出现未知 id 但快照仍不含时的有界重试（最多 2 次、间隔 1.2s）。
    static let missingFollowSessionRetryLimit = 2
    static let missingFollowSessionRetryDelayMs = 1_200
 /// 测试 seam：替换真实 `session/list` 请求，观察「何时会补刷」。
    var sessionListRefreshOverride: (() -> Void)?

 /// 兜底间隔的默认值：15s，E2E 可用 env 缩短（夹在 0.5s–10min，避免误配置
 /// 把真实用户变成轮询风暴）。
    nonisolated static func fallbackRefreshIntervalFromEnvironment() -> Int {
        guard let raw = ProcessInfo.processInfo.environment["DSHM_LIST_FALLBACK_REFRESH_MS"],
              let value = Int(raw) else { return 15_000 }
        return min(max(value, 500), 600_000)
    }

 /// DEBUG 冷启动埋点：连接/列表各阶段耗时用。
    private func coldStartDebug(_ message: String) {
        #if DEBUG
        NSLog("[COLDSTART] %@", message)
        #endif
    }

 // MARK: - M2b-2b cold-start (compact first frame / in-app timing / prewarm)

 /// E2E-gated in-app metrics (`cacheMs=..;firstFrameMs=..;networkMs=..`) surfaced
 /// through the hidden `startup-metrics` accessibility element; nil outside E2E.
    @Published private(set) var startupMetricsValue: String?
    private var deferredRawRestoreTask: Task<Void, Never>?
    private var deferredRawFallbackTask: Task<Void, Never>?
    private var needsDeferredRawRestore = false
    private let prewarmer = SessionWindowPrewarmer()
    private var firstFrameRendered = false
    private var networkApplied = false
    private var prewarmStarted = false
 /// Ordered top-N candidate signature of the last prewarm run; a live list
 /// refresh that reorders the cards restarts the prewarm for the new top card.
    private(set) var prewarmSignature: String?
 /// Reorder that arrived while a prewarm fetch was still in flight.
    private var pendingPrewarmSignature: String?
 /// Test/evidence seam: how many prewarm runs have started.
    private(set) var prewarmStartCount = 0
 /// E2E-gated prewarm diagnostics (`prewarm-metrics` hidden element).
    @Published private(set) var prewarmMetricsValue: String?
 /// How many recent sessions to prewarm (env-tunable for the live bench; 0 = off).
    private let prewarmLimit: Int
    static let collapsedPathsKey = "workspaceList.collapsedPaths"
    static let phoneCreatedBlanksKey = "workspaceList.phoneCreatedBlanks"

    init(
        defaults: UserDefaults = .standard,
        cacheStore: SessionListCacheStore = SessionListCacheStore()
    ) {
        self.defaults = defaults
        self.cacheStore = cacheStore
        self.prewarmLimit = Self.prewarmLimitFromEnvironment()
        collapsedPaths = Set(defaults.stringArray(forKey: Self.collapsedPathsKey) ?? [])
        phoneCreatedBlanks = Set(defaults.stringArray(forKey: Self.phoneCreatedBlanksKey) ?? [])
 // DEBUG-only E2E seam (same family as DSHM_E2E_RESET_CACHE): repeated
 // create-flow rounds leave drafted blank cards behind (product-correct
 // persistence across launches); rounds opt into a clean slate here.
        #if DEBUG
        if ProcessInfo.processInfo.environment["DSHM_E2E_RESET_BLANKS"] == "1" {
            phoneCreatedBlanks = []
            phoneCreatedDraftPreviews = [:]
            persistPhoneCreatedBlanks()
            try? FileManager.default.removeItem(
                at: CacheIO.defaultDirectory().appendingPathComponent("Drafts", isDirectory: true)
            )
        }
        #endif
        restoreCachedList()
    }

 // MARK: - M2b-2 cold-start cache

 /// Synchronously renders the last persisted list + workspace registry. Runs
 /// inside `init`, before the first SwiftUI render, so the list is visible
 /// without waiting for the link/mux handshake.
 ///
 /// M2b-2b: the compact render snapshot (`session-list-render.json`, tens of KB) is
 /// preferred for the first frame; the ~1MB raw wire JSON is decoded afterwards on
 /// a background thread (deep links / consistency), so it never blocks the first
 /// paint. Older caches without a compact snapshot fall back to the synchronous
 /// raw decode (previous behaviour).
    private func restoreCachedList() {
        let started = Date()
        defer {
            cacheLoadMilliseconds = Date().timeIntervalSince(started) * 1000
            if !groups.isEmpty {
                timeToFirstContentMilliseconds = cacheLoadMilliseconds
            }
            if loadedFromCache {
                StartupMetrics.markCacheLoaded()
                startupMetricsValue = StartupMetrics.valueString
            }
        }
        if let render = cacheStore.loadRenderSnapshot() {
            if let follow = render.payload.followBaseline,
               let frame = try? follow.decode(WorkspaceFollowFrame.self) {
                followState.apply(frame)
            }
            var restoredGroups = render.payload.groups.map(Self.workspaceGroup(from:))
 // code review P2: the compact snapshot persists the pinned
 // area in its own field (pinned rows are already split out of `groups`),
 // so pinning survives a cold start on the very first frame instead of
 // waiting for the background raw restore.
            var restoredPinned: [SessionListItem] = []
            if let storedPinned = render.payload.pinned {
                restoredPinned = storedPinned.map(SessionListRenderSnapshot.listItem(from:))
            } else {
 // Legacy snapshot (written before the pinned field existed): its
 // groups still contain the pinned rows, so split them back out from
 // the follow baseline.
                let pinnedRank = Dictionary(
                    followState.pinnedSessionIds.enumerated().map { ($0.element, $0.offset) },
                    uniquingKeysWith: { first, _ in first }
                )
                if !pinnedRank.isEmpty {
                    for index in restoredGroups.indices {
                        var kept: [SessionListItem] = []
                        for session in restoredGroups[index].sessions {
                            if pinnedRank[session.sessionId] != nil {
                                restoredPinned.append(session)
                            } else {
                                kept.append(session)
                            }
                        }
                        restoredGroups[index].sessions = kept
                    }
                    restoredPinned.sort { lhs, rhs in
                        let leftRank = pinnedRank[lhs.sessionId] ?? Int.max
                        let rightRank = pinnedRank[rhs.sessionId] ?? Int.max
                        if leftRank != rightRank { return leftRank < rightRank }
                        let leftTime = Self.activity(of: lhs)
                        let rightTime = Self.activity(of: rhs)
                        if leftTime != rightTime { return leftTime > rightTime }
                        return lhs.sessionId < rhs.sessionId
                    }
                }
            }
            pinnedSessions = restoredPinned
            groups = restoredGroups
            sessionCount = groups.reduce(0) { $0 + $1.sessions.count } + restoredPinned.count
            groupsVersion += 1
            isLoading = false
            loadedFromCache = true
            cacheIsStale = render.isStale
 // Feed the deep-link resolver the compact rows right away; the raw
 // restore (allSessions/subagent rows) starts only after the first frame
 // so its ~0.5s background decode never competes with the first paint.
            sessionsSnapshotVersion += 1
            needsDeferredRawRestore = true
            return
        }
 // Fallback: caches written before the compact snapshot existed.
        guard let cached = cacheStore.load() else { return }

        var restoredAnything = false
        if let follow = cached.payload.followBaseline,
           let frame = try? follow.decode(WorkspaceFollowFrame.self) {
            followState.apply(frame)
            restoredAnything = true
        }
        if let list = cached.payload.sessionList,
           let value = try? list.decode(SessionListValue.self) {
            rememberSnapshotRunning(value.items)
            allSessions = value.items
            var byId: [String: SessionListItem] = [:]
            byId.reserveCapacity(value.items.count)
            for item in value.items {
                byId[item.sessionId] = item
            }
            sessionsById = byId
            sessionsLoaded = true
            lastSessionListJSON = list
            restoredAnything = true
        }
        guard restoredAnything else { return }
        isLoading = false
        loadedFromCache = true
        cacheIsStale = cached.isStale
 // A cached list is good enough to resolve deep-link addresses immediately.
        sessionsSnapshotVersion += 1
        rebuildGroups()
        maybeStartPrewarm()
    }

    private static func workspaceGroup(from group: SessionListRenderSnapshot.Group) -> WorkspaceGroup {
        WorkspaceGroup(
            workspaceId: group.workspaceId,
            path: group.path,
            title: group.title,
            sessions: group.sessions.map(SessionListRenderSnapshot.listItem(from:)),
            displayName: group.displayName
        )
    }

 /// Second-stage cold restore: decodes the raw wire snapshot off the main thread,
 /// then publishes the exact `session/list` rows (deep-link address resolution and
 /// full projections) without touching the already-visible first frame.
    private func startDeferredRawRestoreIfNeeded() {
        guard needsDeferredRawRestore else { return }
        needsDeferredRawRestore = false
        restoreRawCacheInBackground()
    }

    private func restoreRawCacheInBackground() {
        deferredRawRestoreTask?.cancel()
        let store = cacheStore
        deferredRawRestoreTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { store.load() }.value
            guard let self, !Task.isCancelled, let loaded else { return }
            guard let raw = loaded.payload.sessionList else { return }
 // r7 immediate-swipe freeze: the raw snapshot (~1MB, a
 // JSONEncoder+JSONDecoder double conversion) used to be decoded right
 // here on the MainActor. A user swiping right after cold start hit that
 // window and the whole list froze. Decode off the main thread (same fix
 // as the network path, ce023fe); the MainActor only assigns + rebuilds.
            guard let value = try? await Self.decodeSessionListOffMain(raw) else { return }
            guard !Task.isCancelled else { return }
            self.applyDecodedDeferredRawCache(raw, value)
        }
    }

 /// Applies an already-decoded raw cache snapshot on the MainActor (assignments
 /// + in-memory group rebuild only; no JSON decoding here).
    private func applyDecodedDeferredRawCache(_ raw: JSONValue, _ value: SessionListValue) {
        deferredRawRestoreTask = nil
 // A live network snapshot already landed with fresher data: keep it.
        guard !sessionsLoaded else { return }
        lastSessionListJSON = raw
        sessionsLoaded = true
        rememberSnapshotRunning(value.items)
        allSessions = value.items
        var byId: [String: SessionListItem] = [:]
        byId.reserveCapacity(value.items.count)
        for item in value.items {
            byId[item.sessionId] = item
        }
        sessionsById = byId
        rebuildGroups()
        sessionsSnapshotVersion += 1
        maybeStartPrewarm()
    }

 /// `workspace/follow` state as a baseline frame: written to disk so a restart
 /// can reconstruct the registry exactly as the Host last sent it.
    private func followBaselineJSON() -> JSONValue? {
        guard followState.baselineApplied else { return nil }
        let items: [JSONValue] = followState.workspaces.map { workspace in
            var object: [String: JSONValue] = [
                "workspaceId": .string(workspace.workspaceId),
                "path": .string(workspace.path),
                "title": .string(workspace.title),
                "sessionIds": .array(workspace.sessionIds.map { .string($0) }),
            ]
            if let createdAt = workspace.createdAt { object["createdAt"] = .string(createdAt) }
            if let updatedAt = workspace.updatedAt { object["updatedAt"] = .string(updatedAt) }
            return .object(object)
        }
        return .object([
            "type": .string("baseline"),
            "value": .object([
                "items": .array(items),
                "archivedSessionIds": .array(followState.archivedSessionIds.sorted().map { .string($0) }),
                "pinnedSessionIds": .array(followState.pinnedSessionIds.map { .string($0) }),
            ]),
        ])
    }

 /// Debounced so a burst of `workspace/follow` incremental frames (and the
 /// session-list snapshot) produces a single atomic cache write. M2b-2b: the
 /// encode/write (raw ~1MB + compact) happens on a utility queue, never on main.
    private func scheduleListCacheSave() {
        listCacheSaveTask?.cancel()
        listCacheSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.listCacheSaveTask = nil
            self.saveListCacheInBackground()
        }
    }

 /// Persists the current list + registry (only once both halves are known).
 /// Synchronous variant used by unit tests and explicit flushes.
    func saveListCacheNow() {
        guard sessionsLoaded, let sessionList = lastSessionListJSON else { return }
        let follow = followBaselineJSON()
        cacheStore.save(sessionList: sessionList, followBaseline: follow)
        cacheStore.saveRenderSnapshot(
            groups: renderGroups(),
            pinned: renderPinned(),
            followBaseline: follow
        )
    }

 /// M2b-2b: the raw encode (~1MB) and compact write are pure value-type work —
 /// hand them to a utility queue so a refresh never janks the visible list.
    private func saveListCacheInBackground() {
        guard sessionsLoaded, let sessionList = lastSessionListJSON else { return }
        let follow = followBaselineJSON()
        let render = renderGroups()
        let pinned = renderPinned()
        let store = cacheStore
        Task.detached(priority: .utility) {
            store.save(sessionList: sessionList, followBaseline: follow)
            store.saveRenderSnapshot(groups: render, pinned: pinned, followBaseline: follow)
        }
    }

 /// Current groups in the compact, render-only shape written next to the raw cache.
    private func renderGroups() -> [SessionListRenderSnapshot.Group] {
        groups.map { group in
            SessionListRenderSnapshot.Group(
                workspaceId: group.workspaceId,
                path: group.path,
                title: group.title,
                displayName: group.displayName,
                sessions: group.sessions.map(SessionListRenderSnapshot.session(from:))
            )
        }
    }

 /// Compact shape of the pinned area (already split out of `groups`), persisted
 /// so a cold start renders the pinned cards on the first frame.
    private func renderPinned() -> [SessionListRenderSnapshot.Session] {
        pinnedSessions.map(SessionListRenderSnapshot.session(from:))
    }

    var isConnected: Bool {
        link?.phase.isConnected ?? false
    }

 // MARK: - Lifecycle

    func attach(link: LinkService) {
        self.link = link
    }

 /// P0-4: `session/list` runs over the pinned unary transport (HTTPS + a
 /// short-lived api bearer token), which is independent of the mux/`$events`
 /// handshake. As long as the device is paired the request can therefore be
 /// issued *before* `phase ==.connected`; LinkService mints the api token in
 /// parallel (per-purpose auth in-flight since P0), and the `.connected`
 /// handlers below still reload incrementally.
    nonisolated static func canLoadSessionsBeforeConnected(hasCredentials: Bool, isConnected: Bool) -> Bool {
        hasCredentials && !isConnected
    }

 /// Entering the list: keep the workspace stream open and load session metadata.
    func start() {
        guard let link else { return }
        beginHostDrivenListSync()
        coldStartDebug("start phase=\(link.phase) cached=\(loadedFromCache) sessionsLoaded=\(sessionsLoaded) networkApplied=\(networkApplied)")
        observedGeneration = link.generation
 // The cached list was applied in `init`; SwiftUI's `.onChange` only observes
 // changes made after it appears, so re-publish once to feed the deep-link
 // resolver (`AppModel.updateKnownSessions`) on a cold start.
        if loadedFromCache && !didExposeCachedSessions {
            didExposeCachedSessions = true
            sessionsSnapshotVersion += 1
        }
        observeForegroundResume()
 // P0-4: the cached first frame is already on screen (or the empty chrome is);
 // do not wait for `phase ==.connected` to ask the Host for the live list.
 // The request is silent while the link is still busy, and a superseded
 // response can never overwrite the connected-path snapshot (request id).
 // P0-4 guard: never issue the early unary on a path where the stored origin
 // is a stale LAN address (it would hang for the full timeout instead of
 // letting the connect loop dial the relay first).
        startEarlySnapshotDuringBringup()
 // if the first frame is still the cached one, keep retrying the
 // live list on a bounded schedule instead of waiting for the next phase flip
 // .
        armStaleListRetry()
        guard link.phase.isConnected else {
 // Show the list chrome + connection banner instead of a forever spinner;
 // handleConnectionChange() starts the stream once the link is ready.
            isLoading = false
            if !link.phase.isBusy, !link.statusDetail.isEmpty {
                errorText = link.statusDetail
            }
            return
        }
        openWorkspaceStream()
        loadSessions()
        maybeStartPrewarm()
 // task-2: the mux was believed alive, so its first byte must arrive now.
        armReuseLivenessProbe()
 // Fallback: if no card ever appears (e.g. an empty cached list) still start
 // the raw deep-link restore after a beat.
        deferredRawFallbackTask?.cancel()
        deferredRawFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.startDeferredRawRestoreIfNeeded()
        }
    }

 /// Leaving the list: stop consuming the workspace stream.
    func stop() {
        endHostDrivenListSync()
        workspaceStream?.cancel()
        workspaceStream = nil
        loadTask?.cancel()
        loadTask = nil
 // leaving the list retires the stale-list retry loop and the
 // delayed cache-refresh indicator (a late callback must not touch a view
 // that is gone).
        cancelStaleListRetry()
        clearCacheRefreshBanner()
        if let resumeObserver {
            NotificationCenter.default.removeObserver(resumeObserver)
            self.resumeObserver = nil
        }
 // M2b-2b: the deferred raw-cache decode is best-effort. The detail prewarm
 // keeps running after the list disappears: a just-tapped session's first
 // window may still be in flight, and saving it makes the next open instant.
        deferredRawRestoreTask?.cancel()
        deferredRawRestoreTask = nil
        deferredRawFallbackTask?.cancel()
        deferredRawFallbackTask = nil
        baselineProbeTask?.cancel()
        baselineProbeTask = nil
 // Flush a pending debounced cache write (background: raw encode is ~1MB).
        listCacheSaveTask?.cancel()
        listCacheSaveTask = nil
        saveListCacheInBackground()
    }

 /// P0-5: the app is foreground again and `AppModel` decided the existing
 /// TLS/mux is still believed alive. Reuse it: no teardown, no `connectOnce`.
 /// Reopening `workspace/follow` replays the registry baseline on the same mux
 /// and doubles as a liveness probe (a dead socket fails that send and
 /// LinkService reconnects); the session snapshot refreshes over the existing
 /// unary path.
    func handleForegroundResume(backgroundedSeconds: TimeInterval) {
        guard let link else { return }
        guard link.phase.isConnected else {
 // Transport is down; AppModel already asked LinkService to reconnect.
 // Start the snapshot in parallel so it can land right after `connected`.
            if Self.canLoadSessionsBeforeConnected(
                hasCredentials: link.credentials != nil,
                isConnected: link.phase.isConnected
            ) {
                loadSessions(silent: true)
            }
            _ = backgroundedSeconds
            return
        }
        _ = backgroundedSeconds
        reopenWorkspaceStream()
        loadSessions()
        maybeStartPrewarm()
 // task-2: reuse is only valid if the first baseline lands within budget.
        armReuseLivenessProbe()
    }

    private func observeForegroundResume() {
        guard resumeObserver == nil else { return }
        resumeObserver = NotificationCenter.default.addObserver(
            forName: .dshmAppResumedReusingLink,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let seconds = notification.userInfo?["backgroundedSeconds"] as? Double
            Task { @MainActor [weak self] in
                self?.handleForegroundResume(backgroundedSeconds: seconds ?? 0)
            }
        }
    }

 /// Link generation changed (reconnect): the Host replays a fresh baseline, so
 /// reopen the stream and reload the session snapshot.
    func handleGenerationChange(_ generation: Int) {
        guard generation != observedGeneration else { return }
        observedGeneration = generation
        guard generation > 0 else { return }
 // `handleConnectionChange` may already have reopened the stream for this
 // phase; opening twice would subscribe twice on the same mux (P0-5 reuse).
        if workspaceStream == nil { openWorkspaceStream() }
 // P0-4: when the pre-connected request already landed a fresh snapshot, the
 // reconnect must not re-fetch the full list for no user-visible gain.
        let recent = lastNetworkListAppliedAt.map { Date().timeIntervalSince($0) < 2 } ?? false
        if !sessionsLoaded || !recent { loadSessions() }
    }

 /// Connection phase changed. Disconnect cancels the stream; reconnect reopens it.
    func handleConnectionChange() {
        guard let link else { return }
        if link.phase.isConnected {
            if workspaceStream == nil { openWorkspaceStream() }
            if !sessionsLoaded { loadSessions() }
            maybeStartPrewarm()
        } else {
            workspaceStream?.cancel()
            workspaceStream = nil
 // task-2: start the snapshot request while the mux is still handshaking
 // so t1 = connected + listApplied instead of connected + list RTT.
            startEarlySnapshotDuringBringup()
        }
    }

 /// Pull-to-refresh / retry: reopen the stream (baseline replay) and reload the
 /// session snapshot.
    func refresh() async {
        reopenWorkspaceStream()
        await loadSessionsNow()
    }

    private func reopenWorkspaceStream() {
        workspaceStream?.cancel()
        workspaceStream = nil
        openWorkspaceStream()
    }

    private func openWorkspaceStream() {
        guard let link, link.phase.isConnected else { return }
        do {
            workspaceStream = try link.openStream(
                endpoint: "workspace/follow",
                args: [:],
                onItem: { [weak self] value in
                    self?.handleWorkspaceItem(value)
                },
                onEnd: { [weak self] in
                    self?.workspaceStream = nil
                },
                onError: { [weak self] error in
                    guard let self else { return }
                    self.workspaceStream = nil
                    self.isLoading = false
                    self.errorText = error.message.isEmpty ? error.code : error.message
                },
                onClose: { [weak self] _, _ in
 // Transport lost: LinkService reconnects and bumps generation;
 // handleGenerationChange reopens the stream.
                    self?.workspaceStream = nil
                }
            )
        } catch {
            errorText = NetworkErrorInterpreter.message(for: error)
        }
    }

 // MARK: - 桌面端实时同步（task-1）

 /// 列表页在屏：订阅 `$events` 的列表元数据失效信号，并启动低频兜底快照。
 /// 由 `start()` 调用（`stop()` 对称撤销）。
    private func beginHostDrivenListSync() {
        isListPageActive = true
        missingFollowSessionRetries = 0
        guard hostSessionListHintObserver == nil else { return }
        hostSessionListHintObserver = NotificationCenter.default.addObserver(
            forName: HostSessionListInvalidation.notification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let event = notification.userInfo?["event"] as? String ?? "unknown"
            Task { @MainActor [weak self] in
                self?.scheduleHostDrivenRefresh(reason: "events/" + event)
            }
        }
        startFallbackRefreshLoop()
    }

 /// 列表页离屏：撤销订阅与后台任务；回列表时 `start()` 重新装上。
    private func endHostDrivenListSync() {
        isListPageActive = false
        if let observer = hostSessionListHintObserver {
            NotificationCenter.default.removeObserver(observer)
            hostSessionListHintObserver = nil
        }
        hostDrivenRefreshTask?.cancel()
        hostDrivenRefreshTask = nil
        fallbackRefreshTask?.cancel()
        fallbackRefreshTask = nil
        missingFollowSessionRetries = 0
    }

 /// Test seam：无 LinkService 时安装宿主同步（生产由 `start()` 安装）。
    func beginHostDrivenListSyncForTests() {
        beginHostDrivenListSync()
    }

 /// Test seam：卸载宿主同步（否则异步任务会跨测试泄漏）。
    func endHostDrivenListSyncForTests() {
        endHostDrivenListSync()
    }

 /// 把一次宿主信号/follow 缺行合并进同一条去抖补刷。
    private func scheduleHostDrivenRefresh(reason: String, delayMs: Int? = nil) {
        guard isListPageActive else { return }
        hostDrivenRefreshTask?.cancel()
        let delay = delayMs ?? Self.hostDrivenRefreshDelayMs
        hostDrivenRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0)) * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            self.performHostDrivenRefresh(reason: reason)
        }
    }

 /// 执行一次宿主驱动的静默快照。
    private func performHostDrivenRefresh(reason: String) {
        guard isListPageActive else { return }
 // 断线期间不补刷（宿主信号本身也随 $events 流消失）：重连与前台恢复
 // 路径会统一 loadSessions，这里发只会得到一次必败的请求。
        if let link, !link.phase.isConnected { return }
        if let startedAt = lastListRequestStartedAt,
           Date().timeIntervalSince(startedAt) * 1000 < 1_200 {
 // 已有一份刚发出的快照在飞：它落地后会在
 // `noteListSnapshotApplied` 里再检查缺行，这里不叠加请求。
            coldStartDebug("host-driven refresh skipped (\(reason)): in-flight request")
            return
        }
        coldStartDebug("host-driven list refresh reason=\(reason)")
        refreshSessionListFromHost()
    }

 /// 发一次静默 `session/list`（测试注入 override，避免真实网络）。
    private func refreshSessionListFromHost() {
        if let override = sessionListRefreshOverride {
            override()
            return
        }
        loadSessions(silent: true)
    }

 /// 低频兜底：桌面端改名没有任何广播帧，只改 `session/list` 的 title，
 /// 只能靠这个循环收敛（仅在列表页在屏且链路已连时发请求）。
    private func startFallbackRefreshLoop() {
        fallbackRefreshTask?.cancel()
        fallbackRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = max(Self.fallbackRefreshIntervalMs, 50)
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
                guard !Task.isCancelled, let self else { return }
                self.fallbackRefreshTick()
            }
        }
    }

    private func fallbackRefreshTick() {
        guard isListPageActive, sessionsLoaded else { return }
 // 生产路径 start() 先 guard 了 link；无 link 只可能是测试 seam。
        if let link, !link.phase.isConnected { return }
        if let startedAt = lastListRequestStartedAt,
           Date().timeIntervalSince(startedAt) * 1000 < Double(Self.fallbackRefreshMinGapMs) {
            return
        }
        coldStartDebug("fallback list refresh")
        refreshSessionListFromHost()
    }

 /// `workspace/follow` 已有成员关系、但 `session/list` 快照还没有行的
 /// sessionId（桌面端新建会话的正常竞态：follow 先到、元数据快照未取）。
 /// 列表按 id join 元数据，这种 id 会被 `rebuildGroups` 静默丢弃。
    private func hasFollowSessionMissingFromSnapshot() -> Bool {
        guard sessionsLoaded else { return false }
        for workspace in followState.workspaces {
            for sessionId in workspace.sessionIds where sessionsById[sessionId] == nil {
                return true
            }
        }
        return false
    }

 /// 快照落地后：follow 仍带来未知 id 时（Host list work-slice 尚未合并）
 /// 有界重试，收敛后清零。
    private func noteListSnapshotApplied() {
        guard isListPageActive else { return }
        guard hasFollowSessionMissingFromSnapshot() else {
            missingFollowSessionRetries = 0
            return
        }
        guard missingFollowSessionRetries < Self.missingFollowSessionRetryLimit else {
            coldStartDebug("follow session still missing after retries; stop retrying")
            return
        }
        missingFollowSessionRetries += 1
        scheduleHostDrivenRefresh(
            reason: "follow/missing-session#\(missingFollowSessionRetries)",
            delayMs: Self.missingFollowSessionRetryDelayMs
        )
    }

 // MARK: - Stream / snapshot application

    private func handleWorkspaceItem(_ value: JSONValue?) {
        guard let value else { return }
        do {
            let frame = try value.decode(WorkspaceFollowFrame.self)
            applyWorkspaceFrame(frame)
        } catch {
            errorText = L10n.f("工作区数据解析失败: %@", error.localizedDescription)
        }
    }

 /// Test seam: apply one decoded `workspace/follow` frame.
    func applyWorkspaceFrame(_ frame: WorkspaceFollowFrame) {
 // R2 close-out (design 2.3 c): remember which sessions the frame is about
 // to drop, then release phone-created blanks that were archived/removed.
        let knownIds = phoneCreatedBlanks.isEmpty
            ? Set<String>()
            : Set(followState.workspaces.flatMap(\.sessionIds))
        let archivedBefore = followState.archivedSessionIds
        followState.apply(frame)
        if case .baseline = frame {
            isLoading = false
 // task-2: the reused mux delivered its first byte within budget.
            cancelReuseLivenessProbe()
            link?.noteReuseLivenessConfirmed()
        }
        closeOutPhoneCreatedBlanks(knownWorkspaceIds: knownIds, archivedBefore: archivedBefore)
        errorText = nil
        rebuildGroups()
 // task-1：桌面端新建会话时，follow 的 upsert 会先
 // 带来新 sessionId，而卡片要 join `session/list` 的元数据——快照里没有这
 // 一行时 rebuildGroups 会静默丢弃，列表永远不出现。发现未知 id 就补刷。
        if hasFollowSessionMissingFromSnapshot() {
            coldStartDebug("follow frame introduced unknown sessionId; scheduling list refresh")
            scheduleHostDrivenRefresh(reason: "follow/unknown-session")
        }
        maybeStartPrewarm()
        scheduleListCacheSave()
    }

 /// Release phone-created blanks the frame archived or removed (2.3 c). An id
 /// this phone minted moments ago may not have reached the registry yet, so a
 /// blank that was never seen in any workspace is kept (never a false drop).
    private func closeOutPhoneCreatedBlanks(knownWorkspaceIds: Set<String>, archivedBefore: Set<String>) {
        guard !phoneCreatedBlanks.isEmpty else { return }
        let liveIds = Set(followState.workspaces.flatMap(\.sessionIds))
        var survivors: Set<String> = []
        for id in phoneCreatedBlanks {
            if followState.archivedSessionIds.contains(id) { continue }
            if knownWorkspaceIds.contains(id), !liveIds.contains(id) { continue }
            if archivedBefore.contains(id) { continue }
            survivors.insert(id)
        }
        if survivors != phoneCreatedBlanks {
            phoneCreatedBlanks = survivors
            persistPhoneCreatedBlanks()
        }
    }

    private func persistPhoneCreatedBlanks() {
        defaults.set(phoneCreatedBlanks.sorted(), forKey: Self.phoneCreatedBlanksKey)
    }

 /// Register a freshly minted blank (2.3): visible as soon as a draft exists.
    func registerPhoneCreatedBlank(sessionId: String) {
        guard !phoneCreatedBlanks.contains(sessionId) else { return }
        phoneCreatedBlanks.insert(sessionId)
        persistPhoneCreatedBlanks()
    }

 /// Refresh blank-card previews + visibility from the draft store. Called on
 /// list appear (returning from a session page) - the card must reflect the
 /// draft that was typed without any live cross-object push (design 2.3/2.4).
 /// This is also close-out (2.3 b): a blank that came back with an empty
 /// draft is released here, and a blank that has since sent its first
 /// message (no longer blank) is dropped from the set so it cannot pile up.
    func refreshBlankCardState() {
        guard !phoneCreatedBlanks.isEmpty else {
            if !phoneCreatedDraftPreviews.isEmpty { phoneCreatedDraftPreviews = [:] }
            blankDraftMissIds = []
            return
        }
        var survivors: Set<String> = []
        var previews: [String: String] = [:]
        var stillMissingDraft: Set<String> = []
        for id in phoneCreatedBlanks {
            if let item = sessionsById[id], item.blank != true { continue }
            guard let text = DraftStore.shared.text(for: id) else {
 // First miss: the draft may still be in the 500 ms debounce window
 // or waiting for the detail's onDisappear flush (which runs after
 // this refresh). Keep the id; isVisible already keeps the card
 // hidden until a draft exists.
                if blankDraftMissIds.contains(id) { continue }
                stillMissingDraft.insert(id)
                survivors.insert(id)
                continue
            }
            survivors.insert(id)
            previews[id] = String(text.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
        }
        blankDraftMissIds = stillMissingDraft
        if survivors != phoneCreatedBlanks {
            phoneCreatedBlanks = survivors
            persistPhoneCreatedBlanks()
        }
        phoneCreatedDraftPreviews = previews
        rebuildGroups()
    }

 /// Surface one inline error from a view action (R3 disconnect hints etc.).
    func showInlineError(_ text: String) {
        errorText = text
    }

 /// E2E-only companion to `createSession`: the session id returned by the
 /// most recent phone-side create RPC (minted or reused). Write-capable UI
 /// tests address their targets strictly through this id — positional card
 /// lookups once archived a live session, never again.
    @Published private(set) var e2eCreatedSessionId = ""

 /// R2 (design 2.2): mint a session in one workspace through the plugin
 /// route. Returns the new session id (reused or minted); failures surface
 /// through `errorText` (NetworkErrorInterpreter wording) and return nil.
    @MainActor
    func createSession(inWorkspace workspaceId: String, link: LinkService) async -> String? {
        creatingWorkspaceId = workspaceId
        defer { creatingWorkspaceId = nil }
        do {
            let result = try await link.createSession(workspaceId: workspaceId)
            registerPhoneCreatedBlank(sessionId: result.sessionId)
            e2eCreatedSessionId = result.sessionId
            errorText = nil
            return result.sessionId
        } catch {
            errorText = NetworkErrorInterpreter.message(for: error)
            return nil
        }
    }

 // MARK: - R3 pin / archive (optimistic + reconcile, design 3.2)

 /// Apply one optimistic pin change to the local follow-state copy and
 /// rebuild (the pinned group re-sorts immediately). Returns the previous
 /// pin list for rollback.
    @discardableResult
    private func applyOptimisticPin(_ sessionId: String, pinned: Bool) -> [String] {
        let previous = followState.applyOptimisticPin(sessionId, pinned: pinned)
        rebuildGroups()
        return previous
    }

    private func rollbackPin(_ previous: [String]) {
        followState.restorePins(previous)
        rebuildGroups()
    }

 /// Toggle one session's pin. No confirmation (design 3.2): optimistic
 /// reorder + RPC; the returned complete set wins on success, rollback +
 /// inline error otherwise (the later host broadcast frame is the final
 /// word for concurrent edits on both ends).
    @MainActor
    func togglePin(sessionId: String, link: LinkService) async {
        let pinned = !followState.pinnedSessionIds.contains(sessionId)
        let previous = applyOptimisticPin(sessionId, pinned: pinned)
        do {
            let result = try await link.pinSession(sessionId: sessionId, pinned: pinned)
            followState.replacePins(result.pinnedSessionIds)
            rebuildGroups()
        } catch {
            rollbackPin(previous)
            errorText = NetworkErrorInterpreter.message(for: error)
        }
    }

 /// Archive one session. Optimistic removal; a 409 session-active rolls the
 /// card back and rethrows `archive/session-active` so the caller swaps the
 /// idle confirmation for the running one (same dialog, stopActivity: true).
    @MainActor
    func archiveSession(
        sessionId: String, stopActivity: Bool, link: LinkService
    ) async throws {
        let previous = followState.applyOptimisticArchive(sessionId)
        rebuildGroups()
        do {
            let result = try await link.archiveSession(sessionId: sessionId, stopActivity: stopActivity)
            followState.replaceArchived(Set(result.archivedSessionIds))
            closeOutPhoneCreatedBlanksIfArchived([sessionId])
            rebuildGroups()
        } catch {
            followState.restoreArchive(previous.archived, pinned: previous.pinned)
            rebuildGroups()
            throw error
        }
    }

    private func closeOutPhoneCreatedBlanksIfArchived(_ ids: [String]) {
        guard !phoneCreatedBlanks.isEmpty else { return }
        var survivors = phoneCreatedBlanks
        for id in ids where survivors.contains(id) { survivors.remove(id) }
        if survivors != phoneCreatedBlanks {
            phoneCreatedBlanks = survivors
            persistPhoneCreatedBlanks()
        }
    }

 /// Loads the live `session/list` snapshot. `silent` suppresses the error
 /// banner for speculative requests issued while the link is still coming up
 /// (P0-4/P0-5): those either land (and paint the list early) or are superseded
 /// by the `.connected` reload, so a transient failure is not user-actionable.
    private func loadSessions(silent: Bool = false) {
 // 冷启动 <1s：不要取消一个刚发出（<1.2s）的 in-flight 请求。
 // 真机上 connected/generation 触发的 reload 会把快完成的 early 请求 cancel，
 // 然后重发一整轮（TLS+auth+240KB）——抖动路径上叠加成 10s 级刷新。让它在飞，
 // 由 requestID 保证「最新者胜出」；真正挂起时由 stale-list 重试循环 supersede。
        if isRefreshing, let startedAt = lastListRequestStartedAt {
            let inFlightMs = Date().timeIntervalSince(startedAt) * 1000
            if inFlightMs < 1_200 {
                coldStartDebug("loadSessions skipped: in-flight request \(Int(inFlightMs))ms (not cancelling)")
                return
            }
        }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadSessionsNow(silent: silent)
        }
    }

    private func loadSessionsNow(silent: Bool = false) async {
        guard let link, link.credentials != nil else { return }
 // T2(B1)：冷启动首屏列表先等 HTTPS 池预热（上限 350ms），让随后的
 // auth+list 复用预热建好的 TLS，而不是再自付一次 ~200-300ms 握手。只有
 // 「首份网络列表未落地」+「预热在飞」才等：热路径零额外延迟；预热失败/超时/
 // 已完成都立即走原路径（等待不抛错、也不取消预热任务）。
        if Self.shouldAwaitPoolWarmup(
            networkApplied: networkApplied,
            warmupInFlight: link.isPoolWarmupInFlight
        ) {
            let waitStartedAt = Date()
            await link.awaitPoolWarmup(timeoutMs: Self.poolWarmupWaitTimeoutMs)
            let waitedMs = Int(Date().timeIntervalSince(waitStartedAt) * 1000)
            coldStartDebug("pool warm-up waited \(waitedMs)ms")
            guard !Task.isCancelled else { return }
        }
 // P0-4: every request gets an id; a superseded response (cancelled task or
 // the early pre-`connected` request losing the race) is dropped instead of
 // overwriting a newer snapshot.
        sessionListRequestID += 1
        let requestID = sessionListRequestID
        lastListRequestStartedAt = Date()
        let originOverride = link.earlyListOriginOverride()
        coldStartDebug("list request #\(requestID) silent=\(silent) override=\(originOverride?.absoluteString ?? "-") cached=\(loadedFromCache)")
        isRefreshing = true
        armCacheRefreshBannerDelay()
        defer {
            if requestID == sessionListRequestID {
                isRefreshing = false
                loadTask = nil
                clearCacheRefreshBanner()
            }
        }
        do {
            FirstScreenMetrics.markListRequested()
 // P1.5-A: opt in to the plugin's lite projection trim (~1MB -> list
 // fields only). The plugin strips the hint before forwarding, so the
 // upstream DSH request is unchanged; old App builds send no signal
 // and keep the byte-identical full response.
            let value = try await link.unary(
                "session/list",
                args: SessionListLite.requestArgs(),
                timeout: 20,
                originOverride: originOverride
            )
            guard !Task.isCancelled, requestID == sessionListRequestID else { return }
 // cold-launch freeze (user report + Time Profiler): a cold start
 // fires an early pre-connect request and a post-connect reload. Both used
 // to decode + rebuild the list on the MainActor (JSONValue.decode is a
 // JSONEncoder+JSONDecoder double conversion — seconds on large lists), so
 // the whole UI froze for 3.5-5.5s right after launch. Skip an identical
 // second snapshot, and decode off-main.
            if networkApplied, lastSessionListJSON == value {
                coldStartDebug("list duplicate #\(requestID) skipped")
                return
            }
            let list = try await Self.decodeSessionListOffMain(value)
            guard !Task.isCancelled, requestID == sessionListRequestID else { return }
            let elapsedMs = lastListRequestStartedAt.map { Date().timeIntervalSince($0) * 1000 } ?? -1
            coldStartDebug("list applied #\(requestID) elapsedMs=\(Int(elapsedMs))")
            applyDecodedSessionListResponse(value, list: list)
        } catch {
            guard !Task.isCancelled, requestID == sessionListRequestID else { return }
            let elapsedMs = lastListRequestStartedAt.map { Date().timeIntervalSince($0) * 1000 } ?? -1
            coldStartDebug("list failed #\(requestID) elapsedMs=\(Int(elapsedMs)) err=\(NetworkErrorInterpreter.message(for: error))")
            if !silent, !link.phase.isBusy {
                errorText = NetworkErrorInterpreter.message(for: error)
            }
        }
    }

 /// Test seam: apply one raw `session/list` response (the unary result value).
 /// Keeps the raw wire JSON so the next cache write replays the exact same path.
    func applySessionListResponse(_ value: JSONValue) throws {
        let list = try value.decode(SessionListValue.self)
        applyDecodedSessionListResponse(value, list: list)
    }

 /// Off-main decode of a `session/list` payload.
 /// `JSONValue.decode` encodes to JSON and decodes again; running it on the
 /// MainActor froze the whole list page for seconds on cold start.
    nonisolated static func decodeSessionListOffMain(_ value: JSONValue) async throws -> SessionListValue {
        try await Task.detached(priority: .userInitiated) {
            try value.decode(SessionListValue.self)
        }.value
    }

 /// Applies an already-decoded `session/list` snapshot on the MainActor.
    private func applyDecodedSessionListResponse(_ value: JSONValue, list: SessionListValue) {
        lastSessionListJSON = value
        applySessions(list.items)
 // task-1：快照落地后若 follow 仍有未知 id（Host list work-slice 合并
 // 竞态），有界重试；正常情况这里为零成本空跑。
        noteListSnapshotApplied()
        errorText = nil
        lastLoadedAt = Date()
        lastNetworkListAppliedAt = Date()
        loadedFromCache = false
        cacheIsStale = false
 // Live list landed: retire the slow-refresh indicator and the stale retries.
        clearCacheRefreshBanner()
        cancelStaleListRetry()
 // The live snapshot is complete: the deferred raw cache restore is moot.
        needsDeferredRawRestore = false
        scheduleListCacheSave()
        if !networkApplied {
            networkApplied = true
            StartupMetrics.markNetworkApplied()
            startupMetricsValue = StartupMetrics.valueString
        }
 // P0-4 acceptance evidence: the live snapshot landed (may be *before*
 // `StartupMetrics.connMs` when the pre-connected request won).
        FirstScreenMetrics.markListApplied()
 // task-2: t1's second half for the page-enter/foreground reconnect chain.
        ReconnectMetrics.markListApplied()
    }

 // MARK: - task-2 reconnect chain (page enter / stale-socket liveness)

 /// Pure probe verdict: a reused mux that has not produced its first baseline
 /// within the budget, while the link still claims to be the same connected
 /// generation, is presumed dead.
    nonisolated static func shouldDeclareMuxDead(
        baselineApplied: Bool,
        elapsedMs: Double,
        thresholdMs: Double,
        stillConnected: Bool = true
    ) -> Bool {
        stillConnected && !baselineApplied && elapsedMs >= thresholdMs
    }

 // MARK: - T2(B1)：冷启动列表等 HTTPS 池预热

 /// 冷启动首屏列表等待预热的预算（handoff §3.2：≤350ms，超时直接走原路径）。
    static let poolWarmupWaitTimeoutMs = 350

 /// 是否该在发 early `session/list` 前先等冷启动 HTTPS 池预热。
 ///
 /// 只有「首份网络列表还没落地（冷启动）」+「预热任务在飞」两个条件同时成立才等，
 /// 保证热路径（已 applied / 预热已完成 / 从未预热）零额外延迟。
    nonisolated static func shouldAwaitPoolWarmup(
        networkApplied: Bool,
        warmupInFlight: Bool
    ) -> Bool {
        !networkApplied && warmupInFlight
    }

 /// Pure decision for the early snapshot: issue `session/list` while the mux is
 /// still coming up so the request overlaps the handshake (P0-4).
    nonisolated static func shouldStartEarlySnapshot(
        prefersEarlyUnary: Bool,
        hasCredentials: Bool,
        isConnected: Bool
    ) -> Bool {
        prefersEarlyUnary
            && canLoadSessionsBeforeConnected(hasCredentials: hasCredentials, isConnected: isConnected)
    }

 /// One speculative `session/list` per bring-up window, so repeated phase
 /// changes (connecting -> reconnecting) do not stack requests.
    private func startEarlySnapshotDuringBringup() {
        guard let link, !link.manuallyDisconnected else { return }
 // 冷启动 <1s：即使 `prefersEarlyUnary` 因「持久化 origin 是失效
 // LAN」为 false，只要有可达的 relay origin 覆盖，early list 仍然值得立刻发。
        let originOverride = link.earlyListOriginOverride()
        guard Self.shouldStartEarlySnapshot(
            prefersEarlyUnary: link.prefersEarlyUnary || originOverride != nil,
            hasCredentials: link.credentials != nil,
            isConnected: link.phase.isConnected
        ) else {
            coldStartDebug("early-list skipped gate prefersEarlyUnary=\(link.prefersEarlyUnary) override=\(originOverride?.absoluteString ?? "-")")
            return
        }
        if let last = lastEarlySnapshotAt, Date().timeIntervalSince(last) < 1.5 { return }
        lastEarlySnapshotAt = Date()
        coldStartDebug("early-list sent gate prefersEarlyUnary=\(link.prefersEarlyUnary) override=\(originOverride?.absoluteString ?? "-")")
        loadSessions(silent: true)
    }

 // MARK: - 冷启动 <1s：缓存刷新指示器 + stale 列表有界重试

 /// 纯策略：刷新耗时是否已达到显示指示器的阈值（默认 800ms）。
    nonisolated static func shouldShowCacheRefreshBanner(
        elapsedMs: Double,
        thresholdMs: Double = 800
    ) -> Bool {
        elapsedMs >= thresholdMs
    }

 /// `isRefreshing` 置真时调用：只有「缓存首帧 + 尚无 live 列表」才需要指示器，
 /// 且延迟到阈值后才真正显示（<1s 的刷新用户看不到任何「缓存刷新」文案）。
    private func armCacheRefreshBannerDelay() {
        guard loadedFromCache, !networkApplied else {
            clearCacheRefreshBanner()
            return
        }
        if showCacheRefreshBanner { return }
        cacheBannerDelayTask?.cancel()
        let threshold = Self.cacheRefreshBannerDelayMs
        cacheBannerDelayTask = Task { [weak self] in
            let startedAt = Date()
            try? await Task.sleep(nanoseconds: UInt64(threshold) * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.isRefreshing, self.loadedFromCache, !self.networkApplied else { return }
            let elapsed = Date().timeIntervalSince(startedAt) * 1000
            guard Self.shouldShowCacheRefreshBanner(elapsedMs: elapsed, thresholdMs: Double(threshold)) else { return }
            self.showCacheRefreshBanner = true
        }
    }

    private func clearCacheRefreshBanner() {
        cacheBannerDelayTask?.cancel()
        cacheBannerDelayTask = nil
        if showCacheRefreshBanner { showCacheRefreshBanner = false }
    }

 /// 首帧仍来自缓存时，对 live `session/list` 做有界重试。用户的真机现场是
 /// 「桌面端重启后首次启动」：连接轮次重试了约 13s，而 live 列表请求只在连上后才
 /// 重发一次，于是「正在刷新」持续 10s+。这里在 bring-up 窗口内每 0.4–5s 重试一次
 /// （串行、不打断在飞请求），live 列表一落地即停止。
    private func armStaleListRetry() {
        staleListRetryTask?.cancel()
        guard loadedFromCache, !networkApplied, link?.credentials != nil else { return }
        staleListRetryTask = Task { [weak self] in
            for delayMs in Self.staleListRetryDelaysMs {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.networkApplied || !self.loadedFromCache { return }
                guard self.link?.credentials != nil else { return }
 // A request already in flight is normally left alone; if it has been
 // hanging for >1.2s (first launch after a desktop restart), issue a
 // newer request in parallel — its higher request id wins and the
 // stale one is discarded, so the banner cannot sit for its 20s timeout.
                if self.isRefreshing {
                    let inFlightMs = self.lastListRequestStartedAt.map { Date().timeIntervalSince($0) * 1000 } ?? .infinity
                    guard inFlightMs > 1_200 else { continue }
                    self.coldStartDebug("stale-retry supersede inFlightMs=\(Int(inFlightMs))")
                }
                await self.loadSessionsNow(silent: true)
                if self.networkApplied { return }
            }
        }
    }

    private func cancelStaleListRetry() {
        staleListRetryTask?.cancel()
        staleListRetryTask = nil
    }

 /// Arms the reused-mux first-byte probe described by `reuseBaselineTimeoutMs`.
 /// Only the reuse paths (page enter / foreground resume on a believed-alive
 /// mux) call this: a freshly connected socket has no reason to be suspect.
    private func armReuseLivenessProbe() {
        guard let link, link.phase.isConnected else { return }
        baselineProbeTask?.cancel()
        baselineProbeGeneration += 1
        let token = baselineProbeGeneration
        let linkGeneration = link.generation
        let thresholdMs = Self.reuseBaselineTimeoutMs
        let threshold = Double(thresholdMs) / 1000
        baselineProbeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(threshold * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
 // A baseline frame (or a newer stream open) retires this probe.
            let baselineApplied = token != self.baselineProbeGeneration
            guard let link = self.link else { return }
            let stillConnected = link.phase.isConnected && link.generation == linkGeneration
            guard Self.shouldDeclareMuxDead(
                baselineApplied: baselineApplied,
                elapsedMs: Double(thresholdMs),
                thresholdMs: Double(thresholdMs),
                stillConnected: stillConnected
            ) else { return }
            link.noteTransportUnresponsive(source: "workspaceBaseline")
        }
    }

    private func cancelReuseLivenessProbe() {
        baselineProbeTask?.cancel()
        baselineProbeTask = nil
        baselineProbeGeneration += 1
    }

 // MARK: - M2b-2b in-app timing + detail prewarm

 /// Called from the first session card's `onAppear`: the list's first visible
 /// content. Marks the in-app metric and kicks off the low-priority prewarm.
    func markFirstFrameVisible() {
        guard !firstFrameRendered else { return }
        firstFrameRendered = true
        StartupMetrics.markFirstFrame()
 // P0-4 acceptance evidence: in-app first paint of the list (cache or live).
        FirstScreenMetrics.markFirstPaint()
        startupMetricsValue = StartupMetrics.valueString
 // The first frame is on screen: now spend a background thread on the raw
 // decode (deep links / full projections). Network refresh supersedes it.
        startDeferredRawRestoreIfNeeded()
        maybeStartPrewarm()
    }

 /// Test seam: prewarm order. The first cards the user sees come first — the
 /// pinned area (when non-empty) sits above every group, then the first group's
 /// first card, then the rest by recency.
    func prewarmCandidates(limit: Int) -> [SessionWindowPrewarmer.Candidate] {
        guard limit > 0 else { return [] }
        var candidates: [SessionWindowPrewarmer.Candidate] = []
        var seen = Set<String>()
 // code review P3: pinned rows no longer live in `groups`, so
 // without this the very first card on screen (pinned[0]) was never warmed.
        for session in pinnedSessions {
            guard candidates.count < limit else { break }
            guard seen.insert(session.sessionId).inserted else { continue }
            candidates.append(
                SessionWindowPrewarmer.Candidate(sessionId: session.sessionId, address: session.followAddress)
            )
        }
        for group in groups {
            guard candidates.count < limit else { break }
            guard let first = group.sessions.first else { continue }
            guard seen.insert(first.sessionId).inserted else { continue }
            candidates.append(
                SessionWindowPrewarmer.Candidate(sessionId: first.sessionId, address: first.followAddress)
            )
            break
        }
        let rows: [(SessionListItem, Int64)] = groups.flatMap { group in
            group.sessions.map { ($0, Self.activity(of: $0)) }
        }
        let ordered = rows.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.sessionId < rhs.0.sessionId
        }
        for row in ordered {
            guard candidates.count < limit else { break }
            guard seen.insert(row.0.sessionId).inserted else { continue }
            candidates.append(
                SessionWindowPrewarmer.Candidate(sessionId: row.0.sessionId, address: row.0.followAddress)
            )
        }
        return candidates
    }

    private func maybeStartPrewarm() {
        guard prewarmLimit > 0 else { return }
        guard let link, link.phase.isConnected else { return }
 // The list can be reordered by a live `session/list`/`workspace/follow`
 // refresh after the cached first frame, and the card the user taps is
 // whatever is first *now*. Start (or queue) a prewarm for the new order,
 // but never cancel an in-flight fetch: on cellular the first window of the
 // tapped card can be a second away, and a cancel/restart right before the
 // tap was losing that work.
        let candidates = prewarmCandidates(limit: prewarmLimit)
        guard !candidates.isEmpty else { return }
        let signature = candidates.map(\.sessionId).joined(separator: ",")
        guard signature != prewarmSignature else {
            pendingPrewarmSignature = nil
            return
        }
        guard !prewarmer.isRunning else {
            pendingPrewarmSignature = signature
            return
        }
        startPrewarm(candidates: candidates, signature: signature, link: link)
    }

    private func startPrewarm(
        candidates: [SessionWindowPrewarmer.Candidate],
        signature: String,
        link: LinkService
    ) {
        pendingPrewarmSignature = nil
        prewarmSignature = signature
        prewarmStartCount += 1
        prewarmStarted = true
        let top = candidates[0].sessionId
        updatePrewarmMetrics(top: top, saved: [])
        prewarmer.start(
            candidates: candidates,
            onSaved: { [weak self] _ in
                guard let self else { return }
                self.updatePrewarmMetrics(top: top, saved: self.prewarmer.prewarmedSessionIds)
            },
            onFinished: { [weak self] in
                guard let self, self.pendingPrewarmSignature != nil else { return }
                self.maybeStartPrewarm()
            },
            openFirstWindow: Self.prewarmStreamOpener(link: link)
        )
    }

    private func updatePrewarmMetrics(top: String, saved: [String]) {
        guard StartupMetrics.isEnabled else { return }
        prewarmMetricsValue = "starts=\(prewarmStartCount);top=\(top);saved=\(saved.joined(separator: ","))"
    }

 /// Opens one `session/follow` stream and reports only the first snapshot item
 /// (the window written to the cache); live stream deltas are disabled.
 ///
 /// P1.5-B: the prewarm asks for the same phone-sized window the detail's first
 /// open asks for (`SessionWindowPolicy`), so a warm cache is a complete first
 /// frame *and* it lands much sooner after the list appears (a 0.72MB prewarm
 /// was still in flight when the bench tapped the first card).
    private static func prewarmStreamOpener(link: LinkService) -> SessionWindowPrewarmer.OpenFirstWindow {
        { candidate, onSnapshot, onFinish in
            let args: [String: JSONValue] = [
                "request": .object([
                    "address": candidate.address.jsonValue,
                    "assistantStream": .bool(false),
                    "maxMessages": .int(Int64(SessionWindowPolicy.devicePrewarmMessages)),
                ]),
            ]
            do {
                let stream = try link.openStream(
                    endpoint: "session/follow",
                    args: args,
                    onItem: { value in
                        guard let value,
                              let frame = try? SessionStreamFrame.decode(value),
                              case .snapshot = frame else { return }
                        Task { @MainActor in onSnapshot(value) }
                    },
                    onEnd: { Task { @MainActor in onFinish() } },
                    onError: { _ in Task { @MainActor in onFinish() } },
                    onClose: { _, _ in Task { @MainActor in onFinish() } }
                )
                return { stream.cancel() }
            } catch {
                return nil
            }
        }
    }

 /// Prewarm budget: env-tunable for the live bench (`DSHM_PREWARM_COUNT=0` disables
 /// it) so prewarm traffic cannot pollute the list→detail measurement.
    static func prewarmLimitFromEnvironment() -> Int {
        guard let raw = ProcessInfo.processInfo.environment["DSHM_PREWARM_COUNT"],
              let value = Int(raw) else { return 8 }
        return min(max(value, 0), 20)
    }

 /// Test seam: apply one `session/list` snapshot.
    func applySessions(_ items: [SessionListItem]) {
        rememberSnapshotRunning(items)
 // v6：列表快照落地后叠加 `$events` 的实时运行态，避免「请求在 emit 之前、
 // 回包在 emit 之后」把刚变进行中的卡片打回旧状态。
        let merged = Self.overlayLiveRunning(
            items,
            live: link?.liveSessionRunning ?? [:],
            liveUpdatedAt: link?.liveSessionRunningUpdatedAt ?? [:]
        )
        installSessions(merged)
    }

 /// Records the pristine running flags of a network snapshot (before any live
 /// overlay) so the overlay can be reverted later.
    private func rememberSnapshotRunning(_ items: [SessionListItem]) {
        var map: [String: Bool] = [:]
        map.reserveCapacity(items.count)
 // `running` 是可选字段：快照省略时按「未运行」记（nil 与 false 展示等价），
 // 这样清空 live map 后所有会话都能回退，不会因 nil 丢键而残留 overlay。
        for item in items { map[item.sessionId] = item.running ?? false }
        snapshotRunningById = map
    }

 /// Publishes an already-overlaid session list (assignments + group rebuild).
    private func installSessions(_ items: [SessionListItem]) {
        allSessions = items
        var byId: [String: SessionListItem] = [:]
        byId.reserveCapacity(items.count)
        for item in items {
            byId[item.sessionId] = item
        }
        sessionsById = byId
        sessionsLoaded = true
        isLoading = false
        sessionsSnapshotVersion += 1
        rebuildGroups()
        maybeStartPrewarm()
    }

 /// live 运行态覆盖快照的最大年龄（秒）。
 ///
 /// emit 的唯一职责是补「`session/list` 请求在途、emit 先到、旧回包后到」的
 /// 短暂竞态窗；超出该窗口后 `session/list` 快照才是网络真值。这样即使某条
 /// `running=false` emit 丢失（后台/断连/流丢失），错误状态也最多残留一个窗口，
 /// 而不会在重连后无限期覆盖新快照。
    static let liveRunningOverlayMaxAge: TimeInterval = 30

 /// 纯函数：把 live 运行态叠加到列表行上（可单测，不依赖 LinkService）。
 /// - Parameters:
 /// - liveUpdatedAt: 每条 emit 的落库时间；缺时间戳的条目按新鲜处理（兼容旧调用）。
    static func overlayLiveRunning(
        _ items: [SessionListItem],
        live: [String: Bool],
        liveUpdatedAt: [String: Date] = [:],
        now: Date = Date(),
        maxAge: TimeInterval = liveRunningOverlayMaxAge
    ) -> [SessionListItem] {
        guard !live.isEmpty else { return items }
        var changed = false
        let result = items.map { item -> SessionListItem in
            guard let running = live[item.sessionId], item.running != running else { return item }
            if let updatedAt = liveUpdatedAt[item.sessionId],
               now.timeIntervalSince(updatedAt) > maxAge {
                return item
            }
            var copy = item
            copy.running = running
            changed = true
            return copy
        }
        return changed ? result : items
    }

 /// `$events` 运行态变化：不重新拉列表，直接就地更新卡片并重排（running 置顶）。
    func applyLiveSessionRunning() {
        guard let link else { return }
        applyLiveSessionRunning(
            live: link.liveSessionRunning,
            liveUpdatedAt: link.liveSessionRunningUpdatedAt
        )
    }

 /// Re-derives the list running flags from the pristine snapshot + the current
 /// live map (test seam, no LinkService dependency).
 ///
 /// Every entry first falls back to its network-snapshot value, then fresh live
 /// emits are applied on top. This makes an emptied/stale live map self-healing:
 /// clearing it (full teardown / `$events` stream loss) reverts cards that were
 /// previously overlaid, instead of leaving them stuck in 「进行中」.
    func applyLiveSessionRunning(live: [String: Bool], liveUpdatedAt: [String: Date]) {
        guard sessionsLoaded else { return }
        let now = Date()
        var changed = false
        let merged = allSessions.map { item -> SessionListItem in
            var target = snapshotRunningById[item.sessionId] ?? item.running
            if let running = live[item.sessionId] {
                let fresh = liveUpdatedAt[item.sessionId].map {
                    now.timeIntervalSince($0) <= Self.liveRunningOverlayMaxAge
                } ?? true
                if fresh { target = running }
            }
            guard target != item.running else { return item }
            var copy = item
            copy.running = target
            changed = true
            return copy
        }
        guard changed else { return }
        installSessions(merged)
    }

    private func rebuildGroups() {
        let archived = followState.archivedSessionIds
        let pinnedRank = Dictionary(
            followState.pinnedSessionIds.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
 // v6.1: a phone-created draft card must sit at the
 // top of its workspace group, exactly like the DSH desktop sidebar. The
 // Host reuses an existing empty session for "+" (so its server-side
 // updatedAt can be days old) — recency alone therefore ranks a brand-new
 // draft far down the list, sometimes a full screen below the fold.
        let draftBlankIds = Set(phoneCreatedBlanks.filter { DraftStore.shared.hasDraft($0) })
        let comparator = Self.sessionComparator(pinnedRank: pinnedRank, draftBlankIds: draftBlankIds)

        var rebuilt: [WorkspaceGroup] = []
        rebuilt.reserveCapacity(followState.workspaces.count)
        var visibleAll: [SessionListItem] = []
        for workspace in followState.workspaces {
            var sessions: [SessionListItem] = []
            sessions.reserveCapacity(workspace.sessionIds.count)
            for sessionId in workspace.sessionIds {
                guard let session = sessionsById[sessionId],
                      Self.isVisible(
                        session,
                        archivedSessionIds: archived,
                        phoneCreatedBlanks: phoneCreatedBlanks,
                        hasDraft: { DraftStore.shared.hasDraft($0) }
                      ) else { continue }
                sessions.append(session)
            }
            sessions.sort(by: comparator)
            visibleAll.append(contentsOf: sessions)
            sessions.removeAll { pinnedRank[$0.sessionId] != nil }

            let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
            rebuilt.append(
                WorkspaceGroup(
                    workspaceId: workspace.workspaceId,
                    path: workspace.path,
                    title: workspace.title,
                    sessions: sessions,
                    displayName: title.isEmpty ? Self.displayName(for: workspace.path) : title
                )
            )
        }
 // Pinned sessions leave their workspace group and are rendered once,
 // above every group. Most recent pin first.
        let pinned = visibleAll
            .filter { pinnedRank[$0.sessionId] != nil }
            .sorted { lhs, rhs in
                let leftRank = pinnedRank[lhs.sessionId] ?? Int.max
                let rightRank = pinnedRank[rhs.sessionId] ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                let leftTime = Self.activity(of: lhs)
                let rightTime = Self.activity(of: rhs)
                if leftTime != rightTime { return leftTime > rightTime }
                return lhs.sessionId < rhs.sessionId
            }

 // Diff guard: a refresh that yields identical content must not publish a new
 // array (no list flash / scroll jump, and the auto-open hook stays silent).
        if pinned != pinnedSessions {
            pinnedSessions = pinned
            groupsVersion += 1
        }
        if rebuilt != groups {
            groups = rebuilt
            groupsVersion += 1
        }
        sessionCount = visibleAll.count
    }

 // MARK: - Visibility & ordering (shared with unit tests)

 /// Desktop-sidebar visibility rule on top of registry membership, plus the
 /// R2 phone-created blank release (design 2.3): a blank session is visible
 /// only when this phone minted it through the plus button AND a draft
 /// exists - the card disappears the moment the draft is gone or the session
 /// is archived.
    static func isVisible(
        _ session: SessionListItem,
        archivedSessionIds: Set<String>,
        phoneCreatedBlanks: Set<String> = [],
        hasDraft: (String) -> Bool = { _ in false }
    ) -> Bool {
        if session.isSubagent { return false }
        if archivedSessionIds.contains(session.sessionId) { return false }
        if session.blank == true {
            return phoneCreatedBlanks.contains(session.sessionId) && hasDraft(session.sessionId)
        }
        return true
    }

 /// Sort order inside one workspace: running first, then pinned (most recently
 /// pinned first), then the phone-created draft cards (desktop parity: a brand
 /// new draft stays at the top of its group until it sends its first message),
 /// then by last activity; sessionId keeps ties deterministic.
    static func sessionComparator(
        pinnedRank: [String: Int],
        draftBlankIds: Set<String> = []
    ) -> (SessionListItem, SessionListItem) -> Bool {
        { lhs, rhs in
            let leftRank = sessionRank(lhs, pinnedRank: pinnedRank, draftBlankIds: draftBlankIds)
            let rightRank = sessionRank(rhs, pinnedRank: pinnedRank, draftBlankIds: draftBlankIds)
            if leftRank != rightRank { return leftRank < rightRank }
            if leftRank == 1 {
                let leftPin = pinnedRank[lhs.sessionId] ?? Int.max
                let rightPin = pinnedRank[rhs.sessionId] ?? Int.max
                if leftPin != rightPin { return leftPin < rightPin }
            }
            let leftTime = activity(of: lhs)
            let rightTime = activity(of: rhs)
            if leftTime != rightTime { return leftTime > rightTime }
            return lhs.sessionId < rhs.sessionId
        }
    }

    static func sessionRank(
        _ session: SessionListItem,
        pinnedRank: [String: Int],
        draftBlankIds: Set<String> = []
    ) -> Int {
        if session.isRunning { return 0 }
        if pinnedRank[session.sessionId] != nil { return 1 }
        if draftBlankIds.contains(session.sessionId) { return 2 }
        return 3
    }

    static func activity(of item: SessionListItem) -> Int64 {
        item.lastPromptAt ?? item.updatedAt ?? 0
    }

    static func displayName(for path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if let last = trimmed.split(separator: "/").last, !last.isEmpty { return String(last) }
        return path
    }

 // MARK: - Collapse state (persisted per workspace path)

    func isCollapsed(_ path: String) -> Bool {
        collapsedPaths.contains(path)
    }

    func toggleCollapsed(_ path: String) {
        if collapsedPaths.contains(path) {
            collapsedPaths.remove(path)
        } else {
            collapsedPaths.insert(path)
        }
        defaults.set(collapsedPaths.sorted(), forKey: Self.collapsedPathsKey)
    }

    func pendingApprovalCount(sessionId: String, link: LinkService) -> Int {
        link.pendingApprovals.filter { $0.agentId == sessionId }.count
    }
}
