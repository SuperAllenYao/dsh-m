import XCTest
@testable import DSHm

/// Desktop-side model switches must be visible in the App **live** (v0.2.x).
///
/// `session/follow` carries no per-event projections, so before this fix the App
/// kept whatever model the last snapshot carried: a switch made on the desktop
/// silently disagreed with the App until the detail was reopened. The Host's
/// `model/selection` event is the live signal; the journal patches the
/// projection's `next` intent from it.
final class ModelSelectionLiveSyncTests: XCTestCase {

    // MARK: - Fixtures

    /// Host projection view shape: `{lastUsed, next: pending ?? lastUsed}`.
    private func snapshot(modelSelection: String, cursor: Int = 0) throws -> SessionSnapshot {
        let json = """
        {"type":"snapshot","header":{"version":4,"id":"s-model"},"cursor":\(cursor),
         "records":[],"hasMore":false,
         "projections":{"asOfSeq":\(cursor),"values":{"title":"模型联动","modelSelection":\(modelSelection)}},
         "assistantStream":{"revision":0}}
        """
        return try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
    }

    private func snapshotValue(modelSelection: String, cursor: Int = 0) -> JSONValue {
        let json = """
        {"type":"snapshot","header":{"version":4,"id":"s-model"},"cursor":\(cursor),
         "records":[],"hasMore":false,
         "projections":{"asOfSeq":\(cursor),"values":{"title":"模型联动","modelSelection":\(modelSelection)}},
         "assistantStream":{"revision":0}}
        """
        return TestJSON.value(json)
    }

    private func eventFrame(_ type: String, seq: Int, data: String) -> JSONValue {
        TestJSON.value(
            "{\"type\":\"event\",\"event\":{\"type\":\"\(type)\",\"seq\":\(seq),\"time\":1792510000000,\"data\":\(data)}}"
        )
    }

    private static let flash = ModelSelection(provider: "deepseek-account", model: "deepseek-flash", reasoningEffort: "high")

    /// Full catalog: both the snapshot model (`deepseek-flash`) and the model the
    /// desktop switches to (`deepseek-pro`).
    private static let catalog = ModelCatalog(
        defaultSelection: .init(provider: "deepseek-account", model: "deepseek-flash", reasoningEffort: "high"),
        routableProviders: ["deepseek-account"],
        groups: [
            .init(id: "deepseek-account", name: "DeepSeek 账号", models: [
                .init(id: "deepseek-flash", name: "deepseek-flash", description: nil, reasoning: .init(
                    efforts: [
                        .init(id: "low", name: "low", description: nil),
                        .init(id: "high", name: "high", description: nil),
                        .init(id: "max", name: "max", description: nil),
                    ],
                    defaultEffort: "high"
                )),
                .init(id: "deepseek-pro", name: "deepseek-pro", description: nil, reasoning: .init(
                    efforts: [
                        .init(id: "medium", name: "medium", description: nil),
                        .init(id: "high", name: "high", description: nil),
                        .init(id: "max", name: "max", description: nil),
                    ],
                    defaultEffort: "medium"
                )),
            ]),
        ],
        failures: []
    )

    /// Catalog a detail loaded before the desktop switched to `deepseek-pro`.
    private static let narrowCatalog = ModelCatalog(
        defaultSelection: .init(provider: "deepseek-account", model: "deepseek-flash", reasoningEffort: "high"),
        routableProviders: ["deepseek-account"],
        groups: [
            .init(id: "deepseek-account", name: "DeepSeek 账号", models: [
                .init(id: "deepseek-flash", name: "deepseek-flash", description: nil, reasoning: nil),
            ]),
        ],
        failures: []
    )

    /// `SessionViewModel` debounces row rebuilds by ~40ms; live assertions need a
    /// run-loop turn (same pattern as CacheTests).
    private func waitForRowRebuild(_ nanoseconds: UInt64 = 200_000_000) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    // MARK: - Journal: the event patches the `next` intent

    func testJournalPatchesNextFromModelSelectionEvent() throws {
        let journal = SessionJournal()
        journal.apply(snapshot: try snapshot(modelSelection: """
        {"lastUsed":{"provider":"deepseek-account","model":"deepseek-flash","reasoningEffort":"high"},"next":null}
        """))
        XCTAssertEqual(ModelSelection(projection: journal.modelSelection)?.model, "deepseek-flash")

        journal.apply(event: TestJSON.event("model/selection", seq: 1, data: TestJSON.value("""
        {"provider":"deepseek-account","model":"deepseek-pro","reasoningEffort":"max"}
        """)))

        let selection = ModelSelection(projection: journal.modelSelection)
        XCTAssertEqual(selection?.provider, "deepseek-account")
        XCTAssertEqual(selection?.model, "deepseek-pro")
        XCTAssertEqual(selection?.reasoningEffort, "max")
        // `lastUsed` is untouched: it is the last request header, not the intent.
        XCTAssertEqual(journal.modelSelection?["lastUsed"]?["model"]?.stringValue, "deepseek-flash")

        // A later switch without an effort must clear it (provider default).
        journal.apply(event: TestJSON.event("model/selection", seq: 2, data: TestJSON.value("""
        {"provider":"deepseek-account","model":"deepseek-flash"}
        """)))
        XCTAssertNil(ModelSelection(projection: journal.modelSelection)?.reasoningEffort)
    }

    func testJournalIgnoresMalformedModelSelectionEvent() throws {
        let journal = SessionJournal()
        journal.apply(snapshot: try snapshot(modelSelection: "null"))
        // No provider/model: nothing to display, the projection must stay empty.
        journal.apply(event: TestJSON.event("model/selection", seq: 1, data: TestJSON.value(#"{"model":"deepseek-pro"}"#)))
        XCTAssertNil(ModelSelection(projection: journal.modelSelection))
    }

    // MARK: - ViewModel: a desktop switch updates the strip live

    @MainActor
    func testDesktopSwitchUpdatesStripWithoutReopen() async throws {
        let viewModel = SessionViewModel(sessionId: "s-model")
        viewModel.modelCatalogLoader = { Self.catalog }
        await viewModel.loadModelCatalogIfNeeded()

        viewModel.applyStreamValue(snapshotValue(modelSelection: """
        {"lastUsed":{"provider":"deepseek-account","model":"deepseek-flash","reasoningEffort":"high"},"next":null}
        """))
        await waitForRowRebuild()
        XCTAssertEqual(viewModel.modelSelection, Self.flash)
        XCTAssertEqual(viewModel.modelTriggerState?.text, "deepseek-flash · high")

        // The desktop switches to deepseek-pro/max: only the event arrives.
        viewModel.applyStreamValue(eventFrame("model/selection", seq: 1, data: """
        {"provider":"deepseek-account","model":"deepseek-pro","reasoningEffort":"max"}
        """))
        await waitForRowRebuild()

        XCTAssertEqual(
            viewModel.modelSelection,
            ModelSelection(provider: "deepseek-account", model: "deepseek-pro", reasoningEffort: "max")
        )
        XCTAssertEqual(viewModel.modelTriggerState?.text, "deepseek-pro · max")
        XCTAssertEqual(viewModel.modelSelectionText, "deepseek-pro", "the permission sheet reads the same live model")
        XCTAssertNil(viewModel.modelSelectionErrorText)
    }

    // MARK: - ViewModel: unknown live selection refreshes the catalog once

    @MainActor
    func testDesktopSwitchToUnknownModelRefreshesCatalogOnce() async throws {
        let viewModel = SessionViewModel(sessionId: "s-model")
        var loads = 0
        viewModel.modelCatalogLoader = {
            loads += 1
            return loads == 1 ? Self.narrowCatalog : Self.catalog
        }
        await viewModel.loadModelCatalogIfNeeded()
        XCTAssertEqual(loads, 1)

        viewModel.applyStreamValue(snapshotValue(modelSelection: """
        {"lastUsed":{"provider":"deepseek-account","model":"deepseek-flash","reasoningEffort":"high"},"next":null}
        """))
        await waitForRowRebuild()

        // The desktop switches to a model the loaded catalog cannot name.
        viewModel.applyStreamValue(eventFrame("model/selection", seq: 1, data: """
        {"provider":"deepseek-account","model":"deepseek-pro","reasoningEffort":"max"}
        """))
        await waitForRowRebuild(400_000_000)
        XCTAssertEqual(loads, 2, "an unknown live selection must refresh the cached catalog")
        XCTAssertEqual(viewModel.modelTriggerState?.text, "deepseek-pro · max")

        // A later, unrelated rebuild must not re-fetch the same selection.
        viewModel.applyStreamValue(eventFrame("todo/write", seq: 2, data: #"{"todos":[]}"#))
        await waitForRowRebuild(300_000_000)
        XCTAssertEqual(loads, 2, "the refresh stays one-shot per unknown selection")
    }

    // MARK: - ViewModel: a failed refresh keeps the previous display

    @MainActor
    func testFailedCatalogRefreshKeepsLiveSelection() async throws {
        let viewModel = SessionViewModel(sessionId: "s-model")
        var loads = 0
        viewModel.modelCatalogLoader = {
            loads += 1
            if loads == 1 { return Self.narrowCatalog }
            throw LinkError.httpStatus(503, "host/inactive")
        }
        await viewModel.loadModelCatalogIfNeeded()

        viewModel.applyStreamValue(snapshotValue(modelSelection: "null"))
        await waitForRowRebuild()
        viewModel.applyStreamValue(eventFrame("model/selection", seq: 1, data: """
        {"provider":"deepseek-account","model":"deepseek-pro","reasoningEffort":"max"}
        """))
        await waitForRowRebuild(400_000_000)

        XCTAssertEqual(loads, 2)
        XCTAssertEqual(viewModel.modelSelection?.model, "deepseek-pro", "the live selection survives a catalog failure")
        XCTAssertEqual(viewModel.modelTriggerState?.text, L10n.t("请选择模型"), "unknown model falls back to the placeholder")
    }
}
