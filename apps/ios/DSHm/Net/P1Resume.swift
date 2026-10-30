import Foundation

// MARK: - dsh-m/2 resume policy (design §5 READY -> RESUMING -> READY)

/// Pure disposition of one socket loss on a ready dsh-m/2 channel (design §5).
///
/// `LinkService.handleP1Close` asks this type instead of branching on the raw
/// `P1Failure`, so the "replay window keeps the stream table / v2 fallback drops
/// it" decision is unit-testable without a socket.
enum P1ResumePolicy {
    enum Disposition: Equatable {
 /// Keep the channel + stream table and reconnect with `hello{resume}`.
        case retainForResume
 /// v2 is unusable on this connection: drop everything, continue on M1.
        case fallbackLegacy
    }

    static func disposition(for failure: P1Failure) -> Disposition {
        failure.shouldFallbackLegacy ? .fallbackLegacy : .retainForResume
    }

 /// The replay success path is silent: a retryable socket loss must not paint
 /// an error banner. Errors surface only once a resume round actually fails.
    static func surfacesErrorBanner(_ disposition: Disposition) -> Bool {
        disposition == .fallbackLegacy
    }
}

/// What a `welcome` means for the retained channel (design §5 transition table).
struct P1ResumePlan: Equatable {
    enum Streams: Equatable {
 /// Keep live streams/descriptors; replay frames continue them.
        case retain
 /// Drop the old stream table; the business layer rebuilds from snapshots.
        case discard
    }

    var mode: P1ResumeInfo.Mode
    var streams: Streams
    var reopenEvents: Bool
    var bumpGeneration: Bool
 /// Server-reported replayed frame count (`welcome.resume.replayed`).
    var replayedFrames: Int?
 /// Reset cause (`epoch-mismatch`/`evicted`/`sid-ahead`/`gap`) for telemetry.
    var resetReason: String?

 /// Replay that continues the retained streams: no UI rebuild, no flash.
    var isSilentResume: Bool { streams == .retain && !bumpGeneration }

 /// Matrix (design §5):
 /// - `replay` + retained live streams: keep streams, keep `$events`, no bump;
 /// - `replay` without retained live streams (cold start with a persisted
 /// cursor, or the business layer cancelled during the window): rebuild;
 /// - `reset`/`fresh`: drop streams, reopen `$events`, bump generation.
    static func make(welcome: P1Welcome, isResumeAttempt: Bool, hadLiveStreams: Bool) -> P1ResumePlan {
        switch welcome.resume.mode {
        case .replay:
            let retain = isResumeAttempt && hadLiveStreams
            return P1ResumePlan(
                mode: .replay,
                streams: retain ? .retain : .discard,
                reopenEvents: !retain,
                bumpGeneration: !retain,
                replayedFrames: welcome.resume.replayed,
                resetReason: nil
            )
        case .fresh:
            return P1ResumePlan(
                mode: .fresh,
                streams: .discard,
                reopenEvents: true,
                bumpGeneration: true,
                replayedFrames: nil,
                resetReason: nil
            )
        case .reset:
            return P1ResumePlan(
                mode: .reset,
                streams: .discard,
                reopenEvents: true,
                bumpGeneration: true,
                replayedFrames: nil,
                resetReason: welcome.resume.reason
            )
        }
    }
}

/// `welcome.ticket` rotation (design §4.2): drop the used/rejected tickets, then
/// promote the freshly rotated one; keep at most `limit` (2) cached.
enum P1ResumeTickets {
    static let maxTickets = 2

 /// 票据 payload 的本地过期预检（DD-12，纯函数，不触网）。
 ///
 /// 票据格式（插件 `mintResumeTicket`，`packages/dsh-m-link/lib/mux-rpc.js`）：
 /// `base64url(payloadJSON).base64url(HMAC-SHA256)`，payload 里的 `exp` 是
 /// **毫秒**时间戳。客户端只读 `exp`、不校验签名（签名由插件负责）：过期票据
 /// 发 hello 只会换来 `auth/invalid-ticket`（4401）+ 再走一次 ECDSA 挑战，
 /// 白白多付 1+2 个 RTT；本地判定后直接走 ECDSA。
 ///
 /// - Returns: `true` = 已过期；`false` = 未过期；`nil` = **未知**（格式不符 /
 /// 没有数字 `exp` / base64url 或 JSON 解析失败）——调用方保持现行为（仍按
 /// 票据发送），不因解析失败改变协议行为。
    static func isExpired(ticket: String, now: Date = Date()) -> Bool? {
        guard let expiresAtMs = expiryMilliseconds(ticket: ticket) else { return nil }
        return expiresAtMs <= now.timeIntervalSince1970 * 1000
    }

 /// 票据 payload 的毫秒 `exp`；解析失败/字段类型不符时 nil。
    static func expiryMilliseconds(ticket: String) -> TimeInterval? {
        guard let payload = decodePayload(ticket: ticket) else { return nil }
        guard let raw = payload["exp"], !(raw is Bool), let number = raw as? NSNumber else { return nil }
        let milliseconds = number.doubleValue
        guard milliseconds.isFinite else { return nil }
        return milliseconds
    }

 /// 本次连接尝试可用的下一张票（DD-12）：队列里**未用过**、且本地判定
 /// **未过期**（未知视作可用，保持旧 App 语义）的第一张；没有则 nil
 /// （调用方直接走 ECDSA）。
    static func nextUsableTicket(
        _ tickets: [String]?,
        used: Set<String>,
        now: Date = Date()
    ) -> String? {
        guard let tickets else { return nil }
        return tickets.first { ticket in
            !ticket.isEmpty
                && !used.contains(ticket)
                && isExpired(ticket: ticket, now: now) != true
        }
    }

 /// 解码票据的 payload 段为 JSON 对象；失败返回 nil。
 ///
 /// 真实票据形如 `payload.signature`；为便于单测也接受「只有 payload」的
 /// 写法（没有 `.` 时整串视为 payload），不影响生产行为（真实票据恒有签名段）。
    private static func decodePayload(ticket: String) -> [String: Any]? {
        guard !ticket.isEmpty else { return nil }
        let dot = ticket.firstIndex(of: ".")
        var body = dot.map { String(ticket[ticket.startIndex..<$0]) } ?? ticket
        guard !body.isEmpty else { return nil }
 // base64url -> base64（插件侧无 padding）。
        body = body
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while body.count % 4 != 0 { body += "=" }
        guard let data = Data(base64Encoded: body),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func rotate(
        _ tickets: [String]?,
        used: String?,
        rejected: String?,
        rotated: String?,
        limit: Int = maxTickets
    ) -> [String] {
        var out = tickets ?? []
        let stale = Set([used, rejected].compactMap { $0 })
        if !stale.isEmpty { out.removeAll { stale.contains($0) } }
        if let rotated, !rotated.isEmpty {
            out.removeAll { $0 == rotated }
            out.insert(rotated, at: 0)
        }
        return Array(out.prefix(limit))
    }
}

// MARK: - LinkService retention driver

/// Keeps one `P1Channel` (and therefore its stream table) across a socket loss so
/// the next `connect` can resume it (design §5 `RESUMING`).
///
/// Split out of `LinkService` so the full replay/reset lifecycle can be unit
/// tested over the same `P1Socket` fake the transport tests use — no Keychain,
/// no auth, no `LinkService` bootstrap.
@MainActor
final class P1ResumeDriver {
 /// host, port, leaf pin, connect timeout -> a fresh channel.
    typealias ChannelFactory = @MainActor (
        _ host: String,
        _ port: UInt16,
        _ leafPin: String,
        _ connectTimeout: TimeInterval
    ) -> P1Channel

    private let makeChannel: ChannelFactory
    private(set) var channel: P1Channel?
 /// True between a resumable socket loss and the next `welcome`.
    private(set) var isRetained = false

    init(makeChannel: @escaping ChannelFactory) {
        self.makeChannel = makeChannel
    }

 /// Streams still registered on the retained channel (0 when not resuming).
    var retainedStreamCount: Int {
        isRetained ? (channel?.openStreams.count ?? 0) : 0
    }

 /// Channel to use for the next `connect` attempt. A retained channel is
 /// reused as-is (its `streams`/descriptors are the resume state); otherwise a
 /// fresh channel is built and any stale non-retained one is disposed.
    func channelForAttempt(
        host: String,
        port: UInt16,
        leafPin: String,
        connectTimeout: TimeInterval
    ) -> (channel: P1Channel, isResumeAttempt: Bool) {
        if let channel, isRetained {
            return (channel, true)
        }
        if let stale = channel {
            stale.onClose = nil
            stale.discardAllStreams()
            stale.disconnect()
        }
        let created = makeChannel(host, port, leafPin, connectTimeout)
        channel = created
        return (created, false)
    }

 /// Marks the current channel as the resume candidate after a socket loss.
    func retainAfterSocketLoss() {
        guard channel != nil else { return }
        isRetained = true
    }

 /// Test seam: adopts an already-connected channel. Production always wires
 /// the channel through `channelForAttempt` (which adopts it implicitly); the
 /// unit tests build the live channel first so they can open streams on it.
    func adoptExistingChannelForTesting(_ channel: P1Channel) {
        self.channel = channel
        isRetained = false
    }

 /// Applies a `welcome` to the retained channel: performs the stream-table
 /// action (notifying per-stream `onClose` when discarding) and returns the
 /// generation/events plan for `LinkService`.
    func apply(welcome: P1Welcome) -> P1ResumePlan {
        let isResumeAttempt = isRetained
        let hadLiveStreams = channel?.hasLiveStreams ?? false
        let plan = P1ResumePlan.make(
            welcome: welcome,
            isResumeAttempt: isResumeAttempt,
            hadLiveStreams: hadLiveStreams
        )
        if plan.streams == .discard, let channel {
            channel.discardAllStreams(
                reason: plan.resetReason.map { "dsh-m/2 通道重置（\($0)）" } ?? "dsh-m/2 流表重建"
            )
        }
        isRetained = false
        return plan
    }

 /// Hard-drop the retained channel (legacy fallback, explicit reconnect).
    func discard() {
        guard let channel else {
            isRetained = false
            return
        }
        channel.onClose = nil
        channel.discardAllStreams()
        channel.disconnect()
        self.channel = nil
        isRetained = false
    }
}

// MARK: - Resume telemetry

/// `connect-metrics` extension for the replay path (design §7.3).
///
/// Kept next to the Net stack instead of `ConnectionMetrics` so the
/// `Storage/StartupMetrics.swift` surface (shared with the E2E bench) stays
/// untouched; `LinkService.connectionMetricsValue` appends this summary to the
/// existing string, so old parsers/assertions keep working.
@MainActor
enum P1ResumeMetrics {
 /// Unit-test override; `nil` means "follow the E2E gates of ConnectionMetrics".
    static var forceEnabledForTesting: Bool?

    static var isEnabled: Bool {
        if let forceEnabledForTesting { return forceEnabledForTesting }
        return ConnectionMetrics.isEnabled
    }

    private static var replayedFrames = -1
    private static var replayedBytes = -1
    private static var resumeReason = "-"
    private static var recoverMs = -1

    static func begin() {
        replayedFrames = -1
        replayedBytes = -1
        resumeReason = "-"
        recoverMs = -1
    }

 /// Records the handshake outcome for this round. `recoverMs` is the time from
 /// the socket loss to the replay `welcome` (nil when this was not a resume).
    static func record(plan: P1ResumePlan, welcome: P1Welcome, recoverMs: Int?) {
        guard isEnabled else { return }
        resumeReason = plan.resetReason ?? "-"
        self.recoverMs = recoverMs ?? -1
        switch plan.mode {
        case .replay:
            replayedFrames = welcome.resume.replayed ?? -1
            replayedBytes = 0
        case .fresh, .reset:
            replayedFrames = -1
            replayedBytes = -1
        }
    }

 /// Called once the replay window closed with the frames/bytes actually
 /// applied by `P1Channel` (the server does not report byte counts).
    static func markReplayComplete(frames: Int, bytes: Int) {
        guard isEnabled else { return }
        if frames > 0 { replayedFrames = frames }
        replayedBytes = bytes
    }

 /// `resumeReplayedFrames=..;resumeReplayedBytes=..;resumeReason=..;recoverMs=..`
 /// (`-1`/`-` = not a P1 round / not a replay).
    static var summary: String {
        guard isEnabled else { return "" }
        return "resumeReplayedFrames=\(replayedFrames);resumeReplayedBytes=\(replayedBytes);resumeReason=\(resumeReason);recoverMs=\(recoverMs)"
    }
}
