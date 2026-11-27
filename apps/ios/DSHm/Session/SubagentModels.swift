import Foundation
import SwiftUI

// MARK: - Subagent catalog / session models (v5.4 §1-§3, task-13)

/// Catalog mode of one subagent session (`projections.subagentCatalog[].mode`).
enum SubagentMode: String, Equatable, Sendable {
    case oneShot = "one-shot"
    case external
    case continuable
    case unknown

    init(raw: String?) {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "one-shot", "oneshot", "one_shot": self = .oneShot
        case "external": self = .external
        case "continuable", "continue", "continuable-session": self = .continuable
        default: self = .unknown
        }
    }

    var displayLabel: String {
        switch self {
        case .oneShot: return "一次性"
        case .external: return "外部"
        case .continuable: return "连续"
        case .unknown: return "未知"
        }
    }

 /// Localized display text (canonical `displayLabel` stays Chinese for tests).
    var localizedDisplayLabel: String {
        switch self {
        case .oneShot: return L10n.t("一次性")
        case .external: return L10n.t("外部")
        case .continuable: return L10n.t("连续")
        case .unknown: return L10n.t("未知")
        }
    }

 /// Only continuable subagents accept `subagents/prompt` from the parent.
    var isContinuable: Bool { self == .continuable }

 /// `session/follow` address mode token (`unknown` lets the Host resolve it).
    var addressMode: String {
        switch self {
        case .oneShot: return "one-shot"
        case .external: return "external"
        case .continuable: return "continuable"
        case .unknown: return "unknown"
        }
    }
}

/// Context carried by a subagent session detail opened from its parent session.
struct SubagentSessionContext: Equatable, Sendable, Hashable {
    var parentSessionId: String
    var childSessionId: String
    var mode: SubagentMode

    init(parentSessionId: String, childSessionId: String, modeRaw: String?) {
        self.parentSessionId = parentSessionId
        self.childSessionId = childSessionId
        self.mode = SubagentMode(raw: modeRaw)
    }

    var followAddress: SessionFollowAddress {
        .subagent(parentSessionId: parentSessionId, childSessionId: childSessionId, mode: mode.addressMode)
    }

 /// One-shot / external subagents are read-only from the parent (no prompt).
    var isReadOnly: Bool { !mode.isContinuable }

    var readOnlyReason: String? {
        guard isReadOnly else { return nil }
        return L10n.f("%@子代理只读，不能从手机发送消息", mode.localizedDisplayLabel)
    }
}

/// Status of one row in the subagent half-sheet list.
enum SubagentRowStatus: Equatable {
    case running
    case waiting
    case idle

    var label: String {
        switch self {
        case .running: return "运行中"
        case .waiting: return "等待作答"
        case .idle: return "空闲"
        }
    }

    var localizedLabel: String {
        switch self {
        case .running: return L10n.t("运行中")
        case .waiting: return L10n.t("等待作答")
        case .idle: return L10n.t("空闲")
        }
    }

 /// v5.4 status scale: running = orange-amber, waiting = green, idle = neutral.
    var color: Color {
        switch self {
        case .running: return Theme.Palette.running
        case .waiting: return Theme.Palette.waiting
        case .idle: return Theme.Palette.textSecondary
        }
    }
}

/// Runtime facts for one subagent, joined from `session/list` + approval state.
struct SubagentRuntime: Equatable {
    var sessionId: String
    var isRunning: Bool
    var isWaitingAnswer: Bool
    var lastActivityAt: Int64?
    var agentAvailable: Bool?

    var status: SubagentRowStatus {
        SubagentStatusResolver.resolve(isRunning: isRunning, isWaitingAnswer: isWaitingAnswer)
    }
}

enum SubagentStatusResolver {
 /// Priority: waiting for a human (approval/user question) > running > idle.
    static func resolve(isRunning: Bool, isWaitingAnswer: Bool) -> SubagentRowStatus {
        if isWaitingAnswer { return .waiting }
        if isRunning { return .running }
        return .idle
    }
}

/// Aggregate state of the bottom `子代理 · N` capsule.
struct SubagentCapsuleState: Equatable {
    var count: Int
    var runningCount: Int
    var waitingCount: Int

    static func resolve(catalogCount: Int, runtimes: [SubagentRuntime]) -> SubagentCapsuleState {
        SubagentCapsuleState(
            count: catalogCount,
            runningCount: runtimes.filter(\.isRunning).count,
            waitingCount: runtimes.filter(\.isWaitingAnswer).count
        )
    }

    var isVisible: Bool { count > 0 }
 /// Breathing accent pulse while at least one child runs; static grey otherwise.
    var isPulsing: Bool { runningCount > 0 }
    var dotColor: Color { isPulsing ? Theme.Palette.accent : Theme.Palette.textTertiary }
    var accessibilityValue: String {
        if runningCount > 0 { return "running:\(runningCount)" }
        return "idle"
    }
}

/// Joins the parent `subagentCatalog` with `session/list` rows.
enum SubagentRuntimeBuilder {
    static func make(
        catalog: [SubagentCatalogEntry],
        sessions: [SessionListItem],
        pendingApprovalAgentIds: Set<String> = []
    ) -> [String: SubagentRuntime] {
        let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
        var runtimes: [String: SubagentRuntime] = [:]
        for entry in catalog {
            runtimes[entry.id] = runtime(
                for: entry,
                item: byId[entry.id],
                pendingApprovalAgentIds: pendingApprovalAgentIds
            )
        }
        return runtimes
    }

    static func runtime(
        for entry: SubagentCatalogEntry,
        item: SessionListItem?,
        pendingApprovalAgentIds: Set<String> = []
    ) -> SubagentRuntime {
        let isWaiting = item?.hasActiveUserQuestions == true || pendingApprovalAgentIds.contains(entry.id)
        return SubagentRuntime(
            sessionId: entry.id,
            isRunning: item?.isRunning == true,
            isWaitingAnswer: isWaiting,
            lastActivityAt: item?.lastPromptAt ?? item?.updatedAt ?? entry.createdAt,
            agentAvailable: item?.agentAvailable
        )
    }
}

/// Live child-subagent discovery (v0.2.0): the parent journal snapshot is the
/// only carrier of the `subagentCatalog` projection, so a child that starts while
/// the detail is already open would otherwise stay invisible until the detail is
/// reopened. `session/list` (already fetched for the runtime join) reports the
/// same children (`origin == "subagent"` + `parentSessionId`), so merge them in.
enum SubagentCatalogMerge {
 /// Children of `parentSessionId`, in list order. The label comes from the
 /// child's own list title; the capsule and the half-sheet fall back to the
 /// short id when the host reports none.
    static func discovered(
        sessions: [SessionListItem],
        parentSessionId: String
    ) -> [SubagentCatalogEntry] {
 // Explicit result type: `compactMap`'s generic result can no longer be
 // inferred once the multi-statement closure stops being the `return`
 // expression of this function.
        let entries: [SubagentCatalogEntry] = sessions.compactMap { item in
            guard item.parentSessionId == parentSessionId, item.isSubagent else { return nil }
            return SubagentCatalogEntry(
                id: item.sessionId,
                createdAt: item.updatedAt,
                mode: nil,
                label: item.title
            )
        }
 // DD-08: this batch is what `merge` appends (in this order), so the display
 // key is stamped here, right before the merge. The merge output order is not
 // touched. Stamping is first-sight only and idempotent (`AC-03`).
        SubagentCatalogFirstSeenStore.shared.recordDiscoveredBatch(
            parentSessionId: parentSessionId,
            childIds: entries.map(\.id),
            now: Int64(Date().timeIntervalSince1970 * 1000)
        )
        return entries
    }

 /// Projection entries win (they carry the host's mode/label); discovered
 /// children append so a new child is visible before the next snapshot.
    static func merge(
        projection: [SubagentCatalogEntry],
        discovered: [SubagentCatalogEntry]
    ) -> [SubagentCatalogEntry] {
        var seen = Set(projection.map(\.id))
        var merged = projection
        for entry in discovered where !seen.contains(entry.id) {
            seen.insert(entry.id)
            merged.append(entry)
        }
        return merged
    }
}

// MARK: - Catalog display ordering (DD-08 / AC-01 / AC-03)

/// Where one merged catalog entry came from. The projection carries the host's
/// real creation time; a live-discovered child is built from `session/list`
/// with the child's last activity time filled into `createdAt`, so that value
/// must never become its display sort key.
enum SubagentCatalogEntrySource: Equatable {
    case projected
    case discovered
}

extension SubagentCatalogEntry {
 /// The projection entry format always carries `mode` (`FlowModels.swift`,
 /// `init?(json:)`), and `SubagentCatalogMerge.merge` keeps the projection
 /// entry when ids collide. An entry that still has no mode after merging is
 /// therefore one appended by `SubagentCatalogMerge.discovered` — the source
 /// marker for the sort key, without a second stored field.
    var catalogSource: SubagentCatalogEntrySource {
        mode == nil ? .discovered : .projected
    }
}

/// App-lifecycle store of the "first discovered" timestamps live-discovered
/// subagents are sorted by (DD-08). Keyed by parent session id + child session
/// id: leaving the session detail keeps the values, a child that leaves the
/// parent's catalog is pruned, and App termination releases everything. Memory
/// only — nothing is persisted.
final class SubagentCatalogFirstSeenStore {
    static let shared = SubagentCatalogFirstSeenStore()

    private let lock = NSLock()
    private var firstSeenByChild: [String: Int64] = [:]
    private var parentByChild: [String: String] = [:]
    private var shownAsDiscovered: Set<String> = []

 /// Records the children `session/list` reports for one parent. A child is
 /// stamped on its first sighting only, so its key never moves afterwards
 /// (AC-03); inside one batch the values decrease with the batch order, which
 /// is the order `merge` appends them in, so a batch keeps its relative order.
 /// Children no longer in the catalog are pruned here.
    func recordDiscoveredBatch(parentSessionId: String, childIds: [String], now: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let alive = Set(childIds)
        for (childId, childParent) in parentByChild
        where childParent == parentSessionId && !alive.contains(childId) {
            firstSeenByChild[childId] = nil
            parentByChild[childId] = nil
            shownAsDiscovered.remove(childId)
        }
        for (offset, childId) in childIds.enumerated() where firstSeenByChild[childId] == nil {
            firstSeenByChild[childId] = now - Int64(offset)
            parentByChild[childId] = parentSessionId
        }
    }

 /// Marks the entries painted as live-discovered. A projection entry that
 /// later replaces one keeps its recorded first-seen key, so the row does not
 /// jump when the snapshot catches up.
    func noteDisplayed(_ entries: [SubagentCatalogEntry]) {
        lock.lock()
        defer { lock.unlock() }
        for entry in entries where entry.catalogSource == .discovered {
            shownAsDiscovered.insert(entry.id)
        }
    }

 /// First-seen lookup for the display key: a live-discovered entry always uses
 /// the recorded batch value; a projection entry prefers it only when it
 /// replaced a live-discovered one, otherwise `createdAt` stays authoritative.
    func firstSeen(for entry: SubagentCatalogEntry) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        switch entry.catalogSource {
        case .discovered:
            return firstSeenByChild[entry.id]
        case .projected:
            return shownAsDiscovered.contains(entry.id) ? firstSeenByChild[entry.id] : nil
        }
    }

 /// Test hook: the store is App-lifetime state, so tests start from reset.
    func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        firstSeenByChild.removeAll()
        parentByChild.removeAll()
        shownAsDiscovered.removeAll()
    }
}

/// Display ordering of the subagent half-sheet (DD-08 / AC-01): descending by
/// `firstSeen ?? createdAt`, ties by `id` ascending. Status and last activity
/// never participate, so a status flip cannot move a row (AC-03). Pure: the
/// caller supplies the first-seen lookup.
enum SubagentCatalogOrder {
    static func ordered(
        _ entries: [SubagentCatalogEntry],
        firstSeen: (SubagentCatalogEntry) -> Int64?
    ) -> [SubagentCatalogEntry] {
        entries.sorted { lhs, rhs in
            let lhsKey = firstSeen(lhs) ?? lhs.createdAt ?? .min
            let rhsKey = firstSeen(rhs) ?? rhs.createdAt ?? .min
            if lhsKey != rhsKey { return lhsKey > rhsKey }
            return lhs.id < rhs.id
        }
    }
}

/// Relative "recent activity" text for the half-sheet rows.
enum SubagentActivityText {
    static func relative(fromMillis millis: Int64?, now: Date = Date()) -> String? {
        guard let millis, millis > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        let days = hours / 24
        return "\(days) 天前"
    }

 /// Localized variant used by the subagent half-sheet rows.
    static func localizedRelative(fromMillis millis: Int64?, now: Date = Date()) -> String? {
        guard let millis, millis > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return L10n.t("刚刚") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return L10n.f("%lld 分钟前", minutes) }
        let hours = minutes / 60
        if hours < 24 { return L10n.f("%lld 小时前", hours) }
        let days = hours / 24
        return L10n.f("%lld 天前", days)
    }
}

// MARK: - Parent/child routing (v5.4 §2)

enum SessionBackDestination: Equatable {
    case workspaces
    case parentSession(SessionFollowAddress)
}

enum SessionBackNavigation {
 /// A subagent detail goes back to its parent session; a normal session goes
 /// back to the workspace list.
    static func destination(subagentParent: SessionFollowAddress?) -> SessionBackDestination {
        if let subagentParent { return .parentSession(subagentParent) }
        return .workspaces
    }
}
