import XCTest
@testable import DSHm

/// Host protocol tolerance for `session/follow` events + actionable decode errors.
///
/// Incident (2026-10-22): the Host started attaching a **structured** `surfaceOp`
/// (`{"op":"replace","startSeq":75,"endSeq":75}`) to a `system/message` event.
/// `SessionEvent.surfaceOp` was `String?`, so the frame failed to decode, the
/// detail showed the bare "帧解析失败" banner, and because the same event rides in
/// every re-follow snapshot the session could not be opened again until the App
/// was rebuilt. These tests pin the tolerant decode with the exact wire payload.
final class SessionEventToleranceTests: XCTestCase {

    /// Verbatim event taken from the Host session log (`seq 1631`).
    private let structuredSurfaceOpEvent = """
    {"type":"system/message","seq":1631,"time":1792660298206,
     "data":{"turn":3,"step":34,"message":{"role":"system","content":[],"source":{"kind":"system-prompt"},"id":"c11162f4-a044-4605-bd73-3685d9c0c900"}},
     "sourceEventSeqs":[75],"surfaceOp":{"op":"replace","startSeq":75,"endSeq":75}}
    """

    private func decodeEvent(_ json: String) throws -> SessionEvent {
        try JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
    }

    // MARK: - Event tolerance

    func testDecodesStructuredSurfaceOp() throws {
        let event = try decodeEvent(structuredSurfaceOpEvent)
        XCTAssertEqual(event.type, "system/message")
        XCTAssertEqual(event.seq, 1631)
        XCTAssertEqual(event.sourceEventSeqs, [75])
        let surfaceOp = try XCTUnwrap(event.surfaceOp?.objectValue)
        XCTAssertEqual(surfaceOp["op"]?.stringValue, "replace")
        XCTAssertEqual(surfaceOp["startSeq"]?.intValue, 75)
        XCTAssertEqual(surfaceOp["endSeq"]?.intValue, 75)
    }

    func testStillDecodesLegacyStringSurfaceOp() throws {
        let event = try decodeEvent(#"{"type":"session/title","seq":7,"surfaceOp":"replace"}"#)
        XCTAssertEqual(event.surfaceOp?.stringValue, "replace")
        XCTAssertNil(event.sourceEventSeqs)
    }

    func testUnknownShapesOfOptionalFieldsDoNotFailTheEvent() throws {
        // A future Host may send any of these; the App must keep the event.
        let event = try decodeEvent("""
        {"type":"system/message","seq":9,"time":"yesterday","data":"not-an-object",
         "sourceEventSeqs":["75"],"surfaceOp":[1,2,3]}
        """)
        XCTAssertEqual(event.seq, 9)
        XCTAssertNil(event.time, "an unreadable time is dropped, not fatal")
        XCTAssertEqual(event.data?.stringValue, "not-an-object")
        XCTAssertNil(event.sourceEventSeqs, "an unreadable seq list is dropped, not fatal")
        XCTAssertEqual(event.surfaceOp?.arrayValue?.count, 3)
    }

    func testMissingRequiredFieldsStillThrow() {
        XCTAssertThrowsError(try decodeEvent(#"{"type":"system/message"}"#))
        XCTAssertThrowsError(try decodeEvent(#"{"seq":1}"#))
    }

    // MARK: - The stuck path: a snapshot carrying the same event

    func testSnapshotCarryingStructuredSurfaceOpDecodes() throws {
        let json = """
        {"type":"snapshot","header":{"version":4,"id":"s-model"},"cursor":1631,
         "records":[{"type":"event","event":\(structuredSurfaceOpEvent)}],
         "hasMore":false,"assistantStream":{"revision":0}}
        """
        let frame = try SessionStreamFrame.decode(TestJSON.value(json))
        guard case .snapshot(let snapshot) = frame else {
            return XCTFail("expected a snapshot frame, got \(frame)")
        }
        XCTAssertEqual(snapshot.cursor, 1631)
        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertEqual(snapshot.records.first?.event?.seq, 1631)
    }

    // MARK: - Actionable error text

    func testDecodeFailureNamesFrameTypeAndMissingField() throws {
        let value = TestJSON.value(#"{"type":"snapshot"}"#)
        do {
            _ = try SessionStreamFrame.decode(value)
            XCTFail("an empty snapshot must not decode")
        } catch {
            let text = FrameDecodeFailure.describe(error, frame: value)
            XCTAssertTrue(text.hasPrefix("[snapshot]"), text)
            XCTAssertTrue(text.contains("缺少字段"), text)
            XCTAssertTrue(text.contains("header"), "the missing field must be named: \(text)")
        }
    }

    func testDecodeFailureNamesWrongTypedField() {
        let value = TestJSON.value(#"{"type":"event","event":{"type":42,"seq":1}}"#)
        do {
            _ = try SessionStreamFrame.decode(value)
            XCTFail("a numeric event type must not decode")
        } catch {
            let text = FrameDecodeFailure.describe(error, frame: value)
            XCTAssertTrue(text.contains("[event]"), text)
            XCTAssertTrue(text.contains("类型不符"), text)
            XCTAssertTrue(text.contains("String"), "the expected type must be named: \(text)")
        }
    }

    func testCodingPathFormatting() {
        struct NoKey: CodingKey {
            var stringValue: String
            var intValue: Int?
            init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
            init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
        }
        XCTAssertEqual(FrameDecodeFailure.path([]), "<root>")
        XCTAssertEqual(
            FrameDecodeFailure.path([NoKey(stringValue: "records")!, NoKey(intValue: 3)!, NoKey(stringValue: "event")!]),
            "records[3].event"
        )
    }
}
