import Foundation
import Network

/// P0 (remote connection performance): network-path awareness for origin selection.
///
/// Historically the reconnect loop walked every stored origin in order on every
/// network, LAN origins first. A phone on cellular cannot reach the Mac's LAN
/// origin at all, so each probe burned its full timeout (15s) before the relay was
/// dialed — measured cold bring-up was 31s in 3/5 live bench rounds.
///
/// This monitor exposes the current path so `LinkService` can prefer the relay
/// origin (and skip the LAN probes) on cellular/expensive paths, while keeping the
/// legacy LAN-first order on Wi-Fi.
@MainActor
final class NetworkPathMonitor {
    static let shared = NetworkPathMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.dshm.app.network-path")
    private(set) var currentPath: NWPath?

 /// True when dialing the Mac's LAN origin is pointless and the relay origin
 /// should be preferred: a satisfied cellular/expensive/constrained path that is
 /// neither Wi-Fi nor wired Ethernet. An unknown/unsatisfied path keeps the
 /// legacy candidate order so offline retries still work.
    var prefersRelay: Bool {
 // Unknown (monitor still warming up) or unsatisfied path: prefer the relay.
 // The relay works on every network while a LAN origin only exists on the
 // Mac's local network — guessing "LAN" here is exactly what cost a 15s auth
 // timeout on cold start (P0 bench round 1: 16.1s bring-up, first dial = LAN).
        guard let path = currentPath else { return true }
        guard path.status == .satisfied else { return true }
        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
            return false
        }
        return path.usesInterfaceType(.cellular) || path.isExpensive || path.isConstrained
    }

    var isSatisfied: Bool { currentPath?.status == .satisfied }
    var usesWiFi: Bool { currentPath?.usesInterfaceType(.wifi) ?? false }

    private init() {
        start()
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.currentPath = path
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
