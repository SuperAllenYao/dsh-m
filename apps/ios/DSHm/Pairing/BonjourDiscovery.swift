import Foundation
import Network

/// A Mac advertising `_dshm._tcp` through the dsh-m-link plugin's Bonjour
/// responder (design §5.3). TXT contract:
/// `v=1 hostId=<..> hostName=<..> proto=dsh-m/1 ver=<..> pair=code [relay=<..>]`
struct DiscoveredMac: Identifiable, Equatable {
    /// Stable identity (`hostId` TXT value) used for list selection.
    var hostId: String
    var hostName: String
    var serviceName: String
    var txt: [String: String]
    /// Bonjour service endpoint; `NWConnection` resolves SRV/A at connect time.
    var endpoint: NWEndpoint
    /// Optional relay origin the Mac advertised (informational only: the relay
    /// TLS pin is not in TXT, see design §5.4).
    var relayOrigin: String?

    var id: String { hostId }
    var displayName: String { hostName.isEmpty ? serviceName : hostName }
    var protocolVersion: String? { txt["proto"] }
    var pluginVersion: String? { txt["ver"] }
    /// `pair=code` advertises that the Mac accepts 8-digit pairing codes.
    var supportsPairingCode: Bool { (txt["pair"] ?? "").lowercased() == "code" }

    /// Parses one browse result. Entries without `hostId` are ignored: they cannot
    /// be de-duplicated across interfaces and are not the M2a plugin contract.
    static func parse(serviceName: String, txt: [String: String], endpoint: NWEndpoint) -> DiscoveredMac? {
        guard let hostId = txt["hostId"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostId.isEmpty else {
            return nil
        }
        let trimmedHostName = txt["hostName"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let relay = txt["relay"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DiscoveredMac(
            hostId: hostId,
            hostName: trimmedHostName.isEmpty ? serviceName : trimmedHostName,
            serviceName: serviceName,
            txt: txt,
            endpoint: endpoint,
            relayOrigin: relay.isEmpty ? nil : relay
        )
    }
}

/// Test seam so the pairing-code flow model can run without a live browser.
@MainActor
protocol PairingDiscovering: AnyObject {
    var macs: [DiscoveredMac] { get }
    var onChange: (([DiscoveredMac]) -> Void)? { get set }
    func start()
    func stop()
}

/// `NWBrowser` wrapper for `_dshm._tcp` (deployment target 17, so the
/// `bonjourWithTXTRecord` descriptor is available; TXT values ride on each
/// browse result's metadata).
@MainActor
final class BonjourDiscovery: ObservableObject, PairingDiscovering {
    enum State: Equatable {
        case idle
        case searching
        case ready
        case unavailable(String)
    }

    static let serviceType = "_dshm._tcp"

    @Published private(set) var macs: [DiscoveredMac] = []
    @Published private(set) var state: State = .idle
    /// Called on the main actor whenever the deduplicated Mac list changes.
    var onChange: (([DiscoveredMac]) -> Void)?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.dshm.bonjour-browser")

    /// E2E scaffolding (no product behavior): simulator UI tests need a
    /// deterministic "no Mac discovered" state.
    static var isDisabledByEnvironment: Bool {
        ProcessInfo.processInfo.environment["DSHM_DISABLE_BONJOUR"] == "1"
    }

    func start() {
        guard browser == nil else { return }
        if Self.isDisabledByEnvironment {
            state = .unavailable(L10n.t("已禁用局域网发现"))
            return
        }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
        self.browser = browser
        state = .searching
        browser.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor [weak self] in
                self?.handleBrowserState(newState)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let parsed = Self.parse(results)
            Task { @MainActor [weak self] in
                self?.apply(parsed)
            }
        }
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Restart the browse session (pairing page refresh button).
    func restart() {
        stop()
        macs = []
        onChange?([])
        start()
    }

    func handleBrowserState(_ newState: NWBrowser.State) {
        switch newState {
        case .ready:
            if browser != nil {
                state = .ready
                // A browse session may settle with zero results; tell the model so
                // it can show the "no Mac found" fallback instead of "searching".
                onChange?(macs)
            }
        case .failed(let error):
            state = .unavailable(NetworkErrorInterpreter.message(for: error))
        case .waiting(let error):
            state = .unavailable(NetworkErrorInterpreter.message(for: error))
        case .cancelled:
            if browser == nil { state = .idle }
        case .setup:
            state = .searching
        @unknown default:
            break
        }
    }

    func apply(_ discovered: [DiscoveredMac]) {
        let deduplicated = Self.deduplicate(discovered)
        guard deduplicated != macs else { return }
        macs = deduplicated
        if state == .searching, !deduplicated.isEmpty { state = .ready }
        onChange?(deduplicated)
    }

    /// Pure parser for `NWBrowser.Result` sets (unit-testable via `parseTXT`).
    nonisolated static func parse(_ results: Set<NWBrowser.Result>) -> [DiscoveredMac] {
        let parsed: [DiscoveredMac] = results.compactMap { result in
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                txt = record.dictionary
            }
            let serviceName: String
            if case .service(let name, _, _, _) = result.endpoint {
                serviceName = name
            } else {
                return nil
            }
            return DiscoveredMac.parse(serviceName: serviceName, txt: txt, endpoint: result.endpoint)
        }
        return deduplicate(parsed)
    }

    nonisolated static func deduplicate(_ macs: [DiscoveredMac]) -> [DiscoveredMac] {
        var seen = Set<String>()
        var unique: [DiscoveredMac] = []
        for mac in macs where seen.insert(mac.hostId).inserted {
            unique.append(mac)
        }
        return unique.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}
