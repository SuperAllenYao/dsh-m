import Combine
import Foundation
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
        didSet { UserDefaults.standard.set(language.storageKey, forKey: "appLanguage") }
    }

    let link: LinkService
    let push = PushManager()
 /// Deep-link session lookup table, refreshed from every `session/list` load.
    private var deepLinkResolver = SessionDeepLinkResolver()
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
        #endif
 // Republish link state so views observing AppModel also refresh on link changes.
        link.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
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
                if let sessionId = notification.object as? String, !sessionId.isEmpty {
                    self.openSession(sessionId)
                } else {
                    self.route = .workspaces
                }
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

 // MARK: - M4 notification-action approvals

 /// Handles one routed notification response: allow/deny decisions are queued
 /// and answered with retry; unusable payloads fall back to the session.
    private func handlePushApprovalRoute(_ route: PushApprovalRoute) {
        switch route {
        case .approval(let decision):
            enqueueApprovalDecision(decision)
        case .fallback(let sessionId):
            showToast(L10n.t("审批信息不完整，请在 App 内处理"))
            if let sessionId, !sessionId.isEmpty {
                openSession(sessionId)
            }
        case .deepLink(let sessionId):
            if let sessionId, !sessionId.isEmpty {
                openSession(sessionId)
            } else {
                self.route = .workspaces
            }
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
        route = .workspaces
        push.bootstrap()
    }

 /// Opens a session by id (list taps and notification deep links).
    func openSession(_ sessionId: String) {
        subagentRoute = nil
        route = .session(sessionAddress(forDeepLink: sessionId))
    }

    func openSession(_ address: SessionFollowAddress) {
        subagentRoute = nil
        route = .session(address)
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
        subagentRoute = SubagentRoute(context: context, parentAddress: parentAddress)
        route = .session(context.followAddress)
    }

 /// Back from a session detail: subagent detail -> parent session; normal
 /// session -> workspace list.
    func backFromSession() {
        switch SessionBackNavigation.destination(subagentParent: subagentRoute?.parentAddress) {
        case .parentSession(let parentAddress):
            subagentRoute = nil
            route = .session(parentAddress)
        case .workspaces:
            subagentRoute = nil
            route = .workspaces
        }
    }

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
}
