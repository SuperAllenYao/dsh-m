import Foundation
import Network

/// Minimal HTTPS/1.1 client on top of Network.framework.
///
/// We deliberately do not use URLSession: the link origin uses a self-signed
/// certificate and the app pins the leaf SHA-256 fingerprint captured in the QR
/// payload. NWConnection + a custom TLS verify block gives us that control, and
/// also keeps unary calls on HTTP/1.1 exactly like the protocol spec requires.
///
/// M2b: unary/JSON calls are keep-alive pooled per origin (see
/// `HTTPConnectionPool`), so the TCP+TLS 3–4 RTT handshake is paid once per
/// connection instead of once per request. The Bonjour `serviceEndpoint` path
/// stays one-shot: a browse result is a transient pairing/discovery address, not
/// a stable origin key worth pooling.
final class HTTPSClient {
    private let host: String
    private let port: UInt16
    private let leafPin: String?
    /// v0.1.1 C: pinned CA certificate (base64 DER) from the pairing payload /
    /// credential. When present, a leaf chaining to it is accepted and the exact
    /// leaf pin only serves as fallback (see `PinnedTLS`).
    private let caCertBase64: String?
    /// M2a: connect through a Bonjour service endpoint (SRV/A resolution is left
    /// to Network.framework) instead of an explicit host/port pair.
    private let serviceEndpoint: NWEndpoint?
    /// M2b: keep-alive pool (origin-scoped); tests inject a private instance.
    private let pool: HTTPConnectionPool
    /// Test seam: replaces the pinned-TLS parameters with a plain transport so
    /// connection lifecycle/gzip mechanics can be exercised without a
    /// simulator-provisioned certificate identity. Production always uses
    /// `PinnedTLS.parameters`.
    private let parametersOverride: NWParameters?

    // One-shot fallback state (serviceEndpoint path only).
    private let queue = DispatchQueue(label: "com.dshm.https-client")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var parser = HTTPResponseParser()
    private var finished = false
    private let pinCapture = PinCapture()

    init(host: String, port: UInt16, leafPin: String?, caCertBase64: String? = nil) {
        self.host = host
        self.port = port
        self.leafPin = leafPin
        self.caCertBase64 = caCertBase64
        self.serviceEndpoint = nil
        self.pool = .shared
        self.parametersOverride = nil
    }

    /// Test seam: explicit pool/transport. Not used by production call sites.
    init(
        host: String,
        port: UInt16,
        leafPin: String?,
        caCertBase64: String? = nil,
        pool: HTTPConnectionPool,
        parameters: NWParameters? = nil
    ) {
        self.host = host
        self.port = port
        self.leafPin = leafPin
        self.caCertBase64 = caCertBase64
        self.serviceEndpoint = nil
        self.pool = pool
        self.parametersOverride = parameters
    }

    /// Bonjour pairing (design §5.3): the browse result's `.service` endpoint is
    /// connected directly; `hostHeader` is only used for the HTTP Host header and
    /// error text (TLS trust is certificate-pin based, not host-name based).
    init(serviceEndpoint: NWEndpoint, hostHeader: String, leafPin: String?, caCertBase64: String? = nil) {
        self.host = hostHeader
        self.port = 443
        self.leafPin = leafPin
        self.caCertBase64 = caCertBase64
        self.serviceEndpoint = serviceEndpoint
        self.pool = .shared
        self.parametersOverride = nil
    }

    /// v0.1.1 C: pool identity includes the pinned CA so connections validated
    /// with the leaf-pin fallback are not reused after the CA upgrade.
    private var caCertHash: String? {
        caCertBase64.map { PinFormat.sha256Hex(Data($0.utf8)) }
    }

    /// Performs one request. Host/port origins reuse a pooled keep-alive
    /// connection when one is available; otherwise a fresh TCP+TLS connection is
    /// created. `serviceEndpoint` origins always use a one-shot connection.
    func perform(_ request: HTTPRequest, timeout: TimeInterval = 20) async throws -> HTTPResponse {
        guard serviceEndpoint == nil else {
            return try await performOneShot(request, timeout: timeout)
        }
        let key = HTTPConnectionKey(
            host: host,
            port: port,
            pin: PinFormat.normalize(leafPin),
            caCertHash: caCertHash
        )
        if let pooled = pool.checkout(key) {
            do {
                let response = try await pooled.perform(request, timeout: timeout)
                return try Self.decodeBody(of: response)
            } catch HTTPConnectionError.closedBeforeSend {
                // The pooled keep-alive socket died between checkout and
                // dispatch (peer FIN raced the reuse). No request bytes were
                // sent, so rebuilding on a fresh connection is safe for every
                // method, POST included.
            }
        }
        let connection = HTTPConnection(
            key: key,
            host: host,
            port: port,
            leafPin: leafPin,
            caCertBase64: caCertBase64,
            parametersOverride: parametersOverride,
            pool: pool
        )
        let response = try await connection.perform(request, timeout: timeout)
        return try Self.decodeBody(of: response)
    }

    // MARK: - One-shot path (Bonjour serviceEndpoint)

    private func performOneShot(_ request: HTTPRequest, timeout: TimeInterval) async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            queue.async {
                self.start(request: request, timeout: timeout)
            }
        }
    }

    // MARK: - Connection lifecycle (one-shot, all on serial queue)

    private func start(request: HTTPRequest, timeout: TimeInterval) {
        let parameters = PinnedTLS.parameters(
            leafPin: leafPin,
            caCertBase64: caCertBase64,
            capture: pinCapture,
            connectTimeout: min(timeout, PinnedTLS.defaultConnectTimeout)
        )
        let connection: NWConnection
        if let serviceEndpoint {
            connection = NWConnection(to: serviceEndpoint, using: parameters)
        } else {
            connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 443,
                using: parameters
            )
        }
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendRequest(request)
            case .failed(let error):
                self.finish(.failure(LinkError.transport("连接 \(self.host):\(self.port) 失败：" + NetworkErrorInterpreter.message(for: error))))
            case .waiting(let error):
                // TLS pin mismatch usually surfaces here as a cert/trust error.
                self.finish(.failure(LinkError.transport("连接 \(self.host):\(self.port) 等待中：" + NetworkErrorInterpreter.message(for: error))))
            case .cancelled:
                self.finish(.failure(LinkError.cancelled))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(LinkError.timeout("\(request.method) \(request.path)")))
        }
    }

    private func sendRequest(_ request: HTTPRequest) {
        let bytes = Self.serialize(request: request, host: host, port: port, keepAlive: false)
        connection?.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(LinkError.transport("发送失败：" + NetworkErrorInterpreter.message(for: error))))
                return
            }
            self.receiveLoop()
        })
    }

    private func receiveLoop() {
        guard !finished else { return }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.parser.append(data)
                if let response = self.parser.completed {
                    self.finish(.success(self.attachPin(response)))
                    return
                }
            }
            if let error {
                if let response = self.parser.finishOnClose() {
                    self.finish(.success(self.attachPin(response)))
                } else {
                    self.finish(.failure(LinkError.transport("接收失败：" + NetworkErrorInterpreter.message(for: error))))
                }
                return
            }
            if isComplete {
                if let response = self.parser.finishOnClose() {
                    self.finish(.success(self.attachPin(response)))
                } else {
                    self.finish(.failure(LinkError.transport("连接提前关闭")))
                }
                return
            }
            self.receiveLoop()
        }
    }

    private func attachPin(_ response: HTTPResponse) -> HTTPResponse {
        var response = response
        response.observedLeafPin = pinCapture.pin
        return response
    }

    private func finish(_ result: Result<HTTPResponse, Error>) {
        guard !finished else { return }
        finished = true
        connection?.cancel()
        connection = nil
        let continuation = self.continuation
        self.continuation = nil
        switch result {
        case .success(let response):
            do {
                let decoded = try Self.decodeBody(of: response)
                continuation?.resume(returning: decoded)
            } catch {
                continuation?.resume(throwing: error)
            }
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    // MARK: - Response decoding (gzip, M2b)

    /// Decodes a `Content-Encoding: gzip` response body in place. Bodies without
    /// a gzip coding pass through untouched (servers may answer uncompressed
    /// when they ignore `Accept-Encoding`).
    static func decodeBody(of response: HTTPResponse) throws -> HTTPResponse {
        guard let encoding = response.header("content-encoding") else { return response }
        if HTTPCompression.isGzip(encoding) {
            var decoded = response
            do {
                decoded.body = try HTTPCompression.gunzip(response.body)
            } catch {
                throw LinkError.transport("响应 gzip 解压失败：" + error.localizedDescription)
            }
            return decoded
        }
        // Anything else (`identity`, empty) is already the wire body.
        let normalized = encoding.trimmingCharacters(in: .whitespaces).lowercased()
        guard normalized.isEmpty || normalized == "identity" else {
            throw LinkError.transport("不支持的响应编码: \(encoding)")
        }
        return response
    }

    // MARK: - Serialization

    static func serialize(request: HTTPRequest, host: String, port: UInt16, keepAlive: Bool = false) -> Data {
        var lines: [String] = []
        lines.append("\(request.method) \(request.path) HTTP/1.1")
        let hostHeader = port == 443 ? host : "\(host):\(port)"
        lines.append("Host: \(hostHeader)")
        for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        if let body = request.body {
            lines.append("Content-Length: \(body.count)")
        }
        lines.append(keepAlive ? "Connection: keep-alive" : "Connection: close")
        let head = lines.joined(separator: "\r\n") + "\r\n\r\n"
        var data = Data(head.utf8)
        if let body = request.body {
            data.append(body)
        }
        return data
    }

    // MARK: - Convenience

    /// JSON unary call against the link origin (POST /api/<endpoint>).
    /// The trailing `pool`/`parameters` are a test seam (transport-level tests
    /// inject a plain local transport); production call sites use the defaults.
    static func unaryJSON(
        origin: URL,
        endpoint: String,
        args: [String: JSONValue],
        token: String,
        leafPin: String,
        caCertBase64: String? = nil,
        timeout: TimeInterval = 20,
        pool: HTTPConnectionPool = .shared,
        parameters: NWParameters? = nil
    ) async throws -> JSONValue {
        guard let host = origin.host, !host.isEmpty else {
            throw LinkError.transport("origin 无可解析 host: \(origin.absoluteString)")
        }
        let port = UInt16(origin.port ?? 443)
        let envelope = ClientRequestEnvelope(method: endpoint, args: args)
        let body = try JSONEncoder().encode(envelope)
        let request = HTTPRequest(
            method: "POST",
            path: "/api/\(endpoint)",
            headers: [
                "content-type": "application/json",
                "authorization": "Bearer \(token)",
                "accept": "application/json",
                "accept-encoding": "gzip",
            ],
            body: body
        )
        let response = try await HTTPSClient(host: host, port: port, leafPin: leafPin, caCertBase64: caCertBase64, pool: pool, parameters: parameters)
            .perform(request, timeout: timeout)
        guard response.status == 200 else {
            throw LinkError.httpStatus(response.status, response.bodyText)
        }
        let decoded: ServerResponseEnvelope
        do {
            decoded = try JSONDecoder().decode(ServerResponseEnvelope.self, from: response.body)
        } catch {
            throw LinkError.malformedEnvelope("server-response 解析失败: \(error.localizedDescription)")
        }
        guard decoded.type == "server-response" else {
            throw LinkError.malformedEnvelope("type != server-response")
        }
        guard decoded.rpcId == envelope.rpcId else {
            throw LinkError.rpcMismatch(expected: envelope.rpcId, actual: decoded.rpcId)
        }
        switch decoded.result {
        case .ok(let value): return value
        case .failure(let error): throw LinkError.remote(error)
        }
    }

    /// Plain JSON helper used for /health, /pair/redeem and /auth/*.
    /// Returns the parsed JSON body even for non-2xx statuses so callers can read
    /// the plugin's `{"ok":false,"error":"..."}` envelopes.
    static func json(
        origin: URL,
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: JSONValue? = nil,
        leafPin: String?,
        caCertBase64: String? = nil,
        timeout: TimeInterval = 20
    ) async throws -> (status: Int, json: JSONValue, observedLeafPin: String?) {
        guard let host = origin.host, !host.isEmpty else {
            throw LinkError.transport("origin 无可解析 host: \(origin.absoluteString)")
        }
        let port = UInt16(origin.port ?? 443)
        var allHeaders = headers
        allHeaders["accept"] = allHeaders["accept"] ?? "application/json"
        allHeaders["accept-encoding"] = allHeaders["accept-encoding"] ?? "gzip"
        var bodyData: Data?
        if let body {
            allHeaders["content-type"] = "application/json"
            bodyData = try body.encodedData()
        }
        let request = HTTPRequest(method: method, path: path, headers: allHeaders, body: bodyData)
        let response = try await HTTPSClient(host: host, port: port, leafPin: leafPin, caCertBase64: caCertBase64).perform(request, timeout: timeout)
        let json: JSONValue
        do {
            json = try JSONValue.jsonObject(from: response.body)
        } catch {
            throw LinkError.malformedEnvelope("响应不是 JSON（HTTP \(response.status)）: \(response.bodyText.prefix(200))")
        }
        return (response.status, json, response.observedLeafPin)
    }

    /// Bonjour variant of `json`: same plain-JSON helper against an `NWBrowser`
    /// `.service` endpoint (LAN code redeem, design §5.3 step 3).
    static func json(
        serviceEndpoint: NWEndpoint,
        hostHeader: String,
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: JSONValue? = nil,
        leafPin: String?,
        caCertBase64: String? = nil,
        timeout: TimeInterval = 20
    ) async throws -> (status: Int, json: JSONValue, observedLeafPin: String?) {
        var allHeaders = headers
        allHeaders["accept"] = allHeaders["accept"] ?? "application/json"
        allHeaders["accept-encoding"] = allHeaders["accept-encoding"] ?? "gzip"
        var bodyData: Data?
        if let body {
            allHeaders["content-type"] = "application/json"
            bodyData = try body.encodedData()
        }
        let request = HTTPRequest(method: method, path: path, headers: allHeaders, body: bodyData)
        let response = try await HTTPSClient(serviceEndpoint: serviceEndpoint, hostHeader: hostHeader, leafPin: leafPin, caCertBase64: caCertBase64)
            .perform(request, timeout: timeout)
        let json: JSONValue
        do {
            json = try JSONValue.jsonObject(from: response.body)
        } catch {
            throw LinkError.malformedEnvelope("响应不是 JSON（HTTP \(response.status)）: \(response.bodyText.prefix(200))")
        }
        return (response.status, json, response.observedLeafPin)
    }

    /// GET an exact-fetch route (protocol §3.9) through the link origin.
    /// Auth is the same short-lived api bearer token as unary calls; the response
    /// body is plain JSON (not a client-request/server-response envelope).
    static func exactGETJSON(
        origin: URL,
        path: String,
        query: [String: String],
        token: String,
        leafPin: String?,
        caCertBase64: String? = nil,
        timeout: TimeInterval = 20
    ) async throws -> (status: Int, json: JSONValue?, body: String) {
        guard let host = origin.host, !host.isEmpty else {
            throw LinkError.transport("origin 无可解析 host: \(origin.absoluteString)")
        }
        let port = UInt16(origin.port ?? 443)
        var pathWithQuery = path
        if !query.isEmpty {
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?+"))
            let pairs = query
                .sorted { $0.key < $1.key }
                .map { key, value -> String in
                    let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                    let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                    return encodedKey + "=" + encodedValue
                }
            pathWithQuery += "?" + pairs.joined(separator: "&")
        }
        let request = HTTPRequest(
            method: "GET",
            path: pathWithQuery,
            headers: [
                "authorization": "Bearer \(token)",
                "accept": "application/json",
                "accept-encoding": "gzip",
            ],
            body: nil
        )
        let response = try await HTTPSClient(host: host, port: port, leafPin: leafPin, caCertBase64: caCertBase64).perform(request, timeout: timeout)
        let json = try? JSONValue.jsonObject(from: response.body)
        return (response.status, json, response.bodyText)
    }
}
