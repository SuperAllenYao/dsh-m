import Foundation

/// Shared on-disk cache plumbing for the M2b-2 cold-start fast path.
///
/// Files live under `Caches/DSHmCache`, so the OS may purge them at will — they are
/// only a display accelerator, never the source of truth. Every payload carries a
/// schema version and a save timestamp:
///   - version mismatch / corrupt JSON / unreadable file  -> safe `nil` (network path)
///   - older than `CacheSchema.ttl` (~24h)               -> still rendered, flagged stale
///   - older than `CacheSchema.retention` (~7d)          -> dropped (hygiene)
///
/// Writes are atomic (temp file in the destination directory + rename) so a crash
/// mid-write can never leave a half-written payload behind.
///
/// v2 (M2b-2): every payload also carries the pairing-identity fingerprint of the
/// Mac that produced it (`CacheIdentity`); a cache from another pairing is deleted
/// on read instead of being rendered.
enum CacheSchema {
    static let version = 2
    /// Display TTL: a snapshot older than this is still shown but marked stale.
    static let ttl: TimeInterval = 24 * 60 * 60
    /// Hard retention: older files are deleted instead of shown.
    static let retention: TimeInterval = 7 * 24 * 60 * 60
}

/// Stable "pairing identity" that scopes every cache file to one paired Mac.
///
/// Derived from the persisted pairing credentials only — no protocol change and no
/// new dependency. The TLS leaf pin is host-scoped (each plugin instance has its own
/// pin), so switching Macs (or clearing/re-pairing to another host) changes the
/// fingerprint and the old cache is discarded on the next read.
///
/// `origin` is deliberately **not** part of the fingerprint: the app rotates between
/// LAN/relay origins of the *same* pairing, and invalidating the cache on every
/// network switch would defeat the cold-start fast path. `deviceId` is omitted for
/// the same reason — re-pairing the same Mac may issue a new one.
enum CacheIdentity {
    /// Fingerprint for one credentials record. `keyId` (the Host's pairing key id)
    /// guards the unlikely case of pin reuse; absent on older payloads.
    static func make(leafPin: String, keyId: String?) -> String {
        let raw = "\(leafPin)|\(keyId ?? "")"
        return String(CacheIO.stableHash(raw).prefix(16))
    }

    /// Fingerprint of the currently persisted pairing, or nil when unpaired.
    /// Production reads the existing `CredentialStore` (Keychain / simulator
    /// fallback file) directly, so the cache layer needs no `LinkService` reference
    /// during view-model `init`; tests inject their own provider.
    static func current(loadCredentials: () -> PairingCredentials? = { CredentialStore().load() }) -> String? {
        guard let credentials = loadCredentials() else { return nil }
        return make(leafPin: credentials.leafPin, keyId: credentials.keyId)
    }
}

enum CacheIO {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("DSHmCache", isDirectory: true)
    }

    @discardableResult
    static func ensureDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        if fileManager.fileExists(atPath: url.path) { return true }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// Decodes one cache file; any failure (missing/corrupt/typed mismatch) is `nil`.
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? encoder.encode(value)
    }

    /// Atomic write: encode into `<name>.tmp-<uuid>` in the same directory, then
    /// rename over the destination. Returns false on any I/O failure (never throws).
    @discardableResult
    static func writeAtomically<T: Encodable>(
        _ value: T,
        to url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let data = encode(value) else { return false }
        return writeDataAtomically(data, to: url, fileManager: fileManager)
    }

    @discardableResult
    static func writeDataAtomically(
        _ data: Data,
        to url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let directory = url.deletingLastPathComponent()
        guard ensureDirectory(directory, fileManager: fileManager) else { return false }
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try data.write(to: temporary, options: .atomic)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
            return true
        } catch {
            try? fileManager.removeItem(at: temporary)
            return false
        }
    }

    static func remove(_ url: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: url)
    }

    /// Stable FNV-1a 64-bit hash for file names (Swift's `hashValue` is per-process
    /// randomized, so it must never be used for on-disk identity).
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
