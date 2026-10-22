import Foundation

// MARK: - Wire models (session/modelCatalog + session/selectModel)

/// One concrete model route: provider + model id + optional reasoning effort.
///
/// Wire sources:
/// - `session/selectModel` request (`provider`, `model`, `reasoningEffort?`)
/// - `session/selectModel` result (`selected`)
/// - `projections.values.modelSelection` (`next`, then `lastUsed`)
struct ModelSelection: Codable, Equatable, Sendable {
    var provider: String
    var model: String
    var reasoningEffort: String?

    init(provider: String, model: String, reasoningEffort: String? = nil) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    /// Decodes the `modelSelection` projection:
    /// `{ "lastUsed": {...}|null, "next": {...}|null }`.
    ///
    /// `next` is the durable intent (`pending ?? lastUsed` on the Host side) and
    /// is therefore the value the UI must display; `lastUsed` is only the last
    /// request header and lags behind a fresh selection.
    init?(projection: JSONValue?) {
        guard let projection, projection.objectValue != nil else { return nil }
        // `next` can be an explicit JSON null (no pending intent); only an object
        // counts as a usable selection, otherwise fall back to `lastUsed`.
        let nextRaw = projection["next"]
        let raw = (nextRaw?.objectValue != nil) ? nextRaw : projection["lastUsed"]
        guard let raw, raw.objectValue != nil,
              let provider = raw["provider"]?.stringValue, !provider.isEmpty,
              let model = raw["model"]?.stringValue, !model.isEmpty else { return nil }
        let effort = raw["reasoningEffort"]?.stringValue
        self.init(
            provider: provider,
            model: model,
            reasoningEffort: (effort?.isEmpty == false) ? effort : nil
        )
    }
}

/// `session/modelCatalog` result: provider-grouped models, deployment default and
/// isolated provider failures.
struct ModelCatalog: Decodable, Equatable, Sendable {
    struct DefaultSelection: Decodable, Equatable, Sendable {
        var provider: String
        var model: String
        var reasoningEffort: String?
    }

    struct Effort: Decodable, Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var description: String?
    }

    struct Reasoning: Decodable, Equatable, Sendable {
        var efforts: [Effort]
        var defaultEffort: String?
    }

    struct Model: Decodable, Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var description: String?
        /// Absent when the adapter has no reasoning metadata: the UI then hides
        /// the effort row entirely (desktop parity).
        var reasoning: Reasoning?
    }

    struct Group: Decodable, Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var models: [Model]
    }

    struct Failure: Decodable, Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var message: String
    }

    var defaultSelection: DefaultSelection?
    var routableProviders: [String]
    var groups: [Group]
    var failures: [Failure]

    enum CodingKeys: String, CodingKey {
        case defaultSelection = "default"
        case routableProviders
        case groups
        case failures
    }

    init(
        defaultSelection: DefaultSelection? = nil,
        routableProviders: [String] = [],
        groups: [Group] = [],
        failures: [Failure] = []
    ) {
        self.defaultSelection = defaultSelection
        self.routableProviders = routableProviders
        self.groups = groups
        self.failures = failures
    }

    /// Tolerant decode: a malformed/absent optional section must not blank the
    /// whole catalog (the sheet then shows whatever the Host did return).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultSelection = try? container.decodeIfPresent(DefaultSelection.self, forKey: .defaultSelection)
        routableProviders = (try? container.decodeIfPresent([String].self, forKey: .routableProviders)) ?? []
        groups = (try? container.decodeIfPresent([Group].self, forKey: .groups)) ?? []
        failures = (try? container.decodeIfPresent([Failure].self, forKey: .failures)) ?? []
    }
}

// MARK: - Presentation helpers

/// What the status-strip model entry shows.
struct ModelTriggerState: Equatable {
    var text: String
    var isLoading: Bool = false
}

/// One row of the reasoning-effort drill-in.
struct ModelEffortChoice: Identifiable, Equatable {
    /// `nil` = "use the provider default" row.
    var effortId: String?
    var name: String

    /// Stable row id: effort id, or the provider-default sentinel.
    var id: String { effortId ?? "__provider_default__" }
}

extension ModelCatalog {
    /// Provider ordering (desktop parity): DeepSeek account first, DeepSeek
    /// official second, then the catalog's own order for third parties.
    var orderedGroups: [Group] {
        groups.enumerated()
            .sorted { lhs, rhs in
                let left = Self.providerRank(lhs.element.id)
                let right = Self.providerRank(rhs.element.id)
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func providerRank(_ providerId: String) -> Int {
        if providerId == "deepseek-account" { return 0 }
        if providerId == "deepseek-official" || providerId.hasPrefix("deepseek") { return 1 }
        return 2
    }

    var modelCount: Int {
        groups.reduce(0) { $0 + $1.models.count }
    }

    /// Localized display name for one provider group.
    static func groupDisplayName(_ group: Group) -> String {
        let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if group.id == "deepseek-account" { return L10n.t("DeepSeek 账号") }
        return name.isEmpty ? group.id : name
    }

    /// Looks up a model by provider + model id.
    func model(provider: String, id modelId: String) -> Model? {
        groups.first { $0.id == provider }?.models.first { $0.id == modelId }
    }

    /// The selection to submit when the user taps a model row: the model's own
    /// default reasoning effort when the adapter publishes one.
    func selection(provider: String, model: Model) -> ModelSelection {
        ModelSelection(
            provider: provider,
            model: model.id,
            reasoningEffort: model.reasoning?.defaultEffort
        )
    }

    /// First model in desktop order that is *not* `current`; `nil` when the
    /// catalog is empty or offers no alternative. Used by the real-device E2E
    /// swap evidence hook (and covered by unit tests).
    func firstAlternativeSelection(to current: ModelSelection?) -> ModelSelection? {
        for group in orderedGroups {
            for model in group.models {
                if current?.provider == group.id, current?.model == model.id { continue }
                return selection(provider: group.id, model: model)
            }
        }
        return nil
    }

    /// Effort display name for a selection; `nil` when the model has no reasoning
    /// metadata (the trigger then shows only the model name).
    func effortName(for selection: ModelSelection) -> String? {
        guard let model = model(provider: selection.provider, id: selection.model),
              let reasoning = model.reasoning else { return nil }
        let effective = selection.reasoningEffort ?? reasoning.defaultEffort
        guard let effective else { return L10n.t("默认") }
        return reasoning.efforts.first { $0.id == effective }?.name ?? effective
    }

    /// Rows of the effort drill-in. Empty when the model publishes no reasoning
    /// metadata (desktop hides the whole effort row).
    func effortChoices(for selection: ModelSelection) -> [ModelEffortChoice] {
        guard let model = model(provider: selection.provider, id: selection.model),
              let reasoning = model.reasoning else { return [] }
        var choices: [ModelEffortChoice] = []
        if reasoning.defaultEffort == nil {
            choices.append(ModelEffortChoice(effortId: nil, name: L10n.t("默认")))
        }
        choices.append(contentsOf: reasoning.efforts.map {
            ModelEffortChoice(effortId: $0.id, name: $0.name)
        })
        return choices
    }

    /// True when `effortId` is the effective effort of `selection`.
    func isEffectiveEffort(_ effortId: String?, for selection: ModelSelection) -> Bool {
        guard let model = model(provider: selection.provider, id: selection.model) else { return false }
        let effective = selection.reasoningEffort ?? model.reasoning?.defaultEffort
        return effective == effortId
    }

    /// Status-strip trigger text: "模型名 · 推理等级", "模型名", or the placeholder.
    func triggerState(for selection: ModelSelection?, isLoading: Bool) -> ModelTriggerState {
        if isLoading, selection == nil {
            return ModelTriggerState(text: L10n.t("正在加载模型…"), isLoading: true)
        }
        guard let selection,
              let model = model(provider: selection.provider, id: selection.model) else {
            return ModelTriggerState(text: L10n.t("请选择模型"), isLoading: isLoading)
        }
        if let effort = effortName(for: selection), !effort.isEmpty {
            return ModelTriggerState(text: "\(model.name) · \(effort)", isLoading: false)
        }
        return ModelTriggerState(text: model.name, isLoading: false)
    }
}
