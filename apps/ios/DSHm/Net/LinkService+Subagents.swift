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

 /// Lightweight `session/list` read used by the subagent capsule/list refresh
 /// (running/agentAvailable/updatedAt/userQuestions metadata).
    func listSessions() async throws -> [SessionListItem] {
        let value = try await unary("session/list", args: ["_request": .object([:])], timeout: 20)
        return try value.decode(SessionListValue.self).items
    }
}
