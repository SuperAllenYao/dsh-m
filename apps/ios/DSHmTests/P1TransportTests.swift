import Foundation
import XCTest
@testable import DSHm

/// `P1Channel` transport-core tests over an injected `FakeSocket`: handshake,
/// concurrent/out-of-order unary correlation, stream dispatch, resume replay /
/// reset, close-code mapping, timeout & cancellation, protocol violations.
///
/// No sockets, no TLS, no DSH host: the fake socket records outbound frames and
/// injects inbound ones synchronously, which keeps the state machine deterministic.
final class P1TransportTests: XCTestCase {

    // MARK: - Test doubles

    /// Socket seam double. `onSend` runs synchronously inside `send`, which the
    /// channel explicitly supports (see `P1Socket` contract); inbound frames are
    /// therefore deterministic.
    @MainActor
    private final class FakeSocket: P1Socket {
        var onText: ((String) -> Void)?
        var onClose: ((P1SocketClose) -> Void)?
        var onSend: ((String) -> Void)?
        var connectError: Error?
        var sendError: Error?

        private(set) var connectCount = 0
        private(set) var sent: [String] = []
        private(set) var closeCalls: [P1SocketClose] = []
        private(set) var connected = false

        func connect() async throws {
            connectCount += 1
            if let connectError { throw connectError }
            connected = true
        }

        func send(text: String) throws {
            if let sendError { throw sendError }
            guard connected else { throw P1Failure.notConnected }
            sent.append(text)
            onSend?(text)
        }

        func close(code: Int, reason: String) {
            closeCalls.append(P1SocketClose(code: code, reason: reason))
            connected = false
        }

        // Test controls

        func receive(_ text: String) {
            onText?(text)
        }

        func drop(code: Int = 1006, reason: String = "network lost") {
            connected = false
            onClose?(P1SocketClose(code: code, reason: reason))
        }

        var sentObjects: [[String: Any]] { sent.map(Self.parse) }

        func sentFrames(type: String) -> [[String: Any]] {
            sentObjects.filter { $0["type"] as? String == type }
        }

        nonisolated static func parse(_ text: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        }
    }

    @MainActor
    private final class SocketFactory {
        var configure: ((FakeSocket) -> Void)?
        private(set) var created: [FakeSocket] = []

        func make() -> FakeSocket {
            let socket = FakeSocket()
            created.append(socket)
            configure?(socket)
            return socket
        }

        var last: FakeSocket? { created.last }
    }

    // MARK: - Fixtures

    private static func welcomeJSON(
        epoch: String = "epoch-1",
        sid: Int64 = 0,
        resume: String = #"{"ok":true,"mode":"fresh"}"#,
        ticket: String? = "ticket-1"
    ) -> String {
        let ticketField = ticket.map { ",\"ticket\":\"\($0)\"" } ?? ""
        return """
        {"type":"welcome","v":2,"proto":"dsh-m/2","deviceId":"dev-1","epoch":"\(epoch)","sid":\(sid),\
        "resume":\(resume),"caps":{"unary":true,"resume":true,"maxInFlight":8,"replayBytes":4194304}\(ticketField)}
        """
    }

    private static func downJSON(sid: Int64, frame: String) -> String {
        "{\"type\":\"down\",\"sid\":\(sid),\"frame\":\(frame)}"
    }

    private static func itemFrame(streamId: String = "s1", value: String = #"{"type":"snapshot"}"#) -> String {
        "{\"type\":\"item\",\"streamId\":\"\(streamId)\",\"value\":\(value)}"
    }

    private static func endFrame(streamId: String = "s1") -> String {
        "{\"type\":\"end\",\"streamId\":\"\(streamId)\"}"
    }

    private static func errorFrame(
        streamId: String = "s1",
        code: String = "agent/failed",
        message: String = "boom"
    ) -> String {
        "{\"type\":\"error\",\"streamId\":\"\(streamId)\",\"error\":{\"code\":\"\(code)\",\"message\":\"\(message)\"}}"
    }

    private static func rpcResultJSON(
        id: String,
        status: Int = 200,
        contentType: String? = "application/json",
        body: String? = nil,
        bodyText: String? = nil
    ) -> String {
        var fields = "\"type\":\"rpc/result\",\"id\":\"\(id)\",\"status\":\(status)"
        if let contentType { fields += ",\"contentType\":\"\(contentType)\"" }
        if let body { fields += ",\"body\":\(body)" }
        if let bodyText { fields += ",\"bodyText\":\(Self.jsonEscape(bodyText))" }
        return "{\(fields)}"
    }

    private static func rpcErrorJSON(
        id: String,
        code: String = "upstream/failed",
        message: String = "boom"
    ) -> String {
        "{\"type\":\"rpc/error\",\"id\":\"\(id)\",\"error\":{\"code\":\"\(code)\",\"message\":\"\(message)\"}}"
    }

    private static func jsonEscape(_ text: String) -> String {
        let data = try? JSONEncoder().encode(text)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func frameType(_ text: String) -> String? {
        FakeSocket.parse(text)["type"] as? String
    }

    // MARK: - Helpers

    @MainActor
    private func makeChannel(
        _ factory: SocketFactory,
        helloTimeout: TimeInterval = 2,
        maxFrameBytes: Int = P1ProtocolLimits.maxFrameBytes
    ) -> P1Channel {
        P1Channel(
            socketFactory: { factory.make() },
            clientInfo: P1ClientInfo(name: "unit-test", version: "0.0.0"),
            helloTimeout: helloTimeout,
            maxFrameBytes: maxFrameBytes
        )
    }

    /// Makes every new socket answer a `hello` with this welcome (and optional
    /// extra frames injected synchronously right behind it).
    @MainActor
    private func respondWithWelcome(
        _ factory: SocketFactory,
        epoch: String = "epoch-1",
        sid: Int64 = 0,
        resume: String = #"{"ok":true,"mode":"fresh"}"#,
        ticket: String? = "ticket-1",
        extraOnHello: ((FakeSocket) -> Void)? = nil
    ) {
        factory.configure = { socket in
            socket.onSend = { text in
                guard Self.frameType(text) == "hello" else { return }
                socket.receive(Self.welcomeJSON(epoch: epoch, sid: sid, resume: resume, ticket: ticket))
                extraOnHello?(socket)
            }
        }
    }

    /// Answers `hello` and records every `rpc` id (for out-of-order responses).
    @MainActor
    private func respondToHelloAndCollectRPCs(_ factory: SocketFactory) -> () -> [String] {
        var rpcIds: [String] = []
        factory.configure = { socket in
            socket.onSend = { text in
                let object = FakeSocket.parse(text)
                guard let type = object["type"] as? String else { return }
                switch type {
                case "hello":
                    socket.receive(Self.welcomeJSON())
                case "rpc":
                    if let id = object["id"] as? String { rpcIds.append(id) }
                default:
                    break
                }
            }
        }
        return { rpcIds }
    }

    @MainActor
    private func waitUntil(
        _ condition: () -> Bool,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("等待条件超时", file: file, line: line)
    }

    // MARK: - Handshake

    @MainActor
    func testHandshakeSendsHelloAndParsesWelcome() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory)

        let welcome = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))

        let socket = try XCTUnwrap(factory.last)
        XCTAssertEqual(socket.connectCount, 1)
        let hello = try XCTUnwrap(socket.sentFrames(type: "hello").first)
        XCTAssertEqual(hello["v"] as? Int, 2)
        XCTAssertEqual((hello["client"] as? [String: Any])?["name"] as? String, "unit-test")
        XCTAssertEqual((hello["client"] as? [String: Any])?["version"] as? String, "0.0.0")
        XCTAssertEqual((hello["auth"] as? [String: Any])?["ticket"] as? String, "ticket-1")
        XCTAssertNil(hello["resume"], "首连不能带 resume 游标")

        XCTAssertEqual(welcome.epoch, "epoch-1")
        XCTAssertEqual(welcome.resume.mode, .fresh)
        XCTAssertEqual(welcome.sid, 0)
        XCTAssertEqual(welcome.ticket, "ticket-1")
        XCTAssertEqual(channel.state, .ready)
        XCTAssertEqual(channel.epoch, "epoch-1")
        XCTAssertEqual(channel.lastAppliedSid, 0)
        XCTAssertEqual(channel.resumeState, P1ResumeCursor(logEpoch: "epoch-1", sid: 0))
        XCTAssertEqual(channel.welcomeResume?.mode, .fresh)
        XCTAssertNil(channel.lastFailure)
    }

    @MainActor
    func testConnectSendsResumeCursor() async throws {
        let factory = SocketFactory()
        respondWithWelcome(
            factory,
            sid: 2,
            resume: #"{"ok":true,"mode":"replay","replayed":0}"#
        )
        let channel = makeChannel(factory)
        let cursor = P1ResumeCursor(logEpoch: "epoch-1", sid: 2)

        let welcome = try await channel.connect(auth: P1Auth(ticket: "rotated"), resume: cursor)

        let hello = try XCTUnwrap(factory.last?.sentFrames(type: "hello").first)
        let resume = try XCTUnwrap(hello["resume"] as? [String: Any])
        XCTAssertEqual(resume["logEpoch"] as? String, "epoch-1")
        XCTAssertEqual(resume["sid"] as? Int, 2)
        XCTAssertEqual(welcome.resume.mode, .replay)
        XCTAssertEqual(channel.lastAppliedSid, 2)
    }

    @MainActor
    func testConnectFailsWhenHelloTimesOut() async throws {
        let factory = SocketFactory() // no welcome
        let channel = makeChannel(factory, helloTimeout: 0.05)

        do {
            _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
            XCTFail("hello 超时必须抛错")
        } catch {
            let expected = P1Failure.timeout("等待 welcome（hello 超时）")
            XCTAssertEqual(error as? P1Failure, expected)
            XCTAssertEqual(channel.lastFailure, expected)
        }
        XCTAssertEqual(channel.state, .closed)
        XCTAssertNil(channel.welcome)
        XCTAssertEqual(factory.last?.closeCalls.last?.code, P1CloseCode.helloRequired.rawValue)
    }

    @MainActor
    func testConnectMapsAuthCloseToAuthRetry() async throws {
        let factory = SocketFactory()
        factory.configure = { socket in
            socket.onSend = { text in
                guard Self.frameType(text) == "hello" else { return }
                socket.drop(code: P1CloseCode.authFailed.rawValue, reason: "auth/invalid-ticket")
            }
        }
        let channel = makeChannel(factory)

        do {
            _ = try await channel.connect(auth: P1Auth(ticket: "expired"))
            XCTFail("4401 必须抛错")
        } catch {
            XCTAssertEqual(error as? P1Failure, .authRetry(code: 4401, reason: "auth/invalid-ticket"))
        }
        XCTAssertEqual(channel.state, .closed)
        XCTAssertEqual(channel.lastFailure?.action, .retryWithECDSATicket)
    }

    @MainActor
    func testConnectPropagatesSocketConnectError() async throws {
        let factory = SocketFactory()
        factory.configure = { $0.connectError = LinkError.timeout("mux 升级") }
        let channel = makeChannel(factory)

        do {
            _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
            XCTFail("连接失败必须抛错")
        } catch {
            XCTAssertEqual(error as? LinkError, .timeout("mux 升级"))
        }
        XCTAssertEqual(channel.state, .closed)
        XCTAssertEqual(factory.last?.connectCount, 1)
    }

    @MainActor
    func testConnectFailsWhenHelloCannotBeSent() async throws {
        let factory = SocketFactory()
        factory.configure = { $0.sendError = LinkError.notConnected }
        let channel = makeChannel(factory)

        do {
            _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
            XCTFail("hello 发送失败必须抛错")
        } catch {
            XCTAssertEqual(error as? P1Failure, .socketClosed(code: 1006, reason: "hello 发送失败"))
        }
        XCTAssertEqual(channel.state, .closed)
        XCTAssertEqual(factory.last?.closeCalls.last?.code, P1CloseCode.normalClosure.rawValue)
    }

    // MARK: - Unary RPC

    @MainActor
    func testUnaryCorrelatesConcurrentOutOfOrderResponses() async throws {
        let factory = SocketFactory()
        let rpcIds = respondToHelloAndCollectRPCs(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        let slow = Task { try await channel.unary(endpoint: "session/page", args: ["delay": .int(40)], timeout: 2) }
        let fast = Task { try await channel.unary(endpoint: "session/list", args: ["delay": .int(0)], timeout: 2) }
        await waitUntil { rpcIds().count == 2 }

        let ids = rpcIds()
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertEqual(socket.sentFrames(type: "rpc").count, 2)
        let firstRPC = try XCTUnwrap(socket.sentFrames(type: "rpc").first)
        XCTAssertEqual(firstRPC["endpoint"] as? String, "session/page")
        let body = try XCTUnwrap(firstRPC["body"] as? [String: Any])
        XCTAssertEqual(body["type"] as? String, "client-request")
        XCTAssertEqual(body["method"] as? String, "session/page")

        // Answer in reverse order: the channel must correlate by id.
        socket.receive(Self.rpcResultJSON(id: ids[1], body: #"{"marker":"second"}"#))
        socket.receive(Self.rpcResultJSON(id: ids[0], body: #"{"marker":"first"}"#))

        let slowResult = try await slow.value
        let fastResult = try await fast.value
        XCTAssertNotEqual(slowResult.id, fastResult.id)
        XCTAssertEqual(Set([slowResult.id, fastResult.id]), Set(ids))
        let markers = [ids[1]: "second", ids[0]: "first"]
        XCTAssertEqual(slowResult.body?["marker"]?.stringValue, markers[slowResult.id])
        XCTAssertEqual(fastResult.body?["marker"]?.stringValue, markers[fastResult.id])
    }

    @MainActor
    func testUnaryPassesThroughHTTPStatusAndBody() async throws {
        let factory = SocketFactory()
        let rpcIds = respondToHelloAndCollectRPCs(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        let task = Task { try await channel.unary(endpoint: "session/list", args: [:], timeout: 2) }
        await waitUntil { rpcIds().count == 1 }
        let id = try XCTUnwrap(rpcIds().first)
        socket.receive(Self.rpcResultJSON(
            id: id,
            status: 500,
            contentType: "application/json; charset=utf-8",
            body: #"{"type":"server-response","error":{"code":"host/boom","message":"nope"}}"#
        ))

        let result = try await task.value
        XCTAssertEqual(result.status, 500, "HTTP 状态原样透传，不抛错")
        XCTAssertEqual(result.contentType, "application/json; charset=utf-8")
        XCTAssertEqual(result.body?["type"], .string("server-response"))
        XCTAssertEqual(result.body?["error"]?["code"], .string("host/boom"))
    }

    @MainActor
    func testUnaryThrowsOnRPCError() async throws {
        let factory = SocketFactory()
        let rpcIds = respondToHelloAndCollectRPCs(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        let task = Task { try await channel.unary(endpoint: "session/list", args: [:], timeout: 2) }
        await waitUntil { rpcIds().count == 1 }
        let id = try XCTUnwrap(rpcIds().first)
        socket.receive(Self.rpcErrorJSON(id: id, code: "upstream/failed", message: "boom"))

        do {
            _ = try await task.value
            XCTFail("rpc/error 必须抛错")
        } catch {
            XCTAssertEqual(error as? P1Failure, .rpcError(
                id: id,
                error: RemoteError(code: "upstream/failed", message: "boom")
            ))
        }
    }

    @MainActor
    func testUnaryTimeoutDropsLateResponseAndKeepsChannelUsable() async throws {
        let factory = SocketFactory()
        let rpcIds = respondToHelloAndCollectRPCs(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        do {
            _ = try await channel.unary(endpoint: "session/list", args: [:], timeout: 0.05)
            XCTFail("超时必须抛错")
        } catch {
            XCTAssertEqual(error as? P1Failure, .timeout("rpc"))
        }
        XCTAssertEqual(rpcIds().count, 1)
        let staleID = try XCTUnwrap(rpcIds().first)
        // A late response must be dropped without corrupting state.
        socket.receive(Self.rpcResultJSON(id: staleID, body: #"{"late":true}"#))
        XCTAssertEqual(channel.state, .ready)
        XCTAssertEqual(channel.lastAppliedSid, 0)

        // The channel keeps working for the next call.
        let task = Task { try await channel.unary(endpoint: "session/list", args: [:], timeout: 2) }
        await waitUntil { rpcIds().count == 2 }
        let liveID = try XCTUnwrap(rpcIds().last)
        socket.receive(Self.rpcResultJSON(id: liveID, body: #"{"late":false}"#))
        let result = try await task.value
        XCTAssertEqual(result.id, liveID)
        XCTAssertEqual(result.body?["late"], .bool(false))
    }

    @MainActor
    func testUnaryCancellation() async throws {
        let factory = SocketFactory()
        let rpcIds = respondToHelloAndCollectRPCs(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))

        let task = Task { try await channel.unary(endpoint: "session/list", args: [:], timeout: 5) }
        await waitUntil { rpcIds().count == 1 }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消必须抛错")
        } catch {
            XCTAssertEqual(error as? P1Failure, .cancelled)
        }
        XCTAssertEqual(channel.state, .ready)
    }

    @MainActor
    func testUnaryFailsWhenSocketCloses() async throws {
        let factory = SocketFactory()
        let rpcIds = respondToHelloAndCollectRPCs(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        let task = Task { try await channel.unary(endpoint: "session/list", args: [:], timeout: 5) }
        await waitUntil { rpcIds().count == 1 }

        var closes: [P1Failure] = []
        channel.onClose = { closes.append($0) }
        socket.drop(code: P1CloseCode.upstreamClosed.rawValue, reason: "upstream closed")

        let expected = P1Failure.upstreamClosed(code: 1011, reason: "upstream closed")
        do {
            _ = try await task.value
            XCTFail("断线必须让在飞 unary 失败")
        } catch {
            XCTAssertEqual(error as? P1Failure, expected)
        }
        XCTAssertEqual(closes, [expected])
        XCTAssertEqual(channel.lastFailure, expected)
        XCTAssertEqual(channel.state, .closed)
    }

    @MainActor
    func testTransportRejectsCallsBeforeReady() async throws {
        let factory = SocketFactory()
        let channel = makeChannel(factory)

        do {
            _ = try await channel.unary(endpoint: "session/list", args: [:])
            XCTFail("未连接时 unary 必须抛错")
        } catch {
            XCTAssertEqual(error as? P1Failure, .notConnected)
        }
        XCTAssertThrowsError(try channel.openStream(endpoint: "session/follow")) { error in
            XCTAssertEqual(error as? P1Failure, .notConnected)
        }
        XCTAssertTrue(channel.openStreams.isEmpty)
    }

    // MARK: - Streams

    @MainActor
    func testOpenStreamDispatchesItemsAndEndInOrder() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        var items: [JSONValue?] = []
        var ended = false
        let handle = try channel.openStream(
            streamId: "s1",
            endpoint: "session/follow",
            args: ["a": .int(1)],
            onItem: { items.append($0) },
            onEnd: { ended = true }
        )

        let open = try XCTUnwrap(socket.sentFrames(type: "open").first)
        XCTAssertEqual(open["type"] as? String, "open")
        XCTAssertEqual(open["streamId"] as? String, "s1")
        XCTAssertEqual(open["endpoint"] as? String, "session/follow")
        let payload = try XCTUnwrap(open["payload"] as? [String: Any])
        XCTAssertEqual((payload["args"] as? [String: Any])?["a"] as? Int, 1)
        XCTAssertEqual(channel.openStreams.map(\.streamId), ["s1"])
        XCTAssertTrue(handle.isOpen)
        XCTAssertEqual(handle.endpoint, "session/follow")

        socket.receive(Self.downJSON(sid: 1, frame: Self.itemFrame(value: #"{"type":"snapshot","cursor":2}"#)))
        socket.receive(Self.downJSON(sid: 2, frame: Self.itemFrame(value: #"{"type":"event","seq":3}"#)))
        socket.receive(Self.downJSON(sid: 3, frame: Self.endFrame()))

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]?["type"], .string("snapshot"))
        XCTAssertEqual(items[0]?["cursor"], .int(2))
        XCTAssertEqual(items[1]?["type"], .string("event"))
        XCTAssertTrue(ended)
        XCTAssertFalse(handle.isOpen)
        XCTAssertTrue(channel.openStreams.isEmpty)
        XCTAssertEqual(channel.lastAppliedSid, 3)
    }

    @MainActor
    func testStreamErrorDeliversRemoteErrorAndRemovesStream() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        var errors: [RemoteError] = []
        let handle = try channel.openStream(
            streamId: "s1",
            endpoint: "assistant/stream",
            onError: { errors.append($0) }
        )
        socket.receive(Self.downJSON(sid: 1, frame: Self.errorFrame(code: "agent/cancelled", message: "stopped")))

        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.code, "agent/cancelled")
        XCTAssertEqual(errors.first?.message, "stopped")
        XCTAssertFalse(handle.isOpen)
        XCTAssertTrue(channel.openStreams.isEmpty)
    }

    @MainActor
    func testDuplicateDownFramesAreIdempotent() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        var items: [JSONValue?] = []
        _ = try channel.openStream(streamId: "s1", endpoint: "session/follow", onItem: { items.append($0) })

        socket.receive(Self.downJSON(sid: 1, frame: Self.itemFrame(value: #"{"n":1}"#)))
        socket.receive(Self.downJSON(sid: 1, frame: Self.itemFrame(value: #"{"n":1}"#)))
        XCTAssertEqual(items.count, 1, "重放重叠的 sid 不能重复渲染")
        XCTAssertEqual(channel.lastAppliedSid, 1)

        socket.receive(Self.downJSON(sid: 2, frame: Self.itemFrame(value: #"{"n":2}"#)))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(channel.lastAppliedSid, 2)
    }

    @MainActor
    func testDownSIDGapIsProtocolViolation() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        var closes: [P1Failure] = []
        channel.onClose = { closes.append($0) }

        socket.receive(Self.downJSON(sid: 2, frame: Self.itemFrame()))

        XCTAssertEqual(channel.state, .closed)
        XCTAssertEqual(closes.count, 1)
        guard case .protocolViolation(let message) = try XCTUnwrap(closes.first) else {
            return XCTFail("期望 protocolViolation，实际 \(String(describing: closes.first))")
        }
        XCTAssertTrue(message.contains("序号缺口"), message)
        XCTAssertEqual(socket.closeCalls.last?.code, 1002)
    }

    @MainActor
    func testDuplicateStreamIdIsRejected() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))

        _ = try channel.openStream(streamId: "s1", endpoint: "session/follow")
        XCTAssertThrowsError(try channel.openStream(streamId: "s1", endpoint: "session/follow")) { error in
            guard let protocolError = error as? P1ProtocolError, case .violation = protocolError else {
                return XCTFail("期望协议违例，实际 \(error)")
            }
        }
    }

    @MainActor
    func testStreamCancelSendsCancelAndDropsDescriptor() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        let handle = try channel.openStream(streamId: "s1", endpoint: "session/follow")
        handle.cancel()

        XCTAssertEqual(socket.sentFrames(type: "cancel").first?["streamId"] as? String, "s1")
        XCTAssertFalse(handle.isOpen)
        XCTAssertTrue(channel.openStreams.isEmpty)
    }

    @MainActor
    func testStreamUplinkItemAndEndKeepStreamOpen() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        let handle = try channel.openStream(streamId: "s1", endpoint: "$events")
        try handle.sendItem(.object(["k": .string("v")]))
        try handle.sendItem(nil)

        let items = socket.sentFrames(type: "item")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["streamId"] as? String, "s1")
        XCTAssertEqual((items[0]["value"] as? [String: Any])?["k"] as? String, "v")
        XCTAssertNil(items[1]["value"], "nil item 不带 value 字段")

        handle.end()
        XCTAssertEqual(socket.sentFrames(type: "end").first?["streamId"] as? String, "s1")
        XCTAssertTrue(handle.isOpen, "end 只关闭上行方向，下行还可继续")
        XCTAssertEqual(channel.openStreams.map(\.streamId), ["s1"])
    }

    @MainActor
    func testOpenStreamSendFailureRollsBack() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        socket.sendError = LinkError.notConnected
        XCTAssertThrowsError(try channel.openStream(streamId: "s1", endpoint: "session/follow")) { error in
            XCTAssertEqual(error as? P1Failure, .notConnected)
        }
        XCTAssertTrue(channel.openStreams.isEmpty)
    }

    @MainActor
    func testUnknownDownStreamFramesStillAdvanceSid() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        socket.receive(Self.downJSON(sid: 1, frame: #"{"type":"cancel","streamId":"ghost"}"#))
        socket.receive(#"{"type":"pong","ts":1}"#)

        XCTAssertEqual(channel.state, .ready)
        XCTAssertEqual(channel.lastAppliedSid, 1)
    }

    // MARK: - Resume

    @MainActor
    func testResumeReplayDeliversMissingFramesAndKeepsStreams() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let firstSocket = try XCTUnwrap(factory.last)

        var items: [JSONValue?] = []
        _ = try channel.openStream(streamId: "s1", endpoint: "session/follow", onItem: { items.append($0) })
        firstSocket.receive(Self.downJSON(sid: 1, frame: Self.itemFrame(value: #"{"n":1}"#)))
        XCTAssertEqual(items.count, 1)

        var closes: [P1Failure] = []
        channel.onClose = { closes.append($0) }
        firstSocket.drop(code: P1CloseCode.abnormalClosure.rawValue, reason: "network lost")
        XCTAssertEqual(closes.count, 1)

        let cursor = try XCTUnwrap(channel.resumeState)
        XCTAssertEqual(cursor, P1ResumeCursor(logEpoch: "epoch-1", sid: 1))

        // Reconnect: welcome + the two missed frames arrive before `connect` returns.
        factory.configure = { socket in
            socket.onSend = { text in
                guard Self.frameType(text) == "hello" else { return }
                socket.receive(Self.welcomeJSON(sid: 3, resume: #"{"ok":true,"mode":"replay","replayed":2}"#))
                socket.receive(Self.downJSON(sid: 2, frame: Self.itemFrame(value: #"{"n":2}"#)))
                socket.receive(Self.downJSON(sid: 3, frame: Self.itemFrame(value: #"{"n":3}"#)))
            }
        }
        let welcome = try await channel.connect(auth: P1Auth(ticket: "rotated"), resume: cursor)

        XCTAssertEqual(welcome.resume.mode, .replay)
        XCTAssertEqual(welcome.resume.replayed, 2)
        XCTAssertEqual(items.count, 3, "恢复后按序应用重放帧")
        XCTAssertEqual(items.compactMap { $0?["n"] }, [.int(1), .int(2), .int(3)])
        XCTAssertEqual(channel.lastAppliedSid, 3)
        XCTAssertEqual(channel.resumeState, P1ResumeCursor(logEpoch: "epoch-1", sid: 3))
        XCTAssertTrue(channel.isStreamOpen("s1"), "replay 成功后原流继续有效")
        XCTAssertEqual(channel.openStreams.map(\.streamId), ["s1"])

        let helloResume = try XCTUnwrap(factory.last?.sentFrames(type: "hello").first?["resume"] as? [String: Any])
        XCTAssertEqual(helloResume["logEpoch"] as? String, "epoch-1")
        XCTAssertEqual(helloResume["sid"] as? Int, 1)
    }

    @MainActor
    func testResumeResetClearsCursorAndInvalidatesHandlesButKeepsDescriptors() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let firstSocket = try XCTUnwrap(factory.last)

        var items: [JSONValue?] = []
        let handle = try channel.openStream(streamId: "s1", endpoint: "session/follow", onItem: { items.append($0) })
        firstSocket.receive(Self.downJSON(sid: 1, frame: Self.itemFrame(value: #"{"n":1}"#)))
        let cursor = try XCTUnwrap(channel.resumeState)
        firstSocket.drop(code: P1CloseCode.abnormalClosure.rawValue)

        factory.configure = { socket in
            socket.onSend = { text in
                guard Self.frameType(text) == "hello" else { return }
                socket.receive(Self.welcomeJSON(
                    epoch: "epoch-2",
                    sid: 0,
                    resume: #"{"ok":false,"mode":"reset","reason":"epoch-mismatch"}"#
                ))
            }
        }
        let welcome = try await channel.connect(auth: P1Auth(ticket: "rotated"), resume: cursor)

        XCTAssertEqual(welcome.resume.mode, .reset)
        XCTAssertEqual(welcome.resume.reason, "epoch-mismatch")
        XCTAssertEqual(channel.epoch, "epoch-2")
        XCTAssertEqual(channel.lastAppliedSid, 0, "reset 后 sid 从 0 重新开始")
        XCTAssertEqual(channel.resumeState, P1ResumeCursor(logEpoch: "epoch-2", sid: 0))
        XCTAssertFalse(handle.isOpen, "旧 epoch 的句柄失效")
        XCTAssertEqual(channel.openStreams.map(\.streamId), ["s1"], "描述表保留，供上层重开")
        XCTAssertThrowsError(try handle.sendItem(.string("x"))) { error in
            XCTAssertEqual(error as? P1Failure, .notConnected)
        }

        // Re-opening with the same descriptor (new epoch) works and dispatches again.
        let secondSocket = try XCTUnwrap(factory.last)
        var reopenedItems: [JSONValue?] = []
        let reopened = try channel.openStream(
            streamId: "s1",
            endpoint: "session/follow",
            onItem: { reopenedItems.append($0) }
        )
        XCTAssertTrue(reopened.isOpen)
        XCTAssertEqual(channel.openStreams.map(\.streamId), ["s1"], "重开后描述表不重复")
        secondSocket.receive(Self.downJSON(sid: 1, frame: Self.itemFrame(value: #"{"n":9}"#)))
        XCTAssertEqual(reopenedItems.count, 1)
        XCTAssertEqual(channel.lastAppliedSid, 1)
    }

    @MainActor
    func testFreshReconnectWithoutResumeResetsCursorAndStreams() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let firstSocket = try XCTUnwrap(factory.last)

        let handle = try channel.openStream(streamId: "s1", endpoint: "workspace/follow")
        firstSocket.receive(Self.downJSON(sid: 1, frame: Self.itemFrame()))
        firstSocket.drop(code: P1CloseCode.abnormalClosure.rawValue)

        respondWithWelcome(factory, epoch: "epoch-2", sid: 0)
        let welcome = try await channel.connect(auth: P1Auth(ticket: "ticket-2"))

        XCTAssertEqual(welcome.resume.mode, .fresh)
        XCTAssertEqual(channel.epoch, "epoch-2")
        XCTAssertEqual(channel.lastAppliedSid, 0)
        XCTAssertFalse(handle.isOpen)
        XCTAssertEqual(channel.openStreams.map(\.streamId), ["s1"])
        let hello = try XCTUnwrap(factory.last?.sentFrames(type: "hello").first)
        XCTAssertNil(hello["resume"])
    }

    // MARK: - Protocol violations / close codes

    @MainActor
    func testDuplicateWelcomeIsProtocolViolation() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        var closes: [P1Failure] = []
        channel.onClose = { closes.append($0) }
        socket.receive(Self.welcomeJSON())

        XCTAssertEqual(channel.state, .closed)
        XCTAssertEqual(closes.count, 1)
        guard case .protocolViolation(let message) = try XCTUnwrap(closes.first) else {
            return XCTFail("期望 protocolViolation")
        }
        XCTAssertTrue(message.contains("welcome"), message)
        XCTAssertEqual(socket.closeCalls.last?.code, 1002)
    }

    @MainActor
    func testProtocolViolationFailsPendingUnaryAndClosesSocket() async throws {
        let factory = SocketFactory()
        let rpcIds = respondToHelloAndCollectRPCs(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        let task = Task { try await channel.unary(endpoint: "session/list", args: [:], timeout: 5) }
        await waitUntil { rpcIds().count == 1 }

        var closes: [P1Failure] = []
        channel.onClose = { closes.append($0) }
        socket.receive("not-json")

        do {
            _ = try await task.value
            XCTFail("协议违例必须让在飞 unary 失败")
        } catch {
            guard case .protocolViolation = try XCTUnwrap(error as? P1Failure) else {
                return XCTFail("期望 protocolViolation，实际 \(error)")
            }
        }
        XCTAssertEqual(closes.count, 1)
        XCTAssertEqual(socket.closeCalls.last?.code, 1002)
        XCTAssertEqual(channel.state, .closed)
    }

    @MainActor
    func testOversizedInboundFrameClosesWith1009() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory, maxFrameBytes: 512)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let socket = try XCTUnwrap(factory.last)

        var closes: [P1Failure] = []
        channel.onClose = { closes.append($0) }
        let huge = String(repeating: "x", count: 600)
        socket.receive(Self.downJSON(sid: 1, frame: Self.itemFrame(value: Self.jsonEscape(huge))))

        XCTAssertEqual(channel.state, .closed)
        XCTAssertEqual(closes.count, 1)
        guard case .frameTooLarge = try XCTUnwrap(closes.first) else {
            return XCTFail("期望 frameTooLarge")
        }
        XCTAssertEqual(socket.closeCalls.last?.code, P1CloseCode.frameTooLarge.rawValue)
    }

    @MainActor
    func testCloseCodesAfterReadyMapToFailuresExactlyOnce() async throws {
        let cases: [(code: Int, expected: P1Failure)] = [
            (P1CloseCode.protocolViolation.rawValue, .fallbackLegacy(code: 4400, reason: "r")),
            (P1CloseCode.binaryFrame.rawValue, .fallbackLegacy(code: 4403, reason: "r")),
            (P1CloseCode.authFailed.rawValue, .authRetry(code: 4401, reason: "r")),
            (P1CloseCode.helloRequired.rawValue, .helloRequired(code: 4408, reason: "r")),
            (P1CloseCode.connectionConflict.rawValue, .connectionConflict(code: 4409, reason: "r")),
            (P1CloseCode.upstreamClosed.rawValue, .upstreamClosed(code: 1011, reason: "r")),
            (P1CloseCode.bufferOverflow.rawValue, .bufferOverflow(code: 1013, reason: "r")),
            (P1CloseCode.frameTooLarge.rawValue, .frameTooLarge(reason: "r")),
            (P1CloseCode.abnormalClosure.rawValue, .socketClosed(code: 1006, reason: "r")),
        ]
        for entry in cases {
            let factory = SocketFactory()
            respondWithWelcome(factory)
            let channel = makeChannel(factory)
            _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
            let socket = try XCTUnwrap(factory.last)
            var closes: [P1Failure] = []
            channel.onClose = { closes.append($0) }

            socket.drop(code: entry.code, reason: "r")

            XCTAssertEqual(channel.lastFailure, entry.expected, "close \(entry.code)")
            XCTAssertEqual(closes, [entry.expected], "close \(entry.code) onClose 只回调一次")
            XCTAssertEqual(channel.state, .closed, "close \(entry.code)")

            // A late second close event for the dead socket is ignored.
            socket.drop(code: entry.code, reason: "r")
            XCTAssertEqual(closes.count, 1, "close \(entry.code) 重复事件被忽略")
        }
    }

    // MARK: - Dual-stack stream adapter (task-10 P1-3)

    /// `LinkService.openStream` is typed `RemoteStreamHandle`; `P1StreamHandle`
    /// must provide the legacy `send/end/cancel` surface and emit the exact same
    /// mux frames the M1 path sends (open / item / end / cancel).
    @MainActor
    func testP1StreamHandleConformsToRemoteStreamHandle() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))

        let handle: RemoteStreamHandle = try channel.openStream(
            endpoint: "workspace/follow",
            args: [:]
        )
        XCTAssertEqual(handle.endpoint, "workspace/follow")
        XCTAssertFalse(handle.streamId.isEmpty)
        XCTAssertTrue(channel.isStreamOpen(handle.streamId))

        try handle.send(value: .object(["type": .string("ping")]))
        handle.end()
        XCTAssertTrue(channel.isStreamOpen(handle.streamId), "end 是半关闭，下行仍可继续")
        handle.cancel()
        XCTAssertFalse(channel.isStreamOpen(handle.streamId))

        let socket = try XCTUnwrap(factory.last)
        let open = try XCTUnwrap(socket.sentFrames(type: "open").first)
        XCTAssertEqual(open["streamId"] as? String, handle.streamId)
        XCTAssertEqual(open["endpoint"] as? String, "workspace/follow")
        let item = try XCTUnwrap(socket.sentFrames(type: "item").first)
        XCTAssertEqual(item["streamId"] as? String, handle.streamId)
        XCTAssertEqual((item["value"] as? [String: Any])?["type"] as? String, "ping")
        XCTAssertEqual(socket.sentFrames(type: "end").count, 1)
        XCTAssertEqual(socket.sentFrames(type: "cancel").count, 1)
    }
}

// MARK: - LinkService dual-stack seams (task-10 P1-3)

/// Pure seams introduced by the P1 dual-stack integration: the flag/capability
/// routing matrix, `ConnectionMetrics` P1 fields and the `rpc/result` +
/// `rpc/error` → legacy `JSONValue`/`LinkError` mapping. No sockets involved.
final class LinkServiceP1IntegrationTests: XCTestCase {

    // MARK: - Routing decision

    func testTransportRouteMatrix() {
        XCTAssertEqual(
            LinkService.transportRoute(flagEnabled: false, supportsMuxRPC: true, fellBackToLegacy: false),
            .legacy,
            "flag 关 → 旧路径"
        )
        XCTAssertEqual(
            LinkService.transportRoute(flagEnabled: true, supportsMuxRPC: nil, fellBackToLegacy: false),
            .legacy,
            "旧插件无能力 → 旧路径"
        )
        XCTAssertEqual(
            LinkService.transportRoute(flagEnabled: true, supportsMuxRPC: false, fellBackToLegacy: false),
            .legacy,
            "能力不符 → 旧路径"
        )
        XCTAssertEqual(
            LinkService.transportRoute(flagEnabled: true, supportsMuxRPC: true, fellBackToLegacy: true),
            .legacy,
            "会话级回退后不再探测 P1"
        )
        XCTAssertEqual(
            LinkService.transportRoute(flagEnabled: true, supportsMuxRPC: true, fellBackToLegacy: false),
            .p1,
            "flag + 能力 + 无回退 → P1"
        )
    }

    // MARK: - `rpc/result` → JSONValue / LinkError

    func testRPCResultMapsToLegacyJSONValue() throws {
        let result = try decodeResult(
            #"{"type":"rpc/result","id":"r1","status":200,"contentType":"application/json","body":{"type":"server-response","rpcId":"r1","result":{"ok":true,"value":{"sessions":[{"sessionId":"s1"}]}}}}"#
        )
        let value = try P1UnaryMapping.jsonValue(from: result)
        XCTAssertEqual(value["sessions"]?[0]?["sessionId"]?.stringValue, "s1")
    }

    func testRPCResultBusinessErrorMapsToRemote() throws {
        let result = try decodeResult(
            #"{"type":"rpc/result","id":"r1","status":200,"body":{"type":"server-response","rpcId":"r1","result":{"ok":false,"error":{"code":"agent/failed","message":"boom"}}}}"#
        )
        XCTAssertThrowsError(try P1UnaryMapping.jsonValue(from: result)) { error in
            guard let linkError = error as? LinkError, case .remote(let remote) = linkError else {
                return XCTFail("期望 LinkError.remote，实际 \(error)")
            }
            XCTAssertEqual(remote.code, "agent/failed")
            XCTAssertEqual(remote.message, "boom")
        }
    }

    func testRPCResultNon200MapsToHTTPStatusWithBody() throws {
        let result = try decodeResult(
            #"{"type":"rpc/result","id":"r2","status":404,"body":{"error":"changes/not-found"}}"#
        )
        XCTAssertThrowsError(try P1UnaryMapping.jsonValue(from: result)) { error in
            guard let linkError = error as? LinkError, case .httpStatus(let status, let body) = linkError else {
                return XCTFail("期望 LinkError.httpStatus，实际 \(error)")
            }
            XCTAssertEqual(status, 404)
            // JSONEncoder escapes "/" as "\/"; assert on the unescaped tail.
            XCTAssertTrue(body.contains("not-found"), "body=\(body)")
            XCTAssertTrue(body.contains("error"), "body=\(body)")
        }
    }

    func testRPCResultBodyTextAndWrongEnvelopeAreMalformed() throws {
        let textBody = try decodeResult(
            #"{"type":"rpc/result","id":"r3","status":200,"bodyText":"not json"}"#
        )
        assertMalformed(try P1UnaryMapping.jsonValue(from: textBody))

        let wrongType = try decodeResult(
            #"{"type":"rpc/result","id":"r4","status":200,"body":{"type":"other","rpcId":"r4","result":{"ok":true,"value":1}}}"#
        )
        assertMalformed(try P1UnaryMapping.jsonValue(from: wrongType))
    }

    // MARK: - `rpc/error` / channel failures → LinkError

    func testRPCErrorMapsToRemoteTransportOrTimeout() {
        XCTAssertEqual(
            P1UnaryMapping.linkError(from: .rpcError(id: "r", error: RemoteError(code: "rpc/busy", message: "busy"))),
            .remote(RemoteError(code: "rpc/busy", message: "busy"))
        )
        XCTAssertEqual(
            P1UnaryMapping.linkError(from: .rpcError(id: "r", error: RemoteError(code: "upstream/failed", message: "mux down"))),
            .transport("mux down")
        )
        XCTAssertEqual(
            P1UnaryMapping.linkError(from: .rpcError(id: "r", error: RemoteError(code: "rpc/timeout", message: ""))),
            .timeout("rpc")
        )
        XCTAssertEqual(P1UnaryMapping.linkError(from: .notConnected), .notConnected)
        XCTAssertEqual(P1UnaryMapping.linkError(from: .cancelled), .cancelled)
        XCTAssertEqual(
            P1UnaryMapping.linkError(from: .protocolViolation("bad")),
            .transport("dsh-m/2 协议异常：bad")
        )
        XCTAssertEqual(
            P1UnaryMapping.linkError(from: .socketClosed(code: 1006, reason: "")),
            .transport("dsh-m/2 连接关闭（close 1006）")
        )
    }

    // MARK: - ConnectionMetrics P1 fields

    @MainActor
    func testConnectionMetricsRecordsP1Fields() throws {
        ConnectionMetrics.forceEnabledForTesting = true
        defer {
            ConnectionMetrics.forceEnabledForTesting = nil
            ConnectionMetrics.reset()
        }

        // Legacy default stays comparable with P1 rounds (design §5).
        ConnectionMetrics.begin(preferRelay: false)
        ConnectionMetrics.markConnected()
        XCTAssertTrue(
            try XCTUnwrap(ConnectionMetrics.valueString)
                .contains("proto=1;authMode=ecdsa;resumeMode=-;fallbackLegacy=0")
        )

        // P1 success: proto/authMode/resumeMode come from the welcome.
        ConnectionMetrics.begin(preferRelay: true)
        ConnectionMetrics.markCandidate("relay.example")
        ConnectionMetrics.markAuth()
        ConnectionMetrics.markWS()
        ConnectionMetrics.markP1(authMode: "ticket", resumeMode: "replay")
        ConnectionMetrics.markReady()
        ConnectionMetrics.markConnected()
        let p1Value = try XCTUnwrap(ConnectionMetrics.valueString)
        XCTAssertTrue(p1Value.contains("connectMs="), "旧字段不回归：\(p1Value)")
        XCTAssertTrue(p1Value.contains("proto=2"))
        XCTAssertTrue(p1Value.contains("authMode=ticket"))
        XCTAssertTrue(p1Value.contains("resumeMode=replay"))
        XCTAssertTrue(p1Value.contains("fallbackLegacy=0"))

        // A round that fell back from dsh-m/2 to M1 reports the fallback.
        ConnectionMetrics.begin(preferRelay: false)
        ConnectionMetrics.markFallbackLegacy()
        let fallbackValue = try XCTUnwrap(ConnectionMetrics.valueString)
        XCTAssertTrue(fallbackValue.contains("proto=1"))
        XCTAssertTrue(fallbackValue.contains("authMode=ecdsa"))
        XCTAssertTrue(fallbackValue.contains("fallbackLegacy=1"))
    }

    // MARK: - Helpers

    private func decodeResult(_ json: String) throws -> P1RPCResult {
        try JSONDecoder().decode(P1RPCResult.self, from: Data(json.utf8))
    }

    private func assertMalformed(
        _ expression: @autoclosure () throws -> JSONValue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let linkError = error as? LinkError, case .malformedEnvelope = linkError else {
                return XCTFail("期望 LinkError.malformedEnvelope，实际 \(error)", file: file, line: line)
            }
        }
    }
}
