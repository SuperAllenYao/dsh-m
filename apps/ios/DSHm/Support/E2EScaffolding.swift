#if DEBUG
import Foundation

/// DEBUG-only E2E launch injections. Compiled out of Release builds entirely.
///
/// - `DSHM_E2E=1`: enables E2E scaffolding (already used by the M1 suite).
/// - `DSHM_E2E_RELAY_CONFIG`: `dshm-relay://…` string saved as the remote server
///   config at launch, so UI tests exercise the public pairing path without
///   depending on the pasteboard or the QR scanner.
/// - `DSHM_E2E_PAIR_CODE`: optional pairing-code prefill (the primary E2E case
///   still types the code through the number pad).
/// - `DSHM_E2E_RESET_CACHE=1` + `DSHM_E2E_OPEN_SESSION`: clear that session's
///   cold-start window cache before it is opened (repeatable paging E2E).
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
        guard let relayText = env["DSHM_E2E_RELAY_CONFIG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayText.isEmpty,
              let result = RelayServerConfig.parse(relayText),
              case .success(let config) = result else {
            return
        }
        RelayConfigStore.save(config, defaults: defaults)
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
