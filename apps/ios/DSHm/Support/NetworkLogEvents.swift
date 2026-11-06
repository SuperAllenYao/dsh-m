import Darwin
import Foundation

// MARK: - 轮次 traceId（DD-04 / AC-11）

/// 每轮连接生成一个 16 位小写十六进制 `traceId`（8 字节随机）。
///
/// 两类出口共用同一个值：
/// - legacy：HTTP 请求头 `x-dshm-trace`（含握手/鉴权/unary）与 WS upgrade 头；
/// - P1：hello 顶层 `trace`、upgrade 头、每条 unary 帧的 `headers`。
///
/// 旧插件对未知头/字段忽略（BASIS-21），因此不加协议版本门槛（DD-17）。
enum RoundTrace {
    private static let lock = NSLock()
    private static var currentTrace: String?

    /// 当前轮次的 traceId（未进入任何连接轮次时为 nil）。
    static var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return currentTrace
    }

    /// 进入新一轮连接：生成并记住 traceId。
    @discardableResult
    static func next() -> String {
        // 8 字节随机 → 16 位小写十六进制。`%016llx` 对 UInt64 恒定输出 16 位小写。
        let value = String(format: "%016llx", UInt64.random(in: UInt64.min...UInt64.max))
        lock.lock()
        currentTrace = value
        lock.unlock()
        return value
    }
}

// MARK: - 在飞请求登记（DD-18）

/// 线程安全的在飞请求登记表：`round.start` 的 `inflight{count,endpoints,oldestMs}`
/// 从这里取快照，用于回答「重连发生时还有哪些请求没回来、最老的多久」。
///
/// 只做内存数组操作（每次 begin/end 是 O(1)/O(n≤少量)），不触碰磁盘；写盘由
/// `NetworkLog` 的串行队列负责（AC-13）。
final class InflightTracker {
    static let shared = InflightTracker()

    private struct Entry {
        let endpoint: String
        let startedAt: Date
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    /// 快照里最多列 8 个 endpoint（设计 §4.2 `inflight{count,endpoints[≤8],oldestMs}`）。
    private let maxEndpoints = 8

    func begin(_ endpoint: String) {
        lock.lock()
        entries.append(Entry(endpoint: endpoint, startedAt: Date()))
        lock.unlock()
    }

    /// 结束一次登记。同一 endpoint 可能并发在飞，移除最先登记的那条。
    func end(_ endpoint: String) {
        lock.lock()
        if let index = entries.firstIndex(where: { $0.endpoint == endpoint }) {
            entries.remove(at: index)
        }
        lock.unlock()
    }

    /// 当前在飞快照。`oldestMs` 为最老请求的已等待毫秒数（无在飞请求时为 0）。
    func snapshot() -> (count: Int, endpoints: [String], oldestMs: Int) {
        lock.lock()
        let captured = entries
        lock.unlock()
        let now = Date()
        let endpoints = captured.prefix(maxEndpoints).map(\.endpoint)
        let oldest = captured.map { Int(now.timeIntervalSince($0.startedAt) * 1000) }.max() ?? 0
        return (captured.count, endpoints, max(0, oldest))
    }

    /// 单测/现场排障用：清空登记。
    func reset() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

// MARK: - 记录入口

/// 轻量记录入口：只构造字典并交给 `NetworkLog.record`（编码与写盘在串行队列，
/// 不在连接主路径做 I/O）。调用方可在任意线程调用。
@inline(__always)
func record(_ event: String, _ fields: [String: Any]) {
    NetworkLog.record(event, fields)
}

// MARK: - 链路状态镜像（供 app.lifecycle / phase.changed 读）

/// 当前链路 phase/generation 的无锁镜像。
///
/// `LinkService` 是 `@MainActor`，而 `env` / `app.lifecycle` 由 `AppDelegate` 在
/// 启动/前后台回调里写（同一主线程，但不必为读两个值跨 actor）。这里在每次
/// phase/generation 变化时同步一份字符串/整数镜像，读方永远是轻量内存读。
enum NetlogLinkState {
    private static let lock = NSLock()
    private static var phaseValue = "unpaired"
    private static var generationValue = 0

    static var phase: String {
        lock.lock()
        defer { lock.unlock() }
        return phaseValue
    }

    static var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return generationValue
    }

    static func update(phase: String? = nil, generation: Int? = nil) {
        lock.lock()
        if let phase { phaseValue = phase }
        if let generation { generationValue = generation }
        lock.unlock()
    }
}

// MARK: - 事件字段构造

/// `env` 事件（每次进程启动一次）：schema/app/os/model/interfaces/vpnHint。
///
/// 只用 `ProcessInfo`/`Bundle`/`uname`，不依赖 `UIDevice`（避免主线程隔离），
/// 因此 `AppDelegate` 的任意回调都能直接调用。
enum NetlogEnv {
    static func fields() -> [String: Any] {
        let (version, build): (String, String) = {
            let info = Bundle.main.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String ?? "-"
            let build = info?["CFBundleVersion"] as? String ?? "-"
            return (version, build)
        }()
        let (interfaces, vpnHint) = NetworkPathMonitor.loggingInterfaceSnapshot()
        return [
            "schema": "netlog/1",
            "app": ["version": version, "build": build],
            "os": operatingSystem(),
            "model": hardwareModel(),
            "interfaces": interfaces,
            "vpnHint": vpnHint,
        ]
    }

    private static func operatingSystem() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var text = "iOS \(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
        return text
    }

    /// 硬件机型标识（如 `iPhone16,2`）。不含用户可见名称，避免把设备名写进日志。
    private static func hardwareModel() -> String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "unknown" }
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }
}

/// `path.changed` 的前后快照、本机网段等字段构造。
enum NetlogPath {
    static func snapshotFields(_ snapshot: NetworkPathSnapshot?) -> [String: Any] {
        guard let snapshot else {
            return [
                "interface": NetworkPathSnapshot.InterfaceKind.unknown.rawValue,
                "satisfied": false,
                "expensive": false,
                "constrained": false,
            ]
        }
        return [
            "interface": snapshot.interface.rawValue,
            "satisfied": snapshot.isSatisfied,
            "expensive": snapshot.isExpensive,
            "constrained": snapshot.isConstrained,
        ]
    }

    /// 本机在当前主接口上的 IPv4 网段（如 `192.168.1.0/24`）；无 LAN 地址时 nil。
    static func localIPv4(_ network: LocalIPv4Network?) -> String? {
        guard let network else { return nil }
        let value = network.address
        let octets = [
            (value >> 24) & 0xFF,
            (value >> 16) & 0xFF,
            (value >> 8) & 0xFF,
            value & 0xFF,
        ]
        let host = octets.map(String.init).joined(separator: ".")
        return "\(host)/\(network.prefixLength)"
    }
}

/// 候选地址字段（设计 §4.2：`role`/`kind`/`port`，LAN 候选另记 `host`；
/// relay 不记域名/IP）。
enum NetlogCandidate {
    static func fields(_ url: URL, local: LocalIPv4Network?, index: Int? = nil) -> [String: Any] {
        let role = LinkService.candidateRole(host: url.host, local: local)
        var fields: [String: Any] = [
            "role": roleName(role),
            "kind": kindName(host: url.host, role: role),
            "port": url.port ?? 443,
        ]
        if let index { fields["i"] = index }
        if role != .relay, let host = url.host, !host.isEmpty {
            fields["host"] = host
        }
        return fields
    }

    /// 设计 §4.2 用驼峰枚举名（relay/lanSameSubnet/lanOther），与内部 rawValue 不同。
    static func roleName(_ role: LinkService.CandidateRole) -> String {
        switch role {
        case .relay: return "relay"
        case .lanSameSubnet: return "lanSameSubnet"
        case .lanOther: return "lanOther"
        }
    }

    static func kindName(host: String?, role: LinkService.CandidateRole) -> String {
        if PairingOriginSelector.isLoopbackHost(host) { return "loopback" }
        return role == .relay ? "relay" : "lan"
    }
}

/// 应用生命周期事件（launch/foreground/background）。phase/generation 来自
/// `LinkService` 的镜像；进程刚启动、链路还没建立时写默认值。
enum NetlogLifecycle {
    static func record(_ state: String) {
        NetworkLog.record("app.lifecycle", [
            "state": state,
            "phase": NetlogLinkState.phase,
            "generation": NetlogLinkState.generation,
        ])
    }
}

/// `stage.events`：补充 `dial.result` 覆盖不到的异步阶段（如 `$events` ready
/// 握手在 connected 之后才完成）。
enum NetlogStage {
 /// 记录一次异步阶段。`trace` 传入发起时刻的轮次 id（阶段跨轮完成时仍归到发起轮）；
 /// nil 表示取当前轮（`RoundTrace.current`）。
    static func record(
        _ stage: String,
        startedAt: Date,
        ok: Bool,
        errorClass: String? = nil,
        trace: String? = nil
    ) {
        var fields: [String: Any] = [
            "stage": stage,
            "ms": Int(Date().timeIntervalSince(startedAt) * 1000),
            "ok": ok,
        ]
        if let trace = trace ?? RoundTrace.current, !trace.isEmpty { fields["trace"] = trace }
        if let errorClass { fields["errorClass"] = errorClass }
        NetworkLog.record("stage.events", fields)
    }

    /// 轻量错误分类（只用于日志 `errorClass`，不参与任何逻辑判断）。
    static func errorClass(for error: Error) -> String {
        if let linkError = error as? LinkError {
            switch linkError {
            case .timeout: return "timeout"
            case .cancelled: return "cancelled"
            case .transport: return "transport"
            case .httpStatus(let status, _): return "http-\(status)"
            case .remote: return "remote"
            default: return "other"
            }
        }
        return "other"
    }
}
