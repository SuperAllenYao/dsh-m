import Foundation

// MARK: - dsh-m/2 constants (<internal-doc> §3)

/// Identifiers for the P1 single-WSS protocol (dsh-m/2).
///
/// P1 replaces the two-TLS M1/M2b layout with one pinned WSS that carries unary
/// RPC, upstream stream frames and `resume`. The wire behaviour is defined by the
/// plugin prototype (`packages/dsh-m-link/lib/mux-rpc.js`) and verified by
/// `test/p1-single-wss.mjs`; this file mirrors it byte-for-byte and adds strict
/// validation so a malformed server frame cannot corrupt App state.
enum P1Proto {
 /// `hello.v` / `welcome.v`.
    static let version = 2
 /// `welcome.proto` negotiation value.
    static let name = "dsh-m/2"
 /// Upgrade path for the single pinned WSS connection (`?proto=2` opts in; the
 /// plugin keeps the M1 bridge byte-identical for clients that do not ask for it).
    static let socketPath = "/api/remote.mux?proto=2"
}

/// Wire limits mirrored from the plugin (`P1_LIMITS` in `mux-rpc.js`).
enum P1ProtocolLimits {
 /// One WebSocket text message ≤ 32 MiB (design §3.1; same cap as the old unary
 /// body). Oversized frames close the socket with 1009.
    static let maxFrameBytes = 32 * 1024 * 1024
 /// `rpc.id` length cap enforced by `MuxRpcChannel.onRpc`.
    static let maxRPCIdLength = 128
 /// Endpoint shape enforced by the plugin: `namespace/method`.
    static let endpointPattern = "^[A-Za-z0-9_$.-]+/[A-Za-z0-9_$.-]+$"
 /// `hello` → `welcome` deadline (design §5, `muxRpcHelloTimeoutMs`).
    static let helloTimeout: TimeInterval = 3
}

/// A frame that violates the dsh-m/2 contract (bad JSON, unknown type, missing
/// required field, oversized message...).
enum P1ProtocolError: Error, Equatable, LocalizedError {
    case violation(String)
    case frameTooLarge(bytes: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .violation(let message):
            return "dsh-m/2 协议违例: \(message)"
        case .frameTooLarge(let bytes, let limit):
            return "dsh-m/2 单帧 \(bytes)B 超过上限 \(limit)B"
        }
    }

 /// True for the oversize case (the socket must be closed with 1009).
    var isFrameTooLarge: Bool {
        if case .frameTooLarge = self { return true }
        return false
    }
}

// MARK: - Client frames (§3.2)

/// `hello.auth` — in-band credential. A resume ticket is preferred; the one-time
/// mux token is the ECDSA fallback (design §4.2). Never logged.
struct P1Auth: Equatable, Sendable {
    var ticket: String?
    var muxToken: String?

    init(ticket: String? = nil, muxToken: String? = nil) {
        self.ticket = ticket
        self.muxToken = muxToken
    }

 /// No usable credential: the plugin would answer `close 4401 auth/required`.
    var isEmpty: Bool {
        (ticket?.isEmpty ?? true) && (muxToken?.isEmpty ?? true)
    }
}

/// `hello.client` — App identity for audit/support (name required, version optional).
struct P1ClientInfo: Equatable, Sendable {
    var name: String
    var version: String?

    init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }

 /// Production client identity. `version` is filled from the bundle by the
 /// caller that wires the transport into `LinkService`.
    static let dshm = P1ClientInfo(name: "dsh-m-ios", version: nil)
}

/// `hello.resume` — the lossless-reconnect cursor: the channel `epoch` plus the
/// last downstream `sid` the App actually applied.
struct P1ResumeCursor: Equatable, Sendable {
    var logEpoch: String
    var sid: Int64

    init(logEpoch: String, sid: Int64) {
        self.logEpoch = logEpoch
        self.sid = sid
    }
}

/// `hello` payload.
struct P1Hello: Equatable {
    var v: Int
    var client: P1ClientInfo
    var auth: P1Auth
    var resume: P1ResumeCursor?

    init(client: P1ClientInfo, auth: P1Auth, resume: P1ResumeCursor? = nil) {
        self.v = P1Proto.version
        self.client = client
        self.auth = auth
        self.resume = resume
    }
}

/// One unary call (`rpc` frame). `body` is the legacy `client-request` envelope,
/// byte-identical to `POST /api/<endpoint>` (design §3.4).
struct P1RPCCall: Equatable {
    var id: String
    var endpoint: String
    var body: JSONValue
    var headers: [String: String]?

    init(id: String, endpoint: String, body: JSONValue, headers: [String: String]? = nil) {
        self.id = id
        self.endpoint = endpoint
        self.body = body
        self.headers = headers
    }

 /// Builds the `client-request` body for a call (`ClientRequestEnvelope` shape).
    init(id: String, endpoint: String, args: [String: JSONValue], headers: [String: String]? = nil) {
        self.init(id: id, endpoint: endpoint, body: P1ClientRequestBody.encode(rpcId: id, method: endpoint, args: args), headers: headers)
    }
}

/// `client-request` envelope body builder (protocol §2; same bytes as the M1 unary path).
enum P1ClientRequestBody {
    static func encode(rpcId: String, method: String, args: [String: JSONValue]) -> JSONValue {
        .object([
            "type": .string("client-request"),
            "rpcId": .string(rpcId),
            "method": .string(method),
            "payload": .object(["args": .object(args)]),
        ])
    }
}

/// A frame the App may send after the socket is up.
enum P1ClientFrame: Equatable {
    case hello(P1Hello)
    case rpc(P1RPCCall)
 /// Upstream mux frame (`open` / `item` / `end` / `cancel`), forwarded verbatim
 /// by the plugin. Only the envelope is re-used; payloads stay untouched.
    case mux(MuxFrame)
    case ping(ts: Int64)

 /// Validated wire JSON object.
    func encodedJSON() throws -> JSONValue {
        switch self {
        case .hello(let hello):
            return try Self.encodeHello(hello)
        case .rpc(let call):
            return try Self.encodeRPC(call)
        case .mux(let frame):
            return try Self.encodeMux(frame)
        case .ping(let ts):
            return .object(["type": .string("ping"), "ts": .int(ts)])
        }
    }

 // MARK: Encoding

    private static func encodeHello(_ hello: P1Hello) throws -> JSONValue {
        guard hello.v == P1Proto.version else {
            throw P1ProtocolError.violation("hello.v=\(hello.v) 不受支持（需要 \(P1Proto.version)）")
        }
        let name = hello.client.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw P1ProtocolError.violation("hello.client.name 不能为空")
        }
        var client: [String: JSONValue] = ["name": .string(name)]
        if let version = hello.client.version, !version.isEmpty {
            client["version"] = .string(version)
        }
        guard !hello.auth.isEmpty else {
            throw P1ProtocolError.violation("hello.auth 需要 ticket 或 muxToken")
        }
        var auth: [String: JSONValue] = [:]
        if let ticket = hello.auth.ticket, !ticket.isEmpty { auth["ticket"] = .string(ticket) }
        if let muxToken = hello.auth.muxToken, !muxToken.isEmpty { auth["muxToken"] = .string(muxToken) }

        var object: [String: JSONValue] = [
            "type": .string("hello"),
            "v": .int(Int64(hello.v)),
            "client": .object(client),
            "auth": .object(auth),
        ]
        if let resume = hello.resume {
            guard !resume.logEpoch.isEmpty else {
                throw P1ProtocolError.violation("hello.resume.logEpoch 不能为空")
            }
            guard resume.sid >= 0 else {
                throw P1ProtocolError.violation("hello.resume.sid 必须为非负整数")
            }
            object["resume"] = .object([
                "logEpoch": .string(resume.logEpoch),
                "sid": .int(resume.sid),
            ])
        }
        return .object(object)
    }

    private static func encodeRPC(_ call: P1RPCCall) throws -> JSONValue {
        guard !call.id.isEmpty, call.id.utf8.count <= P1ProtocolLimits.maxRPCIdLength else {
            throw P1ProtocolError.violation("rpc.id 必须为 1…\(P1ProtocolLimits.maxRPCIdLength) 字节的字符串")
        }
        guard isEndpoint(call.endpoint) else {
            throw P1ProtocolError.violation("rpc.endpoint 必须形如 ns/method: \(call.endpoint)")
        }
        guard case .object = call.body else {
            throw P1ProtocolError.violation("rpc.body 必须是 client-request 对象")
        }
        var object: [String: JSONValue] = [
            "type": .string("rpc"),
            "id": .string(call.id),
            "endpoint": .string(call.endpoint),
            "body": call.body,
        ]
        if let headers = call.headers, !headers.isEmpty {
            object["headers"] = .object(headers.mapValues { .string($0) })
        }
        return .object(object)
    }

    private static func encodeMux(_ frame: MuxFrame) throws -> JSONValue {
        switch frame {
        case .open(let streamId, _, _), .item(let streamId, _), .end(let streamId), .cancel(let streamId):
            guard !streamId.isEmpty else {
                throw P1ProtocolError.violation("\(streamIdType(of: frame)).streamId 不能为空")
            }
        case .serverItem, .serverEnd, .serverError:
            throw P1ProtocolError.violation("不能把服务端 mux 帧编码成上行帧")
        }
 // Upstream mux frames are forwarded verbatim (plugin byte-bridge semantics):
 // endpoints are not validated here — `$events` legitimately has no
 // namespace slash (`` §3.2).
        do {
            return try frame.encodedJSON()
        } catch {
            throw P1ProtocolError.violation("mux 帧编码失败: \(error.localizedDescription)")
        }
    }

    private static func streamIdType(of frame: MuxFrame) -> String {
        switch frame {
        case .open: return "open"
        case .item: return "item"
        case .end: return "end"
        case .cancel: return "cancel"
        case .serverItem, .serverEnd, .serverError: return "server"
        }
    }

    static func isEndpoint(_ endpoint: String) -> Bool {
        endpoint.range(of: P1ProtocolLimits.endpointPattern, options: .regularExpression) != nil
    }
}

extension P1ClientFrame: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(try encodedJSON())
    }
}

// MARK: - Server frames (§3.2)

/// `welcome.caps`.
struct P1Caps: Decodable, Equatable {
    var unary: Bool
    var resume: Bool
    var maxInFlight: Int
    var replayBytes: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let unary = try container.decodeIfPresent(Bool.self, forKey: .unary),
              let resume = try container.decodeIfPresent(Bool.self, forKey: .resume),
              let maxInFlight = try container.decodeIfPresent(Int.self, forKey: .maxInFlight),
              let replayBytes = try container.decodeIfPresent(Int.self, forKey: .replayBytes) else {
            throw P1ProtocolError.violation("welcome.caps 缺少必填字段")
        }
        guard maxInFlight >= 1 else {
            throw P1ProtocolError.violation("welcome.caps.maxInFlight 非法: \(maxInFlight)")
        }
        guard replayBytes >= 0 else {
            throw P1ProtocolError.violation("welcome.caps.replayBytes 非法: \(replayBytes)")
        }
        self.unary = unary
        self.resume = resume
        self.maxInFlight = maxInFlight
        self.replayBytes = replayBytes
    }

    private enum CodingKeys: String, CodingKey {
        case unary, resume, maxInFlight, replayBytes
    }
}

/// `welcome.resume` — handshake outcome for `hello.resume`.
struct P1ResumeInfo: Decodable, Equatable {
    enum Mode: String, Equatable, Sendable {
 /// No cursor sent: the channel starts at sid 0.
        case fresh
 /// Cursor accepted, missing frames follow the welcome in `down` order.
        case replay
 /// Cursor rejected (epoch mismatch / evicted / sid-ahead / gap): new epoch, sid 0.
        case reset
    }

    var ok: Bool
    var mode: Mode
 /// Number of replayed `down` frames following the welcome (replay mode only).
    var replayed: Int?
 /// Reset cause (`epoch-mismatch`, `evicted`, `sid-ahead`, `gap`) for telemetry.
    var reason: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let ok = try container.decodeIfPresent(Bool.self, forKey: .ok) else {
            throw P1ProtocolError.violation("welcome.resume.ok 必填")
        }
        guard let rawMode = try container.decodeIfPresent(String.self, forKey: .mode) else {
            throw P1ProtocolError.violation("welcome.resume.mode 必填")
        }
        guard let mode = Mode(rawValue: rawMode) else {
            throw P1ProtocolError.violation("welcome.resume.mode 未知: \(rawMode)")
        }
        let replayed = try container.decodeIfPresent(Int.self, forKey: .replayed)
        let reason = try container.decodeIfPresent(String.self, forKey: .reason)
        if ok {
            guard mode != .reset else {
                throw P1ProtocolError.violation("welcome.resume 自相矛盾: ok=true 但 mode=reset")
            }
            if mode == .replay {
                guard let replayed, replayed >= 0 else {
                    throw P1ProtocolError.violation("welcome.resume 在 replay 模式缺少 replayed")
                }
            }
        } else {
            guard mode == .reset else {
                throw P1ProtocolError.violation("welcome.resume 自相矛盾: ok=false 但 mode=\(rawMode)")
            }
            guard let reason, !reason.isEmpty else {
                throw P1ProtocolError.violation("welcome.resume 在 reset 模式缺少 reason")
            }
        }
        self.ok = ok
        self.mode = mode
        self.replayed = replayed
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case ok, mode, replayed, reason
    }
}

/// `welcome` — handshake result. `sid` is the server's current last sequence and
/// `ticket` a freshly rotated resume ticket (cache it, never log it).
struct P1Welcome: Decodable, Equatable {
    var v: Int
    var proto: String
    var deviceId: String
    var epoch: String
    var sid: Int64
    var resume: P1ResumeInfo
    var caps: P1Caps
    var ticket: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = try container.decodeIfPresent(String.self, forKey: .type), type == "welcome" else {
            throw P1ProtocolError.violation("期望 welcome 帧")
        }
        guard let v = try container.decodeIfPresent(Int.self, forKey: .v) else {
            throw P1ProtocolError.violation("welcome 缺少 v")
        }
        guard v == P1Proto.version else {
            throw P1ProtocolError.violation("welcome.v=\(v) 不受支持")
        }
        guard let proto = try container.decodeIfPresent(String.self, forKey: .proto), proto == P1Proto.name else {
            throw P1ProtocolError.violation("welcome.proto 不是 \(P1Proto.name)")
        }
        guard let deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId), !deviceId.isEmpty else {
            throw P1ProtocolError.violation("welcome.deviceId 必填")
        }
        guard let epoch = try container.decodeIfPresent(String.self, forKey: .epoch), !epoch.isEmpty else {
            throw P1ProtocolError.violation("welcome.epoch 必填")
        }
        guard let sid = try container.decodeIfPresent(Int64.self, forKey: .sid), sid >= 0 else {
            throw P1ProtocolError.violation("welcome.sid 必须为非负整数")
        }
        guard let resume = try container.decodeIfPresent(P1ResumeInfo.self, forKey: .resume) else {
            throw P1ProtocolError.violation("welcome.resume 必填")
        }
        guard let caps = try container.decodeIfPresent(P1Caps.self, forKey: .caps) else {
            throw P1ProtocolError.violation("welcome.caps 必填")
        }
        let ticket = try container.decodeIfPresent(String.self, forKey: .ticket)
        if let ticket, ticket.isEmpty {
            throw P1ProtocolError.violation("welcome.ticket 不能为空字符串")
        }
        self.v = v
        self.proto = proto
        self.deviceId = deviceId
        self.epoch = epoch
        self.sid = sid
        self.resume = resume
        self.caps = caps
        self.ticket = ticket
    }

    private enum CodingKeys: String, CodingKey {
        case type, v, proto, deviceId, epoch, sid, resume, caps, ticket
    }
}

/// `down` — one upstream mux frame with its transport sequence number.
struct P1DownEnvelope: Decodable, Equatable {
 /// Monotonic server→client sequence, starting at 1 within one epoch.
    var sid: Int64
 /// Verbatim upstream frame object (`item` / `end` / `error` /...).
    var frame: JSONValue

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = try container.decodeIfPresent(String.self, forKey: .type), type == "down" else {
            throw P1ProtocolError.violation("期望 down 帧")
        }
        guard let sid = try container.decodeIfPresent(Int64.self, forKey: .sid), sid >= 1 else {
            throw P1ProtocolError.violation("down.sid 必须 ≥ 1")
        }
        guard let frame = try container.decodeIfPresent(JSONValue.self, forKey: .frame) else {
            throw P1ProtocolError.violation("down.frame 必填")
        }
        guard case .object = frame else {
            throw P1ProtocolError.violation("down.frame 必须是 JSON 对象")
        }
        guard let frameType = frame["type"]?.stringValue, !frameType.isEmpty else {
            throw P1ProtocolError.violation("down.frame 缺少 type")
        }
        if Self.requiresStreamId(frameType) {
            guard let streamId = frame["streamId"]?.stringValue, !streamId.isEmpty else {
                throw P1ProtocolError.violation("down.frame(\(frameType)) 缺少 streamId")
            }
        }
        self.sid = sid
        self.frame = frame
    }

    private enum CodingKeys: String, CodingKey {
        case type, sid, frame
    }

    private static func requiresStreamId(_ type: String) -> Bool {
        ["open", "item", "end", "cancel", "error"].contains(type)
    }

    var frameType: String? { frame["type"]?.stringValue }
    var streamId: String? { frame["streamId"]?.stringValue }
    var value: JSONValue? { frame["value"] }

 /// Stream error payload (`down.frame.error`), with the same lenient fallback
 /// as `MuxFrame.decode` so a partial error body still surfaces to the UI.
    var error: RemoteError? {
        guard let value = frame["error"] else { return nil }
        if let decoded = try? value.decode(RemoteError.self) { return decoded }
        return RemoteError(code: "unknown", message: value["message"]?.stringValue ?? "stream error")
    }
}

/// `rpc/result` — unary response. HTTP status/content-type pass through unchanged;
/// exactly one of `body` (parsed JSON) / `bodyText` (raw text) is present.
struct P1RPCResult: Decodable, Equatable {
    var id: String
    var status: Int
    var contentType: String?
    var body: JSONValue?
    var bodyText: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = try container.decodeIfPresent(String.self, forKey: .type), type == "rpc/result" else {
            throw P1ProtocolError.violation("期望 rpc/result 帧")
        }
        guard let id = try container.decodeIfPresent(String.self, forKey: .id),
              !id.isEmpty,
              id.utf8.count <= P1ProtocolLimits.maxRPCIdLength else {
            throw P1ProtocolError.violation("rpc/result.id 非法")
        }
        guard let status = try container.decodeIfPresent(Int.self, forKey: .status), (0...999).contains(status) else {
            throw P1ProtocolError.violation("rpc/result.status 非法")
        }
        let contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
        let hasBody = container.contains(.body)
        var body: JSONValue?
        if hasBody {
 // A JSON `null` body is a valid parsed body: keep it as `.null`.
            body = try container.decodeIfPresent(JSONValue.self, forKey: .body) ?? .null
        }
        let bodyText = try container.decodeIfPresent(String.self, forKey: .bodyText)
        guard hasBody != (bodyText != nil) else {
            throw P1ProtocolError.violation("rpc/result 必须且只能携带 body 或 bodyText 之一")
        }
        self.id = id
        self.status = status
        self.contentType = contentType
        self.body = body
        self.bodyText = bodyText
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, status, contentType, body, bodyText
    }

 /// Response bytes for callers that re-use the HTTP response decode path:
 /// the parsed JSON re-encoded, or the raw `bodyText`.
    func bodyData() throws -> Data {
        if let body { return try JSONEncoder().encode(body) }
        return Data((bodyText ?? "").utf8)
    }
}

/// `rpc/error` — plugin-side failure (`rpc/timeout`, `rpc/busy`,
/// `upstream/failed`...), not an HTTP business error.
struct P1RPCErrorFrame: Decodable, Equatable {
    var id: String
    var error: RemoteError

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = try container.decodeIfPresent(String.self, forKey: .type), type == "rpc/error" else {
            throw P1ProtocolError.violation("期望 rpc/error 帧")
        }
        guard let id = try container.decodeIfPresent(String.self, forKey: .id),
              !id.isEmpty,
              id.utf8.count <= P1ProtocolLimits.maxRPCIdLength else {
            throw P1ProtocolError.violation("rpc/error.id 非法")
        }
        guard let error = try container.decodeIfPresent(RemoteError.self, forKey: .error) else {
            throw P1ProtocolError.violation("rpc/error 缺少 error.code/message")
        }
        self.id = id
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, error
    }
}

/// `pong` — heartbeat echo (`ts` mirrors the ping, may be null).
struct P1PongFrame: Decodable, Equatable {
    var ts: Int64?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = try container.decodeIfPresent(String.self, forKey: .type), type == "pong" else {
            throw P1ProtocolError.violation("期望 pong 帧")
        }
        self.ts = try container.decodeIfPresent(Int64.self, forKey: .ts)
    }

    private enum CodingKeys: String, CodingKey {
        case type, ts
    }
}

/// A decoded plugin→App frame.
enum P1ServerFrame: Equatable {
    case welcome(P1Welcome)
    case down(P1DownEnvelope)
    case rpcResult(P1RPCResult)
    case rpcError(P1RPCErrorFrame)
    case pong(P1PongFrame)
}

extension P1ServerFrame: Decodable {
    private enum TypeKey: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: TypeKey.self)
        guard let type = try probe.decodeIfPresent(String.self, forKey: .type) else {
            throw P1ProtocolError.violation("服务端帧缺少 type")
        }
        switch type {
        case "welcome":
            self = .welcome(try P1Welcome(from: decoder))
        case "down":
            self = .down(try P1DownEnvelope(from: decoder))
        case "rpc/result":
            self = .rpcResult(try P1RPCResult(from: decoder))
        case "rpc/error":
            self = .rpcError(try P1RPCErrorFrame(from: decoder))
        case "pong":
            self = .pong(try P1PongFrame(from: decoder))
        default:
            throw P1ProtocolError.violation("未知服务端帧类型 \(type)")
        }
    }
}

// MARK: - Codec

/// Compact JSON codec for dsh-m/2: one WS text message = one JSON object.
enum P1FrameCodec {
 /// Encodes one client frame into a compact JSON string and enforces the
 /// 32 MiB message cap.
    static func encodeText(_ frame: P1ClientFrame, maxBytes: Int = P1ProtocolLimits.maxFrameBytes) throws -> String {
        let value = try frame.encodedJSON()
        let data = try JSONEncoder().encode(value)
        try checkSize(data.count, limit: maxBytes, direction: "上行帧")
        guard let text = String(data: data, encoding: .utf8) else {
            throw P1ProtocolError.violation("上行帧不是合法 UTF-8")
        }
        return text
    }

 /// Decodes one plugin→App text message. Unknown/missing `type`,
 /// missing required fields and oversize messages are protocol violations.
    static func decodeServerFrame(_ text: String, maxBytes: Int = P1ProtocolLimits.maxFrameBytes) throws -> P1ServerFrame {
        let byteCount = text.utf8.count
        guard byteCount > 0 else {
            throw P1ProtocolError.violation("空帧")
        }
        try checkSize(byteCount, limit: maxBytes, direction: "下行帧")
        do {
            return try JSONDecoder().decode(P1ServerFrame.self, from: Data(text.utf8))
        } catch let error as P1ProtocolError {
            throw error
        } catch let error as DecodingError {
            throw P1ProtocolError.violation(Self.describe(error))
        } catch {
            throw P1ProtocolError.violation(error.localizedDescription)
        }
    }

    private static func checkSize(_ bytes: Int, limit: Int, direction: String) throws {
        guard bytes <= limit else {
            throw P1ProtocolError.frameTooLarge(bytes: bytes, limit: limit)
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            return "字段类型不符（期望 \(type)）：\(path(context.codingPath)) \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "缺少数值（\(type)）：\(path(context.codingPath)) \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "缺少字段 \(key.stringValue)：\(path(context.codingPath))"
        case .dataCorrupted(let context):
            return "内容非法：\(path(context.codingPath)) \(context.debugDescription)"
        @unknown default:
            return "无法解析的 JSON"
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        codingPath.map(\.stringValue).joined(separator: ".")
    }
}

// MARK: - Close codes and failure semantics (§3.2 table, §5 transitions)

/// What the App should do after a close/close-like failure.
enum P1CloseSeverity: Equatable, Sendable {
 /// Do not keep using dsh-m/2 in this state (protocol violation).
    case fatal
 /// Back off to the legacy M1/M2b transport (and report).
    case fallback
 /// Retryable — retry the v2 path (reconnect / re-auth / backoff).
    case retry
 /// Ordinary close, no action.
    case normal
}

/// Concrete next step for a close code. `LinkService` maps these onto its
/// reconnect/fallback state machine (design §5).
enum P1CloseAction: Equatable, Sendable {
    case none
 /// Stop using dsh-m/2 and go back to the legacy double-TLS path.
    case fallbackLegacy
 /// 4401: re-authenticate with the ECDSA mux token and retry once.
    case retryWithECDSATicket
 /// 4408/4409: wait 200–500 ms, then retry.
    case retryAfterBackoff
 /// 1011/1013: full reconnect (ticket auth, 1 TLS + 1 hello RTT).
    case reconnect
 /// 1009: fail just this request, keep the connection.
    case requestFailed
}

/// Per-code semantics, combining severity and action.
struct P1CloseSemantics: Equatable, Sendable {
    var severity: P1CloseSeverity
    var action: P1CloseAction

    var isRetryable: Bool {
        switch action {
        case .retryWithECDSATicket, .retryAfterBackoff, .reconnect: return true
        case .none, .fallbackLegacy, .requestFailed: return false
        }
    }

    var shouldFallbackLegacy: Bool { action == .fallbackLegacy }
}

/// dsh-m/2 close codes (custom 4400–4499 range plus WebSocket standard codes).
enum P1CloseCode: Int, CaseIterable, Equatable, Sendable {
    case normalClosure = 1000
    case goingAway = 1001
    case unsupportedData = 1003
    case noStatus = 1005
    case abnormalClosure = 1006
    case frameTooLarge = 1009
    case upstreamClosed = 1011
    case bufferOverflow = 1013
    case protocolViolation = 4400
    case authFailed = 4401
    case binaryFrame = 4403
    case helloRequired = 4408
    case connectionConflict = 4409

    var semantics: P1CloseSemantics {
        switch self {
        case .normalClosure, .goingAway, .noStatus:
            return P1CloseSemantics(severity: .normal, action: .none)
        case .frameTooLarge:
 // 1009: the offending frame is dead, the request fails and is reported;
 // the connection itself may stay up.
            return P1CloseSemantics(severity: .fatal, action: .requestFailed)
        case .upstreamClosed, .bufferOverflow, .abnormalClosure:
            return P1CloseSemantics(severity: .retry, action: .reconnect)
        case .protocolViolation:
            return P1CloseSemantics(severity: .fatal, action: .fallbackLegacy)
        case .authFailed:
            return P1CloseSemantics(severity: .retry, action: .retryWithECDSATicket)
        case .binaryFrame, .unsupportedData:
            return P1CloseSemantics(severity: .fallback, action: .fallbackLegacy)
        case .helloRequired, .connectionConflict:
            return P1CloseSemantics(severity: .retry, action: .retryAfterBackoff)
        }
    }

 /// Semantics for any numeric code; unknown codes are treated as a retryable
 /// transport loss (conservative: never silently fall back on an unknown code).
    static func semantics(for code: Int) -> P1CloseSemantics {
        if let known = P1CloseCode(rawValue: code) { return known.semantics }
        return P1CloseSemantics(severity: .retry, action: .reconnect)
    }
}

/// A dsh-m/2 transport failure with an action attached. `P1Channel` funnels
/// every socket close, protocol violation and per-request failure through this
/// type so `LinkService` can drive its dual-stack state machine.
enum P1Failure: Error, Equatable {
 /// 4400/4403: the v2 protocol is unusable here; fall back to the legacy path.
    case fallbackLegacy(code: Int, reason: String)
 /// 4401: re-authenticate with ECDSA (mux token) and retry hello once.
    case authRetry(code: Int, reason: String)
 /// 4408: first frame was not hello / hello timed out.
    case helloRequired(code: Int, reason: String)
 /// 4409: another socket already owns this device (backoff, then retry).
    case connectionConflict(code: Int, reason: String)
 /// 1011: upstream mux died / plugin internal error (full reconnect).
    case upstreamClosed(code: Int, reason: String)
 /// 1013: buffered frames overflowed before the upstream was ready.
    case bufferOverflow(code: Int, reason: String)
 /// A single frame exceeded the 32 MiB cap (inbound or outbound).
    case frameTooLarge(reason: String)
 /// Any other close (1006 transport loss, 1000/1001, unknown codes).
    case socketClosed(code: Int, reason: String)
 /// A frame/data violated the dsh-m/2 contract.
    case protocolViolation(String)
 /// The channel has no ready socket.
    case notConnected
 /// A request exceeded its deadline; late responses are dropped.
    case timeout(String)
 /// The caller cancelled the operation / explicit disconnect.
    case cancelled
 /// Plugin-side `rpc/error` (`rpc/busy`, `upstream/failed`,...).
    case rpcError(id: String, error: RemoteError)

 /// Maps a socket close event to the failure the App should act on.
    static func close(code: Int, reason: String) -> P1Failure {
        switch P1CloseCode(rawValue: code) {
        case .protocolViolation:
            return .fallbackLegacy(code: code, reason: reason)
        case .authFailed:
            return .authRetry(code: code, reason: reason)
        case .binaryFrame, .unsupportedData:
            return .fallbackLegacy(code: code, reason: reason)
        case .helloRequired:
            return .helloRequired(code: code, reason: reason)
        case .connectionConflict:
            return .connectionConflict(code: code, reason: reason)
        case .upstreamClosed:
            return .upstreamClosed(code: code, reason: reason)
        case .bufferOverflow:
            return .bufferOverflow(code: code, reason: reason)
        case .frameTooLarge:
            return .frameTooLarge(reason: reason.isEmpty ? "单帧过大" : reason)
        case .normalClosure, .goingAway, .noStatus, .abnormalClosure, nil:
            return .socketClosed(code: code, reason: reason)
        }
    }

 /// The close code that produced this failure (nil for local failures).
    var closeCode: Int? {
        switch self {
        case .fallbackLegacy(let code, _),
             .authRetry(let code, _),
             .helloRequired(let code, _),
             .connectionConflict(let code, _),
             .upstreamClosed(let code, _),
             .bufferOverflow(let code, _),
             .socketClosed(let code, _):
            return code
        case .frameTooLarge, .protocolViolation, .notConnected, .timeout, .cancelled, .rpcError:
            return nil
        }
    }

    var action: P1CloseAction {
        switch self {
        case .fallbackLegacy:
            return .fallbackLegacy
        case .authRetry:
            return .retryWithECDSATicket
        case .helloRequired, .connectionConflict:
            return .retryAfterBackoff
        case .upstreamClosed(let code, _), .bufferOverflow(let code, _), .socketClosed(let code, _):
            return P1CloseCode.semantics(for: code).action
        case .frameTooLarge:
            return .requestFailed
        case .protocolViolation:
            return .fallbackLegacy
        case .notConnected, .timeout, .cancelled, .rpcError:
            return .none
        }
    }

    var severity: P1CloseSeverity {
        switch self {
        case .fallbackLegacy:
            return .fatal
        case .authRetry:
            return .retry
        case .helloRequired, .connectionConflict:
            return .retry
        case .upstreamClosed(let code, _), .bufferOverflow(let code, _), .socketClosed(let code, _):
            return P1CloseCode.semantics(for: code).severity
        case .frameTooLarge:
            return .fatal
        case .protocolViolation:
            return .fatal
        case .notConnected, .timeout, .cancelled, .rpcError:
            return .normal
        }
    }

    var shouldFallbackLegacy: Bool { action == .fallbackLegacy }

 /// Retryable failures: reconnect / re-auth / backoff (NOT per-request errors).
    var isRetryable: Bool {
        switch action {
        case .retryWithECDSATicket, .retryAfterBackoff, .reconnect: return true
        case .none, .fallbackLegacy, .requestFailed: return false
        }
    }

 /// Transport/business error carried by an `rpc/error` frame.
    var remoteError: RemoteError? {
        if case .rpcError(_, let error) = self { return error }
        return nil
    }

 /// Short user-facing text (the connection UI shows `onClose` reasons).
    var userMessage: String {
        switch self {
        case .fallbackLegacy(let code, let reason):
            return "dsh-m/2 不可用（close \(code)\(reason.isEmpty ? "" : ": \(reason)")），回退旧连接"
        case .authRetry(let code, let reason):
            return "dsh-m/2 认证失败（close \(code)\(reason.isEmpty ? "" : ": \(reason)")），重试认证"
        case .helloRequired(let code, let reason):
            return "dsh-m/2 握手异常（close \(code)\(reason.isEmpty ? "" : ": \(reason)")）"
        case .connectionConflict(let code, let reason):
            return "dsh-m/2 连接冲突（close \(code)\(reason.isEmpty ? "" : ": \(reason)")）"
        case .upstreamClosed(let code, let reason):
            return "上游 mux 已断开（close \(code)\(reason.isEmpty ? "" : ": \(reason)")）"
        case .bufferOverflow(let code, let reason):
            return "dsh-m/2 缓冲溢出（close \(code)\(reason.isEmpty ? "" : ": \(reason)")）"
        case .frameTooLarge(let reason):
            return "dsh-m/2 帧过大：\(reason)"
        case .socketClosed(let code, let reason):
            return "dsh-m/2 连接关闭（close \(code)\(reason.isEmpty ? "" : ": \(reason)")）"
        case .protocolViolation(let message):
            return "dsh-m/2 协议异常：\(message)"
        case .notConnected:
            return "连接未就绪"
        case .timeout(let what):
            return "超时：\(what)"
        case .cancelled:
            return "已取消"
        case .rpcError(_, let error):
            return error.message.isEmpty ? error.code : "\(error.code): \(error.message)"
        }
    }
}

extension P1Failure: LocalizedError {
    var errorDescription: String? { userMessage }
}
