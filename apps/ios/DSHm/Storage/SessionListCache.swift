import Foundation

/// Cached workspace list: the raw `session/list` result plus the raw
/// `workspace/follow` baseline frame.
///
/// Both are stored as wire JSON on purpose: restoring them replays exactly the same
/// decoding path the network frames use (`SessionListValue` / `WorkspaceFollowFrame`),
/// so there is no second model to keep in sync and no lossy re-encoding.
struct SessionListCachePayload: Codable, Equatable {
    var schemaVersion: Int
    var savedAt: Date
 /// Pairing fingerprint of the Mac that wrote this cache; see `CacheIdentity`.
    var identity: String
    var sessionList: JSONValue?
    var followBaseline: JSONValue?
}

/// Two files inside the cache directory:
/// - `session-list.json` raw wire snapshot (background refresh/consistency)
/// - `session-list-render.json` M2b-2b compact render snapshot (cold-start first frame)
final class SessionListCacheStore {
    struct Loaded {
        var payload: SessionListCachePayload
 /// Older than `CacheSchema.ttl`: show it, but mark the list as stale.
        var isStale: Bool
    }

    struct RenderLoaded {
        var payload: SessionListRenderSnapshot
 /// Older than `CacheSchema.ttl`: show it, but mark the list as stale.
        var isStale: Bool
    }

    let directory: URL
    let fileURL: URL
    let renderFileURL: URL
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
        self.fileURL = directory.appendingPathComponent("session-list.json", isDirectory: false)
        self.renderFileURL = directory.appendingPathComponent("session-list-render.json", isDirectory: false)
        self.fileManager = fileManager
        self.now = now
        self.identity = identity
    }

 /// Returns the cached raw list, or nil when absent / corrupt / outdated schema /
 /// past hard retention / **written by a different pairing**. Never throws and
 /// never crashes on bad bytes.
    func load() -> Loaded? {
        guard let payload: SessionListCachePayload = CacheIO.read(SessionListCachePayload.self, from: fileURL) else {
 // Corrupt or from an older build: drop it so the next save starts clean.
            if fileManager.fileExists(atPath: fileURL.path) {
                CacheIO.remove(fileURL, fileManager: fileManager)
            }
            return nil
        }
        guard let age = validate(payload.identity, payload.schemaVersion, payload.savedAt, at: fileURL) else {
            return nil
        }
        return Loaded(payload: payload, isStale: age > CacheSchema.ttl)
    }

 /// Returns the compact render snapshot used for the cold-start first frame.
 /// Same envelope semantics as `load()`; a broken/mismatched compact snapshot is
 /// deleted and the caller falls back to the raw path.
    func loadRenderSnapshot() -> RenderLoaded? {
        guard let payload: SessionListRenderSnapshot = CacheIO.read(SessionListRenderSnapshot.self, from: renderFileURL) else {
            if fileManager.fileExists(atPath: renderFileURL.path) {
                CacheIO.remove(renderFileURL, fileManager: fileManager)
            }
            return nil
        }
        guard let age = validate(payload.identity, payload.schemaVersion, payload.savedAt, at: renderFileURL) else {
            return nil
        }
        return RenderLoaded(payload: payload, isStale: age > CacheSchema.ttl)
    }

    @discardableResult
    func save(sessionList: JSONValue?, followBaseline: JSONValue?) -> Bool {
        guard sessionList != nil || followBaseline != nil,
              let identity = identity() else { return false }
        let payload = SessionListCachePayload(
            schemaVersion: CacheSchema.version,
            savedAt: now(),
            identity: identity,
            sessionList: sessionList,
            followBaseline: followBaseline
        )
        return CacheIO.writeAtomically(payload, to: fileURL, fileManager: fileManager)
    }

 /// Writes the compact render snapshot (same identity/TTL envelope as the raw one).
    @discardableResult
    func saveRenderSnapshot(
        groups: [SessionListRenderSnapshot.Group],
        followBaseline: JSONValue?
    ) -> Bool {
        guard let identity = identity() else { return false }
        let payload = SessionListRenderSnapshot(
            schemaVersion: CacheSchema.version,
            savedAt: now(),
            identity: identity,
            followBaseline: followBaseline,
            groups: groups
        )
        return CacheIO.writeAtomically(payload, to: renderFileURL, fileManager: fileManager)
    }

    func clear() {
        CacheIO.remove(fileURL, fileManager: fileManager)
        CacheIO.remove(renderFileURL, fileManager: fileManager)
    }

    func clearRenderSnapshot() {
        CacheIO.remove(renderFileURL, fileManager: fileManager)
    }

 // MARK: - Envelope validation

 /// Shared identity/schema/retention check. Returns the age when valid, or nil
 /// after deleting the file (corrupt/other pairing/other schema/too old).
    private func validate(_ payloadIdentity: String, _ schemaVersion: Int, _ savedAt: Date, at url: URL) -> TimeInterval? {
 // A cache from another Mac (or from before this pairing) must never render:
 // treat it as absent and delete it so the network path is used immediately.
        guard payloadIdentity == identity() else {
            CacheIO.remove(url, fileManager: fileManager)
            return nil
        }
        guard schemaVersion == CacheSchema.version else {
            CacheIO.remove(url, fileManager: fileManager)
            return nil
        }
        let age = now().timeIntervalSince(savedAt)
        guard age < CacheSchema.retention else {
            CacheIO.remove(url, fileManager: fileManager)
            return nil
        }
        return age
    }
}
