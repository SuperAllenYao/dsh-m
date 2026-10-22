import XCTest
@testable import DSHm

/// M2b-2 本地缓存秒开：缓存往返 / schema 版本 / 损坏回退 / TTL >= 过期 / 空缓存
/// / 列表 diff / 详情窗口合并去重 / 首屏耗时量化。
final class CacheTests: XCTestCase {
    private var root: URL!
    private var cacheDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSHmCacheTests-\(UUID().uuidString)", isDirectory: true)
        cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Fixtures

    /// Pairing identity used by the test stores; a different value simulates a
    /// different Mac pairing (M2b-2 cache fingerprint).
    private static let pairingIdentity = "pair-identity-A"

    private func listStore(identity: String? = CacheTests.pairingIdentity) -> SessionListCacheStore {
        SessionListCacheStore(directory: cacheDirectory, identity: { identity })
    }

    private func windowStore(identity: String? = CacheTests.pairingIdentity) -> SessionWindowCacheStore {
        SessionWindowCacheStore(directory: cacheDirectory, identity: { identity })
    }

    private func listPayload(
        schemaVersion: Int = CacheSchema.version,
        savedAt: Date = Date(),
        identity: String = CacheTests.pairingIdentity,
        sessionList: JSONValue? = nil,
        followBaseline: JSONValue? = nil
    ) -> SessionListCachePayload {
        SessionListCachePayload(
            schemaVersion: schemaVersion,
            savedAt: savedAt,
            identity: identity,
            sessionList: sessionList,
            followBaseline: followBaseline
        )
    }

    private func windowPayload(
        schemaVersion: Int = SessionWindowCacheStore.schemaVersion,
        savedAt: Date = Date(),
        identity: String = CacheTests.pairingIdentity,
        sessionId: String = "s1",
        snapshot: JSONValue,
        events: [JSONValue] = [],
        windowMessages: Int? = nil,
        hasMore: Bool? = nil,
        p1Epoch: String? = nil,
        p1Sid: Int64? = nil,
        olderEvents: [JSONValue]? = nil,
        oldestSeq: Int? = nil,
        hasMoreOlder: Bool? = nil,
        hasReachedOldest: Bool? = nil
    ) -> SessionWindowCachePayload {
        SessionWindowCachePayload(
            schemaVersion: schemaVersion,
            savedAt: savedAt,
            identity: identity,
            sessionId: sessionId,
            snapshot: snapshot,
            events: events,
            windowMessages: windowMessages,
            hasMore: hasMore,
            p1Epoch: p1Epoch,
            p1Sid: p1Sid,
            olderEvents: olderEvents,
            oldestSeq: oldestSeq,
            hasMoreOlder: hasMoreOlder,
            hasReachedOldest: hasReachedOldest
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "CacheTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    /// Raw `session/list` response (same shape the Host returns to `unary`).
    private func listJSON() -> JSONValue {
        TestJSON.value("""
        {"items":[
          {"sessionId":"s1","updatedAt":10,"cwd":"/ws/a","running":false,
           "projections":{"values":{"title":"One","sessionListMetadata":{"lastPromptAt":10}}}},
          {"sessionId":"s2","updatedAt":20,"cwd":"/ws/a","running":false,
           "projections":{"values":{"title":"Two"}}}
        ]}
        """)
    }

    /// Raw `workspace/follow` baseline frame.
    private func followJSON() -> JSONValue {
        TestJSON.value("""
        {"type":"baseline","value":{"items":[
          {"workspaceId":"w1","path":"/ws/a","title":"A","sessionIds":["s1","s2"]}
        ],"archivedSessionIds":[],"pinnedSessionIds":[]}}
        """)
    }

    private func baselineFrame() throws -> WorkspaceFollowFrame {
        try followJSON().decode(WorkspaceFollowFrame.self)
    }

    private func sessionItem(_ id: String, updatedAt: Int64, title: String) throws -> SessionListItem {
        let json = """
        {"sessionId":"\(id)","updatedAt":\(updatedAt),"cwd":"/ws/a",
         "projections":{"values":{"title":"\(title)"}}}
        """
        return try JSONDecoder().decode(SessionListItem.self, from: Data(json.utf8))
    }

    private func eventJSON(_ type: String, seq: Int, data: String) -> String {
        "{\"type\":\"\(type)\",\"seq\":\(seq),\"data\":\(data)}"
    }

    private func windowEvents() -> [String] {
        [
            eventJSON("turn/start", seq: 1, data: "{\"turn\":1}"),
            eventJSON(
                "user/message",
                seq: 2,
                data: "{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}],\"source\":{\"kind\":\"user\"}}"
            ),
            eventJSON(
                "assistant/message",
                seq: 3,
                data: "{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"world\"}]}}"
            ),
        ]
    }

    private func snapshotJSON(
        cursor: Int,
        title: String = "Cached session",
        hasMore: Bool = false,
        events: [String]
    ) -> JSONValue {
        let records = events
            .map { "{\"type\":\"event\",\"event\":\($0)}" }
            .joined(separator: ",")
        let json = """
        {"type":"snapshot","header":{"version":4,"id":"s1"},"cursor":\(cursor),
         "records":[\(records)],"hasMore":\(hasMore),
         "projections":{"asOfSeq":\(cursor),"values":{"title":"\(title)"}},
         "assistantStream":{"revision":0}}
        """
        return TestJSON.value(json)
    }

    private func eventFrame(_ event: String) -> JSONValue {
        TestJSON.value("{\"type\":\"event\",\"event\":\(event)}")
    }

    /// 平铺消息流的行级投影：turn UI 删除后，断言直接落在渲染行上
    /// （`turn/start` / `turn/end` 只是事件边界，不产生任何行）。
    private func renderedUserTexts(_ rows: [FlowRow]) -> [String] {
        rows.compactMap { row -> String? in
            guard case .user(let bubble) = row.content else { return nil }
            return bubble.text
        }
    }

    private func renderedTexts(_ rows: [FlowRow]) -> [String] {
        rows.compactMap { row -> String? in
            guard case .text(let text) = row.content else { return nil }
            return text
        }
    }

    /// `SessionViewModel` debounces row rebuilds by ~40ms; live-frame assertions on
    /// derived rows need one turn of the run loop.
    @MainActor
    private func waitForRowRebuild() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    // MARK: - 会话列表缓存：往返 / 版本 / 损坏 / 空 / TTL

    func testSessionListCacheRoundTrip() throws {
        let store = listStore()
        XCTAssertNil(store.load(), "首次安装：没有缓存文件 -> nil（走网络）")

        XCTAssertTrue(store.save(sessionList: listJSON(), followBaseline: followJSON()))
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.payload.schemaVersion, CacheSchema.version)
        XCTAssertEqual(loaded.payload.sessionList, listJSON())
        XCTAssertEqual(loaded.payload.followBaseline, followJSON())
        XCTAssertFalse(loaded.isStale)
    }

    func testSessionListCacheRejectsSchemaMismatch() throws {
        let store = listStore()
        let payload = listPayload(
            schemaVersion: CacheSchema.version + 1,
            sessionList: listJSON(),
            followBaseline: followJSON()
        )
        XCTAssertTrue(CacheIO.writeAtomically(payload, to: store.fileURL))

        XCTAssertNil(store.load(), "版本不匹配 -> 安全回退为空缓存")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "不匹配的缓存文件会被清理")
    }

    func testSessionListCacheRejectsCorruptFile() throws {
        let store = listStore()
        try Data("{this is not json".utf8).write(to: store.fileURL)

        XCTAssertNil(store.load(), "损坏 JSON -> nil，不崩溃")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        // 损坏后仍能重新写入并读回（自愈）。
        XCTAssertTrue(store.save(sessionList: listJSON(), followBaseline: nil))
        XCTAssertNotNil(store.load())
    }

    func testSessionListCacheEmptyWhenMissing() {
        XCTAssertNil(listStore().load())
    }

    func testSessionListCacheTTLFlagsStaleAndRetentionDrops() throws {
        let store = listStore()
        let stale = listPayload(
            savedAt: Date().addingTimeInterval(-(CacheSchema.ttl + 60)),
            sessionList: listJSON(),
            followBaseline: followJSON()
        )
        XCTAssertTrue(CacheIO.writeAtomically(stale, to: store.fileURL))
        let loaded = try XCTUnwrap(store.load(), "过期但仍在保留期内 -> 展示并标记 stale")
        XCTAssertTrue(loaded.isStale)

        let retired = listPayload(
            savedAt: Date().addingTimeInterval(-(CacheSchema.retention + 60)),
            sessionList: listJSON(),
            followBaseline: followJSON()
        )
        XCTAssertTrue(CacheIO.writeAtomically(retired, to: store.fileURL))
        XCTAssertNil(store.load(), "超过保留期 -> 丢弃")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testSessionListCacheAtomicWriteLeavesNoTemporaryFiles() throws {
        let store = listStore()
        XCTAssertTrue(store.save(sessionList: listJSON(), followBaseline: followJSON()))
        let entries = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
        XCTAssertEqual(entries.filter { $0.contains(".tmp-") }.count, 0, "原子写完成不应残留临时文件")
        XCTAssertTrue(entries.contains("session-list.json"))
    }

    // MARK: - 会话窗口缓存：往返 / 损坏 / TTL

    func testSessionWindowCacheRoundTrip() throws {
        let store = windowStore()
        let snapshot = snapshotJSON(cursor: 3, events: windowEvents())
        let events = [eventFrame(eventJSON("user/message", seq: 4, data: "{\"content\":[],\"source\":{\"kind\":\"user\"}}"))]
        XCTAssertTrue(store.save(sessionId: "s1", snapshot: snapshot, events: events))

        let loaded = try XCTUnwrap(store.load(sessionId: "s1"))
        XCTAssertEqual(loaded.payload.sessionId, "s1")
        XCTAssertEqual(loaded.payload.snapshot, snapshot)
        XCTAssertEqual(loaded.payload.events, events)
        XCTAssertFalse(loaded.isStale)
        XCTAssertNil(store.load(sessionId: "other"), "按会话隔离，未知会话 -> nil")
    }

    func testSessionWindowCacheRejectsCorruptPayload() throws {
        let store = windowStore()
        try Data("garbage".utf8).write(to: store.fileURL(for: "s1"))
        XCTAssertNil(store.load(sessionId: "s1"), "损坏文件 -> nil，不崩溃")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: "s1").path))

        // 会话 id 一致但 schema 不同：同样丢弃（v2/v3 之外的版本才丢弃；v2 是
        // 兼容读取的旧 40 条窗口，见 testSessionWindowCacheReadsLegacyV2Payload）。
        let payload = windowPayload(
            schemaVersion: SessionWindowCacheStore.schemaVersion + 1,
            snapshot: snapshotJSON(cursor: 3, events: windowEvents())
        )
        XCTAssertTrue(CacheIO.writeAtomically(payload, to: store.fileURL(for: "s1")))
        XCTAssertNil(store.load(sessionId: "s1"))
    }

    func testSessionWindowCacheTTLFlagsStaleAndRetentionDrops() throws {
        let store = windowStore()
        let stale = windowPayload(
            savedAt: Date().addingTimeInterval(-(CacheSchema.ttl + 60)),
            snapshot: snapshotJSON(cursor: 3, events: windowEvents())
        )
        XCTAssertTrue(CacheIO.writeAtomically(stale, to: store.fileURL(for: "s1")))
        XCTAssertTrue(try XCTUnwrap(store.load(sessionId: "s1")).isStale)

        let retired = windowPayload(
            savedAt: Date().addingTimeInterval(-(CacheSchema.retention + 60)),
            snapshot: snapshotJSON(cursor: 3, events: windowEvents())
        )
        XCTAssertTrue(CacheIO.writeAtomically(retired, to: store.fileURL(for: "s1")))
        XCTAssertNil(store.load(sessionId: "s1"))
    }

    // MARK: - 列表秒开（WorkspaceViewModel）

    @MainActor
    func testWorkspaceViewModelShowsCachedListImmediately() throws {
        let store = listStore()
        XCTAssertTrue(store.save(sessionList: listJSON(), followBaseline: followJSON()))

        let viewModel = WorkspaceViewModel(defaults: makeDefaults(), cacheStore: store)
        XCTAssertTrue(viewModel.loadedFromCache)
        XCTAssertFalse(viewModel.isLoading, "有缓存时首帧直接是列表，不显示加载态")
        XCTAssertEqual(viewModel.groups.map(\.workspaceId), ["w1"])
        XCTAssertEqual(viewModel.groups.first?.sessions.map(\.sessionId), ["s2", "s1"])
        XCTAssertEqual(viewModel.sessionCount, 2)
        XCTAssertEqual(viewModel.allSessions.count, 2, "缓存列表也提供深链地址解析")
        XCTAssertGreaterThan(viewModel.sessionsSnapshotVersion, 0)
        XCTAssertFalse(viewModel.cacheIsStale)
    }

    @MainActor
    func testWorkspaceViewModelCacheFirstContentUnder100ms() throws {
        let store = listStore()
        XCTAssertTrue(store.save(sessionList: listJSON(), followBaseline: followJSON()))
        let defaults = makeDefaults()

        var samples: [Double] = []
        for _ in 0..<5 {
            let viewModel = WorkspaceViewModel(defaults: defaults, cacheStore: store)
            XCTAssertEqual(viewModel.groups.count, 1)
            XCTAssertGreaterThan(viewModel.timeToFirstContentMilliseconds, 0)
            samples.append(viewModel.cacheLoadMilliseconds)
        }
        let average = samples.reduce(0, +) / Double(samples.count)
        XCTAssertLessThan(
            average,
            100,
            "M2b-2 目标：缓存列表首屏 <100ms（实测平均 \(String(format: "%.2f", average))ms）"
        )
    }

    @MainActor
    func testWorkspaceViewModelEmptyCacheFallsBackToLoadingState() {
        let viewModel = WorkspaceViewModel(defaults: makeDefaults(), cacheStore: listStore())
        XCTAssertFalse(viewModel.loadedFromCache)
        XCTAssertTrue(viewModel.isLoading, "首次安装无缓存允许先空态/加载态")
        XCTAssertTrue(viewModel.groups.isEmpty)
        XCTAssertTrue(viewModel.allSessions.isEmpty)
    }

    @MainActor
    func testWorkspaceViewModelCorruptCacheFallsBackSafely() throws {
        let store = listStore()
        try Data("\u{0}\u{0}broken".utf8).write(to: store.fileURL)

        let viewModel = WorkspaceViewModel(defaults: makeDefaults(), cacheStore: store)
        XCTAssertFalse(viewModel.loadedFromCache)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertTrue(viewModel.groups.isEmpty, "损坏缓存不能导致崩溃或脏数据")
    }

    @MainActor
    func testWorkspaceViewModelTTLFlagVisible() throws {
        let store = listStore()
        let stale = listPayload(
            savedAt: Date().addingTimeInterval(-(CacheSchema.ttl + 60)),
            sessionList: listJSON(),
            followBaseline: followJSON()
        )
        XCTAssertTrue(CacheIO.writeAtomically(stale, to: store.fileURL))

        let viewModel = WorkspaceViewModel(defaults: makeDefaults(), cacheStore: store)
        XCTAssertTrue(viewModel.loadedFromCache)
        XCTAssertTrue(viewModel.cacheIsStale, "超过 TTL 仍展示，但标记 stale（列表顶部显示缓存提示）")
        XCTAssertEqual(viewModel.groups.count, 1)
    }

    @MainActor
    func testWorkspaceViewModelNetworkSnapshotPersistsAndRestores() throws {
        let store = listStore()
        let defaults = makeDefaults()
        let viewModel = WorkspaceViewModel(defaults: defaults, cacheStore: store)
        viewModel.applyWorkspaceFrame(try baselineFrame())
        try viewModel.applySessionListResponse(listJSON())
        viewModel.saveListCacheNow()
        XCTAssertFalse(viewModel.loadedFromCache)
        XCTAssertNotNil(store.load(), "网络快照 + registry 落盘")

        let relaunched = WorkspaceViewModel(defaults: defaults, cacheStore: store)
        XCTAssertTrue(relaunched.loadedFromCache)
        XCTAssertEqual(relaunched.groups.map(\.workspaceId), ["w1"])
        XCTAssertEqual(relaunched.groups.first?.sessions.map(\.sessionId), ["s2", "s1"])
        XCTAssertEqual(relaunched.sessionCount, 2)
    }

    @MainActor
    func testWorkspaceViewModelDiffOnlyPublishesWhenContentChanges() throws {
        let store = listStore()
        XCTAssertTrue(store.save(sessionList: listJSON(), followBaseline: followJSON()))
        let viewModel = WorkspaceViewModel(defaults: makeDefaults(), cacheStore: store)

        let version = viewModel.groupsVersion
        viewModel.applySessions(viewModel.allSessions)
        XCTAssertEqual(viewModel.groupsVersion, version, "内容相同的刷新不重新发布 groups（不闪屏、不跳滚动）")

        var changed = viewModel.allSessions
        changed[0] = try sessionItem("s1", updatedAt: 10, title: "Renamed")
        viewModel.applySessions(changed)
        XCTAssertEqual(viewModel.groupsVersion, version + 1, "内容变化才发布")
        XCTAssertEqual(viewModel.groups.first?.sessions.first(where: { $0.sessionId == "s1" })?.title, "Renamed")
    }

    // MARK: - 详情秒开（SessionViewModel）

    @MainActor
    func testSessionViewModelRestoresCachedWindowImmediately() throws {
        let store = windowStore()
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 3, events: windowEvents()),
            events: []
        ))

        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertTrue(viewModel.isShowingCachedWindow)
        XCTAssertFalse(viewModel.isLoading, "有缓存时打开即渲染，不显示加载态")
        XCTAssertEqual(viewModel.eventSeqs, [1, 2, 3])
        XCTAssertEqual(viewModel.title, "Cached session")
        XCTAssertEqual(renderedUserTexts(viewModel.rows), ["hello"], "缓存窗口即时构建出用户消息行")
        XCTAssertEqual(renderedTexts(viewModel.rows), ["world"], "缓存窗口即时构建出助手文本行")
        XCTAssertEqual(viewModel.rows.map(\.seq), [2, 3], "渲染行按事件顺序（turn 边界不产生区块）")
        XCTAssertFalse(viewModel.cachedWindowIsStale)
    }

    @MainActor
    func testSessionViewModelCachedWindowFirstRenderUnder100ms() throws {
        let store = windowStore()
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 3, events: windowEvents()),
            events: []
        ))

        var samples: [Double] = []
        for _ in 0..<5 {
            let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
            XCTAssertEqual(viewModel.eventSeqs, [1, 2, 3])
            samples.append(viewModel.cacheLoadMilliseconds)
        }
        let average = samples.reduce(0, +) / Double(samples.count)
        XCTAssertLessThan(
            average,
            100,
            "M2b-2 目标：缓存窗口首帧 <100ms（实测平均 \(String(format: "%.2f", average))ms）"
        )
    }

    @MainActor
    func testSessionViewModelStaleWindowFlagVisible() throws {
        let store = windowStore()
        let stale = windowPayload(
            savedAt: Date().addingTimeInterval(-(CacheSchema.ttl + 60)),
            snapshot: snapshotJSON(cursor: 3, events: windowEvents())
        )
        XCTAssertTrue(CacheIO.writeAtomically(stale, to: store.fileURL(for: "s1")))

        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertTrue(viewModel.isShowingCachedWindow)
        XCTAssertTrue(viewModel.cachedWindowIsStale)
        XCTAssertEqual(viewModel.eventSeqs, [1, 2, 3])
    }

    @MainActor
    func testSessionViewModelLiveSnapshotReplacesCachedWindowWithoutDuplicates() async throws {
        let store = windowStore()
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 3, events: windowEvents()),
            events: []
        ))
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertTrue(viewModel.isShowingCachedWindow, "打开时先显示缓存窗口")

        // live snapshot 到达：窗口整体替换（seq 有序、无重复），缓存横幅消失。
        let liveEvents = [
            eventJSON("turn/start", seq: 2, data: "{\"turn\":1}"),
            eventJSON(
                "user/message",
                seq: 3,
                data: "{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}],\"source\":{\"kind\":\"user\"}}"
            ),
            eventJSON(
                "assistant/message",
                seq: 4,
                data: "{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"world\"}]}}"
            ),
            eventJSON("turn/end", seq: 5, data: "{\"turn\":1,\"reason\":{\"kind\":\"completed\"}}"),
        ]
        viewModel.applyStreamValue(snapshotJSON(cursor: 5, title: "Live session", events: liveEvents))
        XCTAssertFalse(viewModel.isShowingCachedWindow)
        // snapshot 替换所有重叠 seq 的记录；缓存里 seq 1 比 live 窗口最老记录(2)更老，
        // 按 task session-history 语义保留（重连/替换不得丢掉已加载的更早历史）。
        XCTAssertEqual(viewModel.eventSeqs, [1, 2, 3, 4, 5], "snapshot 替换 + 按 seq 排序、去重、保留更老前缀")
        await waitForRowRebuild()
        XCTAssertEqual(viewModel.title, "Live session")

        // 增量事件接续：不能重复也不能乱序。
        viewModel.applyStreamValue(eventFrame(eventJSON(
            "user/message",
            seq: 6,
            data: "{\"content\":[{\"type\":\"text\",\"text\":\"again\"}],\"source\":{\"kind\":\"user\"}}"
        )))
        XCTAssertEqual(viewModel.eventSeqs, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(Set(viewModel.eventSeqs).count, viewModel.eventSeqs.count)
    }

    @MainActor
    func testSessionViewModelGapInCachedEventsDropsWindow() throws {
        let store = windowStore()
        // snapshot cursor=3, 但缓存的事件从 seq 5 开始 -> 与 snapshot 不连续。
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 3, events: windowEvents()),
            events: [TestJSON.value(eventJSON(
                "user/message",
                seq: 5,
                data: "{\"content\":[{\"type\":\"text\",\"text\":\"hole\"}],\"source\":{\"kind\":\"user\"}}"
            ))]
        ))

        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertFalse(viewModel.isShowingCachedWindow, "不连续缓存整体丢弃，不能展示有洞的窗口")
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertTrue(viewModel.eventSeqs.isEmpty)
    }

    @MainActor
    func testSessionViewModelCorruptCacheDoesNotCrash() throws {
        let store = windowStore()
        try Data("not-a-window".utf8).write(to: store.fileURL(for: "s1"))

        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertFalse(viewModel.isShowingCachedWindow)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertTrue(viewModel.eventSeqs.isEmpty)
        XCTAssertNil(viewModel.title)
    }

    @MainActor
    func testSessionViewModelPersistsLiveWindowForNextOpen() throws {
        let store = windowStore()
        let firstOpen = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        firstOpen.applyStreamValue(snapshotJSON(cursor: 3, events: windowEvents()))
        firstOpen.applyStreamValue(eventFrame(eventJSON(
            "assistant/message",
            seq: 4,
            data: "{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"more\"}]}}"
        )))
        firstOpen.saveWindowCacheNow()

        let secondOpen = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertTrue(secondOpen.isShowingCachedWindow)
        XCTAssertEqual(secondOpen.eventSeqs, [1, 2, 3, 4], "上次会话窗口在下次打开时秒开")
    }

    // MARK: - 体积接近真实数据的首屏测量（写入 notes 的数字）

    /// ~950KB `session/list`（220 会话，带 title/lastPromptAt/contextPressure/turnOutline
    /// 大投影），体积对齐 Lead 真机实测的 959KB 缓存文件。
    private func largeListJSON() -> JSONValue {
        var items: [[String: Any]] = []
        for index in 0..<220 {
            let outline: [[String: Any]] = (0..<30).map { step in
                [
                    "step": step,
                    "title": "Step \(step) — a realistic long-ish turn outline entry for session \(index)",
                    "status": "completed",
                    "summary": "summary text for step \(step) of session \(index)",
                ]
            }
            items.append([
                "sessionId": "session-\(index)",
                "updatedAt": 1_792_510_000_000 + index,
                "running": index % 17 == 0,
                "cwd": "/Users/example/myProject/workspace-\(index % 12)",
                "projections": ["values": [
                    "title": "会话 \(index) — 一个足够长的标题用来模拟真实 session/list 体积",
                    "sessionListMetadata": ["lastPromptAt": 1_792_500_000_000 + index],
                    "contextPressure": [
                        "pressureTokens": 12_345,
                        "projectedTokens": 96_000,
                        "contextWindow": 200_000,
                    ],
                    "turnOutline": outline,
                ]],
            ])
        }
        let data = try! JSONSerialization.data(withJSONObject: ["items": items])
        return try! JSONValue.jsonObject(from: data)
    }

    private func largeFollowJSON() -> JSONValue {
        var workspaces: [[String: Any]] = []
        for workspace in 0..<12 {
            let ids = (0..<220).filter { $0 % 12 == workspace }.map { "session-\($0)" }
            workspaces.append([
                "workspaceId": "w-\(workspace)",
                "path": "/Users/example/myProject/workspace-\(workspace)",
                "title": "workspace-\(workspace)",
                "sessionIds": ids,
            ])
        }
        let data = try! JSONSerialization.data(withJSONObject: [
            "type": "baseline",
            "value": ["items": workspaces, "archivedSessionIds": [], "pinnedSessionIds": []],
        ])
        return try! JSONValue.jsonObject(from: data)
    }

    /// 40 条消息（约 70KB，模拟带工具输出的真实首屏窗口）。
    private func largeWindowSnapshot() -> JSONValue {
        var events: [String] = []
        var seq = 0
        for turn in 1...13 {
            seq += 1
            events.append(eventJSON("turn/start", seq: seq, data: "{\"turn\":\(turn)}"))
            seq += 1
            events.append(eventJSON(
                "user/message",
                seq: seq,
                data: "{\"content\":[{\"type\":\"text\",\"text\":\"message \(turn)\"}],\"source\":{\"kind\":\"user\"}}"
            ))
            seq += 1
            let body = String(repeating: "工具输出内容 ", count: 300)
            events.append(eventJSON(
                "assistant/message",
                seq: seq,
                data: "{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"\(body)\"}]}}"
            ))
        }
        return snapshotJSON(cursor: seq, events: events)
    }

    @MainActor
    func testWorkspaceViewModelLargeCachedListFirstContentUnder100ms() throws {
        let store = listStore()
        try seedCache(store: store, sessionList: largeListJSON(), follow: largeFollowJSON())
        let defaults = makeDefaults()

        var samples: [Double] = []
        var sessionCount = 0
        for _ in 0..<5 {
            let viewModel = WorkspaceViewModel(defaults: defaults, cacheStore: store)
            sessionCount = viewModel.sessionCount
            XCTAssertEqual(viewModel.groups.count, 12)
            samples.append(viewModel.cacheLoadMilliseconds)
        }
        let average = samples.reduce(0, +) / Double(samples.count)
        print("[M2b-2b] compact list cache-first: raw=\(fileSize(store.fileURL))B compact=\(fileSize(store.renderFileURL))B sessions=\(sessionCount) avg=\(String(format: "%.2f", average))ms samples=\(samples.map { String(format: "%.2f", $0) })")
        XCTAssertEqual(sessionCount, 220)
        XCTAssertLessThan(
            average,
            100,
            "M2b-2b 目标：~950KB raw 缓存下紧凑快照首屏 <100ms（实测平均 \(String(format: "%.2f", average))ms）"
        )
    }

    @MainActor
    func testSessionViewModelLargeCachedWindowFirstRenderUnder100ms() throws {
        let store = windowStore()
        let snapshot = largeWindowSnapshot()
        XCTAssertGreaterThan((try JSONEncoder().encode(snapshot)).count, 40_000, "fixture 体积接近真实窗口")
        XCTAssertTrue(store.save(sessionId: "s1", snapshot: snapshot, events: []))

        var samples: [Double] = []
        for _ in 0..<5 {
            let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
            XCTAssertEqual(viewModel.rows.count, 26, "大缓存窗口即时构建出全部渲染行（13 用户 + 13 助手）")
            XCTAssertEqual(renderedUserTexts(viewModel.rows), (1...13).map { "message \($0)" })
            XCTAssertEqual(renderedTexts(viewModel.rows).count, 13)
            samples.append(viewModel.cacheLoadMilliseconds)
        }
        let average = samples.reduce(0, +) / Double(samples.count)
        print("[M2b-cache] detail cache-first (~70KB, 40 messages): avg=\(String(format: "%.2f", average))ms samples=\(samples.map { String(format: "%.2f", $0) })")
        XCTAssertLessThan(
            average,
            100,
            "M2b-2 目标：缓存窗口首帧 <100ms（实测平均 \(String(format: "%.2f", average))ms）"
        )
    }

    // MARK: - 配对身份指纹（换 Mac / 重配后旧缓存立即失效）

    func testSessionListCacheHitsForSamePairingIdentity() throws {
        let writer = listStore()
        XCTAssertTrue(writer.save(sessionList: listJSON(), followBaseline: followJSON()))

        let reader = listStore(identity: CacheTests.pairingIdentity)
        let loaded = try XCTUnwrap(reader.load(), "同一配对 -> 正常命中")
        XCTAssertEqual(loaded.payload.identity, CacheTests.pairingIdentity)
    }

    func testSessionListCacheRejectsDifferentPairingIdentity() throws {
        let writer = listStore(identity: "pair-identity-OLD-Mac")
        XCTAssertTrue(writer.save(sessionList: listJSON(), followBaseline: followJSON()))

        let reader = listStore(identity: "pair-identity-NEW-Mac")
        XCTAssertNil(reader.load(), "不同配对 -> 当作没有缓存")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reader.fileURL.path), "并立即删除旧缓存文件")
    }

    @MainActor
    func testWorkspaceViewModelDropsCacheFromOtherPairing() throws {
        let writer = listStore(identity: "pair-identity-OLD-Mac")
        XCTAssertTrue(writer.save(sessionList: listJSON(), followBaseline: followJSON()))

        let viewModel = WorkspaceViewModel(
            defaults: makeDefaults(),
            cacheStore: listStore(identity: "pair-identity-NEW-Mac")
        )
        XCTAssertFalse(viewModel.loadedFromCache, "换 Mac 后旧列表缓存不得展示")
        XCTAssertTrue(viewModel.isLoading, "回退到网络加载态")
        XCTAssertTrue(viewModel.groups.isEmpty)
        XCTAssertTrue(viewModel.allSessions.isEmpty)
    }

    func testSessionWindowCacheRejectsDifferentPairingIdentity() throws {
        let writer = windowStore(identity: "pair-identity-OLD-Mac")
        XCTAssertTrue(writer.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 3, events: windowEvents()),
            events: []
        ))

        let reader = windowStore(identity: "pair-identity-NEW-Mac")
        XCTAssertNil(reader.load(sessionId: "s1"), "不同配对 -> 当作没有缓存")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reader.fileURL(for: "s1").path))
    }

    @MainActor
    func testSessionViewModelDropsCacheFromOtherPairing() throws {
        let writer = windowStore(identity: "pair-identity-OLD-Mac")
        XCTAssertTrue(writer.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 3, events: windowEvents()),
            events: []
        ))

        let viewModel = SessionViewModel(
            address: .session(sessionId: "s1"),
            windowCache: windowStore(identity: "pair-identity-NEW-Mac")
        )
        XCTAssertFalse(viewModel.isShowingCachedWindow, "换 Mac 后旧窗口缓存不得展示")
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertTrue(viewModel.eventSeqs.isEmpty)
    }

    func testCacheIdentityIsStableAndHostScoped() throws {
        let identity = CacheIdentity.make(leafPin: "leaf-A", keyId: "key-A")
        XCTAssertEqual(identity, CacheIdentity.make(leafPin: "leaf-A", keyId: "key-A"), "同一配对 -> 稳定指纹")
        XCTAssertNotEqual(identity, CacheIdentity.make(leafPin: "leaf-B", keyId: "key-A"), "不同 Mac -> 不同指纹")
        XCTAssertNotEqual(identity, CacheIdentity.make(leafPin: "leaf-A", keyId: "key-B"))
        XCTAssertEqual(identity.count, 16)
        XCTAssertNil(CacheIdentity.current(loadCredentials: { nil }), "未配对 -> 无身份（首次启动行为不变）")

        let credentials = PairingCredentials(
            origin: "https://192.168.1.10:3466",
            leafPin: "leaf-A",
            deviceId: "device-1",
            credential: "credential",
            deviceName: "iPhone",
            pairedAt: 0,
            keyId: "key-A",
            originCandidates: nil
        )
        XCTAssertEqual(CacheIdentity.current(loadCredentials: { credentials }), identity, "身份只由配对凭据派生")
    }

    // MARK: - i18n（en 下不能露出中文）

    func testCacheStatusStringsHaveEnglishTranslations() throws {
        let keys = [
            "%@ · 本地缓存",
            "%@ · 缓存已过期",
            "本地缓存 · 正在刷新…",
            "本地缓存 · 已超过 24 小时",
            "显示本地缓存，正在同步…",
            "显示本地缓存（已过期），正在同步…",
        ]
        let enPath = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"), "app bundle 缺少 en.lproj")
        let enBundle = try XCTUnwrap(Bundle(path: enPath))
        let han = try NSRegularExpression(pattern: "\\p{Han}")
        for key in keys {
            let value = enBundle.localizedString(forKey: key, value: "__missing__", table: nil)
            XCTAssertNotEqual(value, "__missing__", "en 缺少本地化 key: \(key)")
            XCTAssertNotEqual(value, key, "en 回退成了中文 key: \(key)")
            XCTAssertTrue(
                han.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) == nil,
                "en 文案仍含中文: \(key) -> \(value)"
            )
        }
    }

    func testCacheStatusFormattedStringLocalizesToEnglish() throws {
        let enPath = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let enBundle = try XCTUnwrap(Bundle(path: enPath))
        let format = enBundle.localizedString(forKey: "%@ · 本地缓存", value: nil, table: nil)
        let formatted = String(format: format, "3 workspaces · 12 sessions")
        XCTAssertEqual(formatted, "3 workspaces · 12 sessions · Local cache")
        XCTAssertNil(formatted.range(of: "\\p{Han}", options: .regularExpression))
    }

    // MARK: - M2b-2b 紧凑渲染快照 / 启动延迟化 / in-app 计时 / 详情预热

    /// One `session/list` row JSON with the fields the compact snapshot must preserve.
    private func listItemJSON(
        _ id: String,
        running: Bool = false,
        updatedAt: Int64 = 1,
        lastPromptAt: Int64? = nil,
        userQuestions: Int = 0,
        parentSessionId: String? = nil
    ) -> String {
        var projectionValues: [String: Any] = ["title": "Title \(id)"]
        if let lastPromptAt {
            projectionValues["sessionListMetadata"] = ["lastPromptAt": lastPromptAt]
        }
        if userQuestions > 0 {
            projectionValues["userQuestions"] = [
                "active": Array(repeating: ["callId": "q-\(id)"], count: userQuestions),
            ]
        }
        var row: [String: Any] = [
            "sessionId": id,
            "updatedAt": updatedAt,
            "running": running,
            "projections": ["values": projectionValues],
        ]
        if let parentSessionId {
            row["parentSessionId"] = parentSessionId
            row["origin"] = "subagent"
        }
        let data = try! JSONSerialization.data(withJSONObject: row)
        return String(data: data, encoding: .utf8)!
    }

    private func decodedListItem(_ id: String, running: Bool = false, userQuestions: Int = 0) throws -> SessionListItem {
        try JSONDecoder().decode(
            SessionListItem.self,
            from: Data(listItemJSON(id, running: running, userQuestions: userQuestions).utf8)
        )
    }

    /// Persists a raw + compact cache pair through the production save path.
    @MainActor
    @discardableResult
    private func seedCache(
        store: SessionListCacheStore,
        sessionList: JSONValue,
        follow: JSONValue
    ) throws -> WorkspaceViewModel {
        let viewModel = WorkspaceViewModel(defaults: makeDefaults(), cacheStore: store)
        viewModel.applyWorkspaceFrame(try follow.decode(WorkspaceFollowFrame.self))
        try viewModel.applySessionListResponse(sessionList)
        viewModel.saveListCacheNow()
        return viewModel
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }

    func testCompactRenderSnapshotPreservesCardFields() throws {
        let item = try decodedListItem("s1", running: true, userQuestions: 2)
        let compact = SessionListRenderSnapshot.session(from: item)
        let restored = SessionListRenderSnapshot.listItem(from: compact)

        XCTAssertEqual(restored.sessionId, item.sessionId)
        XCTAssertEqual(restored.title, item.title)
        XCTAssertEqual(restored.lastPromptAt, item.lastPromptAt)
        XCTAssertEqual(restored.updatedAt, item.updatedAt)
        XCTAssertEqual(restored.isRunning, item.isRunning)
        XCTAssertEqual(restored.userQuestionsActive.count, item.userQuestionsActive.count)
        XCTAssertEqual(restored.followAddress, item.followAddress)
        XCTAssertEqual(SessionListStatusResolver.status(for: restored, pendingApprovals: 0, isConnected: true),
                       SessionListStatusResolver.status(for: item, pendingApprovals: 0, isConnected: true))
    }

    @MainActor
    func testCompactSnapshotColdStartRestoresListImmediately() throws {
        let store = listStore()
        try seedCache(store: store, sessionList: listJSON(), follow: followJSON())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.renderFileURL.path), "紧凑快照随列表一起落盘")
        XCTAssertLessThan(fileSize(store.renderFileURL), 100_000)

        let viewModel = WorkspaceViewModel(defaults: makeDefaults(), cacheStore: store)
        XCTAssertTrue(viewModel.loadedFromCache)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.groups.map(\.workspaceId), ["w1"])
        XCTAssertEqual(viewModel.groups.first?.sessions.map(\.sessionId), ["s2", "s1"])
        XCTAssertEqual(viewModel.sessionCount, 2)
        XCTAssertEqual(viewModel.groups.first?.sessions.first?.title, "Two")
    }

    @MainActor
    func testDeferredRawRestoreFillsAllSessionsForDeepLinks() async throws {
        let store = listStore()
        try seedCache(store: store, sessionList: listJSON(), follow: followJSON())

        let viewModel = WorkspaceViewModel(defaults: makeDefaults(), cacheStore: store)
        XCTAssertFalse(viewModel.groups.isEmpty, "紧凑快照先出首帧")
        XCTAssertTrue(viewModel.allSessions.isEmpty, "raw 后台解码在首帧之后才启动（不与首帧争主线程/IO）")
        viewModel.markFirstFrameVisible()
        await waitUntil { viewModel.allSessions.count == 2 }
        XCTAssertEqual(viewModel.allSessions.count, 2, "raw 快照在后台补齐深链地址表")
        XCTAssertGreaterThanOrEqual(viewModel.sessionsSnapshotVersion, 2)
    }

    @MainActor
    func testCompactSnapshotUnder100KBForBusyMachine() throws {
        let store = listStore()
        try seedCache(store: store, sessionList: largeListJSON(), follow: largeFollowJSON())

        let rawSize = fileSize(store.fileURL)
        let compactSize = fileSize(store.renderFileURL)
        print("[M2b-2b] cache sizes: raw=\(rawSize)B compact=\(compactSize)B")
        XCTAssertGreaterThan(rawSize, 800_000, "raw wire 快照体积对齐真机 959KB 档")
        XCTAssertLessThan(compactSize, 100_000, "M2b-2b 目标：渲染用紧凑快照 <100KB")
        XCTAssertLessThan(compactSize, rawSize / 5)
    }

    @MainActor
    func testCompactSnapshotColdStartFasterThanRawFallback() throws {
        let store = listStore()
        try seedCache(store: store, sessionList: largeListJSON(), follow: largeFollowJSON())
        let defaults = makeDefaults()

        var compactSamples: [Double] = []
        for _ in 0..<5 {
            let viewModel = WorkspaceViewModel(defaults: defaults, cacheStore: store)
            XCTAssertFalse(viewModel.groups.isEmpty)
            compactSamples.append(viewModel.cacheLoadMilliseconds)
        }
        let rawBytes = fileSize(store.fileURL)
        store.clearRenderSnapshot()
        var rawSamples: [Double] = []
        for _ in 0..<5 {
            let viewModel = WorkspaceViewModel(defaults: defaults, cacheStore: store)
            XCTAssertFalse(viewModel.groups.isEmpty)
            rawSamples.append(viewModel.cacheLoadMilliseconds)
        }
        let compactAverage = compactSamples.reduce(0, +) / Double(compactSamples.count)
        let rawAverage = rawSamples.reduce(0, +) / Double(rawSamples.count)
        print("[M2b-2b] cold-start cache load: compact avg=\(String(format: "%.2f", compactAverage))ms raw avg=\(String(format: "%.2f", rawAverage))ms raw=\(rawBytes)B")
        XCTAssertLessThan(compactAverage, rawAverage, "冷启动紧凑快照必须先于 raw 解码")
        XCTAssertLessThan(compactAverage, 100)
    }

    @MainActor
    func testCompactSnapshotCorruptFallsBackToRaw() throws {
        let store = listStore()
        try seedCache(store: store, sessionList: listJSON(), follow: followJSON())
        try Data("broken".utf8).write(to: store.renderFileURL)

        let viewModel = WorkspaceViewModel(defaults: makeDefaults(), cacheStore: store)
        XCTAssertTrue(viewModel.loadedFromCache, "紧凑快照损坏 -> 回退 raw 同步解码")
        XCTAssertEqual(viewModel.groups.first?.sessions.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.renderFileURL.path), "损坏的紧凑快照被清理")
    }

    @MainActor
    func testCompactSnapshotOtherPairingFallsBackToRaw() throws {
        let store = listStore()
        try seedCache(store: store, sessionList: listJSON(), follow: followJSON())
        let render = try XCTUnwrap(store.loadRenderSnapshot()).payload
        var tampered = render
        tampered.identity = "pair-identity-OLD-Mac"
        XCTAssertTrue(CacheIO.writeAtomically(tampered, to: store.renderFileURL))

        let viewModel = WorkspaceViewModel(defaults: makeDefaults(), cacheStore: store)
        XCTAssertTrue(viewModel.loadedFromCache, "身份不匹配的紧凑快照被丢弃，raw 路径仍可用")
        XCTAssertEqual(viewModel.groups.first?.sessions.map(\.sessionId), ["s2", "s1"])
    }

    @MainActor
    func testPrewarmCandidatesAreMostRecentSessions() throws {
        let store = listStore()
        let viewModel = try seedCache(store: store, sessionList: listJSON(), follow: followJSON())
        let candidates = viewModel.prewarmCandidates(limit: 2)
        XCTAssertEqual(candidates.map(\.sessionId), ["s2", "s1"], "按最后活动时间倒序")
        XCTAssertEqual(candidates.first?.address, .session(sessionId: "s2"))
        XCTAssertEqual(WorkspaceViewModel.prewarmLimitFromEnvironment(), 8, "默认预热 8 个会话（bench 可用 env 关闭）")
    }

    @MainActor
    func testPrewarmerSavesFirstWindowAndSkipsFreshCache() async throws {
        let store = windowStore()
        let prewarmer = SessionWindowPrewarmer(cacheStore: store, throttleNanoseconds: 0, timeoutNanoseconds: 0)
        let candidates = [
            SessionWindowPrewarmer.Candidate(sessionId: "s1", address: .session(sessionId: "s1")),
            SessionWindowPrewarmer.Candidate(sessionId: "s2", address: .session(sessionId: "s2")),
        ]
        let snapshot = snapshotJSON(cursor: 3, events: windowEvents())
        var opened: [String] = []
        prewarmer.start(candidates: candidates) { candidate, onSnapshot, _ in
            opened.append(candidate.sessionId)
            onSnapshot(snapshot)
            return {}
        }
        await waitUntil { !prewarmer.isRunning }
        XCTAssertEqual(opened, ["s1", "s2"])
        XCTAssertEqual(prewarmer.prewarmedSessionIds.sorted(), ["s1", "s2"])
        XCTAssertNotNil(store.load(sessionId: "s1"), "详情首窗已写入 window 缓存")
        XCTAssertNotNil(store.load(sessionId: "s2"))

        // Second run: both windows are fresh -> no stream is opened.
        opened = []
        prewarmer.start(candidates: candidates) { candidate, onSnapshot, _ in
            opened.append(candidate.sessionId)
            onSnapshot(snapshot)
            return {}
        }
        await waitUntil { !prewarmer.isRunning }
        XCTAssertTrue(opened.isEmpty, "已新鲜的窗口不重复预热")
    }

    @MainActor
    func testPrewarmerHandlesOpenFailureAndStreamErrorsSilently() async throws {
        let prewarmer = SessionWindowPrewarmer(
            cacheStore: windowStore(),
            throttleNanoseconds: 0,
            timeoutNanoseconds: 0
        )
        let candidates = [
            SessionWindowPrewarmer.Candidate(sessionId: "s1", address: .session(sessionId: "s1")),
            SessionWindowPrewarmer.Candidate(sessionId: "s2", address: .session(sessionId: "s2")),
        ]
        var opened = 0
        prewarmer.start(candidates: candidates) { _, _, onFinish in
            opened += 1
            if opened == 1 { return nil }   // stream could not be opened
            onFinish()                       // stream ended before any snapshot
            return {}
        }
        await waitUntil { !prewarmer.isRunning }
        XCTAssertEqual(opened, 2, "一次失败不阻塞后续候选")
        XCTAssertTrue(prewarmer.prewarmedSessionIds.isEmpty, "失败静默，不产生半成品缓存")
    }

    @MainActor
    func testPrewarmerCancelStopsRemainingCandidates() async throws {
        let prewarmer = SessionWindowPrewarmer(
            cacheStore: windowStore(),
            throttleNanoseconds: 0,
            timeoutNanoseconds: 0
        )
        let candidates = (0..<4).map {
            SessionWindowPrewarmer.Candidate(sessionId: "s\($0)", address: .session(sessionId: "s\($0)"))
        }
        var opened: [String] = []
        prewarmer.start(candidates: candidates) { candidate, _, _ in
            opened.append(candidate.sessionId)
            return {}   // stream stays open (no snapshot/end) until cancelled
        }
        await waitUntil { opened.count == 1 }
        prewarmer.cancel()
        XCTAssertFalse(prewarmer.isRunning)
        XCTAssertEqual(opened.count, 1, "取消后不再打开后续会话的流")
    }

    @MainActor
    func testStartupMetricsFormatsCacheFirstFrameAndNetwork() throws {
        StartupMetrics.forceEnabledForTesting = true
        StartupMetrics.reset()
        defer {
            StartupMetrics.forceEnabledForTesting = nil
            StartupMetrics.reset()
        }

        StartupMetrics.begin()
        StartupMetrics.markCacheLoaded()
        let afterCache = try XCTUnwrap(StartupMetrics.valueString)
        XCTAssertTrue(afterCache.contains("cacheMs="))
        XCTAssertTrue(afterCache.contains("firstFrameMs=-1"))
        XCTAssertTrue(afterCache.contains("networkMs=-1"))
        XCTAssertEqual(afterCache.components(separatedBy: ";").count, 5, "格式：cacheMs=..;firstFrameMs=..;networkMs=..;connMs=..;beginEpochMs=..")
        let beginEpoch = try XCTUnwrap(metricDouble(afterCache, "beginEpochMs"))
        XCTAssertGreaterThan(beginEpoch, 1_700_000_000_000, "beginEpochMs 是毫秒级 wall clock（跨进程时钟对齐用）")

        StartupMetrics.markConnected()
        StartupMetrics.markFirstFrame()
        StartupMetrics.markNetworkApplied()
        let complete = try XCTUnwrap(StartupMetrics.valueString)
        let pattern = #"^cacheMs=\d+(\.\d+)?;firstFrameMs=\d+(\.\d+)?;networkMs=\d+(\.\d+)?;connMs=\d+(\.\d+)?;beginEpochMs=\d+$"#
        XCTAssertNotNil(complete.range(of: pattern, options: .regularExpression), "实际值: \(complete)")

        StartupMetrics.forceEnabledForTesting = false
        XCTAssertNil(StartupMetrics.valueString, "非 E2E 启动不暴露计时（无产品行为）")
    }

    // MARK: - M2b-2c 详情 in-app 计时 / 预热命中自证

    /// Parses one `key=value` field of an in-app metrics string.
    private func metricDouble(_ metrics: String, _ key: String) -> Double? {
        for part in metrics.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0] == key else { continue }
            return Double(pair[1])
        }
        return nil
    }

    @MainActor
    func testDetailMetricsCacheHitPath() throws {
        let store = windowStore()
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 3, events: windowEvents()),
            events: []
        ))
        DetailMetrics.forceEnabledForTesting = true
        DetailMetrics.reset()
        defer {
            DetailMetrics.forceEnabledForTesting = nil
            DetailMetrics.reset()
        }

        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertTrue(viewModel.didRestoreWindowFromCache, "窗口缓存命中应在 init 内完成")
        XCTAssertNil(viewModel.detailMetricsValue, "详情视图出现前不暴露 detail-metrics")

        viewModel.markDetailViewAppeared()
        let value = try XCTUnwrap(viewModel.detailMetricsValue)
        XCTAssertTrue(value.contains("cacheHit=1"), "预热/缓存命中自证字段：\(value)")
        XCTAssertFalse(value.contains("firstFrameMs=-1"))
        XCTAssertTrue(value.contains("networkMs=-1"), "live snapshot 尚未到达")
        // Legacy keys stay in the same order for the UI-test parser; P1.5-B appends
        // window/cacheMs/fullMs/resumed at the end.
        let pattern = #"^firstFrameMs=\d+(\.\d+)?;cacheHit=1;networkMs=-1;beginEpochMs=\d+;sessionId=s1;window=\d+;cacheMs=\d+(\.\d+)?;fullMs=-1;resumed=0$"#
        XCTAssertNotNil(value.range(of: pattern, options: .regularExpression), "实际值: \(value)")
        XCTAssertGreaterThan(try XCTUnwrap(metricDouble(value, "beginEpochMs")), 1_700_000_000_000)
        XCTAssertNotEqual(try XCTUnwrap(metricDouble(value, "cacheMs")), -1, "缓存命中应记录 cacheMs")
        XCTAssertEqual(try XCTUnwrap(metricDouble(value, "resumed")), 0, "P1 resume 未落地前恒 0")

        // A live snapshot marks the network segment (cacheHit stays in the value).
        viewModel.applyStreamValue(snapshotJSON(cursor: 3, events: windowEvents()))
        let afterNetwork = try XCTUnwrap(viewModel.detailMetricsValue)
        XCTAssertFalse(afterNetwork.contains("networkMs=-1"), "live snapshot 到达后应记录 networkMs")
        XCTAssertTrue(afterNetwork.contains("cacheHit=1"))

        DetailMetrics.forceEnabledForTesting = false
        XCTAssertNil(DetailMetrics.valueString, "非 E2E 启动不暴露 detail 计时")
    }

    @MainActor
    func testDetailMetricsColdPathMarksWhenContentAppears() async throws {
        DetailMetrics.forceEnabledForTesting = true
        DetailMetrics.reset()
        defer {
            DetailMetrics.forceEnabledForTesting = nil
            DetailMetrics.reset()
        }

        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: windowStore())
        XCTAssertFalse(viewModel.didRestoreWindowFromCache, "无缓存 -> cacheHit=0")
        viewModel.markDetailViewAppeared()
        XCTAssertNil(viewModel.detailMetricsValue, "标题/内容都还没到时不能标记首帧")

        viewModel.applyStreamValue(snapshotJSON(cursor: 3, events: windowEvents()))
        await waitUntil {
            guard let value = viewModel.detailMetricsValue else { return false }
            return !value.contains("firstFrameMs=-1")
        }
        let value = try XCTUnwrap(viewModel.detailMetricsValue)
        XCTAssertTrue(value.contains("cacheHit=0"))
        XCTAssertFalse(value.contains("firstFrameMs=-1"), "live snapshot 内容渲染后标记首帧：\(value)")
        XCTAssertFalse(value.contains("networkMs=-1"))
        XCTAssertNotNil(metricDouble(value, "beginEpochMs"))
    }

    @MainActor
    func testPrewarmFirstVisibleCardComesFirst() throws {
        let store = listStore()
        let follow = TestJSON.value("""
        {"type":"baseline","value":{"items":[
          {"workspaceId":"w1","path":"/ws/a","title":"A","sessionIds":["a-old"]},
          {"workspaceId":"w2","path":"/ws/b","title":"B","sessionIds":["b-new"]}
        ],"archivedSessionIds":[],"pinnedSessionIds":[]}}
        """)
        let list = TestJSON.value("""
        {"items":[
          {"sessionId":"a-old","updatedAt":10,"cwd":"/ws/a","projections":{"values":{"title":"Old"}}},
          {"sessionId":"b-new","updatedAt":99,"cwd":"/ws/b","projections":{"values":{"title":"New"}}}
        ]}
        """)
        let viewModel = try seedCache(store: store, sessionList: list, follow: follow)
        let candidates = viewModel.prewarmCandidates(limit: 3)
        XCTAssertEqual(candidates.map(\.sessionId), ["a-old", "b-new"], "列表第一张卡片优先预热（bench 点它）")
    }

    @MainActor
    func testPrewarmWindowIsHitByNextDetailOpen() throws {
        // 预热写盘 -> 下一次打开同会话的 SessionViewModel 在 init 内命中该窗口。
        let store = windowStore()
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 3, events: windowEvents()),
            events: []
        ))
        let detail = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertTrue(detail.didRestoreWindowFromCache)
        XCTAssertEqual(detail.eventSeqs, [1, 2, 3])
    }

    // MARK: - 体验收尾: E2E in-app metrics (send / prewarm / detail session id)

    @MainActor
    func testSendMetricsLifecycle() {
        SendMetrics.forceEnabledForTesting = true
        defer {
            SendMetrics.forceEnabledForTesting = nil
            SendMetrics.reset()
        }
        SendMetrics.reset()
        SendMetrics.begin()
        SendMetrics.markAccepted()
        SendMetrics.markTurnVisible()
        let value = SendMetrics.valueString ?? ""
        XCTAssertTrue(value.contains("tapToAcceptedMs="), value)
        XCTAssertTrue(value.contains("tapToTurnVisibleMs="), value)
        XCTAssertFalse(value.contains("tapToAcceptedMs=-1"), value)
        XCTAssertFalse(value.contains("tapToTurnVisibleMs=-1"), value)
        XCTAssertTrue(value.contains("queued=0"), value)
        XCTAssertTrue(value.contains("failed=0"), value)
    }

    @MainActor
    func testSendMetricsQueuedAndFailedFlags() {
        SendMetrics.forceEnabledForTesting = true
        defer {
            SendMetrics.forceEnabledForTesting = nil
            SendMetrics.reset()
        }
        SendMetrics.reset()
        SendMetrics.begin()
        SendMetrics.markQueued()
        SendMetrics.markFailed()
        let value = SendMetrics.valueString ?? ""
        XCTAssertTrue(value.contains("queued=1"), value)
        XCTAssertTrue(value.contains("failed=1"), value)
        XCTAssertTrue(value.contains("tapToAcceptedMs=-1"), value)
    }

    @MainActor
    func testDetailMetricsIncludesOpenedSessionId() {
        DetailMetrics.forceEnabledForTesting = true
        defer {
            DetailMetrics.forceEnabledForTesting = nil
            DetailMetrics.reset()
        }
        DetailMetrics.reset()
        DetailMetrics.begin(sessionId: "session-abc")
        let value = DetailMetrics.valueString ?? ""
        XCTAssertTrue(value.contains("sessionId=session-abc"), value)
    }

    @MainActor
    func testStartupMetricsReportsConnectionMark() {
        StartupMetrics.forceEnabledForTesting = true
        defer {
            StartupMetrics.forceEnabledForTesting = nil
            StartupMetrics.reset()
        }
        StartupMetrics.reset()
        StartupMetrics.begin()
        StartupMetrics.markConnected()
        let value = StartupMetrics.valueString ?? ""
        XCTAssertTrue(value.contains("connMs="), value)
        XCTAssertFalse(value.contains("connMs=-1"), value)
    }

    // MARK: - P0 (remote perf): path-aware dialing + connect metrics

    func testPairingOriginSelectorClassifiesLANHosts() {
        XCTAssertTrue(PairingOriginSelector.isLANHost("192.168.1.10"))
        XCTAssertTrue(PairingOriginSelector.isLANHost("10.1.2.3"))
        XCTAssertTrue(PairingOriginSelector.isLANHost("172.16.0.9"))
        XCTAssertTrue(PairingOriginSelector.isLANHost("172.31.255.254"))
        XCTAssertTrue(PairingOriginSelector.isLANHost("169.254.1.1"))
        XCTAssertTrue(PairingOriginSelector.isLANHost("mac.local"))
        XCTAssertTrue(PairingOriginSelector.isLANHost("[fe80::1]"))
        XCTAssertTrue(PairingOriginSelector.isLANHost("fd12:3456::1"))
        XCTAssertFalse(PairingOriginSelector.isLANHost("203.0.113.10"), "公网 relay 裸 IP 属于 relay 候选")
        XCTAssertFalse(PairingOriginSelector.isLANHost("example.com"))
        XCTAssertFalse(PairingOriginSelector.isLANHost("172.15.0.1"), "172.15 不是私网段")
        XCTAssertFalse(PairingOriginSelector.isLANHost(nil))
    }

    func testDialCandidatesSkipsLANOnExpensivePath() throws {
        let lan = try XCTUnwrap(URL(string: "https://192.168.1.10:3466"))
        let relay = try XCTUnwrap(URL(string: "https://203.0.113.10:30000"))
        let all = [lan, relay]

        XCTAssertEqual(
            PairingOriginSelector.dialCandidates(all, prefersRelay: true).map(\.absoluteString),
            [relay.absoluteString],
            "蜂窝/昂贵网络：只拨 relay，不再付 LAN 探测超时"
        )
        XCTAssertEqual(
            PairingOriginSelector.dialCandidates(all, prefersRelay: false).map(\.absoluteString),
            all.map(\.absoluteString),
            "Wi-Fi：保持原有 LAN 优先顺序"
        )
        XCTAssertEqual(
            PairingOriginSelector.dialCandidates([lan], prefersRelay: true).map(\.absoluteString),
            [lan.absoluteString],
            "只有 LAN 候选时仍要尝试（如 Mac 未开 relay）"
        )
    }

    @MainActor
    func testConnectionMetricsSegments() {
        ConnectionMetrics.forceEnabledForTesting = true
        defer {
            ConnectionMetrics.forceEnabledForTesting = nil
            ConnectionMetrics.reset()
        }
        ConnectionMetrics.reset()
        ConnectionMetrics.begin(preferRelay: true)
        ConnectionMetrics.markCandidate("203.0.113.10")
        ConnectionMetrics.markAuth()
        ConnectionMetrics.markWS()
        ConnectionMetrics.markReady()
        ConnectionMetrics.markConnected()
        let value = ConnectionMetrics.valueString ?? ""
        XCTAssertTrue(value.contains("connectMs="), value)
        XCTAssertTrue(value.contains("candidateMs="), value)
        XCTAssertTrue(value.contains("authMs="), value)
        XCTAssertTrue(value.contains("wsMs="), value)
        XCTAssertTrue(value.contains("readyMs="), value)
        XCTAssertTrue(value.contains("host=203.0.113.10"), value)
        XCTAssertTrue(value.contains("relayFirst=1"), value)
        XCTAssertFalse(value.contains("connectMs=-1"), value)
        XCTAssertFalse(value.contains("authMs=-1"), value)
    }

    // MARK: - P1.5-B 详情秒开（首窗自适应 / 后台补齐 / 窗口元数据）

    func testSessionWindowPolicyPhoneSizing() {
        XCTAssertEqual(SessionWindowPolicy.firstWindowMessages(screenHeight: 667), 12, "小屏 12")
        XCTAssertEqual(SessionWindowPolicy.firstWindowMessages(screenHeight: 736), 12)
        XCTAssertEqual(SessionWindowPolicy.firstWindowMessages(screenHeight: 844), 16, "标准屏 16")
        XCTAssertEqual(SessionWindowPolicy.firstWindowMessages(screenHeight: 956), 20, "Pro Max 20")
        XCTAssertEqual(SessionWindowPolicy.fillMessages(firstWindow: 12), 40, "后台补齐仍是旧 40 条窗口")
        XCTAssertEqual(SessionWindowPolicy.fillMessages(firstWindow: 20), 40)
        XCTAssertEqual(SessionWindowPolicy.fillMessages(firstWindow: 50), 50, "补齐不会缩窗")
        XCTAssertEqual(
            SessionWindowPolicy.prewarmMessages(screenHeight: 956),
            SessionWindowPolicy.firstWindowMessages(screenHeight: 956),
            "预热写入与首开请求同一窗口（命中即完整首帧）"
        )
    }

    @MainActor
    func testColdOpenUsesPhoneSizedWindowAndPaintsFirstSnapshotSynchronously() throws {
        DetailMetrics.forceEnabledForTesting = true
        DetailMetrics.reset()
        defer {
            DetailMetrics.forceEnabledForTesting = nil
            DetailMetrics.reset()
        }
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: windowStore())
        XCTAssertEqual(viewModel.firstWindowMessages, SessionWindowPolicy.deviceFirstWindowMessages)
        XCTAssertTrue((12...20).contains(viewModel.firstWindowMessages), "首窗 12–20")
        XCTAssertEqual(viewModel.fillWindowMessages, 40)
        viewModel.markDetailViewAppeared()
        XCTAssertNil(viewModel.detailMetricsValue, "无内容时不能标记首帧")
        XCTAssertTrue(viewModel.rows.isEmpty, "无内容时不构建渲染行")

        viewModel.applyStreamValue(snapshotJSON(cursor: 3, events: windowEvents()))
        XCTAssertFalse(viewModel.rows.isEmpty, "首 snapshot 同步 rebuildRows，不等 40ms debounce")
        XCTAssertEqual(renderedUserTexts(viewModel.rows), ["hello"], "首帧行内容来自快照事件")
        let value = try XCTUnwrap(viewModel.detailMetricsValue)
        XCTAssertFalse(value.contains("firstFrameMs=-1"), value)
        XCTAssertFalse(value.contains("networkMs=-1"), value)
        XCTAssertEqual(try XCTUnwrap(metricDouble(value, "cacheHit")), 0)
        XCTAssertEqual(
            try XCTUnwrap(metricDouble(value, "window")),
            Double(viewModel.firstWindowMessages),
            "window 字段记录首请求窗口"
        )
        XCTAssertEqual(try XCTUnwrap(metricDouble(value, "fullMs")), -1, "hasMore=false 不需要补齐")
        XCTAssertEqual(try XCTUnwrap(metricDouble(value, "resumed")), 0)
        XCTAssertFalse(viewModel.needsFullWindowFill)
    }

    @MainActor
    func testLongSessionSchedulesBackgroundFillThenPromotesWideWindow() async throws {
        DetailMetrics.forceEnabledForTesting = true
        DetailMetrics.reset()
        defer {
            DetailMetrics.forceEnabledForTesting = nil
            DetailMetrics.reset()
        }
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: windowStore())
        viewModel.markDetailViewAppeared()
        // Small live window that reports older history.
        viewModel.applyStreamValue(snapshotJSON(cursor: 3, hasMore: true, events: windowEvents()))
        XCTAssertTrue(viewModel.needsFullWindowFill, "hasMore=true -> 需要后台补齐 40 条窗口")
        XCTAssertEqual(viewModel.eventSeqs, [1, 2, 3])
        let firstFrameValue = try XCTUnwrap(viewModel.detailMetricsValue)
        XCTAssertEqual(try XCTUnwrap(metricDouble(firstFrameValue, "fullMs")), -1, "补齐前 fullMs 未到")

        // The background-fill snapshot (wide window) replaces the small one.
        let wide = snapshotJSON(
            cursor: 5,
            title: "Wide session",
            hasMore: false,
            events: windowEvents() + [
                eventJSON("turn/end", seq: 4, data: "{\"turn\":1}"),
                eventJSON(
                    "user/message",
                    seq: 5,
                    data: "{\"content\":[{\"type\":\"text\",\"text\":\"more\"}],\"source\":{\"kind\":\"user\"}}"
                ),
            ]
        )
        viewModel.applyFillStreamValue(wide)
        XCTAssertFalse(viewModel.needsFullWindowFill, "补齐后不再需要 fill")
        XCTAssertEqual(viewModel.eventSeqs, [1, 2, 3, 4, 5])
        await waitForRowRebuild()
        let value = try XCTUnwrap(viewModel.detailMetricsValue)
        XCTAssertFalse(value.contains("fullMs=-1"), "补齐落地后记录 fullMs：\(value)")
        XCTAssertEqual(viewModel.title, "Wide session")
    }

    @MainActor
    func testWindowCacheCarriesFirstWindowAndResumeBaselineMetadata() throws {
        let store = windowStore()
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 3, hasMore: true, events: windowEvents()),
            events: [],
            windowMessages: 20,
            hasMore: true,
            p1Epoch: "epoch-1",
            p1Sid: 7
        ))
        let loaded = try XCTUnwrap(store.load(sessionId: "s1"))
        XCTAssertEqual(loaded.payload.windowMessages, 20)
        XCTAssertEqual(loaded.payload.hasMore, true)
        XCTAssertEqual(loaded.payload.p1Epoch, "epoch-1")
        XCTAssertEqual(loaded.payload.p1Sid, 7)

        // Legacy v2 payload (new optional fields absent) still loads: old caches
        // keep working after the app update (restore interprets it as the legacy
        // 40-message window: oldestSeq = earliest record, hasMoreOlder = hasMore).
        let legacy = windowPayload(
            schemaVersion: 2,
            snapshot: snapshotJSON(cursor: 3, events: windowEvents())
        )
        let data = try XCTUnwrap(CacheIO.encode(legacy))
        XCTAssertTrue(CacheIO.writeDataAtomically(data, to: store.fileURL(for: "s1")))
        let restored = try XCTUnwrap(store.load(sessionId: "s1"))
        XCTAssertEqual(restored.payload.schemaVersion, 2)
        XCTAssertNil(restored.payload.windowMessages)
        XCTAssertNil(restored.payload.hasMore)
        XCTAssertNil(restored.payload.p1Epoch)
        XCTAssertNil(restored.payload.p1Sid)
        XCTAssertNil(restored.payload.olderEvents)
        XCTAssertNil(restored.payload.oldestSeq)
        XCTAssertNil(restored.payload.hasMoreOlder)
    }

    // MARK: - task session-history: 已加载区间缓存（v3）/ v2 兼容 / 超限裁剪

    /// Raw "event" object (the "event" field of a session/page record).
    private func rawEvent(_ type: String, seq: Int) -> JSONValue {
        TestJSON.value(eventJSON(type, seq: seq, data: "{}"))
    }

    func testSessionWindowCacheRoundTripsLoadedOlderRange() throws {
        let store = windowStore()
        let older = (0...7).map { rawEvent("tool/call", seq: $0) }
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 10, events: windowEvents()),
            events: [],
            windowMessages: 20,
            hasMore: true,
            olderEvents: older,
            oldestSeq: 0,
            hasMoreOlder: true,
            hasReachedOldest: false
        ))
        let loaded = try XCTUnwrap(store.load(sessionId: "s1"))
        XCTAssertEqual(loaded.payload.schemaVersion, SessionWindowCacheStore.schemaVersion)
        XCTAssertEqual(loaded.payload.olderEvents, older)
        XCTAssertEqual(loaded.payload.oldestSeq, 0)
        XCTAssertEqual(loaded.payload.hasMoreOlder, true)
        XCTAssertEqual(loaded.payload.hasReachedOldest, false)
    }

    // MARK: - task-6: 粘滞终止位（v4）

    func testSessionWindowCacheRoundTripsStickyReachedOldest() throws {
        let store = windowStore()
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 10, events: windowEvents()),
            events: [],
            olderEvents: [rawEvent("tool/call", seq: 0)],
            oldestSeq: 0,
            hasMoreOlder: true,
            hasReachedOldest: true
        ))
        let loaded = try XCTUnwrap(store.load(sessionId: "s1"))
        XCTAssertEqual(loaded.payload.hasReachedOldest, true)

        // v3 payload（无该字段）仍可读，交给 VM 从 oldestSeq / 首条记录推导。
        var v3 = loaded.payload
        v3.schemaVersion = SessionWindowCacheStore.olderRangeSchemaVersion
        v3.hasReachedOldest = nil
        XCTAssertTrue(CacheIO.writeAtomically(v3, to: store.fileURL(for: "s1")))
        let legacy = try XCTUnwrap(store.load(sessionId: "s1"), "v3 缓存必须可读")
        XCTAssertEqual(legacy.payload.schemaVersion, SessionWindowCacheStore.olderRangeSchemaVersion)
        XCTAssertNil(legacy.payload.hasReachedOldest)
    }

    func testSessionWindowCacheReadsLegacyV2Payload() throws {
        let store = windowStore()
        let legacy = windowPayload(
            schemaVersion: 2,
            snapshot: snapshotJSON(cursor: 3, events: windowEvents())
        )
        XCTAssertTrue(CacheIO.writeAtomically(legacy, to: store.fileURL(for: "s1")))
        let loaded = try XCTUnwrap(store.load(sessionId: "s1"), "v2 缓存必须可读，升级不得直接丢弃")
        XCTAssertEqual(loaded.payload.schemaVersion, 2)
        XCTAssertNil(loaded.payload.olderEvents)
        XCTAssertNil(loaded.payload.oldestSeq)
        XCTAssertNil(loaded.payload.hasMoreOlder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: "s1").path))
    }

    func testSessionWindowCacheTrimsOlderRangeInsteadOfFailing() throws {
        let store = windowStore()
        let body = String(repeating: "x", count: 12_000)
        let older = (0..<400).map { seq in
            TestJSON.value("{\"type\":\"tool/result\",\"seq\":\(seq),\"data\":{\"text\":\(TestJSON.quoted(body))}}")
        }
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 3, events: windowEvents()),
            events: [],
            olderEvents: older,
            oldestSeq: 0,
            hasMoreOlder: false
        ), "超过 4MB 预算时裁剪最老历史，而不是整份缓存写入失败")
        let loaded = try XCTUnwrap(store.load(sessionId: "s1"))
        let kept = try XCTUnwrap(loaded.payload.olderEvents)
        XCTAssertLessThan(kept.count, older.count, "必须裁剪")
        XCTAssertEqual(kept.last, older.last, "保留最新的一段已加载历史")
        XCTAssertEqual(loaded.payload.hasMoreOlder, true, "被裁剪 -> 必须允许重新向上分页")
        XCTAssertNil(loaded.payload.oldestSeq, "被裁剪后 oldestSeq 由恢复时的记录推导")
    }

    @MainActor
    func testSessionViewModelRestoresPagedOlderRangeFromCache() throws {
        let store = windowStore()
        let older = (0...7).map { rawEvent("tool/call", seq: $0) }
        let window = [
            eventJSON("turn/start", seq: 8, data: "{\"turn\":1}"),
            eventJSON("user/message", seq: 9, data: "{\"content\":[],\"source\":{\"kind\":\"user\"}}"),
            eventJSON("assistant/message", seq: 10, data: "{\"message\":{\"content\":[]}}"),
        ]
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 10, events: window),
            events: [],
            windowMessages: 20,
            hasMore: true,
            olderEvents: older,
            oldestSeq: 0,
            hasMoreOlder: false
        ))
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertTrue(viewModel.isShowingCachedWindow)
        XCTAssertEqual(viewModel.eventSeqs, Array(0...10), "冷启动恢复 [oldestSeq, cursor] 整段，不退回 40 条窗口")
        XCTAssertEqual(viewModel.oldestLoadedSeq, 0)
        XCTAssertFalse(viewModel.hasMoreOlder)
    }

    @MainActor
    func testSessionViewModelLegacyV2CacheIsInterpretedAsFortyMessageWindow() throws {
        let store = windowStore()
        let legacy = windowPayload(
            schemaVersion: 2,
            snapshot: snapshotJSON(cursor: 3, hasMore: true, events: windowEvents())
        )
        XCTAssertTrue(CacheIO.writeAtomically(legacy, to: store.fileURL(for: "s1")))
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertTrue(viewModel.isShowingCachedWindow)
        XCTAssertEqual(viewModel.eventSeqs, [1, 2, 3], "v2 = 旧 40 条窗口：只有快照窗口内的记录")
        XCTAssertEqual(viewModel.oldestLoadedSeq, 1, "v2: oldestSeq = 最早记录")
        XCTAssertTrue(viewModel.hasMoreOlder, "v2: hasMoreOlder = 旧 hasMore（true）")
    }

    @MainActor
    func testSessionViewModelReconnectKeepsLoadedPagedHistory() throws {
        let store = windowStore()
        let older = (0...8).map { rawEvent("tool/call", seq: $0) }
        let window = [
            eventJSON("turn/start", seq: 9, data: "{\"turn\":1}"),
            eventJSON("user/message", seq: 10, data: "{\"content\":[],\"source\":{\"kind\":\"user\"}}"),
        ]
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 10, events: window),
            events: [],
            olderEvents: older,
            oldestSeq: 0,
            hasMoreOlder: true
        ))
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertEqual(viewModel.eventSeqs, Array(0...10))

        // 重连：新 snapshot 窗口 9...12 与已加载区间重叠，0...8 必须保留。
        viewModel.applyStreamValue(snapshotJSON(
            cursor: 12,
            title: "Live",
            hasMore: true,
            events: [
                eventJSON("user/message", seq: 9, data: "{\"content\":[],\"source\":{\"kind\":\"user\"}}"),
                eventJSON("assistant/message", seq: 10, data: "{\"message\":{\"content\":[]}}"),
                eventJSON("turn/end", seq: 11, data: "{\"turn\":1}"),
                eventJSON("turn/start", seq: 12, data: "{\"turn\":2}"),
            ]
        ))
        XCTAssertEqual(viewModel.eventSeqs, Array(0...12), "重连不得丢掉已加载的更早历史")
        XCTAssertEqual(viewModel.oldestLoadedSeq, 0)
        XCTAssertFalse(viewModel.hasMoreOlder, "已加载到 seq 0：重连后不得重新显示加载更早")
    }

    func testSessionWindowPoliciesCarryTurnWindowWithinHostBounds() {
        for messages in [12, 16, 20] {
            let window = SessionWindowPolicy.firstWindowTurnWindow(messages: messages)
            XCTAssertLessThanOrEqual(window.minMessages, messages, "Host 校验：minMessages <= maxMessages")
            XCTAssertGreaterThanOrEqual(window.minTurns, 6, "覆盖若干完整 turn")
            XCTAssertEqual(window.minTurns, SessionWindowPolicy.turnWindowMinTurns)
        }
        let fill = SessionWindowPolicy.fillWindowTurnWindow(messages: 40)
        XCTAssertLessThanOrEqual(fill.minMessages, 40)
        let page = SessionWindowPolicy.pageTurnWindow
        XCTAssertLessThanOrEqual(page.minMessages, SessionWindowPolicy.pageWindowMessages)
        XCTAssertTrue((40...60).contains(SessionWindowPolicy.pageWindowMessages), "分页步长 40–60 条消息")

        // Wire keys must match the Host schema exactly.
        let json = page.jsonValue
        XCTAssertEqual(Set((json.objectValue ?? [:]).keys), Set(["minMessages", "minTurns"]))
        XCTAssertEqual(json["minMessages"]?.intValue, Int64(page.minMessages))
        XCTAssertEqual(json["minTurns"]?.intValue, Int64(page.minTurns))
    }

    /// 证据测试：已加载 2000 条事件（~2MB）的窗口缓存冷启动恢复耗时（报告用；
    /// 宽松上限防止大缓存把首帧拖到秒级）。
    @MainActor
    func testSessionViewModelPagedHistoryColdRestoreCost() throws {
        let store = windowStore()
        let body = String(repeating: "工具输出内容 ", count: 40)
        // 真实会话的事件形状（turn/start -> user -> tool/call -> tool/result ->
        // assistant -> turn/end）。这里的 tool/result 是"孤儿结果"（没有匹配的
        // tool/call 行）：它曾触发 SessionRowBuilder 的 inout/闭包 exclusivity 崩溃，
        // 现在同时作为该 bug 的回归用例（分页历史事件里同样会出现孤儿工具结果）。
        let types = ["turn/start", "user/message", "tool/call", "tool/result", "assistant/message", "turn/end"]
        var older: [JSONValue] = []
        for seq in 0..<2000 {
            let type = types[seq % types.count]
            older.append(TestJSON.value(
                "{\"type\":\"\(type)\",\"seq\":\(seq),\"data\":{\"text\":\(TestJSON.quoted(body))}}"
            ))
        }
        let window = [
            eventJSON("turn/start", seq: 2000, data: "{\"turn\":1}"),
            eventJSON("user/message", seq: 2001, data: "{\"content\":[],\"source\":{\"kind\":\"user\"}}"),
        ]
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 2001, events: window),
            events: [],
            olderEvents: older,
            oldestSeq: 0,
            hasMoreOlder: false
        ))
        let size = fileSize(store.fileURL(for: "s1"))
        var samples: [Double] = []
        for _ in 0..<5 {
            let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
            XCTAssertEqual(viewModel.eventSeqs.count, 2002)
            samples.append(viewModel.cacheLoadMilliseconds)
        }
        let average = samples.reduce(0, +) / Double(samples.count)
        print("[session-history] paged-history cache restore: bytes=\(size) events=2002 avg=\(String(format: "%.2f", average))ms samples=\(samples.map { String(format: "%.2f", $0) })")
        XCTAssertLessThan(average, 500, "大历史缓存恢复不得慢到秒级（实测 \(String(format: "%.2f", average))ms）")
    }

    // MARK: - task-7: 非连续缓存窗口修复（洞 -> 前缀丢弃/假运行中）

    @MainActor
    func testCacheRestoreDropsNonContiguousOlderPrefix() throws {
        let store = windowStore()
        // 老前缀：turn 1–2（seq 0...7，自身连续）。带文本的消息用于证明：
        // 前缀被丢弃后，这些行不得出现在平铺流里。
        let olderPrefix = [
            eventJSON("turn/start", seq: 0, data: "{\"turn\":1}"),
            eventJSON("user/message", seq: 1, data: "{\"content\":[{\"type\":\"text\",\"text\":\"dropped turn 1 user\"}],\"source\":{\"kind\":\"user\"}}"),
            eventJSON("assistant/message", seq: 2, data: "{\"message\":{\"content\":[]}}"),
            eventJSON("turn/end", seq: 3, data: "{\"turn\":1}"),
            eventJSON("turn/start", seq: 4, data: "{\"turn\":2}"),
            eventJSON("user/message", seq: 5, data: "{\"content\":[{\"type\":\"text\",\"text\":\"dropped turn 2 user\"}],\"source\":{\"kind\":\"user\"}}"),
            eventJSON("assistant/message", seq: 6, data: "{\"message\":{\"content\":[]}}"),
            eventJSON("turn/end", seq: 7, data: "{\"turn\":2}"),
        ]
        // 新快照窗口：turn 8–9（seq 3005...3011，turn 9 已结束），与老前缀之间缺 8...3004。
        let window = [
            eventJSON("turn/start", seq: 3005, data: "{\"turn\":8}"),
            eventJSON("user/message", seq: 3006, data: "{\"content\":[{\"type\":\"text\",\"text\":\"turn 8 user\"}],\"source\":{\"kind\":\"user\"}}"),
            eventJSON("assistant/message", seq: 3007, data: "{\"message\":{\"content\":[]}}"),
            eventJSON("turn/end", seq: 3008, data: "{\"turn\":8}"),
            eventJSON("turn/start", seq: 3009, data: "{\"turn\":9}"),
            eventJSON("user/message", seq: 3010, data: "{\"content\":[{\"type\":\"text\",\"text\":\"turn 9 user\"}],\"source\":{\"kind\":\"user\"}}"),
            eventJSON("turn/end", seq: 3011, data: "{\"turn\":9}"),
        ]
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 3011, hasMore: true, events: window),
            events: [],
            olderEvents: olderPrefix.map { TestJSON.value($0) },
            oldestSeq: 0,
            hasMoreOlder: false,
            hasReachedOldest: false
        ))
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertTrue(viewModel.isShowingCachedWindow)
        // 洞被丢弃：窗口 = 快照窗口（连续）——平铺流里只应有快照窗口产生的行，
        // 被丢弃前缀的 turn 1/2 消息不得渲染成行；窗口尾部 turn/end 已结束，
        // 已完成的会话不得报告运行中。
        XCTAssertEqual(viewModel.eventSeqs, Array(3005...3011), "不连续老前缀必须丢弃")
        XCTAssertEqual(
            renderedUserTexts(viewModel.rows),
            ["turn 8 user", "turn 9 user"],
            "只渲染连续快照窗口的行，被丢弃前缀的 turn 1/2 行不得出现"
        )
        XCTAssertEqual(viewModel.rows.map(\.seq), [3006, 3010], "行按事件顺序渲染（turn 边界不产生行）")
        XCTAssertFalse(viewModel.isRunning, "窗口最新一轮已结束：已完成会话不得报告运行中")
        XCTAssertEqual(viewModel.oldestLoadedSeq, 3005)
        XCTAssertTrue(viewModel.hasMoreOlder, "丢弃前缀后必须允许重新拉取更早历史")
        XCTAssertFalse(viewModel.reachedFirstEvent)
    }

    @MainActor
    func testCacheRestoreKeepsOnlyContiguousSuffixOfOlderRange() throws {
        let store = windowStore()
        // 老前缀 seq 0...8 中缺 4（内部洞）：只保留与快照相接的 5...8。
        let older = [0, 1, 2, 3, 5, 6, 7, 8].map { seq in
            TestJSON.value(eventJSON("tool/call", seq: seq, data: "{}"))
        }
        let window = [
            eventJSON("turn/start", seq: 9, data: "{\"turn\":3}"),
            eventJSON("user/message", seq: 10, data: "{\"content\":[],\"source\":{\"kind\":\"user\"}}"),
            eventJSON("turn/end", seq: 11, data: "{\"turn\":3}"),
            eventJSON("turn/start", seq: 12, data: "{\"turn\":4}"),
        ]
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 12, hasMore: true, events: window),
            events: [],
            olderEvents: older,
            oldestSeq: 0,
            hasMoreOlder: false,
            hasReachedOldest: false
        ))
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertEqual(viewModel.eventSeqs, Array(5...12), "只保留与快照相接的连续后缀")
        XCTAssertEqual(viewModel.oldestLoadedSeq, 5)
        XCTAssertTrue(viewModel.hasMoreOlder, "丢弃的 0...4 需要重新拉取")
    }

    @MainActor
    func testSnapshotJumpDropsStaleOlderFramesFromCache() async throws {
        let store = windowStore()
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        viewModel.applyStreamValue(snapshotJSON(cursor: 3, hasMore: true, events: windowEvents()))
        // 先分页拿到一页旧前缀（缓存里出现 olderEvents）。
        viewModel.olderPageLoader = { _ in
            .object([
                "records": .array([
                    .object([
                        "type": .string("event"),
                        "event": TestJSON.value(self.eventJSON(
                            "user/message", seq: 0,
                            data: "{\"content\":[],\"source\":{\"kind\":\"user\"}}"
                        )),
                    ]),
                ]),
                "hasMore": .bool(false),
            ])
        }
        await viewModel.loadOlderPageNowForTesting()
        XCTAssertEqual(viewModel.eventSeqs, Array(0...3))
        viewModel.saveWindowCacheNow()
        XCTAssertNotNil(store.load(sessionId: "s1")?.payload.olderEvents, "前置历史已进缓存")

        // 窗口整体跳远（与本窗口不连续）：旧前缀不得留在缓存里，否则下次冷启动带洞。
        let jumped = snapshotJSON(cursor: 50, hasMore: true, events: [
            eventJSON("turn/start", seq: 45, data: "{\"turn\":9}"),
            eventJSON("user/message", seq: 46, data: "{\"content\":[],\"source\":{\"kind\":\"user\"}}"),
        ])
        viewModel.applyStreamValue(jumped)
        XCTAssertEqual(viewModel.eventSeqs, [45, 46])
        viewModel.saveWindowCacheNow()
        let payload = try XCTUnwrap(store.load(sessionId: "s1")?.payload)
        XCTAssertNil(payload.olderEvents, "跳远后旧前缀必须从缓存清掉")
    }

    // MARK: - task-7 (a 补强)：粘滞“已到最早”与不连续前缀丢弃的交互

    /// 真实冷启动场景：用户上一次已经翻到过 turn 1（cache 粘滞位 hasReachedOldest=true），
    /// 之后重连快照把窗口整体跳到 turn 8-9（seq 3005...）。恢复时老前缀与快照之间缺
    /// seq 8...3004：必须丢弃前缀、保持窗口连续、只渲染快照窗口产生的行，并且不能把缓存的粘滞位
    /// 当成“已到最早”沿用——窗口已不含 seq 0，hasMoreOlder 必须重新为 true（§4.1 的粘滞
    /// 语义只在窗口真的到达最早事件时成立）。
    @MainActor
    func testCacheRestoreClearsStickyOldestWhenPrefixIsDropped() throws {
        let store = windowStore()
        // 老前缀：turn 1-2（seq 0...7，自身连续）。带文本的消息用于证明：
        // 前缀被丢弃后，这些行不得出现在平铺流里。
        let olderPrefix = [
            eventJSON("turn/start", seq: 0, data: #"{"turn":1}"#),
            eventJSON("user/message", seq: 1, data: #"{"content":[{"type":"text","text":"dropped turn 1 user"}],"source":{"kind":"user"}}"#),
            eventJSON("assistant/message", seq: 2, data: #"{"message":{"content":[]}}"#),
            eventJSON("turn/end", seq: 3, data: #"{"turn":1}"#),
            eventJSON("turn/start", seq: 4, data: #"{"turn":2}"#),
            eventJSON("user/message", seq: 5, data: #"{"content":[{"type":"text","text":"dropped turn 2 user"}],"source":{"kind":"user"}}"#),
            eventJSON("assistant/message", seq: 6, data: #"{"message":{"content":[]}}"#),
            eventJSON("turn/end", seq: 7, data: #"{"turn":2}"#),
        ]
        // 新快照窗口：turn 8-9（seq 3005...3011，turn 9 已结束），与老前缀之间缺 8...3004。
        let window = [
            eventJSON("turn/start", seq: 3005, data: #"{"turn":8}"#),
            eventJSON("user/message", seq: 3006, data: #"{"content":[{"type":"text","text":"turn 8 user"}],"source":{"kind":"user"}}"#),
            eventJSON("assistant/message", seq: 3007, data: #"{"message":{"content":[]}}"#),
            eventJSON("turn/end", seq: 3008, data: #"{"turn":8}"#),
            eventJSON("turn/start", seq: 3009, data: #"{"turn":9}"#),
            eventJSON("user/message", seq: 3010, data: #"{"content":[{"type":"text","text":"turn 9 user"}],"source":{"kind":"user"}}"#),
            eventJSON("turn/end", seq: 3011, data: #"{"turn":9}"#),
        ]
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 3011, hasMore: true, events: window),
            events: [],
            olderEvents: olderPrefix.map { TestJSON.value($0) },
            oldestSeq: 0,
            hasMoreOlder: false,
            hasReachedOldest: true
        ))
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertTrue(viewModel.isShowingCachedWindow)
        // 不连续老前缀必须整体丢弃：恢复后的窗口严格连续。
        XCTAssertEqual(viewModel.eventSeqs, Array(3005...3011), "不连续老前缀必须丢弃")
        // 平铺流只含快照窗口产生的行：不会出现被丢弃前缀（turn 1/2）的行。
        XCTAssertEqual(
            renderedUserTexts(viewModel.rows),
            ["turn 8 user", "turn 9 user"],
            "只渲染连续快照窗口的行，被丢弃前缀的 turn 1/2 行不得出现"
        )
        XCTAssertEqual(viewModel.rows.map(\.seq), [3006, 3010], "行按事件顺序渲染（turn 边界不产生行）")
        // 窗口尾部 turn/end 已结束：已完成会话不得报告运行中。
        XCTAssertFalse(viewModel.isRunning, "已完成会话不得报告运行中")
        // 丢弃前缀 = 确实还有更早历史要重新拉：hasMoreOlder 必须为 true。
        XCTAssertTrue(viewModel.hasMoreOlder, "丢弃前缀后放开分页")
        // 粘滞位不得沿用：窗口已不含 seq 0。
        XCTAssertFalse(viewModel.reachedFirstEvent, "粘滞 hasReachedOldest 必须被清掉")
    }

    /// task-7 (b 补强)：重连快照整体跳远 → 旧前缀不得写进缓存，且写出的缓存
    /// 重新带 hasMoreOlder=true / oldestSeq=新快照最老；从这份缓存再冷启动一次，
    /// 窗口仍连续、分页入口还在（不会因为一次跳远把缓存写成洞）。
    @MainActor
    func testSnapshotJumpDropsPrefixAndReArmsPaginationOnReopen() async throws {
        let store = windowStore()
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        viewModel.applyStreamValue(snapshotJSON(
            cursor: 20,
            hasMore: true,
            events: (15...20).map { eventJSON("tool/call", seq: $0, data: "{}") }
        ))
        // 先分页拿到一页旧前缀（10...14），缓存里出现 olderEvents。
        viewModel.olderPageLoader = { _ in
            .object([
                "records": .array((10...14).map { seq in
                    .object([
                        "type": .string("event"),
                        "event": TestJSON.value(self.eventJSON("tool/call", seq: seq, data: "{}")),
                    ])
                }),
                "hasMore": .bool(true),
            ])
        }
        await viewModel.loadOlderPageNowForTesting()
        XCTAssertEqual(viewModel.oldestLoadedSeq, 10)
        XCTAssertTrue(viewModel.hasMoreOlder)
        viewModel.saveWindowCacheNow()
        XCTAssertNotNil(store.load(sessionId: "s1")?.payload.olderEvents, "前置历史已进缓存")

        // 窗口整体跳远（seq 45... 与 10...20 不连续）：旧前缀必须丢弃，不写进缓存。
        viewModel.applyStreamValue(snapshotJSON(
            cursor: 46,
            hasMore: true,
            events: (45...46).map { eventJSON("tool/call", seq: $0, data: "{}") }
        ))
        XCTAssertEqual(viewModel.eventSeqs, [45, 46])
        viewModel.saveWindowCacheNow()
        let payload = try XCTUnwrap(store.load(sessionId: "s1")?.payload)
        XCTAssertNil(payload.olderEvents, "跳远后旧前缀不得写进缓存")
        XCTAssertEqual(payload.oldestSeq, 45, "缓存的 oldestSeq 必须对齐新快照")
        XCTAssertEqual(payload.hasMoreOlder, true, "旧前缀被丢弃 → 需重新拉取，缓存要带 hasMoreOlder=true")

        // 用这份缓存冷启动：窗口连续、分页仍可用（缓存没被写成洞）。
        let reopened = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertTrue(reopened.isShowingCachedWindow)
        XCTAssertEqual(reopened.eventSeqs, [45, 46], "冷启动窗口严格连续")
        XCTAssertTrue(reopened.hasMoreOlder, "重新打开后分页入口仍在")
        XCTAssertFalse(reopened.reachedFirstEvent)
    }

    // MARK: - task-5：缓存里的“已无更早历史”与恢复窗口 front 不一致 → 重新武装分页

    /// 真机取证（session-daa07b5a…）：cache payload 由旧构建写成 hasMoreOlder=false（+
    /// hasReachedOldest=true），但恢复出的窗口最老 seq=3232 > 0，而该 session 实际从
    /// seq 0 开始。若直接采纳缓存状态，“加载更早”入口会永久消失（用户回不到 turn 1-7）。
    /// 收尾一致性 gate 必须在 oldestSeq>0 且 !hasMoreOlder 时重新武装分页。
    @MainActor
    func testCacheRestoreReArmsPaginationWhenCachedStateSaysTerminal() async throws {
        let store = windowStore()
        // 连续 olderEvents(3232...3234) + snapshot(3235...3240)：窗口无洞，修复路径不会触发，
        // 只有一致性 gate 能救回分页入口。
        let older = (3232...3234).map { TestJSON.value(eventJSON("tool/call", seq: $0, data: "{}")) }
        let window = (3235...3240).map { eventJSON("tool/call", seq: $0, data: "{}") }
        XCTAssertTrue(store.save(
            sessionId: "s1",
            snapshot: snapshotJSON(cursor: 3240, hasMore: true, events: window),
            events: [],
            olderEvents: older,
            oldestSeq: 3232,
            hasMoreOlder: false,
            hasReachedOldest: true
        ))
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertTrue(viewModel.isShowingCachedWindow)
        XCTAssertEqual(viewModel.eventSeqs, Array(3232...3240), "恢复后窗口保持连续")
        XCTAssertEqual(viewModel.oldestLoadedSeq, 3232)
        XCTAssertTrue(viewModel.hasMoreOlder, "oldest>0 时“已无更早历史”是假终态，必须重新武装")
        XCTAssertFalse(viewModel.reachedFirstEvent, "粘滞终态必须被清掉（窗口不含 seq 0）")

        // 重新武装后 loadOlderIfNeeded 必须真的发请求（入口不是摆设）。
        var calls = 0
        viewModel.olderPageLoader = { _ in
            calls += 1
            return .object([:])
        }
        viewModel.loadOlderIfNeeded()
        await waitForRowRebuild()
        XCTAssertEqual(calls, 1, "重新武装后分页请求必须发出")
    }

    /// 合法终态不被误伤：缓存窗口真的覆盖到 seq 0 时保持粘滞终止（本次 gate 不生效）。
    @MainActor
    func testCacheRestoreKeepsLegalTerminalStateAtFirstEvent() async throws {
        let store = windowStore()
        let older = (0...2).map { TestJSON.value(eventJSON("tool/call", seq: $0, data: "{}")) }
        let window = (3...5).map { eventJSON("tool/call", seq: $0, data: "{}") }
        XCTAssertTrue(store.save(
            sessionId: "s2",
            snapshot: snapshotJSON(cursor: 5, hasMore: false, events: window),
            events: [],
            olderEvents: older,
            oldestSeq: 0,
            hasMoreOlder: false,
            hasReachedOldest: true
        ))
        let viewModel = SessionViewModel(address: .session(sessionId: "s2"), windowCache: store)
        XCTAssertEqual(viewModel.eventSeqs, Array(0...5))
        XCTAssertEqual(viewModel.oldestLoadedSeq, 0)
        XCTAssertFalse(viewModel.hasMoreOlder, "真的到 seq 0 → 合法终态，不得重新武装")
        XCTAssertTrue(viewModel.reachedFirstEvent)

        var calls = 0
        viewModel.olderPageLoader = { _ in
            calls += 1
            return .object([:])
        }
        viewModel.loadOlderIfNeeded()
        await waitForRowRebuild()
        XCTAssertEqual(calls, 0, "已到最早事件，不得再发分页请求")
    }
}

