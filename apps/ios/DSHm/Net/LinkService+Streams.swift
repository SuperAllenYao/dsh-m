import Foundation

/// One-line diagnostics for the exact-fetch file-change routes (§3.9).
///
/// Enable on a DEBUG build with `DSHM_CHANGESDBG=1` (for example
/// `xcrun devicectl device process launch --console --environment DSHM_CHANGESDBG=1 …`).
/// Silent in production. Every failure line carries what is needed to explain a
/// meta.diffs fallback in the field: seq, route, resolved origin, relay
/// preference, error type/text, HTTP status and elapsed ms.
enum ChangesDebugLog {
    static let isEnabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DSHM_CHANGESDBG"] == "1"
        #else
        return false
        #endif
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        NSLog("[CHANGESDBG] %@", message())
    }
}

/// Host-forwarded `$events` hints that make the list's joined metadata stale.
///
/// 现场探针（task-1, isolated stack，真 Host + 真插件）：
/// - 桌面端新建会话 → `workspace/follow` 立即推 `upsert`（成员关系，含新
/// sessionId），`$events` 同时推 `api-session/added`（完整 summary）；
/// - 会话首条消息 → `$events` 推 `api-session/activity`；`session/list` 的
/// `blank` 翻成 false 并给出 title；
/// - 删除 → `api-session/removed`；改名 → **两路都没有**任何帧（只有
/// `session/list` 的 title 变了，见 WorkspaceViewModel 的低频兜底快照）。
///
/// 列表 = follow 成员关系 ⨝ `session/list` 元数据：只应用 follow 不会让新卡片
/// 出现（join 缺行）。这里把「元数据已失效」转成一条通知，由列表视图模型去抖后
/// 补一次快照；`api-session/status` 仍走已有的实时运行态 overlay，不触发整表刷新。
enum HostSessionListInvalidation {
    static let notification = Notification.Name("dshmHostSessionListInvalidated")

 /// 已确认会被 Host 转发、且改变列表元数据的 emit。
    static let events: Set<String> = [
        "api-session/added",
        "api-session/activity",
        "api-session/removed",
    ]

    static func matches(_ eventName: String) -> Bool { events.contains(eventName) }
}

/// Bound for the alternate-channel exact-fetch attempt: a LAN probe on a
/// cellular path must not double the primary 20 s timeout.
private let exactFetchAlternateTimeout: TimeInterval = 8

/// LinkService: $events subscription, approval answers, unary calls and
/// logical stream opening.
extension LinkService {
 /// Human-readable last transport error (empty when none).
    var statusDetail: String { lastErrorText ?? "" }


 // MARK: - $events ready handshake

 /// Opens `$events` and waits for its `ready` frame.
 ///
 /// v0.1.1 (Bug 1): first-launch audits showed attempts where mux/api auth
 /// succeeded but no `ready` frame ever reached the client, so the UI sat on
 /// 「正在连接 Mac…」 until the 15s timeout failed the whole candidate — and the
 /// reconnect cycle repeated (which also flickered the pending cards, Bug 2).
 /// Before failing the candidate, reopen `$events` once on the same mux: a
 /// lost open/ready frame is a stream-level fault, so a fresh stream can
 /// recover without paying for a new TLS + mux-token round.
 ///
 /// the wait is now bounded by the caller's per-candidate attempt
 /// budget (`timeout`). The old hard-coded 15s + 5s sat **outside** the round
 /// budget, so a single-candidate round could take ≈26s while the UI showed
 /// 「正在连接 Mac…」 (handoff §5.4-2). Cap: first wait ≤6s, reopen ≤2s.
    func openEventsAndWaitReady(mux: RemoteMux, timeout: TimeInterval) async throws {
        let firstWait = max(1.0, min(timeout, 6))
        let reopenWait = max(0.8, min(timeout, 2))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.readyContinuation = continuation
            self.readyHandshakeGeneration &+= 1
            self.readyReopenUsed = false
            self.openEventsStream(
                mux: mux,
                generation: self.readyHandshakeGeneration,
                timeout: firstWait,
                reopenTimeout: reopenWait
            )
        }
    }

 /// One `$events` open plus its `ready` wait (bounded first try, then the
 /// one-shot reopen, so a dead candidate still fails within a bounded window).
    private func openEventsStream(
        mux: RemoteMux,
        generation: Int,
        timeout: TimeInterval,
        reopenTimeout: TimeInterval
    ) {
        do {
            self.eventsStream = try mux.openStream(
                endpoint: "$events",
                args: [:],
                onItem: { [weak self] value in
                    self?.handleRemoteEventItem(value, readyGeneration: generation)
                },
                onEnd: { [weak self] in
                    self?.failReady(
                        LinkError.transport(L10n.t("$events 流被服务端结束")),
                        generation: generation
                    )
                },
                onError: { [weak self] error in
                    self?.failReady(LinkError.remote(error), generation: generation)
                },
                onClose: { [weak self] _, _ in
                    self?.failReady(
                        LinkError.transport(L10n.t("$events 流随连接关闭")),
                        generation: generation
                    )
                }
            )
        } catch {
            guard let continuation = self.readyContinuation else { return }
            self.readyContinuation = nil
            continuation.resume(throwing: error)
            return
        }
        self.readyTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.handleReadyTimeout(mux: mux, generation: generation, reopenTimeout: reopenTimeout)
        }
    }

 /// First timeout reopens `$events` on the same mux; the second fails the
 /// candidate and the regular legacy reconnect path takes over.
    private func handleReadyTimeout(mux: RemoteMux, generation: Int, reopenTimeout: TimeInterval) {
        guard generation == readyHandshakeGeneration, readyContinuation != nil else { return }
        guard !readyReopenUsed else {
            failReady(LinkError.timeout("$events ready"))
            return
        }
        readyReopenUsed = true
 // Retire the abandoned stream: its late ready/close callbacks must not
 // resume or fail the handshake armed by the reopened stream.
        readyHandshakeGeneration &+= 1
        eventsStream?.cancel()
        eventsStream = nil
        openEventsStream(
            mux: mux,
            generation: readyHandshakeGeneration,
            timeout: reopenTimeout,
            reopenTimeout: reopenTimeout
        )
    }

 /// Fails the current ready wait. Transport-loss paths call this
 /// generation-agnostically; `$events` stream callbacks go through the
 /// generation-checked overload below.
    func failReady(_ error: Error) {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
 // Retire every callback still holding this handshake's generation so a
 // late frame cannot touch the next connection attempt.
        readyHandshakeGeneration &+= 1
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        eventsStream?.cancel()
        eventsStream = nil
        continuation.resume(throwing: error)
    }

 /// Stream-callback variant: only the handshake that armed the callback may
 /// fail it (a cancelled stale stream stays silent).
    private func failReady(_ error: Error, generation: Int) {
        guard generation == readyHandshakeGeneration else { return }
        failReady(error)
    }

 /// P1 variant of the `$events` handshake: on dsh-m/2 the `welcome` frame is
 /// already the ready signal, so this only subscribes to `$events` (forwarded
 /// approvals/questions) and seeds `clientId`. No 15s wait, no continuation.
    func openEventsAndWaitReadyP1(channel: P1Channel) throws {
        guard let welcome = channel.welcome else { throw LinkError.notConnected }
 // 新连接的 `$events` 还没 ready：在收到本连接的 ready 帧之前，不能用
 // `welcome.deviceId` 这个种子值去回答 waterfall（会被判成另一个 Peer）。
        eventsClientIdConfirmed = false
        clientId = welcome.deviceId
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        eventsStream = try channel.openStream(
            endpoint: "$events",
            args: [:],
            onItem: { [weak self] value in
                self?.handleRemoteEventItem(value)
            },
            onEnd: { [weak self] in
 // The connection itself stays up (welcome already made it ready);
 // only the approval/question waterfall is affected.
                self?.noteP1EventsStreamLoss(L10n.t("$events 流被服务端结束"))
            },
            onError: { [weak self] error in
                self?.noteP1EventsStreamLoss(error.message)
            }
        )
    }

 // MARK: - Forwarded events (approval waterfall)

 /// - Parameter readyGeneration: legacy `$events` handshake generation that
 /// owns this item (nil on the dsh-m/2 path, where `welcome` is the ready
 /// signal). A stale stream from an abandoned handshake must not resume a
 /// newer continuation.
    func handleRemoteEventItem(_ value: JSONValue?, readyGeneration: Int? = nil) {
        guard let value else { return }
        let event = ForwardedRemoteEvent.decode(value)
        if case .ready(let ready) = event {
            if let readyGeneration, readyGeneration != readyHandshakeGeneration { return }
            clientId = ready.clientId
 /// 本连接的事件流就绪：从现在起 `$events/result` 才会被 Host 接受。
            eventsClientIdConfirmed = true
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            if let continuation = readyContinuation {
                readyContinuation = nil
                continuation.resume()
            }
            return
        }
 // Cancel frames (turn aborted / session cancelled) must drop the pending
 // waterfalls so the card disappears without an error (T10).
        var approvals = pendingApprovals
        var questions = pendingUserQuestions
        ForwardedWaterfallQueue.apply(event, approvals: &approvals, questions: &questions)
        if approvals != pendingApprovals { pendingApprovals = approvals }
        if questions != pendingUserQuestions { pendingUserQuestions = questions }
 // v6：实时运行态 emit → 列表卡片状态即时刷新。
        if case .emit(let name, let args) = event,
           let live = LiveSessionStatusEmit.parse(name: name, args: args) {
            applyLiveSessionStatus(live)
        }
 // task-1：桌面端新建/首条消息/删除会改 `session/list` 的
 // 元数据（title/blank/updatedAt），但既不会重放快照、也不会让 follow 的
 // join 凭空多出一行。转发失效信号，列表视图模型去抖后补一次静默快照。
        if case .emit(let name, _) = event, HostSessionListInvalidation.matches(name) {
            NotificationCenter.default.post(
                name: HostSessionListInvalidation.notification,
                object: self,
                userInfo: ["event": name]
            )
        }
    }

 /// Answers a pending approval waterfall via the unary `$events/result` method.
 /// Only `allowed-once` permits the tool; `rejected` fails closed.
    func respondApproval(_ approval: ApprovalWaterfall, outcome: ApprovalOutcome) async throws {
 // 必须等本连接的 $events ready：旧 clientId 会被 Host 判成另一个 Peer。
        let confirmedClientId = try await confirmedEventsClientId()
        _ = try await unary(
            "$events/result",
            args: EventsResultArgs.outcome(clientId: confirmedClientId, eventId: approval.eventId, value: outcome)
        )
        pendingApprovals.removeAll { $0.eventId == approval.eventId }
    }

 // MARK: - User questions (§3.7.2)

 /// Answers a `continued` user-question call through the unary
 /// `userQuestions/answer` method. Returns the Host's boolean: `true` means
 /// the call was still pending and the batch was accepted; `false` means the
 /// call no longer exists (answered elsewhere or expired).
    func answerUserQuestions(
        sessionId: String,
        callId: String,
        answers: [UserQuestionAnswer]
    ) async throws -> Bool {
        let value = try await unary("userQuestions/answer", args: [
            "agentId": .string(sessionId),
            "callId": .string(callId),
            "answer": UserQuestionAnswersBatch(answers: answers).jsonValue(),
        ])
        if let accepted = value.boolValue { return accepted }
        if let accepted = value["accepted"]?.boolValue { return accepted }
        return false
    }

 /// Answers an `open` user-question call through the live forwarded-events
 /// waterfall (`$events/result`). Requires the `$events` ready `clientId`.
    func answerUserQuestionsLive(eventId: String, answers: [UserQuestionAnswer]) async throws {
 // The Host may have cancelled/settled this waterfall while the user was
 // composing an answer (turn aborted, answered elsewhere); never send a
 // stale $events/result.
        guard pendingUserQuestions.contains(where: { $0.eventId == eventId }) else {
            throw UserQuestionSubmitError.noLiveRequest
        }
 // 必须等本连接的 $events ready：重连窗口内用旧 clientId 会得到
 // gateway/interactions-forbidden（Remote event result belongs to another Peer）。
        let confirmedClientId = try await confirmedEventsClientId()
        _ = try await unary(
            "$events/result",
            args: EventsResultArgs.userQuestionOutcome(
                clientId: confirmedClientId,
                eventId: eventId,
                answers: answers
            )
        )
        pendingUserQuestions.removeAll { $0.eventId == eventId }
    }

 /// Live user-question waterfalls for one session (missing agentId matches all).
    func pendingUserQuestionWaterfalls(forSession sessionId: String) -> [UserQuestionWaterfall] {
        pendingUserQuestions.filter { $0.agentId == nil || $0.agentId == sessionId }
    }

 // MARK: - Unary + streams

 /// Remote unary call. On dsh-m/2 the call rides the ready single WSS as an
 /// `rpc` frame (no bearer token, no gzip/HTTP pool; the `client-request`
 /// envelope is byte-identical). Otherwise this is the legacy pinned-HTTPS
 /// path with a short-lived api bearer token; on `auth/token-expired`/
 /// `auth/invalid` the token is refreshed once and the call retried (the
 /// protocol has no automatic retry contract, but token refresh is
 /// transport-level auth, not a business mutation).
 /// `originOverride`: the early list refresh may target
 /// the relay origin while the persisted `credentials.origin` is a stale LAN
 /// address (cellular / cross-network). See `earlyListOriginOverride()`.
    func unary(
        _ endpoint: String,
        args: [String: JSONValue] = [:],
        timeout: TimeInterval = 20,
        originOverride: URL? = nil
    ) async throws -> JSONValue {
        if let p1 = p1Channel, p1.isReady {
 // 协议 v1：协商 projV1 后插件把 `session/page` 成功响应改为
 // `0x02` 分帧（契约 §5/§6）。普通 unary 调用方（首页/页间预取、lazy-fetch
 // 窄页、其它 session/page 消费方）语义不变：这里消费整页帧并按旧 JSON
 // 信封重建（records 升序 + hasMore）。逐帧流式消费见
 // `projectedSessionPageStream`。
            if endpoint == "session/page", p1.projV1Negotiated {
                do {
                    return try await Self.projectedPageValue(p1: p1, args: args, timeout: timeout)
                } catch let failure as P1Failure {
                    throw P1UnaryMapping.linkError(from: failure)
                } catch let protocolError as P1ProtocolError {
                    throw LinkError.transport(protocolError.localizedDescription)
                }
            }
            do {
                let result = try await p1.unary(endpoint: endpoint, args: args, timeout: timeout)
                return try P1UnaryMapping.jsonValue(from: result)
            } catch let failure as P1Failure {
                throw P1UnaryMapping.linkError(from: failure)
            } catch let protocolError as P1ProtocolError {
                throw LinkError.transport(protocolError.localizedDescription)
            }
        }
        guard let credentials else { throw LinkError.notPaired }
        guard let origin = originOverride ?? credentials.originURL else { throw LinkError.transport(L10n.t("配对 origin 非法")) }
        var token = try await ensureAPIToken(originOverride: originOverride)
        do {
            return try await HTTPSClient.unaryJSON(
                origin: origin,
                endpoint: endpoint,
                args: args,
                token: token,
                leafPin: credentials.leafPin,
                caCertBase64: credentials.caCertBase64,
                timeout: timeout
            )
        } catch let error as LinkError {
            if case .httpStatus(let status, let body) = error,
               status == 401,
               body.contains("auth/token-expired") || body.contains("auth/invalid") {
                token = try await ensureAPIToken(forceRefresh: true, originOverride: originOverride)
                return try await HTTPSClient.unaryJSON(
                    origin: origin,
                    endpoint: endpoint,
                    args: args,
                    token: token,
                    leafPin: credentials.leafPin,
                    caCertBase64: credentials.caCertBase64,
                    timeout: timeout
                )
            }
            throw error
        }
    }

 /// Opens one logical stream over whichever transport is active. Consumers keep
 /// the same `RemoteStreamHandle` surface (send/end/cancel).
 ///
 /// `onClose` parity: on both transports it fires only when the stream is
 /// dropped without a protocol `end`/`error` — legacy mux close, or a P1
 /// epoch reset/fresh welcome / hard teardown. A plain dsh-m/2 socket loss
 /// deliberately leaves the stream registered so `hello{resume}` replay can
 /// continue it (design §5); the business layer must NOT see a close there.
    func openStream(
        endpoint: String,
        args: [String: JSONValue],
        onItem: @escaping (JSONValue?) -> Void,
        onEnd: @escaping () -> Void,
        onError: @escaping (RemoteError) -> Void,
        onClose: @escaping (Int, String) -> Void
    ) throws -> RemoteStreamHandle {
        if let p1 = p1Channel, p1.isReady {
            return try p1.openStream(
                endpoint: endpoint,
                args: args,
                onItem: onItem,
                onEnd: onEnd,
                onError: onError,
                onClose: onClose
            )
        }
        guard phase.isConnected, let mux else { throw LinkError.notConnected }
        return try mux.openStream(endpoint: endpoint, args: args, onItem: onItem, onEnd: onEnd, onError: onError, onClose: onClose)
    }

 // MARK: - APNs device token registration (plugin PAIRING §5.3)

    struct PushTokenRegistration: Equatable {
        var deviceId: String?
        var mode: String?
        var environment: String?
        var topic: String?
        var tokenFingerprint: String?
        var renamed: Bool?
    }

 /// `POST /devices/push-token` with `{"deviceToken":"<64-256 hex>",
 /// "environment":"sandbox"|"production", "name":"<device>"}`.
 /// Caller passes the raw APNs token hex; only the short fingerprint comes
 /// back in the response (the full token is never logged by the app).
    @discardableResult
    func registerPushToken(
        _ rawToken: String,
        environment: String = "sandbox",
        name: String? = nil
    ) async throws -> PushTokenRegistration {
        guard APNsTokenValidator.isValidHex(rawToken) else {
            throw LinkError.transport(L10n.t("APNs deviceToken 必须是 64–256 位十六进制"))
        }
        let hexToken = rawToken.replacingOccurrences(of: " ", with: "").lowercased()
        guard let credentials, let origin = credentials.originURL else { throw LinkError.notPaired }
        var fields: [String: JSONValue] = [
            "deviceToken": .string(hexToken),
            "environment": .string(environment),
        ]
        if let name, !name.isEmpty {
            fields["name"] = .string(String(name.prefix(64)))
        }
        let body = JSONValue.object(fields)

        func attempt(_ apiToken: String) async throws -> (Int, JSONValue?) {
            let result = try await HTTPSClient.json(
                origin: origin,
                method: "POST",
                path: "/devices/push-token",
                headers: ["authorization": "Bearer \(apiToken)"],
                body: body,
                leafPin: credentials.leafPin,
                caCertBase64: credentials.caCertBase64,
                timeout: 15
            )
            return (result.status, result.json)
        }

        var apiToken = try await ensureAPIToken()
        var (status, json) = try await attempt(apiToken)
        let firstErrorCode = json?["error"]?.stringValue ?? ""
 // auth/revoked must not be retried (the device is blacklisted: re-pair).
        if status == 401, firstErrorCode == "auth/revoked" {
            throw LinkError.remote(RemoteError(code: firstErrorCode, message: L10n.t("设备已被撤销，请重新配对")))
        }
        if status == 401 {
            apiToken = try await ensureAPIToken(forceRefresh: true)
            (status, json) = try await attempt(apiToken)
        }
        let errorCode = json?["error"]?.stringValue ?? "push-token-registration-failed"
        if status == 200, json?["ok"]?.boolValue == true {
            return PushTokenRegistration(
                deviceId: json?["deviceId"]?.stringValue,
                mode: json?["mode"]?.stringValue,
                environment: json?["environment"]?.stringValue,
                topic: json?["topic"]?.stringValue,
                tokenFingerprint: json?["tokenFingerprint"]?.stringValue,
                renamed: json?["renamed"]?.boolValue
            )
        }
        if status == 401, errorCode == "auth/revoked" {
            throw LinkError.remote(RemoteError(code: errorCode, message: L10n.t("设备已被撤销，请重新配对")))
        }
        if status == 400 {
            let message: String
            switch errorCode {
            case "push-token-invalid": message = L10n.t("APNs token 格式非法")
            case "push-environment-invalid": message = L10n.t("APNs environment 非法")
            default: message = errorCode
            }
            throw LinkError.remote(RemoteError(code: errorCode, message: message))
        }
        throw LinkError.httpStatus(status, errorCode)
    }

 // MARK: - Session permission switch (M5)

 /// `POST /session/permission` with `{"sessionId":"<id>","preset":"<value>"}`
 /// against the plugin's own TLS origin (not the remote relay), authorized with
 /// the short-lived api bearer token.
 ///
 /// 401 refreshes the token once and retries (token expiry is transport auth,
 /// not a business mutation); `auth/revoked` is never retried — the device is
 /// blacklisted and must re-pair. Every non-200 is surfaced as
 /// `LinkError.remote(RemoteError(code:message:))` so the sheet can render the
 /// plugin's business code with localized text.
    func setSessionPermission(
        sessionId: String,
        preset: String,
        timeout: TimeInterval = 15
    ) async throws -> SessionPermissionUpdate {
        guard let credentials, let origin = credentials.originURL else { throw LinkError.notPaired }
        let body = JSONValue.object([
            "sessionId": .string(sessionId),
            "preset": .string(preset),
        ])

        func attempt(_ apiToken: String) async throws -> (Int, JSONValue) {
            let result = try await HTTPSClient.json(
                origin: origin,
                method: "POST",
                path: "/session/permission",
                headers: ["authorization": "Bearer \(apiToken)"],
                body: body,
                leafPin: credentials.leafPin,
                caCertBase64: credentials.caCertBase64,
                timeout: timeout
            )
            return (result.status, result.json)
        }

        func revokedError() -> LinkError {
            LinkError.remote(RemoteError(
                code: "auth/revoked",
                message: PermissionSwitchErrorText.message(forCode: "auth/revoked")
            ))
        }

        var apiToken = try await ensureAPIToken()
        var (status, json) = try await attempt(apiToken)
 // auth/revoked must not be retried (the device is blacklisted: re-pair).
        if status == 401, json["error"]?.stringValue == "auth/revoked" { throw revokedError() }
        if status == 401 {
            apiToken = try await ensureAPIToken(forceRefresh: true)
            (status, json) = try await attempt(apiToken)
            if status == 401, json["error"]?.stringValue == "auth/revoked" { throw revokedError() }
        }
        if status == 200 {
            let update: SessionPermissionUpdate
            do {
                update = try json.decode(SessionPermissionUpdate.self)
            } catch {
                throw LinkError.malformedEnvelope(
                    L10n.f("session/permission 响应解析失败: %@", error.localizedDescription)
                )
            }
            guard update.ok else {
                throw LinkError.remote(RemoteError(
                    code: "permission/failed",
                    message: PermissionSwitchErrorText.message(forCode: "permission/failed")
                ))
            }
            return update
        }
        let code = json["error"]?.stringValue ?? ""
        let effectiveCode = code.isEmpty ? "permission/failed" : code
        throw LinkError.remote(RemoteError(
            code: effectiveCode,
            message: PermissionSwitchErrorText.message(
                forCode: effectiveCode,
                serverMessage: json["message"]?.stringValue
            )
        ))
    }

 // MARK: - Exact-fetch routes (§3.9: changes.summary / changes.diff)

 /// Ordered origins to try for one exact-fetch GET (at most two), preferred first.
 ///
 /// Mirrors the cold-start list override (`earlyListOriginOverride()`, v0.2.5):
 /// on cellular/cross-network the persisted `credentials.originURL` is the Mac's
 /// LAN address, which a phone off that network can never reach — the exact summary
 /// fetch then timed out and permanently fell back to the meta.diffs aggregate (the
 /// cross-end file-count mismatch, handoff §2). A LAN alternate is dropped on those
 /// paths because dialing it could only burn the timeout a second time.
 /// `nonisolated static` so the ordering is unit-tested.
    nonisolated static func exactFetchOriginCandidates(
        persisted: URL?,
        stored: [String]?,
        relayOverride: URL?,
        prefersRelay: Bool
    ) -> [URL] {
        guard let current = relayOverride ?? persisted else { return [] }
        var ordered: [URL] = [current]
        let candidates = PairingOriginSelector.reconnectCandidates(
            current: persisted?.absoluteString,
            stored: stored
        )
        for candidate in candidates where candidate != current {
            if prefersRelay, PairingOriginSelector.isLANHost(candidate.host) { continue }
            ordered.append(candidate)
            break
        }
        return ordered
    }

 /// Ordered exact-fetch origins for the current network path.
    private func exactFetchOrigins() -> [URL] {
        guard let credentials else { return [] }
        return Self.exactFetchOriginCandidates(
            persisted: credentials.originURL,
            stored: credentials.originCandidates,
            relayOverride: earlyListOriginOverride(),
            prefersRelay: NetworkPathMonitor.shared.prefersRelay
        )
    }

 /// GET an allowlisted exact-fetch route through the link proxy with the
 /// short-lived api token (auto-refresh once on 401).
 ///
 /// task-2: the origin is the same reachable LAN/relay origin the unary path uses
 /// (`earlyListOriginOverride()`), with the alternate channel as one bounded
 /// fallback when the failure is transport-level (not a Host 404). Diagnostics are
 /// one line per attempt behind `DSHM_CHANGESDBG=1`.
    func exactFetchJSON(path: String, query: [String: String], timeout: TimeInterval = 20) async throws -> JSONValue? {
        guard let credentials else { throw LinkError.notPaired }
        let origins = exactFetchOrigins()
        guard let primary = origins.first else { throw LinkError.transport(L10n.t("配对 origin 非法")) }
        let seq = query["seq"] ?? "-"
        let prefersRelay = NetworkPathMonitor.shared.prefersRelay
        var lastError: Error = LinkError.transport(L10n.t("配对 origin 非法"))
        for (index, origin) in origins.enumerated() {
            let isPrimary = index == 0
            let attemptTimeout = isPrimary ? timeout : min(timeout, exactFetchAlternateTimeout)
            let started = Date()
            do {
 // The API token refresh must also target the reachable origin; a stale
 // LAN origin would otherwise hang the auth before the GET is even sent.
                var token = try await ensureAPIToken(originOverride: origin)
                var result = try await Self.exactFetchGET(
                    origin: origin,
                    path: path,
                    query: query,
                    token: token,
                    credentials: credentials,
                    timeout: attemptTimeout
                )
                if result.status == 401,
                   result.body.contains("auth/token-expired") || result.body.contains("auth/invalid") {
                    token = try await ensureAPIToken(forceRefresh: true, originOverride: origin)
                    result = try await Self.exactFetchGET(
                        origin: origin,
                        path: path,
                        query: query,
                        token: token,
                        credentials: credentials,
                        timeout: attemptTimeout
                    )
                }
                guard result.status == 200 else {
                    throw LinkError.httpStatus(result.status, result.body)
                }
                ChangesDebugLog.log("ok path=\(path) seq=\(seq) origin=\(origin.absoluteString) relay=\(prefersRelay ? 1 : 0) status=200 ms=\(Self.millis(since: started))")
                return result.json
            } catch {
                lastError = error
                let status = Self.httpStatus(of: error).map(String.init) ?? "-"
                let body = Self.httpBody(of: error) ?? "-"
                ChangesDebugLog.log("fail path=\(path) seq=\(seq) try=\(index + 1)/\(origins.count) origin=\(origin.absoluteString) relay=\(prefersRelay ? 1 : 0) status=\(status) err=\(Self.describe(error)) ms=\(Self.millis(since: started)) body=\(body.prefix(160))")
                guard index + 1 < origins.count, Self.shouldTryAlternateExactFetchOrigin(error) else { throw error }
                ChangesDebugLog.log("retry-alt path=\(path) seq=\(seq) alternate=\(origins[index + 1].absoluteString)")
            }
        }
        throw lastError
    }

    private nonisolated static func exactFetchGET(
        origin: URL,
        path: String,
        query: [String: String],
        token: String,
        credentials: PairingCredentials,
        timeout: TimeInterval
    ) async throws -> (status: Int, json: JSONValue?, body: String) {
        try await HTTPSClient.exactGETJSON(
            origin: origin,
            path: path,
            query: query,
            token: token,
            leafPin: credentials.leafPin,
            caCertBase64: credentials.caCertBase64,
            timeout: timeout
        )
    }

    nonisolated static func httpStatus(of error: Error) -> Int? {
        guard let linkError = error as? LinkError,
              case let .httpStatus(status, _) = linkError else { return nil }
        return status
    }

    nonisolated static func httpBody(of error: Error) -> String? {
        guard let linkError = error as? LinkError,
              case let .httpStatus(_, body) = linkError else { return nil }
        return body
    }

    nonisolated static func describe(_ error: Error) -> String {
        "\(type(of: error)): \(String(describing: error))"
    }

    nonisolated static func millis(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

 /// Whether a failed attempt can be fixed by dialing another origin.
 /// A Host 404 ("summary released") cannot; a transport/timeout/relay/proxy
 /// failure can. 404 from the relay proxy itself (`route/not-allowed`, upstream
 /// connect failure) is a relay-version problem, not the Host dropping the data.
    nonisolated static func shouldTryAlternateExactFetchOrigin(_ error: Error) -> Bool {
        guard let linkError = error as? LinkError else { return true }
        switch linkError {
        case .httpStatus(let status, let body):
            switch status {
            case 401, 403: return true
            case 404: return body.contains("route/not-allowed") || body.contains("upstream")
            case 500...599: return true
            default: return false
            }
        case .cancelled, .notPaired: return false
        default: return true
        }
    }

 /// File-change summary for one `workspace/changes` event seq.
 /// Throws `LinkError.httpStatus(404,...)` when the Host no longer holds it.
    func changesSummary(sessionId: String, seq: Int) async throws -> ChangesSummaryValue {
        guard let value = try await exactFetchJSON(
            path: "/api/changes.summary",
            query: ["sessionId": sessionId, "seq": String(seq)]
        ) else {
            throw LinkError.malformedEnvelope(L10n.t("changes.summary 响应为空"))
        }
        return try value.decode(ChangesSummaryValue.self)
    }

 /// Diff for one file index inside a `workspace/changes` event.
    func changesDiff(sessionId: String, seq: Int, index: Int) async throws -> ChangesDiffValue {
        guard let value = try await exactFetchJSON(
            path: "/api/changes.diff",
            query: ["sessionId": sessionId, "seq": String(seq), "index": String(index)]
        ) else {
            throw LinkError.malformedEnvelope(L10n.t("changes.diff 响应为空"))
        }
        return try value.decode(ChangesDiffValue.self)
    }

 // MARK: - Attachments (§8.2 session/attachment)

    struct AttachmentValue: Decodable {
        struct Attachment: Decodable {
            var attachmentId: String?
            var mediaType: String?
            var name: String?
            var width: Int?
            var height: Int?
            var bytes: Int?
        }
        var attachment: Attachment?
        var data: String?
    }

 /// Fetches image bytes as described in §8.2 / §6:
 /// unary session/attachment {request:{sessionId, attachmentId}} -> {attachment, data(base64)}.
    func attachmentData(sessionId: String, attachmentId: String) async throws -> (data: Data, mediaType: String?) {
        let value = try await unary("session/attachment", args: [
            "request": .object([
                "sessionId": .string(sessionId),
                "attachmentId": .string(attachmentId),
            ]),
        ])
        let decoded = try value.decode(AttachmentValue.self)
        guard let base64 = decoded.data, let data = Data(base64Encoded: base64) else {
            throw LinkError.malformedEnvelope(L10n.t("session/attachment 缺少 base64 data"))
        }
        return (data, decoded.attachment?.mediaType)
    }

 // MARK: - Projected session/page streaming（协议 v1，契约 §4）

 /// 投影页帧间空闲超时上限（契约 DD-11：`min(10s, unary 超时)`）。
    static let maxProjectedFrameIdleSeconds: TimeInterval = 10

 /// 当前 dsh-m/2 连接是否协商成功投影帧（`0x02`）。false = 走既有 JSON 路径
 /// （legacy 通道 / 旧插件 / 插件 feature off / 客户端开关关闭）。
    var projectedHistoryAvailable: Bool {
        guard let p1 = p1Channel, p1.isReady else { return false }
        return p1.projV1Negotiated
    }

 /// 投影流式 `session/page`：逐帧返回（帧序 = seq 降序，帧 0 与已加载窗口
 /// 前沿相邻）。`nil` = 当前连接不能投影，调用方回退既有 `unary` JSON 路径。
 ///
 /// 错误语义：`P1Failure`（超时/断线/取消）与 `P1ProtocolError` 直接抛出，
 /// 由调用方按既有 unary 失败语义处理；已产出的帧保持有效（半页续传）。
    func projectedSessionPageStream(
        args: [String: JSONValue],
        timeout: TimeInterval = 10
    ) throws -> P1ProjectedStream? {
        guard let p1 = p1Channel, p1.isReady, p1.projV1Negotiated else { return nil }
        return try p1.unaryProjected(endpoint: "session/page", args: args, timeout: timeout)
    }

 /// 消费一整页投影帧 → 旧 JSON 页信封（`{records:[{type:"event",event,seq}], hasMore}`）。
 ///
 /// 只给「不需要逐帧的普通 unary 调用方」用；记录按 seq 升序（Host JSON 页口径）。
 /// 插件整页回退时（`.textResult`）直接走旧 JSON 映射，与旧路径逐字节等价。
    @MainActor
    private static func projectedPageValue(
        p1: P1Channel,
        args: [String: JSONValue],
        timeout: TimeInterval
    ) async throws -> JSONValue {
 // 契约 DD-11：投影页帧间空闲超时 = `min(10s, unary 超时)`。这里的通用 unary
 // 调用方（lazy-fetch 窄页 timeout 15s、默认 20s）不得把帧间等待放宽到 >10s。
        let stream = try p1.unaryProjected(
            endpoint: "session/page",
            args: args,
            timeout: min(timeout, Self.maxProjectedFrameIdleSeconds)
        )
        var rows: [JSONValue] = []
        var hasMore = false
        for try await event in stream.events {
            switch event {
            case .frame(let header, let frameRows):
                if header.f == 0 { hasMore = header.hasMore ?? false }
                rows.append(contentsOf: frameRows)
            case .textResult(let result):
                return try P1UnaryMapping.jsonValue(from: result)
            case .completed(_, _, let pageHasMore):
                hasMore = pageHasMore
            }
        }
        return try ProjV1RowMapping.pageValue(rows: rows, hasMore: hasMore)
    }
}

/// Pure mapping from the dsh-m/2 unary frames to the error/JSON types the rest of
/// the App already consumes on the M1 path (design §3.4):
///
/// - `rpc/result.status == 200` + `server-response` envelope -> the same
/// `JSONValue` the HTTPS unary path returns (including business errors as
/// `LinkError.remote`);
/// - non-200 status -> existing `LinkError.httpStatus` branch (body passed through);
/// - `rpc/error` -> `LinkError.remote` for business-ish codes, `LinkError.transport`
/// for upstream/plugin failures, `LinkError.timeout` for `rpc/timeout`.
///
/// Kept as free functions so the mapping is unit-tested without a socket.
enum P1UnaryMapping {
 /// Decodes one `rpc/result` into the legacy unary result value.
    static func jsonValue(from result: P1RPCResult) throws -> JSONValue {
        guard result.status == 200 else {
            throw LinkError.httpStatus(result.status, bodyText(of: result))
        }
        guard let body = result.body else {
 // HTTP 200 with a non-JSON body cannot be a `server-response` envelope.
            throw LinkError.malformedEnvelope(L10n.t("dsh-m/2 rpc/result 缺少 JSON body"))
        }
 // Fast path for the huge bodies (a `session/page` history page is
 // ~1.4 MB of JSON on a real long session): read the envelope
 // structurally off the already-decoded `JSONValue`. The generic path
 // below is `JSONValue.decode(_:)`, which re-encodes the whole tree to
 // JSON and parses it again — that double conversion ran on the main
 // actor for every history page and starved touch delivery during the
 // detail-view history fill (freeze report: the page would
 // not scroll and the header back button would not respond until the
 // fill progress bar finished).
        if let object = body.objectValue,
           object["type"]?.stringValue == "server-response",
           let resultObject = object["result"]?.objectValue,
           resultObject["ok"]?.boolValue == true {
            return resultObject["value"] ?? .null
        }
 // Every other shape (business error, non-`server-response`, malformed)
 // keeps the exact legacy semantics through the typed envelope decode.
 // Failure envelopes are tiny — they never carry a history page.
        let envelope: ServerResponseEnvelope
        do {
            envelope = try body.decode(ServerResponseEnvelope.self)
        } catch {
            throw LinkError.malformedEnvelope("server-response 解析失败: \(error.localizedDescription)")
        }
        guard envelope.type == "server-response" else {
            throw LinkError.malformedEnvelope("type != server-response")
        }
        switch envelope.result {
        case .ok(let value):
            return value
        case .failure(let error):
            throw LinkError.remote(error)
        }
    }

 /// Maps a `P1Channel.unary` failure onto the legacy transport error surface.
    static func linkError(from failure: P1Failure) -> LinkError {
        switch failure {
        case .notConnected:
            return .notConnected
        case .timeout:
            return .timeout("rpc")
        case .cancelled:
            return .cancelled
        case .rpcError(_, let error):
            if error.code == "rpc/timeout" { return .timeout("rpc") }
            if error.code.hasPrefix("upstream/") {
                return .transport(error.message.isEmpty ? error.code : error.message)
            }
            return .remote(error)
        case .frameTooLarge(let reason):
            return .transport(L10n.f("dsh-m/2 帧过大：%@", reason))
        case .protocolViolation(let message):
            return .transport(L10n.f("dsh-m/2 协议异常：%@", message))
        default:
            return .transport(failure.userMessage)
        }
    }

 /// Raw error body for `LinkError.httpStatus` (what the HTTP path would have
 /// passed as `response.bodyText`).
    private static func bodyText(of result: P1RPCResult) -> String {
        if let text = result.bodyText { return text }
        if let body = result.body {
            if case .string(let text) = body { return text }
            if let data = try? JSONEncoder().encode(body),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        return ""
    }
}
