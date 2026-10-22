import XCTest
@testable import DSHm

/// v0.2.0 model selection: catalog decoding, provider ordering, trigger text,
/// effort resolution and the `modelSelection` projection parse (display uses
/// `next`, never `lastUsed` when they disagree).
final class ModelSelectionTests: XCTestCase {

    private let catalogJSON = """
    {
      "default": {"provider": "deepseek-official", "model": "deepseek-flash", "reasoningEffort": "high"},
      "routableProviders": ["deepseek-official", "anthropic"],
      "groups": [
        {
          "id": "anthropic",
          "name": "Anthropic",
          "models": [
            {"id": "claude-x", "name": "Claude X"}
          ]
        },
        {
          "id": "deepseek-official",
          "name": "DeepSeek",
          "models": [
            {
              "id": "deepseek-flash",
              "name": "deepseek-flash",
              "reasoning": {
                "efforts": [
                  {"id": "low", "name": "low"},
                  {"id": "high", "name": "high"},
                  {"id": "max", "name": "max"}
                ],
                "defaultEffort": "high"
              }
            },
            {"id": "deepseek-plain", "name": "deepseek-plain"}
          ]
        },
        {
          "id": "deepseek-account",
          "name": "DeepSeek 账号",
          "models": [
            {"id": "deepseek-v3", "name": "deepseek-v3"}
          ]
        }
      ],
      "failures": [
        {"id": "openai", "name": "OpenAI", "message": "no credentials"}
      ]
    }
    """

    private func decodeCatalog() throws -> ModelCatalog {
        try JSONDecoder().decode(ModelCatalog.self, from: Data(catalogJSON.utf8))
    }

    private func jsonValue(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: - Catalog decoding / ordering

    func testDecodesCatalog() throws {
        let catalog = try decodeCatalog()
        XCTAssertEqual(catalog.defaultSelection?.provider, "deepseek-official")
        XCTAssertEqual(catalog.defaultSelection?.model, "deepseek-flash")
        XCTAssertEqual(catalog.defaultSelection?.reasoningEffort, "high")
        XCTAssertEqual(catalog.routableProviders, ["deepseek-official", "anthropic"])
        XCTAssertEqual(catalog.modelCount, 4)
        XCTAssertEqual(catalog.failures.count, 1)
        XCTAssertEqual(catalog.failures.first?.message, "no credentials")
    }

    func testTolerantDecodeKeepsWhatItCan() throws {
        let json = #"{"default": {"provider": "p", "model": "m"}}"#
        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.defaultSelection?.provider, "p")
        XCTAssertTrue(catalog.groups.isEmpty)
        XCTAssertTrue(catalog.failures.isEmpty)
        XCTAssertTrue(catalog.routableProviders.isEmpty)
    }

    func testProviderOrderingAccountThenDeepSeekThenCatalogOrder() throws {
        let catalog = try decodeCatalog()
        XCTAssertEqual(catalog.orderedGroups.map(\.id), ["deepseek-account", "deepseek-official", "anthropic"])
    }

    func testGroupDisplayName() throws {
        let catalog = try decodeCatalog()
        let account = try XCTUnwrap(catalog.orderedGroups.first)
        XCTAssertEqual(ModelCatalog.groupDisplayName(account), L10n.t("DeepSeek 账号"))
        let deepseek = catalog.orderedGroups[1]
        XCTAssertEqual(ModelCatalog.groupDisplayName(deepseek), "DeepSeek")
    }

    // MARK: - Projection

    func testProjectionPrefersNextOverLastUsed() throws {
        let projection = try jsonValue("""
        {"lastUsed": {"provider": "deepseek-official", "model": "deepseek-flash", "reasoningEffort": "low"},
         "next": {"provider": "deepseek-official", "model": "deepseek-pro", "reasoningEffort": "max"}}
        """)
        let selection = ModelSelection(projection: projection)
        XCTAssertEqual(selection?.model, "deepseek-pro")
        XCTAssertEqual(selection?.reasoningEffort, "max")
    }

    func testProjectionFallsBackToLastUsed() throws {
        let projection = try jsonValue("""
        {"lastUsed": {"provider": "p", "model": "m"}, "next": null}
        """)
        XCTAssertEqual(ModelSelection(projection: projection)?.model, "m")
    }

    func testProjectionNilWhenNothingSelected() throws {
        let projection = try jsonValue(#"{"lastUsed": null, "next": null}"#)
        XCTAssertNil(ModelSelection(projection: projection))
        XCTAssertNil(ModelSelection(projection: nil))
        XCTAssertNil(ModelSelection(projection: try jsonValue(#"{}"#)))
    }

    // MARK: - Trigger / effort presentation

    func testTriggerPlaceholderWithoutSelectionOrCatalog() throws {
        let catalog = try decodeCatalog()
        XCTAssertEqual(catalog.triggerState(for: nil, isLoading: false).text, L10n.t("请选择模型"))
        XCTAssertEqual(catalog.triggerState(for: nil, isLoading: true).text, L10n.t("正在加载模型…"))
    }

    func testTriggerShowsModelAndEffort() throws {
        let catalog = try decodeCatalog()
        let selection = ModelSelection(
            provider: "deepseek-official",
            model: "deepseek-flash",
            reasoningEffort: "max"
        )
        let trigger = catalog.triggerState(for: selection, isLoading: false)
        XCTAssertEqual(trigger.text, "deepseek-flash · max")
        XCTAssertFalse(trigger.isLoading)
    }

    func testTriggerFallsBackToDefaultEffortWhenSelectionHasNone() throws {
        let catalog = try decodeCatalog()
        let selection = ModelSelection(provider: "deepseek-official", model: "deepseek-flash")
        XCTAssertEqual(catalog.effortName(for: selection), "high")
        XCTAssertEqual(catalog.triggerState(for: selection, isLoading: false).text, "deepseek-flash · high")
    }

    func testTriggerHasNoEffortWhenModelHasNoReasoningMetadata() throws {
        let catalog = try decodeCatalog()
        let selection = ModelSelection(provider: "deepseek-official", model: "deepseek-plain")
        XCTAssertNil(catalog.effortName(for: selection))
        XCTAssertEqual(catalog.triggerState(for: selection, isLoading: false).text, "deepseek-plain")
    }

    func testTriggerFallsBackWhenSelectionNotInCatalog() throws {
        let catalog = try decodeCatalog()
        let selection = ModelSelection(provider: "gone-provider", model: "gone-model")
        XCTAssertEqual(catalog.triggerState(for: selection, isLoading: false).text, L10n.t("请选择模型"))
    }

    func testSelectionForModelUsesModelDefaultEffort() throws {
        let catalog = try decodeCatalog()
        let flash = try XCTUnwrap(catalog.model(provider: "deepseek-official", id: "deepseek-flash"))
        let selection = catalog.selection(provider: "deepseek-official", model: flash)
        XCTAssertEqual(selection.reasoningEffort, "high")
    }

    // MARK: - Effort drill-in

    func testEffortChoicesIncludeProviderDefaultOnlyWhenNoDefaultPublished() throws {
        let catalog = try decodeCatalog()
        let flash = ModelSelection(provider: "deepseek-official", model: "deepseek-flash")
        XCTAssertEqual(catalog.effortChoices(for: flash).map(\.effortId), ["low", "high", "max"])
        XCTAssertFalse(catalog.effortChoices(for: flash).contains { $0.effortId == nil })

        let noDefaultJSON = """
        {"groups": [{"id": "p", "name": "P", "models": [
          {"id": "m", "name": "M", "reasoning": {"efforts": [{"id": "a", "name": "A"}]}}
        ]}]}
        """
        let noDefault = try JSONDecoder().decode(ModelCatalog.self, from: Data(noDefaultJSON.utf8))
        let choices = noDefault.effortChoices(for: ModelSelection(provider: "p", model: "m"))
        XCTAssertEqual(choices.map(\.effortId), [nil, "a"])
        XCTAssertEqual(choices.first?.name, L10n.t("默认"))
    }

    func testEffortChoicesEmptyWhenNoReasoningMetadata() throws {
        let catalog = try decodeCatalog()
        let plain = ModelSelection(provider: "deepseek-official", model: "deepseek-plain")
        XCTAssertTrue(catalog.effortChoices(for: plain).isEmpty)
    }

    func testEffectiveEffortUsesExplicitThenDefault() throws {
        let catalog = try decodeCatalog()
        let explicit = ModelSelection(provider: "deepseek-official", model: "deepseek-flash", reasoningEffort: "max")
        XCTAssertTrue(catalog.isEffectiveEffort("max", for: explicit))
        XCTAssertFalse(catalog.isEffectiveEffort("low", for: explicit))

        let implicit = ModelSelection(provider: "deepseek-official", model: "deepseek-flash")
        XCTAssertTrue(catalog.isEffectiveEffort("high", for: implicit))
    }

    // MARK: - Real-device swap hook

    func testFirstAlternativeSelectionSkipsCurrent() throws {
        let catalog = try decodeCatalog()
        // Desktop order starts with deepseek-account / deepseek-v3.
        let current = ModelSelection(provider: "deepseek-account", model: "deepseek-v3")
        let alternative = try XCTUnwrap(catalog.firstAlternativeSelection(to: current))
        XCTAssertEqual(alternative.provider, "deepseek-official")
        XCTAssertEqual(alternative.model, "deepseek-flash")
        XCTAssertEqual(alternative.reasoningEffort, "high")
    }

    func testFirstAlternativeSelectionPicksFirstWhenNoCurrent() throws {
        let catalog = try decodeCatalog()
        let alternative = try XCTUnwrap(catalog.firstAlternativeSelection(to: nil))
        XCTAssertEqual(alternative.provider, "deepseek-account")
        XCTAssertEqual(alternative.model, "deepseek-v3")
    }

    func testFirstAlternativeSelectionNilWhenOnlyCurrentExists() throws {
        let json = """
        {"groups": [{"id": "p", "name": "P", "models": [{"id": "m", "name": "M"}]}]}
        """
        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: Data(json.utf8))
        XCTAssertNil(catalog.firstAlternativeSelection(to: ModelSelection(provider: "p", model: "m")))
        XCTAssertNil(ModelCatalog(defaultSelection: nil, groups: []).firstAlternativeSelection(to: nil))
    }

    // MARK: - Wire encoding

    func testSelectionEncodesOptionalEffort() throws {
        let withEffort = ModelSelection(provider: "p", model: "m", reasoningEffort: "high")
        let encoded = try JSONEncoder().encode(withEffort)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(object?["provider"] as? String, "p")
        XCTAssertEqual(object?["model"] as? String, "m")
        XCTAssertEqual(object?["reasoningEffort"] as? String, "high")

        let without = ModelSelection(provider: "p", model: "m")
        let decoded = try JSONDecoder().decode(ModelSelection.self, from: JSONEncoder().encode(without))
        XCTAssertNil(decoded.reasoningEffort)
    }
}
