import SwiftUI

/// Session-list status (v6 status pass; DD-04 live question sources).
///
/// Priority: offline > waiting-for-approval (amber) > waiting-for-answer (green)
/// > in-progress (orange-amber) > not-started (info blue) > idle (neutral gray).
/// Both waiting sources are live: tool approvals ($events ->
/// LinkService.pendingApprovals) and user questions from the `session/list`
/// snapshot (`projections.values.userQuestions.active`) ∪ the live `$events`
/// waterfalls (`LinkService.pendingUserQuestions`), deduped by callId and minus
/// the answered/cancelled callIds. Approval wins when both are pending; the
/// displayed count folds both sources.
enum SessionListStatus: Equatable {
    case waitingForApproval(count: Int)
    case waitingForAnswer(count: Int)
    case running
    case notStarted
    case idle
    case offline

 /// Card status line text: 等待审批 / 等待作答 / 进行中 / 未开始 / 空闲 / 离线.
    var label: String {
        switch self {
        case .waitingForApproval(let count):
            return count > 1 ? "等待审批 \(count)" : "等待审批"
        case .waitingForAnswer(let count):
            return count > 1 ? "等待作答 \(count)" : "等待作答"
        case .running: return "进行中"
        case .notStarted: return "未开始"
        case .idle: return "空闲"
        case .offline: return "离线"
        }
    }

 /// Localized display text for the card row (the canonical label stays
 /// Chinese for the unit-tested semantics).
    var localizedLabel: String {
        switch self {
        case .waitingForApproval(let count):
            return count > 1 ? L10n.f("等待审批 %lld", count) : L10n.t("等待审批")
        case .waitingForAnswer(let count):
            return count > 1 ? L10n.f("等待作答 %lld", count) : L10n.t("等待作答")
        case .running: return L10n.t("进行中")
        case .notStarted: return L10n.t("未开始")
        case .idle: return L10n.t("空闲")
        case .offline: return L10n.t("离线")
        }
    }

 /// v6 icon kind for this status (detail header + list status row).
    var kind: SessionStatusKind {
        switch self {
        case .waitingForApproval: return .approval
        case .waitingForAnswer: return .answer
        case .running: return .running
        case .notStarted: return .notStarted
        case .idle: return .idle
        case .offline: return .offline
        }
    }

 /// v5.4 scale color kept for non-icon surfaces (card border emphasis etc.).
 /// The v6 status icon + its label paint with SessionStatusKind.color, which
 /// equals these tokens except running (#22D3EE accent, per design v6 §2).
    var color: Color {
        switch self {
        case .waitingForApproval: return Theme.Palette.warning
        case .waitingForAnswer: return Theme.Palette.waiting
        case .running: return Theme.Palette.running
        case .notStarted: return Theme.Palette.info
        case .idle: return Theme.Palette.textSecondary
        case .offline: return Theme.Palette.textTertiary
        }
    }

 /// Only the in-progress state keeps the pulsing dot.
    var isPulsing: Bool {
        self == .running
    }

 /// Card border hint for actionable states (approval / answer / running).
    var emphasizedBorderColor: Color? {
        switch self {
        case .waitingForApproval: return Theme.Palette.warning.opacity(0.32)
        case .waitingForAnswer: return Theme.Palette.waiting.opacity(0.32)
        case .running: return Theme.Palette.running.opacity(0.32)
        default: return nil
        }
    }
}

/// Maps one session/list row + live overlay to the list status (DD-04).
///
/// Priority: offline > approval > answer > running > not-started > idle. The
/// waiting count folds both sources; when both exist the approval case wins and
/// its count = approvals + active question calls (requirement §6.1).
///
/// User questions come from two sources keyed by `callId`: the `session/list`
/// snapshot (`projections.values.userQuestions.active[].callId`) and the live
/// `$events` waterfalls (`LinkService.pendingUserQuestions[].callId`). The card
/// passes `(snapshot ∪ live)` already minus the answered/cancelled callIds
/// (`LinkService.dismissedQuestionCallIds`, 60 s TTL), so an `open` waterfall the
/// snapshot already lists is counted once. A waterfall without an `agentId` is
/// not attributed to any card, and one without a `callId` cannot be deduped or
/// dismissed, so neither is counted (DD-04).
enum SessionListStatusResolver {
 /// DD-04 primary entry: both callId sets supplied, dismissed callIds already
 /// removed by the caller.
    static func status(
        for session: SessionListItem,
        pendingApprovals: Int,
        liveQuestionKeys: Set<String>,
        snapshotQuestionKeys: Set<String>,
        isConnected: Bool
    ) -> SessionListStatus {
 // A disconnected link cannot receive answers; show the offline state.
        if !isConnected { return .offline }
        let questionCount = liveQuestionKeys.union(snapshotQuestionKeys).count
        if pendingApprovals > 0 {
            return .waitingForApproval(count: pendingApprovals + questionCount)
        }
        if questionCount > 0 {
            return .waitingForAnswer(count: questionCount)
        }
 // DD-11: `running` is the live emit overlay applied by the view model; it
 // never writes back to the snapshot, so the row remains the fallback truth.
        if session.isRunning { return .running }
        if session.blank == true { return .notStarted }
        return .idle
    }

 /// Snapshot-only entry (rows without a live question overlay, and existing
 /// call sites/tests). Derives the callId set from the projection.
    static func status(
        for session: SessionListItem,
        pendingApprovals: Int,
        isConnected: Bool
    ) -> SessionListStatus {
        status(
            for: session,
            pendingApprovals: pendingApprovals,
            liveQuestionKeys: [],
            snapshotQuestionKeys: snapshotQuestionKeys(for: session),
            isConnected: isConnected
        )
    }

 /// Active callIds from `projections.values.userQuestions.active[].callId`.
 /// An entry without a callId cannot be deduped against a live waterfall nor
 /// dismissed, so it is not counted (DD-04); answering still works in detail.
 /// 快照侧去重键：与实时瀑布同一套「问题 id 指纹优先」规则，旧 Host 不带
 /// callId 时也能与实时事件去重（同一条问题只计一次）。
    static func snapshotQuestionKeys(for session: SessionListItem) -> Set<String> {
        var keys = Set<String>()
        for entry in session.userQuestionsActive {
            if let ids = entry["questions"]?.arrayValue?.compactMap({ $0["id"]?.stringValue }),
               !ids.isEmpty {
                keys.insert("q:" + ids.sorted().joined(separator: "|"))
                continue
            }
            if let callId = entry["callId"]?.stringValue, !callId.isEmpty {
                keys.insert("c:" + callId)
            }
        }
        return keys
    }

 /// 兼容旧名（单测引用）。
    static func snapshotQuestionCallIds(for session: SessionListItem) -> Set<String> {
        snapshotQuestionKeys(for: session)
    }
}
