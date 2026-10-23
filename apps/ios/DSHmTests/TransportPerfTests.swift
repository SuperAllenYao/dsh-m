import Compression
import Network
import XCTest
@testable import DSHm

/// M2b transport regression: HTTP/1.1 keep-alive connection pool, idle
/// eviction, peer-close rebuild, response gzip decoding and the unchanged
/// content-length / chunked / until-close parsing paths.
///
/// The production TLS pin path is not re-provisioned here: `HTTPSClient` takes a
/// test seam (`parameters:` + injected `HTTPConnectionPool`) so the same
/// connection/pool/parser code is exercised over a deterministic loopback
/// transport. TLS credential handling itself is covered by the pairing tests
/// and the real-device E2E scripts.
final class TransportPerfTests: XCTestCase {

    // MARK: - Loopback HTTP/1.1 test server

    struct TestRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    enum TestBodyMode { case contentLength, chunked, untilClose }

    struct TestResponse {
        var status: Int = 200
        var headers: [String: String] = ["content-type": "application/json"]
        var body = Data()
        var mode: TestBodyMode = .contentLength
        var closeAfter = false
        var delay: TimeInterval = 0
    }

    final class TestServer {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "com.dshm.tests.http-server")
        private let lock = NSLock()
        private var accepted = 0
        private var recorded: [TestRequest] = []
        private var connections: [ServerConnection] = []
        private var closed = false

        private(set) var port: UInt16 = 0
        var handler: (TestRequest) -> TestResponse
        /// When set, the server closes each connection this long after sending a
        /// response (simulates Node's `keepAliveTimeout` FIN without a
        /// `Connection: close` header).
        var idleCloseAfter: TimeInterval?

        init(handler: @escaping (TestRequest) -> TestResponse) throws {
            self.handler = handler
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: .any)
        }

        var connectionsAccepted: Int {
            lock.lock()
            defer { lock.unlock() }
            return accepted
        }

        var requests: [TestRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func start() async throws {
            listener.newConnectionHandler = { [weak self] nw in
                self?.accept(nw)
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumed = ResumeFlag()
                listener.stateUpdateHandler = { state in
                    guard !resumed.value else { return }
                    switch state {
                    case .ready:
                        resumed.value = true
                        continuation.resume()
                    case .failed(let error):
                        resumed.value = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
            port = listener.port?.rawValue ?? 0
            XCTAssertGreaterThan(port, 0)
        }

        func stop() {
            lock.lock()
            closed = true
            let conns = connections
            connections = []
            lock.unlock()
            listener.cancel()
            for conn in conns { conn.cancel() }
        }

        func record(_ request: TestRequest) -> Int {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(request)
            return recorded.count
        }

        private func accept(_ nw: NWConnection) {
            lock.lock()
            accepted += 1
            lock.unlock()
            let conn = ServerConnection(server: self, nw: nw, queue: queue)
            lock.lock()
            connections.append(conn)
            lock.unlock()
            conn.start()
        }
    }

    /// Small helper so the state handler can resume the continuation exactly once.
    final class ResumeFlag {
        var value = false
    }

    final class ServerConnection {
        private let nw: NWConnection
        private unowned let server: TestServer
        private let queue: DispatchQueue
        private var buffer = Data()
        private var receiveInFlight = false
        private var idleTimer: DispatchWorkItem?
        private var cancelled = false

        init(server: TestServer, nw: NWConnection, queue: DispatchQueue) {
            self.server = server
            self.nw = nw
            self.queue = queue
        }

        func start() {
            nw.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.pump()
                case .failed, .cancelled:
                    self.cancelled = true
                default:
                    break
                }
            }
            nw.start(queue: queue)
        }

        func cancel() {
            guard !cancelled else { return }
            cancelled = true
            idleTimer?.cancel()
            idleTimer = nil
            nw.stateUpdateHandler = nil
            nw.cancel()
        }

        private func pump() {
            guard !cancelled, !receiveInFlight else { return }
            receiveInFlight = true
            nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                self.receiveInFlight = false
                guard !self.cancelled else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.processBuffer()
                }
                if error != nil || isComplete {
                    self.cancel()
                    return
                }
                self.pump()
            }
        }

        private func processBuffer() {
            while let request = nextRequest() {
                idleTimer?.cancel()
                idleTimer = nil
                _ = server.record(request)
                let response = server.handler(request)
                write(response)
                if response.closeAfter || response.mode == .untilClose {
                    // `untilClose` closes after the response body; `closeAfter`
                    // advertises Connection: close and then closes.
                    return
                }
            }
            armIdleClose()
        }

        private func armIdleClose() {
            guard let delay = server.idleCloseAfter, idleTimer == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                self?.cancel()
            }
            idleTimer = item
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        }

        /// Parses one complete request from `buffer` (headers + content-length body).
        private func nextRequest() -> TestRequest? {
            guard let headerEnd = findHeaderEnd() else { return nil }
            let headData = buffer.subdata(in: 0..<(headerEnd - 4))
            guard let headText = String(data: headData, encoding: .utf8) else { return nil }
            let lines = headText.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return nil }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { headers[name] = value }
            }
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            let total = headerEnd + contentLength
            guard buffer.count >= total else { return nil }
            let body = buffer.subdata(in: headerEnd..<total)
            buffer.removeSubrange(0..<total)
            return TestRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
        }

        private func findHeaderEnd() -> Int? {
            let bytes = [UInt8](buffer)
            guard bytes.count >= 4 else { return nil }
            var index = 0
            while index < bytes.count - 3 {
                if bytes[index] == 13, bytes[index + 1] == 10, bytes[index + 2] == 13, bytes[index + 3] == 10 {
                    return index + 4
                }
                index += 1
            }
            return nil
        }

        private func write(_ response: TestResponse) {
            var lines = ["HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Status")"]
            var headers = response.headers
            headers["content-type"] = headers["content-type"] ?? "application/json"
            if response.mode == .chunked {
                headers["transfer-encoding"] = "chunked"
            } else if response.mode == .contentLength {
                headers["content-length"] = String(response.body.count)
            }
            if response.closeAfter {
                headers["connection"] = "close"
            }
            for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
                lines.append("\(name): \(value)")
            }
            var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
            switch response.mode {
            case .contentLength, .untilClose:
                data.append(response.body)
            case .chunked:
                if !response.body.isEmpty {
                    data.append(Data("\(String(response.body.count, radix: 16))\r\n".utf8))
                    data.append(response.body)
                    data.append(Data("\r\n".utf8))
                }
                data.append(Data("0\r\n\r\n".utf8))
            }
            let send = { [weak self] in
                guard let self, !self.cancelled else { return }
                self.nw.send(content: data, completion: .contentProcessed { [weak self] _ in
                    guard let self else { return }
                    if response.closeAfter || response.mode == .untilClose { self.cancel() }
                })
            }
            if response.delay > 0 {
                queue.asyncAfter(deadline: .now() + response.delay, execute: send)
            } else {
                send()
            }
        }
    }

    // MARK: - Helpers

    private func makePool(maxIdle: Int = 2, idleTimeout: TimeInterval = 10) -> HTTPConnectionPool {
        HTTPConnectionPool(config: HTTPConnectionPoolConfig(maxIdlePerOrigin: maxIdle, idleTimeout: idleTimeout))
    }

    private func makeClient(_ server: TestServer, pool: HTTPConnectionPool) -> HTTPSClient {
        HTTPSClient(
            host: "127.0.0.1",
            port: server.port,
            leafPin: nil,
            pool: pool,
            parameters: NWParameters.tcp
        )
    }

    private func key(_ server: TestServer) -> HTTPConnectionKey {
        HTTPConnectionKey(host: "127.0.0.1", port: server.port, pin: nil)
    }

    private func post(_ path: String = "/api/session/list", body: String = "{}") -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            path: path,
            headers: ["content-type": "application/json"],
            body: Data(body.utf8)
        )
    }

    private func runServer(
        idleCloseAfter: TimeInterval? = nil,
        handler: @escaping (TestRequest) -> TestResponse,
        _ body: (TestServer) async throws -> Void
    ) async throws {
        let server = try TestServer(handler: handler)
        server.idleCloseAfter = idleCloseAfter
        try await server.start()
        defer { server.stop() }
        try await body(server)
    }

    // MARK: - Keep-alive reuse

    func testSequentialRequestsReuseOneConnection() async throws {
        try await runServer(handler: { _ in
            TestResponse(body: Data(#"{"ok":true}"#.utf8))
        }) { server in
            let pool = makePool()
            for index in 0..<4 {
                let response = try await makeClient(server, pool: pool).perform(post(), timeout: 5)
                XCTAssertEqual(response.status, 200, "request \(index)")
                XCTAssertEqual(response.bodyText, #"{"ok":true}"#)
            }
            XCTAssertEqual(server.connectionsAccepted, 1, "four unary requests must share one TCP+TLS connection")
            XCTAssertEqual(server.requests.count, 4)
            XCTAssertEqual(pool.idleCount(for: key(server)), 1)
            // `Connection: keep-alive` must be on the wire (HTTP/1.1 explicit).
            XCTAssertEqual(server.requests.first?.header("connection"), "keep-alive")
        }
    }

    func testServerConnectionCloseResponseForcesReconnect() async throws {
        try await runServer(handler: { _ in
            TestResponse(body: Data(#"{"ok":true}"#.utf8), closeAfter: true)
        }) { server in
            let pool = makePool()
            _ = try await makeClient(server, pool: pool).perform(post(), timeout: 5)
            _ = try await makeClient(server, pool: pool).perform(post(), timeout: 5)
            XCTAssertEqual(server.connectionsAccepted, 2, "Connection: close response must not be pooled")
            XCTAssertEqual(pool.idleCount(for: key(server)), 0)
        }
    }

    func testIdlePeerCloseIsDetectedAndConnectionRebuilt() async throws {
        // The peer closes the keep-alive connection *without* a header (Node
        // keepAliveTimeout behaviour). The idle liveness receive must notice the
        // EOF and drop the pooled connection, so the next request silently
        // rebuilds instead of failing on a half-dead socket.
        try await runServer(idleCloseAfter: 0.15, handler: { _ in
            TestResponse(body: Data(#"{"ok":true}"#.utf8))
        }) { server in
            let pool = makePool(idleTimeout: 10)
            _ = try await makeClient(server, pool: pool).perform(post(), timeout: 5)
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(pool.idleCount(for: key(server)), 0, "EOF on an idle connection must evict it from the pool")
            let response = try await makeClient(server, pool: pool).perform(post(), timeout: 5)
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(server.connectionsAccepted, 2, "next request after peer EOF must reconnect")
        }
    }

    func testIdleConnectionEvictedAfterClientTimeout() async throws {
        try await runServer(handler: { _ in
            TestResponse(body: Data(#"{"ok":true}"#.utf8))
        }) { server in
            let pool = makePool(idleTimeout: 0.15)
            _ = try await makeClient(server, pool: pool).perform(post(), timeout: 5)
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(pool.idleCount(for: key(server)), 0, "idle timeout must close the pooled connection")
            _ = try await makeClient(server, pool: pool).perform(post(), timeout: 5)
            XCTAssertEqual(server.connectionsAccepted, 2)
        }
    }

    func testConcurrentRequestsUseSeparateConnectionsNoPipelining() async throws {
        try await runServer(handler: { _ in
            TestResponse(body: Data(#"{"ok":true}"#.utf8), delay: 0.1)
        }) { server in
            let pool = makePool()
            async let firstRequest = makeClient(server, pool: pool).perform(post(), timeout: 5)
            async let secondRequest = makeClient(server, pool: pool).perform(post(), timeout: 5)
            let first = try await firstRequest
            let second = try await secondRequest
            XCTAssertEqual(first.status, 200)
            XCTAssertEqual(second.status, 200)
            XCTAssertEqual(server.connectionsAccepted, 2, "one request per connection while the first is busy (no pipelining)")
        }
    }

    func testMaxIdleConnectionsAreCapped() async throws {
        try await runServer(handler: { _ in
            TestResponse(body: Data(#"{"ok":true}"#.utf8), delay: 0.05)
        }) { server in
            let pool = makePool(maxIdle: 1)
            async let firstRequest = makeClient(server, pool: pool).perform(post(), timeout: 5)
            async let secondRequest = makeClient(server, pool: pool).perform(post(), timeout: 5)
            _ = try await firstRequest
            _ = try await secondRequest
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(pool.idleCount(for: key(server)), 1, "per-origin idle cap must close the extra connection")
        }
    }

    // MARK: - Body framing unchanged

    func testChunkedResponseParsedAndConnectionReused() async throws {
        try await runServer(handler: { _ in
            TestResponse(
                headers: ["content-type": "application/json"],
                body: Data(#"{"chunked":true}"#.utf8),
                mode: .chunked
            )
        }) { server in
            let pool = makePool()
            for _ in 0..<2 {
                let response = try await makeClient(server, pool: pool).perform(post(), timeout: 5)
                XCTAssertEqual(response.bodyText, #"{"chunked":true}"#)
            }
            XCTAssertEqual(server.connectionsAccepted, 1, "chunked HTTP/1.1 responses stay keep-alive eligible")
        }
    }

    func testUntilCloseBodyParsedAndConnectionNotReused() async throws {
        try await runServer(handler: { _ in
            TestResponse(body: Data(#"{"untilClose":true}"#.utf8), mode: .untilClose)
        }) { server in
            let pool = makePool()
            let first = try await makeClient(server, pool: pool).perform(post(), timeout: 5)
            XCTAssertEqual(first.bodyText, #"{"untilClose":true}"#)
            XCTAssertEqual(pool.idleCount(for: key(server)), 0)
            let second = try await makeClient(server, pool: pool).perform(post(), timeout: 5)
            XCTAssertEqual(second.status, 200)
            XCTAssertEqual(server.connectionsAccepted, 2)
        }
    }

    // MARK: - gzip

    private func rawDeflate(_ data: Data) throws -> Data {
        var destination = [UInt8](repeating: 0, count: max(64, data.count + 1024))
        let written = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return destination.withUnsafeMutableBufferPointer { buffer in
                compression_encode_buffer(buffer.baseAddress!, buffer.count, base, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw HTTPCompression.DecodeError.decoderFailure(-2) }
        return Data(destination.prefix(written))
    }

    /// Minimal gzip container around raw DEFLATE. The trailer CRC/ISIZE are left
    /// zero on purpose: the client decoder ignores them (TLS-pinned payload is
    /// validated as JSON), and this test isolates the decompression mechanism.
    private func gzipWrap(_ data: Data) throws -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff])
        out.append(try rawDeflate(data))
        out.append(Data(count: 8))
        return out
    }

    func testUnaryJSONDecodesGzipResponse() async throws {
        let payload = #"{"type":"server-response","rpcId":"__RPC__","result":{"ok":true,"value":{"title":"gzip ok","items":[1,2,3]}}}"#
        let server = try TestServer(handler: { request in
            let requestJSON = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            let rpcId = requestJSON?["rpcId"] as? String ?? "missing"
            let json = payload.replacingOccurrences(of: "__RPC__", with: rpcId)
            let compressed = (try? self.gzipWrap(Data(json.utf8))) ?? Data()
            return TestResponse(
                headers: ["content-type": "application/json", "content-encoding": "gzip"],
                body: compressed
            )
        })
        try await server.start()
        defer { server.stop() }

        let pool = makePool()
        let origin = URL(string: "http://127.0.0.1:\(server.port)")!
        let value = try await HTTPSClient.unaryJSON(
            origin: origin,
            endpoint: "session/list",
            args: [:],
            token: "test-token",
            leafPin: "",
            timeout: 5,
            pool: pool,
            parameters: NWParameters.tcp
        )
        XCTAssertEqual(value["title"]?.stringValue, "gzip ok")
        XCTAssertEqual(value["items"]?.arrayValue?.count, 3)
        XCTAssertEqual(server.requests.first?.header("accept-encoding"), "gzip", "unary helper must advertise gzip support")
        XCTAssertEqual(server.connectionsAccepted, 1)
    }

    func testUncompressedResponseFallsBackWhenServerIgnoresGzip() async throws {
        let payload = #"{"type":"server-response","rpcId":"__RPC__","result":{"ok":true,"value":{"plain":true}}}"#
        let server = try TestServer(handler: { request in
            let requestJSON = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            let rpcId = requestJSON?["rpcId"] as? String ?? "missing"
            let json = payload.replacingOccurrences(of: "__RPC__", with: rpcId)
            return TestResponse(headers: ["content-type": "application/json"], body: Data(json.utf8))
        })
        try await server.start()
        defer { server.stop() }

        let pool = makePool()
        let origin = URL(string: "http://127.0.0.1:\(server.port)")!
        let value = try await HTTPSClient.unaryJSON(
            origin: origin,
            endpoint: "session/list",
            args: [:],
            token: "test-token",
            leafPin: "",
            timeout: 5,
            pool: pool,
            parameters: NWParameters.tcp
        )
        XCTAssertEqual(value["plain"]?.boolValue, true)
    }

    /// task-4 (2026-10-24): a gzip header around a body that does not decompress
    /// must NOT throw LinkError.transport — the link plugin's exact-fetch
    /// passthrough forwards a stale `content-encoding` header (undici inflates the
    /// upstream body but keeps the header), and masking the HTTP status turned a
    /// Host 404 into a retryable transport error (the file-change card then
    /// disappeared after the retry budget). Now the raw body + status are handed
    /// back so callers can act on httpStatus.
    func testGzipDecodeFallsBackToRawBodyWhenBodyIsNotGzip() throws {
        let raw = Data([0x1f, 0x8b, 0x08, 0x00]) // truncated gzip: decompression fails
        let response = HTTPResponse(
            status: 404,
            headers: ["content-encoding": "gzip"],
            body: raw,
            observedLeafPin: nil
        )
        let decoded = try HTTPSClient.decodeBody(of: response)
        XCTAssertEqual(decoded.status, 404, "the HTTP status must survive a body decode failure")
        XCTAssertEqual(decoded.body, raw, "the raw wire body is handed back untouched")
        // Plain responses pass through untouched.
        let plain = HTTPResponse(status: 200, headers: [:], body: Data(#"{"ok":true}"#.utf8), observedLeafPin: nil)
        XCTAssertEqual(try HTTPSClient.decodeBody(of: plain).bodyText, #"{"ok":true}"#)
    }

    func testGzipDecodesLargeBodyIncrementally() throws {
        // 158 KB session/list-shaped payload: bigger than the 8 KiB inflate
        // window, so the streaming loop has to run multiple rounds.
        let padding = String(repeating: "x", count: 640)
        let rows = (0..<220).map { index in
            #"{"sessionId":"sess-\#(index)-abcdefghij","updatedAt":\#(1_700_000_000 + index),"projections":{"values":{"title":"session \#(index) \#(padding)","running":false}}}"#
        }
        let json = #"{"type":"server-response","rpcId":"rpc-large","result":{"ok":true,"value":{"items":[\#(rows.joined(separator: ","))]}}}"#
        let raw = Data(json.utf8)
        XCTAssertGreaterThan(raw.count, 140 * 1024)
        let gz = try gzipWrap(raw)
        XCTAssertLessThan(gz.count, raw.count)
        let decoded = try HTTPCompression.gunzip(gz)
        XCTAssertEqual(decoded.count, raw.count)
        XCTAssertEqual(decoded, raw)
    }

    // MARK: - Serialization

    func testSerializeAdvertisesKeepAliveOnlyForPooledPath() {
        let request = post()
        let keepAlive = HTTPSClient.serialize(request: request, host: "127.0.0.1", port: 4443, keepAlive: true)
        let oneShot = HTTPSClient.serialize(request: request, host: "127.0.0.1", port: 4443, keepAlive: false)
        XCTAssertTrue(String(data: keepAlive, encoding: .utf8)!.contains("Connection: keep-alive\r\n"))
        XCTAssertTrue(String(data: oneShot, encoding: .utf8)!.contains("Connection: close\r\n"))
        XCTAssertTrue(String(data: keepAlive, encoding: .utf8)!.contains("Host: 127.0.0.1:4443\r\n"))
    }

    // MARK: - 2026-10-23 T2(A): TLS-only prewarm

    /// 预热只建 TCP+TLS、不发请求；随后 unary 直接复用这条连接（服务端只接受 1 条）。
    func testPrewarmTLSBuildsOnePooledConnectionWithoutSendingRequest() async throws {
        try await runServer(handler: { _ in
            TestResponse(body: Data(#"{"ok":true}"#.utf8))
        }) { server in
            let pool = makePool()
            let warmed = await HTTPSClient.prewarmTLS(
                origin: URL(string: "https://127.0.0.1:\(server.port)")!,
                leafPin: nil,
                timeout: 5,
                pool: pool,
                parameters: NWParameters.tcp
            )
            XCTAssertTrue(warmed, "loopback TLS-less transport must reach ready")
            XCTAssertEqual(pool.idleCount(for: key(server)), 1, "prewarmed connection must be idle in the pool")
            XCTAssertEqual(server.requests.count, 0, "TLS-only prewarm must not send an HTTP request")

            // 后续 unary 直接 checkout 预热的连接：服务端 TCP 连接数仍为 1。
            let response = try await makeClient(server, pool: pool).perform(post(), timeout: 5)
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(server.connectionsAccepted, 1, "the list request must reuse the prewarmed connection")
            XCTAssertEqual(server.requests.count, 1)
            XCTAssertEqual(pool.idleCount(for: key(server)), 1, "the connection must return to the pool")
        }
    }

    /// 池里已有空闲连接时，重复预热不得再建一条。
    func testPrewarmTLSSkipsWhenPoolAlreadyHasIdleConnection() async throws {
        try await runServer(handler: { _ in
            TestResponse(body: Data(#"{"ok":true}"#.utf8))
        }) { server in
            let pool = makePool()
            let origin = URL(string: "https://127.0.0.1:\(server.port)")!
            let first = await HTTPSClient.prewarmTLS(
                origin: origin, leafPin: nil, timeout: 5, pool: pool, parameters: NWParameters.tcp
            )
            let second = await HTTPSClient.prewarmTLS(
                origin: origin, leafPin: nil, timeout: 5, pool: pool, parameters: NWParameters.tcp
            )
            XCTAssertTrue(first)
            XCTAssertTrue(second)
            XCTAssertEqual(server.requests.count, 0)
            _ = try await makeClient(server, pool: pool).perform(post(), timeout: 5)
            XCTAssertEqual(server.connectionsAccepted, 1, "second prewarm must not open another connection")
        }
    }

    /// 预热失败（origin 不可达）必须快速返回 false、不抛错、不污染连接池。
    func testPrewarmTLSFailsCleanlyWhenOriginUnreachable() async {
        let pool = makePool()
        let started = Date()
        let warmed = await HTTPSClient.prewarmTLS(
            origin: URL(string: "https://127.0.0.1:1")!,
            leafPin: nil,
            timeout: 2,
            pool: pool,
            parameters: NWParameters.tcp
        )
        XCTAssertFalse(warmed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "prewarm failure must not hang")
        XCTAssertEqual(
            pool.idleCount(for: HTTPConnectionKey(host: "127.0.0.1", port: 1, pin: nil)),
            0,
            "a failed prewarm must never leave a pooled connection behind"
        )
    }
}
