import XCTest
@testable import DSHm

/// P1.5-A: `session/list` lite projection trim (App side).
///
/// The plugin (`packages/dsh-m-link/lib/list-lite.js`) drops everything the list
/// does not need when the App opts in (`SessionListLite.requestArgs()`). These
/// tests pin the decode/apply contract:
///   - a lite row decodes through the exact same `SessionListItem` path as the
///     legacy full row, and every list/detail derive input survives;
///   - rows with missing/partial `projections` tolerate the trim (all decoded
///     fields are optional);
///   - the legacy full response still decodes (rollout / kill-switch safety);
///   - the workspace list, status resolver, subagent address and the render
///     snapshot cache keep working off lite rows.
final class P15LiteListTests: XCTestCase {

    // MARK: - Fixtures (shape produced by the plugin's lite whitelist)

    private static let liteRows = """
    {"sessionId":"s-lite-1","updatedAt":1792510000000,"agentAvailable":true,"formatStatus":"current","running":true,"blank":false,"cwd":"/ws/a","projections":{"kind":"sequenced","asOfSeq":42,"values":{"title":"修复列表 1MB 响应","sessionListMetadata":{"lastPromptAt":1792510000000,"blank":false},"userQuestions":{"active":[]},"contextPressure":{"contextWindow":1000000,"projectedTokens":12400}}}},
    {"sessionId":"s-lite-2","updatedAt":1792500000000,"agentAvailable":false,"formatStatus":"current","running":false,"blank":false,"cwd":"/ws/b","projections":{"kind":"cached","values":{"title":"","sessionListMetadata":{"lastPromptAt":1792499990000},"userQuestions":{"active":[{"callId":"call-1"}]},"contextPressure":{"contextWindow":1000000}}}}
    """

    private func liteListJSON(rows: String = P15LiteListTests.liteRows) -> String {
        #"{"items":["# + rows + "]}"
    }

    private func decodeItems(_ json: String) throws -> [SessionListItem] {
        try TestJSON.value(json).decode(SessionListValue.self).items
    }

    // MARK: - Lite rows decode like full rows

    func testLiteResponseDecodesListAndDerivedFields() throws {
        let items = try decodeItems(liteListJSON())
        XCTAssertEqual(items.count, 2)

        let first = items[0]
        XCTAssertEqual(first.sessionId, "s-lite-1")
        XCTAssertEqual(first.title, "修复列表 1MB 响应")
        XCTAssertEqual(first.lastPromptAt, 1_792_510_000_000)
        XCTAssertEqual(first.updatedAt, 1_792_510_000_000)
        XCTAssertTrue(first.isRunning)
        XCTAssertFalse(first.blank ?? true)
        XCTAssertEqual(first.workspacePath, "/ws/a")
        XCTAssertEqual(first.agentAvailable, true)
        XCTAssertEqual(first.formatStatus, "current")
        XCTAssertEqual(first.contextPressure?.usedTokens, 12_400)
        XCTAssertEqual(first.contextPressure?.contextWindow, 1_000_000)
        XCTAssertEqual(first.followAddress, .session(sessionId: "s-lite-1"))
        XCTAssertEqual(first.displayTitle, "修复列表 1MB 响应")

        let second = items[1]
        XCTAssertEqual(second.userQuestionsActive.count, 1)
        XCTAssertTrue(second.hasActiveUserQuestions)
        XCTAssertEqual(second.contextPressure?.usedTokens, nil, "partial contextPressure keeps the window only")
        XCTAssertEqual(second.contextPressure?.contextWindow, 1_000_000)
        XCTAssertEqual(second.displayTitle, "未命名会话", "empty title falls back to the legacy placeholder")
    }

    func testLiteRowsTolerateMissingProjections() throws {
        let items = try decodeItems("""
        {"items":[
          {"sessionId":"no-projections"},
          {"sessionId":"empty-values","projections":{"values":{}}},
          {"sessionId":"title-only","projections":{"values":{"title":"Only title"}}},
          {"sessionId":"partial-pressure","projections":{"values":{"contextPressure":{"contextWindow":200000}}}}
        ]}
        """)
        XCTAssertEqual(items.count, 4)
        XCTAssertNil(items[0].title)
        XCTAssertNil(items[0].lastPromptAt)
        XCTAssertEqual(items[0].userQuestionsActive.count, 0)
        XCTAssertNil(items[0].contextPressure)
        XCTAssertEqual(items[0].workspacePath, "", "missing cwd must not crash the list")
        XCTAssertEqual(items[2].title, "Only title")
        XCTAssertNil(items[2].contextPressure)
        XCTAssertEqual(items[3].contextPressure?.contextWindow, 200_000)
        XCTAssertEqual(items[3].contextPressure?.usedTokens, nil)
        XCTAssertFalse(items[3].isRunning)
    }

    func testLegacyFullResponseStillDecodes() throws {
        // One legacy row: the full projection block the old path still returns.
        let items = try decodeItems("""
        {"items":[{"sessionId":"s-full","updatedAt":1792510000000,"agentAvailable":true,"formatStatus":"current","running":false,"blank":false,"cwd":"/ws/a","projections":{"kind":"sequenced","asOfSeq":7,"values":{
          "title":"Legacy full row",
          "goal":null,
          "tokenUsage":{"uncachedInputTokens":1,"outputTokens":2,"cacheReadTokens":3,"cacheWriteTokens":4},
          "contextPressure":{"contextWindow":1000000,"pressureTokens":999},
          "contextBreakdown":{"systemTokens":1,"toolsTokens":2,"messageTokens":3},
          "inbox":{"next-turn":[],"next-step":[]},
          "sessionStats":{"turns":1,"steps":1},
          "turnOutline":[{"turn":1,"seq":4,"prompt":"p","response":"r"}],
          "agentPreset":"standard",
          "userQuestions":{"active":[],"settled":[]},
          "permissions":{"currentValue":"workspace-write"},
          "workingDirectory":"/ws/a",
          "subagentCatalog":[],
          "subagentTiming":{"settledMs":0},
          "subagent":null,
          "todos":null,
          "plan":{"active":false,"pending":false},
          "modelSelection":{"lastUsed":{"provider":"p","model":"m"}},
          "sessionListMetadata":{"blank":false,"lastPromptAt":1792500000000},
          "imageLimits":{"maxImageBytes":1}
        }}}]}
        """)
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.title, "Legacy full row")
        XCTAssertEqual(item.lastPromptAt, 1_792_500_000_000)
        XCTAssertEqual(item.contextPressure?.usedTokens, 999)
        XCTAssertEqual(item.displayTitle, "Legacy full row")
        XCTAssertEqual(item.followAddress, .session(sessionId: "s-full"))
    }

    // MARK: - Derived list behaviour

    func testLiteRowsDriveStatusResolver() throws {
        let items = try decodeItems(liteListJSON())
        XCTAssertEqual(
            SessionListStatusResolver.status(for: items[0], pendingApprovals: 0, isConnected: true),
            .running
        )
        XCTAssertEqual(
            SessionListStatusResolver.status(for: items[1], pendingApprovals: 0, isConnected: true),
            .waitingForAnswer(count: 1)
        )
        XCTAssertEqual(
            SessionListStatusResolver.status(for: items[0], pendingApprovals: 2, isConnected: true),
            .waitingForAnswer(count: 2)
        )
        XCTAssertEqual(
            SessionListStatusResolver.status(for: items[0], pendingApprovals: 0, isConnected: false),
            .offline
        )

        let blank = try decodeItems(#"{"items":[{"sessionId":"blank","blank":true,"projections":{"values":{}}}]}"#)[0]
        XCTAssertEqual(SessionListStatusResolver.status(for: blank, pendingApprovals: 0, isConnected: true), .notStarted)
        let idle = try decodeItems(#"{"items":[{"sessionId":"idle","projections":{"values":{}}}]}"#)[0]
        XCTAssertEqual(SessionListStatusResolver.status(for: idle, pendingApprovals: 0, isConnected: true), .idle)
    }

    func testLiteSubagentRowKeepsFollowAddress() throws {
        let child = try decodeItems("""
        {"items":[{"sessionId":"child-1","origin":"subagent","parentSessionId":"parent-1","projections":{"values":{}}}]}
        """)[0]
        XCTAssertTrue(child.isSubagent)
        XCTAssertEqual(child.followAddress, .subagent(parentSessionId: "parent-1", childSessionId: "child-1", mode: "unknown"))
        XCTAssertEqual(child.subagentAddress?.objectValue?["kind"]?.stringValue, "subagent")

        let normal = try decodeItems(liteListJSON())[0]
        XCTAssertFalse(normal.isSubagent)
        XCTAssertNil(normal.subagentAddress)
    }

    // MARK: - Workspace list + cache path

    @MainActor
    func testWorkspaceViewModelAppliesLiteSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P15LiteListTests-cache-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suite = "P15LiteListTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let cacheStore = SessionListCacheStore(directory: directory, identity: { "p15-lite-tests" })
        let viewModel = WorkspaceViewModel(defaults: defaults, cacheStore: cacheStore)

        viewModel.applyWorkspaceFrame(
            .baseline(WorkspaceFollowSnapshot(
                items: [WorkspaceDescriptor(workspaceId: "w1", path: "/ws/a", title: "Repo", sessionIds: ["s-lite-1", "s-lite-2"])],
                archivedSessionIds: [],
                pinnedSessionIds: []
            ))
        )
        try viewModel.applySessionListResponse(TestJSON.value(liteListJSON()))

        XCTAssertEqual(viewModel.groups.count, 1)
        XCTAssertEqual(viewModel.groups[0].sessions.map(\.sessionId), ["s-lite-1", "s-lite-2"], "running row sorts first")
        XCTAssertEqual(viewModel.groups[0].sessions[0].title, "修复列表 1MB 响应")
        XCTAssertEqual(viewModel.sessionCount, 2)
        XCTAssertEqual(viewModel.allSessions.count, 2)
        XCTAssertFalse(viewModel.loadedFromCache)
        XCTAssertNotNil(viewModel.lastLoadedAt)
    }

    func testLiteRowSurvivesRenderSnapshotRoundTrip() throws {
        let item = try decodeItems(liteListJSON())[1]
        let renderRow = SessionListRenderSnapshot.session(from: item)
        XCTAssertEqual(renderRow.title, "")
        XCTAssertEqual(renderRow.lastPromptAt, 1_792_499_990_000)
        XCTAssertEqual(renderRow.userQuestionCount, 1)

        let rebuilt = SessionListRenderSnapshot.listItem(from: renderRow)
        XCTAssertEqual(rebuilt.sessionId, item.sessionId)
        XCTAssertEqual(rebuilt.title, item.title)
        XCTAssertEqual(rebuilt.lastPromptAt, item.lastPromptAt)
        XCTAssertEqual(rebuilt.updatedAt, item.updatedAt)
        XCTAssertEqual(rebuilt.cwd, item.cwd)
        XCTAssertEqual(rebuilt.userQuestionsActive.count, 1)
    }

    // MARK: - Opt-in contract

    func testSessionListLiteRequestArgs() {
        let args = SessionListLite.requestArgs()
        XCTAssertEqual(args["_request"]?.objectValue?["listMode"]?.stringValue, "lite")
        XCTAssertEqual(SessionListLite.requestKey, "listMode")
        XCTAssertEqual(SessionListLite.requestValue, "lite")
        XCTAssertEqual(SessionListLite.responseHeader, "x-dshm-list-lite")
    }
}
