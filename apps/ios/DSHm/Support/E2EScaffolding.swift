#if DEBUG
import Foundation

/// DEBUG-only E2E launch injections. Compiled out of Release builds entirely.
///
/// - `DSHM_E2E=1`: enables E2E scaffolding (already used by the M1 suite).
/// - `DSHM_E2E_RELAY_CONFIG`: `dshm-relay://…` string saved as the remote server
/// config at launch, so UI tests exercise the public pairing path without
/// depending on the pasteboard or the QR scanner.
/// - `DSHM_E2E_PAIR_CODE`: optional pairing-code prefill (the primary E2E case
/// still types the code through the number pad).
/// - `DSHM_E2E_RESET_CACHE=1` + `DSHM_E2E_OPEN_SESSION`: clear that session's
/// cold-start window cache before it is opened (repeatable paging E2E).
enum E2EScaffolding {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["DSHM_E2E"] == "1"
    }

    static func applyLaunchEnvironment(defaults: UserDefaults = .standard) {
        let env = ProcessInfo.processInfo.environment
        if env["DSHM_RESET_RELAY_CONFIG"] == "1" {
            RelayConfigStore.save(nil, defaults: defaults)
        }
        guard isEnabled else { return }
 // task-7 E2E: drop the cold-start window cache for the session we are about
 // to open. A restored cache already holds previously paged-in older events,
 // so `hasMoreOlder` is false on the next launch and the pull-to-load gesture
 // test would silently assert against a no-op. DEBUG + explicit env only;
 // product launch paths never read this key.
        if env["DSHM_E2E_RESET_CACHE"] == "1",
           let openSession = env["DSHM_E2E_OPEN_SESSION"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !openSession.isEmpty {
            SessionWindowCacheStore().clear(sessionId: openSession)
        }
 // full-history autoload failure-mode matrix: craft/poison this
 // session's first-paint cache before it opens (DEBUG + explicit env only).
        if let openSession = env["DSHM_E2E_OPEN_SESSION"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !openSession.isEmpty {
            if env["DSHM_E2E_CORRUPT_CACHE"] == "1" {
                Self.seedCorruptCache(sessionId: openSession)
            }
            if env["DSHM_E2E_LEGACY_CACHE"] == "1" {
                Self.seedLegacyCache(sessionId: openSession)
            }
            if env["DSHM_E2E_STALE_CACHE"] == "1" {
                Self.seedStaleCache(sessionId: openSession)
            }
        }
        guard let relayText = env["DSHM_E2E_RELAY_CONFIG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayText.isEmpty,
              let result = RelayServerConfig.parse(relayText),
              case .success(let config) = result else {
            return
        }
        RelayConfigStore.save(config, defaults: defaults)
    }

 // MARK: - Autoload E2E cache seeds (F4/F5/F6)

    private static func seedCorruptCache(sessionId: String) {
        let store = SessionWindowCacheStore()
        let url = store.fileURL(for: sessionId)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data("{not-a-json-cache".utf8).write(to: url)
    }

 /// Writes the removed v4 envelope (snapshot/olderEvents shape): the loader must
 /// drop it and fall back to the network path (F5).
    private static func seedLegacyCache(sessionId: String) {
        let store = SessionWindowCacheStore()
        let url = store.fileURL(for: sessionId)
        var object: [String: Any] = [
            "schemaVersion": 4,
            "savedAt": Date().timeIntervalSince1970,
            "identity": CacheIdentity.current() ?? "e2e",
            "sessionId": sessionId,
            "snapshot": ["type": "snapshot"],
            "events": [],
        ]
        if let identity = CacheIdentity.current() {
            object["identity"] = identity
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url)
    }

 /// Writes a valid first-paint payload whose savedAt is 25h old: the view may show
 /// it but must flag it stale (F6).
    private static func seedStaleCache(sessionId: String) {
        let store = SessionWindowCacheStore(now: { Date().addingTimeInterval(-25 * 60 * 60) })
        let events = (1...12).map { index in
            SessionEvent(
                type: index == 1 ? "user/message" : "assistant/message",
                seq: index * 10,
                time: 0,
                data: .object(["text": .string("E2E stale cache line " + String(index))]),
                surfaceOp: nil,
                sourceEventSeqs: nil
            )
        }
        let header = SessionHeader(
            version: nil,
            id: sessionId,
            createdAt: nil,
            cwd: nil,
            isSeeded: nil,
            agentPreset: nil
        )
        let projections = ProjectionValues(
            asOfSeq: 120,
            values: ["title": .string("E2E stale cache")]
        )
        _ = store.save(
            sessionId: sessionId,
            cursor: 120,
            hasMore: true,
            header: header,
            projections: projections,
            events: events,
            windowMessages: SessionWindowPolicy.maxFirstWindowMessages
        )
    }

    static var pairCode: String? {
        guard isEnabled else { return nil }
        let value = ProcessInfo.processInfo.environment["DSHM_E2E_PAIR_CODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

 /// When an E2E relay config was injected, the pairing-code flow must take the
 /// public relay path even if a LAN Mac happens to be discoverable (otherwise
 /// the E2E would consume the code against a different Mac link-server).
    static var forcesRelayPairing: Bool {
        guard isEnabled else { return false }
        let value = ProcessInfo.processInfo.environment["DSHM_E2E_RELAY_CONFIG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !value.isEmpty
    }
}
#endif
