import XCTest
@testable import DSHm

/// 「下拉加载更早」触发判定的单测（纯逻辑）。
///
/// 2026-10-22 真机回归：触发距离改为 240pt 后，用户贴顶下拉完全无法加载。
/// 原因是旧实现用「手势开始 offset - 手势结束 offset」算位移，而贴顶下拉进入
/// rubber-band 后松手会弹回 0，算出的位移恒为 0。这里锁定「累计峰值」的口径。
final class NearTopPullTrackerTests: XCTestCase {

    /// 贴顶下拉：offset 变负（rubber-band），松手弹回 0，但峰值已超过阈值 → 触发。
    func testPullAtTopBeyondThresholdTriggersEvenAfterBounceBack() {
        var tracker = NearTopPullTracker()
        XCTAssertTrue(tracker.isNearTop)
        tracker.gestureBegan()
        tracker.updateOffset(-120)
        tracker.updateOffset(-380)
        // 松手回弹：idle 之前 offset 已经回到顶部
        tracker.updateOffset(-40)
        tracker.updateOffset(0)
        XCTAssertTrue(tracker.gestureEnded(), "峰值 380pt 应触发加载，不能因为回弹后 offset=0 而失效")
    }

    /// 贴顶状态下的轻微搓动（< 240pt 峰值）不触发——这正是用户要求"放大 2 倍"的意图。
    func testSmallWiggleAtTopDoesNotTrigger() {
        var tracker = NearTopPullTracker()
        tracker.gestureBegan()
        tracker.updateOffset(-30)
        tracker.updateOffset(-80)
        tracker.updateOffset(0)
        XCTAssertFalse(tracker.gestureEnded())
    }

    /// 从中段一路拉到顶部：位移远大于阈值 → 触发。
    func testPullFromMidListToTopTriggers() {
        var tracker = NearTopPullTracker()
        tracker.updateOffset(1200)
        tracker.gestureBegan()
        tracker.updateOffset(900)
        tracker.updateOffset(300)
        tracker.updateOffset(0)
        XCTAssertTrue(tracker.gestureEnded())
    }

    /// 拉了很长距离但松手时没有到达顶部附近 → 不触发（避免半路误加载）。
    func testPullEndingAwayFromTopDoesNotTrigger() {
        var tracker = NearTopPullTracker()
        tracker.updateOffset(3000)
        tracker.gestureBegan()
        tracker.updateOffset(2500)
        tracker.updateOffset(2400)
        XCTAssertFalse(tracker.isNearTop)
        XCTAssertFalse(tracker.gestureEnded())
    }

    /// 程序化滚动（贴底跟随/锚点恢复）不经过手势：不得触发加载。
    func testProgrammaticScrollWithoutGestureDoesNotTrigger() {
        var tracker = NearTopPullTracker()
        tracker.updateOffset(1800)
        tracker.updateOffset(600)
        tracker.updateOffset(0)
        XCTAssertFalse(tracker.gestureEnded(), "没有 gestureBegan 的滚动不能算用户下拉")
    }

    /// 连续多次下拉：每次手势独立判定，不会因为上一次触发而失效。
    func testConsecutiveGesturesAreJudgedIndependently() {
        var tracker = NearTopPullTracker()

        tracker.gestureBegan()
        tracker.updateOffset(-300)
        tracker.updateOffset(0)
        XCTAssertTrue(tracker.gestureEnded(), "第 1 次下拉应触发")

        tracker.gestureBegan()
        tracker.updateOffset(-20)
        tracker.updateOffset(0)
        XCTAssertFalse(tracker.gestureEnded(), "第 2 次轻微搓动不应触发")

        tracker.gestureBegan()
        tracker.updateOffset(-260)
        tracker.updateOffset(0)
        XCTAssertTrue(tracker.gestureEnded(), "第 3 次下拉仍应触发（连续下拉回归 §4.2）")
    }

    /// 阈值边界：offset == 240 算顶部附近，241 不算。
    func testNearTopThresholdBoundary() {
        var tracker = NearTopPullTracker()
        tracker.updateOffset(240)
        XCTAssertTrue(tracker.isNearTop)
        tracker.updateOffset(241)
        XCTAssertFalse(tracker.isNearTop)
    }

    /// 峰值在回弹前累计：先超过阈值再回弹，仍应触发。
    func testPeakIsAccumulatedBeforeBounce() {
        var tracker = NearTopPullTracker()
        tracker.gestureBegan()
        tracker.updateOffset(-100)
        tracker.updateOffset(-260)
        tracker.updateOffset(-90)
        XCTAssertEqual(tracker.maxPullDistance, 260)
        tracker.updateOffset(0)
        XCTAssertTrue(tracker.gestureEnded())
    }
}
