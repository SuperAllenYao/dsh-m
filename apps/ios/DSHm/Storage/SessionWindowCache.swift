import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Session detail window policy.
///
/// the detail no longer has manual "load earlier"
/// pagination. The first paint is a phone-sized window; the full history is then
/// pulled automatically in the background by the history filler. The on-disk cache
/// only keeps the latest 4 screens (fast first paint + a little scroll-up headroom),
/// never the full history.
enum SessionWindowPolicy {
 /// Phone-sized first window (messages). 12-20 keeps the first paint cheap.
    static let minFirstWindowMessages = 12
    static let maxFirstWindowMessages = 20

 /// First-paint cache depth: the newest 4 screens are persisted.
    static let cachedScreens = 4

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
    static let historyPageMessagesLAN = 160
    static let historyPageMessagesRelay = 60

    nonisolated static func historyPageMessages(isRelay: Bool) -> Int {
        isRelay ? historyPageMessagesRelay : historyPageMessagesLAN
    }

 // MARK: - Prewarm (writes the same 4-screen first-paint cache)

 /// Prewarm asks for the full 4-screen cache window so a warm open paints the
 /// first screen from chunk 0 and has the other 3 screens ready immediately.
    nonisolated static func prewarmMessages(screenHeight: CGFloat) -> Int {
        firstWindowMessages(screenHeight: screenHeight) * cachedScreens
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

 /// Prewarm window for this device (4 screens).
    @MainActor static var devicePrewarmMessages: Int {
        prewarmMessages(screenHeight: deviceScreenHeight)
    }
}

/// First-paint cache for one session: the newest up-to-4 screens of events plus the
/// metadata the detail header needs (header + projections), so a warm open can paint
/// the first screen without any network round trip and without re-decoding a huge
/// payload.
///
/// The payload is chunked by screen, newest chunk first:
/// - restore applies chunks[0] as a synthetic snapshot -> first paint rows;
/// - chunks[1...] are then merged into the front in the background (cheap,
/// bounded memory).
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
 /// Newest-first screen chunks. chunks[0] is the newest screen (first paint).
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
 /// A 4-screen window on a tool-heavy session can be a couple of MB; beyond this
 /// the oldest screens are dropped (the filler refetches them; we never let a
 /// cache write slow down or OOM the next open).
    static let maxPayloadBytes = 4 * 1024 * 1024

 /// Window payload schema. Older schemas (raw snapshot + olderEvents envelope)
 /// are deleted on read: the cache is chunked by screen and has no
 /// full-history range.
    static let schemaVersion = 5
    static let readableSchemaVersions: Set<Int> = [5]

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

 /// Persists the newest screens screens derived from chronological events.
 /// Oldest screens are dropped when the encoded payload exceeds the byte budget.
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
