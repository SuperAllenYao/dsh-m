import CryptoKit
import XCTest
@testable import DSHm

final class PairingAndTransportTests: XCTestCase {

    // MARK: - QR payload schema (signed M1 payload)

    func testParseSignedPayload() {
        let pin = "BE:0E:62:CD:C0:48:E4:E9:DC:D5:F8:69:E1:47:5A:67:69:00:41:D0:CB:4C:D2:4E:66:88:13:67:4D:48:55:47"
        let json = """
        {"v":1,"kind":"dsh-m.pair","host":{"id":"ca89da19b9ea24ea","name":"Mac","key":"4pgLvSwc3WBNWyyK_k4PFU29WUP3BPMsa4vjTNa5ypA"},
         "mode":"lan","origins":["https://127.0.0.1:3488"],
         "endpoints":[{"url":"https://127.0.0.1:3488","kind":"lan","pri":10,"trust":"localCA","pin":"ignored"}],
         "tls":{"kind":"self-signed-ca","caPin":"kSJLCF3LapoNsuWdnToxo28WzGCFKSvrSRYlCe2pN3g","leafPin":"PY4XGhElXvJhKsNkN2A0pk1amPPv24VnCnMio5Cc54",
                "caFingerprint256":"7C:47:C9:ED:79:17:AA:45:E6:08:D8:87:57:EE:F8:DF:9F:01:AE:1F:84:72:F3:9A:61:90:5D:E7:F7:17:DB:1A",
                "leafFingerprint256":"\(pin)","leafNotAfter":"Oct 20 16:29:56 2027 GMT"},
         "pair":{"id":"p1","token":"tok-1234567890","exp":1893456000,"proto":"dsh-m/1","caps":{}},
         "sig":"fake-sig"}
        """
        let payload = try! XCTUnwrap(PairingPayload.parse(json))
        XCTAssertEqual(payload.v, 1)
        XCTAssertEqual(payload.kind, "dsh-m.pair")
        XCTAssertEqual(payload.bestOrigin, "https://127.0.0.1:3488")
        XCTAssertEqual(payload.token, "tok-1234567890")
        XCTAssertEqual(payload.proto, "dsh-m/1")
        XCTAssertEqual(payload.tlsLeafPinHex, pin.lowercased().replacingOccurrences(of: ":", with: ""))
        XCTAssertFalse(payload.isExpired)
        XCTAssertTrue(payload.isSigned)
        XCTAssertFalse(payload.verifyHostSignature(), "fake signature must not verify")
    }

    func testParsePayloadFromBase64URLPins() {
        // leafPin/caPin are base64url 32-byte digests in the plugin payload.
        let leafHex = "f43399c7662e5115027cd25c1d15ec3571e734ea4ee6bcc8859e0e8a4beb700d"
        let leafB64 = Data(hexString: leafHex).base64URLEncodedString
        let json = """
        {"v":1,"kind":"dsh-m.pair","origins":["https://127.0.0.1:3488"],
         "tls":{"caPin":"aaa","leafPin":"\(leafB64)"},"pair":{"token":"t","exp":1893456000}}
        """
        let payload = try! XCTUnwrap(PairingPayload.parse(json))
        XCTAssertEqual(payload.tlsLeafPinHex, leafHex)
    }

    func testParseLegacyFlatPayload() {
        let json = """
        {"v":1,"origins":["https://127.0.0.1:3466"],
         "leafPin":"20:5A:8C:D9:E8:1B:DE:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22",
         "pairToken":"tok-legacy","exp":1792512926035}
        """
        let payload = try! XCTUnwrap(PairingPayload.parse(json))
        XCTAssertEqual(payload.token, "tok-legacy")
        XCTAssertEqual(payload.bestOrigin, "https://127.0.0.1:3466")
        XCTAssertNotNil(payload.tlsLeafPinHex)
        XCTAssertTrue(payload.isExpired)
    }

    func testPayloadRejectsNonJSON() {
        XCTAssertNil(PairingPayload.parse("not-json"))
        XCTAssertNil(PairingPayload.parse("dsh-m/1"))
    }

    func testManualPayloadFallback() {
        let payload = PairingPayload.manual(origin: "https://127.0.0.1:3488", pairToken: "t", pin: nil)
        XCTAssertEqual(payload.bestOrigin, "https://127.0.0.1:3488")
        XCTAssertEqual(payload.token, "t")
        XCTAssertNil(payload.tlsLeafPinHex)
        XCTAssertFalse(payload.isSigned)
    }

    // MARK: - Signed payload verification (Ed25519 + JCS)

    func testHostSignatureVerificationWithRealKey() throws {
        let hostKey = Curve25519.Signing.PrivateKey()
        let hostPublic = hostKey.publicKey.rawRepresentation.base64URLEncodedString
        let unsigned: [String: JSONValue] = [
            "v": .int(1),
            "kind": .string("dsh-m.pair"),
            "host": .object([
                "id": .string("abc"),
                "name": .string("Mac 测试"),
                "key": .string(hostPublic),
            ]),
            "origins": .array([.string("https://127.0.0.1:3488")]),
            "pair": .object(["token": .string("tok"), "exp": .int(1_893_456_000)]),
        ]
        let canonical = try CanonicalJSON.encode(.object(unsigned))
        let signature = try hostKey.signature(for: Data(canonical.utf8))
        var signed = unsigned
        signed["sig"] = .string(signature.base64URLEncodedString)
        let payloadText = try CanonicalJSON.encode(.object(signed))
        XCTAssertTrue(HostSignature.verify(payloadText: payloadText))

        // Tampering with a field must invalidate the signature.
        var tampered = signed
        tampered["origins"] = .array([.string("https://evil.example:443")])
        let tamperedText = try CanonicalJSON.encode(.object(tampered))
        XCTAssertFalse(HostSignature.verify(payloadText: tamperedText))
    }

    func testCanonicalJsonOrderingAndEscaping() throws {
        let value = JSONValue.object([
            "b": .int(2),
            "a": .string("x\"y\n"),
            "arr": .array([.int(1), .bool(true), .null]),
        ])
        let canonical = try CanonicalJSON.encode(value)
        XCTAssertEqual(canonical, #"{"a":"x\"y\n","arr":[1,true,null],"b":2}"#)
        XCTAssertThrowsError(try CanonicalJSON.encode(.object(["x": .double(1.5)])))
    }

    // MARK: - base64url

    func testBase64URLRoundTrip() {
        let data = Data([0xFB, 0xFF, 0x00, 0x01, 0x02])
        let encoded = data.base64URLEncodedString
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(Data(base64URL: encoded), data)
    }

    // MARK: - HTTP/1.1 response parser

    func testHTTPParserContentLength() {
        let parser = HTTPResponseParser()
        parser.append(Data("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 7\r\n\r\n{\"a\":1}".utf8))
        let response = try! XCTUnwrap(parser.completed)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.header("content-type"), "application/json")
        XCTAssertEqual(response.bodyText, #"{"a":1}"#)
    }

    func testHTTPParserChunked() {
        let parser = HTTPResponseParser()
        let payload = "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        let data = Data(payload.utf8)
        let split = data.index(data.startIndex, offsetBy: 33)
        parser.append(data.subdata(in: data.startIndex..<split))
        XCTAssertNil(parser.completed)
        parser.append(data.subdata(in: split..<data.endIndex))
        let response = try! XCTUnwrap(parser.completed)
        XCTAssertEqual(response.bodyText, "hello world")
    }

    // MARK: - WebSocket frame codec (RFC 6455)

    func testClientFrameIsMasked() {
        let payload = Data("hello mux".utf8)
        let encoded = WSFrameCodec.encodeClientFrame(fin: true, opcode: WSOpcode.text, payload: payload)
        let bytes = [UInt8](encoded)
        XCTAssertEqual(bytes[0], 0x81)
        XCTAssertNotEqual(bytes[1] & 0x80, 0)
        XCTAssertEqual(Int(bytes[1] & 0x7F), payload.count)
    }

    func testServerFrameDecodes() throws {
        let payload = Data("hello mux".utf8)
        var server = Data([0x81, UInt8(payload.count)])
        server.append(payload)
        let frame = try XCTUnwrap(try WSFrameCodec.decode(from: &server))
        XCTAssertEqual(frame.opcode, WSOpcode.text)
        XCTAssertEqual(String(data: frame.payload, encoding: .utf8), "hello mux")
    }

    func testServerPingAndCloseDecode() throws {
        var ping = Data([0x89, 0x00])
        let pingFrame = try XCTUnwrap(try WSFrameCodec.decode(from: &ping))
        XCTAssertEqual(pingFrame.opcode, WSOpcode.ping)

        var close = Data([0x88, 0x02, 0x03, 0xE8])
        let closeFrame = try XCTUnwrap(try WSFrameCodec.decode(from: &close))
        XCTAssertEqual(closeFrame.opcode, WSOpcode.close)
        XCTAssertEqual(Int(closeFrame.payload[0]) << 8 | Int(closeFrame.payload[1]), 1000)
    }

    func testPartialFrameReturnsNil() throws {
        var buffer = Data([0x81])
        XCTAssertNil(try WSFrameCodec.decode(from: &buffer))
        buffer.append(0x05)
        buffer.append(contentsOf: [0x68, 0x65])
        XCTAssertNil(try WSFrameCodec.decode(from: &buffer))
        buffer.append(contentsOf: [0x6C, 0x6C, 0x6F])
        let frame = try XCTUnwrap(try WSFrameCodec.decode(from: &buffer))
        XCTAssertEqual(String(data: frame.payload, encoding: .utf8), "hello")
    }

    // MARK: - Approval waterfall parsing

    func testApprovalWaterfallParsesBilingualDisplayReason() {
        let value = TestJSON.value("""
        {"type":"waterfall","event":"approval/request","eventId":"evt-1","agentId":"session-1",
         "request":{"toolName":"bash","callId":"toolu_1","reason":"escalate sandbox",
                    "displayReason":{"en":"Allow this operation","zh":"允许本次操作"}}}
        """)
        let approval = try! XCTUnwrap(ApprovalWaterfall.parse(value))
        XCTAssertEqual(approval.eventId, "evt-1")
        XCTAssertEqual(approval.agentId, "session-1")
        XCTAssertEqual(approval.toolName, "bash")
        XCTAssertEqual(approval.callId, "toolu_1")
        XCTAssertEqual(approval.displayReason, "允许本次操作")
        XCTAssertEqual(approval.localizedReason, "允许本次操作")
    }

    func testEventsResultArgsShape() throws {
        let args = EventsResultArgs.outcome(clientId: "c1", eventId: "e1", value: .allowedOnce)
        XCTAssertEqual(args["clientId"]?.stringValue, "c1")
        XCTAssertEqual(args["eventId"]?.stringValue, "e1")
        XCTAssertEqual(args["outcome"]?["kind"]?.stringValue, "result")
        XCTAssertEqual(args["outcome"]?["value"]?.stringValue, "allowed-once")
    }
}

private extension Data {
    init(hexString: String) {
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            bytes.append(UInt8(hexString[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
