import XCTest
@testable import DSHm

/// v5.4 session-list status rules: waiting-for-answer (tool approval OR active user
/// questions) > in-progress > not-started > idle, plus the offline fallback.
final class SessionListStatusTests: XCTestCase {

    // MARK: - Fixtures

    private func decode(_ json: String) throws -> SessionListItem {
        try JSONDecoder().decode(SessionListItem.self, from: Data(json.utf8))
    }

    private func session(
        running: Bool = false,
        blank: Bool? = false,
        activeQuestionCalls: Int = 0
    ) -> SessionListItem {
        var values: [String: JSONValue] = [:]
        if activeQuestionCalls > 0 {
            let active: [JSONValue] = (0..<activeQuestionCalls).map { index in
                .object([
                    "callId": .string("call_\(index)"),
                    "questions": .array([
                        .object([
                            "id": .string("q_\(index)"),
                            "question": .string("选哪个？"),
                            "detail": .string(""),
                            "header": .string("确认"),
                        ]),
                    ]),
                ])
            }
            values["userQuestions"] = .object(["active": .array(active)])
        }
        return SessionListItem(
            sessionId: "session-\(activeQuestionCalls)-\(running)-\(blank.map(String.init) ?? "nil")",
            running: running,
            blank: blank,
            cwd: "/ws/a",
            projections: ProjectionValues(values: values)
        )
    }

    private func status(
        _ item: SessionListItem,
        approvals: Int = 0,
        connected: Bool = true
    ) -> SessionListStatus {
        SessionListStatusResolver.status(
            for: item,
            pendingApprovals: approvals,
            isConnected: connected
        )
    }

    // MARK: - userQuestions projection parsing

    func testUserQuestionsProjectionParsing() throws {
        // Shape verified against the Host's session/list projections:
        // projections.values.userQuestions.active[] = {callId, questions:[{id,question,detail,header}]}
        let item = try decode("""
        {"sessionId":"s1","cwd":"/ws/a","projections":{"values":{"userQuestions":{"active":[
          {"callId":"call_1","questions":[
            {"id":"q1","question":"选哪个方案？","detail":"","header":"确认"},
            {"id":"q2","question":"继续吗？","detail":"","header":"继续"}
          ]}
        ]}}}}
        """)
        XCTAssertTrue(item.hasActiveUserQuestions)
        XCTAssertEqual(item.userQuestionsActive.count, 1)
        XCTAssertEqual(item.userQuestionsActive[0]["callId"]?.stringValue, "call_1")
    }

    func testEmptyActiveUserQuestionsIsNotWaiting() throws {
        let item = try decode("""
        {"sessionId":"s2","cwd":"/ws/a","projections":{"values":{"userQuestions":{"active":[]}}}}
        """)
        XCTAssertFalse(item.hasActiveUserQuestions)
        XCTAssertEqual(status(item), .idle, "an empty active array must not be treated as waiting")
    }

    func testMissingUserQuestionsProjectionIsNotWaiting() throws {
        let item = try decode(#"{"sessionId":"s3","cwd":"/ws/a"}"#)
        XCTAssertFalse(item.hasActiveUserQuestions)
        XCTAssertEqual(status(item), .idle)
    }

    // MARK: - Status mapping and priority

    func testApprovalMakesWaiting() {
        XCTAssertEqual(status(session(), approvals: 1), .waitingForAnswer(count: 1))
        XCTAssertEqual(status(session(), approvals: 1).label, "等待作答")
    }

    func testActiveUserQuestionsMakeWaiting() {
        XCTAssertEqual(status(session(activeQuestionCalls: 1)), .waitingForAnswer(count: 1))
        XCTAssertEqual(status(session(activeQuestionCalls: 1)).label, "等待作答")
        XCTAssertEqual(status(session(activeQuestionCalls: 2)), .waitingForAnswer(count: 2))
        XCTAssertEqual(status(session(activeQuestionCalls: 2)).label, "等待作答 2")
    }

    func testWaitingTakesPriorityOverRunning() {
        XCTAssertEqual(
            status(session(running: true), approvals: 1),
            .waitingForAnswer(count: 1),
            "waiting outranks running (both approval and question sources)"
        )
        XCTAssertEqual(
            status(session(running: true, activeQuestionCalls: 1)),
            .waitingForAnswer(count: 1)
        )
    }

    func testWaitCountFoldsApprovalsAndQuestionCalls() {
        XCTAssertEqual(status(session(activeQuestionCalls: 2), approvals: 2), .waitingForAnswer(count: 4))
        XCTAssertEqual(status(session(activeQuestionCalls: 2), approvals: 2).label, "等待作答 4")
    }

    func testRunningBeforeNotStartedAndIdle() {
        XCTAssertEqual(status(session(running: true)), .running)
        XCTAssertEqual(status(session(running: true)).label, "进行中")
        XCTAssertTrue(status(session(running: true)).isPulsing, "in-progress keeps the pulsing dot")
        XCTAssertFalse(status(session()).isPulsing)
    }

    func testBlankIsNotStarted() {
        XCTAssertEqual(status(session(blank: true)), .notStarted)
        XCTAssertEqual(status(session(blank: true)).label, "未开始")
    }

    func testIdleFallback() {
        XCTAssertEqual(status(session()), .idle)
        XCTAssertEqual(status(session()).label, "空闲")
    }

    func testOfflineOverridesEveryOtherState() {
        XCTAssertEqual(status(session(running: true), approvals: 2, connected: false), .offline)
        XCTAssertEqual(status(session(activeQuestionCalls: 1), connected: false), .offline)
        XCTAssertEqual(status(session(blank: true), connected: false).label, "离线")
    }

    func testStatusLabelsCoverAllStates() {
        XCTAssertEqual(SessionListStatus.waitingForAnswer(count: 1).label, "等待作答")
        XCTAssertEqual(SessionListStatus.running.label, "进行中")
        XCTAssertEqual(SessionListStatus.notStarted.label, "未开始")
        XCTAssertEqual(SessionListStatus.idle.label, "空闲")
        XCTAssertEqual(SessionListStatus.offline.label, "离线")
    }
}
