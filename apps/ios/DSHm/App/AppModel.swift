import Combine
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension Notification.Name {
 /// P0-5: posted by `AppModel` when the app returns to the foreground with a
 /// live link. The TLS/mux is reused (no teardown, no full reconnect); the
 /// workspace list refreshes incrementally on top of it.
 /// `userInfo["backgroundedSeconds"]: Double`.
    static let dshmAppResumedReusingLink = Notification.Name("com.dshm.appResumedReusingLink")
}

/// P0-4/P0-5: E2E-gated first-screen clock (same gates and in-app monotonic
/// style as `StartupMetrics`, which it complements rather than replaces):
///
/// - `firstPaintMs` launch -> first list card on screen (`markFirstPaint`)
/// - `listReqStartMs` launch -> `session/list` handed to the transport
/// - `listAppliedMs` launch -> first live `session/list` snapshot applied
///
/// The point of these marks is the acceptance evidence for "first screen no
/// longer waits for the connection": `listReqStartMs` can now be smaller than
/// `StartupMetrics.connMs`. `ConnectionMetrics` owns the transport segments
/// (connect/candidate/auth/ws/ready); this enum deliberately does not repeat
/// them. Disabled unless `DSHM_E2E=1`/`DSHM_STARTUP_METRICS=1`; surfaced through
/// the hidden `first-screen-metrics` element (RootView) and `[P0-LIVE]` logs.
@MainActor
enum FirstScreenMetrics {
 /// Unit-test override; `nil` means "read the launch environment".
    static var forceEnabledForTesting: Bool?
 /// A host observes the summary string (SwiftUI cannot observe a static).
    static var onChange: ((String?) -> Void)?

    static var isEnabled: Bool {
        if let forceEnabledForTesting { return forceEnabledForTesting }
        let env = ProcessInfo.processInfo.environment
        return env["DSHM_E2E"] == "1" || env["DSHM_STARTUP_METRICS"] == "1"
    }

    private static var launchAt: TimeInterval?
 /// Wall-clock epoch (ms) at `begin()`: maps the in-app t0 onto the UI-test
 /// process clock (same phone, same system clock), like `StartupMetrics`.
    private static var beginEpochMs: Int64?
    private static var firstPaintAt: TimeInterval?
    private static var listReqAt: TimeInterval?
    private static var listAppliedAt: TimeInterval?

 /// Call as early as possible in `AppModel.init` (right after
 /// `StartupMetrics.begin()`).
    static func begin() {
        guard isEnabled else { return }
        launchAt = ProcessInfo.processInfo.systemUptime
        beginEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
        firstPaintAt = nil
        listReqAt = nil
        listAppliedAt = nil
        publish()
    }

 /// First list card appeared on screen (called from the card's `onAppear`).
    static func markFirstPaint() {
        guard isEnabled, launchAt != nil, firstPaintAt == nil else { return }
        firstPaintAt = ProcessInfo.processInfo.systemUptime
        publish()
    }

 /// `session/list` request handed to the unary transport (before the first
 /// response is applied). Deliberately recorded before any `connected` gate.
    static func markListRequested() {
        guard isEnabled, launchAt != nil, listReqAt == nil else { return }
        listReqAt = ProcessInfo.processInfo.systemUptime
        publish()
    }

 /// First live `session/list` snapshot applied to the list state.
    static func markListApplied() {
        guard isEnabled, launchAt != nil, listAppliedAt == nil else { return }
        listAppliedAt = ProcessInfo.processInfo.systemUptime
        publish()
    }

 /// `firstPaintMs=..;listReqStartMs=..;listAppliedMs=..;beginEpochMs=..`
 /// (ms since launch, `-1` = not yet); nil when disabled.
    static var valueString: String? {
        guard isEnabled, let launchAt else { return nil }
        func milliseconds(_ mark: TimeInterval?) -> String {
            guard let mark else { return "-1" }
            return String(format: "%.1f", (mark - launchAt) * 1000)
        }
        return "firstPaintMs=\(milliseconds(firstPaintAt));listReqStartMs=\(milliseconds(listReqAt));listAppliedMs=\(milliseconds(listAppliedAt));beginEpochMs=\(beginEpochMs ?? -1)"
    }

 /// Clears every mark (unit tests / repeated in-process measurements).
    static func reset() {
        launchAt = nil
        beginEpochMs = nil
        firstPaintAt = nil
        listReqAt = nil
        listAppliedAt = nil
    }

    private static func publish() {
        guard let value = valueString else { return }
        onChange?(value)
        NSLog("[P0-LIVE] first-screen %@", value)
    }
}

/// task-9: navigation a push deep link must use for one session id.
///
/// A subagent (Agent Teams teammate) session must be opened through its durable
/// parent address **and** carry the parent context: a plain `kind:"session"`
/// address for such a session is rejected by the Host (`session/agent-busy`),
/// which used to leave an empty detail + error banner after tapping a turn-end
/// notification.
struct PushDeepLinkNavigation: Equatable {
    var address: SessionFollowAddress
 /// Non-nil when `address` is a subagent address: where "back" goes.
    var parentAddress: SessionFollowAddress?
 /// Non-nil when `address` is a subagent address: parent/child/mode context.
    var context: SubagentSessionContext?
}

/// App-level navigation + environment wiring.
@MainActor
final class AppModel: ObservableObject {
    enum Route: Equatable {
        case pairing
        case workspaces
 /// Carries the session/follow address: subagent (Agent Teams teammate)
 /// sessions need their durable parent address, not a plain session id.
        case session(SessionFollowAddress)
    }

    @Published var route: Route
    @Published var toast: String?
 /// v5.4 task-13: non-nil while a subagent detail was opened from its parent
 /// session, so the back button returns to the parent instead of the list.
    struct SubagentRoute: Equatable {
        var context: SubagentSessionContext
        var parentAddress: SessionFollowAddress
    }
    @Published private(set) var subagentRoute: SubagentRoute?
    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.storageKey, forKey: "appLanguage")
 // the localization cache is language-keyed; rebuild it.
            L10n.invalidateCache()
        }
    }

    let link: LinkService
    let push = PushManager()
 /// Deep-link session lookup table, refreshed from every `session/list` load.
    private var deepLinkResolver = SessionDeepLinkResolver()
 /// 通知 tap 的 deep link 在未配对时就到达（冷启动/配对前）：先记住，配对完成再跳。
    private var pendingDeepLinkSessionId: String?
 /// task-9: in-flight `session/list` lookup for a notification deep link whose
 /// id is not in the cached table (see `resolveDeepLinkSession`).
    private var deepLinkResolveTask: Task<Void, Never>?
    private var deepLinkResolveToken: UUID?
 /// Ids from the last `session/list`: a known session navigates immediately, an
 /// unknown one must be resolved first (it may be a subagent child).
    private var knownSessionIds = Set<String>()
 /// Test seam: overrides the live `session/list` lookup used by
 /// `resolveDeepLinkSession`. Nil in production.
    var deepLinkSessionLookup: ((String) async -> [SessionListItem]?)?
    private var cancellables = Set<AnyCancellable>()

 // MARK: - P0-4/P0-5 first screen + foreground resume

 /// E2E-gated first-screen evidence (`first-screen-metrics` hidden element in
 /// `RootView`): first paint / list request / list applied, all relative to app
 /// launch. Nil outside E2E.
    @Published private(set) var firstScreenMetricsValue: String?
 /// E2E-gated foreground-resume evidence (`foreground-metrics` hidden element):
 /// the P0-5 decision (reuse the existing TLS/mux vs. reconnect) and how long
 /// the app was in the background.
    @Published private(set) var foregroundMetricsValue: String?
 /// Set when the scene goes to the background; consumed on the next activation
 /// so a cold launch (never backgrounded) is not treated as a resume.
    private var enteredBackgroundAt: Date?
 /// Test/evidence seam: how many foreground resumes reused the live link.
    private(set) var foregroundReuseCount = 0

 // MARK: - M4 push actions / silent push (<internal-doc>)

 /// E2E-gated visibility counters: silent pushes
 /// received and the last notification-action approval result. Product UI never
 /// shows them; `RootView` exposes them through hidden accessibility elements
 /// only when `DSHM_E2E=1`.
    @Published private(set) var silentPushCount = 0
    @Published private(set) var lastApprovalActionResult: String?
 /// Bumped when a silent push passes the ≥2s throttle; the visible list/detail
 /// views refresh their snapshot on change (M4 §4).
    @Published private(set) var silentPushRefreshVersion = 0
 /// `sessionId` of the last accepted silent push (nil = generic sync hint), so
 /// the detail view refreshes only when the pushed session matches.
    @Published private(set) var silentPushSessionId: String?

 /// Notification-action approval decisions waiting to be answered (M4 §3).
    private var approvalActionQueue: [PushApprovalDecision] = []
    private var approvalActionTask: Task<Void, Never>?
    private var silentPushThrottle = SilentPushThrottle()
    private var toastDismissTask: Task<Void, Never>?

    init() {
 // task-2 diagnostic scaffold (env-gated): installs the keyboard-latency probe
 // observers only when DSHM_KEYBOARD_PROBE=1; a no-op otherwise. Kept first so the
 // observers exist before any input can be focused. Remove with the probe file.
        KeyboardLatencyProbe.startIfEnabled()
 // M2b-2b: E2E-gated in-app cold-start clock (t0 = app model init). No product
 // behavior: recording is disabled unless DSHM_E2E/DSHM_STARTUP_METRICS is set.
        StartupMetrics.begin()
 // P0: warm the path monitor before the link's first connect so origin
 // selection already knows whether this is a cellular/expensive path.
        _ = NetworkPathMonitor.shared
 // P0-4/P0-5: the first-screen clock shares the same E2E gates and t0.
        FirstScreenMetrics.begin()
 // E2E scaffolding (env-gated, no product behavior): reset stored pairing
 // before LinkService reads the Keychain.
        if ProcessInfo.processInfo.environment["DSHM_RESET_PAIRING"] == "1" {
            CredentialStore().clear()
        }
        #if DEBUG
 // Debug-only E2E injection: save `DSHM_E2E_RELAY_CONFIG` before the pairing
 // UI reads the stored remote-server config. Absent from Release builds.
        E2EScaffolding.applyLaunchEnvironment()
 // E2E: keep the screen awake while a UI test drives the app (push deep-link
 // tests otherwise race the auto-lock and tap a lock-screen notification).
        if ProcessInfo.processInfo.environment["DSHM_E2E"] == "1" {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        #endif
        let link = LinkService()
        self.link = link
        if let forced = ProcessInfo.processInfo.environment["DSHM_FORCE_LANGUAGE"], !forced.isEmpty {
 // E2E scaffolding: pin the UI language so screenshot/assertion text is stable.
            language = forced.lowercased().hasPrefix("en") ? .english : .zhHans
        } else {
            language = AppLanguage.fromStored(UserDefaults.standard.string(forKey: "appLanguage"))
        }
        route = link.credentials == nil ? .pairing : .workspaces
 // Surface the (E2E-only) first-screen marks to RootView's hidden element.
        FirstScreenMetrics.onChange = { [weak self] value in
            self?.firstScreenMetricsValue = value
        }
 // FirstScreenMetrics.begin() ran before the link existed; publish the
 // launch-state string so the hidden element exists from the first frame.
        firstScreenMetricsValue = FirstScreenMetrics.valueString
        #if DEBUG
 // E2E: open a specific session right at launch (M2a live acceptance:
 // measures list/detail latency and drives the composer on a real device).
        if let deepLink = ProcessInfo.processInfo.environment["DSHM_E2E_OPEN_SESSION"], !deepLink.isEmpty {
            openSession(deepLink)
        }
 // E2E: push a session detail with no Host round-trip — the navigation-pop
 // UI tests (native edge-swipe back) only need a real pushed page, not
 // live session data. `parent/child/mode` pushes the subagent depth.
 // Debug-only; no product behavior.
        if let probe = ProcessInfo.processInfo.environment["DSHM_E2E_NAV_PROBE_SESSION"], !probe.isEmpty {
            let parts = probe.split(separator: "/").map(String.init)
            if parts.count == 3 {
                let context = SubagentSessionContext(parentSessionId: parts[0], childSessionId: parts[1], modeRaw: parts[2])
                subagentRoute = SubagentRoute(context: context, parentAddress: .session(sessionId: parts[0]))
                route = .session(context.followAddress)
            } else {
                route = .session(.session(sessionId: probe))
            }
        }
 // E2E: `parent/child/mode` + DSHM_E2E_NAV_PROBE_SUBAGENT_AFTER_MS — open the
 // parent LIVE first, then push the subagent child after the delay. Proves
 // whether covering a live parent fires its onDisappear (dormancy).
        if let raw = ProcessInfo.processInfo.environment["DSHM_E2E_NAV_PROBE_SUBAGENT_AFTER_MS"],
           let delayMs = Int(raw), delayMs > 0,
           let probe = ProcessInfo.processInfo.environment["DSHM_E2E_NAV_PROBE_PARENT"], !probe.isEmpty {
            let parts = probe.split(separator: "/").map(String.init)
            guard parts.count == 3 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                guard let self, case .session = self.route else { return }
                self.openSubagentSession(
                    SubagentCatalogEntry(id: parts[1], mode: parts[2]),
                    parentAddress: .session(sessionId: parts[0]),
                    parentSessionId: parts[0]
                )
            }
        }
 // E2E: simulate a notification tap N ms after launch. Posts the exact
 // NotificationCenter signal AppDelegate sends for a real push response, so
 // UI tests exercise the real tap path (AppModel.handlePushTap). Tap the
 // session currently on screen: requirement says this must be a
 // no-op (no detail rebuild / scroll reset / refetch); tap another session
 // id: the detail is replaced. Debug-only.
        if let tappedSession = ProcessInfo.processInfo.environment["DSHM_E2E_TAP_PUSH_SESSION"],
           !tappedSession.isEmpty {
            let delay = Int(ProcessInfo.processInfo.environment["DSHM_E2E_TAP_PUSH_AFTER_MS"] ?? "") ?? 1_500
 // `DSHM_E2E_TAP_PUSH_WAIT_READY=1`: 先等链路就绪再计延迟。首屏可能在
 // 冷启动/清缓存/跨网恢复时超过固定延迟，旧写法会让"注入推送"早于
 // 测试基线，导致跨会话重入断言假红。
            let waitForReady = ProcessInfo.processInfo.environment["DSHM_E2E_TAP_PUSH_WAIT_READY"] == "1"
            scheduleE2EPushTap(session: tappedSession, delayMs: delay, waitForReady: waitForReady)
        }
 // E2E: 在运行中模拟一次网络切换（Wi-Fi↔蜂窝/断网恢复），验证即时重连。
        if let raw = ProcessInfo.processInfo.environment["DSHM_E2E_SIMULATE_PATH_CHANGE_AFTER_MS"],
           let milliseconds = Int(raw), milliseconds >= 0 {
 //与 push tap 同理等「基线会话就绪」再计延迟，否则首屏
 // 打开慢于注入延迟时，切换发生在测试基线之前，generation 断言假红。
            scheduleE2EAfterBaselineReady(delayMs: milliseconds) { [weak self] in
                self?.link.simulateNetworkPathChangeForE2E()
            }
        }
        #endif
 // Republish link state so views observing AppModel also refresh on link changes.
        link.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
 // E2E-only visibility (nav-debug marker): when the link actually reached
 // each phase during the run.
        link.$phase
            .sink { [weak self] phase in
                self?.pushDbg("link phase -> \(String(describing: phase))")
            }
            .store(in: &cancellables)

 // APNs: forward device tokens to the link plugin; retry after pairing or
 // when a reconnect reaches the ready state.
        push.onToken = { [weak self] token in
            guard let self else { return }
            Task {
                do {
                    let registration = try await self.link.registerPushToken(
                        token,
                        environment: self.push.apnsEnvironment,
                        name: AppSettings.deviceName
                    )
                    self.push.markRegistered(registration)
                } catch let error as LinkError {
                    if case .remote(let remote) = error, remote.code == "auth/revoked" {
                        self.link.clearPairing()
                        self.route = .pairing
                    }
                    self.push.markRegistrationFailed(error.localizedDescription)
                } catch {
                    self.push.markRegistrationFailed(error.localizedDescription)
                }
            }
        }
        link.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                if phase.isConnected {
                    StartupMetrics.markConnected()
                }
                guard let self, phase.isConnected, let token = self.push.deviceTokenHex else { return }
                Task {
                    if let registration = try? await self.link.registerPushToken(
                        token,
                        environment: self.push.apnsEnvironment,
                        name: AppSettings.deviceName
                    ) {
                        self.push.markRegistered(registration)
                    }
                }
            }
            .store(in: &cancellables)

 // Notification tap -> deep link to the session from the APNs payload.
 // The payload carries only a session id; resolve it against the last
 // loaded session list so subagent sessions get their durable parent
 // address instead of a plain one (see SessionDeepLinkResolver).
        NotificationCenter.default.publisher(for: .dshmPushNotificationTapped)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                self.handlePushTap(sessionId: notification.object as? String)
            }
            .store(in: &cancellables)

 // M4 §3: approval notification actions -> queue -> `$events/result` with
 // a bounded retry; an unusable payload falls back to opening the session.
        NotificationCenter.default.publisher(for: .dshmPushApprovalAction)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, let route = notification.object as? PushApprovalRoute else { return }
                self.handlePushApprovalRoute(route)
            }
            .store(in: &cancellables)

 // M4 §4: silent pushes only pre-warm data; they never approve/answer.
        NotificationCenter.default.publisher(for: .dshmSilentPushReceived)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, let envelope = notification.object as? SilentPushEnvelope else { return }
                self.handleSilentPush(envelope)
            }
            .store(in: &cancellables)

 // Cold launch from a notification action: UIKit may deliver the response
 // before SwiftUI builds this model, so drain the delegate's parked routes.
 // The main thread is serial — routes posted after this init reach the
 // publisher above, so nothing is handled twice.
        for route in PushActionInbox.shared.drain() {
            handlePushApprovalRoute(route)
        }
 // 通知 tap 冷启动：UIKit 可能在 AppModel 创建前就投递了 deep link，上面那次
 // NotificationCenter post 会丢失，默认 `.workspaces` 路由就会覆盖掉它
 // （用户报障：点通知只进工作区列表）。这里领取 delegate 停放的 sessionId。
        PushDeepLinkInbox.shared.markLive()
        if let parkedSessionId = PushDeepLinkInbox.shared.drain() {
            if link.credentials == nil {
                pendingDeepLinkSessionId = parkedSessionId
            } else {
                handlePushTap(sessionId: parkedSessionId)
            }
        }
    }

 /// Called from RootView on appear: notification permission + APNs registration
 /// , plus a retry of any token already obtained.
    func start() {
        push.bootstrap()
        push.reRegister()
    }

 // MARK: - P0-5 foreground resume

 /// What a foreground activation should do to the link (pure decision seam,
 /// unit-tested; `backgroundedSeconds == nil` = first activation after launch).
    enum ForegroundAction: Equatable {
        case none
        case reconnect
        case reuseMux
    }

 /// P0-5: decide how to resume the remote connection when the scene becomes
 /// active. The default is to **reuse** the existing TLS/mux: a full
 /// `connectOnce` is only justified when the transport is already down.
 ///
 /// task-2: a **meaningful network-path change** since the last successful
 /// connect makes `.connected` meaningless — the socket was dialed on the old
 /// network and the OS has not reported it dead — so the resume must reconnect
 /// instead of reusing a stale mux.
    nonisolated static func foregroundAction(
        phase: LinkService.Phase,
        backgroundedSeconds: TimeInterval?,
        networkPathChanged: Bool = false
    ) -> ForegroundAction {
        guard let backgroundedSeconds else { return .none }
        switch phase {
        case .connected:
 // A stale transport is never reusable, regardless of the interruption
 // length: the mux was dialed on the network we already left.
            if networkPathChanged { return .reconnect }
 // A very short interruption (control center, permission alert…) does
 // not justify any extra traffic or a stream reopen; a real resume
 // reuses the existing TLS/mux.
            return backgroundedSeconds >= 1 ? .reuseMux : .none
        case .connecting:
 // A bring-up attempt is already running. Restarting it would cancel
 // the in-flight TLS/WSS work (P0-5) — unless the round predates a
 // network switch, in which case it is dialing the wrong path.
            return networkPathChanged ? .reconnect : .none
        case .disconnected, .reconnecting:
 // `.reconnecting` may be waiting out the 0.5–10s backoff; the resumed
 // app should retry immediately instead of waiting for it.
            return .reconnect
        case .unpaired, .needsRepair:
            return .none
        }
    }

 /// Scene went to `.background` (P0-5): remember when, so the next activation
 /// can tell a real resume from a cold launch / control-center blip.
    func handleAppEnteredBackground() {
        enteredBackgroundAt = Date()
    }

 /// Scene became `.active`: P0-5 reuse-first resume. Called from `RootView`
 /// instead of calling `link.handleForeground()` directly, so the decision is
 /// testable and never duplicates an in-flight connection attempt.
    func handleAppBecameActive() {
        let backgroundedSeconds = enteredBackgroundAt.map { Date().timeIntervalSince($0) }
        enteredBackgroundAt = nil
        let networkPathChanged = link.networkPathChangedSinceConnect
        switch Self.foregroundAction(
            phase: link.phase,
            backgroundedSeconds: backgroundedSeconds,
            networkPathChanged: networkPathChanged
        ) {
        case .none:
            return
        case .reconnect:
 // t0 of the reconnect chain: `scenePhase ==.active` (handoff §2.0).
            ReconnectMetrics.beginPageEnter(reason: "sceneActive")
            if networkPathChanged {
                ReconnectMetrics.markInvalidate(reason: "sceneActive/pathChanged")
            }
            let ms = (backgroundedSeconds ?? 0) * 1000
            recordForegroundMetrics(action: "reconnect", backgroundedMs: ms, reused: false)
            link.handleForeground()
        case .reuseMux:
 // A healthy mux on the current network: the chain only measures the
 // list refresh latency (connected is t0 itself).
            ReconnectMetrics.beginPageEnter(reason: "sceneActive")
            ReconnectMetrics.markReuseDecision()
            let seconds = backgroundedSeconds ?? 0
            foregroundReuseCount += 1
            recordForegroundMetrics(action: "reuseMux", backgroundedMs: seconds * 1000, reused: true)
 // The list refreshes incrementally on top of the *existing* mux: no
 // teardown, no `connectOnce` (P0-5).
            NotificationCenter.default.post(
                name: .dshmAppResumedReusingLink,
                object: nil,
                userInfo: ["backgroundedSeconds": seconds]
            )
        }
    }

    private func recordForegroundMetrics(action: String, backgroundedMs: TimeInterval, reused: Bool) {
        guard FirstScreenMetrics.isEnabled else { return }
        let value = String(
            format: "action=%@;bgMs=%.0f;reuse=%d;phase=%@;atEpochMs=%.0f",
            action,
            backgroundedMs,
            reused ? 1 : 0,
            String(describing: link.phase),
            Date().timeIntervalSince1970 * 1000
        )
        foregroundMetricsValue = value
        NSLog("[P0-LIVE] foreground resume %@", value)
    }

 // MARK: - 需求 #5：推送点击的同会话 no-op

 /// 推送点击是否需要真的切换会话（需求：推送对应的会话就是
 /// 当前正在看的会话时不转跳）。
 ///
 /// 详情页的身份就是 route 里的 `address.sessionId`（`RootView` 用
 /// `address.sessionId` 做 `.id`），所以「当前路由地址的会话 id == 推送目标」
 /// 即同一会话：
 /// - 顶层会话：route 是 `.session(.session(id))`；
 /// - 子会话（subagent）：route 的地址是 durable parent 地址，其
 /// `address.sessionId` 就是 childSessionId，同样成立；
 /// - `.pairing` / `.workspaces`：没有打开的详情页，必须导航。
 ///
 /// 同一会话时返回 false：不重建详情页、不丢滚动位置、不触发按需重拉数据。
    nonisolated static func shouldOpenPushDeepLink(
        currentRoute: Route,
        targetSessionId: String?
    ) -> Bool {
        guard let targetSessionId, !targetSessionId.isEmpty else { return true }
        guard case .session(let address) = currentRoute else { return true }
        return address.sessionId != targetSessionId
    }

 /// 通知 tap 的统一入口（前台横幅点击、冷启动停放、审批 fallback 都走这里）：
 /// 同会话 no-op，空 payload 回工作区列表。
    private func handlePushTap(sessionId rawSessionId: String?) {
        guard let sessionId = rawSessionId, !sessionId.isEmpty else {
            route = .workspaces
            return
        }
        pushDbg("push tap: session=" + sessionId + " route=\(route)")
        guard Self.shouldOpenPushDeepLink(currentRoute: route, targetSessionId: sessionId) else {
 // 需求：正在看这个会话，点击通知不应打断（滚动/已加载
 // 数据都保持原样）。
            pushDbg("push tap: already viewing session=" + sessionId + " (no-op)")
            return
        }
        openSession(sessionId)
    }

 // MARK: - M4 notification-action approvals

 /// Handles one routed notification response: allow/deny decisions are queued
 /// and answered with retry; unusable payloads fall back to the session.
    private func handlePushApprovalRoute(_ route: PushApprovalRoute) {
        switch route {
        case .approval(let decision):
            enqueueApprovalDecision(decision)
        case .fallback(let sessionId):
            showToast(L10n.t("审批信息不完整，请在 App 内处理"))
 // 没有可用深链时保持当前页面（旧行为）；有会话才走同会话 no-op 判定。
            if let sessionId, !sessionId.isEmpty {
                handlePushTap(sessionId: sessionId)
            }
        case .deepLink(let sessionId):
            handlePushTap(sessionId: sessionId)
        case .ignored:
            break
        }
    }

    private func enqueueApprovalDecision(_ decision: PushApprovalDecision) {
        approvalActionQueue.append(decision)
        processApprovalQueue()
    }

 /// Answers queued decisions one at a time (each may retry for up to 8s).
    private func processApprovalQueue() {
        guard approvalActionTask == nil, let decision = approvalActionQueue.first else { return }
        approvalActionTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.answerApproval(decision)
            if !self.approvalActionQueue.isEmpty {
                self.approvalActionQueue.removeFirst()
            }
            self.approvalActionTask = nil
            self.recordApprovalResult(result, decision: decision)
            self.processApprovalQueue()
        }
    }

 /// Sends one approval answer, retrying every 500ms until 8s while the
 /// `$events` `clientId`/transport is not ready yet (M4 §3.5 / §9).
 /// `respondApproval` clears the pending waterfall on success; a remote
 /// business rejection means the event was already settled and is final.
    private func answerApproval(_ decision: PushApprovalDecision) async -> PushApprovalResult {
        let policy = PushApprovalRetryPolicy()
        let started = Date()
        while true {
            if link.clientId != nil, link.phase.isConnected {
                let approval = decision.waterfall(pending: link.pendingApprovals)
                do {
                    try await link.respondApproval(approval, outcome: decision.outcome)
                    return .sent(decision.outcome)
                } catch let error as LinkError {
                    guard PushApprovalRetryPolicy.canRetry(after: error) else { return .failed }
                } catch {
                    return .failed
                }
            }
            guard policy.shouldRetry(elapsed: Date().timeIntervalSince(started)) else { return .failed }
            try? await Task.sleep(nanoseconds: policy.retryDelayNanoseconds)
            if Task.isCancelled { return .failed }
        }
    }

    private func recordApprovalResult(_ result: PushApprovalResult, decision: PushApprovalDecision) {
        lastApprovalActionResult = result.markerValue
        switch result {
        case .sent(let outcome):
            showToast(outcome == .allowedOnce ? L10n.t("已允许") : L10n.t("已拒绝"))
        case .failed:
            showToast(L10n.t("审批提交失败，请在 App 内处理"))
            if let sessionId = decision.sessionId, !sessionId.isEmpty {
                openSession(sessionId)
            }
        }
    }

 // MARK: - M4 silent push (background pre-warm only)

 /// Background push: count it for E2E evidence, then bump the refresh version
 /// at most once per 2s. It never approves or answers anything.
    private func handleSilentPush(_ envelope: SilentPushEnvelope, now: Date = Date()) {
        guard envelope.isSilent else { return }
        silentPushCount += 1
        guard silentPushThrottle.shouldAccept(now: now) else { return }
        silentPushSessionId = envelope.sessionId
        silentPushRefreshVersion += 1
    }

 // MARK: - Toast

 /// Shows a transient toast and clears it automatically (M4 approval feedback).
    func showToast(_ text: String, duration: TimeInterval = 2.5) {
        toast = text
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, !Task.isCancelled, self.toast == text else { return }
            self.toast = nil
        }
    }

 // MARK: - Launch environment (E2E / demo scaffolding, no product behavior)

    var envPairingPayload: String? {
        let value = ProcessInfo.processInfo.environment["DSHM_PAIRING_PAYLOAD"]
        return (value?.isEmpty == false) ? value : nil
    }

    var isE2EMode: Bool {
        ProcessInfo.processInfo.environment["DSHM_E2E"] == "1"
    }

 // MARK: - Navigation

    func didPair() {
        subagentRoute = nil
 // 配对前点过通知：配对完成后再补跳会话详情，而不是丢掉这次意图。
        if let pending = pendingDeepLinkSessionId {
            pendingDeepLinkSessionId = nil
            openSession(pending)
        } else {
            route = .workspaces
        }
        push.bootstrap()
    }

 /// Opens a session by id (list taps and notification deep links).
 ///
 /// task-9: a notification can point at a **subagent** session. That session
 /// must be opened through its durable parent address *and* with the parent
 /// context (`subagentRoute`), otherwise the app either (a) sends a plain
 /// `kind:"session"` address, which the Host rejects with
 /// `session/agent-busy` (blank detail + error banner) — or (b) opens the child
 /// as a normal session (wrong back navigation / composer).
    func openSession(_ sessionId: String) {
 // 未配对时没有会话可看：先停在这里，配对成功（didPair）后再跳，避免
 // 落到一个打不开的详情页或丢掉这次 deep link。
        guard link.credentials != nil else {
            subagentRoute = nil
            pendingDeepLinkSessionId = sessionId
            route = .pairing
            return
        }
        openDeepLinkSession(sessionId)
    }

 /// Opens one notification deep link. A resolved subagent address (or a known
 /// top-level session) navigates immediately; an **unknown** id is resolved
 /// against a fresh `session/list` *before* the detail is created — the detail
 /// identity is the session id, so replacing the route afterwards would keep the
 /// existing (plain-address) view model and its Host rejection alive.
    private func openDeepLinkSession(_ sessionId: String) {
 // Every deep link supersedes a pending lookup: rapid notification taps must
 // end on the newest target, and a slow lookup of an older tap must not
 // override it.
        let navigationToken = UUID()
        deepLinkResolveToken = navigationToken
        let navigation = Self.deepLinkNavigation(sessionId: sessionId, resolver: deepLinkResolver)
        if navigation.context != nil || knownSessionIds.contains(sessionId) {
            deepLinkResolveTask?.cancel()
            deepLinkResolveTask = nil
            applyDeepLinkNavigation(navigation)
            return
        }
        resolveDeepLinkSession(sessionId, token: navigationToken)
    }

    private func applyDeepLinkNavigation(_ navigation: PushDeepLinkNavigation) {
 // t0 for the user-perceived detail latency on the notification
 // deep-link path (same clock as the list tap).
        DetailMetrics.beginTap()
        pushDbg("deep link apply address=\(navigation.address.sessionId) subagent=\(navigation.context != nil ? 1 : 0) currentRoute=\(route)")
        navWriteAt = Date()
 // 真机实证：replace 走系统转场会竞态（SwiftUI 把 replace 拆成
 // pop+push，pop 段回写旧 path，页面被弹回旧会话）。深链替换改为瞬时直写
 // ——与旧 ZStack 时代的「深链换页无动画」行为一致；手势返回仍是系统动效。
        withTransaction(Self.instantNavTransaction) {
            if let context = navigation.context, let parentAddress = navigation.parentAddress {
                subagentRoute = SubagentRoute(context: context, parentAddress: parentAddress)
            } else {
                subagentRoute = nil
            }
 // A deep link always replaces the page identity.
            route = .session(navigation.address)
        }
    }

 /// Pure decision seam (unit-tested): route + subagent context for one id.
    nonisolated static func deepLinkNavigation(
        sessionId: String,
        resolver: SessionDeepLinkResolver
    ) -> PushDeepLinkNavigation {
        let address = resolver.address(for: sessionId)
        guard case .subagent(let parentSessionId, let childSessionId, let mode) = address else {
            return PushDeepLinkNavigation(address: address, parentAddress: nil, context: nil)
        }
 // A subagent parent is a top-level session; if a (stale) row resolves the
 // parent to another subagent address, fall back to the plain parent id
 // instead of nesting subagent addresses.
        let resolvedParent = resolver.address(for: parentSessionId)
        let parentAddress: SessionFollowAddress = resolvedParent.isSubagent
            ? .session(sessionId: parentSessionId)
            : resolvedParent
        let context = SubagentSessionContext(
            parentSessionId: parentSessionId,
            childSessionId: childSessionId,
            modeRaw: mode
        )
        return PushDeepLinkNavigation(
            address: address,
            parentAddress: parentAddress,
            context: context
        )
    }

 /// Resolves an unknown deep-linked id against a fresh `session/list`, then
 /// opens it (a cold-launch tap arrives before the transport is up, and the
 /// table is only refreshed when the workspace list renders). A failed lookup
 /// falls back to the plain address after a bounded wait so an offline tap still
 /// navigates somewhere — the Host error then surfaces instead of a silent no-op.
    private func resolveDeepLinkSession(_ sessionId: String, token resolveToken: UUID) {
        deepLinkResolveTask?.cancel()
        deepLinkResolveTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.deepLinkResolveToken == resolveToken {
                    self.deepLinkResolveTask = nil
                    self.deepLinkResolveToken = nil
                }
            }
            var items: [SessionListItem]?
            if let lookup = self.deepLinkSessionLookup {
                items = await lookup(sessionId)
            } else {
                for _ in 0..<24 {
                    if Task.isCancelled { return }
                    if self.link.phase.isConnected { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                if !Task.isCancelled, self.link.phase.isConnected,
                   let value = try? await self.link.unary(
                       "session/list",
                       args: SessionListLite.requestArgs(),
                       timeout: 20
                   ),
                   let list = try? value.decode(SessionListValue.self) {
                    items = list.items
                }
            }
            guard !Task.isCancelled else { return }
            if let items { self.updateKnownSessions(items) }
            let navigation = Self.deepLinkNavigation(
                sessionId: sessionId,
                resolver: self.deepLinkResolver
            )
            pushDbg(
                "deep link resolve session=" + sessionId
                    + " listed=" + String(items != nil)
                    + " subagent=" + String(navigation.context != nil)
            )
 // Ordering: a newer deep link (or a newer resolved navigation) supersedes
 // this lookup. `.pairing` / `.workspaces` are fine — nothing is open yet
 // (cold launch / pairing hand-off), so the deep link still completes.
            guard self.deepLinkResolveToken == resolveToken else { return }
            self.applyDeepLinkNavigation(navigation)
        }
    }

 /// DSHM_DEBUG_STREAM-gated diagnostic (notification deep-link navigation).
    private static let pushDebugEnabled =
        ProcessInfo.processInfo.environment["DSHM_DEBUG_STREAM"] == "1"
            || ProcessInfo.processInfo.environment["DSHM_E2E"] == "1"

    private func pushDbg(_ message: @autoclosure () -> String) {
        guard Self.pushDebugEnabled else { return }
        let line = message()
        NSLog("[PUSHDBG] %@", line)
 // E2E-only visibility channel (hidden accessibility marker in RootView):
 // device app stdout is not captured by xcodebuild, the marker value is.
        navDebugLog = (navDebugLog.count > 800 ? String(navDebugLog.suffix(800)) : navDebugLog) + "\n" + line
    }

 /// E2E-only navigation debug trail, surfaced through the hidden
 /// `nav-debug` accessibility marker (empty outside E2E).
    @Published var navDebugLog: String = ""

    #if DEBUG
 /// E2E 注入闸门：基线会话（DSHM_E2E_OPEN_SESSION）的详情页
 /// 已经出现（SessionDetailView.task 上报）。只升不降；产品行为无涉。
    private var e2eBaselineDetailAppeared = false

    func noteE2EDetailAppeared(sessionId: String) {
        guard isE2EMode,
              sessionId == ProcessInfo.processInfo.environment["DSHM_E2E_OPEN_SESSION"] else { return }
        e2eBaselineDetailAppeared = true
        pushDbg("e2e baseline detail appeared session=" + sessionId)
    }
    #endif

    func openSession(_ address: SessionFollowAddress) {
        NavDiagnostics.log("route openSession subagent=0")
        navWriteAt = Date()
 // 瞬时直写（见 applyDeepLinkNavigation 注释）。
        withTransaction(Self.instantNavTransaction) {
            subagentRoute = nil
            route = .session(address)
        }
    }

 /// v5.4 task-13: opens a child subagent session from its parent catalog and
 /// remembers the parent address for the back navigation.
    func openSubagentSession(
        _ entry: SubagentCatalogEntry,
        parentAddress: SessionFollowAddress,
        parentSessionId: String
    ) {
        let context = SubagentSessionContext(
            parentSessionId: parentSessionId,
            childSessionId: entry.id,
            modeRaw: entry.mode
        )
        NavDiagnostics.log("route openSubagent child=(context.childSessionId)")
        navWriteAt = Date()
 // 瞬时直写（见 applyDeepLinkNavigation 注释）。
        withTransaction(Self.instantNavTransaction) {
            subagentRoute = SubagentRoute(context: context, parentAddress: parentAddress)
            route = .session(context.followAddress)
        }
    }

 /// Back from a session detail: subagent detail -> parent session; normal
 /// session -> workspace list. Drives the NavigationStack pop (:
 /// system push/pop transition).
    func backFromSession() {
        NavDiagnostics.log("route backFromSession")
        navWriteAt = Date()
        withAnimation(.default) {
            switch SessionBackNavigation.destination(subagentParent: subagentRoute?.parentAddress) {
            case .parentSession(let parentAddress):
                subagentRoute = nil
                route = .session(parentAddress)
            case .workspaces:
                subagentRoute = nil
                route = .workspaces
            }
        }
    }

 /// The NavigationStack path derived from `route` + `subagentRoute` (single
 /// source of truth; unit-tested). Level 1 = top-level session, level 2 =
 /// subagent child. Empty everywhere except an open session detail.
 /// native system navigation (Apple's own edge-swipe back).
    func sessionNavPath() -> [SessionNavTarget] {
        var path: [SessionNavTarget] = []
        switch route {
        case .session(let address):
            if let sub = subagentRoute {
                path.append(SessionNavTarget(address: sub.parentAddress, subagentContext: nil))
                path.append(SessionNavTarget(address: sub.context.followAddress, subagentContext: sub.context))
            } else {
                path.append(SessionNavTarget(address: address, subagentContext: nil))
            }
        case .pairing, .workspaces:
            break
        }
        return path
    }

 /// Translates a user-driven NavigationStack change (system back button /
 /// edge-swipe pop) back into the model. Pushes never arrive here — they only
 /// go through `openSession` / `openSubagentSession` / deep links — so exactly
 /// two shapes are legitimate:
 /// * depth 1 -> [] (pop the top-level session to the list)
 /// * depth 2 -> [parent] (pop the subagent child to its parent)
 /// Anything else is an ECHO of a previous path (observed on
 /// device: during an animated deep-link REPLACE, SwiftUI re-writes the old
 /// single element mid-transition; accepting it would revert the replace —
 /// "title stayed..." in SessionHistoryE2ETests). Echoes also arrive while a
 /// programmatic push is still animating, so sets inside `navEchoWindow`
 /// after a model-driven nav write are ignored: UIKit cannot start a user
 /// pop during another transition, so nothing legitimate is lost.
    func applySessionNavPath(_ newPath: [SessionNavTarget]) {
        guard Date().timeIntervalSince(navWriteAt) > navEchoWindowSeconds else {
            NavDiagnostics.log("pathApply ignored(echo) depth=\(newPath.count)")
            return
        }
        let current = sessionNavPath()
        guard newPath != current else { return }
        NavDiagnostics.log("pathApply depth=\(newPath.count) current=\(current.count)")
 // P0：pop 回写的模型更新走**瞬时无动画事务**。
 // 崩溃栈：pop 转场中 SwiftUI 以 animated 方式再次 setViewControllers
 // → UINavigationController 断言 → SIGABRT。无动画更新不会与转场竞争。
        withTransaction(Self.instantNavTransaction) {
            switch newPath.count {
        case 0:
 // Legit only from depth 1: popping the top-level session to the list.
            if current.count == 1 {
                subagentRoute = nil
                route = .workspaces
            }
        case 1:
 // Legit only from depth 2, and only to the parent element that is
 // already underneath the child (subagent pop). A different element
 // while at depth 1 is the replace echo described above.
            if current.count == 2, newPath[0] == current[0] {
                subagentRoute = nil
                route = .session(newPath[0].address)
            }
        default:
 // Depth stays 2; nothing to reconcile.
            break
            }
        }
    }

 /// A transaction that disables ALL animations for a navigation write
 /// (push/replace seams; pops keep the system animation).
    static var instantNavTransaction: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }

 /// Time after a model-driven navigation write during which binding `set`
 /// calls are treated as transition echoes (test-injectable).
    var navEchoWindowSeconds: TimeInterval = 0.6
 /// When the model last wrote a navigation route (push/replace/pop seams).
    var navWriteAt = Date.distantPast

 /// Address a deep-linked session id must be opened with. Falls back to the
 /// plain address when the session was not in the last loaded `session/list`
 /// (cold launch / newly created session); documenting the M1 limitation:
 /// such a subagent target then shows the Host's business error banner.
    func sessionAddress(forDeepLink sessionId: String) -> SessionFollowAddress {
        deepLinkResolver.address(for: sessionId)
    }

 /// Keeps the deep-link lookup table in sync with the list the user sees.
    func updateKnownSessions(_ sessions: [SessionListItem]) {
        deepLinkResolver.update(sessions: sessions)
        knownSessionIds = Set(sessions.map(\.sessionId))
    }

    func backToWorkspaces() {
        subagentRoute = nil
        route = .workspaces
    }

    func startOverPairing() {
        link.clearPairing()
        subagentRoute = nil
        route = .pairing
    }

    #if DEBUG
 /// E2E 推送注入（生产不可达）。
 ///
 /// `waitForReady == false`：按 launch 起算的固定延迟（旧行为，用于验"启动即被
 /// 推送打断"的场景）。`waitForReady == true`：等链路就绪后**再**计延迟，保证
 /// 测试基线已经在目标会话里——冷启动/清缓存/跨网恢复时首屏可能超过固定延迟，
 /// 旧写法会让注入早于基线，产生跨会话重入假红。
    private func scheduleE2EPushTap(session: String, delayMs: Int, waitForReady: Bool) {
        func post(afterDelay: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, afterDelay))) {
                NotificationCenter.default.post(name: .dshmPushNotificationTapped, object: session)
            }
        }
        guard waitForReady else { return post(afterDelay: delayMs) }
        scheduleE2EAfterBaselineReady(delayMs: delayMs, minimumDelayMs: 1_200, fire: {
            post(afterDelay: 0)
        })
    }

 /// E2E 注入统一就绪闸门：链路 isConnected 只说明能拉
 /// 数据，不说明「测试基线」已建立——首屏打开基线会话可能超过注入延迟，注入
 /// 事件早于基线会让后续断言假红（push tap 已把 app 带走 / generation 已前进）。
 /// 就绪 = 链路连通 **且** route 已停在启动基线会话（DSHM_E2E_OPEN_SESSION）；
 /// 无基线 env 时退回仅链路判定。90s 兜底后强制注入。
    private func scheduleE2EAfterBaselineReady(
        delayMs: Int,
        minimumDelayMs: Int = 0,
        fire: @escaping () -> Void
    ) {
        var polls = 0
        func poll() {
            let baselineId = ProcessInfo.processInfo.environment["DSHM_E2E_OPEN_SESSION"]
            var onBaseline = true
            if let baselineId, !baselineId.isEmpty {
                if case .session(let address) = route, address.sessionId == baselineId {
                    onBaseline = true
                } else {
                    onBaseline = false
                }
            }
 // 二次真机复现：route 到位 ≠ 测试基线已取到——真机上详情
 // 渲染 + 测试轮询到 session-title 可能超过注入延迟，注入仍早于基线
 // （tap 已把 app 带走 / generation 已前进）。必须等**基线会话的详情页
 // 实际出现**（SessionDetailView.task 回调）再计延迟。
            if (link.phase.isConnected && onBaseline && e2eBaselineDetailAppeared) || polls >= 900 {
 // 就绪后再给首屏渲染一点余量。
                return DispatchQueue.main.asyncAfter(
                    deadline: .now() + .milliseconds(max(delayMs, minimumDelayMs))
                ) {
                    fire()
                }
            }
            polls += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { poll() }
        }
        poll()
    }
    #endif
}
