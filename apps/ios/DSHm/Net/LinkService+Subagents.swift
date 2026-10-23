import Foundation

// MARK: - subagents/prompt (v5.4 task-13)

/// Pure wire-args builders for the subagent endpoints, kept separate so the
/// contract (`mode:"continuable"`, `delivery:"queue"|"steer"`) is unit-tested.
enum SubagentsPromptArgs {
    static let continuableMode = "continuable"

 /// `request` payload for `subagents/prompt`:
 /// `{requestId, parentSessionId, childSessionId, mode:"continuable",
 /// delivery:"queue"|"steer", content:[{type:"text", text}], clientTimeZone?}`
    static func make(
        requestId: String = UUID().uuidString.lowercased(),
        parentSessionId: String,
        childSessionId: String,
        delivery: String,
        text: String,
        clientTimeZone: String? = TimeZone.current.identifier
    ) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "requestId": .string(requestId),
            "parentSessionId": .string(parentSessionId),
            "childSessionId": .string(childSessionId),
            "mode": .string(continuableMode),
            "delivery": .string(delivery),
            "content": .array([
                .object(["type": .string("text"), "text": .string(text)]),
            ]),
        ]
        if let clientTimeZone, !clientTimeZone.isEmpty {
            payload["clientTimeZone"] = .string(clientTimeZone)
        }
        return payload
    }
}

// MARK: - subagents/interruptByParent (v5.4 task-13)

enum SubagentsInterruptArgs {
 /// `request` payload for `subagents/interruptByParent`:
 /// `{childSessionId, parentSessionId}`.
    static func make(parentSessionId: String, childSessionId: String) -> [String: JSONValue] {
        [
            "childSessionId": .string(childSessionId),
            "parentSessionId": .string(parentSessionId),
        ]
    }
}

// MARK: - LinkService calls

extension LinkService {
 /// Sends a message to a continuable subagent session from its parent.
    @discardableResult
    func subagentsPrompt(
        parentSessionId: String,
        childSessionId: String,
        delivery: String,
        text: String
    ) async throws -> JSONValue {
        try await unary("subagents/prompt", args: [
            "request": .object(SubagentsPromptArgs.make(
                parentSessionId: parentSessionId,
                childSessionId: childSessionId,
                delivery: delivery,
                text: text
            )),
        ])
    }

 /// Interrupts a running subagent from its parent (`interruptByParent`).
    @discardableResult
    func subagentsInterruptByParent(
        parentSessionId: String,
        childSessionId: String
    ) async throws -> JSONValue {
        try await unary("subagents/interruptByParent", args: [
            "request": .object(SubagentsInterruptArgs.make(
                parentSessionId: parentSessionId,
                childSessionId: childSessionId
            )),
        ])
    }

 /// Wire args for the subagent/capsule `session/list` read.
 ///
 /// P1.5-A: this is the highest-frequency list read in the App — an open detail
 /// polls it on the 8 s tick (`SessionDetailView`) and on every ≥2 s activity
 /// debounce (`SessionViewModel.scheduleSubagentRefreshFromActivity`) — so it
 /// **must** opt in to the plugin's lite projection trim
 /// (`packages/dsh-m-link/lib/list-lite.js`). Without the hint the plugin
 /// returns the untouched ~1.5 MB response (~357 KB gzipped) on every poll;
 /// with it, rows keep exactly the fields the derived state reads
 /// (`contextPressure`, `userQuestions.active`, `running`, `agentAvailable`,
 /// `origin`/`parentSessionId` for the subagent catalog).
 ///
 /// Kept as a pure builder (no socket) so the opt-in contract is unit-tested:
 /// `P15LiteListTests.testListSessionsRequestArgsCarryLiteHint`.
    nonisolated static func listSessionsRequestArgs() -> [String: JSONValue] {
        SessionListLite.requestArgs()
    }

 /// Lightweight `session/list` read used by the subagent capsule/list refresh
 /// (running/agentAvailable/updatedAt/userQuestions metadata).
    func listSessions() async throws -> [SessionListItem] {
        let value = try await unary("session/list", args: Self.listSessionsRequestArgs(), timeout: 20)
        return try value.decode(SessionListValue.self).items
    }
}
