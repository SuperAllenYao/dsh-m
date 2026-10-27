import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Session detail window policy.
///
/// the detail no longer has manual "load earlier"
/// pagination. The first paint is a phone-sized window; the full history is then
/// pulled automatically in the background by the history filler. The on-disk cache
/// keeps the newest 300 messages (fast first paint + deep scroll-up headroom),
/// never the full history.
enum SessionWindowPolicy {
 /// Phone-sized first window (messages). 12-20 keeps the first paint cheap; the
 /// network first window must stay small (relay payload), the cache restores
 /// depth from disk instead.
    static let minFirstWindowMessages = 12
    static let maxFirstWindowMessages = 20

 /// First-paint cache depth: the newest 300 messages are persisted per session
 /// .
    static let cachedMessages = 300

 /// Cache chunk size in messages: one phone screen. Keeps the existing
 /// newest-first chunk format and bounds each payload chunk's decode/apply cost.
    static let cachedChunkMessages = maxFirstWindowMessages

 /// Number of screen-sized chunks the 300-message cache is split into (15).
    static var cachedScreens: Int {
        (cachedMessages + cachedChunkMessages - 1) / cachedChunkMessages
    }

 /// turnWindow minima shared by the first window request: stop at a turn
 /// boundary after both minima when the message budget allows it.
    static let turnWindowMinTurns = 8

    struct TurnWindow: Equatable {
        var minMessages: Int
        var minTurns: Int

        var jsonValue: JSONValue {
            .object([
                "minMessages": .int(Int64(minMessages)),
                "minTurns": .int(Int64(minTurns)),
            ])
        }
    }

 /// First window (12-20 messages): the turn stop only matters for short-turn
 /// conversations; in tool-heavy sessions maxMessages binds first.
    nonisolated static func firstWindowTurnWindow(messages: Int) -> TurnWindow {
        TurnWindow(minMessages: max(1, min(8, messages)), minTurns: turnWindowMinTurns)
    }

 /// Screen-height adaptive first window: small phones 12, standard 16,
 /// large (Pro Max class) 20.
    nonisolated static func firstWindowMessages(screenHeight: CGFloat) -> Int {
        guard screenHeight > 0 else { return 16 }
        if screenHeight < 750 { return minFirstWindowMessages }
        if screenHeight >= 850 { return maxFirstWindowMessages }
        return 16
    }

 // MARK: - Background history filler (automatic full-history load)

 /// Filler page size in append-origin messages. Pages are all events in the seq
 /// range, so on tool-heavy sessions a page is several times larger than its
 /// message count. LAN gets bigger pages (fewer round trips); relay/cellular gets
 /// smaller ones (bounded decode/paint cost per batch).
 ///
 /// (task-3, design <internal-doc> L3b):
 /// LAN 160→320 / relay 60→240。单页变大的解码/内存风险由下行 gzip（~4.6x，
 /// 设计 F11 实测）对冲；收益是蜂窝 RTT 轮次近乎减半（F13：relay 8+ 页串行
 /// 是用户 7-8s 报障的主构成，且 L3c 页间流水线让「单页更大、页数更少」的
 /// 收益直接叠加）。初始值，实施段按 U2 bench 校准；回滚＝常量改回。
    static let historyPageMessagesLAN = 320
    static let historyPageMessagesRelay = 240

    nonisolated static func historyPageMessages(isRelay: Bool) -> Int {
        isRelay ? historyPageMessagesRelay : historyPageMessagesLAN
    }

 // MARK: - Prewarm (writes the same 300-message first-paint cache)

 /// Prewarm asks for the full cache window (300 messages) so a warm open paints
 /// the first screen immediately and restores the deep window without any extra
 /// round trip. Cache depth no longer depends on the first window size (12-20),
 /// so the screen height is accepted for call-site compatibility only.
    nonisolated static func prewarmMessages(screenHeight: CGFloat) -> Int {
        cachedMessages
    }

    #if canImport(UIKit)
 /// Current device screen height in points.
    @MainActor static var deviceScreenHeight: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first?.screen.bounds.height ?? 800
    }
    #else
    @MainActor static var deviceScreenHeight: CGFloat { 800 }
    #endif

 /// First window for this device (used by the SessionViewModel.openStream).
    @MainActor static var deviceFirstWindowMessages: Int {
        firstWindowMessages(screenHeight: deviceScreenHeight)
    }

 /// Prewarm window for this device (the full 300-message cache depth).
    @MainActor static var devicePrewarmMessages: Int {
        prewarmMessages(screenHeight: deviceScreenHeight)
    }
}

/// First-paint cache for one session: the newest up-to-300 messages of events plus
/// the metadata the detail header needs (header + projections), so a warm open can
/// paint the first screen without any network round trip and restore a deep window
/// (no "loading earlier messages" jump when scrolling up).
///
/// The payload is chunked by screen (~20 messages), newest chunk first:
/// - on a cold journal the whole cache is flattened into one chronological,
/// gap-free prefix and applied as a single synthetic snapshot -> one rows
/// rebuild (: applying the cache chunk-by-chunk caused a visible
/// flash / viewport jump on real devices);
/// - when the live snapshot lands first, the cached prefix is merged into the
/// journal front with a single prepend.
///
/// There is no full-history cache: the history filler always pulls the rest from the
/// Host.
struct SessionWindowCachePayload: Codable, Equatable {
    var schemaVersion: Int
    var savedAt: Date
 /// Pairing fingerprint of the Mac that wrote this window; see CacheIdentity.
    var identity: String
    var sessionId: String
 /// Newest applied log position when the payload was written.
    var cursor: Int
 /// journal.hasMore at save time (Host still has older events beyond the window).
    var hasMore: Bool?
 /// Session header (id/cwd/...). Title itself comes from projections.
    var header: SessionHeader?
 /// Full projection values at save time (title / permissions / model selection /
 /// todos / user questions / subagent catalog...). Small and needed by the header.
    var projections: ProjectionValues?
 /// Newest-first screen chunks (~20 messages each): flattened this is the newest
 /// 300 messages of the session. chunks[0] is the newest screen (first paint).
    var chunks: [[SessionEvent]]
 /// Evidence: requested first window (messages) at save time.
    var windowMessages: Int?

 /// Oldest event seq this payload can restore (nil when empty).
    var oldestSeq: Int? { chunks.last?.first?.seq }
 /// Newest event seq this payload contains (nil when empty).
    var newestSeq: Int? { chunks.first?.last?.seq }
}

/// One file per session (window-<stable-hash>.json) inside the cache directory.
final class SessionWindowCacheStore {
 /// A 300-message window on a tool-heavy session can be several MB; beyond this
 /// byte budget the oldest chunks are dropped (the filler refetches them; we never
 /// let a cache write slow down or OOM the next open). This is also the per-session
 /// disk cap on top of the retention prune below.
    static let maxPayloadBytes = 4 * 1024 * 1024

 /// Window payload schema. Older schemas (raw snapshot + olderEvents envelope, or
 /// the 4-screen v5 cache) are deleted on read: v6 keeps the newest 300 messages
 /// chunked by screen.
    static let schemaVersion = 6
    static let readableSchemaVersions: Set<Int> = [6]

    struct Loaded {
        var payload: SessionWindowCachePayload
 /// Older than CacheSchema.ttl: shown, but the caller may mark it stale.
        var isStale: Bool
    }

    let directory: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let identity: () -> String?

    init(
        directory: URL = CacheIO.defaultDirectory(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        identity: @escaping () -> String? = { CacheIdentity.current() }
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.now = now
        self.identity = identity
    }

    func fileURL(for sessionId: String) -> URL {
        directory.appendingPathComponent(
            "window-" + CacheIO.stableHash(sessionId) + ".json",
            isDirectory: false
        )
    }

 /// Returns the cached window for the session, or nil when absent / corrupt /
 /// wrong schema / past hard retention / written by a different pairing.
 /// Never throws and never crashes on bad bytes.
    func load(sessionId: String) -> Loaded? {
        let url = fileURL(for: sessionId)
        guard let payload: SessionWindowCachePayload = CacheIO.read(SessionWindowCachePayload.self, from: url) else {
            if fileManager.fileExists(atPath: url.path) {
                CacheIO.remove(url, fileManager: fileManager)
            }
            return nil
        }
        guard payload.identity == identity() else {
            CacheIO.remove(url, fileManager: fileManager)
            return nil
        }
        guard Self.readableSchemaVersions.contains(payload.schemaVersion),
              payload.sessionId == sessionId else {
            CacheIO.remove(url, fileManager: fileManager)
            return nil
        }
        let age = now().timeIntervalSince(payload.savedAt)
        guard age < CacheSchema.retention else {
            CacheIO.remove(url, fileManager: fileManager)
            return nil
        }
        return Loaded(payload: payload, isStale: age > CacheSchema.ttl)
    }

 /// Splits chronological events into up to screens chunks, newest first.
 ///
 /// Each chunk covers about messagesPerScreen append-origin messages and starts at
 /// a message/turn boundary when one can be found in the scanned range (so a
 /// restored chunk[0] starts at a clean row boundary instead of mid tool block).
    nonisolated static func screenChunks(
        events: [SessionEvent],
        messagesPerScreen: Int,
        screens: Int
    ) -> [[SessionEvent]] {
        guard !events.isEmpty, screens > 0, messagesPerScreen > 0 else { return [] }
        let sorted = events.sorted { $0.seq < $1.seq }
        var chunks: [[SessionEvent]] = []
        var end = sorted.count
        var remainingScreens = screens
        while end > 0, remainingScreens > 0 {
            var messageCount = 0
            var scan = end - 1
            var start = end - 1
            while scan >= 0 {
                start = scan
                let type = sorted[scan].type
                if type == "user/message" || type == "assistant/message" {
                    messageCount += 1
                }
                if messageCount >= messagesPerScreen { break }
                scan -= 1
            }
 // Prefer a clean boundary at/after the scanned start.
            var boundary = start
            var probe = start
            while probe < end {
                let type = sorted[probe].type
                if type == "user/message" || type == "turn/start" { boundary = probe; break }
                probe += 1
            }
            if boundary >= end { break }
            let chunk = Array(sorted[boundary..<end])
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
            end = boundary
            remainingScreens -= 1
        }
        return chunks
    }

 /// One pending (or in-flight) background write. Only the newest one is kept:
 /// a history fill can trigger a save every batch, and re-encoding intermediate
 /// windows is wasted CPU.
    private struct SaveWork {
 /// nil = 后台写入时再读身份（避免主线程 keychain/identity 读取开销）。
        let identity: String?
        let sessionId: String
        let cursor: Int
        let hasMore: Bool?
        let header: SessionHeader?
        let projections: ProjectionValues?
        let events: [SessionEvent]
        let windowMessages: Int?
        let messagesPerScreen: Int
        let screens: Int
    }

 /// 测试开关：`saveAsync` 退化为同步写（单测断言「调用返回即落盘」；生产恒为 false）。
    static var synchronousWritesForTesting = false

    private let saveQueue = DispatchQueue(label: "com.dshm.session-window-cache.save", qos: .utility)
    private let pendingLock = NSLock()
    private var pendingWork: SaveWork?
    private var drainScheduled = false

 /// 后台队列版本（合并写入）：主线程只做参数捕获，分屏/编码/原子写全部在 utility 队列。
 /// 历史补齐每批都会写缓存，同步做（每批 ~29ms）会直接造成滑动卡顿。
    @discardableResult
    func saveAsync(
        sessionId: String,
        cursor: Int,
        hasMore: Bool?,
        header: SessionHeader?,
        projections: ProjectionValues?,
        events: [SessionEvent],
        windowMessages: Int? = nil,
        messagesPerScreen: Int = SessionWindowPolicy.maxFirstWindowMessages,
        screens: Int = SessionWindowPolicy.cachedScreens
    ) -> Bool {
        guard !events.isEmpty else { return false }
        if Self.synchronousWritesForTesting {
            return save(
                sessionId: sessionId,
                cursor: cursor,
                hasMore: hasMore,
                header: header,
                projections: projections,
                events: events,
                windowMessages: windowMessages,
                messagesPerScreen: messagesPerScreen,
                screens: screens
            )
        }
        let work = SaveWork(
            identity: nil,
            sessionId: sessionId,
            cursor: cursor,
            hasMore: hasMore,
            header: header,
            projections: projections,
            events: events,
            windowMessages: windowMessages,
            messagesPerScreen: messagesPerScreen,
            screens: screens
        )
        pendingLock.lock()
        pendingWork = work
        let schedule = !drainScheduled
        drainScheduled = true
        pendingLock.unlock()
        if schedule {
            saveQueue.async { [weak self] in self?.drainSaves() }
        }
        return true
    }

    private func drainSaves() {
        while true {
            pendingLock.lock()
            guard let work = pendingWork else {
                drainScheduled = false
                pendingLock.unlock()
                return
            }
            pendingWork = nil
            pendingLock.unlock()
            #if DEBUG
            PerfProbe.shared.measure("cacheSaveBG", ["events": work.events.count]) {
                _ = writeNow(work)
            }
            #else
            _ = writeNow(work)
            #endif
        }
    }

 /// Persists the newest screen chunks (up to 300 messages) derived from
 /// chronological events. Oldest chunks are dropped when the encoded payload
 /// exceeds the byte budget.
    @discardableResult
    func save(
        sessionId: String,
        cursor: Int,
        hasMore: Bool?,
        header: SessionHeader?,
        projections: ProjectionValues?,
        events: [SessionEvent],
        windowMessages: Int? = nil,
        messagesPerScreen: Int = SessionWindowPolicy.maxFirstWindowMessages,
        screens: Int = SessionWindowPolicy.cachedScreens
    ) -> Bool {
        guard let identity = identity(), !events.isEmpty else { return false }
        return writeNow(SaveWork(
            identity: identity,
            sessionId: sessionId,
            cursor: cursor,
            hasMore: hasMore,
            header: header,
            projections: projections,
            events: events,
            windowMessages: windowMessages,
            messagesPerScreen: messagesPerScreen,
            screens: screens
        ))
    }

    private func writeNow(_ work: SaveWork) -> Bool {
        guard let identity = work.identity ?? identity() else { return false }
        let sessionId = work.sessionId
        let events = work.events
        var payload = SessionWindowCachePayload(
            schemaVersion: Self.schemaVersion,
            savedAt: now(),
            identity: identity,
            sessionId: sessionId,
            cursor: work.cursor,
            hasMore: work.hasMore,
            header: work.header,
            projections: work.projections,
            chunks: Self.screenChunks(
                events: events,
                messagesPerScreen: work.messagesPerScreen,
                screens: work.screens
            ),
            windowMessages: work.windowMessages
        )
        guard !payload.chunks.isEmpty else { return false }
        guard var data = CacheIO.encode(payload) else { return false }
 // Drop the oldest screens until the payload fits. Dropping a screen is safe:
 // the history filler refetches it from the Host on the next open.
        while data.count > Self.maxPayloadBytes, payload.chunks.count > 1 {
            payload.chunks.removeLast()
            guard let encoded = CacheIO.encode(payload) else { return false }
            data = encoded
        }
        guard data.count <= Self.maxPayloadBytes else { return false }
        let url = fileURL(for: sessionId)
        guard CacheIO.writeDataAtomically(data, to: url, fileManager: fileManager) else { return false }
        pruneExpiredFiles(keeping: url)
        return true
    }

    func clear(sessionId: String) {
        CacheIO.remove(fileURL(for: sessionId))
    }

 /// Drops session windows older than the hard retention so the cache directory
 /// cannot grow without bound across app launches.
    private func pruneExpiredFiles(keeping keep: URL) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = now().addingTimeInterval(-CacheSchema.retention)
        for url in entries {
            guard url.lastPathComponent.hasPrefix("window-"),
                  url.lastPathComponent.hasSuffix(".json"),
                  url.standardizedFileURL != keep.standardizedFileURL else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            CacheIO.remove(url)
        }
    }
}
