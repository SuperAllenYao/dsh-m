import Foundation
import XCTest
@testable import DSHm

/// dsh-m/2 protocol codec tests: frame encoding (byte-identical to the plugin's
/// expectations), strict server-frame decoding, close-code semantics and the
/// 32 MiB message cap. No sockets involved.
final class P1ProtocolTests: XCTestCase {

    // MARK: - Helpers

    private func encodedObject(_ frame: P1ClientFrame) throws -> [String: JSONValue] {
        let text = try P1FrameCodec.encodeText(frame)
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        return try XCTUnwrap(value.objectValue)
    }

    private func decode(_ text: String) throws -> P1ServerFrame {
        try P1FrameCodec.decodeServerFrame(text)
    }

    private func assertViolation(
        _ body: @autoclosure () throws -> Any,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), message, file: file, line: line) { error in
            guard let protocolError = error as? P1ProtocolError else {
                XCTFail("期望 P1ProtocolError，实际 \(type(of: error)): \(error)", file: file, line: line)
                return
            }
            if case .frameTooLarge = protocolError {
                XCTFail("期望协议违例，实际 frameTooLarge", file: file, line: line)
            }
        }
    }

    private func welcomeJSON(
        v: Int = 2,
        proto: String = "dsh-m/2",
        deviceId: String = "dev-1",
        epoch: String = "epoch-1",
        sid: Int64 = 0,
        resume: String = #"{"ok":true,"mode":"fresh"}"#,
        caps: String = #"{"unary":true,"resume":true,"maxInFlight":8,"replayBytes":4194304}"#,
        ticket: String? = "ticket-1"
    ) -> String {
        let ticketField = ticket.map { ",\"ticket\":\"\($0)\"" } ?? ""
        return """
        {"type":"welcome","v":\(v),"proto":"\(proto)","deviceId":"\(deviceId)","epoch":"\(epoch)","sid":\(sid),\
        "resume":\(resume),"caps":\(caps)\(ticketField)}
        """
    }

    // MARK: - Client frame encoding

    func testHelloEncodingCarriesClientAuthAndResume() throws {
        let frame = P1ClientFrame.hello(P1Hello(
            client: P1ClientInfo(name: "dsh-m-ios", version: "0.1.0"),
            auth: P1Auth(ticket: "ticket-a", muxToken: "token-b"),
            resume: P1ResumeCursor(logEpoch: "epoch-1", sid: 7)
        ))
        let object = try encodedObject(frame)
        XCTAssertEqual(object["type"], .string("hello"))
        XCTAssertEqual(object["v"], .int(2))
        XCTAssertEqual(object["client"], .object([
            "name": .string("dsh-m-ios"),
            "version": .string("0.1.0"),
        ]))
        XCTAssertEqual(object["auth"], .object([
            "ticket": .string("ticket-a"),
            "muxToken": .string("token-b"),
        ]))
        XCTAssertEqual(object["resume"], .object([
            "logEpoch": .string("epoch-1"),
            "sid": .int(7),
        ]))
    }

    func testHelloOmitsNilOptionals() throws {
        let frame = P1ClientFrame.hello(P1Hello(
            client: P1ClientInfo(name: "dsh-m-ios"),
            auth: P1Auth(muxToken: "token-b")
        ))
        let object = try encodedObject(frame)
        XCTAssertNil(object["resume"], "未带 resume 时不能编码 resume 字段（插件会把它当成新 epoch）")
        XCTAssertEqual(object["client"], .object(["name": .string("dsh-m-ios")]))
        XCTAssertEqual(object["auth"], .object(["muxToken": .string("token-b")]))
    }

    func testHelloRejectsInvalidPayloads() {
        assertViolation(try encodedObject(.hello(P1Hello(client: P1ClientInfo(name: ""), auth: P1Auth(ticket: "t")))))
        assertViolation(try encodedObject(.hello(P1Hello(client: P1ClientInfo(name: "x"), auth: P1Auth()))))
        assertViolation(try encodedObject(.hello(P1Hello(
            client: P1ClientInfo(name: "x"),
            auth: P1Auth(ticket: "t"),
            resume: P1ResumeCursor(logEpoch: "", sid: 0)
        ))))
        assertViolation(try encodedObject(.hello(P1Hello(
            client: P1ClientInfo(name: "x"),
            auth: P1Auth(ticket: "t"),
            resume: P1ResumeCursor(logEpoch: "epoch-1", sid: -1)
        ))))
    }

    func testRPCBodyIsTheLegacyClientRequestEnvelope() throws {
        let id = "rpc-1"
        let endpoint = "session/list"
        let args: [String: JSONValue] = ["limit": .int(10), "q": .string("hi")]
        let object = try encodedObject(.rpc(P1RPCCall(id: id, endpoint: endpoint, args: args)))
        XCTAssertEqual(object["type"], .string("rpc"))
        XCTAssertEqual(object["id"], .string(id))
        XCTAssertEqual(object["endpoint"], .string(endpoint))

        // Byte-identical to the M1 unary body built by ClientRequestEnvelope.
        let envelope = ClientRequestEnvelope(rpcId: id, method: endpoint, args: args)
        let expected = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(envelope))
        XCTAssertEqual(object["body"], expected)
        XCTAssertNil(object["headers"], "没有 headers 时不能编码空对象")
    }

    func testRPCHeadersAndValidation() throws {
        let call = P1RPCCall(
            id: "rpc-2",
            endpoint: "session/page",
            body: P1ClientRequestBody.encode(rpcId: "rpc-2", method: "session/page", args: [:]),
            headers: ["accept-encoding": "identity"]
        )
        let object = try encodedObject(.rpc(call))
        XCTAssertEqual(object["headers"], .object(["accept-encoding": .string("identity")]))

        assertViolation(try encodedObject(.rpc(P1RPCCall(
            id: "x",
            endpoint: "session/list",
            body: P1ClientRequestBody.encode(rpcId: "x", method: "session/list", args: [:])
        ).withId(String(repeating: "a", count: P1ProtocolLimits.maxRPCIdLength + 1)))))
        assertViolation(try encodedObject(.rpc(P1RPCCall(
            id: "x",
            endpoint: "not-an-endpoint",
            body: .object([:])
        ))))
        assertViolation(try encodedObject(.rpc(P1RPCCall(
            id: "x",
            endpoint: "session/list",
            body: .string("not-an-object")
        ))))
    }

    func testMuxFramesStayByteIdenticalToLegacyRemoteFrames() throws {
        let frames: [MuxFrame] = [
            .open(streamId: "s1", endpoint: "session/follow", args: ["a": .int(1)]),
            // `$events` has no namespace slash: mux endpoints are forwarded
            // verbatim and must not be validated as unary `ns/method` endpoints.
            .open(streamId: "s2", endpoint: "$events", args: [:]),
            .item(streamId: "s1", value: .object(["type": .string("snapshot")])),
            .item(streamId: "s1", value: nil),
            .end(streamId: "s1"),
            .cancel(streamId: "s1"),
        ]
        for frame in frames {
            let legacy = try frame.encodedJSON()
            let encoded = try encodedObject(.mux(frame))
            XCTAssertEqual(JSONValue.object(encoded), legacy, "P1 只是加 envelope，上行帧必须与旧协议逐字一致")
        }
    }

    func testMuxFrameValidation() {
        // Server→client frames cannot be encoded upstream.
        assertViolation(try encodedObject(.mux(.serverItem(streamId: "s1", value: nil))))
        assertViolation(try encodedObject(.mux(.open(streamId: "", endpoint: "session/follow", args: [:]))))
        assertViolation(try encodedObject(.mux(.end(streamId: ""))))
    }

    func testPingEncoding() throws {
        let object = try encodedObject(.ping(ts: 1_792_510_000_000))
        XCTAssertEqual(object["type"], .string("ping"))
        XCTAssertEqual(object["ts"], .int(1_792_510_000_000))
    }

    func testFrameCapIs32MiBAndEnforcedOnEncode() throws {
        XCTAssertEqual(P1ProtocolLimits.maxFrameBytes, 32 * 1024 * 1024)
        let call = P1RPCCall(
            id: "rpc-big",
            endpoint: "session/list",
            args: ["payload": .string(String(repeating: "x", count: 200))]
        )
        XCTAssertThrowsError(try P1FrameCodec.encodeText(.rpc(call), maxBytes: 64)) { error in
            guard let protocolError = error as? P1ProtocolError,
                  case .frameTooLarge(let bytes, let limit) = protocolError else {
                return XCTFail("期望 frameTooLarge，实际 \(error)")
            }
            XCTAssertGreaterThan(bytes, limit)
            XCTAssertEqual(limit, 64)
        }
        // The default cap accepts the same frame.
        XCTAssertNoThrow(try P1FrameCodec.encodeText(.rpc(call)))
    }

    // MARK: - welcome decoding

    func testDecodeWelcomeFresh() throws {
        guard case .welcome(let welcome) = try decode(welcomeJSON()) else {
            return XCTFail("期望 welcome 帧")
        }
        XCTAssertEqual(welcome.v, 2)
        XCTAssertEqual(welcome.proto, "dsh-m/2")
        XCTAssertEqual(welcome.deviceId, "dev-1")
        XCTAssertEqual(welcome.epoch, "epoch-1")
        XCTAssertEqual(welcome.sid, 0)
        XCTAssertTrue(welcome.resume.ok)
        XCTAssertEqual(welcome.resume.mode, .fresh)
        XCTAssertNil(welcome.resume.replayed)
        XCTAssertEqual(welcome.caps, P1CapsFixture.unaryAndResume)
        XCTAssertEqual(welcome.ticket, "ticket-1")
    }

    func testDecodeWelcomeReplayAndReset() throws {
        guard case .welcome(let replay) = try decode(welcomeJSON(
            epoch: "epoch-1",
            sid: 4,
            resume: #"{"ok":true,"mode":"replay","replayed":2}"#
        )) else {
            return XCTFail("期望 welcome 帧")
        }
        XCTAssertEqual(replay.resume.mode, .replay)
        XCTAssertEqual(replay.resume.replayed, 2)
        XCTAssertNil(replay.resume.reason)

        guard case .welcome(let reset) = try decode(welcomeJSON(
            epoch: "epoch-2",
            sid: 0,
            resume: #"{"ok":false,"mode":"reset","reason":"epoch-mismatch"}"#,
            ticket: nil
        )) else {
            return XCTFail("期望 welcome 帧")
        }
        XCTAssertFalse(reset.resume.ok)
        XCTAssertEqual(reset.resume.mode, .reset)
        XCTAssertEqual(reset.resume.reason, "epoch-mismatch")
        XCTAssertNil(reset.ticket)
    }

    func testWelcomeStrictViolations() {
        // Version / proto negotiation.
        assertViolation(try decode(welcomeJSON(v: 1)))
        assertViolation(try decode(welcomeJSON(proto: "dsh-m/1")))
        // Required fields.
        assertViolation(try decode(#"{"type":"welcome","v":2,"proto":"dsh-m/2","deviceId":"d","sid":0,"resume":{"ok":true,"mode":"fresh"},"caps":{"unary":true,"resume":true,"maxInFlight":8,"replayBytes":0}}"#))
        assertViolation(try decode(welcomeJSON(deviceId: "")))
        assertViolation(try decode(welcomeJSON(epoch: "")))
        assertViolation(try decode(welcomeJSON(sid: -1)))
        assertViolation(try decode(welcomeJSON(caps: "{}")))
        assertViolation(try decode(welcomeJSON(caps: #"{"unary":true,"resume":true,"maxInFlight":0,"replayBytes":0}"#)))
        // resume consistency.
        assertViolation(try decode(welcomeJSON(resume: #"{"ok":true,"mode":"replayed"}"#)))
        assertViolation(try decode(welcomeJSON(resume: #"{"ok":true,"mode":"reset","reason":"x"}"#)))
        assertViolation(try decode(welcomeJSON(resume: #"{"ok":false,"mode":"fresh"}"#)))
        assertViolation(try decode(welcomeJSON(resume: #"{"ok":false,"mode":"reset"}"#)))
        assertViolation(try decode(welcomeJSON(resume: #"{"ok":true,"mode":"replay"}"#)))
        assertViolation(try decode(welcomeJSON(resume: #"{"ok":true,"mode":"replay","replayed":-1}"#)))
        // Ticket must not be an empty string.
        assertViolation(try decode(welcomeJSON(ticket: "")))
    }

    // MARK: - down decoding

    func testDecodeDownEnvelopeItemEndAndError() throws {
        guard case .down(let item) = try decode(
            #"{"type":"down","sid":1,"frame":{"type":"item","streamId":"s1","value":{"type":"snapshot","cursor":2}}}"#
        ) else { return XCTFail("期望 down 帧") }
        XCTAssertEqual(item.sid, 1)
        XCTAssertEqual(item.frameType, "item")
        XCTAssertEqual(item.streamId, "s1")
        XCTAssertEqual(item.value?["cursor"], .int(2))

        guard case .down(let end) = try decode(
            #"{"type":"down","sid":2,"frame":{"type":"end","streamId":"s1"}}"#
        ) else { return XCTFail("期望 down 帧") }
        XCTAssertEqual(end.frameType, "end")
        XCTAssertNil(end.value)

        guard case .down(let failure) = try decode(
            #"{"type":"down","sid":3,"frame":{"type":"error","streamId":"s1","error":{"code":"agent/failed","message":"boom"}}}"#
        ) else { return XCTFail("期望 down 帧") }
        XCTAssertEqual(failure.error?.code, "agent/failed")
        XCTAssertEqual(failure.error?.message, "boom")

        // Partial error body falls back to a readable RemoteError.
        guard case .down(let partial) = try decode(
            #"{"type":"down","sid":4,"frame":{"type":"error","streamId":"s1"}}"#
        ) else { return XCTFail("期望 down 帧") }
        XCTAssertNil(partial.error, "error 字段缺失时按无错误正文处理")
    }

    func testDownStrictViolations() {
        assertViolation(try decode(#"{"type":"down","sid":0,"frame":{"type":"item","streamId":"s1"}}"#))
        assertViolation(try decode(#"{"type":"down","sid":-1,"frame":{"type":"item","streamId":"s1"}}"#))
        assertViolation(try decode(#"{"type":"down","sid":1}"#))
        assertViolation(try decode(#"{"type":"down","sid":1,"frame":"text"}"#))
        assertViolation(try decode(#"{"type":"down","sid":1,"frame":{"type":"item"}}"#))
        assertViolation(try decode(#"{"type":"down","sid":1,"frame":{"streamId":"s1"}}"#))
    }

    func testDownKeepsUnknownUpstreamFrameTypes() throws {
        // Forward compatibility: a frame type this App does not know is still a
        // valid envelope (the upstream may grow new frame kinds).
        guard case .down(let envelope) = try decode(
            #"{"type":"down","sid":5,"frame":{"type":"future-frame","payload":1}}"#
        ) else { return XCTFail("期望 down 帧") }
        XCTAssertEqual(envelope.frameType, "future-frame")
    }

    // MARK: - unary result / error / pong decoding

    func testDecodeRPCResultVariants() throws {
        guard case .rpcResult(let json) = try decode(
            #"{"type":"rpc/result","id":"rpc-1","status":200,"contentType":"application/json","body":{"type":"server-response","rpcId":"rpc-1","result":{"ok":true}}}"#
        ) else { return XCTFail("期望 rpc/result") }
        XCTAssertEqual(json.id, "rpc-1")
        XCTAssertEqual(json.status, 200)
        XCTAssertEqual(json.contentType, "application/json")
        XCTAssertEqual(json.body?["type"], .string("server-response"))
        XCTAssertNil(json.bodyText)
        let bodyData = try json.bodyData()
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: bodyData)["type"], .string("server-response"))

        guard case .rpcResult(let text) = try decode(
            #"{"type":"rpc/result","id":"rpc-2","status":500,"bodyText":"upstream 500"}"#
        ) else { return XCTFail("期望 rpc/result") }
        XCTAssertEqual(text.status, 500)
        XCTAssertNil(text.body)
        XCTAssertEqual(text.bodyText, "upstream 500")
        XCTAssertEqual(String(data: try text.bodyData(), encoding: .utf8), "upstream 500")

        // A parsed JSON `null` body is a valid body and must not be mistaken for
        // a missing one.
        guard case .rpcResult(let nullBody) = try decode(
            #"{"type":"rpc/result","id":"rpc-3","status":200,"body":null}"#
        ) else { return XCTFail("期望 rpc/result") }
        XCTAssertEqual(nullBody.body, .null)
    }

    func testRPCResultStrictViolations() {
        assertViolation(try decode(#"{"type":"rpc/result","id":"","status":200,"body":{}}"#))
        assertViolation(try decode(#"{"type":"rpc/result","id":"x","status":1000,"body":{}}"#))
        assertViolation(try decode(#"{"type":"rpc/result","id":"x","status":200}"#))
        assertViolation(try decode(#"{"type":"rpc/result","id":"x","status":200,"body":{},"bodyText":"t"}"#))
        assertViolation(try decode(#"{"type":"rpc/error","id":"x","status":200,"body":{}}"#))
    }

    func testDecodeRPCErrorAndPong() throws {
        guard case .rpcError(let error) = try decode(
            #"{"type":"rpc/error","id":"rpc-9","error":{"code":"rpc/busy","message":"too many"}}"#
        ) else { return XCTFail("期望 rpc/error") }
        XCTAssertEqual(error.id, "rpc-9")
        XCTAssertEqual(error.error.code, "rpc/busy")
        XCTAssertEqual(error.error.message, "too many")

        guard case .pong(let pong) = try decode(#"{"type":"pong","ts":7}"#) else {
            return XCTFail("期望 pong")
        }
        XCTAssertEqual(pong.ts, 7)

        guard case .pong(let nullPong) = try decode(#"{"type":"pong","ts":null}"#) else {
            return XCTFail("期望 pong")
        }
        XCTAssertNil(nullPong.ts, "插件在 ping 未带 ts 时回 ts:null，必须容忍")
    }

    func testRPCDecodeViolations() {
        assertViolation(try decode(#"{"type":"rpc/error","id":"","error":{"code":"x","message":"y"}}"#))
        assertViolation(try decode(#"{"type":"rpc/error","id":"x"}"#))
        assertViolation(try decode(#"{"type":"pong","ts":"soon"}"#))
    }

    // MARK: - Frame-level violations

    func testUnknownAndMalformedServerFramesAreViolations() {
        assertViolation(try decode(""))
        assertViolation(try decode("not-json"))
        assertViolation(try decode("[1,2,3]"))
        assertViolation(try decode(#""just-a-string""#))
        assertViolation(try decode("null"))
        assertViolation(try decode(#"{"type":"hello","v":2}"#))
        assertViolation(try decode(#"{"type":"bogus"}"#))
        assertViolation(try decode(#"{"v":2}"#))
    }

    func testDecodeServerFrameSizeCap() throws {
        let small = welcomeJSON()
        XCTAssertThrowsError(try P1FrameCodec.decodeServerFrame(small, maxBytes: 32)) { error in
            guard let protocolError = error as? P1ProtocolError,
                  case .frameTooLarge = protocolError else {
                return XCTFail("期望 frameTooLarge，实际 \(error)")
            }
        }
        XCTAssertNoThrow(try P1FrameCodec.decodeServerFrame(small, maxBytes: P1ProtocolLimits.maxFrameBytes))
    }

    // MARK: - close codes / failure semantics

    func testCloseCodeSemanticsTable() {
        XCTAssertEqual(P1CloseCode.allCases.count, 13)
        let expectations: [(P1CloseCode, P1CloseSeverity, P1CloseAction, Bool)] = [
            (.protocolViolation, .fatal, .fallbackLegacy, false),
            (.authFailed, .retry, .retryWithECDSATicket, true),
            (.binaryFrame, .fallback, .fallbackLegacy, false),
            (.helloRequired, .retry, .retryAfterBackoff, true),
            (.connectionConflict, .retry, .retryAfterBackoff, true),
            (.upstreamClosed, .retry, .reconnect, true),
            (.bufferOverflow, .retry, .reconnect, true),
            (.frameTooLarge, .fatal, .requestFailed, false),
            (.normalClosure, .normal, .none, false),
            (.goingAway, .normal, .none, false),
            (.noStatus, .normal, .none, false),
            (.abnormalClosure, .retry, .reconnect, true),
            (.unsupportedData, .fallback, .fallbackLegacy, false),
        ]
        for (code, severity, action, retryable) in expectations {
            let semantics = code.semantics
            XCTAssertEqual(semantics.severity, severity, "close \(code.rawValue) severity")
            XCTAssertEqual(semantics.action, action, "close \(code.rawValue) action")
            XCTAssertEqual(semantics.isRetryable, retryable, "close \(code.rawValue) retryable")
            XCTAssertEqual(semantics.shouldFallbackLegacy, action == .fallbackLegacy, "close \(code.rawValue) fallback")
        }
        // Unknown custom codes stay retryable rather than silently falling back.
        XCTAssertEqual(P1CloseCode.semantics(for: 4321).action, .reconnect)
        XCTAssertEqual(P1CloseCode.semantics(for: 4321).severity, .retry)
    }

    func testCloseFailureMapping() {
        XCTAssertEqual(P1Failure.close(code: 4400, reason: "bad"), .fallbackLegacy(code: 4400, reason: "bad"))
        XCTAssertEqual(P1Failure.close(code: 4403, reason: "binary"), .fallbackLegacy(code: 4403, reason: "binary"))
        XCTAssertEqual(P1Failure.close(code: 4401, reason: "auth"), .authRetry(code: 4401, reason: "auth"))
        XCTAssertEqual(P1Failure.close(code: 4408, reason: "hello"), .helloRequired(code: 4408, reason: "hello"))
        XCTAssertEqual(P1Failure.close(code: 4409, reason: "conflict"), .connectionConflict(code: 4409, reason: "conflict"))
        XCTAssertEqual(P1Failure.close(code: 1011, reason: "upstream"), .upstreamClosed(code: 1011, reason: "upstream"))
        XCTAssertEqual(P1Failure.close(code: 1013, reason: "overflow"), .bufferOverflow(code: 1013, reason: "overflow"))
        XCTAssertEqual(P1Failure.close(code: 1009, reason: "too big"), .frameTooLarge(reason: "too big"))
        XCTAssertEqual(P1Failure.close(code: 1006, reason: "lost"), .socketClosed(code: 1006, reason: "lost"))
        XCTAssertEqual(P1Failure.close(code: 1000, reason: "bye"), .socketClosed(code: 1000, reason: "bye"))
        XCTAssertEqual(P1Failure.close(code: 4321, reason: "custom"), .socketClosed(code: 4321, reason: "custom"))
    }

    func testFailureActionAndRetrySemantics() {
        XCTAssertTrue(P1Failure.fallbackLegacy(code: 4400, reason: "").shouldFallbackLegacy)
        XCTAssertFalse(P1Failure.fallbackLegacy(code: 4400, reason: "").isRetryable)
        XCTAssertEqual(P1Failure.fallbackLegacy(code: 4400, reason: "").severity, .fatal)

        XCTAssertEqual(P1Failure.authRetry(code: 4401, reason: "").action, .retryWithECDSATicket)
        XCTAssertTrue(P1Failure.authRetry(code: 4401, reason: "").isRetryable)
        XCTAssertEqual(P1Failure.authRetry(code: 4401, reason: "").closeCode, 4401)

        XCTAssertTrue(P1Failure.upstreamClosed(code: 1011, reason: "").isRetryable)
        XCTAssertEqual(P1Failure.bufferOverflow(code: 1013, reason: "").action, .reconnect)
        XCTAssertFalse(P1Failure.socketClosed(code: 1000, reason: "").isRetryable)
        XCTAssertTrue(P1Failure.socketClosed(code: 1006, reason: "").isRetryable)

        XCTAssertEqual(P1Failure.frameTooLarge(reason: "big").action, .requestFailed)
        XCTAssertFalse(P1Failure.protocolViolation("x").isRetryable)
        XCTAssertEqual(P1Failure.protocolViolation("x").action, .fallbackLegacy)
        XCTAssertNil(P1Failure.notConnected.closeCode)
        XCTAssertNil(P1Failure.timeout("rpc").closeCode)
        XCTAssertEqual(P1Failure.cancelled.action, .none)

        let remote = RemoteError(code: "rpc/busy", message: "busy")
        let rpcFailure = P1Failure.rpcError(id: "rpc-1", error: remote)
        XCTAssertEqual(rpcFailure.remoteError, remote)
        XCTAssertEqual(rpcFailure.action, .none)
        XCTAssertFalse(P1Failure.notConnected.userMessage.isEmpty)
        XCTAssertEqual(P1Failure.cancelled.userMessage, "已取消")
    }
}

/// Shared `welcome.caps` fixture.
private enum P1CapsFixture {
    static let unaryAndResume = P1Caps.decoded(#"{"unary":true,"resume":true,"maxInFlight":8,"replayBytes":4194304}"#)
}

extension P1Caps {
    /// Test-only decoder helper (the production initializer is Decodable-only).
    static func decoded(_ json: String) -> P1Caps {
        try! JSONDecoder().decode(P1Caps.self, from: Data(json.utf8))
    }
}

extension P1RPCCall {
    /// Test helper for building a call with an arbitrary id.
    func withId(_ id: String) -> P1RPCCall {
        P1RPCCall(id: id, endpoint: endpoint, body: body, headers: headers)
    }
}
