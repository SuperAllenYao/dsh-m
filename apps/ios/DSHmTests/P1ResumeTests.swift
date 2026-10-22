import Foundation
import XCTest
@testable import DSHm

/// P1 resume (§17.3-3 / design `p1-single-wss-transport.zh.md` §5, §7.3):
/// the LinkService-level retention policy plus the full replay/reset lifecycle
/// driven through the production `P1ResumeDriver` + `P1Channel` over the same
/// injected `FakeSocket` seam `P1TransportTests` uses (no TLS, no Keychain).
@MainActor
final class P1ResumeTests: XCTestCase {

    // MARK: - Test doubles

    /// Socket seam double: `onSend` runs synchronously inside `send`, which the
    /// channel explicitly supports, so inbound frames are deterministic.
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

        func drop(code: Int = P1CloseCode.abnormalClosure.rawValue, reason: String = "network lost") {
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

    @MainActor
    private final class Recorder {
        var items: [JSONValue?] = []
        var closes: [(Int, String)] = []
    }

    // MARK: - Fixtures

    private static func replayResume(replayed: Int) -> String {
        #"{"ok":true,"mode":"replay","replayed":\#(replayed)}"#
    }

    private static let resetResume = #"{"ok":false,"mode":"reset","reason":"evicted"}"#
    private static let freshResume = #"{"ok":true,"mode":"fresh"}"#

    private static func welcomeJSON(
        epoch: String = "epoch-1",
        sid: Int64 = 0,
        resume: String = freshResume,
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

    private static func itemFrame(streamId: String = "s1", n: Int) -> String {
        #"{"type":"item","streamId":"\#(streamId)","value":{"n":\#(n)}}"#
    }

    private static func frameType(_ text: String) -> String? {
        FakeSocket.parse(text)["type"] as? String
    }

    // MARK: - Helpers

    private func makeChannel(_ factory: SocketFactory) -> P1Channel {
        P1Channel(
            socketFactory: { factory.make() },
            clientInfo: P1ClientInfo(name: "unit-test", version: "0.0.0"),
            helloTimeout: 2,
            maxFrameBytes: P1ProtocolLimits.maxFrameBytes
        )
    }

    private func makeDriver(_ factory: SocketFactory) -> P1ResumeDriver {
        P1ResumeDriver { [self] _, _, _, _ in makeChannel(factory) }
    }

    /// Every freshly created socket answers its `hello` with this welcome and, in
    /// replay mode, injects the given missed frames right behind it.
    private func respondWithWelcome(
        _ factory: SocketFactory,
        sid: Int64 = 0,
        resume: String = freshResume,
        replayedFrames: [(sid: Int64, n: Int)] = [],
        helloJSON: ((String) -> String)? = nil
    ) {
        factory.configure = { socket in
            socket.onSend = { text in
                guard Self.frameType(text) == "hello" else { return }
                if let helloJSON {
                    socket.receive(helloJSON(text))
                    return
                }
                socket.receive(Self.welcomeJSON(sid: sid, resume: resume))
                for frame in replayedFrames {
                    socket.receive(Self.downJSON(sid: frame.sid, frame: Self.itemFrame(n: frame.n)))
                }
            }
        }
    }

    private func decodeWelcome(_ json: String) throws -> P1Welcome {
        try JSONDecoder().decode(P1Welcome.self, from: Data(json.utf8))
    }

    private func makeReplayWelcome(sid: Int64 = 3, replayed: Int = 2, epoch: String = "epoch-1") throws -> P1Welcome {
        try decodeWelcome(Self.welcomeJSON(
            epoch: epoch,
            sid: sid,
            resume: Self.replayResume(replayed: replayed)
        ))
    }

    /// Live channel + one stream with `items`/`closes` recorders; returns everything
    /// the resume tests need to assert on.
    private func makeLiveChannel(
        _ factory: SocketFactory
    ) async throws -> (channel: P1Channel, handle: P1StreamHandle, items: () -> [JSONValue?], closes: () -> [(Int, String)]) {
        respondWithWelcome(factory)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))

        let recorder = Recorder()
        let handle = try channel.openStream(
            streamId: "s1",
            endpoint: "session/follow",
            onItem: { recorder.items.append($0) },
            onClose: { recorder.closes.append(($0, $1)) }
        )
        let socket = try XCTUnwrap(factory.last)
        socket.receive(Self.downJSON(sid: 1, frame: Self.itemFrame(n: 1)))
        return (channel, handle, { recorder.items }, { recorder.closes })
    }

    // MARK: - Pure policy: replay vs rebuild / generation

    func testReplayPlanKeepsStreamsAndGenerationWhenRetained() throws {
        let welcome = try makeReplayWelcome()
        let plan = P1ResumePlan.make(welcome: welcome, isResumeAttempt: true, hadLiveStreams: true)

        XCTAssertEqual(plan.mode, .replay)
        XCTAssertEqual(plan.streams, .retain)
        XCTAssertFalse(plan.reopenEvents, "replay 保留 $events 订阅")
        XCTAssertFalse(plan.bumpGeneration, "replay 不 bump generation（UI 不重建）")
        XCTAssertTrue(plan.isSilentResume)
        XCTAssertEqual(plan.replayedFrames, 2)
        XCTAssertNil(plan.resetReason)
    }

    func testReplayWithoutRetainedStreamsDegradesToRebuild() throws {
        let welcome = try makeReplayWelcome()

        // Cold start with a persisted cursor: the server replays, but the App has
        // no stream table to attach the frames to.
        let coldStart = P1ResumePlan.make(welcome: welcome, isResumeAttempt: false, hadLiveStreams: false)
        XCTAssertEqual(coldStart.streams, .discard)
        XCTAssertTrue(coldStart.reopenEvents)
        XCTAssertTrue(coldStart.bumpGeneration, "无流可挂的 replay 必须重建（generation bump）")

        // Retained attempt, but the business layer cancelled its stream(s) while
        // the socket was down: nothing to continue either.
        let noLiveStreams = P1ResumePlan.make(welcome: welcome, isResumeAttempt: true, hadLiveStreams: false)
        XCTAssertEqual(noLiveStreams.streams, .discard)
        XCTAssertTrue(noLiveStreams.bumpGeneration)
    }

    func testResetPlanDiscardsStreamsAndBumpsGeneration() throws {
        let welcome = try decodeWelcome(Self.welcomeJSON(sid: 0, resume: Self.resetResume))
        let plan = P1ResumePlan.make(welcome: welcome, isResumeAttempt: true, hadLiveStreams: true)

        XCTAssertEqual(plan.mode, .reset)
        XCTAssertEqual(plan.streams, .discard)
        XCTAssertTrue(plan.reopenEvents, "reset 必须重开 $events")
        XCTAssertTrue(plan.bumpGeneration, "reset 必须 bump generation")
        XCTAssertFalse(plan.isSilentResume)
        XCTAssertEqual(plan.resetReason, "evicted")
        XCTAssertNil(plan.replayedFrames)
    }

    func testFreshPlanBumpsGeneration() throws {
        let welcome = try decodeWelcome(Self.welcomeJSON(sid: 0, resume: Self.freshResume))
        let plan = P1ResumePlan.make(welcome: welcome, isResumeAttempt: true, hadLiveStreams: true)

        XCTAssertEqual(plan.mode, .fresh)
        XCTAssertEqual(plan.streams, .discard)
        XCTAssertTrue(plan.reopenEvents)
        XCTAssertTrue(plan.bumpGeneration)
        XCTAssertFalse(plan.isSilentResume)
    }

    func testResumePolicyMatrix() {
        // Retryable socket losses keep the stream table / stay silent.
        XCTAssertEqual(P1ResumePolicy.disposition(for: .socketClosed(code: 1006, reason: "")), .retainForResume)
        XCTAssertEqual(P1ResumePolicy.disposition(for: .upstreamClosed(code: 1011, reason: "")), .retainForResume)
        XCTAssertEqual(P1ResumePolicy.disposition(for: .bufferOverflow(code: 1013, reason: "")), .retainForResume)
        XCTAssertEqual(P1ResumePolicy.disposition(for: .authRetry(code: 4401, reason: "")), .retainForResume)
        XCTAssertFalse(P1ResumePolicy.surfacesErrorBanner(.retainForResume), "replay 成功路径不回显错误横幅")

        // v2 unusable: drop everything and surface the real error.
        XCTAssertEqual(P1ResumePolicy.disposition(for: .fallbackLegacy(code: 4403, reason: "")), .fallbackLegacy)
        XCTAssertEqual(P1ResumePolicy.disposition(for: .protocolViolation("bad frame")), .fallbackLegacy)
        XCTAssertTrue(P1ResumePolicy.surfacesErrorBanner(.fallbackLegacy))
    }

    // MARK: - Ticket rotation / cursor

    func testTicketRotationDropsUsedAndPromotesRotated() {
        XCTAssertEqual(
            P1ResumeTickets.rotate(["ticket-a", "ticket-b"], used: "ticket-a", rejected: nil, rotated: "ticket-c"),
            ["ticket-c", "ticket-b"]
        )
        XCTAssertEqual(
            P1ResumeTickets.rotate(["ticket-a", "ticket-b"], used: nil, rejected: "ticket-b", rotated: nil),
            ["ticket-a"]
        )
        // Cap 2: the rotated ticket is promoted and the oldest cached one drops.
        XCTAssertEqual(
            P1ResumeTickets.rotate(["ticket-a", "ticket-b", "ticket-c"], used: nil, rejected: nil, rotated: "ticket-c"),
            ["ticket-c", "ticket-a"]
        )
        XCTAssertEqual(P1ResumeTickets.rotate(nil, used: nil, rejected: nil, rotated: nil), [])
        // No duplicate when the rotated ticket was already cached.
        XCTAssertEqual(
            P1ResumeTickets.rotate(["ticket-a", "ticket-b"], used: nil, rejected: nil, rotated: "ticket-b"),
            ["ticket-b", "ticket-a"]
        )
    }

    // MARK: - Driver: replay keeps streams, ordering, no re-open

    func testDriverReplayRetainsStreamsAppliesFramesInOrderAndKeepsCursor() async throws {
        let factory = SocketFactory()
        let driver = makeDriver(factory)
        let (channel, handle, items, closes) = try await makeLiveChannel(factory)

        let firstAttempt = driver.channelForAttempt(host: "h", port: 443, leafPin: "pin", connectTimeout: 2)
        XCTAssertFalse(firstAttempt.isResumeAttempt, "冷启动不是 resume attempt")
        // The live channel used by makeLiveChannel is a different object; make the
        // driver own it the same way `attemptP1Connection` does.
        driver.resetForTesting(to: channel)

        var channelFailures: [P1Failure] = []
        channel.onClose = { channelFailures.append($0) }
        try XCTUnwrap(factory.last).drop()
        XCTAssertEqual(channelFailures.count, 1)
        XCTAssertEqual(closes().count, 0, "socket 丢失不得触发 per-stream onClose（流被保留）")

        driver.retainAfterSocketLoss()
        XCTAssertTrue(driver.isRetained)
        let cursor = try XCTUnwrap(channel.resumeState)
        XCTAssertEqual(cursor, P1ResumeCursor(logEpoch: "epoch-1", sid: 1))

        var replayWindow: P1ReplayStats?
        channel.onReplayWindowClosed = { replayWindow = $0 }
        respondWithWelcome(
            factory,
            sid: 3,
            resume: Self.replayResume(replayed: 2),
            replayedFrames: [(sid: 2, n: 2), (sid: 3, n: 3)]
        )
        let welcome = try await channel.connect(auth: P1Auth(ticket: "rotated"), resume: cursor)
        let plan = driver.apply(welcome: welcome)

        XCTAssertEqual(plan.streams, .retain)
        XCTAssertFalse(plan.bumpGeneration)
        XCTAssertFalse(plan.reopenEvents)
        XCTAssertEqual(plan.replayedFrames, 2)
        XCTAssertFalse(driver.isRetained, "welcome 后 driver 回到 live 状态")

        XCTAssertEqual(items().compactMap { $0?["n"] }, [.int(1), .int(2), .int(3)], "replay 帧按序应用")
        XCTAssertEqual(closes().count, 0)
        XCTAssertTrue(handle.isOpen, "retained stream 仍然可写")
        XCTAssertEqual(channel.openStreams.map(\.streamId), ["s1"])
        XCTAssertEqual(channel.resumeState, P1ResumeCursor(logEpoch: "epoch-1", sid: 3))
        XCTAssertEqual(replayWindow, P1ReplayStats(frames: 2, bytes: replayWindow?.bytes ?? 0))
        XCTAssertGreaterThan(replayWindow?.bytes ?? 0, 0, "replay 字节埋点必须 > 0")
        XCTAssertEqual(try XCTUnwrap(factory.last).sentFrames(type: "open").count, 0, "replay 不得重发 open")
    }

    // MARK: - Driver: reset drops streams, notifies once, bumps generation

    func testDriverResetDropsStreamsNotifiesCloseOnceAndBumpsGeneration() async throws {
        let factory = SocketFactory()
        let driver = makeDriver(factory)
        let (channel, handle, _, closes) = try await makeLiveChannel(factory)
        driver.resetForTesting(to: channel)

        try XCTUnwrap(factory.last).drop()
        driver.retainAfterSocketLoss()
        let cursor = try XCTUnwrap(channel.resumeState)

        respondWithWelcome(factory, sid: 0, resume: Self.resetResume)
        let welcome = try await channel.connect(auth: P1Auth(ticket: "rotated"), resume: cursor)
        let plan = driver.apply(welcome: welcome)

        XCTAssertEqual(plan.mode, .reset)
        XCTAssertEqual(plan.streams, .discard)
        XCTAssertTrue(plan.bumpGeneration)
        XCTAssertTrue(plan.reopenEvents)
        XCTAssertEqual(closes().count, 1, "per-stream onClose 恰好一次")
        XCTAssertEqual(closes().first?.0, P1CloseCode.abnormalClosure.rawValue)
        XCTAssertTrue(closes().first?.1.contains("evicted") ?? false, "close reason 带上 reset 原因")
        XCTAssertFalse(handle.isOpen)
        XCTAssertTrue(channel.openStreams.isEmpty, "reset 后旧流描述表被丢弃")

        // Idempotent: a later hard teardown must not fire the close callbacks again.
        channel.discardAllStreams()
        driver.discard()
        XCTAssertEqual(closes().count, 1, "重复丢弃不得重复触发 onClose")
    }

    // MARK: - Driver: replay without live streams rebuilds

    func testDriverReplayWithoutLiveStreamsRebuilds() async throws {
        let factory = SocketFactory()
        let driver = makeDriver(factory)
        let (channel, handle, _, closes) = try await makeLiveChannel(factory)
        driver.resetForTesting(to: channel)

        try XCTUnwrap(factory.last).drop()
        driver.retainAfterSocketLoss()
        let cursor = try XCTUnwrap(channel.resumeState)
        // Business layer cancelled during the disconnect window (phase change).
        handle.cancel()
        XCTAssertFalse(channel.hasLiveStreams)

        respondWithWelcome(
            factory,
            sid: 3,
            resume: Self.replayResume(replayed: 2),
            replayedFrames: [(sid: 2, n: 2), (sid: 3, n: 3)]
        )
        let welcome = try await channel.connect(auth: P1Auth(ticket: "rotated"), resume: cursor)
        let plan = driver.apply(welcome: welcome)

        XCTAssertEqual(plan.mode, .replay)
        XCTAssertEqual(plan.streams, .discard, "没有 live stream 时 replay 退化为 rebuild")
        XCTAssertTrue(plan.bumpGeneration, "rebuild 必须 bump generation")
        XCTAssertTrue(plan.reopenEvents)
        XCTAssertTrue(channel.openStreams.isEmpty)
        XCTAssertEqual(closes().count, 0, "业务层自己 cancel 的流不再补发 onClose")
    }

    // MARK: - Driver: fresh cold start

    func testDriverFreshColdStartRebuilds() async throws {
        let factory = SocketFactory()
        let driver = makeDriver(factory)
        respondWithWelcome(factory)
        let attempt = driver.channelForAttempt(host: "h", port: 443, leafPin: "pin", connectTimeout: 2)
        XCTAssertFalse(attempt.isResumeAttempt)
        XCTAssertFalse(driver.isRetained)

        let welcome = try await attempt.channel.connect(auth: P1Auth(ticket: "ticket-1"))
        let plan = driver.apply(welcome: welcome)

        XCTAssertEqual(plan.mode, .fresh)
        XCTAssertEqual(plan.streams, .discard)
        XCTAssertTrue(plan.bumpGeneration)
        XCTAssertTrue(plan.reopenEvents)
        XCTAssertTrue(attempt.channel.openStreams.isEmpty)
    }

    func testRetainedChannelIsReusedForResumeAttempt() async throws {
        let factory = SocketFactory()
        let driver = makeDriver(factory)
        respondWithWelcome(factory)
        let first = driver.channelForAttempt(host: "h", port: 443, leafPin: "pin", connectTimeout: 2)
        _ = try await first.channel.connect(auth: P1Auth(ticket: "ticket-1"))
        try XCTUnwrap(factory.last).drop()

        driver.retainAfterSocketLoss()
        let second = driver.channelForAttempt(host: "h", port: 443, leafPin: "pin", connectTimeout: 2)
        XCTAssertTrue(second.isResumeAttempt)
        XCTAssertTrue(second.channel === first.channel, "resume 必须复用同一 P1Channel（流表在其内部）")
        XCTAssertEqual(factory.created.count, 1, "复用时不新建 socket")

        // A fallback/discard ends retention: the next attempt gets a fresh channel.
        driver.discard()
        let third = driver.channelForAttempt(host: "h", port: 443, leafPin: "pin", connectTimeout: 2)
        XCTAssertFalse(third.isResumeAttempt)
        XCTAssertFalse(third.channel === first.channel)
    }

    // MARK: - Requests during the silent resume window (deterministic failure)

    func testCallsFailFastWhileResumeChannelIsClosed() async throws {
        let factory = SocketFactory()
        let driver = makeDriver(factory)
        let (channel, _, _, _) = try await makeLiveChannel(factory)
        driver.resetForTesting(to: channel)
        try XCTUnwrap(factory.last).drop()
        driver.retainAfterSocketLoss()

        // No queuing and no hang: while the channel is closed, stream/unary calls
        // throw the existing `.notConnected` failure immediately.
        XCTAssertFalse(channel.isReady)
        XCTAssertThrowsError(try channel.openStream(endpoint: "session/follow")) { error in
            XCTAssertEqual(error as? P1Failure, .notConnected)
        }
        do {
            _ = try await channel.unary(endpoint: "$events/result")
            XCTFail("closed channel must not accept unary calls")
        } catch {
            XCTAssertEqual(error as? P1Failure, .notConnected)
        }
    }

    // MARK: - Replay byte/frame counting

    func testReplayStatsCountAppliedFramesOnly() async throws {
        let factory = SocketFactory()
        let (channel, _, items, _) = try await makeLiveChannel(factory)
        let socket = try XCTUnwrap(factory.last)

        var window: P1ReplayStats?
        channel.onReplayWindowClosed = { window = $0 }
        socket.drop()
        let cursor = try XCTUnwrap(channel.resumeState)

        let welcomeText = Self.welcomeJSON(sid: 3, resume: Self.replayResume(replayed: 2))
        let down2 = Self.downJSON(sid: 2, frame: Self.itemFrame(n: 2))
        let down3 = Self.downJSON(sid: 3, frame: Self.itemFrame(n: 3))
        respondWithWelcome(factory, sid: 3, resume: Self.replayResume(replayed: 2), helloJSON: { _ in welcomeText })
        let welcome = try await channel.connect(auth: P1Auth(ticket: "rotated"), resume: cursor)
        XCTAssertEqual(welcome.resume.replayed, 2)

        let newSocket = try XCTUnwrap(factory.last)
        newSocket.receive(down2)
        newSocket.receive(down2) // duplicate sid: applied once, not counted again
        XCTAssertNil(window, "窗口未关闭前不回调")
        newSocket.receive(down3)

        XCTAssertEqual(channel.replayStats.frames, 2, "重复 sid 不计入 replayed frames")
        XCTAssertEqual(channel.replayStats.bytes, down2.utf8.count + down3.utf8.count)
        XCTAssertEqual(window, channel.replayStats)
        XCTAssertEqual(items().compactMap { $0?["n"] }, [.int(1), .int(2), .int(3)])
    }

    func testReplayWelcomeWithNothingMissingClosesWindowImmediately() async throws {
        let factory = SocketFactory()
        respondWithWelcome(factory, sid: 0, resume: Self.freshResume)
        let channel = makeChannel(factory)
        _ = try await channel.connect(auth: P1Auth(ticket: "ticket-1"))
        var window: P1ReplayStats?
        channel.onReplayWindowClosed = { window = $0 }
        try XCTUnwrap(factory.last).drop()
        let cursor = try XCTUnwrap(channel.resumeState)

        // Cursor already at the server's sid: replay mode but zero missing frames.
        respondWithWelcome(factory, sid: 0, resume: Self.replayResume(replayed: 0))
        _ = try await channel.connect(auth: P1Auth(ticket: "rotated"), resume: cursor)
        XCTAssertEqual(window, P1ReplayStats(frames: 0, bytes: 0))
    }

    // MARK: - Resume telemetry (`connect-metrics` extension)

    func testResumeMetricsRecordsReplayAndResetFields() throws {
        P1ResumeMetrics.forceEnabledForTesting = true
        P1ResumeMetrics.begin()
        defer {
            P1ResumeMetrics.forceEnabledForTesting = nil
            P1ResumeMetrics.begin()
        }

        XCTAssertEqual(
            P1ResumeMetrics.summary,
            "resumeReplayedFrames=-1;resumeReplayedBytes=-1;resumeReason=-;recoverMs=-1"
        )

        let replay = try makeReplayWelcome()
        let replayPlan = P1ResumePlan.make(welcome: replay, isResumeAttempt: true, hadLiveStreams: true)
        P1ResumeMetrics.record(plan: replayPlan, welcome: replay, recoverMs: 85)
        XCTAssertEqual(
            P1ResumeMetrics.summary,
            "resumeReplayedFrames=2;resumeReplayedBytes=0;resumeReason=-;recoverMs=85"
        )

        P1ResumeMetrics.markReplayComplete(frames: 2, bytes: 1234)
        XCTAssertEqual(
            P1ResumeMetrics.summary,
            "resumeReplayedFrames=2;resumeReplayedBytes=1234;resumeReason=-;recoverMs=85"
        )

        let reset = try decodeWelcome(Self.welcomeJSON(sid: 0, resume: Self.resetResume))
        let resetPlan = P1ResumePlan.make(welcome: reset, isResumeAttempt: true, hadLiveStreams: true)
        P1ResumeMetrics.record(plan: resetPlan, welcome: reset, recoverMs: 210)
        XCTAssertEqual(
            P1ResumeMetrics.summary,
            "resumeReplayedFrames=-1;resumeReplayedBytes=-1;resumeReason=evicted;recoverMs=210"
        )
    }

    func testResumeMetricsDisabledProducesNoSegment() {
        P1ResumeMetrics.forceEnabledForTesting = false
        defer { P1ResumeMetrics.forceEnabledForTesting = nil }
        P1ResumeMetrics.begin()
        XCTAssertEqual(P1ResumeMetrics.summary, "", "埋点关闭时不追加字段（旧串不回归）")
    }
}

// MARK: - Test-only driver seeding

private extension P1ResumeDriver {
    /// The production code adopts the channel it created via `channelForAttempt`;
    /// tests build the live channel first (to open streams), then hand it over.
    func resetForTesting(to channel: P1Channel) {
        discard()
        adoptExistingChannelForTesting(channel)
    }
}

// MARK: - WSSClient connect deadline (root cause of the isolated-E2E 8s drop loop)

/// Regression guard for `WSSConnectTimeout`: the pre-fix code armed an
/// un-cancelled `asyncAfter`, which killed a healthy WebSocket `timeout` seconds
/// after a successful upgrade (E2E: `conn.closed code=1006` every ~8s = one per
/// candidate `attemptTimeout`). `WSSClient` now disarms it in
/// `resumeConnectSuccess()` (and in `fail`/`finishClosed`); these tests pin the
/// schedule/cancel contract the client relies on.
final class WSSConnectTimeoutTests: XCTestCase {

    func testArmedDeadlineFiresOnce() {
        let deadline = WSSConnectTimeout()
        let queue = DispatchQueue(label: "test.wss-deadline.fire")
        let fired = expectation(description: "deadline fires")
        deadline.arm(on: queue, after: 0.05) { fired.fulfill() }
        wait(for: [fired], timeout: 2)

        // A one-shot deadline must not fire a second time.
        let secondFire = expectation(description: "no second fire")
        secondFire.isInverted = true
        wait(for: [secondFire], timeout: 0.3)
    }

    /// The upgrade completed: `WSSClient.resumeConnectSuccess()` calls `cancel()`,
    /// so the deadline must never tear the live socket down afterwards.
    func testCancelledDeadlineDoesNotFire() {
        let deadline = WSSConnectTimeout()
        let queue = DispatchQueue(label: "test.wss-deadline.cancel")
        let fired = expectation(description: "cancelled deadline must not fire")
        fired.isInverted = true
        deadline.arm(on: queue, after: 0.05) { fired.fulfill() }
        deadline.cancel()
        deadline.cancel() // idempotent
        wait(for: [fired], timeout: 0.4)
    }

    func testRearmingCancelsThePreviousDeadline() {
        let deadline = WSSConnectTimeout()
        let queue = DispatchQueue(label: "test.wss-deadline.rearm")
        let first = expectation(description: "first (cancelled) deadline must not fire")
        first.isInverted = true
        deadline.arm(on: queue, after: 0.05) { first.fulfill() }
        let second = expectation(description: "latest deadline fires")
        deadline.arm(on: queue, after: 0.2) { second.fulfill() }
        wait(for: [first, second], timeout: 2)
    }

    /// Mirrors the real `WSSClient` ordering: arm in `start(timeout:)`, cancel on
    /// the 101 upgrade (`resumeConnectSuccess`), cancel again on teardown
    /// (`finishClosed`). The socket must survive the whole flow.
    func testUpgradeSuccessThenTeardownCancelIsIdempotent() {
        let deadline = WSSConnectTimeout()
        let queue = DispatchQueue(label: "test.wss-deadline.flow")
        let fired = expectation(description: "healthy socket must not be torn down")
        fired.isInverted = true
        deadline.arm(on: queue, after: 0.06) { fired.fulfill() }
        deadline.cancel() // 101 upgrade completed
        deadline.cancel() // later teardown / fail path
        deadline.cancel() // repeated cancel stays safe
        wait(for: [fired], timeout: 0.3)
    }
}
