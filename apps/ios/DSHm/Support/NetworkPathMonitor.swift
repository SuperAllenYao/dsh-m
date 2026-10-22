import Darwin
import Foundation
import Network

/// Pure, testable projection of the parts of `NWPath` that decide the fate of a
/// live connection. Keeping this free of `NWPath`/`NWPathMonitor` means the
/// "did the network really change?" rule is unit-tested instead of only observed
/// on a device (a wrong rule either reconnects too often or never notices the
/// Wi-Fi -> cellular switch).
struct NetworkPathSnapshot: Equatable {
    enum InterfaceKind: String {
        case unknown
        case wifi
        case wiredEthernet
        case cellular
        case other
    }

    var interface: InterfaceKind
    var isSatisfied: Bool
    var isExpensive: Bool
    var isConstrained: Bool

    /// Baseline before the monitor's first callback: unknown + unsatisfied, which
    /// keeps the legacy candidate order (see `prefersRelay`).
    static let unknown = NetworkPathSnapshot(
        interface: .unknown,
        isSatisfied: false,
        isExpensive: false,
        isConstrained: false
    )

    static func from(_ path: NWPath) -> NetworkPathSnapshot {
        let kind: InterfaceKind
        if path.usesInterfaceType(.wifi) {
            kind = .wifi
        } else if path.usesInterfaceType(.wiredEthernet) {
            kind = .wiredEthernet
        } else if path.usesInterfaceType(.cellular) {
            kind = .cellular
        } else if path.usesInterfaceType(.other) {
            kind = .other
        } else {
            kind = .unknown
        }
        return NetworkPathSnapshot(
            interface: kind,
            isSatisfied: path.status == .satisfied,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    /// True when dialing the Mac's LAN origin is pointless and the relay origin
    /// should be preferred: a satisfied cellular/expensive/constrained path that is
    /// neither Wi-Fi nor wired Ethernet. An unknown/unsatisfied path keeps the
    /// legacy candidate order so offline retries still work.
    var prefersRelay: Bool {
        // Unknown (monitor still warming up) or unsatisfied path: prefer the relay.
        // The relay works on every network while a LAN origin only exists on the
        // Mac's local network — guessing "LAN" here is exactly what cost a 15s auth
        // timeout on cold start (P0 bench round 1: 16.1s bring-up, first dial = LAN).
        guard isSatisfied else { return true }
        if interface == .wifi || interface == .wiredEthernet { return false }
        return interface == .cellular || isExpensive || isConstrained
    }
}

/// Phone's IPv4 address + prefix on the current primary LAN interface.
///
/// task-2 (cross-network): a stored LAN origin (e.g. the Mac's 172.20.10.2 hotspot
/// address) is only worth dialing first when the phone is still **on that subnet**.
/// On a different network the LAN probe can only burn the round budget, so the
/// relay must go first. `NWPath` does not expose the address, hence getifaddrs
/// (below) plus this pure, unit-tested comparison.
struct LocalIPv4Network: Equatable {
    /// Host-order IPv4 address of the phone on its current LAN interface.
    let address: UInt32
    /// Prefix length derived from the interface netmask (e.g. /24 -> 24).
    let prefixLength: UInt8

    nonisolated static func parseIPv4(_ text: String?) -> UInt32? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt32(part), octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    nonisolated static func prefixLength(mask: UInt32) -> UInt8 {
        var count: UInt8 = 0
        var bit: UInt32 = 0x8000_0000
        while bit != 0, mask & bit != 0 {
            count += 1
            bit >>= 1
        }
        return count
    }

    nonisolated static func fromInterface(address: String, netmask: String) -> LocalIPv4Network? {
        guard let addressValue = parseIPv4(address),
              let maskValue = parseIPv4(netmask),
              maskValue != 0 else { return nil }
        return LocalIPv4Network(address: addressValue, prefixLength: prefixLength(mask: maskValue))
    }

    /// True when `host` is an IPv4 address inside this network prefix.
    nonisolated func contains(host: String?) -> Bool {
        guard let candidate = LocalIPv4Network.parseIPv4(host) else { return false }
        let bits = min(32, Int(prefixLength))
        guard bits > 0 else { return false }
        let mask: UInt32 = bits == 32 ? UInt32.max : (UInt32.max << UInt32(32 - bits))
        return (address & mask) == (candidate & mask)
    }
}

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
///
/// task-2 (reconnect < 1s): the monitor additionally reports **meaningful** path
/// changes (interface type change / satisfied flip) so `LinkService` can invalidate
/// a socket that the system has not reported dead yet: after a Wi-Fi -> cellular
/// switch the old mux can sit in `.connected` until the TCP timeout, which used to
/// make every request hang for 10s+ before the reconnect even started.
@MainActor
final class NetworkPathMonitor {
    static let shared = NetworkPathMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.dshm.app.network-path")
    private(set) var currentPath: NWPath?
    /// Latest pure projection of `currentPath` (nil until the first callback).
    private(set) var snapshot: NetworkPathSnapshot?
    /// Increments once per meaningful change; `LinkService` stamps it on every
    /// successful connect and compares on page enter / foreground resume.
    private(set) var changeGeneration = 0
    /// Called on the main actor right after `changeGeneration` increments.
    var onMeaningfulChange: (() -> Void)?

    /// True when dialing the Mac's LAN origin is pointless and the relay origin
    /// should be preferred: a satisfied cellular/expensive/constrained path that is
    /// neither Wi-Fi nor wired Ethernet. An unknown/unsatisfied path keeps the
    /// legacy candidate order so offline retries still work.
    var prefersRelay: Bool { snapshot?.prefersRelay ?? true }

    var isSatisfied: Bool { snapshot?.isSatisfied ?? false }
    var usesWiFi: Bool { snapshot?.interface == .wifi }

    /// `startImmediately: false` is the unit-test seam: no `NWPathMonitor` starts,
    /// `applyForTesting` feeds snapshots directly.
    init(startImmediately: Bool = true) {
        if startImmediately { start() }
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentPath = path
                self.apply(NetworkPathSnapshot.from(path))
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    /// Applies one path snapshot and fires `onMeaningfulChange` when the change can
    /// invalidate a live socket. The first sample only establishes the baseline:
    /// launch starts on whatever network exists and there is nothing to invalidate.
    func apply(_ snapshot: NetworkPathSnapshot) {
        let previous = self.snapshot
        self.snapshot = snapshot
        guard Self.isMeaningfulChange(from: previous, to: snapshot) else { return }
        changeGeneration += 1
        onMeaningfulChange?()
    }

    /// Test seam mirroring the callback path without `NWPath`.
    func applyForTesting(_ snapshot: NetworkPathSnapshot) {
        apply(snapshot)
    }

    /// The rule that decides whether a path update invalidates a live connection.
    ///
    /// - interface type change (Wi-Fi <-> cellular <-> wired, or lost/regained);
    /// - satisfaction flip (offline <-> online);
    /// - expense/constraint change on the same satisfied interface (personal
    ///   hotspot / Low Data Mode) — but only while satisfied, so a flapping
    ///   unsatisfied path does not produce duplicates.
    ///
    /// The very first sample is never a change: there was no connection to
    /// invalidate yet, and treating it as one would make every launch look like a
    /// network switch.
    nonisolated static func isMeaningfulChange(
        from previous: NetworkPathSnapshot?,
        to current: NetworkPathSnapshot
    ) -> Bool {
        guard let previous else { return false }
        if previous.isSatisfied != current.isSatisfied { return true }
        if previous.interface != current.interface { return true }
        if current.isSatisfied,
           previous.isExpensive != current.isExpensive || previous.isConstrained != current.isConstrained {
            return true
        }
        return false
    }

    /// task-2 (cross-network): the phone's IPv4 network on its current Wi-Fi/wired
    /// path, or nil on cellular/unknown paths (no LAN candidate can be reachable
    /// there anyway, so the caller keeps the relay-first order).
    func currentLocalIPv4Network() -> LocalIPv4Network? {
        guard let interface = snapshot?.interface,
              interface == .wifi || interface == .wiredEthernet else {
            return nil
        }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let rawName = entry.pointee.ifa_name else { continue }
            let name = String(cString: rawName)
            guard name.hasPrefix("en") else { continue } // Wi-Fi / wired on iOS
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard let netmask = entry.pointee.ifa_netmask else { continue }
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var maskBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &hostBuffer, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            guard getnameinfo(
                netmask, socklen_t(netmask.pointee.sa_len),
                &maskBuffer, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let text = String(cString: hostBuffer)
            let mask = String(cString: maskBuffer)
            if let network = LocalIPv4Network.fromInterface(address: text, netmask: mask) {
                return network
            }
        }
        return nil
    }
}
