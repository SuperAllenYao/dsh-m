import XCTest
@testable import DSHm

/// 2026-10-23 T2(B2)：api token Keychain 持久化的语义回归。
///
/// 用注入的内存后端 + 固定时钟覆盖：存取往返、过期/5s 窗口、hostId 隔离、清除、
/// 写入失败降级、续期窗口判定。真实 Keychain（`AfterFirstUnlockThisDeviceOnly`）
/// 与首次安装行为由真机验收覆盖。
final class APITokenStoreTests: XCTestCase {

    final class InMemoryBackend: APITokenBackend {
        var items: [String: Data] = [:]
        var failWrites = false

        func read(account: String) -> Data? { items[account] }

        @discardableResult
        func write(_ data: Data, account: String) -> Bool {
            guard !failWrites else { return false }
            items[account] = data
            return true
        }

        func delete(account: String) { items[account] = nil }

        func deleteAll() { items.removeAll() }
    }

    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private var backend: InMemoryBackend!
    private var store: APITokenStore!

    override func setUp() {
        super.setUp()
        backend = InMemoryBackend()
        let now = fixedNow
        store = APITokenStore(backend: backend, now: { now })
    }

    private func token(_ value: String, expiresIn seconds: TimeInterval) -> StoredAPIToken {
        StoredAPIToken(token: value, expiresAt: fixedNow.addingTimeInterval(seconds))
    }

    // MARK: - 存取往返

    func testSaveThenLoadRoundTripsTokenAndExpiry() throws {
        XCTAssertTrue(store.save(token("tok-1", expiresIn: 1_800), scope: "mac-A"))
        let loaded = try XCTUnwrap(store.load(scope: "mac-A"))
        XCTAssertEqual(loaded.token, "tok-1")
        XCTAssertEqual(loaded.expiresAt.timeIntervalSince1970, fixedNow.addingTimeInterval(1_800).timeIntervalSince1970, accuracy: 0.001)
    }

    func testSaveOverwritesSameHost() throws {
        XCTAssertTrue(store.save(token("tok-old", expiresIn: 600), scope: "mac-A"))
        XCTAssertTrue(store.save(token("tok-new", expiresIn: 1_800), scope: "mac-A"))
        let loaded = try XCTUnwrap(store.load(scope: "mac-A"))
        XCTAssertEqual(loaded.token, "tok-new")
        XCTAssertEqual(backend.items.count, 1, "same hostId must reuse one Keychain item")
    }

    // MARK: - 过期 / 快路径窗口

    func testExpiredTokenIsNotLoaded() {
        XCTAssertTrue(store.save(token("tok-expired", expiresIn: -1), scope: "mac-A"))
        XCTAssertNil(store.load(scope: "mac-A"), "expired token must never be reused")
    }

    func testTokenWithinFiveSecondWindowIsNotLoaded() {
        XCTAssertTrue(store.save(token("tok-nearly", expiresIn: 3), scope: "mac-A"))
        XCTAssertNil(store.load(scope: "mac-A"), "<=5s remaining must match ensureAPIToken's fast-path gate")
        XCTAssertTrue(store.save(token("tok-fresh", expiresIn: 60), scope: "mac-A"))
        XCTAssertNotNil(store.load(scope: "mac-A"))
    }

    // MARK: - hostId 隔离

    func testHostIdIsolation() throws {
        XCTAssertTrue(store.save(token("tok-A", expiresIn: 1_800), scope: "mac-A"))
        XCTAssertTrue(store.save(token("tok-B", expiresIn: 1_800), scope: "mac-B"))
        XCTAssertEqual(try XCTUnwrap(store.load(scope: "mac-A")).token, "tok-A")
        XCTAssertEqual(try XCTUnwrap(store.load(scope: "mac-B")).token, "tok-B")
        XCTAssertNil(store.load(scope: "mac-C"), "another Mac must never inherit this token")
        XCTAssertNil(store.load(scope: nil))
        XCTAssertNil(store.load(scope: ""))
    }

    func testNilHostIdIsNeverPersisted() {
        XCTAssertFalse(store.save(token("tok", expiresIn: 1_800), scope: nil))
        XCTAssertFalse(store.save(token("tok", expiresIn: 1_800), scope: ""))
        XCTAssertTrue(backend.items.isEmpty, "no scope -> no persistence")
    }

    // MARK: - scope 推导（hostId 优先，旧凭据回退端点指纹）

    func testScopePrefersHostIdThenFallsBackToLeafPin() {
        XCTAssertEqual(APITokenStore.scope(hostId: "mac-A", leafPin: "pin-A"), "host:mac-A")
        // 真机事故回归：旧配对凭据没有 hostId（hostId 字段 2026-10-23 才引入），
        // 若只认 hostId，B2 的 token 持久化会完全失效。这里必须回退到 leafPin 指纹。
        XCTAssertEqual(APITokenStore.scope(hostId: nil, leafPin: "pin-A"), "pin:pin-A")
        XCTAssertEqual(APITokenStore.scope(hostId: "", leafPin: "pin-A"), "pin:pin-A")
        // 两者都缺：拒绝持久化（无法安全隔离到某台 Mac）。
        XCTAssertNil(APITokenStore.scope(hostId: nil, leafPin: nil))
        XCTAssertNil(APITokenStore.scope(hostId: "", leafPin: ""))
        // 不同 Mac 的端点指纹不同 -> 不同 scope（不会跨设备复用）。
        XCTAssertNotEqual(
            APITokenStore.scope(hostId: nil, leafPin: "pin-A"),
            APITokenStore.scope(hostId: nil, leafPin: "pin-B")
        )
    }

    func testKeychainAccountIsStableAndDoesNotLeakHostId() {
        let a1 = APITokenStore.account(for: "mac-A")
        let a2 = APITokenStore.account(for: "mac-A")
        let b = APITokenStore.account(for: "mac-B")
        XCTAssertEqual(a1, a2, "same Mac must map to the same Keychain item")
        XCTAssertNotEqual(a1, b, "different Macs must not share an item")
        XCTAssertTrue(a1.hasPrefix("api-token."))
        XCTAssertFalse(a1.contains("mac-A"), "raw hostId must not be used as the Keychain account")
    }

    // MARK: - 清除

    func testClearRemovesOnlyThatHost() {
        XCTAssertTrue(store.save(token("tok-A", expiresIn: 1_800), scope: "mac-A"))
        XCTAssertTrue(store.save(token("tok-B", expiresIn: 1_800), scope: "mac-B"))
        store.clear(scope: "mac-A")
        XCTAssertNil(store.load(scope: "mac-A"))
        XCTAssertNotNil(store.load(scope: "mac-B"))
    }

    func testClearAllRemovesEveryHost() {
        XCTAssertTrue(store.save(token("tok-A", expiresIn: 1_800), scope: "mac-A"))
        XCTAssertTrue(store.save(token("tok-B", expiresIn: 1_800), scope: "mac-B"))
        store.clearAll()
        XCTAssertNil(store.load(scope: "mac-A"))
        XCTAssertNil(store.load(scope: "mac-B"))
        XCTAssertTrue(backend.items.isEmpty)
    }

    // MARK: - 降级 / 损坏数据

    func testBackendWriteFailureDegradesToNoPersistence() {
        backend.failWrites = true
        XCTAssertFalse(store.save(token("tok", expiresIn: 1_800), scope: "mac-A"))
        XCTAssertNil(store.load(scope: "mac-A"))
        XCTAssertTrue(backend.items.isEmpty)
    }

    func testCorruptedPayloadIsIgnored() {
        backend.items[APITokenStore.account(for: "mac-A")] = Data("not-json".utf8)
        XCTAssertNil(store.load(scope: "mac-A"))
    }

    // MARK: - 主动续期窗口（纯策略）

    func testShouldRenewDecisionMatrix() {
        XCTAssertFalse(APITokenStore.shouldRenew(expiresAt: nil, inFlight: false, now: fixedNow))
        XCTAssertFalse(APITokenStore.shouldRenew(expiresAt: nil, inFlight: true, now: fixedNow))
        // 剩余 25 分钟：不需要续期。
        XCTAssertFalse(APITokenStore.shouldRenew(expiresAt: fixedNow.addingTimeInterval(25 * 60), inFlight: false, now: fixedNow))
        // 剩余 19 分钟：进入 20 分钟续期窗口。
        XCTAssertTrue(APITokenStore.shouldRenew(expiresAt: fixedNow.addingTimeInterval(19 * 60), inFlight: false, now: fixedNow))
        // 边界：恰好 20 分钟不续期（严格小于）。
        XCTAssertFalse(APITokenStore.shouldRenew(expiresAt: fixedNow.addingTimeInterval(20 * 60), inFlight: false, now: fixedNow))
        // 已过期：下次 connected 时也值得续一次。
        XCTAssertTrue(APITokenStore.shouldRenew(expiresAt: fixedNow.addingTimeInterval(-1), inFlight: false, now: fixedNow))
        // 已有续期任务在飞：单飞，不重复触发。
        XCTAssertFalse(APITokenStore.shouldRenew(expiresAt: fixedNow.addingTimeInterval(60), inFlight: true, now: fixedNow))
    }
}
