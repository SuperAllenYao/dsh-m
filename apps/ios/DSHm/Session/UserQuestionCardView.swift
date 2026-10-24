import SwiftUI

/// Inline user-question card (tech-design §14 / remote-protocol §3.7.2).
///
/// One card per active `userQuestions` call. Desktop parity: the card is embedded
/// directly above the composer (no full-screen sheet) and pages one question at a
/// time — `上一题 / i / n / 下一题` — so a call with many questions never grows past
/// the screen (fixes the real-device bug where a 9-question panel could not be
/// scrolled and the submit button was unreachable).
///
/// The view is stateless about networking — it reports the answer batch through
/// `onSubmit` (whole-card skip goes through `onSkip`); `SessionViewModel` owns the
/// request and the projection refresh.
///
/// Accessibility contract (E2E, task-4): `uq-card`, `uq-question-<i>` (global
/// question index), `uq-option-<i>` (option index across the whole call),
/// `uq-custom-input` (single question) / `uq-custom-input-<i>` (multi question),
/// `uq-submit`, `uq-skip`, `uq-error`, plus the pager `uq-pager-prev`,
/// `uq-progress`, `uq-pager-next` and the validation hint `uq-inline-notice`.
struct UserQuestionCardView: View {
    let call: UserQuestionCall
    /// True while the answer/skip request for this call is in flight.
    let isSubmitting: Bool
    /// Human-readable failure banner (already localized by the caller).
    let errorText: String?
    let onSubmit: ([UserQuestionAnswer]) -> Void
    let onSkip: () -> Void
    /// Optional retry hook shown in the error banner (refresh the snapshot).
    var onRetry: (() -> Void)? = nil
    /// v0.2.0 panel embedding: the interaction panel owns the title/status chrome,
    /// so the card drops its own header and card surface when embedded.
    var showsHeader: Bool = true
    var embedded: Bool = false

    /// Paging / draft / validation state (pure logic, unit-tested separately).
    @State private var model: UserQuestionPagerModel
    /// question.id set whose long detail is expanded.
    @State private var expandedDetails: Set<String> = []
    /// True after a submit attempt bounced back because a question was left blank.
    @State private var showsIncompleteNotice = false
    /// Measured natural height of the current page's stem (question + detail). The
    /// stem scrolls only when it overflows `stemMaxHeight`; a bare `ScrollView`
    /// would always consume the cap and leave a blank gap for short questions.
    @State private var stemContentHeight: CGFloat = 0

    /// Max height of the scrollable question stem area.
    private static let stemMaxHeight: CGFloat = 160
    /// Width of one pager button (fits "‹ 上一题" / "下一题 ›").
    private static let pagerButtonWidth: CGFloat = 88

    init(
        call: UserQuestionCall,
        isSubmitting: Bool,
        errorText: String?,
        onSubmit: @escaping ([UserQuestionAnswer]) -> Void,
        onSkip: @escaping () -> Void,
        onRetry: (() -> Void)? = nil,
        showsHeader: Bool = true,
        embedded: Bool = false
    ) {
        self.call = call
        self.isSubmitting = isSubmitting
        self.errorText = errorText
        self.onSubmit = onSubmit
        self.onSkip = onSkip
        self.onRetry = onRetry
        self.showsHeader = showsHeader
        self.embedded = embedded
        _model = State(initialValue: UserQuestionPagerModel(call: call))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if showsHeader {
                header
            }
            questionPage
            if showsIncompleteNotice {
                incompleteNotice
            }
            if let errorText, !errorText.isEmpty {
                InlineErrorView(message: errorText, retry: onRetry)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("uq-error")
            }
            if model.showsPager {
                pagerBar
            }
            actions
        }
        .padding(embedded ? 0 : Theme.Spacing.m)
        .background {
            if !embedded {
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(Theme.Palette.surfaceRaised)
            }
        }
        .overlay {
            if !embedded {
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Palette.accentBorder, lineWidth: 1)
            }
        }
        .shadow(
            color: embedded ? .clear : Theme.Palette.accent.opacity(0.10),
            radius: embedded ? 0 : 16,
            x: 0,
            y: embedded ? 0 : 4
        )
        // Keep the card as an accessibility container: XCUITest can address the
        // uq-card root and still reach its children (uq-question-*/uq-option-*/…).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("uq-card")
        .onChange(of: model.currentIndex) { _, _ in
            // New page: re-measure the stem instead of reusing the old height.
            stemContentHeight = 0
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityHidden(true)
            Text(headerText)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Chip(
                text: stateLabel,
                color: call.state == .continued ? Theme.Palette.warning : Theme.Palette.accent,
                background: call.state == .continued ? Theme.Palette.warningMuted : Theme.Palette.accentSoft,
                borderColor: call.state == .continued ? Theme.Palette.warningBorder : Theme.Palette.accentBorder
            )
        }
    }

    private var headerText: String {
        if call.questions.count == 1,
           let header = call.questions[0].header?.trimmingCharacters(in: .whitespacesAndNewlines),
           !header.isEmpty {
            return header
        }
        return L10n.t("需要你的回答")
    }

    /// `open` = the live waterfall is still waiting on us; `continued` = the timed
    /// wait expired and only the unary answer path is available (still answerable).
    private var stateLabel: String {
        call.state == .continued ? L10n.t("继续作答") : L10n.t("等待作答")
    }

    // MARK: - Current question page

    @ViewBuilder
    private var questionPage: some View {
        if let question = model.currentQuestion {
            questionContent(question, index: model.currentIndex)
                // Fresh identity per page: resets the field/scroll state, keeps the
                // drafts in the model (going back restores them).
                .id(question.id)
        }
    }

    private func questionContent(_ question: UserQuestion, index: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if model.showsPager {
                questionHeaderRow(question)
            }
            stemViewport(question, index: index)
            if let options = question.options, !options.isEmpty {
                optionsView(options, question: question, questionIndex: index)
            }
            customInput(for: question, questionIndex: index)
        }
    }

    @ViewBuilder
    private func questionHeaderRow(_ question: UserQuestion) -> some View {
        if let header = question.header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty {
            Text(header)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.accent)
                .lineLimit(1)
        }
    }

    /// Question text + optional detail. Capped and scrollable so a long
    /// plan-review detail cannot push the options / pager / actions off screen;
    /// options and the action bars stay outside the scroll area.
    private func stemViewport(_ question: UserQuestion, index: Int) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(question.question)
                    .font(Theme.Typography.bodyMedium)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("uq-question-\(index)")
                if let detail = question.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                    detailView(detail, question: question)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: StemHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            )
        }
        .onPreferenceChange(StemHeightPreferenceKey.self) { height in
            stemContentHeight = height
        }
        .frame(height: stemViewportHeight)
    }

    /// Natural content height, capped at `stemMaxHeight`.
    ///
    /// The height must be definite (not `maxHeight`): inside the interaction
    /// panel the card sits in a content-sized VStack, where a flexible ScrollView
    /// would collapse to zero and hide the question text entirely. 44pt is the
    /// first-layout fallback until the measure preference lands.
    private var stemViewportHeight: CGFloat {
        guard stemContentHeight > 0 else { return 44 }
        return min(stemContentHeight, Self.stemMaxHeight)
    }

    @ViewBuilder
    private func detailView(_ detail: String, question: UserQuestion) -> some View {
        let isExpanded = expandedDetails.contains(question.id)
        let isLong = detail.count > 120
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(detail)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(isLong && !isExpanded ? 4 : nil)
            if isLong {
                Button(isExpanded ? L10n.t("收起") : L10n.t("展开")) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isExpanded {
                            expandedDetails.remove(question.id)
                        } else {
                            expandedDetails.insert(question.id)
                        }
                    }
                }
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.accent)
                .buttonStyle(.plain)
                .accessibilityIdentifier("uq-detail-toggle-\(question.id)")
            }
        }
        // 行高由 SessionMessageListView 显式逐帧驱动；这里只做边界裁剪。
        .clipped()
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
    }

    // MARK: - Options

    private func optionsView(_ options: [UserQuestionOption], question: UserQuestion, questionIndex: Int) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            ForEach(Array(options.enumerated()), id: \.element.id) { optionIndex, option in
                optionRow(
                    option,
                    question: question,
                    globalIndex: globalOptionIndex(questionIndex: questionIndex, optionIndex: optionIndex)
                )
            }
        }
    }

    /// Accessibility `uq-option-<i>` is unique per card: options of all questions
    /// share one counter (single-question cards: 0..n-1).
    private func globalOptionIndex(questionIndex: Int, optionIndex: Int) -> Int {
        var index = optionIndex
        for previous in call.questions.prefix(questionIndex) {
            index += previous.options?.count ?? 0
        }
        return index
    }

    private func optionRow(_ option: UserQuestionOption, question: UserQuestion, globalIndex: Int) -> some View {
        let isSelected = model.isOptionSelected(option.label, for: question.id)
        return Button {
            guard !isSubmitting else { return }
            showsIncompleteNotice = false
            // Single-select answers auto-advance inside the model; multi-select
            // answers stay on the page until "下一题".
            model.toggleOption(option.label)
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                selectionIndicator(selected: isSelected, multiSelect: question.isMultiSelect)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(Theme.Typography.bodyMedium)
                        .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = option.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !description.isEmpty {
                        Text(description)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 10)
            .background(
                isSelected ? Theme.Palette.accentSoft : Theme.Palette.surface,
                in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(isSelected ? Theme.Palette.accentBorder : Theme.Palette.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
        .accessibilityIdentifier("uq-option-\(globalIndex)")
        .accessibilityLabel(option.label)
        .accessibilityValue(isSelected ? L10n.t("已选择") : L10n.t("未选择"))
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    private func selectionIndicator(selected: Bool, multiSelect: Bool) -> some View {
        ZStack {
            if multiSelect {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(selected ? Theme.Palette.accent : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(selected ? Theme.Palette.accent : Theme.Palette.borderStrong, lineWidth: 1.5)
                    )
            } else {
                Circle()
                    .fill(selected ? Theme.Palette.accent : .clear)
                    .overlay(Circle().strokeBorder(selected ? Theme.Palette.accent : Theme.Palette.borderStrong, lineWidth: 1.5))
            }
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.Palette.accentInk)
            }
        }
        .frame(width: 18, height: 18)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }

    // MARK: - Custom answer

    private func customInput(for question: UserQuestion, questionIndex: Int) -> some View {
        let hasSelection = !model.selectedLabels(for: question.id).isEmpty
        let hasCustom = !model.customText(for: question.id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .accessibilityHidden(true)
                TextField(L10n.t("其他回答（自定义）…"), text: customBinding(for: question.id), axis: .vertical)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .disabled(isSubmitting)
                    .accessibilityIdentifier(customInputIdentifier(questionIndex: questionIndex))
                    // Desktop parity (hardware keyboard): Return = continue/submit,
                    // Shift+Return = newline. The software keyboard keeps inserting
                    // a newline because the field is multi-line.
                    .onKeyPress { press in
                        guard press.key == .return, !press.modifiers.contains(.shift) else {
                            return .ignored
                        }
                        handlePrimaryAction()
                        return .handled
                    }
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 10)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )
            if !question.isMultiSelect, hasCustom, hasSelection {
                Text(L10n.t("自定义回答会覆盖所选选项"))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private func customInputIdentifier(questionIndex: Int) -> String {
        call.questions.count == 1 ? "uq-custom-input" : "uq-custom-input-\(questionIndex)"
    }

    private func customBinding(for questionId: String) -> Binding<String> {
        Binding(
            get: { model.customText(for: questionId) },
            set: { text in
                showsIncompleteNotice = false
                model.setCustomText(text, for: questionId)
            }
        )
    }

    // MARK: - Pager

    private var pagerBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
                guard !isSubmitting else { return }
                showsIncompleteNotice = false
                model.goToPreviousQuestion()
            } label: {
                pagerButtonLabel(icon: "chevron.left", title: L10n.t("上一题"))
            }
            .buttonStyle(OutlineButtonStyle(
                tint: Theme.Palette.textSecondary,
                border: Theme.Palette.border,
                width: Self.pagerButtonWidth
            ))
            .disabled(isSubmitting || model.isFirstQuestion)
            .opacity(model.isFirstQuestion ? 0.45 : 1)
            .accessibilityIdentifier("uq-pager-prev")

            Text(model.progressText)
                .font(Theme.Typography.captionMedium.monospacedDigit())
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("uq-progress")

            Button {
                guard !isSubmitting else { return }
                showsIncompleteNotice = false
                model.goToNextQuestion()
            } label: {
                pagerButtonLabel(icon: "chevron.right", title: L10n.t("下一题"))
            }
            .buttonStyle(OutlineButtonStyle(
                tint: Theme.Palette.textSecondary,
                border: Theme.Palette.border,
                width: Self.pagerButtonWidth
            ))
            .disabled(isSubmitting || model.isLastQuestion)
            .opacity(model.isLastQuestion ? 0.45 : 1)
            .accessibilityIdentifier("uq-pager-next")
        }
    }

    private func pagerButtonLabel(icon: String, title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
        }
    }

    // MARK: - Actions

    /// Skip = drop the current page's draft and move on; on the last page the whole
    /// batch is submitted (skipped/unanswered questions as `{id, selected: []}`).
    private func skipCurrentPage() {
        guard !isSubmitting, model.questionCount > 0 else { return }
        switch model.skipCurrentQuestion() {
        case .submitted(let answers):
            showsIncompleteNotice = false
            deliverSkip(answers)
        case .moved:
            showsIncompleteNotice = false
        case .incomplete, .idle:
            break
        }
    }

    /// Whole-card skip keeps the parent's dedicated skip path (`onSkip`) when the
    /// batch carries no real answer — the wire payloads are identical there. If an
    /// earlier page was answered, the composed batch goes through `onSubmit` so
    /// those answers are preserved.
    private func deliverSkip(_ answers: [UserQuestionAnswer]) {
        let carriesAnswer = answers.contains { answer in
            !answer.selected.isEmpty
                || !(answer.custom ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if carriesAnswer {
            onSubmit(answers)
        } else {
            onSkip()
        }
    }

    /// Main button / custom-field Return: next page on non-final questions, submit
    /// (with validation) on the final one.
    private func handlePrimaryAction() {
        guard !isSubmitting, model.questionCount > 0 else { return }
        guard model.isLastQuestion else {
            showsIncompleteNotice = false
            model.goToNextQuestion()
            return
        }
        switch model.attemptSubmit() {
        case .submitted(let answers):
            showsIncompleteNotice = false
            onSubmit(answers)
        case .incomplete:
            showsIncompleteNotice = true
        case .moved, .idle:
            break
        }
    }

    private var primaryEnabled: Bool {
        !isSubmitting && model.questionCount > 0
    }

    /// Glow only when the final "提交" press is guaranteed to go through.
    private var primaryGlow: Bool {
        model.isLastQuestion && model.canSubmit
    }

    private var primaryButtonTitle: String {
        if isSubmitting { return L10n.t("提交中…") }
        return model.isLastQuestion ? L10n.t("提交") : L10n.t("下一题")
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
                skipCurrentPage()
            } label: {
                Text(L10n.t("跳过"))
            }
            .buttonStyle(OutlineButtonStyle(tint: Theme.Palette.textSecondary, border: Theme.Palette.borderStrong))
            .disabled(isSubmitting || model.questionCount == 0)
            .opacity(isSubmitting ? 0.5 : 1)
            .accessibilityIdentifier("uq-skip")

            Button {
                handlePrimaryAction()
            } label: {
                HStack(spacing: 6) {
                    if isSubmitting {
                        ProgressView()
                            .tint(Theme.Palette.accentInk)
                            .scaleEffect(0.8)
                    }
                    Text(primaryButtonTitle)
                }
            }
            .buttonStyle(PrimaryButtonStyle(glow: primaryGlow, enabled: primaryEnabled))
            .disabled(!primaryEnabled)
            .accessibilityIdentifier("uq-submit")
        }
        .padding(.top, Theme.Spacing.xxs)
    }

    // MARK: - Inline validation hint

    private var incompleteNotice: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.warning)
                .accessibilityHidden(true)
            Text(L10n.t("请先完成所有问题（作答或跳过）后再提交"))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.s)
        .background(Theme.Palette.warningMuted, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Theme.Palette.warningBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("uq-inline-notice")
    }
}

// MARK: - Stem height preference

/// Reports the natural height of the question stem so the card can scroll it only
/// when it overflows the cap (a bare `ScrollView` always eats the whole cap).
private struct StemHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Previews

#Preview("Single select") {
    ZStack {
        Theme.Palette.background.ignoresSafeArea()
        UserQuestionCardView(
            call: UserQuestionCall(
                callId: "preview-1",
                state: .open,
                questions: [
                    UserQuestion(
                        id: "q1",
                        question: "这个探针应该使用哪种抓包模式？",
                        detail: "waterfall 会复用当前会话流的真实帧；stream 会单独开一条 probe 流。\n长文本用于验证折叠：这是一段足够长的说明，用来演示超过四行时的“展开/收起”行为。",
                        header: "Gap capture",
                        options: [
                            UserQuestionOption(label: "waterfall", description: "复用当前会话流，最贴近真实链路"),
                            UserQuestionOption(label: "stream", description: "独立 probe 流，隔离性更好"),
                        ],
                        multiSelect: false
                    ),
                ]
            ),
            isSubmitting: false,
            errorText: nil,
            onSubmit: { _ in },
            onSkip: {}
        )
        .padding(Theme.Spacing.pageInset)
    }
}

#Preview("Multi select + error") {
    ZStack {
        Theme.Palette.background.ignoresSafeArea()
        UserQuestionCardView(
            call: UserQuestionCall(
                callId: "preview-2",
                state: .continued,
                questions: [
                    UserQuestion(
                        id: "q1",
                        question: "需要包含哪些检查项？",
                        options: [
                            UserQuestionOption(label: "健康检查", description: nil),
                            UserQuestionOption(label: "审计日志", description: "dsh-m-link audit.log"),
                            UserQuestionOption(label: "配对列表", description: nil),
                        ],
                        multiSelect: true
                    ),
                ]
            ),
            isSubmitting: false,
            errorText: "提交失败：连接已断开，请检查与 Mac 的连接后重试",
            onSubmit: { _ in },
            onSkip: {}
        )
        .padding(Theme.Spacing.pageInset)
    }
}

#Preview("Multi question pager") {
    ZStack {
        Theme.Palette.background.ignoresSafeArea()
        UserQuestionCardView(
            call: UserQuestionCall(
                callId: "preview-3",
                state: .open,
                questions: [
                    UserQuestion(
                        id: "q1",
                        question: "第一步：选择部署环境",
                        header: "部署环境",
                        options: [
                            UserQuestionOption(label: "隔离实例", description: "不影响现有会话"),
                            UserQuestionOption(label: "生产实例", description: "直接作用于当前工作区"),
                        ],
                        multiSelect: false
                    ),
                    UserQuestion(
                        id: "q2",
                        question: "第二步：需要包含哪些检查项？",
                        header: "检查项",
                        options: [
                            UserQuestionOption(label: "健康检查", description: nil),
                            UserQuestionOption(label: "审计日志", description: "dsh-m-link audit.log"),
                            UserQuestionOption(label: "配对列表", description: nil),
                        ],
                        multiSelect: true
                    ),
                ]
            ),
            isSubmitting: false,
            errorText: nil,
            onSubmit: { _ in },
            onSkip: {}
        )
        .padding(Theme.Spacing.pageInset)
    }
}
