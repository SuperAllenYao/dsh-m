import XCTest
@testable import DSHm

/// Covers the desktop-1:1 workspace list (task-7): projects and session membership
/// come from `workspace/follow`, visibility matches the desktop sidebar
/// (`sessionVisible()`), and ordering is running → pinned → activity.
final class WorkspaceViewModelTests: XCTestCase {

    // MARK: - Fixtures

    private func session(
        _ sessionId: String,
        cwd: String = "/ws/a",
        updatedAt: Int64 = 0,
        running: Bool = false,
        blank: Bool? = false,
        origin: String? = nil,
        parentSessionId: String? = nil
    ) -> SessionListItem {
        SessionListItem(
            sessionId: sessionId,
            updatedAt: updatedAt,
            running: running,
            blank: blank,
            cwd: cwd,
            origin: origin,
            parentSessionId: parentSessionId
        )
    }

    private func workspace(
        _ workspaceId: String,
        path: String = "/ws/\(UUID().uuidString)",
        title: String = "Workspace",
        sessionIds: [String] = []
    ) -> WorkspaceDescriptor {
        WorkspaceDescriptor(workspaceId: workspaceId, path: path, title: title, sessionIds: sessionIds)
    }

    private func baseline(
        _ workspaces: [WorkspaceDescriptor],
        archived: [String] = [],
        pinned: [String] = []
    ) -> WorkspaceFollowFrame {
        .baseline(WorkspaceFollowSnapshot(items: workspaces, archivedSessionIds: archived, pinnedSessionIds: pinned))
    }

    private func frame(_ json: String) throws -> WorkspaceFollowFrame {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return try value.decode(WorkspaceFollowFrame.self)
    }

    /// M2b-2: isolated cache directory so tests never read or write the app cache.
    private func makeCacheStore() -> SessionListCacheStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceViewModelTests-cache-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return SessionListCacheStore(directory: directory, identity: { "workspace-tests" })
    }

    @MainActor
    private func makeViewModel() -> (WorkspaceViewModel, UserDefaults, String) {
        let suite = "WorkspaceViewModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (WorkspaceViewModel(defaults: defaults, cacheStore: makeCacheStore()), defaults, suite)
    }

    // MARK: - workspace/follow frame decoding (protocol §3.13/§5)

    func testBaselineAndIncrementalFramesDecode() throws {
        let baselineFrame = try frame("""
        {"type":"baseline","value":{"items":[
          {"workspaceId":"w1","path":"/ws/a","title":"A","sessionIds":["s1","s2"],"createdAt":"2026-10-01T00:00:00.000Z","updatedAt":"2026-10-02T00:00:00.000Z"}
        ],"archivedSessionIds":["s9"],"pinnedSessionIds":["s2"]}}
        """)
        guard case .baseline(let snapshot) = baselineFrame else {
            return XCTFail("expected baseline frame")
        }
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].workspaceId, "w1")
        XCTAssertEqual(snapshot.items[0].path, "/ws/a")
        XCTAssertEqual(snapshot.items[0].title, "A")
        XCTAssertEqual(snapshot.items[0].sessionIds, ["s1", "s2"])
        XCTAssertEqual(snapshot.archivedSessionIds, ["s9"])
        XCTAssertEqual(snapshot.pinnedSessionIds, ["s2"])

        let replace = try frame("""
        {"type":"replace","value":{"items":[],"archivedSessionIds":[],"pinnedSessionIds":[]}}
        """)
        if case .replace = replace {} else { XCTFail("expected replace frame") }

        let upsert = try frame("""
        {"type":"upsert","workspace":{"workspaceId":"w2","path":"/ws/b","title":"B","sessionIds":["s3"],"createdAt":"x","updatedAt":"y"}}
        """)
        guard case .upsert(let workspace) = upsert else { return XCTFail("expected upsert frame") }
        XCTAssertEqual(workspace.workspaceId, "w2")
        XCTAssertEqual(workspace.sessionIds, ["s3"])

        guard case .remove(let removed) = try frame(#"{"type":"remove","workspaceId":"w1"}"#) else {
            return XCTFail("expected remove frame")
        }
        XCTAssertEqual(removed, "w1")

        guard case .order(let ids) = try frame(#"{"type":"order","workspaceIds":["w2","w1"]}"#) else {
            return XCTFail("expected order frame")
        }
        XCTAssertEqual(ids, ["w2", "w1"])

        guard case .archived(let archived) = try frame(#"{"type":"archived","archivedSessionIds":["s1"]}"#) else {
            return XCTFail("expected archived frame")
        }
        XCTAssertEqual(archived, ["s1"])

        guard case .pinned(let pinned) = try frame(#"{"type":"pinned","pinnedSessionIds":["s2","s1"]}"#) else {
            return XCTFail("expected pinned frame")
        }
        XCTAssertEqual(pinned, ["s2", "s1"])

        guard case .unknown(let type) = try frame(#"{"type":"some-future-frame"}"#) else {
            return XCTFail("unknown frame types must be tolerated")
        }
        XCTAssertEqual(type, "some-future-frame")
    }

    // MARK: - Visibility (desktop sessionVisible parity)

    @MainActor
    func testVisibilityFiltersSubagentBlankArchived() {
        let (viewModel, defaults, suite) = makeViewModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        viewModel.applyWorkspaceFrame(baseline(
            [workspace("w1", sessionIds: ["visible", "subagent", "blank", "archived"])],
            archived: ["archived"]
        ))
        viewModel.applySessions([
            session("visible", updatedAt: 10),
            session("subagent", updatedAt: 90, origin: "subagent", parentSessionId: "parent"),
            session("blank", updatedAt: 91, blank: true),
            session("archived", updatedAt: 92),
        ])

        XCTAssertEqual(viewModel.groups.count, 1)
        XCTAssertEqual(viewModel.groups[0].sessions.map(\.sessionId), ["visible"])
        XCTAssertEqual(viewModel.sessionCount, 1)
        // The full snapshot is still kept for notification deep links.
        XCTAssertEqual(viewModel.allSessions.count, 4)
    }

    @MainActor
    func testUngroupedSessionsNeverShown() {
        let (viewModel, defaults, suite) = makeViewModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        viewModel.applyWorkspaceFrame(baseline([workspace("w1", sessionIds: ["s1", "s2"])]))
        viewModel.applySessions([
            session("s1", updatedAt: 10),
            session("s2", updatedAt: 20),
            // Old cwd-inferred groups (e.g. /private/tmp, dchat-workplace) must not
            // appear: the phone list is 1:1 with the desktop registry.
            session("ungrouped-1", cwd: "/private/tmp/dshm-poc/ws", updatedAt: 999),
            session("ungrouped-2", cwd: "/Users/example/Documents/deepseek-harness-default-workspace", updatedAt: 998),
        ])

        XCTAssertEqual(viewModel.groups.count, 1)
        XCTAssertEqual(viewModel.groups[0].sessions.map(\.sessionId), ["s2", "s1"])
        XCTAssertEqual(viewModel.sessionCount, 2)
        XCTAssertFalse(viewModel.groups.contains { $0.path.contains("tmp") })
    }

    // MARK: - Grouping, empty workspaces, count

    @MainActor
    func testWorkspaceOrderAndEmptyGroupsPreserved() {
        let (viewModel, defaults, suite) = makeViewModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        viewModel.applyWorkspaceFrame(baseline([
            workspace("w1", path: "/ws/one", title: "One"),
            workspace("w2", path: "/ws/two", title: "Empty project", sessionIds: []),
            workspace("w3", path: "/ws/three", title: "", sessionIds: ["s3"]),
        ]))
        viewModel.applySessions([session("s3", updatedAt: 5)])

        XCTAssertEqual(viewModel.groups.map(\.workspaceId), ["w1", "w2", "w3"], "registry order is preserved")
        XCTAssertEqual(viewModel.groups[1].sessions.count, 0, "empty workspaces keep their header")
        XCTAssertEqual(viewModel.groups[2].displayName, "three", "missing title falls back to the path name")
        XCTAssertEqual(viewModel.sessionCount, 1)
    }

    @MainActor
    func testVisibleCountMatchesDesktopExpectation() {
        let (viewModel, defaults, suite) = makeViewModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Mirrors the real desktop: ctx-kit 9 visible (17 raw: 7 blank, 1 archived,
        // 1 subagent after filtering), sqlxjl 1 (3 raw, 2 blank), dsh-m 2 (3 raw,
        // one subagent), plus ungrouped noise.
        let ctxKitIds = (0..<17).map { "ctx-\($0)" }
        let sqlxjlIds = (0..<3).map { "sql-\($0)" }
        let dshmIds = (0..<3).map { "dshm-\($0)" }

        viewModel.applyWorkspaceFrame(baseline(
            [
                workspace("w-ctx-kit", path: "/Users/example/myProject/ctx-kit", title: "ctx-kit", sessionIds: ctxKitIds),
                workspace("w-sqlxjl", path: "/Users/example/dchat-workplace/sqlxjl", title: "sqlxjl", sessionIds: sqlxjlIds),
                workspace("w-dsh-m", path: "/Users/example/myProject/dsh-m", title: "dsh-m", sessionIds: dshmIds),
            ],
            archived: ["ctx-15"],
            pinned: ["ctx-1"]
        ))

        var sessions: [SessionListItem] = []
        for index in 0..<17 {
            let isSubagent = index == 16
            let isBlank = index >= 9 && index <= 14
            sessions.append(session(
                "ctx-\(index)",
                updatedAt: Int64(index),
                blank: isBlank,
                origin: isSubagent ? "subagent" : nil,
                parentSessionId: isSubagent ? "parent" : nil
            ))
        }
        sessions.append(session("sql-0", updatedAt: 1))
        sessions.append(session("sql-1", updatedAt: 2, blank: true))
        sessions.append(session("sql-2", updatedAt: 3, blank: true))
        sessions.append(session("dshm-0", updatedAt: 4))
        sessions.append(session("dshm-1", updatedAt: 5))
        sessions.append(session("dshm-2", updatedAt: 6, origin: "subagent", parentSessionId: "parent"))
        sessions.append(session("orphan-tmp", cwd: "/private/tmp/x", updatedAt: 999))
        viewModel.applySessions(sessions)

        XCTAssertEqual(viewModel.groups.count, 3)
        XCTAssertEqual(viewModel.groups.map(\.sessions.count), [9, 1, 2])
        XCTAssertEqual(viewModel.sessionCount, 12, "desktop expectation: 3 workspaces · 12 sessions")
    }

    // MARK: - Ordering: running → pinned → activity

    @MainActor
    func testRunningThenPinnedThenActivityOrdering() {
        let (viewModel, defaults, suite) = makeViewModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        viewModel.applyWorkspaceFrame(baseline(
            [workspace("w1", sessionIds: ["idle-old", "pinned", "running-old", "idle-new", "running-new"])],
            pinned: ["pinned"]
        ))
        viewModel.applySessions([
            session("running-old", updatedAt: 100, running: true),
            session("pinned", updatedAt: 200),
            session("idle-new", updatedAt: 500),
            session("idle-old", updatedAt: 50),
            session("running-new", updatedAt: 400, running: true),
        ])

        XCTAssertEqual(
            viewModel.groups[0].sessions.map(\.sessionId),
            ["running-new", "running-old", "pinned", "idle-new", "idle-old"],
            "running first (activity desc), then pinned, then activity desc"
        )
    }

    @MainActor
    func testPinnedOrderUsesPinRecencyNotTimestamp() {
        let (viewModel, defaults, suite) = makeViewModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        // pinnedSessionIds is "most recently pinned first" per the protocol.
        viewModel.applyWorkspaceFrame(baseline(
            [workspace("w1", sessionIds: ["p1", "p2", "idle"])],
            pinned: ["p2", "p1"]
        ))
        viewModel.applySessions([
            session("p1", updatedAt: 900),
            session("p2", updatedAt: 100),
            session("idle", updatedAt: 999),
        ])

        XCTAssertEqual(viewModel.groups[0].sessions.map(\.sessionId), ["p2", "p1", "idle"])
    }

    // MARK: - Incremental frames

    @MainActor
    func testIncrementalUpsertRemoveOrderArchivedPinned() throws {
        let (viewModel, defaults, suite) = makeViewModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        viewModel.applyWorkspaceFrame(baseline([
            workspace("a", path: "/ws/a", title: "A", sessionIds: ["s1"]),
            workspace("b", path: "/ws/b", title: "B", sessionIds: ["s2"]),
        ]))
        viewModel.applySessions([
            session("s1", updatedAt: 10),
            session("s2", updatedAt: 20),
            session("s3", updatedAt: 30),
        ])

        // A newly created workspace is prepended by the Host.
        viewModel.applyWorkspaceFrame(try frame("""
        {"type":"upsert","workspace":{"workspaceId":"c","path":"/ws/c","title":"C","sessionIds":["s3"]}}
        """))
        XCTAssertEqual(viewModel.groups.map(\.workspaceId), ["c", "a", "b"])
        XCTAssertEqual(viewModel.sessionCount, 3)

        viewModel.applyWorkspaceFrame(try frame(#"{"type":"remove","workspaceId":"a"}"#))
        XCTAssertEqual(viewModel.groups.map(\.workspaceId), ["c", "b"])
        XCTAssertEqual(viewModel.sessionCount, 2)

        viewModel.applyWorkspaceFrame(try frame(#"{"type":"order","workspaceIds":["b","c"]}"#))
        XCTAssertEqual(viewModel.groups.map(\.workspaceId), ["b", "c"])

        viewModel.applyWorkspaceFrame(try frame(#"{"type":"archived","archivedSessionIds":["s2"]}"#))
        XCTAssertEqual(viewModel.sessionCount, 1, "archiving a session hides it")
        XCTAssertEqual(viewModel.groups.map(\.sessions.count), [0, 1])

        viewModel.applyWorkspaceFrame(try frame(#"{"type":"pinned","pinnedSessionIds":["s3"]}"#))
        XCTAssertEqual(viewModel.followState.pinnedSessionIds, ["s3"])

        // A fresh baseline (reconnect/refresh) replaces the whole table.
        viewModel.applyWorkspaceFrame(baseline([workspace("d", path: "/ws/d", title: "D", sessionIds: [])]))
        XCTAssertEqual(viewModel.groups.map(\.workspaceId), ["d"])
        XCTAssertEqual(viewModel.sessionCount, 0)
    }

    @MainActor
    func testUnknownFrameIsIgnored() throws {
        let (viewModel, defaults, suite) = makeViewModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        viewModel.applyWorkspaceFrame(baseline([workspace("w1", sessionIds: ["s1"])]))
        viewModel.applySessions([session("s1")])
        viewModel.applyWorkspaceFrame(try frame(#"{"type":"future-frame","payload":{}}"#))
        XCTAssertEqual(viewModel.groups.map(\.workspaceId), ["w1"])
        XCTAssertEqual(viewModel.sessionCount, 1)
    }

    @MainActor
    func testLoadingStopsOnBaseline() {
        let (viewModel, defaults, suite) = makeViewModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(viewModel.isLoading, "list starts in the loading state")
        viewModel.applyWorkspaceFrame(baseline([]))
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(viewModel.groups.isEmpty)
        XCTAssertEqual(viewModel.sessionCount, 0)
    }

    // MARK: - Collapse state (persisted per workspace path)

    @MainActor
    func testCollapseDefaultsToExpanded() {
        let (viewModel, defaults, suite) = makeViewModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(viewModel.isCollapsed("/ws/a"), "workspaces start expanded")
    }

    @MainActor
    func testCollapseTogglePersistsPerWorkspacePath() {
        let (viewModel, defaults, suite) = makeViewModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        viewModel.toggleCollapsed("/ws/a")
        XCTAssertTrue(viewModel.isCollapsed("/ws/a"))
        XCTAssertFalse(viewModel.isCollapsed("/ws/b"))
        XCTAssertEqual(defaults.stringArray(forKey: WorkspaceViewModel.collapsedPathsKey), ["/ws/a"])

        let restored = WorkspaceViewModel(defaults: defaults, cacheStore: makeCacheStore())
        XCTAssertTrue(restored.isCollapsed("/ws/a"), "a new app launch restores persisted collapse state")

        restored.toggleCollapsed("/ws/a")
        XCTAssertFalse(restored.isCollapsed("/ws/a"))
        XCTAssertEqual(defaults.stringArray(forKey: WorkspaceViewModel.collapsedPathsKey), [])
    }

    @MainActor
    func testCollapseStateSurvivesStreamBaselineReload() {
        let (viewModel, defaults, suite) = makeViewModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        viewModel.toggleCollapsed("/ws/a")
        viewModel.applyWorkspaceFrame(baseline([
            workspace("w1", path: "/ws/a", title: "A"),
            workspace("w2", path: "/ws/b", title: "B"),
        ]))
        XCTAssertTrue(viewModel.isCollapsed("/ws/a"))
        XCTAssertFalse(viewModel.isCollapsed("/ws/b"))
    }

    // MARK: - P0-4: session/list before `phase == .connected`

    func testSessionListCanStartBeforeConnectedOnlyWhenPaired() {
        // Unpaired: the unary transport has no credential to authenticate with.
        XCTAssertFalse(
            WorkspaceViewModel.canLoadSessionsBeforeConnected(hasCredentials: false, isConnected: false)
        )
        // Paired but mux/$events still bringing up: the live list may start now.
        XCTAssertTrue(
            WorkspaceViewModel.canLoadSessionsBeforeConnected(hasCredentials: true, isConnected: false)
        )
        // Already connected: the normal load path owns it (no duplicate request).
        XCTAssertFalse(
            WorkspaceViewModel.canLoadSessionsBeforeConnected(hasCredentials: true, isConnected: true)
        )
    }

    @MainActor
    func testApplyingLiveListAndFirstPaintRecordsFirstScreenMarks() throws {
        FirstScreenMetrics.forceEnabledForTesting = true
        FirstScreenMetrics.reset()
        FirstScreenMetrics.begin()
        defer {
            FirstScreenMetrics.forceEnabledForTesting = nil
            FirstScreenMetrics.reset()
        }
        let (viewModel, defaults, suite) = makeViewModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        FirstScreenMetrics.markListRequested()
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"items":[]}"#.utf8))
        try viewModel.applySessionListResponse(value)
        viewModel.markFirstFrameVisible()

        let metrics = try XCTUnwrap(FirstScreenMetrics.valueString)
        XCTAssertFalse(metrics.contains("listReqStartMs=-1"), "list request mark must be recorded")
        XCTAssertFalse(metrics.contains("listAppliedMs=-1"), "applied snapshot mark must be recorded")
        XCTAssertFalse(metrics.contains("firstPaintMs=-1"), "first paint mark must be recorded")
        XCTAssertTrue(metrics.contains("beginEpochMs="), "wall-clock t0 is exposed for the UI-test parser")
    }

    @MainActor
    func testFirstScreenMetricsInactiveOutsideE2E() {
        FirstScreenMetrics.forceEnabledForTesting = false
        FirstScreenMetrics.reset()
        defer { FirstScreenMetrics.forceEnabledForTesting = nil }
        FirstScreenMetrics.begin()
        FirstScreenMetrics.markListRequested()
        FirstScreenMetrics.markListApplied()
        FirstScreenMetrics.markFirstPaint()
        XCTAssertNil(FirstScreenMetrics.valueString, "E2E-gated: no product behavior, no metrics surface")
    }

    // MARK: - P0-5: foreground resume reuses the live link

    func testForegroundActionReusesLiveLinkOnlyAfterARealBackground() {
        // Cold launch / re-activation with no background episode.
        XCTAssertEqual(AppModel.foregroundAction(phase: .connected, backgroundedSeconds: nil), .none)
        // Control-center / permission-alert blip: no extra traffic, no teardown.
        XCTAssertEqual(AppModel.foregroundAction(phase: .connected, backgroundedSeconds: 0.4), .none)
        // Real resume with a live link: reuse the existing TLS/mux.
        XCTAssertEqual(AppModel.foregroundAction(phase: .connected, backgroundedSeconds: 8), .reuseMux)
    }

    func testForegroundActionReconnectsOnlyWhenTransportIsDown() {
        XCTAssertEqual(AppModel.foregroundAction(phase: .disconnected, backgroundedSeconds: 8), .reconnect)
        // A backoff wait must not delay the resumed app up to the 10s cap.
        XCTAssertEqual(
            AppModel.foregroundAction(phase: .reconnecting(attempt: 3), backgroundedSeconds: 8),
            .reconnect
        )
        // An in-flight bring-up must not be cancelled and restarted (P0-5).
        XCTAssertEqual(AppModel.foregroundAction(phase: .connecting, backgroundedSeconds: 8), .none)
        // Pairing states are user-driven.
        XCTAssertEqual(AppModel.foregroundAction(phase: .unpaired, backgroundedSeconds: 8), .none)
        XCTAssertEqual(AppModel.foregroundAction(phase: .needsRepair("repair"), backgroundedSeconds: 8), .none)
    }

    // MARK: - task-2: reconnect chain (page enter / stale-socket liveness)

    func testDeclareMuxDeadDecisionMatrix() {
        // First byte did arrive: never a dead socket, however late.
        XCTAssertFalse(
            WorkspaceViewModel.shouldDeclareMuxDead(
                baselineApplied: true, elapsedMs: 10_000, thresholdMs: 500
            )
        )
        // Byte still missing but the budget is not spent yet.
        XCTAssertFalse(
            WorkspaceViewModel.shouldDeclareMuxDead(
                baselineApplied: false, elapsedMs: 499, thresholdMs: 500
            )
        )
        // Budget spent with no byte: the reused socket is presumed dead.
        XCTAssertTrue(
            WorkspaceViewModel.shouldDeclareMuxDead(
                baselineApplied: false, elapsedMs: 500, thresholdMs: 500
            )
        )
        // A reconnect already changed the generation: nothing to declare.
        XCTAssertFalse(
            WorkspaceViewModel.shouldDeclareMuxDead(
                baselineApplied: false,
                elapsedMs: 5_000,
                thresholdMs: 500,
                stillConnected: false
            )
        )
    }

    @MainActor
    func testReuseBaselineBudgetIsWithinHandoffRange() {
        // 300-500ms per handoff §2.3(2); the env tunable may narrow it for the bench.
        XCTAssertTrue((50...5_000).contains(WorkspaceViewModel.reuseBaselineTimeoutMs))
    }

    func testShouldStartEarlySnapshotDecisionMatrix() {
        XCTAssertTrue(
            WorkspaceViewModel.shouldStartEarlySnapshot(
                prefersEarlyUnary: true, hasCredentials: true, isConnected: false
            ),
            "paired but not connected: the list request may overlap the handshake"
        )
        XCTAssertFalse(
            WorkspaceViewModel.shouldStartEarlySnapshot(
                prefersEarlyUnary: false, hasCredentials: true, isConnected: false
            ),
            "stale LAN origin on cellular: do not hang on the unary path"
        )
        XCTAssertFalse(
            WorkspaceViewModel.shouldStartEarlySnapshot(
                prefersEarlyUnary: true, hasCredentials: false, isConnected: false
            )
        )
        XCTAssertFalse(
            WorkspaceViewModel.shouldStartEarlySnapshot(
                prefersEarlyUnary: true, hasCredentials: true, isConnected: true
            ),
            "already connected: the normal load path owns the request"
        )
    }

    @MainActor
    func testLiveListApplicationCompletesReconnectChain() throws {
        var now: TimeInterval = 500
        ReconnectMetrics.forceEnabledForTesting = true
        ReconnectMetrics.clock = { now }
        ReconnectMetrics.reset()
        defer {
            ReconnectMetrics.forceEnabledForTesting = nil
            ReconnectMetrics.reset()
            ReconnectMetrics.clock = { ProcessInfo.processInfo.systemUptime }
        }
        let (viewModel, defaults, suite) = makeViewModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        ReconnectMetrics.beginPageEnter(reason: "listPage")
        now += 0.250
        ReconnectMetrics.markReconnectStart()
        now += 0.300
        ReconnectMetrics.markConnected()
        now += 0.200
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"items":[]}"#.utf8))
        try viewModel.applySessionListResponse(value)

        let metrics = try XCTUnwrap(ReconnectMetrics.valueString)
        XCTAssertTrue(metrics.contains("totalMs=750"), metrics)
        XCTAssertTrue(metrics.contains("stage=complete"), metrics)
        XCTAssertTrue(metrics.contains("listAppliedMs=750"), metrics)
    }
}
