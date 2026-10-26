import SwiftUI

/// Session-list status (v6 status pass).
///
/// Priority: offline > waiting-for-approval (amber) > waiting-for-answer (green)
/// > in-progress (orange-amber) > not-started (info blue) > idle (neutral gray).
/// Both waiting sources are live: tool approvals ($events ->
/// LinkService.pendingApprovals) and active user-question waterfalls carried by
/// session/list projections (projections.values.userQuestions.active). Approval
/// wins when both are pending; the displayed count folds both sources.
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

/// Maps one session/list row + live approval count to the list status.
///
/// Priority: offline > approval > answer > running > not-started > idle. The
/// waiting count folds both sources; when both exist the approval case wins and
/// its count = approvals + active question calls (everything needing a human).
enum SessionListStatusResolver {
    static func status(
        for session: SessionListItem,
        pendingApprovals: Int,
        isConnected: Bool
    ) -> SessionListStatus {
 // A disconnected link cannot receive answers; show the offline state.
        if !isConnected { return .offline }
        let questionCalls = session.userQuestionsActive.count
        if pendingApprovals > 0 {
            return .waitingForApproval(count: pendingApprovals + questionCalls)
        }
        if questionCalls > 0 {
            return .waitingForAnswer(count: questionCalls)
        }
        if session.isRunning { return .running }
        if session.blank == true { return .notStarted }
        return .idle
    }
}
