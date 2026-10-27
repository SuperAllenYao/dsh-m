import Foundation

/// Deterministic progress of the background full-history filler.
///
/// Design: `<internal-doc>` (r2, approved
/// ). The user-visible contract:
/// - the newest 300 cached messages are the zero point and are **not** counted;
/// - the bar covers the remaining history down to the session's first event;
/// - completion is forced to 100% (never an animated/fake indeterminate value).
///
/// The math lives in `HistoryFillProgressTracker` (pure) so the boundary cases
/// are unit-tested without SwiftUI/async: origin arming, late cache widening,
/// monotonic fraction, forced completion and the hidden cases.
struct HistoryFillProgress: Equatable {
    enum Phase: String, Equatable {
        case loading
        case paused
        case completed
    }

 /// Oldest event seq of the first-screen window (the denominator).
    let originSeq: Int
 /// Smallest loaded seq observed during this page visit (the numerator base).
    let floorSeq: Int
    let phase: Phase
 /// Monotonic 0...1 fraction (never decreases within one page visit).
    let fraction: Double

 /// Rounded percentage for display/diagnostics.
    var percent: Int { Int((fraction * 100).rounded()) }
}

/// Pure state machine turning journal facts into `HistoryFillProgress`.
///
/// Journal facts used (all already available on the App side, no protocol change):
/// `journal.oldestSeq` (front of the loaded window) and `journal.hasMoreOlder`
/// (the Host still has events before it). See `Protocol/SessionJournal.swift`.
struct HistoryFillProgressTracker: Equatable {
 /// Origin seq (denominator); `nil` until the first-screen window is known.
    private(set) var originSeq: Int?
 /// Deepest `oldestSeq` observed since arming.
    private(set) var floorSeq: Int?
 /// Armed while older history existed → there is something to show.
    private(set) var hadOlderHistoryAtArm = false
 /// Filler pages merged since arming. The origin may only widen before the
 /// first page (e.g. a slow cache restore landing after the live snapshot).
    private(set) var pagesLoaded = 0
 /// High-water mark: a window reset / origin widening never jumps backwards.
    private(set) var maxFraction: Double = 0
 /// Sticky once the session's first event was reached after older history.
    private(set) var hasReachedEnd = false

    var isArmed: Bool { originSeq != nil }

    mutating func reset() {
        self = HistoryFillProgressTracker()
    }

 /// Arms the origin once the first screen window is known. No-op afterwards.
    mutating func armIfNeeded(oldestSeq: Int?, hasMoreOlder: Bool) {
        guard originSeq == nil, let oldest = oldestSeq else { return }
        originSeq = oldest
        floorSeq = oldest
        hadOlderHistoryAtArm = hasMoreOlder && oldest > 0
        hasReachedEnd = false
    }

 /// Recomputes from the current journal window; called on every window change
 /// (snapshot, merged history batch, reconnect). Never widens the origin: a
 /// filler page must not inflate the denominator.
    mutating func note(oldestSeq: Int?, hasMoreOlder: Bool) {
        guard originSeq != nil else { return }
        if let oldest = oldestSeq {
            if let floor = floorSeq {
                floorSeq = min(floor, oldest)
            } else {
                floorSeq = oldest
            }
        }
        if hasMoreOlder {
            hadOlderHistoryAtArm = true
        } else if hadOlderHistoryAtArm {
            hasReachedEnd = true
        }
    }

 /// One `session/page` batch was merged into the window.
    mutating func notePageLoaded() {
        pagesLoaded += 1
    }

 /// A late first-paint cache restore widened the first-screen window (only
 /// possible before the first filler page). Keeps the denominator honest when
 /// the live snapshot (12-20 messages) beat the off-main cache read (300).
    mutating func widenOrigin(to oldestSeq: Int?) {
        guard let origin = originSeq, pagesLoaded == 0,
              let oldest = oldestSeq, origin > 0, oldest < origin, oldest >= 0 else { return }
        originSeq = oldest
        if let floor = floorSeq {
            floorSeq = min(floor, oldest)
        } else {
            floorSeq = oldest
        }
    }

 /// Current progress, or `nil` when the bar must not be shown at all
 /// (no older history, no origin yet, or a degenerate zero origin).
 ///
 /// - Parameter activePhase: `.loading` while the filler runs, `.paused`
 /// otherwise (offline / waiting / watchdog retry). `.completed` is decided
 /// here because it must be forced to 100%.
    mutating func progress(activePhase: HistoryFillProgress.Phase) -> HistoryFillProgress? {
        guard let origin = originSeq, origin > 0, hadOlderHistoryAtArm else { return nil }
        if hasReachedEnd {
            return HistoryFillProgress(
                originSeq: origin,
                floorSeq: floorSeq ?? origin,
                phase: .completed,
                fraction: 1
            )
        }
        let floor = floorSeq ?? origin
        let raw = min(1, max(0, Double(origin - floor) / Double(origin)))
        maxFraction = max(maxFraction, raw)
        return HistoryFillProgress(
            originSeq: origin,
            floorSeq: floor,
            phase: activePhase,
            fraction: maxFraction
        )
    }
}

/// task-2：进度条首次可见延迟（reveal delay）的自适应策略。
///
/// 设计稿 §5（用户已批准）：「确定 O0 后延迟 300ms 再出现，短会话完成太快就不闪条」。
/// 用户报障「进详情后进度条很久才出现」——固定 300ms 对**长会话**是纯等待：它还要补
/// 至少 2 页，不存在「200ms 内补完、条闪一下」的风险。Lead 批准：
/// 预计补齐页数 ≥ 2 时缩短到 120ms，其余保留 300ms。
///
/// 页数估计用**本次会话自己的密度**（已加载窗口的事件数/消息数），不引入和设备或
/// 协议相关的固定事件数阈值：
/// eventsPerMessage = max(1, loadedEvents / loadedMessages)
/// remainingMessages ≈ originSeq / eventsPerMessage
/// expectedPages = remainingMessages / pageMessages
/// 窗口里还没有 user/assistant 消息时（极端窗口）退回 1 事件/消息的保守估计。
struct HistoryFillRevealPolicy: Equatable {
 /// 设计稿 §5 的默认防闪延迟。
    static let standardDelay: TimeInterval = 0.3
 /// 长会话（≥2 页）的自适应延迟：仍留出一帧以上的出现时间，避免闪烁。
    static let fastDelay: TimeInterval = 0.12
 /// 「长会话」的页数门槛（Lead 口径：预计补齐页数 ≥ 2）。
    static let longSessionPages: Double = 2

 /// 预计还要补多少页（≥0；数据不足时按 1 事件/消息保守估计）。
    static func expectedPages(
        originSeq: Int?,
        loadedEvents: Int,
        loadedMessages: Int,
        pageMessages: Int
    ) -> Double {
        guard let origin = originSeq, origin > 0, pageMessages > 0 else { return 0 }
        let events = max(1, loadedEvents)
        let messages = max(0, loadedMessages)
        let eventsPerMessage = messages > 0 ? max(1, Double(events) / Double(messages)) : 1
        let remainingMessages = Double(origin) / eventsPerMessage
        return remainingMessages / Double(pageMessages)
    }

 /// 本次进入用的 reveal 延迟（长会话快出，短会话防闪）。
    static func revealDelay(
        originSeq: Int?,
        loadedEvents: Int,
        loadedMessages: Int,
        pageMessages: Int
    ) -> TimeInterval {
        expectedPages(
            originSeq: originSeq,
            loadedEvents: loadedEvents,
            loadedMessages: loadedMessages,
            pageMessages: pageMessages
        ) >= longSessionPages ? fastDelay : standardDelay
    }
}
