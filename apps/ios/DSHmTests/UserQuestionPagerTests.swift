import XCTest
@testable import DSHm

/// Pure paging / draft / validation tests for `UserQuestionPagerModel`, the logic
/// behind `UserQuestionCardView` (one question per page, desktop parity).
final class UserQuestionPagerTests: XCTestCase {

    // MARK: - Fixtures

    private func singleSelectQuestion(
        id: String,
        options: [String] = ["A", "B", "C"]
    ) -> UserQuestion {
        UserQuestion(
            id: id,
            question: "问题 \(id)",
            options: options.map { UserQuestionOption(label: $0) },
            multiSelect: false
        )
    }

    private func multiSelectQuestion(
        id: String,
        options: [String] = ["A", "B", "C"]
    ) -> UserQuestion {
        UserQuestion(
            id: id,
            question: "问题 \(id)",
            options: options.map { UserQuestionOption(label: $0) },
            multiSelect: true
        )
    }

    private func makeModel(_ questions: [UserQuestion]) -> UserQuestionPagerModel {
        UserQuestionPagerModel(
            call: UserQuestionCall(callId: "call-1", state: .open, questions: questions)
        )
    }

    // MARK: - Single-select auto advance

    func testSingleSelectAutoAdvancesToNextQuestion() {
        var model = makeModel([singleSelectQuestion(id: "q1"), singleSelectQuestion(id: "q2")])
        XCTAssertEqual(model.currentIndex, 0)

        let advanced = model.toggleOption("B")

        XCTAssertTrue(advanced)
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(model.selectedLabels(for: "q1"), ["B"])
        XCTAssertEqual(model.progressText, "2 / 2")
    }

    func testSingleSelectOnLastQuestionStaysPut() {
        var model = makeModel([singleSelectQuestion(id: "q1"), singleSelectQuestion(id: "q2")])
        model.goToNextQuestion()

        XCTAssertFalse(model.toggleOption("A"))
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(model.selectedLabels(for: "q2"), ["A"])
    }

    func testSingleSelectRetapKeepsSelection() {
        var model = makeModel([singleSelectQuestion(id: "q1")])

        XCTAssertFalse(model.toggleOption("A"))
        XCTAssertFalse(model.toggleOption("A"))

        XCTAssertEqual(model.selectedLabels(for: "q1"), ["A"])
    }

    // MARK: - Multi-select stays on page

    func testMultiSelectStaysOnPageAndAccumulates() {
        var model = makeModel([multiSelectQuestion(id: "q1"), singleSelectQuestion(id: "q2")])

        XCTAssertFalse(model.toggleOption("A"))
        XCTAssertFalse(model.toggleOption("C"))
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertEqual(model.selectedLabels(for: "q1"), ["A", "C"])

        XCTAssertFalse(model.toggleOption("A"))
        XCTAssertEqual(model.selectedLabels(for: "q1"), ["C"])
        XCTAssertEqual(model.currentIndex, 0)
    }

    // MARK: - Draft retention on back/forward

    func testGoingBackKeepsSelectionsAndCustomDraft() {
        var model = makeModel([singleSelectQuestion(id: "q1"), singleSelectQuestion(id: "q2")])
        XCTAssertTrue(model.toggleOption("B"))          // q1 answered, auto-advanced
        XCTAssertEqual(model.currentIndex, 1)
        model.setCustomText("自定义补充", for: "q2")

        model.goToPreviousQuestion()
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertEqual(model.selectedLabels(for: "q1"), ["B"])

        model.goToNextQuestion()
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(model.customText(for: "q2"), "自定义补充")
    }

    // MARK: - Skip semantics

    func testSkipMovesToNextQuestionAndSerializesEmpty() {
        var model = makeModel([singleSelectQuestion(id: "q1"), singleSelectQuestion(id: "q2")])
        XCTAssertTrue(model.toggleOption("A"))          // q1 answered → q2
        model.goToPreviousQuestion()

        XCTAssertEqual(model.skipCurrentQuestion(), .moved(to: 1))
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertTrue(model.isSkipped("q1"))
        XCTAssertFalse(model.hasAnswer(model.questions[0]))
        XCTAssertEqual(model.selectedLabels(for: "q1"), [])
    }

    func testSkipOnLastQuestionSubmitsWholeBatchPreservingEarlierAnswers() {
        var model = makeModel([singleSelectQuestion(id: "q1"), multiSelectQuestion(id: "q2")])
        XCTAssertTrue(model.toggleOption("B"))          // q1 answered → q2 (last)

        let result = model.skipCurrentQuestion()

        guard case .submitted(let answers) = result else {
            XCTFail("expected a submit result, got \(result)")
            return
        }
        XCTAssertEqual(answers, [
            UserQuestionAnswer(id: "q1", selected: ["B"]),
            UserQuestionAnswer(id: "q2", selected: []),
        ])
    }

    func testSkipOnLastQuestionSubmitsEmptyAnswersWhenNothingAnswered() {
        var model = makeModel([singleSelectQuestion(id: "q1"), singleSelectQuestion(id: "q2")])
        model.goToNextQuestion()

        let result = model.skipCurrentQuestion()

        guard case .submitted(let answers) = result else {
            XCTFail("expected a submit result, got \(result)")
            return
        }
        XCTAssertEqual(answers, [
            UserQuestionAnswer(id: "q1", selected: []),
            UserQuestionAnswer(id: "q2", selected: []),
        ])
    }

    func testSkippedQuestionIsCompleteAndAnsweringItClearsSkip() {
        var model = makeModel([singleSelectQuestion(id: "q1"), singleSelectQuestion(id: "q2")])
        XCTAssertEqual(model.skipCurrentQuestion(), .moved(to: 1))
        XCTAssertEqual(model.firstIncompleteIndex, 1)

        model.goToPreviousQuestion()
        XCTAssertTrue(model.isSkipped("q1"))
        XCTAssertTrue(model.toggleOption("C"))          // re-answer q1 → auto-advance
        XCTAssertFalse(model.isSkipped("q1"))
        XCTAssertEqual(model.selectedLabels(for: "q1"), ["C"])
        XCTAssertEqual(model.currentIndex, 1)
    }

    // MARK: - Submit validation

    func testSubmitJumpsToFirstIncompleteQuestion() {
        var model = makeModel([
            singleSelectQuestion(id: "q1"),
            singleSelectQuestion(id: "q2"),
            singleSelectQuestion(id: "q3"),
        ])
        XCTAssertTrue(model.toggleOption("A"))          // q1 answered → q2
        model.goToNextQuestion()                        // q2 left blank → q3
        XCTAssertEqual(model.currentIndex, 2)
        XCTAssertFalse(model.toggleOption("B"))         // q3 answered, last page stays

        XCTAssertFalse(model.canSubmit)
        XCTAssertEqual(model.firstIncompleteIndex, 1)
        XCTAssertEqual(model.attemptSubmit(), .incomplete(index: 1))
        XCTAssertEqual(model.currentIndex, 1)
    }

    func testSubmitSucceedsWhenAllQuestionsAnsweredOrSkipped() {
        var model = makeModel([singleSelectQuestion(id: "q1"), singleSelectQuestion(id: "q2")])
        XCTAssertTrue(model.toggleOption("A"))          // q1 → q2
        XCTAssertFalse(model.toggleOption("B"))         // q2 answered (last)
        XCTAssertTrue(model.canSubmit)

        let result = model.attemptSubmit()

        guard case .submitted(let answers) = result else {
            XCTFail("expected a submit result, got \(result)")
            return
        }
        XCTAssertEqual(answers.map(\.id), ["q1", "q2"])
        XCTAssertEqual(answers[0].selected, ["A"])
        XCTAssertEqual(answers[1].selected, ["B"])
    }

    func testSubmitSucceedsWhenTheOnlyQuestionIsSkipped() {
        var model = makeModel([singleSelectQuestion(id: "q1")])
        XCTAssertEqual(model.skipCurrentQuestion(), .submitted([
            UserQuestionAnswer(id: "q1", selected: []),
        ]))
    }

    func testCustomTextCountsAsAnswer() {
        var model = makeModel([singleSelectQuestion(id: "q1")])
        model.setCustomText("  补充说明  ", for: "q1")

        XCTAssertTrue(model.canSubmit)
        XCTAssertEqual(model.attemptSubmit(), .submitted([
            UserQuestionAnswer(id: "q1", selected: [], custom: "补充说明"),
        ]))
    }

    func testWhitespaceCustomTextDoesNotCountAsAnswer() {
        var model = makeModel([singleSelectQuestion(id: "q1")])
        model.setCustomText("   ", for: "q1")

        XCTAssertFalse(model.hasAnswer(model.questions[0]))
        XCTAssertEqual(model.attemptSubmit(), .incomplete(index: 0))
    }

    // MARK: - Answer batch serialization

    func testAnswersIncludeEveryQuestionInOrderWithSkipsEmpty() {
        var model = makeModel([
            singleSelectQuestion(id: "q1"),
            multiSelectQuestion(id: "q2"),
            singleSelectQuestion(id: "q3"),
        ])
        XCTAssertTrue(model.toggleOption("A"))          // q1 answered → q2
        XCTAssertEqual(model.skipCurrentQuestion(), .moved(to: 2))  // q2 skipped → q3
        model.setCustomText("  自定义  ", for: "q3")

        XCTAssertEqual(model.answers, [
            UserQuestionAnswer(id: "q1", selected: ["A"]),
            UserQuestionAnswer(id: "q2", selected: []),
            UserQuestionAnswer(id: "q3", selected: [], custom: "自定义"),
        ])
    }

    func testAnswersKeepCallOrderWhenCurrentPageIsInTheMiddle() {
        var model = makeModel([
            singleSelectQuestion(id: "q1"),
            multiSelectQuestion(id: "q2"),
            singleSelectQuestion(id: "q3"),
        ])
        XCTAssertTrue(model.toggleOption("A"))          // q1 → q2
        XCTAssertFalse(model.toggleOption("B"))         // q2 multi-select, stays
        XCTAssertFalse(model.toggleOption("C"))
        model.goToNextQuestion()                        // q3
        XCTAssertEqual(model.answers.map(\.id), ["q1", "q2", "q3"])
        XCTAssertEqual(model.answers[1].selected, ["B", "C"])
    }

    // MARK: - Pager visibility / progress

    func testSingleQuestionHidesPager() {
        let model = makeModel([singleSelectQuestion(id: "q1")])

        XCTAssertFalse(model.showsPager)
        XCTAssertEqual(model.progressText, "1 / 1")
    }

    func testProgressTextTracksNavigation() {
        var model = makeModel([
            singleSelectQuestion(id: "q1"),
            singleSelectQuestion(id: "q2"),
            singleSelectQuestion(id: "q3"),
        ])

        XCTAssertEqual(model.progressText, "1 / 3")
        model.goToNextQuestion()
        XCTAssertEqual(model.progressText, "2 / 3")
        model.goToNextQuestion()
        XCTAssertEqual(model.progressText, "3 / 3")

        model.goToNextQuestion()                        // clamped on the last page
        XCTAssertEqual(model.currentIndex, 2)
        XCTAssertEqual(model.progressText, "3 / 3")

        model.goToPreviousQuestion()
        XCTAssertEqual(model.progressText, "2 / 3")
    }

    // MARK: - Empty call

    func testEmptyQuestionListIsIdle() {
        var model = makeModel([])

        XCTAssertEqual(model.questionCount, 0)
        XCTAssertFalse(model.showsPager)
        XCTAssertNil(model.currentQuestion)
        XCTAssertEqual(model.progressText, "0 / 0")
        XCTAssertEqual(model.answers, [])
        XCTAssertFalse(model.canSubmit)
        XCTAssertFalse(model.toggleOption("A"))
        XCTAssertEqual(model.skipCurrentQuestion(), .idle)
        XCTAssertEqual(model.attemptSubmit(), .idle)
    }
}
