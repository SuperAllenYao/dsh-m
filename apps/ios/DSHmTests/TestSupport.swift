import Foundation
@testable import DSHm

enum TestJSON {
    static func value(_ text: String) -> JSONValue {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            fatalError("invalid test JSON: \(text)")
        }
        return value
    }

    /// One `session/list` row (v5.4 task-13 subagent runtime join tests).
    static func sessionItem(
        sessionId: String,
        running: Bool = false,
        userQuestionsActive: Int = 0,
        lastPromptAt: Int64? = nil,
        updatedAt: Int64? = nil,
        parentSessionId: String? = nil,
        origin: String? = "subagent",
        title: String? = nil
    ) -> SessionListItem {
        var projectionValues: [String: Any] = [:]
        var metadata: [String: Any] = [:]
        if let lastPromptAt { metadata["lastPromptAt"] = lastPromptAt }
        if !metadata.isEmpty { projectionValues["sessionListMetadata"] = metadata }
        if userQuestionsActive > 0 {
            projectionValues["userQuestions"] = ["active": Array(repeating: ["callId": "question-1"], count: userQuestionsActive)]
        }
        if let title { projectionValues["title"] = title }
        var row: [String: Any] = ["sessionId": sessionId, "running": running]
        if let updatedAt { row["updatedAt"] = updatedAt }
        if let parentSessionId { row["parentSessionId"] = parentSessionId }
        if let origin { row["origin"] = origin }
        if !projectionValues.isEmpty { row["projections"] = ["values": projectionValues] }
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              let item = try? JSONDecoder().decode(SessionListItem.self, from: data) else {
            fatalError("invalid session/list fixture: \(row)")
        }
        return item
    }

    /// JSON-escaped string literal (for embedding a JSON-string argument in a fixture).
    static func quoted(_ text: String) -> String {
        let data = try! JSONEncoder().encode(text)
        return String(data: data, encoding: .utf8)!
    }

    static func event(_ type: String, seq: Int, time: Int64 = 1_792_510_000_000, data: JSONValue? = nil) -> SessionEvent {
        SessionEvent(type: type, seq: seq, time: time, data: data, surfaceOp: nil, sourceEventSeqs: nil)
    }

    static func reason(_ kind: String) -> JSONValue {
        .object(["kind": .string(kind)])
    }
}
