import SwiftUI

/// Session-list status (v5.4 interaction pass).
///
/// Priority: waiting-for-answer (green) > in-progress (orange-amber) > not-started
/// (info blue) > idle (neutral gray); a disconnected link shows "offline" in gray.
/// Waiting covers both sources: live tool approvals (`$events` →
/// `LinkService.pendingApprovals`) and active user-question waterfalls carried by
/// `session/list` projections (`projections.values.userQuestions.active`).
enum SessionListStatus: Equatable {
    case waitingForAnswer(count: Int)
    case running
    case notStarted
    case idle
    case offline

 /// Card status line text: 等待作答 / 进行中 / 未开始 / 空闲 / 离线.
    var label: String {
        switch self {
        case .waitingForAnswer(let count):
            return count > 1 ? "等待作答 \(count)" : "等待作答"
        case .running: return "进行中"
        case .notStarted: return "未开始"
        case .idle: return "空闲"
        case .offline: return "离线"
        }
    }

 /// Localized display text for the card row (the canonical `label` stays
 /// Chinese for the unit-tested semantics).
    var localizedLabel: String {
        switch self {
        case .waitingForAnswer(let count):
            return count > 1 ? L10n.f("等待作答 %lld", count) : L10n.t("等待作答")
        case .running: return L10n.t("进行中")
        case .notStarted: return L10n.t("未开始")
        case .idle: return L10n.t("空闲")
        case .offline: return L10n.t("离线")
        }
    }

    var color: Color {
        switch self {
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

 /// Card border hint for actionable states (waiting / running).
    var emphasizedBorderColor: Color? {
        switch self {
        case .waitingForAnswer: return Theme.Palette.waiting.opacity(0.32)
        case .running: return Theme.Palette.running.opacity(0.32)
        default: return nil
        }
    }
}

/// Maps one `session/list` row + live approval count to the list status.
///
/// The waiting count folds both sources: tool approvals (one each) and active
/// user-question calls (one each). The UI only surfaces it when > 1 as
/// 「等待作答 N」; `userQuestions` answering itself is MVP scope.
enum SessionListStatusResolver {
    static func status(
        for session: SessionListItem,
        pendingApprovals: Int,
        isConnected: Bool
    ) -> SessionListStatus {
 // A disconnected link cannot receive answers; show the offline state.
        if !isConnected { return .offline }
        let questionCalls = session.userQuestionsActive.count
        if pendingApprovals > 0 || questionCalls > 0 {
            return .waitingForAnswer(count: pendingApprovals + questionCalls)
        }
        if session.isRunning { return .running }
        if session.blank == true { return .notStarted }
        return .idle
    }
}
