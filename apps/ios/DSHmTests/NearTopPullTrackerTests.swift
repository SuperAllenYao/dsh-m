import XCTest
@testable import DSHm

/// 2026-10-23 全量历史自动补齐：in-app 计时门禁（detail-metrics 新增 autoload key 组）。
/// - legacy 串（firstFrameMs/cacheHit/networkMs/beginEpochMs/sessionId/window/cacheMs/fullMs/resumed）
///   必须保持字节稳定（旧 bench parser / 旧 E2E 兼容）；
/// - autoload 组（tapMs/tapAtEpochMs/shellMs/contentMs/firstContentMs/cacheChunk0Ms/
///   fillMs/fillPages/fillOldest）由 ; 拼在 legacy 之后。
final class AutoloadMetricsTests: XCTestCase {

    private func fields(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in value.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            result[String(pair[0])] = String(pair[1])
        }
        return result
    }

    private func number(_ fields: [String: String], _ key: String) -> Double? {
        fields[key].flatMap(Double.init)
    }

    // MARK: - legacy 段

    @MainActor
    func testLegacyDetailMetricsStringStaysByteStable() throws {
        defer { DetailMetrics.forceEnabledForTesting = nil; DetailMetrics.reset() }
        DetailMetrics.forceEnabledForTesting = true
        DetailMetrics.reset()
        DetailMetrics.begin(sessionId: "s1")
        let value = try XCTUnwrap(DetailMetrics.valueString)
        let pattern = #"^firstFrameMs=-1;cacheHit=0;networkMs=-1;beginEpochMs=\d+;sessionId=s1;window=-1;cacheMs=-1;fullMs=-1;resumed=0$"#
        XCTAssertNotNil(
            value.range(of: pattern, options: .regularExpression),
            "legacy detail-metrics 串必须保持旧格式（旧 E2E parser 依赖）: \(value)"
        )
    }

    // MARK: - autoload 段

    @MainActor
    func testAutoloadMetricsExposeTapToFillSegments() throws {
        defer { DetailMetrics.forceEnabledForTesting = nil; DetailMetrics.reset() }
        DetailMetrics.forceEnabledForTesting = true
        DetailMetrics.reset()
        DetailMetrics.beginTap()
        DetailMetrics.begin(sessionId: "s1")
        DetailMetrics.setFirstWindow(16)
        DetailMetrics.markShellFrame()
        DetailMetrics.markFirstContent()
        DetailMetrics.markNetworkApplied()
        DetailMetrics.markCacheRestored(milliseconds: 12.5)
        DetailMetrics.markHistoryFillCompleted(milliseconds: 2345.6, pages: 3, oldestSeq: 0)
        let autoload = try XCTUnwrap(DetailMetrics.autoloadValueString)
        let f = fields(autoload)
        XCTAssertEqual(Set(f.keys).sorted(), [
            "cacheChunk0Ms", "contentMs", "fillMs", "fillOldest", "fillPages",
            "firstContentMs", "shellMs", "tapAtEpochMs", "tapMs",
        ])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(number(f, "tapMs")), 0, "tap 是 VM init 之前的第一笔 in-app 时间")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(number(f, "tapAtEpochMs")), 1_700_000_000_000)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(number(f, "shellMs")), 0)
        XCTAssertEqual(try XCTUnwrap(number(f, "firstContentMs")), try XCTUnwrap(number(f, "contentMs")))
        XCTAssertEqual(try XCTUnwrap(number(f, "cacheChunk0Ms")), 12.5)
        XCTAssertEqual(try XCTUnwrap(number(f, "fillMs")), 2345.6)
        XCTAssertEqual(try XCTUnwrap(number(f, "fillPages")), 3)
        XCTAssertEqual(try XCTUnwrap(number(f, "fillOldest")), 0)
    }

    @MainActor
    func testCacheRestoredMarksLegacyCacheKeys() throws {
        defer { DetailMetrics.forceEnabledForTesting = nil; DetailMetrics.reset() }
        DetailMetrics.forceEnabledForTesting = true
        DetailMetrics.reset()
        DetailMetrics.begin(sessionId: "s1")
        DetailMetrics.setFirstWindow(16)
        DetailMetrics.markCacheRestored(milliseconds: 21.0)
        let legacy = try XCTUnwrap(DetailMetrics.valueString)
        XCTAssertTrue(legacy.contains("cacheHit=0"), "cacheHit 由 setCacheHit 单独写入")
        XCTAssertTrue(legacy.contains("window=16"))
        XCTAssertTrue(legacy.contains("cacheMs=21.0"))
    }

    // MARK: - VM 拼接

    private func snapshotJSON() -> JSONValue {
        TestJSON.value("""
        {"type":"snapshot","header":{"version":4,"id":"s1"},"cursor":3,
         "records":[
           {"type":"event","event":{"type":"user/message","seq":1,"data":{"content":[{"type":"text","text":"hello"}],"source":{"kind":"user"}}}},
           {"type":"event","event":{"type":"assistant/message","seq":2,"data":{"message":{"content":[{"type":"text","text":"world"}]}}}}
         ],
         "hasMore":false,
         "projections":{"asOfSeq":2,"values":{}},"assistantStream":{"revision":0}}
        """)
    }

    @MainActor
    func testViewModelDetailMetricsValueAppendsAutoloadGroup() async throws {
        DetailMetrics.forceEnabledForTesting = true
        DetailMetrics.reset()
        let store = SessionWindowCacheStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("AutoMetrics-\(UUID().uuidString)", isDirectory: true),
            identity: { "autoload-tests" }
        )
        let viewModel = SessionViewModel(address: .session(sessionId: "s1"), windowCache: store)
        viewModel.applyStreamValue(snapshotJSON())
        try? await Task.sleep(nanoseconds: 150_000_000)
        viewModel.markDetailViewAppeared()
        let value = try XCTUnwrap(viewModel.detailMetricsValue)
        let f = fields(value)
        XCTAssertNotNil(f["firstFrameMs"], "legacy 段保留")
        XCTAssertNotNil(f["tapMs"], "autoload 段追加")
        XCTAssertNotNil(f["fillMs"])
        XCTAssertEqual(f["fillOldest"], "-1", "补齐未跑时 fillOldest=-1")
    }
}
