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
///
/// Task session-history (2026-10-22): the window is no longer capped at the newest
/// N messages. Older history is pulled in with the unary `session/page` endpoint
/// and merged into the front of the window by `prepend(page:)`; that keeps the
/// "newest first" fast paint (the follow snapshot is still phone-sized) while making
/// the *entire* session reachable by scrolling up. The two ends are tracked
/// separately:
///   - `lastSeq` / `cursor`: newest applied position (live stream / snapshot);
///   - `oldestSeq` / `hasMoreOlder`: front of the loaded window and whether the
///     Host still has events before it (`session/page` `hasMore`).
/// A reconnect snapshot therefore *preserves* the already-loaded older prefix
/// instead of throwing the user's scroll position away.
final class SessionJournal {

    enum Update: Equatable {
        /// Snapshot replaced the window; UI should rebuild from scratch.
        case snapshotReplaced
        /// A batch of contiguous events was applied.
        case eventsApplied([Int])
        /// Older `session/page` events were merged into the front of the window.
        /// Carries the seqs actually inserted (already-loaded seqs are skipped).
        case olderPrepended([Int])
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
    /// Front of the loaded window (nil while empty). Always `events.first?.seq`;
    /// kept as an explicit accessor because pagination keys `beforeSeq` off it.
    var oldestSeq: Int? { events.first?.seq }
    /// The Host still has events older than `oldestSeq` (last `session/page`
    /// `hasMore`, or the opening snapshot's `hasMore`). False = history start
    /// reached (or no snapshot yet).
    ///
    /// Task-6: this is **derived** and structurally terminal — false whenever the
    /// window reaches the session's first event or `hasReachedOldest` is set. A
    /// reconnect / background-fill snapshot can therefore never re-arm the "load
    /// earlier" entry after the user scrolled to turn 1.
    var hasMoreOlder: Bool { hasMoreOlderFlag && !hasReachedOldest }

    /// Sticky "the session's first event has been loaded": once true it never resets
    /// for the lifetime of the journal (task-6 acceptance: reaching the earliest
    /// event must terminate pagination for good, no matter which snapshot arrives
    /// afterwards — a reconnect/fill snapshot only describes the newest window and
    /// its `hasMore` must not resurrect the entry).
    private(set) var hasReachedOldest: Bool = false
    /// Raw paging state behind `hasMoreOlder` (only meaningful while the first
    /// event has not been reached).
    private var hasMoreOlderFlag: Bool = false
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
        // Task session-history: a reconnect / background-fill snapshot only covers
        // the newest message window. Keep the older events the user already loaded
        // (front-merged by `session/page`), otherwise every reconnect silently
        // throws the loaded history away ("cold start/reconnect must not regress to
        // the 40-message window").
        //
        // Only a *contiguous* prefix is kept: when the new snapshot's window starts
        // past the loaded events (a long gap between reconnects), the two ranges
        // would contain a hole; dropping the stale prefix and restarting pagination
        // from the snapshot is safer than rendering a window with a hidden gap.
        let previous = events
        var preserved: [SessionEvent] = []
        if let snapshotOldest = deduped.first?.seq {
            let older = previous.filter { $0.seq < snapshotOldest }
            if !older.isEmpty, let last = older.last, last.seq + 1 == snapshotOldest {
                preserved = older
            }
        }
        header = snapshot.header
        events = preserved + deduped
        cursor = snapshot.cursor
        lastSeq = snapshot.cursor
        projections = snapshot.projections?.values ?? [:]
        projectionsAsOfSeq = snapshot.projections?.asOfSeq
        assistantRevision = snapshot.assistantStream?.revision ?? 0
        hasMore = snapshot.hasMore ?? false
        // The snapshot's own `hasMore` only describes its message window. When a
        // loaded prefix was preserved, the paging state (whether *more* history
        // exists before it) is already known and must win; otherwise the snapshot is
        // the first word on older history. `markReachedOldestIfNeeded` keeps the
        // terminal state sticky (task-6): once seq 0 is loaded, a later snapshot with
        // `hasMore = true` must not re-arm the entry.
        if preserved.isEmpty {
            hasMoreOlderFlag = snapshot.hasMore ?? false
        }
        markReachedOldestIfNeeded()
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

    // MARK: - Older history (unary session/page)

    /// Merges one `session/page` result into the front of the window.
    ///
    /// Semantics (verified against the installed Host's session-controller
    /// `paginate`, 2026-10-22):
    ///   - `beforeSeq` is exclusive: a page holds events with `seq < beforeSeq`;
    ///   - records are *all* events of that seq range (turn/start, tool events, ...),
    ///     not just user/assistant messages;
    ///   - `hasMore` = the page's oldest offset > 0, i.e. the Host has still older
    ///     events than the page's first event.
    ///
    /// Merging never touches `lastSeq`/`cursor`/`events` after the front: the newest
    /// position and the live stream are unaffected by scrolling up. Pages arrive in
    /// descending seq order (each request uses the previous page's first seq as
    /// `beforeSeq`), are re-sorted defensively, and de-duplicated against the
    /// already-loaded window (the Host contract makes them disjoint; the dedupe only
    /// protects against re-requesting the same page).
    ///
    /// A page that yields no new events stops pagination (`hasMoreOlder = false`)
    /// so a Host-side inconsistency can never spin the caller in a request loop.
    @discardableResult
    func prepend(page: SessionPage) -> Update {
        let incoming = page.records.compactMap { record -> SessionEvent? in
            guard record.type == "event" else { return nil }
            return record.event
        }
        return prepend(events: incoming, hasMoreOlder: page.hasMore)
    }

    /// Cache-restore / test seam for `prepend(page:)` without wire records.
    @discardableResult
    func prepend(events incoming: [SessionEvent], hasMoreOlder: Bool) -> Update {
        let ascending = incoming.sorted { $0.seq < $1.seq }
        let currentOldest = events.first?.seq
        var merged: [SessionEvent] = []
        merged.reserveCapacity(events.count + ascending.count)
        var inserted: [Int] = []
        for event in ascending {
            // Defensive: the Host only returns events older than `beforeSeq`; keep
            // anything at/after the current front out of the prefix merge.
            if let currentOldest, event.seq >= currentOldest { continue }
            if let last = merged.last, event.seq <= last.seq { continue }
            merged.append(event)
            inserted.append(event.seq)
        }
        merged.append(contentsOf: events)
        events = merged
        if inserted.isEmpty {
            // Nothing new: stop pagination instead of asking the same page forever.
            hasMoreOlderFlag = false
        } else {
            hasMoreOlderFlag = hasMoreOlder
        }
        // `page.hasMore == false` is the Host telling us this page starts the log;
        // reaching seq 0 proves the same thing even if a (conservative/buggy) Host
        // still reports `hasMore = true` (task-6).
        if !hasMoreOlder {
            hasReachedOldest = true
        }
        markReachedOldestIfNeeded()
        return .olderPrepended(inserted)
    }

    /// Restores the paging state from an on-disk window cache (see
    /// `SessionWindowCachePayload`); never touches the event window itself.
    func setHasMoreOlder(_ value: Bool) {
        hasMoreOlderFlag = value
        if !value {
            hasReachedOldest = true
        }
        markReachedOldestIfNeeded()
    }

    /// Restores the sticky `hasReachedOldest` flag from a window cache (task-6).
    /// One-way: `false` is ignored — the journal only learns "reached the earliest
    /// event", it never forgets it.
    func setHasReachedOldest(_ value: Bool) {
        if value {
            hasReachedOldest = true
            hasMoreOlderFlag = false
        }
        markReachedOldestIfNeeded()
    }

    /// Window mutations that can move the front call this: once `events.first` is
    /// the session's first event, pagination is over for good (sticky).
    private func markReachedOldestIfNeeded() {
        guard events.first?.seq == 0 else { return }
        hasReachedOldest = true
        hasMoreOlderFlag = false
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

/// Result of the unary `session/page` endpoint (older history).
///
/// Wire shape verified against the installed Host's session-controller
/// (`ApiSessionHistory.page`, 2026-10-22):
/// `{records: [{"type":"event","event":{...}}], hasMore: Bool}`.
///
/// Request semantics (same source): `throughSeq` is the inclusive log cut taken
/// from the corresponding `session/follow` opening frame (`snapshot.cursor`);
/// `beforeSeq` is **exclusive** (`end = min(throughSeq + 1, beforeSeq ?? …)`), so
/// the next request uses the current oldest loaded seq to walk strictly backwards.
struct SessionPage: Decodable {
    var records: [SnapshotRecord]
    var hasMore: Bool
}
