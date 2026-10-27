import Foundation

// MARK: - Socket seam

/// One close/failure event from a `P1Socket`.
struct P1SocketClose: Equatable {
    var code: Int
    var reason: String

    init(code: Int, reason: String) {
        self.code = code
        self.reason = reason
    }
}

/// Transport seam under `P1Channel`.
///
/// Production uses `P1WSSocket` (a thin adapter over the existing pinned-TLS
/// `WSSClient`); tests inject `FakeSocket`. Contract:
/// - `connect()` opens the pinned WS. It must NOT deliver `onText`/`onBinary`/
/// `onClose` synchronously from inside `connect()` (real transports deliver on
/// the main queue after the await returns).
/// - `send(text:)` is one text message; delivery may be synchronous (tests).
/// - `close(code:reason:)` is idempotent and must not throw.
/// - All callbacks are invoked on the main actor, in wire order.
/// - `onBinary` delivers binary WS frames — only
/// sent by the plugin after `welcome.caps.gzip` negotiation; the channel
/// treats an un-negotiated binary frame as a protocol violation.
@MainActor
protocol P1Socket: AnyObject {
    var onText: ((String) -> Void)? { get set }
    var onBinary: ((Data) -> Void)? { get set }
    var onClose: ((P1SocketClose) -> Void)? { get set }
    func connect() async throws
    func send(text: String) throws
    func close(code: Int, reason: String)
}

/// Production socket: reuses the existing `WSSClient` (NWConnection + pinned TLS
/// + RFC 6455 codec), so the certificate pin check keeps happening at the TLS
/// handshake — before any `hello`/`rpc` frame is sent (design §7.2).
///
/// Wiring: `LinkService` builds this with the origin host/port and the pairing
/// leaf pin, path `P1Proto.socketPath` (i.e. `/api/remote.mux?proto=2`) and no
/// `authorization` header (P1 authenticates in-band in `hello`). The same
/// `WSSClient` still supports the legacy M1 path untouched.
@MainActor
final class P1WSSocket: P1Socket {
    private let ws: WSSClient
    private let connectTimeout: TimeInterval

    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onClose: ((P1SocketClose) -> Void)?

    init(
        host: String,
        port: UInt16,
        path: String = P1Proto.socketPath,
        headers: [String: String] = [:],
        leafPin: String,
        caCertBase64: String? = nil,
        connectTimeout: TimeInterval = PinnedTLS.defaultConnectTimeout
    ) {
        self.ws = WSSClient(host: host, port: port, path: path, headers: headers, leafPin: leafPin, caCertBase64: caCertBase64)
        self.connectTimeout = connectTimeout
        ws.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .text(let text):
                self.onText?(text)
            case .binary(let data):
 // link-perf L3a：gzip 协商后的下行压缩帧，按 data 透传。
                self.onBinary?(data)
            case .closed(let code, let reason):
                self.onClose?(P1SocketClose(code: code, reason: reason))
            case .failed(let error):
                self.onClose?(P1SocketClose(
                    code: P1CloseCode.abnormalClosure.rawValue,
                    reason: NetworkErrorInterpreter.message(for: error)
                ))
            case .opened, .pong:
                break
            }
        }
    }

    func connect() async throws {
        try await ws.connect(timeout: connectTimeout)
    }

    func send(text: String) throws {
        try ws.send(text: text)
    }

    func close(code: Int, reason: String) {
        ws.close(code: code, reason: reason)
    }
}

// MARK: - Channel state

/// Lifecycle of one logical dsh-m/2 channel.
///
/// `closed` is resumable: the next `connect` may carry `resume` with
/// `lastAppliedSid`/`epoch` to continue the server-side channel.
enum P1ChannelState: Equatable {
    case idle
    case connecting
    case ready
    case closed
}

/// Description of an opened stream, kept across socket loss / epoch reset so the
/// caller can re-open it (design §5 `RESUMING`).
struct P1StreamDescriptor: Equatable, Sendable {
    var streamId: String
    var endpoint: String
    var args: [String: JSONValue]
}

/// Replay-window telemetry: how many missed `down` frames the App actually
/// applied and how many wire bytes they cost (design §7.3).
struct P1ReplayStats: Equatable, Sendable {
    var frames: Int
    var bytes: Int

    init(frames: Int = 0, bytes: Int = 0) {
        self.frames = frames
        self.bytes = bytes
    }
}

// MARK: - Stream handle

/// Handle returned by `P1Channel.openStream`. Mirrors `RemoteStream`'s surface so
/// `LinkService+Streams` can be wired over the P1 transport without rewriting the
/// stream consumers.
@MainActor
final class P1StreamHandle {
    let descriptor: P1StreamDescriptor
    private weak var channel: P1Channel?

    var streamId: String { descriptor.streamId }
    var endpoint: String { descriptor.endpoint }
    var args: [String: JSONValue] { descriptor.args }

 /// False after the stream ended/was cancelled, or after an epoch reset
 /// invalidated the previous channel epoch's streams.
    var isOpen: Bool { channel?.isStreamOpen(streamId) ?? false }

    init(descriptor: P1StreamDescriptor, channel: P1Channel) {
        self.descriptor = descriptor
        self.channel = channel
    }

 /// Uplink one item (`nil` value == field omitted, like `RemoteStream.send`).
    func sendItem(_ value: JSONValue? = nil) throws {
        guard let channel else { throw P1Failure.notConnected }
        try channel.sendStreamItem(streamId: streamId, value: value)
    }

 /// Half-close the uplink side (`end` frame); downlink frames may still arrive.
    func end() {
        channel?.endStream(streamId: streamId)
    }

 /// Cancel the stream: drops the local handle and best-effort sends `cancel`.
    func cancel() {
        channel?.cancelStream(streamId: streamId)
    }
}

// MARK: - Channel

/// Where inbound frame JSON is parsed.
///
/// Production uses `offMain`: one `session/page` result can be megabytes of
/// JSON and parsing it on the main actor starved touch delivery during the
/// detail-view history fill. Unit tests that assert
/// synchronous frame application use `inline` — same application logic, same
/// wire order, no thread hop.
enum P1InboundDecoding: Equatable {
 /// Parse on the main actor (deterministic for unit tests; handshake-size
 /// frames only).
    case inline
 /// Parse on a background serial lane, then apply on the main actor in wire
 /// order (production).
    case offMain
}

/// The single-connection dsh-m/2 transport core.
///
/// Responsibilities (design §5): hello/welcome handshake, unary correlation by
/// `id` (concurrent, out-of-order completion), stream dispatch by `streamId`,
/// downstream `sid` bookkeeping for lossless `resume`, and close-code →
/// `P1Failure` mapping. It does not know about DSH business endpoints; the caller
/// passes the raw `client-request` args and consumes `P1RPCResult` / stream
/// callbacks exactly as the legacy path does.
///
/// Threading: main actor only. Callbacks fire in wire order.
@MainActor
final class P1Channel {
    typealias SocketFactory = @MainActor () throws -> P1Socket

    let clientInfo: P1ClientInfo
    let helloTimeout: TimeInterval
    let maxFrameBytes: Int

    private let socketFactory: SocketFactory
    private var socket: P1Socket?

    private(set) var state: P1ChannelState = .idle
 /// Last handshake result (nil before the first successful welcome).
    private(set) var welcome: P1Welcome?
 /// link-perf L3a：本次 welcome 是否协商了下行 gzip（binary 收帧
 /// 判定与诊断取证共用）。
    var gzipNegotiated: Bool { welcome?.caps.gzip == true }
 /// Server channel epoch; changes force the caller to re-open every stream.
    private(set) var epoch: String?
 /// Last downstream `sid` this channel actually applied (resume cursor).
    private(set) var lastAppliedSid: Int64 = 0
 /// `welcome.resume` of the most recent handshake (fresh/replay/reset).
    private(set) var welcomeResume: P1ResumeInfo?
 /// Failure that ended the last socket (nil while connecting/ready).
    private(set) var lastFailure: P1Failure?
 /// Invoked once per unexpected socket loss AND once per protocol violation
 /// after the channel was ready. Not invoked for explicit `disconnect()`.
    var onClose: ((P1Failure) -> Void)?

    private var welcomeContinuation: CheckedContinuation<P1Welcome, Error>?
    private var helloTimeoutTask: Task<Void, Never>?
    private var inboundBeforeWelcome: [String] = []
    private var hasWelcomed = false

 /// Frame decode lane; see `P1InboundDecoding`.
    private let inboundDecoding: P1InboundDecoding

    private var pendingRPC: [String: CheckedContinuation<P1RPCResult, Error>] = [:]
    private var rpcTimeoutTasks: [String: Task<Void, Never>] = [:]

    private var streams: [String: P1Stream] = [:]
    private var streamDescriptors: [P1StreamDescriptor] = []
 /// `welcome.sid` targeted by an active `mode=replay` window (nil otherwise).
    private var replayTargetSid: Int64?

    init(
        socketFactory: @escaping SocketFactory,
        clientInfo: P1ClientInfo = .dshm,
        helloTimeout: TimeInterval = P1ProtocolLimits.helloTimeout,
        maxFrameBytes: Int = P1ProtocolLimits.maxFrameBytes,
        inboundDecoding: P1InboundDecoding = .offMain
    ) {
        self.socketFactory = socketFactory
        self.clientInfo = clientInfo
        self.helloTimeout = helloTimeout
        self.maxFrameBytes = maxFrameBytes
        self.inboundDecoding = inboundDecoding
    }

 /// Production wiring: one pinned WSS to `host:port` per `connect`.
    convenience init(
        host: String,
        port: UInt16,
        leafPin: String,
        caCertBase64: String? = nil,
        path: String = P1Proto.socketPath,
        headers: [String: String] = [:],
        connectTimeout: TimeInterval = PinnedTLS.defaultConnectTimeout,
        clientInfo: P1ClientInfo = .dshm,
        helloTimeout: TimeInterval = P1ProtocolLimits.helloTimeout
    ) {
        self.init(
            socketFactory: {
                P1WSSocket(host: host, port: port, path: path, headers: headers, leafPin: leafPin, caCertBase64: caCertBase64, connectTimeout: connectTimeout)
            },
            clientInfo: clientInfo,
            helloTimeout: helloTimeout
        )
    }

 // MARK: Introspection

    var isReady: Bool { state == .ready }

 /// True while live stream handlers are still registered. A socket loss keeps
 /// them (for `hello{resume}` replay); an epoch reset/fresh welcome or
 /// `discardAllStreams` clears them after notifying their `onClose`.
    var hasLiveStreams: Bool { !streams.isEmpty }

 /// Frames/bytes applied during the current replay window (design §7.3
 /// `resumeReplayedFrames`/`resumeReplayedBytes`). Reset on every `connect`.
    private(set) var replayStats = P1ReplayStats(frames: 0, bytes: 0)

 /// Invoked once when the replay window closes (every missing `down` frame up
 /// to `welcome.sid` has been applied). Not invoked when the window is cut
 /// short by another socket loss.
    var onReplayWindowClosed: ((P1ReplayStats) -> Void)?

 /// Cursor to persist and send as `hello.resume` on the next connection.
    var resumeState: P1ResumeCursor? {
        guard let epoch else { return nil }
        return P1ResumeCursor(logEpoch: epoch, sid: lastAppliedSid)
    }

 /// Streams the caller may need to re-open after a socket loss or epoch reset
 /// (descriptors survive `P1ResumeInfo.Mode.reset`; handles are invalidated).
    var openStreams: [P1StreamDescriptor] { streamDescriptors }

    func isStreamOpen(_ streamId: String) -> Bool { streams[streamId] != nil }

 // MARK: Connect / handshake

 /// Opens the socket and performs the `hello` → `welcome` handshake.
 ///
 /// - Parameters:
 /// - auth: in-band credential (resume ticket preferred, mux token fallback).
 /// - resume: cursor from a previous epoch; when the plugin accepts it the
 /// missing `down` frames arrive right after the welcome (still inside this
 /// async call's frame delivery) and `lastAppliedSid` advances to the
 /// server's current `sid`.
 /// - Returns: the parsed welcome.
 /// - Throws: `P1Failure` (close code mapping, hello timeout, protocol
 /// violation) or the underlying transport error from `P1Socket.connect`.
    @discardableResult
    func connect(auth: P1Auth, resume: P1ResumeCursor? = nil) async throws -> P1Welcome {
        guard state == .idle || state == .closed else {
            throw P1Failure.protocolViolation("连接状态非法: \(state)")
        }
 // Validate (and serialize) hello before touching the network.
        let helloText = try P1FrameCodec.encodeText(
            .hello(P1Hello(client: clientInfo, auth: auth, resume: resume)),
            maxBytes: maxFrameBytes
        )
        if let resume {
 // Adopt the caller's cursor until the welcome overrides it (reset → 0).
            epoch = resume.logEpoch
            lastAppliedSid = resume.sid
        }
        welcome = nil
        welcomeResume = nil
        lastFailure = nil
        hasWelcomed = false
        inboundBeforeWelcome.removeAll()
        replayStats = P1ReplayStats()
        replayTargetSid = nil
        state = .connecting

        let socket: P1Socket
        do {
            socket = try socketFactory()
        } catch {
            state = .closed
            let failure = P1Failure.socketClosed(
                code: P1CloseCode.abnormalClosure.rawValue,
                reason: NetworkErrorInterpreter.message(for: error)
            )
            lastFailure = failure
            throw failure
        }
        self.socket = socket
        socket.onText = { [weak self] text in
            guard let self, self.socket === socket else { return }
            self.handleText(text)
        }
        socket.onBinary = { [weak self] data in
            guard let self, self.socket === socket else { return }
            self.handleBinary(data)
        }
        socket.onClose = { [weak self] close in
            guard let self, self.socket === socket else { return }
            self.handleSocketClose(close)
        }

        do {
            try await socket.connect()
        } catch {
            if self.socket === socket { self.socket = nil }
            state = .closed
            lastFailure = P1Failure.socketClosed(
                code: P1CloseCode.abnormalClosure.rawValue,
                reason: NetworkErrorInterpreter.message(for: error)
            )
            throw error
        }
        guard self.socket === socket else {
            throw P1Failure.cancelled
        }
        return try await awaitWelcome(sending: helloText)
    }

 /// Closes the socket and fails any in-flight work with `.cancelled`.
 /// Does not fire `onClose` (the caller initiated the teardown).
    func disconnect(reason: String = "client closed") {
        guard state != .idle else { return }
        let close = socket
        socket = nil
        state = .closed
        hasWelcomed = false
        helloTimeoutTask?.cancel()
        helloTimeoutTask = nil
        close?.close(code: P1CloseCode.normalClosure.rawValue, reason: reason)
        if let continuation = welcomeContinuation {
            welcomeContinuation = nil
            continuation.resume(throwing: P1Failure.cancelled)
        }
        failPending(.cancelled)
    }

 /// Drops the stream table (live handles plus the re-open descriptors).
 /// Use when leaving dsh-m/2 (legacy fallback) or after a permanent reset.
 ///
 /// Live handles get their `onClose` exactly once here (legacy `RemoteMux`
 /// parity); the table is emptied before the callbacks run so a handler that
 /// calls `cancel()` cannot re-trigger anything.
    func discardAllStreams(
        reason: String = "dsh-m/2 流表已丢弃",
        closeCode: Int = P1CloseCode.abnormalClosure.rawValue
    ) {
        let dropped = streams
        streams.removeAll()
        streamDescriptors.removeAll()
        replayTargetSid = nil
        for stream in dropped.values {
            stream.onClose?(closeCode, reason)
        }
    }

    private func awaitWelcome(sending helloText: String) async throws -> P1Welcome {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.welcomeContinuation = continuation
                self.startHelloTimeout()
 // Frames delivered synchronously between `connect()` returning and
 // this continuation being installed are buffered, not lost.
                self.flushInboundBeforeWelcome()
                guard self.welcomeContinuation != nil, self.state == .connecting else { return }
                do {
                    try self.sendRaw(helloText)
                } catch {
                    self.welcomeContinuation = nil
                    self.helloTimeoutTask?.cancel()
                    self.helloTimeoutTask = nil
                    let close = self.socket
                    self.socket = nil
                    self.state = .closed
                    let failure = P1Failure.socketClosed(
                        code: P1CloseCode.abnormalClosure.rawValue,
                        reason: "hello 发送失败"
                    )
                    self.lastFailure = failure
                    close?.close(code: P1CloseCode.normalClosure.rawValue, reason: "hello send failed")
                    continuation.resume(throwing: failure)
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.abortConnecting(.cancelled, closeCode: P1CloseCode.normalClosure.rawValue)
            }
        })
    }

    private func startHelloTimeout() {
        helloTimeoutTask?.cancel()
        guard helloTimeout > 0 else { return }
        let interval = helloTimeout
        helloTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.abortConnecting(
                .timeout("等待 welcome（hello 超时）"),
                closeCode: P1CloseCode.helloRequired.rawValue
            )
        }
    }

    private func flushInboundBeforeWelcome() {
        guard !inboundBeforeWelcome.isEmpty else { return }
        let buffered = inboundBeforeWelcome
        inboundBeforeWelcome.removeAll()
        for text in buffered {
            decodeAndHandleInline(text)
            if welcomeContinuation == nil { return }
        }
    }

 /// Fails a handshake that has not produced a welcome yet (timeout/cancel).
    private func abortConnecting(_ failure: P1Failure, closeCode: Int) {
        guard state == .connecting else { return }
        helloTimeoutTask?.cancel()
        helloTimeoutTask = nil
        let close = socket
        socket = nil
        state = .closed
        lastFailure = failure
        close?.close(code: closeCode, reason: failure.userMessage)
        let continuation = welcomeContinuation
        welcomeContinuation = nil
        continuation?.resume(throwing: failure)
        failPending(failure)
    }

 // MARK: Uplink

    private func sendRaw(_ text: String) throws {
        guard let socket else { throw P1Failure.notConnected }
        do {
            try socket.send(text: text)
        } catch {
            throw P1Failure.notConnected
        }
    }

    private func sendText(_ text: String) throws {
        guard state == .ready else { throw P1Failure.notConnected }
        try sendRaw(text)
    }

 /// Sends one unary call and awaits its correlated result.
 ///
 /// Late responses (after timeout/cancel) are dropped silently, which is what
 /// the plugin expects (it does not cache unary results either, design §3.4).
    func unary(
        endpoint: String,
        args: [String: JSONValue] = [:],
        timeout: TimeInterval = 30
    ) async throws -> P1RPCResult {
        guard state == .ready, socket != nil else { throw P1Failure.notConnected }
        let id = UUID().uuidString.lowercased()
        let text = try P1FrameCodec.encodeText(
            .rpc(P1RPCCall(id: id, endpoint: endpoint, args: args)),
            maxBytes: maxFrameBytes
        )
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.pendingRPC[id] = continuation
                do {
                    try self.sendText(text)
                } catch {
                    self.pendingRPC.removeValue(forKey: id)
                    continuation.resume(throwing: P1Failure.notConnected)
                    return
                }
                let interval = max(0.001, timeout)
                self.rpcTimeoutTasks[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.timeOutRPC(id)
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRPC(id)
            }
        })
    }

 /// Opens a logical stream. Returns a handle; server frames are dispatched to
 /// the callbacks in wire order.
 ///
 /// `onClose` mirrors the legacy `RemoteMux` surface: it fires only when the
 /// stream is dropped without a protocol `end`/`error` (epoch reset/fresh
 /// welcome, hard channel teardown). A plain socket loss deliberately does NOT
 /// fire it so the stream can be continued by `hello{resume}` replay.
    @discardableResult
    func openStream(
        streamId: String = UUID().uuidString.lowercased(),
        endpoint: String,
        args: [String: JSONValue] = [:],
        onItem: ((JSONValue?) -> Void)? = nil,
        onEnd: (() -> Void)? = nil,
        onError: ((RemoteError) -> Void)? = nil,
        onClose: ((Int, String) -> Void)? = nil
    ) throws -> P1StreamHandle {
        guard state == .ready, socket != nil else { throw P1Failure.notConnected }
        guard streams[streamId] == nil else {
            throw P1ProtocolError.violation("streamId 重复: \(streamId)")
        }
        guard !streamId.isEmpty else {
            throw P1ProtocolError.violation("streamId 不能为空")
        }
        let text = try P1FrameCodec.encodeText(
            .mux(.open(streamId: streamId, endpoint: endpoint, args: args)),
            maxBytes: maxFrameBytes
        )
        let descriptor = P1StreamDescriptor(streamId: streamId, endpoint: endpoint, args: args)
        let stream = P1Stream(
            descriptor: descriptor,
            onItem: onItem,
            onEnd: onEnd,
            onError: onError,
            onClose: onClose
        )
        streams[streamId] = stream
        upsertDescriptor(descriptor)
        do {
            try sendText(text)
        } catch {
            streams.removeValue(forKey: streamId)
            removeDescriptor(streamId)
            throw P1Failure.notConnected
        }
        return P1StreamHandle(descriptor: descriptor, channel: self)
    }

 // MARK: Stream uplink (handle plumbing)

    fileprivate func sendStreamItem(streamId: String, value: JSONValue?) throws {
        guard streams[streamId] != nil else { throw P1Failure.notConnected }
        let text = try P1FrameCodec.encodeText(
            .mux(.item(streamId: streamId, value: value)),
            maxBytes: maxFrameBytes
        )
        try sendText(text)
    }

 /// Uplink half-close: the stream stays registered (downlink may continue).
    fileprivate func endStream(streamId: String) {
        guard streams[streamId] != nil else { return }
        guard let text = try? P1FrameCodec.encodeText(.mux(.end(streamId: streamId)), maxBytes: maxFrameBytes) else { return }
        try? sendText(text)
    }

    fileprivate func cancelStream(streamId: String) {
        guard streams.removeValue(forKey: streamId) != nil else { return }
        removeDescriptor(streamId)
        guard let text = try? P1FrameCodec.encodeText(.mux(.cancel(streamId: streamId)), maxBytes: maxFrameBytes) else { return }
        try? sendText(text)
    }

 // MARK: Inbound dispatch

 /// Serial lane for inbound frame decoding.
 ///
 /// Why off-main (device report: on entering a session detail the
 /// page froze — the list would not scroll and the header back button would
 /// not respond — until the top 2pt history-fill progress bar finished):
 /// one `session/page` rpc/result carries the whole history page (measured
 /// 1.4 MB of JSON per page on a real long session, 8 pages per fill), and
 /// `P1FrameCodec.decodeServerFrame` parses all of it. That parse used to
 /// run on the main actor for every page, back-to-back with no gap, so the
 /// main thread never got a free slot between pages and touch delivery (pan
 /// + header button) starved for the whole fill. Decoding here keeps the
 /// main actor free; frames are decoded in wire order on this serial queue
 /// and handed back to the main actor in the same order (serial queue +
 /// `DispatchQueue.main.async` FIFO).
    private static let inboundDecodeQueue = DispatchQueue(
        label: "com.dshm.p1.inbound-decode",
        qos: .userInitiated
    )

    private func handleText(_ text: String) {
        if state == .connecting && welcomeContinuation == nil {
 // Not expected from a real transport (see `P1Socket`), but keep the
 // handshake robust: buffer and flush once the continuation is installed.
            guard inboundBeforeWelcome.count < 8 else {
                violate(P1ProtocolError.violation("welcome 前收到过多帧"))
                return
            }
            inboundBeforeWelcome.append(text)
            return
        }
        guard state == .connecting || state == .ready else { return }
        decodeInboundLane { text }
    }

 /// link-perf L3a：binary 下行帧（gzip 协商成功后的压缩载荷）。
 /// 未协商（welcome.caps.gzip!= true，含 welcome 未到）却收到 binary =
 /// 协议违规——这是「新 App × 旧插件」错配窗口的安全网（设计 §3-L1 兼容
 /// 矩阵第三行），走既有 violate 路径关连接，上层 useLegacy 会话级回退。
    private func handleBinary(_ data: Data) {
        guard gzipNegotiated else {
            violate(P1ProtocolError.violation("未协商 gzip 却收到 binary 帧"))
            return
        }
        guard state == .connecting || state == .ready else { return }
        decodeInboundLane { try P1FrameCodec.inflateBinaryFrame(data) }
    }

 /// Inbound decode lane shared by text frames and (gzip-negotiated) binary
 /// frames. `produceText` runs ON the decode lane
 /// (identity for text; `[0x01][gzip]` → JSON text for binary), so one lane
 /// task per wire frame keeps main-actor application in wire order (serial
 /// queue + FIFO `main.async`) — a binary frame must NOT re-enter
 /// `handleText` from the lane, or the following text frame could overtake it.
    private func decodeInboundLane(_ produceText: @escaping @Sendable () throws -> String) {
        guard inboundDecoding == .offMain else {
            let text: String
            do {
                text = try produceText()
            } catch {
                violate(error)
                return
            }
            decodeAndHandleInline(text)
            return
        }
        guard let source = socket else { return }
        let maxBytes = maxFrameBytes
        Self.inboundDecodeQueue.async { [weak self] in
            var rawText: String?
            var decoded: Result<P1ServerFrame, P1ProtocolError>
            do {
                let text = try produceText()
                rawText = text
                #if DEBUG
 // Device evidence hook (`DSHM_PERFDBG=1`): confirms the history
 // page decode really runs off the main actor and how long one
 // page takes on the phone.
                decoded = .success(try PerfProbe.shared.measure(
                    "p1FrameDecodeBG",
                    ["bytes": text.utf8.count]
                ) {
                    try P1FrameCodec.decodeServerFrame(text, maxBytes: maxBytes)
                })
                #else
                decoded = .success(try P1FrameCodec.decodeServerFrame(text, maxBytes: maxBytes))
                #endif
            } catch let error as P1ProtocolError {
                decoded = .failure(error)
            } catch {
                decoded = .failure(.violation(error.localizedDescription))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated {
 // The socket may have been replaced (reconnect) while the
 // frame was decoded off-main: a stale frame must never be
 // applied to the new connection's sid bookkeeping.
                    guard self.socket === source else { return }
                    guard self.state == .connecting || self.state == .ready else { return }
                    switch decoded {
                    case .success(let frame):
 // Success implies produceText() completed and rawText was set.
                        self.applyFrame(frame, rawText: rawText ?? "")
                    case .failure(let error):
                        self.violate(error)
                    }
                }
            }
        }
    }

 /// Synchronous decode for the pre-welcome buffer flush.
 ///
 /// `awaitWelcome` depends on the flush having delivered a buffered welcome
 /// by the time it returns (otherwise it would send `hello` again). Frames
 /// that can land before the welcome continuation exists are tiny handshake
 /// frames — never a history page — so decoding them inline cannot block the
 /// main thread.
    private func decodeAndHandleInline(_ text: String) {
        let frame: P1ServerFrame
        do {
            frame = try P1FrameCodec.decodeServerFrame(text, maxBytes: maxFrameBytes)
        } catch {
            violate(error)
            return
        }
        applyFrame(frame, rawText: text)
    }

 /// Main-actor half of the inbound path: applies one decoded frame.
    private func applyFrame(_ frame: P1ServerFrame, rawText: String) {
        switch frame {
        case .welcome(let welcome):
            handleWelcome(welcome)
        case .down(let envelope):
            do {
                let advanced = try applyDown(envelope)
                if advanced { recordReplayFrame(rawText) }
            } catch {
                violate(error)
            }
        case .rpcResult(let result):
            resolveRPC(result)
        case .rpcError(let errorFrame):
            rejectRPC(errorFrame)
        case .pong:
            break
        }
    }

    private func handleWelcome(_ welcome: P1Welcome) {
        guard state == .connecting, self.welcome == nil else {
            violate(P1ProtocolError.violation("非预期 welcome（状态 \(state)）"))
            return
        }
        helloTimeoutTask?.cancel()
        helloTimeoutTask = nil
        self.welcome = welcome
        epoch = welcome.epoch
        welcomeResume = welcome.resume
        switch welcome.resume.mode {
        case .replay:
 // Cursor accepted: replay frames follow with their original sids.
            if lastAppliedSid > welcome.sid { lastAppliedSid = welcome.sid }
            replayStats = P1ReplayStats()
            if welcome.sid > lastAppliedSid {
                replayTargetSid = welcome.sid
            } else {
 // Nothing was missed (or the cursor already covers welcome.sid).
                replayTargetSid = nil
                onReplayWindowClosed?(replayStats)
            }
        case .fresh, .reset:
 // New epoch (or first connection): sid restarts at 0 and the plugin
 // has cancelled the old epoch's upstream streams. Notify the live
 // handles (legacy `RemoteMux` parity) so the business layer can nil
 // its references before the generation bump re-opens them; the
 // descriptors stay for the caller's own bookkeeping.
            let why = welcome.resume.reason.map { "（\($0)）" } ?? ""
            lastAppliedSid = 0
            replayTargetSid = nil
            closeLiveStreams(
                code: P1CloseCode.abnormalClosure.rawValue,
                reason: "dsh-m/2 通道\(welcome.resume.mode == .reset ? "重置" : "新建")\(why)"
            )
        }
        state = .ready
        hasWelcomed = true
        let continuation = welcomeContinuation
        welcomeContinuation = nil
        continuation?.resume(returning: welcome)
    }

 /// Applies one downstream frame. Returns true when the frame advanced the
 /// applied `sid` (duplicates/replay overlap return false and are not counted
 /// as replayed frames).
    @discardableResult
    private func applyDown(_ envelope: P1DownEnvelope) throws -> Bool {
        guard state == .ready else {
            throw P1ProtocolError.violation("welcome 之前收到 down 帧")
        }
        if envelope.sid <= lastAppliedSid {
 // Replay overlap / duplicate: already rendered, keep idempotent.
            return false
        }
        guard envelope.sid == lastAppliedSid + 1 else {
            throw P1ProtocolError.violation("down 序号缺口：期望 \(lastAppliedSid + 1)，收到 \(envelope.sid)")
        }
        lastAppliedSid = envelope.sid
        guard let type = envelope.frameType, let streamId = envelope.streamId else { return true }
        switch type {
        case "item":
            streams[streamId]?.onItem?(envelope.value)
        case "end":
            guard let stream = streams.removeValue(forKey: streamId) else { return true }
            removeDescriptor(streamId)
            stream.onEnd?()
        case "error":
            guard let stream = streams.removeValue(forKey: streamId) else { return true }
            removeDescriptor(streamId)
            stream.onError?(envelope.error ?? RemoteError(code: "unknown", message: "stream error"))
        default:
 // `open`/`cancel`/unknown upstream frames carry no App action here.
            break
        }
        return true
    }

 /// Counts one applied `down` frame while the replay window is open and closes
 /// the window once the server's `welcome.sid` has been reached.
    private func recordReplayFrame(_ text: String) {
        guard let target = replayTargetSid else { return }
        replayStats.frames += 1
        replayStats.bytes += text.utf8.count
        guard lastAppliedSid >= target else { return }
        replayTargetSid = nil
        onReplayWindowClosed?(replayStats)
    }

 /// Drops the live stream handlers after an epoch reset/fresh welcome, firing
 /// each `onClose` exactly once (legacy `RemoteMux.handleSocketClosed` parity).
    private func closeLiveStreams(code: Int, reason: String) {
        let dropped = streams
        streams.removeAll()
        replayTargetSid = nil
        for stream in dropped.values {
            stream.onClose?(code, reason)
        }
    }

    private func resolveRPC(_ result: P1RPCResult) {
        guard let continuation = takePending(result.id) else { return }
        continuation.resume(returning: result)
    }

    private func rejectRPC(_ frame: P1RPCErrorFrame) {
        guard let continuation = takePending(frame.id) else { return }
        continuation.resume(throwing: P1Failure.rpcError(id: frame.id, error: frame.error))
    }

    private func timeOutRPC(_ id: String) {
        guard let continuation = takePending(id) else { return }
        continuation.resume(throwing: P1Failure.timeout("rpc"))
    }

    private func cancelRPC(_ id: String) {
        guard let continuation = takePending(id) else { return }
        continuation.resume(throwing: P1Failure.cancelled)
    }

    private func takePending(_ id: String) -> CheckedContinuation<P1RPCResult, Error>? {
        rpcTimeoutTasks[id]?.cancel()
        rpcTimeoutTasks.removeValue(forKey: id)
        return pendingRPC.removeValue(forKey: id)
    }

    private func failPending(_ failure: P1Failure) {
        let continuations = Array(pendingRPC.values)
        pendingRPC.removeAll()
        for task in rpcTimeoutTasks.values { task.cancel() }
        rpcTimeoutTasks.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: failure)
        }
    }

 // MARK: Socket close / protocol violation

    private func handleSocketClose(_ close: P1SocketClose) {
        let failure = P1Failure.close(code: close.code, reason: close.reason)
        socket = nil
        state = .closed
        lastFailure = failure
 // Keep `streams`/descriptors: this is the resume state (design §5
 // RESUMING). Only stop counting a replay window that was cut short.
        replayTargetSid = nil
        helloTimeoutTask?.cancel()
        helloTimeoutTask = nil
        if let continuation = welcomeContinuation {
            welcomeContinuation = nil
            continuation.resume(throwing: failure)
            failPending(failure)
            return
        }
        failPending(failure)
        if hasWelcomed {
            hasWelcomed = false
            onClose?(failure)
        }
    }

 /// Fails the current connection because the peer violated the protocol
 /// (malformed/unknown frame, oversized message, downstream sid gap...).
    private func violate(_ error: Error) {
        let failure: P1Failure
        let closeCode: Int
        if let protocolError = error as? P1ProtocolError, protocolError.isFrameTooLarge {
            failure = .frameTooLarge(reason: protocolError.localizedDescription)
            closeCode = P1CloseCode.frameTooLarge.rawValue
        } else {
            failure = .protocolViolation(error.localizedDescription)
            closeCode = 1002 // WS protocol error: we cannot trust this connection's stream.
        }
        guard state == .connecting || state == .ready else { return }
        let close = socket
        socket = nil
        state = .closed
        lastFailure = failure
        helloTimeoutTask?.cancel()
        helloTimeoutTask = nil
        close?.close(code: closeCode, reason: failure.userMessage)
        if let continuation = welcomeContinuation {
            welcomeContinuation = nil
            continuation.resume(throwing: failure)
            failPending(failure)
            return
        }
        failPending(failure)
        if hasWelcomed {
            hasWelcomed = false
            onClose?(failure)
        }
    }

 // MARK: Stream descriptors

    private func upsertDescriptor(_ descriptor: P1StreamDescriptor) {
        if let index = streamDescriptors.firstIndex(where: { $0.streamId == descriptor.streamId }) {
            streamDescriptors[index] = descriptor
        } else {
            streamDescriptors.append(descriptor)
        }
    }

    private func removeDescriptor(_ streamId: String) {
        streamDescriptors.removeAll { $0.streamId == streamId }
    }
}

// MARK: - Internal stream record

private final class P1Stream {
    let descriptor: P1StreamDescriptor
    let onItem: ((JSONValue?) -> Void)?
    let onEnd: (() -> Void)?
    let onError: ((RemoteError) -> Void)?
 /// Legacy `RemoteMux` parity: fired when a live stream is dropped without a
 /// protocol `end`/`error` (epoch reset/fresh welcome, hard channel teardown).
 /// NOT fired on a plain socket loss: those streams stay registered so the
 /// next `hello{resume}` replay can continue them (design §5 RESUMING).
    let onClose: ((Int, String) -> Void)?

    init(
        descriptor: P1StreamDescriptor,
        onItem: ((JSONValue?) -> Void)?,
        onEnd: (() -> Void)?,
        onError: ((RemoteError) -> Void)?,
        onClose: ((Int, String) -> Void)?
    ) {
        self.descriptor = descriptor
        self.onItem = onItem
        self.onEnd = onEnd
        self.onError = onError
        self.onClose = onClose
    }
}
