import XCTest
@testable import DSHm

final class EnvelopeCodecTests: XCTestCase {

    // MARK: - Unary envelope (§2.2/§2.4/§2.5)

    func testClientRequestEnvelopeEncodesExactWireShape() throws {
        let envelope = ClientRequestEnvelope(
            rpcId: "rpc-1",
            method: "session/list",
            args: ["_request": .object([:])]
        )
        let data = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "client-request")
        XCTAssertEqual(object["rpcId"] as? String, "rpc-1")
        XCTAssertEqual(object["method"] as? String, "session/list")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["args"], "payload must contain exactly {args}")
        let args = try XCTUnwrap(payload["args"] as? [String: Any])
        XCTAssertEqual(Set(args.keys), ["_request"], "wire args keep the reserved _request name")
    }

    func testServerResponseDecodesOkValue() throws {
        let json = """
        {"type":"server-response","rpcId":"rpc-1","result":{"ok":true,"value":{"items":[{"sessionId":"s1","running":false}]}}}
        """
        let envelope = try JSONDecoder().decode(ServerResponseEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.type, "server-response")
        XCTAssertEqual(envelope.rpcId, "rpc-1")
        guard case .ok(let value) = envelope.result else {
            return XCTFail("expected ok result")
        }
        XCTAssertEqual(value["items"]?.arrayValue?.first?["sessionId"]?.stringValue, "s1")
        XCTAssertEqual(value["items"]?.arrayValue?.first?["running"]?.boolValue, false)
    }

    func testServerResponseDecodesBusinessError() throws {
        let json = """
        {"type":"server-response","rpcId":"p","result":{"ok":false,"error":{"code":"gateway/arguments-invalid","message":"missing _request","details":{"endpoint":"session/list"}}}}
        """
        let envelope = try JSONDecoder().decode(ServerResponseEnvelope.self, from: Data(json.utf8))
        guard case .failure(let error) = envelope.result else {
            return XCTFail("expected error result")
        }
        XCTAssertEqual(error.code, "gateway/arguments-invalid")
        XCTAssertEqual(error.details?["endpoint"]?.stringValue, "session/list")
    }

    // MARK: - Mux frames (§3.2)

    func testOpenFrameEncodesStrictKeySet() throws {
        let frame = MuxFrame.open(streamId: "stream-1", endpoint: "$events", args: [:])
        let value = try frame.encodedJSON()
        guard let object = value.objectValue else {
            return XCTFail("open frame must be an object")
        }
        XCTAssertEqual(Set(object.keys), ["type", "streamId", "endpoint", "payload"])
        XCTAssertEqual(object["type"]?.stringValue, "open")
        XCTAssertEqual(object["endpoint"]?.stringValue, "$events")
        let payload = try XCTUnwrap(object["payload"]?.objectValue)
        XCTAssertEqual(Set(payload.keys), ["args"])
    }

    func testCancelFrameEncodes() throws {
        let value = try MuxFrame.cancel(streamId: "s9").encodedJSON()
        XCTAssertEqual(Set(try XCTUnwrap(value.objectValue).keys), ["type", "streamId"])
        XCTAssertEqual(value["type"]?.stringValue, "cancel")
    }

    func testServerItemFrameDecodesValue() throws {
        let value = TestJSON.value("""
        {"type":"item","streamId":"s1","value":{"type":"snapshot","cursor":2}}
        """)
        guard case .serverItem(let streamId, let payload) = try MuxFrame.decode(value) else {
            return XCTFail("expected item frame")
        }
        XCTAssertEqual(streamId, "s1")
        XCTAssertEqual(payload?["type"]?.stringValue, "snapshot")
    }

    func testServerEndAndErrorFramesDecode() throws {
        let end = TestJSON.value(#"{"type":"end","streamId":"s1"}"#)
        guard case .serverEnd(let endId) = try MuxFrame.decode(end) else {
            return XCTFail("expected end frame")
        }
        XCTAssertEqual(endId, "s1")

        let error = TestJSON.value("""
        {"type":"error","streamId":"s2","error":{"code":"session/not-found","message":"nope","details":{"sessionId":"s2"}}}
        """)
        guard case .serverError(let errorId, let remoteError) = try MuxFrame.decode(error) else {
            return XCTFail("expected error frame")
        }
        XCTAssertEqual(errorId, "s2")
        XCTAssertEqual(remoteError.code, "session/not-found")
        XCTAssertEqual(remoteError.message, "nope")
    }

    // MARK: - session/follow frames (§3.5)

    func testSnapshotFrameDecodes() throws {
        let value = TestJSON.value("""
        {"type":"snapshot","header":{"version":4,"id":"session-x","cwd":"/tmp/ws"},"cursor":2,
         "records":[{"type":"event","event":{"type":"permission/preset","seq":0,"time":1,"data":{"preset":"workspace-write"}}}],
         "hasMore":false,"projections":{"asOfSeq":2,"values":{"title":"pong","permissions":{"currentValue":"workspace-write"}}},
         "assistantStream":{"revision":0}}
        """)
        guard case .snapshot(let snapshot) = try SessionStreamFrame.decode(value) else {
            return XCTFail("expected snapshot")
        }
        XCTAssertEqual(snapshot.header.id, "session-x")
        XCTAssertEqual(snapshot.cursor, 2)
        XCTAssertEqual(snapshot.records.first?.event?.type, "permission/preset")
        XCTAssertEqual(snapshot.projections?.values["title"]?.stringValue, "pong")
    }

    func testAssistantStreamFrameDecodes() throws {
        let value = TestJSON.value("""
        {"type":"assistant-stream","frame":{"type":"chunk","attemptId":"s:1","revision":2,"index":0,
         "chunk":{"type":"finish","reason":{"kind":"error"}}}}
        """)
        guard case .assistantStream(let frame) = try SessionStreamFrame.decode(value) else {
            return XCTFail("expected assistant-stream")
        }
        XCTAssertEqual(frame.type, "chunk")
        XCTAssertEqual(frame.revision, 2)
    }
}
