import Foundation

// MARK: - mux frames (§3.2)

/// Logical stream frame carried on /api/remote.mux.
/// One WebSocket text message = one JSON object; key sets are validated strictly by DSH.
enum MuxFrame: Equatable {
 /// Client to server: open a logical stream.
    case open(streamId: String, endpoint: String, args: [String: JSONValue])
 /// Client to server uplink item; nil value == undefined (field omitted).
    case item(streamId: String, value: JSONValue?)
 /// Client to server uplink end.
    case end(streamId: String)
 /// Client to server cancel.
    case cancel(streamId: String)
 /// Server to client data item (value may be omitted).
    case serverItem(streamId: String, value: JSONValue?)
 /// Server to client stream ended.
    case serverEnd(streamId: String)
 /// Server to client stream failed.
    case serverError(streamId: String, error: RemoteError)

 /// Encodes a client to server frame into its wire JSON value.
    func encodedJSON() throws -> JSONValue {
        switch self {
        case .open(let streamId, let endpoint, let args):
            return .object([
                "type": .string("open"),
                "streamId": .string(streamId),
                "endpoint": .string(endpoint),
                "payload": .object(["args": .object(args)]),
            ])
        case .item(let streamId, let value):
            if let value {
                return .object(["type": .string("item"), "streamId": .string(streamId), "value": value])
            }
            return .object(["type": .string("item"), "streamId": .string(streamId)])
        case .end(let streamId):
            return .object(["type": .string("end"), "streamId": .string(streamId)])
        case .cancel(let streamId):
            return .object(["type": .string("cancel"), "streamId": .string(streamId)])
        case .serverItem, .serverEnd, .serverError:
            throw LinkError.malformedEnvelope("attempted to encode a server frame")
        }
    }

 /// Decodes a server to client frame.
    static func decode(_ value: JSONValue) throws -> MuxFrame {
        guard let type = value["type"]?.stringValue else {
            throw LinkError.malformedEnvelope("mux frame without type")
        }
        guard let streamId = value["streamId"]?.stringValue else {
            throw LinkError.malformedEnvelope("mux frame without streamId")
        }
        switch type {
        case "item":
            return .serverItem(streamId: streamId, value: value["value"])
        case "end":
            return .serverEnd(streamId: streamId)
        case "error":
            guard let errorValue = value["error"] else {
                return .serverError(streamId: streamId, error: RemoteError(code: "unknown", message: "stream error without body"))
            }
            let error = (try? errorValue.decode(RemoteError.self))
                ?? RemoteError(code: "unknown", message: errorValue["message"]?.stringValue ?? "stream error")
            return .serverError(streamId: streamId, error: error)
        default:
            throw LinkError.malformedEnvelope("unknown mux frame type \(type)")
        }
    }
}

// MARK: - $events (§3.7)

/// `ready` frame of the forwarded remote-events stream.
struct RemoteEventsReady: Decodable {
    var type: String
    var clientId: String
    var host: HostInfo?

    struct HostInfo: Decodable {
        var home: String?
    }
}

/// A pending approval waterfall request (`approval/request`).
struct ApprovalWaterfall: Identifiable, Equatable {
    var eventId: String
    var agentId: String?
    var toolName: String?
    var callId: String?
    var reason: String?
    var displayReason: String?

    var id: String { eventId }

 /// Parses the `value` of an `$events` item when it is an approval waterfall.
    static func parse(_ value: JSONValue) -> ApprovalWaterfall? {
        guard value["type"]?.stringValue == "waterfall" else { return nil }
        guard value["event"]?.stringValue == "approval/request" else { return nil }
        guard let eventId = value["eventId"]?.stringValue else { return nil }
        let request = value["request"]
        return ApprovalWaterfall(
            eventId: eventId,
            agentId: value["agentId"]?.stringValue,
            toolName: request?["toolName"]?.stringValue,
            callId: request?["callId"]?.stringValue,
            reason: request?["reason"]?.stringValue,
            displayReason: Self.localizedDisplayReason(request?["displayReason"])
        )
    }

 /// displayReason is a bilingual object on the wire ({en, zh}, protocol §3.7.1).
 /// Older payloads may carry a plain string; iOS shows Chinese by default.
    static func localizedDisplayReason(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let string = value.stringValue { return string }
        return value["zh"]?.stringValue ?? value["en"]?.stringValue
    }

 /// Reason shown in the approval sheet: displayReason first, then reason.
    var localizedReason: String? {
        if let displayReason, !displayReason.isEmpty { return displayReason }
        return reason
    }
}

/// A pending user-question waterfall request (`user-questions/request`, §3.7.2).
///
/// Live half of the answer loop: only `open` calls carry one here, and they are
/// answered through the unary `$events/result` method (see EventsResultArgs).
struct UserQuestionWaterfall: Identifiable, Equatable {
    var eventId: String
    var agentId: String?
    var questions: [UserQuestion]
 /// `request.wait.callId` — authoritative correlation with the projection's
 /// `userQuestions.active[].callId`. Older hosts omit it; the caller then
 /// falls back to matching question ids.
    var callId: String?
 /// `request.wait.timed` — the Host waits with a timeout on this client.
    var timed: Bool?

    var id: String { eventId }

 /// Parses the `value` of an `$events` item when it is a user-question waterfall.
    static func parse(_ value: JSONValue) -> UserQuestionWaterfall? {
        guard value["type"]?.stringValue == "waterfall" else { return nil }
        guard value["event"]?.stringValue == "user-questions/request" else { return nil }
        guard let eventId = value["eventId"]?.stringValue else { return nil }
        let request = value["request"]
        let wait = request?["wait"]
        let questionsValue = request?["questions"] ?? .array([])
        let questions = (try? questionsValue.decode([UserQuestion].self)) ?? []
 // P1-4: a waterfall without usable questions can only render an empty
 // card and would submit `{"answers":[]}`; treat it as not answerable.
        guard !questions.isEmpty else { return nil }
        return UserQuestionWaterfall(
            eventId: eventId,
            agentId: value["agentId"]?.stringValue,
            questions: questions,
            callId: wait?["callId"]?.stringValue ?? request?["callId"]?.stringValue,
            timed: wait?["timed"]?.boolValue ?? request?["timed"]?.boolValue
        )
    }
}

/// One parsed item from the `$events` logical stream.
enum ForwardedRemoteEvent {
    case ready(RemoteEventsReady)
    case emit(name: String, args: [JSONValue])
    case waterfall(value: JSONValue, approval: ApprovalWaterfall?, userQuestion: UserQuestionWaterfall?)
    case cancel(eventId: String)
    case unknown

    static func decode(_ value: JSONValue) -> ForwardedRemoteEvent {
        switch value["type"]?.stringValue {
        case "ready":
            if let ready = try? value.decode(RemoteEventsReady.self) { return .ready(ready) }
            return .unknown
        case "emit":
            return .emit(name: value["event"]?.stringValue ?? "", args: value["args"]?.arrayValue ?? [])
        case "waterfall":
            return .waterfall(
                value: value,
                approval: ApprovalWaterfall.parse(value),
                userQuestion: UserQuestionWaterfall.parse(value)
            )
        case "cancel":
            if let eventId = value["eventId"]?.stringValue { return .cancel(eventId: eventId) }
            return .unknown
        default:
            return .unknown
        }
    }
}

// MARK: - Approval outcome vocabulary (§3.7)

enum ApprovalOutcome: String {
    case allowedOnce = "allowed-once"
    case rejected = "rejected"
    case cancelled = "cancelled"
    case unavailable = "unavailable"
}

/// Builds the unary `$events/result` args payload.
enum EventsResultArgs {
    static func outcome(clientId: String, eventId: String, value: ApprovalOutcome) -> [String: JSONValue] {
        [
            "clientId": .string(clientId),
            "eventId": .string(eventId),
            "outcome": .object([
                "kind": .string("result"),
                "value": .string(value.rawValue),
            ]),
        ]
    }

 /// Answer batch for a `user-questions/request` waterfall (§3.7.2):
 /// `outcome = {kind: "result", value: {answers: [...]}}`.
    static func userQuestionOutcome(
        clientId: String,
        eventId: String,
        answers: [UserQuestionAnswer]
    ) -> [String: JSONValue] {
        [
            "clientId": .string(clientId),
            "eventId": .string(eventId),
            "outcome": .object([
                "kind": .string("result"),
                "value": UserQuestionAnswersBatch(answers: answers).jsonValue(),
            ]),
        ]
    }

 /// Convenience for a raw answer batch.
    static func userQuestionOutcome(
        clientId: String,
        eventId: String,
        batch: UserQuestionAnswersBatch
    ) -> [String: JSONValue] {
        userQuestionOutcome(clientId: clientId, eventId: eventId, answers: batch.answers)
    }
}

// MARK: - Forwarded waterfall queue (T10)

/// Applies forwarded `$events` frames to the pending waterfall queues.
///
/// Extracted from `LinkService.handleRemoteEventItem` so the cancel semantics
/// stay unit-testable: when a turn is aborted/session cancelled the Host pushes
/// `{"type":"cancel","eventId":"…"}` and this must drop the matching approval
/// **and** user-question waterfall (the card then disappears, no error banner).
enum ForwardedWaterfallQueue {
    static func apply(
        _ event: ForwardedRemoteEvent,
        approvals: inout [ApprovalWaterfall],
        questions: inout [UserQuestionWaterfall]
    ) {
        switch event {
        case .waterfall(_, let approval, let userQuestion):
            if let approval {
                if let index = approvals.firstIndex(where: { $0.eventId == approval.eventId }) {
                    approvals[index] = approval
                } else {
                    approvals.append(approval)
                }
            }
            if let userQuestion {
                if let index = questions.firstIndex(where: { $0.eventId == userQuestion.eventId }) {
                    questions[index] = userQuestion
                } else {
                    questions.append(userQuestion)
                }
            }
        case .cancel(let eventId):
            approvals.removeAll { $0.eventId == eventId }
            questions.removeAll { $0.eventId == eventId }
        case .ready, .emit, .unknown:
            break
        }
    }
}

// MARK: - workspace/follow (§3.4)

struct WorkspaceBaseline: Decodable {
    var items: [WorkspaceItem]?
    var archivedSessionIds: [String]?
    var pinnedSessionIds: [String]?
}

struct WorkspaceItem: Decodable, Equatable {
    var workspaceId: String?
    var cwd: String?
    var title: String?
    var sessionIds: [String]?
}
