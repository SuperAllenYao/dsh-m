import XCTest
@testable import DSHm

/// v5.5 §14.5 context-window data layer: `contextPressure` projection parsing,
/// token shorthand, percent rounding, display fallback, `SessionListItem`
/// parsing, the pure `session/list` refresh merge and the journal/view-model
/// accessors. No networking is involved: every case builds its own fixtures.
final class ContextPressureTests: XCTestCase {

    // MARK: - Fixtures

    private func pressureProjection(
        pressureTokens: Int? = nil,
        projectedTokens: Int? = nil,
        contextWindow: Int? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let pressureTokens { object["pressureTokens"] = .int(Int64(pressureTokens)) }
        if let projectedTokens { object["projectedTokens"] = .int(Int64(projectedTokens)) }
        if let contextWindow { object["contextWindow"] = .int(Int64(contextWindow)) }
        return .object(object)
    }

    /// Builds one `session/list` row; `contextPressureJSON` is inserted as the raw
    /// `projections.values.contextPressure` value when non-nil.
    private func listItem(
        sessionId: String,
        contextPressureJSON: String? = nil,
        origin: String? = nil,
        parentSessionId: String? = nil
    ) throws -> SessionListItem {
        var fields: [String] = ["\"sessionId\":\"\(sessionId)\""]
        if let origin { fields.append("\"origin\":\"\(origin)\"") }
        if let parentSessionId { fields.append("\"parentSessionId\":\"\(parentSessionId)\"") }
        if let contextPressureJSON {
            fields.append("\"projections\":{\"values\":{\"contextPressure\":\(contextPressureJSON)}}")
        }
        let json = "{\(fields.joined(separator: ","))}"
        return try JSONDecoder().decode(SessionListItem.self, from: Data(json.utf8))
    }

    private func journalSnapshot(contextPressureJSON: String?) throws -> SessionSnapshot {
        let values = contextPressureJSON.map { "\"contextPressure\":\($0)" } ?? ""
        let json = """
        {"type":"snapshot","header":{"id":"s-ctx"},"cursor":2,"records":[],
         "projections":{"asOfSeq":2,"values":{\(values)}}}
        """
        return try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
    }

    // MARK: - Parsing: complete / partial / missing

    func testParsesCompleteProjection() {
        let value = ContextPressureValue(projection: pressureProjection(
            pressureTokens: 12400,
            projectedTokens: 13000,
            contextWindow: 200000
        ))
        XCTAssertEqual(value?.pressureTokens, 12400)
        XCTAssertEqual(value?.projectedTokens, 13000)
        XCTAssertEqual(value?.contextWindow, 200000)
        XCTAssertEqual(value?.usedTokens, 13000)
        XCTAssertEqual(value?.percent, 7)
        XCTAssertEqual(value?.displayText, "13k / 200k · 7%")
    }

    func testFallsBackToPressureTokensWhenProjectedMissing() {
        let value = ContextPressureValue(projection: pressureProjection(
            pressureTokens: 12400,
            contextWindow: 200000
        ))
        XCTAssertEqual(value?.usedTokens, 12400)
        XCTAssertEqual(value?.displayText, "12.4k / 200k · 6%")
    }

    func testProjectedTokensWinOverPressureTokens() {
        let value = ContextPressureValue(projection: pressureProjection(
            pressureTokens: 100000,
            projectedTokens: 150000,
            contextWindow: 200000
        ))
        XCTAssertEqual(value?.usedTokens, 150000)
        XCTAssertEqual(value?.percent, 75)
    }

    func testWindowOnlyProjectionParses() {
        let value = ContextPressureValue(projection: pressureProjection(contextWindow: 200000))
        XCTAssertEqual(value?.contextWindow, 200000)
        XCTAssertNil(value?.usedTokens)
        XCTAssertNil(value?.percent)
        XCTAssertEqual(value?.displayText, "—")
    }

    func testEmptyObjectProjectionIsNil() {
        XCTAssertNil(ContextPressureValue(projection: .object([:])))
    }

    func testNilProjectionIsNil() {
        XCTAssertNil(ContextPressureValue(projection: nil))
    }

    func testNonObjectProjectionIsNil() {
        XCTAssertNil(ContextPressureValue(projection: .string("12400")))
        XCTAssertNil(ContextPressureValue(projection: .int(12400)))
        XCTAssertNil(ContextPressureValue(projection: .array([])))
        XCTAssertNil(ContextPressureValue(projection: .null))
    }

    func testUnknownKeysOnlyIsNil() {
        XCTAssertNil(ContextPressureValue(projection: .object([
            "unknownTokens": .int(12400),
        ])))
    }

    func testWrongTypedFieldsAreIgnored() {
        let value = ContextPressureValue(projection: .object([
            "pressureTokens": .string("12400"),
            "projectedTokens": .bool(true),
            "contextWindow": .int(200000),
        ]))
        XCTAssertNil(value?.pressureTokens)
        XCTAssertNil(value?.projectedTokens)
        XCTAssertEqual(value?.contextWindow, 200000)
    }

    func testZeroUsageParses() {
        let value = ContextPressureValue(projection: pressureProjection(
            pressureTokens: 0,
            contextWindow: 200000
        ))
        XCTAssertEqual(value?.usedTokens, 0)
        XCTAssertEqual(value?.percent, 0)
        XCTAssertEqual(value?.displayText, "0 / 200k · 0%")
    }

    // MARK: - Token shorthand

    func testShortTokensPlainBelowThousand() {
        XCTAssertEqual(ContextPressureValue.shortTokens(0), "0")
        XCTAssertEqual(ContextPressureValue.shortTokens(1), "1")
        XCTAssertEqual(ContextPressureValue.shortTokens(999), "999")
    }

    func testShortTokensKilobytes() {
        XCTAssertEqual(ContextPressureValue.shortTokens(1_000), "1k")
        XCTAssertEqual(ContextPressureValue.shortTokens(1_200), "1.2k")
        XCTAssertEqual(ContextPressureValue.shortTokens(12_400), "12.4k")
        XCTAssertEqual(ContextPressureValue.shortTokens(200_000), "200k")
    }

    func testShortTokensMegabytes() {
        XCTAssertEqual(ContextPressureValue.shortTokens(1_000_000), "1M")
        XCTAssertEqual(ContextPressureValue.shortTokens(1_200_000), "1.2M")
        XCTAssertEqual(ContextPressureValue.shortTokens(1_250_000), "1.3M")
        XCTAssertEqual(ContextPressureValue.shortTokens(200_000_000), "200M")
    }

    func testShortTokensRoundingBoundary() {
        XCTAssertEqual(ContextPressureValue.shortTokens(999_949), "999.9k")
        XCTAssertEqual(ContextPressureValue.shortTokens(999_950), "1M")
        XCTAssertEqual(ContextPressureValue.shortTokens(999_999), "1M")
    }

    func testShortTokensNegativeClampsToZero() {
        XCTAssertEqual(ContextPressureValue.shortTokens(-42), "0")
    }

    // MARK: - Percent

    func testPercentRoundsDown() {
        XCTAssertEqual(ContextPressureValue(pressureTokens: 12_400, contextWindow: 200_000).percent, 6)
    }

    func testPercentRoundsHalfAwayFromZero() {
        XCTAssertEqual(ContextPressureValue(pressureTokens: 13_000, contextWindow: 200_000).percent, 7)
        XCTAssertEqual(ContextPressureValue(pressureTokens: 125_000, contextWindow: 200_000).percent, 63)
    }

    func testPercentZeroAndFull() {
        XCTAssertEqual(ContextPressureValue(pressureTokens: 0, contextWindow: 200_000).percent, 0)
        XCTAssertEqual(ContextPressureValue(pressureTokens: 200_000, contextWindow: 200_000).percent, 100)
    }

    func testPercentOverWindowIsNotClamped() {
        let value = ContextPressureValue(pressureTokens: 300_000, contextWindow: 200_000)
        XCTAssertEqual(value.percent, 150)
        XCTAssertEqual(value.displayText, "300k / 200k · 150%")
    }

    func testPercentNilWithoutWindow() {
        XCTAssertNil(ContextPressureValue(pressureTokens: 12_400).percent)
    }

    func testPercentNilForNonPositiveWindow() {
        XCTAssertNil(ContextPressureValue(pressureTokens: 12_400, contextWindow: 0).percent)
        XCTAssertNil(ContextPressureValue(pressureTokens: 12_400, contextWindow: -1).percent)
    }

    func testPercentNilWithoutUsage() {
        XCTAssertNil(ContextPressureValue(contextWindow: 200_000).percent)
    }

    // MARK: - Display fallback

    func testDisplayTextComplete() {
        let value = ContextPressureValue(
            pressureTokens: 12_400,
            projectedTokens: 13_000,
            contextWindow: 200_000
        )
        XCTAssertEqual(value.displayText, "13k / 200k · 7%")
    }

    func testDisplayTextPlaceholderWhenAllMissing() {
        XCTAssertEqual(ContextPressureValue().displayText, "—")
    }

    func testDisplayTextUsedOnly() {
        XCTAssertEqual(ContextPressureValue(pressureTokens: 12_400).displayText, "12.4k")
    }

    func testDisplayTextSkipsPercentForInvalidWindow() {
        XCTAssertEqual(
            ContextPressureValue(pressureTokens: 12_400, contextWindow: 0).displayText,
            "12.4k"
        )
        XCTAssertEqual(
            ContextPressureValue(pressureTokens: 12_400, contextWindow: -5).displayText,
            "12.4k"
        )
    }

    // MARK: - SessionListItem parsing

    func testSessionListItemParsesContextPressure() throws {
        let item = try listItem(
            sessionId: "s-1",
            contextPressureJSON: "{\"pressureTokens\":12400,\"projectedTokens\":13000,\"contextWindow\":200000}"
        )
        XCTAssertEqual(item.contextPressure?.contextWindow, 200_000)
        XCTAssertEqual(item.contextPressure?.usedTokens, 13_000)
        XCTAssertEqual(item.contextPressure?.displayText, "13k / 200k · 7%")
    }

    func testSessionListItemWithoutProjectionsIsNil() throws {
        let item = try listItem(sessionId: "s-2")
        XCTAssertNil(item.contextPressure)
    }

    func testSessionListItemWithoutContextPressureProjectionIsNil() throws {
        let json = """
        {"sessionId":"s-3","projections":{"values":{"title":"hello"}}}
        """
        let item = try JSONDecoder().decode(SessionListItem.self, from: Data(json.utf8))
        XCTAssertNil(item.contextPressure)
        XCTAssertEqual(item.title, "hello")
    }

    func testSubagentListItemParsesContextPressure() throws {
        let item = try listItem(
            sessionId: "c-1",
            contextPressureJSON: "{\"pressureTokens\":1000,\"contextWindow\":8000}",
            origin: "subagent",
            parentSessionId: "p-1"
        )
        XCTAssertTrue(item.isSubagent)
        XCTAssertEqual(item.contextPressure?.displayText, "1k / 8k · 13%")
    }

    // MARK: - session/list refresh merge (pure)

    func testResolveFindsMatchingRow() throws {
        let sessions = [
            try listItem(sessionId: "s-a", contextPressureJSON: "{\"pressureTokens\":100}"),
            try listItem(sessionId: "s-b", contextPressureJSON: "{\"pressureTokens\":200,\"contextWindow\":1000}"),
            try listItem(sessionId: "s-c"),
        ]
        let value = ContextPressureResolver.resolve(sessionId: "s-b", sessions: sessions)
        XCTAssertEqual(value?.pressureTokens, 200)
        XCTAssertEqual(value?.contextWindow, 1_000)
    }

    func testResolveMissingRowIsNil() throws {
        let sessions = [try listItem(sessionId: "s-a", contextPressureJSON: "{\"pressureTokens\":100}")]
        XCTAssertNil(ContextPressureResolver.resolve(sessionId: "s-missing", sessions: sessions))
        XCTAssertNil(ContextPressureResolver.resolve(sessionId: "s-a", sessions: []))
    }

    func testResolveRowWithoutPressureIsNil() throws {
        let sessions = [
            try listItem(sessionId: "s-a", contextPressureJSON: "{\"unknown\":1}"),
        ]
        XCTAssertNil(ContextPressureResolver.resolve(sessionId: "s-a", sessions: sessions))
    }

    func testMergeKeepsCurrentWhenIncomingMissing() {
        let current = ContextPressureValue(pressureTokens: 12_400, contextWindow: 200_000)
        XCTAssertEqual(ContextPressureResolver.merge(current: current, incoming: nil), current)
        XCTAssertNil(ContextPressureResolver.merge(current: nil, incoming: nil))
    }

    func testMergeAdoptsIncomingWhenCurrentMissing() {
        let incoming = ContextPressureValue(pressureTokens: 12_400, contextWindow: 200_000)
        XCTAssertEqual(ContextPressureResolver.merge(current: nil, incoming: incoming), incoming)
    }

    func testMergeCarriesWindowForward() {
        let current = ContextPressureValue(pressureTokens: 10_000, contextWindow: 200_000)
        let incoming = ContextPressureValue(pressureTokens: 12_400)
        let merged = ContextPressureResolver.merge(current: current, incoming: incoming)
        XCTAssertEqual(merged?.usedTokens, 12_400)
        XCTAssertEqual(merged?.contextWindow, 200_000)
        XCTAssertEqual(merged?.displayText, "12.4k / 200k · 6%")
    }

    func testMergeCarriesUsageWhenIncomingOnlyWindow() {
        let current = ContextPressureValue(pressureTokens: 12_400, contextWindow: 100_000)
        let incoming = ContextPressureValue(contextWindow: 200_000)
        let merged = ContextPressureResolver.merge(current: current, incoming: incoming)
        XCTAssertEqual(merged?.usedTokens, 12_400)
        XCTAssertEqual(merged?.contextWindow, 200_000, "the fresher window wins")
    }

    func testRefreshValueKeepsLastKnownWhenSessionAbsent() throws {
        let current = ContextPressureValue(pressureTokens: 12_400, contextWindow: 200_000)
        let sessions = [try listItem(sessionId: "other", contextPressureJSON: "{\"pressureTokens\":1}")]
        let value = ContextPressureResolver.refreshValue(
            current: current,
            sessionId: "s-ctx",
            sessions: sessions
        )
        XCTAssertEqual(value, current)
    }

    func testRefreshValueAppliesRowUpdate() throws {
        let current = ContextPressureValue(pressureTokens: 12_400, contextWindow: 200_000)
        let sessions = [
            try listItem(
                sessionId: "s-ctx",
                contextPressureJSON: "{\"projectedTokens\":13000}"
            ),
        ]
        let value = ContextPressureResolver.refreshValue(
            current: current,
            sessionId: "s-ctx",
            sessions: sessions
        )
        XCTAssertEqual(value?.usedTokens, 13_000)
        XCTAssertEqual(value?.contextWindow, 200_000)
        XCTAssertEqual(value?.displayText, "13k / 200k · 7%")
    }

    // MARK: - SessionJournal / SessionViewModel accessors

    func testJournalParsesContextPressureFromSnapshot() throws {
        let journal = SessionJournal()
        journal.apply(snapshot: try journalSnapshot(
            contextPressureJSON: "{\"pressureTokens\":12400,\"projectedTokens\":13000,\"contextWindow\":200000}"
        ))
        XCTAssertEqual(journal.contextPressure?.usedTokens, 13_000)
        XCTAssertEqual(journal.contextPressure?.percent, 7)
    }

    func testJournalContextPressureNilWithoutProjection() throws {
        let journal = SessionJournal()
        journal.apply(snapshot: try journalSnapshot(contextPressureJSON: nil))
        XCTAssertNil(journal.contextPressure)
    }

    @MainActor
    func testViewModelShowsPlaceholderBeforeAnyData() {
        let viewModel = SessionViewModel(sessionId: "s-ctx")
        XCTAssertNil(viewModel.contextPressure)
        XCTAssertEqual(viewModel.contextPressureText, "—")
    }

    @MainActor
    func testSubagentViewModelExposesSamePlaceholderContract() {
        let address = SessionFollowAddress.subagent(
            parentSessionId: "p-ctx",
            childSessionId: "c-ctx",
            mode: "unknown"
        )
        let viewModel = SessionViewModel(address: address)
        XCTAssertEqual(viewModel.sessionId, "c-ctx")
        XCTAssertEqual(viewModel.contextPressureText, "—")
    }
}
