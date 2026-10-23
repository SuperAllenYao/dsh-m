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

    // MARK: - v5 首屏缓存 fixtures（2026-10-23：4 屏 chunked cache，无 olderEvents）

    /// 把原始 event JSON 字符串数组解析成时间序事件（缓存 save/断言共用）。
    private func cachedEvents(_ raw: [String]) -> [SessionEvent] {
        raw.compactMap { try? TestJSON.value($0).decode(SessionEvent.self) }
    }

    /// 跨多屏的连续事件（turn 边界 + user/assistant 消息），用于分屏/合并断言。
    private func firstPaintEvents(count: Int = 24, startSeq: Int = 0) -> [SessionEvent] {
        var events: [SessionEvent] = []
        for offset in 0..<count {
            let seq = startSeq + offset
            let append = JSONValue.string("append")
            let time = 1_792_510_000_000 + Int64(seq)
            switch offset % 4 {
            case 0:
                events.append(SessionEvent(
                    type: "turn/start", seq: seq, time: time,
                    data: .object(["turn": .int(Int64(offset / 4 + 1))]),
                    surfaceOp: nil, sourceEventSeqs: nil
                ))
            case 1:
                events.append(SessionEvent(
                    type: "user/message", seq: seq, time: time,
                    data: .object([
                        "content": .array([.object([
                            "type": .string("text"),
                            "text": .string("user-\(seq)"),
                        ])]),
                        "source": .object(["kind": .string("user")]),
                    ]),
                    surfaceOp: append, sourceEventSeqs: nil
                ))
            case 2:
                events.append(SessionEvent(
                    type: "assistant/message", seq: seq, time: time,
                    data: .object([
                        "message": .object([
                            "content": .array([.object([
                                "type": .string("text"),
                                "text": .string("assistant-\(seq)"),
                            ])]),
                        ]),
                    ]),
                    surfaceOp: append, sourceEventSeqs: nil
                ))
            default:
                events.append(SessionEvent(
                    type: "turn/end", seq: seq, time: time,
                    data: .object(["turn": .int(Int64(offset / 4 + 1))]),
                    surfaceOp: nil, sourceEventSeqs: nil
                ))
            }
        }
        return events
    }

    /// 直接写原始缓存字节（损坏 / 旧 schema / 身份不符用例绕过 save 的校验）。
    @discardableResult
    private func writeRawWindowFile(_ text: String, sessionId: String = "s1") throws -> URL {
        let url = windowStore().fileURL(for: sessionId)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// 合法的 v5 原始 payload JSON（写旧 schema / TTL 变体用；日期用 secondsSince1970）。
    private func rawWindowPayloadJSON(
        schemaVersion: Int = SessionWindowCacheStore.schemaVersion,
        sessionId: String = "s1",
        identity: String = CacheTests.pairingIdentity,
        savedAt: Date = Date(),
        cursor: Int = 3,
        events: [SessionEvent] = []
    ) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let encodedEvents = (try? encoder.encode(events)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "[]"
        return "{\"schemaVersion\":\(schemaVersion),\"savedAt\":\(savedAt.timeIntervalSince1970),"
            + "\"identity\":\"\(identity)\",\"sessionId\":\"\(sessionId)\","
            + "\"cursor\":\(cursor),\"hasMore\":false,\"chunks\":[\(encodedEvents)],"
            + "\"windowMessages\":16}"
    }
    /// firstPaintEvents 对应的原始 event JSON 字符串（snapshotJSON 用）。
    private func firstPaintEventJSON(count: Int = 24, startSeq: Int = 0) -> [String] {
        let encoder = JSONEncoder()
        return firstPaintEvents(count: count, startSeq: startSeq).compactMap { event in
            guard let data = try? encoder.encode(event) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// ~800KB 级会话列表 wire 快照（真机 busy machine bench 档）。
    /// projections 里放紧凑快照不保留的大字段，保留 raw 与 compact 的体积差（M2b-2b 断言用）。
    private func largeListJSON(sessionCount: Int = 200) -> JSONValue {
        let blob = String(repeating: "z", count: 4000)
        let items = (0..<sessionCount).map { index in
            """
            {"sessionId":"session-\(index)","updatedAt":\(1_792_500_000 + index),"cwd":"/ws/\(index % 4)","running":\(index % 7 == 0 ? "true" : "false"),
             "projections":{"values":{"title":"Busy session \(index)","sessionListMetadata":{"lastPromptAt":\(1_792_500_000 + index)},"modelSelectionBlob":"\(blob)"}}}
            """
        }.joined(separator: ",")
        return TestJSON.value("{\"items\":[\(items)]}")
    }

    private func largeFollowJSON(workspaceCount: Int = 4, sessionCount: Int = 200) -> JSONValue {
        let groups = (0..<workspaceCount).map { workspace -> String in
            let ids = stride(from: workspace, to: sessionCount, by: workspaceCount)
                .map { "\"session-\($0)\"" }
                .joined(separator: ",")
            return "{\"workspaceId\":\"w\(workspace)\",\"path\":\"/ws/\(workspace)\",\"title\":\"Workspace \(workspace)\",\"sessionIds\":[\(ids)]}"
        }.joined(separator: ",")
        return TestJSON.value("{\"type\":\"baseline\",\"value\":{\"items\":[\(groups)],\"archivedSessionIds\":[],\"pinnedSessionIds\":[]}}")
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

    // MARK: - 会话窗口缓存（v5，4 屏 chunked）：往返 / 分屏 / 旧 schema / 损坏 / TTL / 上限

    func testSessionWindowCacheRoundTripKeepsChunksAndMetadata() throws {
        let store = windowStore()
        let events = firstPaintEvents(count: 24)
        XCTAssertTrue(store.save(
            sessionId: "s1", cursor: 23, hasMore: true, header: nil, projections: nil,
            events: events, windowMessages: 16
        ))
        let loaded = try XCTUnwrap(store.load(sessionId: "s1"))
        XCTAssertEqual(loaded.payload.schemaVersion, SessionWindowCacheStore.schemaVersion)
        XCTAssertEqual(loaded.payload.schemaVersion, 5)
        XCTAssertEqual(loaded.payload.cursor, 23)
        XCTAssertEqual(loaded.payload.hasMore, true)
        XCTAssertEqual(loaded.payload.oldestSeq, 0)
        XCTAssertEqual(loaded.payload.newestSeq, 23)
        XCTAssertEqual(loaded.payload.chunks.flatMap { $0 }.map(\.seq).sorted(), Array(0...23))
        XCTAssertFalse(loaded.isStale)
    }

    func testScreenChunksAreNewestFirstAndGapFree() throws {
        let events = firstPaintEvents(count: 80) // 40 append 消息 / 每屏 10 条
        let chunks = SessionWindowCacheStore.screenChunks(
            events: events, messagesPerScreen: 10, screens: 4
        )
        XCTAssertEqual(chunks.count, 4, "默认只缓存 4 屏")
        XCTAssertEqual(chunks.first?.last?.seq, 79, "chunk0 = 最新一屏")
        let flattened = chunks.reversed().flatMap { $0 }
        XCTAssertEqual(flattened.map(\.seq).sorted(), flattened.map(\.seq), "拼接后必须按 seq 升序")
        XCTAssertEqual(Array(Set(flattened.map(\.seq))).count, flattened.count, "chunk 之间不得重复")
        for (older, newer) in zip(flattened, flattened.dropFirst()) {
            XCTAssertEqual(newer.seq, older.seq + 1, "chunk 边界必须连续（无空洞）")
        }
    }

    func testSessionWindowCacheDropsLegacySchemaAndRemovesFile() throws {
        let url = try writeRawWindowFile(rawWindowPayloadJSON(schemaVersion: 4))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(windowStore().load(sessionId: "s1"), "v4 旧 schema 一律丢弃（分页缓存不再兼容）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "旧 schema 文件在读取时删除")
    }

    func testSessionWindowCacheRejectsCorruptPayload() throws {
        let url = try writeRawWindowFile("{not json at all")
        XCTAssertNil(windowStore().load(sessionId: "s1"), "损坏 payload 静默回退冷启动")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "损坏文件读取时删除")
    }

    func testSessionWindowCacheTTLFlagsStaleAndRetentionDrops() throws {
        let staleAt = Date().addingTimeInterval(-(CacheSchema.ttl + 3600))
        let events = cachedEvents(windowEvents())
        XCTAssertTrue(windowStore().save(
            sessionId: "s1", cursor: 3, hasMore: false, header: nil, projections: nil,
            events: events, windowMessages: 16
        ))
        // 先用合法 save 写一份，再把 savedAt 前移模拟 25h 前的 payload。
        let staleJSON = rawWindowPayloadJSON(savedAt: staleAt, events: events)
        let staleURL = try writeRawWindowFile(staleJSON)
        let stale = try XCTUnwrap(windowStore().load(sessionId: "s1"))
        XCTAssertTrue(stale.isStale, "超过 24h TTL -> 仍可展示但标记 stale")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleURL.path))

        let expiredAt = Date().addingTimeInterval(-(CacheSchema.retention + 3600))
        try writeRawWindowFile(rawWindowPayloadJSON(savedAt: expiredAt, events: events))
        XCTAssertNil(windowStore().load(sessionId: "s1"), "超过 7d retention -> 直接丢弃")
    }

    func testSessionWindowCacheDropsOldestChunksOverByteBudget() throws {
        let big = String(repeating: "x", count: 400_000)
        let events = (0..<12).map { seq -> SessionEvent in
            SessionEvent(
                type: "assistant/message", seq: seq, time: 1_792_510_000_000 + Int64(seq),
                data: .object([
                    "message": .object([
                        "content": .array([.object([
                            "type": .string("text"),
                            "text": .string(big + String(seq)),
                        ])]),
                    ]),
                ]),
                surfaceOp: .string("append"), sourceEventSeqs: nil
            )
        }
        XCTAssertTrue(windowStore().save(
            sessionId: "s1", cursor: 11, hasMore: true, header: nil, projections: nil,
            events: events, windowMessages: 16, messagesPerScreen: 3, screens: 4
        ))
        let loaded = try XCTUnwrap(windowStore().load(sessionId: "s1"), "裁剪最老屏后仍应可读")
        XCTAssertLessThan(loaded.payload.chunks.count, 4, "超过 4MB 上限时从最老 chunk 开始裁")
        XCTAssertEqual(loaded.payload.chunks.first?.last?.seq, 11, "最新一屏必须保留")
    }

    func testSessionWindowCacheRequiresNonEmptyEvents() throws {
        XCTAssertFalse(windowStore().save(
            sessionId: "s1", cursor: 3, hasMore: true, header: nil, projections: nil,
            events: [], windowMessages: 16
        ), "空事件窗口不写缓存（下次走 live snapshot 首屏）")
        XCTAssertNil(windowStore().load(sessionId: "s1"))
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

    // MARK: - 详情首屏缓存（v5）：init 不阻塞 / chunk0 先上屏 / 后台合并 / live 快照去重

    @MainActor
    func testSessionViewModelInitNeverBlocksOnCacheAndRestoresOffMain() async throws {
        let store = windowStore()
        XCTAssertTrue(store.save(
            sessionId: "s1", cursor: 3, hasMore: true, header: nil, projections: nil,
            events: cachedEvents(windowEvents()), windowMessages: 16
        ))
        let started = Date()
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        let initMs = Date().timeIntervalSince(started) * 1000
        XCTAssertLessThan(initMs, 100, "init 不得同步读盘/解码（改动前 4MB 缓存 ~152ms）: \(initMs)ms")
        XCTAssertTrue(viewModel.eventSeqs.isEmpty, "init 返回时缓存恢复尚未开始（off-main）")
        await viewModel.awaitFirstPaintCacheForTesting()
        XCTAssertTrue(viewModel.didRestoreFirstPaintCache, "off-main 缓存命中")
        XCTAssertTrue(viewModel.isShowingCachedWindow)
        XCTAssertEqual(viewModel.eventSeqs, [1, 2, 3], "chunk0 必须先上屏")
        XCTAssertEqual(renderedUserTexts(viewModel.rows), ["hello"])
    }

    /// 2026-10-23 真机/模拟器回归：热缓存 + 快链路时，off-main 的首屏缓存恢复可能
    /// 晚于 live `session/follow` 快照到达。恢复侧不得把 `isShowingCachedWindow`
    /// 再置 true，否则「显示本地缓存，正在同步…」横幅/菊花会永久卡死（没有下一帧
    /// 快照来清它）。真机手动复现：会话 idle、补齐已完成，横幅 65s 仍在。
    @MainActor
    func testLateCacheRestoreDoesNotReArmCacheBannerAfterLiveSnapshot() async throws {
        let store = windowStore()
        XCTAssertTrue(store.save(
            sessionId: "s1", cursor: 3, hasMore: true, header: nil, projections: nil,
            events: cachedEvents(windowEvents()), windowMessages: 16
        ))
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        // live 快照先到（缓存恢复还在 off-main 读盘/解码）。
        viewModel.applyStreamValue(snapshotJSON(cursor: 3, events: windowEvents()))
        await waitForRowRebuild()
        XCTAssertTrue(viewModel.hasLiveSnapshot, "live 快照已落地")
        XCTAssertFalse(viewModel.isShowingCachedWindow, "快照帧后不应再展示缓存横幅")

        await viewModel.awaitFirstPaintCacheForTesting()
        XCTAssertTrue(viewModel.didRestoreFirstPaintCache, "缓存数据仍要恢复（只是不挂横幅）")
        XCTAssertFalse(viewModel.isShowingCachedWindow,
                       "快照之后才完成的缓存恢复不得重新挂「显示本地缓存，正在同步…」")
        XCTAssertFalse(viewModel.cachedWindowIsStale, "快照之后才完成的缓存恢复不得标记缓存过期")
    }

    /// 2026-10-23 真机闪回修复后：首屏缓存**只应用 chunk0（最新一屏）**。
    /// 其余缓存屏不再逐块 prepend 进可见列表（每块都会重建 rows + 滚底，真机上表现为
    /// 内容出现后整页快速闪两次 + 视口上跳再回底）；更早历史交给后台补齐引擎。
    @MainActor
    func testFirstPaintCacheRestoresOnlyNewestScreen() async throws {
        let store = windowStore()
        let events = firstPaintEvents(count: 100) // 50 append 消息 -> 3 屏
        XCTAssertTrue(store.save(
            sessionId: "s1", cursor: 99, hasMore: true, header: nil, projections: nil,
            events: events, windowMessages: 16
        ))
        let expectedChunk0 = try XCTUnwrap(store.load(sessionId: "s1")?.payload.chunks.first)
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        await viewModel.awaitFirstPaintCacheForTesting()
        XCTAssertTrue(viewModel.didRestoreFirstPaintCache)
        XCTAssertEqual(viewModel.eventSeqs.last, 99, "chunk0 = 最新一屏，先上屏")
        XCTAssertEqual(viewModel.eventSeqs, expectedChunk0.map(\.seq), "只应用 chunk0，其余屏不再中途插入")
        XCTAssertLessThan(viewModel.eventSeqs.count, 100, "其余缓存屏不逐块插入（避免真机闪回）")
    }

    @MainActor
    func testLiveSnapshotReplacesCachedWindowWithoutDuplicates() async throws {
        let store = windowStore()
        XCTAssertTrue(store.save(
            sessionId: "s1", cursor: 3, hasMore: true, header: nil, projections: nil,
            events: cachedEvents(windowEvents()), windowMessages: 16
        ))
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        await viewModel.awaitFirstPaintCacheForTesting()
        XCTAssertTrue(viewModel.didRestoreFirstPaintCache)
        viewModel.applyStreamValue(snapshotJSON(cursor: 5, events: windowEvents() + [
            eventJSON(
                "user/message",
                seq: 4,
                data: "{\"content\":[{\"type\":\"text\",\"text\":\"live\"}],\"source\":{\"kind\":\"user\"}}"
            ),
            eventJSON(
                "assistant/message",
                seq: 5,
                data: "{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"live-reply\"}]}}"
            ),
        ]))
        await waitForRowRebuild()
        XCTAssertEqual(Set(viewModel.eventSeqs).count, viewModel.eventSeqs.count, "live 快照与缓存窗口去重后不得有重复 seq")
        XCTAssertEqual(viewModel.eventSeqs, [1, 2, 3, 4, 5])
        XCTAssertEqual(renderedUserTexts(viewModel.rows), ["hello", "live"])
    }

    @MainActor
    func testSessionViewModelPersistsLiveWindowForNextOpen() async throws {
        let store = windowStore()
        let first = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        first.applyStreamValue(snapshotJSON(cursor: 5, events: windowEvents()))
        await waitForRowRebuild()
        first.saveWindowCacheNow()
        let saved = try XCTUnwrap(store.load(sessionId: "s1"))
        XCTAssertEqual(saved.payload.chunks.flatMap { $0 }.map(\.seq), [1, 2, 3], "首屏后写入 4 屏缓存")

        let reopened = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        await reopened.awaitFirstPaintCacheForTesting()
        XCTAssertTrue(reopened.didRestoreFirstPaintCache)
        XCTAssertEqual(reopened.eventSeqs, [1, 2, 3])
    }

    @MainActor
    func testCorruptOrLegacyCacheFallsBackToColdPath() async throws {
        try writeRawWindowFile("{broken")
        let corrupt = SessionViewModel(address: .session(sessionId: "s1"), windowCache: windowStore())
        await corrupt.awaitFirstPaintCacheForTesting()
        XCTAssertFalse(corrupt.didRestoreFirstPaintCache)
        XCTAssertTrue(corrupt.isLoading, "缓存不可用 -> 走 live 加载态")
        XCTAssertTrue(corrupt.eventSeqs.isEmpty)

        try writeRawWindowFile(rawWindowPayloadJSON(schemaVersion: 4))
        let legacy = SessionViewModel(address: .session(sessionId: "s1"), windowCache: windowStore())
        await legacy.awaitFirstPaintCacheForTesting()
        XCTAssertFalse(legacy.didRestoreFirstPaintCache, "旧 schema 不得恢复")
        XCTAssertTrue(legacy.eventSeqs.isEmpty)
    }

    @MainActor
    func testStaleCacheIsShownAndFlagged() async throws {
        let staleAt = Date().addingTimeInterval(-(CacheSchema.ttl + 3600))
        try writeRawWindowFile(rawWindowPayloadJSON(savedAt: staleAt, events: cachedEvents(windowEvents())))
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: windowStore())
        await viewModel.awaitFirstPaintCacheForTesting()
        XCTAssertTrue(viewModel.didRestoreFirstPaintCache)
        XCTAssertTrue(viewModel.cachedWindowIsStale, "25h 前缓存仍展示但标记 stale")
        XCTAssertEqual(viewModel.eventSeqs, [1, 2, 3])
    }

    // MARK: - 大缓存首屏测量（v5 off-main；after 侧同口径数字）
    //
    // 对照 task-1 基线（改动前代码，同步 restoreCachedWindow）：4MB payload init 152ms。
    // 新架构断言 init 毫秒级、恢复在后台完成；print 的数字进 evidence。

    @MainActor
    func testLargeFirstPaintCacheDoesNotBlockInit() async throws {
        let store = windowStore()
        let big = String(repeating: "x", count: 100_000)
        var events: [SessionEvent] = []
        for seq in 0..<40 {
            events.append(SessionEvent(
                type: "assistant/message", seq: seq, time: 1_792_510_000_000 + Int64(seq),
                data: .object([
                    "message": .object([
                        "content": .array([.object([
                            "type": .string("text"),
                            "text": .string(big + String(seq)),
                        ])]),
                    ]),
                ]),
                surfaceOp: .string("append"), sourceEventSeqs: nil
            ))
        }
        XCTAssertTrue(store.save(
            sessionId: "s1", cursor: 39, hasMore: true, header: nil, projections: nil,
            events: events, windowMessages: 16
        ))
        let payloadBytes = (try? Data(contentsOf: store.fileURL(for: "s1")).count) ?? 0
        XCTAssertGreaterThan(payloadBytes, 1_000_000, "构造 MB 级大缓存")
        let started = Date()
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        let initMs = Date().timeIntervalSince(started) * 1000
        await viewModel.awaitFirstPaintCacheForTesting()
        let restoreMs = viewModel.cacheLoadMilliseconds
        let chunks = (try? store.load(sessionId: "s1"))??.payload.chunks.count ?? 0
        print("AUTOLOAD-CACHE after payload_bytes=\(payloadBytes) init_ms=\(String(format: "%.1f", initMs)) restore_ms=\(String(format: "%.1f", restoreMs)) chunks=\(chunks)")
        XCTAssertLessThan(initMs, 100, "改动前 4MB 同步恢复 ~152ms；新架构 init 必须毫秒级: \(initMs)ms")
        XCTAssertTrue(viewModel.didRestoreFirstPaintCache)
        XCTAssertEqual(viewModel.eventSeqs.last, 39)
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
            sessionId: "s1", cursor: 3, hasMore: false, header: nil, projections: nil,
            events: cachedEvents(windowEvents())
        ))

        let reader = windowStore(identity: "pair-identity-NEW-Mac")
        XCTAssertNil(reader.load(sessionId: "s1"), "不同配对 -> 当作没有缓存")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reader.fileURL(for: "s1").path))
    }

    @MainActor
    func testSessionViewModelDropsCacheFromOtherPairing() throws {
        let writer = windowStore(identity: "pair-identity-OLD-Mac")
        XCTAssertTrue(writer.save(
            sessionId: "s1", cursor: 3, hasMore: false, header: nil, projections: nil,
            events: cachedEvents(windowEvents())
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
    func testDetailMetricsCacheHitPath() async throws {
        let store = windowStore()
        XCTAssertTrue(store.save(
            sessionId: "s1", cursor: 3, hasMore: true, header: nil, projections: nil,
            events: cachedEvents(windowEvents()), windowMessages: 16
        ))
        DetailMetrics.forceEnabledForTesting = true
        DetailMetrics.reset()
        defer {
            DetailMetrics.forceEnabledForTesting = nil
            DetailMetrics.reset()
        }

        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        XCTAssertNil(viewModel.detailMetricsValue, "详情视图出现前不暴露 detail-metrics")
        await viewModel.awaitFirstPaintCacheForTesting()
        XCTAssertTrue(viewModel.didRestoreFirstPaintCache, "首屏缓存命中（off-main 恢复）")

        viewModel.markDetailViewAppeared()
        let value = try XCTUnwrap(viewModel.detailMetricsValue)
        XCTAssertTrue(value.contains("cacheHit=1"), "缓存命中自证字段：\(value)")
        XCTAssertFalse(value.contains("firstFrameMs=-1"), "缓存窗口上屏即首帧")
        XCTAssertNotNil(
            value.range(
                of: #"^firstFrameMs=\d+(\.\d+)?;cacheHit=1;networkMs=-1;beginEpochMs=\d+;sessionId=s1;window=\d+;cacheMs=\d+(\.\d+)?;fullMs=-1;resumed=0"#,
                options: .regularExpression
            ),
            "legacy 段必须保持旧格式（autoload 段在末尾追加）: \(value)"
        )
        XCTAssertGreaterThan(try XCTUnwrap(metricDouble(value, "beginEpochMs")), 1_700_000_000_000)
        XCTAssertNotEqual(try XCTUnwrap(metricDouble(value, "cacheMs")), -1, "缓存命中应记录 cacheMs")
        XCTAssertNotNil(metricDouble(value, "fillMs"), "detail-metrics 末尾追加 autoload 段")

        // A live snapshot marks the network segment (cacheHit stays in the value).
        viewModel.applyStreamValue(snapshotJSON(cursor: 3, events: windowEvents()))
        let afterNetwork = try XCTUnwrap(viewModel.detailMetricsValue)
        XCTAssertFalse(afterNetwork.contains("networkMs=-1"), "live snapshot 到达后应记录 networkMs")
        XCTAssertTrue(afterNetwork.contains("cacheHit=1"))
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
        await viewModel.awaitFirstPaintCacheForTesting()
        XCTAssertFalse(viewModel.didRestoreFirstPaintCache, "无缓存 -> cacheHit=0")
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
    func testPrewarmWindowIsHitByNextDetailOpen() async throws {
        // 预热写盘 -> 下一次打开同会话的 SessionViewModel 命中首屏缓存（off-main 恢复）。
        let store = windowStore()
        XCTAssertTrue(store.save(
            sessionId: "s1", cursor: 3, hasMore: true, header: nil, projections: nil,
            events: cachedEvents(windowEvents()), windowMessages: 16
        ))
        let detail = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        await detail.awaitFirstPaintCacheForTesting()
        XCTAssertTrue(detail.didRestoreFirstPaintCache)
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

    // MARK: - 自动补齐 policy + 缓存写入（2026-10-23 用户决策）

    func testSessionWindowPolicyAutoloadSizing() {
        XCTAssertEqual(SessionWindowPolicy.firstWindowMessages(screenHeight: 600), 12, "小屏首窗 12")
        XCTAssertEqual(SessionWindowPolicy.firstWindowMessages(screenHeight: 800), 16, "标准屏首窗 16")
        XCTAssertEqual(SessionWindowPolicy.firstWindowMessages(screenHeight: 900), 20, "大屏首窗 20")
        XCTAssertEqual(SessionWindowPolicy.cachedScreens, 4, "只缓存最近 4 屏")
        XCTAssertEqual(SessionWindowPolicy.prewarmMessages(screenHeight: 800), 64, "预热 = 首窗 x 4 屏")
        XCTAssertEqual(SessionWindowPolicy.firstWindowTurnWindow(messages: 16).minMessages, 8)
        XCTAssertEqual(SessionWindowPolicy.firstWindowTurnWindow(messages: 16).minTurns, 8)
    }

    func testHistoryPageMessagesAdaptToNetworkPath() {
        XCTAssertEqual(SessionWindowPolicy.historyPageMessages(isRelay: false), 160, "LAN 页大小（主线程解码，2026-10-23 调小）")
        XCTAssertEqual(SessionWindowPolicy.historyPageMessages(isRelay: true), 60, "relay/蜂窝小页控制单页解码/绘制成本")
    }

    func testHistoryPageRequestArgsUseWireKeys() throws {
        let args = SessionViewModel.historyPageRequestArgs(
            address: .session(sessionId: "s1"),
            throughSeq: 10,
            beforeSeq: 5,
            maxMessages: 240
        )
        let request = try XCTUnwrap(args["request"]?.objectValue)
        XCTAssertEqual(request["throughSeq"]?.intValue, 10)
        XCTAssertEqual(request["beforeSeq"]?.intValue, 5, "beforeSeq exclusive")
        XCTAssertEqual(request["maxMessages"]?.intValue, 240)
        XCTAssertEqual(request["address"]?["kind"]?.stringValue, "session")
        XCTAssertEqual(request["address"]?["sessionId"]?.stringValue, "s1")
        XCTAssertNil(request["turnWindow"], "turnWindow 省略：自动补齐按 Host 默认 turn 边界分页")
    }

    @MainActor
    func testSaveWindowCacheKeepsOnlyNewestFourScreens() async throws {
        let store = windowStore()
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        // 400 events = 200 条 append 消息 = 10 屏；缓存只允许最近 4 屏。
        let events = firstPaintEventJSON(count: 400)
        viewModel.applyStreamValue(snapshotJSON(cursor: 399, events: events))
        await waitForRowRebuild()
        viewModel.saveWindowCacheNow()
        let loaded = try XCTUnwrap(store.load(sessionId: "s1"))
        XCTAssertLessThanOrEqual(loaded.payload.chunks.count, SessionWindowPolicy.cachedScreens)
        XCTAssertEqual(loaded.payload.chunks.first?.last?.seq, 399, "最新一屏必须写入")
        // chunks 是最新在前；按时间序拼回去再检查连续性。
        let cachedSeqs = loaded.payload.chunks.reversed().flatMap { $0 }.map(\.seq)
        XCTAssertGreaterThan(try XCTUnwrap(cachedSeqs.min()), 0, "只写最近 4 屏尾部，不落盘全量历史")
        for (older, newer) in zip(cachedSeqs, cachedSeqs.dropFirst()) {
            XCTAssertEqual(newer, older + 1, "缓存窗口必须连续（无空洞）")
        }
    }
}
