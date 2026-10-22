import XCTest
@testable import DSHm

/// task-2: userQuestions data layer — projection parsing, exact answer payloads,
/// open/continued path selection, soft business results and state write-back.
/// Contract source: remote-protocol §3.7.2 / tech-design §14 (Lead-verified).
final class UserQuestionTests: XCTestCase {

    // MARK: - Projection parsing

    private func projection(_ json: String) -> UserQuestionsProjection {
        UserQuestionsProjection.parse(TestJSON.value(json))
    }

    func testProjectionParsesActiveCallFields() throws {
        let parsed = projection("""
        {"active":[{
            "callId":"call-1",
            "state":"continued",
            "questions":[{
                "id":"q1",
                "question":"Which capture mode?",
                "detail":"Longer explanation",
                "header":"Gap capture",
                "options":[{"label":"waterfall","description":"reuse live frames"},{"label":"stream"}],
                "multiSelect":true
            }]
        }],"settled":[]}
        """)
        XCTAssertEqual(parsed.active.count, 1)
        let call = try XCTUnwrap(parsed.active.first)
        XCTAssertEqual(call.callId, "call-1")
        XCTAssertEqual(call.state, .continued)
        XCTAssertEqual(call.questions.count, 1)
        let question = try XCTUnwrap(call.questions.first)
        XCTAssertEqual(question.id, "q1")
        XCTAssertEqual(question.question, "Which capture mode?")
        XCTAssertEqual(question.detail, "Longer explanation")
        XCTAssertEqual(question.header, "Gap capture")
        XCTAssertEqual(question.options?.map(\.label), ["waterfall", "stream"])
        XCTAssertEqual(question.options?.first?.description, "reuse live frames")
        XCTAssertTrue(question.isMultiSelect)
        XCTAssertTrue(call.state.isAnswerableUnarily)
    }

    func testProjectionParsesBothStates() {
        let parsed = projection("""
        {"active":[
            {"callId":"c-open","state":"open","questions":[]},
            {"callId":"c-continued","state":"continued","questions":[]}
        ]}
        """)
        XCTAssertEqual(parsed.active.map(\.callId), ["c-open", "c-continued"])
        XCTAssertEqual(parsed.active[0].state, .open)
        XCTAssertTrue(parsed.active[0].state.isOpen)
        XCTAssertEqual(parsed.active[1].state, .continued)
    }

    func testProjectionParsesSettledAnswersWithCustom() throws {
        let parsed = projection("""
        {"active":[],"settled":[{
            "callId":"call-1",
            "answers":[
                {"id":"q1","selected":["waterfall"],"custom":"extra note"},
                {"id":"q2","selected":[]}
            ]
        }]}
        """)
        XCTAssertTrue(parsed.active.isEmpty)
        let settled = try XCTUnwrap(parsed.settled.first)
        XCTAssertEqual(settled.callId, "call-1")
        XCTAssertEqual(settled.answers.count, 2)
        XCTAssertEqual(settled.answers[0].selected, ["waterfall"])
        XCTAssertEqual(settled.answers[0].custom, "extra note")
        XCTAssertEqual(settled.answers[1].selected, [])
        XCTAssertNil(settled.answers[1].custom)
    }

    func testProjectionToleratesMissingOptionalFields() throws {
        let parsed = projection("""
        {"active":[{"callId":"c1","questions":[{"id":"q1","question":"ping"}]}]}
        """)
        let call = try XCTUnwrap(parsed.active.first)
        XCTAssertEqual(call.state, .unknown(""))
        let question = try XCTUnwrap(call.questions.first)
        XCTAssertNil(question.options)
        XCTAssertNil(question.multiSelect)
        XCTAssertFalse(question.isMultiSelect)
        XCTAssertTrue(UserQuestionsProjection.parse(nil).isEmpty)
        XCTAssertTrue(UserQuestionsProjection.parse(.string("nope")).isEmpty)
        XCTAssertEqual(UserQuestionsProjection.parseProjections(TestJSON.value(#"{"values":{"userQuestions":{"active":[]}}}"#)).active.count, 0)
    }

    // MARK: - Answer payloads (exact wire JSON)

    func testAnswerBatchEncodesExactJSON() throws {
        let batch = UserQuestionAnswersBatch(answers: [
            UserQuestionAnswer(id: "q1", selected: ["waterfall", "stream"], custom: "自定义"),
            UserQuestionAnswer(id: "q2", selected: []),
        ])
        let json = try batch.encodedJSONString()
        XCTAssertEqual(json, #"{"answers":[{"custom":"自定义","id":"q1","selected":["waterfall","stream"]},{"id":"q2","selected":[]}]}"#)
    }

    func testSkipBatchEncodesExactJSON() throws {
        let call = UserQuestionCall(
            callId: "c1",
            state: .continued,
            questions: [
                UserQuestion(id: "q1", question: "a"),
                UserQuestion(id: "q2", question: "b"),
            ]
        )
        let answers = UserQuestionSubmitPlanner.skipAnswers(for: call)
        let json = try UserQuestionAnswersBatch(answers: answers).encodedJSONString()
        XCTAssertEqual(json, #"{"answers":[{"id":"q1","selected":[]},{"id":"q2","selected":[]}]}"#)
    }

    func testAnswerBatchJSONValueShape() throws {
        let batch = UserQuestionAnswersBatch.single(id: "q1", selected: ["ok"], custom: "x")
        let expected = TestJSON.value(#"{"answers":[{"id":"q1","selected":["ok"],"custom":"x"}]}"#)
        XCTAssertEqual(batch.jsonValue(), expected)
        // JSONValue produced by the model decodes back into the same model.
        let roundTripped = try batch.jsonValue().decode(UserQuestionAnswersBatch.self)
        XCTAssertEqual(roundTripped, batch)
    }

    // MARK: - session/list projection (typed, with v5.4 compat)

    func testSessionListItemActiveUserQuestionsTyped() throws {
        let json = """
        {"sessionId":"session-1","projections":{"values":{"userQuestions":{
            "active":[{"callId":"call-9","state":"open","questions":[
                {"id":"q1","question":"pick","options":[{"label":"A"}],"multiSelect":false}
            ]}],
            "settled":[{"callId":"call-8","answers":[{"id":"q0","selected":["A"]}]}]
        }}}}
        """
        let item = try JSONDecoder().decode(SessionListItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.activeUserQuestions.count, 1)
        XCTAssertEqual(item.activeUserQuestions.first?.callId, "call-9")
        XCTAssertEqual(item.activeUserQuestions.first?.state, .open)
        XCTAssertEqual(item.activeUserQuestions.first?.questions.first?.options?.first?.label, "A")
        // v5.4 compatibility fields still work.
        XCTAssertEqual(item.userQuestionsActive.count, 1)
        XCTAssertTrue(item.hasActiveUserQuestions)
    }

    // MARK: - Live waterfall parsing (§3.7.2, open path)

    func testWaterfallParsesQuestionsAndWait() throws {
        let value = TestJSON.value("""
        {"type":"waterfall","event":"user-questions/request","eventId":"evt-uq-1",
         "agentId":"session-1","request":{
            "questions":[{"id":"q1","question":"pick","header":"H",
                          "options":[{"label":"waterfall"},{"label":"stream"}],"multiSelect":false}],
            "wait":{"callId":"call-1","timed":true}
         }}
        """)
        let waterfall = try XCTUnwrap(UserQuestionWaterfall.parse(value))
        XCTAssertEqual(waterfall.eventId, "evt-uq-1")
        XCTAssertEqual(waterfall.agentId, "session-1")
        XCTAssertEqual(waterfall.callId, "call-1")
        XCTAssertEqual(waterfall.timed, true)
        XCTAssertEqual(waterfall.questions.map(\.id), ["q1"])
    }

    func testForwardedEventDecodeCarriesUserQuestionWaterfall() throws {
        let value = TestJSON.value("""
        {"type":"waterfall","event":"user-questions/request","eventId":"evt-uq-1",
         "agentId":"session-1","request":{"questions":[{"id":"q1","question":"pick"}]}}
        """)
        guard case .waterfall(_, let approval, let userQuestion) = ForwardedRemoteEvent.decode(value) else {
            return XCTFail("expected .waterfall")
        }
        XCTAssertNil(approval)
        XCTAssertEqual(userQuestion?.eventId, "evt-uq-1")
        XCTAssertEqual(userQuestion?.questions.first?.id, "q1")
    }

    func testEventsResultArgsForUserQuestionAnswers() {
        let args = EventsResultArgs.userQuestionOutcome(
            clientId: "client-1",
            eventId: "evt-1",
            answers: [UserQuestionAnswer(id: "q1", selected: ["A"])]
        )
        XCTAssertEqual(args["clientId"]?.stringValue, "client-1")
        XCTAssertEqual(args["eventId"]?.stringValue, "evt-1")
        XCTAssertEqual(args["outcome"]?["kind"]?.stringValue, "result")
        XCTAssertEqual(args["outcome"]?["value"], TestJSON.value(#"{"answers":[{"id":"q1","selected":["A"]}]}"#))
    }

    /// v0.1.1 (Bug 2): pending cards now survive a reconnect teardown, so the
    /// Host's re-delivery of the same waterfall must update in place (by
    /// `eventId`) instead of appending a duplicate; a `cancel` frame still
    /// drops the card.
    func testForwardedWaterfallQueueReDeliveryIsIdempotent() {
        var approvals: [ApprovalWaterfall] = []
        var questions: [UserQuestionWaterfall] = []
        func apply(_ json: String) {
            ForwardedWaterfallQueue.apply(
                ForwardedRemoteEvent.decode(TestJSON.value(json)),
                approvals: &approvals,
                questions: &questions
            )
        }
        let approvalJSON = """
        {"type":"waterfall","event":"approval/request","eventId":"evt-a-1",
         "agentId":"session-1","request":{"toolName":"Bash","callId":"call-a","reason":"first"}}
        """
        let questionJSON = """
        {"type":"waterfall","event":"user-questions/request","eventId":"evt-uq-1",
         "agentId":"session-1","request":{"questions":[{"id":"q1","question":"pick"}]}}
        """
        apply(approvalJSON)
        apply(questionJSON)
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(questions.count, 1)
        // Reconnect: the Host re-delivers the same pending waterfalls.
        apply(approvalJSON)
        apply(questionJSON)
        XCTAssertEqual(approvals.count, 1, "re-delivery must not duplicate the approval card")
        XCTAssertEqual(questions.count, 1, "re-delivery must not duplicate the question card")
        // A settled/aborted waterfall still disappears via the cancel frame.
        apply(#"{"type":"cancel","eventId":"evt-uq-1"}"#)
        apply(#"{"type":"cancel","eventId":"evt-a-1"}"#)
        XCTAssertTrue(approvals.isEmpty)
        XCTAssertTrue(questions.isEmpty)
    }

    // MARK: - Path selection (open / continued / live-missing)

    private func call(_ callId: String, _ state: UserQuestionState, questionIds: [String] = ["q1"]) -> UserQuestionCall {
        UserQuestionCall(
            callId: callId,
            state: state,
            questions: questionIds.map { UserQuestion(id: $0, question: "q-" + $0) }
        )
    }

    func testPlannerContinuedUsesUnaryAnswerPath() {
        let path = UserQuestionSubmitPlanner.path(
            for: call("call-1", .continued),
            pending: []
        )
        XCTAssertEqual(path, .unary(callId: "call-1"))
    }

    func testPlannerOpenWithLiveWaterfallUsesEventsResult() {
        let waterfall = UserQuestionWaterfall(
            eventId: "evt-1",
            agentId: "session-1",
            questions: [UserQuestion(id: "q1", question: "q")],
            callId: "call-1",
            timed: true
        )
        let path = UserQuestionSubmitPlanner.path(
            for: call("call-1", .open),
            pending: [waterfall]
        )
        XCTAssertEqual(path, .live(eventId: "evt-1"))
    }

    func testPlannerOpenMatchesByQuestionIdsWhenWaitCallIdMissing() {
        let waterfall = UserQuestionWaterfall(
            eventId: "evt-1",
            agentId: "session-1",
            questions: [UserQuestion(id: "q1", question: "q")],
            callId: nil,
            timed: nil
        )
        let path = UserQuestionSubmitPlanner.path(
            for: call("call-x", .open),
            pending: [waterfall]
        )
        XCTAssertEqual(path, .live(eventId: "evt-1"))
    }

    func testPlannerOpenWithoutLiveRequestReportsNoLiveRequest() {
        XCTAssertEqual(
            UserQuestionSubmitPlanner.path(for: call("call-1", .open), pending: []),
            .noLiveRequest
        )
        // Ambiguous question-id match must not pick a waterfall.
        let a = UserQuestionWaterfall(eventId: "e1", agentId: nil, questions: [UserQuestion(id: "q1", question: "q")], callId: nil, timed: nil)
        let b = UserQuestionWaterfall(eventId: "e2", agentId: nil, questions: [UserQuestion(id: "q1", question: "q")], callId: nil, timed: nil)
        XCTAssertEqual(
            UserQuestionSubmitPlanner.path(for: call("call-y", .open), pending: [a, b]),
            .noLiveRequest
        )
    }

    func testPlannerMissingCallAndUnknownState() {
        XCTAssertEqual(UserQuestionSubmitPlanner.path(for: nil, pending: []), .callNotFound)
        XCTAssertEqual(
            UserQuestionSubmitPlanner.path(for: call("call-1", .unknown("paused")), pending: []),
            .unsupportedState("paused")
        )
    }

    // MARK: - Outcome mapping (false / REPLY_QUEUED)

    func testOutcomeMappingAcceptedBools() {
        XCTAssertEqual(UserQuestionSubmitPlanner.outcome(accepted: true), .answered)
        XCTAssertEqual(UserQuestionSubmitPlanner.outcome(accepted: false), .noLongerPending)
    }

    func testOutcomeMappingReplyQueuedIsSoftResult() {
        let error = LinkError.remote(RemoteError(code: "REPLY_QUEUED", message: "reply queued"))
        XCTAssertEqual(UserQuestionSubmitPlanner.outcome(for: error), .queued)
        // Other business errors must propagate.
        XCTAssertNil(UserQuestionSubmitPlanner.outcome(for: LinkError.remote(RemoteError(code: "NO_PROVIDER", message: "x"))))
        XCTAssertNil(UserQuestionSubmitPlanner.outcome(for: LinkError.notConnected))
    }

    // MARK: - State write-back

    @MainActor
    func testViewModelApplyProjectionAndLocalRemoval() throws {
        let viewModel = SessionViewModel(sessionId: "session-1")
        XCTAssertEqual(viewModel.userQuestionsActiveCount, 0)

        viewModel.applyUserQuestionProjection(TestJSON.value("""
        {"active":[
            {"callId":"call-1","state":"continued","questions":[{"id":"q1","question":"a"}]},
            {"callId":"call-2","state":"open","questions":[{"id":"q2","question":"b"}]}
        ]}
        """))
        XCTAssertEqual(viewModel.activeUserQuestions.map(\.callId), ["call-1", "call-2"])
        XCTAssertEqual(viewModel.userQuestionsActiveCount, 2)

        // Successful answer write-back: only the answered call disappears.
        viewModel.markUserQuestionAnsweredLocally(callId: "call-1")
        XCTAssertEqual(viewModel.activeUserQuestions.map(\.callId), ["call-2"])
        XCTAssertEqual(viewModel.userQuestionsActiveCount, 1)

        // Refreshed projection (snapshot/session-list) settles the rest.
        viewModel.applyUserQuestionProjection(TestJSON.value("""
        {"active":[],"settled":[{"callId":"call-2","answers":[{"id":"q2","selected":[]}]}]}
        """))
        XCTAssertTrue(viewModel.activeUserQuestions.isEmpty)
        XCTAssertEqual(viewModel.userQuestionsActiveCount, 0)
    }

    // MARK: - G1 (task-6): live $events requests merge into the cards

    @MainActor
    private func makeViewModel() -> SessionViewModel {
        SessionViewModel(sessionId: "session-1")
    }

    private func waterfall(
        eventId: String,
        agentId: String? = "session-1",
        callId: String?,
        questionIds: [String] = ["q1"]
    ) -> UserQuestionWaterfall {
        UserQuestionWaterfall(
            eventId: eventId,
            agentId: agentId,
            questions: questionIds.map { UserQuestion(id: $0, question: "q-" + $0) },
            callId: callId,
            timed: true
        )
    }

    @MainActor
    func testLivePendingAppearsWhenProjectionIsEmpty() {
        let viewModel = makeViewModel()
        // Legacy/blocking ask_user_question builds keep the projection empty.
        viewModel.applyUserQuestionProjection(TestJSON.value(#"{"active":[],"settled":[]}"#))
        XCTAssertTrue(viewModel.activeUserQuestions.isEmpty)

        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-1", callId: "call-1", questionIds: ["q1", "q2"]),
        ])
        XCTAssertEqual(viewModel.activeUserQuestions.map(\.callId), ["call-1"])
        let live = viewModel.activeUserQuestions[0]
        XCTAssertEqual(live.state, .open)
        XCTAssertEqual(live.questions.map(\.id), ["q1", "q2"])
        XCTAssertEqual(viewModel.userQuestionsActiveCount, 1)
    }

    @MainActor
    func testLivePendingUsesEventIdWhenWaitCallIdMissing() {
        let viewModel = makeViewModel()
        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-fallback", callId: nil),
        ])
        XCTAssertEqual(viewModel.activeUserQuestions.map(\.callId), ["evt-fallback"])
        XCTAssertEqual(viewModel.activeUserQuestions.first?.state, .open)
    }

    @MainActor
    func testProjectionWinsOverLiveOnSameCallId() {
        let viewModel = makeViewModel()
        viewModel.applyUserQuestionProjection(TestJSON.value("""
        {"active":[{"callId":"call-1","state":"continued","questions":[{"id":"q1","question":"proj"}]}]}
        """))
        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-1", callId: "call-1"),
        ])
        XCTAssertEqual(viewModel.activeUserQuestions.count, 1)
        XCTAssertEqual(viewModel.activeUserQuestions.first?.state, .continued)
        XCTAssertEqual(viewModel.activeUserQuestions.first?.questions.first?.question, "proj")
    }

    @MainActor
    func testDuplicateLiveWaterfallsKeepSingleCard() {
        let viewModel = makeViewModel()
        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-1", callId: "call-1"),
            waterfall(eventId: "evt-1", callId: "call-1"),
            waterfall(eventId: "evt-2", callId: "call-2"),
        ])
        XCTAssertEqual(viewModel.activeUserQuestions.map(\.callId), ["call-1", "call-2"])
    }

    @MainActor
    func testPendingRemovalDropsLiveCard() {
        let viewModel = makeViewModel()
        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-1", callId: "call-1"),
        ])
        XCTAssertEqual(viewModel.activeUserQuestions.count, 1)
        // Host settled the waterfall / teardown cleared the pending list.
        viewModel.applyPendingUserQuestionWaterfalls([])
        XCTAssertTrue(viewModel.activeUserQuestions.isEmpty)
        XCTAssertEqual(viewModel.userQuestionsActiveCount, 0)
    }

    @MainActor
    func testPendingFromOtherSessionIsFilteredOut() {
        let viewModel = makeViewModel()
        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-other", agentId: "session-2", callId: "call-2"),
            waterfall(eventId: "evt-mine", agentId: "session-1", callId: "call-1"),
            waterfall(eventId: "evt-noagent", agentId: nil, callId: "call-0"),
        ])
        XCTAssertEqual(viewModel.activeUserQuestions.map(\.callId), ["call-1", "call-0"])
    }

    @MainActor
    func testSubmitPathForLiveOpenCallUsesEventsResult() {
        let viewModel = makeViewModel()
        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-1", callId: "call-1"),
        ])
        XCTAssertEqual(
            viewModel.userQuestionSubmitPath(callId: "call-1"),
            .live(eventId: "evt-1")
        )
        // Unknown callIds stay explicit.
        XCTAssertEqual(viewModel.userQuestionSubmitPath(callId: "missing"), .callNotFound)
    }

    @MainActor
    func testMarkAnsweredRemovesLiveCard() {
        let viewModel = makeViewModel()
        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-1", callId: "call-1"),
            waterfall(eventId: "evt-2", callId: "call-2"),
        ])
        viewModel.markUserQuestionAnsweredLocally(callId: "call-1")
        XCTAssertEqual(viewModel.activeUserQuestions.map(\.callId), ["call-2"])
        XCTAssertEqual(viewModel.userQuestionsActiveCount, 1)
        // The live pending list still holds evt-2 only (LinkService removed evt-1
        // after the live answer); a refresh keeps the settled call gone.
        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-2", callId: "call-2"),
        ])
        XCTAssertEqual(viewModel.activeUserQuestions.map(\.callId), ["call-2"])
    }

    // MARK: - Code-review fixes (task-9)

    // P0-1 / P1-1: answered cards stay hidden when stale state is replayed.
    @MainActor
    func testStaleProjectionReplayDoesNotResurrectAnsweredCard() {
        let viewModel = makeViewModel()
        let staleProjection = TestJSON.value("""
        {"active":[{"callId":"call-1","state":"continued","questions":[{"id":"q1","question":"a"}]}]}
        """)
        viewModel.applyUserQuestionProjection(staleProjection)
        XCTAssertEqual(viewModel.activeUserQuestions.map(\.callId), ["call-1"])

        viewModel.markUserQuestionAnsweredLocally(callId: "call-1")
        XCTAssertTrue(viewModel.activeUserQuestions.isEmpty)

        // The journal projection only refreshes on snapshots, so rebuildRows()
        // replays the same stale value after the next event (P0-1).
        viewModel.applyUserQuestionProjection(staleProjection)
        XCTAssertTrue(viewModel.activeUserQuestions.isEmpty)
        XCTAssertTrue(viewModel.isUserQuestionAnsweredLocally("call-1"))

        // A stale session/list write-back (P1-1) must not resurrect it either.
        viewModel.applyUserQuestionProjection(staleProjection)
        XCTAssertTrue(viewModel.activeUserQuestions.isEmpty)
        XCTAssertEqual(viewModel.userQuestionsActiveCount, 0)
    }

    @MainActor
    func testRepublishedLiveWaterfallStaysHiddenAfterAnswer() {
        let viewModel = makeViewModel()
        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-1", callId: "call-1"),
        ])
        viewModel.markUserQuestionAnsweredLocally(callId: "call-1")
        XCTAssertTrue(viewModel.activeUserQuestions.isEmpty)

        // $events redelivery after a reconnect republishes the same waterfall.
        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-1", callId: "call-1"),
            waterfall(eventId: "evt-2", callId: "call-2"),
        ])
        XCTAssertEqual(viewModel.activeUserQuestions.map(\.callId), ["call-2"])
    }

    // P0-2: one answer per question; untouched questions become explicit skips.
    private func threeQuestionCall() -> UserQuestionCall {
        UserQuestionCall(
            callId: "call-multi",
            state: .open,
            questions: [
                UserQuestion(id: "q1", question: "one", options: [
                    UserQuestionOption(label: "A"), UserQuestionOption(label: "B"),
                ]),
                UserQuestion(id: "q2", question: "two", options: [
                    UserQuestionOption(label: "C"), UserQuestionOption(label: "D"),
                ]),
                UserQuestion(id: "q3", question: "three", options: [
                    UserQuestionOption(label: "E"), UserQuestionOption(label: "F"),
                ]),
            ]
        )
    }

    func testComposerFillsUnansweredQuestionsWithExplicitSkips() throws {
        let call = threeQuestionCall()
        let answers = UserQuestionAnswerComposer.compose(
            call: call,
            selected: ["q1": ["A"]],
            custom: [:]
        )
        XCTAssertEqual(answers.map(\.id), ["q1", "q2", "q3"])
        XCTAssertEqual(answers[0].selected, ["A"])
        XCTAssertEqual(answers[1].selected, [])
        XCTAssertNil(answers[1].custom)
        XCTAssertEqual(answers[2].selected, [])
        XCTAssertEqual(UserQuestionAnswerComposer.answeredCount(call: call, selected: ["q1": ["A"]], custom: [:]), 1)

        let json = try UserQuestionAnswersBatch(answers: answers).encodedJSONString()
        XCTAssertEqual(
            json,
            #"{"answers":[{"id":"q1","selected":["A"]},{"id":"q2","selected":[]},{"id":"q3","selected":[]}]}"#
        )
    }

    func testComposerTrimsCustomAndCountsAnsweredQuestions() {
        let call = threeQuestionCall()
        let answers = UserQuestionAnswerComposer.compose(
            call: call,
            selected: ["q1": ["B"]],
            custom: ["q2": "  自定义  "]
        )
        XCTAssertEqual(answers[0].selected, ["B"])
        XCTAssertEqual(answers[1].selected, [])
        XCTAssertEqual(answers[1].custom, "自定义")
        XCTAssertEqual(answers[2].selected, [])
        XCTAssertEqual(
            UserQuestionAnswerComposer.answeredCount(call: call, selected: ["q1": ["B"]], custom: ["q2": "  自定义  "]),
            2
        )
        // Whitespace-only custom text does not count as an answer.
        XCTAssertEqual(
            UserQuestionAnswerComposer.answeredCount(call: call, selected: [:], custom: ["q1": "   "]),
            0
        )
    }

    // P1-3: per-entry tolerant projection decoding.
    func testProjectionSkipsMalformedEntriesButKeepsValidOnes() {
        let parsed = projection("""
        {"active":[
          {"callId":"good-1","state":"open","questions":[{"id":"q1","question":"ok"}]},
          {"state":"open","questions":[]},
          {"callId":123},
          {"callId":"good-2","state":"continued","questions":[
              {"id":"q2","question":"ok2"},
              {"question":"missing id"}
          ]}
        ],"settled":[
          {"answers":[]},
          {"callId":"settled-1","answers":[{"id":"q1","selected":["A"]},{"selected":[]}]}
        ]}
        """)
        XCTAssertEqual(parsed.active.map(\.callId), ["good-1", "good-2"])
        XCTAssertEqual(parsed.active[1].questions.map(\.id), ["q2"])
        XCTAssertEqual(parsed.settled.map(\.callId), ["settled-1"])
        XCTAssertEqual(parsed.settled.first?.answers.map(\.id), ["q1"])
    }

    func testProjectionAllMalformedStillReturnsEmptyInsteadOfThrowing() {
        let parsed = projection("""
        {"active":[{"state":"open"},{"callId":[]}],"settled":[{"callId":{}}]}
        """)
        XCTAssertTrue(parsed.active.isEmpty)
        XCTAssertTrue(parsed.settled.isEmpty)
    }

    @MainActor
    func testProjectionCallWithoutQuestionsIsHidden() {
        let viewModel = makeViewModel()
        viewModel.applyUserQuestionProjection(TestJSON.value("""
        {"active":[
          {"callId":"empty","state":"open","questions":[]},
          {"callId":"ok","state":"open","questions":[{"id":"q1","question":"a"}]}
        ]}
        """))
        XCTAssertEqual(viewModel.activeUserQuestions.map(\.callId), ["ok"])
    }

    // P1-4: waterfalls without usable questions never become cards.
    func testWaterfallWithoutUsableQuestionsIsDiscarded() {
        XCTAssertNil(UserQuestionWaterfall.parse(TestJSON.value("""
        {"type":"waterfall","event":"user-questions/request","eventId":"e1","agentId":"s1","request":{"questions":[]}}
        """)))
        XCTAssertNil(UserQuestionWaterfall.parse(TestJSON.value("""
        {"type":"waterfall","event":"user-questions/request","eventId":"e2","agentId":"s1","request":{}}
        """)))
        XCTAssertNil(UserQuestionWaterfall.parse(TestJSON.value("""
        {"type":"waterfall","event":"user-questions/request","eventId":"e3","agentId":"s1","request":{"questions":[{"question":"no id"}]}}
        """)))

        let event = ForwardedRemoteEvent.decode(TestJSON.value("""
        {"type":"waterfall","event":"user-questions/request","eventId":"e4","agentId":"s1","request":{"questions":[]}}
        """))
        guard case .waterfall(_, _, let userQuestion) = event else {
            return XCTFail("expected .waterfall")
        }
        XCTAssertNil(userQuestion)
    }

    func testWaterfallWithUsableQuestionsStillParses() throws {
        let waterfall = try XCTUnwrap(UserQuestionWaterfall.parse(TestJSON.value("""
        {"type":"waterfall","event":"user-questions/request","eventId":"e5","agentId":"s1",
         "request":{"questions":[{"id":"q1","question":"pick","options":[{"label":"A"}]}]}}
        """)))
        XCTAssertEqual(waterfall.eventId, "e5")
        XCTAssertEqual(waterfall.questions.map(\.id), ["q1"])
    }

    // MARK: - T10: cancel frames / duplicate & concurrent submits

    func testCancelFrameDropsPendingUserQuestionAndApprovalWaterfall() {
        var approvals = [
            ApprovalWaterfall(eventId: "evt-approval", agentId: "s1", toolName: "bash", callId: "c0",
                              reason: "r", displayReason: nil),
            ApprovalWaterfall(eventId: "evt-other", agentId: "s2", toolName: "bash", callId: "c1",
                              reason: "r", displayReason: nil),
        ]
        var questions = [
            UserQuestionWaterfall(eventId: "evt-uq", agentId: "s1",
                                  questions: [UserQuestion(id: "q1", question: "pick")],
                                  callId: "call-1", timed: false),
            UserQuestionWaterfall(eventId: "evt-keep", agentId: "s1",
                                  questions: [UserQuestion(id: "q2", question: "keep")],
                                  callId: "call-2", timed: false),
        ]
        // Host pushes this when the turn is aborted by session/cancel (§3.7.1).
        let event = ForwardedRemoteEvent.decode(TestJSON.value(#"{"type":"cancel","eventId":"evt-uq"}"#))
        ForwardedWaterfallQueue.apply(event, approvals: &approvals, questions: &questions)
        XCTAssertEqual(questions.map(\.eventId), ["evt-keep"])
        XCTAssertEqual(approvals.map(\.eventId), ["evt-approval", "evt-other"])

        let approvalCancel = ForwardedRemoteEvent.decode(TestJSON.value(#"{"type":"cancel","eventId":"evt-approval"}"#))
        ForwardedWaterfallQueue.apply(approvalCancel, approvals: &approvals, questions: &questions)
        XCTAssertEqual(approvals.map(\.eventId), ["evt-other"])
        XCTAssertEqual(questions.count, 1)
    }

    func testWaterfallFrameUpsertsByEventId() {
        var approvals: [ApprovalWaterfall] = []
        var questions: [UserQuestionWaterfall] = []
        let first = ForwardedRemoteEvent.decode(TestJSON.value("""
        {"type":"waterfall","event":"user-questions/request","eventId":"evt-1","agentId":"s1",
         "request":{"questions":[{"id":"q1","question":"one"}]}}
        """))
        ForwardedWaterfallQueue.apply(first, approvals: &approvals, questions: &questions)
        XCTAssertEqual(questions.count, 1)
        // Redelivery of the same eventId updates in place (no duplicate card).
        let second = ForwardedRemoteEvent.decode(TestJSON.value("""
        {"type":"waterfall","event":"user-questions/request","eventId":"evt-1","agentId":"s1",
         "request":{"questions":[{"id":"q1","question":"updated"}]}}
        """))
        ForwardedWaterfallQueue.apply(second, approvals: &approvals, questions: &questions)
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions.first?.questions.first?.question, "updated")
    }

    func testSubmitGateRejectsDuplicateInFlightSubmit() {
        var gate = UserQuestionSubmitGate()
        XCTAssertTrue(gate.begin("call-1"))
        XCTAssertTrue(gate.isInFlight("call-1"))
        // A second submit for the same call (double tap / racing caller) is rejected.
        XCTAssertFalse(gate.begin("call-1"))
        gate.end("call-1")
        XCTAssertFalse(gate.isInFlight("call-1"))
        // Once the first attempt finished (success or error) a retry is allowed.
        XCTAssertTrue(gate.begin("call-1"))
    }

    func testSubmitGateAllowsDifferentCallsConcurrently() {
        var gate = UserQuestionSubmitGate()
        XCTAssertTrue(gate.begin("call-1"))
        XCTAssertTrue(gate.begin("call-2"))
        XCTAssertEqual(gate.inFlight, ["call-1", "call-2"])
    }

    @MainActor
    func testDuplicateAnswerAfterLocalAnswerThrowsCallNotFound() async {
        let viewModel = makeViewModel()
        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-1", callId: "call-1"),
        ])
        viewModel.markUserQuestionAnsweredLocally(callId: "call-1")
        do {
            _ = try await viewModel.skipUserQuestion(callId: "call-1")
            XCTFail("answering an already answered call must fail")
        } catch let error as UserQuestionSubmitError {
            XCTAssertEqual(error, .callNotFound("call-1"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    @MainActor
    func testSubmitUnknownCallFailsBeforeNetwork() async {
        let viewModel = makeViewModel()
        // No link attached: the path validation must still report callNotFound
        // instead of a generic "not connected" (duplicate/expired answer UX).
        do {
            _ = try await viewModel.submitUserQuestionAnswers(callId: "missing", answers: [])
            XCTFail("unknown call must not be submitted")
        } catch let error as UserQuestionSubmitError {
            XCTAssertEqual(error, .callNotFound("missing"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    @MainActor
    func testAbortDismissesLiveQuestionsAndKeepsThemHidden() {
        let viewModel = makeViewModel()
        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-1", callId: "call-1"),
            waterfall(eventId: "evt-2", callId: "call-2"),
        ])
        XCTAssertEqual(viewModel.activeUserQuestions.count, 2)

        // Composer abort: the pending live question belongs to the aborted turn.
        viewModel.dismissLiveUserQuestionsForAbortedTurn()
        XCTAssertTrue(viewModel.activeUserQuestions.isEmpty)
        XCTAssertEqual(viewModel.userQuestionsActiveCount, 0)

        // A republished pending list (redelivery/reconnect) must not re-add it.
        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-1", callId: "call-1"),
        ])
        XCTAssertTrue(viewModel.activeUserQuestions.isEmpty)
        XCTAssertEqual(viewModel.userQuestionSubmitPath(callId: "call-1"), .callNotFound)

        // A brand-new ask after the abort still shows normally.
        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-3", callId: "call-3"),
        ])
        XCTAssertEqual(viewModel.activeUserQuestions.map(\.callId), ["call-3"])
    }

    @MainActor
    func testAbortDismissDoesNotRemoveProjectionCalls() {
        let viewModel = makeViewModel()
        viewModel.applyUserQuestionProjection(TestJSON.value("""
        {"active":[{"callId":"projection-1","state":"continued","questions":[{"id":"q1","question":"a"}]}]}
        """))
        viewModel.applyPendingUserQuestionWaterfalls([
            waterfall(eventId: "evt-1", callId: "call-1"),
        ])
        viewModel.dismissLiveUserQuestionsForAbortedTurn()
        // Only the live half is dropped; a projection-backed (timed build) call
        // stays answerable.
        XCTAssertEqual(viewModel.activeUserQuestions.map(\.callId), ["projection-1"])
        XCTAssertEqual(viewModel.userQuestionSubmitPath(callId: "projection-1"), .unary(callId: "projection-1"))
    }
}
