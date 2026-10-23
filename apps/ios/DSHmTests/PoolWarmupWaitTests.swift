import XCTest
@testable import DSHm

/// 2026-10-23 T2(B1)：冷启动 HTTPS 池预热等待的语义回归（handoff §3.2 兜底要求）。
///
/// 覆盖三种语义：
/// 1. 预热已完成 → 立即返回；
/// 2. 预热未完成 → 按 timeout 上限返回，不抛错（底层预热继续在后台跑）；
/// 3. 预热失败（任务内部吞掉 `/health` 错误后结束）→ 仍返回，调用方继续走原路径。
///
/// 另锁两个与收益相关的前提：
/// 4. 冷启动门控矩阵——热路径（`networkApplied`）与无在飞预热时零等待；
/// 5. 预热 origin 与 early list 的 `originOverride` 必须一致（同一个连接池 key），
///    否则等再久也不会复用预热建好的 TLS。
///
/// `LinkService` 是 @MainActor 且 `init` 会读凭据/启动连接，不适合直接实例化；
/// 因此把等待逻辑抽成 `PoolWarmupWait` 纯工具后在这里单测，`LinkService` 侧只保留
/// 一个 guard + 转发。
final class PoolWarmupWaitTests: XCTestCase {

    // MARK: - 1. 预热已完成：立即返回

    func testWaitReturnsImmediatelyWhenWarmupAlreadyCompleted() async {
        let warmup = Task<Void, Never> {}
        await warmup.value
        let started = Date()
        await PoolWarmupWait.wait(for: warmup, timeoutMs: 350)
        let elapsedMs = Date().timeIntervalSince(started) * 1000
        XCTAssertLessThan(elapsedMs, 100, "已完成的预热不得再占用等待预算")
    }

    // MARK: - 2. 超时：按上限返回、不抛错

    func testWaitTimesOutAtUpperBoundWithoutThrowing() async {
        // 模拟「预热很慢/卡住」：底层任务远比预算长。
        let warmup = Task<Void, Never> {
            _ = try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        let started = Date()
        // 非 throwing API：能返回即代表没有抛错。
        await PoolWarmupWait.wait(for: warmup, timeoutMs: 120)
        let elapsedMs = Date().timeIntervalSince(started) * 1000
        XCTAssertGreaterThanOrEqual(elapsedMs, 80, "不应早于预算返回")
        XCTAssertLessThan(elapsedMs, 1_000, "必须按 timeout 上限放行，不能等到底层预热结束")
        warmup.cancel()
    }

    // MARK: - 3. 预热失败：仍能继续

    func testWaitReturnsWhenWarmupFailedSoCallerContinues() async {
        // 真实预热的失败形态：`try? HTTPSClient.json(/health)` 吞错后任务正常结束。
        let warmup = Task<Void, Never> {
            do {
                throw NSError(domain: "PoolWarmupWaitTests", code: 1)
            } catch {
                // warm-up 语义：失败静默结束，调用方走原路径。
            }
        }
        let started = Date()
        var callerContinued = false
        await PoolWarmupWait.wait(for: warmup, timeoutMs: 350)
        callerContinued = true
        let elapsedMs = Date().timeIntervalSince(started) * 1000
        XCTAssertTrue(callerContinued)
        XCTAssertLessThan(elapsedMs, 300, "失败结束应立即放行，而不是拖到超时")
    }

    // MARK: - 4. 非法/零预算：立即返回

    func testNonPositiveTimeoutReturnsImmediately() async {
        let warmup = Task<Void, Never> {
            _ = try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let started = Date()
        await PoolWarmupWait.wait(for: warmup, timeoutMs: 0)
        let elapsedMs = Date().timeIntervalSince(started) * 1000
        XCTAssertLessThan(elapsedMs, 100)
        warmup.cancel()
    }

    // MARK: - 5. 冷启动门控矩阵（热路径零等待）

    func testShouldAwaitPoolWarmupDecisionMatrix() {
        XCTAssertTrue(
            WorkspaceViewModel.shouldAwaitPoolWarmup(networkApplied: false, warmupInFlight: true),
            "冷启动首份网络列表 + 预热在飞：等"
        )
        XCTAssertFalse(
            WorkspaceViewModel.shouldAwaitPoolWarmup(networkApplied: false, warmupInFlight: false),
            "没有在飞预热：立即走原路径"
        )
        XCTAssertFalse(
            WorkspaceViewModel.shouldAwaitPoolWarmup(networkApplied: true, warmupInFlight: true),
            "热路径（列表已落地）：零额外延迟"
        )
        XCTAssertFalse(
            WorkspaceViewModel.shouldAwaitPoolWarmup(networkApplied: true, warmupInFlight: false)
        )
    }

    @MainActor
    func testPoolWarmupTimeoutBudgetMatchesHandoff() {
        XCTAssertEqual(WorkspaceViewModel.poolWarmupWaitTimeoutMs, 350)
    }

    // MARK: - 6. 复用前提：预热 origin 与 early list override 一致

    func testRelayWarmupUsesSameOriginAsEarlyListOverride() {
        // 蜂窝/跨网：持久化 origin 是失效 LAN，early list 用 relay 覆盖。
        let lan = "https://192.168.1.10:30000"
        let relay = "https://relay.dshm.example.com:443"
        let candidates = PairingOriginSelector.reconnectCandidates(current: lan, stored: [lan, relay])
        // 与 `LinkService.earlyListOriginOverride()` 同一规则：prefersRelay 且 current 是
        // LAN → 取第一个非 LAN 候选（无覆盖时 unary 才用 credentials.originURL）。
        let earlyListOrigin = candidates.first { !PairingOriginSelector.isLANHost($0.host) }
        let warmupOrigin = LinkService.poolWarmupOrigin(
            current: lan,
            stored: [lan, relay],
            prefersRelay: true,
            local: nil
        )
        XCTAssertEqual(warmupOrigin, earlyListOrigin, "连接池按 origin 复用：两者必须同一个 URL")
        XCTAssertEqual(warmupOrigin?.host, "relay.dshm.example.com")
    }

    func testLANWarmupUsesStoredCurrentOrigin() {
        // 同网段：override 为 nil，unary 直接用 credentials.originURL；预热也必须打同一 origin。
        let lan = "https://192.168.1.10:30000"
        let warmupOrigin = LinkService.poolWarmupOrigin(
            current: lan,
            stored: [lan],
            prefersRelay: false,
            local: nil
        )
        XCTAssertEqual(warmupOrigin?.absoluteString, lan)
    }
}
