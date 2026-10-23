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
    @Published private(set) var lastErrorText: String?
    @Published private(set) var lastConnectedAt: Date?
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
            helloTimeout: P1ProtocolLimits.helloTimeout
        )
    }
 /// True while the first reconnect after a resumable socket loss runs
 /// silently: `phase` stays `.connected` and no banner is painted, so a
 /// replay success produces no UI flash. Bounded by one candidate attempt.
    var p1SilentResume = false
 /// Timestamp of the socket loss, for the `recoverMs` replay metric.
    var p1LostAt: Date?
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
 /// One in-flight challenge/verify per purpose. **Purpose-scoped on purpose**:
 /// an api token cannot open the WSS mux and a single-use mux token cannot call
 /// unary endpoints, so sharing one in-flight task across purposes handed the
 /// wrong token to the second caller (mux upgrade 401 → reconnect loops).
    var authInFlightByPurpose: [String: Task<String, Error>] = [:]

    init() {
        credentials = store.load()
 // task-2 (reconnect < 1s): one listener per app process. A meaningful path
 // change invalidates the live socket immediately instead of waiting for the
 // system TCP timeout; the reconnect then runs on the new path.
        NetworkPathMonitor.shared.onMeaningfulChange = { [weak self] in
            self?.handleNetworkPathChanged()
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
        if credentials != nil {
            phase = .connecting
            startConnecting()
        }
    }


 /// Picks a reachable origin from the QR payload and pairs. On a physical
 /// iPhone loopback origins (127.0.0.1/localhost) are filtered out; each
 /// remaining origin is tried in order and failures are reported together.
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
        }
        guard let pairToken = payload.token, !pairToken.isEmpty else {
            throw LinkError.transport(L10n.t("配对载荷缺少配对码（pair.token）"))
        }
        if payload.isExpired {
            throw LinkError.transport(L10n.t("配对码已过期，请在 Mac 上刷新二维码"))
        }

        let candidates = PairingOriginSelector.candidates(payload: payload)
        guard !candidates.isEmpty else {
            throw LinkError.transport(
                L10n.t("配对二维码里只有 127.0.0.1/localhost 地址，手机无法访问。请让 Mac 使用局域网 IP 重新生成二维码。")
            )
        }

        var attempts: [String] = []
        for origin in candidates {
            do {
                return try await pairOn(
                    origin: origin,
                    payload: payload,
                    pairToken: pairToken,
                    deviceName: deviceName,
                    candidates: candidates
                )
            } catch {
                attempts.append((origin.host ?? origin.absoluteString) + ": " + NetworkErrorInterpreter.message(for: error))
            }
        }
        let detail = attempts.joined(separator: "\n")
        throw LinkError.transport(
            "无法连接 Mac（已尝试 \(candidates.count) 个地址）：\n\(detail)\n请确认 iPhone 与 Mac 在同一 Wi-Fi、已允许本地网络权限，并让 Mac 使用局域网 IP 生成二维码；若 Mac 开着 VPN/隧道或代理模式，请关闭或对局域网分流。"
        )
    }

 /// One pairing attempt against a concrete origin: /health -> /pair/redeem.
    private func pairOn(
        origin: URL,
        payload: PairingPayload,
        pairToken: String,
        deviceName: String,
        candidates: [URL]
    ) async throws -> PairingCredentials {
        guard let host = origin.host, !host.isEmpty else {
            throw LinkError.transport(L10n.f("配对 origin 缺少 host: %@", origin.absoluteString))
        }
        guard origin.scheme?.lowercased() == "https" else {
            throw LinkError.transport(L10n.t("配对 origin 必须是 https"))
        }

        pairStep = "校验桌面端证书"
        let requestedPin = payload.tlsLeafPinHex
        let health = try await HTTPSClient.json(
            origin: origin,
            method: "GET",
            path: "/health",
            leafPin: requestedPin,
            timeout: 15
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
            timeout: 20
        )
        guard redeem.status == 200, redeem.json["ok"]?.boolValue == true else {
            let code = redeem.json["error"]?.stringValue ?? "unknown"
            switch code {
            case "pair/invalid":
                throw LinkError.transport(L10n.t("配对码无效或已被使用，请在 Mac 上刷新二维码"))
            case "pair/expired":
                throw LinkError.transport(L10n.t("配对码已过期，请在 Mac 上刷新二维码"))
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
            relayOrigin: payload.relay?.origin,
            healthDeviceEndpoints: Self.healthDeviceEndpoints(from: health.json)
        )
 // P1: remember the plugin's single-WSS capability + in-band auth tickets
 // at pairing time, so a cold start/reconnect can skip the "anonymous
 // upgrade -> 401 -> fallback" probe (design §4.3/§6).
        let p1Capable: Bool = {
            if let flag = health.json["features"]?["muxRpc"]?.boolValue { return flag }
            if let proto = health.json["proto"]?.stringValue { return proto.contains("dsh-m/2") }
            if let protos = health.json["proto"]?.arrayValue {
                return protos.contains { $0.stringValue == "dsh-m/2" }
            }
            return false
        }()
        let seededTickets = redeem.json["connectTickets"]?.arrayValue?.compactMap { $0.stringValue }
        let credentials = PairingCredentials(
            origin: normalizedOrigin,
            leafPin: effectivePin,
            caCertBase64: payload.tlsCACertBase64 ?? health.json["tls"]?["caCert"]?.stringValue,
            deviceId: deviceId,
            credential: credential,
            deviceName: deviceName,
            pairedAt: Int64(Date().timeIntervalSince1970 * 1000),
            keyId: redeem.json["keyId"]?.stringValue,
            originCandidates: learnedCandidates,
            supportsMuxRPC: p1Capable,
            connectTickets: seededTickets,
            p1Epoch: nil,
            p1Sid: nil,
            hostId: payload.host?.id
        )
        adopt(credentials: credentials)
 // M2a: remember the relay server advertised by the Mac so public
 // lookup/reconnect works without a second server-config scan.
        RelayConfigStore.capture(from: payload)
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
 /// 3. the payload's optional top-level `relay.origin` (design §5.4);
 /// 4. `/health.deviceEndpoints` — every origin the phone may dial.
 ///
 /// Learned origins (3/4) must be https and non-loopback, and are de-duplicated
 /// against everything before them: on a physical iPhone 127.0.0.1/localhost/
 ///1 point at the phone itself. The current origin is kept even when it is
 /// loopback (the iOS simulator shares the Mac's network namespace).
    nonisolated static func mergeOriginCandidates(
        currentOrigin: URL,
        payloadCandidates: [URL],
        relayOrigin: String?,
        healthDeviceEndpoints: [String]
    ) -> [String] {
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
        var learned = healthDeviceEndpoints
        if let relayOrigin, !relayOrigin.isEmpty {
            learned.insert(relayOrigin, at: 0)
        }
        for text in learned {
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

 /// Persists freshly minted pairing credentials and (re)starts the connection
 /// loop. Shared by QR/manual pairing and the M2a pairing-code redeem flow.
    @discardableResult
    func adopt(credentials: PairingCredentials) -> PairingCredentials {
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
        attempt = 0
        manuallyDisconnected = false
        p1FellBackToLegacy = false
        p1SilentResume = false
        p1LostAt = nil
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
    func ensureAPIToken(forceRefresh: Bool = false, originOverride: URL? = nil) async throws -> String {
        if !forceRefresh, originOverride == nil, let apiToken, let expiry = apiTokenExpiresAt, expiry.timeIntervalSinceNow > 5 {
            return apiToken
        }
        return try await authenticateToken(purpose: "api", originOverride: originOverride)
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
            if let expires = verify.json["expiresAt"]?.intValue {
                apiTokenExpiresAt = Date(timeIntervalSince1970: TimeInterval(expires) / 1000)
            } else {
                apiTokenExpiresAt = Date().addingTimeInterval(600)
            }
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
        ReconnectMetrics.markPathChange()
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
        if clearCredentials {
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
        guard !isConnecting, !manuallyDisconnected, let credentials else {
            return
        }
        isConnecting = true
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
 // 冷启动 <1s（列表侧）：预热共享 HTTPS 池，让 t0+~100ms 就发出的
 // early session/list 复用已建好的 TLS，而不是再付一次 ~300ms 握手。
        warmHTTPSPoolIfColdStart(prefersRelay: prefersRelay, local: localNetwork)
 // 跨网络自愈（用户）：mDNS 拿 Mac **当前** 端点 + 对候选并行打
 // /health，两项都带预算（≤1.2–1.5s）。网络刚变时这一步把"按旧顺序串行盲试"
 // 变成一次并行收敛，第一拨就落在可达地址上。
 //
 // 冷启动 <1s（用户人工验收）：跨网（5G）时 relay 是第一且唯一可能
 // 立即可达的候选，而发现+探测真机实测约 1.58s（connect-metrics 的 candidateMs
 // 1577–1614ms 就是这一段）。它只用于「首拨失败后换地址」，绝不能挡在第一次
 // 拨号前：relay-first 路径改为**立刻拨 relay**，发现/探测在后台并发，只有首拨
 // 失败时才 await 结果重排剩余候选；其它路径（同网段 LAN-first / 单候选）保持
 // 原行为（它们的预算里含真实选路价值）。
        let relayFirstFastPath = Self.shouldDialRelayImmediately(
            prefersRelay: prefersRelay,
            orderedCandidates: orderedCandidates,
            local: localNetwork
        )
        var dialCandidates = orderedCandidates
        var convergenceConsumed = false
        var convergenceTask: Task<(origins: [String], observations: [EndpointHealing.ProbeObservation]), Never>?
        if relayFirstFastPath {
            convergenceTask = Task { [weak self] in
                guard let self else { return ([], []) }
                return await self.discoverAndProbe(
                    candidates: orderedCandidates,
                    local: localNetwork,
                    credentials: credentials
                )
            }
            linkDebug("round: relay-first fast path (dial now, convergence in background)")
        } else {
            let discovery = await discoverAndProbe(
                candidates: orderedCandidates,
                local: localNetwork,
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
        while queueIndex < queue.count {
            let origin = queue[queueIndex]
            queueIndex += 1
            let originKey = PairingOriginSelector.normalizedOriginString(origin).lowercased()
            guard attemptedOriginKeys.insert(originKey).inserted else { continue }
 // Budget semantics keep the original meaning: "index 0" is the first
 // distinct candidate actually attempted in this round.
            let attemptIndex = attemptedOriginKeys.count - 1
            let attemptCount = max(queue.count, dialCandidates.count)
            if Task.isCancelled {
                isConnecting = false
                return
            }
            let remaining = roundDeadline.timeIntervalSinceNow
            guard let attemptTimeout = Self.attemptBudget(
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
            ConnectionMetrics.markCandidate(host)
            let candidateStartedAt = ReconnectMetrics.clock()
            switch await attemptConnection(origin: origin, leafPin: credentials.leafPin, timeout: attemptTimeout) {
            case .connected(let bumpGeneration):
                linkDebug("round: connected " + Self.originLabel(origin))
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
                ReconnectMetrics.markConnected()
                ConnectionMetrics.markConnected()
                connectionMetricsValue = connectionMetricsSummary()
 // v0.1.1 C: pre-C pairings still trust only the leaf pin; while
 // the freshly authenticated link is up, learn the public CA
 // certificate so future leaf re-issues need no re-pair.
                startCATrustMigrationIfNeeded()
 // 连接成功即把 Mac 当前端点写回持久化候选（网络再变时手里是新地址）。
                endpointsDirty = false
                refreshEndpointsAfterConnect(origin: origin)
                return
            case .credentialRejected(let reason):
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
                let failureClass = Self.classifyFailureMessage(reason)
                ReconnectMetrics.markCandidateAttempt(
                    host: host,
                    milliseconds: (ReconnectMetrics.clock() - candidateStartedAt) * 1000,
                    result: failureClass.rawValue
                )
                failureClasses.append(failureClass)
                failures.append(host + ": " + reason)
                lastErrorText = reason
            }
 // Relay-first fast path: the first dial failed, so now pay for the
 // background convergence exactly once and rebuild the remaining queue in
 // its preferred order (newly discovered LAN/relay endpoints included).
            if !convergenceConsumed, let convergenceTask {
                convergenceConsumed = true
                let discovery = await convergenceTask.value
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
    private func attemptConnection(origin: URL, leafPin: String, timeout: TimeInterval) async -> ConnectAttemptOutcome {
        if Self.transportRoute(
            flagEnabled: AppSettings.remoteProtocolV2,
            supportsMuxRPC: credentials?.supportsMuxRPC,
            fellBackToLegacy: p1FellBackToLegacy
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
    nonisolated static func transportRoute(
        flagEnabled: Bool,
        supportsMuxRPC: Bool?,
        fellBackToLegacy: Bool
    ) -> TransportRoute {
        guard flagEnabled, supportsMuxRPC == true, !fellBackToLegacy else { return .legacy }
        return .p1
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
    func noteP1EventsStreamLoss(_ message: String) {
        lastErrorText = message
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
        }
        if let continuation = readyContinuation {
            readyContinuation = nil
            continuation.resume(throwing: LinkError.cancelled)
        }
        mux?.onClose = nil
        mux = nil
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
 /// 连接。这里在启动连接轮次的同时用一次轻量 `/health` 打通 TCP+TLS 并留在池里，
 /// 认证/列表都直接复用 → 列表侧预期 −200~300ms。
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
        linkDebug("pool warm-up -> " + Self.originLabel(origin))
        poolWarmupTask = Task { [weak self] in
            defer { self?.poolWarmupTask = nil }
 // A plain GET /health over the shared pool: TLS handshake + one round trip,
 // connection stays pooled for the auth/list requests that follow.
            _ = try? await HTTPSClient.json(
                origin: origin,
                method: "GET",
                path: "/health",
                leafPin: leafPin,
                caCertBase64: caCertBase64,
                timeout: 3
            )
        }
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

 /// 一轮连接前的并行发现：mDNS 拿 Mac **当前** 端点 + 对所有候选并行打 `/health`。
 ///
 /// 两项都带硬预算（≤1.5s）且并发执行：即便发现全部失败，也只让这一轮多等一次
 /// 预算，随后回落到原有的串行拨号。
    private func discoverAndProbe(
        candidates: [URL],
        local: LocalIPv4Network?,
        credentials: PairingCredentials
    ) async -> (origins: [String], observations: [EndpointHealing.ProbeObservation]) {
 // 单候选且端点不脏：没有可切换目标、地址也不可能过时，直接拨（省掉预算）。
        let shouldDiscover = endpointsDirty || candidates.count > 1
        let shouldProbe = EndpointHealing.shouldProbe(candidateCount: candidates.count)
        guard shouldDiscover || shouldProbe else { return ([], []) }
        let hasLANCandidate = candidates.contains {
            Self.candidateRole(host: $0.host, local: local) != .relay
        }
        let discoveryBudget = EndpointHealing.discoveryBudget(hasLANCandidate: hasLANCandidate)
        let probeTimeout = EndpointHealing.probeTimeout(candidateCount: candidates.count)
        async let discovered: LANEndpointDiscovery.Result = shouldDiscover
            ? LANEndpointDiscovery.discover(
                hostId: credentials.hostId,
                leafPin: credentials.leafPin,
                caCertBase64: credentials.caCertBase64,
                budget: discoveryBudget
            )
            : LANEndpointDiscovery.Result()
        async let probed: [EndpointHealing.ProbeObservation] = shouldProbe
            ? probeCandidateHealth(candidates, timeout: probeTimeout)
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

 /// 冷启动 <1s：跨网（relay-first）时是否跳过"拨号前串行发现+探测"直接拨
 /// 第一个候选。真机实测这段串行收敛 1577–1614ms（connect-metrics candidateMs），
 /// 而 relay 拨号本身约 700ms——它是冷启动最大的可消除浪费。
 ///
 /// 条件刻意保守：只有 (a) 当前路径判断要求 relay 优先，(b) 至少两个候选（发现才有
 /// 意义），且 (c) 首候选确实是 relay 时才走快路径。同网段 LAN-first 与单候选保持
 /// 原行为（后者的发现预算本来就是 0）。
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

