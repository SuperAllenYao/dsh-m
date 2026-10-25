// DraftStore.swift — per-session composer draft persistence (design §2.4).
//
// Why: drafts used to live only in `SessionViewModel.draft` (memory), so a
// back-navigation or app backgrounding silently lost what the user had typed.
// This store keeps every session's draft under
// `CacheIO.defaultDirectory/Drafts/<sessionId>.json` (`{"text","updatedAt"}`,
// atomic tmp+rename, same directory family as the other caches) with an
// in-memory cache in front so reads/`hasDraft` are immediate and never touch
// the disk on the UI path.
//
// Lifecycle (design §2.4): written on a 500 ms debounce while typing, on
// session-view disappear and on scene backgrounding; read at
// `SessionViewModel` init; deleted as soon as the message is sent (an empty
// draft removes the file too). A failed write keeps the in-memory state and is
// retried by the next save — it never blocks typing (failure mode matrix).
//
// Thread model: any thread; a lock guards the cache and the disk state.

import Foundation

/// Wire/ondisk shape of one draft file.
struct DraftPayload: Codable, Equatable {
    var text: String
    var updatedAt: Int64
}

final class DraftStore {
 /// Process-wide store (App + previews + tests may also construct private ones).
    static let shared: DraftStore = DraftStore()

    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
 /// sessionId -> known draft text. `nil` = not loaded yet (next read loads it),
 /// non-nil (possibly empty) = the authoritative in-memory state.
    private var cache: [String: String?] = [:]

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = directory ?? CacheIO.defaultDirectory(fileManager: fileManager)
            .appendingPathComponent("Drafts", isDirectory: true)
        self.directory = base
    }

    private func fileURL(for sessionId: String) -> URL {
        directory.appendingPathComponent(sessionId + ".json", isDirectory: false)
    }

 /// Load one session's draft from disk (once); afterwards the cache answers.
    private func loadLocked(_ sessionId: String) -> String? {
        if let cached = cache[sessionId] { return (cached ?? "").isEmpty ? nil : cached }
        let url = fileURL(for: sessionId)
        let payload: DraftPayload? = CacheIO.read(DraftPayload.self, from: url)
        let text = payload?.text ?? ""
        cache[sessionId] = text
        return text.isEmpty ? nil : text
    }

 /// The stored draft text, or nil when there is none (unknown session,
 /// empty draft, or an unreadable/corrupt file — all read as "no draft").
    func text(for sessionId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loadLocked(sessionId)
    }

 /// Immediate visibility signal for the phone-created blank card (§2.3).
    func hasDraft(_ sessionId: String) -> Bool {
        text(for: sessionId)?.isEmpty == false
    }

 /// Store one draft. An empty text removes the draft entirely (§2.4: an
 /// empty draft file is deleted, not kept). The in-memory state updates even
 /// when the disk write fails, so the next save retries silently.
    @discardableResult
    func save(_ text: String, for sessionId: String) -> Bool {
        lock.lock()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            cache[sessionId] = ""
            let url = fileURL(for: sessionId)
            lock.unlock()
            try? fileManager.removeItem(at: url)
            return true
        }
        cache[sessionId] = trimmed
        let payload = DraftPayload(text: trimmed, updatedAt: Int64(Date().timeIntervalSince1970 * 1000))
        let url = fileURL(for: sessionId)
        lock.unlock()
        return CacheIO.writeAtomically(payload, to: url, fileManager: fileManager)
    }

 /// Remove one draft (send path + blank-card close-out).
    func remove(for sessionId: String) {
        _ = save("", for: sessionId)
    }

 /// Forget the cached state of one session (tests + future account switches).
    func resetCache() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
    }
}
