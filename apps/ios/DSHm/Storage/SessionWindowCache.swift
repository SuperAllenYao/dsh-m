import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// P1.5-B: phone-sized `session/follow` first window.
///
/// P1.5-B measure: the detail's first open used to request 40 messages (~0.72MB on
/// the bench sessions), so a cache miss paid the whole window before *anything*
/// could paint (App 内首帧 329ms / 跨进程 687ms). The user only sees the newest
/// few turns first, so the live request now starts with a screen-sized window and
/// the legacy 40-message window is filled in the background (see
/// `SessionViewModel`); prewarm writes the same small window, which also makes the
/// prewarmed cache land sooner.
enum SessionWindowPolicy {
    /// P1.5 plan bounds: 12–20 messages for the first window.
    static let minFirstWindowMessages = 12
    static let maxFirstWindowMessages = 20
    /// Background fill target: keeps the legacy 40-message history window.
    static let fillWindowMessages = 40

    // MARK: - turnWindow (task session-history)

    /// Turn minima shared by every window: cover ~8 complete turns *when the
    /// session's turns are short*, never at the cost of a bigger window.
    ///
    /// Host semantics (verified 2026-10-22 in the installed session-controller
    /// `paginate`): the Host walks backwards from the window end, counts
    /// append-origin user/assistant messages, and stops at a `turn/start` once
    /// `count >= minMessages && turns >= minTurns` — **unless `maxMessages` or
    /// history exhaustion wins first**. `minMessages` must be ≤ `maxMessages`
    /// (Host-side validation). Consequence: adding a turnWindow never enlarges a
    /// window; it only stops *earlier* at a turn boundary.
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

    /// First window (12–20 messages): keep it phone-sized for the first paint; the
    /// turn stop only matters for short-turn conversations (in tool-heavy sessions
    /// `maxMessages` binds first — measured on real logs, see the session-history
    /// report).
    nonisolated static func firstWindowTurnWindow(messages: Int) -> TurnWindow {
        TurnWindow(minMessages: max(1, min(8, messages)), minTurns: turnWindowMinTurns)
    }

    /// Background fill window (40 messages): stop at a turn start once 32 messages
    /// and 8 turns are covered, otherwise the 40-message cap wins.
    nonisolated static func fillWindowTurnWindow(messages: Int) -> TurnWindow {
        TurnWindow(minMessages: max(1, min(messages - 8, messages)), minTurns: turnWindowMinTurns)
    }

    /// Older-history page step: 40 user/assistant messages (schema allows 40–60; a
    /// page is *all* events in the seq range, so 40 messages ≈ 350–400 events /
    /// 0.8–1.2MB on the measured long sessions — the same order as the legacy
    /// 40-message fill, just fetched on demand while scrolling up).
    static let pageWindowMessages = 40

    /// Page turn stop: ≥32 messages + ≥8 turns, otherwise `maxMessages` wins.
    nonisolated static var pageTurnWindow: TurnWindow {
        TurnWindow(minMessages: 32, minTurns: turnWindowMinTurns)
    }

    /// Screen-height adaptive first window: small phones 12, standard 16,
    /// large (Pro Max class) 20.
    nonisolated static func firstWindowMessages(screenHeight: CGFloat) -> Int {
        guard screenHeight > 0 else { return 16 }
        if screenHeight < 750 { return minFirstWindowMessages }
        if screenHeight >= 850 { return maxFirstWindowMessages }
        return 16
    }

    /// Fill window: never smaller than the first window (a fill must be a superset).
    nonisolated static func fillMessages(firstWindow: Int) -> Int {
        max(fillWindowMessages, firstWindow)
    }

    /// Prewarm writes exactly the window the first open asks for, so a warm cache
    /// is a complete hit (smaller payload = it lands before the user taps).
    nonisolated static func prewarmMessages(screenHeight: CGFloat) -> Int {
        firstWindowMessages(screenHeight: screenHeight)
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

    /// First window for this device (used by `SessionViewModel.openStream`).
    @MainActor static var deviceFirstWindowMessages: Int {
        firstWindowMessages(screenHeight: deviceScreenHeight)
    }

    /// Prewarm window for this device (used by the workspace list prewarmer).
    @MainActor static var devicePrewarmMessages: Int {
        prewarmMessages(screenHeight: deviceScreenHeight)
    }
}

/// Cached detail window for one session: the last `session/follow` snapshot frame
/// (raw wire JSON, phone-sized first window plus the background-filled history)
/// plus the raw event frames that followed it.
///
/// Like `SessionListCache`, the payload stays as wire JSON: restoring replays the
/// frames through `SessionJournal` (`SessionStreamFrame.decode` → `apply(snapshot:)`
/// / `apply(event:)`), which gives sequence ordering and de-duplication for free.
/// `assistant-stream` deltas are intentionally not cached (ephemeral live text; the
/// next live snapshot/session stream supersedes them).
struct SessionWindowCachePayload: Codable, Equatable {
    var schemaVersion: Int
    var savedAt: Date
    /// Pairing fingerprint of the Mac that wrote this window; see `CacheIdentity`.
    var identity: String
    var sessionId: String
    /// Raw `{"type":"snapshot", ...}` item value as received on `session/follow`.
    var snapshot: JSONValue
    /// Raw `event` objects (the `event` field of an `{"type":"event"}` frame),
    /// contiguous after `snapshot`.
    var events: [JSONValue]
    /// P1.5-B: number of messages the snapshot was requested with (window size
    /// evidence; caches written before this field decode with nil = legacy 40).
    var windowMessages: Int?
    /// P1.5-B: `snapshot.hasMore` (older history exists; the last live window is
    /// the 40-message background fill, so a warm cache is still complete).
    var hasMore: Bool?
    /// P1 resume base: channel epoch + applied downstream `sid` when this window
    /// was last aligned with the live stream. Only meaningful on dsh-m/2; nil on
    /// the legacy path (which keeps its old behaviour).
    var p1Epoch: String?
    var p1Sid: Int64?

    // MARK: - v3 (task session-history): loaded older range

    /// Raw `event` objects **older than** `snapshot`'s first record, ascending by
    /// seq (the front of the loaded window, filled by `session/page`). A cold open
    /// replays them so the user's loaded history is still there instead of
    /// regressing to the newest message window.
    var olderEvents: [JSONValue]?
    /// Oldest event seq this payload can restore (= `olderEvents.first` seq, or the
    /// snapshot's first record when no older range is persisted). Evidence field:
    /// restoring derives the same value from the replayed records.
    var oldestSeq: Int?
    /// `session/page` `hasMore` at save time: true = the Host still has events
    /// before `oldestSeq` (the user can keep scrolling up). Nil on v2 payloads,
    /// which are interpreted from the legacy `hasMore` field instead.
    var hasMoreOlder: Bool?
    /// v4 (task-6): sticky "the session's first event has already been loaded".
    /// Once true, a cold open must not show the "load earlier" entry again. Nil on
    /// v2/v3 payloads: derived as `oldestSeq == 0 || replayed front seq == 0`.
    var hasReachedOldest: Bool?
}

/// One file per session (`window-<stable-hash>.json`) inside the cache directory.
final class SessionWindowCacheStore {
    /// Very long tool outputs can make a wide snapshot multi-MB; caching that
    /// would slow the next open instead of speeding it up.
    static let maxPayloadBytes = 4 * 1024 * 1024

    /// Window payload schema.
    /// - **v3** (task session-history) adds the loaded older range
    ///   (`olderEvents` / `oldestSeq` / `hasMoreOlder`);
    /// - **v4** (task-6) adds the sticky `hasReachedOldest` termination flag.
    ///
    /// v2/v3 payloads stay readable: v2 means "the legacy 40-message window"
    /// (`oldestSeq = earliest record`, `hasMoreOlder = legacy hasMore`), v3 lacks
    /// only the sticky flag (derived from the replayed front seq). The shared
    /// `CacheSchema.version` is deliberately untouched: the session-list payloads
    /// have their own schema and must not be invalidated by this change.
    static let schemaVersion = 4
    /// Versions `load` accepts (v2 = legacy 40-message window, upgraded in memory).
    static let readableSchemaVersions: Set<Int> = [2, 3, 4]
    /// First schema that carries the older-range fields (`olderEvents` etc.).
    static let olderRangeSchemaVersion = 3

    struct Loaded {
        var payload: SessionWindowCachePayload
        /// Older than `CacheSchema.ttl`: shown, but the caller may mark it stale.
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
            "window-\(CacheIO.stableHash(sessionId)).json",
            isDirectory: false
        )
    }

    /// Returns the cached window for `sessionId`, or nil when absent / corrupt /
    /// wrong schema / past hard retention / **written by a different pairing**.
    /// Never throws and never crashes on bad bytes.
    func load(sessionId: String) -> Loaded? {
        let url = fileURL(for: sessionId)
        guard let payload: SessionWindowCachePayload = CacheIO.read(SessionWindowCachePayload.self, from: url) else {
            if fileManager.fileExists(atPath: url.path) {
                CacheIO.remove(url, fileManager: fileManager)
            }
            return nil
        }
        // Another Mac's window must never render: delete it and use the network path.
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

    @discardableResult
    func save(
        sessionId: String,
        snapshot: JSONValue,
        events: [JSONValue],
        windowMessages: Int? = nil,
        hasMore: Bool? = nil,
        p1Epoch: String? = nil,
        p1Sid: Int64? = nil,
        olderEvents: [JSONValue] = [],
        oldestSeq: Int? = nil,
        hasMoreOlder: Bool? = nil,
        hasReachedOldest: Bool? = nil
    ) -> Bool {
        guard let identity = identity() else { return false }
        var payload = SessionWindowCachePayload(
            schemaVersion: Self.schemaVersion,
            savedAt: now(),
            identity: identity,
            sessionId: sessionId,
            snapshot: snapshot,
            events: events,
            windowMessages: windowMessages,
            hasMore: hasMore,
            p1Epoch: p1Epoch,
            p1Sid: p1Sid,
            olderEvents: olderEvents.isEmpty ? nil : olderEvents,
            oldestSeq: oldestSeq,
            hasMoreOlder: hasMoreOlder,
            hasReachedOldest: hasReachedOldest
        )
        guard var data = CacheIO.encode(payload) else { return false }
        // A long session can accumulate more loaded older history than the cold-start
        // budget. Persisting *some* of it beats failing the whole write (a cold start
        // without any window cache is a much worse regression): drop the oldest older
        // events until the payload fits, and report `hasMoreOlder = true` so
        // scrolling up refetches the dropped prefix from the Host.
        while data.count > Self.maxPayloadBytes,
              let older = payload.olderEvents, !older.isEmpty {
            let keep = older.count / 2
            payload.olderEvents = keep > 0 ? Array(older.suffix(keep)) : nil
            payload.oldestSeq = nil
            payload.hasMoreOlder = true
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
        CacheIO.remove(fileURL(for: sessionId), fileManager: fileManager)
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
            CacheIO.remove(url, fileManager: fileManager)
        }
    }
}
