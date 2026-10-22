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
}

/// One file per session (`window-<stable-hash>.json`) inside the cache directory.
final class SessionWindowCacheStore {
    /// Very long tool outputs can make a wide snapshot multi-MB; caching that
    /// would slow the next open instead of speeding it up.
    static let maxPayloadBytes = 4 * 1024 * 1024

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
        guard payload.schemaVersion == CacheSchema.version, payload.sessionId == sessionId else {
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
        p1Sid: Int64? = nil
    ) -> Bool {
        guard let identity = identity() else { return false }
        let payload = SessionWindowCachePayload(
            schemaVersion: CacheSchema.version,
            savedAt: now(),
            identity: identity,
            sessionId: sessionId,
            snapshot: snapshot,
            events: events,
            windowMessages: windowMessages,
            hasMore: hasMore,
            p1Epoch: p1Epoch,
            p1Sid: p1Sid
        )
        guard let data = CacheIO.encode(payload), data.count <= Self.maxPayloadBytes else { return false }
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
