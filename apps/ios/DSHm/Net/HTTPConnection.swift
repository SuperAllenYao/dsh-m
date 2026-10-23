import Foundation
import Network

/// Origin identity of a pooled HTTP/1.1 connection.
///
/// The leaf pin is part of the key on purpose: re-pairing can rotate the plugin
/// certificate (`tls.leafFingerprint256`) on the same host:port, and a pooled
/// TLS connection that was validated against the previous pin must never be
/// reused for the new credential.
struct HTTPConnectionKey: Hashable {
    let host: String
    let port: UInt16
 /// Normalized (lowercase hex) leaf pin, nil for unpinned discovery calls.
    let pin: String?
 /// v0.1.1 C: digest of the pinned CA certificate (nil for pre-C pairings).
 /// Part of the key so a pooled TLS connection validated against the leaf-pin
 /// fallback is never reused once the credential upgrades to CA trust.
    let caCertHash: String?

    init(host: String, port: UInt16, pin: String?, caCertHash: String? = nil) {
        self.host = host
        self.port = port
        self.pin = pin
        self.caCertHash = caCertHash
    }
}

/// Errors that are safe to retry on a fresh connection: the pooled socket died
/// between checkout and dispatch, so the request bytes were never written.
enum HTTPConnectionError: Error {
 /// The pooled connection closed before the request was sent (stale
 /// keep-alive socket); HTTPSClient retries once on a fresh connection.
    case closedBeforeSend
}

/// Tunables of the unary keep-alive pool.
struct HTTPConnectionPoolConfig {
 /// Idle connections kept per origin; connections beyond this are closed
 /// after their response completes.
    var maxIdlePerOrigin: Int
 /// How long an idle connection is kept locally before being closed. Kept
 /// below the plugin's HTTP `keepAliveTimeout` (see link-server.js), so the
 /// server never closes a connection we are about to reuse.
    var idleTimeout: TimeInterval

    init(maxIdlePerOrigin: Int = 2, idleTimeout: TimeInterval = 30) {
        self.maxIdlePerOrigin = maxIdlePerOrigin
        self.idleTimeout = idleTimeout
    }
}

/// Thread-safe idle pool for HTTP/1.1 keep-alive connections.
///
/// Only idle connections are tracked here: a connection checked out by a
/// request is owned by that request and is either checked back in after a
/// keep-alive-eligible response or closed. There is no pipelining — one request
/// per connection at a time (HTTP/1.1 semantics without the complexity).
final class HTTPConnectionPool {
    static let shared = HTTPConnectionPool()

    let config: HTTPConnectionPoolConfig
    private let lock = NSLock()
    private var idle: [HTTPConnectionKey: [HTTPConnection]] = [:]

    init(config: HTTPConnectionPoolConfig = HTTPConnectionPoolConfig()) {
        self.config = config
    }

 /// Pops a live idle connection for `key`, or returns nil when the caller
 /// must create a fresh one. Connections that died while idle are discarded
 /// here (their idle monitor already removed them from the pool, but the
 /// claim is re-checked so a close racing the checkout can never be reused).
    func checkout(_ key: HTTPConnectionKey) -> HTTPConnection? {
        lock.lock()
        defer { lock.unlock() }
        guard var list = idle[key] else { return nil }
        while !list.isEmpty {
            let connection = list.removeLast()
            if connection.claimForRequest() {
                idle[key] = list.isEmpty ? nil : list
                return connection
            }
        }
        idle[key] = nil
        return nil
    }

 /// Hands an idle connection back. Returns a connection that had to be
 /// evicted because the per-origin cap is exceeded; the caller closes it.
    @discardableResult
    func checkin(_ connection: HTTPConnection) -> HTTPConnection? {
        lock.lock()
        var list = idle[connection.key] ?? []
        var evicted: HTTPConnection?
        if list.count >= config.maxIdlePerOrigin, !list.isEmpty {
            evicted = list.removeFirst()
        }
        list.append(connection)
        idle[connection.key] = list
        lock.unlock()
        return evicted
    }

    func remove(_ connection: HTTPConnection) {
        lock.lock()
        if var list = idle[connection.key] {
            list.removeAll { $0 === connection }
            idle[connection.key] = list.isEmpty ? nil : list
        }
        lock.unlock()
    }

 /// Test/diagnostic hook: number of idle connections for an origin.
    func idleCount(for key: HTTPConnectionKey) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return idle[key]?.count ?? 0
    }

    func closeAll() {
        lock.lock()
        let all = idle.values.flatMap { $0 }
        idle.removeAll()
        lock.unlock()
        for connection in all { connection.closeFromPool() }
    }
}

/// One reusable HTTP/1.1 connection.
///
/// Lifecycle: connect once, then serialize requests (no pipelining). While idle
/// exactly one `receive` stays armed, which doubles as a liveness probe: when
/// the peer closes (Node keep-alive timeout, relay/network teardown) the
/// receive completes with EOF *before* the next request, so the connection is
/// removed from the pool instead of being reused half-dead.
///
/// All mutable connection state is confined to `queue`; the small
/// `closed`/`idle`/`reused` flags are additionally guarded by `stateLock`
/// because the pool reads them from other threads.
final class HTTPConnection {
    let key: HTTPConnectionKey
    let host: String
    let port: UInt16

    private let parameters: NWParameters
    private weak var pool: HTTPConnectionPool?
    private let queue = DispatchQueue(label: "com.dshm.http-connection")
    private var connection: NWConnection?
    private var parser = HTTPResponseParser()
    private let pinCapture: PinCapture
    private var pending: PendingRequest?
    private var ready = false
 /// T2(A): a TLS-only prewarm waiting for `.ready` (no request pending).
    private var readyWait: ReadyWait?
    private var receiveInFlight = false
    private var idleTimer: DispatchWorkItem?
    private var nextRequestId = 0
 /// True once the current request's bytes were handed to NWConnection; before
 /// that a failure is a stale-pool retry candidate (no request was sent).
    private var didSend = false
 /// True when this connection was claimed from the idle pool (a fresh
 /// connection's pre-send failures are real errors, not stale-pool races).
    private var wasReused = false

    private let stateLock = NSLock()
    private var closed = false
    private var idle = false

    private(set) var observedLeafPin: String?

    private struct PendingRequest {
        let id: Int
        let request: HTTPRequest
        let bytes: Data
        let continuation: CheckedContinuation<HTTPResponse, Error>
        var timeoutItem: DispatchWorkItem?
 /// task-2 (reconnect): first-byte watchdog state. Only reused keep-alive
 /// connections are watched (see `scheduleFirstByteWatchdog`).
        var firstByteSeen = false
        var firstByteItem: DispatchWorkItem?
    }

 /// One in-flight `awaitReadyAndCheckIn` waiter. Queue-confined like `pending`.
    private struct ReadyWait {
        let continuation: CheckedContinuation<Bool, Never>
        var timeoutItem: DispatchWorkItem?
    }

 /// task-2 (reconnect < 1s): budget for the **first response byte on a reused
 /// (keep-alive) connection**. A socket that survived a Wi-Fi -> cellular switch
 /// but is actually dead stays "open" locally; without this watchdog the first
 /// unary call after the switch waited for the full 20s HTTP timeout before the
 /// reconnect loop even started. Fresh connections (TCP/TLS handshake included)
 /// are never watched: a slow network must not be mistaken for a dead socket.
 ///
 /// Single tunable constant by design (Lead decision): one place to adjust from
 /// real-device data.
 ///
 /// real-device calibration: 0.8s fired on a **slow but alive** relay
 /// path — a 5G/relay round under head-of-line blocking routinely pushes a large
 /// response past 800ms (`/api/session/list` is 1.46MB raw / 357KB gzip and the
 /// tunnel carries session/page concurrently). This watchdog only *reports*; the
 /// whole-transport teardown decision lives in `LinkService`, which now verifies
 /// the path before forcing a reconnect. 1.5s keeps dead-socket detection fast on
 /// LAN while tolerating a relay stall that is still making progress.
    static let firstByteTimeout: TimeInterval = 1.5

    init(
        key: HTTPConnectionKey,
        host: String,
        port: UInt16,
        leafPin: String?,
        caCertBase64: String? = nil,
        parametersOverride: NWParameters?,
        pool: HTTPConnectionPool?
    ) {
        self.key = key
        self.host = host
        self.port = port
        self.pool = pool
        let pinCapture = PinCapture()
        self.pinCapture = pinCapture
        self.parameters = parametersOverride
            ?? PinnedTLS.parameters(
                leafPin: leafPin,
                caCertBase64: caCertBase64,
                capture: pinCapture,
                connectTimeout: PinnedTLS.defaultConnectTimeout
            )
        let nw = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 443,
            using: parameters
        )
        self.connection = nw
        nw.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
        }
        nw.start(queue: queue)
    }

    deinit {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

 // MARK: - Cross-thread flags

    var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    var isIdle: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return idle
    }

 /// Pool → connection hand-off. Returns false when the connection died while
 /// idle (the caller then creates a fresh one).
    func claimForRequest() -> Bool {
        stateLock.lock()
        guard !closed, idle else {
            stateLock.unlock()
            return false
        }
        idle = false
        stateLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.wasReused = true
            self.idleTimer?.cancel()
            self.idleTimer = nil
        }
        return true
    }

    private func setIdle(_ value: Bool) {
        stateLock.lock()
        idle = value
        stateLock.unlock()
    }

 // MARK: - TLS-only prewarm)

 /// 等到 TCP+TLS `.ready`，**不发任何 HTTP 请求**，然后把连接标记 idle 并放回
 /// 共享池——等价于一次 keep-alive 响应后的空闲态（idle timer + 一个空闲
 /// receive 做存活探测），后续 checkout 走的是完全相同的复用路径。
 ///
 /// - true：连接已入池，同一 key 的后续请求可直接复用它；
 /// - false：超时/握手失败/连接关闭/不可池化（pool == nil），连接已丢弃。
 /// 不抛错；调用方失败时忽略即可（后续请求走原路径）。
    func awaitReadyAndCheckIn(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                self.beginReadyWait(continuation: continuation, timeout: timeout)
            }
        }
    }

    private func beginReadyWait(continuation: CheckedContinuation<Bool, Never>, timeout: TimeInterval) {
        guard !isTraceableClosed else {
            continuation.resume(returning: false)
            return
        }
 // `.ready` may have landed before the await started (init already dialed).
        if ready, pending == nil {
            continuation.resume(returning: checkInAfterReady())
            return
        }
        var wait = ReadyWait(continuation: continuation)
        let item = DispatchWorkItem { [weak self] in
            self?.timeoutReadyWait()
        }
        wait.timeoutItem = item
        readyWait = wait
        queue.asyncAfter(deadline: .now() + max(0.05, timeout), execute: item)
    }

    private func timeoutReadyWait() {
        guard readyWait != nil else { return }
 // closeInternal resumes the waiter with false and tears the socket down.
        closeInternal(notifyPool: false)
    }

 /// Shared `.ready` + no pending request path: mark idle, hand to the pool,
 /// arm the idle timer and the idle liveness receive (same as a keep-alive
 /// response). Returns false when the connection cannot be pooled.
    private func checkInAfterReady() -> Bool {
        guard let pool, !isTraceableClosed else {
            closeInternal(notifyPool: false)
            return false
        }
        if isIdle { return true }
        setIdle(true)
        if let evicted = pool.checkin(self) {
            evicted.closeFromPool()
        }
        armIdleTimer()
        receiveNext()
        return true
    }

 // MARK: - Requests

    func perform(_ request: HTTPRequest, timeout: TimeInterval) async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: LinkError.transport("连接已释放"))
                    return
                }
                self.begin(request: request, timeout: timeout, continuation: continuation)
            }
        }
    }

    private func begin(request: HTTPRequest, timeout: TimeInterval, continuation: CheckedContinuation<HTTPResponse, Error>) {
        if isTraceableClosed {
 // Only a connection claimed from the pool can be closed before the
 // request starts; let the caller rebuild instead of surfacing a
 // spurious transport error.
            continuation.resume(throwing: preSendFailure(LinkError.transport("连接已关闭")))
            return
        }
        if pending != nil {
 // Defensive: the pool never hands out a busy connection.
            continuation.resume(throwing: LinkError.transport("连接忙"))
            return
        }
        didSend = false
        parser.reset()
        nextRequestId += 1
        let requestId = nextRequestId
        let bytes = HTTPSClient.serialize(request: request, host: host, port: port, keepAlive: true)
        var item = PendingRequest(id: requestId, request: request, bytes: bytes, continuation: continuation)
        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.handleTimeout(requestId: requestId)
        }
        item.timeoutItem = timeoutItem
        pending = item
        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        if ready {
            sendPending()
        }
 // Otherwise the `.ready` state handler flushes the pending request.
    }

 /// Queue-confined view of `closed` (avoids taking the lock in hot paths).
    private var isTraceableClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    private func sendPending() {
        guard let pending, let connection else {
            handleClosure(LinkError.transport("连接已关闭"))
            return
        }
        didSend = true
        connection.send(content: pending.bytes, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.handleClosure(LinkError.transport("发送失败：" + NetworkErrorInterpreter.message(for: error)))
                return
            }
            self.scheduleFirstByteWatchdog()
            self.receiveNext()
        })
    }

    private func receiveNext() {
        guard !isTraceableClosed, let connection, !receiveInFlight else { return }
        receiveInFlight = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.receiveInFlight = false
            self.handleReceive(data: data, isComplete: isComplete, error: error)
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if isTraceableClosed { return }
        if let data, !data.isEmpty {
            guard self.pending != nil else {
 // No pipelining: bytes while idle are a protocol violation.
                closeInternal(notifyPool: true)
                return
            }
 // task-2: any response byte satisfies the reused-socket watchdog —
 // including the case where the TCP migration kept a half-stale
 // connection alive but slow.
            self.pending?.firstByteSeen = true
            self.pending?.firstByteItem?.cancel()
            self.pending?.firstByteItem = nil
            parser.append(data)
            if let response = parser.completed {
                completeResponse(response)
                return
            }
        }
        if let error {
            if pending != nil, let response = parser.finishOnClose() {
                completeResponse(response)
            } else {
                failPending(LinkError.transport("接收失败：" + NetworkErrorInterpreter.message(for: error)))
                closeInternal(notifyPool: true)
            }
            return
        }
        if isComplete {
            if pending != nil, let response = parser.finishOnClose() {
                completeResponse(response)
            } else {
                failPending(LinkError.transport("连接提前关闭"))
                closeInternal(notifyPool: true)
            }
            return
        }
 // Keep the receive pump alive while a request is in flight, and keep a
 // single liveness receive armed while idle (see class comment).
        receiveNext()
    }

    private func completeResponse(_ response: HTTPResponse) {
        guard let pending else {
            closeInternal(notifyPool: true)
            return
        }
        self.pending = nil
        pending.timeoutItem?.cancel()
        pending.firstByteItem?.cancel()
        var response = response
        response.observedLeafPin = pinCapture.pin
        let keepAlive = canKeepAlive(response: response, request: pending.request)
        pending.continuation.resume(returning: response)
        parser.reset()
        if keepAlive {
            setIdle(true)
            if let pool {
                if let evicted = pool.checkin(self) {
                    evicted.closeFromPool()
                }
                armIdleTimer()
                receiveNext()
            } else {
                closeInternal(notifyPool: false)
            }
        } else {
            closeInternal(notifyPool: true)
        }
    }

 /// HTTP/1.1 keep-alive eligibility. Only responses whose body ended at a
 /// known boundary and that did not advertise `Connection: close` are
 /// reusable; a body that ended because the socket closed (`untilClose`) is
 /// never reusable.
    private func canKeepAlive(response: HTTPResponse, request: HTTPRequest) -> Bool {
        if parser.hasBufferedBytes { return false }
        if parser.bodyEndedByClose { return false }
        let connectionHeader = (response.header("connection") ?? "").lowercased()
        if connectionHeader.contains("close") { return false }
        if parser.protocolVersion == "HTTP/1.0" {
            return connectionHeader.contains("keep-alive")
        }
        return true
    }

    private func handleTimeout(requestId: Int) {
        guard let pending, pending.id == requestId else { return }
        let error = LinkError.timeout("\(pending.request.method) \(pending.request.path)")
        failPending(error)
 // A timed-out connection is in an unknown mid-response state: drop it.
        closeInternal(notifyPool: true)
    }

 /// task-2 (reconnect): arms the reused-socket first-byte watchdog. Scheduled
 /// **after** the request bytes went out, and only for connections claimed from
 /// the idle pool: a fresh connection still has legitimate TCP/TLS/first-flight
 /// latency, so it is never watched.
    private func scheduleFirstByteWatchdog() {
        guard wasReused, let pending else { return }
        pending.firstByteItem?.cancel()
        let requestId = pending.id
        let item = DispatchWorkItem { [weak self] in
            self?.handleFirstByteTimeout(requestId: requestId)
        }
        self.pending?.firstByteItem = item
        queue.asyncAfter(deadline: .now() + Self.firstByteTimeout, execute: item)
    }

 /// task-2: a reused socket produced zero response bytes within
 /// `firstByteTimeout`. Fail the request with a transport timeout, report the
 /// condition (searchable log + NotificationCenter for `LinkService`), and drop
 /// the socket so a dead keep-alive connection can never be checked out again.
    private func handleFirstByteTimeout(requestId: Int) {
        guard let pending, pending.id == requestId, !pending.firstByteSeen, wasReused else { return }
        let endpoint = pending.request.path
        let waitedMs = Self.firstByteTimeout * 1000
        NSLog("[RECONNECT] firstByteTimeout endpoint=%@;waitedMs=%.0f", endpoint, waitedMs)
        NotificationCenter.default.post(
            name: .dshmHTTPFirstByteTimeout,
            object: self,
            userInfo: [
                "endpoint": endpoint,
                "waitedMs": waitedMs,
                "host": host,
                "port": Int(port),
            ]
        )
        failPending(LinkError.timeout("首字节超时（复用连接 \(Int(waitedMs))ms 无响应）：\(endpoint)"))
        closeInternal(notifyPool: true)
    }

 /// Test seam (fake clock): run the first-byte deadline now for the in-flight
 /// request instead of waiting `firstByteTimeout` in real time.
    func simulateFirstByteTimeoutForTesting() {
        queue.sync { [weak self] in
            guard let self, let requestId = self.pending?.id else { return }
            self.handleFirstByteTimeout(requestId: requestId)
        }
    }

    private func failPending(_ error: Error) {
        guard let pending else { return }
        self.pending = nil
        pending.timeoutItem?.cancel()
        pending.firstByteItem?.cancel()
        pending.continuation.resume(throwing: error)
    }

 // MARK: - State changes

    private func handleState(_ state: NWConnection.State) {
        if isTraceableClosed { return }
        switch state {
        case .ready:
            ready = true
            observedLeafPin = pinCapture.pin
            if pending != nil {
                sendPending()
            } else if let wait = readyWait {
 // T2(A): TLS-only prewarm completed — hand the ready
 // connection to the idle pool, exactly like a keep-alive response.
                readyWait = nil
                wait.timeoutItem?.cancel()
                wait.continuation.resume(returning: checkInAfterReady())
            }
        case .failed(let error):
            handleClosure(LinkError.transport("连接 \(host):\(port) 失败：" + NetworkErrorInterpreter.message(for: error)))
        case .waiting(let error):
 // TLS pin mismatch usually surfaces here as a cert/trust error.
            handleClosure(LinkError.transport("连接 \(host):\(port) 等待中：" + NetworkErrorInterpreter.message(for: error)))
        case .cancelled:
            handleClosure(LinkError.cancelled)
        default:
            break
        }
    }

 /// A pre-send failure on a reused connection is a stale-keep-alive race and
 /// is retryable on a fresh connection; everything else keeps its error.
    private func preSendFailure(_ error: Error) -> Error {
        if didSend || !wasReused { return error }
        return HTTPConnectionError.closedBeforeSend
    }

 /// Connection died between requests (or while connecting): fail the pending
 /// request if any, drop the socket and remove ourselves from the pool.
    private func handleClosure(_ error: Error) {
        if pending != nil {
 // A reused socket can fail before the request bytes are written
 // (peer FIN raced the checkout); that is retryable on a fresh
 // connection. Failures after send stay fatal (POST ambiguity).
            failPending(preSendFailure(error))
        }
        closeInternal(notifyPool: true)
    }

    private func closeInternal(notifyPool: Bool) {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return
        }
        closed = true
        idle = false
        stateLock.unlock()
        idleTimer?.cancel()
        idleTimer = nil
 // T2(A): a prewarm waiter must be released when the handshake
 // fails or the connection is torn down (exactly-once resume).
        if let wait = readyWait {
            readyWait = nil
            wait.timeoutItem?.cancel()
            wait.continuation.resume(returning: false)
        }
        if let pending {
            self.pending = nil
            pending.timeoutItem?.cancel()
            pending.continuation.resume(throwing: preSendFailure(LinkError.transport("连接已关闭")))
        }
        ready = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        if notifyPool { pool?.remove(self) }
    }

    private func armIdleTimer() {
        guard let pool else { return }
        idleTimer?.cancel()
        let timeout = max(0.05, pool.config.idleTimeout)
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isIdle else { return }
            self.closeInternal(notifyPool: true)
        }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + timeout, execute: item)
    }

 /// Called by the pool when this connection is evicted for capacity or when
 /// the pool is torn down.
    func closeFromPool() {
        queue.async { [weak self] in
            self?.closeInternal(notifyPool: false)
        }
    }
}

/// task-2 (reconnect): posted once per **reused** pooled connection whose first
/// response byte did not arrive within `HTTPConnection.firstByteTimeout`.
/// `LinkService` listens and invalidates the live transport (a dead unary socket
/// and a dead mux almost always share the same network event), so the reconnect
/// starts immediately instead of waiting for the full HTTP timeout.
extension Notification.Name {
    static let dshmHTTPFirstByteTimeout = Notification.Name("com.dshm.httpFirstByteTimeout")
}
