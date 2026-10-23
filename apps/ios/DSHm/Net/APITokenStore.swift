import Foundation
import Security

/// T2(B2)：一条可持久化复用的 api token。
struct StoredAPIToken: Equatable {
    let token: String
    let expiresAt: Date
}

/// api token 的存储后端：生产走 Keychain；单测注入内存实现（不依赖签名/Keychain 环境）。
protocol APITokenBackend {
    func read(account: String) -> Data?
    @discardableResult
    func write(_ data: Data, account: String) -> Bool
    func delete(account: String)
    func deleteAll()
}

/// T2(B2)：冷启动复用 api token 的本机 Keychain 存储。
///
/// 目标：api token TTL 60min，冷启动直接复用未过期 token，省掉 challenge+verify
/// 两个 RTT。
///
/// 安全约束：
/// - 只存本机 Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，与
/// `CredentialStore` 的配对凭据同级；不随 iCloud/备份迁移），不上传、不写日志；
/// - **按 `hostId` 隔离**：Keychain account 由 `sha256(hostId)` 派生，换 Mac /
/// 重新配对不会复用其它设备的 token；hostId 为空的旧凭据拒绝持久化；
/// - token 明文不出现在系统日志里（调用方只记录「是否命中」）。
///
/// 语义：
/// - `save` 覆盖同一 hostId 的记录；
/// - `load` 只返回剩余有效期 > 5s 的 token（与 `ensureAPIToken` 快路径门槛一致）；
/// - `clear(hostId:)` 精确清除；`clearAll()` 在解绑设备时清全部。
final class APITokenStore {
    static let shared = APITokenStore()

 /// 与 `ensureAPIToken` 快路径一致：剩余 <= 5s 的 token 视为不可用。
    static let minimumRemaining: TimeInterval = 5
 /// 主动续期窗口：剩余 < 20min 时在链路就绪/前台恢复后后台刷新一次。
    static let renewalLeadTime: TimeInterval = 20 * 60

    private let backend: APITokenBackend
    private let now: () -> Date

    init(backend: APITokenBackend = KeychainAPITokenBackend(), now: @escaping () -> Date = Date.init) {
        self.backend = backend
        self.now = now
    }

 /// Keychain account：sha256(hostId) 派生，避免把 Mac 标识直接写进 Keychain 项。
    static func account(for hostId: String) -> String {
        "api-token." + PinFormat.sha256Hex(Data(hostId.utf8))
    }

 /// 保存（同一 hostId 覆盖）。hostId 为空时不持久化（无法安全隔离到某台 Mac）。
    @discardableResult
    func save(_ token: StoredAPIToken, hostId: String?) -> Bool {
        guard let hostId, !hostId.isEmpty else { return false }
        let payload = Payload(token: token.token, expiresAtMs: Self.milliseconds(token.expiresAt))
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        return backend.write(data, account: Self.account(for: hostId))
    }

 /// 只返回仍可用的 token；过期/损坏/hostId 缺失都返回 nil。
    func load(hostId: String?) -> StoredAPIToken? {
        guard let hostId, !hostId.isEmpty else { return nil }
        guard let data = backend.read(account: Self.account(for: hostId)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let expiresAt = Date(timeIntervalSince1970: TimeInterval(payload.expiresAtMs) / 1000)
        guard expiresAt.timeIntervalSince(now()) > Self.minimumRemaining else { return nil }
        return StoredAPIToken(token: payload.token, expiresAt: expiresAt)
    }

    func clear(hostId: String?) {
        guard let hostId, !hostId.isEmpty else { return }
        backend.delete(account: Self.account(for: hostId))
    }

    func clearAll() {
        backend.deleteAll()
    }

 /// 主动续期判定（纯策略，单测覆盖）：有 token、剩余 < 20min、且当前没有续期
 /// 任务在飞时，后台 forceRefresh 一次。`expiresAt == nil`（从未认证/已清除）
 /// 不触发——正常请求的认证路径会处理。
    static func shouldRenew(expiresAt: Date?, inFlight: Bool, now: Date = Date()) -> Bool {
        guard !inFlight, let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < renewalLeadTime
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private struct Payload: Codable {
        let token: String
        let expiresAtMs: Int64
    }
}

/// Keychain 后端。模拟器编译沿用 `CredentialStore` 的本地 fallback 文件，让无签名
/// 模拟器 build 的冷启动 E2E 也能命中 token 持久化；真机只用 Keychain。
struct KeychainAPITokenBackend: APITokenBackend {
    private let service = "com.dshm.app.api-token"

    func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return data }
        #if targetEnvironment(simulator)
        return try? Data(contentsOf: Self.fallbackURL(account: account))
        #else
        return nil
        #endif
    }

    @discardableResult
    func write(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        #if targetEnvironment(simulator)
        try? data.write(to: Self.fallbackURL(account: account), options: [.atomic])
        return true
        #else
        return status == errSecSuccess
        #endif
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        #if targetEnvironment(simulator)
        try? FileManager.default.removeItem(at: Self.fallbackURL(account: account))
        #endif
    }

    func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        #if targetEnvironment(simulator)
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: Self.fallbackDirectory, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix(Self.fallbackPrefix) {
                try? fm.removeItem(at: file)
            }
        }
        #endif
    }

    #if targetEnvironment(simulator)
    private static let fallbackPrefix = "t2-api-token-"

    private static var fallbackDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func fallbackURL(account: String) -> URL {
        fallbackDirectory.appendingPathComponent(fallbackPrefix + account + ".json")
    }
    #endif
}
