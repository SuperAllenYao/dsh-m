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
    func testAppModelOpenSessionByIDUsesResolvedAddress() {
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

        app.openSession("s-unknown")
        XCTAssertEqual(app.route, .session(.session(sessionId: "s-unknown")), "fallback when list has no match")
    }

    @MainActor
    func testAppModelOpenSessionByAddressStillWorks() {
        let app = AppModel()
        app.openSession(.subagent(parentSessionId: "p", childSessionId: "c", mode: "unknown"))
        XCTAssertEqual(app.route, .session(.subagent(parentSessionId: "p", childSessionId: "c", mode: "unknown")))
    }
}
