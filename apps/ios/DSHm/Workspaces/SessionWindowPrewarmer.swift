import Foundation

/// M2b-2b: low-priority detail-window prewarm.
///
/// `session/follow` windows are cached per session by `SessionViewModel` only *after*
/// the user opens that session. On cellular the first open of a session without a
/// cached window pays a full relay round-trip (measured list→detail P50 1.67s), while
/// the deep-linked long session whose window was already cached renders in ~0.14s.
///
/// After the list's first frame we therefore fetch the first window of the most recent
/// N sessions in the background and persist it through the existing
/// `SessionWindowCacheStore`, so "list -> recent session" is cache-first as well.
///
/// Properties: cancellable (list disappears / app leaves, or in-flight stream cancel),
/// throttled between sessions (no burst of 8-10 streams on cellular), silent on
/// failures, skips sessions whose cached window is already fresh.
@MainActor
final class SessionWindowPrewarmer {
    struct Candidate: Equatable {
        var sessionId: String
        var address: SessionFollowAddress
    }

    /// Production opens the real `session/follow` stream; unit tests inject a fake.
    /// Returns a cancellation closure (or nil when the stream could not be opened).
    typealias OpenFirstWindow = (
        _ candidate: Candidate,
        _ onSnapshot: @escaping (JSONValue) -> Void,
        _ onFinish: @escaping () -> Void
    ) -> (() -> Void)?

    let cacheStore: SessionWindowCacheStore
    /// Delay between two prewarm fetches: keeps the mux/relay free for the tap the
    /// user is about to make and avoids a burst of 8-10 streams on cellular.
    var throttleNanoseconds: UInt64
    /// A stream that never delivers a snapshot must not wedge the queue.
    var timeoutNanoseconds: UInt64

    private var task: Task<Void, Never>?
    private var cancelCurrentAttempt: (() -> Void)?
    /// Sessions whose first window this prewarmer actually wrote (evidence/asserts).
    private(set) var prewarmedSessionIds: [String] = []

    init(
        cacheStore: SessionWindowCacheStore = SessionWindowCacheStore(),
        throttleNanoseconds: UInt64 = 250_000_000,
        timeoutNanoseconds: UInt64 = 8_000_000_000
    ) {
        self.cacheStore = cacheStore
        self.throttleNanoseconds = throttleNanoseconds
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    var isRunning: Bool { task != nil }

    /// Sequentially prewarms `candidates` (most recent first, caller-ordered).
    /// Replaces any in-flight run. Never throws and never surfaces errors.
    func start(
        candidates: [Candidate],
        onSaved: ((String) -> Void)? = nil,
        onFinished: (() -> Void)? = nil,
        openFirstWindow: @escaping OpenFirstWindow
    ) {
        cancel()
        guard !candidates.isEmpty else { return }
        task = Task { [weak self] in
            guard let self else { return }
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                // Already fresh on disk (kept within the display TTL): nothing to do.
                if let cached = self.cacheStore.load(sessionId: candidate.sessionId), !cached.isStale {
                    if StartupMetrics.isEnabled {
                        NSLog("[DSHM-PERF] prewarm skip-fresh %@", candidate.sessionId)
                    }
                    continue
                }
                let saved = await self.prewarmOne(candidate, openFirstWindow: openFirstWindow)
                guard !Task.isCancelled else { return }
                if saved {
                    self.prewarmedSessionIds.append(candidate.sessionId)
                    if StartupMetrics.isEnabled {
                        NSLog("[DSHM-PERF] prewarm saved %@", candidate.sessionId)
                    }
                    onSaved?(candidate.sessionId)
                }
                if self.throttleNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: self.throttleNanoseconds)
                }
            }
            self.task = nil
            onFinished?()
        }
    }

    func cancel() {
        cancelCurrentAttempt?()
        cancelCurrentAttempt = nil
        task?.cancel()
        task = nil
    }

    /// Fetches one session's first window. Returns true when a snapshot was cached.
    private func prewarmOne(_ candidate: Candidate, openFirstWindow: @escaping OpenFirstWindow) async -> Bool {
        // All state is touched on the main actor; the checked continuation bridges the
        // callback-based stream API without leaking either end.
        final class Attempt {
            var finished = false
            var saved = false
            var cancelStream: (() -> Void)?
        }
        let attempt = Attempt()
        defer { cancelCurrentAttempt = nil }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            func finish() {
                guard !attempt.finished else { return }
                attempt.finished = true
                attempt.cancelStream?()
                attempt.cancelStream = nil
                continuation.resume()
            }
            let cancel = openFirstWindow(
                candidate,
                { [weak self] snapshot in
                    guard let self, !attempt.finished else { return }
                    // P1.5-B: persist the window size and `hasMore` alongside the
                    // snapshot (evidence + the detail knows the window is complete
                    // when `hasMore=false`). The opener asks for the same
                    // `SessionWindowPolicy.devicePrewarmMessages` window.
                    // 2026-10-23: the cache now stores the newest 4 screens as
                    // chunks. Decode the snapshot off-main (1-2MB on long sessions),
                    // then persist chunk 0..3 so the first open paints from chunk 0.
                    let store = self.cacheStore
                    let sessionId = candidate.sessionId
                    let windowMessages = SessionWindowPolicy.devicePrewarmMessages
                    Task {
                        // Decode (1-2MB snapshot) and the payload encode/disk write
                        // both stay off the main actor: the list must not jank while
                        // the prewarm runs behind it.
                        let didSave = await Task.detached(priority: .utility) {
                            guard case .snapshot(let parsed)? = try? SessionStreamFrame.decode(snapshot) else {
                                return false
                            }
                            return store.save(
                                sessionId: sessionId,
                                cursor: parsed.cursor,
                                hasMore: parsed.hasMore,
                                header: parsed.header,
                                projections: parsed.projections,
                                events: parsed.records.compactMap { $0.event },
                                windowMessages: windowMessages,
                                messagesPerScreen: SessionWindowPolicy.maxFirstWindowMessages,
                                screens: SessionWindowPolicy.cachedScreens
                            )
                        }.value
                        attempt.saved = didSave
                        finish()
                    }
                },
                {
                    finish()
                }
            )
            attempt.cancelStream = cancel
            cancelCurrentAttempt = { finish() }
            if cancel == nil { finish() }
            if timeoutNanoseconds > 0 {
                Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: self.timeoutNanoseconds)
                    finish()
                }
            }
        }
        return attempt.saved
    }
}
