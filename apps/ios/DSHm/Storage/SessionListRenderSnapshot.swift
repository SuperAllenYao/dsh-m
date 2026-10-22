import Foundation

/// M2b-2b: compact, render-only mirror of the workspace list, used for the cold-start
/// first frame.
///
/// `session-list.json` keeps the raw `session/list` wire JSON (source of truth for
/// background refresh/consistency), but it is ~1MB on a busy machine and its decode
/// is unnecessary before the first paint. This snapshot carries only the fields the
/// list cards need (workspace grouping + card title/time/status inputs), so decoding
/// it is a few milliseconds instead of tens.
///
/// Same envelope semantics as the raw cache (`CacheSchema.version`, pairing
/// `identity`, `savedAt` TTL/retention, corrupt/mismatch -> nil + delete).
struct SessionListRenderSnapshot: Codable, Equatable, Sendable {
    struct Session: Codable, Equatable, Sendable {
        var sessionId: String
        var title: String?
        var lastPromptAt: Int64?
        var updatedAt: Int64?
        var running: Bool?
        var blank: Bool?
        var cwd: String?
        var origin: String?
        var parentSessionId: String?
        var userQuestionCount: Int
    }

    struct Group: Codable, Equatable, Sendable {
        var workspaceId: String
        var path: String
        var title: String
        var displayName: String
        var sessions: [Session]
    }

    var schemaVersion: Int
    var savedAt: Date
    var identity: String
    /// Registry state so incremental `workspace/follow` frames can still be applied
    /// after a compact-only cold start (the raw cache is restored in the background).
    var followBaseline: JSONValue?
    var groups: [Group]

    /// Builds the compact render row for one list item.
    static func session(from item: SessionListItem) -> Session {
        Session(
            sessionId: item.sessionId,
            title: item.title,
            lastPromptAt: item.lastPromptAt,
            updatedAt: item.updatedAt,
            running: item.running,
            blank: item.blank,
            cwd: item.cwd,
            origin: item.origin,
            parentSessionId: item.parentSessionId,
            userQuestionCount: item.userQuestionsActive.count
        )
    }

    /// Rebuilds the `SessionListItem` the existing cards/status resolver/opening path
    /// expect from one compact row (the dropped projections are not rendered by the
    /// list and are replaced by the background raw restore / next network refresh).
    static func listItem(from session: Session) -> SessionListItem {
        var values: [String: JSONValue] = [:]
        if let title = session.title {
            values["title"] = .string(title)
        }
        if let lastPromptAt = session.lastPromptAt {
            values["sessionListMetadata"] = .object(["lastPromptAt": .int(lastPromptAt)])
        }
        if session.userQuestionCount > 0 {
            values["userQuestions"] = .object([
                "active": .array((0..<session.userQuestionCount).map { _ in
                    .object(["callId": .string("cached")])
                }),
            ])
        }
        return SessionListItem(
            sessionId: session.sessionId,
            updatedAt: session.updatedAt,
            agentAvailable: nil,
            formatStatus: nil,
            running: session.running,
            blank: session.blank,
            cwd: session.cwd,
            origin: session.origin,
            parentSessionId: session.parentSessionId,
            projections: ProjectionValues(values: values)
        )
    }
}
