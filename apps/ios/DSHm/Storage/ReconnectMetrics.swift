import Foundation

/// task-2 (reconnect chain P50 < 1s): end-to-end timing of **one page-enter /
/// foreground reconnect chain**, from `pageEnter` (t0) to `connected` **and**
/// `listApplied` (t1), plus the intermediate `reconnectStart` mark.
///
/// Design constraints (handoff §2.0/§2.3):
/// - t0 = the first callback of "the list page appeared" or `scenePhase ==.active`;
/// - t1 = `phase ==.connected` **and** the `session/list` response applied to the UI;
/// - a chain that reuses a healthy mux (no reconnect) is still a chain: its
/// `connectedMs` is 0 and `totalMs` is the list refresh latency;
/// - a page enter more than `chainLifetime` after the previous one starts a fresh
/// t0 instead of extending the old chain.
///
/// Only active with the same E2E gates as `FirstScreenMetrics`/`ConnectionMetrics`
/// (`DSHM_E2E=1` or `DSHM_STARTUP_METRICS=1`); emits one `[RECONNECT]...` NSLog
/// line per stage and exposes `valueString` for the hidden E2E element.
///
/// Deliberately not actor-isolated: the marks are written from `LinkService`
/// (main actor) and read from the E2E host/tests; the stage math is pure and the
/// single `chain` value is only touched by those main-thread call sites.
enum ReconnectMetrics {
 /// Unit-test override; `nil` means "read the launch environment".
    static var forceEnabledForTesting: Bool?
 /// Injectable monotonic clock (seconds) so the stage math is unit-tested.
    static var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
 /// Host observes the summary string (SwiftUI cannot observe a static).
    static var onChange: ((String?) -> Void)?
 /// A page enter further than this from the previous one starts a new chain.
    static let chainLifetime: TimeInterval = 5
 /// A chain older than this (e.g. a reconnect that never reached t1) is
 /// discarded by late marks instead of silently absorbing unrelated events.
    static let staleLifetime: TimeInterval = 30

    static var isEnabled: Bool {
        if let forceEnabledForTesting { return forceEnabledForTesting }
        let env = ProcessInfo.processInfo.environment
        return env["DSHM_E2E"] == "1" || env["DSHM_STARTUP_METRICS"] == "1"
    }

 /// One candidate-origin attempt inside the reconnect round, for the bench:
 /// which address was dialed, how long it took and why it failed.
    struct CandidateAttempt: Equatable {
        var host: String
        var milliseconds: Double
        var result: String
    }

    struct Chain: Equatable {
        var pageEnterAt: TimeInterval
        var beginEpochMs: Int64
        var reason: String
        var pageEnterCount = 1
        var reconnectStartAt: TimeInterval?
        var connectedAt: TimeInterval?
        var listAppliedAt: TimeInterval?
        var reusedMux = false
 /// A reuse chain only completes once the mux proved it is alive (first
 /// baseline); until then a first-byte timeout / path change demotes it to a
 /// real reconnect chain instead of reporting a misleading 0ms `connected`.
        var reuseConfirmed = false
        var pathChanges = 0
        var firstByteTimeouts = 0
        var invalidatedBy: String?
        var candidates: [CandidateAttempt] = []
        var pickedOrigin: String?
        var budgetExhausted = false
        var completed = false
        var lastStage = "-"
    }

    private(set) static var chain: Chain?

 // MARK: - Marks

 /// t0: the list page appeared, or `scenePhase` became `.active`. Repeated
 /// callbacks within `chainLifetime` keep the earliest t0 (page `.task` and the
 /// scene-phase callback can both fire for one resume).
    static func beginPageEnter(reason: String) {
        guard isEnabled else { return }
        let now = clock()
        if var current = chain, !current.completed, now - current.pageEnterAt < chainLifetime {
            current.pageEnterCount += 1
            chain = current
            publish(stage: "pageEnterAgain")
            return
        }
        chain = Chain(
            pageEnterAt: now,
            beginEpochMs: Int64(Date().timeIntervalSince1970 * 1000),
            reason: reason
        )
        publish(stage: "pageEnter")
    }

 /// A reconnect round actually began (`connectOnce`), i.e. the backoff wait was
 /// skipped or already elapsed. Recorded once per chain (the first round).
    static func markReconnectStart() {
        guard var current = activeChain() else { return }
        guard current.reconnectStartAt == nil else { return }
        current.reconnectStartAt = clock()
        chain = current
        publish(stage: "reconnectStart")
    }

 /// `phase ==.connected` was published.
    static func markConnected() {
        guard var current = activeChain() else { return }
        guard current.connectedAt == nil else { return }
        current.connectedAt = clock()
        chain = current
        publish(stage: "connected")
        completeIfReady()
    }

 /// The `session/list` response was applied to the list state (t1's second half).
    static func markListApplied() {
        guard var current = activeChain() else { return }
        guard current.listAppliedAt == nil else { return }
        current.listAppliedAt = clock()
        chain = current
        publish(stage: "listApplied")
        completeIfReady()
    }

 /// Page enter while the link is believed alive: no reconnect, so `connected` is
 /// t0 itself and the chain only measures how fast the list refresh lands. The
 /// reuse is provisional: the list page confirms it with `markReuseConfirmed()`
 /// once the mux's first baseline arrives. A first-byte timeout before that
 /// demotes the chain back to a real reconnect instead of reporting a 0ms chain.
    static func markReuseDecision() {
        guard var current = activeChain() else { return }
        current.reusedMux = true
        current.reuseConfirmed = false
        if current.connectedAt == nil { current.connectedAt = current.pageEnterAt }
        chain = current
        publish(stage: "reuse")
    }

 /// The reused mux proved it is alive (first `workspace/follow` baseline inside
 /// the probe budget): the reuse chain may complete.
    static func markReuseConfirmed() {
        guard var current = chain, !current.completed, current.reusedMux else { return }
        current.reuseConfirmed = true
        chain = current
        publish(stage: "reuseConfirmed")
        completeIfReady()
    }

 /// A provisional reuse that turned out to be a dead socket: drop the "connected
 /// at t0" claim so the following real reconnect produces the honest `connectedMs`.
    private static func demoteProvisionalReuse() {
        guard var current = chain, !current.completed, current.reusedMux, !current.reuseConfirmed else { return }
        current.reusedMux = false
        current.connectedAt = nil
        chain = current
    }

 /// The network path changed in a way that can invalidate the live socket.
    static func markPathChange() {
        guard var current = activeChain() else { return }
        demoteProvisionalReuse()
        guard var updated = chain else { return }
        updated.pathChanges += 1
        chain = updated
        publish(stage: "pathChange")
    }

 /// A request on the live transport did not produce a first byte within the
 /// probe budget: the socket is presumed dead.
    static func markFirstByteTimeout(source: String) {
        guard activeChain() != nil else { return }
        demoteProvisionalReuse()
        guard var current = chain else { return }
        current.firstByteTimeouts += 1
        current.invalidatedBy = "firstByte/" + source
        chain = current
        publish(stage: "firstByteTimeout")
    }

 /// Why the previous transport was invalidated (path change, page-enter heuristic,
 /// first-byte probe). Informational for the bench.
    static func markInvalidate(reason: String) {
        guard activeChain() != nil else { return }
        demoteProvisionalReuse()
        guard var current = chain else { return }
        current.invalidatedBy = reason
        chain = current
        publish(stage: "invalidate")
    }

 /// One candidate origin finished its attempt (success or classified failure).
    static func markCandidateAttempt(host: String, milliseconds: Double, result: String) {
        guard var current = activeChain() else { return }
        current.candidates.append(
            CandidateAttempt(host: host, milliseconds: max(0, milliseconds), result: result)
        )
        chain = current
        publish(stage: "candidate")
    }

 /// The origin that finally produced `phase ==.connected`.
    static func markPickedOrigin(_ host: String) {
        guard var current = activeChain() else { return }
        current.pickedOrigin = host
        chain = current
    }

 /// The fixed round budget ran out before every candidate was dialed (the
 /// explicit "no 10s tail" failure state; retryable via the normal backoff).
    static func markRoundBudgetExhausted() {
        guard var current = activeChain() else { return }
        current.budgetExhausted = true
        chain = current
        publish(stage: "budgetExhausted")
    }

 // MARK: - Summary

 /// `totalMs=..;pageEnterMs=0;reconnectStartMs=..;connectedMs=..;listAppliedMs=..;reuse=0|1;pathChanges=..;firstByteTimeouts=..;candidates=host:ms:result|..;picked=host;budgetExhausted=0|1;reason=..;invalidatedBy=..;stage=..;beginEpochMs=..`
 /// (`-1` = not seen yet; nil when disabled or no chain is active.)
    static var valueString: String? {
        guard isEnabled, let chain else { return nil }
        func milliseconds(_ at: TimeInterval?) -> String {
            guard let at else { return "-1" }
            return String(format: "%.0f", max(0, (at - chain.pageEnterAt) * 1000))
        }
        let total = totalMilliseconds(
            pageEnterAt: chain.pageEnterAt,
            connectedAt: chain.connectedAt,
            listAppliedAt: chain.listAppliedAt
        )
        let totalText = total.map { String(format: "%.0f", $0) } ?? "-1"
        let candidatesText = chain.candidates.isEmpty
            ? "-"
            : chain.candidates.map {
                "\($0.host):\(String(format: "%.0f", $0.milliseconds)):\($0.result)"
            }.joined(separator: "|")
        return "totalMs=\(totalText);pageEnterMs=0;reconnectStartMs=\(milliseconds(chain.reconnectStartAt));connectedMs=\(milliseconds(chain.connectedAt));listAppliedMs=\(milliseconds(chain.listAppliedAt));reuse=\(chain.reusedMux ? 1 : 0);pathChanges=\(chain.pathChanges);firstByteTimeouts=\(chain.firstByteTimeouts);candidates=\(candidatesText);picked=\(chain.pickedOrigin ?? "-");budgetExhausted=\(chain.budgetExhausted ? 1 : 0);reason=\(chain.reason);invalidatedBy=\(chain.invalidatedBy ?? "-");stage=\(chain.lastStage);beginEpochMs=\(chain.beginEpochMs)"
    }

 /// t1 - t0: the chain only completes when **both** halves of t1 are in, so the
 /// total is the later of `connected` and `listApplied` relative to t0.
    nonisolated static func totalMilliseconds(
        pageEnterAt: TimeInterval,
        connectedAt: TimeInterval?,
        listAppliedAt: TimeInterval?
    ) -> Double? {
        guard let connectedAt, let listAppliedAt else { return nil }
        return max(0, max(connectedAt, listAppliedAt) - pageEnterAt) * 1000
    }

    static func reset() {
        chain = nil
    }

 // MARK: - Internals

    private static func activeChain() -> Chain? {
        guard isEnabled, let current = chain, !current.completed else { return nil }
        let now = clock()
        guard now - current.pageEnterAt < staleLifetime else {
            chain = nil
            return nil
        }
        return current
    }

    private static func completeIfReady() {
        guard var current = chain else { return }
        guard current.connectedAt != nil, current.listAppliedAt != nil else { return }
 // A provisional reuse must be confirmed (or demoted) before it can close.
        guard !current.reusedMux || current.reuseConfirmed else { return }
        current.completed = true
        current.lastStage = "complete"
        chain = current
        guard let value = valueString else { return }
        onChange?(value)
        NSLog("[RECONNECT] %@", value)
    }

    private static func publish(stage: String) {
        guard isEnabled, var current = chain else { return }
        current.lastStage = stage
        chain = current
        guard let value = valueString else { return }
        onChange?(value)
        NSLog("[RECONNECT] %@", value)
    }
}
