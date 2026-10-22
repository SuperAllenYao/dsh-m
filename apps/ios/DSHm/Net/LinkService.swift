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
    var readyContinuation: CheckedContinuation<Void, Error>?
    var readyTimeoutTask: Task<Void, Never>?
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
 /// Observer for `HTTPConnection`'s reused-socket first-byte watchdog.
    private var firstByteTimeoutObserver: NSObjectProtocol?

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
            p1Sid: nil
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
        phase = .connecting
        startConnecting()
        return credentials
    }

 // MARK: - Auth tokens (ECDSA-P256 challenge/verify)

 /// Returns a valid api bearer token, refreshing it when close to expiry.
    func ensureAPIToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let apiToken, let expiry = apiTokenExpiresAt, expiry.timeIntervalSinceNow > 5 {
            return apiToken
        }
        return try await authenticateToken(purpose: "api")
    }

 /// One challenge/verify round trip. Concurrent callers share one in-flight
 /// challenge (the plugin rate-limits challenges).
    func authenticateToken(purpose: String, timeout: TimeInterval = 15) async throws -> String {
        if let inFlight = authInFlightByPurpose[purpose] {
            do {
                return try await inFlight.value
            } catch {
 // Fall through and try once with a fresh challenge.
            }
        }
        let task = Task { [weak self] () throws -> String in
            guard let self else { throw LinkError.notConnected }
            return try await self.performAuthentication(purpose: purpose, timeout: timeout)
        }
        authInFlightByPurpose[purpose] = task
        defer { authInFlightByPurpose[purpose] = nil }
        return try await task.value
    }

    private func performAuthentication(purpose: String, timeout: TimeInterval) async throws -> String {
        guard let credentials, let origin = credentials.originURL else { throw LinkError.notPaired }
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

 /// The reused mux delivered its first `workspace/follow` baseline inside the
 /// probe budget: the provisional "reuse" chain is confirmed and may complete.
    func noteReuseLivenessConfirmed() {
        ReconnectMetrics.markReuseConfirmed()
    }

 /// A pooled unary request hit `HTTPConnection.firstByteTimeout`. Only a request
 /// against the *current* origin says anything about the live mux transport.
    private func handleFirstByteTimeout(endpoint: String, host: String?) {
        guard let currentHost = credentials?.originURL?.host, let host, currentHost == host else {
            return
        }
        noteTransportUnresponsive(source: "unary:" + endpoint)
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
 // Spec §3.8: base 500ms, factor 2, cap 10s, 50% jitter.
        let delayMs = Self.reconnectDelayMs(attempt: attemptNumber, randomUnit: Double.random(in: 0...1))
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
        let hasSameSubnetLAN = orderedCandidates.contains {
            Self.candidateRole(host: $0.host, local: localNetwork) == .lanSameSubnet
        }
        let hasRelay = orderedCandidates.contains {
            Self.candidateRole(host: $0.host, local: localNetwork) == .relay
        }
 // Fixed total budget for the candidate walk: the round can never turn into
 // a 10s tail. Cross-network relay+LAN: 1.5s; same-LAN: 3s; a single
 // candidate keeps the generous dial budget (nothing to switch to).
        let roundBudget = Self.roundBudgetSeconds(
            candidateCount: orderedCandidates.count,
            hasSameSubnetLAN: hasSameSubnetLAN,
            hasRelay: hasRelay
        )
        let roundDeadline = Date().addingTimeInterval(roundBudget)
        var failures: [String] = []
        var failureClasses: [CandidateFailureClass] = []
        var roundBudgetExhausted = false
        for (index, origin) in orderedCandidates.enumerated() {
            if Task.isCancelled {
                isConnecting = false
                return
            }
            let remaining = roundDeadline.timeIntervalSinceNow
            guard let attemptTimeout = Self.attemptBudget(
                baseTimeout: Self.candidateTimeoutSeconds(
                    index: index,
                    count: orderedCandidates.count,
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
            if index > 0 {
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
                return
            case .credentialRejected(let reason):
                ReconnectMetrics.markCandidateAttempt(
                    host: host,
                    milliseconds: (ReconnectMetrics.clock() - candidateStartedAt) * 1000,
                    result: CandidateFailureClass.credentialRejected.rawValue
                )
                isConnecting = false
                lastErrorText = reason
                phase = .needsRepair(reason)
                return
            case .fastRejected(let reason, let failureClass):
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
        }
        isConnecting = false
        guard !Task.isCancelled else { return }
        if roundBudgetExhausted {
            ReconnectMetrics.markRoundBudgetExhausted()
            failureClasses.append(.timeout)
            failures.append(L10n.f("候选总预算已耗尽（%lld ms）", Int(roundBudget * 1000)))
        }
 // One-line, actionable reason (cross-network req 4): the list banner shows
 // `statusDetail`, so it must never be empty or a generic 「重连中」.
        lastErrorText = Self.roundFailureSummary(classes: failureClasses, details: failures)
 // Remember a different starting origin for the next round so a dead
 // address does not always head the list.
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

 // Every physical mux connection needs a fresh single-use mux token.
        let muxToken: String
        do {
            muxToken = try await authenticateToken(purpose: "mux", timeout: timeout)
        } catch {
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
        if Task.isCancelled { return .failed(L10n.t("已取消")) }

 // M2b: mint the unary api token in parallel with the WSS mux handshake.
 // The first screen after `connected` is session/list, which needs the
 // token; overlapping its 2-RTT challenge/verify with the WS upgrade +
 // $events ready removes it from the startup critical path (before M2b
 // the token was only requested when the first unary call ran).
        let apiTokenPrefetch = Task { [weak self] () -> String? in
            guard let self else { return nil }
            return try? await self.ensureAPIToken()
        }

        let ws = WSSClient(
            host: host,
            port: port,
            path: "/api/remote.mux",
            headers: ["authorization": "Bearer \(muxToken)"],
            leafPin: leafPin,
            caCertBase64: credentials?.caCertBase64
        )
        self.ws = ws
        do {
            try await ws.connect(timeout: timeout)
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
        do {
            try await openEventsAndWaitReady(mux: mux)
        } catch {
            apiTokenPrefetch.cancel()
            let reason = NetworkErrorInterpreter.message(for: error)
            mux.close()
            self.mux = nil
            self.ws = nil
            if isCredentialRejection(error) { return .credentialRejected(reason) }
            let failureClass = Self.failureClass(for: error)
            if failureClass.isFastReject { return .fastRejected(reason, failureClass) }
            return .failed(reason)
        }
        ConnectionMetrics.markReady()
 // Best-effort: a failed prefetch surfaces on the first real unary call
 // (which re-authenticates) instead of failing the connection attempt.
 //
 // v0.1.1 (Bug 1): do **not** await the prefetch here. A slow/flaky
 // challenge+verify pair can burn up to 2 × 15s HTTP timeouts while the
 // link itself is already ready, and awaiting it kept `phase` busy so the
 // UI stayed on 「正在连接 Mac…」. `authenticateToken` shares one in-flight
 // task per purpose, so the first unary call joins the same challenge
 // instead of minting a second token (401 refresh-once path unchanged).
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

 /// Per-candidate budget inside one round. The last candidate keeps a longer
 /// budget so a slow-but-working relay still connects; the others are bounded at
 /// 2s (1.5s after a path change) because a reachable origin completes
 /// TCP+TLS+auth well under 1s, and a stale LAN address must not burn 4s before
 /// the relay is dialed.
    nonisolated static func candidateTimeoutSeconds(
        index: Int,
        count: Int,
        pathChanged: Bool
    ) -> TimeInterval {
        if index >= count - 1 { return 8 }
        return pathChanged ? 1.5 : 2
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

 /// Fixed total budget for walking the candidates of one round. This removes the
 /// old 10s+ tail where every serial candidate burned its own timeout.
 /// - single candidate: nothing to switch to, but still capped at 6s (8s dial +
 /// backoff used to be the worst-case tail);
 /// - same-LAN multi-candidate: LAN should answer fast, relay fallback usable -> 3s;
 /// - cross-network multi-candidate (relay first + LAN fallback): 1.5s total.
    nonisolated static func roundBudgetSeconds(
        candidateCount: Int,
        hasSameSubnetLAN: Bool,
        hasRelay: Bool
    ) -> TimeInterval {
        guard candidateCount > 1 else { return 6 }
        if hasSameSubnetLAN { return 3 }
        guard hasRelay else { return 3 }
        return 1.5
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

