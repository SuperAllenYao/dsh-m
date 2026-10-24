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
