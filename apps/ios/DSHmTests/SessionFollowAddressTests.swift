import XCTest
@testable import DSHm

/// Covers the `session/follow` address construction that must distinguish normal
/// sessions from subagent (Agent Teams teammate) sessions. The Host rejects a
/// plain address for a session whose header origin is "subagent" with
/// `session/agent-busy` — "subagent Sessions require their durable parent address".
final class SessionFollowAddressTests: XCTestCase {

    private func item(_ json: String) throws -> SessionListItem {
        try JSONDecoder().decode(SessionListItem.self, from: Data(json.utf8))
    }

    // MARK: - session/list item decoding

    func testNormalListItemBuildsPlainSessionAddress() throws {
        let listItem = try item(#"{"sessionId":"s-normal","cwd":"/tmp/ws"}"#)

        XCTAssertFalse(listItem.isSubagent)
        XCTAssertNil(listItem.origin)
        XCTAssertNil(listItem.parentSessionId)
        XCTAssertNil(listItem.subagentAddress, "normal sessions have no subagent address")
        XCTAssertEqual(listItem.followAddress, .session(sessionId: "s-normal"))
        XCTAssertEqual(
            listItem.followAddress.jsonValue,
            .object(["kind": .string("session"), "sessionId": .string("s-normal")])
        )
    }

    func testSubagentListItemBuildsDurableParentAddress() throws {
        let listItem = try item(#"""
        {"sessionId":"child-1","cwd":"/tmp/ws","origin":"subagent","parentSessionId":"parent-1"}
        """#)

        XCTAssertTrue(listItem.isSubagent)
        XCTAssertEqual(
            listItem.followAddress,
            .subagent(parentSessionId: "parent-1", childSessionId: "child-1", mode: "unknown"),
            "subagent sessions must be opened through their durable parent"
        )
        // mode:"unknown" lets the Host resolve the real mode from projections.
        XCTAssertEqual(
            listItem.subagentAddress,
            .object([
                "kind": .string("subagent"),
                "parentSessionId": .string("parent-1"),
                "childSessionId": .string("child-1"),
                "mode": .string("unknown"),
            ])
        )
        XCTAssertEqual(listItem.followAddress.jsonValue, listItem.subagentAddress)
    }

    /// Documented fallback: origin=subagent but no listed parentSessionId means the
    /// durable parent is unknown. We send the plain address (never crash, never
    /// fabricate a parent) and the Host reports its own business error banner.
    func testSubagentWithoutParentFallsBackToPlainAddress() throws {
        let listItem = try item(#"{"sessionId":"child-2","origin":"subagent"}"#)

        XCTAssertTrue(listItem.isSubagent, "origin still marks it as a subagent session")
        XCTAssertNil(listItem.subagentAddress, "no durable parent => no subagent address object")
        XCTAssertEqual(
            listItem.followAddress,
            .session(sessionId: "child-2"),
            "fallback must be a valid plain address, not a crash and not a fabricated parent"
        )
    }

    func testSubagentWithBlankParentFallsBackToPlainAddress() throws {
        let listItem = try item(#"{"sessionId":"child-3","origin":"subagent","parentSessionId":"   "}"#)

        XCTAssertTrue(listItem.isSubagent)
        XCTAssertNil(listItem.subagentAddress)
        XCTAssertEqual(listItem.followAddress, .session(sessionId: "child-3"))
    }

    /// Defensive: a listed durable parent is enough to open the subagent address
    /// even if the optional `origin` marker is absent.
    func testParentWithoutOriginStillBuildsSubagentAddress() throws {
        let listItem = try item(#"{"sessionId":"child-4","parentSessionId":"parent-4"}"#)

        XCTAssertTrue(listItem.isSubagent)
        XCTAssertEqual(
            listItem.followAddress,
            .subagent(parentSessionId: "parent-4", childSessionId: "child-4", mode: "unknown")
        )
    }

    // MARK: - Address type itself

    func testAddressAccessorsAndWireShape() throws {
        let plain = SessionFollowAddress.session(sessionId: "s-1")
        XCTAssertEqual(plain.sessionId, "s-1")
        XCTAssertFalse(plain.isSubagent)

        let subagent = SessionFollowAddress.subagent(
            parentSessionId: "p-1",
            childSessionId: "c-1",
            mode: "unknown"
        )
        XCTAssertEqual(subagent.sessionId, "c-1", "childSessionId is the session being viewed")
        XCTAssertTrue(subagent.isSubagent)

        let data = try JSONEncoder().encode(subagent.jsonValue)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["kind", "parentSessionId", "childSessionId", "mode"],
            "session/follow oneOf subagent branch requires exactly these four fields"
        )
        XCTAssertEqual(object["kind"] as? String, "subagent")
        XCTAssertEqual(object["parentSessionId"] as? String, "p-1")
        XCTAssertEqual(object["childSessionId"] as? String, "c-1")
        XCTAssertEqual(object["mode"] as? String, "unknown")
    }

    func testFromListItemTrimsParentSessionId() {
        XCTAssertEqual(
            SessionFollowAddress.fromListItem(sessionId: "c-9", parentSessionId: " p-9\n"),
            .subagent(parentSessionId: "p-9", childSessionId: "c-9", mode: "unknown")
        )
        XCTAssertEqual(
            SessionFollowAddress.fromListItem(sessionId: "s-9", parentSessionId: nil),
            .session(sessionId: "s-9")
        )
    }

    /// The view model must forward the chosen address to session/follow; a plain
    /// session id (APNs deep link) keeps the plain-address default.
    @MainActor
    func testSessionViewModelCarriesAddress() {
        let subagent = SessionFollowAddress.subagent(
            parentSessionId: "p-2",
            childSessionId: "c-2",
            mode: "unknown"
        )
        let subagentViewModel = SessionViewModel(address: subagent)
        XCTAssertEqual(subagentViewModel.address, subagent)
        XCTAssertEqual(subagentViewModel.sessionId, "c-2")

        let plainViewModel = SessionViewModel(sessionId: "s-2")
        XCTAssertEqual(plainViewModel.address, .session(sessionId: "s-2"))
        XCTAssertEqual(plainViewModel.sessionId, "s-2")
    }
}
