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
