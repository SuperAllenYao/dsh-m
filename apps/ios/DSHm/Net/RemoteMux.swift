import Foundation

/// Transport-agnostic handle for one logical remote stream.
///
/// Consumers (workspace/session/`$events` subscriptions) hold this instead of a
/// concrete stream class so the same code runs over the legacy `RemoteMux`
/// (double TLS) and the P1 single-WSS channel (dsh-m/2), with no behaviour change.
@MainActor
protocol RemoteStreamHandle: AnyObject {
    var streamId: String { get }
    var endpoint: String { get }
 /// Uplink one item (nil value == undefined/omitted field).
    func send(value: JSONValue?) throws
 /// Half-close the uplink side (`end` frame).
    func end()
 /// Cancel the stream and release the local handle.
    func cancel()
}

/// One logical stream opened on a RemoteMux.
@MainActor
final class RemoteStream {
    let streamId: String
    let endpoint: String
    private weak var mux: RemoteMux?

 /// All callbacks are delivered on the main queue, in wire order.
    var onItem: ((JSONValue?) -> Void)?
    var onEnd: (() -> Void)?
    var onError: ((RemoteError) -> Void)?
    var onClose: ((Int, String) -> Void)?

    init(streamId: String, endpoint: String, mux: RemoteMux) {
        self.streamId = streamId
        self.endpoint = endpoint
        self.mux = mux
    }

 /// Uplink an item (nil value == undefined).
    func send(value: JSONValue? = nil) throws {
        guard let mux else { throw LinkError.notConnected }
        try mux.sendItem(streamId: streamId, value: value)
    }

    func end() { mux?.sendEnd(streamId: streamId) }

    func cancel() { mux?.cancel(streamId: streamId) }
}

extension RemoteStream: RemoteStreamHandle {}

/// P1 names the uplink `sendItem`; the shared protocol keeps the legacy
/// `send(value:)` surface so stream consumers compile over both transports.
extension P1StreamHandle: RemoteStreamHandle {
    func send(value: JSONValue?) throws { try sendItem(value) }
}

/// Multiplexes logical streams over one /api/remote.mux WebSocket.
///
/// Threading: create/open/close on the main thread. Server frames arrive on the
/// main queue (WSSClient delivers there) and callbacks are invoked in wire order.
@MainActor
final class RemoteMux {
    private let ws: WSSClient
    private var streams: [String: RemoteStream] = [:]
    private(set) var closed = false
    private(set) var openedAt = Date()

 /// Called on the main queue when the physical socket closes or fails.
    var onClose: ((Error?) -> Void)?

    init(ws: WSSClient) {
        self.ws = ws
        ws.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .text(let text):
                self.handle(text: text)
            case .closed(let code, let reason):
                self.handleSocketClosed(error: LinkError.transport("mux 已关闭(\(code)) \(reason)"))
            case .failed(let error):
                self.handleSocketClosed(error: error)
            case .opened, .pong:
                break
            case .binary:
 // link-perf L3a：binary 帧只出现在 P1（gzip 协商后）
 // 下行；legacy M1 mux 不存在该语义，防御性忽略（P1 通道侧才有
 // 「未协商却收到 binary = 违规」的判定与协商态）。
                break
            }
        }
    }

    @discardableResult
    func openStream(
        endpoint: String,
        args: [String: JSONValue],
        onItem: ((JSONValue?) -> Void)? = nil,
        onEnd: (() -> Void)? = nil,
        onError: ((RemoteError) -> Void)? = nil,
        onClose: ((Int, String) -> Void)? = nil
    ) throws -> RemoteStream {
        guard !closed else { throw LinkError.notConnected }
        let streamId = UUID().uuidString.lowercased()
        let stream = RemoteStream(streamId: streamId, endpoint: endpoint, mux: self)
        stream.onItem = onItem
        stream.onEnd = onEnd
        stream.onError = onError
        stream.onClose = onClose
        streams[streamId] = stream
        try sendFrame(.open(streamId: streamId, endpoint: endpoint, args: args))
        return stream
    }

    func close() {
        guard !closed else { return }
        ws.close()
        handleSocketClosed(error: nil)
    }

 // MARK: - Outbound

    fileprivate func sendItem(streamId: String, value: JSONValue?) throws {
        try sendFrame(.item(streamId: streamId, value: value))
    }

    fileprivate func sendEnd(streamId: String) {
        try? sendFrame(.end(streamId: streamId))
    }

    fileprivate func cancel(streamId: String) {
        streams.removeValue(forKey: streamId)
        try? sendFrame(.cancel(streamId: streamId))
    }

    private func sendFrame(_ frame: MuxFrame) throws {
        let value = try frame.encodedJSON()
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LinkError.malformedEnvelope("frame UTF-8 编码失败")
        }
        try ws.send(text: text)
    }

 // MARK: - Inbound

    private func handle(text: String) {
        guard let data = text.data(using: .utf8) else { return }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        guard let frame = try? MuxFrame.decode(value) else { return }
        switch frame {
        case .serverItem(let streamId, let value):
            streams[streamId]?.onItem?(value)
        case .serverEnd(let streamId):
            guard let stream = streams.removeValue(forKey: streamId) else { return }
            stream.onEnd?()
        case .serverError(let streamId, let error):
            guard let stream = streams.removeValue(forKey: streamId) else { return }
            stream.onError?(error)
        case .open, .item, .end, .cancel:
            break
        }
    }

    private func handleSocketClosed(error: Error?) {
        guard !closed else { return }
        closed = true
        let pending = streams
        streams.removeAll()
        for stream in pending.values {
            stream.onClose?(1006, "mux closed")
        }
        onClose?(error)
    }
}
