import Foundation

/// ONE step of a pairing dial plan: which origin to dial and which phase of the
/// approved network policy it belongs to (spec §3 A1).
///
/// The phase is internal only — it is never rendered in the UI (link type stays
/// silent, spec §0.4). It decides the *execution shape*:
/// - `.lanProbe`: same-network/direct origins, dialed as one **parallel** group
/// with a hard 2.0 s budget before the relay group is tried (user policy:
/// "同一 Wi-Fi 直连优先，2 秒不通自动切中继");
/// - `.relay`: any-network origins, dialed serially with health + redeem.
struct PairingDialAttempt: Equatable {
    enum Phase: String, Equatable {
 /// Reachable only (or fastest) on the Mac's local network: LAN hosts and
 /// loopback origins on the iOS simulator.
        case lanProbe = "lan"
 /// Reachable from any network (M2a relay bridge / control plane origin).
        case relay
    }

    let url: URL
    let phase: Phase
}

/// Why a pairing dial plan has no attempt at all on the current network path.
enum PairingDialRejection: Equatable {
 /// The payload carried no dialable origin at all (only loopback, filtered
 /// out on a physical device).
    case noCandidates
 /// Cellular / expensive non-Wi-Fi path with no any-network origin. The user
 /// policy forbids falling back to the Mac's LAN address here ("不得回退撞
 /// LAN"): it can only burn the whole budget.
    case cellularWithoutRelay
}

/// Result of `PairingDialPolicy.plan` — pure, fully unit-testable.
struct PairingDialPlan: Equatable {
 /// Dial attempts in execution order.
    var attempts: [PairingDialAttempt]
 /// Hard budget for the leading parallel LAN `/health` group. Non-nil only
 /// when a LAN group exists **and** a relay group follows it, so a dead LAN
 /// address can never delay the relay by more than 2 s (user policy).
    var lanProbeBudget: TimeInterval?
 /// Hard budget for the whole pairing dial sequence.
    var totalBudget: TimeInterval
 /// Set when the current path makes dialing impossible under the policy.
    var rejection: PairingDialRejection?

    var isDialable: Bool { rejection == nil && !attempts.isEmpty }
}

/// Pure dialing policy for the pairing screen (spec §3 A1, D3 root cause).
///
/// Before this policy the app walked the QR payload origins serially in payload
/// order with a 15 s `/health` timeout each: on cellular the first (LAN) origin
/// burned 15 s, then the relay was tried; on the same Wi-Fi the relay could be
/// dialed before the LAN address. The policy below encodes the approved
/// rules instead:
///
/// 1. **cellular / expensive non-Wi-Fi**: relay only — LAN candidates are
/// dropped entirely (no fallback);
/// 2. **Wi-Fi / wired**: LAN candidates first (same subnet before other LAN
/// networks), then relay;
/// 3. **unknown / nil path**: a local IPv4 network means "treat as Wi-Fi";
/// otherwise relay first with LAN as fallback;
/// 4. **simulator**: loopback origins are directly reachable and stay in the
/// LAN group (they only exist when `allowLoopback` is on, i.e. simulator);
/// 5. `lanProbeBudget = 2.0 s` only when a LAN group precedes a relay group;
/// `totalBudget = 10 s` in every path.
enum PairingDialPolicy {
 /// Per-origin `/health` timeout inside the parallel LAN group.
    static let lanProbeTimeout: TimeInterval = 1.5
 /// Hard budget for the whole parallel LAN group (user policy: 2 s).
    static let lanProbeBudgetSeconds: TimeInterval = 2.0
 /// Hard budget for the whole pairing dial sequence (user policy: 10 s).
    static let totalBudgetSeconds: TimeInterval = 10.0
 /// `/health` timeout of one serial relay attempt.
    static let relayHealthTimeout: TimeInterval = 3.0
 /// `/pair/redeem` timeout of one pairing attempt (LAN winner or relay).
    static let redeemTimeout: TimeInterval = 5.0

 /// Builds the dial plan for the current network path.
 ///
 /// - Parameters:
 /// - candidates: origins from `PairingOriginSelector.candidates(payload:)`
 /// (already loopback-filtered according to the device).
 /// - path: latest `NetworkPathMonitor` snapshot (nil before the first
 /// callback; treated like "unknown").
 /// - local: the phone's current LAN network
 /// (`NetworkPathMonitor.currentLocalIPv4Network()`), nil on
 /// cellular/unknown paths.
    static func plan(
        candidates: [URL],
        path: NetworkPathSnapshot?,
        local: LocalIPv4Network?
    ) -> PairingDialPlan {
        guard !candidates.isEmpty else {
            return PairingDialPlan(
                attempts: [],
                lanProbeBudget: nil,
                totalBudget: totalBudgetSeconds,
                rejection: .noCandidates
            )
        }
        let loopback = candidates.filter { PairingOriginSelector.isLoopbackHost($0.host) }
        let lan = candidates.filter {
            !PairingOriginSelector.isLoopbackHost($0.host) && PairingOriginSelector.isLANHost($0.host)
        }
        let relay = candidates.filter {
            !PairingOriginSelector.isLoopbackHost($0.host) && !PairingOriginSelector.isLANHost($0.host)
        }
 // LAN group order: same subnet first (fastest), then other LAN addresses,
 // loopback last (it only exists on the simulator, and the payload lists it
 // last as a development fallback).
        let lanGroup = orderLAN(lan, local: local) + loopback
        let relayAttempts = relay.map { PairingDialAttempt(url: $0, phase: .relay) }
        let lanAttempts = lanGroup.map { PairingDialAttempt(url: $0, phase: .lanProbe) }

        if isCellularPath(path) {
 // Rule 1: only any-network origins. The LAN group is NOT a fallback.
            guard !relay.isEmpty || !loopback.isEmpty else {
                return PairingDialPlan(
                    attempts: [],
                    lanProbeBudget: nil,
                    totalBudget: totalBudgetSeconds,
                    rejection: .cellularWithoutRelay
                )
            }
 // Loopback origins (iOS simulator only — a physical device filters
 // them out of the candidate list) are directly reachable and stay in
 // the LAN group even on a cellular path, keeping simulator pairing
 // working. Real LAN hosts are still dropped on this path.
            let loopbackAttempts = loopback.map { PairingDialAttempt(url: $0, phase: .lanProbe) }
            return PairingDialPlan(
                attempts: relayAttempts + loopbackAttempts,
                lanProbeBudget: nil,
                totalBudget: totalBudgetSeconds,
                rejection: nil
            )
        }

        let lanFirst = shouldPreferLAN(path: path, local: local)
        if lanFirst {
 // Rules 2/3a: same-network path (or a local IPv4 network exists).
            return PairingDialPlan(
                attempts: lanAttempts + relayAttempts,
                lanProbeBudget: (!lanAttempts.isEmpty && !relayAttempts.isEmpty) ? lanProbeBudgetSeconds : nil,
                totalBudget: totalBudgetSeconds,
                rejection: nil
            )
        }
 // Rule 3b: unknown path without a local network — relay first, LAN stays
 // as a bounded fallback (relay failure may still be a transient relay
 // problem while the LAN address is reachable after all).
        return PairingDialPlan(
            attempts: relayAttempts + lanAttempts,
            lanProbeBudget: nil,
            totalBudget: totalBudgetSeconds,
            rejection: nil
        )
    }

 /// Cellular / expensive non-Wi-Fi path: dialing a LAN origin is pointless.
 /// An explicit `.cellular` interface counts even when unsatisfied (there is
 /// no Wi-Fi to fall back to); `.other`/unknown follow rules 2–3 unless the
 /// system marks the path expensive/constrained while satisfied.
    static func isCellularPath(_ path: NetworkPathSnapshot?) -> Bool {
        guard let path else { return false }
        switch path.interface {
        case .cellular:
            return true
        case .wifi, .wiredEthernet, .unknown:
            return false
        case .other:
            return path.isSatisfied && (path.isExpensive || path.isConstrained)
        }
    }

 /// Rule 2/3a: LAN candidates are dialed first on Wi-Fi/wired paths and when a
 /// local IPv4 network exists (unknown path that is clearly still on a LAN).
    static func shouldPreferLAN(path: NetworkPathSnapshot?, local: LocalIPv4Network?) -> Bool {
        guard let path else { return local != nil }
        if path.interface == .wifi || path.interface == .wiredEthernet { return true }
        if path.interface == .unknown { return local != nil }
 // .other /.cellular handled by isCellularPath; keep LAN-first on a
 // satisfied non-expensive.other path.
        return !isCellularPath(path) && local != nil
    }

 // MARK: - Execution order (spec P3)

 /// One executable step of a dial plan. `plan.attempts` is declared to be the
 /// execution order; this projection makes that contract explicit for the
 /// executor: consecutive `.lanProbe` attempts form ONE parallel group, and
 /// every `.relay` attempt is a serial step in plan order.
    enum PairingDialStep: Equatable {
 /// Dial these origins in parallel (`/health`), first success wins.
        case lanGroup([PairingDialAttempt])
 /// Dial this one origin serially (health + redeem).
        case relay(PairingDialAttempt)
    }

 /// Projects a plan into executor steps without reordering it: relay-first
 /// plans (cellular / unknown without a local network) start with their relay
 /// steps and finish with a trailing LAN group; LAN-first plans start with the
 /// parallel LAN group.
    static func executionSteps(_ plan: PairingDialPlan) -> [PairingDialStep] {
        var steps: [PairingDialStep] = []
        var pendingLAN: [PairingDialAttempt] = []
        for attempt in plan.attempts {
            switch attempt.phase {
            case .lanProbe:
                pendingLAN.append(attempt)
            case .relay:
                if !pendingLAN.isEmpty {
                    steps.append(.lanGroup(pendingLAN))
                    pendingLAN.removeAll()
                }
                steps.append(.relay(attempt))
            }
        }
        if !pendingLAN.isEmpty {
            steps.append(.lanGroup(pendingLAN))
        }
        return steps
    }

 /// Same-subnet LAN origins first, remaining LAN origins in payload order.
    static func orderLAN(_ lan: [URL], local: LocalIPv4Network?) -> [URL] {
        guard let local, lan.count > 1 else { return lan }
        var same: [URL] = []
        var other: [URL] = []
        for url in lan {
            if local.contains(host: url.host) {
                same.append(url)
            } else {
                other.append(url)
            }
        }
        return same + other
    }

 // MARK: - Budgets

 /// Remaining time until `deadline`, or nil when the budget is exhausted.
    static func remainingBudget(deadline: Date, now: Date = Date()) -> TimeInterval? {
        let remaining = deadline.timeIntervalSince(now)
        return remaining > 0.05 ? remaining : nil
    }

 /// One attempt timeout clamped to the remaining total budget, or nil when the
 /// budget is already exhausted.
    static func attemptTimeout(cap: TimeInterval, deadline: Date, now: Date = Date()) -> TimeInterval? {
        guard let remaining = remainingBudget(deadline: deadline, now: now) else { return nil }
        return min(cap, remaining)
    }
}
