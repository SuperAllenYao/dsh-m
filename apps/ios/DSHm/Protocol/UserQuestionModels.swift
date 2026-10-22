import Foundation

// MARK: - userQuestions projection (protocol §3.7.2 / tech-design §14)

/// State of one pending `ask_user_question` call in
/// `projections.values.userQuestions.active[i]`.
///
/// - `open`: the live waterfall (`$events` → `user-questions/request`) is still
///   waiting on this client; answer it with `$events/result`.
/// - `continued`: the timed wait expired; the call can only be answered through
///   the unary `userQuestions/answer` method.
/// - `unknown`: forward-compatible fallback for a future state string.
enum UserQuestionState: Equatable {
    case open
    case continued
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "open": self = .open
        case "continued": self = .continued
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .open: return "open"
        case .continued: return "continued"
        case .unknown(let value): return value
        }
    }

    var isOpen: Bool { self == .open }
    var isContinued: Bool { self == .continued }

    /// Only `continued` calls accept the unary `userQuestions/answer` path.
    var isAnswerableUnarily: Bool { self == .continued }
}

/// One selectable option; `label` is the exact wire value submitted back.
struct UserQuestionOption: Codable, Equatable, Identifiable {
    var label: String
    var description: String?

    var id: String { label }

    init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

/// One question inside a user-question call (protocol §3.7.2).
struct UserQuestion: Codable, Equatable, Identifiable {
    var id: String
    var question: String
    var detail: String?
    var header: String?
    var options: [UserQuestionOption]?
    var multiSelect: Bool?

    init(
        id: String,
        question: String,
        detail: String? = nil,
        header: String? = nil,
        options: [UserQuestionOption]? = nil,
        multiSelect: Bool? = nil
    ) {
        self.id = id
        self.question = question
        self.detail = detail
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    var isMultiSelect: Bool { multiSelect ?? false }
}

/// One pending user-question call, decoded from
/// `projections.values.userQuestions.active[i]`.
///
/// Contract (verified from DSH source by Lead):
/// `{callId, state: "open" | "continued", questions: [{id, question, detail?, header?, options?[{label, description?}], multiSelect?}]}`.
/// Note: the projection carries no `intent` field; that one only exists on the
/// live waterfall request.
struct UserQuestionCall: Codable, Equatable, Identifiable {
    var callId: String
    var state: UserQuestionState
    var questions: [UserQuestion]

    /// The projection entry has no id beyond `callId`.
    var id: String { callId }

    init(callId: String, state: UserQuestionState, questions: [UserQuestion]) {
        self.callId = callId
        self.state = state
        self.questions = questions
    }

    private enum CodingKeys: String, CodingKey { case callId, state, questions }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callId = try container.decode(String.self, forKey: .callId)
        let rawState = (try? container.decodeIfPresent(String.self, forKey: .state)) ?? ""
        state = UserQuestionState(rawValue: rawState)
        // P1-3: decode question entries individually — one malformed question
        // must not drop the whole call (which would hide every card).
        let rawQuestions = (try? container.decodeIfPresent([JSONValue].self, forKey: .questions)) ?? []
        questions = rawQuestions.compactMap { try? $0.decode(UserQuestion.self) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(callId, forKey: .callId)
        try container.encode(state.rawValue, forKey: .state)
        try container.encode(questions, forKey: .questions)
    }

    /// Answer batch that skips every question (`selected: []`).
    var skipAnswers: [UserQuestionAnswer] {
        questions.map { UserQuestionAnswer(id: $0.id, selected: []) }
    }
}

// MARK: - Answers / payloads

/// One answer inside an answer batch.
///
/// Wire shape: `{"id": "...", "selected": ["..."], "custom": "..."}`.
/// - single-select: `custom` (when present) overrides `selected`;
/// - multi-select: `custom` is appended as an extra value;
/// - skip = `selected: []` with no custom.
struct UserQuestionAnswer: Codable, Equatable {
    var id: String
    var selected: [String]
    var custom: String?

    init(id: String, selected: [String], custom: String? = nil) {
        self.id = id
        self.selected = selected
        self.custom = custom
    }

    private enum CodingKeys: String, CodingKey { case id, selected, custom }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        selected = try container.decodeIfPresent([String].self, forKey: .selected) ?? []
        custom = try container.decodeIfPresent(String.self, forKey: .custom)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(selected, forKey: .selected)
        try container.encodeIfPresent(custom, forKey: .custom)
    }
}

/// Exact answer batch forwarded by `$events/result` and `userQuestions/answer`:
/// `{"answers":[...]}`.
struct UserQuestionAnswersBatch: Codable, Equatable {
    var answers: [UserQuestionAnswer]

    init(answers: [UserQuestionAnswer]) {
        self.answers = answers
    }

    static func single(id: String, selected: [String], custom: String? = nil) -> UserQuestionAnswersBatch {
        UserQuestionAnswersBatch(answers: [UserQuestionAnswer(id: id, selected: selected, custom: custom)])
    }

    /// JSON object in the exact wire shape (used as the unary `answer` arg and
    /// the waterfall `outcome.value`).
    func jsonValue() -> JSONValue {
        .object([
            "answers": .array(answers.map { answer in
                var object: [String: JSONValue] = [
                    "id": .string(answer.id),
                    "selected": .strings(answer.selected),
                ]
                if let custom = answer.custom { object["custom"] = .string(custom) }
                return .object(object)
            }),
        ])
    }

    /// Deterministic JSON string (sorted keys) for exact-payload assertions / logs.
    func encodedJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Projection parsing

/// One settled record appended after a call is answered.
struct UserQuestionSettled: Codable, Equatable, Identifiable {
    var callId: String
    var answers: [UserQuestionAnswer]

    var id: String { callId }

    init(callId: String, answers: [UserQuestionAnswer]) {
        self.callId = callId
        self.answers = answers
    }

    private enum CodingKeys: String, CodingKey { case callId, answers }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callId = try container.decode(String.self, forKey: .callId)
        let rawAnswers = (try? container.decodeIfPresent([JSONValue].self, forKey: .answers)) ?? []
        answers = rawAnswers.compactMap { try? $0.decode(UserQuestionAnswer.self) }
    }
}

/// `projections.values.userQuestions` — `{active: [...], settled: [...]}`.
struct UserQuestionsProjection: Decodable, Equatable {
    var active: [UserQuestionCall]
    var settled: [UserQuestionSettled]

    init(active: [UserQuestionCall] = [], settled: [UserQuestionSettled] = []) {
        self.active = active
        self.settled = settled
    }

    private enum CodingKeys: String, CodingKey { case active, settled }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // P1-3: per-entry tolerant decoding — one malformed projection entry
        // must not wipe the whole (valid) list and hide every card.
        let rawActive = (try? container.decodeIfPresent([JSONValue].self, forKey: .active)) ?? []
        active = rawActive.compactMap { try? $0.decode(UserQuestionCall.self) }
        let rawSettled = (try? container.decodeIfPresent([JSONValue].self, forKey: .settled)) ?? []
        settled = rawSettled.compactMap { try? $0.decode(UserQuestionSettled.self) }
    }

    var isEmpty: Bool { active.isEmpty && settled.isEmpty }

    /// Decodes the projection value out of a `session/list` / snapshot / event
    /// JSON fragment. Accepts the raw `userQuestions` value itself.
    static func parse(_ value: JSONValue?) -> UserQuestionsProjection {
        guard let value, value.objectValue != nil else { return UserQuestionsProjection() }
        return (try? value.decode(UserQuestionsProjection.self)) ?? UserQuestionsProjection()
    }

    /// Convenience for the full `projections` object: reads
    /// `values.userQuestions`.
    static func parseProjections(_ projections: JSONValue?) -> UserQuestionsProjection {
        parse(projections?["values"]?["userQuestions"])
    }
}

// MARK: - Answer composition (pure, unit-testable)

/// Builds the submit batch from the card's per-question UI state (P0-2).
///
/// Contract: the batch has one entry per question, and questions the user left
/// untouched are sent explicitly as `{id, selected: []}` — never dropped, so a
/// partial answer stays unambiguous.
enum UserQuestionAnswerComposer {
    /// - Parameters:
    ///   - selected: question.id → set of selected option labels (wire values).
    ///   - custom: question.id → free-text ("自定义") answer.
    static func compose(
        call: UserQuestionCall,
        selected: [String: Set<String>],
        custom: [String: String]
    ) -> [UserQuestionAnswer] {
        call.questions.map { question in
            let labels = (question.options ?? []).map(\.label).filter {
                selected[question.id]?.contains($0) == true
            }
            let text = (custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if labels.isEmpty && text.isEmpty {
                return UserQuestionAnswer(id: question.id, selected: [])
            }
            return UserQuestionAnswer(id: question.id, selected: labels, custom: text.isEmpty ? nil : text)
        }
    }

    /// Number of questions that actually carry an answer (selection or custom
    /// text); the submit button stays disabled while this is zero.
    static func answeredCount(
        call: UserQuestionCall,
        selected: [String: Set<String>],
        custom: [String: String]
    ) -> Int {
        call.questions.reduce(into: 0) { count, question in
            let hasSelection = (question.options ?? []).contains {
                selected[question.id]?.contains($0.label) == true
            }
            let hasCustom = !(custom[question.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            if hasSelection || hasCustom { count += 1 }
        }
    }
}

// MARK: - Submit planning (pure, unit-testable)

/// Which transport path answers one call.
enum UserQuestionSubmitPath: Equatable {
    /// `continued` → unary `userQuestions/answer`.
    case unary(callId: String)
    /// `open` + a local live waterfall → unary `$events/result`.
    case live(eventId: String)
    /// `open` but this client holds no live request for it (e.g. answered from
    /// the desktop, reconnected after the wait expired).
    case noLiveRequest
    /// The call is no longer in the active projection.
    case callNotFound
    /// Forward-compatible unknown state.
    case unsupportedState(String)
}

/// Result of one submit / skip.
enum UserQuestionSubmitOutcome: Equatable {
    /// Unary `userQuestions/answer` returned `true`.
    case answered
    /// Live `$events/result` accepted the batch for an `open` call.
    case answeredViaLiveEvents
    /// Unary returned `false`: the call is no longer pending (answered
    /// elsewhere or expired).
    case noLongerPending
    /// Host answered `REPLY_QUEUED`: the reply was queued instead of resolving.
    case queued
}

/// Errors specific to the user-question answer path (protocol-level network
/// failures still surface as `LinkError`).
enum UserQuestionSubmitError: Error, LocalizedError, Equatable {
    case callNotFound(String)
    case noLiveRequest
    case unsupportedState(String)
    /// A submit for this call is already in flight (double tap / retry storm).
    case alreadySubmitting(String)

    var errorDescription: String? {
        switch self {
        case .callNotFound(let callId):
            return "该问答已不在等待队列中（callId: \(callId)），已刷新状态"
        case .noLiveRequest:
            return "本机没有这条问答的实时等待请求（可能已在桌面端作答或等待已超时），请刷新后重试"
        case .unsupportedState(let raw):
            return "不支持的问答状态：\(raw.isEmpty ? "未知" : raw)"
        case .alreadySubmitting:
            return "该问答正在提交中，请稍候"
        }
    }
}

/// Duplicate/concurrent submit guard (pure, unit-testable).
///
/// A second submit for the same call while the first is in flight (double tap,
/// concurrent callers, retry storm) must not send a second answer batch.
struct UserQuestionSubmitGate {
    private(set) var inFlight: Set<String> = []

    /// Returns true when the caller now owns the submission; false when the same
    /// call is already being submitted.
    mutating func begin(_ callId: String) -> Bool {
        guard !inFlight.contains(callId) else { return false }
        inFlight.insert(callId)
        return true
    }

    mutating func end(_ callId: String) {
        inFlight.remove(callId)
    }

    func isInFlight(_ callId: String) -> Bool {
        inFlight.contains(callId)
    }
}

/// Pure path/outcome decisions shared by `SessionViewModel` and the unit tests.
enum UserQuestionSubmitPlanner {
    static let replyQueuedCode = "REPLY_QUEUED"

    /// Picks the answer path from the projection state and the locally observed
    /// live waterfalls.
    static func path(
        for call: UserQuestionCall?,
        pending: [UserQuestionWaterfall]
    ) -> UserQuestionSubmitPath {
        guard let call else { return .callNotFound }
        switch call.state {
        case .continued:
            return .unary(callId: call.callId)
        case .open:
            if let waterfall = liveCandidate(for: call, pending: pending) {
                return .live(eventId: waterfall.eventId)
            }
            return .noLiveRequest
        case .unknown(let raw):
            return .unsupportedState(raw)
        }
    }

    /// Finds the live waterfall that belongs to `call`.
    ///
    /// The projection keys calls by `callId`; live calls are matched in this
    /// order: `wait.callId` → `eventId` (used as stable identity when the frame
    /// has no `wait.callId`) → exact question-id match (only when unambiguous).
    static func liveCandidate(
        for call: UserQuestionCall,
        pending: [UserQuestionWaterfall]
    ) -> UserQuestionWaterfall? {
        if let sameCall = pending.first(where: { $0.callId == call.callId }) {
            return sameCall
        }
        if let sameEvent = pending.first(where: { $0.eventId == call.callId }) {
            return sameEvent
        }
        let ids = Set(call.questions.map(\.id))
        guard !ids.isEmpty else { return nil }
        let matches = pending.filter { Set($0.questions.map(\.id)) == ids }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Skip batch: one `selected: []` answer per question.
    static func skipAnswers(for call: UserQuestionCall) -> [UserQuestionAnswer] {
        call.skipAnswers
    }

    /// Maps the unary boolean result.
    static func outcome(accepted: Bool) -> UserQuestionSubmitOutcome {
        accepted ? .answered : .noLongerPending
    }

    /// Maps a thrown error onto an outcome when it is a *soft* business result
    /// (`REPLY_QUEUED`); everything else must propagate.
    static func outcome(for error: Error) -> UserQuestionSubmitOutcome? {
        guard let linkError = error as? LinkError,
              let remote = linkError.remoteError,
              remote.code == replyQueuedCode else {
            return nil
        }
        return .queued
    }
}
