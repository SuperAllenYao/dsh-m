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

 /// Every session from the last `session/list`, including subagent/blank/
 /// archived/ungrouped rows. Kept for deep-link address resolution only.
    private(set) var allSessions: [SessionListItem] = []
    private(set) var followState = WorkspaceFollowState()

    private var sessionsById: [String: SessionListItem] = [:]
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

    init(
        defaults: UserDefaults = .standard,
        cacheStore: SessionListCacheStore = SessionListCacheStore()
    ) {
        self.defaults = defaults
        self.cacheStore = cacheStore
        self.prewarmLimit = Self.prewarmLimitFromEnvironment()
        collapsedPaths = Set(defaults.stringArray(forKey: Self.collapsedPathsKey) ?? [])
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
            groups = render.payload.groups.map(Self.workspaceGroup(from:))
            sessionCount = groups.reduce(0) { $0 + $1.sessions.count }
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
            self.applyDeferredRawCache(loaded)
        }
    }

    private func applyDeferredRawCache(_ cached: SessionListCacheStore.Loaded) {
        deferredRawRestoreTask = nil
 // A live network snapshot already landed with fresher data: keep it.
        guard !sessionsLoaded else { return }
        guard let list = cached.payload.sessionList,
              let value = try? list.decode(SessionListValue.self) else { return }
        lastSessionListJSON = list
        sessionsLoaded = true
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
        cacheStore.saveRenderSnapshot(groups: renderGroups(), followBaseline: follow)
    }

 /// M2b-2b: the raw encode (~1MB) and compact write are pure value-type work —
 /// hand them to a utility queue so a refresh never janks the visible list.
    private func saveListCacheInBackground() {
        guard sessionsLoaded, let sessionList = lastSessionListJSON else { return }
        let follow = followBaselineJSON()
        let render = renderGroups()
        let store = cacheStore
        Task.detached(priority: .utility) {
            store.save(sessionList: sessionList, followBaseline: follow)
            store.saveRenderSnapshot(groups: render, followBaseline: follow)
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
        workspaceStream?.cancel()
        workspaceStream = nil
        loadTask?.cancel()
        loadTask = nil
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
        followState.apply(frame)
        if case .baseline = frame {
            isLoading = false
 // task-2: the reused mux delivered its first byte within budget.
            cancelReuseLivenessProbe()
        }
        errorText = nil
        rebuildGroups()
        maybeStartPrewarm()
        scheduleListCacheSave()
    }

 /// Loads the live `session/list` snapshot. `silent` suppresses the error
 /// banner for speculative requests issued while the link is still coming up
 /// (P0-4/P0-5): those either land (and paint the list early) or are superseded
 /// by the `.connected` reload, so a transient failure is not user-actionable.
    private func loadSessions(silent: Bool = false) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadSessionsNow(silent: silent)
        }
    }

    private func loadSessionsNow(silent: Bool = false) async {
        guard let link, link.credentials != nil else { return }
 // P0-4: every request gets an id; a superseded response (cancelled task or
 // the early pre-`connected` request losing the race) is dropped instead of
 // overwriting a newer snapshot.
        sessionListRequestID += 1
        let requestID = sessionListRequestID
        isRefreshing = true
        defer {
            if requestID == sessionListRequestID {
                isRefreshing = false
                loadTask = nil
            }
        }
        do {
            FirstScreenMetrics.markListRequested()
 // P1.5-A: opt in to the plugin's lite projection trim (~1MB -> list
 // fields only). The plugin strips the hint before forwarding, so the
 // upstream DSH request is unchanged; old App builds send no signal
 // and keep the byte-identical full response.
            let value = try await link.unary("session/list", args: SessionListLite.requestArgs(), timeout: 20)
            guard !Task.isCancelled, requestID == sessionListRequestID else { return }
            try applySessionListResponse(value)
        } catch {
            guard !Task.isCancelled, requestID == sessionListRequestID else { return }
            if !silent, !link.phase.isBusy {
                errorText = NetworkErrorInterpreter.message(for: error)
            }
        }
    }

 /// Test seam: apply one raw `session/list` response (the unary result value).
 /// Keeps the raw wire JSON so the next cache write replays the exact same path.
    func applySessionListResponse(_ value: JSONValue) throws {
        let list = try value.decode(SessionListValue.self)
        lastSessionListJSON = value
        applySessions(list.items)
        errorText = nil
        lastLoadedAt = Date()
        lastNetworkListAppliedAt = Date()
        loadedFromCache = false
        cacheIsStale = false
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
        guard Self.shouldStartEarlySnapshot(
            prefersEarlyUnary: link.prefersEarlyUnary,
            hasCredentials: link.credentials != nil,
            isConnected: link.phase.isConnected
        ) else { return }
        if let last = lastEarlySnapshotAt, Date().timeIntervalSince(last) < 1.5 { return }
        lastEarlySnapshotAt = Date()
        loadSessions(silent: true)
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

 /// Test seam: prewarm order. The list's first visible card comes first (that is
 /// what the user — and the live bench — taps first), then the rest by recency.
    func prewarmCandidates(limit: Int) -> [SessionWindowPrewarmer.Candidate] {
        guard limit > 0 else { return [] }
        var candidates: [SessionWindowPrewarmer.Candidate] = []
        var seen = Set<String>()
        for group in groups {
            guard let first = group.sessions.first else { continue }
            seen.insert(first.sessionId)
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
        allSessions = items
        var byId: [String: SessionListItem] = [:]
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

    private func rebuildGroups() {
        let archived = followState.archivedSessionIds
        let pinnedRank = Dictionary(
            followState.pinnedSessionIds.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let comparator = Self.sessionComparator(pinnedRank: pinnedRank)

        var rebuilt: [WorkspaceGroup] = []
        rebuilt.reserveCapacity(followState.workspaces.count)
        var count = 0
        for workspace in followState.workspaces {
            var sessions: [SessionListItem] = []
            sessions.reserveCapacity(workspace.sessionIds.count)
            for sessionId in workspace.sessionIds {
                guard let session = sessionsById[sessionId],
                      Self.isVisible(session, archivedSessionIds: archived) else { continue }
                sessions.append(session)
            }
            sessions.sort(by: comparator)
            count += sessions.count

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
 // Diff guard: a refresh that yields identical content must not publish a new
 // array (no list flash / scroll jump, and the auto-open hook stays silent).
        if rebuilt != groups {
            groups = rebuilt
            groupsVersion += 1
        }
        sessionCount = count
    }

 // MARK: - Visibility & ordering (shared with unit tests)

 /// Desktop-sidebar visibility rule on top of registry membership.
    static func isVisible(_ session: SessionListItem, archivedSessionIds: Set<String>) -> Bool {
        if session.isSubagent { return false }
        if session.blank == true { return false }
        if archivedSessionIds.contains(session.sessionId) { return false }
        return true
    }

 /// Sort order inside one workspace: running first, then pinned (most recently
 /// pinned first), then by last activity; sessionId keeps ties deterministic.
    static func sessionComparator(pinnedRank: [String: Int]) -> (SessionListItem, SessionListItem) -> Bool {
        { lhs, rhs in
            let leftRank = sessionRank(lhs, pinnedRank: pinnedRank)
            let rightRank = sessionRank(rhs, pinnedRank: pinnedRank)
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

    static func sessionRank(_ session: SessionListItem, pinnedRank: [String: Int]) -> Int {
        if session.isRunning { return 0 }
        if pinnedRank[session.sessionId] != nil { return 1 }
        return 2
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
