import Combine
import Foundation

/// High-level link client: pairing, TLS-pinned HTTPS unary calls, the mux
/// WebSocket, $events (approval waterfall) subscription and reconnect state.
///
/// M1 pairing/auth flow (dsh-m-link v0.1.0):
/// signed QR payload -> GET /health (pin) -> POST /pair/redeem (P-256 device key)
/// -> POST /auth/challenge -> sign message -> POST /auth/verify -> short-lived
/// bearer token; unary uses the api token, the WSS mux uses a single-use mux token.
///
/// State machine: unpaired/disconnected -> connecting -> connected(ready);
/// "connected" is only published after $events receives its ready frame.
@MainActor
final class LinkService: ObservableObject {

    enum Phase: Equatable {
        case unpaired
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case needsRepair(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        var isBusy: Bool {
            switch self {
            case .connecting, .reconnecting: return true
            default: return false
            }
        }

        var label: String {
            switch self {
            case .unpaired: return L10n.t("未配对")
            case .disconnected: return L10n.t("已断开")
            case .connecting: return L10n.t("连接中")
            case .connected: return L10n.t("在线")
            case .reconnecting(let attempt): return L10n.f("重连中·%lld", attempt)
            case .needsRepair: return L10n.t("需要重新配对")
            }
        }
    }

    @Published private(set) var phase: Phase = .unpaired
    @Published private(set) var credentials: PairingCredentials?
    @Published private(set) var generation: Int = 0
    @Published var clientId: String?
 /// 当前连接上是否收到过 **本连接** 的 `$events` ready 帧。
 /// Host 只接受来自"拥有该事件流"的 Peer 的 `$events/result`；重连后沿用旧
 /// clientId 会得到 `gateway/interactions-forbidden: Remote event result belongs
 /// to another Peer`（用户 报障：作答/审批提交失败）。
    var eventsClientIdConfirmed = false
    @Published var pendingApprovals: [ApprovalWaterfall] = []
 /// Live user-question waterfalls from `$events` (task-2 / tech-design §14).
 /// `open` calls answer through `$events/result`; the pending list lets the
 /// UI observe live requests that have no snapshot projection yet.
    @Published var pendingUserQuestions: [UserQuestionWaterfall] = []
 /// `$events` 实时会话运行态（`api-session/status` emit）：列表卡片用它即时刷新
 /// 状态，不必等下一次 `session/list`（用户 报障：列表状态不实时）。
    @Published private(set) var liveSessionRunning: [String: Bool] = [:]
 /// 每次运行态 emit 递增，供列表页 `.onChange` 触发重算（map 值相等时 SwiftUI 不回调）。
    @Published private(set) var liveSessionStatusRevision = 0
 /// 每条 live 运行态 emit 的落库时间。emit 只用于补「快照请求在途」的短暂竞态；
 /// 超过 `WorkspaceViewModel.liveRunningOverlayMaxAge` 后不再覆盖 `session/list`
 /// 快照（快照是网络真值），避免丢帧/后台断连后卡片永久「假进行中」。
    private(set) var liveSessionRunningUpdatedAt: [String: Date] = [:]
    @Published private(set) var lastErrorText: String?
    @Published private(set) var lastConnectedAt: Date?
 /// 重连提速（最快 1s / 最迟 2s）：最近一次「网络切换信号 → 连接
 /// 成功」的耗时（毫秒）。只有 `handleNetworkPathChanged` 锚定的重连链会写入
 /// （切换→多轮退避重试→最终连上都算同一链）；其它来源的重连（前台恢复 /
 /// 看门狗 / 翻页）不覆盖它，E2E 与真机手动切换验收据此断言真实重连时长。
    @Published private(set) var lastSwitchReconnectMs: Int?
 /// 上一个切换锚定链的起点；连接成功时结算成 `lastSwitchReconnectMs` 后清空。
    private var switchReconnectStartedAt: Date?
 /// P0: E2E-gated `connect-metrics` summary of the last bring-up round.
    @Published private(set) var connectionMetricsValue: String?
 /// task-2 (reconnect): E2E-gated one-line `[RECONNECT]...` summary of the last
 /// page-enter / foreground reconnect chain (see `ReconnectMetrics`). Surfaced
 /// through the hidden `reconnect-metrics` element on the list page.
    @Published private(set) var reconnectMetricsValue: String?

 /// P0-4 guard: an early `session/list` before `phase ==.connected` is only
 /// worth issuing when the stored origin is dialable on this path. A stale LAN
 /// origin on cellular would just hang for the full auth timeout.
    var prefersEarlyUnary: Bool {
        guard let origin = credentials?.originURL else { return false }
        if NetworkPathMonitor.shared.prefersRelay && PairingOriginSelector.isLANHost(origin.host) {
            return false
        }
        return true
    }

 /// 冷启动 <1s：early/重试的 live `session/list` 可用的**可达 origin**。
 ///
 /// `prefersEarlyUnary` 在「持久化 origin 是 LAN + 当前是蜂窝/跨网」时为 false，
 /// 于是列表只能等 mux 连上后才刷新——真机上这就是「缓存刷新 10s」的放大器。
 /// 这里不改 `credentials.origin`（连接轮次正在用它逐候选拨号），而是返回一个
 /// **本次请求的 origin 覆盖**：蜂窝/跨网时取存储候选里的非 LAN（relay）地址。
 /// 无覆盖需求时返回 nil（走原路径，行为不变）。
    func earlyListOriginOverride() -> URL? {
        guard let credentials else { return nil }
        guard NetworkPathMonitor.shared.prefersRelay,
              let current = credentials.originURL,
              PairingOriginSelector.isLANHost(current.host) else { return nil }
        let candidates = PairingOriginSelector.reconnectCandidates(
            current: credentials.origin,
            stored: credentials.originCandidates
        )
        return candidates.first { !PairingOriginSelector.isLANHost($0.host) }
    }
 /// task-2: true when the network path changed after this link became ready —
 /// the live socket is then presumed stale even if `phase` still says
 /// `.connected` (the OS does not report a migrated socket as dead).
    var networkPathChangedSinceConnect: Bool {
        pathGenerationAtConnect != NetworkPathMonitor.shared.changeGeneration
    }
 /// v0.1.1 C: true while the one-shot `/health` CA-migration fetch runs, so
 /// repeated reconnects do not stack migration requests.
    var caTrustMigrationInFlight = false
    @Published private(set) var discoveredLeafPin: String?
    @Published private(set) var pairStep: String?

    let store = CredentialStore()
    private(set) var ws: WSSClient?
    private(set) var mux: RemoteMux?
 /// P1 single-WSS channel (dsh-m/2). Non-nil only while P1 is the active
 /// transport; the legacy `ws`/`mux` stay nil on that path.
    private(set) var p1Channel: P1Channel?
 /// Session-level P1 degradation: a fallback-class `P1Failure` (4400/4403 or
 /// 4401 with both ticket and ECDSA retry exhausted) makes every later round
 /// in this app session dial the legacy M1 path, until an explicit
 /// `reconnectNow()` or re-pair (design §6 rollback without re-pairing).
    var p1FellBackToLegacy = false
 /// Resume driver: retains the dsh-m/2 channel (and therefore its stream
 /// table) across a socket loss so the next round can continue it with
 /// `hello{resume}` (design §5 `RESUMING`).
    private(set) lazy var p1Resume = P1ResumeDriver { [weak self] host, port, leafPin, connectTimeout in
        P1Channel(
            host: host,
            port: port,
            leafPin: leafPin,
            caCertBase64: self?.credentials?.caCertBase64,
            path: P1Proto.socketPath,
            headers: [:],
            connectTimeout: connectTimeout,
            clientInfo: P1ClientInfo(name: "dsh-m-ios", version: Self.appVersion),
            helloTimeout: P1ProtocolLimits.helloTimeout,
 // 协议 v1：hello.caps.projV1 跟随客户端回滚开关。
            wantsProjV1: AppSettings.projV1Enabled
        )
    }
 /// True while the first reconnect after a resumable socket loss runs
 /// silently: `phase` stays `.connected` and no banner is painted, so a
 /// replay success produces no UI flash. Bounded by one candidate attempt.
    var p1SilentResume = false
 /// Timestamp of the socket loss, for the `recoverMs` replay metric.
    var p1LostAt: Date?

 // MARK: - DD-16 客户端回滚：projV1 开关运行中变化 → 受控重挂

 /// 目标生效值（合并在飞切换用；nil = 没有待处理的重挂）。
    private var projV1RemountTarget: Bool?
 /// 一轮受控重挂在飞（禁止并发重挂/重连风暴）。
    private var projV1RemountLoopRunning = false
 /// 观察 `AppSettings.projV1SettingDidChange` 的 token（与
 /// `firstByteTimeoutObserver` 同款：进程生命周期、弱引用 self）。
    private var projV1SettingObserver: NSObjectProtocol?
 /// 单测 seam：受控重挂真实执行次数（不触网络的断言用）。
    private(set) var projV1RemountCountForTesting = 0
 /// link-perf L2（DEC-D，设计变更二审）：冷启动能力探测是否已
 /// 消费——本 App 运行周期首次连接轮次探测一次（**不绑定 supportsMuxRPC**：
 /// 每周期都要重读 takeoverWindowMs 并探测插件回退，否则持久化的 true 会让
 /// 桌面端重启后的新窗口值永远读不到）；重连/网络切换轮次绝不探测。
 /// 409 保守升级会重置一次（见 `muxConflictAlignEscalated`）。
 ///
 /// D 段：探测从「首拨前串行 await」改成「本轮起点并行启动」，
 /// 不再占冷启关键路径的 500ms（见 `startColdStartCapabilityProbe`）。
    private var p1ColdStartProbeConsumed = false
 /// 本周期 /health 观测到的接管窗口：nil = 无有效观测值（探测未跑/失败，
 /// 或旧插件无字段——后者同时清空 credentials 缓存）。
    private var sessionTakeoverWindowMs: Int?
 /// 本周期是否已有一次成功的 /health 观测（含「旧插件无字段」结论）——
 /// true 后 credentials 缓存不再参与对齐（优先级：会话观测 > 缓存 > 兜底）。
    private var sessionTakeoverWindowObserved = false
 /// link-perf L1（设计变更二审兜底）：按已知窗口对齐的快重试
 /// 仍收到 409 → 后续重试一律保守 1.7s 对齐，并触发一次能力刷新。
    private var muxConflictAlignEscalated = false
 /// 单测 seam：探测的 /health 取数（nil = 生产路径 `HTTPSClient.json`）。
 /// hosted 单测与 E2E App 共享网络栈，注入后探测不触真实 origin。
    var p1ColdStartProbeFetch: (@MainActor (URL) async throws -> (status: Int, json: JSONValue))?
 /// 单测 seam：探测结果持久化（nil = 生产路径 `store.save`）。hosted 单测
 /// 与 E2E App 共享同一 Keychain，注入后探测不写真实凭据。
    var p1ColdStartProbePersist: ((PairingCredentials) -> Void)?
 /// 实施段（D 段 P1 修复）：在飞的冷启能力探测任务。
 ///
 /// 旧实现把它当 `connectOnce` 的局部变量并 `defer { cancel() }`——快连接
 /// （首拨 < 探测往返）时本轮一返回就取消探测，而 `p1ColdStartProbeConsumed`
 /// 已在启动时置 true → `supportsMuxRPC`/`takeoverWindowMs`/
 /// `sessionTakeoverWindowObserved` **整个 App 周期都不落地**（探测不再重试）。
 /// 现在任务挂在实例上，轮次出口不取消；只有登出/解绑（`disconnect`）取消。
 /// 任务自身 ≤ `p1ColdStartProbeTimeoutSeconds`（0.5s）有界、只弱引用 self，
 /// 不构成泄漏；结果写回与 `defer cancel` 无关。
    private(set) var coldProbeTask: Task<Void, Never>?
 /// 任务代次：避免「旧任务的完成清理」把后来新起的任务句柄清掉（取消/重探）。
    private var coldProbeGeneration = 0
    var eventsStream: RemoteStreamHandle?
    var connectTask: Task<Void, Never>?
    var retryTask: Task<Void, Never>?
 /// 最近一轮每个候选的失败类别：用于区分"桌面端还在启动"（插件未就绪/地址不可达）
 /// 与普通断网，从而在重启窗口内用短固定退避快速探测，不让退避滚到 10s。
    private var lastRoundFailureClasses: [CandidateFailureClass] = []
    var readyContinuation: CheckedContinuation<Void, Error>?
    var readyTimeoutTask: Task<Void, Never>?
 /// 冷启动 <1s：`$events` ready 握手已从「在线」判定里解耦，改成
 /// connected 之后的后台任务（失败则按传输失联重连）。这里保留句柄便于取消。
    var eventsHandshakeTask: Task<Void, Never>?
 /// 冷启动 <1s：共享 HTTPS 连接池预热任务（见 `warmHTTPSPoolIfColdStart`）。
    private var poolWarmupTask: Task<Void, Never>?
 /// T2(B1)：预热任务是否仍在飞——early list 等待它的唯一条件。
 /// 任务结束（成功或失败）后 `warmHTTPSPoolIfColdStart` 的 `defer` 会把上面
 /// 的句柄置 nil，所以这里为 false 即「无需等待」，热路径零延迟。
    var isPoolWarmupInFlight: Bool { poolWarmupTask != nil }
 /// Generation of the legacy `$events` ready handshake (v0.1.1 Bug 1). Stream
 /// callbacks and the timeout task capture it, so a retired stream (the one
 /// abandoned by the one-shot reopen) can neither resume nor fail the
 /// handshake that replaced it.
    var readyHandshakeGeneration = 0
 /// True once the 15s ready wait has reopened `$events` on the same mux.
    var readyReopenUsed = false
    var attempt = 0
    var isConnecting = false
    var manuallyDisconnected = false

 // MARK: - task-2 reconnect-chain state

 /// `NetworkPathMonitor.changeGeneration` at the last successful connect and at
 /// the start of the current round; together they tell "the socket died on a new
 /// network" from "this round already dialed on the new network".
    private var pathGenerationAtConnect = 0
    private var pathGenerationAtRoundStart = 0
 /// Dedupe: page enter + scenePhase + path change can all request a reconnect in
 /// the same few milliseconds; restarting a just-started round would cancel the
 /// candidate that is about to win.
    private var lastReconnectRequestAt: Date?
 /// 运行时端点自愈（用户）：最近一次连接成功后刷新
 /// `/health.deviceEndpoints` 的时间，用于节流。
    private var lastEndpointRefreshAt: Date?
 /// 网络路径变化 / 整轮失败后置脏：下一轮必须重新发现端点 + 并行探测，
 /// 不能沿用上一张网络的地址顺序。
    private var endpointsDirty = true
 /// Observer for `HTTPConnection`'s reused-socket first-byte watchdog.
    private var firstByteTimeoutObserver: NSObjectProtocol?
 /// 真机根因修复：首字节看门狗不再直接拆传输，先做一次
 /// 「新连接 /health」存活校验；这里是校验去抖与在飞任务。
    private var lastFirstByteVerificationAt: Date?
    private var transportVerificationTask: Task<Void, Never>?

 /// Short-lived api token (auto-refreshed on expiry/401).
    var apiToken: String?
    var apiTokenExpiresAt: Date?
 /// T2(B2)：api token 的本机 Keychain 持久化（scope 隔离）。
 /// 冷启动复用未过期 token → 省掉 challenge+verify 2 个 RTT。
    private let apiTokenStore = APITokenStore.shared
 /// 持久化 scope：Mac 的 hostId 优先；旧配对凭据没有 hostId（该字段
 /// 才引入，Keychain 里的凭据可能更旧）时回退到配对钉住的 leafPin（端点指纹）。
 /// 两者都缺时才放弃持久化。
    private var apiTokenScope: String? {
        APITokenStore.scope(hostId: credentials?.hostId, leafPin: credentials?.leafPin)
    }
 /// 主动续期单飞任务（剩余 < 20min 时后台 forceRefresh 一次）。
    private var apiTokenRenewalTask: Task<Void, Never>?
 /// One in-flight challenge/verify per purpose. **Purpose-scoped on purpose**:
 /// an api token cannot open the WSS mux and a single-use mux token cannot call
 /// unary endpoints, so sharing one in-flight task across purposes handed the
 /// wrong token to the second caller (mux upgrade 401 → reconnect loops).
    var authInFlightByPurpose: [String: Task<String, Error>] = [:]

    init() {
        credentials = store.load()
 // T2(B2)：冷启动直接恢复未过期的 api token（若本机 Keychain 有），
 // 让随后 connect 轮次里的 api token 预取命中快路径（省 2 个 RTT）。
        restorePersistedAPIToken()
 // task-2 (reconnect < 1s): one listener per app process. A meaningful path
 // change invalidates the live socket immediately instead of waiting for the
 // system TCP timeout; the reconnect then runs on the new path.
        NetworkPathMonitor.shared.onMeaningfulChange = { [weak self] in
            guard let self, !self.ignoresNetworkPathChangesForTesting else { return }
            self.handleNetworkPathChanged()
        }
        ReconnectMetrics.onChange = { [weak self] value in
            self?.reconnectMetricsValue = value
        }
 // A pooled unary request that produced no first byte within
 // `HTTPConnection.firstByteTimeout` means the keep-alive socket is dead
 // (network switch/Mac sleep). The mux almost always shares that fate.
        firstByteTimeoutObserver = NotificationCenter.default.addObserver(
            forName: .dshmHTTPFirstByteTimeout,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let endpoint = notification.userInfo?["endpoint"] as? String ?? "-"
            let host = notification.userInfo?["host"] as? String
            Task { @MainActor [weak self] in
                self?.handleFirstByteTimeout(endpoint: endpoint, host: host)
            }
        }
 // DD-16（AC-09/契约 §8 客户端回滚层）：projV1 开关有效值变化 → 受控重挂
 // transport（重新 hello 且不带/带上 caps.projV1），活连接立即生效。
 // 与 `firstByteTimeoutObserver` 同款生命周期（弱引用 self，无需手动移除：
 // 闭包不持有 self，token 随实例释放）。
        projV1SettingObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.projV1SettingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let enabled = notification.userInfo?["enabled"] as? Bool
                ?? AppSettings.projV1Enabled
            Task { @MainActor [weak self] in
                self?.applyProjV1SettingChange(enabled: enabled)
            }
        }
        if credentials != nil {
            phase = .connecting
            startConnecting()
        }
    }


 /// Picks a reachable origin from the QR payload and pairs, following the
 /// approved network policy (spec §3 A1/A2):
 /// - **same Wi-Fi**: one parallel LAN `/health` group (2 s budget) first, then
 /// the relay group as the fallback — the Mac's LAN address is the fastest path;
 /// - **cellular/cross-network**: relay origins only; LAN origins are never
 /// dialed (they can only burn the budget);
 /// - the whole sequence is capped by a 10 s total budget;
 /// - a failure is one actionable sentence plus per-host reasons (no link-type
 /// classification is ever exposed, spec §0.4).
    @discardableResult
    func pair(payload: PairingPayload, deviceName: String) async throws -> PairingCredentials {
        pairStep = "校验配对载荷"
        defer { pairStep = nil }

        if payload.isSigned {
 // The QR content is the out-of-band trust anchor: endpoints/pins/token
 // must be signed by the host Ed25519 key.
            guard payload.verifyHostSignature() else {
                throw LinkError.transport(L10n.t("配对载荷签名校验失败（载荷可能被篡改）"))
            }
 // Spec §3 A3 / D2 self-heal: adopt the control-plane relay config as
 // soon as the payload is **trusted** — *before* (not after) a
 // successful redeem — so a rotated relay certificate is refreshed by
 // scanning the QR once even if this pairing attempt fails later. A
 // legacy bad config (`relay.origin` = Mac bridge data endpoint, D1) is
 // never re-saved. Spec P2-2: an unsigned payload must never write the
 // relay config (there is no trust anchor for it).
            RelayConfigStore.adoptControlPlane(from: payload)
        }

        guard let pairToken = payload.token, !pairToken.isEmpty else {
            throw LinkError.transport(L10n.t("配对载荷缺少配对码（pair.token）"))
        }
        if payload.isExpired {
            throw LinkError.transport(L10n.t("二维码已过期，请在 Mac 上刷新后重扫。"))
        }

        let candidates = PairingOriginSelector.candidates(payload: payload)
        guard !candidates.isEmpty else {
            throw LinkError.transport(
                L10n.t("二维码里没有手机可访问的地址，请在 Mac 上刷新二维码后重扫。")
            )
        }
        let plan = PairingDialPolicy.plan(
            candidates: candidates,
            path: NetworkPathMonitor.shared.snapshot,
            local: NetworkPathMonitor.shared.currentLocalIPv4Network()
        )
        guard plan.isDialable else {
            if plan.rejection == .cellularWithoutRelay {
 // User policy: cellular/cross-network never falls back to the
 // Mac's LAN address; the relay must be advertised by the Mac.
                throw LinkError.transport(
                    L10n.t("无法连接 Mac。请确认 Mac 端连接页已打开，并在 Mac 上刷新二维码后重扫。")
                )
            }
            throw LinkError.transport(
                L10n.t("配对二维码里没有可用的 Mac 地址，请在 Mac 上刷新二维码后重扫。")
            )
        }
        let deadline = Date().addingTimeInterval(plan.totalBudget)
        var attemptSummaries: [String] = []

 // Strict plan order (spec P3): consecutive LAN/direct attempts run as one
 // parallel `/health` group (hard group budget when a relay step follows),
 // every relay attempt is dialed serially, and every step is clamped by the
 // total deadline. `plan.attempts` is the execution order — a relay-first
 // plan dials relay first and only then the LAN group.
        stepsLoop: for step in PairingDialPolicy.executionSteps(plan) {
            guard PairingDialPolicy.remainingBudget(deadline: deadline) != nil else { break stepsLoop }
            switch step {
            case .lanGroup(let lanAttempts):
                let groupBudget = plan.lanProbeBudget ?? PairingDialPolicy.lanProbeTimeout
                pairStep = "查找 Mac"
                let group = await probeLANGroup(lanAttempts, payload: payload, budget: groupBudget)
                attemptSummaries.append(contentsOf: group.failures)
                guard let pick = group.pick else { continue }
                guard let redeemTimeout = PairingDialPolicy.attemptTimeout(
                    cap: PairingDialPolicy.redeemTimeout,
                    deadline: deadline
                ) else { break stepsLoop }
                do {
                    return try await redeemPairingCredentials(
                        probe: pick.probe,
                        payload: payload,
                        pairToken: pairToken,
                        deviceName: deviceName,
                        candidates: candidates,
                        redeemTimeout: redeemTimeout,
                        deadline: deadline
                    )
                } catch {
                    attemptSummaries.append(Self.attemptSummary(origin: pick.origin, error: error))
                }
            case .relay(let attempt):
                pairStep = "连接 Mac"
                do {
                    return try await pairOn(
                        origin: attempt.url,
                        payload: payload,
                        pairToken: pairToken,
                        deviceName: deviceName,
                        candidates: candidates,
                        healthTimeout: PairingDialPolicy.relayHealthTimeout,
                        redeemTimeout: PairingDialPolicy.redeemTimeout,
                        deadline: deadline
                    )
                } catch {
                    attemptSummaries.append(Self.attemptSummary(origin: attempt.url, error: error))
                }
            }
        }

 // Everything inside the budget failed: one actionable sentence + the
 // per-host reasons (host level only, no link-type wording).
        let head = L10n.t("无法连接 Mac。请确认 Mac 端连接页已打开，并在 Mac 上刷新二维码后重扫。")
        guard !attemptSummaries.isEmpty else { throw LinkError.transport(head) }
        throw LinkError.transport(head + "\n" + attemptSummaries.joined(separator: "\n"))
    }

 /// Result of one `/health` probe: everything the redeem step needs.
    private struct PairingOriginProbe {
        var origin: URL
        var healthJSON: JSONValue
        var effectivePin: String
    }

 /// Winner of the parallel LAN probe group.
    private struct PairingLANGroupPick {
        var origin: URL
        var probe: PairingOriginProbe
    }

 /// One pairing attempt against a concrete origin: /health -> /pair/redeem.
    private func pairOn(
        origin: URL,
        payload: PairingPayload,
        pairToken: String,
        deviceName: String,
        candidates: [URL],
        healthTimeout: TimeInterval = PairingDialPolicy.relayHealthTimeout,
        redeemTimeout: TimeInterval = PairingDialPolicy.redeemTimeout,
        deadline: Date? = nil,
        prefetchedProbe: PairingOriginProbe? = nil
    ) async throws -> PairingCredentials {
        let probe: PairingOriginProbe
        if let prefetchedProbe, prefetchedProbe.origin == origin {
            probe = prefetchedProbe
        } else {
            probe = try await probePairingOrigin(
                origin: origin,
                payload: payload,
                healthTimeout: healthTimeout,
                deadline: deadline
            )
        }
        return try await redeemPairingCredentials(
            probe: probe,
            payload: payload,
            pairToken: pairToken,
            deviceName: deviceName,
            candidates: candidates,
            redeemTimeout: redeemTimeout,
            deadline: deadline
        )
    }

 /// Pinned `/health` check for one origin: status/ok, leaf pin consistency
 /// (payload pin wins; TOFU only when the payload has no pin) and CA pin check.
    private func probePairingOrigin(
        origin: URL,
        payload: PairingPayload,
        healthTimeout: TimeInterval,
        deadline: Date?
    ) async throws -> PairingOriginProbe {
        guard let host = origin.host, !host.isEmpty else {
            throw LinkError.transport(L10n.f("配对 origin 缺少 host: %@", origin.absoluteString))
        }
        guard origin.scheme?.lowercased() == "https" else {
            throw LinkError.transport(L10n.t("配对 origin 必须是 https"))
        }
        let timeout = try Self.boundedTimeout(cap: healthTimeout, deadline: deadline)
        let requestedPin = payload.tlsLeafPinHex
        let health = try await HTTPSClient.json(
            origin: origin,
            method: "GET",
            path: "/health",
            leafPin: requestedPin,
            timeout: timeout
        )
        guard health.status == 200, health.json["ok"]?.boolValue == true else {
            throw LinkError.transport(L10n.f("link 插件 /health 不可用（HTTP %lld）", health.status))
        }
        let reportedLeaf = PinFormat.normalize(health.json["tls"]?["leafFingerprint256"]?.stringValue)
            ?? PinFormat.hexFromBase64URL(health.json["tls"]?["leafPin"]?.stringValue)
        let reportedCA = PinFormat.normalize(health.json["tls"]?["caFingerprint256"]?.stringValue)
            ?? PinFormat.hexFromBase64URL(health.json["tls"]?["caPin"]?.stringValue)
        let effectivePin: String
        if let requestedPin {
            effectivePin = requestedPin
            if let reportedLeaf, reportedLeaf != requestedPin {
                throw LinkError.tlsPinMismatch(expected: requestedPin, actual: reportedLeaf)
            }
        } else if let reportedLeaf {
            effectivePin = reportedLeaf
        } else if let observed = health.observedLeafPin {
            effectivePin = observed
        } else {
            throw LinkError.tlsPinMismatch(expected: "unknown", actual: nil)
        }
        if let caPin = payload.tlsCAPinHex, let reportedCA, caPin != reportedCA {
            throw LinkError.transport(L10n.t("配对载荷 CA 指纹与 link 插件不一致"))
        }
        discoveredLeafPin = effectivePin
        return PairingOriginProbe(origin: origin, healthJSON: health.json, effectivePin: effectivePin)
    }

 /// Parallel `/health` probe of the LAN/direct group (spec §3 A2): every origin
 /// gets a 1.5 s timeout, the whole group never exceeds `budget`, and the first
 /// success wins (cancelling the remaining probes). Returns per-host failures so
 /// the aggregated message can still say *why* every address failed.
    private func probeLANGroup(
        _ attempts: [PairingDialAttempt],
        payload: PairingPayload,
        budget: TimeInterval
    ) async -> (pick: PairingLANGroupPick?, failures: [String]) {
        guard !attempts.isEmpty else { return (nil, []) }
        let probeTimeout = min(PairingDialPolicy.lanProbeTimeout, max(0.2, budget))
        var pick: PairingLANGroupPick?
        var failures: [String] = []
        await withTaskGroup(
            of: (index: Int, origin: URL, probe: PairingOriginProbe?, failure: String?).self
        ) { group in
            for (index, attempt) in attempts.enumerated() {
                group.addTask { [self] in
                    do {
                        let probe = try await probePairingOrigin(
                            origin: attempt.url,
                            payload: payload,
                            healthTimeout: probeTimeout,
                            deadline: nil
                        )
                        return (index, attempt.url, probe, nil)
                    } catch {
                        return (index, attempt.url, nil, Self.attemptSummary(origin: attempt.url, error: error))
                    }
                }
            }
            for await result in group {
                if let probe = result.probe {
                    pick = PairingLANGroupPick(origin: result.origin, probe: probe)
                    group.cancelAll()
                    return
                }
                if let failure = result.failure {
                    failures.append(failure)
                }
            }
        }
        return (pick, failures)
    }

 /// One host-level line for the aggregated pairing failure. Deliberately has no
 /// "LAN / relay / 直连 / 中继" wording (link type stays silent).
    private nonisolated static func attemptSummary(origin: URL, error: Error) -> String {
        let host = origin.host ?? origin.absoluteString
        return host + "：" + NetworkErrorInterpreter.message(for: error)
    }

 /// Attempt timeout clamped to the remaining total pairing budget.
    private static func boundedTimeout(cap: TimeInterval, deadline: Date?) throws -> TimeInterval {
        guard let deadline else { return cap }
        guard let timeout = PairingDialPolicy.attemptTimeout(cap: cap, deadline: deadline) else {
            throw LinkError.transport(L10n.t("配对超时，请重试"))
        }
        return timeout
    }

 /// Redeems device credentials on an origin whose `/health` just passed.
    private func redeemPairingCredentials(
        probe: PairingOriginProbe,
        payload: PairingPayload,
        pairToken: String,
        deviceName: String,
        candidates: [URL],
        redeemTimeout: TimeInterval,
        deadline: Date?
    ) async throws -> PairingCredentials {
        let origin = probe.origin
        let healthJSON = probe.healthJSON
        let effectivePin = probe.effectivePin
        let timeout = try Self.boundedTimeout(cap: redeemTimeout, deadline: deadline)

 // Device identity: the plugin binds the credential to this P-256 key and
 // requires a signature for every /auth/challenge afterwards.
        let devicePubKey = DeviceIdentity.shared.publicKeyBase64URL
        pairStep = "兑换设备凭据"
        let redeemBody = JSONValue.object([
            "pairToken": .string(pairToken),
            "devicePubKey": .string(devicePubKey),
            "deviceName": .string(deviceName),
            "platform": .string("ios"),
        ])
        let redeem = try await HTTPSClient.json(
            origin: origin,
            method: "POST",
            path: "/pair/redeem",
            body: redeemBody,
            leafPin: effectivePin,
            timeout: timeout
        )
        guard redeem.status == 200, redeem.json["ok"]?.boolValue == true else {
            let code = redeem.json["error"]?.stringValue ?? "unknown"
            switch code {
            case "pair/invalid":
                throw LinkError.transport(L10n.t("配对码无效或已被使用，请在 Mac 上刷新二维码"))
            case "pair/expired":
                throw LinkError.transport(L10n.t("二维码已过期，请在 Mac 上刷新后重扫。"))
            case "pair/rate-limited":
                throw LinkError.transport(L10n.t("配对尝试过于频繁，请稍后再试"))
            case "pair/invalid-key":
                throw LinkError.transport(L10n.f("设备公钥被拒绝: %@", redeem.json["message"]?.stringValue ?? "invalid-key"))
            case "host/starting", "host/incompatible":
                throw LinkError.transport(L10n.t("桌面端插件尚未就绪或不兼容，请在 Mac 上检查 DSH-m 连接页"))
            default:
                throw LinkError.httpStatus(redeem.status, redeem.json["message"]?.stringValue ?? code)
            }
        }
        guard let deviceId = redeem.json["deviceId"]?.stringValue,
              let credential = redeem.json["credential"]?.stringValue, !credential.isEmpty else {
            throw LinkError.malformedEnvelope(L10n.t("/pair/redeem 响应缺少 deviceId/credential"))
        }
        if let proto = redeem.json["proto"]?.stringValue, proto != "dsh-m/1" {
            throw LinkError.transport(L10n.f("桌面端插件协议版本不匹配（%@）", proto))
        }
 // /pair/redeem repeats the plugin's SPKI pins (base64url). Compare them
 // with the QR payload's SPKI pins — the handshake pin is the certificate
 // fingerprint256 and must not be compared against these.
        if let expectedSPKI = payload.tls?.leafPin,
           let serverSPKI = redeem.json["tls"]?["leafPin"]?.stringValue,
           expectedSPKI != serverSPKI {
            throw LinkError.tlsPinMismatch(expected: expectedSPKI, actual: serverSPKI)
        }

        var normalizedOrigin = origin.absoluteString
        while normalizedOrigin.hasSuffix("/") { normalizedOrigin.removeLast() }
 // M2b P1-②: the manual pairing form (origin + one-time code) only carries
 // one origin, so learn every phone-facing origin (LAN interfaces + the M2a
 // relay bridge) from the /health document we just verified; otherwise a
 // LAN-paired phone cannot fall back to the relay after switching to
 // cellular. Payload/code pairing keeps its exact candidate order.
        let learnedCandidates = Self.mergeOriginCandidates(
            currentOrigin: origin,
            payloadCandidates: candidates,
            relayOrigin: nil,
            healthDeviceEndpoints: Self.healthDeviceEndpoints(from: healthJSON)
        )
 // P1: remember the plugin's single-WSS capability + in-band auth tickets
 // at pairing time, so a cold start/reconnect can skip the "anonymous
 // upgrade -> 401 -> fallback" probe (design §4.3/§6).
        let p1Capabilities = Self.p1HealthCapabilities(from: healthJSON)
        let seededTickets = redeem.json["connectTickets"]?.arrayValue?.compactMap { $0.stringValue }
        let credentials = PairingCredentials(
            origin: normalizedOrigin,
            leafPin: effectivePin,
            caCertBase64: payload.tlsCACertBase64 ?? healthJSON["tls"]?["caCert"]?.stringValue,
            deviceId: deviceId,
            credential: credential,
            deviceName: deviceName,
            pairedAt: Int64(Date().timeIntervalSince1970 * 1000),
            keyId: redeem.json["keyId"]?.stringValue,
            originCandidates: learnedCandidates,
            supportsMuxRPC: p1Capabilities.supportsMuxRPC,
            connectTickets: seededTickets,
            p1Epoch: nil,
            p1Sid: nil,
            takeoverWindowMs: p1Capabilities.takeoverWindowMs,
            hostId: payload.host?.id
        )
        adopt(credentials: credentials)
 // M2a: remember the control-plane relay config advertised by the Mac so
 // public lookup/reconnect works without a second server-config scan. The
 // adoption ran right after signature verification (self-heal, spec §3 A3);
 // repeating it here keeps the original "commit on success" semantics and
 // is idempotent. Spec P2-2: an unsigned (manual) payload must never write
 // the relay config; the store re-checks `payload.isSigned` as defence in
 // depth, and validation rejects legacy bridge data origins.
        if payload.isSigned {
            RelayConfigStore.adoptControlPlane(from: payload)
        }
        return credentials
    }

 // MARK: - Learned pairing origin candidates (M2b P1-②)

 /// Builds `PairingCredentials.originCandidates` after a successful pairing.
 ///
 /// The manual pairing form (origin + one-time code) produces a payload with a
 /// single origin, so without learning the Mac's other phone-facing origins the
 /// phone would never fall back from LAN to the M2a relay when it leaves the
 /// Wi-Fi (measured in earlier device runs). Sources, in priority order:
 /// 1. the origin that just completed pairing — every reconnect round starts
 /// from the current origin (design §4.7);
 /// 2. the payload candidates in their existing order, so payload/code pairing
 /// keeps its exact candidate order and is not duplicated;
 /// 3. `/health.deviceEndpoints` — every origin the phone may dial.
 ///
 /// Spec §3 A3: `relayOrigin` is **ignored** (parameter kept for source
 /// compatibility). The payload's top-level `relay.origin` is the relay
 /// *control plane* origin since D1's fix, not a Mac data-plane origin; the
 /// Mac's relay bridge endpoint is already covered by `/health.deviceEndpoints`
 /// (and by `endpoints[]` in payload candidates). Persisting the control
 /// origin here used to make every reconnect dial the relay server with the
 /// Mac certificate pin (TLS failure).
 ///
 /// Learned origins must be https and non-loopback, and are de-duplicated
 /// against everything before them: on a physical iPhone 127.0.0.1/localhost/
 ///1 point at the phone itself. The current origin is kept even when it is
 /// loopback (the iOS simulator shares the Mac's network namespace).
    nonisolated static func mergeOriginCandidates(
        currentOrigin: URL,
        payloadCandidates: [URL],
        relayOrigin: String?,
        healthDeviceEndpoints: [String]
    ) -> [String] {
        _ = relayOrigin
        var seen = Set<String>()
        var result: [String] = []

        func append(_ url: URL, allowLoopback: Bool) {
            guard url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty else { return }
            if !allowLoopback, PairingOriginSelector.isLoopbackHost(host) { return }
            let text = PairingOriginSelector.normalizedOriginString(url)
            guard seen.insert(text.lowercased()).inserted else { return }
            result.append(text)
        }

        append(currentOrigin, allowLoopback: true)
        for candidate in payloadCandidates {
            append(candidate, allowLoopback: true)
        }
        for text in healthDeviceEndpoints {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed) else { continue }
            append(url, allowLoopback: false)
        }
        return result
    }

 /// `/health.deviceEndpoints` as URL strings (M1 plugin contract: an array of
 /// strings; M1-era / LAN-only hosts may omit the field entirely).
    nonisolated static func healthDeviceEndpoints(from healthJSON: JSONValue) -> [String] {
        (healthJSON["deviceEndpoints"]?.arrayValue ?? []).compactMap { $0.stringValue }
    }

 /// /health → P1 能力与接管窗口。
 /// 配对路径与冷启动能力探测共用；muxRpc/proto 解析口径与原配对路径逐字
 /// 一致，`takeoverWindowMs` 只接受正值（防御畸形 /health，正常值 800/1500）。
    nonisolated static func p1HealthCapabilities(
        from healthJSON: JSONValue
    ) -> (supportsMuxRPC: Bool, takeoverWindowMs: Int?) {
        let supportsMuxRPC: Bool
        if let flag = healthJSON["features"]?["muxRpc"]?.boolValue {
            supportsMuxRPC = flag
        } else if let proto = healthJSON["proto"]?.stringValue {
            supportsMuxRPC = proto.contains("dsh-m/2")
        } else if let protos = healthJSON["proto"]?.arrayValue {
            supportsMuxRPC = protos.contains { $0.stringValue == "dsh-m/2" }
        } else {
            supportsMuxRPC = false
        }
        let takeoverWindowMs = healthJSON["features"]?["takeoverWindowMs"]?.intValue
            .flatMap { $0 > 0 ? Int($0) : nil }
        return (supportsMuxRPC, takeoverWindowMs)
    }

 /// Persists freshly minted pairing credentials and (re)starts the connection
 /// loop. Shared by QR/manual pairing and the M2a pairing-code redeem flow.
    @discardableResult
    func adopt(credentials: PairingCredentials) -> PairingCredentials {
        let previousScope = apiTokenScope
        do {
            try store.save(credentials)
        } catch {
            lastErrorText = L10n.f("凭据保存失败: %@", error.localizedDescription)
        }
        self.credentials = credentials
        var origin = credentials.origin
        while origin.hasSuffix("/") { origin.removeLast() }
        AppSettings.lastOrigin = origin
        apiToken = nil
        apiTokenExpiresAt = nil
 // T2(B2)：重新配对 = 全新凭据语境，旧机器/旧会话的持久化 api token
 // 一律作废（不允许在 repair 之后仍复用旧 token）。
        apiTokenStore.clear(scope: previousScope)
        apiTokenStore.clear(scope: apiTokenScope)
        attempt = 0
        manuallyDisconnected = false
        p1FellBackToLegacy = false
        p1SilentResume = false
        p1LostAt = nil
 // link-perf L2/L1：重新配对 = 全新能力语境，冷启动探测与
 // 409 保守升级状态一并复位（新插件/新窗口值立即重学）。
 //
 // B-1（审查阻断）：复位「已探测」标记之前必须**取消在飞探测**——否则
 // 旧探测（快照是上一台设备/上一套凭据）会在 ≤0.5s 后落地并写回，把刚
 // adopt 的新凭据顶掉（配对语义损坏 / 需二次扫码）。取消会推进探测代次，
 // 写回处还有代次 + deviceId 双重校验兜底。
        cancelColdStartCapabilityProbe()
        p1ColdStartProbeConsumed = false
        sessionTakeoverWindowObserved = false
        sessionTakeoverWindowMs = nil
        muxConflictAlignEscalated = false
        p1Resume.discard()
 // 新配对 = 全新端点语境：下一轮必须重新发现（mDNS + /health 探测）。
        endpointsDirty = true
        lastEndpointRefreshAt = nil
        phase = .connecting
        startConnecting()
        return credentials
    }

 // MARK: - Auth tokens (ECDSA-P256 challenge/verify)

 /// Returns a valid api bearer token, refreshing it when close to expiry.
 ///
 /// `originOverride`: the early `session/list` may be
 /// issued against the relay origin while the persisted `credentials.origin` is a
 /// stale LAN address (cellular / cross-network). Without the override that
 /// request would hang on the unreachable LAN origin and the list would only load
 /// after the mux connect finished — the amplified 10s stale-cache case.
 ///
 /// T2(B2)：快路径去掉「`originOverride == nil`」限制。token 是插件
 /// 实例级的（与 origin 覆盖无关），冷启动从 Keychain 恢复的有效 token 在蜂窝
 /// relay 覆盖下同样可用；否则早列表会白白再付 challenge+verify 2 个 RTT。
    func ensureAPIToken(forceRefresh: Bool = false, originOverride: URL? = nil) async throws -> String {
        if !forceRefresh, let apiToken, let expiry = apiTokenExpiresAt, expiry.timeIntervalSinceNow > 5 {
 // 冷启动 early list 走覆盖 origin 时打一行诊断（无 token 明文），下一次
 // 真机 console 就能区分「token 命中」与「又发生 auth」。
            if originOverride != nil { linkDebug("api token fast-path hit (early list)") }
            return apiToken
        }
        do {
            return try await authenticateToken(purpose: "api", originOverride: originOverride)
        } catch {
 // 设备被撤销/凭据失效：本机持久化的 token 一并作废，避免下一次冷启动
 // 又拿旧 token 撞 401（之后由既有 repair 提示要求重新配对）。
            if isCredentialRejection(error) {
                apiToken = nil
                apiTokenExpiresAt = nil
                apiTokenStore.clear(scope: apiTokenScope)
            }
            throw error
        }
    }

 /// T2(B2)：冷启动从 Keychain 恢复未过期的 api token。
 /// 只在内存里没有 token 时执行（断开/恢复场景走同一入口）。
    private func restorePersistedAPIToken() {
        guard apiToken == nil, let scope = apiTokenScope,
              let stored = apiTokenStore.load(scope: scope) else {
            linkDebug("api token not restored scope=" + Self.apiTokenScopeKind(apiTokenScope))
            return
        }
        apiToken = stored.token
        apiTokenExpiresAt = stored.expiresAt
        linkDebug("api token restored scope=" + Self.apiTokenScopeKind(scope))
    }

 /// T2(B2)：认证成功后把 api token 落盘（只存本机 Keychain，不打印 token）。
    private func persistAPIToken(_ token: String, expiresAt: Date) {
        guard let scope = apiTokenScope else {
            linkDebug("api token persist skipped: no scope")
            return
        }
        let saved = apiTokenStore.save(StoredAPIToken(token: token, expiresAt: expiresAt), scope: scope)
        linkDebug("api token persist " + (saved ? "ok" : "failed") + " scope=" + Self.apiTokenScopeKind(scope))
    }

 /// 诊断用：scope 类型（host / pin / none），不含任何敏感原值。
    private static func apiTokenScopeKind(_ scope: String?) -> String {
        guard let scope else { return "none" }
        return scope.hasPrefix("pin:") ? "pin" : "host"
    }

 /// T2(B2)：链路就绪/前台恢复时，若 api token 剩余 < 20min，后台
 /// 静默续期一次——避免 60min TTL 用尽后下一次冷启动又要 2 个 RTT 认证。
 ///
 /// 单飞：已有续期任务在飞则跳过；与普通请求共享 `authInFlightByPurpose` 的
 /// 「api」in-flight challenge；失败静默（401/下次 connected 仍走既有路径）。
    private func renewAPITokenIfNeededAfterConnect() {
        guard apiToken != nil,
              APITokenStore.shouldRenew(
                  expiresAt: apiTokenExpiresAt,
                  inFlight: apiTokenRenewalTask != nil
              ) else { return }
        apiTokenRenewalTask = Task { [weak self] in
            defer { self?.apiTokenRenewalTask = nil }
            guard let self else { return }
 // 让出冷启动首屏关键路径：列表/首帧通常 1.5s 内落地，续期只是后台保鲜，
 // 不要和 early session/list 抢同一条 relay 连接（省得把 T2 重新拉长）。
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, self.phase.isConnected else { return }
            linkDebug("api token renewal (remaining < 20min)")
            _ = try? await self.ensureAPIToken(forceRefresh: true)
        }
    }

 /// One challenge/verify round trip. Concurrent callers share one in-flight
 /// challenge (the plugin rate-limits challenges).
    func authenticateToken(purpose: String, timeout: TimeInterval = 15, originOverride: URL? = nil) async throws -> String {
        let inFlightKey = originOverride.map { purpose + "@" + $0.absoluteString } ?? purpose
        if let inFlight = authInFlightByPurpose[inFlightKey] {
            do {
                return try await inFlight.value
            } catch {
 // Fall through and try once with a fresh challenge.
            }
        }
        let task = Task { [weak self] () throws -> String in
            guard let self else { throw LinkError.notConnected }
            return try await self.performAuthentication(purpose: purpose, timeout: timeout, originOverride: originOverride)
        }
        authInFlightByPurpose[inFlightKey] = task
        defer { authInFlightByPurpose[inFlightKey] = nil }
        return try await task.value
    }

    private func performAuthentication(purpose: String, timeout: TimeInterval, originOverride: URL? = nil) async throws -> String {
        guard let credentials, let origin = originOverride ?? credentials.originURL else { throw LinkError.notPaired }
        let challenge = try await HTTPSClient.json(
            origin: origin,
            method: "POST",
            path: "/auth/challenge",
            headers: ["authorization": "Bearer \(credentials.credential)"],
            body: .object(["purpose": .string(purpose)]),
            leafPin: credentials.leafPin,
            caCertBase64: credentials.caCertBase64,
            timeout: timeout
        )
        guard challenge.status == 200,
              challenge.json["ok"]?.boolValue == true,
              let challengeId = challenge.json["challengeId"]?.stringValue,
              let message = challenge.json["message"]?.stringValue else {
            let code = challenge.json["error"]?.stringValue ?? "unknown"
            if challenge.status == 401 {
                throw LinkError.transport(L10n.f("设备凭据已失效（%@），请重新配对", code))
            }
            throw LinkError.httpStatus(challenge.status, code)
        }
        let signature: String
        do {
            signature = try DeviceIdentity.shared.signatureBase64URL(message: message)
        } catch {
            throw LinkError.transport(L10n.f("设备密钥签名失败: %@", error.localizedDescription))
        }
        let verify = try await HTTPSClient.json(
            origin: origin,
            method: "POST",
            path: "/auth/verify",
            body: .object([
                "challengeId": .string(challengeId),
                "signature": .string(signature),
            ]),
            leafPin: credentials.leafPin,
            caCertBase64: credentials.caCertBase64,
            timeout: timeout
        )
        guard verify.status == 200,
              verify.json["ok"]?.boolValue == true,
              let token = verify.json["token"]?.stringValue else {
            let code = verify.json["error"]?.stringValue ?? "unknown"
            throw LinkError.transport(L10n.f("设备认证失败（%@），请重新配对", code))
        }
        if purpose == "api" {
            apiToken = token
            let expiresAt: Date
            if let expires = verify.json["expiresAt"]?.intValue {
                expiresAt = Date(timeIntervalSince1970: TimeInterval(expires) / 1000)
            } else {
                expiresAt = Date().addingTimeInterval(600)
            }
            apiTokenExpiresAt = expiresAt
 // T2(B2)：认证成功后落盘，供下一次冷启动直接复用。
            persistAPIToken(token, expiresAt: expiresAt)
        }
        return token
    }

 // MARK: - CA trust migration (v0.1.1 C)

 /// Legacy pairings persisted only the exact leaf-certificate pin. Once the
 /// link is up — which already authenticated the current leaf pin or the
 /// pinned CA — fetch `/health` through that trusted connection and persist the
 /// plugin's public CA certificate, so every later connection validates the CA
 /// chain and a re-issued leaf never forces a re-pair. Best effort: a failure
 /// keeps the leaf-pin fallback and retries on the next connected round.
    func startCATrustMigrationIfNeeded() {
        guard credentials?.caCertBase64 == nil, !caTrustMigrationInFlight else { return }
        Task { [weak self] in
            await self?.migrateCATrustIfNeeded()
        }
    }

    private func migrateCATrustIfNeeded() async {
        guard !caTrustMigrationInFlight,
              let current = credentials,
              current.caCertBase64 == nil,
              let origin = current.originURL else { return }
        caTrustMigrationInFlight = true
        defer { caTrustMigrationInFlight = false }
        do {
            let health = try await HTTPSClient.json(
                origin: origin,
                method: "GET",
                path: "/health",
                leafPin: current.leafPin,
                timeout: 10
            )
            guard health.status == 200,
                  let caCert = health.json["tls"]?["caCert"]?.stringValue,
                  !caCert.isEmpty,
                  let data = Data(base64Encoded: caCert, options: [.ignoreUnknownCharacters]),
                  !data.isEmpty else { return }
 // The connection may have re-paired / rotated origin while the fetch
 // was in flight: only stamp the same device's current credential.
            guard var latest = credentials, latest.deviceId == current.deviceId else { return }
            latest.caCertBase64 = caCert
            credentials = latest
            try? store.save(latest)
            #if DEBUG
            print("[dshm] ca-trust migrated: device=\(latest.deviceId.prefix(8)) caCertLen=\(caCert.count)")
            #endif
        } catch {
 // Best effort; the leaf-pin fallback remains valid.
            #if DEBUG
            print("[dshm] ca-trust migration failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func isCredentialRejection(_ error: Error) -> Bool {
        if let linkError = error as? LinkError {
            switch linkError {
            case .httpStatus(401, _), .httpStatus(403, _):
                return true
            case .transport(let message):
                return message.contains("重新配对") || message.lowercased().contains("pair again")
            default:
                return false
            }
        }
        return false
    }

 // MARK: - Connection lifecycle

    func startConnecting() {
        guard credentials != nil else {
            phase = .unpaired
            return
        }
 // T2(B2)：手动断开后重连时恢复本机持久化的 api token。
        restorePersistedAPIToken()
        retryTask?.cancel()
        retryTask = nil
        if isConnecting { return }
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            await self?.connectOnce()
        }
    }

    func reconnectNow() {
        guard credentials != nil else { return }
 // task-2: page enter + scenePhase + path change can all request a reconnect
 // in the same few milliseconds; restarting a just-started round would cancel
 // the candidate that is about to win. (An explicit user retry after a long
 // wait is not throttled: the phase is not busy then.)
        if phase.isBusy, let last = lastReconnectRequestAt,
           Date().timeIntervalSince(last) < 0.3 {
            return
        }
        lastReconnectRequestAt = Date()
        retryTask?.cancel()
        retryTask = nil
        attempt = 0
        manuallyDisconnected = false
 // An explicit reconnect is the operator/UI retry: probe dsh-m/2 again
 // even if an earlier round degraded to the legacy path, and do a full
 // rebuild instead of continuing a retained resume channel.
        p1FellBackToLegacy = false
        p1SilentResume = false
        p1LostAt = nil
        p1Resume.discard()
        isConnecting = false
        connectTask?.cancel()
        phase = .connecting
        connectTask = Task { [weak self] in
            await self?.connectOnce()
        }
    }

 // MARK: - DD-16 客户端回滚：projV1 开关运行中变化 → 受控重挂

 /// DD-16（AC-09/契约 §8）：把「projV1 开关有效值」应用到**活连接**上。
 ///
 /// 语义（设计 DD-16 + 契约 §8 客户端行）：
 /// - 关闭 → 主动重挂 transport，重新发 hello 且**不带** `caps.projV1`，插件
 /// `onHello` 按新 caps 重算 `projV1Enabled`（`mux-rpc.js` `attachTransport`
 /// 先清零、`onHello` 再算），因此活连接此后不再收到 `0x02` 投影帧；
 /// - 打开 → 对称恢复（重挂后 hello 带 caps.projV1，重新协商）；
 /// - 无活 P1 连接（未连接 / legacy 路径 / 正在重连）：不需要重挂，下一轮
 /// `attemptP1Connection` 建通道时自然读新值（见那里的同款同步）；
 /// - 会话状态由 resume 保持：只关旧 socket、保留流表，重挂轮次走
 /// `hello{resume}` + `welcome.resume.mode=replay` 的静默续传（不闪断、不重建）；
 /// - 不产生并发重连风暴：同值/已在目标值 no-op，在飞时目标值合并，循环结束
 /// 后按最新目标最多再补一次；
 /// - 重挂失败 → 回到既有重连退避（`connectOnce` 的多候选 + `scheduleReconnect`）。
 ///
 /// 未暴露给用户 UI（DEBUG/排障开关）；E2E 通过
 /// `AppSettings.setProjV1Enabled(_:)` 触发。
    func applyProjV1SettingChange(enabled: Bool) {
 // 未连接/legacy：下一轮自然按新值协商，不必重挂（也不制造流量）。
        guard phase.isConnected, p1Channel != nil, credentials != nil,
              !manuallyDisconnected else {
            projV1RemountTarget = nil
            return
        }
        projV1RemountTarget = enabled
        guard !projV1RemountLoopRunning else { return }
        startProjV1RemountLoop()
    }

    private func startProjV1RemountLoop() {
        projV1RemountLoopRunning = true
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            await self?.runProjV1RemountLoop()
        }
    }

 /// 一轮（或按合并后的最新目标补一轮）受控重挂。只做「关旧 socket → 改 hello
 /// 协商位 → 标 resume 保留 → 跑一次 silent-resume 轮次」，不新增网络预算。
 ///
 /// 合并语义：循环每次都读**最新**目标值；同一目标已被当前通道协商 → 不重挂。
 /// 若恰有一轮连接在飞（silent resume 期间 `phase` 仍是 connected），不抢跑，
 /// 等它落地后按最新目标决定是否需要补一次（有界等待，绝不并发重连）。
    private func runProjV1RemountLoop() async {
        defer { projV1RemountLoopRunning = false }
        let deadline = Date().addingTimeInterval(Self.projV1RemountWaitForRoundSeconds)
        while let target = projV1RemountTarget {
            guard phase.isConnected, let channel = p1Channel else {
                projV1RemountTarget = nil
                return
            }
            if isConnecting {
                guard Date() < deadline else {
 // 在飞轮次迟迟不结束：目标留给下一次自然重连（attemptP1Connection
 // 也会按当前开关值重新协商），不在这里制造并发重连。
                    projV1RemountTarget = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            projV1RemountTarget = nil
            guard channel.wantsProjV1 != target else { continue }
            retryTask?.cancel()
            retryTask = nil
 // 1) 关旧 socket（流表保留，供 resume）；2) 改下一次 hello 的 caps；
 // 3) 标成 resume 保留 + silent 轮次（phase 不闪断、generation 不 bump）。
            channel.disconnect(reason: "projV1 开关变更重挂")
            channel.applyWantsProjV1ForRemount(target)
            p1Resume.retainAfterSocketLoss()
            p1SilentResume = true
            p1LostAt = Date()
            projV1RemountCountForTesting += 1
            if let round = projV1RemountRoundForTesting {
 // 单测 seam：hosted 单测跑真实 `connectOnce` 会触网络与 Keychain，
 // 这里只验证重挂前置状态与次数（生产恒为 nil）。
                round()
            } else {
                await connectOnce()
            }
 // 重挂失败：phase 已离开 connected（visible reconnect/退避），交给既有链路。
            guard phase.isConnected else { return }
        }
    }

 /// 重挂循环等待「在飞连接轮次」落地的上限（正常一轮 <1s；超上限就交回下一轮）。
    private static let projV1RemountWaitForRoundSeconds: TimeInterval = 5

 /// 单测 seam：把 service 置成「P1 活连接」状态（不触网络/Keychain），用于
 /// DD-16 受控重挂的状态机断言。生产路径由 `attemptP1Connection` 设置同一组
 /// 状态：`p1Channel` = 活通道、`p1Resume.channel` = 该通道、`phase` = connected。
 ///
 /// hosted 单测的确定基线：`LinkService.init` 可能在飞一轮自动连接（宿主机
 /// Keychain 里的真实凭据），它的 `phase =.connecting`/`isConnecting = true`
 /// 会在测试 await 期间落地，与「活连接」断言互斥。这里把连接轮次簿记显式
 /// 归零（并取消我们自己持有的任务），让后续断言只依赖 seam 设的状态；
 /// 被取消的遗留轮次由 `connectOnce` 入口的 `Task.isCancelled` 守卫直接退回。
    func adoptLiveP1ChannelForTesting(_ channel: P1Channel) {
        connectTask?.cancel()
        connectTask = nil
        retryTask?.cancel()
        retryTask = nil
        isConnecting = false
        p1SilentResume = false
        manuallyDisconnected = false
        projV1RemountTarget = nil
        projV1RemountLoopRunning = false
        p1Channel = channel
        p1Resume.adoptExistingChannelForTesting(channel)
        phase = .connected
    }

 /// 单测 seam：重挂轮次的执行体（nil = 生产 `connectOnce`）。见
 /// `runProjV1RemountLoop`。
    var projV1RemountRoundForTesting: (@MainActor () -> Void)?

 /// Foreground resume: reconnect immediately; views rebuild from snapshots
 /// when `generation` changes.
    func handleForeground() {
        guard credentials != nil, !manuallyDisconnected else { return }
        if phase.isConnected {
 // task-2: ".connected" on a network the socket was not dialed on is a
 // stale transport, not a reusable one. The path-change event usually
 // invalidates it already; this is the scenePhase race window.
            if networkPathChangedSinceConnect {
                ReconnectMetrics.markInvalidate(reason: "foreground/pathChanged")
                teardownTransport()
                reconnectNow()
            } else {
 // T2(B2)：前台恢复且链路可复用时按需续期 api token。
                renewAPITokenIfNeededAfterConnect()
            }
            return
        }
 // A `connectOnce` round is already in flight: restarting it would cancel
 // the candidate that is about to succeed (foreground resume must not turn
 // a 1s connect into a full retry).
        guard !isConnecting else { return }
        reconnectNow()
    }

 // MARK: - task-2 reconnect triggers

 /// The session/workspace list page appeared: t0 of the reconnect chain.
 ///
 /// A healthy mux on the current network is reused with no traffic (P0-5 rule);
 /// every other state reconnects **now**, cancelling a pending backoff wait so
 /// the chain never pays the 0.5-10s `scheduleReconnect` delay.
    func handlePageEnter() {
        ReconnectMetrics.beginPageEnter(reason: "listPage")
        guard credentials != nil, !manuallyDisconnected else { return }
        switch phase {
        case .connected:
            if networkPathChangedSinceConnect {
                ReconnectMetrics.markInvalidate(reason: "pageEnter/pathChanged")
                endpointsDirty = true
                teardownTransport()
                reconnectNow()
            } else {
                ReconnectMetrics.markReuseDecision()
            }
        case .reconnecting, .disconnected:
 // The backoff wait exists to space out unattended retries; an explicit
 // page enter is a user-visible resume and must not wait for it.
            reconnectNow()
        case .connecting, .unpaired, .needsRepair:
            break
        }
    }

 /// A **meaningful** network-path change (interface type / satisfied flip).
 ///
 /// The OS keeps the old socket open across Wi-Fi -> cellular until the TCP
 /// timeout; invalidating it here is what turns a 10s+ wait into a <1s reconnect.
    func handleNetworkPathChanged() {
        #if DEBUG
        ScrollHitchProbe.mark("e2ePathChanged", ["phase": String(describing: phase)])
        #endif
        ReconnectMetrics.markPathChange()
 // 真机验收根因：池化 HTTPS 连接是旧网络上拨的——5G→WiFi 后
 // 蜂窝接口不立刻死（socket 仍 ESTABLISHED），但路由已切走：连接静默黑洞
 // 化。新拨号的鉴权复用它，烧满 1.5s 首字节看门狗（真机 4895ms 复盘：
 // `/auth/challenge 首字节超时 1558ms`）。WiFi→5G 不踩坑是因 WiFi 接口
 // 断开时 socket 立刻报错、直接走新连接。路径一变就清池：新网络一律新
 // 连接（与 WSS 的 TLS 并行建立，不增长关键路径）。
        HTTPConnectionPool.shared.closeAll()
 // 切换锚定链起点：后面所有退避重试都归到这条链，直到连接成功结算。
 // （手动真实切换验收时 e2ePathChanged → e2eSwitchReconnect 两个 mark 的
 // 差值就是 App 侧真实重连耗时，直接从 hitch jsonl 可读。）
        switchReconnectStartedAt = Date()
 // 网络已变：旧端点顺序作废，下一轮必须重新发现（mDNS）+ 并行探测。
        endpointsDirty = true
        guard credentials != nil, !manuallyDisconnected else { return }
        switch phase {
        case .connected:
            ReconnectMetrics.markInvalidate(reason: "pathChange")
            lastErrorText = L10n.t("网络已切换，正在重连…")
            teardownTransport()
            reconnectNow()
        case .reconnecting, .disconnected:
            ReconnectMetrics.markInvalidate(reason: "pathChange")
            reconnectNow()
        case .connecting:
 // Only restart a round that was dialed before the change; a round that
 // already started on the new path must be allowed to finish.
            if Self.shouldRestartConnectingRound(
                roundStartGeneration: pathGenerationAtRoundStart,
                pathGeneration: NetworkPathMonitor.shared.changeGeneration
            ) {
                ReconnectMetrics.markInvalidate(reason: "pathChange/connecting")
                reconnectNow()
            }
        case .unpaired, .needsRepair:
            break
        }
    }

 /// The live transport produced no first byte within its probe budget (callers:
 /// the reused-mux `workspace/follow` baseline probe and the pooled-unary
 /// watchdog). Treat the socket as lost and reconnect immediately.
    func noteTransportUnresponsive(source: String) {
        ReconnectMetrics.markFirstByteTimeout(source: source)
        guard credentials != nil, !manuallyDisconnected, phase.isConnected else { return }
        lastErrorText = L10n.t("连接无响应，正在重连…")
        teardownTransport()
        reconnectNow()
    }

 /// E2E-only：模拟 OS 报告一次网络切换，走与真实切换完全相同的
 /// `handleNetworkPathChanged` 即时重连路径。
    func simulateNetworkPathChangeForE2E() {
        NetworkPathMonitor.shared.simulateMeaningfulChangeForE2E()
    }

 /// The reused mux delivered its first `workspace/follow` baseline inside the
 /// probe budget: the provisional "reuse" chain is confirmed and may complete.
    func noteReuseLivenessConfirmed() {
        ReconnectMetrics.markReuseConfirmed()
    }

 /// A pooled unary request hit `HTTPConnection.firstByteTimeout`. Only a request
 /// against the *current* origin says anything about the live mux transport.
 ///
 /// real-device root-cause fix: a first-byte timeout on ONE pooled
 /// request is **not** proof that the whole transport is dead. On 5G/relay the
 /// shared tunnel carries `session/list` (1.46MB raw / 357KB gzip) and
 /// `session/page` concurrently; head-of-line blocking routinely pushes a small
 /// request's first byte past the watchdog while the mux is perfectly alive.
 /// Real-device evidence (11:53:30): three timeouts within 350ms tore down a live
 /// transport and started a ~25s reconnect storm ("连接无响应，正在重连…").
 ///
 /// New rule: verify the path on a **fresh** connection before invalidating the
 /// mux. `/health` (pinned TLS, 1.2s) alive → keep the transport (the failed
 /// request is retried by its caller on a fresh pooled connection). Dead → the
 /// path really changed (or Mac/relay went away) → reconnect now. Bursts are
 /// debounced so one stall cannot launch several probes/teardowns.
    private func handleFirstByteTimeout(endpoint: String, host: String?) {
        guard let currentHost = credentials?.originURL?.host, let host, currentHost == host else {
            return
        }
        guard phase.isConnected, !manuallyDisconnected, !isConnecting else { return }
        let now = Date()
        if let last = lastFirstByteVerificationAt, now.timeIntervalSince(last) < 2.0 {
            linkDebug("unary firstByte timeout burst (" + endpoint + ") ignored while verifying")
            return
        }
        lastFirstByteVerificationAt = now
        transportVerificationTask?.cancel()
        transportVerificationTask = Task { [weak self] in
            guard let self else { return }
            let alive = await self.probeCurrentOriginHealth(timeout: 1.2)
            guard !Task.isCancelled, self.phase.isConnected, !self.isConnecting else { return }
            if alive {
                self.linkDebug("unary firstByte timeout (" + endpoint + ") but fresh /health ok; keeping transport")
                return
            }
            self.noteTransportUnresponsive(source: "unary:" + endpoint)
        }
    }

 /// Fresh-connection `/health` probe used before invalidating a live transport.
 /// Deliberately bypasses the HTTP pool: a dead keep-alive socket must not be
 /// allowed to decide whether the network path is alive.
    private func probeCurrentOriginHealth(timeout: TimeInterval) async -> Bool {
        guard let credentials, let origin = credentials.originURL else { return false }
        do {
            let response = try await HTTPSClient.json(
                origin: origin,
                method: "GET",
                path: "/health",
                leafPin: credentials.leafPin,
                caCertBase64: credentials.caCertBase64,
                timeout: timeout
            )
            return response.status == 200 && response.json["ok"]?.boolValue == true
        } catch {
            return false
        }
    }

    func disconnect(clearCredentials: Bool) {
        connectTask?.cancel()
        connectTask = nil
        retryTask?.cancel()
        retryTask = nil
 // 实施段：登出/解绑/切设备时取消在飞的冷启能力探测（结果不得
 // 写回已失效的凭据语境）。普通轮次出口**不**取消（见
 // `startColdStartCapabilityProbe`）。
        cancelColdStartCapabilityProbe()
        projV1RemountTarget = nil
        isConnecting = false
        p1SilentResume = false
        p1LostAt = nil
        teardownTransport()
 // v0.1.1 (Bug 2): only a real disconnect drops the pending
 // approval/question cards. `teardownTransport` also runs at the start of
 // every reconnect attempt, so clearing there made the card disappear and
 // reappear within ~15–20s. The Host re-delivers its pending waterfalls
 // once `$events` is ready again (idempotent by `eventId` via
 // `ForwardedWaterfallQueue.apply`), so retaining them is safe.
        clearPendingWaterfalls()
        apiToken = nil
        apiTokenExpiresAt = nil
        apiTokenRenewalTask?.cancel()
        apiTokenRenewalTask = nil
        if clearCredentials {
 // T2(B2)：解绑/repair 时本机持久化的 api token 一并清除，
 // 不得在重新配对后残留可用凭据。
            apiTokenStore.clearAll()
            store.clear()
            credentials = nil
            phase = .unpaired
        } else {
            manuallyDisconnected = true
            phase = .disconnected
        }
    }

    func clearPairing() {
        disconnect(clearCredentials: true)
    }

    func scheduleReconnect() {
        guard credentials != nil, !manuallyDisconnected else { return }
        retryTask?.cancel()
        attempt += 1
 // Any scheduled round is visible: the silent resume window is over.
        p1SilentResume = false
        let attemptNumber = attempt
 // 桌面端重启窗口：上一轮所有候选都是"服务端还没起来"（插件未就绪 / 网关 5xx /
 // 地址不可达 / 超时）时，用短固定退避（400ms 起、+200ms、上限 1.5s）快速探测；
 // 不要用指数退避滚到 10s（用户实测：重启桌面端后开 App 等了约 10 秒）。
        let delayMs = Self.isBootWindow(classes: lastRoundFailureClasses)
            ? Self.bootWindowDelayMs(attempt: attemptNumber)
 // Spec §3.8: base 500ms, factor 2, cap 10s, 50% jitter.
            : Self.reconnectDelayMs(attempt: attemptNumber, randomUnit: Double.random(in: 0...1))
        phase = .reconnecting(attempt: attemptNumber)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.connectOnce()
        }
    }

 /// One reconnect round. Every round walks **all** stored candidate origins
 /// (current first, then the signed payload's LAN/relay candidates) instead of
 /// trying a single origin per backoff step: after a Wi-Fi -> cellular switch
 /// the stale LAN origin must fall back to the relay origin within this round,
 /// not after several backoff delays (design §4.7).
    func connectOnce() async {
 // 入口先看取消：`connectTask` 被取消（disconnect/重连竞态）后，任务体仍会
 // 被调度执行；没有这道守卫，一个「已取消但尚未开始」的轮次会在下一次挂起
 // 后真正拨号，并改写 `phase`/`isConnecting`（hosted 单测与线上都可能遇到）。
        guard !Task.isCancelled else { return }
        guard !isConnecting, !manuallyDisconnected, let credentials else {
            return
        }
        isConnecting = true
 // 轮起点：mux 冲突重试的等待基准（插件 1.5s 静默接管窗口从旧连接最后
 // 一帧起算 ≈ 本时刻）。
        let roundStartedAt = Date()
        let silentResume = p1SilentResume
        teardownTransport(keepP1Resume: silentResume)
 // A silent resume keeps `phase ==.connected` on purpose: no view model
 // observes a disconnect, so the replay can continue its streams.
        if !silentResume {
            phase = attempt > 0 ? .reconnecting(attempt: attempt) : .connecting
        }
        let prefersRelay = NetworkPathMonitor.shared.prefersRelay
        let pathChanged = networkPathChangedSinceConnect
        pathGenerationAtRoundStart = NetworkPathMonitor.shared.changeGeneration
        ReconnectMetrics.markReconnectStart()
        ConnectionMetrics.begin(preferRelay: prefersRelay)
        P1ResumeMetrics.begin()

        let candidates = PairingOriginSelector.reconnectCandidates(
            current: credentials.origin,
            stored: credentials.originCandidates
        )
        guard !candidates.isEmpty else {
            isConnecting = false
            phase = .needsRepair(L10n.t("配对凭据没有可用的服务器地址，请重新配对"))
            return
        }
 // link-perf L2（DEC-D + 设计变更二审）：本 App 运行周期首次
 // 连接轮次**无条件**先对主候选 origin 做一次有界 /health 探测再拨号
 // （每周期重读 takeoverWindowMs + 探测插件回退；supportsMuxRPC 写回后
 // 本轮 transportRoute 即可生效）。探测的 ≤500ms 计入轮起点之后，
 // fast-retry 对齐等待按「轮起点 + 对齐值」自校正，不改变 AC-01 口径；
 // 重连/网络切换轮次绝不探测。
 // Cross-network requirement: order candidates by the phone's *current*
 // network. Same subnet -> LAN first; cellular / a different network ->
 // relay first with the stale LAN address only as a bounded fallback. This
 // is what stops a cross-network reconnect from burning seconds on an
 // unreachable LAN origin (the reported relay-503 -> LAN-timeout chain).
        let localNetwork = NetworkPathMonitor.shared.currentLocalIPv4Network()
        let orderedCandidates = Self.orderedCandidatesForPath(
            candidates,
            prefersRelay: prefersRelay,
            local: localNetwork,
            pathChanged: pathChanged
        )
 // D 段（连接清理）：冷启 P1 能力探测不再串行挡在首次拨号之前。
 // 旧实现（v2.17）在本 App 周期首个连接轮次先 `await` 一次 ≤500ms 的
 // /health 再拨号——冷启白付一个 RTT（HANDOFF §4.D H4：删掉后 ≈0.5s）。
 // 现在：探测在**本轮起点并行启动**（不 await），首拨立即开始；能力判定
 // 用两路信息合成——
 // - 缓存 `supportsMuxRPC`（配对/welcome/上次探测学到的）；
 // - 本 App 周期首个轮次「乐观 P1」：P1 握手/upgrade 本身就是能力探测
 // （旧插件在 401/403/503 拒绝 → 同一候选内 useLegacy 回退，不多付
 // /health 的一次往返）；探测结果落地后（成功/失败）后续轮次只信缓存。
 // 探测仍然刷新 `takeoverWindowMs`（409 对齐用）与存量设备升 P1（F3），
 // 只是不再占关键路径。
        let isColdStartRound = !p1ColdStartProbeConsumed
 // 实施段（D 段 P1 修复）：**不得**在本轮出口取消探测任务。
 // 旧实现在快连接（首拨毫秒级返回）时因「轮次出口清理」取消了探测，而
 // `p1ColdStartProbeConsumed` 已在启动时置 true →
 // `supportsMuxRPC`/`takeoverWindowMs`/`sessionTakeoverWindowObserved`
 // 整个 App 周期都不落地且不重试（409 对齐与存量设备升 P1 失效）。
 // 任务句柄挂在实例上、自带有界超时（0.5s）且只弱引用本对象；登出/解绑由
 // `disconnect` 取消（见 `cancelColdStartCapabilityProbe`）。
 // 探测不占首拨关键路径：此处不 await。
        startColdStartCapabilityProbe(primaryOrigin: orderedCandidates.first)
 // 冷启动 <1s（列表侧）：预热共享 HTTPS 池，让 t0+~100ms 就发出的
 // early session/list 复用已建好的 TLS，而不是再付一次 ~300ms 握手。
        warmHTTPSPoolIfColdStart(prefersRelay: prefersRelay, local: localNetwork)
 // 跨网络自愈（用户）：mDNS 拿 Mac **当前** 端点 + 对候选并行打
 // /health，两项都带预算（≤1.2–1.5s）。网络刚变时这一步把"按旧顺序串行盲试"
 // 变成一次并行收敛，第一拨就落在可达地址上。
 //
 // 冷启动 <1s：跨网（5G）时 relay 是第一且唯一可能立即可达的候选，
 // 而发现+探测真机实测约 1.58s（connect-metrics 的 candidateMs 1577–1614ms
 // 就是这一段）。它只用于「首拨失败后换地址」，绝不能挡在第一次拨号前。
 //
 // 重连提速（用户目标：最快 1s、最迟 2s）：dial-first 从 relay
 // 泛化到所有首候选可信的路径。真机探针复盘（hitch-1793096527）：
 // - 模拟切换（LAN 有效）整轮重连 392ms，其中发现+探测占了大头；
 // - 自发重连（firstByteTimeout 路径）整轮 ~1.5s，几乎全是阻塞发现；
 // 同网段 LAN 首拨健康时 ≈100–300ms，把 1.5–2s 的发现挪到后台并发后，
 // LAN 侧重连从 ~1.9–2.4s 降到 ~0.3–0.5s。陈旧 LAN 地址（Mac 换 IP）由
 // speculative 紧上限兜底：最多烧 1.2s 就转后台收敛结果，不劣于旧的
 // 「先发现 1.5–2s 再拨」。
        let dialPolicy = Self.dialFirstPolicy(
            prefersRelay: prefersRelay,
            orderedCandidates: orderedCandidates,
            local: localNetwork,
            shouldDiscover: endpointsDirty || candidates.count > 1
        )
        var dialCandidates = orderedCandidates
        var convergenceConsumed = false
        var convergenceTask: Task<(origins: [String], observations: [EndpointHealing.ProbeObservation]), Never>?
        switch dialPolicy {
        case .none:
            let discovery = await discoverAndProbe(
                candidates: orderedCandidates,
                local: localNetwork,
                prefersRelay: prefersRelay,
                credentials: credentials
            )
            dialCandidates = Self.dialOrder(
                discovered: discovery.origins,
                observations: discovery.observations,
                fallback: orderedCandidates,
                local: localNetwork,
                prefersRelay: prefersRelay
            )
            convergenceConsumed = true
        case .fullBudget, .speculative:
            let convergenceStartedAt = Date()
            convergenceTask = Task { [weak self] in
                guard let self else { return ([], []) }
                let result = await self.discoverAndProbe(
                    candidates: orderedCandidates,
                    local: localNetwork,
                    prefersRelay: prefersRelay,
                    credentials: credentials
                )
                #if DEBUG
                ScrollHitchProbe.mark("e2eConvergenceDone", [
                    "ms": Int(Date().timeIntervalSince(convergenceStartedAt) * 1000),
                    "origins": result.origins.count
                ])
                #endif
                return result
            }
            linkDebug("round: dial-first \(dialPolicy) (dial now, convergence in background)")
        }
        defer { convergenceTask?.cancel() }
        let hasSameSubnetLAN = dialCandidates.contains {
            Self.candidateRole(host: $0.host, local: localNetwork) == .lanSameSubnet
        }
        let hasRelay = dialCandidates.contains {
            Self.candidateRole(host: $0.host, local: localNetwork) == .relay
        }
        linkDebug("round: dial=[" + dialCandidates.map { Self.originLabel($0) }.joined(separator: ",") + "]")
 // Fixed total budget for the candidate walk: the round can never turn into
 // a 10s tail. Cross-network relay+LAN: 1.5s; same-LAN: 3s; a single
 // candidate keeps the generous dial budget (nothing to switch to).
        let roundBudget = Self.roundBudgetSeconds(
            candidateCount: dialCandidates.count,
            hasSameSubnetLAN: hasSameSubnetLAN,
            hasRelay: hasRelay
        )
        let roundDeadline = Date().addingTimeInterval(roundBudget)
        var failures: [String] = []
        var failureClasses: [CandidateFailureClass] = []
        var roundBudgetExhausted = false
 /// credential rejections are recorded per candidate instead of
 /// ending the round on the first one. A rejected credential is only fatal
 /// (`needsRepair`, user must re-pair) when **every** candidate rejects it —
 /// otherwise a self-healed/stale origin could turn a recoverable round into
 /// a permanent offline state.
        var credentialRejections: [String] = []
        var attemptedOriginKeys = Set<String>()
        var queue = dialCandidates
        var queueIndex = 0
 // 瞬态快失败原地重试：首个候选 <1s 的网络层 unreachable 多为
 // 中继/隧道在旧连接关闭后的短暂拒绝窗口（真机实测模拟切换后中继首拨
 // 100% 在 ~480ms 被拒、~1–5s 后恢复；同构建手动复现则 374ms 干净连上，
 // 证明是服务侧瞬态而非拨号路径问题）。原地重试一次 + 350ms 等待，比走完
 // 兜底队列再退避回来快数秒。
        var fastRetryUsed = false
 // 蜂窝下 LAN 候选每轮最多尝试个数：跨网 RFC1918 必然不可达（仅 VPN 边缘
 // 有戏），1.2s 上限 × 无上限个数仍会把整轮拖满（真机实测 3 个烧 4.6s，
 // 挤掉中继重试窗口）。保留 2 个最后一线，其余留到下一轮。
        var cellularLANAttempts = 0
        while queueIndex < queue.count {
            let origin = queue[queueIndex]
            queueIndex += 1
            let originKey = PairingOriginSelector.normalizedOriginString(origin).lowercased()
            guard attemptedOriginKeys.insert(originKey).inserted else { continue }
            if prefersRelay, localNetwork == nil,
               Self.candidateRole(host: origin.host, local: localNetwork) != .relay,
               cellularLANAttempts >= Self.maxCellularLANAttemptsPerRound {
                continue
            }
 // Budget semantics keep the original meaning: "index 0" is the first
 // distinct candidate actually attempted in this round.
            let attemptIndex = attemptedOriginKeys.count - 1
            let attemptCount = max(queue.count, dialCandidates.count)
            if Task.isCancelled {
                isConnecting = false
                return
            }
            let remaining = roundDeadline.timeIntervalSinceNow
            guard var attemptTimeout = Self.attemptBudget(
                baseTimeout: Self.candidateTimeoutSeconds(
                    index: attemptIndex,
                    count: attemptCount,
                    pathChanged: pathChanged
                ),
                remainingRoundBudget: remaining
            ) else {
                roundBudgetExhausted = true
                break
            }
 // dial-first 的首轮是「投机拨号」，蜂窝下的 LAN 候选跨网必然不可达：
 // 两类都只值一个紧上限（健康 LAN 拨号 ~100–300ms，1.2s 是 4–12 倍余量），
 // 超时即转后台收敛结果/下一候选，不烧整档候选超时（真机实测蜂窝下
 // LAN 兜底白烧 2679ms）。
            if let cap = Self.attemptTimeoutCap(
                attemptIndex: attemptIndex,
                policy: dialPolicy,
                origin: origin,
                local: localNetwork,
                prefersRelay: prefersRelay
            ) {
                attemptTimeout = min(attemptTimeout, cap)
            }
 // authenticateToken() reads `credentials.origin`, so point it at the
 // origin under test before every attempt.
            setCurrentOrigin(origin, persist: false)
            if attemptIndex > 0 {
 // The silent resume window is bounded by one candidate attempt:
 // from the second candidate on, the reconnect becomes visible
 // (phase + banner) and the retained stream table is dropped.
                if p1SilentResume {
                    p1SilentResume = false
                    phase = .reconnecting(attempt: max(1, attempt))
                }
                teardownTransport(keepP1Resume: p1SilentResume)
            }
            let host = origin.host ?? origin.absoluteString
            if prefersRelay, localNetwork == nil,
               Self.candidateRole(host: origin.host, local: localNetwork) != .relay {
                cellularLANAttempts += 1
            }
            ConnectionMetrics.markCandidate(host)
            let candidateStartedAt = ReconnectMetrics.clock()
            #if DEBUG
            ScrollHitchProbe.mark("e2eDialStart", [
                "origin": Self.originLabel(origin),
                "timeout": Double(attemptTimeout),
                "index": attemptIndex
            ])
            #endif
            switch await attemptConnection(
                origin: origin,
                leafPin: credentials.leafPin,
                timeout: attemptTimeout,
                coldStartOptimistic: isColdStartRound
            ) {
            case .connected(let bumpGeneration):
                linkDebug("round: connected " + Self.originLabel(origin))
                #if DEBUG
                ScrollHitchProbe.mark("e2eDialResult", [
                    "origin": Self.originLabel(origin),
                    "ms": Int((ReconnectMetrics.clock() - candidateStartedAt) * 1000),
                    "result": "connected"
                ])
                #endif
                ReconnectMetrics.markCandidateAttempt(
                    host: host,
                    milliseconds: (ReconnectMetrics.clock() - candidateStartedAt) * 1000,
                    result: CandidateFailureClass.ok.rawValue
                )
                ReconnectMetrics.markPickedOrigin(host)
                setCurrentOrigin(origin, persist: true)
                isConnecting = false
                attempt = 0
                lastConnectedAt = Date()
                lastErrorText = nil
                pathGenerationAtConnect = NetworkPathMonitor.shared.changeGeneration
                lastRoundFailureClasses = []
                p1SilentResume = false
                phase = .connected
                if bumpGeneration { generation += 1 }
                #if DEBUG
                ScrollHitchProbe.mark("e2eReconnected", ["bump": bumpGeneration, "generation": generation])
                #endif
 // 切换锚定链结算：网络切换信号 → 此刻连接成功的真实耗时。
                if let started = switchReconnectStartedAt {
                    switchReconnectStartedAt = nil
                    let ms = max(0, Int(Date().timeIntervalSince(started) * 1000))
                    lastSwitchReconnectMs = ms
                    #if DEBUG
                    ScrollHitchProbe.mark("e2eSwitchReconnect", ["ms": ms])
                    #endif
                    linkDebug("switch reconnect settled in \(ms)ms")
                }
                ReconnectMetrics.markConnected()
                ConnectionMetrics.markConnected()
                connectionMetricsValue = connectionMetricsSummary()
 // T2(B2)：链路就绪后按需后台续期 api token（剩余 < 20min）。
                renewAPITokenIfNeededAfterConnect()
 // v0.1.1 C: pre-C pairings still trust only the leaf pin; while
 // the freshly authenticated link is up, learn the public CA
 // certificate so future leaf re-issues need no re-pair.
                startCATrustMigrationIfNeeded()
 // 连接成功即把 Mac 当前端点写回持久化候选（网络再变时手里是新地址）。
                endpointsDirty = false
                refreshEndpointsAfterConnect(origin: origin)
                return
            case .credentialRejected(let reason):
                #if DEBUG
                ScrollHitchProbe.mark("e2eDialResult", [
                    "origin": Self.originLabel(origin),
                    "ms": Int((ReconnectMetrics.clock() - candidateStartedAt) * 1000),
                    "result": "credentialRejected"
                ])
                #endif
                ReconnectMetrics.markCandidateAttempt(
                    host: host,
                    milliseconds: (ReconnectMetrics.clock() - candidateStartedAt) * 1000,
                    result: CandidateFailureClass.credentialRejected.rawValue
                )
                credentialRejections.append(reason)
                failures.append(host + ": " + reason)
                lastErrorText = reason
                linkDebug("round: credentialRejected " + Self.originLabel(origin) + " " + reason)
 // Keep walking: only an all-candidates rejection means re-pairing.
            case .fastRejected(let reason, let failureClass):
                linkDebug("round: fastRejected " + Self.originLabel(origin) + " " + reason)
                #if DEBUG
                ScrollHitchProbe.mark("e2eDialResult", [
                    "origin": Self.originLabel(origin),
                    "ms": Int((ReconnectMetrics.clock() - candidateStartedAt) * 1000),
                    "result": "fastRejected:" + failureClass.rawValue
                ])
                #endif
                ReconnectMetrics.markCandidateAttempt(
                    host: host,
                    milliseconds: (ReconnectMetrics.clock() - candidateStartedAt) * 1000,
                    result: failureClass.rawValue
                )
                failureClasses.append(failureClass)
                failures.append(host + ": " + reason)
 // Fast reject: the server answered, so switch candidates with no
 // timeout wait and no retry of this origin. Keep a clear interim
 // message for the banner (cross-network req 4).
                lastErrorText = failureClass == .pluginNotReady
                    ? L10n.t("桌面端插件未就绪（host/inactive），正在尝试其他地址…")
                    : L10n.t("该地址被服务端拒绝，正在尝试其他地址…")
            case .failed(let reason):
                linkDebug("round: failed " + Self.originLabel(origin) + " " + reason)
                #if DEBUG
                ScrollHitchProbe.mark("e2eDialResult", [
                    "origin": Self.originLabel(origin),
                    "ms": Int((ReconnectMetrics.clock() - candidateStartedAt) * 1000),
                    "result": "failed:" + Self.classifyFailureMessage(reason).rawValue,
                    "reason": reason
                ])
                #endif
                let failureClass = Self.classifyFailureMessage(reason)
                ReconnectMetrics.markCandidateAttempt(
                    host: host,
                    milliseconds: (ReconnectMetrics.clock() - candidateStartedAt) * 1000,
                    result: failureClass.rawValue
                )
                failureClasses.append(failureClass)
                failures.append(host + ": " + reason)
                lastErrorText = reason
 // link-perf L1（设计变更二审兜底）：按已知窗口对齐的
 // 快重试仍收到 409 → 真实接管窗口比已知值宽（插件回退/配置变更）。
 // 后续重试一律保守 1.7s 对齐，并触发一次能力刷新（重置探测标记，
 // 下一轮 connectOnce 重新 /health 探测；每 App 周期最多一次）。
                let isMuxConflict = Self.isMuxConflictRejection(reason)
                if isMuxConflict, fastRetryUsed, !muxConflictAlignEscalated {
                    muxConflictAlignEscalated = true
                    p1ColdStartProbeConsumed = false
                    linkDebug("mux-conflict: aligned retry still 409 → conservative 1.7s align + capability refresh")
                }
 // 瞬态快失败原地重试（见 fastRetryUsed 声明处的取证）：只对首轮、
 // 网络层 unreachable 且 <1s 的失败生效；服务端拒绝（fastRejected）
 // 是确定性状态，不重试。
                if attemptIndex == 0, !fastRetryUsed, failureClass == .unreachable,
                   (ReconnectMetrics.clock() - candidateStartedAt) < 1.0 {
                    fastRetryUsed = true
 // 等待对齐插件的 mux 接管窗口（见 muxConflictRetryAlignSeconds）：
 // 409 冲突的静默判定从旧连接最后一帧起算 ≈ 轮起点，对齐值
 // （窗口 + 120ms 边距，取自本周期 /health 观测或 credentials
 // 缓存）后重试可越过窗口。
 // 下限分档（设计变更三审）：409 冲突用 max(0, align − 轮内已
 // 耗时)——350ms 下限会让「首拨+409 > 570ms」（蜂窝 0.3-0.9s
 // 常见）时重试推迟到 1.0-1.35s，超 AC-01 硬线①（冲突重试
 // 等待段 ≤1.0s）；纯瞬态 unreachable 无窗口语义，保持 350ms
 // 防抖下限。
                    let sinceRoundStart = Date().timeIntervalSince(roundStartedAt)
                    let align = muxConflictRetryAlignSeconds
                    let waitSeconds = max(isMuxConflict ? 0 : 0.35, align - sinceRoundStart)
 // 409 取证（设计变更三审，AC-01 验收）：首拨时长 / 409 收到
 // 时刻（轮起点起算）/ 重试预计发出时刻 / 对齐值。
                    let dialMs = Int((ReconnectMetrics.clock() - candidateStartedAt) * 1000)
                    #if DEBUG
                    ScrollHitchProbe.mark("e2eFastRetry", [
                        "origin": Self.originLabel(origin),
                        "conflict": isMuxConflict ? 1 : 0,
                        "dialMs": dialMs,
                        "conflictAtMs": Int(sinceRoundStart * 1000),
                        "retryAtMs": Int((sinceRoundStart + waitSeconds) * 1000),
                        "alignMs": Int(align * 1000),
                        "reason": reason
                    ])
                    #endif
                    linkDebug(
                        "round: fast-retry " + Self.originLabel(origin)
                            + " conflict=" + (isMuxConflict ? "1" : "0")
                            + " dialMs=" + String(dialMs)
                            + " conflictAtMs=" + String(Int(sinceRoundStart * 1000))
                            + " retryAtMs=" + String(Int((sinceRoundStart + waitSeconds) * 1000))
                            + " alignMs=" + String(Int(align * 1000))
                    )
                    try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                    guard !Task.isCancelled else { break }
                    attemptedOriginKeys.remove(originKey)
                    queueIndex = 0
                    queue.insert(origin, at: 0)
                    continue
                }
            }
 // Relay-first fast path: the first dial failed, so now pay for the
 // background convergence exactly once and rebuild the remaining queue in
 // its preferred order (newly discovered LAN/relay endpoints included).
            if !convergenceConsumed, let convergenceTask {
                convergenceConsumed = true
                let convergenceAwaitStartedAt = Date()
                let discovery = await convergenceTask.value
                #if DEBUG
                ScrollHitchProbe.mark("e2eConvergenceConsumed", [
                    "waitMs": Int(Date().timeIntervalSince(convergenceAwaitStartedAt) * 1000)
                ])
                #endif
                let reordered = Self.dialOrder(
                    discovered: discovery.origins,
                    observations: discovery.observations,
                    fallback: orderedCandidates,
                    local: localNetwork,
                    prefersRelay: prefersRelay
                )
                queue = reordered.filter {
                    !attemptedOriginKeys.contains(PairingOriginSelector.normalizedOriginString($0).lowercased())
                }
                queueIndex = 0
                linkDebug("round: convergence consumed, remaining=[" + queue.map { Self.originLabel($0) }.joined(separator: ",") + "]")
            }
        }
        isConnecting = false
        guard !Task.isCancelled else { return }
 // Only when every candidate rejected the credential is re-pairing the only
 // remedy; a single rejected (stale/healed) origin must not end the round.
        if !credentialRejections.isEmpty, credentialRejections.count >= dialCandidates.count {
            lastErrorText = credentialRejections.last
 // T2(B2)：凭据被所有候选拒绝 = repair 语义，持久化的 api
 // token 也一并作废（重新配对时 adopt 会再清一次，双保险）。
            apiTokenStore.clear(scope: apiTokenScope)
            phase = .needsRepair(credentialRejections.last ?? L10n.t("配对凭据被拒绝，请重新配对"))
            return
        }
        if roundBudgetExhausted {
            ReconnectMetrics.markRoundBudgetExhausted()
            failureClasses.append(.timeout)
            failures.append(L10n.f("候选总预算已耗尽（%lld ms）", Int(roundBudget * 1000)))
        }
 // One-line, actionable reason (cross-network req 4): the list banner shows
 // `statusDetail`, so it must never be empty or a generic 「重连中」.
        lastErrorText = Self.roundFailureSummary(classes: failureClasses, details: failures)
        linkDebug("round: all candidates failed classes=[" + failureClasses.map(\.rawValue).joined(separator: ",") + "]")
 // Remember a different starting origin for the next round so a dead
 // address does not always head the list.
        lastRoundFailureClasses = failureClasses
 // 整轮都失败：下一轮必须重新发现端点（很可能手里全是旧地址）。
        endpointsDirty = true
        _ = rotateOriginIfPossible(reason: failures.last ?? L10n.t("连接失败"))
        scheduleReconnect()
    }

 /// 冷启动 P1 能力探测。
 ///
 /// 背景（设计 F3 + 二审修正）：`supportsMuxRPC`/`takeoverWindowMs` 原本只在
 /// 配对时学得——桌面端后来开启 muxRpc 的存量设备永远不会自动升 P1；且
 /// `supportsMuxRPC` 持久化为 true 后，桌面端重启换新窗口值永远读不到、
 /// 插件回退旧版（窗口 1500）时旧缓存 800 会用 920ms 对齐去撞 409。因此
 /// 探测条件是**本 App 运行周期第一次连接轮次，无条件**（不绑定
 /// supportsMuxRPC）：对主候选 origin（单个，不遍历）发一次有界（500ms）
 /// GET /health（复用 HTTPSClient 共享连接池）：
 /// - 成功：`features.muxRpc`/`proto` 写回 supportsMuxRPC（存量设备自动升
 /// P1），`takeoverWindowMs` 覆盖/清空缓存（无字段 = 旧插件 → 存 nil，
 /// 走 1.7s 兜底对齐；不字面存 1500——那是新插件显式广播值的语义）；
 /// - 失败/非 200：不动缓存、不阻塞本轮（按缓存值对齐，409 升级路径兜底），
 /// 本生命周期不再重试——重连/网络切换的 <1s 关键路径绝不付这 500ms。
 ///
 /// 单测注入 `p1ColdStartProbeFetch`/`p1ColdStartProbePersist` 后不触网络与
 /// Keychain（测试宿主与 E2E App 共享两者）。
 ///
 /// D 段：本方法保留原有「消费一次」语义（单测/同步调用用），
 /// 生产 `connectOnce` 改用并行入口 `startColdStartCapabilityProbe`
 /// （探测不再挡在首拨之前）。
    func probeP1CapabilityIfColdStart(primaryOrigin: URL?) async {
        guard !p1ColdStartProbeConsumed else { return }
        p1ColdStartProbeConsumed = true
        coldProbeGeneration += 1
        await performColdStartCapabilityProbe(
            primaryOrigin: primaryOrigin,
            generation: coldProbeGeneration
        )
    }

 /// D 段（连接清理）：并行启动冷启能力探测（不 await、不占关键
 /// 路径）。返回探测任务供调用方按需 await（单测），已消费/在飞/无凭据时
 /// 返回 nil。
 ///
 /// 语义与 `probeP1CapabilityIfColdStart` 完全一致，只是把「等它完成」从
 /// 首拨前的串行段去掉：结果落地后写回 `credentials`/会话窗口观测值，供
 /// 后续轮次（409 对齐、存量设备升 P1）使用。探测失败不改变本轮任何行为。
 ///
 /// 实施段（D 段 P1 修复）：任务句柄挂在实例上（`coldProbeTask`），
 /// **连接轮次出口不取消**——快连接下结果也必须落地；登出/解绑由 `disconnect`
 /// 取消。完成时按代次清理句柄，避免把后来新起的探测误清。
    @discardableResult
    func startColdStartCapabilityProbe(primaryOrigin: URL?) -> Task<Void, Never>? {
        guard !p1ColdStartProbeConsumed, coldProbeTask == nil else { return nil }
        p1ColdStartProbeConsumed = true
        coldProbeGeneration += 1
        let generation = coldProbeGeneration
        let task = Task { [weak self] in
            await self?.performColdStartCapabilityProbe(
                primaryOrigin: primaryOrigin,
                generation: generation
            )
            guard let self, self.coldProbeGeneration == generation else { return }
            self.coldProbeTask = nil
        }
        coldProbeTask = task
        return task
    }

 /// 取消在飞的冷启能力探测（登出/解绑/重新配对时调用，避免结果写回旧凭据语境）。
 ///
 /// 注意：`cancel()` 只是协作式的——`HTTPSClient.json` 的
 /// `withCheckedThrowingContinuation` **不感知取消**，探测仍会跑完（≤0.5s）。
 /// 所以「不写回旧凭据」不靠取消本身，而靠 `performColdStartCapabilityProbe`
 /// 写回前的三重校验（未取消 + 代次未变 + 仍是同一台设备；见 B-1 修复）。
    private func cancelColdStartCapabilityProbe() {
        coldProbeGeneration += 1
        coldProbeTask?.cancel()
        coldProbeTask = nil
    }

 /// 冷启能力探测的实际工作（/health 取数 + 能力/窗口写回）。
 ///
 /// B-1（审查阻断）：`generation` = 发起时的探测代次。`await` 期间可能发生
 /// 解绑/重新配对/切设备，而 /health 请求不感知取消 → 必须在**任何写回之前**
 /// 校验「本次结果仍属于当前凭据语境」，否则会用旧快照覆盖/复活已删已换的
 /// 凭据（`PairingCredentials` 含 origin/deviceId/credential/ticket）。
    private func performColdStartCapabilityProbe(primaryOrigin: URL?, generation: Int) async {
        guard let current = credentials else { return }
 // 主候选优先；无候选时退回持久化的 origin（旧调用语义）。
        guard let origin = primaryOrigin ?? current.originURL else { return }
        linkDebug("cold-probe: target=" + (origin.host ?? "?"))
        do {
            let status: Int
            let json: JSONValue
            if let fetch = p1ColdStartProbeFetch {
                let response = try await fetch(origin)
                status = response.status
                json = response.json
            } else {
                let response = try await HTTPSClient.json(
                    origin: origin,
                    method: "GET",
                    path: "/health",
                    leafPin: current.leafPin,
                    caCertBase64: current.caCertBase64,
                    timeout: Self.p1ColdStartProbeTimeoutSeconds
                )
                status = response.status
                json = response.json
            }
            guard status == 200 else {
                throw LinkError.httpStatus(status, "cold-probe /health")
            }
            let capabilities = Self.p1HealthCapabilities(from: json)
 // B-1（审查阻断）：await 期间可能已解绑/重新配对/切设备，而 /health
 // 请求不感知 Task 取消（`withCheckedThrowingContinuation`）。写回前
 // 三重校验，任一不满足就整份丢弃——否则旧凭据快照会覆盖（或复活）
 // 已删/已换的凭据：解绑后静默复活旧配对、重新配对后被旧快照顶掉
 // （需二次扫码，触 AC-12）。这也是 `cancelColdStartCapabilityProbe`
 // 注释里承诺的「结果不得写回已失效的凭据语境」的真正落点。
            guard !Task.isCancelled,
                  coldProbeGeneration == generation,
                  let latest = credentials,
                  latest.deviceId == current.deviceId else {
                linkDebug("cold-probe: 结果已过期（取消/代次变化/凭据已换），整份丢弃不写回")
                return
            }
 // 本周期观测结论（对齐优先级高于 credentials 缓存）：旧插件无字段
 // = 观测到「无窗口」，缓存同步清空（存 nil，设计变更二审拍板）。
            sessionTakeoverWindowObserved = true
            sessionTakeoverWindowMs = capabilities.takeoverWindowMs
 // 能力与窗口写回（存量设备升 P1 的 F3 路径 + 下一周期缓存）。
 //
 // 实施段（B-1 同一根因的另一面）：写回基准必须是**当前**
 // 凭据 `latest`，而不是探测起点快照——`await` 期间同一轮握手可能刚
 // 写入了轮换后的 connectTickets / p1Epoch / p1Sid、或已升 P1；拿旧
 // 快照 `current` 整体覆盖会把这些一并冲掉（丢 resume 游标/复用已删
 // ticket）。这里只把「能力位 + 接管窗口」合并进最新凭据。
            guard latest.supportsMuxRPC != capabilities.supportsMuxRPC
                || latest.takeoverWindowMs != capabilities.takeoverWindowMs else { return }
            var updated = latest
            updated.supportsMuxRPC = capabilities.supportsMuxRPC
            updated.takeoverWindowMs = capabilities.takeoverWindowMs
            credentials = updated
            if let persist = p1ColdStartProbePersist {
                persist(updated)
            } else {
                try? store.save(updated)
            }
            linkDebug(
                "cold-probe: supportsMuxRPC=" + (capabilities.supportsMuxRPC ? "1" : "0")
                    + " takeoverWindowMs=" + (capabilities.takeoverWindowMs.map(String.init) ?? "-")
            )
        } catch {
 // 探测失败：不动缓存、不阻塞本轮（按缓存值继续），本生命周期不再探测。
            linkDebug("cold-probe: 失败（不阻塞，按已知值继续）: " + NetworkErrorInterpreter.message(for: error))
        }
    }

 /// 冷启动探测的有界超时（设计 §3-L2：500ms）。
    static let p1ColdStartProbeTimeoutSeconds: TimeInterval = 0.5

    private enum ConnectAttemptOutcome {
 /// `bumpGeneration` is false only for a silent replay (streams retained).
        case connected(bumpGeneration: Bool)
        case credentialRejected(String)
 /// The origin answered "cannot serve right now" (503 host/inactive, 5xx
 /// gateway): the round must switch to the next candidate immediately, with
 /// no timeout wait and no retry of this candidate.
        case fastRejected(String, CandidateFailureClass)
        case failed(String)
    }

 /// Outcome of one dsh-m/2 attempt. `useLegacy` is the design's
 /// `LEGACY_FALLBACK` transition: the candidate is still tried on M1.
    private enum P1AttemptOutcome {
 /// `bumpGeneration` is false when the handshake silently continued the
 /// retained stream table via `welcome.resume.mode=replay`.
        case connected(bumpGeneration: Bool)
        case useLegacy(String)
        case credentialRejected(String)
        case failed(String)
    }

 /// One connection attempt against a concrete origin.
 ///
 /// Dual-stack pre-step (designed in `p1-app-integration.zh.md` §1): when the
 /// rollout flag and the plugin capability both allow it, try the single-WSS
 /// dsh-m/2 path first. A fallback-class failure degrades this app session to
 /// the unchanged legacy M1 path, which then runs on the same candidate.
    private func attemptConnection(
        origin: URL,
        leafPin: String,
        timeout: TimeInterval,
        coldStartOptimistic: Bool = false
    ) async -> ConnectAttemptOutcome {
 // link-perf L2：flag 语义反转后 `AppSettings.remoteProtocolV2`
 // 默认 on（env/UserDefaults 显式覆盖优先）；能否走 P1 由 supportsMuxRPC
 // （配对/冷启动探测/welcome 缓存）与会话级回退状态把关。
 //
 // D 段：本 App 周期首个轮次带 `coldStartOptimistic`——缓存
 // `supportsMuxRPC` 还不是 true（未配对探测/旧缓存 false）时也先试 P1：
 // P1 upgrade/hello 拒绝会走 `.useLegacy` 在**同一候选内**回退旧路径，
 // 于是「协商」在 1 次连接尝试内完成（不再先付 /health 的 500ms）。
        if Self.transportRoute(
            flagEnabled: AppSettings.remoteProtocolV2,
            supportsMuxRPC: credentials?.supportsMuxRPC,
            fellBackToLegacy: p1FellBackToLegacy,
            coldStartOptimistic: coldStartOptimistic
        ) == .p1 {
            switch await attemptP1Connection(origin: origin, leafPin: leafPin, timeout: timeout) {
            case .connected(let bumpGeneration):
                return .connected(bumpGeneration: bumpGeneration)
            case .credentialRejected(let reason):
                return .credentialRejected(reason)
            case .failed(let reason):
                return .failed(reason)
            case .useLegacy(let reason):
 // 4400/4403, or 4401 with both the ticket and the ECDSA retry
 // exhausted: stop probing dsh-m/2 for the rest of this session
 // and drop any retained resume channel/stream table.
                p1FellBackToLegacy = true
                p1SilentResume = false
                p1LostAt = nil
                teardownP1Channel()
                ConnectionMetrics.markFallbackLegacy()
                lastErrorText = reason
            }
        }
        return await attemptLegacyConnection(origin: origin, leafPin: leafPin, timeout: timeout)
    }

 /// Pure routing decision between the dsh-m/2 channel and the legacy M1 path.
 /// Kept free of LinkService state so the whole matrix is unit-testable.
 ///
 /// `coldStartOptimistic`：本 App 周期首个连接轮次用
 /// 「P1 握手即能力探测」代替拨号前的串行 /health——缓存 capability 未知/
 /// false 时也先试 P1，旧插件会以 upgrade 拒绝（401/403/503）在同一候选内
 /// 回退 legacy；P1 成功则协商（gzip/projV1/muxRPC）在本次尝试内完成。
    nonisolated static func transportRoute(
        flagEnabled: Bool,
        supportsMuxRPC: Bool?,
        fellBackToLegacy: Bool,
        coldStartOptimistic: Bool = false
    ) -> TransportRoute {
        guard flagEnabled, !fellBackToLegacy else { return .legacy }
        if supportsMuxRPC == true { return .p1 }
        return coldStartOptimistic ? .p1 : .legacy
    }

    enum TransportRoute: Equatable {
        case p1
        case legacy
    }

 /// One legacy M1/M2b connection against a concrete origin: mux token -> WSS
 /// mux -> $events ready. Unchanged by the P1 integration.
    private func attemptLegacyConnection(origin: URL, leafPin: String, timeout: TimeInterval) async -> ConnectAttemptOutcome {
        guard let host = origin.host, !host.isEmpty else {
            return .failed(L10n.t("origin 缺少 host"))
        }
        let port = UInt16(origin.port ?? 443)

 // cold start <1s（第二级）：TCP+TLS 建立与 mux token 的
 // challenge/verify 互不依赖。真机拆解显示 TLS 段 ~300ms、auth 段 ~100ms，
 // 且原本是「auth 用一条 TLS 连接、WSS 再建一条 TLS」的串行两段。
 // 这里先把 WSS 的 TLS 连接放到后台并行建立，auth 完成后再发 upgrade，
 // 把第二段 TLS 从关键路径上消掉（预期 −150~250ms）。
        let ws = WSSClient(
            host: host,
            port: port,
            path: "/api/remote.mux",
            headers: [:],
            leafPin: leafPin,
            caCertBase64: credentials?.caCertBase64
        )
        self.ws = ws
        let wsPrepare = Task { try await ws.prepareConnection(timeout: timeout) }

 // Cold-start critical path: the unary api token and the mux
 // token are two independent 2-RTT challenge/verify rounds. Mint them
 // **concurrently** (purpose-scoped in-flight tasks) instead of serializing
 // them: on a 5G relay each round trip is ~150–300ms and the list request
 // waits on the api token, so this removes one full round trip from
 // "connected → list visible" (part of the <1s cold-start target).
        let apiTokenPrefetch = Task { [weak self] () -> String? in
            guard let self else { return nil }
            return try? await self.ensureAPIToken()
        }

 // Every physical mux connection needs a fresh single-use mux token.
        let muxToken: String
        do {
            muxToken = try await authenticateToken(purpose: "mux", timeout: timeout)
        } catch {
            apiTokenPrefetch.cancel()
            wsPrepare.cancel()
            ws.close()
            self.ws = nil
            let reason = NetworkErrorInterpreter.message(for: error)
            if isCredentialRejection(error) { return .credentialRejected(reason) }
 // Cross-network: `503 {error:"host/inactive"}` means this origin's
 // plugin instance is not serving; switching candidates costs one
 // round-trip instead of a full timeout.
            let failureClass = Self.failureClass(for: error)
            if failureClass.isFastReject { return .fastRejected(reason, failureClass) }
            return .failed(reason)
        }
        ConnectionMetrics.markAuth()
        if Task.isCancelled {
            apiTokenPrefetch.cancel()
            wsPrepare.cancel()
            ws.close()
            self.ws = nil
            return .failed(L10n.t("已取消"))
        }

        do {
            try await wsPrepare.value
        } catch {
            apiTokenPrefetch.cancel()
            self.ws = nil
            let reason = NetworkErrorInterpreter.message(for: error)
            if isCredentialRejection(error) { return .credentialRejected(reason) }
            let failureClass = Self.failureClass(for: error)
            if failureClass.isFastReject { return .fastRejected(reason, failureClass) }
            return .failed(reason)
        }
        ws.setUpgradeHeaders(["authorization": "Bearer \(muxToken)"])
        do {
            try await ws.upgrade(timeout: timeout)
        } catch {
            apiTokenPrefetch.cancel()
            self.ws = nil
            let reason = NetworkErrorInterpreter.message(for: error)
            if isCredentialRejection(error) { return .credentialRejected(reason) }
 // A 5xx upgrade refusal is a fast reject (plugin/gateway state), not a
 // transient timeout: do not sit on this candidate.
            let failureClass = Self.failureClass(for: error)
            if failureClass.isFastReject { return .fastRejected(reason, failureClass) }
            return .failed(reason)
        }
        ConnectionMetrics.markWS()
        guard self.ws === ws else {
            apiTokenPrefetch.cancel()
            return .failed(L10n.t("连接被取消"))
        }
        let mux = RemoteMux(ws: ws)
        mux.onClose = { [weak self] error in
            self?.handleTransportLost(error: error)
        }
        self.mux = mux
 // 冷启动 <1s（用户人工验收）：mux 一旦建立，unary 与 streams 都已可用；
 // `$events` ready 是连接路径上最后 ~150ms，而列表请求根本不依赖它。
 // 因此这里立即返回 connected，把 ready 握手放到后台完成：
 // - 成功：事件流/审批/问题卡正常到达（稍晚 ~150ms，无感）；
 // - 失败/超时：按「传输失联」处理（teardown + 重连），不会出现「在线但事件
 // 永不到达」的静默坏状态。
 // 指标口径：readyMs 现在等于 mux 建立时刻（readyMs≈wsMs），真实握手完成打日志。
        ConnectionMetrics.markReady()
        eventsHandshakeTask?.cancel()
        eventsHandshakeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.openEventsAndWaitReady(mux: mux, timeout: timeout)
                self.linkDebug("events ready (background handshake after connected)")
            } catch {
                guard !Task.isCancelled, self.mux === mux, self.phase.isConnected else { return }
                self.linkDebug("events ready failed after connected: " + NetworkErrorInterpreter.message(for: error))
                self.handleTransportLost(error: LinkError.transport(L10n.t("$events 未就绪，重新连接")))
            }
        }
        return .connected(bumpGeneration: true)
    }

 // MARK: - P1 single-WSS connection (dsh-m/2)

 /// One dsh-m/2 attempt against a concrete origin (design §5): pinned WSS on
 /// `/api/remote.mux?proto=2` -> `hello` (resume ticket first, ECDSA mux token
 /// fallback) -> `welcome` -> `$events` subscription.
 ///
 /// On this path `welcome` is the ready signal: there is no 15s `$events`
 /// ready wait and no separate unary TLS. Failure classes:
 /// - 4400/4403 (`shouldFallbackLegacy`) -> `.useLegacy`;
 /// - 4401 -> one ECDSA-mux-token retry, then `.useLegacy`;
 /// - 4408/4409 -> one 200–500ms backoff retry, then fallback/fail;
 /// - 1011/1013/1006 -> one full channel reconnect, then `.failed`;
 /// - upgrade refused with HTTP 401/403/503 (old plugin / flag off) -> `.useLegacy`.
    private func attemptP1Connection(origin: URL, leafPin: String, timeout: TimeInterval) async -> P1AttemptOutcome {
        guard let host = origin.host, !host.isEmpty else {
            return .failed(L10n.t("origin 缺少 host"))
        }
        let port = UInt16(origin.port ?? 443)
        let resume = p1ResumeCursor()

        var auth: P1Auth
        var authMode: String
        if let ticket = credentials?.connectTickets?.first, !ticket.isEmpty {
            auth = P1Auth(ticket: ticket)
            authMode = "ticket"
 // No extra round trip: tickets are minted at pair/redeem + welcome.
            ConnectionMetrics.markAuth()
        } else {
            do {
                let muxToken = try await authenticateToken(purpose: "mux", timeout: timeout)
                auth = P1Auth(muxToken: muxToken)
                authMode = "muxToken"
                ConnectionMetrics.markAuth()
            } catch {
                let reason = NetworkErrorInterpreter.message(for: error)
                if isCredentialRejection(error) { return .credentialRejected(reason) }
                return .failed(reason)
            }
        }
        if Task.isCancelled { return .failed(L10n.t("已取消")) }

 // Reuse the retained channel after a socket loss (its stream table is the
 // resume state); a cold round builds a fresh one (design §5).
        let (channel, _) = p1Resume.channelForAttempt(
            host: host,
            port: port,
            leafPin: leafPin,
            connectTimeout: timeout
        )
 // DD-16：每一轮都按**当前**开关值重新协商 projV1（新通道由工厂闭包读
 // `AppSettings.projV1Enabled`；resume 复用的保留通道在这里同步）。
 // 覆盖「通知丢失 / 在未连接状态下改开关 / 重挂轮次」三种情形——活连接
 // 立即生效的重挂见 `applyProjV1SettingChange`。
        channel.applyWantsProjV1ForRemount(AppSettings.projV1Enabled)
        var rejectedTicket: String?
        var retriedTicket = false
        var retriedBackoff = false
        var retriedReconnect = false

        while true {
            if Task.isCancelled {
                channel.disconnect(reason: "cancelled")
                return .failed(L10n.t("已取消"))
            }
            do {
 // Replay frames may still be arriving after `connect` returns;
 // re-publish the metrics string once the window closes so the
 // E2E bench reads the final frame/byte counts (design §7.3).
                channel.onReplayWindowClosed = { [weak self] stats in
                    P1ResumeMetrics.markReplayComplete(frames: stats.frames, bytes: stats.bytes)
                    if let self {
                        self.connectionMetricsValue = self.connectionMetricsSummary()
                    }
                }
                let welcome = try await channel.connect(auth: auth, resume: resume)
                ConnectionMetrics.markWS()
                p1Channel = channel
                channel.onClose = { [weak self] failure in
                    self?.handleP1Close(failure)
                }
 // Decide replay vs rebuild *before* the ticket rotation so a
 // discard path can notify/drop the old stream table first.
                let plan = p1Resume.apply(welcome: welcome)
                let recoverMs = p1LostAt.map { max(0, Int(Date().timeIntervalSince($0) * 1000)) }
                p1LostAt = nil
                applyP1Welcome(
                    welcome,
                    usedTicket: authMode == "ticket" ? auth.ticket : nil,
                    rejectedTicket: rejectedTicket
                )
                adoptP1WelcomeBasics(welcome)
                if plan.reopenEvents {
 // reset/fresh (or replay without live streams): the old
 // `$events` subscription is gone with the old epoch.
                    eventsStream = nil
                    pendingApprovals.removeAll()
                    pendingUserQuestions.removeAll()
                    do {
                        try openEventsAndWaitReadyP1(channel: channel)
                    } catch {
                        p1Resume.discard()
                        teardownP1Channel()
                        return .failed(NetworkErrorInterpreter.message(for: error))
                    }
                }
                P1ResumeMetrics.record(plan: plan, welcome: welcome, recoverMs: recoverMs)
 // link-perf L3a：压缩协商结果取证（linkDebug；与插件侧
 // /health counters.p1Gzip* 对照；welcome 无回显 = 旧插件错配窗口）。
                linkDebug("p1 welcome: gzip=" + (channel.welcome?.caps.gzip == true ? "1" : "0"))
                ConnectionMetrics.markP1(authMode: authMode, resumeMode: welcome.resume.mode.rawValue)
                ConnectionMetrics.markReady()
                return .connected(bumpGeneration: plan.bumpGeneration)
            } catch let failure as P1Failure {
                let reason = failure.userMessage
                if failure.shouldFallbackLegacy { return .useLegacy(reason) }
                switch failure.action {
                case .retryWithECDSATicket:
                    guard authMode == "ticket", !retriedTicket else {
 // Ticket + ECDSA both rejected: the legacy path may still work.
                        return .useLegacy(reason)
                    }
                    retriedTicket = true
                    rejectedTicket = auth.ticket
                    do {
                        let muxToken = try await authenticateToken(purpose: "mux", timeout: timeout)
                        auth = P1Auth(muxToken: muxToken)
                        authMode = "muxToken"
                        ConnectionMetrics.markAuth()
                        continue
                    } catch {
                        let authReason = NetworkErrorInterpreter.message(for: error)
                        if isCredentialRejection(error) { return .credentialRejected(authReason) }
                        return .useLegacy(authReason)
                    }
                case .retryAfterBackoff:
                    guard !retriedBackoff else {
                        if failure.closeCode == P1CloseCode.connectionConflict.rawValue {
 // 4409 twice: the old socket is still owned server-side.
 // Let the candidate loop / backoff round retry later.
                            return .failed(reason)
                        }
 // 4408 twice: stop trusting dsh-m/2 for this session.
                        return .useLegacy(reason)
                    }
                    retriedBackoff = true
                    await Self.p1Backoff()
                    continue
                case .reconnect:
                    guard !retriedReconnect else { return .failed(reason) }
                    retriedReconnect = true
                    continue
                case .fallbackLegacy, .requestFailed, .none:
                    return .failed(reason)
                }
            } catch let protocolError as P1ProtocolError {
                return .failed(protocolError.localizedDescription)
            } catch {
                let reason = NetworkErrorInterpreter.message(for: error)
                if isCredentialRejection(error) { return .credentialRejected(reason) }
 // Old plugin / flag off: the anonymous `?proto=2` upgrade is
 // refused (401/403/503) before any frame — fall back to M1.
                if case .httpStatus(let status, _) = error as? LinkError,
                   status == 401 || status == 403 || status == 503 {
                    return .useLegacy(L10n.f("dsh-m/2 升级被拒绝（HTTP %lld）", status))
                }
                return .failed(reason)
            }
        }
    }

 /// 200–500ms jittered backoff for 4409/4408 (design §5 transition table).
    nonisolated static func p1Backoff() async {
        let milliseconds = Double.random(in: 200...500)
        try? await Task.sleep(nanoseconds: UInt64(milliseconds * 1_000_000))
    }

 /// App identity for `hello.client.version` (nil in unit-test hosts is fine).
    nonisolated static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

 /// Cursor persisted from the last live channel, for `hello{resume}`.
    private func p1ResumeCursor() -> P1ResumeCursor? {
        guard let credentials, let epoch = credentials.p1Epoch, !epoch.isEmpty else { return nil }
        return P1ResumeCursor(logEpoch: epoch, sid: Int64(credentials.p1Sid ?? 0))
    }

 /// Applies a successful `welcome`: rotates the in-band resume ticket, stores
 /// the `{epoch, sid}` cursor and caches the now-proven mux-rpc capability.
 ///
 /// The persisted `sid` is the channel's *applied* cursor (0 on reset/fresh,
 /// resume sid on replay); `teardownP1Channel` refreshes it once the replay
 /// frames have been applied, so a later drop never skips unapplied frames.
    private func applyP1Welcome(_ welcome: P1Welcome, usedTicket: String?, rejectedTicket: String?) {
        guard var credentials else { return }
        credentials.connectTickets = P1ResumeTickets.rotate(
            credentials.connectTickets,
            used: usedTicket,
            rejected: rejectedTicket,
            rotated: welcome.ticket
        )
        credentials.p1Epoch = welcome.epoch
        credentials.p1Sid = Int(clamping: p1Channel?.lastAppliedSid ?? 0)
        credentials.supportsMuxRPC = true
        self.credentials = credentials
        try? store.save(credentials)
    }

 /// `welcome` bookkeeping that is needed on both handshake branches: replay
 /// keeps the `$events` subscription, reset/fresh re-opens it, but the device
 /// id and the pending ready timeout are common.
    private func adoptP1WelcomeBasics(_ welcome: P1Welcome) {
        clientId = welcome.deviceId
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
    }

 /// 当前连接上真正生效的 `$events` clientId（必须来自本连接的 ready 帧）。
 ///
 /// 重连/冷启动后 Host 侧仍可能残留上一次连接的事件流 client；直接拿 `clientId`
 /// 发 `$events/result` 会被判成"另一个 Peer 的结果"。这里等 ready 落地
 /// （通常 <300ms），超时抛未连接错误，由调用方呈现可重试提示。
    func confirmedEventsClientId(timeoutMs: Int = 3000) async throws -> String {
        let deadline = Date().addingTimeInterval(Double(max(0, timeoutMs)) / 1000)
        while true {
            if eventsClientIdConfirmed, let clientId { return clientId }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        throw LinkError.notConnected
    }

 /// 单测 seam：直接设定"已确认的 `$events` clientId"，不经过真实流。
    func setConfirmedEventsClientIdForTesting(_ id: String?) {
        clientId = id
        eventsClientIdConfirmed = id != nil
    }

 /// 单测 seam：直接设定凭据（不走 `adopt` 的 Keychain 写入与
 /// `startConnecting`；hosted 单测与 E2E App 共享 Keychain）。
    func setCredentialsForTesting(_ value: PairingCredentials?) {
        credentials = value
    }

 /// 单测 seam：忽略网络路径变化事件。hosted 单测里模拟器启动期的首次
 /// 「satisfied 变化」可能触发 `handleNetworkPathChanged()` → `reconnectNow()`，
 /// 把 `phase` 改成 `connecting` 并起真实拨号，与「活连接」状态机断言互斥。
 /// 真实设备/App 恒为 false（只有单测会置 true）。
    var ignoresNetworkPathChangesForTesting = false

 /// 单测 seam：重置「本 App 周期已探测」状态（取消在飞探测 + 清观测值）。
 /// hosted 测试宿主的 Keychain 里若有真实凭据，`LinkService.init` 的自动连接
 /// 轮次可能已经消费过探测，单测需要从确定的初始态开始。
    func resetColdStartProbeStateForTesting() {
        cancelColdStartCapabilityProbe()
        p1ColdStartProbeConsumed = false
        sessionTakeoverWindowObserved = false
        sessionTakeoverWindowMs = nil
        muxConflictAlignEscalated = false
    }

 /// Persists the live channel's resume cursor into the Keychain credential.
    func persistP1Resume() {
        guard let p1Channel, var credentials, let resume = p1Channel.resumeState else { return }
        let sid = Int(clamping: resume.sid)
        guard credentials.p1Epoch != resume.logEpoch || credentials.p1Sid != sid else { return }
        credentials.p1Epoch = resume.logEpoch
        credentials.p1Sid = sid
        self.credentials = credentials
        try? store.save(credentials)
    }

 /// Drops the P1 channel without firing the channel `onClose` (caller-initiated
 /// teardown). Live streams still receive their per-stream `onClose` so the
 /// business layer can release its handles (legacy `RemoteMux` parity).
    func teardownP1Channel() {
        persistP1Resume()
        p1Channel?.onClose = nil
        p1Channel?.disconnect()
        p1Channel?.discardAllStreams()
        p1Channel = nil
        p1Resume.discard()
    }

 /// dsh-m/2 socket loss after the channel was ready (`welcome` delivered).
 ///
 /// Retryable losses keep the channel + stream table and reconnect immediately
 /// with `hello{resume}` (design §5 `READY -> RESUMING`). The first round is
 /// silent: `phase` stays `.connected` and no error banner is painted, so a
 /// replay success produces no UI flash and the `$events`/business streams stay
 /// subscribed. The silent window is bounded by one candidate attempt; after
 /// that (or for fallback-class closes) the regular visible reconnect path
 /// takes over.
    func handleP1Close(_ failure: P1Failure) {
        guard phase.isConnected || phase.isBusy || readyContinuation != nil else { return }
        let disposition = P1ResumePolicy.disposition(for: failure)
        if disposition == .fallbackLegacy {
            p1FellBackToLegacy = true
            p1SilentResume = false
            p1LostAt = nil
            if P1ResumePolicy.surfacesErrorBanner(disposition) {
                lastErrorText = failure.userMessage
            }
            ConnectionMetrics.markFallbackLegacy()
            failReady(LinkError.transport(L10n.f("连接中断: %@", failure.userMessage)))
            p1Resume.discard()
            teardownTransport()
            if !Task.isCancelled {
                _ = rotateOriginIfPossible(reason: failure.userMessage)
                scheduleReconnect()
            }
            return
        }
 // Resumable: keep every stream and the `{epoch, sid}` cursor, then run the
 // immediate silent `hello{resume}` round.
        persistP1Resume()
        p1Resume.retainAfterSocketLoss()
        p1LostAt = Date()
        p1SilentResume = phase.isConnected
        guard !Task.isCancelled else { return }
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            await self?.connectOnce()
        }
    }

 /// P1 `$events` subscription loss: the link itself stays ready (`welcome` was
 /// the ready signal), so only the approval/question waterfall is affected.
 ///
 /// The status emits share this stream and there is no re-subscribe path in
 /// this connection lifetime, so the live running map must be dropped as well:
 /// otherwise its last values would keep overriding `session/list` snapshots.
    func noteP1EventsStreamLoss(_ message: String) {
        lastErrorText = message
        clearLiveSessionRunning()
    }

 /// Points the credential's current origin at the origin under test.
    private func setCurrentOrigin(_ origin: URL, persist: Bool) {
        guard var credentials else { return }
        credentials.origin = PairingOriginSelector.normalizedOriginString(origin)
        self.credentials = credentials
        if persist {
            try? store.save(credentials)
            AppSettings.lastOrigin = credentials.origin
        }
    }

    func handleTransportLost(error: Error?) {
        guard phase.isConnected || phase.isBusy || readyContinuation != nil else { return }
        let reason = error.map { NetworkErrorInterpreter.message(for: $0) } ?? L10n.t("未知原因")
        lastErrorText = L10n.f("连接中断：%@", reason)
        failReady(LinkError.transport(L10n.f("连接中断: %@", reason)))
        teardownTransport()
        if !Task.isCancelled {
            _ = rotateOriginIfPossible(reason: reason)
            scheduleReconnect()
        }
    }

 /// Rotate to the next origin from the pairing payload. Used on physical
 /// iPhones when the current origin becomes unreachable (Wi-Fi change, QR
 /// generated with loopback only in older payloads, etc.).
    func rotateOriginIfPossible(reason: String) -> Bool {
        guard var credentials, let candidates = credentials.originCandidates, candidates.count > 1 else {
            return false
        }
        let current = credentials.origin
        let index = candidates.firstIndex(of: current) ?? -1
        let next = candidates[(index + 1) % candidates.count]
        guard next != current else { return false }
        credentials.origin = next
        self.credentials = credentials
        try? store.save(credentials)
        lastErrorText = L10n.f("地址 %@ 连接失败（%@），切换到 %@", current, reason, next)
        return true
    }

 /// Drops the pending approval/question cards.
 ///
 /// v0.1.1 (Bug 2): their live source is the `$events` waterfall, and a
 /// transport teardown during reconnect is not a logical disconnect — the
 /// Host re-delivers pending waterfalls (idempotently by `eventId`) once
 /// `$events` is ready again. Call this only on a real disconnect
 /// (user-initiated disconnect / unpair), right after `teardownTransport()`.
    func clearPendingWaterfalls() {
        pendingApprovals.removeAll()
        pendingUserQuestions.removeAll()
 // 真断开的 live 运行态一并作废：重连后以新的 `session/list` 快照为准。
        clearLiveSessionRunning()
    }

 /// Applies one live `api-session/status` emit (`session/list` 之外的实时运行态源)。
    func applyLiveSessionStatus(_ emit: LiveSessionStatusEmit) {
 // 同一开关值也刷新时间戳：只要还在收到 emit，就说明它是新鲜的网络事实。
        liveSessionRunningUpdatedAt[emit.sessionId] = Date()
        guard liveSessionRunning[emit.sessionId] != emit.running else { return }
        liveSessionRunning[emit.sessionId] = emit.running
        liveSessionStatusRevision += 1
    }

 /// Drops the live running overlay. The emit source (`$events`) is gone, so the
 /// values are unknowable until new emits arrive: the next `session/list` snapshot
 /// is the truth. Without this a lost `running=false` emit leaves a card stuck in
 /// 「进行中」 (and sorted to the top) for the rest of the connection, or forever if
 /// the snapshot is then overlaid with the stale value.
    func clearLiveSessionRunning() {
        guard !liveSessionRunning.isEmpty || !liveSessionRunningUpdatedAt.isEmpty else { return }
        liveSessionRunning.removeAll()
        liveSessionRunningUpdatedAt.removeAll()
        liveSessionStatusRevision += 1
    }

 /// Drops the active transport.
 ///
 /// - Parameter keepP1Resume: true only for the silent resume round that
 /// follows a resumable dsh-m/2 socket loss: the retained channel, its
 /// streams and the `$events` subscription stay alive so `hello{resume}`
 /// can continue them (design §5 `RESUMING`). Every other caller does a
 /// full teardown.
    func teardownTransport(keepP1Resume: Bool = false) {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
 // the $events handshake now runs after `connected`; a teardown
 // (reconnect/disconnect) must retire it so a late ready cannot touch the next
 // connection's state.
        eventsHandshakeTask?.cancel()
        eventsHandshakeTask = nil
        let preservingP1 = keepP1Resume && p1Resume.isRetained
        if !preservingP1 {
            eventsStream?.cancel()
            eventsStream = nil
            clientId = nil
            eventsClientIdConfirmed = false
 // v0.1.1 (Bug 2): pending approval/question waterfalls are **not**
 // dropped here. `teardownTransport` also runs at the start of every
 // reconnect attempt; clearing here is what made the answer card
 // hide and reappear every ~15–20s. They are cleared only by
 // `clearPendingWaterfalls()` on a real disconnect.
 // P1: persist `{epoch, sid}` before dropping the channel, then notify
 // and discard the stream table (caller-initiated close must not fire
 // the channel `onClose`).
            teardownP1Channel()
 // review P1: a full teardown also destroys the `$events`
 // subscription that feeds `api-session/status`, and reconnect only
 // re-delivers pending waterfalls (protocol §4.4) — it never replays
 // status emits. Keeping the map here meant a lost `running=false`
 // could override every later `session/list` snapshot with a stale
 // 「进行中」. Unlike approvals (re-delivered idempotently), running
 // state is not re-delivered, so it must fall back to the snapshot.
            clearLiveSessionRunning()
        }
        if let continuation = readyContinuation {
            readyContinuation = nil
            continuation.resume(throwing: LinkError.cancelled)
        }
        mux?.onClose = nil
        mux = nil
 // 重连提速根因修复：旧 mux socket 必须真正关闭（WS close 帧 +
 // TCP FIN），而不是置 nil 后遗弃。遗弃的 socket 让插件端
 // `device.downstream` 保持占用，新升级在「静默 1.5s 接管窗口」内一律被
 // 409 拒绝（真机实测 `HTTP 409: mux 升级被拒绝`，把重连拖到 2.8–8.4s
 // 甚至 31s 风暴）。插件在 WS close 事件里立即清 downstream，主动关闭
 // 后新升级（~百 ms 后）就无冲突。选 ws.close() 而非 mux.close()：
 // 绕过 per-stream onClose 回调，副作用面与原「遗弃」路径完全一致，
 // 只多一次干净的挥手；真实跨网切换（旧网已死发不出 close）仍由插件的
 // stale-takeover 兜底。
        if let ws {
            ws.close()
        }
        ws = nil
    }

 /// The `connect-metrics` string consumed by the E2E bench: unchanged
 /// `ConnectionMetrics` fields plus the P1 resume/replay segment (design §7.3).
    private func connectionMetricsSummary() -> String? {
        let resume = P1ResumeMetrics.summary
        guard let base = ConnectionMetrics.valueString else {
            return resume.isEmpty ? nil : resume
        }
        return resume.isEmpty ? base : base + ";" + resume
    }

 // MARK: - 冷启动 HTTPS 池预热

 /// 冷启动时预热共享 HTTPS 连接池。
 ///
 /// 真机拆解：early `session/list` 在 t0+~100ms 就发出，但连接池是空的 → 首个
 /// 请求（api token 认证）要先付一次 TLS，列表请求再复用同一条
 /// 连接。这里在启动连接轮次的同时把 TCP+TLS 握手提前做掉并留在池里，认证/列表
 /// 都直接复用 → 列表侧预期 −200~300ms。
 ///
 /// T2(A)：预热改为 **TLS-only**（`HTTPSClient.prewarmTLS`）。B1 实测
 /// 旧的 `GET /health` 预热要额外付 1 个 RTT（整段 ~400–470ms），等待成本抵消了
 /// 收益；只握手不发送请求可以让预热 ≈ TLS 时长。
 ///
 /// 只在「本次进程还没成功连过」时执行；网络切换/重连不重复预热。选择 origin 的
 /// 规则与拨号序一致：蜂窝/跨网优先 relay 候选，避免预热打到失效 LAN 上。
    private func warmHTTPSPoolIfColdStart(prefersRelay: Bool, local: LocalIPv4Network?) {
        guard lastConnectedAt == nil, poolWarmupTask == nil, let credentials else { return }
        guard let origin = Self.poolWarmupOrigin(
            current: credentials.origin,
            stored: credentials.originCandidates,
            prefersRelay: prefersRelay,
            local: local
        ) else { return }
        let leafPin = credentials.leafPin
        let caCertBase64 = credentials.caCertBase64
        linkDebug("pool warm-up (tls-only) -> " + Self.originLabel(origin))
        poolWarmupTask = Task { [weak self] in
            defer { self?.poolWarmupTask = nil }
 // T2(A)：只做 TCP+TLS 握手（不发 /health），把握手放到连接
 // 轮次并行进行；随后 auth/list 直接 checkout 这条空闲连接。
            _ = await HTTPSClient.prewarmTLS(
                origin: origin,
                leafPin: leafPin,
                caCertBase64: caCertBase64,
                timeout: 3
            )
        }
    }

 /// T2(B1)：冷启动首屏列表前等 HTTPS 池预热就绪，最多 `timeoutMs` 毫秒。
 ///
 /// 竞态语义（以下三种情况都**不抛错、不取消预热任务**）：
 /// - 没有在飞的预热（热路径 / 预热已完成 / 从未预热）：立即返回，零额外延迟；
 /// - 预热在飞：等它结束；超时按 `timeoutMs` 上限返回，预热继续在后台跑完，
 /// 后续请求（含已放行的列表请求）仍能复用它建好的连接；
 /// - 预热失败：任务内部吞掉握手错误后正常结束，这里按「完成」返回，调用方
 /// 直接走原路径（该付的 TLS 照付，不影响正确性）。
    func awaitPoolWarmup(timeoutMs: Int) async {
        guard let task = poolWarmupTask else { return }
        await PoolWarmupWait.wait(for: task, timeoutMs: timeoutMs)
    }

 /// Pure origin choice for the cold-start pool warm-up (unit-tested). Same rule as
 /// the dial order: cellular/cross-network warms the relay candidate, LAN paths
 /// warm the stored current origin.
    nonisolated static func poolWarmupOrigin(
        current: String?,
        stored: [String]?,
        prefersRelay: Bool,
        local: LocalIPv4Network?
    ) -> URL? {
        let candidates = PairingOriginSelector.reconnectCandidates(current: current, stored: stored)
        if prefersRelay,
           let relay = candidates.first(where: { candidateRole(host: $0.host, local: local) == .relay }) {
            return relay
        }
        return candidates.first
    }

 // MARK: - 运行时端点自愈（用户：任何网络都要连得上，且极致快）

 /// 一轮连接前的并行发现：mDNS 拿 Mac **当前** 端点 + 对候选并行打 `/health`。
 ///
 /// 两项都带硬预算（≤1.5s）且并发执行：即便发现全部失败，也只让这一轮多等一次
 /// 预算，随后回落到原有的串行拨号。
 ///
 /// 跨网去浪费：
 /// 手机在蜂窝（无本地 LAN 接口）时——
 /// - mDNS 是链路本地多播，物理上不可能看到 Mac 的广播：浏览预算纯浪费
 /// （实测 heal mdns=0 仍白等预算）→ 跳过；
 /// - LAN 候选跨网必然不可达，探测它们只会把收敛时间钉死在探测超时上
 /// （实测 7 候选全部 unreachable@1590ms，把 relay 失败后的收敛等待拖到
 /// 2.2s）→ 只探测 relay 候选，relay 探测健康时收敛 ~150ms 即完成。
    private func discoverAndProbe(
        candidates: [URL],
        local: LocalIPv4Network?,
        prefersRelay: Bool,
        credentials: PairingCredentials
    ) async -> (origins: [String], observations: [EndpointHealing.ProbeObservation]) {
 // 单候选且端点不脏：没有可切换目标、地址也不可能过时，直接拨（省掉预算）。
        let shouldDiscover = endpointsDirty || candidates.count > 1
        let probeTargets = Self.probeTargets(candidates: candidates, local: local, prefersRelay: prefersRelay)
        let shouldProbe = EndpointHealing.shouldProbe(candidateCount: probeTargets.count)
 // mDNS 只在手机自己有 LAN 接口时才有可能命中（见上）；蜂窝下跳过。
        let shouldBrowse = shouldDiscover && local != nil
        guard shouldBrowse || shouldProbe else { return ([], []) }
        let hasLANCandidate = candidates.contains {
            Self.candidateRole(host: $0.host, local: local) != .relay
        }
        let discoveryBudget = EndpointHealing.discoveryBudget(hasLANCandidate: hasLANCandidate)
        let probeTimeout = EndpointHealing.probeTimeout(candidateCount: probeTargets.count)
        async let discovered: LANEndpointDiscovery.Result = shouldBrowse
            ? LANEndpointDiscovery.discover(
                hostId: credentials.hostId,
                leafPin: credentials.leafPin,
                caCertBase64: credentials.caCertBase64,
                budget: discoveryBudget
            )
            : LANEndpointDiscovery.Result()
        async let probed: [EndpointHealing.ProbeObservation] = shouldProbe
            ? probeCandidateHealth(probeTargets, timeout: probeTimeout)
            : []
        let (mdns, observations) = await (discovered, probed)
        var origins = mdns.origins
 // 根因修复（N-04）：只有「广播的 hostId 与配对 hostId 一致」（或旧
 // 凭据没有 hostId 时由 matchMacs 的唯一一台规则采纳）才把 mDNS relay 端点写进
 // 拨号序。hostId 不匹配的发现结果永不使用——那是别的 Mac/DSH 实例的中继。
        let mdnsHostMatches = credentials.hostId == nil || mdns.hostId == credentials.hostId
        if let relay = mdns.relayOrigin, mdnsHostMatches { origins.append(relay) }
        let probeSummary = EndpointHealing.rankProbes(observations)
            .map { "\($0.origin)=\($0.result)\( $0.latencyMs)ms" }
            .joined(separator: ",")
        linkDebug("heal mdns=\(mdns.origins.count) relay=\(mdns.relayOrigin ?? "-") probes=[\(probeSummary)]")
        return (origins, observations)
    }

 /// 只读 `/health` 的并行探测（不认证、不改凭据、不碰 mux），给选路提供
 /// "此刻谁能连"的事实，替代按存储顺序盲试。
    private func probeCandidateHealth(
        _ candidates: [URL],
        timeout: TimeInterval
    ) async -> [EndpointHealing.ProbeObservation] {
        let leafPin = credentials?.leafPin
        let caCertBase64 = credentials?.caCertBase64
        let normalized = candidates.map { PairingOriginSelector.normalizedOriginString($0) }
        return await withTaskGroup(of: EndpointHealing.ProbeObservation.self) { group in
            for (index, url) in candidates.enumerated() {
                let origin = normalized[index]
                group.addTask {
                    let started = ProcessInfo.processInfo.systemUptime
                    func elapsedMs() -> Int {
                        Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
                    }
                    do {
                        let response = try await HTTPSClient.json(
                            origin: url,
                            method: "GET",
                            path: "/health",
                            leafPin: leafPin,
                            caCertBase64: caCertBase64,
                            timeout: timeout
                        )
                        let healthy = response.status == 200 && response.json["ok"]?.boolValue == true
                        return EndpointHealing.ProbeObservation(
                            origin: origin,
                            result: healthy ? .healthy : .rejected,
                            latencyMs: elapsedMs()
                        )
                    } catch {
                        return EndpointHealing.ProbeObservation(
                            origin: origin,
                            result: .unreachable,
                            latencyMs: elapsedMs()
                        )
                    }
                }
            }
            var observations: [EndpointHealing.ProbeObservation] = []
            for await observation in group { observations.append(observation) }
            return observations
        }
    }

    nonisolated static func originLabel(_ url: URL) -> String {
        let host = url.host ?? url.absoluteString
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

 /// 本轮拨号顺序：mDNS 当前端点（已被 `/health` 验证）→ 并行探测结论
 /// （healthy 按延迟、rejected 次之）→ 其余存量候选兜底。
    nonisolated static func dialOrder(
        discovered: [String],
        observations: [EndpointHealing.ProbeObservation],
        fallback: [URL],
        local: LocalIPv4Network?,
        prefersRelay: Bool
    ) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        func append(_ url: URL) {
            let key = PairingOriginSelector.normalizedOriginString(url).lowercased()
            guard seen.insert(key).inserted else { return }
            result.append(url)
        }
        let discoveredURLs = PairingOriginSelector.candidates(
            from: discovered,
            allowLoopback: !PairingOriginSelector.isPhysicalDevice
        )
        for url in discoveredURLs { append(url) }
        for observation in EndpointHealing.rankProbes(observations) where observation.result != .unreachable {
            guard let url = URL(string: observation.origin) else { continue }
            append(url)
        }
        for url in fallback { append(url) }
 // 组合完再按当前网络路径做一次稳定分组：同一 Wi-Fi 同网段 LAN 优先；
 // 蜂窝/跨网段中继优先（LAN 只兜底）。组内保留 mDNS/探测得到的顺序。
        guard result.count > 1 else { return result }
        var relay: [URL] = []
        var lanSame: [URL] = []
        var lanOther: [URL] = []
        for url in result {
            switch candidateRole(host: url.host, local: local) {
            case .relay: relay.append(url)
            case .lanSameSubnet: lanSame.append(url)
            case .lanOther: lanOther.append(url)
            }
        }
        if !prefersRelay, !lanSame.isEmpty { return lanSame + relay + lanOther }
        if prefersRelay || local != nil { return relay + lanOther + lanSame }
        return result
    }

 /// 连接成功后把 Mac 当前的 `/health.deviceEndpoints` 合并回持久化候选：
 /// 网络再变时手机手里是"现在的地址"，而不是配对那天的。
    private func refreshEndpointsAfterConnect(origin: URL) {
        guard let current = credentials else { return }
        let pathChanged = endpointsDirty
        guard EndpointHealing.shouldRefreshEndpoints(
            lastRefreshAt: lastEndpointRefreshAt,
            now: Date(),
            networkPathChanged: pathChanged
        ) else { return }
        lastEndpointRefreshAt = Date()
        Task { [weak self] in
            guard let self else { return }
            let response = try? await HTTPSClient.json(
                origin: origin,
                method: "GET",
                path: "/health",
                leafPin: current.leafPin,
                caCertBase64: current.caCertBase64,
                timeout: 4
            )
            guard let response, response.status == 200 else { return }
            let advertised = Self.healthDeviceEndpoints(from: response.json)
            guard !advertised.isEmpty else { return }
            self.applyAdvertisedEndpoints(advertised, currentOrigin: origin)
        }
    }

 /// 合并并持久化 Mac 广播的端点；有变化时同步更新内存凭据（下一轮立即用新顺序）。
    @discardableResult
    func applyAdvertisedEndpoints(_ advertised: [String], currentOrigin: URL) -> [String]? {
        guard var latest = credentials else { return nil }
        let merged = EndpointHealing.mergeAdvertised(
            current: PairingOriginSelector.normalizedOriginString(currentOrigin),
            stored: latest.originCandidates,
            advertised: advertised
        )
        guard !merged.isEmpty, merged != latest.originCandidates else { return nil }
        latest.originCandidates = merged
        credentials = latest
        try? store.save(latest)
        linkDebug("endpoints healed: " + merged.joined(separator: ","))
        return merged
    }

 /// DEBUG 一行诊断日志。
    private func linkDebug(_ message: String) {
        #if DEBUG
        NSLog("[LINKHEAL] %@", message)
        #endif
    }
}

// MARK: - task-2 reconnect policy (pure, unit-tested)

extension LinkService {
 /// Spec §3.8 backoff: base 500ms, factor 2, cap 10s, 50% jitter. Extracted from
 /// `scheduleReconnect()` so the bounds are unit-tested instead of only observed.
    nonisolated static func reconnectDelayMs(attempt: Int, randomUnit: Double) -> Double {
        let base = min(10_000.0, 500.0 * pow(2.0, Double(max(0, attempt - 1))))
        let unit = min(1, max(0, randomUnit))
        return base / 2 + unit * (base / 2)
    }

 /// "桌面端还在启动"：这一轮所有候选都是服务端未就绪类失败（插件未就绪 / 网关 5xx /
 /// 地址不可达 / 超时），而不是凭据失效或被取消。重启桌面的窗口很短，值得密探。
    nonisolated static func isBootWindow(classes: [CandidateFailureClass]) -> Bool {
        guard !classes.isEmpty else { return false }
        return classes.allSatisfy {
            $0 == .pluginNotReady || $0 == .gatewayRejected || $0 == .unreachable || $0 == .timeout
        }
    }

 /// 启动窗口内的短固定退避：400ms 起、每轮 +200ms、上限 1.5s。
 /// 桌面端插件恢复通常在数秒内，指数退避（500ms→…→10s）会把等待放大到 ~10s。
    nonisolated static func bootWindowDelayMs(attempt: Int) -> Double {
        min(1_500.0, 400.0 + Double(max(0, attempt - 1)) * 200.0)
    }

 /// Per-candidate budget inside one round. The last candidate keeps a longer
 /// budget so a slow-but-working relay still connects; the others are bounded so
 /// a stale LAN address cannot burn time before the relay is dialed.
 ///
 /// real-device calibration (iPhone 16 Pro Max on 5G + relay): a
 /// **healthy** legacy connect measured `candidateMs=1577–1602ms` end-to-end
 /// (TLS + mux auth + WSS upgrade + `$events` ready), and a degraded-path
 /// `/auth/challenge` attempt was aborted at 1617ms. The old 1.5s/2s budgets
 /// therefore cancelled attempts that were about to succeed (two failed rounds
 /// in the 11:53 cold-start storm: 2.35s connected → 800ms watchdog kill →
 /// two 1.5s-budget rounds aborted → 28.4s total). Non-last candidates now get
 /// 3s (2.5s after a path change) so one healthy 5G relay round fits.
    nonisolated static func candidateTimeoutSeconds(
        index: Int,
        count: Int,
        pathChanged: Bool
    ) -> TimeInterval {
        if index >= count - 1 { return 8 }
        return pathChanged ? 2.5 : 3
    }

 // MARK: Candidate role + path-aware order (cross-network requirement)

 /// Role of one stored origin relative to the phone's current network.
    enum CandidateRole: String {
 /// Public relay bridge (reachable from any network).
        case relay = "relay"
 /// LAN origin inside the phone's current subnet (fastest path).
        case lanSameSubnet = "lan-same"
 /// LAN origin from another network / different subnet (fallback only).
        case lanOther = "lan-other"
    }

    nonisolated static func candidateRole(host: String?, local: LocalIPv4Network?) -> CandidateRole {
        guard PairingOriginSelector.isLANHost(host) else { return .relay }
        guard let local, local.contains(host: host) else { return .lanOther }
        return .lanSameSubnet
    }

 /// Path-aware candidate order for one reconnect round:
 /// - **same LAN** (Wi-Fi/wired and the LAN candidate is inside the phone's
 /// subnet): LAN first, relay as fallback — the Mac's LAN origin is the fastest;
 /// - **cellular / cross-network** (no LAN candidate on this subnet): relay first,
 /// LAN addresses last as a best-effort fallback — the old serial "try the
 /// stale LAN first and burn seconds" order is exactly the reported failure;
 /// - **unknown local network**: legacy order (current origin, then stored list).
 ///
 /// Happy Eyeballs (parallel first dial) is deliberately **not** used:
 /// `authInFlightByPurpose` is purpose-scoped and two concurrent attempts would
 /// fight over `self.ws`/`self.mux` and multiply `/auth/challenge` requests
 /// (plugin rate limit). The serial walk is bounded by `roundBudgetSeconds`.
    nonisolated static func orderedCandidatesForPath(
        _ candidates: [URL],
        prefersRelay: Bool,
        local: LocalIPv4Network?,
        pathChanged: Bool
    ) -> [URL] {
        guard candidates.count > 1 else { return candidates }
        var relay: [URL] = []
        var lanSame: [URL] = []
        var lanOther: [URL] = []
        for candidate in candidates {
            switch candidateRole(host: candidate.host, local: local) {
            case .relay: relay.append(candidate)
            case .lanSameSubnet: lanSame.append(candidate)
            case .lanOther: lanOther.append(candidate)
            }
        }
        let sameLANPath = !prefersRelay && !lanSame.isEmpty
        if sameLANPath { return lanSame + relay + lanOther }
        if prefersRelay || pathChanged || local != nil { return relay + lanOther + lanSame }
        return candidates
    }

 /// 首拨策略：拨号前**绝不串行等**
 /// mDNS 发现 + /health 探测。
 ///
 /// - `.fullBudget`：首候选是 relay——健康 relay 拨号本身可达 ~1.6s（受 RTT
 /// 物理下限约束），保持整档候选超时，立即拨号；发现/探测后台并发，首拨
 /// 失败才消费结果重排剩余候选。 的 relay fast path 原样泛化，
 /// 并放开「≥2 候选」限制（单 relay 候选同样不该先付 0.6s mDNS）。
 /// - `.speculative(1.2)`：首候选是**当前同网段 LAN** 地址——健康 LAN 拨号
 /// ~100–300ms，立即拨号但只给 1.2s 紧上限（陈旧地址最多烧这么多就转
 /// 后台收敛结果）。真实 5G→WiFi 切换、WiFi 侧重连都走这条路径，从
 /// 「先发现 1.5–2s 再拨」变成 ~0.3–0.5s 直连。
 /// - `.none`：首候选是跨网段陈旧 LAN（lanOther）或本轮没有发现/探测要做——
 /// 保持先发现再拨：lanOther 的拨号大概率超时（白烧 2.5s），发现先行真有
 /// 选路价值；无发现需求时本来就直拨。
    enum DialFirstPolicy: Equatable, CustomStringConvertible {
        case none
        case fullBudget
        case speculative(TimeInterval)

        var description: String {
            switch self {
            case .none: return "none(discovery-first)"
            case .fullBudget: return "fullBudget"
            case .speculative(let cap): return "speculative(\(String(format: "%.1f", cap))s)"
            }
        }
    }

 /// LAN 投机首拨的紧上限：健康 LAN 拨号 ~100–300ms（本地 RTT 1–5ms ×
 /// TLS+auth+upgrade 约 5–8 个 RTT），1.2s 是 4–12 倍余量；再慢基本说明
 /// 地址已陈旧，不值得继续烧整档候选超时。
    static let speculativeLANDialCapSeconds: TimeInterval = 1.2

 /// 蜂窝下 LAN 候选每轮最多尝试个数（超出留到下一轮）：跨网 RFC1918 必然
 /// 不可达，只保留 VPN 边缘路由的最后一线，不把整轮预算烧在必然失败上。
    static let maxCellularLANAttemptsPerRound = 2

 /// mux 冲突重试的等待对齐：插件 `MUX_TAKEOVER_STALE_MS`——真实
 /// 跨网切换（旧网已死，发不出 WS close 帧）只能等插件把静默旧连接判死后
 /// 接管。重试安排在 轮起点 + 对齐值，命不中的代价只是一次拨号超时。同网
 /// 重连已由 teardown 主动 close 消除 409，此参数只兜真实切换。
 ///
 /// link-perf L1（DEC-E + 设计变更二审）：
 /// - 观测档：插件经 /health 广播 `features.takeoverWindowMs`，对齐 = 窗口
 /// + 120ms 安全边距。800ms 窗口 → 920ms（原 200ms 边距会让对齐值恰好
 /// 等于 AC-01 硬线 1.0s，调度抖动必然判失败；120ms 覆盖轮起点锚点与
 /// 插件静默钟的偏差，且插件侧静默检查发生在拨号+TLS+RTT 之后，天然还
 /// 有 ≥1 RTT 余量）。
 /// - 兜底档：无任何已知窗口（旧插件无字段 / 缓存被观测清空 / 409 保守
 /// 升级）一律 1.7s = 历史值（1500 窗口 + 200ms），等价现状（设计
 /// §3-L1 兼容矩阵第一行，AC-02 不劣化）。
    static let muxConflictRetryAlignFallbackSeconds: TimeInterval = 1.7
    static let muxConflictRetryAlignMarginSeconds: TimeInterval = 0.12

 /// 纯函数（可单测）：无已知窗口 → 1.7s；观测到 800 → 0.92s。
    nonisolated static func muxConflictRetryAlignSeconds(takeoverWindowMs: Int?) -> TimeInterval {
        guard let takeoverWindowMs, takeoverWindowMs > 0 else {
            return muxConflictRetryAlignFallbackSeconds
        }
        return TimeInterval(takeoverWindowMs) / 1000 + muxConflictRetryAlignMarginSeconds
    }

 /// 本实例当前对齐值（设计变更二审的优先级）：409 保守升级 > 本周期
 /// /health 观测 > credentials 缓存 > 1.7s 兜底。
    var muxConflictRetryAlignSeconds: TimeInterval {
        if muxConflictAlignEscalated { return Self.muxConflictRetryAlignFallbackSeconds }
        let window = sessionTakeoverWindowObserved
            ? sessionTakeoverWindowMs
            : credentials?.takeoverWindowMs
        return Self.muxConflictRetryAlignSeconds(takeoverWindowMs: window)
    }

    nonisolated static func dialFirstPolicy(
        prefersRelay: Bool,
        orderedCandidates: [URL],
        local: LocalIPv4Network?,
        shouldDiscover: Bool
    ) -> DialFirstPolicy {
        guard shouldDiscover, let top = orderedCandidates.first else { return .none }
        switch candidateRole(host: top.host, local: local) {
        case .relay:
            return .fullBudget
        case .lanSameSubnet:
            return .speculative(speculativeLANDialCapSeconds)
        case .lanOther:
            return .none
        }
    }

 /// 一次候选拨号的超时紧上限（纯函数，可单测）。命中即返回上限值，调用方
 /// `min(attemptTimeout, cap)`：
 /// - dial-first 首轮投机拨号（`.speculative`）：发现/探测还没回来，陈旧
 /// LAN 地址最多值 1.2s；
 /// - 蜂窝（无本地 LAN 接口）下的 LAN 候选：跨网 RFC1918 必然不可达，只有
 /// VPN 之类边缘路由有戏——保留最后一线但同样只给 1.2s(真机
 /// 实测：relay 失败后 LAN 兜底按整档 2.5s 白烧 2679ms，把整轮拖进
 /// roundBudgetExhausted）。这是配对策略「蜂窝不拨 LAN」的软化版。
    nonisolated static func attemptTimeoutCap(
        attemptIndex: Int,
        policy: DialFirstPolicy,
        origin: URL,
        local: LocalIPv4Network?,
        prefersRelay: Bool
    ) -> TimeInterval? {
        if attemptIndex == 0, case .speculative(let cap) = policy { return cap }
        if prefersRelay, local == nil,
           candidateRole(host: origin.host, local: local) != .relay {
            return speculativeLANDialCapSeconds
        }
        return nil
    }

 /// 并行健康探测的目标集合（纯函数，可单测）。蜂窝（`prefersRelay && 无本地
 /// LAN 接口`）下 LAN 候选必然不可达，探测它们只会把收敛时间钉死在探测
 /// 超时上——只探测 relay 候选；
 /// relay 探测健康时收敛 ~150ms 即完成，失败后的重排等待也从 ~1.5s 降到
 /// relay 探测实际耗时。
    nonisolated static func probeTargets(
        candidates: [URL],
        local: LocalIPv4Network?,
        prefersRelay: Bool
    ) -> [URL] {
        guard prefersRelay, local == nil else { return candidates }
        let relays = candidates.filter { candidateRole(host: $0.host, local: local) == .relay }
 // 没有 relay 候选（异常配置）：退回全量探测，不让收敛变空转。
        return relays.isEmpty ? candidates : relays
    }

 /// 冷启动 <1s（已被 `dialFirstPolicy` 泛化取代，保留给单测锚定
 /// 原语义）：跨网（relay-first）时是否跳过"拨号前串行发现+探测"直接拨
 /// 第一个候选。真机实测这段串行收敛 1577–1614ms（connect-metrics candidateMs），
 /// 而 relay 拨号本身约 700ms——它是冷启动最大的可消除浪费。
    nonisolated static func shouldDialRelayImmediately(
        prefersRelay: Bool,
        orderedCandidates: [URL],
        local: LocalIPv4Network?
    ) -> Bool {
        guard prefersRelay, orderedCandidates.count > 1 else { return false }
        return candidateRole(host: orderedCandidates[0].host, local: local) == .relay
    }

 /// Fixed total budget for walking the candidates of one round. This removes the
 /// old 10s+ tail where every serial candidate burned its own timeout.
 /// - single candidate: nothing to switch to; give it the full 8s candidate
 /// budget (the old 6s cap could not even cover a slow relay round);
 /// - same-LAN multi-candidate: LAN should answer fast, relay fallback usable -> 4s;
 /// - cross-network multi-candidate (relay first + stale LAN fallback): 5s.
 ///
 /// real-device calibration: the old cross-network 1.5s round budget is
 /// shorter than one healthy relay round (`candidateMs≈1.6s`), so whenever the
 /// `/health` probes all failed the relay attempt was guaranteed to be cancelled
 /// at 1.5s — the exact mechanism that turned a 800ms stall into a 28.4s
 /// cold-start storm. 5s covers the relay attempt plus one bounded LAN fallback.
    nonisolated static func roundBudgetSeconds(
        candidateCount: Int,
        hasSameSubnetLAN: Bool,
        hasRelay: Bool
    ) -> TimeInterval {
        guard candidateCount > 1 else { return 8 }
        if hasSameSubnetLAN { return 4 }
        guard hasRelay else { return 4 }
        return 5
    }

 /// Clamped per-candidate timeout, or nil when the round budget is exhausted
 /// (the caller then reports a clear retryable failure instead of waiting).
    nonisolated static func attemptBudget(
        baseTimeout: TimeInterval,
        remainingRoundBudget: TimeInterval
    ) -> TimeInterval? {
        guard remainingRoundBudget > 0.05 else { return nil }
        return min(baseTimeout, remainingRoundBudget)
    }

 // MARK: Failure classification (fast reject + retryable distinction)

 /// Why one candidate failed. Drives fast candidate switching, the per-candidate
 /// `[RECONNECT]` metrics and the one-line user-facing error (handoff reqs 2/4/5).
    enum CandidateFailureClass: String {
        case ok = "ok"
 /// The plugin instance is gone/booting: `HTTP 503 {error:host/inactive}`.
        case pluginNotReady = "plugin-not-ready"
 /// Gateway/upgrade refusal (5xx) that is not a plugin-state error.
        case gatewayRejected = "gateway-5xx"
        case timeout = "timeout"
        case unreachable = "unreachable"
 /// Credential rejected: only re-pairing can help (not retryable).
        case credentialRejected = "credential-rejected"
        case cancelled = "cancelled"
        case other = "other"

 /// The server told us this origin cannot serve the request right now: do
 /// not wait for a timeout and do not retry the same candidate — switch to
 /// the next one immediately.
        var isFastReject: Bool {
            self == .pluginNotReady || self == .gatewayRejected
        }

 /// Worth another round after the standard backoff.
        var isRetryable: Bool { self != .credentialRejected }
    }

 /// Maps a connect-path error to a failure class. `HTTP 5xx` with a plugin-state
 /// code is a fast reject; 401/403 is a credential rejection; everything else is
 /// classified from the localized transport text.
    nonisolated static func failureClass(for error: Error) -> CandidateFailureClass {
        if let linkError = error as? LinkError {
            switch linkError {
            case .httpStatus(let status, let body):
                let text = body.lowercased()
                if (500...599).contains(status) {
                    if text.contains("host/inactive")
                        || text.contains("host/starting")
                        || text.contains("host/incompatible") {
                        return .pluginNotReady
                    }
                    return .gatewayRejected
                }
                if status == 401 || status == 403 { return .credentialRejected }
                return .other
            case .timeout:
                return .timeout
            case .cancelled:
                return .cancelled
            case .transport(let message):
                return classifyFailureMessage(message)
            default:
                return .other
            }
        }
        return classifyFailureMessage(NetworkErrorInterpreter.message(for: error))
    }

    nonisolated static func classifyFailureMessage(_ message: String) -> CandidateFailureClass {
        let lower = message.lowercased()
        if lower.contains("host/inactive") || lower.contains("host/starting") {
            return .pluginNotReady
        }
        if lower.contains("超时") || lower.contains("timeout") || lower.contains("timed out")
            || lower.contains("code: 60") {
            return .timeout
        }
        if lower.contains("已取消") || lower.contains("cancelled") {
            return .cancelled
        }
        if lower.contains("http 5") || lower.contains("网关") {
            return .gatewayRejected
        }
        return .unreachable
    }

 /// mux 接管冲突类失败（409/4409）：接管窗口未过、旧连接仍被插件持有。
 /// 文本判定与 `classifyFailureMessage` 同风格（legacy 真机实测文案
 /// "HTTP 409: mux 升级被拒绝"；P1 侧 4409 的 userMessage 含「冲突」）。
 /// link-perf L1：驱动 fast-retry 的下限分档与 409 保守升级。
    nonisolated static func isMuxConflictRejection(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("409") || lower.contains("冲突")
    }

 /// One-line user-facing reason after a failed round — the UI must never show
 /// only 「重连中」 (handoff cross-network req 4).
    nonisolated static func roundFailureSummary(
        classes: [CandidateFailureClass],
        details: [String]
    ) -> String {
        if classes.contains(.pluginNotReady) {
            return L10n.t("桌面端插件未就绪（host/inactive），请在 Mac 上重启 DSH-m 插件后重试")
        }
        if classes.contains(.gatewayRejected) {
            return L10n.t("连接被服务端网关拒绝（HTTP 5xx），请检查桌面端插件状态")
        }
        if classes.contains(.credentialRejected) {
            return L10n.t("设备凭据已失效，请重新配对")
        }
        if classes.contains(.timeout) {
            return L10n.t("连接 Mac 超时：当前网络不可达，请检查网络与桌面端")
        }
        if let last = details.last, !last.isEmpty {
            return last
        }
        return L10n.t("无法连接 Mac，请检查网络与桌面端是否在线")
    }

 /// A round already dialed on the post-change path must be allowed to finish;
 /// only a round that predates the change is restarted.
    nonisolated static func shouldRestartConnectingRound(
        roundStartGeneration: Int,
        pathGeneration: Int
    ) -> Bool {
        roundStartGeneration < pathGeneration
    }
}

// MARK: - T2(B1)：冷启动预热限时等待

/// 限时等待一个**已经启动**的预热任务结束，供 `LinkService.awaitPoolWarmup` 与单测共用。
///
/// 为什么不能直接 `await task.value`：那会一直等到任务结束、拿不到超时上限。
/// 这里让「任务完成」和「超时」两个一次性唤醒者竞速，先到者唤醒调用方，另一个
/// 什么都不做——**既不取消也不等待**预热任务：超时后预热继续在后台跑完，后续
/// 请求仍可复用它建好的连接。
enum PoolWarmupWait {
 /// 等 `task` 结束，最多 `timeoutMs` 毫秒；永不抛错。
 ///
 /// - `timeoutMs <= 0`：立即返回（不额外等待）；
 /// - 超时：按上限返回，任务本身继续在后台跑；
 /// - 任务完成（无论其内部 `/health` 成功还是失败）：立即返回。
    static func wait(for task: Task<Void, Never>, timeoutMs: Int) async {
        guard timeoutMs > 0 else { return }
 // 上限 60s：防止异常入参造成 UInt64 纳秒溢出（生产调用方只用 350ms 量级）。
        let clampedMs = min(timeoutMs, 60_000)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeOnce = ResumeOnce(continuation)
            Task {
                await task.value
                resumeOnce.resume()
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(clampedMs) * 1_000_000)
                resumeOnce.resume()
            }
        }
    }

 /// 两个竞速唤醒者只有第一个真正 resume continuation（double resume 会崩）。
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }
}

