import XCTest
@testable import DSHm

final class SessionJournalTests: XCTestCase {

    private func snapshot(cursor: Int, eventSeqs: ClosedRange<Int>, revision: Int = 0) -> SessionSnapshot {
        let records = eventSeqs.map { seq in
            """
            {"type":"event","event":{"type":"step/start","seq":\(seq),"time":\(1_000 + seq),"data":{"turn":1,"step":\(seq)}}}
            """
        }.joined(separator: ",")
        let json = """
        {"type":"snapshot","header":{"version":4,"id":"session-test","cwd":"/tmp/ws"},"cursor":\(cursor),
         "records":[\(records)],"hasMore":false,
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

        // re-snapshot after reconnect: old window is discarded, new cursor wins
        XCTAssertEqual(journal.apply(snapshot: snapshot(cursor: 9, eventSeqs: 6...9)), .snapshotReplaced)
        XCTAssertEqual(journal.lastSeq, 9)
        XCTAssertEqual(journal.events.count, 4)
        XCTAssertEqual(journal.events.first?.seq, 6)
        XCTAssertEqual(journal.events.last?.seq, 9)

        // events older than the new snapshot are duplicates
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
}
