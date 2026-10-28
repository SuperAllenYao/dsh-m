import Foundation

/// M2b-2b: E2E-gated in-app cold-start clock.
///
/// The UI test's wall clock (`launch() -> element exists`) has ~0.5s polling
/// resolution and includes XCUITest/accessibility overhead, so it cannot tell where
/// the launch time goes. This clock records monotonic marks **inside the app**,
/// relative to `begin()` (called as early as possible in `AppModel.init`):
///
/// - `cacheMs` launch -> workspace list restored from the on-disk cache
/// - `firstFrameMs` launch -> first session card appeared on screen
/// - `networkMs` launch -> first live `session/list` snapshot applied
///
/// Only active when the launch environment asks for it (`DSHM_E2E=1` or
/// `DSHM_STARTUP_METRICS=1`), so it has no product behavior. The result string is
/// surfaced through a hidden accessibility element (`startup-metrics`) and logged by
/// `M2ALiveUITests` as `[M2A-LIVE] startup metrics:...` for the bench parser.
@MainActor
enum StartupMetrics {
 /// Unit-test override; `nil` means "read the launch environment".
    static var forceEnabledForTesting: Bool?

    static var isEnabled: Bool {
        if let forceEnabledForTesting { return forceEnabledForTesting }
        let env = ProcessInfo.processInfo.environment
        return env["DSHM_E2E"] == "1" || env["DSHM_STARTUP_METRICS"] == "1"
    }

    private static var launchAt: TimeInterval?
 /// Wall-clock epoch (ms) captured at `begin()`: lets the UI-test process map the
 /// in-app t0 onto its own `app.launch()` timestamp (both run on the same phone
 /// with the same system clock). Used for the user-perceived acceptance metric.
    private static var beginEpochMs: Int64?
    private static var cacheAt: TimeInterval?
    private static var firstFrameAt: TimeInterval?
    private static var networkAt: TimeInterval?
 /// First live link connection (E2E diagnostics: the earliest point the detail
 /// prewarmer can open a background stream).
    private static var connectedAt: TimeInterval?

 /// Call as early as possible in the app lifecycle (first line of `AppModel.init`).
    static func begin() {
        guard isEnabled, launchAt == nil else { return }
        launchAt = ProcessInfo.processInfo.systemUptime
        beginEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
    }

 /// Workspace list restored from disk (compact snapshot or raw fallback).
    static func markCacheLoaded() {
        guard isEnabled, launchAt != nil, cacheAt == nil else { return }
        cacheAt = ProcessInfo.processInfo.systemUptime
    }

 /// First successful link connection (E2E diagnostics for prewarm timing).
    static func markConnected() {
        guard isEnabled, launchAt != nil, connectedAt == nil else { return }
        connectedAt = ProcessInfo.processInfo.systemUptime
    }

 /// First visible list content appeared (`onAppear` of the first session card).
    static func markFirstFrame() {
        guard isEnabled, launchAt != nil, firstFrameAt == nil else { return }
        firstFrameAt = ProcessInfo.processInfo.systemUptime
    }

 /// First live `session/list` snapshot applied (network refresh landed).
    static func markNetworkApplied() {
        guard isEnabled, launchAt != nil, networkAt == nil else { return }
        networkAt = ProcessInfo.processInfo.systemUptime
    }

 /// `cacheMs=..;firstFrameMs=..;networkMs=..;beginEpochMs=..` (milliseconds since
 /// launch, `-1` when that mark has not happened yet; `beginEpochMs` is wall-clock
 /// ms at t0); nil when the clock is disabled.
    static var valueString: String? {
        guard isEnabled, let launchAt else { return nil }
        func milliseconds(_ mark: TimeInterval?) -> String {
            guard let mark else { return "-1" }
            return String(format: "%.1f", (mark - launchAt) * 1000)
        }
        return "cacheMs=\(milliseconds(cacheAt));firstFrameMs=\(milliseconds(firstFrameAt));networkMs=\(milliseconds(networkAt));connMs=\(milliseconds(connectedAt));beginEpochMs=\(beginEpochMs ?? -1)"
    }

 /// Clears every mark (unit tests / repeated in-process measurements).
    static func reset() {
        launchAt = nil
        beginEpochMs = nil
        cacheAt = nil
        firstFrameAt = nil
        networkAt = nil
        connectedAt = nil
    }
}

/// M2b-2c: in-app timing for one session-detail open.
///
/// `t0` is the `SessionViewModel.init` entry (the first in-app work after the tap),
/// so the value is fully inside the app — without the XCUITest/accessibility
/// overhead that makes the wall clock unusable for the ≤1s detail acceptance:
/// - `firstFrameMs`: t0 -> detail first visible content (title + first rows)
/// - `cacheHit`: 1 when the window cache was restored in `init`, else 0
/// - `networkMs`: t0 -> first live `session/follow` snapshot applied (`-1` none)
///
/// P1.5-B segments (appended after the legacy keys, so the existing bench parser
/// keeps matching `firstFrameMs`/`cacheHit`/`networkMs` by key):
/// - `window`: messages the first `session/follow` asked for (12–20, phone-sized)
/// - `cacheMs`: t0 -> cached window replay finished (`-1` = cache miss)
/// - `fullMs`: t0 -> background fill applied the legacy 40-message window (`-1`
/// = no fill needed/finished yet; `hasMore=false` short sessions
/// never fill)
/// - `resumed`: 1 when the window was kept across a reconnect because the P1
/// channel missed no frames (kept `0` until the Net/ stream-resume
/// change lands; field reserved for that evidence)
///
/// Only active with the same E2E env gates as `StartupMetrics`; exposed through the
/// hidden `detail-metrics` accessibility element and logged by `M2ALiveUITests` as
/// `[M2A-LIVE] detail metrics:...` for the bench parser.
@MainActor
enum DetailMetrics {
 /// Unit-test override; `nil` means "read the launch environment".
    static var forceEnabledForTesting: Bool?

    static var isEnabled: Bool {
        if let forceEnabledForTesting { return forceEnabledForTesting }
        let env = ProcessInfo.processInfo.environment
        return env["DSHM_E2E"] == "1" || env["DSHM_STARTUP_METRICS"] == "1"
    }

    private static var openedAt: TimeInterval?
 /// Session that was opened (E2E diagnostics: correlate a cache miss with the
 /// prewarmed candidate set).
    private static var sessionId: String?
 /// Wall-clock epoch (ms) at t0 — shared clock with the UI-test process, used to
 /// compute the user-perceived detail latency (tap -> first content).
    private static var beginEpochMs: Int64?
    private static var firstFrameAt: TimeInterval?
    private static var networkAt: TimeInterval?
    private static var fullAt: TimeInterval?
    private static var cacheHit = false
 /// P1.5-B: first-window request size + cache replay duration (ms).
    private static var firstWindow = -1
    private static var cacheRestoreMs: TimeInterval?
 /// Reserved for the Net/ stream-resume change (P1.5-B keeps it 0).
    private static var resumed = false
 /// full-history autoload metrics:
 /// - tapAt: the card tap action (before route switch / VM init)
 /// - shellAt: detail shell on screen (header/composer/skeleton)
 /// - fill*: the silent background full-history fill (E2E evidence only)
    private static var tapAt: TimeInterval?
    private static var tapAtEpochMs: Int64 = -1
    private static var shellAt: TimeInterval?
    private static var fillCompletedMs: Double = -1
    private static var fillPages: Int = -1
    private static var fillOldestSeq: Int = -1
 /// Design r2: when the 2pt history-fill bar was first revealed (progress < 0 = never).
    private static var fillProgressAt: TimeInterval?

 /// Call first thing in `SessionViewModel.init` (t0). The cache-hit flag is
 /// filled in by `setCacheHit(_:)` once the synchronous restore has run.
    static func begin(sessionId: String? = nil) {
        guard isEnabled else { return }
        openedAt = ProcessInfo.processInfo.systemUptime
        self.sessionId = sessionId
        beginEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
        firstFrameAt = nil
        networkAt = nil
        fullAt = nil
        cacheHit = false
        firstWindow = -1
        cacheRestoreMs = nil
        resumed = false
        shellAt = nil
        fillCompletedMs = -1
        fillPages = -1
        fillOldestSeq = -1
        fillProgressAt = nil
    }

    static func setCacheHit(_ hit: Bool) {
        guard isEnabled, openedAt != nil else { return }
        cacheHit = hit
    }

 /// The `maxMessages` the first `session/follow` requested (P1.5-B evidence).
    static func setFirstWindow(_ messages: Int) {
        guard isEnabled, openedAt != nil else { return }
        firstWindow = messages
    }

 /// Cached window replay + first row rebuild finished inside `init`.
    static func markCacheRestored(milliseconds: Double) {
        guard isEnabled, openedAt != nil, cacheRestoreMs == nil else { return }
        cacheRestoreMs = milliseconds
        NSLog("[DETAILMETRIC] cacheRestored %.0fms", milliseconds)
    }

 /// The card tap action entry (t0 of the user-perceived detail latency). Called
 /// from the list before the route switch; begin(sessionId:) keeps it.
    static func beginTap() {
        guard isEnabled else { return }
        tapAt = ProcessInfo.processInfo.systemUptime
        tapAtEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
        NSLog("[DETAILMETRIC] tap")
    }

 /// The detail shell is on screen (header / composer / message skeleton, content
 /// not required yet). Idempotent.
    static func markShellFrame() {
        guard isEnabled, openedAt != nil, shellAt == nil else { return }
        shellAt = ProcessInfo.processInfo.systemUptime
        NSLog("[DETAILMETRIC] shell +%.0fms", (shellAt! - openedAt!) * 1000)
    }

 /// Detail's first visible content: title and/or first rows are on screen.
    static func markFirstContent() {
        guard isEnabled, openedAt != nil, firstFrameAt == nil else { return }
        firstFrameAt = ProcessInfo.processInfo.systemUptime
        NSLog("[DETAILMETRIC] firstContent +%.0fms", (firstFrameAt! - openedAt!) * 1000)
    }

 /// Backward-compatible alias.
    static func markFirstFrame() {
        markFirstContent()
    }

 /// The silent history fill reached the session's first event.
    static func markHistoryFillCompleted(milliseconds: Double, pages: Int, oldestSeq: Int) {
        guard isEnabled, openedAt != nil else { return }
        if fillCompletedMs < 0 { fillCompletedMs = milliseconds }
        fillPages = pages
        fillOldestSeq = oldestSeq
        NSLog("[DETAILMETRIC] fillDone +%.0fms pages=%d", milliseconds, pages)
    }

 /// Design r2: the 2pt history-fill bar became visible (after the reveal delay).
    static func markHistoryFillProgressVisible() {
        guard isEnabled, openedAt != nil, fillProgressAt == nil else { return }
        fillProgressAt = ProcessInfo.processInfo.systemUptime
    }

 /// First live `session/follow` snapshot applied.
    static func markNetworkApplied() {
        guard isEnabled, openedAt != nil, networkAt == nil else { return }
        networkAt = ProcessInfo.processInfo.systemUptime
        NSLog("[DETAILMETRIC] networkApplied +%.0fms", (networkAt! - openedAt!) * 1000)
    }

 /// Background fill applied: the legacy 40-message window is on screen.
    static func markFullWindowApplied() {
        guard isEnabled, openedAt != nil, fullAt == nil else { return }
        fullAt = ProcessInfo.processInfo.systemUptime
        NSLog("[DETAILMETRIC] fullWindow +%.0fms", (fullAt! - openedAt!) * 1000)
    }

 /// Reserved for P1 stream resume; P1.5-B always keeps 0.
    static func markResumed() {
        guard isEnabled, openedAt != nil else { return }
        resumed = true
    }

 /// `firstFrameMs=..;cacheHit=1;networkMs=..;beginEpochMs=..;sessionId=..`
 /// followed by the P1.5-B keys `window/cacheMs/fullMs/resumed` (ms since init,
 /// `-1` = not yet; `beginEpochMs` is wall-clock ms at t0); nil when disabled.
    static var valueString: String? {
        guard isEnabled, let openedAt else { return nil }
        func milliseconds(_ mark: TimeInterval?) -> String {
            guard let mark else { return "-1" }
            return String(format: "%.1f", (mark - openedAt) * 1000)
        }
        return "firstFrameMs=\(milliseconds(firstFrameAt));cacheHit=\(cacheHit ? 1 : 0);networkMs=\(milliseconds(networkAt));beginEpochMs=\(beginEpochMs ?? -1);sessionId=\(sessionId ?? "-");window=\(firstWindow);cacheMs=\(cacheRestoreMs.map { String(format: "%.1f", $0) } ?? "-1");fullMs=\(milliseconds(fullAt));resumed=\(resumed ? 1 : 0)"
    }

 /// The autoload key group, appended to the legacy detail metrics by
 /// the view model. Kept separate so the legacy valueString stays byte-stable for
 /// older bench parsers/tests.
    static var autoloadValueString: String? {
        guard isEnabled, let openedAt else { return nil }
        func secondsString(_ seconds: TimeInterval) -> String {
            return String(format: "%.1f", seconds * 1000)
        }
        let tap: String
        if let tapAt {
            tap = secondsString(openedAt - tapAt)
        } else {
            tap = "-1"
        }
        let shell: String
        if let shellAt {
            shell = secondsString(shellAt - openedAt)
        } else {
            shell = "-1"
        }
        let content: String
        if let firstFrameAt {
            content = secondsString(firstFrameAt - openedAt)
        } else {
            content = "-1"
        }
        let fill: String
        if fillCompletedMs < 0 {
            fill = "-1"
        } else {
            fill = String(format: "%.1f", fillCompletedMs)
        }
        let cacheChunk0: String
        if let cacheRestoreMs {
            cacheChunk0 = String(format: "%.1f", cacheRestoreMs)
        } else {
            cacheChunk0 = "-1"
        }
        let progressVisible: String
        if let fillProgressAt {
            progressVisible = secondsString(fillProgressAt - openedAt)
        } else {
            progressVisible = "-1"
        }
        return "tapMs=" + tap + ";tapAtEpochMs=" + String(tapAtEpochMs)
            + ";shellMs=" + shell + ";contentMs=" + content
            + ";firstContentMs=" + content + ";cacheChunk0Ms=" + cacheChunk0
            + ";fillMs=" + fill + ";fillPages=" + String(fillPages)
            + ";fillOldest=" + String(fillOldestSeq)
            + ";fillProgressMs=" + progressVisible
    }

 /// Clears every mark (unit tests).
    static func reset() {
        openedAt = nil
        beginEpochMs = nil
        sessionId = nil
        firstFrameAt = nil
        networkAt = nil
        fullAt = nil
        cacheHit = false
        firstWindow = -1
        cacheRestoreMs = nil
        resumed = false
        tapAt = nil
        tapAtEpochMs = -1
        shellAt = nil
        fillCompletedMs = -1
        fillPages = -1
        fillOldestSeq = -1
        fillProgressAt = nil
    }
}


/// 体验收尾: in-app timing for one prompt send (E2E only).
///
/// `t0` is `SessionViewModel.submitDraft()` entry (the tap's first in-app work):
/// - `tapToAcceptedMs`: t0 -> `session/prompt` unary returned (turn registered)
/// - `tapToTurnVisibleMs`: t0 -> running/turn indicator first rendered
/// - `queued`: 1 when the prompt went to the queue instead of the wire
/// - `failed`: 1 when the unary failed (banner shown)
/// Only active with the same E2E env gates as `StartupMetrics`; exposed through
/// the hidden `send-metrics` element and logged by `M2ALiveUITests`.
@MainActor
enum SendMetrics {
 /// Unit-test override; `nil` means "read the launch environment".
    static var forceEnabledForTesting: Bool?

    static var isEnabled: Bool {
        if let forceEnabledForTesting { return forceEnabledForTesting }
        let env = ProcessInfo.processInfo.environment
        return env["DSHM_E2E"] == "1" || env["DSHM_STARTUP_METRICS"] == "1"
    }

    private static var tappedAt: TimeInterval?
    private static var beginEpochMs: Int64?
    private static var acceptedAt: TimeInterval?
    private static var turnVisibleAt: TimeInterval?
    private static var queued = false
    private static var failed = false

    static func begin() {
        guard isEnabled else { return }
        tappedAt = ProcessInfo.processInfo.systemUptime
        beginEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
        acceptedAt = nil
        turnVisibleAt = nil
        queued = false
        failed = false
    }

    static func markQueued() {
        guard isEnabled, tappedAt != nil else { return }
        queued = true
    }

    static func markAccepted() {
        guard isEnabled, tappedAt != nil, acceptedAt == nil else { return }
        acceptedAt = ProcessInfo.processInfo.systemUptime
    }

    static func markTurnVisible() {
        guard isEnabled, tappedAt != nil, turnVisibleAt == nil else { return }
        turnVisibleAt = ProcessInfo.processInfo.systemUptime
    }

    static func markFailed() {
        guard isEnabled, tappedAt != nil else { return }
        failed = true
    }

 /// `tapToAcceptedMs=..;tapToTurnVisibleMs=..;queued=0;failed=0;beginEpochMs=..`
    static var valueString: String? {
        guard isEnabled, let tappedAt else { return nil }
        func milliseconds(_ mark: TimeInterval?) -> String {
            guard let mark else { return "-1" }
            return String(format: "%.0f", (mark - tappedAt) * 1000)
        }
        return "tapToAcceptedMs=\(milliseconds(acceptedAt));tapToTurnVisibleMs=\(milliseconds(turnVisibleAt));queued=\(queued ? 1 : 0);failed=\(failed ? 1 : 0);beginEpochMs=\(beginEpochMs ?? -1)"
    }

    static func reset() {
        tappedAt = nil
        beginEpochMs = nil
        acceptedAt = nil
        turnVisibleAt = nil
        queued = false
        failed = false
    }
}


/// P0 (remote perf): E2E-gated segmentation of one connection bring-up round.
///
/// Offsets are milliseconds from `begin()` (first in-app work of a `connectOnce`
/// round), so the live bench can separate transport cost from list/detail cost:
/// - `candidateMs`: first candidate started dialing
/// - `authMs`: mux token obtained (challenge+verify round trips done)
/// - `wsMs`: WSS upgrade completed
/// - `readyMs`: `$events` ready frame received
/// - `connectMs`: `phase = connected` published
/// - `host`/`relayFirst`: first dialed host and whether the path-aware relay-first
/// order was used (cellular/expensive path)
/// Only active with the same E2E env gates as `StartupMetrics`; exposed through the
/// hidden `connect-metrics` element and logged by `M2ALiveUITests`.
@MainActor
enum ConnectionMetrics {
 /// Unit-test override; `nil` means "read the launch environment".
    static var forceEnabledForTesting: Bool?

    static var isEnabled: Bool {
        if let forceEnabledForTesting { return forceEnabledForTesting }
        let env = ProcessInfo.processInfo.environment
        return env["DSHM_E2E"] == "1" || env["DSHM_STARTUP_METRICS"] == "1"
    }

    private static var startedAt: TimeInterval?
    private static var beginEpochMs: Int64?
    private static var candidateAt: TimeInterval?
    private static var authAt: TimeInterval?
    private static var wsAt: TimeInterval?
    private static var readyAt: TimeInterval?
    private static var connectedAt: TimeInterval?
    private static var firstHost: String?
    private static var relayFirst = false
 /// P1 dual-stack fields (task-10 / design §5). Legacy rounds report
 /// `proto=1;authMode=ecdsa;resumeMode=-;fallbackLegacy=0`, so the live bench
 /// can compare P1 and M1 rounds without branching on the rollout flag.
    private static var proto = 1
    private static var authMode = "ecdsa"
    private static var resumeMode = "-"
    private static var fallbackLegacy = false

    static func begin(preferRelay: Bool) {
        guard isEnabled else { return }
        startedAt = ProcessInfo.processInfo.systemUptime
        beginEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
        candidateAt = nil
        authAt = nil
        wsAt = nil
        readyAt = nil
        connectedAt = nil
        firstHost = nil
        relayFirst = preferRelay
        proto = 1
        authMode = "ecdsa"
        resumeMode = "-"
        fallbackLegacy = false
    }

 /// Records the dsh-m/2 handshake that produced this round: `authMode` is
 /// `ticket`/`muxToken`; `resumeMode` is `fresh`/`replay`/`reset`.
    static func markP1(authMode: String, resumeMode: String) {
        guard isEnabled, startedAt != nil else { return }
        proto = 2
        self.authMode = authMode
        self.resumeMode = resumeMode
        fallbackLegacy = false
    }

 /// This round tried dsh-m/2 and ended up on the legacy M1 path instead.
    static func markFallbackLegacy() {
        guard isEnabled, startedAt != nil else { return }
        proto = 1
        authMode = "ecdsa"
        resumeMode = "-"
        fallbackLegacy = true
    }

    static func markCandidate(_ host: String) {
        guard isEnabled, startedAt != nil else { return }
        if candidateAt == nil {
            candidateAt = ProcessInfo.processInfo.systemUptime
            firstHost = host
        }
    }

    static func markAuth() {
        guard isEnabled, startedAt != nil, authAt == nil else { return }
        authAt = ProcessInfo.processInfo.systemUptime
    }

    static func markWS() {
        guard isEnabled, startedAt != nil, wsAt == nil else { return }
        wsAt = ProcessInfo.processInfo.systemUptime
    }

    static func markReady() {
        guard isEnabled, startedAt != nil, readyAt == nil else { return }
        readyAt = ProcessInfo.processInfo.systemUptime
    }

    static func markConnected() {
        guard isEnabled, startedAt != nil, connectedAt == nil else { return }
        connectedAt = ProcessInfo.processInfo.systemUptime
    }

 /// `connectMs=..;candidateMs=..;authMs=..;wsMs=..;readyMs=..;host=..;relayFirst=0|1;beginEpochMs=..;proto=1|2;authMode=ecdsa|ticket|muxToken;resumeMode=fresh|replay|reset|-;fallbackLegacy=0|1`
    static var valueString: String? {
        guard isEnabled, let startedAt else { return nil }
        func milliseconds(_ mark: TimeInterval?) -> String {
            guard let mark else { return "-1" }
            return String(format: "%.0f", (mark - startedAt) * 1000)
        }
        return "connectMs=\(milliseconds(connectedAt));candidateMs=\(milliseconds(candidateAt));authMs=\(milliseconds(authAt));wsMs=\(milliseconds(wsAt));readyMs=\(milliseconds(readyAt));host=\(firstHost ?? "-");relayFirst=\(relayFirst ? 1 : 0);beginEpochMs=\(beginEpochMs ?? -1);proto=\(proto);authMode=\(authMode);resumeMode=\(resumeMode);fallbackLegacy=\(fallbackLegacy ? 1 : 0)"
    }

 /// 最近一轮「连接完成」耗时（ms，与 `connectMs` 同口径）。详情页 7 段埋点
 /// （`proj-v1-metrics` 的 `connect` 段）复用；未启用/本轮未连接时 nil。
    static var lastConnectMilliseconds: Int? {
        guard isEnabled, let startedAt, let connectedAt else { return nil }
        return max(0, Int((connectedAt - startedAt) * 1000))
    }

    static func reset() {
        startedAt = nil
        beginEpochMs = nil
        candidateAt = nil
        authAt = nil
        wsAt = nil
        readyAt = nil
        connectedAt = nil
        firstHost = nil
        relayFirst = false
        proto = 1
        authMode = "ecdsa"
        resumeMode = "-"
        fallbackLegacy = false
    }
}
