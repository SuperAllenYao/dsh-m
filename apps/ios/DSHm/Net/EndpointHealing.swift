import Foundation

/// 跨网络连接自愈的**纯逻辑**（可直接单测）：端点合并、刷新节流、探测排序。
///
/// 背景（用户 2026-10-23 明确要求：网络环境随时变化，App 必须在任何网络下都能
/// 连上 Mac，并且极致快）：旧实现只在配对时学一次地址（`originCandidates`），之后
/// 永不更新；网络一变就只剩陈旧候选，再按 2s/个串行探测 → 连不上或极慢。
///
/// 这里提供三块可测策略，网络 IO 在 `LinkService` / `LANEndpointDiscovery` 中：
/// 1. `mergeAdvertised`：把 Mac 刚广播的 `/health.deviceEndpoints` 合并回候选（新鲜
///    地址在前，陈旧地址截断保底），供持久化；
/// 2. `rankProbes` + `shouldProbe`/`probeTimeout`：并行探测的结果排序与预算，让
///    第一拨连接直接落在可达地址上，而不是按存储顺序盲试；
/// 3. `shouldRefreshEndpoints`：成功连接后的端点刷新节流（网络路径变化时强制刷新）。
enum EndpointHealing {

    /// 持久化候选上限：新鲜地址 + 陈旧地址一共最多 8 个，避免无限增长。
    static let maxCandidates = 8

    /// 一次并行健康探测的结论。
    enum ProbeResult: Equatable {
        /// `/health` 200 且 `ok:true`：现在就能连。
        case healthy
        /// 服务器应答但不可用（5xx / host-inactive / 认证类拒绝）：可达但不是当前可用路径。
        case rejected
        /// 网络层失败（超时 / 不可达 / TLS 失败）：这条地址现在别拨。
        case unreachable

        /// 排序权重：healthy 最先，rejected 次之，unreachable 最后。
        var rank: Int {
            switch self {
            case .healthy: return 0
            case .rejected: return 1
            case .unreachable: return 2
            }
        }
    }

    struct ProbeObservation: Equatable {
        /// 归一化后的 origin（无尾斜杠）。
        var origin: String
        var result: ProbeResult
        var latencyMs: Int
    }

    // MARK: - 端点合并

    /// 合并 Mac 最新广播的端点。
    ///
    /// 顺序：**当前 origin** → **按 Mac 广播顺序的新端点** → 仍不在广播里的旧候选
    /// （保底，让"Mac 暂时没广播 relay"之类的情况仍可回退），整体截断到
    /// `maxCandidates`。只接受 https origin；重复项按小写去重。
    static func mergeAdvertised(
        current: String?,
        stored: [String]?,
        advertised: [String]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        func append(_ text: String?) {
            guard let normalized = normalizedHTTPSOrigin(text) else { return }
            guard seen.insert(normalized.lowercased()).inserted else { return }
            result.append(normalized)
        }

        append(current)
        for origin in advertised { append(origin) }
        for origin in stored ?? [] { append(origin) }
        return Array(result.prefix(maxCandidates))
    }

    /// 归一化成 https origin 文本（无尾斜杠）；非 https / 缺 host 返回 nil。
    static func normalizedHTTPSOrigin(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        var value = url.absoluteString
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    // MARK: - 刷新节流

    /// 成功连接后是否应刷新端点：网络路径变化时必须刷新（这正是地址可能变了的时候），
    /// 否则按 `minInterval` 节流，避免每轮重连都多打一次 `/health`。
    static func shouldRefreshEndpoints(
        lastRefreshAt: Date?,
        now: Date,
        networkPathChanged: Bool,
        minInterval: TimeInterval = 60
    ) -> Bool {
        if networkPathChanged { return true }
        guard let lastRefreshAt else { return true }
        return now.timeIntervalSince(lastRefreshAt) >= minInterval
    }

    // MARK: - 探测预算

    /// 只有一个候选时无可切换目标，直接拨（省掉探测预算）。
    static func shouldProbe(candidateCount: Int) -> Bool { candidateCount > 1 }

    /// 一次并行探测的总预算。候选多给 1.5s，常规 1.2s —— 再慢也不该让"选路"成为
    /// 连接耗时的主体。
    static func probeTimeout(candidateCount: Int) -> TimeInterval {
        candidateCount > 3 ? 1.5 : 1.2
    }

    /// mDNS 发现预算：存着 LAN 候选（说明以前在同一 Wi-Fi）给 1.0s；纯中继网络
    /// 本机大概率不在 LAN，给 0.6s 尽快回到拨号。
    static func discoveryBudget(hasLANCandidate: Bool) -> TimeInterval {
        hasLANCandidate ? 1.0 : 0.6
    }

    // MARK: - 探测排序

    /// 探测结果排序：healthy 按延迟升序 → rejected → unreachable；同 origin 只留最好结果。
    static func rankProbes(_ observations: [ProbeObservation]) -> [ProbeObservation] {
        var best: [String: ProbeObservation] = [:]
        for observation in observations {
            let key = observation.origin.lowercased()
            if let existing = best[key] {
                if observation.result.rank < existing.result.rank
                    || (observation.result == existing.result && observation.latencyMs < existing.latencyMs) {
                    best[key] = observation
                }
            } else {
                best[key] = observation
            }
        }
        return best.values.sorted { lhs, rhs in
            if lhs.result.rank != rhs.result.rank { return lhs.result.rank < rhs.result.rank }
            if lhs.latencyMs != rhs.latencyMs { return lhs.latencyMs < rhs.latencyMs }
            return lhs.origin < rhs.origin
        }
    }
}
