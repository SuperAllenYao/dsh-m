import Combine
import Foundation

/// Drives the pairing-code sheet (design §5.3/§5.4/§5.6): Bonjour discovery,
/// Mac selection, 8-digit auto-submit, LAN-vs-relay routing and retry handling.
///
/// The model owns no transport of its own: `PairingCodeRedeeming` performs the
/// HTTPS redeem/lookup and `PairingDiscovering` the `_dshm._tcp` browse, so the
/// whole state machine is unit-testable without a live Mac.
@MainActor
final class PairingCodeFlowModel: ObservableObject {
    enum DiscoveryState: Equatable {
        case idle
        case searching
        case empty
        case found(Int)
    }

    enum Route: Equatable {
        case none
        case lan(DiscoveredMac)
        case relay(RelayServerConfig)
    }

    @Published private(set) var code = PairingCodeInput()
    @Published private(set) var phase: PairingCodeSubmissionPhase = .idle
    @Published private(set) var macs: [DiscoveredMac] = []
    @Published private(set) var discoveryState: DiscoveryState = .idle
    @Published private(set) var selectedMacId: String?
    @Published private(set) var relayConfig: RelayServerConfig?
    /// User explicitly asked to pair through the relay even when a LAN Mac is
    /// visible (offered once a relay config exists).
    @Published private(set) var prefersRelay = false
    @Published private(set) var attemptsLeft: Int?

    /// Called on the main actor with the redeemed credentials; the sheet wires
    /// this to `LinkService.adopt(credentials:)` + `AppModel.didPair()`.
    var onRedemption: ((PairingCodeRedemption) -> Void)?

    private let redeemer: PairingCodeRedeeming
    private let discovery: PairingDiscovering
    private let defaults: UserDefaults
    private var started = false
    private var submitTask: Task<Void, Never>?

    init(
        redeemer: PairingCodeRedeeming = PairingCodeRedeemer(),
        discovery: PairingDiscovering? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.redeemer = redeemer
        self.discovery = discovery ?? BonjourDiscovery()
        self.defaults = defaults
        self.relayConfig = RelayConfigStore.load(defaults: defaults)
        self.discovery.onChange = { [weak self] macs in
            self?.updateMacs(macs)
        }
    }

    // MARK: - Derived state

    var selectedMac: DiscoveredMac? {
        guard let selectedMacId else { return nil }
        return macs.first { $0.id == selectedMacId }
    }

    var hasRelayConfig: Bool { relayConfig != nil }

    var failure: PairingCodeFailure? { phase.failure }

    /// Whether the code field's contents can be submitted right now.
    var canSubmit: Bool {
        code.isComplete && !phase.isSubmitting && resolveRoute() != Route.none
    }

    /// The transport the next submit will use.
    var route: Route { resolveRoute() }

    var discoveryHint: String? {
        switch discoveryState {
        case .idle, .searching:
            return L10n.t("正在发现局域网内的 Mac…")
        case .empty:
            if relayConfig != nil {
                return L10n.t("未发现 Mac，将尝试通过远程服务器配对")
            }
            return L10n.t("未发现 Mac：请确认 iPhone 与 Mac 在同一 Wi-Fi，或在 Mac 上刷新配对码；也可以先配置远程服务器")
        case .found(let count):
            if count > 1, selectedMacId == nil {
                return L10n.t("发现多台 Mac，请选择要配对的一台")
            }
            return nil
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        relayConfig = RelayConfigStore.load(defaults: defaults)
        discoveryState = .searching
        discovery.start()
    }

    func stop() {
        submitTask?.cancel()
        submitTask = nil
        discovery.stop()
    }

    // MARK: - Discovery / selection

    func updateMacs(_ newMacs: [DiscoveredMac]) {
        macs = newMacs
        if let selectedMacId, !newMacs.contains(where: { $0.id == selectedMacId }) {
            self.selectedMacId = nil
        }
        if selectedMacId == nil, newMacs.count == 1, let only = newMacs.first {
            // Exactly one Mac on the LAN: select it, but never auto-try codes
            // against several Macs (each wrong code burns an attempt).
            selectedMacId = only.id
        }
        discoveryState = newMacs.isEmpty ? .empty : .found(newMacs.count)
        resolveRoute()
    }

    func selectMac(_ id: String) {
        guard macs.contains(where: { $0.id == id }) else { return }
        selectedMacId = id
        prefersRelay = false
        resolveRoute()
        if code.isComplete, phase.failure != nil {
            submit()
        }
    }

    func useRelay() {
        guard relayConfig != nil else { return }
        prefersRelay = true
        resolveRoute()
        if code.isComplete, phase.failure != nil {
            submit()
        }
    }

    func useLAN() {
        prefersRelay = false
        resolveRoute()
    }

    func rediscover() {
        selectedMacId = nil
        macs = []
        discoveryState = .searching
        if let bonjour = discovery as? BonjourDiscovery {
            bonjour.restart()
        } else {
            discovery.start()
        }
    }

    // MARK: - Relay config

    func applyRelayConfig(_ config: RelayServerConfig?) {
        relayConfig = config
        RelayConfigStore.save(config, defaults: defaults)
        if config == nil {
            prefersRelay = false
        }
        resolveRoute()
    }

    func reloadRelayConfig() {
        relayConfig = RelayConfigStore.load(defaults: defaults)
        resolveRoute()
    }

    // MARK: - Code input / submission

    func updateCode(_ text: String) {
        let previous = code.digits
        let completed = code.update(text)
        // Clear a previous failure only on a real user edit. Programmatic resets
        // (e.g. the field being re-rendered with the sanitized value) must not
        // wipe an error message the user needs to read.
        if phase.failure != nil, code.digits != previous, !code.digits.isEmpty {
            phase = .idle
            attemptsLeft = nil
        }
        if completed {
            submit()
        }
    }

    func submit() {
        guard !phase.isSubmitting else { return }
        guard code.isComplete else { return }
        let route = resolveRoute()
        guard route != Route.none else {
            if relayConfig == nil, macs.isEmpty {
                phase = .failed(.noTarget)
            } else if macs.count > 1, selectedMacId == nil, !prefersRelay {
                phase = .failed(.selectionRequired)
            } else {
                phase = .failed(.noTarget)
            }
            return
        }
        let submittedCode = code.digits
        let deviceName = AppSettings.deviceName
        phase = .submitting
        submitTask?.cancel()
        submitTask = Task { [weak self] in
            guard let self else { return }
            do {
                let redemption: PairingCodeRedemption
                switch route {
                case .lan(let mac):
                    redemption = try await self.redeemer.redeemOnLAN(mac: mac, code: submittedCode, deviceName: deviceName)
                case .relay(let config):
                    redemption = try await self.redeemer.redeemViaRelay(config: config, code: submittedCode, deviceName: deviceName)
                case .none:
                    self.phase = .failed(.noTarget)
                    return
                }
                guard !Task.isCancelled else { return }
                self.applyRedemption(redemption)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let failure = Self.failure(from: error)
                self.phase = .failed(failure)
                if case .invalid(let remaining) = failure {
                    self.attemptsLeft = remaining
                }
                if !failure.keepsCode {
                    self.code.clear()
                }
            }
        }
    }

    func retry() {
        submit()
    }

    func clearCode() {
        code.clear()
        if phase.failure != nil { phase = .idle }
    }

    /// Fills the eight digits without auto-submitting (E2E prefill/debug aid).
    func prefillCode(_ text: String) {
        _ = code.update(text)
    }

    func applyRedemption(_ redemption: PairingCodeRedemption) {
        // Design §5.4: a LAN pairing may teach the app the relay config (its pin
        // is only available from the payload's `relay` object).
        if let relay = redemption.relay {
            relayConfig = relay
            RelayConfigStore.save(relay, defaults: defaults)
        }
        attemptsLeft = nil
        phase = .idle
        onRedemption?(redemption)
    }

    static func failure(from error: Error) -> PairingCodeFailure {
        if let pairingError = error as? PairingCodeError {
            return pairingError.failure
        }
        return .network(NetworkErrorInterpreter.message(for: error))
    }

    // MARK: - Routing

    @discardableResult
    private func resolveRoute() -> Route {
        if prefersRelay, let relayConfig {
            return .relay(relayConfig)
        }
        if let selectedMac {
            return .lan(selectedMac)
        }
        // No usable LAN selection: an empty discovery falls back to the relay.
        if macs.isEmpty, let relayConfig {
            return .relay(relayConfig)
        }
        return .none
    }
}
