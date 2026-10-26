import Foundation

/// 一条「流式准备中」的工具调用（task-5）。
///
/// `session/follow` 的 process-local `assistant-stream` 会在磁盘事件落地
/// （`tool/call`）之前就送来 `tool-call-delta`：App 用它提前渲染「正在调用 X /
/// 正在生成参数」，否则一次长工具调用期间详情页只有思考文本、看不到工具步骤。
///
/// 同一轮 assistant 消息里的并行工具调用用 `index` 区分（流内稳定）；`id` 由
/// `index` 派生，保证参数增长时 SwiftUI 的行身份不变（不重建行）。`callId` /
/// `name` 可能晚于首个 `argumentsDelta` 到达，缺失时先按 `index` 合并、到达后补上。
struct LiveToolPreparation: Equatable, Identifiable {
 /// assistant 消息内的工具调用块序号（流内稳定，多工具并行时用于区分）。
    var index: Int
 /// Host 调用 id（`tool-call-delta.id`）；`tool/call` 落地时用于精确结算。
    var callId: String? = nil
 /// 工具名（`tool-call-delta.name`），可能晚到。
    var name: String?
 /// 已累积的 `argumentsDelta` 原文拼接（不保证是合法 JSON，UI 显示时应容错）。
    var arguments: String

 /// SwiftUI 行身份：按 `index` 稳定，参数增长不换行。
    var id: String { "live-prep-\(index)" }
}

/// Applies session/follow frames to a local window.
///
/// Implements the DSH browser client's journal alignment algorithm
/// (<internal-doc> §4.3):
/// - snapshot replaces the local window and sets lastSeq = cursor
/// - event with seq <= lastSeq is a duplicate and is dropped
/// - event with seq == lastSeq + 1 is appended
/// - event with seq > lastSeq + 1 signals a hole; M1 policy is "snapshot rebuild"
/// (drop the window, re-open session/follow) rather than session/page patching
/// - assistant-stream revision must increment by exactly 1, otherwise the carrier
/// is considered broken and the stream must be re-opened.
///
/// Task session-history: the window is no longer capped at the newest
/// N messages. Older history is pulled in with the unary `session/page` endpoint
/// and merged into the front of the window by `prepend(page:)`; that keeps the
/// "newest first" fast paint (the follow snapshot is still phone-sized) while making
/// the *entire* session reachable by scrolling up. The two ends are tracked
/// separately:
/// - `lastSeq` / `cursor`: newest applied position (live stream / snapshot);
/// - `oldestSeq` / `hasMoreOlder`: front of the loaded window and whether the
/// Host still has events before it (`session/page` `hasMore`).
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

 /// task-5: 实时思考文本（`assistant-stream` 的 `reasoning-delta` 累积）。
 ///
 /// 与 `liveAssistantText` 同生命周期：start / 新 snapshot 时清空，
 /// 持久事件 `assistant/message` / `turn/end` 结算时清空（磁盘消息是唯一真源）。
    private(set) var liveReasoningText: String = ""

 /// task-5: 实时「准备中」的工具调用（`tool-call-delta` 按 `index` 合并）。
 ///
 /// 持久 `tool/call` 到达时移除对应项；`assistant/message`/`turn/end`/
 /// snapshot 结算时清空。列表按 `index` 升序（并行工具调用按调用顺序渲染）。
    private(set) var liveToolPreparations: [LiveToolPreparation] = []

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
        var droppedPrefixWhilePreserving = false
        if let snapshotOldest = deduped.first?.seq {
            let older = previous.filter { $0.seq < snapshotOldest }
            if !older.isEmpty, let last = older.last, last.seq + 1 == snapshotOldest {
 // A previous replay/cache could have left an internal hole in the
 // loaded prefix. Keep only the gap-free suffix that is adjacent to the
 // snapshot window: carrying the hole over hides whole turns (turn 1
 // keeps "running", turns 2–7 vanish) and can never be repaired by
 // paging, which only walks further back from the front.
                preserved = Self.contiguousSuffix(of: older)
                droppedPrefixWhilePreserving = preserved.count < older.count
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
        if droppedPrefixWhilePreserving {
 // The discarded prefix must be pulled again (a hole can only be refilled
 // from the outside in, never from the current front).
            markOlderHistoryUnloaded()
        }
        markReachedOldestIfNeeded()
        snapshotCount += 1
 // task-5: a (re)opened snapshot is authoritative — process-local previews
 // can never be trusted across a window rebuild (the stream is re-opened
 // from a baseline revision and the new window already has the committed
 // messages the previews were standing in for).
        liveAssistantText = ""
        liveReasoningText = ""
        liveToolPreparations = []
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
 // `{lastUsed, next: pending?? lastUsed}` and only ships with snapshots).
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
 // the same text twice. task-5: the reasoning preview and the tool-call
 // preparations live on the same process-local timeline and are settled by
 // the same durable events.
        if event.type == "assistant/message" || event.type == "turn/end" {
            liveAssistantText = ""
            liveReasoningText = ""
            liveToolPreparations = []
        }
 // task-5: the durable tool/call supersedes its streamed preparation.
        if event.type == "tool/call" {
            settleLiveToolPreparation(
                callId: event.data?["callId"]?.stringValue,
                name: event.data?["name"]?.stringValue,
                arguments: event.data?["arguments"]?.stringValue
            )
        }
        return .eventsApplied([event.seq])
    }

 // MARK: - Older history (unary session/page)

 /// Merges one `session/page` result into the front of the window.
 ///
 /// Semantics (verified against the installed Host's session-controller
 /// `paginate`):
 /// - `beforeSeq` is exclusive: a page holds events with `seq < beforeSeq`;
 /// - records are *all* events of that seq range (turn/start, tool events,...),
 /// not just user/assistant messages;
 /// - `hasMore` = the page's oldest offset > 0, i.e. the Host has still older
 /// events than the page's first event.
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
 ///
 /// Task-7: a page is only merged when it is a **gap-free block adjacent to the
 /// current front** (`candidates.last.seq + 1 == events.first.seq`). The Host
 /// guarantees this for a request keyed on the current oldest seq, but a stale page
 /// (arrived after a snapshot jump) or a corrupt reply must never punch a hole in
 /// the window: a hole hides whole turns and can not be repaired by further paging
 /// (which only walks further back). Rejected pages keep `hasMoreOlder = true` so
 /// the next scroll refetches from the new front.
    @discardableResult
    func prepend(events incoming: [SessionEvent], hasMoreOlder: Bool) -> Update {
        let ascending = incoming.sorted { $0.seq < $1.seq }
        let currentOldest = events.first?.seq
        var candidates: [SessionEvent] = []
        candidates.reserveCapacity(ascending.count)
        for event in ascending {
 // Defensive: the Host only returns events older than `beforeSeq`; keep
 // anything at/after the current front out of the prefix merge.
            if let currentOldest, event.seq >= currentOldest { continue }
            if let last = candidates.last, event.seq <= last.seq { continue }
            candidates.append(event)
        }
        guard !candidates.isEmpty else {
 // Nothing older to merge. Two different cases:
 // - the page carried no events at all: the Host claimed older history
 // but handed us nothing, so stop instead of asking the same page
 // forever;
 // - the page carried events, but every one of them is at/after the
 // current front (a stale page that was requested *before* a snapshot
 // jump): that is a non-adjacent page and must be rejected like one,
 // keeping hasMoreOlder = true so the paging entry survives and the
 // next request walks back from the new front (task-7).
            if incoming.isEmpty {
                hasMoreOlderFlag = false
                markReachedOldestIfNeeded()
            } else {
                hasMoreOlderFlag = true
            }
            return .olderPrepended([])
        }
        let blockContiguous = zip(candidates, candidates.dropFirst())
            .allSatisfy { $0.seq + 1 == $1.seq }
        let adjacentToFront = currentOldest.map { candidates[candidates.count - 1].seq + 1 == $0 } ?? false
        guard blockContiguous, adjacentToFront else {
 // Reject the page as a whole: keep the window (and the paging flag) intact
 // so the caller can retry with a fresh `beforeSeq`.
            hasMoreOlderFlag = true
            return .olderPrepended([])
        }
        events = candidates + events
        hasMoreOlderFlag = hasMoreOlder
 // `page.hasMore == false` is the Host telling us this page starts the log;
 // reaching seq 0 proves the same thing even if a (conservative/buggy) Host
 // still reports `hasMore = true` (task-6).
        if !hasMoreOlder {
            hasReachedOldest = true
        }
        markReachedOldestIfNeeded()
        return .olderPrepended(candidates.map(\.seq))
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

 // MARK: - Window continuity (task-7)

 /// True when every neighbouring pair in the window is exactly +1 (no holes).
 /// A hole is a hard rendering bug: turn grouping loses intermediate turns and a
 /// turn whose `turn/end` fell into the hole looks "running" forever.
    var isWindowContiguous: Bool {
        guard events.count > 1 else { return true }
        for index in 1..<events.count where events[index].seq != events[index - 1].seq + 1 {
            return false
        }
        return true
    }

 /// Keeps only the maximal gap-free suffix of the window (front repair: a hole can
 /// only be refilled from the outside in, never by paging from the current front).
 /// Never touches `lastSeq`/`cursor`; returns the number of dropped oldest events.
    @discardableResult
    func trimToContiguousSuffix() -> Int {
        guard events.count > 1 else { return 0 }
        var start = events.count - 1
        while start > 0, events[start].seq == events[start - 1].seq + 1 {
            start -= 1
        }
        return dropOldestPrefix(start)
    }

 /// Drops the `count` oldest events (front repair). Never touches
 /// `lastSeq`/`cursor`.
    @discardableResult
    func dropOldestPrefix(_ count: Int) -> Int {
        let dropped = max(0, min(count, events.count))
        guard dropped > 0 else { return 0 }
        events.removeFirst(dropped)
        return dropped
    }

 /// Repair hook: the loaded front is no longer usable (a hole was discarded), so
 /// older history has to be pulled again. Clears the sticky terminal state — the
 /// window no longer contains the first event.
    func markOlderHistoryUnloaded() {
        hasReachedOldest = false
        hasMoreOlderFlag = true
    }

 /// Longest gap-free suffix of an ascending event list.
    static func contiguousSuffix(of ascending: [SessionEvent]) -> [SessionEvent] {
        guard !ascending.isEmpty else { return [] }
        var start = ascending.count - 1
        while start > 0, ascending[start].seq == ascending[start - 1].seq + 1 {
            start -= 1
        }
        return Array(ascending[start...])
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
            liveReasoningText = ""
            liveToolPreparations = []
        case "chunk":
 // task-5: 一个 chunk 只携带一种增量；三路各自累积（思考/文本/工具参数）。
            if let text = Self.textDelta(from: frame.chunk) {
                liveAssistantText += text
            }
            if let reasoning = Self.reasoningDelta(from: frame.chunk) {
                liveReasoningText += reasoning
            }
            if let toolCall = Self.toolCallDelta(from: frame.chunk) {
                mergeLiveToolCallDelta(toolCall)
            }
        case "end":
 // task-5: 刻意保留两路实时预览（不清空）。`end` 只是流式帧的收尾，
 // 真正的结算事件（`assistant/message` / `tool/call` / `turn/end`）
 // 紧随其后；若在 end 就清空，UI 会在两帧之间闪一次空。
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

 // MARK: - 实时思考 / 工具参数（task-5）

 /// 一条 `tool-call-delta` chunk（已验证的 Host 形状：
 /// `{type:"tool-call-delta", index, id, name?, argumentsDelta}`）。
    struct ToolCallDelta: Equatable {
        var index: Int
        var callId: String?
        var name: String?
        var argumentsDelta: String
    }

 /// 从 chunk 中提取思考（reasoning）增量；不是思考帧时返回 nil。
 ///
 /// 已验证的 chunk 类型是 `reasoning-delta{text}`；其余别名只是同一语义的
 /// Provider 变体（与 `textDelta` 的容错策略一致）。
    static func reasoningDelta(from chunk: JSONValue?) -> String? {
        guard let chunk else { return nil }
        let type = chunk["type"]?.stringValue ?? ""
        switch type {
        case "reasoning", "reasoning-delta", "thinking", "thinking-delta":
            return chunk["text"]?.stringValue
                ?? chunk["delta"]?.stringValue
                ?? chunk["reasoning"]?.stringValue
        default:
            if let delta = chunk["delta"], delta["type"]?.stringValue != nil {
                return reasoningDelta(from: delta)
            }
            return nil
        }
    }

 /// 从 chunk 中提取工具调用增量；不是工具调用帧时返回 nil。
    static func toolCallDelta(from chunk: JSONValue?) -> ToolCallDelta? {
        guard let chunk else { return nil }
        let type = chunk["type"]?.stringValue ?? ""
        guard type == "tool-call-delta" || type == "tool_call_delta" else {
            if let delta = chunk["delta"], delta["type"]?.stringValue != nil {
                return toolCallDelta(from: delta)
            }
            return nil
        }
        guard let index = chunk["index"]?.int else { return nil }
        return ToolCallDelta(
            index: index,
            callId: chunk["id"]?.stringValue,
            name: chunk["name"]?.stringValue,
            argumentsDelta: chunk["argumentsDelta"]?.stringValue
                ?? chunk["arguments_delta"]?.stringValue
                ?? ""
        )
    }

 /// 把一条 `tool-call-delta` 按 `index` 合并进 `liveToolPreparations`：
 /// 参数增量拼接，晚到的 `id` / `name` 补上。
    private func mergeLiveToolCallDelta(_ delta: ToolCallDelta) {
        if let position = liveToolPreparations.firstIndex(where: { $0.index == delta.index }) {
            var preparation = liveToolPreparations[position]
            preparation.arguments += delta.argumentsDelta
            if let callId = delta.callId, !callId.isEmpty { preparation.callId = callId }
            if let name = delta.name, !name.isEmpty { preparation.name = name }
            liveToolPreparations[position] = preparation
            return
        }
        let preparation = LiveToolPreparation(
            index: delta.index,
            callId: delta.callId.flatMap { $0.isEmpty ? nil : $0 },
            name: delta.name.flatMap { $0.isEmpty ? nil : $0 },
            arguments: delta.argumentsDelta
        )
 // 并行工具调用的 delta 会交错到达（0,1,0,…）：按 index 有序插入，
 // UI 按调用顺序渲染而不是首个 delta 的到达顺序。
        let insertion = liveToolPreparations.firstIndex { $0.index > delta.index }
            ?? liveToolPreparations.endIndex
        liveToolPreparations.insert(preparation, at: insertion)
    }

 /// 持久 `tool/call` 落地时结算对应的流式准备项。
 ///
 /// 匹配顺序：
 /// 1. Host `callId` 精确匹配（`tool-call-delta.id` 已到达时最可靠）；
 /// 2. 工具名 + 原始参数串匹配（Provider 先送参数、后送 identity 时 id 缺失）；
 /// 3. 带 `callId` 却都匹配不上：整体清空。此时流式形状已偏离已验证契约，
 /// 留下「准备中」行会永久渲染一个幽灵步骤；磁盘 `tool/call` 行才是权威。
 /// 事件不带 `callId`（旧形状）时保守处理：匹配不上就保留，等 turn 结算清空。
    private func settleLiveToolPreparation(callId: String?, name: String?, arguments: String?) {
        guard !liveToolPreparations.isEmpty else { return }
        if let callId,
           let position = liveToolPreparations.firstIndex(where: { $0.callId == callId }) {
            liveToolPreparations.remove(at: position)
            return
        }
        if let name,
           let position = liveToolPreparations.firstIndex(where: {
               $0.name == name && $0.arguments == (arguments ?? "")
           }) {
            liveToolPreparations.remove(at: position)
            return
        }
        guard callId != nil else { return }
        liveToolPreparations.removeAll()
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
/// (`ApiSessionHistory.page`):
/// `{records: [{"type":"event","event":{...}}], hasMore: Bool}`.
///
/// Request semantics (same source): `throughSeq` is the inclusive log cut taken
/// from the corresponding `session/follow` opening frame (`snapshot.cursor`);
/// `beforeSeq` is **exclusive** (`end = min(throughSeq + 1, beforeSeq?? …)`), so
/// the next request uses the current oldest loaded seq to walk strictly backwards.
struct SessionPage: Decodable {
    var records: [SnapshotRecord]
    var hasMore: Bool
}
