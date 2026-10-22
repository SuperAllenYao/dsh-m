import CryptoKit
import Foundation
import Network

/// Cancellable one-shot deadline for the WebSocket upgrade handshake.
///
/// History: the deadline used to be an un-cancelled `queue.asyncAfter` block, so
/// it tore down a *healthy* socket `timeout` seconds after connect (isolated E2E:
/// `conn.closed code=1006` every ~8s — one per candidate `attemptTimeout`, no new
/// logical channel, resume reattach every cycle). `WSSClient` cancels it as soon
/// as the 101 upgrade completes; this type keeps the schedule/cancel semantics
/// unit-testable without a real `NWConnection`.
final class WSSConnectTimeout: @unchecked Sendable {
    private let lock = NSLock()
    private var item: DispatchWorkItem?

    /// Arms the deadline (replacing any previous one). `fire` runs at most once
    /// and only when `cancel()` was not called first.
    func arm(on queue: DispatchQueue, after seconds: TimeInterval, fire: @escaping @Sendable () -> Void) {
        let item = DispatchWorkItem(block: fire)
        lock.lock()
        let previous = self.item
        self.item = item
        lock.unlock()
        previous?.cancel()
        queue.asyncAfter(deadline: .now() + max(0, seconds), execute: item)
    }

    /// Disarms the deadline; idempotent and callable from any thread.
    func cancel() {
        lock.lock()
        let item = self.item
        self.item = nil
        lock.unlock()
        item?.cancel()
    }
}

/// Minimal RFC 6455 WebSocket client over Network.framework TLS.
///
/// The DSH mux needs an `authorization` header on the upgrade request and a
/// leaf-fingerprint pin on the TLS handshake; NWProtocolWebSocket offers neither,
/// so the upgrade handshake and frame codec are implemented here.
final class WSSClient: @unchecked Sendable {
    enum Event {
        case opened
        case text(String)
        case pong
        case closed(code: Int, reason: String)
        case failed(Error)
    }

    private let host: String
    private let port: UInt16
    private let path: String
    private let extraHeaders: [String: String]
    private let leafPin: String

    private let queue = DispatchQueue(label: "com.dshm.ws-client")
    private let pinCapture = PinCapture()
    /// v0.1.1 C: pinned CA certificate (base64 DER) from the pairing payload /
    /// credential. When present the handshake accepts any leaf chaining to it,
    /// so a re-issued leaf needs no re-pair; `leafPin` remains the fallback.
    private let caCertBase64: String?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var handshakeDone = false
    private var finished = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var pingTimer: DispatchSourceTimer?
    private var pingSentAt: Date?
    /// Cancelled as soon as the 101 upgrade completes (see `WSSConnectTimeout`).
    private let connectTimeout = WSSConnectTimeout()
    private var fragmentedOpcode: UInt8?
    private var fragments: [Data] = []

    /// Invoked on the main queue.
    var onEvent: (@MainActor (Event) -> Void)?

    init(host: String, port: UInt16, path: String, headers: [String: String], leafPin: String, caCertBase64: String? = nil) {
        self.host = host
        self.port = port
        self.path = path
        self.extraHeaders = headers
        self.leafPin = leafPin
        self.caCertBase64 = caCertBase64
    }

    // MARK: - Connect

    func connect(timeout: TimeInterval = 15) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            queue.async { self.start(timeout: timeout) }
        }
    }

    private func start(timeout: TimeInterval) {
        let parameters = PinnedTLS.parameters(leafPin: leafPin, caCertBase64: caCertBase64, capture: pinCapture, connectTimeout: min(timeout, 15))
        let hostPort = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 443)
        let connection = NWConnection(to: hostPort, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendHandshake()
            case .failed(let error):
                self.fail(LinkError.transport("mux 连接 \(self.host):\(self.port) 失败：" + NetworkErrorInterpreter.message(for: error)))
            case .cancelled:
                self.fail(LinkError.cancelled)
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Must be disarmed by `processHandshake()`: otherwise this deadline kills
        // a healthy socket `timeout` seconds after a successful upgrade.
        connectTimeout.arm(on: queue, after: timeout) { [weak self] in
            self?.fail(LinkError.timeout("mux 升级"))
        }
    }

    private func sendHandshake() {
        var keyBytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<16 { keyBytes[index] = UInt8.random(in: 0...255) }
        let key = Data(keyBytes).base64EncodedString()
        self.webSocketKey = key
        var lines: [String] = []
        lines.append("GET \(path) HTTP/1.1")
        lines.append("Host: \(host):\(port)")
        lines.append("Upgrade: websocket")
        lines.append("Connection: Upgrade")
        lines.append("Sec-WebSocket-Key: \(key)")
        lines.append("Sec-WebSocket-Version: 13")
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        connection?.send(content: request, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.fail(LinkError.transport("mux 升级请求发送失败：" + NetworkErrorInterpreter.message(for: error)))
            } else {
                self.receiveLoop()
            }
        })
    }

    private var webSocketKey: String = ""

    // MARK: - Receive loop

    private func receiveLoop() {
        guard !finished else { return }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                if self.handshakeDone {
                    self.processFrames()
                } else {
                    self.processHandshake()
                }
            }
            if let error {
                self.fail(LinkError.transport("mux 接收失败：" + NetworkErrorInterpreter.message(for: error)))
                return
            }
            if isComplete {
                self.handleTransportClosed()
                return
            }
            self.receiveLoop()
        }
    }

    private func processHandshake() {
        guard let range = receiveBuffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headerData = receiveBuffer.subdata(in: 0..<range.lowerBound)
        receiveBuffer.removeSubrange(0..<range.upperBound)
        let text = String(data: headerData, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            fail(LinkError.malformedEnvelope("mux 升级响应为空"))
            return
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            fail(LinkError.malformedEnvelope("mux 升级响应状态行非法: \(statusLine)"))
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        guard status == 101 else {
            fail(LinkError.httpStatus(status, "mux 升级被拒绝"))
            return
        }
        let expectedAccept = Data(Insecure.SHA1.hash(data: Data((webSocketKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        if let accept = headers["sec-websocket-accept"], accept != expectedAccept {
            fail(LinkError.malformedEnvelope("Sec-WebSocket-Accept 不匹配"))
            return
        }
        handshakeDone = true
        resumeConnectSuccess()
        startPingTimer()
        if !receiveBuffer.isEmpty {
            processFrames()
        }
    }

    private func resumeConnectSuccess() {
        // The upgrade is done: the remaining handshake deadline must not tear the
        // live socket down later (root cause of the E2E 8s 1006 close loop).
        connectTimeout.cancel()
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
        emit(.opened)
    }

    private func processFrames() {
        while !finished {
            do {
                guard let frame = try WSFrameCodec.decode(from: &receiveBuffer) else { return }
                handleFrame(frame)
            } catch {
                fail(error)
                return
            }
        }
    }

    private func handleFrame(_ frame: WSFrame) {
        switch frame.opcode {
        case WSOpcode.text:
            if frame.fin {
                fragmentedOpcode = nil
                fragments = []
                if let text = String(data: frame.payload, encoding: .utf8) {
                    emit(.text(text))
                }
            } else {
                fragmentedOpcode = WSOpcode.text
                fragments = [frame.payload]
            }
        case WSOpcode.continuation:
            guard fragmentedOpcode != nil else {
                fail(WSFrameCodec.CodecError.protocolViolation("continuation without text frame"))
                return
            }
            fragments.append(frame.payload)
            if frame.fin {
                let payload = fragments.reduce(into: Data()) { $0.append($1) }
                fragments = []
                fragmentedOpcode = nil
                if let text = String(data: payload, encoding: .utf8) {
                    emit(.text(text))
                }
            }
        case WSOpcode.binary:
            fail(WSFrameCodec.CodecError.protocolViolation("binary frame not allowed"))
        case WSOpcode.ping:
            sendControlFrame(opcode: WSOpcode.pong, payload: frame.payload)
        case WSOpcode.pong:
            pingSentAt = nil
            emit(.pong)
        case WSOpcode.close:
            var code = 1000
            var reason = ""
            if frame.payload.count >= 2 {
                let bytes = [UInt8](frame.payload)
                code = Int(bytes[0]) << 8 | Int(bytes[1])
                if frame.payload.count > 2 {
                    reason = String(data: frame.payload.subdata(in: 2..<frame.payload.count), encoding: .utf8) ?? ""
                }
            }
            sendControlFrame(opcode: WSOpcode.close, payload: frame.payload)
            finishClosed(code: code, reason: reason)
        default:
            break
        }
    }

    // MARK: - Send

    func send(text: String) throws {
        guard handshakeDone, !finished else { throw LinkError.notConnected }
        let data = WSFrameCodec.encodeClientFrame(fin: true, opcode: WSOpcode.text, payload: Data(text.utf8))
        queue.async { [weak self] in
            guard let self, let connection = self.connection, !self.finished else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error { self?.fail(LinkError.transport("mux 发送失败: \(error.localizedDescription)")) }
            })
        }
    }

    private func sendControlFrame(opcode: UInt8, payload: Data) {
        let data = WSFrameCodec.encodeClientFrame(fin: true, opcode: opcode, payload: payload)
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func ping() {
        guard handshakeDone, !finished else { return }
        if let pingSentAt, Date().timeIntervalSince(pingSentAt) > 10 {
            fail(LinkError.timeout("mux 心跳无响应"))
            return
        }
        let payload = Data(String(Int(Date().timeIntervalSince1970)).utf8)
        sendControlFrame(opcode: WSOpcode.ping, payload: payload)
        self.pingSentAt = Date()
    }

    func close(code: Int = 1000, reason: String = "client closed") {
        guard !finished else { return }
        var payload = Data()
        payload.append(UInt8((code >> 8) & 0xFF))
        payload.append(UInt8(code & 0xFF))
        payload.append(Data(reason.utf8))
        sendControlFrame(opcode: WSOpcode.close, payload: payload)
        finishClosed(code: code, reason: reason)
    }

    // MARK: - Timers / teardown

    private func startPingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in self?.ping() }
        timer.resume()
        pingTimer = timer
    }

    private func handleTransportClosed() {
        if let pingSentAt, Date().timeIntervalSince(pingSentAt) <= 10 {
            finishClosed(code: 1006, reason: "传输层关闭")
        } else {
            finishClosed(code: 1006, reason: "传输层关闭")
        }
    }

    private func finishClosed(code: Int, reason: String) {
        guard !finished else { return }
        finished = true
        connectTimeout.cancel()
        pingTimer?.cancel()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        let continuation = self.continuation
        self.continuation = nil
        if let continuation {
            continuation.resume(throwing: LinkError.httpStatus(409, reason.isEmpty ? "mux 关闭" : reason))
        } else {
            emit(.closed(code: code, reason: reason))
        }
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        connectTimeout.cancel()
        pingTimer?.cancel()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        let continuation = self.continuation
        self.continuation = nil
        if let continuation {
            continuation.resume(throwing: error)
        } else {
            emit(.failed(error))
        }
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.onEvent?(event)
            }
        }
    }
}
