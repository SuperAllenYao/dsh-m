import XCTest
@testable import DSHm

final class SessionJournalTests: XCTestCase {

    private func snapshot(
        cursor: Int,
        eventSeqs: ClosedRange<Int>,
        revision: Int = 0,
        hasMore: Bool = false
    ) -> SessionSnapshot {
        let records = eventSeqs.map { seq in
            """
            {"type":"event","event":{"type":"step/start","seq":\(seq),"time":\(1_000 + seq),"data":{"turn":1,"step":\(seq)}}}
            """
        }.joined(separator: ",")
        let json = """
        {"type":"snapshot","header":{"version":4,"id":"session-test","cwd":"/tmp/ws"},"cursor":\(cursor),
         "records":[\(records)],"hasMore":\(hasMore),
         "projections":{"asOfSeq":\(cursor),"values":{"title":"hello"}},
         "assistantStream":{"revision":\(revision)}}
        """
        return try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
    }

    // MARK: - Snapshot rebuild state machine (§4.3)

    func testSnapshotRebuildReplacesWindowAndDropsStaleEvents() {
        let journal = SessionJournal()
        XCTAssertEqual(journal.apply(snapshot: snapshot(cursor: 4, eventSeqs: 0...4)), .snapshotReplaced)
        XCTAssertEqual(journal.lastSeq, 4)
        XCTAssertEqual(journal.events.count, 5)
        XCTAssertEqual(journal.title, "hello")

        // live event continues the window
        XCTAssertEqual(journal.apply(event: TestJSON.event("step/end", seq: 5)), .eventsApplied([5]))
        XCTAssertEqual(journal.lastSeq, 5)
        XCTAssertEqual(journal.events.count, 6)

        // duplicate is dropped
        XCTAssertEqual(journal.apply(event: TestJSON.event("step/end", seq: 5)), .duplicate(5))
        XCTAssertEqual(journal.events.count, 6)

        // hole is surfaced (MVP policy: caller rebuilds from snapshot)
        XCTAssertEqual(
            journal.apply(event: TestJSON.event("step/end", seq: 7)),
            .gap(expected: 6, received: 7)
        )
        XCTAssertEqual(journal.events.count, 6, "gap event must not be applied")

        // re-snapshot after reconnect: the newest window is replaced, but the prefix
        // the user already loaded is preserved (task session-history: a reconnect
        // must not throw the loaded history away). Local 0...5 + new window 6...9 =
        // contiguous, so all of it stays.
        XCTAssertEqual(journal.apply(snapshot: snapshot(cursor: 9, eventSeqs: 6...9)), .snapshotReplaced)
        XCTAssertEqual(journal.lastSeq, 9)
        XCTAssertEqual(journal.events.map(\.seq), Array(0...9), "更老的前缀必须保留")
        XCTAssertEqual(journal.oldestSeq, 0)
        XCTAssertEqual(journal.events.last?.seq, 9)

        // events older than the new snapshot's cursor are duplicates
        XCTAssertEqual(journal.apply(event: TestJSON.event("step/end", seq: 8)), .duplicate(8))
    }

    func testSnapshotEventsAreSortedAndDeduped() throws {
        let json = """
        {"type":"snapshot","header":{"id":"s"},"cursor":3,
         "records":[
           {"type":"event","event":{"type":"step/start","seq":3}},
           {"type":"event","event":{"type":"step/start","seq":1}},
           {"type":"event","event":{"type":"step/start","seq":1}},
           {"type":"event","event":{"type":"step/start","seq":2}}
         ],"projections":{"asOfSeq":3,"values":{}}}
        """
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot)
        XCTAssertEqual(journal.events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(journal.lastSeq, 3)
    }

    func testSnapshotRejectsEventsBeyondCursorUntilTheyArrive() {
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot(cursor: 2, eventSeqs: 0...2))
        // snapshot says cursor=2, an event at seq 3 is the next contiguous event
        XCTAssertEqual(journal.apply(event: TestJSON.event("turn/start", seq: 3)), .eventsApplied([3]))
    }

    // MARK: - assistant-stream revision (§3.5/§4.3)

    func testAssistantStreamRequiresMonotonicRevision() {
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot(cursor: 0, eventSeqs: 0...0, revision: 0))

        XCTAssertEqual(
            journal.apply(assistantStream: try! JSONDecoder().decode(AssistantStreamFrame.self, from: Data(#"{"type":"chunk","revision":2}"#.utf8))),
            .assistantRevisionGap(expected: 1, received: 2)
        )
        XCTAssertEqual(journal.assistantRevision, 0)

        XCTAssertEqual(
            journal.apply(assistantStream: try! JSONDecoder().decode(AssistantStreamFrame.self, from: Data(#"{"type":"start","revision":1}"#.utf8))),
            .assistantStreamProgress(1)
        )
        XCTAssertEqual(
            journal.apply(assistantStream: try! JSONDecoder().decode(AssistantStreamFrame.self, from: Data(#"{"type":"chunk","revision":2,"chunk":{"type":"text","text":"po"}}"#.utf8))),
            .assistantStreamProgress(2)
        )
        XCTAssertEqual(journal.liveAssistantText, "po")
        XCTAssertEqual(
            journal.apply(assistantStream: try! JSONDecoder().decode(AssistantStreamFrame.self, from: Data(#"{"type":"chunk","revision":1}"#.utf8))),
            .duplicate(1)
        )
        XCTAssertEqual(journal.liveAssistantText, "po")
    }

    func testCommittedAssistantMessageClearsLiveStreamText() {
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot(cursor: 0, eventSeqs: 0...0))
        journal.apply(assistantStream: try! JSONDecoder().decode(
            AssistantStreamFrame.self,
            from: Data(#"{"type":"chunk","revision":1,"chunk":{"type":"text","text":"多步过程演示完成"}}"#.utf8)
        ))
        XCTAssertEqual(journal.liveAssistantText, "多步过程演示完成")
        journal.apply(event: TestJSON.event("assistant/message", seq: 1, data: TestJSON.value("""
        {"message":{"content":[{"type":"text","text":"多步过程演示完成"}]}}
        """)))
        XCTAssertEqual(journal.liveAssistantText, "", "committed assistant/message must supersede the live delta")
    }

    // MARK: - Projections replay from events

    func testEventProjectionsTrackTitlePermissionAndTodos() {
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot(cursor: 0, eventSeqs: 0...0))
        journal.apply(event: TestJSON.event("session/title", seq: 1, data: .object(["title": .string("新标题")])))
        journal.apply(event: TestJSON.event("permission/preset", seq: 2, data: .object(["preset": .string("read-only")])))
        journal.apply(event: TestJSON.event("todo/write", seq: 3, data: .object([
            "todos": .array([.object(["content": .string("a"), "status": .string("pending")])]),
        ])))
        XCTAssertEqual(journal.title, "新标题")
        XCTAssertEqual(journal.permissionsValue, "read-only")
        XCTAssertEqual(journal.todos?.count, 1)
    }

    // MARK: - 更早历史前置合并（task session-history: unary session/page）
    //
    // Host semantics (verified against the installed session-controller):
    // beforeSeq exclusive, records hold *all* events of the seq range, hasMore =
    // the range's oldest offset > 0. These tests pin the client side of that
    // contract: sorted/de-duplicated front merge, newest position untouched, and a
    // paging state that stops exactly at the first event.

    private func page(records seqs: [Int], hasMore: Bool) -> SessionPage {
        let records = seqs
            .map { "{\"type\":\"event\",\"event\":{\"type\":\"user/message\",\"seq\":\($0)}}" }
            .joined(separator: ",")
        let json = "{\"records\":[\(records)],\"hasMore\":\(hasMore)}"
        return try! JSONDecoder().decode(SessionPage.self, from: Data(json.utf8))
    }

    func testFirstSnapshotHasMoreOlderComesFromSnapshot() {
        let journal = SessionJournal()
        XCTAssertFalse(journal.hasMoreOlder, "没有快照 -> 未知，整型默认 false")
        journal.apply(snapshot: snapshot(cursor: 6, eventSeqs: 4...6, hasMore: true))
        XCTAssertTrue(journal.hasMoreOlder, "长会话首帧 hasMore=true，视图才能触发\"加载更早\"")
        XCTAssertEqual(journal.oldestSeq, 4)
    }

    func testPrependSortsDedupesAndKeepsNewestPosition() {
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot(cursor: 20, eventSeqs: 9...20))
        XCTAssertEqual(journal.oldestSeq, 9)

        // Out of order + duplicated seqs: the Host is exclusive per page, the merge
        // is defensive about both.
        let update = journal.prepend(page: page(records: [6, 8, 7, 6, 5], hasMore: true))
        XCTAssertEqual(update, .olderPrepended([5, 6, 7, 8]))
        XCTAssertEqual(journal.events.map(\.seq), Array(5...20))
        XCTAssertEqual(journal.oldestSeq, 5)
        XCTAssertEqual(journal.lastSeq, 20, "前置合并不改最新位置")
        XCTAssertEqual(journal.cursor, 20, "cursor 仍是 follow 快照的 cursor")
        XCTAssertTrue(journal.hasMoreOlder)
    }

    func testPrependReachesFirstEventAndClearsHasMoreOlder() {
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot(cursor: 3, eventSeqs: 3...3, hasMore: true))
        XCTAssertEqual(journal.prepend(page: page(records: [1, 2], hasMore: true)), .olderPrepended([1, 2]))
        XCTAssertTrue(journal.hasMoreOlder)
        // The last page reaches seq 0: the Host reports hasMore=false.
        XCTAssertEqual(journal.prepend(page: page(records: [0], hasMore: false)), .olderPrepended([0]))
        XCTAssertEqual(journal.events.map(\.seq), Array(0...3))
        XCTAssertEqual(journal.oldestSeq, 0)
        XCTAssertFalse(journal.hasMoreOlder, "到达第一条事件后停止分页")
    }

    func testEmptyPageStopsPaginationInsteadOfLooping() {
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot(cursor: 3, eventSeqs: 2...3, hasMore: true))
        // The Host claimed more history but the page adds nothing: stop instead of
        // asking the same page forever.
        XCTAssertEqual(journal.prepend(page: page(records: [], hasMore: true)), .olderPrepended([]))
        XCTAssertFalse(journal.hasMoreOlder)
        XCTAssertEqual(journal.events.map(\.seq), [2, 3])
    }

    func testPrependIgnoresRecordsAtOrAfterCurrentFront() {
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot(cursor: 5, eventSeqs: 3...5, hasMore: true))
        // Overlapping (non-exclusive) page: only the truly older seq is merged.
        XCTAssertEqual(journal.prepend(page: page(records: [4, 5, 2], hasMore: true)), .olderPrepended([2]))
        XCTAssertEqual(journal.events.map(\.seq), Array(2...5))
        XCTAssertTrue(journal.hasMoreOlder)
    }

    func testPrependIgnoresNonEventRecords() {
        let json = """
        {"records":[{"type":"projection","seq":9},
                    {"type":"event","event":{"type":"tool/call","seq":2}}],"hasMore":false}
        """
        let page = try! JSONDecoder().decode(SessionPage.self, from: Data(json.utf8))
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot(cursor: 4, eventSeqs: 3...4, hasMore: true))
        XCTAssertEqual(journal.prepend(page: page), .olderPrepended([2]))
        XCTAssertEqual(journal.events.map(\.seq), [2, 3, 4])
        XCTAssertFalse(journal.hasMoreOlder)
    }

    func testPrependCoexistsWithLiveEventAppend() {
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot(cursor: 5, eventSeqs: 3...5, hasMore: true))
        journal.prepend(page: page(records: [0, 1, 2], hasMore: false))
        XCTAssertEqual(journal.lastSeq, 5)
        // The live tail keeps appending from the snapshot cursor, unaffected by the
        // front merge (and its gap detection still works).
        XCTAssertEqual(journal.apply(event: TestJSON.event("step/end", seq: 6)), .eventsApplied([6]))
        XCTAssertEqual(journal.apply(event: TestJSON.event("step/end", seq: 8)), .gap(expected: 7, received: 8))
        XCTAssertEqual(journal.lastSeq, 6)
        XCTAssertEqual(journal.oldestSeq, 0)
        XCTAssertEqual(journal.events.count, 7)
    }

    func testReconnectSnapshotPreservesPagedHistory() {
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot(cursor: 5, eventSeqs: 3...5, hasMore: true))
        journal.prepend(page: page(records: [0, 1, 2], hasMore: false))
        XCTAssertEqual(journal.oldestSeq, 0)
        // Reconnect: new snapshot window [4...7] is contiguous with the preserved
        // 0...3, so the whole loaded range survives and paging state stays "done".
        XCTAssertEqual(
            journal.apply(snapshot: snapshot(cursor: 7, eventSeqs: 4...7, hasMore: true)),
            .snapshotReplaced
        )
        XCTAssertEqual(journal.events.map(\.seq), Array(0...7))
        XCTAssertEqual(journal.lastSeq, 7)
        XCTAssertEqual(journal.cursor, 7)
        XCTAssertFalse(journal.hasMoreOlder, "已加载到 seq 0，重连不得重置回 snapshot.hasMore")
    }

    func testReconnectSnapshotDropsStalePrefixWhenDiscontinuous() {
        let journal = SessionJournal()
        // 首个快照已到 seq 0 -> 粘滞终止位已置（task-6）。
        journal.apply(snapshot: snapshot(cursor: 5, eventSeqs: 0...5, hasMore: false))
        XCTAssertTrue(journal.hasReachedOldest)
        // The Host's window moved past the loaded events (a long gap): keeping the
        // stale prefix would render a hole, so it is dropped. The terminal state is
        // sticky: even this wholesale window reset must not re-arm "load earlier".
        XCTAssertEqual(
            journal.apply(snapshot: snapshot(cursor: 20, eventSeqs: 18...20, hasMore: true)),
            .snapshotReplaced
        )
        XCTAssertEqual(journal.events.map(\.seq), Array(18...20))
        XCTAssertEqual(journal.oldestSeq, 18)
        XCTAssertTrue(journal.hasReachedOldest, "粘滞终止位不回退")
        XCTAssertFalse(journal.hasMoreOlder, "到过 seq 0 后不再提示更早历史")
    }

    func testSnapshotReplacementWithoutPrefixAdoptsSnapshotHasMore() {
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot(cursor: 2, eventSeqs: 1...2, hasMore: false))
        XCTAssertFalse(journal.hasMoreOlder)
        journal.apply(snapshot: snapshot(cursor: 4, eventSeqs: 2...4, hasMore: true))
        XCTAssertEqual(journal.oldestSeq, 1, "第一段 1 被保留，与快照 2...4 连续")
        XCTAssertFalse(journal.hasMoreOlder, "已有已加载前缀时沿用分页状态（此前为 false）")

        let fresh = SessionJournal()
        fresh.apply(snapshot: snapshot(cursor: 4, eventSeqs: 2...4, hasMore: true))
        XCTAssertTrue(fresh.hasMoreOlder, "空 journal 的首个快照直接采用 hasMore")
        XCTAssertEqual(fresh.oldestSeq, 2)
    }

    // MARK: - task-6: 到达最早事件后终止分页（粘滞）

    func testReachingFirstEventIsStickyAcrossSnapshots() {
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot(cursor: 20, eventSeqs: 9...20, hasMore: true))
        XCTAssertTrue(journal.hasMoreOlder)
        XCTAssertFalse(journal.hasReachedOldest)

        journal.prepend(page: page(records: Array(0...8), hasMore: false))
        XCTAssertTrue(journal.hasReachedOldest, "到达第一条事件 -> 粘滞终止")
        XCTAssertFalse(journal.hasMoreOlder)
        XCTAssertEqual(journal.oldestSeq, 0)

        // 重连/后台 fill：新快照只覆盖最新窗口且 hasMore=true；这里故意让它与已加载
        // 窗口不连续（preserved.isEmpty 分支），终止状态也不得被重新武装。
        journal.apply(snapshot: snapshot(cursor: 60, eventSeqs: 55...60, hasMore: true))
        XCTAssertTrue(journal.hasReachedOldest, "粘滞位永不回退")
        XCTAssertFalse(journal.hasMoreOlder, "snapshot.hasMore=true 不得复活\"加载更早\"")
    }

    func testConservativePageContainingFirstEventWinsOverHasMoreTrue() {
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot(cursor: 20, eventSeqs: 10...20, hasMore: true))
        // Host 保守/异常：一页已经含 seq 0，却仍报 hasMore=true。
        XCTAssertEqual(
            journal.prepend(page: page(records: Array(0...9), hasMore: true)),
            .olderPrepended(Array(0...9))
        )
        XCTAssertTrue(journal.hasReachedOldest)
        XCTAssertFalse(journal.hasMoreOlder, "页内含 seq 0 即证明没有更早历史")
    }

    func testPageHasMoreFalseTerminatesPaginationEvenWithoutFirstEvent() {
        let journal = SessionJournal()
        journal.apply(snapshot: snapshot(cursor: 20, eventSeqs: 12...20, hasMore: true))
        journal.prepend(page: page(records: Array(1...11), hasMore: false))
        XCTAssertTrue(journal.hasReachedOldest, "hasMore=false 是 Host 的\"日志到头\"信号")
        XCTAssertFalse(journal.hasMoreOlder)

        // 后续 live 事件 / 快照都不会复活。
        journal.apply(event: TestJSON.event("step/end", seq: 21))
        journal.apply(snapshot: snapshot(cursor: 30, eventSeqs: 20...30, hasMore: true))
        XCTAssertFalse(journal.hasMoreOlder)
        XCTAssertTrue(journal.hasReachedOldest)
    }

    func testCacheRestoreStickyFlagIsOneWay() {
        let journal = SessionJournal()
        journal.setHasReachedOldest(false)
        XCTAssertFalse(journal.hasReachedOldest)
        journal.setHasReachedOldest(true)
        XCTAssertTrue(journal.hasReachedOldest)
        XCTAssertFalse(journal.hasMoreOlder)

        // 之后的任何快照（哪怕 hasMore=true）都不得清除粘滞终止位。
        journal.apply(snapshot: snapshot(cursor: 5, eventSeqs: 1...5, hasMore: true))
        XCTAssertTrue(journal.hasReachedOldest)
        XCTAssertFalse(journal.hasMoreOlder)
    }
}
