import Foundation

/// Pure paging / draft / validation state behind `UserQuestionCardView`.
///
/// The card renders one question at a time (desktop parity). Every decision that
/// does not need a view lives here, so it stays unit-testable:
/// - current page + previous/next navigation,
/// - per-question draft (selected option labels + custom free text),
/// - explicit skip bookkeeping,
/// - answer-batch serialization and "submit only when complete" validation.
///
/// `UserQuestionCardView` owns one instance in `@State`. The call is snapshotted
/// per card identity: the parent keys cards by `callId`, and a pending call's
/// question list does not change while the card is on screen.
struct UserQuestionPagerModel {

    /// Pure result of a card action, so the view only maps it to callbacks/labels.
    enum ActionResult: Equatable {
        /// The page moved; nothing leaves the card.
        case moved(to: Int)
        /// Every question is answered or skipped; the batch is ready for `onSubmit`.
        case submitted([UserQuestionAnswer])
        /// Submit was refused; the page jumped to the first incomplete question.
        case incomplete(index: Int)
        /// There is no question to act on (empty call).
        case idle
    }

    let call: UserQuestionCall
    private(set) var currentIndex: Int
    /// question.id -> selected option labels (labels are the wire values).
    private(set) var selectedLabels: [String: Set<String>]
    /// question.id -> custom ("其他") free-text answer.
    private(set) var customTexts: [String: String]
    /// question.id set explicitly skipped; these serialize as `{id, selected: []}`.
    private(set) var skippedQuestionIds: Set<String>

    init(call: UserQuestionCall) {
        self.call = call
        self.currentIndex = 0
        self.selectedLabels = [:]
        self.customTexts = [:]
        self.skippedQuestionIds = []
    }

    // MARK: - Pages

    var questions: [UserQuestion] { call.questions }

    var questionCount: Int { call.questions.count }

    var currentQuestion: UserQuestion? {
        guard questions.indices.contains(currentIndex) else { return nil }
        return questions[currentIndex]
    }

    /// A single-question card has no pager (desktop parity).
    var showsPager: Bool { questionCount > 1 }

    var isFirstQuestion: Bool { currentIndex <= 0 }

    var isLastQuestion: Bool { questionCount > 0 && currentIndex >= questionCount - 1 }

    /// "i / n" progress label shown between the pager buttons.
    var progressText: String {
        guard questionCount > 0 else { return "0 / 0" }
        return "\(min(currentIndex, questionCount - 1) + 1) / \(questionCount)"
    }

    mutating func goToPreviousQuestion() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    mutating func goToNextQuestion() {
        guard currentIndex < questionCount - 1 else { return }
        currentIndex += 1
    }

    // MARK: - Draft

    func selectedLabels(for questionId: String) -> Set<String> {
        selectedLabels[questionId] ?? []
    }

    func customText(for questionId: String) -> String {
        customTexts[questionId] ?? ""
    }

    func isOptionSelected(_ label: String, for questionId: String) -> Bool {
        selectedLabels[questionId]?.contains(label) == true
    }

    func isSkipped(_ questionId: String) -> Bool {
        skippedQuestionIds.contains(questionId)
    }

    /// True when the question carries a usable answer (option or custom text).
    func hasAnswer(_ question: UserQuestion) -> Bool {
        let hasSelection = (question.options ?? []).contains {
            isOptionSelected($0.label, for: question.id)
        }
        let hasCustom = !customText(for: question.id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return hasSelection || hasCustom
    }

    /// A question is "done" when it is answered or explicitly skipped.
    func isComplete(_ question: UserQuestion) -> Bool {
        isSkipped(question.id) || hasAnswer(question)
    }

    /// First question that is neither answered nor skipped (nil = batch complete).
    var firstIncompleteIndex: Int? {
        questions.firstIndex { !isComplete($0) }
    }

    /// True when every question is answered or skipped.
    var canSubmit: Bool {
        !questions.isEmpty && firstIncompleteIndex == nil
    }

    /// Toggles one option on the current page.
    ///
    /// - Returns: `true` when a single-select answer auto-advanced to the next
    ///   page. The last page never auto-advances; multi-select never does.
    @discardableResult
    mutating func toggleOption(_ label: String) -> Bool {
        guard let question = currentQuestion else { return false }
        var labels = selectedLabels[question.id] ?? []
        if question.isMultiSelect {
            if labels.contains(label) { labels.remove(label) } else { labels.insert(label) }
        } else {
            // Single-select: the latest tap replaces the selection. Re-tapping the
            // selected option keeps it ("跳过" is the explicit no-answer path).
            labels = [label]
        }
        // Drop anything that is not a real option of this question (stale drafts).
        labels.formIntersection(Set((question.options ?? []).map(\.label)))
        selectedLabels[question.id] = labels
        if hasAnswer(question) {
            skippedQuestionIds.remove(question.id)
        }
        // Desktop parity: a single-select answer advances automatically.
        guard !question.isMultiSelect, hasAnswer(question), !isLastQuestion else { return false }
        currentIndex += 1
        return true
    }

    mutating func setCustomText(_ text: String, for questionId: String) {
        customTexts[questionId] = text
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            skippedQuestionIds.remove(questionId)
        }
    }

    // MARK: - Answers

    /// One answer per question, in call order. Skipped and untouched questions are
    /// serialized explicitly as `{id, selected: []}`, so a partial batch is never
    /// ambiguous (P0-2 contract).
    var answers: [UserQuestionAnswer] {
        let composed = UserQuestionAnswerComposer.compose(
            call: call,
            selected: selectedLabels,
            custom: customTexts
        )
        guard !skippedQuestionIds.isEmpty else { return composed }
        return composed.map { answer in
            skippedQuestionIds.contains(answer.id)
                ? UserQuestionAnswer(id: answer.id, selected: [])
                : answer
        }
    }

    // MARK: - Actions

    /// Skips the current page: its draft is dropped, the question serializes as an
    /// empty answer, and the card moves on. On the last page the whole batch is
    /// submitted immediately (skipped/unanswered questions as `selected: []`).
    mutating func skipCurrentQuestion() -> ActionResult {
        guard let question = currentQuestion else { return .idle }
        skippedQuestionIds.insert(question.id)
        selectedLabels[question.id] = []
        customTexts[question.id] = ""
        if isLastQuestion { return .submitted(answers) }
        currentIndex += 1
        return .moved(to: currentIndex)
    }

    /// Validates the whole batch before submit: a batch with incomplete questions
    /// does not leave the card; the pager jumps to the first incomplete question.
    mutating func attemptSubmit() -> ActionResult {
        guard !questions.isEmpty else { return .idle }
        guard let index = firstIncompleteIndex else { return .submitted(answers) }
        currentIndex = index
        return .incomplete(index: index)
    }
}
