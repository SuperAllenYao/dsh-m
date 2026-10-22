import Foundation
import Network

/// 局域网端点自愈：短暂浏览 `_dshm._tcp`，用 Bonjour **service endpoint** 直接打
/// 已配对 Mac 的 `/health`（TLS 证书 pin 与正式连接一致），拿回 Mac **当前** 的
/// `/health.deviceEndpoints`。
///
/// 为什么需要它：手机持久化的 LAN 地址来自配对那一刻；Mac 换 Wi-Fi / 换网段 /
/// 换路由器后旧 IP 永远超时，而中继地址也可能随隧道重部署变化。mDNS 是唯一
/// 「不依赖旧地址」的发现通道——Mac 现在广播的 hostId/SRV 就是它现在的地址。
@MainActor
enum LANEndpointDiscovery {

    struct Result: Equatable {
        /// Mac 当前广播且 `/health` 已验证可拨的 https origin（顺序沿用 Mac 端点）。
        var origins: [String] = []
        /// 匹配到的 Mac hostId（确认是同一台）。
        var hostId: String?
        /// TXT 里广播的中继 origin（可选；中继地址的最新来源）。
        var relayOrigin: String?

        var isEmpty: Bool { origins.isEmpty && relayOrigin == nil }
    }

    /// 发现预算内尽量完成一次 `browse -> /health -> deviceEndpoints`。
    ///
    /// - Parameters:
    ///   - hostId: 已配对 Mac 的 hostId（旧凭据可能为 nil）。
    ///   - leafPin: 与正式连接一致的证书 pin（严格校验，不做 TOFU）。
    ///   - budget: 总预算（调用方来自 `EndpointHealing.discoveryBudget`）。
    static func discover(
        hostId: String?,
        leafPin: String?,
        caCertBase64: String?,
        budget: TimeInterval
    ) async -> Result {
        // 模拟器没有本地网络权限/多播语义差异，E2E 脚手架可用环境变量关掉。
        if BonjourDiscovery.isDisabledByEnvironment { return Result() }
        let discovery = BonjourDiscovery()
        defer { discovery.stop() }
        discovery.start()
        let deadline = Date().addingTimeInterval(max(0.2, budget))
        while discovery.macs.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        let macs = discovery.macs
        guard !macs.isEmpty else { return Result() }
        let matched = matchMacs(macs, hostId: hostId)
        guard !matched.isEmpty else { return Result() }
        let perMacTimeout = max(0.8, min(1.4, budget))
        for mac in matched.prefix(2) {
            guard let health = try? await HTTPSClient.json(
                serviceEndpoint: mac.endpoint,
                hostHeader: mac.serviceName,
                method: "GET",
                path: "/health",
                leafPin: leafPin,
                caCertBase64: caCertBase64,
                timeout: perMacTimeout
            ) else { continue }
            guard health.status == 200, health.json["ok"]?.boolValue == true else { continue }
            let origins = (health.json["deviceEndpoints"]?.arrayValue ?? [])
                .compactMap { $0.stringValue }
                .compactMap { EndpointHealing.normalizedHTTPSOrigin($0) }
            return Result(origins: origins, hostId: mac.hostId, relayOrigin: mac.relayOrigin)
        }
        // browse 成功但 /health 打不通：至少把 TXT 的 relay 带回去（它不依赖旧地址）。
        return Result(hostId: matched.first?.hostId, relayOrigin: matched.first?.relayOrigin)
    }

    /// 选择要探测的 Mac。
    ///
    /// 优先 hostId 精确匹配；旧凭据没有 hostId、或 Mac 重置了身份（hostId 变化）时，
    /// **只有唯一一台 Mac 在广播**才采用它——多台时绝不猜，避免连到别人的 Mac。
    nonisolated static func matchMacs(_ macs: [DiscoveredMac], hostId: String?) -> [DiscoveredMac] {
        if let hostId, let matched = macs.first(where: { $0.hostId == hostId }) {
            return [matched]
        }
        if macs.count == 1 { return [macs[0]] }
        return []
    }
}
