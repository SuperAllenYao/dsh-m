import Foundation

// MARK: - Errors

/// DSH Remote business error: {code, message, details}. `details` is an open object.
struct RemoteError: Codable, Equatable, Sendable {
    var code: String
    var message: String
    var details: JSONValue?

    init(code: String, message: String, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

extension RemoteError: LocalizedError {
    var errorDescription: String? { message }
}

/// Transport / codec level failures (HTTP status, TLS pin, malformed envelope...).
enum LinkError: Error, LocalizedError, Equatable {
    case notPaired
    case notConnected
    case tlsPinMismatch(expected: String, actual: String?)
    case transport(String)
    case httpStatus(Int, String)
    case malformedEnvelope(String)
    case rpcMismatch(expected: String, actual: String)
    case remote(RemoteError)
    case cancelled
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .notPaired: return "尚未配对"
        case .notConnected: return "连接未就绪"
        case .tlsPinMismatch(let expected, let actual):
            return "TLS 证书指纹不匹配（期望 \(expected)…，实际 \(actual ?? "无")…）"
        case .transport(let message): return message
        case .httpStatus(let status, let body): return "HTTP \(status): \(body.prefix(160))"
        case .malformedEnvelope(let message): return "协议信封非法: \(message)"
        case .rpcMismatch(let expected, let actual): return "rpcId 不匹配: \(expected) != \(actual)"
        case .remote(let error): return error.message.isEmpty ? error.code : "\(error.code): \(error.message)"
        case .cancelled: return "已取消"
        case .timeout(let what): return "超时: \(what)"
        }
    }

    var remoteError: RemoteError? {
        if case .remote(let error) = self { return error }
        return nil
    }
}

// MARK: - Unary envelopes (§2)

/// Client to server unary envelope: {type:"client-request", rpcId, method, payload:{args}}.
struct ClientRequestEnvelope: Encodable {
    let type = "client-request"
    let rpcId: String
    let method: String
    let payload: Payload

    struct Payload: Encodable {
        let args: [String: JSONValue]
    }

    init(rpcId: String = UUID().uuidString.lowercased(), method: String, args: [String: JSONValue]) {
        self.rpcId = rpcId
        self.method = method
        self.payload = Payload(args: args)
    }
}

/// Server to client unary envelope: result is ok(value) or error(RemoteError).
enum UnaryResult: Decodable {
    case ok(JSONValue)
    case failure(RemoteError)

    private enum CodingKeys: String, CodingKey {
        case ok
        case value
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ok = (try? container.decode(Bool.self, forKey: .ok)) ?? false
        if ok {
            let value = (try? container.decode(JSONValue.self, forKey: .value)) ?? .null
            self = .ok(value)
        } else {
            let error = (try? container.decode(RemoteError.self, forKey: .error))
                ?? RemoteError(code: "unknown", message: "malformed error")
            self = .failure(error)
        }
    }
}

struct ServerResponseEnvelope: Decodable {
    let type: String
    let rpcId: String
    let result: UnaryResult
}

// MARK: - Session list (§5.2 example 2)

struct ProjectionValues: Codable, Equatable {
    var asOfSeq: Int64?
    var values: [String: JSONValue]

    init(asOfSeq: Int64? = nil, values: [String: JSONValue] = [:]) {
        self.asOfSeq = asOfSeq
        self.values = values
    }

    enum CodingKeys: String, CodingKey {
        case asOfSeq
        case values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        asOfSeq = try? container.decode(Int64.self, forKey: .asOfSeq)
        values = (try? container.decode([String: JSONValue].self, forKey: .values)) ?? [:]
    }
}

struct SessionListItem: Decodable, Identifiable, Equatable {
    var sessionId: String
    var updatedAt: Int64?
    var agentAvailable: Bool?
    var formatStatus: String?
    var running: Bool?
    var blank: Bool?
    var cwd: String?
    /// `"subagent"` for Agent Teams teammate sessions (a session/list item field,
    /// not a session header field).
    var origin: String?
    /// Durable parent session id, present on subagent sessions.
    var parentSessionId: String?
    var projections: ProjectionValues?

    var id: String { sessionId }

    /// True for subagent (Agent Teams teammate) sessions. `origin` is the protocol
    /// marker; a non-empty `parentSessionId` also implies a subagent session
    /// (defensive, so a missing `origin` cannot silently regress the open path).
    var isSubagent: Bool {
        origin == "subagent" || parentSessionId?.isEmpty == false
    }

    /// Address for `session/follow`. Subagent items must use their durable parent
    /// address; if `origin == "subagent"` but no `parentSessionId` is present the
    /// durable parent is unknown, so this falls back to the plain session address
    /// (the Host then reports a business error instead of the app crashing).
    var followAddress: SessionFollowAddress {
        SessionFollowAddress.fromListItem(
            sessionId: sessionId,
            parentSessionId: parentSessionId
        )
    }

    /// Subagent address object (protocol §3.5 oneOf, second branch), or nil for
    /// normal sessions and for incomplete subagent identities.
    var subagentAddress: JSONValue? {
        guard case .subagent = followAddress else { return nil }
        return followAddress.jsonValue
    }

    var title: String? { projections?.values["title"]?.stringValue }

    var lastPromptAt: Int64? {
        projections?.values["sessionListMetadata"]?["lastPromptAt"]?.intValue
    }

    /// Active user-question waterfall calls from
    /// `projections.values.userQuestions.active` (v5.4 status: this session is
    /// waiting for a human answer). Answering itself is MVP scope; the phone list
    /// only shows the status.
    var userQuestionsActive: [JSONValue] {
        projections?.values["userQuestions"]?["active"]?.arrayValue ?? []
    }

    /// True while at least one user-question call awaits an answer.
    var hasActiveUserQuestions: Bool { !userQuestionsActive.isEmpty }

    /// Typed view of the same projection used by the answer loop (task-2):
    /// `projections.values.userQuestions.active` decoded into models.
    var activeUserQuestions: [UserQuestionCall] {
        UserQuestionsProjection.parse(projections?.values["userQuestions"]).active
    }

    /// v5.5 §14.5: context-window usage parsed from the retained raw projections
    /// JSON of `session/list` (nil until the provider reports usage). Works for
    /// normal and subagent rows alike (a subagent child is its own list row).
    var contextPressure: ContextPressureValue? {
        guard let value = projections?.values["contextPressure"] else { return nil }
        return ContextPressureValue(projection: value)
    }

    var isRunning: Bool { running == true }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return blank == true ? "新会话" : "未命名会话"
    }

    var workspacePath: String { cwd ?? "" }
}

struct SessionListValue: Decodable {
    var items: [SessionListItem]
}

/// `session/follow` request.address (protocol §3.5 `oneOf`):
/// - normal session: `{"kind":"session","sessionId":"<id>"}`
/// - subagent session: `{"kind":"subagent","parentSessionId":"<parent>",
///   "childSessionId":"<child>","mode":"one-shot"|"continuable"|"unknown"}`
///
/// The Host rejects a plain `kind:"session"` address for a session whose header
/// `origin` is `"subagent"` with `session/agent-busy` ("subagent Sessions require
/// their durable parent address"). `mode:"unknown"` is the safe value: the Host
/// then resolves the real mode from its projections instead of requiring an exact
/// `one-shot`/`continuable` match.
enum SessionFollowAddress: Equatable, Sendable {
    case session(sessionId: String)
    case subagent(parentSessionId: String, childSessionId: String, mode: String)

    var sessionId: String {
        switch self {
        case .session(let sessionId): return sessionId
        case .subagent(_, let childSessionId, _): return childSessionId
        }
    }

    var isSubagent: Bool {
        if case .subagent = self { return true }
        return false
    }

    /// Wire value for `request.address`.
    var jsonValue: JSONValue {
        switch self {
        case .session(let sessionId):
            return .object([
                "kind": .string("session"),
                "sessionId": .string(sessionId),
            ])
        case .subagent(let parentSessionId, let childSessionId, let mode):
            return .object([
                "kind": .string("subagent"),
                "parentSessionId": .string(parentSessionId),
                "childSessionId": .string(childSessionId),
                "mode": .string(mode),
            ])
        }
    }

    /// Builds the address from a `session/list` item's durable parent id. A
    /// subagent item always uses `mode:"unknown"`; when the listed parent id is
    /// missing/blank there is no valid durable parent address, so fall back to the
    /// plain address (documented trade-off: the Host returns a business error,
    /// no crash).
    static func fromListItem(
        sessionId: String,
        parentSessionId: String?
    ) -> SessionFollowAddress {
        let parent = parentSessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !parent.isEmpty else {
            // Normal session, or an origin=="subagent" item whose durable parent
            // is missing from session/list: cannot build a valid parent address.
            return .session(sessionId: sessionId)
        }
        return .subagent(parentSessionId: parent, childSessionId: sessionId, mode: "unknown")
    }
}

// MARK: - session/follow (§3.5)

struct SessionHeader: Codable, Equatable {
    var version: Int?
    var id: String
    var createdAt: Int64?
    var cwd: String?
    var isSeeded: Bool?
    var agentPreset: String?
}

struct SessionEvent: Codable, Equatable, Identifiable {
    var type: String
    var seq: Int
    var time: Int64?
    var data: JSONValue?
    /// Host surface bookkeeping. Older Hosts sent a plain string (`"replace"`);
    /// current Hosts send a structured object (`{"op":"replace","startSeq":…}`).
    /// The App never reads it, so it is kept as a raw value: a changed shape must
    /// never fail the whole `session/follow` frame (or the snapshot that carries
    /// the same event).
    var surfaceOp: JSONValue?
    /// Event ids this event supersedes (`[75]` on the wire).
    var sourceEventSeqs: [Int]?

    var id: String { "seq-\(seq)" }
}

extension SessionEvent {
    /// Tolerant decode (2026-10-22): only `type` + `seq` are required. Every
    /// other field is optional *and shape-tolerant*, because one unfamiliar
    /// field used to drop the entire frame — the detail then showed the generic
    /// "帧解析失败" banner and, since the offending event also rides in every
    /// re-follow snapshot, the session stayed unopenable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        seq = try container.decode(Int.self, forKey: .seq)
        time = try? container.decodeIfPresent(Int64.self, forKey: .time)
        data = try? container.decodeIfPresent(JSONValue.self, forKey: .data)
        surfaceOp = try? container.decodeIfPresent(JSONValue.self, forKey: .surfaceOp)
        sourceEventSeqs = try? container.decodeIfPresent([Int].self, forKey: .sourceEventSeqs)
    }
}

struct SnapshotRecord: Decodable {
    var type: String
    var event: SessionEvent?
    var seq: Int?
}

struct AssistantStreamBaseline: Codable, Equatable {
    var revision: Int
}

struct SessionSnapshot: Decodable {
    var type: String
    var header: SessionHeader
    var cursor: Int
    var records: [SnapshotRecord]
    var hasMore: Bool?
    var projections: ProjectionValues?
    var assistantStream: AssistantStreamBaseline?
}

struct AssistantStreamFrame: Decodable, Equatable {
    var type: String
    var attemptId: String?
    var revision: Int
    var turn: Int?
    var step: Int?
    var index: Int?
    var startedAfterSeq: Int?
    var chunk: JSONValue?
    var outcome: JSONValue?
}

/// One item from a session/follow logical stream (the mux "item" value payload).
enum SessionStreamFrame {
    case snapshot(SessionSnapshot)
    case event(SessionEvent)
    case assistantStream(AssistantStreamFrame)
    case unknown(String)

    static func decode(_ value: JSONValue) throws -> SessionStreamFrame {
        guard let type = value["type"]?.stringValue else {
            throw LinkError.malformedEnvelope("session/follow item without type")
        }
        switch type {
        case "snapshot":
            return .snapshot(try value.decode(SessionSnapshot.self))
        case "event":
            guard let eventValue = value["event"] else {
                throw LinkError.malformedEnvelope("event frame without event")
            }
            return .event(try eventValue.decode(SessionEvent.self))
        case "assistant-stream":
            guard let frameValue = value["frame"] else {
                throw LinkError.malformedEnvelope("assistant-stream without frame")
            }
            return .assistantStream(try frameValue.decode(AssistantStreamFrame.self))
        default:
            return .unknown(type)
        }
    }
}
