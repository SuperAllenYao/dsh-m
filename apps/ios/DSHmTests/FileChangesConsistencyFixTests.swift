import Compression
import Network
import XCTest
@testable import DSHm

/// task-4（2026-10-24）「#1 跨端文件变更一致性」修复回归单测。
///
/// 三个行为契约（① 真 bug；② 稳健性兼容；③ 跨端标题口径）：
/// 1. HTTPSClient.decodeBody：响应头声明 gzip 但 body 实际不是 gzip 时（典型：链路
///    插件 exact-fetch 透传的 Host 404），必须回退原始 body、保留 HTTP status，让
///    FileChangesFetchPolicy 看到 404 terminal，而不是被 transport 错误重试耗尽。
/// 2. SessionRowBuilder.handleToolResult：真实宿主 tool/result 的 diffs 在 data.meta
///    （优先，扫真实会话日志确认）；部分静态 fixture / 部分恢复快照只保留
///    message.meta，兜底做兼容——两种位置都要能聚合出文件（稳健性兼容，不是真实
///    用户 bug；真实口径不变）。
/// 3. 跨端标题口径：卡片标题用 Host total，不是客户端 files.length；DEBUG E2E
///    seam 注入的 summary 与真实 exact fetch 共用同一口径。
final class FileChangesConsistencyFixTests: XCTestCase {

    // MARK: - ① gzip 头 + 非 gzip body：回退原始 body，不吞 HTTP status

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

    private func gzipWrap(_ data: Data) throws -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff])
        out.append(try rawDeflate(data))
        out.append(Data(count: 8))
        return out
    }

    func testDecodeBodyGunzipsValidGzipBody() throws {
        let payload = Data(#"{"ok":true,"value":{"files":[]}}"#.utf8)
        let response = HTTPResponse(
            status: 200,
            headers: ["content-type": "application/json", "content-encoding": "gzip"],
            body: try gzipWrap(payload),
            observedLeafPin: nil
        )
        let decoded = try HTTPSClient.decodeBody(of: response)
        XCTAssertEqual(decoded.status, 200)
        XCTAssertEqual(decoded.body, payload, "a real gzip body must still be inflated")
        XCTAssertEqual(decoded.bodyText, String(decoding: payload, as: UTF8.self))
    }

    /// 真 bug 场景：链路插件把 Host 404 的响应头 content-encoding: gzip 原样透传，
    /// 但 undici 已把 body 解压成明文 JSON。旧代码在这里抛 transport，404 被重试耗尽后
    /// 「本轮文件变更」卡整张消失。现在必须返回原始 body + 404。
    func testDecodeBodyFallsBackToRawBodyWhenGzipHeaderWrapsPlainJSON() throws {
        let plain = Data(#"{"ok":false,"error":"summary/not-found","message":"Host released the turn"}"#.utf8)
        XCTAssertNotEqual(plain.first, 0x1f, "fixture body is deliberately NOT gzip")
        let response = HTTPResponse(
            status: 404,
            headers: ["content-type": "application/json", "content-encoding": "gzip"],
            body: plain,
            observedLeafPin: nil
        )
        let decoded = try HTTPSClient.decodeBody(of: response)
        XCTAssertEqual(decoded.status, 404, "the HTTP status must survive the decode failure")
        XCTAssertEqual(decoded.body, plain, "the raw body must be handed back untouched")
        XCTAssertTrue(decoded.bodyText.contains("summary/not-found"))
    }

    func testDecodeBodyPassesThroughIdentityAndHeaderlessResponses() throws {
        let payload = Data(#"{"ok":true}"#.utf8)
        let identity = HTTPResponse(
            status: 200,
            headers: ["content-encoding": "identity"],
            body: payload,
            observedLeafPin: nil
        )
        XCTAssertEqual(try HTTPSClient.decodeBody(of: identity).body, payload)

        let headerless = HTTPResponse(status: 200, headers: [:], body: payload, observedLeafPin: nil)
        XCTAssertEqual(try HTTPSClient.decodeBody(of: headerless).body, payload)
    }

    /// 安全边界（lead 要求保留）：回退只针对「gzip 头 + 非 gzip body」；
    /// 其他不支持的 content-encoding（br/deflate 等）仍然必须报错，不能被
    /// 静默当明文放行，否则请求协商会被悄悄降级。
    func testDecodeBodyStillRejectsUnsupportedContentEncoding() {
        let response = HTTPResponse(
            status: 200,
            headers: ["content-encoding": "br"],
            body: Data(#"{"ok":true}"#.utf8),
            observedLeafPin: nil
        )
        XCTAssertThrowsError(try HTTPSClient.decodeBody(of: response)) { error in
            guard case LinkError.transport(let message) = error else {
                return XCTFail("unsupported coding must stay a transport error, got: \(error)")
            }
            XCTAssertTrue(message.contains("br"), "error must name the unsupported coding: \(message)")
        }
    }

    /// 端到端（进程内 loopback）：旧代码把 404 变成 LinkError.transport，这里断言
    /// 上层拿到的是 LinkError.httpStatus(404, body) —— exact-fetch 判定与 404 兜底
    /// 都依赖这个 error 形状。
    func testUnaryJSONSurfacesHTTP404WhenGzipHeaderWrapsPlainJSON() async throws {
        let errorBody = Data(#"{"ok":false,"error":"summary/not-found"}"#.utf8)
        let server = try TransportPerfTests.TestServer(handler: { _ in
            TransportPerfTests.TestResponse(
                status: 404,
                headers: ["content-type": "application/json", "content-encoding": "gzip"],
                body: errorBody
            )
        })
        try await server.start()
        defer { server.stop() }

        let pool = HTTPConnectionPool(
            config: HTTPConnectionPoolConfig(maxIdlePerOrigin: 2, idleTimeout: 10)
        )
        let origin = URL(string: "http://127.0.0.1:\(server.port)")!
        do {
            _ = try await HTTPSClient.unaryJSON(
                origin: origin,
                endpoint: "changes.summary",
                args: [:],
                token: "test-token",
                leafPin: "",
                timeout: 5,
                pool: pool,
                parameters: NWParameters.tcp
            )
            XCTFail("a 404 must never be reported as success")
        } catch let LinkError.httpStatus(status, body) {
            XCTAssertEqual(status, 404)
            XCTAssertTrue(body.contains("summary/not-found"), "error body must be readable: \(body)")
        } catch {
            XCTFail("404 was masked as a non-HTTP error (the reported bug): \(error)")
        }
    }

    // MARK: - ② diffs 兼容口径：data.meta 优先，message.meta 兜底

    /// 稳健性兼容：真实会话 diffs 在 data.meta（优先级由下一个用例验证），但部分
    /// 静态 fixture / 部分恢复快照只保留 message.meta。兜底必须在这种形态下也能
    /// 聚合出文件，否则 404 回退会没有文件可展示。
    func testToolResultFallsBackToMessageMetaWhenTopLevelMetaIsAbsent() throws {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("tool/call", seq: 2, data: TestJSON.value(#"""
            {"callId":"call_edit","name":"edit","arguments":"{}","turn":1,"step":1}
            """#)),
            TestJSON.event("tool/result", seq: 3, data: TestJSON.value(#"""
            {"name":"edit","message":{"content":[{"type":"text","text":"ok"}],"isError":false,
             "toolCallId":"call_edit",
             "meta":{"diffs":[{"path":"Sources/A.swift","oldText":"a","newText":"a\nb"}]}}}
            """#)),
        ]
        let flow = SessionRowBuilder.build(events: events)
        let changes = try XCTUnwrap(flow.latestFileChanges, "restored-session message.meta.diffs must aggregate")
        XCTAssertEqual(changes.files, ["Sources/A.swift"])
        XCTAssertEqual(changes.additions, 1, "a -> a\\nb is one added line")
        XCTAssertEqual(changes.deletions, 0)

        let call = try XCTUnwrap(SessionRowBuilder.findToolCall(in: flow.rows, callId: "call_edit"))
        XCTAssertNotNil(call.result?.meta?["diffs"]?.arrayValue, "the diffs must attach to the tool row for the result view")
    }

    /// 原优先级必须保留：live 事件顶层 data.meta 优先于 message.meta（两者不同时以
    /// data.meta 为准，避免 live 结果被持久化副本覆盖）。
    func testToolResultPrefersTopLevelMetaOverMessageMeta() throws {
        let events = [
            TestJSON.event("turn/start", seq: 1, data: .object(["turn": .int(1)])),
            TestJSON.event("tool/call", seq: 2, data: TestJSON.value(#"""
            {"callId":"call_edit","name":"edit","arguments":"{}","turn":1,"step":1}
            """#)),
            TestJSON.event("tool/result", seq: 3, data: TestJSON.value(#"""
            {"name":"edit","message":{"content":[{"type":"text","text":"ok"}],"isError":false,
             "toolCallId":"call_edit",
             "meta":{"diffs":[{"path":"stale/Persisted.swift","oldText":"x","newText":"x\ny"}]}},
             "meta":{"diffs":[{"path":"live/TopLevel.swift","oldText":"x","newText":"x\ny"}]}}
            """#)),
        ]
        let flow = SessionRowBuilder.build(events: events)
        let changes = try XCTUnwrap(flow.latestFileChanges)
        XCTAssertEqual(changes.files, ["live/TopLevel.swift"], "data.meta keeps its original priority")
    }

    // MARK: - ③ 跨端口径：标题用 Host total，不是 files.length

    func testExactSummaryTitleUsesHostTotalNotFileCount() throws {
        let summary = try JSONDecoder().decode(ChangesSummaryValue.self, from: Data(#"""
        {"turn":3,
         "files":[{"path":"Sources/A.swift","display":"A.swift","added":3,"deleted":1},
                  {"path":"Sources/B.swift","display":"B.swift","added":1,"deleted":0}],
         "total":50,"added":123,"deleted":45}
        """#.utf8))
        let changes = TurnFileChanges.exact(from: summary, seq: 9)
        XCTAssertEqual(changes.titleFileCount, 50, "卡片标题必须用 Host total(50)，不是 files.count(2)")
        XCTAssertEqual(changes.files.count, 2, "sheet 列表仍用 files.length")
        XCTAssertEqual(changes.added, 123)
        XCTAssertEqual(changes.deleted, 45)
        XCTAssertEqual(changes.source, .exactFetch)
        XCTAssertEqual(changes.seq, 9)
        XCTAssertFalse(changes.isLoading)
    }

    func testTitleFallsBackToFileCountWhenHostOmitsTotal() throws {
        let summary = try JSONDecoder().decode(ChangesSummaryValue.self, from: Data(#"""
        {"files":[{"path":"a.swift","added":2,"deleted":0},{"path":"b.swift","added":0,"deleted":1}]}
        """#.utf8))
        let changes = TurnFileChanges.exact(from: summary, seq: nil)
        XCTAssertNil(changes.total)
        XCTAssertEqual(changes.titleFileCount, 2, "without a Host total the title falls back to files.count")
        XCTAssertEqual(changes.added, 2, "added/deleted are summed from files when the Host omits them")
        XCTAssertEqual(changes.deleted, 1)
    }

    /// DEBUG E2E seam 与真实 exact fetch 共用 TurnFileChanges.exact：注入 total=50 /
    /// files=18 后，卡片（latestTurnFileChanges）必须按 50 渲染，且不进入 loading 态。
    @MainActor
    func testE2EChangesSummarySeamDrivesCardWithHostTotal() throws {
        let files = (0..<18).map { index in
            #"{"path":"Sources/File\#(index).swift","display":"File\#(index).swift","added":1,"deleted":0}"#
        }
        let json = #"{"turn":1,"files":[\#(files.joined(separator: ","))],"total":50,"added":123,"deleted":45}"#
        let viewModel = SessionViewModel(sessionId: "session-e2e-changes")
        viewModel.installE2EChangesSummaryPreview(json: json)

        let changes = try XCTUnwrap(viewModel.latestTurnFileChanges)
        XCTAssertEqual(changes.source, .exactFetch)
        XCTAssertEqual(changes.titleFileCount, 50, "seam must reproduce the Host-total title口径")
        XCTAssertEqual(changes.files.count, 18, "sheet list length stays 18 (files.length)")
        XCTAssertEqual(changes.added, 123)
        XCTAssertEqual(changes.deleted, 45)
        XCTAssertFalse(changes.isLoading, "an injected summary must not render the loading card")
        XCTAssertFalse(viewModel.fileChangesExactFetchPending)
    }

    @MainActor
    func testE2EChangesSummarySeamIgnoresMalformedJSON() {
        let viewModel = SessionViewModel(sessionId: "session-e2e-changes")
        viewModel.installE2EChangesSummaryPreview(json: "{not-json")
        XCTAssertNil(viewModel.latestTurnFileChanges, "malformed seam JSON must be ignored, not crash the card")
    }
}
