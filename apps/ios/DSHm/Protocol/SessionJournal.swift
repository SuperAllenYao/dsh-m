import Foundation

/// Applies session/follow frames to a local window.
///
/// Implements the DSH browser client's journal alignment algorithm
/// (docs/design/remote-protocol.zh.md §4.3):
///   - snapshot replaces the local window and sets lastSeq = cursor
///   - event with seq <= lastSeq is a duplicate and is dropped
///   - event with seq == lastSeq + 1 is appended
///   - event with seq > lastSeq + 1 signals a hole; M1 policy is "snapshot rebuild"
///     (drop the window, re-open session/follow) rather than session/page patching
///   - assistant-stream revision must increment by exactly 1, otherwise the carrier
///     is considered broken and the stream must be re-opened.
final class SessionJournal {

    enum Update: Equatable {
        /// Snapshot replaced the window; UI should rebuild from scratch.
        case snapshotReplaced
        /// A batch of contiguous events was applied.
        case eventsApplied([Int])
        /// Duplicate event (seq <= lastSeq) ignored.
        case duplicate(Int)
        /// Sequence hole detected. Caller must rebuild from a new snapshot.
        case gap(expected: Int, received: Int)
        /// assistant-stream revision skipped. Caller must re-open the stream.
        case assistantRevisionGap(expected: Int, received: Int)
        /// assistant-stream frame applied (revision ok).
        case assistantStreamProgress(Int)
        /// Unknown/unhandled snapshot record type (ignored).
        case ignored
    }

    private(set) var header: SessionHeader?
    private(set) var events: [SessionEvent] = []
    private(set) var lastSeq: Int = -1
    private(set) var projections: [String: JSONValue] = [:]
    private(set) var projectionsAsOfSeq: Int64?
    private(set) var assistantRevision: Int = 0
    private(set) var hasMore: Bool = false
    private(set) var snapshotCount: Int = 0

    /// Latest live assistant text assembled from assistant-stream text deltas.
    private(set) var liveAssistantText: String = ""

    var title: String? { projections["title"]?.stringValue }
    var permissionsValue: String? { projections["permissions"]?["currentValue"]?.stringValue }
    var todos: [JSONValue]? { projections["todos"]?.arrayValue }
    var plan: JSONValue? { projections["plan"] }
    var modelSelection: JSONValue? { projections["modelSelection"] }
    var workingDirectory: String? { projections["workingDirectory"]?.stringValue }
    var turnOutline: [JSONValue]? { projections["turnOutline"]?.arrayValue }
    var userQuestions: JSONValue? { projections["userQuestions"] }
    var goal: JSONValue? { projections["goal"] }
    var sessionListMetadata: JSONValue? { projections["sessionListMetadata"] }
    var subagentCatalog: [JSONValue]? { projections["subagentCatalog"]?.arrayValue }

    /// v5.5 §14.5: context-window usage projection (absent until a provider
    /// reports usage; see `ContextPressureValue`).
    var contextPressure: ContextPressureValue? {
        ContextPressureValue(projection: projections["contextPressure"])
    }

    func projection(_ key: String) -> JSONValue? { projections[key] }

    /// Replaces the window with a fresh snapshot.
    @discardableResult
    func apply(snapshot: SessionSnapshot) -> Update {
        var nextEvents: [SessionEvent] = []
        nextEvents.reserveCapacity(snapshot.records.count)
        for record in snapshot.records where record.type == "event" {
            if let event = record.event {
                nextEvents.append(event)
            }
        }
        nextEvents.sort { $0.seq < $1.seq }
        // Defensive: drop duplicate seq values inside a single snapshot.
        var deduped: [SessionEvent] = []
        deduped.reserveCapacity(nextEvents.count)
        for event in nextEvents {
            if let last = deduped.last, event.seq <= last.seq { continue }
            deduped.append(event)
        }
        header = snapshot.header
        events = deduped
        cursor = snapshot.cursor
        lastSeq = snapshot.cursor
        projections = snapshot.projections?.values ?? [:]
        projectionsAsOfSeq = snapshot.projections?.asOfSeq
        assistantRevision = snapshot.assistantStream?.revision ?? 0
        hasMore = snapshot.hasMore ?? false
        snapshotCount += 1
        liveAssistantText = ""
        return .snapshotReplaced
    }

    private(set) var cursor: Int = -1

    /// Applies one incremental event.
    @discardableResult
    func apply(event: SessionEvent) -> Update {
        if event.seq <= lastSeq {
            return .duplicate(event.seq)
        }
        guard event.seq == lastSeq + 1 else {
            return .gap(expected: lastSeq + 1, received: event.seq)
        }
        events.append(event)
        lastSeq = event.seq
        // Keep a single projection snapshot per list operation; per-event projections
        // are not emitted by session/follow (only snapshot carries them).
        if event.type == "session/title", let title = event.data?["title"]?.stringValue {
            projections["title"] = .string(title)
        }
        if event.type == "permission/preset", let preset = event.data?["preset"]?.stringValue {
            var permissions = projections["permissions"]?.objectValue ?? [:]
            permissions["currentValue"] = .string(preset)
            projections["permissions"] = .object(permissions)
        }
        if event.type == "todo/write", let todos = event.data?["todos"] {
            projections["todos"] = todos
        }
        // Desktop-side model switch: `session/follow` never pushes per-event
        // projections, so the Host's `model/selection` event is the only live
        // signal that a new selection was installed (the projection view is
        // `{lastUsed, next: pending ?? lastUsed}` and only ships with snapshots).
        // Patching `next` makes the status strip and the model sheet show the
        // desktop's choice immediately instead of keeping the stale snapshot.
        if event.type == "model/selection",
           let data = event.data?.objectValue,
           let provider = data["provider"]?.stringValue, !provider.isEmpty,
           let model = data["model"]?.stringValue, !model.isEmpty {
            var selected: [String: JSONValue] = [
                "provider": .string(provider),
                "model": .string(model),
            ]
            if let effort = data["reasoningEffort"]?.stringValue, !effort.isEmpty {
                selected["reasoningEffort"] = .string(effort)
            }
            var projection = projections["modelSelection"]?.objectValue ?? [:]
            projection["next"] = .object(selected)
            projections["modelSelection"] = .object(projection)
        }
        // process-local assistant-stream deltas are superseded by the committed
        // assistant/message (or the turn ending): clear them to avoid rendering
        // the same text twice.
        if event.type == "assistant/message" || event.type == "turn/end" {
            liveAssistantText = ""
        }
        return .eventsApplied([event.seq])
    }

    /// Applies an assistant-stream frame; enforces strictly monotonic revision.
    @discardableResult
    func apply(assistantStream frame: AssistantStreamFrame) -> Update {
        if frame.revision <= assistantRevision {
            return .duplicate(frame.revision)
        }
        guard frame.revision == assistantRevision + 1 else {
            return .assistantRevisionGap(expected: assistantRevision + 1, received: frame.revision)
        }
        assistantRevision = frame.revision
        switch frame.type {
        case "start":
            liveAssistantText = ""
        case "chunk":
            if let text = Self.textDelta(from: frame.chunk) {
                liveAssistantText += text
            }
        case "end":
            break
        default:
            break
        }
        return .assistantStreamProgress(frame.revision)
    }

    /// assistant-stream chunk shapes differ by provider; extract a text delta when present.
    static func textDelta(from chunk: JSONValue?) -> String? {
        guard let chunk else { return nil }
        let type = chunk["type"]?.stringValue ?? ""
        switch type {
        case "text", "text-delta", "content", "content-delta", "delta":
            return chunk["text"]?.stringValue
                ?? chunk["delta"]?.stringValue
                ?? chunk["content"]?.stringValue
        default:
            // Some providers nest the delta: {type:"chunk", delta:{type:"text", text:"..."}}
            if let delta = chunk["delta"] {
                return textDelta(from: delta)
            }
            return nil
        }
    }

    func event(type: String) -> SessionEvent? {
        events.last { $0.type == type }
    }

    func events(after seq: Int) -> [SessionEvent] {
        events.filter { $0.seq > seq }
    }
}
