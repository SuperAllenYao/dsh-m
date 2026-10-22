import XCTest
@testable import DSHm

/// Covers notification deep links: the APNs payload carries only a session id
/// (plugin `notifier.js`), so `AppModel.openSession(_:)` must resolve it against
/// the last loaded `session/list` to pick the right `session/follow` address.
final class SessionDeepLinkResolverTests: XCTestCase {

    private func item(_ sessionId: String, origin: String? = nil, parentSessionId: String? = nil) -> SessionListItem {
        SessionListItem(
            sessionId: sessionId,
            origin: origin,
            parentSessionId: parentSessionId
        )
    }

    func testKnownNormalSessionResolvesPlainAddress() {
        let resolver = SessionDeepLinkResolver(sessions: [item("s-normal")])
        XCTAssertEqual(resolver.address(for: "s-normal"), .session(sessionId: "s-normal"))
        XCTAssertEqual(resolver.knownSessionCount, 1)
    }

    func testKnownSubagentSessionResolvesDurableParentAddress() {
        let resolver = SessionDeepLinkResolver(sessions: [
            item("child-1", origin: "subagent", parentSessionId: "parent-1"),
        ])
        XCTAssertEqual(
            resolver.address(for: "child-1"),
            .subagent(parentSessionId: "parent-1", childSessionId: "child-1", mode: "unknown"),
            "a notification pointing at a subagent session must open its durable parent address"
        )
        XCTAssertEqual(
            resolver.address(for: "child-1").jsonValue,
            .object([
                "kind": .string("subagent"),
                "parentSessionId": .string("parent-1"),
                "childSessionId": .string("child-1"),
                "mode": .string("unknown"),
            ])
        )
    }

    /// Documented M1 limitation: a cold launch straight from the notification (or
    /// a session created after the last refresh) has no list row to resolve, so
    /// the plain address is used and the Host may return its business error.
    func testUnknownSessionFallsBackToPlainAddress() {
        let resolver = SessionDeepLinkResolver(sessions: [item("s-normal")])
        XCTAssertEqual(resolver.address(for: "s-missing"), .session(sessionId: "s-missing"))
    }

    func testEmptyListFallsBackToPlainAddress() {
        let resolver = SessionDeepLinkResolver()
        XCTAssertEqual(resolver.address(for: "child-2"), .session(sessionId: "child-2"))
        XCTAssertEqual(resolver.knownSessionCount, 0)
    }

    func testUpdateReplacesLookupTable() {
        var resolver = SessionDeepLinkResolver(sessions: [
            item("child-3", origin: "subagent", parentSessionId: "parent-3"),
        ])
        XCTAssertEqual(
            resolver.address(for: "child-3"),
            .subagent(parentSessionId: "parent-3", childSessionId: "child-3", mode: "unknown")
        )
        resolver.update(sessions: [item("s-4")])
        XCTAssertEqual(resolver.knownSessionCount, 1)
        XCTAssertEqual(
            resolver.address(for: "child-3"),
            .session(sessionId: "child-3"),
            "stale rows must not survive a list refresh"
        )
        XCTAssertEqual(resolver.address(for: "s-4"), .session(sessionId: "s-4"))
    }

    func testDuplicateSessionIdDoesNotCrash() {
        let resolver = SessionDeepLinkResolver(sessions: [
            item("dup", origin: "subagent", parentSessionId: "p-old"),
            item("dup", origin: "subagent", parentSessionId: "p-new"),
        ])
        // Last write wins; the important part is that duplicate ids never crash.
        XCTAssertEqual(
            resolver.address(for: "dup"),
            .subagent(parentSessionId: "p-new", childSessionId: "dup", mode: "unknown")
        )
    }

    // MARK: - AppModel integration (deep-link entry point)

    @MainActor
    func testAppModelOpenSessionByIDUsesResolvedAddress() async {
        let app = AppModel()
        app.updateKnownSessions([
            item("s-plain"),
            item("child-5", origin: "subagent", parentSessionId: "parent-5"),
        ])

        app.openSession("child-5")
        XCTAssertEqual(
            app.route,
            .session(.subagent(parentSessionId: "parent-5", childSessionId: "child-5", mode: "unknown")),
            "notification tap for a subagent session must route to the parent address"
        )

        app.openSession("s-plain")
        XCTAssertEqual(app.route, .session(.session(sessionId: "s-plain")))

        // Unknown id: the deep link resolves one `session/list` first (bounded),
        // then falls back to the plain address when the list has no match.
        app.deepLinkSessionLookup = { _ in [] }
        app.openSession("s-unknown")
        for _ in 0..<25 where app.route != .session(.session(sessionId: "s-unknown")) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(app.route, .session(.session(sessionId: "s-unknown")), "fallback when list has no match")
        XCTAssertNil(app.subagentRoute)
    }

    /// 冷启动 / 列表过期：deep link 的 id 未知时必须先查一次 `session/list`，确认是
    /// subagent 子会话后按 parent 地址 + context 打开；不能先开 plain 详情再改路由
    /// （详情 identity 是 sessionId，换地址不会重建 VM，Host 拒绝会一直挂着）。
    @MainActor
    func testAppModelOpenSessionUnknownResolvesSubagentBeforeOpening() async {
        let app = AppModel()
        app.deepLinkSessionLookup = { _ in
            [
                self.item("parent-9"),
                self.item("child-9", origin: "subagent", parentSessionId: "parent-9"),
            ]
        }

        app.openSession("child-9")
        var attempts = 0
        while attempts < 25 {
            if case .session = app.route { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }

        XCTAssertEqual(
            app.route,
            .session(.subagent(parentSessionId: "parent-9", childSessionId: "child-9", mode: "unknown")),
            "未知 id 解析出子会话后必须用 durable parent 地址打开"
        )
        XCTAssertEqual(app.subagentRoute?.parentAddress, .session(sessionId: "parent-9"))
        XCTAssertEqual(app.subagentRoute?.context.childSessionId, "child-9")
    }

    @MainActor
    func testAppModelOpenSessionByAddressStillWorks() {
        let app = AppModel()
        app.openSession(.subagent(parentSessionId: "p", childSessionId: "c", mode: "unknown"))
        XCTAssertEqual(app.route, .session(.subagent(parentSessionId: "p", childSessionId: "c", mode: "unknown")))
    }

    // MARK: - task-9: push deep link must open subagent sessions with parent context

    /// 真机 bug①（23:0x turn-end 推送点开后空白/turn2 贴底）：推送目标若是 subagent
    /// 子会话，必须按 durable parent 地址打开，并带上 subagentRoute（返回父会话、
    /// 只读语义）。否则 Host 会拒绝 plain address（`session/agent-busy` → 空白详情），
    /// 或者把子会话当普通会话打开。
    @MainActor
    func testAppModelOpenSessionByIDBuildsSubagentContextAndParentBackRoute() {
        let app = AppModel()
        app.updateKnownSessions([
            item("parent-6"),
            item("child-6", origin: "subagent", parentSessionId: "parent-6"),
        ])

        app.openSession("child-6")

        XCTAssertEqual(
            app.route,
            .session(.subagent(parentSessionId: "parent-6", childSessionId: "child-6", mode: "unknown")),
            "子会话推送必须打开 durable parent 地址"
        )
        XCTAssertEqual(
            app.subagentRoute?.parentAddress,
            .session(sessionId: "parent-6"),
            "返回键必须回到父会话，而不是工作区列表"
        )
        XCTAssertEqual(app.subagentRoute?.context.parentSessionId, "parent-6")
        XCTAssertEqual(app.subagentRoute?.context.childSessionId, "child-6")
    }

    /// 普通顶层会话推送仍按 plain 地址打开，且不得残留上一次的子代理返回路由。
    @MainActor
    func testAppModelOpenSessionByIDClearsSubagentRouteForPlainSession() {
        let app = AppModel()
        app.updateKnownSessions([
            item("parent-7"),
            item("child-7", origin: "subagent", parentSessionId: "parent-7"),
            item("s-plain-7"),
        ])
        app.openSession("child-7")
        XCTAssertNotNil(app.subagentRoute)

        app.openSession("s-plain-7")
        XCTAssertEqual(app.route, .session(.session(sessionId: "s-plain-7")))
        XCTAssertNil(app.subagentRoute, "顶层会话不得残留子代理返回路由")
    }

    /// 未知 session（冷启动 / 列表过期）先按 plain 打开，等异步 session/list 结果
    /// 再升级——纯决策 seam 这里锁定两端：未知 = plain 无 context；子会话 = 有 context。
    func testDeepLinkNavigationDecision() {
        let resolver = SessionDeepLinkResolver(sessions: [
            item("parent-8"),
            item("child-8", origin: "subagent", parentSessionId: "parent-8"),
        ])

        let unknown = AppModel.deepLinkNavigation(sessionId: "s-missing", resolver: resolver)
        XCTAssertEqual(unknown.address, .session(sessionId: "s-missing"))
        XCTAssertNil(unknown.parentAddress)
        XCTAssertNil(unknown.context)

        let ordinary = AppModel.deepLinkNavigation(sessionId: "parent-8", resolver: resolver)
        XCTAssertEqual(ordinary.address, .session(sessionId: "parent-8"))
        XCTAssertNil(ordinary.context)

        let subagent = AppModel.deepLinkNavigation(sessionId: "child-8", resolver: resolver)
        XCTAssertEqual(
            subagent.address,
            .subagent(parentSessionId: "parent-8", childSessionId: "child-8", mode: "unknown")
        )
        XCTAssertEqual(subagent.parentAddress, .session(sessionId: "parent-8"))
        XCTAssertEqual(subagent.context?.parentSessionId, "parent-8")
        XCTAssertEqual(subagent.context?.childSessionId, "child-8")
    }

    /// 连续点两条（都未知 id）推送：只有最新一条生效，慢查询的旧结果不得覆盖。
    @MainActor
    func testRapidDeepLinkTapsKeepNewestNavigation() async {
        let app = AppModel()
        app.deepLinkSessionLookup = { sessionId in
            try? await Task.sleep(nanoseconds: 120_000_000)
            return [self.item(sessionId)]
        }
        app.openSession("first-target")
        app.openSession("second-target")

        var attempts = 0
        while attempts < 40 {
            if case .session(let address) = app.route, address.sessionId == "second-target" { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }
        XCTAssertEqual(
            app.route,
            .session(.session(sessionId: "second-target")),
            "最新一次 deep link 必须胜出（旧的慢查询不得覆盖）"
        )
    }
}
