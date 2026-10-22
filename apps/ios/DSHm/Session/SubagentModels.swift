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
struct SubagentSessionContext: Equatable, Sendable {
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
        sessions.compactMap { item in
            guard item.parentSessionId == parentSessionId, item.isSubagent else { return nil }
            return SubagentCatalogEntry(
                id: item.sessionId,
                createdAt: item.updatedAt,
                mode: nil,
                label: item.title
            )
        }
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
